document.addEventListener("DOMContentLoaded", function (event) {
  document.getElementById('benchmark-uris').value = [
    'https://picsum.photos/id/1025/800/600.jpg',
    'https://images.dog.ceo/breeds/pug/n02110958_10842.jpg',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/7/7f/Pug_portrait.jpg/800px-Pug_portrait.jpg'
  ].join('\n');

  document.getElementById('new-benchmark-form').onsubmit = submitNewBenchmarkForm;
  document.getElementById('check-benchmark-form').onsubmit = submitCheckBenchmarkForm;
  document.getElementById('submit-request-form').onsubmit = submitCheckBenchmarkForm;
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
  var id = document.getElementById('benchmark-id').value;
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

function submitRequestForm() {

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
