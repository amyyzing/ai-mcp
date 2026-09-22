'use strict';
const $ = (id) => document.getElementById(id);
const source = $('source');
let ready = false, busy = false, mode = 'sandboxed', currentJob = null;
let selectedArtifact = null, artifactText = '', fullArtifact = false;
let toastTimer, statsTimer, refreshSerial = 0, dragDepth = 0, lastPollFailure = false;
const encoder = new TextEncoder();
const terminal = new Set(['completed', 'partial', 'failed', 'unsupported', 'cancelled']);
const escapeHtml = (s) => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const bytes = (n) => n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(2)} MB`;

function notify(message, error = false) {
  clearTimeout(toastTimer); $('toast').textContent = message;
  $('toast').classList.toggle('error', error); $('toast').hidden = false;
  toastTimer = setTimeout(() => $('toast').hidden = true, 4300);
}
async function api(path, options = {}) {
  const response = await fetch(path, {...options, credentials: 'same-origin', cache: 'no-store', signal: options.signal || AbortSignal.timeout(15000)});
  let body;
  try { body = await response.json(); } catch { throw new Error(`The server returned an unreadable response (${response.status}).`); }
  if (!response.ok) throw new Error(typeof body.detail === 'string' ? body.detail : `Request failed (${response.status}).`);
  return body;
}
function updateRun() {
  const count = encoder.encode(source.value).length;
  $('run-button').disabled = busy || !ready || !source.value.trim() || count > 4194304;
}
function updateStats() {
  const count = encoder.encode(source.value).length, lines = source.value.split('\n').length;
  $('input-stats').textContent = `${bytes(count)} · ${lines.toLocaleString()} ${lines === 1 ? 'line' : 'lines'} · UTF-8`;
  $('input-stats').style.color = count > 4194304 ? '#ff8d7e' : '';
  $('input-gutter').textContent = Array.from({length: Math.min(lines, 10000)}, (_, i) => i + 1).join('\n');
  $('input-gutter').scrollTop = source.scrollTop; updateRun();
}
source.addEventListener('input', () => { clearTimeout(statsTimer); statsTimer = setTimeout(updateStats, 100); });
source.addEventListener('scroll', () => $('input-gutter').scrollTop = source.scrollTop);
source.addEventListener('keydown', (e) => {
  if (e.key === 'Tab' && !busy) { e.preventDefault(); source.setRangeText('    ', source.selectionStart, source.selectionEnd, 'end'); updateStats(); }
});
function setSource(text, name = 'protected.luau') {
  if (busy) return notify('Wait for this job to finish or cancel it first.', true);
  if (encoder.encode(text).length > 4194304) return notify('The source limit is 4 MB.', true);
  source.value = text; $('file-label').textContent = name; $('file-label').title = name; updateStats(); source.focus();
}
async function loadFile(file) {
  if (!file) return;
  if (file.size > 4194304) return notify('The source limit is 4 MB.', true);
  if (!/\.(lua|luau|txt|md)$/i.test(file.name)) return notify('Choose a .lua, .luau, .txt, or .md file.', true);
  try { setSource(await file.text(), file.name); notify(`Loaded ${file.name}`); } catch { notify('The file could not be read.', true); }
}
$('upload-button').addEventListener('click', () => $('file-input').click());
$('file-input').addEventListener('change', e => { loadFile(e.target.files[0]); e.target.value = ''; });
$('paste-button').addEventListener('click', async () => {
  try { setSource(await navigator.clipboard.readText()); }
  catch { source.focus(); notify('Clipboard access is unavailable. Paste into the editor with Ctrl+V or ⌘V.'); }
});
$('clear-button').addEventListener('click', () => setSource(''));
const drop = $('drop-zone');
for (const name of ['dragenter', 'dragover', 'dragleave', 'drop']) drop.addEventListener(name, e => { e.preventDefault(); e.stopPropagation(); });
drop.addEventListener('dragenter', () => { dragDepth++; if (!busy) drop.classList.add('dragging'); });
drop.addEventListener('dragleave', () => { if (--dragDepth <= 0) drop.classList.remove('dragging'); });
drop.addEventListener('drop', e => { dragDepth = 0; drop.classList.remove('dragging'); loadFile(e.dataTransfer.files[0]); });
window.addEventListener('dragover', e => e.preventDefault()); window.addEventListener('drop', e => e.preventDefault());
$('settings-button').addEventListener('click', () => {
  $('settings-panel').hidden = !$('settings-panel').hidden;
  $('settings-button').setAttribute('aria-expanded', String(!$('settings-panel').hidden));
});
document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => {
  if (busy) return;
  mode = button.dataset.mode;
  document.querySelectorAll('[data-mode]').forEach(b => { b.classList.toggle('selected', b === button); b.setAttribute('aria-pressed', String(b === button)); });
  $('mode-description').textContent = mode === 'strict' ? 'Luraph: capture without staged finalisation. Other Luau: native literal/constant cleanup and source analysis without application execution.' : 'Native Luau 0.739 cleanup is applied to every input. Supported VM adapters run separately; observed calls never replace the full source.';
}));
function toggleExpand(force) {
  const expanded = force === undefined ? !$('workbench').classList.contains('expanded') : force;
  $('workbench').classList.toggle('expanded', expanded); document.body.classList.toggle('workspace-expanded', expanded);
  $('expand-button').setAttribute('aria-label', expanded ? 'Restore workspace' : 'Expand workspace');
  $('expand-button').title = expanded ? 'Restore workspace' : 'Expand workspace';
}
$('expand-button').addEventListener('click', () => toggleExpand());
window.addEventListener('keydown', e => {
  if (e.key === 'Escape') toggleExpand(false);
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter' && !$('run-button').disabled && !$('help-dialog').open) { e.preventDefault(); startJob(); }
});
const showHelp = () => $('help-dialog').showModal();
['how-button','limits-button','error-help'].forEach(id => $(id).addEventListener('click', showHelp));
['close-help','help-done'].forEach(id => $(id).addEventListener('click', () => $('help-dialog').close()));
$('help-dialog').addEventListener('click', e => { if (e.target === $('help-dialog')) { const r = e.target.getBoundingClientRect(); if(e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) e.target.close(); } });
for (let i = 0; i < 18; i++) {
  const p = document.createElement('span'); p.className = 'particle'; const size = 2 + (i * 7 % 8);
  p.style.cssText = `left:${(i * 37 + 9) % 100}%;top:${(i * 23 + 8) % 100}%;width:${size}px;height:${size}px;animation-delay:-${i * 1.8}s;animation-duration:${15 + i % 9}s;filter:blur(${1 + i % 4}px)`;
  $('particles').append(p);
}
$('motion-button').addEventListener('click', () => {
  const paused = document.body.classList.toggle('motion-paused');
  $('motion-button').setAttribute('aria-label', paused ? 'Resume background animation' : 'Pause background animation');
  $('motion-button').title = paused ? 'Resume background animation' : 'Pause background animation';
});
async function checkHealth() {
  try {
    const health = await api('/api/health'); ready = health.ok === true;
    $('engine-status').innerHTML = '<span class="status-dot online"></span><span>Engine online</span>';
    $('engine-status').title = `luau-vmp-deobf ${health.version} · official Luau ${health.nativeLuau || 'unavailable'} · ${health.commit.slice(0, 8)}`;
  } catch {
    ready = false; $('engine-status').innerHTML = '<span class="status-dot offline"></span><span>Engine unavailable</span>';
    $('engine-status').title = 'The server is not currently ready. Status refreshes automatically.';
  }
  updateRun();
}
function setBusy(value) {
  busy = value; source.readOnly = value;
  ['paste-button','clear-button','upload-button','timeout'].forEach(id => $(id).disabled = value);
  document.querySelectorAll('[data-mode]').forEach(b => b.disabled = value); $('cancel-button').hidden = !value;
  $('run-button').querySelector('span').textContent = value ? 'Processing' : 'Analyse & deobfuscate'; updateRun();
}
function showView(view) { for (const id of ['output-empty','running-state','error-state','output-code']) $(id).hidden = id !== view; }
function badge(label, cls = '') { $('output-badge').textContent = label; $('output-badge').className = `output-badge ${cls}`; }
function resetOutput() {
  refreshSerial++; selectedArtifact = null; artifactText = ''; fullArtifact = false;
  $('output-code').textContent = ''; $('artifact-picker').hidden = true; $('output-note').hidden = false;
  $('output-note').textContent = 'Waiting for engine output'; $('output-size').textContent = '—';
  $('copy-button').disabled = true; $('download-button').disabled = true; $('export-all').disabled = true;
  $('result-summary').hidden = true; $('warnings').hidden = true; $('warnings').textContent = ''; $('report-metrics').textContent = ''; $('events').textContent = '';
}
async function startJob() {
  if (busy || !source.value.trim() || !ready) return;
  setBusy(true); resetOutput(); $('job-report').hidden = false; $('events-details').open = true;
  badge('Submitting', 'running'); showView('running-state'); $('running-title').textContent = 'Preparing recovery';
  $('running-description').textContent = 'Sending your source to the recovery worker.'; $('stage-track-fill').style.width = '4%';
  try {
    const job = await api('/api/jobs', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({source:source.value, name:$('file-label').textContent, mode, timeout:Number($('timeout').value)})});
    currentJob = job.id; lastPollFailure = false; renderJob(job); await pollJob(job.id);
  } catch (e) {
    setBusy(false); showView('error-state'); badge('Request failed','failed');
    $('error-title').textContent = 'Could not start recovery'; $('error-message').textContent = e.message; notify(e.message, true);
  }
}
$('run-button').addEventListener('click', startJob);
$('cancel-button').addEventListener('click', async () => {
  if (!currentJob) return;
  $('cancel-button').disabled = true;
  try { await api(`/api/jobs/${currentJob}`, {method:'DELETE'}); notify('Cancellation requested.'); }
  catch (e) { notify(e.message, true); } finally { $('cancel-button').disabled = false; }
});
async function pollJob(id) {
  let failures = 0;
  while (currentJob === id) {
    try {
      const job = await api(`/api/jobs/${id}`); failures = 0; lastPollFailure = false; renderJob(job);
      if (terminal.has(job.state)) { await finishJob(job); return; }
    } catch (e) {
      failures++;
      if (!lastPollFailure) { notify('Connection interrupted. Retrying this same job…', true); lastPollFailure = true; }
      if (failures >= 8) {
        setBusy(false); showView('error-state'); badge('Disconnected','failed'); $('error-title').textContent = 'Lost connection to the job';
        $('error-message').textContent = `${e.message} The server job may still be running; reload after its timeout before resubmitting.`; return;
      }
    }
    await new Promise(resolve => setTimeout(resolve, Math.min(1400 + failures * 800, 6000)));
  }
}
function renderJob(job) {
  $('elapsed').textContent = `${job.elapsed.toFixed(1)} s`;
  $('events').replaceChildren(...job.events.map(event => {
    const li = document.createElement('li'), time = document.createElement('time'), text = document.createElement('span');
    time.textContent = `+${event.at.toFixed(2)}s`; text.textContent = event.message; li.append(time,text); return li;
  }));
  $('event-count').textContent = `${job.events.length} events`;
  if (!terminal.has(job.state)) {
    badge(job.state === 'queued' ? 'Queued' : 'Recovering', 'running');
    $('running-title').textContent = job.state === 'queued' ? 'In the recovery queue' : job.phaseLabel;
    $('running-description').textContent = job.state === 'queued' ? 'Your job will start when the current worker is available.' : `Stage ${Math.max(job.phase, 1)} · ${job.mode === 'strict' ? 'Strict capture' : 'Full recovery'}`;
    $('stage-track-fill').style.width = `${Math.max(4, job.phase / 8 * 100)}%`;
  }
  const q = job.quality;
  const metrics = [
    ['Input class', q.family || 'Detecting', ''],
    ['Selected compile check', q.compileChecked == null ? 'Pending' : q.compileChecked ? 'Passed' : 'Unconfirmed', q.compileChecked ? 'good' : 'warn'],
    ['Escaped literals decoded', q.escapedLiteralsDecoded ?? '—', ''],
    ['Constant expressions reduced', q.constantExpressionsFolded ?? '—', ''],
    ['Pool entries recovered', q.decodedStrings ?? '—', ''],
    ['Functions inspected', q.syntacticFunctions ?? q.prototypes ?? '—', ''],
    ['Referenced URLs · not fetched', q.externalUrls ?? '—', ''],
    ['Opaque binary literals', q.opaqueBinaryLiterals ?? '—', ''],
    ['Embedded source candidates', q.embeddedSources ?? '—', ''],
    ['Native verification', q.nativeRuntime ?? '—', ''],
    ['Observed profiles · not all paths', q.nativeComparisons != null ? `${q.nativeComparisons}/3` : 'Not run', ''],
  ];  $('report-metrics').replaceChildren(...metrics.map(([label,value,cls]) => {
    const el = document.createElement('span'); el.className = `metric ${cls}`; el.append(document.createTextNode(label));
    const v = document.createElement('strong'); v.textContent = String(value); el.append(v); return el;
  }));
  $('warnings').replaceChildren(...job.warnings.map(w => { const p = document.createElement('p'); p.textContent = w; return p; })); $('warnings').hidden = !job.warnings.length;
}
async function finishJob(job) {
  setBusy(false);
  const outcomes = {'unchanged':'Unchanged · no transformation','formatted-only':'Formatted only','literals-decoded':'Literals decoded','constants-decoded':'Constants decoded','partial-vm-recovery':'Partial VM recovery','partial-analysis':'Partial analysis'};
  const resultLabel = outcomes[job.quality.outcome] || ({completed:'Processed',partial:'Partial recovery',unsupported:'Unsupported',failed:'Failed',cancelled:'Cancelled'})[job.state];
  badge(resultLabel, job.state);
  const summary = $('result-summary');
  summary.hidden = !['completed','partial'].includes(job.state);
  summary.textContent = job.quality.outcome === 'unchanged' ? 'No supported source transformation was applied. This is the preserved input, not a devirtualized application.' :
    job.quality.outcome === 'formatted-only' ? 'Layout was improved; no hidden program or encrypted payload was recovered.' :
    `${resultLabel}. Full source is retained. ${job.quality.externalUrls ? 'Referenced remote bodies were not downloaded. ' : ''}${job.state === 'partial' ? 'Remaining recovery gaps are listed below.' : 'Compilation validates syntax, not every runtime behavior.'}`;
  $('export-all').disabled = !job.artifacts.length;
  if (job.artifacts.length) {
    $('artifact-picker').hidden = false; $('output-note').hidden = true;
    $('artifact-select').replaceChildren(...job.artifacts.map(a => { const opt = document.createElement('option'); opt.value=a.name; opt.textContent=`${a.name} · ${a.kind}`; return opt; }));
    if (!job.primary) { const prompt = document.createElement('option'); prompt.value = ''; prompt.textContent = 'Open diagnostic…'; prompt.disabled = true; prompt.selected = true; $('artifact-select').prepend(prompt); } else { $('artifact-select').value = job.primary; }
  }
  if (job.state === 'completed' || job.state === 'partial') {
    await selectArtifact(job.primary || job.artifacts[0]?.name);
    notify(resultLabel + '. Inspect the selected artifact and coverage report.');
  } else {
    showView('error-state'); $('error-title').textContent = job.state === 'unsupported' ? 'This recovery path needs more support.' : job.state === 'cancelled' ? 'Recovery cancelled.' : 'This one needs a closer look.';
    $('error-message').textContent = job.error || 'The worker was stopped. Your source is still in the input editor.';
    $('output-note').textContent = job.state === 'unsupported' ? 'No source was fabricated' : 'No successful recovery';
  }
}
function highlight(text, name) {
  if (!/\.(lua|luau)$/.test(name)) return escapeHtml(text);
  const tokens = /--\[\[[\s\S]*?\]\]|--[^\n]*|\[\[[\s\S]*?\]\]|"(?:[^"\\]|\\[\s\S])*"|'(?:[^'\\]|\\[\s\S])*'|\b(?:local|function|end|return|if|then|else|elseif|while|do|for|in|repeat|until|break|continue|and|or|not|nil|true|false|type|export)\b|\b(?:print|warn|pairs|ipairs|tostring|tonumber|pcall|select|unpack|setmetatable|getfenv|require)\b|\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b/g;
  let out='', last=0;
  for (const m of text.matchAll(tokens)) {
    out += escapeHtml(text.slice(last,m.index)); const v=m[0];
    const cls = v.startsWith('--') ? 'comment' : /^["'\[]/.test(v) ? 'string' : /^\d/.test(v) ? 'number' : /^(print|warn|pairs|ipairs|tostring|tonumber|pcall|select|unpack|setmetatable|getfenv|require)$/.test(v) ? 'builtin' : 'keyword';
    out += `<span class="tok-${cls}">${escapeHtml(v)}</span>`; last=m.index+v.length;
  }
  return out+escapeHtml(text.slice(last));
}
async function selectArtifact(name) {
  if (!name || !currentJob) return;
  const serial = ++refreshSerial, id=currentJob;
  try {
    const artifact = await api(`/api/jobs/${id}/artifact?name=${encodeURIComponent(name)}`);
    if (serial !== refreshSerial || id !== currentJob) return;
    selectedArtifact = name; artifactText = artifact.text; fullArtifact = !artifact.previewTruncated;
    $('output-code').innerHTML = highlight(artifact.text, name); $('output-code').scrollTop=0;
    $('output-size').textContent = `${bytes(artifact.bytes)}${artifact.previewTruncated ? ' · Preview' : ''}`;
    $('output-size').title = artifact.previewTruncated ? 'Preview is limited; copy and download retrieve the complete artifact.' : `SHA-256: ${artifact.sha256}`;
    $('copy-button').disabled = false; $('download-button').disabled = false; showView('output-code');
  } catch(e) { notify(e.message, true); }
}
$('artifact-select').addEventListener('change', e => selectArtifact(e.target.value));
$('copy-button').addEventListener('click', async () => {
  if (!selectedArtifact || !currentJob) return;
  try {
    let text=artifactText;
    if (!fullArtifact) {
      const response=await fetch(`/api/jobs/${currentJob}/artifact?download=true&name=${encodeURIComponent(selectedArtifact)}`, {credentials:'same-origin', cache:'no-store'});
      if(!response.ok) throw new Error('The artifact has expired.'); text=await response.text();
    }
    await navigator.clipboard.writeText(text); notify('Artifact copied to clipboard.');
  } catch(e) { notify('Clipboard access failed. Download the artifact instead.', true); }
});
function download(url) { const a = document.createElement('a'); a.href=url; a.download=''; document.body.append(a); a.click(); a.remove(); }
$('download-button').addEventListener('click', () => { if (selectedArtifact && currentJob) download(`/api/jobs/${currentJob}/artifact?download=true&name=${encodeURIComponent(selectedArtifact)}`); });
$('export-all').addEventListener('click', () => { if (currentJob) download(`/api/jobs/${currentJob}/download`); });
updateStats(); checkHealth(); setInterval(checkHealth, 30000);
