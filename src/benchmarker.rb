# frozen_string_literal: true

# Author::    Alex Cummaudo  (mailto:ca@deakin.edu.au)
# Copyright:: Copyright (c) 2019 Alex Cummaudo
# License::   MIT License

require 'sequel'
require 'logger'

require './requester'

# The benchmarker handles evolution of labels and confidence values of images
# against a representative dataset to identify specific changes of a service.
# The benchmarker is used to make requests to a service using a key. This key
# may expire if the service re-evaluates the representative dataset and there
# are changes in the response (i.e., given the same dataset, if the service
# responds with a different result, then this is notified back in the response).
# @example
#   b = Benchmarker.new(service: :google_cloud_vision)
#   key = b.benchmark_dataset([
#     'http://example.com/dog1.jpg',
#     'http://example.com/dog2.jpg',
#     'http://example.com/dog3.jpg'
#   ])
#   r = b.request('http://example.com/dog4.jpg', key)
class Benchmarker
  # Benchmarker version number.
  VERSION = '0.1'

  # List of services the benchmarker supports.
  VALID_SERVICES = %i[google_cloud_vision amazon_rekognition azure_computer_vision]

  # Initialises a new instance of a benchmarker.
  # @param [Symbol] service The service by which to benchmark against. Must be
  #   one of +:google_cloud_vision+, +:amazon_rekognition+, or
  #   +:azure_computer_vision+.
  # @param [String] database Path to an sqlite3 database that maintains the
  #   benchmarker's dataset. Defaults to +./benchmark.db+.
  # @param [Fixnum] frequency The number of minutes before the benchmark dataset
  #   is re-evaluated against the service. Defaults to 10080 mins (1 week).
  # @param [Float] min_confidence_delta The minimum amount a confidence value
  #   must shift by for a benchmark to expire. Default is 0.001.
  # @param [Boolean] refuse_invalid_key When a key has expired, any further
  #   requests made are refused by the server (HTTP 410 Gone). Forces user to
  #   re-evaluate with a new benchmark dataset to identify changes. Default is
  #   +true+.
  def initialize(service:, database: './benchmark.db', **options)

    unless VALID_SERVICES.contains(service)
      raise ArgumentError, "Service '#{service} is not supported. Must be one of #{VALID_SERVICES}"
    end

    @dbc = Sequel.connect(database, Logger.new('log/benchmark.db.log'))
    _initialise_db unless @dbc.table_exists?('benchmark_metadata')

    @requester = Requester.new(
      max_labels: options[:max_labels],
      min_conficence: options[:min_confidence]
    )

    @config = {
      service: service,
      frequency: options[:frequency]                       || 10_080,
      min_labels_delta: options[:min_labels_delta]         || 1,
      min_confidence_delta: options[:min_confidence_delta] || 0.001,
      refuse_invalid_key: options[:refuse_invalid_key]     || true
    }
  end

  def latest_key
    benchmarks.order(:created_at).last.map(:key).first
  end

  def benchmark_dataset(uris)

  end

  def request_batch(uris, async: false, callback: -> { })
    start_time = DateTime.now
    batch_successful = true
    threads = []
    uris.each do |uri|
      thread << Thread.new do
        Thread.current.abort_on_exception = true
        request_successful = true
        begin
          @requester.send("request_#{@config[:service]}", uri)
        rescue RequesterError => e
          # TODO: THIS REQUEST failed... so log?
          request_successful = false
        ensure
          # insert into request DB that this request failed
          @dbc[:request].insert(
            service: @config[:service],
            start_time: start_time,
            end_time: DateTime.now,
            success: request_successful,
            batch_id: #???
          )
        end
      end
    end
    if async
      callback
    else
      threads.each(&:join)
    end
  rescue StandardError
    batch_successful = false
  ensure
    @dbc[:request_batches].insert(
      service: @config[:service],
      start_time: start_time,
      end_time: DateTime.now,
      success: batch_successful
    )
  end

  private

  def _benchmarks
    @dbc[:benchmarks].where(service: @config.service)
  end

  def _initialise_db
    @dbc.drop_table(:benchmark_metadata, :benchmarks, :requests)
    @dbc.create_table :benchmark_metadata do
      String :version_number
      DateTime :created_at
    end
    md = @dbc[:benchmark_metadata]
    md.insert(version_number: VERSION, created_at: DateTime.now)
    @dbc.create_table :benchmarks do
      primary_key :key
      String :service
      DateTime :created_at
    end
    # Each request ever made to this service and when
    @dbc.create_table :requests do
      primary_key :id
      String :service
      DateTime :start_time
      DateTime :end_time
      String :uri
      String :result_json
      String :batch_id
      boolean :success
    end
    @dbc.create_table :request_batches do
      primary_key :id
      String :service
      DateTime :start_time
      DateTime :end_time
      boolean :success
    end
  end
end
