// 比べる相手の harness の adapter（EngineAdapter）。engine のブラウザ版の書き出し（public/flix/）を harness の頁に載せる。
// make web-engine-compare が build/upstream/src/engines/flix/index.ts へ写す。engine は書き換えない（計画の X1 案 c）:
//   - engine の wasm のループは rAF を待って止まる作りなので、rAF を包んで engine の callback を溜め、frame() の中で呼ぶ。
//     呼ぶと同じ JS の呼び出しの中でループが再開し、更新・描き・submit・次の待ちまで進んで戻る（S0.5 で確かめた）。
//   - 場面の時刻は頁の fgeQueryPairs を包んで渡し、場面の更新の ms は console の 1 行（[wec] sim <ms>）で受ける。
import type { EngineAdapter, InitOptions, InitReport, LoadReport, SceneData, Variant } from '../../harness/types';

const BASE = '/flix/';
const SIM_LINE = '[wec] sim ';
const PICK_LINE = '[wec] pick ';
/** pick の答えを待つコマ数の上限。 */
const PICK_FRAMES = 4;
/** engine が置き方を勧める行の頭（数えて counters の hints に出す）。 */
const HINT_PREFIXES = ['scene3d: 置いた物が', 'scene3d: 場面の draw call が', '[scene3d] staticGroup の名前か値が'];
/** load の中で回すコマ数（pipeline と形の初めての上げを済ませる）。 */
const LOAD_FRAMES = 60;
/** 起動（wasm の compile と main）を待つ上限。 */
const BOOT_TIMEOUT_MS = 60000;

declare global {
  interface Window {
    fgeDev?: Record<string, unknown>;
    fgeQueryPairs?: () => string[];
    fgeWantWebGpu?: boolean;
  }
}

export function createAdapter(): EngineAdapter {
  return new FlixAdapter();
}

class FlixAdapter implements EngineAdapter {
  readonly name = 'flix';
  readonly version = 'flix_game_engine';
  private queue: FrameRequestCallback[] = [];
  private capturing = true;
  private clock = 0;
  private sceneTime = 0;
  private simMs = 0;
  private presented = 0;
  private backend: 'webgpu' | 'webgl2' = 'webgpu';
  private pairs: (() => string[]) | null = null;
  private patched = false;
  private hints = 0;
  private pickSeq = 0;
  private pickReq: { seq: number; x: number; y: number } | null = null;
  private pickAnswer: { seq: number; slot: number; ms: number } | null = null;
  private pickMs: number | null = null;

  async init(canvas: HTMLCanvasElement, opts: InitOptions): Promise<InitReport> {
    this.backend = opts.backend;
    this.wrapPage();
    window.fgeDev = { backend: opts.backend === 'webgl2' ? 'webgl2' : 'webgpu', sw: false };
    canvas.id = 'fge-canvas';
    const page = await (await fetch(`${BASE}index.html`, { cache: 'no-store' })).text();
    const base = document.createElement('base');
    base.href = BASE;
    document.head.prepend(base);
    this.mountShell(page);
    await this.runFrames(1, BOOT_TIMEOUT_MS, true);
    base.remove();
    const onWebGpu = window.fgeWantWebGpu !== false;
    return { backend: onWebGpu ? 'webgpu' : 'webgl2', msaa: 4, notes: ['PostStack の MSAA 4×・ACES は AcesNarkowicz（画面の値に掛ける）で代用'] };
  }

  async load(_scene: SceneData, variant: Variant, opt?: string): Promise<LoadReport> {
    if (opt) throw new Error(`N/A: optimized の候補 ${opt} は無い`);
    const scenario = new URLSearchParams(location.search).get('scenario');
    if (variant === 'optimized' && scenario === 'k8') throw new Error('N/A (as naive): engine の pick の口は Ray3d（1 つずつ当てる）だけ');
    await this.runFrames(LOAD_FRAMES, BOOT_TIMEOUT_MS, false);
    this.capturing = false;
    this.simMs = 0;
    return { path: pathOf(scenario, variant), notes: ['場面は Flix の側で同じ乱数から作る（bench/web_engine_compare/src/Scenes.flix）'] };
  }

  frame(t: number, _dt: number) {
    this.sceneTime = t;
    this.pump();
  }

  /** 直前のコマの、Flix の側の場面の更新の ms（harness が CPU 時間から差し引いて sim に足す）。 */
  takeSimMs() {
    const ms = this.simMs;
    this.simMs = 0;
    return ms;
  }

  /**
   * K8: canvas の画素の下の物の場面の slot の番号（無ければ -1）。頼みを fgeQueryPairs に載せて engine の 1 コマを回し、Flix の側の答えを console の 1 行で受ける。
   */
  pick(x: number, y: number) {
    this.pickSeq++;
    this.pickReq = { seq: this.pickSeq, x, y };
    for (let k = 0; k < PICK_FRAMES && this.pickAnswer?.seq !== this.pickSeq; k++) this.pump();
    const answer = this.pickAnswer?.seq === this.pickSeq ? this.pickAnswer : null;
    this.pickMs = answer ? answer.ms : null;
    return answer ? answer.slot : -1;
  }

  /** 直前の pick の、Flix の側でレイを当てた ms（harness が pick の時間にこちらを使う。描くコマの時間を含めない）。 */
  takePickMs() {
    const ms = this.pickMs;
    this.pickMs = null;
    return ms;
  }

  counters() {
    return { hints: this.hints };
  }

  async dispose() {}

  /** 溜まった engine の callback を全部呼ぶ。呼ぶ時刻はコマの番号 × 16.67 ms の単調な時計（harness の t は 1 周で 0 に戻るので渡さない）。 */
  private pump() {
    this.patchGlobals();
    const batch = this.queue.splice(0, this.queue.length);
    this.clock += 1000 / 60;
    const wasCapturing = this.capturing;
    this.capturing = true;
    for (const cb of batch) cb(this.clock);
    this.capturing = wasCapturing;
  }

  /** engine が n コマ出すまで、本物の rAF の上で pump を回す。tap = 押して始める画面を keydown で通す。 */
  private runFrames(n: number, timeoutMs: number, tap: boolean) {
    const goal = this.presented + n;
    const began = performance.now();
    return new Promise<void>((resolve, reject) => {
      const step = () => {
        if (this.presented >= goal) return resolve();
        if (performance.now() - began > timeoutMs) return reject(new Error(`engine が ${n} コマを出さない（${timeoutMs} ms）`));
        if (tap && this.presented === 0) window.dispatchEvent(new KeyboardEvent('keydown', { code: 'Space', key: ' ' }));
        this.pump();
        realRaf(step);
      };
      realRaf(step);
    });
  }

  /**
   * fge-web.js が置く大域の関数を包む（読み終えた後に 1 回）。fgeFramePresented = engine が 1 コマを画面へ出した・fgeQueryPairs = 場面の時刻を足して返す。
   */
  // WhyNot: fge-web.js を読む前に defineProperty で包まない — 大域の function 宣言が後から上書きする。
  private patchGlobals() {
    const w = window as any;
    if (this.patched || typeof w.fgeFramePresented !== 'function' || typeof w.fgeQueryPairs !== 'function') return;
    this.patched = true;
    const presented = w.fgeFramePresented;
    w.fgeFramePresented = () => { this.presented++; presented(); };
    if (this.pairs) w.fgeQueryPairs = this.pairs;
  }

  private wrapPage() {
    const self = this;
    // engine の wasm が await（材質の WGSL の getCompilationInfo など）から pump の外で戻って次のコマを待つ時も溜める。
    // WhyNot: pump の外の予約を全部 harness の物として本物の rAF へ渡さない — 1 回でも外で戻ると engine が本物の rAF で回り続け、frame() の中で 1 コマも回らなくなる（K3 の初めての絵の材質で起きた）。
    window.requestAnimationFrame = (cb: FrameRequestCallback) => {
      if (!self.capturing && !calledFromWasm()) return realRaf(cb);
      self.queue.push(cb);
      return self.queue.length;
    };
    const log = console.log.bind(console);
    console.log = (...args: unknown[]) => {
      const first = args[0];
      if (typeof first === 'string' && first.startsWith(PICK_LINE)) {
        const [seq, slot, ms] = first.slice(PICK_LINE.length).split(' ').map(Number);
        self.pickAnswer = { seq, slot, ms };
        return;
      }
      if (typeof first === 'string' && first.startsWith(SIM_LINE)) {
        self.simMs += Number(first.slice(SIM_LINE.length)) || 0;
        return;
      }
      log(...args);
    };
    // WhyNot: engine が置き方を勧める 1 行を consoleErrors のままにしない — 誤りではなく助言で、report の誤りの数に混ざる。
    const error = console.error.bind(console);
    console.error = (...args: unknown[]) => {
      const first = args[0];
      if (typeof first === 'string' && HINT_PREFIXES.some((p) => first.startsWith(p))) {
        self.hints++;
        return;
      }
      error(...args);
    };
  }

  /** 書き出しの頁の body の部品（起動の画面・誤りの欄など。canvas は harness の物を使う）と頭の script を載せる。 */
  private mountShell(page: string) {
    const doc = new DOMParser().parseFromString(page, 'text/html');
    const shell = document.createElement('div');
    shell.style.display = 'none';
    for (const el of Array.from(doc.body.children)) {
      if (el.tagName === 'SCRIPT' || el.id === 'fge-canvas') continue;
      shell.appendChild(document.importNode(el, true));
    }
    document.body.appendChild(shell);
    const self = this;
    const pairs = () => {
      const out: string[] = [];
      new URLSearchParams(location.search).forEach((v, k) => out.push(k, v));
      out.push('harness_t', String(self.sceneTime));
      if (self.pickReq) out.push('pick_seq', String(self.pickReq.seq), 'pick_x', String(self.pickReq.x), 'pick_y', String(self.pickReq.y));
      return out;
    };
    for (const s of Array.from(doc.querySelectorAll('script'))) {
      const el = document.createElement('script');
      if (s.src) el.src = s.getAttribute('src')!;
      else el.textContent = s.textContent;
      el.async = false;
      document.body.appendChild(el);
    }
    this.pairs = pairs;
  }
}

/** 物の置き方の名前（report の path）。 */
function pathOf(scenario: string | null, variant: Variant) {
  if (scenario === 'k5') return variant === 'optimized' ? '区画ごとの Scene3d.staticGroup（起動の時に先に作る）・見える区画をゲームの側で選ぶ' : 'Scene3d.meshInstance per object（物の列は読み込みで 1 回作る）';
  if (variant === 'optimized') return 'MultiMesh3d.build per (geometry, material)・毎コマ組み直す';
  if (scenario === 'k3') return 'Scene3d.meshInstance per object・作り直した組は Texture3d.fromArgb（128×128）＋ texturedMaterial と withMetallicRoughness と tint';
  return 'Scene3d.meshInstance per object（同じ形と材質は engine が自動でまとめる）';
}

/** 呼び手の stack に wasm の関数があるか（engine の予約か、harness の予約か）。 */
function calledFromWasm() {
  return (new Error().stack ?? '').includes('wasm://');
}

const realRaf: (cb: FrameRequestCallback) => number = window.requestAnimationFrame.bind(window);
