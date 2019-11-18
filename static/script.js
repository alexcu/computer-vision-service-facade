document.addEventListener("DOMContentLoaded", function (event) {
  document.getElementById('benchmark-dataset').value = [
    'https://picsum.photos/id/1025/800/600.jpg',
    'https://images.dog.ceo/breeds/pug/n02110958_10842.jpg',
    'https://cdn.shopify.com/s/files/1/2193/4553/products/pug_1400x.jpg'
  ].join('\n');

  document.getElementById('new-benchmark-form').onsubmit = submitNewBenchmarkForm;
  document.getElementById('check-benchmark-form').onsubmit = submitCheckBenchmarkForm;
  document.getElementById('submit-request-form').onsubmit = submitRequestForm;
  document.getElementById('submit-request-image-uri').oninput = inputImageUri;
  document.getElementById('benchmark-callback-uri').value = window.location.origin + '/callbacks/benchmark';

  document.getElementById('severity').onchange = function (e) {
    var el = document.getElementById('warning-callback-uri')
    var iswarn = e.target.value == 'warning';
    el.value = iswarn ? window.location.origin + '/callbacks/warning' : '';
    el.required = iswarn;
    document.getElementById('warning-callback-uri-form-group').classList.toggle('required', iswarn);
  }
});

function escapeHtml(unsafe) {
  return unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function handleReadyState(e, data, resultDiv) {

}

function invalidId(id) {
  return isNaN(id) || id.trim().length == 0;
}

function xhr(method, to, resultDiv, data) {
  var xhr = new XMLHttpRequest();
  data = data == undefined ? '' : JSON.stringify(data);
  url = new URL(to, location)
  xhr.open(method, to, true);
  xhr.setRequestHeader('Content-Type', 'application/json;charset=utf-8');
  xhr.onreadystatechange = function () {
    if (xhr.readyState == xhr.DONE) {
      resultDiv.innerHTML +=
        (data.length > 0 ? '\r\n\r\n' : '') +
        '<<<<<<<<<\r\n' +
        'HTTP/1.1 ' + xhr.status + ' ' + xhr.statusText + '\r\n' +
        xhr.getAllResponseHeaders() + '\r\n' +
        escapeHtml(xhr.responseText);
    }
  };
  xhr.send(data);
  resultDiv.innerHTML =
    '>>>>>>>>>\r\n' + method + ' ' + to + ' HTTP/1.1\r\n' +
    'host: ' + url.host + '\r\n' +
    'user-agent: ' + navigator.userAgent + '\r\n' +
    'accept: */*\r\n' +
    'content-type: application/json;charset=utf-8\r\n' +
    'content-length: ' + data.length +
    (data.length > 0 ? '\r\n\r\n' + data : '\r\n');
  return xhr;
}

function submitNewBenchmarkForm() {
  var resultDiv = document.getElementById('new-benchmark-form-results');

  xhr('POST', '/benchmark', resultDiv, {
    'benchmark_dataset': document.getElementById('benchmark-dataset').value,
    'service': document.getElementById('service').value,
    'max_labels': document.getElementById('max-labels').value,
    'min_confidence': document.getElementById('min-confidence').value,
    'delta_labels': document.getElementById('delta-labels').value,
    'delta_confidence': document.getElementById('delta-confidence').value,
    'trigger_on_schedule': document.getElementById('trigger-on-schedule').value,
    'trigger_on_failcount': document.getElementById('trigger-on-failcount').value,
    'expected_labels': document.getElementById('expected-labels').value,
    'benchmark_callback_uri': document.getElementById('benchmark-callback-uri').value,
    'warning_callback_uri': document.getElementById('warning-callback-uri').value,
    'severity': document.getElementById('severity').value
  })

  return false;
}

function submitCheckBenchmarkForm() {
  var id = document.getElementById('check-benchmark-benchmark-id').value;

  if (invalidId(id)) { return false; }

  var statusResults = document.getElementById('check-benchmark-status-results');
  var logResults = document.getElementById('check-benchmark-log-results');

  xhr('GET', '/benchmark/' + id, statusResults);
  xhr('GET', '/benchmark/' + id + '/log', logResults);
  return false;
}

function inputImageUri() {
  var imageUri = document.getElementById('submit-request-image-uri').value;
  var imgEl = document.getElementById('submit-request-image-preview');

  imgEl.src = imageUri;
}

function submitRequestForm() {
  var benchmarkId = document.getElementById('submit-request-benchmark-id').value;
  var keyId = document.getElementById('submit-request-key-id').value;
  var imageUri = document.getElementById('submit-request-image-uri').value;

  if (invalidId(benchmarkId) || invalidId(keyId) || imageUri.trim().length == 0) { return false; }

  var results = document.getElementById('submit-request-results');

  var formData = new FormData();
  formData.append('benchmark_id', benchmarkId);
  formData.append('key_id', keyId);
  formData.append('image_uri', imageUri);

  var req = new XMLHttpRequest();
  req.onreadystatechange = function () { handleResults(this, results) };
  req.open('POST', '/request', true);
  req.send(formData);

  return false;
}


function resultHandler() {

}

function executeRequest() {
  var formData = new FormData();
  formData.append('csv', document.getElementById('input-csv').files[0])
  formData.append('api', document.getElementById('input-api').value)
  formData.append('cost', document.getElementById('input-cost').value)
  formData.append('impact', document.getElementById('input-impact').value)

  var req = new XMLHttpRequest();
  req.onreadystatechange = resultHandler;
  req.open('POST', '/results.json', true);
  req.send(formData);

  return false;
}
