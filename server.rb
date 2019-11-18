# frozen_string_literal: true

require 'sinatra'
require 'time'
require 'json'
require 'require_all'
require_all 'lib'

set :root, File.dirname(__FILE__)
set :public_folder, File.join(File.dirname(__FILE__), 'static')
set :show_exceptions, false

store = {}
lgger = Logger::Formatter.new

before do
  logger.formatter = proc { |severity, datetime, progname, msg|
    lgger.call(severity, datetime, progname, msg.dump)
  }
  if request.body.size.positive?
    request.body.rewind
    @params = JSON.parse(request.body.read, symbolize_names: true)
  end
end

def check_brc_id(id, store)
  halt 400, 'Benchmark id must be a positive integer' unless id.integer? && id.to_i.positive?
  halt 400, "No such benchmark request client exists with id=#{id}" unless store.key?(id)
end

get '/' do
  File.read(File.expand_path('index.html', settings.public_folder))
end

# Creates a new benchmark request client with given parameters
post '/benchmark' do
  # Extract params
  service = params[:service] || ''
  benchmark_dataset = params[:benchmark_dataset] || ''
  max_labels = params[:max_labels] || ''
  min_confidence = params[:min_confidence] || ''
  trigger_on_schedule = params[:trigger_on_schedule] || ''
  trigger_on_failcount = params[:trigger_on_failcount] || ''
  benchmark_callback_uri = params[:benchmark_callback_uri] || ''
  warning_callback_uri = params[:warning_callback_uri] || ''
  expected_labels = params[:expected_labels] || ''
  delta_labels = params[:delta_labels] || ''
  delta_confidence = params[:delta_confidence] || ''
  severity = params[:severity] || ''

  # Check param types
  unless max_labels.integer? && max_labels.to_i.positive?
    halt 400, 'max_labels must be a positive integer'
  end
  unless min_confidence.float? && min_confidence.to_f.positive?
    halt 400, 'min_confidence must be a positive float'
  end
  unless delta_labels.integer? && delta_labels.to_i.positive?
    halt 400, 'delta_labels must be a positive integer'
  end
  unless delta_confidence.float? && delta_confidence.to_f.positive?
    halt 400, 'delta_confidence must be a positive float'
  end
  unless ICVSB::VALID_SERVICES.include?(service.to_sym)
    halt 400, "service must be one of #{ICVSB::VALID_SERVICES.join(', ')}"
  end
  unless trigger_on_schedule.cronline?
    halt 400, 'trigger_on_schedule must be a cron string in * * * * * (see man 5 crontab)'
  end
  unless trigger_on_failcount.integer? && trigger_on_schedule.to_i >= -1
    halt 400, 'trigger_on_failcount must be zero or positive integer'
  end
  if !benchmark_callback_uri.empty? && !benchmark_callback_uri.uri?
    halt 400, 'benchmark_callback_uri is not a valid URI'
  end

  unless ICVSB::VALID_SEVERITIES.include?(severity.to_sym)
    halt 400, "severity must be one of #{ICVSB::VALID_SEVERITIES.join(', ')}"
  end
  if ICVSB::BenchmarkSeverity[name: severity.to_s] == ICVSB::BenchmarkSeverity::WARNING && !warning_callback_uri.uri?
    halt 400, 'Must provide a valid warning_callback_uri when severity is WARNING'
  end

  halt 400, 'benchmark_dataset has not been specified' if benchmark_dataset.empty?
  benchmark_dataset = benchmark_dataset.lines.map(&:strip)
  expected_labels = expected_labels.empty? ? [] : expected_labels.split(',').map(&:strip)
  benchmark_dataset.each do |uri|
    unless uri.uri?
      halt 400, "benchmark_dataset must be a list of uris separated by a newline character; #{uri} is not a valid URI"
    end
  end

  # Convert params
  brc = ICVSB::BenchmarkedRequestClient.new(
    ICVSB::Service[name: service.to_s],
    benchmark_dataset,
    max_labels: max_labels.to_i,
    min_confidence: min_confidence.to_f,
    opts: {
      trigger_on_schedule: trigger_on_schedule,
      trigger_on_failcount: trigger_on_failcount.to_i,
      benchmark_callback_uri: benchmark_callback_uri,
      warning_callback_uri: warning_callback_uri,
      expected_labels: expected_labels,
      delta_labels: delta_labels.to_i,
      delta_confidence: delta_confidence.to_f,
      severity: ICVSB::BenchmarkSeverity[name: severity.to_s],
      autobenchmark: false
    }
  )
  # Benchmark on new thread
  Thread.new do
    brc.trigger_benchmark
    store[brc.object_id] = brc
  end

  store[brc.object_id] = brc

  status 201
  content_type 'application/json;charset=utf-8'
  { id: brc.object_id }.to_json
end

# Gets all auxillary information about the benchmark
get '/benchmark/:id' do
  id = params[:id].to_i
  check_brc_id(id, store)
  brc = store[id]

  content_type 'application/json;charset=utf-8'
  {
    id: id,
    service: brc.service.name,
    created_at: brc.created_at,
    current_key_id: brc.current_key ? brc.current_key.id : nil,
    is_benchmarking: brc.benchmarking?,
    # last_scheduled_benchmark_time: brc.last_scheduled_benchmark_time,
    # next_scheduled_benchmark_time: brc.next_scheduled_benchmark_time,
    invalid_state_count: brc.invalid_state_count,
    last_benchmark_time: brc.last_benchmark_time,
    benchmark_count: brc.benchmark_count,
    config: {
      max_labels: brc.max_labels,
      min_confidence: brc.min_confidence,
      key: brc.key_config,
      benchmarking: brc.benchmark_config
    },
    benchmark_dataset: brc.dataset
  }.to_json
end

# Gets all auxillary information about this key's benchmark
get '/benchmark/:id/key' do
  id = params[:id].to_i
  check_brc_id(id, store)
  brc = store[id]

  halt 422, 'The requested benchmark client is still benchmarking its first key' if brc.current_key.nil?

  current_key_id = brc.current_key.id
  redirect "/key/#{current_key_id}"
end

get '/key/:id' do
  id = params[:id].to_i
  bk = BenchmarkKey[id: params[:id]]

  halt 400, 'id must be an integer' unless id.integer?
  halt 400, "No such benchmark key request client exists with id=#{id}" if bk.nil?

  content_type 'application/json;charset=utf-8'
  {
    id: bk.id,
    service: bk.service.name,
    created_at: bk.created_at,
    benchmark_dataset: bk.batch_request.uris,
    success: bk.success?,
    expired: bk.expired?,
    severity: bk.severity.name,
    responses: bk.batch_request.responses.map(&:hash),
    config: {
      expected_labels: bk.expected_labels_set.to_a,
      delta_labels: bk.delta_labels,
      delta_confidence: bk.delta_confidence,
      max_labels: bk.max_labels,
      min_confidence: bk.min_confidence
    }
  }.to_json
end

# Gets the log of the benchmark with the given id
get '/benchmark/:id/log' do
  id = params[:id].to_i

  check_brc_id(id, store)

  content_type 'text/plain'
  store[id].read_log
end

# Labels resources against the provided uri. This is a conditional HTTP request.
# Must provide "If-Match" request header field with at least one ETag. Note that
# the ETag must ALWAYS been provided in the following format:
#
#   W/"<benchmark-id>[;<behaviour-token>]"
#
# Note that the ETag is a weak ETag; ``weak ETag values of two representations
# of the same resources might be semantically equivalent, but not byte-for-byte
# identical.'' (https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/ETag).
# That is, as the developer is not directly accessing the service, they are
# only getting a semantically equivalent representation of the labels, but not
# a byte-for-byte equivalent (the model may have changed slightly, given the
# latest benchmark used.)
#
# The first id, the benchmark-id, is mandatory as the request must know what
# benchmark dataset (and service) the requested URI is being made against.
#
# The following behaviour-token is optional, indicating the tolerances to which
# the response will be made, and the behaviour by which the response will change
# given if evolution has occured since the last benchmark was made. (Not that
# internally to this project, we refer to the behaviour token as a BenchmarkKey
# -- see ICVSB::BenchmarkKey.)
#
# One may provide multiple ETags (separated by commas) in the format:
#
#  W/"<benchmark-id1>[;<behaviour-token1>]",W/"<benchmark-id2>[;<behaviour-token2>]" ...
#
# Where this is the case, the label requested will attempt to match ANY of the
# tags provided. If failure occurs for the first, it will default to the next
# ETag, and so on.
#
# If NO behaviour-token is specified, then then (additionally) one must provide
# an "If-Unmodified-Since" request header field, indicating that the resource
# (labels) must have been unmodified since the given date. This will attempt to
# automatically locate the nearest behaviour token that was generated after the
# given date and request the labels against that date.
#
# The endpoint will return one of the following HTTP responses:
#
#   - 200 OK if this is the first request made to this URI;
#   - 304 if the repsonse provided is cached (i.e., no changes to the service
#     the last time it was benchmarked against the current key to not be
#     considered a violation);
#   - 400 Bad Request if invalid parameters were provided by the client;
#   - 412 Precondition Failed if the key/unmodified time provided is no longer
#     valid, and thus the key provided (or time provided) is violating the
#     valid tolerances embedded within the key (responding further details
#     reasoning what tolerances were violated as metadata in the response body);
#   - 422 Unprocessable Entity if a service error has occured, indicating the
#     service cannot process the entity or a bad request was made.
#   - 500 Internal Server Error if a facade error has occured.
#
get '/labels?uri={uri}' do
  image_uri = params[:uri]

  if_match = request.env['If-Match']
  if_unmodified_since = request.env['If-Unmodified-Since']

  halt 400, 'URI provided to analyse is not a valid URI' unless image_uri.uri?
  halt 400, 'Missing If-Match in request header' if if_match.nil?
  unless if_unmodified_since.nil? || if_unmodified_since.httpdate?
    halt 400, 'If Unmodified Since must be compliant with the RFC 2616 HTTP date format'
  end

  if_unmodified_since_date = Time.httpdate(if_unmodified_since)

  relay_body = {}
  relay_etag = nil

  # Scan through each comma-separated ETag
  etags = if_match.scan(%r{W\/"(\d+;?\d+)",?})
  etags.each do |etag|
    benchmark_id, benchmark_key_id = etag[0].split(';')

    # Check if we have a valid benchmark id
    check_brc_id(benchmark_id)
    brc = store[benchmark_id]
    bk = nil

    # Check if we have a key; if no key we must have a If-Unmodified-Since.
    if benchmark_key_id.nil? && if_unmodified_since.nil?
      halt 400, "You have provided a benchmark id (id=#{benchmark_key_id}) "\
                'without a behaviour token. Please provide a behaviour token '\
                'or include the If-Unmodified-Since request header with a RFC '\
                '2616-compliant HTTP date string.'
    elsif !benchmark_key_id.nil?
      # Check if valid key
      halt 400, "No such key with id #{key_id} exists!" if ICVSB::BenchmarkKey.where(id: key_id).empty?
      unless benchmark_key_id.integer? && benchmark_key_id.positive?
        halt 400, 'Behaviour token must be a positive integer.'
      end

      bk = BenchmarkKey[id: benchmark_key_id]
    elsif !if_unmodified_since.nil?
      bk = brc.find_key_since(if_unmodified_since_date)
      halt 400, "No behaviour token can be found that has been unmodified since #{if_unmodified_since_date}." if bk.nil?
    end

    # Process...
    result = brc.send_uri_with_key(image_uri, bk)

    # Set HTTP status+body as appropriate if there is no more ETags or if
    # this was a successful response (i.e., no errors so don't keep trying other
    # ETags...)
    error = result.key?(:key_error) || result.key?(:response_error) || result[:response].key?(:service_error)
    if etag == etags.last || !error
      if result[:key_error] || result[:response_error]
        status 412
        relay_body = !result[:key_error].nil? ? result[:key_error] : result[:response_error]
      elsif result[:response].key?(:service_error)
        status 422
        relay_body = result[:service_error]
      else
        status result[:cached] ? 304 : 200
        content_type 'application/json;charset=utf-8'
        relay_body = result[:response]
      end
      relay_etag = etag
    end
  end
  response.headers['ETag'] = relay_etag
  response.headers['Last-Modified'] = brc.current_key.created_at.httpdate
  relay_body.to_json
end

error do |e|
  halt 500, e.message
end
