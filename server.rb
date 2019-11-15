# frozen_string_literal: true

require 'sinatra'
require 'pstore'
require 'require_all'
require_all 'lib'

set :root, File.dirname(__FILE__)
set :public_folder, File.join(File.dirname(__FILE__), 'static')
set :show_exceptions, false

store = {}#{PStore.new('icvsb.pstore')}


def check_brc_id(id, store)
  halt 422, 'id must be an integer' unless id.integer?
  # store.transaction do
  # puts "THE KEY IS", store.key?(id), store.keys, store.keys.map(&:class), store.keys, id.class
    halt 422, "No such benchmark request client exists with id=#{id}" unless store.key?(id)
  # end
end

get '/' do
  File.read(File.expand_path('index.html', settings.public_folder))
end

# Creates a new benchmark request client with given parameters
post '/benchmark' do
  # Extract params
  service = params[:service].to_sym
  benchmark_uris = params[:benchmark_uris].lines.map(&:strip)
  max_labels = params[:max_labels]
  min_confidence = params[:min_confidence]
  reevaluate_on = params[:reevaluate_on]
  delta_labels = params[:delta_labels]
  delta_confidence = params[:delta_confidence]
  severity = params[:severity].to_sym

  # Check param types
  halt 422, "service must be one of #{ICVSB::VALID_SERVICES.join(', ')}" unless ICVSB::VALID_SERVICES.include?(service)
  halt 422, 'max_labels must an integer' unless max_labels.integer?
  halt 422, 'min_confidence must be a float' unless min_confidence.float?
  halt 422, 'reevaluate_on must be a cron string in * * * * * (see man 5 crontab)' unless reevaluate_on.cronline?
  halt 422, 'delta_labels must be an integer' unless delta_labels.integer?
  halt 422, 'delta_confidence must be a float' unless delta_confidence.float?
  unless ICVSB::VALID_SEVERITIES.include?(severity)
    halt 422, "severity must be one of #{ICVSB::VALID_SEVERITIES.join(', ')}"
  end

  benchmark_uris.each do |uri|
    unless uri.uri?
      halt 422, "benchmark_uris must be a list of uris separated by a newline character; #{uri} is not a valid URI"
    end
  end

  # Convert params
  brc = ICVSB::BenchmarkedRequestClient.new(
    ICVSB::Service[name: service.to_s],
    benchmark_uris,
    max_labels: max_labels.to_i,
    min_confidence: min_confidence.to_f,
    opts: {
      reevaluate_on: reevaluate_on,
      delta_labels: delta_labels.to_i,
      delta_confidence: delta_confidence.to_f,
      severity: ICVSB::BenchmarkSeverity[name: severity.to_s],
      autobenchmark: false
    }
  )
  # Benchmark on new thread
  Thread.new do
    brc.benchmark
    # store.transaction do
      store[brc.object_id] = brc
      # store.commit
    # end
  end

  store[brc.object_id] = brc # store.transaction { store[brc.object_id] = brc && store.commit }

  content_type 'application/json'
  { id: brc.object_id, is_benchmarking: true }.to_json
end

get '/benchmark/:id/status' do
  id = params[:id].to_i

  check_brc_id(id, store)

  # status = nil
  # store.transaction do
    # status =
  # end

  content_type 'application/json'
  { id: id, is_benchmarking: store[id].benchmarking? }.to_json
end

# Gets the log of the benchmark with the given id
get '/benchmark/:id/log' do
  id = params[:id].to_i

  check_brc_id(id, store)

  # status = nil
  # store.transaction do
    # status = store[id].is_benchmarking?
  # end
  content_type 'text/plain'
  store[id].read_log
end

# Makes a request against the given benchmark
post '/request' do
  benchmark_id = params[:benchmark_id].to_i
  key_id = params[:key_id]
  image_uri = params[:image_uri]

  puts params

  halt 422, 'key_id is not an integer' unless key_id.integer?
  halt 422, "No such key with id #{key_id} exists!" if ICVSB::BenchmarkKey.where(id: key_id).empty?
  halt 422, 'image_uri is not a valid URI' unless image_uri.uri?
  check_brc_id(benchmark_id, store)

  brc = store[benchmark_id]
  key = ICVSB::BenchmarkKey[id: key_id]

  content_type 'application/json'
  brc.send_uri_with_key(image_uri, key).to_json
end

error do |e|
  content_type 'application/json'
  halt 500, { error: "Internal server error! #{e.message}." }.to_json
end

post '/results.json' do
  csv_fp = params[:csv][:tempfile]
  csv_head = 'img_name,img_uri,ground_truth_label'
  unless csv_fp.read.start_with?(csv_head)
    halt 400, "Ensure your input CSV has the following headers: #{csv_head}"
  end
  csv = csv_fp.path
  api = params[:api]
  cost = params[:cost]
  impact = params[:impact]
  # run respective api endpoint
  script = File.join(api, "#{api}.py")
  eval_root = File.join(settings.root, 'eval')
  cmd = "python #{script} #{csv}"
  Open3.popen3(cmd, chdir: eval_root) do |_stdin, stdout, stderr, wait_thr|
    exit_status = wait_thr.value
    if exit_status.success?
      resdata = "utc_timestamp,img_name,img_uri,label,confidence\n"
      resdata += stdout.read
      sbfunc(csv_fp.read, resdata, cost, impact).to_json
    else
      halt 500, "Internal error executing #{cmd}\n\n\n#{stderr.read}"
    end
  end
end

def sbfunc(input_csv, response_csv, cost, impact)
  puts 'TODO:  Call Scotts R script here...'
  puts 'TODO:  This would return a JSON value of all required data...'
  # MUST RETURN A HASH
  { request: input_csv, response: response_csv, cost: cost, impact: impact }
end
