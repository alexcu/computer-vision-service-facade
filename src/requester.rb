# frozen_string_literal: true

# Author::    Alex Cummaudo  (mailto:ca@deakin.edu.au)
# Copyright:: Copyright (c) 2019 Alex Cummaudo
# License::   MIT License

require 'dotenv/load'
require 'google/cloud/vision'
require 'aws-sdk-rekognition'
require 'net/http/post/multipart'
require 'down'
require 'uri'
require 'json'

# The requester class handles requests to the computer vision label endpoints
# and returns the results in a consistent format: [[label, confidence], ...].
# Use the requester to make raw requests to each endpoint; it will not handle
# the benchmarking lifecycle for you.
# @example
#   r = Requester.new.request_google_cloud_vision('http://example.com/dog.jpg')
#   puts r[0][0] == 'dog'
#   puts r[0][1] >= 0.90
#   puts r[1][0] == 'animal'
#   puts r[1][1] >= 0.50
class Requester
  # Initialises a new instance of the requester to label endpoints.
  # Params:
  # @param [Fixnum] max_labels The maximum labels that the requester returns.
  #   Default is 100 labels.
  # @param [Float]  min_confidence The confidence threshold by which labels
  #   are returned. Default is 0.50.
  def initialize(max_labels: 100, min_confidence: 0.50)
    @config = {
      max_labels: max_labels,
      min_confidence: min_confidence
    }
    @gcv_client = Google::Cloud::Vision::ImageAnnotator.new
    @rek_client = Aws::Rekognition::Client.new
  end

  # Makes a request to Google Cloud Vision's +LABEL_DETECTION+ feature.
  # @see https://cloud.google.com/vision/docs/labels
  # @param [String] uri A URI to an image to detect labels. Google Cloud Vision
  #   supports JPEGs, PNGs, GIFs, BMPs, WEBPs, RAWs, ICOs, PDFs and TIFFs only.
  # @returns [Array] a two dimensional array containing +[res1, res2... resN]+
  #   where +resN+ contains +[label, confidence]+. No results leads to an empty
  #   array being returned.
  def request_google_cloud_vision(uri)
    image = _download_image(uri)
    supported_mimes = %w[
      image/jpeg
      image/png
      image/gif
      image/webp
      image/x-dcraw
      image/vnd.microsoft.icon
      application/pdf
      image/tiff
    ]

    unless supported_mimes.include?(image.content_type)
      raise ArgumentError, "Invalid image format #{image.content_type}. Rekognition supports #{supported_mimes} only."
    end

    res = @gcv_client.label_detection(
      image: image.open,
      max_results: @config[:max_labels]
    )

    # TODO: Handle res on error; raise RequesterError? Catch this in Benchmarker thread
    # ditto for others...

    if res.empty?
      []
    else
      res.responses.first.label_annotations.map do |label|
        [label.description.downcase, label.score]
      end
    end
  end

  # Makes a request to Amazon Rekogntiion's +DetectLabels+ endpoint.
  # @see https://docs.aws.amazon.com/rekognition/latest/dg/API_DetectLabels.html
  # @param [String] uri A URI to an image to detect labels. Amazon Rekognition
  #   only supports JPEGs and PNGs.
  # @returns (see #request_google_cloud_vision)
  def request_amazon_rekognition(uri)
    image = _download_image(uri)
    supported_mimes = %w[image/jpeg image/png]

    unless supported_mimes.include?(image.content_type)
      raise ArgumentError, "Invalid image format #{image.content_type}. Rekognition supports #{supported_mimes} only."
    end

    res = @rek_client.detect_labels(
      image: {
        bytes: image.read
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

  # Makes a request to Azure's +analyze+ endpoint with +visualFeatures+ of
  #   +Tags+.
  # @see https://docs.microsoft.com/en-us/rest/api/cognitiveservices/computervision/tagimage/tagimage
  # @param [String] uri A URI to an image to detect labels. Amazon Rekognition
  #   only supports JPEGs, PNGs, GIFs, and BMPs.
  # @returns (see #request_google_cloud_vision)
  def request_azure_computer_vision(uri)
    image = _download_image(uri)
    supported_mimes = %w[image/jpeg image/png image/gif image/bmp]

    unless supported_mimes.include?(image.content_type)
      raise ArgumentError, "Invalid image format #{image.content_type}. Azure supports #{supported_mimes} only."
    end

    acvuri = URI('https://australiaeast.api.cognitive.microsoft.com/vision/v2.0/analyze')
    acvuri.query = URI.encode_www_form(visualFeatures: 'Tags')

    http_req = Net::HTTP::Post::Multipart.new(
      acvuri,
      file: UploadIO.new(image.open, image.content_type, image.original_filename)
    )
    http_req['Ocp-Apim-Subscription-Key'] = ENV['AZURE_SUBSCRIPTION_KEY']

    http_res = Net::HTTP.start(acvuri.host, acvuri.port, use_ssl: true) do |h|
      h.request(http_req)
    end

    JSON.parse(http_res.body)['tags'].map do |label|
      [label['name'].downcase, label['confidence']]
    end.first(@config[:max_labels])
  end

  private

  # Downloads the image at the specified URI.
  # @param [String] uri The URI to download.
  # @return [File] if download was successful.
  def _download_image(uri)
    raise ArgumentError, "Invalid URI specified: #{uri}" unless uri =~ URI::DEFAULT_PARSER.make_regexp

    file = Down.download(uri)

    raise ArgumentError, "Content type of URI #{uri} is not image/*" unless file.content_type.start_with?('image/')

    file
  rescue Down::Error => e
    raise ArgumentError, "Could not access the URI #{uri} - #{e.class}"
  end
end
