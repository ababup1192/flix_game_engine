// bench-overlay.js — ベンチのブラウザ版の頁に足す script（make bench-web-export が index.html へ差し込む）。
// wasm が console へ出す `[bench] begin` / `[bench] result {…}` / `[bench] done`（bench/common/BenchRun.flix）を拾い、
// 結果を頁の上に字で出し、window.__bench に置く（人がスマホで読む・bin/fge web-bench が機械で取る）。
// 1 コマの CPU の時間（cpu_*）は fge-web.js の fgeStats から取る（wasm が rAF から戻ってから次に待つまで）。
// WhyNot: 1 コマの間隔（frame_*）だけで比べない — ブラウザは rAF に合わせて待つので、軽い場面では画面の周期（16.7 ms など）に張り付く。
(function () {
  "use strict";
  var bench = window.__bench = {
    done: false, measuring: false, results: [], query: location.search,
    env: { userAgent: navigator.userAgent, devicePixelRatio: window.devicePixelRatio || 1, renderer: "", canvas: "" }
  };

  try {
    var gl = document.createElement("canvas").getContext("webgl2");
    var info = gl && gl.getExtension("WEBGL_debug_renderer_info");
    bench.env.renderer = gl ? String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER)) : "WebGL2 なし";
  } catch (e) { bench.env.renderer = "不明"; }

  var box = document.createElement("div");
  box.style.cssText = "position:fixed;left:0;right:0;top:env(safe-area-inset-top,0px);z-index:9999;max-height:70vh;overflow:auto;" +
    "margin:0;padding:6px 8px;font:12px/1.45 ui-monospace,Menlo,Consolas,monospace;color:#fff;background:rgba(0,0,0,.72);" +
    "white-space:pre-wrap;word-break:break-all;-webkit-user-select:text;user-select:text;touch-action:pan-y";
  var text = document.createElement("div");
  var copy = document.createElement("button");
  copy.type = "button";
  copy.textContent = "JSON をコピー";
  copy.style.cssText = "font:inherit;margin-top:4px;padding:4px 10px";
  copy.addEventListener("click", function () {
    var json = JSON.stringify(bench);
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(json).then(function () { copy.textContent = "コピーした"; }, function () { copy.textContent = "コピーできない"; });
    } else copy.textContent = "コピーできない";
  });
  box.appendChild(text);
  box.appendChild(copy);

  // 結果の行のうち、つまみとして頭に出さない鍵（集計の値）。
  var metricKeys = { frames: 1, frame_avg: 1, frame_p50: 1, frame_p95: 1, frame_p99: 1, work_p50: 1, work_p95: 1, submit_p50: 1, submit_p95: 1,
    swap_p50: 1, gpu_p50: 1, gpu_frames: 1, draw_items: 1, instances: 1, drawn: 1, draw_calls: 1, cpu_phases: 1,
    draw2d_calls: 1, draw2d_breaks: 1, draw3d_breaks: 1,
    cpu_frames: 1, cpu_mean: 1, cpu_p50: 1, cpu_p95: 1, raf_lag_p50: 1 };

  function resultLine(r) {
    // WhyNot: 門の結果（bench/webgpu_check の頁）に測りの欄を並べない — 測った値を持たず、undefined が並ぶだけになる。
    if (typeof r.ok === "boolean") return (r.ok ? "OK " : "NG ") + r.name + "\n  " + r.detail;
    var knobs = Object.keys(r).filter(function (k) { return !metricKeys[k] && k !== "bench"; })
      .map(function (k) { return k + "=" + r[k]; }).join(" ");
    var line = knobs + "\n  cpu p50 " + r.cpu_p50 + " / p95 " + r.cpu_p95 + " ms   frame p50 " + r.frame_p50 + " / p95 " + r.frame_p95 +
      " ms   submit p50 " + r.submit_p50 + " ms";
    if (r.work_p50 > 0) line += "   work p50 " + r.work_p50 + " ms";
    line += r.draw_calls > 0 ? "\n  3D draw " + r.draw_calls + "（物 " + r.drawn + "/" + r.instances + "）" : "\n  2D の物 " + r.draw_items;
    var phases = Object.keys(r.cpu_phases || {}).map(function (k) { return k + " " + r.cpu_phases[k]; }).join(" / ");
    if (phases && r.draw_calls > 0) line += "   " + phases;
    if (r.draw_calls > 0) line += "\n  3D の draw が分かれた理由 " + breaksText(r.draw3d_breaks);
    if (r.draw2d_calls > 0) line += "\n  2D draw " + r.draw2d_calls + "（切れた理由 " + breaksText(r.draw2d_breaks) + "）";
    return line;
  }

  // 理由ごとの数（draw2d_breaks・draw3d_breaks）を 1 行に。古い engine の結果には欄が無い。
  function breaksText(breaks) {
    var names = Object.keys(breaks || {});
    return names.length === 0 ? "-" : names.map(function (k) { return k + " " + breaks[k]; }).join(" / ");
  }

  function render() {
    var canvas = document.getElementById("fge-canvas");
    if (canvas) bench.env.canvas = canvas.width + "x" + canvas.height;
    var name = bench.results.length > 0 ? (bench.results[0].bench || bench.results[0].name) : "bench";
    var state = bench.done ? "終わり" : (bench.measuring ? "測っている（区間 " + (bench.results.length + 1) + "）" : "温めている");
    text.textContent = name + " " + location.search + " — " + state + "\n" + bench.env.renderer + " / canvas " + bench.env.canvas +
      " / dpr " + bench.env.devicePixelRatio + "\n" + bench.results.map(resultLine).join("\n");
    if (!box.parentNode && document.body) document.body.appendChild(box);
  }

  function handle(line) {
    if (line === "begin") {
      if (window.fgeStats) window.fgeStats.reset();
      bench.measuring = true;
    } else if (line === "done") {
      bench.done = true;
    } else if (line.indexOf("result ") === 0) {
      var r = JSON.parse(line.slice(7));
      var stats = window.fgeStats ? window.fgeStats.summary() : null;
      if (stats) {
        r.cpu_frames = stats.cpu.frames; r.cpu_mean = stats.cpu.mean; r.cpu_p50 = stats.cpu.median; r.cpu_p95 = stats.cpu.p95;
        r.raf_lag_p50 = stats.lag.median;
      }
      bench.results.push(r);
      bench.measuring = false;
    }
    render();
  }

  var log = console.log;
  console.log = function (line) {
    if (typeof line === "string" && line.indexOf("[bench] ") === 0) {
      try { handle(line.slice(8)); } catch (e) { bench.error = String(e && e.message || e); }
    }
    // 頁が描き手を名乗った行（"[backend] webgpu: <adapter>"）。env.renderer は overlay が自分で取った WebGL2 の名前なので、WebGPU で描いたかはこちらで見る。
    if (typeof line === "string" && line.indexOf("[backend] ") === 0) bench.env.backend = line.slice(10);
    return log.apply(console, arguments);
  };
})();
