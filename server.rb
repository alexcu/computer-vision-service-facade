# frozen_string_literal: true

require 'sinatra'
require 'open3'
require 'eval'

set :root, File.dirname(__FILE__)
set :public_folder, File.join(File.dirname(__FILE__), 'static')

get '/' do
  File.read(File.expand_path('index.html', settings.public_folder))
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
