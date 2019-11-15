document.addEventListener("DOMContentLoaded", function (event) {
  document.getElementById('benchmark-uris').value = [
    'https://picsum.photos/id/1025/800/600.jpg',
    'https://images.dog.ceo/breeds/pug/n02110958_10842.jpg',
    'https://cdn.shopify.com/s/files/1/2193/4553/products/pug_1400x.jpg'
  ].join('\n');

  document.getElementById('new-benchmark-form').onsubmit = submitNewBenchmarkForm;
  document.getElementById('check-benchmark-form').onsubmit = submitCheckBenchmarkForm;
  document.getElementById('submit-request-form').onsubmit = submitRequestForm;
  document.getElementById('submit-request-image-uri').oninput = inputImageUri;
})

function handleResults(e, resultDiv) {
  if (e.readyState != 4) {
    resultDiv.innerHTML = 'Processing...';
  }
  if (e.readyState === 4 && e.status === 200) {
    resultDiv.innerHTML = e.responseText;
  } else if (e.readyState === 4 && e.status != 200) {
    resultDiv.innerHTML = "[HTTP" + e.status + "]: " + e.responseText;
  }
}

function invalidId(id) {
  return isNaN(id) || id.trim().length == 0;
}

function submitNewBenchmarkForm() {
  var benchmarkUris = document.getElementById('benchmark-uris');
  var service = document.getElementById('service');
  var maxLabels = document.getElementById('max-labels');
  var minConfidence = document.getElementById('min-confidence');
  var deltaLabels = document.getElementById('delta-labels');
  var deltaConfidence = document.getElementById('delta-confidence');
  var reevaluateOn = document.getElementById('reevaluate-on');
  var severity = document.getElementById('severity');

  var results = document.getElementById('new-benchmark-form-results');

  var formData = new FormData();
  formData.append('benchmark_uris', benchmarkUris.value);
  formData.append('service', service.value);
  formData.append('max_labels', maxLabels.value);
  formData.append('min_confidence', minConfidence.value);
  formData.append('delta_labels', deltaLabels.value);
  formData.append('delta_confidence', deltaConfidence.value);
  formData.append('reevaluate_on', reevaluateOn.value);
  formData.append('severity', severity.value)

  var req = new XMLHttpRequest();
  req.onreadystatechange = function () { handleResults(this, results) };
  req.open('POST', '/benchmark', true);
  req.send(formData);

  return false;
}

function submitCheckBenchmarkForm() {
  var id = document.getElementById('check-benchmark-benchmark-id').value;

  if (invalidId(id)) { return false; }

  var statusResults = document.getElementById('check-benchmark-status-results');
  var logResults = document.getElementById('check-benchmark-log-results');

  var statusReq = new XMLHttpRequest();
  statusReq.onreadystatechange = function () { handleResults(this, statusResults); }
  statusReq.open('GET', '/benchmark/' + id + '/status', true);
  statusReq.send();

  var logReq = new XMLHttpRequest();
  logReq.onreadystatechange = function () { handleResults(this, logResults); }
  logReq.open('GET', '/benchmark/' + id + '/log', true);
  logReq.send();

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
