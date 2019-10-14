function resultHandler() {
  if (this.readyState != 4) {
    document.getElementById("results").innerHTML = "Processing...";
  }
  if (this.readyState === 4 && this.status === 200) {
    var data = JSON.parse(this.responseText);
    document.getElementById("results").innerHTML = this.responseText;
  } else if (this.readyState === 4 && this.status != 200) {
    alert("[HTTP" + this.status + "]: " + this.responseText)
  }
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
