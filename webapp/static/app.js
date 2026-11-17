"use strict";
const $ = (id) => document.getElementById(id);
const fields = [];
let dataset = null, active = false, loading = true, uploading = false, result = null, page = 0, currentJob = null, pollTimer;
for (let i = 0; i < 8; i++) {
  const label = document.createElement("label"); label.textContent = `c[${i}]`;
  const input = document.createElement("input"); input.type = "text"; input.inputMode = "numeric";
  input.value = i === 0 ? "16384" : "0"; input.dataset.testid = `coefficient-${i}`;
  input.setAttribute("aria-label", `Coefficient ${i}`); input.addEventListener("input", () => {
    clearError(); updateForm();
    const invalid = coefficients().indexOf(null);
    if (invalid !== -1) showError({code:"COEFFICIENT_OUT_OF_RANGE",message:"Coefficient must be an integer between -32768 and 32767.",field:`coefficients[${invalid}]`});
  });
  label.append(input); $("coefficients").append(label); fields.push(input);
}
function coefficients() {
  return fields.map((field) => {
    const token = field.value.trim(), value = Number(token);
    const valid = /^[+-]?[0-9]+$/.test(token) && Number.isSafeInteger(value) && value >= -32768 && value <= 32767;
    field.setAttribute("aria-invalid", String(!valid));
    return valid ? value : null;
  });
}
function updateForm() {
  const valid = !coefficients().includes(null);
  $("submit").disabled = loading || active || uploading || !dataset || !valid || $("mode").selectedOptions[0].disabled;
  $("configuration").disabled = active || uploading || loading;
  $("file").disabled = active || uploading;
  $("upload").disabled = active || uploading || !$("file").files.length;
}
function clearError() { $("error").hidden = true; $("error").dataset.code = ""; }
function showError(error) {
  $("error").hidden = false; $("error").dataset.code = error.code || "NETWORK_ERROR";
  $("error").textContent = `${error.message || "Could not contact the server."}${error.field ? ` (${error.field})` : ""}`;
}
async function api(path, options) {
  let response;
  try { response = await fetch(path, options); } catch (_) { throw { code: "NETWORK_ERROR", message: "Connection lost. Check the server and retry." }; }
  const value = await response.json();
  if (!response.ok) throw value.error || { code: "HTTP_ERROR", message: `Request failed (${response.status}).` };
  return value;
}
function showDataset(value) { dataset = value; $("sample-count").textContent = `${value.sample_count.toLocaleString()} samples ready · ${value.dataset_id.slice(0, 15)}…`; updateForm(); }
function resetResult() {
  result = null; page = 0; $("empty").hidden = false; $("chart").hidden = true; $("download").hidden = true;
  $("output-count").textContent = $("saturation").textContent = $("elapsed").textContent = "—";
  $("rows").replaceChildren(); const row = document.createElement("tr"), cell = document.createElement("td");
  cell.colSpan = 4; cell.className = "muted"; cell.textContent = "No results yet"; row.append(cell); $("rows").append(row);
  $("range").textContent = "0 samples"; $("previous").disabled = $("next").disabled = true;
  $("verification").textContent = "Verification details appear when a job finishes. Reference output is computed by the model.";
}
function showJob(status) {
  active = ["queued", "running"].includes(status.state);
  $("status").dataset.state = status.state; $("status").textContent = status.state.replace("_", " ");
  $("job-id").textContent = status.job_id;
  $("engine").textContent = status.mode === "reference" ? "Python reference" : "RTL simulation";
  $("job-note").textContent = active ? (status.state === "queued" ? "Waiting for the worker…" : "Processing the submitted dataset…") : status.state === "succeeded" ? "Processing complete. Result and download use the same stored output." : "This job did not produce a successful result.";
  if (status.error) showError(status.error);
  updateForm();
}
function showTable() {
  $("rows").replaceChildren();
  const start = page*50, end = Math.min(start+50, result.output_count);
  for (let i = start; i < end; i++) {
    const row = document.createElement("tr");
    for (const value of [i, result.inputs[i], result.outputs[i], result.saturated[i] ? "Yes" : "No"]) {
      const cell = document.createElement("td"); cell.textContent = String(value); row.append(cell);
    }
    row.lastChild.dataset.saturated = String(result.saturated[i]); $("rows").append(row);
  }
  $("range").textContent = `${start+1}–${end} of ${result.output_count.toLocaleString()} samples`;
  $("previous").disabled = page === 0; $("next").disabled = end === result.output_count;
}
function drawChart() {
  if (!result) return;
  const canvas = $("chart"), ratio = window.devicePixelRatio || 1, width = canvas.clientWidth, height = 245;
  canvas.width = width*ratio; canvas.height = height*ratio;
  const ctx = canvas.getContext("2d"); ctx.scale(ratio, ratio);
  const left = 48, right = width-12, top = 16, bottom = height-25;
  ctx.font = "10px system-ui"; ctx.fillStyle = "#718592";
  for (const value of [-32768, 0, 32767]) {
    const y = top+(32767-value)/65535*(bottom-top);
    ctx.strokeStyle = "#e5ecef"; ctx.beginPath(); ctx.moveTo(left,y); ctx.lineTo(right,y); ctx.stroke();
    ctx.fillText(String(value), 0, y+3);
  }
  const x = (i) => left+i/Math.max(1,result.input_count-1)*(right-left);
  for (const [values,color] of [[result.inputs,"#84a6b5"],[result.outputs,"#167b70"]]) {
    ctx.strokeStyle = color; ctx.lineWidth = 1.6; ctx.beginPath();
    values.forEach((value,i) => { const y = top+(32767-value)/65535*(bottom-top); if (i) ctx.lineTo(x(i),y); else ctx.moveTo(x(i),y); }); ctx.stroke();
    if (values.length === 1) { ctx.fillStyle = color; ctx.beginPath(); ctx.arc(x(0),top+(32767-values[0])/65535*(bottom-top),3,0,Math.PI*2); ctx.fill(); }
  }
  ctx.fillStyle = "#718592"; ctx.fillText("0",left,height-6); ctx.fillText(`Sample ${result.input_count-1}`,Math.max(left,right-70),height-6);
}
async function fetchResult(job) {
  result = await api(`/api/v1/jobs/${job}/result`); page = 0;
  $("empty").hidden = true; $("chart").hidden = false;
  $("output-count").textContent = result.output_count.toLocaleString(); $("saturation").textContent = String(result.saturation_count);
  $("elapsed").textContent = `${result.metrics.worker_elapsed_ms.toFixed(2)} ms`;
  $("elapsed-label").textContent = result.mode === "rtl" ? "COMPILE + SIMULATION TIME" : "WORKER COMPUTE TIME";
  $("engine").textContent = result.execution.engine;
  $("verification").textContent = result.verification.status === "passed" ? `RTL data and flags verified against Python: ${result.verification.compared_outputs} samples · ${result.metrics.rtl_cycles} stream cycles at 10 ns. Time shown includes compilation and simulation, not board performance.` : "Python reference output · independent RTL verification is not applicable. Time shown is model compute time, not FPGA performance.";
  $("download").href = `/api/v1/jobs/${job}/result.csv`; $("download").hidden = false;
  showTable(); drawChart();
}
async function poll(job) {
  clearTimeout(pollTimer); $("retry").hidden = true;
  try {
    const status = await api(`/api/v1/jobs/${job}`);
    if (job !== currentJob) return;
    showJob(status);
    if (active) pollTimer = setTimeout(() => poll(job), 1000);
    else if (status.state === "succeeded") await fetchResult(job);
  } catch (error) { showError(error); $("retry").hidden = false; }
}
$("file").addEventListener("change", () => { clearError(); dataset = null; $("sample-count").textContent = "File selected; upload to validate"; updateForm(); });
$("half-gain").addEventListener("click", () => { fields.forEach((input,i) => { input.value = i === 0 ? "16384" : "0"; }); clearError(); updateForm(); });
$("upload").addEventListener("click", async () => {
  clearError(); uploading = true; updateForm();
  try { const form = new FormData(); form.append("file", $("file").files[0]); showDataset(await api("/api/v1/datasets",{method:"POST",body:form})); }
  catch (error) { dataset = null; $("sample-count").textContent = "Upload was not accepted"; showError(error); }
  finally { uploading = false; updateForm(); }
});
$("submit").addEventListener("click", async () => {
  if ($("submit").disabled) return;
  clearError(); resetResult(); active = true; updateForm();
  try {
    const status = await api("/api/v1/jobs",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({mode:$("mode").value,dataset_id:dataset.dataset_id,coefficients:coefficients()})});
    currentJob = status.job_id; history.replaceState(null,"",`/?job_id=${encodeURIComponent(currentJob)}`); showJob(status); poll(currentJob);
  } catch (error) { active = false; updateForm(); showError(error); }
});
$("retry").addEventListener("click", () => { clearError(); if (currentJob) poll(currentJob); });
$("previous").addEventListener("click", () => { page--; showTable(); });
$("next").addEventListener("click", () => { page++; showTable(); });
window.addEventListener("resize", drawChart);
async function initialize() {
  try {
    const caps = await api("/api/v1/capabilities");
    for (const option of $("mode").options) {
      option.disabled = !caps.modes[option.value].available;
      if (option.value === "rtl") option.textContent = caps.modes.rtl.available ? "Vivado RTL simulation" : "RTL simulation · unavailable";
    }
    $("mode-note").textContent = caps.modes.rtl.available ? "Both modes are available. RTL runs the submitted dataset through Vivado XSim and checks it against Python." : "Python reference is available. Configure the server's Vivado path to enable real RTL simulation.";
    const job = new URLSearchParams(location.search).get("job_id");
    if (job) {
      currentJob = job; active = true;
      const status = await api(`/api/v1/jobs/${encodeURIComponent(job)}`);
      status.coefficients.forEach((value,i) => { fields[i].value = String(value); }); $("mode").value = status.mode;
      showDataset(await api(`/api/v1/datasets/${encodeURIComponent(status.dataset_id)}`));
      await poll(job);
    }
  } catch (error) { active = false; showError(error); }
  finally { loading = false; updateForm(); }
}
initialize();
