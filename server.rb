require 'sinatra'
require 'open3'

set :root, File.dirname(__FILE__)
set :public_folder, File.join(File.dirname(__FILE__), 'static')

get '/' do
  File.read(File.expand_path('index.html', settings.public_folder))
end

post '/execute' do
  csv = params[:csv][:tempfile].path
  api = params[:api]
  cost = params[:cost]
  impact = params[:impact]
  # run respective api endpoint
  script = File.join(settings.root, 'eval', api, "#{api}.py")
  cmd = "python #{script} #{csv}"
  puts cmd
  Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
    exit_status = wait_thr.value
    unless exit_status.success?
      "FAILED !!! #{cmd} #{stderr.read}"
    end
    # do something with response data...
  end
end
