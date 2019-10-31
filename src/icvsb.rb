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

# Intelligent Computer Vision Service Benchmarker (ICVSB)
module ICVSB
  VALID_SERVICES = %i[google_cloud_vision amazon_rekognition azure_computer_vision].freeze
  VALID_SEVERITIES = %i[exception warning info none].freeze

  #################################
  # Database schema creation seed #
  #################################
  url = ENV['ICVSB_DATABASE_CONNTECTION_URL'] || 'sqlite://icvsb.db'
  log = ENV['ICVSB_LOGGER_FILE'] || 'icvsb.db.log'
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
    column :success,   'boolean',   null: false

    index :request_id
  end
  dbc.create_table?(:benchmark_keys) do
    primary_key :id
    foreign_key :service_id,            :services,             null: false
    foreign_key :response_id,           :responses,            null: false
    foreign_key :benchmark_severity_id, :benchmark_severities, null: true
    foreign_key :batch_request_id,      :batch_request_id,     null: false

    column :created_at,       'timestamp',  null: false
    column :expired?,         'boolean',    null: false
    column :delta_labels,     'integer',    null: false
    column :delta_confidence, 'numeric',    null: false
    column :max_labels,       'integer',    null: false
    column :min_confidence,   'numeric',    null: false
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
  end

  class BatchRequest < Sequel::Model(dbc)
    one_to_many :requests

    def success?
      requests.map(&:success?).reduce(:&)
    end
  end

  class BenchmarkKey < Sequel::Model(dbc)
    many_to_one :service
    many_to_one :response
    many_to_one :benchmark_severity
    one_to_one  :batch_request

    def expired?
      expired
    end
  end

  # The Request Client class is used to make non-benchmarked requests to the
  # provided service's labelling endpoints. It handles creating respective
  # +Request+ and +Response+ records to be commited to the benchmarker database.
  # Requests made with the +RequestClient+ do *not* ensure that
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

    # Sends a request to the client's respective service endpoint.
    # Params:
    # @param [String] uri A URI to an image to detect labels.
    # @param [BatchRequest] batch The batch that the request is being made
    #   under. Defaults to nil.
    # @return [Response] The response record commited to the benchmarker
    #   database.
    def send_uri(uri, batch: nil)
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
        exception = e
      end

      batch_id = batch.nil? ? nil : batch.id
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

      raise exception unless exception.nil?
    end

    # Sends a batch request with multiple images to client's respective service
    # endpoint. Does *not* validate a response against a key.
    # Params:
    # @param [Array<String>] uris An array of URIs to an image to detect labels.
    # @return [Array<BatchRequest,StandardError>] The batch request made and
    #   the respective exceptions that were caught during the request.
    def send_uris(uris)
      batch_request = BatchRequest.create(created_at: DateTime.now)
      exceptions = []
      uris.each do |uri|
        begin
          send_uri(uri, batch: batch_request)
        rescue StandardError => e
          exceptions << e
        end
      end
      [batch_request, exceptions]
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
        puts e
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
      raise ArgumentError, "Invalid URI specified: #{uri}." unless uri =~ URI::DEFAULT_PARSER.make_regexp

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
end

r = ICVSB::RequestClient.new(ICVSB::Service::AMAZON)
br, ex = r.send_uris(%w[
  https://picsum.photos/id/1/800/600
  https://picsum.photos/id/2/800/600
])
puts br.success?
