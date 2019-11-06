document.addEventListener("DOMContentLoaded", function (event) {
  document.getElementById('benchmark-uris').value = [
    'https://picsum.photos/id/1025/800/600.jpg',
    'https://images.dog.ceo/breeds/pug/n02110958_10842.jpg',
    'https://upload.wikimedia.org/wikipedia/commons/7/7f/Pug_portrait.jpg'
  ].join('\n');

  document.getElementById('new-benchmark-form').onsubmit = submitNewBenchmarkForm;
  document.getElementById('check-benchmark-form').onsubmit = submitCheckBenchmarkForm;
  document.getElementById('submit-request-form').onsubmit = submitCheckBenchmarkForm;
})

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
  var form = document.getElementById('new-benchmark-form');

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
  req.onreadystatechange = function (e) {
    if (this.readyState != 4) {
      results.innerHTML = 'Processing...';
    }
    if (this.readyState === 4 && this.status === 200) {
      results.innerHTML = this.responseText;
      form.clear();
    } else if (this.readyState === 4 && this.status != 200) {
      results.innerHTML = "[HTTP" + this.status + "]: " + this.responseText;
    }
  };
  req.open('POST', '/benchmark', true);
  req.send(formData);

  return false;
}

function submitCheckBenchmarkForm() {

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
