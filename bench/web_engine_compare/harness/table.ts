// 比べる相手の report（build/upstream/report/out/data.json）から、README の表と同じ行の数字を Markdown の表にする。
//   npx tsx ../../harness/table.ts [backend]   （build/upstream で流す。既定 webgpu）
// 数の場面は「60 fps に収まる最大」（≥ は最後まで超えなかった）・時間の場面は frame cost の ms・K3 は frame cost / CPU の最悪のコマ・K8 は 1 回の pick の ms。
import { readFileSync } from 'node:fs';

const backend = process.argv[2] ?? 'webgpu';
const d = JSON.parse(readFileSync('report/out/data.json', 'utf8'));
const engines: string[] = Object.keys(d.engines).filter((e: string) => d.cells.some((c: any) => c.engine === e && c.backend === backend));

const cell = (e: string, s: string, v: string, l: number) => d.cells.find((c: any) => c.engine === e && c.backend === backend && c.scenario === s && c.variant === v && c.level === l);
const ladder = (e: string, s: string, v: string) => d.ladders.find((x: any) => x.engine === e && x.backend === backend && x.scenario === s && x.variant === v);
const ms = (x: number | undefined | null) => (x == null || !Number.isFinite(x) ? '—' : x < 10 ? x.toFixed(1) : x.toFixed(0));
const count = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : String(Math.round(n)));
const na = (c: any) => (c && c.status !== 'ok' ? (String(c.error ?? c.status).startsWith('N/A') ? 'n/a' : c.status) : null);

function capacity(e: string, s: string, v: string) {
  const l = ladder(e, s, v);
  if (!l || l.maxAt60 == null) return '—';
  return (l.bound === "beyond" ? '≥ ' : '') + count(l.maxAt60);
}
function best(e: string, s: string) {
  const a = ladder(e, s, 'naive'), b = ladder(e, s, 'optimized');
  const pick = [a, b].filter((x) => x && x.maxAt60 != null).sort((x, y) => y.maxAt60 - x.maxAt60)[0];
  return pick ? (pick.bound === "beyond" ? '≥ ' : '') + count(pick.maxAt60) : '—';
}
function cost(e: string, s: string, v: string, l: number) {
  const c = cell(e, s, v, l);
  return na(c) ?? ms(c?.frameCost?.med);
}

const rows: [string, (e: string) => string][] = [
  ['K1 TTFF（Sponza・K4 段 0）ms', (e) => ms(cell(e, 'k4', 'naive', 0)?.timings?.ttff?.med)],
  ['K1 frame cost ms', (e) => cost(e, 'k1', 'naive', 1)],
  ['K2 動く物 scene graph（naive）', (e) => capacity(e, 'k2', 'naive')],
  ['K2 動く物 良い方（naive / optimized）', (e) => best(e, 'k2')],
  ['K3 churn frame cost / CPU 最悪 ms', (e) => { const c = cell(e, 'k3', 'naive', 2000); return na(c) ?? `${ms(c?.frameCost?.med)} / ${ms(c?.long?.cpuMax?.med)}`; }],
  ['K4 段 0（素）ms', (e) => cost(e, 'k4', 'naive', 0)],
  ['K4 段 3（影＋31 灯＋bloom）ms', (e) => cost(e, 'k4', 'naive', 3)],
  ['K4 段 4（256 灯）ms', (e) => cost(e, 'k4', 'naive', 4)],
  ['K5 10 万 既定 ms', (e) => cost(e, 'k5', 'naive', 100000)],
  ['K5 10 万 optimized ms', (e) => cost(e, 'k5', 'optimized', 100000)],
  ['K6 crossfade（naive）', (e) => capacity(e, 'k6', 'naive')],
  ['K6 1 clip（optimized）', (e) => capacity(e, 'k6', 'optimized')],
  ['K7 半透明', (e) => capacity(e, 'k7', 'naive')],
  ['K7 compute 1M ms', (e) => cost(e, 'k7c', 'naive', 1000000)],
  ['K8 1 万の中の pick ms', (e) => { const c = cell(e, 'k8', 'naive', 10000); return na(c) ?? ms(c?.pick?.p50?.med); }],
  ['K8 1M 三角形の pick ms', (e) => { const c = cell(e, 'k8', 'naive', 1); return na(c) ?? ms(c?.pick?.p50?.med); }],
  ['K9 名札 良い方', (e) => best(e, 'k9')],
];

const b = d.browsers[0];
console.log(`測った日 ${b.startedAt.slice(0, 10)}・機械 ${d.machine.description}・${b.name} ${b.version}（${backend}）・profile ${b.profile}・session ${b.session}\n`);
console.log(`| 場面 | ${engines.join(' | ')} |`);
console.log(`|---|${engines.map(() => '---:').join('|')}|`);
for (const [label, f] of rows) console.log(`| ${label} | ${engines.map(f).join(' | ')} |`);
