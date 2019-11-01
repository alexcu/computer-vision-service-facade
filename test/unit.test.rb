require 'CSV'

module Test
  DATASET_COMPUTERS = %w[
    https://picsum.photos/id/1/800/600
    https://picsum.photos/id/2/800/600
    https://picsum.photos/id/5/800/600
    https://picsum.photos/id/6/800/600
    https://picsum.photos/id/8/800/600
    https://picsum.photos/id/9/800/600
  ].freeze
  MAX_LABELS = 1000
  MIN_CONFIDENCE = 0.0

  def self.select_severity
    sym = Test.prompt.select('Severity:', ICVSB::BenchmarkSeverity.constants - ICVSB::BenchmarkSeverity.superclass.constants)
    ICVSB::BenchmarkSeverity.const_get(sym)
  end

  def self.select_svc
    sym = Test.prompt.select('Service:', ICVSB::Service.constants - ICVSB::Service.superclass.constants)
    ICVSB::Service.const_get(sym)
  end

  def self.request_client(service = select_svc)
    ICVSB::RequestClient.new(service, max_labels: MAX_LABELS, min_confidence: MIN_CONFIDENCE)
  end

  ### Unit tests

  def self.test_send_uri
    ap request_client.send_uri(DATASET_COMPUTERS[0])
  end

  def self.test_send_uris
    ap request_client.send_uris(DATASET_COMPUTERS)
  end

  def self.test_send_uri_custom
    ap request_client.send_uri(@prompt.ask('Image URI:'))
  end

  def self.test_key_validation
    service = select_svc
    severity = select_severity
    delta_labels = @prompt.ask('Number of labels to expire key?', default: 1, convert: :int)
    delta_confidence = @prompt.ask('Confidence delta for key to expire?', default: 0.001, convert: :float)

    uri =
      if service == ICVSB::Service::AZURE
        'https://media.githubusercontent.com/media/alexcu/icsme2019-datasets/master/cocoval2017/000000074200.jpg'
      else
        'https://media.githubusercontent.com/media/alexcu/icsme2019-datasets/master/large/0124.jpg'
      end
    file2018, file2019 = Dir["test/#{service.name.split('_').first}*"].sort.map { |f| File.read(f) }
    year2018 = DateTime.new(2018)

    batch_request2018 = ICVSB::BatchRequest.create(created_at: year2018)
    request2018 = ICVSB::Request.create(
      service_id: service.id,
      created_at: year2018,
      uri: uri,
      batch_request_id: batch_request2018.id
    )
    response2018 = ICVSB::Response.create(
      created_at: year2018,
      body: file2018,
      success: true,
      request_id: request2018.id
    )
    benchmark_key2018 = ICVSB::BenchmarkKey.create(
      service_id: service.id,
      benchmark_severity_id: severity.id,
      batch_request_id: batch_request2018.id,
      created_at: year2018,
      expired: false,
      delta_labels: delta_labels,
      delta_confidence: delta_confidence,
      max_labels: MAX_LABELS,
      min_confidence: MIN_CONFIDENCE
    )

    year2019 = DateTime.new(2019)
    batch_request2019 = ICVSB::BatchRequest.create(created_at: year2019)
    request2019 = ICVSB::Request.create(
      service_id: service.id,
      created_at: year2019,
      uri: uri,
      batch_request_id: batch_request2019.id
    )
    response2019 = ICVSB::Response.create(
      created_at: year2019,
      body: file2019,
      success: true,
      request_id: request2019.id
    )
    benchmark_key2019 = ICVSB::BenchmarkKey.create(
      service_id: service.id,
      benchmark_severity_id: severity.id,
      batch_request_id: batch_request2019.id,
      created_at: year2019,
      expired: false,
      delta_labels: delta_labels,
      delta_confidence: delta_confidence,
      max_labels: MAX_LABELS,
      min_confidence: MIN_CONFIDENCE
    )

    benchmark_key2019.valid_against?(benchmark_key2018)
  end
end
