# frozen_string_literal: true

# Author::    Alex Cummaudo  (mailto:ca@deakin.edu.au)
# Copyright:: Copyright (c) 2019 Alex Cummaudo
# License::   MIT License

require 'sequel'
require 'logger'
require 'dotenv/load'
require 'google/cloud/vision'
require 'aws-sdk-rekognition'
require 'net/http/post/multipart'
require 'down'
require 'uri'
require 'json'
require 'tempfile'
require 'rufus-scheduler'

# Intelligent Computer Vision Service Benchmarker (ICVSB) module. This module
# implements an architectural pattern that helps overcome evolution issues
# within intelligent computer vision services.
module ICVSB
  VALID_SERVICES = %i[google_cloud_vision amazon_rekognition azure_computer_vision].freeze
  VALID_SEVERITIES = %i[exception warning info none].freeze

  @log = Logger.new(ENV['ICVSB_LOGGER_FILE'] || STDOUT)
  def self.log
    @log
  end

  #################################
  # Database schema creation seed #
  #################################
  url = ENV['ICVSB_DATABASE_CONNTECTION_URL'] || 'sqlite://icvsb.db'
  log = ENV['ICVSB_DATABASE_LOG_FILE'] || 'icvsb.db.log'
  dbc = Sequel.connect(url, logger: Logger.new(log))
  # Create Services and Severity enums...
  dbc.create_table?(:services) do
    primary_key :id
    column :name, 'char(32)', null: false, unique: true
  end
  dbc.create_table?(:benchmark_severities) do
    primary_key :id
    column :name, 'char(32)', null: false, unique: true
  end
  if dbc[:services].first.nil?
    VALID_SERVICES.each { |s| dbc[:services].insert(name: s.to_s) }
    VALID_SEVERITIES.each { |s| dbc[:benchmark_severities].insert(name: s.to_s) }
  end
  # Create Objects...
  dbc.create_table?(:batch_requests) do
    primary_key :id
    column :created_at, 'timestamp', null: false
  end
  dbc.create_table?(:requests) do
    primary_key :id
    foreign_key :service_id,        :services,       null: false
    foreign_key :batch_request_id,  :batch_requests, null: true

    column :created_at, 'timestamp', null: false
    column :uri, 'string',           null: false

    index %i[service_id batch_request_id]
  end
  dbc.create_table?(:responses) do
    primary_key :id
    foreign_key :request_id, :requests, null: false

    column :created_at, 'timestamp', null: false
    column :body,       'blob',      null: false
    column :success,    'boolean',   null: false

    index :request_id
  end
  dbc.create_table?(:benchmark_keys) do
    primary_key :id
    foreign_key :service_id,            :services,             null: false
    foreign_key :batch_request_id,      :batch_requests,       null: false
    foreign_key :benchmark_severity_id, :benchmark_severities, null: false

    column :created_at,       'timestamp',  null: false
    column :expired,          'boolean',    null: false
    column :delta_labels,     'integer',    null: false
    column :delta_confidence, 'numeric',    null: false
    column :max_labels,       'integer',    null: false
    column :min_confidence,   'numeric',    null: false

    index %i[service_id batch_request_id]
  end

  class Service < Sequel::Model(dbc)
    GOOGLE = Service[name: VALID_SERVICES[0].to_s]
    AMAZON = Service[name: VALID_SERVICES[1].to_s]
    AZURE  = Service[name: VALID_SERVICES[2].to_s]
  end

  class BenchmarkSeverity < Sequel::Model(dbc[:benchmark_severities])
    EXCEPTION = BenchmarkSeverity[name: VALID_SEVERITIES[0].to_s][:id]
    WARNING   = BenchmarkSeverity[name: VALID_SEVERITIES[1].to_s][:id]
    INFO      = BenchmarkSeverity[name: VALID_SEVERITIES[2].to_s][:id]
    NONE      = BenchmarkSeverity[name: VALID_SEVERITIES[3].to_s][:id]
  end

  class Request < Sequel::Model(dbc)
    many_to_one :service
    many_to_one :batch
    one_to_one :response

    def success?
      response.success?
    end
  end

  class Response < Sequel::Model(dbc)
    many_to_one :request

    def success?
      success
    end

    def hash
      JSON.parse(body.lit.to_s, symbolize_names: true).to_h
    end

    def labels
      if success?
        case request.service
        when Service::GOOGLE
          _google_cloud_vision_labels
        when Service::AMAZON
          _amazon_rekognition_labels
        when Service::AZURE
          _azure_computer_vision_labels
        end
      else
        {}
      end
    end

    private

    def _google_cloud_vision_labels
      hash[:responses][0][:label_annotations].map do |label|
        [label[:description].downcase, label[:score]]
      end.to_h
    end

    def _amazon_rekognition_labels
      hash[:labels].map do |label|
        [label[:name].downcase, label[:confidence] * 0.01]
      end.to_h
    end

    def _azure_computer_vision_labels
      hash[:tags].map do |label|
        [label[:name].downcase, label[:confidence]]
      end.to_h
    end
  end

  class BatchRequest < Sequel::Model(dbc)
    one_to_many :requests

    def success?
      requests.map(&:success?).reduce(:&)
    end

    def responses
      requests.map(&:response)
    end

    def uris
      requests.map(&:uri)
    end
  end

  class BenchmarkKey < Sequel::Model(dbc)
    many_to_one :service
    many_to_one :benchmark_severity
    one_to_one  :batch_request

    def success?
      batch_request.success?
    end

    def expired?
      expired
    end

    def expire
      self.expired = false
      save
    end

    def valid_against?(key)
      ICVSB.log.info("Validating key id=#{id} with other key id=#{key.id}")

      # 1. Ensure same services!
      if key.service != service
        ICVSB.log.warn("Service mismatch in validation: #{key.service.name} != #{service.name}")
        return false
      end

      # 2. Ensure same benchmark dataset
      symm_diff_uris = Set[*service.uris] ^ Set[*key.batch_request.uris]
      unless symm_diff_uris.empty?
        ICVSB.log.warn('Benchmark dataset mismatch in key validation: '\
          "Symm difference contains #{symm_diff_uris.count} different URIs")
        return false
      end

      # 3. Ensure successful request made in BOTH instances
      unless key.success? && success?
        ICVSB.log.warn('Sucesss mismatch in key validation')
        return false
      end

      # 4. Ensure the same max label and min confs are unchanged
      unless key.min_confidence == min_confidence && key.max_labels == max_labels
        ICVSB.log.warn('Minimum confidence or max labels mismatch in key validation')
        return false
      end

      # 4. Ensure same number of results...
      unless batch_request.responses.length == key.batch_request.responses.length
        ICVSB.log.warn('Number of responses mismatch in key validation')
        return false
      end

      # 4. Validate every response's label count and confidence delta
      our_requests = batch_request.requests
      their_requests = key.batch_request.requests
      our_requests.each do |our_request|
        this_uri = request.uri
        their_request = their_requests[uri: this_uri]

        our_labels = Set[our_request.response.labels.keys]
        their_labels = Set[their_request.response.labels.keys]

        if (our_labels ^ their_labels).length > delta_labels
          ICVSB.log.warn('Number of labels mismatch in key validation')
          return false
        end

        our_request.response.labels.each do |label, conf|
          our_conf = conf
          their_conf = their_request.response.labels[label]

          if (our_conf - their_conf).abs > delta_confidence
            ICVSB.log.warn('Maximum confidence delta breached in key validation')
            return false
          end
        end
      end

      true
    end
  end

  # The Request Client class is used to make non-benchmarked requests to the
  # provided service's labelling endpoints. It handles creating respective
  # +Request+ and +Response+ records to be commited to the benchmarker database.
  # Requests made with the +RequestClient+ do *not* ensure that evolution risk
  # has occured (see #BenchmarkedRequestClient).
  class RequestClient
    # Initialises a new instance of the requester to label endpoints.
    # @param [Service] service The service to request from.
    # @param [Fixnum] max_labels The maximum labels that the requester returns.
    #   Only supported if the service supports this parameter. Default is 100
    #   labels.
    # @param [Float] min_confidence The confidence threshold by which labels
    #   are returned. Only supported if the service supports this parameter.
    #   Default is 0.50.
    def initialize(service, max_labels: 100, min_confidence: 0.50)
      unless service.is_a?(Service) && [Service::GOOGLE, Service::AMAZON, Service::AZURE].include?(service)
        raise ArgumentError, "Service with name #{service.name} not supported."
      end

      @service = service
      @service_client =
        case @service
        when Service::GOOGLE
          Google::Cloud::Vision::ImageAnnotator.new
        when Service::AMAZON
          Aws::Rekognition::Client.new
        when Service::AZURE
          URI('https://australiaeast.api.cognitive.microsoft.com/vision/v2.0/analyze')
        end
      @config = {
        max_labels: max_labels,
        min_confidence: min_confidence
      }
    end

    # Sends a request to the client's respective service endpoint. Does *not*
    # validate a response against a key (see #ICVSB::BenchmarkedRequestClient).
    # Params:
    # @param [String] uri A URI to an image to detect labels.
    # @param [BatchRequest] batch The batch that the request is being made
    #   under. Defaults to nil.
    # @return [Response] The response record commited to the benchmarker
    #   database.
    def send_uri(uri, batch: nil)
      raise ArgumentError, 'Batch must be a BatchRequest.' if !batch.nil? && !batch.is_a?(BatchRequest)

      batch_id = batch.nil? ? nil : batch.id
      ICVSB.log.info("Sending URI #{uri} to #{@service.name} - batch_id: #{batch_id}")

      begin
        request_start = DateTime.now
        exception = nil
        case @service
        when Service::GOOGLE
          response = _request_google_cloud_vision(uri)
        when Service::AMAZON
          response = _request_amazon_rekognition(uri)
        when Service::AZURE
          response = _request_azure_computer_vision(uri)
        end
      rescue StandardError => e
        ICVSB.log.warn("Exception caught in send_uri: #{e.class} - #{e.message} - #{e.backtrace.join(' ⏎ ')}")
        exception = e
      end
      request = Request.create(
        service_id: @service.id,
        created_at: request_start,
        uri: uri,
        batch_request_id: batch_id
      )
      Response.create(
        created_at: DateTime.now,
        body: response[:body],
        success: exception.nil? && response[:success],
        request_id: request.id
      )
    end

    # Sends a batch request with multiple images to client's respective service
    # endpoint. Does *not* validate a response against a key (see
    # ICVSB::BenchmarkedRequestClient).
    # Params:
    # @param [Array<String>] uris An array of URIs to an image to detect labels.
    # @return [BatchRequest] The batch request that was created.
    def send_uris(uris)
      batch_request = BatchRequest.create(created_at: DateTime.now)
      ICVSB.log.info("Initiated a batch request for #{uris.count} URIs")
      uris.each do |uri|
        send_uri(uri, batch: batch_request)
      end
      batch_request
    end

    private

    # Makes a request to Google Cloud Vision's +LABEL_DETECTION+ feature.
    # @see https://cloud.google.com/vision/docs/labels
    # @param [String] uri A URI to an image to detect labels. Google Cloud
    #   Vision supports JPEGs, PNGs, GIFs, BMPs, WEBPs, RAWs, ICOs, PDFs and
    #   TIFFs only.
    # @return [Hash] A hash containing the response +body+ and whether the
    #   request was +success+ful.
    def _request_google_cloud_vision(uri)
      begin
        image = _download_image(
          uri,
          %w[
            image/jpeg
            image/png
            image/gif
            image/webp
            image/x-dcraw
            image/vnd.microsoft.icon
            application/pdf
            image/tiff
          ]
        )
        exception = nil
        res = @service_client.label_detection(
          image: image.open,
          max_results: @config[:max_labels]
        ).to_h
      rescue Google::Gax::RetryError => e
        exception = e
        res = { error: "#{e.class} - #{e.message}" }
      end
      {
        body: res.to_json,
        success: exception.nil? && res.key?(:responses)
      }
    end

    # Makes a request to Amazon Rekogntiion's +DetectLabels+ endpoint.
    # @see https://docs.aws.amazon.com/rekognition/latest/dg/API_DetectLabels.html
    # @param [String] uri A URI to an image to detect labels. Amazon Rekognition
    #   only supports JPEGs and PNGs.
    # @returns (see #_request_google_cloud_vision)
    def _request_amazon_rekognition(uri)
      begin
        image = _download_image(uri, %w[image/jpeg image/png])
        exception = nil
        res = @service_client.detect_labels(
          image: {
            bytes: image.read
          },
          max_labels: @config[:max_labels],
          min_confidence: @config[:min_confidence]
        ).to_h
      rescue Aws::Rekognition::Errors => e
        exception = e
        res = { error: "#{e.class} - #{e.message}" }
      end
      {
        body: res.to_json,
        success: exception.nil? && res.key?(:labels)
      }
    end

    # Makes a request to Azure's +analyze+ endpoint with +visualFeatures+ of
    #   +Tags+.
    # @see https://docs.microsoft.com/en-us/rest/api/cognitiveservices/computervision/tagimage/tagimage
    # @param [String] uri A URI to an image to detect labels. Amazon Rekognition
    #   only supports JPEGs, PNGs, GIFs, and BMPs.
    # @return (see #_request_google_cloud_vision)
    def _request_azure_computer_vision(uri)
      image = _download_image(uri, %w[image/jpeg image/png image/gif image/bmp])

      http_req = Net::HTTP::Post::Multipart.new(
        @service_client,
        file: UploadIO.new(image.open, image.content_type, image.original_filename)
      )
      http_req['Ocp-Apim-Subscription-Key'] = ENV['AZURE_SUBSCRIPTION_KEY']

      http_res = Net::HTTP.start(@service_client.host, @service_client.port, use_ssl: true) do |h|
        h.request(http_req)
      end

      {
        body: http_res.body,
        success: JSON.parse(http_res.body).key?('tags')
      }
    end

    # Downloads the image at the specified URI.
    # @param [String] uri The URI to download.
    # @param [Array<String>] mimes Accepted mime types.
    # @return [File] if download was successful.
    def _download_image(uri, mimes)
      raise ArgumentError, 'URI must be a string.' unless uri.is_a?(String)
      raise ArgumentError, 'Mimes must be an array of strings.' unless mimes.is_a?(Array)
      raise ArgumentError, "Invalid URI specified: #{uri}." unless uri =~ URI::DEFAULT_PARSER.make_regexp

      ICVSB.log.info("Downloading image at URI: #{uri}")
      file = Down.download(uri)
      mime = file.content_type

      unless mimes.include?(mime)
        raise ArgumentError, "Content type of URI #{uri} not accepted. Recieved #{mime}. Valid are: #{mimes}."
      end

      file
    rescue Down::Error => e
      raise ArgumentError, "Could not access the URI #{uri} - #{e.class}"
    end
  end

  # The Benchmarked Request Client class is used to make requests to a service's
  # labelling endpoints, ensuring that the response from the endpoint has not
  # altered significantly as indicated by the expiration flags. It handles
  # creating respective +Request+ and +Response+ records to be commited to the
  # benchmarker database. Unlike the +RequestClient+, the
  # +BenchmarkedRequestClient+ ensures that, respective to a benchmark dataset,
  # evolution has not occured and thus is safe to use the endpoint without
  # re-evaluation. Requires a #BenchmarkKey to make any requests.
  class BenchmarkedRequestClient < RequestClient
    alias send_uri_no_key send_uri
    alias send_uris_no_key send_uris

    # Initialises a new instance of the benchmarked requester to label
    # endpoints.
    # @param [Service] service (see RequestClient#initialize)
    # @param [Fixnum] max_labels (see RequestClient#initialize)
    # @param [Float] min_confidence (see RequestClient#initialize)
    # @param [Hash] opts Additional benchmark-related parameters.
    # @option opts [String] :reevaluate_on A cron-tab string (see
    #   +man 5 crontab+) that is used for the benchmarker to re-evaluate if the
    #   current key should be expired. Default is every Sunday at middnight,
    #   i.e., +0 0 * * 0+.
    # @option opts [Fixnum] :delta_labels Number of labels that change for a
    #   #BenchmarkKey to expire. Default is 5.
    # @option opts [Float] :delta_confidences Minimum amount of difference for
    #   the same label to have changed between the last benchmark for the
    #   #BenchmarkKey to expire. Default is 0.01.
    # @option opts [BenchmarkSeverity] :severity The severity of warning for
    #   the #BenchmarkKey to fail. Default is +BenchmarkSeverity::INFO+.
    def initialize(service, benchmark_dataset, max_labels: 100, min_confidence: 0.50, opts: {})
      super(service, max_labels: max_labels, min_confidence: min_confidence)
      @scheduler = Rufus::Scheduler.new
      @key_config = {
        reevaluate_on: opts[:reevaluate_on]       || '0 0 * * 0',
        delta_labels: opts[:delta_labels]         || 5,
        delta_confidence: opts[:delta_confidence] || 0.01,
        severity: opts[:severity]                 || BenchmarkSeverity::INFO
      }
      @current_key = _benchmark_dataset(benchmark_dataset)
      @scheduler.cron(@key_config[:reevaluate_on]) do |cronjob|
        ICVSB.log.info("Cronjob starting for BenchmarkedRequestClient #{self} - "\
          "Scheduled at: #{cronjob.scheduled_at} - Last ran at: #{cronjob.last_time}")
        new_key = _benchmark_dataset(benchmark_dataset)
        if @current_key.valid_against?(new_key)
          @current_key.expire
          @current_key = new_key
        end
      end
    end

    def send_uri_with_key(uri, key)
      raise ArgumentError, 'URI must be a string.' unless uri.is_a?(String)
      raise ArgumentError, 'Key must be a BenchmarkKey type.' unless key.is_a?(BenchmarkKey)

      valid_key = @current_key.valid_against?(key)
      # Handle invalid key according to severity level...
      # send the request accodingly...
    end

    private

    def _benchmark_dataset(uris)
      br = send_uris_no_key(uris)
      BenchmarkKey.create(
        service_id: @service.id,
        benchmark_severity_id: @key_config[:severity],
        batch_request_id: br.id,
        created_at: DateTime.now,
        expired: false,
        delta_labels: @key_config[:delta_labels],
        delta_confidence: @key_config[:delta_confidence],
        max_labels: @config[:max_labels],
        min_confidence: @config[:min_confidence]
      )
    end
  end
end

# reqclient = ICVSB::RequestClient.new(ICVSB::Service::AMAZON)
uris = %w[
  https://picsum.photos/id/1/800/600
  https://picsum.photos/id/2/800/600
]

benchmark = ICVSB::BenchmarkedRequestClient.new(ICVSB::Service::AMAZON, uris)


#benchmark.send_uri('https://picsum.photos/id/1/800/600', 'Bepis')

# r = ICVSB::RequestClient.new(ICVSB::Service::AMAZON)
# br, ex = r.send_uris(%w[
#   https://picsum.photos/id/1/800/600
#   https://picsum.photos/id/2/800/600
# ])
# puts br.success?
