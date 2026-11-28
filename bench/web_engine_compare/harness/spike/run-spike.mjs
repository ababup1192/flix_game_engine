// X1 案 c のスパイクを流す: 書き出した頁を手元で配り、index.html に extloop-spike.js を差し込んで、ヘッドレスの Chrome で開き、window.__spike を読んで要約を出す。
//   node run-spike.mjs <書き出したフォルダ> [--headed]
// Chrome とサーバーはこの中で起こして、終わる時に止める。
import { createServer } from 'node:http';
import { readFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { join, extname } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const dir = process.argv[2];
const headed = process.argv.includes('--headed');
const here = new URL('.', import.meta.url).pathname;
const types = { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json' };

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path === '/extloop-spike.js') {
    res.writeHead(200, { 'content-type': 'text/javascript' });
    return res.end(readFileSync(join(here, 'extloop-spike.js')));
  }
  const file = join(dir, path === '/' ? 'index.html' : path);
  if (!existsSync(file)) { res.writeHead(404); return res.end(); }
  let body = readFileSync(file);
  if (file.endsWith('index.html')) {
    body = Buffer.from(String(body).replace('<head>', '<head>\n<script src="/extloop-spike.js"></script>'));
  }
  res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
  res.end(body);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const profile = mkdtempSync(join(tmpdir(), 'wec-spike-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  ...(headed ? [] : ['--headless=new']),
  '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1', `--user-data-dir=${profile}`,
  '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--mute-audio',
  '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows',
  '--window-size=1920,1080', `http://127.0.0.1:${port}/index.html?fge=sw:0`,
], { stdio: ['ignore', 'ignore', 'pipe'] });

const wsUrl = await new Promise((resolve, reject) => {
  let buf = '';
  chrome.stderr.on('data', (d) => {
    buf += d;
    const m = buf.match(/DevTools listening on (ws:\S+)/);
    if (m) resolve(m[1]);
  });
  setTimeout(() => reject(new Error('Chrome の DevTools の口が出ない')), 20000);
});
const list = await (await fetch(wsUrl.replace('ws://', 'http://').replace(/\/devtools\/browser\/.*/, '/json/list'))).json();
const pageWs = new WebSocket(list.find((t) => t.type === 'page').webSocketDebuggerUrl);
await new Promise((r) => pageWs.addEventListener('open', r));
let id = 0;
const pending = new Map();
const consoleLines = [];
pageWs.addEventListener('message', (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); }
  if (msg.method === 'Runtime.consoleAPICalled') consoleLines.push(msg.params.args.map((a) => a.value ?? a.description).join(' '));
  if (msg.method === 'Runtime.exceptionThrown') consoleLines.push('EXC ' + JSON.stringify(msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text));
});
const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); pageWs.send(JSON.stringify({ id: n, method, params })); });
await send('Runtime.enable');
const evaluate = async (expr) => (await send('Runtime.evaluate', { expression: expr, returnByValue: true })).result.value;

const began = Date.now();
let state = null;
while (Date.now() - began < 120000) {
  await new Promise((r) => setTimeout(r, 1000));
  state = await evaluate('window.__spike && { n: __spike.frames.length, started: __spike.started, total: __spike.submitsTotal, outside: __spike.outsideSubmits }');
  if (state && state.n >= 600) break;
}
const frames = await evaluate('window.__spike ? __spike.frames : []');
const backend = await evaluate('typeof fgeWantWebGpu !== "undefined" ? (fgeWantWebGpu ? "webgpu" : "webgl2") : "?"');
const tail = frames.slice(60);
const ms = tail.map((f) => f.ms).sort((a, b) => a - b);
const pct = (q) => ms.length ? ms[Math.min(ms.length - 1, Math.floor(ms.length * q))] : null;
const summary = {
  backend,
  state,
  frames: frames.length,
  framesAfterWarmup: tail.length,
  withSubmit: tail.filter((f) => f.submits > 0).length,
  withPresent: tail.filter((f) => f.presents > 0).length,
  requeuedInside: tail.filter((f) => f.requeued > 0).length,
  calledPerFrame: [...new Set(tail.map((f) => f.called))],
  submitsPerFrame: [...new Set(tail.map((f) => f.submits))],
  cpuMs: { p50: pct(0.5), p95: pct(0.95), max: ms[ms.length - 1] },
  firstFrames: frames.slice(0, 8),
  console: consoleLines.slice(-15),
};
console.log(JSON.stringify(summary, null, 2));
pageWs.close();
chrome.kill();
server.close();
setTimeout(() => { rmSync(profile, { recursive: true, force: true }); process.exit(0); }, 1500);
