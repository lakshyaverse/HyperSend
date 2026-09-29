/**
 * The serve-mode web UI: one self-contained HTML page, no build step, no
 * dependencies. Written in the app's visual language — pastel sky, frosted
 * glass panels, deep-blue ink — so the browser GUI reads as HyperSend and not
 * as a generic admin page. Vanilla JS talks to the /api/* endpoints with
 * fetch + EventSource; drag-and-drop stages files, the devices list polls
 * nothing (an SSE stream pushes every change).
 */

export const PAGE = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HyperSend</title>
<style>
  :root {
    --sky0: #9ed4fc; --sky1: #78b0fc; --sky2: #6b9ffa; --ink: #14428f;
    --ink-soft: rgba(20, 66, 143, .62); --glass: rgba(255, 255, 255, .42);
    --glass-edge: rgba(255, 255, 255, .85); --radius: 18px;
  }
  * { box-sizing: border-box; margin: 0; }
  html, body { height: 100%; }
  body {
    font: 14px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif;
    color: var(--ink);
    background: linear-gradient(180deg, var(--sky0), var(--sky1) 45%, var(--sky2));
    min-height: 100%;
    display: flex; align-items: center; justify-content: center;
    padding: 24px;
  }
  .wrap { width: min(860px, 100%); }
  .head { text-align: center; margin-bottom: 18px; color: #fff; text-shadow: 0 1px 8px rgba(20,66,143,.35); }
  .head h1 { font-size: 26px; font-weight: 700; letter-spacing: .2px; }
  .head p { opacity: .9; font-size: 13px; margin-top: 2px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  @media (max-width: 720px) { .grid { grid-template-columns: 1fr; } }
  .panel {
    background: var(--glass);
    border: 1px solid var(--glass-edge);
    border-radius: var(--radius);
    box-shadow: 0 12px 40px rgba(20, 66, 143, .18), inset 0 1px 0 rgba(255,255,255,.9);
    backdrop-filter: blur(18px) saturate(1.4);
    -webkit-backdrop-filter: blur(18px) saturate(1.4);
    padding: 18px;
  }
  .panel h2 {
    font-size: 11px; text-transform: uppercase; letter-spacing: 1.4px;
    color: var(--ink-soft); margin-bottom: 12px; font-weight: 600;
  }
  #drop {
    border: 2px dashed rgba(20, 66, 143, .35);
    border-radius: 14px;
    padding: 30px 14px;
    text-align: center;
    cursor: pointer;
    transition: background .18s, border-color .18s, transform .18s;
  }
  #drop:hover { background: rgba(255,255,255,.25); }
  #drop.over { background: rgba(255,255,255,.5); border-color: var(--ink); transform: scale(1.015); }
  #drop .big { font-size: 15px; font-weight: 600; }
  #drop .sub { font-size: 12px; color: var(--ink-soft); margin-top: 3px; }
  #stageList { margin-top: 12px; display: flex; flex-direction: column; gap: 6px; }
  .file {
    display: flex; align-items: center; gap: 8px;
    background: rgba(255,255,255,.55);
    border-radius: 10px; padding: 8px 12px; font-size: 13px;
  }
  .file .name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .file .size { color: var(--ink-soft); font-variant-numeric: tabular-nums; }
  .file .x { cursor: pointer; opacity: .55; border: 0; background: none; font-size: 15px; color: var(--ink); }
  .file .x:hover { opacity: 1; }
  #peerList { display: flex; flex-direction: column; gap: 6px; min-height: 60px; }
  .peer {
    display: flex; align-items: center; gap: 10px;
    background: rgba(255,255,255,.55);
    border-radius: 10px; padding: 10px 12px; cursor: pointer;
    border: 1.5px solid transparent;
    transition: border-color .15s, background .15s;
  }
  .peer:hover { background: rgba(255,255,255,.75); }
  .peer.sel { border-color: var(--ink); background: rgba(255,255,255,.75); }
  .peer .dot {
    width: 9px; height: 9px; border-radius: 50%;
    background: #2fbf71; box-shadow: 0 0 8px rgba(47,191,113,.8);
    flex: none;
  }
  .peer .name { font-weight: 600; }
  .peer .addr { margin-left: auto; font-size: 11.5px; color: var(--ink-soft); font-variant-numeric: tabular-nums; }
  .empty { color: var(--ink-soft); font-size: 12.5px; padding: 8px 2px; }
  #sendRow { display: flex; gap: 10px; margin-top: 14px; align-items: center; }
  #sendBtn {
    flex: 1;
    border: 0; border-radius: 12px; padding: 12px 0;
    font: inherit; font-weight: 700; font-size: 14px; color: #fff;
    background: linear-gradient(180deg, #4d8df8, #3567d6);
    box-shadow: 0 6px 18px rgba(38, 84, 190, .45), inset 0 1px 0 rgba(255,255,255,.4);
    cursor: pointer; transition: transform .12s, filter .15s;
  }
  #sendBtn:hover { filter: brightness(1.06); }
  #sendBtn:active { transform: scale(.985); }
  #sendBtn:disabled { filter: grayscale(.5) brightness(.9); cursor: default; }
  .card {
    display: none;
    margin-top: 16px;
    background: rgba(255,255,255,.6);
    border-radius: 12px; padding: 14px 16px;
  }
  .card.on { display: block; }
  .bar { height: 8px; border-radius: 99px; background: rgba(20,66,143,.15); overflow: hidden; }
  .bar i { display: block; height: 100%; width: 0%; border-radius: 99px;
           background: linear-gradient(90deg, #4d8df8, #35c8d6); transition: width .25s; }
  .meta { display: flex; justify-content: space-between; font-size: 12px; color: var(--ink-soft); margin-top: 6px;
          font-variant-numeric: tabular-nums; }
  #recvList { display: flex; flex-direction: column; gap: 6px; }
  .rcv { display: flex; align-items: center; gap: 8px; background: rgba(255,255,255,.55);
         border-radius: 10px; padding: 8px 12px; font-size: 13px; }
  .rcv .ok { color: #1d9d5c; font-weight: 700; }
  .rcv .name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rcv .size { color: var(--ink-soft); font-variant-numeric: tabular-nums; }
  /* incoming offer prompt */
  #offerMask {
    display: none; position: fixed; inset: 0;
    background: rgba(20, 40, 90, .35);
    align-items: center; justify-content: center; z-index: 10;
  }
  #offerMask.on { display: flex; }
  #offer {
    width: min(420px, calc(100vw - 48px));
    background: rgba(255,255,255,.92);
    border-radius: 18px; padding: 22px;
    box-shadow: 0 24px 80px rgba(10, 30, 80, .45);
    text-align: center;
  }
  #offer .t { font-weight: 700; font-size: 16px; }
  #offer .f { margin: 10px 0 2px; font-size: 14px; word-break: break-all; }
  #offer .s { color: var(--ink-soft); font-size: 12.5px; margin-bottom: 16px; }
  #offer .row { display: flex; gap: 10px; }
  #offer button {
    flex: 1; border: 0; border-radius: 12px; padding: 11px 0;
    font: inherit; font-weight: 700; cursor: pointer;
  }
  #acceptBtn { background: linear-gradient(180deg, #38b26d, #1d9d5c); color: #fff; }
  #declineBtn { background: rgba(20,66,143,.1); color: var(--ink); }
  .foot { text-align: center; margin-top: 14px; font-size: 11.5px; color: rgba(255,255,255,.85); }
</style>
</head>
<body>
<div class="wrap">
  <div class="head">
    <h1>HyperSend</h1>
    <p>files over Wi-Fi and cable, verified with SHA-256 — this page talks straight to your machine</p>
  </div>

  <div class="grid">
    <section class="panel">
      <h2>Send</h2>
      <div id="drop">
        <div class="big">Drop files here</div>
        <div class="sub">or click to choose — they stay on this machine until you send</div>
        <input id="picker" type="file" multiple hidden>
      </div>
      <div id="stageList"></div>
      <div id="sendRow">
        <button id="sendBtn" disabled>Send</button>
      </div>
      <div id="progressCard" class="card">
        <div class="bar"><i id="bar"></i></div>
        <div class="meta"><span id="pName"></span><span id="pPct"></span></div>
        <div class="meta"><span id="pRate"></span><span id="pLanes"></span></div>
      </div>
    </section>

    <section class="panel">
      <h2>Devices</h2>
      <div id="peerList"><div class="empty">listening for beacons…</div></div>

      <h2 style="margin-top:18px">Received</h2>
      <div id="recvList"><div class="empty">nothing yet</div></div>
    </section>
  </div>

  <div class="foot">Everything stays on your network. Nothing leaves the LAN.</div>
</div>

<div id="offerMask">
  <div id="offer">
    <div class="t">Incoming file</div>
    <div class="f" id="offerName"></div>
    <div class="s" id="offerSize"></div>
    <div class="row">
      <button id="acceptBtn">Accept</button>
      <button id="declineBtn">Decline</button>
    </div>
  </div>
</div>

<script>
const $ = (id) => document.getElementById(id);
const fmt = (n) => {
  if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
  if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
  if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
  return n + ' B';
};

let staged = [];
let selected = null;
let sending = false;

function renderStage() {
  const list = $('stageList');
  list.innerHTML = '';
  for (const f of staged) {
    const row = document.createElement('div');
    row.className = 'file';
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = f.name;
    const size = document.createElement('span');
    size.className = 'size';
    size.textContent = fmt(f.size);
    const x = document.createElement('button');
    x.className = 'x';
    x.textContent = '×';
    x.onclick = () => { staged = staged.filter((s) => s !== f); renderStage(); };
    row.append(name, size, x);
    list.appendChild(row);
  }
  $('sendBtn').disabled = staged.length === 0 || !selected || sending;
  $('sendBtn').textContent = sending
    ? 'Sending…'
    : staged.length === 0
      ? 'Send'
      : selected
        ? 'Send ' + staged.length + ' file' + (staged.length > 1 ? 's' : '') + ' to ' + selected.name
        : 'Pick a device';
}

function renderPeers(peers) {
  const list = $('peerList');
  list.innerHTML = '';
  if (!peers.length) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.textContent = 'listening for beacons… (or type an address below)';
    list.appendChild(e);
    return;
  }
  for (const p of peers) {
    const row = document.createElement('div');
    row.className = 'peer' + (selected && selected.host === p.host && selected.port === p.port ? ' sel' : '');
    const dot = document.createElement('span'); dot.className = 'dot';
    const name = document.createElement('span'); name.className = 'name'; name.textContent = p.name;
    const addr = document.createElement('span'); addr.className = 'addr'; addr.textContent = p.host + ':' + p.port;
    row.append(dot, name, addr);
    row.onclick = () => { selected = p; renderPeers(peers); renderStage(); };
    list.appendChild(row);
  }
}

function renderReceived(files) {
  const list = $('recvList');
  list.innerHTML = '';
  if (!files.length) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.textContent = 'nothing yet';
    list.appendChild(e);
    return;
  }
  for (const f of files.slice(-8).reverse()) {
    const row = document.createElement('div');
    row.className = 'rcv';
    const ok = document.createElement('span'); ok.className = 'ok'; ok.textContent = '✓';
    const name = document.createElement('span'); name.className = 'name'; name.textContent = f.name;
    const size = document.createElement('span'); size.className = 'size'; size.textContent = fmt(f.size);
    row.append(ok, name, size);
    list.appendChild(row);
  }
}

// ── SSE: every state change arrives pushed, nothing polls ────────────────────
const es = new EventSource('/api/events');
es.onmessage = (ev) => {
  const state = JSON.parse(ev.data);
  renderPeers(state.peers || []);
  renderReceived(state.received || []);
  if (state.offer) showOffer(state.offer); else hideOffer();
  if (state.transfer) showProgress(state.transfer);
};

// ── staging ──────────────────────────────────────────────────────────────────
const drop = $('drop');
drop.onclick = () => $('picker').click();
$('picker').onchange = () => { addFiles($('picker').files); $('picker').value = ''; };
['dragenter', 'dragover'].forEach((t) =>
  drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach((t) =>
  drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', (e) => addFiles(e.dataTransfer.files));

function addFiles(fileList) {
  for (const f of fileList) {
    if (!staged.some((s) => s.name === f.name && s.size === f.size)) staged.push(f);
  }
  renderStage();
}

// ── send ─────────────────────────────────────────────────────────────────────
$('sendBtn').onclick = async () => {
  if (sending || !selected || staged.length === 0) return;
  sending = true;
  renderStage();
  $('progressCard').classList.add('on');
  const fd = new FormData();
  for (const f of staged) fd.append('files', f, f.name);
  fd.append('host', selected.host);
  fd.append('port', String(selected.port));
  try {
    const res = await fetch('/api/send', { method: 'POST', body: fd });
    const out = await res.json();
    if (!out.ok) {
      $('progressCard').classList.remove('on');
      alert('send failed: ' + (out.error || 'unknown error'));
    }
  } catch (err) {
    $('progressCard').classList.remove('on');
    alert('send failed: ' + err.message);
  }
  sending = false;
  staged = [];
  renderStage();
  setTimeout(() => $('progressCard').classList.remove('on'), 2500);
};

function showProgress(t) {
  $('progressCard').classList.add('on');
  $('bar').style.width = Math.round((t.bytesDone / Math.max(1, t.bytesTotal)) * 100) + '%';
  $('pName').textContent = t.fileName;
  $('pPct').textContent = Math.round((t.bytesDone / Math.max(1, t.bytesTotal)) * 100) + '%';
  $('pRate').textContent = t.mibsPerSec.toFixed(1) + ' MiB/s';
  $('pLanes').textContent = (t.perPath || []).map((p) => p.label + ' ' + (p.bytes / 1048576).toFixed(0) + 'MB').join(' + ');
}

// ── incoming offers ──────────────────────────────────────────────────────────
let offerId = null;
function showOffer(o) {
  offerId = o.transferId;
  $('offerName').textContent = o.path;
  $('offerSize').textContent = fmt(o.size);
  $('offerMask').classList.add('on');
}
function hideOffer() {
  offerId = null;
  $('offerMask').classList.remove('on');
}
$('acceptBtn').onclick = () => decide(true);
$('declineBtn').onclick = () => decide(false);
async function decide(accept) {
  const id = offerId;
  hideOffer();
  if (id) await fetch('/api/offer/' + id, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ accept }),
  });
}

renderStage();
</script>
</body>
</html>`;
