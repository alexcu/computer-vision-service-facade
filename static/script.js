var category_data = null;

document.addEventListener("DOMContentLoaded", function (event) {
  var default_dataset = [
    'https://picsum.photos/id/1025/800/600.jpg',
    'https://images.dog.ceo/breeds/pug/n02110958_10842.jpg',
    'https://cdn.shopify.com/s/files/1/2193/4553/products/pug_1400x.jpg'
  ].join('\n');

  document.getElementById('benchmark-dataset').value = default_dataset;
  document.getElementById('service').onchange = function (e) {
    if (e.target.value == "demo") {
      prefillDatasetWith("all");
    } else {
      document.getElementById('benchmark-dataset').value = default_dataset;
    }
  }

  document.getElementById('new-benchmark-form').onsubmit = submitNewBenchmarkForm;
  document.getElementById('submit-request-form').onsubmit = submitRequestForm;
  document.getElementById('submit-request-image-uri').oninput = updateImagePreview;
  document.getElementById('benchmark-callback-uri').value = window.location.origin + '/callbacks/benchmark';

  document.getElementById('severity').onchange = function (e) {
    var el = document.getElementById('warning-callback-uri')
    var iswarn = e.target.value == 'warning';
    el.value = iswarn ? window.location.origin + '/callbacks/warning' : '';
    el.required = iswarn;
    document.getElementById('warning-callback-uri-form-group').classList.toggle('required', iswarn);
  }

  // Load categories
  var xhr = new XMLHttpRequest();
  xhr.open('GET', '/demo/categories.json', true);
  xhr.onreadystatechange = function () {
    if (xhr.readyState == xhr.DONE) {
      category_data = JSON.parse(xhr.responseText);
    }
  }
  xhr.send();
});

function prefillDatasetWith(type) {
  document.getElementById('benchmark-dataset').value = category_data[type].map(function (v) {
    return window.location.origin + "/demo/data/" + v + ".jpeg";
  }).join("\n");
  if (type != 'all') {
    document.getElementById('expected-labels').value = type;
  }
}

function updateImagePreview() {
  var imageUri = document.getElementById('submit-request-image-uri').value;
  var imgEl = document.getElementById('submit-request-image-preview');
  imgEl.src = imageUri;
}

function randomImage() {
  document.getElementById('submit-request-image-uri').value =
    'https://picsum.photos/seed/' + Math.floor(Math.random() * 10000) + '/800/600'
  updateImagePreview();
}

function randomTestImage(type) {
  var xhr = new XMLHttpRequest();
  xhr.open("GET", window.location.origin + '/demo/random/' + type + '.jpg');
  xhr.onreadystatechange = function (e) {
    if (xhr.readyState == xhr.DONE) {
      document.getElementById('submit-request-image-uri').value = xhr.responseURL;
      updateImagePreview();
    }
  }
  xhr.send();
}

function isJson(str) {
  try {
    JSON.parse(str);
  } catch (e) {
    return false;
  }
  return true;
}

function escapeHtml(unsafe) {
  return unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function xhr(method, to, resultDiv, data, headers) {
  var xhr = new XMLHttpRequest();
  data = data == undefined ? '' : JSON.stringify(data, null, 2);
  url = new URL(to, location)
  xhr.open(method, to, true);
  for (var header in headers) {
    xhr.setRequestHeader(header, headers[header]);
  }
  xhr.setRequestHeader('Content-Type', 'application/json;charset=utf-8');
  xhr.onreadystatechange = function () {
    if (xhr.readyState == xhr.DONE) {
      var resText = xhr.responseText;
      if (isJson(resText)) {
        resText = JSON.stringify(JSON.parse(resText), null, 2);
      }
      resultDiv.innerHTML +=
        (data.length > 0 ? '\r\n\r\n' : '') +
        '<<<<<<<<<\r\n' +
        'HTTP/1.1 ' + xhr.status + ' ' + xhr.statusText + '\r\n' +
        xhr.getAllResponseHeaders() + '\r\n' +
        escapeHtml(resText);
    }
  };
  xhr.send(data);
  resultDiv.innerHTML =
    '>>>>>>>>>\r\n' + method + ' ' + to + ' HTTP/1.1\r\n' +
    'host: ' + url.host + '\r\n' +
    'user-agent: ' + navigator.userAgent + '\r\n' +
    'accept: */*\r\n' +
    'content-type: application/json;charset=utf-8\r\n' +
    'content-length: ' + data.length + function () {
      if (headers == undefined || headers.length == 0) {
        return data.length > 0 ? '\r\n\r\n' + data : '\r\n'
      } else {
        var result = '\r\n';
        for (var header in headers) {
          result += header.toLowerCase() + ': ' + headers[header] + '\r\n';
        }
        result += data.length > 0 ? '\r\n' + data : '';
        return result;
      }
    }();
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

  if (isNaN(id) || id.trim().length == 0) {
    return false;
  }

  var statusResults = document.getElementById('check-benchmark-status-results');
  var logResults = document.getElementById('check-benchmark-log-results');

  xhr('GET', '/benchmark/' + id, statusResults);
  xhr('GET', '/benchmark/' + id + '/log', logResults);
  return false;
}

function submitRequestForm() {
  var imageUri = document.getElementById('submit-request-image-uri').value;
  var ifMatchValue = document.getElementById('submit-request-if-match').value;
  var ifUnmodifiedSinceValue = document.getElementById('submit-request-if-unmodified-since').value;

  if (ifMatchValue.trim().length == 0 || imageUri.trim().length == 0) {
    return false;
  }

  var results = document.getElementById('submit-request-results');
  var headers = {
    'If-Match': ifMatchValue
  }
  if (ifUnmodifiedSinceValue.trim().length > 0) {
    headers['If-Unmodified-Since'] = ifUnmodifiedSinceValue;
  }

  xhr('GET', '/labels?image=' + encodeURI(imageUri), results, null, headers);

  return false;
}

function triggerBenchmark(evolution = false) {
  var id = document.getElementById('check-benchmark-benchmark-id').value;

  if (isNaN(id) || id.trim().length == 0) {
    return false;
  }

  var statusResults = document.getElementById('check-benchmark-status-results');
  var logResults = document.getElementById('check-benchmark-log-results');
  var patchPayloadData = {
    is_benchmarking: true
  }

  if (evolution) {
    patchPayloadData['flip_demo_timestamp'] = evolution;
  }

  xhr('GET', '/benchmark/' + id + '/log', logResults);
  xhr('PATCH', '/benchmark/' + id, statusResults, patchPayloadData);
}

function triggerBenchmarkWithEvolution() {
  triggerBenchmark(true);
}
