// bench.js — fps3d-room の比べる頁の 1 回分（game/index.html の <head> の頭へ差し込む）。
// 起動画面を自分で押し、部屋に入ったコマ（wasm が saves/bench.txt を書く）から数えて決まったコマを測り、
// 結果を sessionStorage の fgeBench へ足して次の回（無ければ ../index.html）へ移る。
// mode=time は測るだけ。mode=count は JS の API の呼び出しと wasm→JS の橋渡しを数える（数える分だけ遅くなるので時間は読まない）。
(function () {
  "use strict";
  var q = new URLSearchParams(location.search);
  var runIndex = parseInt(q.get("brun") || "-1", 10);
  if (runIndex < 0) return;
  var mode = q.get("mode") || "time";
  var warm = parseInt(q.get("warm") || "90", 10);
  var frames = parseInt(q.get("frames") || "960", 10);
  var spin = parseFloat(q.get("spin") || "0.75");
  var fixedYaw = q.get("yaw");
  var counting = mode === "count";

  var state = { roomAt: -1, samples: [], stamps: [], perFrame: [], diag: "", adapter: "", errors: [], done: false };
  window.__benchRun = state;

  // ── 数える仕掛け（count の回だけ）──
  var labels = Object.create(null), calls = Object.create(null), bytes = Object.create(null), bridge = Object.create(null);
  function bump(table, key, n) { table[key] = (table[key] || 0) + n; }
  function sizeOf(v) { return v && typeof v.byteLength === "number" ? v.byteLength : 0; }
  function patchProto(name) {
    var C = window[name];
    if (!C || !C.prototype) return;
    var proto = C.prototype;
    Object.getOwnPropertyNames(proto).forEach(function (m) {
      var d = Object.getOwnPropertyDescriptor(proto, m);
      if (!d || typeof d.value !== "function" || m === "constructor") return;
      var f = d.value, key = name.replace(/RenderingContext$/, "") + "." + m;
      proto[m] = function () {
        calls[key] = (calls[key] || 0) + 1;
        // 作る物と書き先は label ごとにも数える（どこが毎コマ作っているかを見る）。
        if (/^create(BindGroup|Buffer|Texture|View|Sampler|CommandEncoder)$|^beginRenderPass$/.test(m) && arguments[0] && arguments[0].label) bump(labels, key + " " + arguments[0].label, 1);
        else if (m === "writeBuffer" && arguments[0] && arguments[0].label) bump(labels, key + " " + arguments[0].label, 1);
        if (m === "writeBuffer") bump(bytes, key, arguments.length >= 5 && typeof arguments[4] === "number" ? arguments[4] : sizeOf(arguments[2]));
        else if (m === "writeTexture") bump(bytes, key, sizeOf(arguments[1]));
        else if (m === "bufferSubData" || m === "bufferData" || m === "texSubImage2D") bump(bytes, key, sizeOf(arguments[2]) || sizeOf(arguments[arguments.length - 1]));
        return f.apply(this, arguments);
      };
    });
  }
  if (counting) {
    ["GPUDevice", "GPUQueue", "GPUCommandEncoder", "GPURenderPassEncoder", "GPUComputePassEncoder", "GPUTexture", "GPUBuffer",
     "GPUCanvasContext", "WebGL2RenderingContext"].forEach(patchProto);
    var instantiate = WebAssembly.instantiate;
    WebAssembly.instantiate = function (module, imports) {
      if (imports && module instanceof WebAssembly.Module) {
        Object.keys(imports).forEach(function (ns) {
          // WhyNot: wasm:js-string を包まない — 文字の組み込みとして読まれる名前空間で、包むと組み込みの扱いが外れる。
          if (ns === "wasm:js-string") return;
          var o = imports[ns], w = {};
          Object.getOwnPropertyNames(o).forEach(function (k) {
            var f = o[k];
            if (typeof f !== "function") { w[k] = f; return; }
            var key = ns + "." + k.replace(/[0-9]+$/, "");
            w[k] = function () { bridge[key] = (bridge[key] || 0) + 1; return f.apply(this, arguments); };
          });
          imports[ns] = w;
        });
      }
      return instantiate.apply(this, arguments);
    };
  }
  function snapshot() {
    var all = {};
    [["call", calls], ["bytes", bytes], ["bridge", bridge], ["label", labels]].forEach(function (p) {
      Object.keys(p[1]).forEach(function (k) { all[p[0] + ":" + k] = p[1][k]; });
    });
    return all;
  }

  // ── 部屋に入ったコマと診断の行（wasm の saves/bench.txt）──
  var setItem = Storage.prototype.setItem;
  Storage.prototype.setItem = function (key, value) {
    if (typeof key === "string" && /bench\.txt$/.test(key) && typeof value === "string" && value.indexOf("room") === 0) {
      if (state.roomAt < 0) state.roomAt = state.samples.length;
      if (value.length > 5) state.diag = value.slice(5);
    }
    return setItem.apply(this, arguments);
  };
  var log = console.log;
  console.log = function (line) {
    if (typeof line === "string" && line.indexOf("[backend] ") === 0) state.adapter = line.slice(10);
    return log.apply(console, arguments);
  };
  window.addEventListener("error", function (e) { state.errors.push(String(e.message || e)); });

  // ── 1 コマの値（fge-web.js の fgeStats.cpu を包む）──
  var counted = null;
  function hook() {
    if (!window.fgeStats || window.fgeStats.__bench) return !!(window.fgeStats);
    var cpu = window.fgeStats.cpu;
    window.fgeStats.cpu = function (ms) {
      state.samples.push(ms);
      state.stamps.push(performance.now());
      if (counting) {
        var now = snapshot(), d = {};
        if (counted) Object.keys(now).forEach(function (k) { var v = now[k] - (counted[k] || 0); if (v) d[k] = v; });
        state.perFrame.push(d);
        counted = now;
      }
      tick();
      return cpu.apply(this, arguments);
    };
    window.fgeStats.__bench = true;
    return true;
  }
  var poll = setInterval(function () {
    hook();
    var start = document.getElementById("fge-start");
    // 起動画面の「押して始める」が出たら、こちらで押す（音は起きないが測る物には要らない）。
    if (start && start.style.display !== "none" && window.fgeSplash && window.fgeSplash.ready && !window.fgeSplash.tapped) {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter" }));
    }
    if (state.done) clearInterval(poll);
  }, 100);

  function stats(values) {
    if (values.length === 0) return { n: 0 };
    var s = values.slice().sort(function (a, b) { return a - b; });
    var at = function (p) { return s[Math.min(s.length - 1, Math.floor(p * s.length))]; };
    var sum = values.reduce(function (a, b) { return a + b; }, 0);
    return { n: values.length, mean: +(sum / values.length).toFixed(2), median: +at(0.5).toFixed(2), p95: +at(0.95).toFixed(2) };
  }

  function tick() {
    if (state.done || state.roomAt < 0) return;
    var from = state.roomAt + warm, to = from + frames;
    if (state.samples.length < to) return;
    state.done = true;
    var cpu = state.samples.slice(from, to);
    var span = state.stamps[to - 1] - state.stamps[from];
    var bins = [];
    for (var b = 0; b < 8; b++) bins.push([]);
    for (var i = from; i < to; i++) {
      var k = i - state.roomAt;
      var deg = fixedYaw !== null ? 0 : ((k * spin) % 360 + 360) % 360;
      bins[Math.floor(deg / 45) % 8].push(state.samples[i]);
    }
    var r = {
      run: runIndex, build: location.pathname.split("/").slice(-2)[0], backend: q.get("backend") === "webgpu" ? "webgpu" : "webgl2", mode: mode,
      knobs: location.search, adapter: state.adapter, frames: frames, warm: warm,
      fps: +((frames - 1) * 1000 / span).toFixed(1), cpu: stats(cpu),
      bins: bins.map(function (v) { return stats(v).median || null; }),
      canvas: (function () { var c = document.getElementById("fge-canvas"); return c ? c.width + "x" + c.height : ""; })(),
      dpr: window.devicePixelRatio || 1, ua: navigator.userAgent, errors: state.errors, diag: state.diag
    };
    if (counting) {
      var sum = {};
      state.perFrame.slice(from, to).forEach(function (d) { Object.keys(d).forEach(function (k) { sum[k] = (sum[k] || 0) + d[k]; }); });
      var per = {};
      Object.keys(sum).sort(function (a, b) { return sum[b] - sum[a]; }).forEach(function (k) { per[k] = +(sum[k] / frames).toFixed(1); });
      r.perFrame = per;
    }
    try {
      var all = JSON.parse(sessionStorage.getItem("fgeBench") || "[]");
      all.push(r);
      sessionStorage.setItem("fgeBench", JSON.stringify(all));
    } catch (e) { state.errors.push(String(e)); }
    var next = q.get("bnext");
    // WhyNot: すぐに移らない — 移る前のコマの submit が終わる前に頁を捨てると、次の頁の起動に前の頁の GPU の後始末が乗る。
    setTimeout(function () { location.replace(next ? decodeURIComponent(next) : "../index.html?done=1"); }, 300);
  }
})();
