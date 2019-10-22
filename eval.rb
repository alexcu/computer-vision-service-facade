# frozen_string_literal: true

###
#require './eval'
#e = Evaluator.new(max_results: 999999, min_confidence: 0)
#i = 'https://github.com/alexcu/cv-api-eval-datasets/raw/master/small/cat_1.JPG'
###

require 'dotenv/load'
require 'google/cloud/vision'
require 'aws-sdk-rekognition'
require 'down'
require 'net/http'
require 'json'

class Evaluator
  def initialize(config)
    @config = config
    @gcv_client = Google::Cloud::Vision::ImageAnnotator.new
    @rek_client = Aws::Rekognition::Client.new
    @acv_uri = URI('https://australiaeast.api.cognitive.microsoft.com/' \
                   'vision/v2.0/analyze')
    @acv_uri.query = URI.encode_www_form(visualFeatures: 'Tags')
  end

  def gcv(uri)
    @gcv_client.label_detection(
      image: Down.download(uri).open,
      max_results: @config[:max_labels]
    ).responses.first.label_annotations.map do |label|
      [label.description.downcase, label.score]
    end
  end

  def rek(uri)
    @rek_client.detect_labels(
      image: {
        bytes: Down.download(uri).read
      },
      max_labels: @config[:max_labels],
      min_confidence: @config[:min_confidence]
    ).labels.map do |label|
      [label.name.downcase, label.confidence * 0.01]
    end
  end

  def acv(uri)
    http_req = Net::HTTP::Post.new(@acv_uri)
    http_req['Ocp-Apim-Subscription-Key'] = ENV['AZURE_SUBSCRIPTION_KEY']
    http_req['Content-Type'] = 'application/json'
    http_req.body = { url: uri }.to_json

    http_res = Net::HTTP.start(@acv_uri.host,
                               @acv_uri.port, use_ssl: true) do |http|
      http.request(http_req)
    end

    raise http_res.body unless http_res.code == '200'

    http_res.body.to_json['tags'].map do |label|
      [label['name'].downcase, label['confidence']]
    end
  end
end
