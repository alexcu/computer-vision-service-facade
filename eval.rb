require 'dotenv/load'
require 'google/cloud/vision'
require 'aws-sdk-rekognition'
require 'down'
require 'net/http/post/multipart'
require 'json'

class Evaluator
  def initialize(config)
    @config = config
    @gcv_client = Google::Cloud::Vision::ImageAnnotator.new
    @rek_client = Aws::Rekognition::Client.new
  end

  def request_google_cloud_vision(uri)
    res = @gcv_client.label_detection(
      image: Down.download(uri).open,
      max_results: @config[:max_labels]
    )
    if res.empty?
      []
    else
      res.responses.first.label_annotations.map do |label|
        [label.description.downcase, label.score]
      end
    end
  end

  def request_amazon_rekognition(uri)
    res = @rek_client.detect_labels(
      image: {
        bytes: Down.download(uri).read
      },
      max_labels: @config[:max_labels],
      min_confidence: @config[:min_confidence]
    )
    if res.empty?
      []
    else
      res.labels.map do |label|
        [label.name.downcase, label.confidence * 0.01]
      end
    end
  end

  def request_azure_computer_vision(uri)
    acvuri = URI('https://australiaeast.api.cognitive.microsoft.com/' \
                  'vision/v2.0/analyze')
    acvuri.query = URI.encode_www_form(visualFeatures: 'Tags')

    file = Down.download(uri)
    http_req = Net::HTTP::Post::Multipart.new(
      acvuri,
      file: UploadIO.new(file.open, file.content_type, file.original_filename)
    )
    http_req['Ocp-Apim-Subscription-Key'] = ENV['AZURE_SUBSCRIPTION_KEY']

    http_res = Net::HTTP.start(acvuri.host, acvuri.port, use_ssl: true) do |h|
      h.request(http_req)
    end

    JSON.parse(http_res.body)['tags'].map do |label|
      [label['name'].downcase, label['confidence']]
    end
  end
end
