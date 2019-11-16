# frozen_string_literal: true

# Author::    Alex Cummaudo  (mailto:ca@deakin.edu.au)
# Copyright:: Copyright (c) 2019 Alex Cummaudo
# License::   MIT License

require 'sequel'
require 'logger'
require 'stringio'
require 'binding_of_caller'
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
  # The valid services this version of the ICVSB module supports. At present the
  # only services supported are Google Cloud Vision, Amazon Rekognition, and
  # Azure Computer Vision and their respective labelling/tagging endpoints.
  # @see https://cloud.google.com/vision/docs/labels
  #   Google Cloud Vision labelling endpoint.
  # @see https://docs.aws.amazon.com/rekognition/latest/dg/API_DetectLabels.html
  #   Amazon Rekognition's labelling endpoint.
  # @see https://docs.microsoft.com/en-us/rest/api/cognitiveservices/computervision/tagimage/tagimage
  #   Azure Computer Visions's tagging endpoint.
  VALID_SERVICES = %i[google_cloud_vision amazon_rekognition azure_computer_vision].freeze

  # A list of the valid severities that the ICVSB module supports. Exception
  # prevents the response from being accessed; warning will still produce a
  # response but the +error+ field will be filled in; info will only log
  # errors to the ICVSB log file and keep +error+ empty and none ignores the
  # errors entirely.
  VALID_SEVERITIES = %i[exception warning info none].freeze

  # Logs a messaage to the global ICVSB logger. If called from within the
  # stack trace of a RequestClient, it will also add the message provided
  # the RequestClient's log associated with the RequestClient's object id.
  # @param [Logger::Severity] severity The type of severity to log.
  # @param [String] message The message to log.
  def self.lmessage(severity, message)
    unless [Logger::DEBUG, Logger::INFO, Logger::WARN, Logger::ERROR, Logger::FATAL, Logger::UNKNOWN].include?(severity)
      raise ArgumentError, 'Severity must be a Logger::Severity type'
    end
    raise ArgumentError, 'Message must be a string' unless message.is_a?(String)

    @log ||= Logger.new(ENV['ICVSB_LOGGER_FILE'] || STDOUT)

    # Add message to global ICVSB logger
    @log.add(severity, message)
    # Find object_id within request_clients... when found add this message w/
    # severity to that RC's log too
    binding.frame_count.times do |n|
      caller_obj_id = binding.of_caller(n).eval('object_id')
      if @request_clients.keys.include?(caller_obj_id)
        @request_clients[caller_obj_id].log(severity, "[RequestClient=#{caller_obj_id}] #{message}")
        break
      end
    end
  end

  # Logs an error to the global ICVSB logger.
  # @param [String] message The message to log.
  def self.lerror(message)
    lmessage(Logger::ERROR, message)
  end

  # Logs a warning to the global ICVSB logger.
  # @param [String] message The message to log.
  def self.lwarn(message)
    lmessage(Logger::WARN, message)
  end

  # Logs an info message to the global ICVSB logger.
  # @param [String] message The message to log.
  def self.linfo(message)
    lmessage(Logger::INFO, message)
  end

  # Logs a debug message to the global ICVSB logger.
  # @param [String] message The message to log.
  def self.ldebug(message)
    lmessage(Logger::DEBUG, message)
  end

  # Register's a request client to the ICVSB's register of request clients.
  # @param [RequestClient] request_client The request client to register.
  def self.register_request_client(request_client)
    raise ArgumentError, 'request_client must be a RequestClient' unless request_client.is_a?(RequestClient)

    @request_clients ||= {}
    @request_clients[request_client.object_id] = request_client
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
    column :name, String, null: false, unique: true
  end
  dbc.create_table?(:benchmark_severities) do
    primary_key :id
    column :name, String, null: false, unique: true
  end
  if dbc[:services].first.nil?
    VALID_SERVICES.each { |s| dbc[:services].insert(name: s.to_s) }
    VALID_SEVERITIES.each { |s| dbc[:benchmark_severities].insert(name: s.to_s) }
  end
  # Create Objects...
  dbc.create_table?(:batch_requests) do
    primary_key :id
    column :created_at, DateTime, null: false
  end
  dbc.create_table?(:requests) do
    primary_key :id
    foreign_key :service_id,        :services,       null: false
    foreign_key :batch_request_id,  :batch_requests, null: true
    foreign_key :benchmark_key_id,  :benchmark_keys, null: true

    column :created_at, DateTime, null: false
    column :uri,        String,   null: false

    index %i[service_id batch_request_id]
  end
  dbc.create_table?(:responses) do
    primary_key :id
    foreign_key :request_id, :requests, null: false

    column :created_at, DateTime,  null: false
    column :body,       File,      null: true
    column :success,    TrueClass, null: false

    index :request_id
  end
  dbc.create_table?(:benchmark_keys) do
    primary_key :id
    foreign_key :service_id,            :services,             null: false
    foreign_key :batch_request_id,      :batch_requests,       null: false
    foreign_key :benchmark_severity_id, :benchmark_severities, null: false

    column :created_at,       DateTime,  null: false
    column :expired,          TrueClass, null: false
    column :delta_labels,     Integer,   null: false
    column :delta_confidence, Float,     null: false
    column :max_labels,       Integer,   null: false
    column :min_confidence,   Float,     null: false

    index %i[service_id batch_request_id]
  end

  # Service representing the list of VALID_SERVICES the ICVSB module supports.
  class Service < Sequel::Model(dbc)
    # The Service representing Google Cloud Vision's labelling endpoint.
    # @see https://cloud.google.com/vision/docs/labels
    #   Google Cloud Vision labelling endpoint.
    GOOGLE = Service[name: VALID_SERVICES[0].to_s]

    # The Service representing Amazon Rekognition's labelling endpoint.
    # @see https://docs.aws.amazon.com/rekognition/latest/dg/API_DetectLabels.html
    #   Amazon Rekognition's labelling endpoint.
    AMAZON = Service[name: VALID_SERVICES[1].to_s]

    # The Service representing Azure Computer Vision's tagging endpoint.
    # @see https://docs.microsoft.com/en-us/rest/api/cognitiveservices/computervision/tagimage/tagimage
    #   Azure Computer Visions's tagging endpoint.
    AZURE  = Service[name: VALID_SERVICES[2].to_s]
  end

  # Severity representing the list of VALID_SEVERITIES the ICVSB module
  # supports. The severity is encoded within a BenchmarkKey.
  class BenchmarkSeverity < Sequel::Model(dbc[:benchmark_severities])
    # Exception severities will prevent responses from being accessed. This
    # disallows access to the Response object encoded within a
    # BenchmarkedRequestClient#send_uri_with_key or
    # BenchmarkedRequestClient#send_uris_with_key result.
    EXCEPTION = BenchmarkSeverity[name: VALID_SEVERITIES[0].to_s]

    # Warning severities will allow the Response from being accessed but will
    # additionally populate the +error+ value encoded within a
    # BenchmarkedRequestClient#send_uri_with_key or
    # BenchmarkedRequestClient#send_uris_with_key result.
    WARNING   = BenchmarkSeverity[name: VALID_SEVERITIES[1].to_s]

    # Info severities will allow the Response from being accessed encoded within
    # the result of a BenchmarkedRequestClient#send_uri_with_key or
    # BenchmarkedRequestClient#send_uris_with_key call, however, information
    # pertaining to issues with the request will be logged to the ICVSB log
    # file.
    INFO      = BenchmarkSeverity[name: VALID_SEVERITIES[2].to_s]

    # None severities will essentially ignore all benchmarking capabilities and
    # 'switches off' the benchmarking.
    NONE      = BenchmarkSeverity[name: VALID_SEVERITIES[3].to_s]
  end

  # This class represents a single request made to a Service. It encodes the
  # service, batch of requests (if applicable) and respective response.
  class Request < Sequel::Model(dbc)
    many_to_one :service
    many_to_one :batch
    one_to_one :response

    # @see Response#success.
    def success?
      response.success?
    end
  end

  # This class represents a single response returned back from a Service. It
  # encodes the reqeust that was made to invoke the response.
  class Response < Sequel::Model(dbc)
    many_to_one :request

    # Indicates if the response from the request was successful.
    # @return [Boolean] True if the response was successful or false if the
    #   response contained some issue.
    def success?
      success
    end

    # Returns a hash of the entire response object, decoded form its
    # Service-specific response Ruby type and into a simple hash object.
    # @return [Hash] A hash representing the entire Service response object
    #   within a Hash type.
    def hash
      return nil if body.nil?

      JSON.parse(body.lit.downcase.to_s, symbolize_names: true).to_h
    end

    # Returns hash of labels paired with their respective confidence values.
    # Decodes each Service's individual response syntax into a simple
    # key-value-pair that can be used for generalised use, regardless of which
    # Service actually generated the response.
    # @return [Hash] A hash with key-value-pairs representing the label (key)
    #   and value (confidence) of the response.
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

    # Decodes a Google Cloud Vision label endpoint response into a simple hash.
    # @return [Hash] A key-value-pair representing label => confidence.
    def _google_cloud_vision_labels
      hash[:responses][0][:label_annotations].map do |label|
        [label[:description].downcase, label[:score]]
      end.to_h
    end

    # Decodes an Amazon Rekognition label endpoint response into a simple hash.
    # @return [Hash] See #{#_google_cloud_vision_labels}.
    def _amazon_rekognition_labels
      hash[:labels].map do |label|
        [label[:name].downcase, label[:confidence] * 0.01]
      end.to_h
    end

    # Decodes an Azure Computer Vision tagging endpoint into a simple hash.
    # @return [Hash] See #{#_google_cloud_vision_labels}.
    def _azure_computer_vision_labels
      hash[:tags].map do |label|
        [label[:name].downcase, label[:confidence]]
      end.to_h
    end
  end

  # The batch request class collates multiple requests (URIs) invoked to a
  # single Service's endpoint in a single request. It encodes all requests
  # made to the service and can produce all responses back.
  class BatchRequest < Sequel::Model(dbc)
    one_to_many :requests

    # Indicates if every request in the batch of requests made were successful.
    # @return [Boolean] True if every response was successful, false
    #   otherwise.
    def success?
      requests.map(&:success?).reduce(:&)
    end

    # Maps all Response objects that were returned back from this batch to an
    # array.
    # @return [Array<Response>] An array of Response objects from every Request
    #  made in this batch.
    def responses
      requests.map(&:response)
    end

    # Maps all URIs that were requested back within this batch.
    # @return [Array<String>] An array of URI strings from every Request
    #  made in this batch.
    def uris
      requests.map(&:uri)
    end
  end

  # The Benchmark Key encodes all information pertaining to the evolution of a
  # specific service and is used to validate if a benchmark dataset has evolved
  # with time. This key must be used in conjunction with the
  # BenchmarkedRequestClient to ensure that responses made are still reasonable to
  # use or if the service should be re-benchmarked against a new dataset.
  class BenchmarkKey < Sequel::Model(dbc)
    many_to_one :service
    many_to_one :benchmark_severity
    many_to_one :batch_request

    # Class that encapsulates reasons why a benchmark key can be invalided.
    class InvalidKeyError
      module InvalidKeyErrorType
        NO_KEY_YET = 'No key yet exists. It is likely still benchmarking its results.'
        SERVICE_MISMATCH = 'Keys use different services'
        DATASET_MISTMATCH = 'Keys have different benchmark datasets'
        SUCCESS_MISMATCH = 'One or both keys do not have successful service responses'
        MIN_CONFIDENCE_MISMATCH = 'Keys have different min confidence values'
        MAX_LABELS_MISMATCH = 'Keys have different max label values'
        RESPONSE_LENGTH_MISMATCH = 'Keys have different number of responses'
        LABEL_DELTA_MISMATCH = 'Number of labels in one key exceeds the label delta threshold'
        CONFIDENCE_DELTA_MISMATCH = 'Confidence value for a label in one key exceeds the confidence delta threshold'
        EXPECTED_LABELS_MISMATCH = 'Expected labels missing from response'
      end

      include InvalidKeyErrorType
      attr_accessor :reason, :details

      def initialize(errortype, details = '')
        @errorname = InvalidKeyErrorType.constants.find { |c| InvalidKeyErrorType.const_get(c) == reason }
        @errorcode = InvalidKeyErrorType.constants.index(errortype)
        @details = details
      end

      def to_s
        "[#{@errorcode}::#{@errorname}] #{@reason}. #{@details}"
      end
    end

    # @see BatchRequest#success?
    def success?
      batch_request.success?
    end

    # An alias for the +expired+ field on the key, adding a question mark at the
    # end to make the field more 'Ruby-esque'.
    # @return [Boolean] True if the key has expired and thus should not be used
    #   for future requests as it is no longer valid.
    def expired?
      expired
    end

    # Expires this key by writing over its +expired+ field and marking it
    # false.
    # @return [void]
    def expire
      self.expired = false
      save
    end

    # Returns the comma-separated mandatory labels list as an set of values
    # @return [Set<String>] The set of mandatory labels required by this key.
    def expected_labels_set
      Set[*expected_labels.split(',').map(&:downcase)]
    end

    # Validates another key against this key to ensure if the two keys are
    # compatible or if evolution has occured iff BenchmarkKey is provided to
    # +key_or_response+. If a Response is provided instead, then validates that
    # the response is okay against this key's encoded parameters.
    # @param [BenchmarkKey,Response] key_or_response A key or response to
    #   validate against.
    # @return [Array<Boolean,BenchmarkKey::InvalidKeyError>] Returns +true+ if
    #   this key is valid against the other key OR a tuple with +false+ and
    #   BenchmarkKey::InvalidKeyError to explain why the key is invalid.
    def valid_against?(key_or_response)
      if key_or_response.is_a?(BenchmarkKey)
        _validate_against_key(key_or_response)
      elsif key_or_response.is_a?(Response)
        _validate_against_response(key_or_response)
      else
        raise ArgumentError, 'key_or_response must be a BenchmarkKey or Response type'
      end
    end

    private

    # Validates a key against this key as per rules encoded within this key.
    # @param [BenchmarkKey] key The key to validate.
    # @return See #valid_against?
    def _validate_against_key(key)
      ICVSB.linfo("Validating key id=#{id} with other key id=#{key.id}")

      # 1. Ensure same services!
      if key.service != service
        ICVSB.lwarn("Service mismatch in validation: #{key.service.name} != #{service.name}")
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::SERVICE_MISMATCH,
          "Source key (id=#{id}) service=#{service.name} but "\
          "validation key (id=#{key.id}) service=#{key.service.name}."
        )
      end
      ICVSB.linfo('Services both match')

      # 2. Ensure same benchmark dataset
      symm_diff_uris = Set[*batch_request.uris] ^ Set[*key.batch_request.uris]
      unless symm_diff_uris.empty?
        ICVSB.lwarn('Benchmark dataset mismatch in key validation: '\
          "Symm difference contains #{symm_diff_uris.count} different URIs")
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::DATASET_MISTMATCH,
          "Source key (id=#{id}) and valiation key (id=#{key.id}) have different benchmark dataset URIS."\
          "The symmetric difference is: #{symm_diff_uris.to_a}."
        )
      end
      ICVSB.linfo('Same benchmark dataset has been used')

      # 3. Ensure successful request made in BOTH instances
      our_key_success = success?
      their_key_success = key.success?
      unless our_key_success && their_key_success
        ICVSB.lwarn('Sucesss mismatch in key validation')
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::SUCCESS_MISMATCH,
          "Source key (id=#{id}) success=#{our_key_success} but "\
          "validation key (id=#{key.id}) success=#{their_key_success}."
        )
      end
      ICVSB.linfo('Both keys were successful')

      # 4. Ensure the same max labels
      unless key.max_labels == max_labels
        ICVSB.lwarn('Max labels mismatch in key validation')
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::MAX_LABELS_MISMATCH,
          "Source key (id=#{id}) max_labels=#{max_labels} but "\
          "validation key (id=#{key.id}) max_labels=#{key.service.name}."
        )
      end
      ICVSB.linfo('Both keys have same max labels')

      # 5. Ensure the same min confs
      unless key.min_confidence == min_confidence
        ICVSB.lwarn('Minimum confidence or max labels mismatch in key validation')
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::MIN_CONFIDENCE_MISMATCH,
          "Source key (id=#{id}) min_confience=#{min_confidence} but "\
          "validation key (id=#{key.id}) min_confidence=#{key.min_confidence}."
        )
      end
      ICVSB.linfo('Both keys have same min confidence')

      # 6. Ensure same number of results... (responses... not labels!)
      our_response_length = batch_request.responses.length
      their_response_length = key.batch_request.responses.length
      unless out_response_length == their_response_length
        ICVSB.lwarn('Number of responses mismatch in key validation')
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::RESPONSE_LENGTH_MISMATCH,
          "Source key (id=#{id}) responses#=#{our_response_length} but "\
          "validation key (id=#{key.id}) responses#=#{their_response_length}."
        )
      end
      ICVSB.linfo('Both keys have same number of encoded responses')

      # 7. Validate every label delta and confidence delta
      our_requests = batch_request.requests
      their_requests = key.batch_request.requests
      our_requests.each do |our_request|
        this_uri = our_request.uri
        their_request = their_requests.find { |r| r.uri == this_uri }

        our_labels = Set[*our_request.response.labels.keys]
        their_labels = Set[*their_request.response.labels.keys]

        # 7a. Label delta
        symm_diff_labels = our_labels ^ their_labels

        ICVSB.ldebug("Request id=#{our_request.id} {#{our_labels.to_a.join(', ')}} against "\
          "id=#{their_request.id} {#{their_labels.to_a.join(', ')}} - symm diff "\
          "= {#{symm_diff_labels.to_a.join(', ')}}")
        if symm_diff_labels.length > delta_labels
          ICVSB.lwarn("Number of labels mismatch in key validation (margin of error=#{delta_labels})")
          return false, BenchmarkKey::InvalidKeyError.new(
            BenchmarkKey::InvalidKeyError::LABEL_DELTA_MISMATCH,
            "Source key (id=#{id}) labels#=#{our_labels.length} but "\
            "validation key (id=#{key.id}) labels#=#{their_labels.length} "\
            "which exceeds the delta label value of #{delta_labels}."
          )
        end
        ICVSB.linfo("Number of labels match both keys (within margin of error #{delta_labels})")

        # 7b. Confidence delta
        delta_confs_exceeded = []
        our_request.response.labels.each do |label, conf|
          our_conf = conf
          their_conf = their_request.response.labels[label]

          if their_conf.nil?
            ICVSB.linfo("The label #{label} does not exist in the response id=#{their_request.response.id}. "\
              'Skipping confidence comparison...')
            next
          end

          delta = (our_conf - their_conf).abs
          ICVSB.ldebug("Request id=#{our_request.id} against id=#{their_request.id} "\
            "for label '#{label}' confidence: #{our_conf}, #{their_conf} (delta=#{delta})")
          if delta > delta_confidence
            ICVSB.lwarn("Maximum confidence delta breached in key validation (margin of error=#{delta_confidence})")
            delta_confs_exceeded << {
              label: label,
              source_key_conf: our_conf,
              validation_key_conf: their_conf,
              delta: delta
            }
          end
        end
        unless delta_confs_exceeded.empty?
          return false, BenchmarkKey::InvalidKeyError.new(
            BenchmarkKey::InvalidKeyError::CONFIDENCE_DELTA_MISMATCH,
            "Source key (id=#{id}) has exceeded confidence delta of "\
            "validation key (id=#{key.id}): #{delta_confs_exceeded}."
          )
        end
        ICVSB.linfo("Both keys have confidence within margin of error #{delta_confidence}")
      end

      # All checks pass...
      [true, nil]
    end

    # Validates a response against this key as per rules encoded within this key.
    # @param [Response] key The response to validate.
    # @return See #valid_against?
    def _validate_against_response(response)
      symm_diff_response_labels = Set[*response.labels.keys] ^ expected_labels_set
      unless symm_diff_response_labels.empty?
        return false, BenchmarkKey::InvalidKeyError.new(
          BenchmarkKey::InvalidKeyError::EXPECTED_LABELS_MISMATCH,
          "Expected key (id=#{id}) expects the following mandatory labels: '#{mandatory_labels}'."\
          "However, response (id=#{response.id}) has the following labels: '#{response.labels.keys.join(',')}."\
          "The following labels are missing: #{symm_diff_response_labels.to_a.join(',')}."
        )
      end

      # All checks pass...
      [true, nil]
    end
  end

  # The Request Client class is used to make non-benchmarked requests to the
  # provided service's labelling endpoints. It handles creating respective
  # +Request+ and +Response+ records to be commited to the benchmarker database.
  # Requests made with the +RequestClient+ do *not* ensure that evolution risk
  # has occured (see BenchmarkedRequestClient).
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

      # Registers logging for this client
      ICVSB.register_request_client(self)
      @logstrio = StringIO.new
      @log = Logger.new(@logstrio)

      @service = service
      @service_client =
        case @service
        when Service::GOOGLE
          Google::Cloud::Vision::ImageAnnotator.new
        when Service::AMAZON
          Aws::Rekognition::Client.new
        when Service::AZURE
          URI('https://australiaeast.api.cognitive.microsoft.com/vision/v2.0/tag')
        end
      @config = {
        max_labels: max_labels,
        min_confidence: min_confidence
      }
    end

    # Sends a request to the client's respective service endpoint. Does *not*
    # validate a response against a key (see BenchmarkedRequestClient).
    # Params:
    # @param [String] uri A URI to an image to detect labels.
    # @param [BatchRequest] batch The batch that the request is being made
    #   under. Defaults to nil.
    # @return [Response] The response record commited to the benchmarker
    #   database.
    def send_uri(uri, batch: nil)
      raise ArgumentError, 'URI must be a string.' unless uri.is_a?(String)
      raise ArgumentError, 'Batch must be a BatchRequest.' if !batch.nil? && !batch.is_a?(BatchRequest)

      batch_id = batch.nil? ? nil : batch.id
      ICVSB.linfo("Sending URI #{uri} to #{@service.name} - batch_id: #{batch_id}")

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
        ICVSB.linfo("Succesful response for URI #{uri} to #{@service.name} - batch_id: #{batch_id}")
      rescue StandardError => e
        ICVSB.lwarn("Exception caught in send_uri: #{e.class} - #{e.message}")
        exception = e
      end
      request = Request.create(
        service_id: @service.id,
        created_at: request_start,
        uri: uri,
        batch_request_id: batch_id
      )
      response = Response.create(
        created_at: DateTime.now,
        body: response[:body],
        success: exception.nil? && response[:success],
        request_id: request.id
      )
      ICVSB.linfo("Request saved (id=#{request.id}) with response (id=#{response.id})")
      response
    end

    # Sends a batch request with multiple images to client's respective service
    # endpoint. Does *not* validate a response against a key (see
    # ICVSB::BenchmarkedRequestClient).
    # @param [Array<String>] uris An array of URIs to an image to detect labels.
    # @return [BatchRequest] The batch request that was created.
    def send_uris(uris)
      raise ArgumentError, 'URIs must be an array of strings.' unless uris.is_a?(Array)

      batch_request = BatchRequest.create(created_at: DateTime.now)
      ICVSB.linfo("Initiated a batch request for #{uris.count} URIs")
      uris.each do |uri|
        send_uri(uri, batch: batch_request)
      end
      ICVSB.linfo("Batch is complete (id=#{batch_request.id})")
      batch_request
    end

    # Performs the same operation as send_uris but performs sends each URI
    # asynchronously. Saves a lot of time if you have lots of URIs. This method
    # should not be used with an SQLite database.
    # @see #send_uris
    # @param [Array<String>] uri See #send_uris
    # @return [Array<BatchRequest, Array<Thread>] Returns both the array and an
    #   array of threads representing each request. Call +threads.join(&:each)+
    #   to ensure all requests have finished.
    def send_uris_async(uris)
      raise ArgumentError, 'URIs must be an array of strings.' unless uris.is_a?(Array)
      if ICVSB::Request.superclass.db.url.start_with?('sqlite')
        raise StandardError, 'You are using SQLite and thus async operations are not supported.'
      end

      threads = []
      batch_request = BatchRequest.create(created_at: DateTime.now)
      ICVSB.linfo("Initiated an async batch request for #{uris.count} URIs")
      uris.each do |uri|
        threads << Thread.new do
          send_uri(uri, batch: batch_request)
        end
      end
      ICVSB.linfo("Async batch submitted (id=#{batch_request.id}). Wait for this batch to be complete!")
      [batch_request, threads]
    end

    # Adds a message of a specific severity to this client's logger.
    # @param [Logger::Severity] severity The type of severity to log.
    # @param [String] message The message to log.
    def log(severity, message)
      unless [Logger::DEBUG, Logger::INFO, Logger::WARN, Logger::ERROR, Logger::FATAL, Logger::UNKNOWN]
             .include?(severity)
        raise ArgumentError, 'Severity must be a Logger::Severity type'
      end
      raise ArgumentError, 'Message must be a string' unless message.is_a?(String)

      @log.add(severity, message)
    end

    # Gets the log of this client as a string.
    # @return [String] The entire log.
    def read_log
      @logstrio.string
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
      end
      {
        body: exception.nil? ? res.to_json : { service_error: "#{exception.class} - #{exception.message}" },
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

      tags_present = JSON.parse(http_res.body).key?('tags')
      {
        body: tags_present ? http_res.body : { service_error: http_res.body },
        success: tags_present
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

      ICVSB.linfo("Downloading image at URI: #{uri}")
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
  # re-evaluation. Requires a BenchmarkKey to make any requests.
  class BenchmarkedRequestClient < RequestClient
    alias send_uri_no_key send_uri
    alias send_uris_no_key send_uris
    alias send_uris_no_key_async send_uris_async

    # Initialises a new instance of the benchmarked requester to label
    # endpoints.
    # @param [Service] service (see RequestClient#initialize)
    # @param [Array<String>] dataset An array of URIs to benchmark
    #   against.
    # @param [Fixnum] max_labels (see RequestClient#initialize)
    # @param [Float] min_confidence (see RequestClient#initialize)
    # @param [Hash] opts Additional benchmark-related parameters.
    # @option opts [String] :trigger_on_schedule A cron-tab string (see
    #   +man 5 crontab+) that is used for the benchmarker to re-evaluate if the
    #   current key should be expired. Default is every Sunday at middnight,
    #   i.e., +0 0 * * 0+.
    # @option opts [String] :trigger_on_failcount Number of times the benchmark
    #   request fails making requests for the benchmark to re-evalauate. Must
    #   be a positive, non-zero number for the benchmark to trigger on failure,
    #   else this field is ignored. Default is 0.
    # @option opts [String] :benchmark_callback_uri The URI to call with results
    #   of a completed benchmark. Optional.
    # @option opts [BenchmarkSeverity] :severity The severity of warning for
    #   the #BenchmarkKey to fail. Default is +BenchmarkSeverity::INFO+.
    # @option opts [String] :warning_callback_uri Required when the +:severity:+
    #   is +BenchmarkSeverity::WARN+. If left blank, the effect of the benchmark
    #   client is essentially a severity of +BenchmarkSeverity::NONE+, as no
    #   warning endpoint can be called to notify of issues.
    # @option opts [Boolean] :autobenchmark Automatically benchmark the client
    #   as soon as it it initialised. If +false+, then you will need to call
    #   the #benchmark method immediately (i.e., on your own thread). Defaults
    #   to true, so will block the current thread before benchmarking is
    #   complete.
    # @option opts [Fixnum] :delta_labels Number of labels that change for a
    #   #BenchmarkKey to expire. Default is 5.
    # @option opts [Float] :delta_confidences Minimum amount of difference for
    #   the same label to have changed between the last benchmark for the
    #   #BenchmarkKey to expire. Default is 0.01.
    # @option opts [Array<String>] :expected_labels Array of strings for the
    #   various expected labels that should be expected in every result. Fails
    #   otherwise. Encoded within the key.
    def initialize(service, dataset, max_labels: 100, min_confidence: 0.50, opts: {})
      super(service, max_labels: max_labels, min_confidence: min_confidence)
      @scheduler = Rufus::Scheduler.new
      @dataset = dataset
      @super_config = @config
      @key_config = {
        delta_labels: opts[:delta_labels]                     || 5,
        delta_confidence: opts[:delta_confidence]             || 0.01,
        severity: opts[:severity]                             || BenchmarkSeverity::INFO,
        expected_labels: opts[:expected_labels]               || []
      }
      @benchmark_config = {
        trigger_on_schedule: opts[:trigger_on_schedule]       || '0 0 * * 0',
        trigger_on_failcount: opts[:trigger_on_failcount]     || 0,
        benchmark_callback_uri: opts[:benchmark_callback_uri] || nil,
        warning_callback_uri: opts[:warning_callback_uri]     || nil,
        autobenchmark: opts[:autobenchmark]                   || true
      }
      @is_benchmarking = false
      @failure_count = 0
      benchmark if @benchmark_config[:autobenchmark]
      @scheduler.cron(@benchmark_config[:trigger_on_schedule]) do |cronjob|
        ICVSB.linfo("Cronjob starting for BenchmarkedRequestClient #{self} - "\
          "Scheduled at: #{cronjob.scheduled_at} - Last ran at: #{cronjob.last_time}")
        benchmark
      end
    end

    # Exposes whether or not the client is currently benchmarking.
    # @return [Boolean] True if the client is benchmarking, false otherwise.
    def benchmarking?
      @is_benchmarking
    end

    # Sends an image to this client's respective labelling endpoint, verifying
    # the key provided has not expired (and thus substantial evolution in the
    # labelling endpoint has not occured for significant impact to the results).
    # Depending on the key's varied severity level, a response will be returned
    # with varied fields populated.
    # @param [URI] uri (see RequestClient#send_uri)
    # @param [BenchmarkKey] key The benchmark key required to make a request
    #   to the service using this client. This key is verified against this
    #   client's most recent benchmark, thereby ensuring no evolution has occured
    #   in the back-end service.
    # @return [Hash] A hash with the following keys: +:response+, the raw
    #   #Response object returned from the #RequestClient.send_uri method (i.e.,
    #   a non-benchmarked response) or +nil+ if the #key has expired or invalid
    #   and the key's severity level is #BenchmarkSeverity::EXCEPTION;
    #   +:labels:, a shortcut to the #Response.label method of the response or
    #   +nil+ if the key has expired or was invalid and the key's severity level
    #   is #BenchmarkSeverity::EXCEPTION; +:key_error+: an error response
    #   indicating if the key has expired (a string value) which is only
    #   populated if the key has a severity level of
    #   #BenchmarkSeverity::EXCEPTION or #BenchmarkSeverity::WARNING;
    #   +:response_error:+ similar to :key_error: but for the response.
    def send_uri_with_key(uri, key)
      raise ArgumentError, 'URI must be a string.' unless uri.is_a?(String)
      raise ArgumentError, 'Key must be a BenchmarkKey.' unless key.is_a?(BenchmarkKey)

      if @current_key.nil?
        return { key_error: BenchmarkKey::InvalidKeyError.new(BenchmarkKey::InvalidKeyError::NO_KEY_YET) }
      end

      result = {
        labels: nil,
        response: nil,
        key_error: nil,
        response_error: nil
      }

      # Check for key validity
      key_valid, key_invalid_reason = @current_key.valid_against?(key)
      unless key_valid
        result[:key_error] = key_invalid_reason.to_s
        @failure_count += 1
        ICVSB.linfo("Error has occured in key validation. Fail count is now #{@failure_count}.")
      end

      # If key is valid, raise request and check if response is valid
      if key_valid
        response = send_uri_no_key(uri)
        # Update the benchmark key id
        response.benchmark_key_id = @current_key.id
        response.save!
        # Now check to see if it was valid...
        response_valid, response_invalid_reason = @current_key.valid_against?(response)
        result[:labels] = response.labels
        result[:response] = response.hash
        unless response_valid
          result[:response_error] = response_invalid_reason.to_s
          @failure_count += 1
          ICVSB.linfo("Error has occured in response validation. Fail count is now #{@failure_count}.")
        end
      end

      # If benchmark trigger on num failures is set
      if @benchmark_config[:trigger_on_failcount].positive? &&
         @failure_count > @benchmark_config[:trigger_on_failcount]
        ICVSB.linfo("Benchmark has failed #{@benchmark_config[:trigger_on_failcount]} "\
          'times... retriggering benchmark...')
        @failure_count = 0
        _benchmark
      end

      # Response behaviour is dependent on the severity encoded within the key
      case @current_key.benchmark_severity
      when BenchmarkSeverity::EXCEPTION
        # Only expose errors...
        { key_error: result[:key_error], response_error: result[:response_error] }
      when BenchmarkSeverity::WARNING
        # Flag a warning to the warning endpoint about this result if sev is WARN
        _flag_warning(result)
        result
      when BenchmarkSeverity::INFO
        # Log to info...
        unless key_valid
          ICVSB.lwarn("Benchmarked request made for #{uri} with invalid key "\
            "(id=#{@current_key.id}) -- #{key_invalid_reason}")
        end
        unless response_valid
          ICVSB.lwarn("Benchmarked request made for #{uri} and response violated current key "\
            "(id=#{@current_key.id}) -- #{response_invalid_reason}")
        end
        result
      when BenchmarkSeverity::NONE
        # Passthrough...
        result
      end
    end

    # Makes a request to benchmark's the client's current key against the
    # client's URIs to benchmark against. Expires the existing current key
    # if a new benchmark key is no longer valid against the old benchmark
    # key.
    def benchmark
      @is_benchmarking = true
      new_key = _benchmark
      if @current_key.nil?
        @current_key = new_key
      else
        valid_key, reason = @current_key.valid_against?(new_key)
        if !valid_key
          ICVSB.lerror('BenchmarkedRequestClient no longer has a valid key!'\
            "Reason='#{reason}'"\
            "Expiring old key (id=#{@current_key.id}) with new key (id=#{new_key.id})")
          @current_key.expire
          @current_key = new_key
        end
      end
      @is_benchmarking = false
    end

    private

    # Forwards a full result to the benchmarked request client's warning endpoint
    # @param [Hash] result See #send_uri_with_key
    # @returns [void]
    def _flag_warning(result)
      # TODO: do it on its own thread
    end

    # Benchmarks this client against a set of URIs, returning this client's
    # configurated key configuration.
    # @return [BenchmarkKey] A key representing the result of this benchmark.
    def _benchmark
      ICVSB.linfo("Benchmarking dataset against dataset of #{@dataset.count} URIs.")
      br, thr = send_uris_no_key_async(@dataset)
      ICVSB.linfo("Benchmarking this dataset using batch request with id=#{br.id}.")
      # Wait for all threads to finish...
      thr.each(&:join)
      ICVSB.linfo("Batch request with id=#{br.id} is now complete!")
      bk = BenchmarkKey.create(
        service_id: @service.id,
        benchmark_severity_id: @key_config[:severity].id,
        batch_request_id: br.id,
        created_at: DateTime.now,
        expired: false,
        delta_labels: @key_config[:delta_labels],
        delta_confidence: @key_config[:delta_confidence],
        expected_labels: @key_config[:expected_labels].map(&:downcase).join(','),
        max_labels: @super_config[:max_labels],
        min_confidence: @super_config[:min_confidence]
      )
      ICVSB.linfo("Benchmarking dataset is complete. Key from benchmarking is #{bk.id}.")
      bk
    end
  end
end
