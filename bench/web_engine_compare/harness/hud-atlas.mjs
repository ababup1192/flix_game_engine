// K9 の icon の atlas（比べる相手が canvas に描く 8×8 マス × 32 px）を、比べる相手の buildScene に描かせて PNG に書く。
//   node harness/hud-atlas.mjs <比べる相手のリポ> <出す PNG>   （make compare-assets）
// 比べる相手の vite の dev サーバーで scenes.ts を読む頁を開き、ヘッドレスの Chrome の canvas の PNG を受け取る。サーバーと Chrome はこの中で止める。
// WhyNot: 描き方を Flix や自前の JS に写さない — 比べる相手のリポに LICENSE が無く、コードを写せない。字の形も Chrome の sans-serif に任せる。
import { writeFileSync, mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

const repo = resolve(process.argv[2]);
const out = resolve(process.argv[3]);
const page = 'wec-hud-atlas.html';
writeFileSync(join(repo, page), `<!doctype html><script type="module">
import { buildScene } from '/src/harness/scenes.ts';
window.__atlas = buildScene('k9', 250, null).hud.atlas.canvas.toDataURL('image/png');
</script>`);

const port = 5199;
const vite = spawn(process.execPath, [join(repo, 'node_modules/vite/bin/vite.js'), '--port', String(port), '--strictPort'], { cwd: repo, stdio: 'ignore' });
let up = false;
for (let k = 0; k < 60 && !up; k++) {
  await new Promise((r) => setTimeout(r, 500));
  up = await fetch(`http://localhost:${port}/${page}`).then((r) => r.ok, () => false);
}
if (!up) { vite.kill(); rmSync(join(repo, page), { force: true }); throw new Error('vite が起きない'); }

const profile = mkdtempSync(join(tmpdir(), 'wec-atlas-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1', `--user-data-dir=${profile}`,
  '--no-first-run', '--no-default-browser-check', '--disable-extensions', `http://localhost:${port}/${page}`,
], { stdio: ['ignore', 'ignore', 'pipe'] });

const stop = (code) => {
  chrome.kill();
  vite.kill();
  rmSync(join(repo, page), { force: true });
  setTimeout(() => { rmSync(profile, { recursive: true, force: true }); process.exit(code); }, 1000);
};

try {
  const wsUrl = await new Promise((resolveWs, reject) => {
    let buf = '';
    chrome.stderr.on('data', (d) => {
      buf += d;
      const m = buf.match(/DevTools listening on (ws:\S+)/);
      if (m) resolveWs(m[1]);
    });
    setTimeout(() => reject(new Error('Chrome の DevTools の口が出ない')), 20000);
  });
  const list = await (await fetch(wsUrl.replace('ws://', 'http://').replace(/\/devtools\/browser\/.*/, '/json/list'))).json();
  const ws = new WebSocket(list.find((t) => t.type === 'page').webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r));
  let id = 0;
  const pending = new Map();
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); }
  });
  const evaluate = (expression) => new Promise((r) => {
    const n = ++id;
    pending.set(n, (res) => r(res?.result?.value));
    ws.send(JSON.stringify({ id: n, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
  });
  let url = null;
  for (let k = 0; k < 60 && !url; k++) {
    await new Promise((r) => setTimeout(r, 500));
    url = await evaluate('window.__atlas ?? null');
  }
  if (!url) throw new Error('atlas の PNG が出ない');
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, Buffer.from(url.slice(url.indexOf(',') + 1), 'base64'));
  console.log(`[hud-atlas] ${out}`);
  ws.close();
  stop(0);
} catch (e) {
  console.error(`[hud-atlas] ${e.message}`);
  stop(1);
}
