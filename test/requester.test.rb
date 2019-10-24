require 'CSV'

module Test
  @client = Requester.new(max_labels: 999, min_confidence: 0)

  def self.read_test_imgs_uris
    CSV.read('test/test_imgs.csv').drop(1).map(&:last)
  end

  def self.select_svc
    Test.prompt.select('Service:', @client.methods - Object.methods)
  end

  def self.test_eval_single_upload
    ap @client.send(select_svc, read_test_imgs_uris[0]), limit: 10
  end

  def self.test_eval_custom_uri
    uri = @prompt.ask('Image URI:')
    ap @client.send(select_svc, uri), limit: 10
  end
end
