// 書き出した頁の配る大きさ（比べる相手の bundle-size と同じく brotli の quality 11）を出す。
//   node footprint.mjs <書き出したフォルダ…>
// 最初に要る分 = index.html が読む JS と classes.wasm。後で読む分 = 後回しの Worker・Service Worker の JS。素材（glb・絵・音）は数えない（比べる相手も JS だけを数える）。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { brotliCompressSync, constants } from 'node:zlib';

const brotli = (buf) => brotliCompressSync(buf, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: buf.length } }).length;
const LAZY = new Set(['fge-glb-worker.js', 'sw.js', 'fge-sw.js']);

for (const dir of process.argv.slice(2)) {
  const html = readFileSync(join(dir, 'index.html'), 'utf8');
  const inlineScripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');
  const loaded = new Set([...html.matchAll(/<script src="([^"?]+)/g)].map((m) => m[1]));
  const rows = [];
  for (const name of readdirSync(dir)) {
    const file = join(dir, name);
    if (!statSync(file).isFile()) continue;
    if (!(name.endsWith('.js') || name === 'classes.wasm')) continue;
    const buf = readFileSync(file);
    const when = LAZY.has(name) ? 'lazy' : (name === 'classes.wasm' || loaded.has(name) || inlineScripts.includes(name)) ? 'initial' : 'unused';
    rows.push({ name, raw: buf.length, brotli: brotli(buf), when });
  }
  rows.push({ name: '(index.html の中の script)', raw: Buffer.byteLength(inlineScripts), brotli: brotli(Buffer.from(inlineScripts)), when: 'initial' });
  const sum = (w) => rows.filter((r) => r.when === w).reduce((a, r) => a + r.brotli, 0);
  const shipped = existsSync(join(dir, 'classes.wasm.br')) ? statSync(join(dir, 'classes.wasm.br')).size : null;
  console.log(`\n## ${dir}`);
  console.log('| file | raw (B) | brotli q11 (B) | 読む時 |');
  console.log('|---|---:|---:|---|');
  for (const r of rows.sort((a, b) => b.brotli - a.brotli)) console.log(`| ${r.name} | ${r.raw} | ${r.brotli} | ${r.when} |`);
  console.log(`最初に要る分 ${(sum('initial') / 1000).toFixed(1)} KB・後で読む分 ${(sum('lazy') / 1000).toFixed(1)} KB・合計 ${((sum('initial') + sum('lazy')) / 1000).toFixed(1)} KB` +
    (shipped !== null ? `（書き出しが付けた classes.wasm.br は ${shipped} B）` : ''));
}
