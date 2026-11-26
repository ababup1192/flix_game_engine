// fge-glb-worker.js — 後から届く glb を解く Web Worker（頁の fge-web.js が起こす）。
// ゲームと同じ wasm を起こして exports.main を呼び、WebLayer の入口が頼みを待つ輪（WebLayer.Internal.GlbWorker.serve）へ入る。
// 頁から { type: "init" } で wasm の道を受け、{ type: "parse" } の頼みを 1 本ずつ wasm に渡し、解いた並びと使う絵の ImageBitmap を transfer で返す。
// WhyNot: 頁から wasm の Module を渡さない — 頁の起動の道（fgeLoadWasm）が TeaVM に道を渡してコンパイルさせる形を変えることになり、
//   URL に紐づくコンパイル済みのコードの持ち越しが効かなくなる。Worker は同じ道を取ってブラウザの持ち越しを使う。
"use strict";

var fgeGlbWorkerScope = true;
var fgeGlbWorkerQueue = [];
var fgeGlbWorkerWaiter = null;
var fgeGlbWorkerRequest = null;
var fgeGlbWorkerResult = null;

// ゲームの WebMain が run の前に呼びうる頁の口（Worker には頁の fge-web.js が無い）。
// WhyNot: 代わりの無い口を黙って空にしない — 呼ばれたら ReferenceError で main が落ち、頁はこの Worker を使わずにメインで読む。
function fgeQueryPairs() { return []; }
var fgeCaptureFrame = 0;
var fgeSwitches = { webgpuFail: "" };
var fgeUsedAssets = null;
var fgeNet4g = false;
function fgeNoteUsed() { }

// WhyNot: 知らせを Worker の console に出したままにしない — 頁の ?fge=errors に載らず、コンソールを開けないスマホで見えない（頁が [glb-worker] を頭に付けて出す）。
["warn", "error"].forEach(function (level) {
  var plain = console[level].bind(console);
  console[level] = function () {
    var text = Array.prototype.map.call(arguments, function (a) { return a && a.stack ? a.stack : String(a); }).join(" ");
    try { self.postMessage({ type: "log", level: level, text: text }); } catch (e) { plain(text); }
  };
});

var fgeGlbWorkerServing = false;
function fgeGlbWorkerNext(done) {
  if (!fgeGlbWorkerServing) { fgeGlbWorkerServing = true; self.postMessage({ type: "ready" }); }
  fgeGlbWorkerRequest = null;
  if (fgeGlbWorkerQueue.length > 0) {
    fgeGlbWorkerBegin(fgeGlbWorkerQueue.shift());
    Promise.resolve().then(done);
  } else {
    fgeGlbWorkerWaiter = done;
  }
}

function fgeGlbWorkerBegin(req) {
  fgeGlbWorkerRequest = req;
  fgeGlbWorkerResult = { strings: [], ints: null, floats: null, f64s: [], i32s: [], images: [] };
}

// 解き終えた並びを送る。使う絵は ImageBitmap にして一緒に送る（解けない絵は飛ばし、wasm が読む時に解く）。
function fgeGlbWorkerFinish() {
  var req = fgeGlbWorkerRequest;
  var r = fgeGlbWorkerResult;
  var bytes = new Uint8Array(req.bytes.buffer, req.bytes.byteOffset, req.bytes.byteLength);
  var bitmaps = r.images.map(function (image) {
    var part = bytes.subarray(image[1], image[1] + image[2]);
    return createImageBitmap(new Blob([part], { type: fgeGlbImageType(part) }), { premultiplyAlpha: "none", colorSpaceConversion: "none" })
      .then(function (bitmap) { return { index: image[0], bitmap: bitmap }; }, function () { return null; });
  });
  var f64 = fgeGlbJoin(r.f64s, Float64Array);
  var i32 = fgeGlbJoin(r.i32s, Int32Array);
  var strLens = new Int32Array(r.strings.map(function (s) { return s.length; }));
  var msg = { type: "parsed", id: req.id, text: r.strings.join(""), strLens: strLens, ints: r.ints, floats: r.floats,
              f64: f64.all, f64Lens: f64.lens, i32: i32.all, i32Lens: i32.lens, images: [] };
  Promise.all(bitmaps).then(function (got) {
    msg.images = got.filter(function (g) { return g !== null; });
    var transfer = [msg.strLens.buffer, msg.ints.buffer, msg.floats.buffer, msg.f64.buffer, msg.f64Lens.buffer, msg.i32.buffer, msg.i32Lens.buffer]
      .concat(msg.images.map(function (g) { return g.bitmap; }));
    self.postMessage(msg, transfer);
  }).catch(function (err) {
    // WhyNot: 失敗を投げたままにしない — Promise の外へ出ず頁の onerror に届かないので、頁は 30 秒待ってからメインで読み直す。
    self.postMessage({ type: "failed", id: req.id, why: String(err && err.message || err) });
  });
}

// 配列の並びを 1 本につなぎ、長さの並びを添える（頁の wasm が JS から写す回数を配列の数によらず 1 回にする）。
// WhyNot: 配列を 1 本ずつ wasm へ写さない — 束 1 つで配列が 1,000 本を超え、JS と wasm をまたぐ呼び出しの手間が写す量より重くなる。
function fgeGlbJoin(arrays, Kind) {
  var lens = new Int32Array(arrays.length);
  var total = 0;
  arrays.forEach(function (a, i) { lens[i] = a.length; total += a.length; });
  var all = new Kind(total);
  var at = 0;
  arrays.forEach(function (a) { all.set(a, at); at += a.length; });
  return { all: all, lens: lens };
}

function fgeGlbWorkerFail(why) {
  self.postMessage({ type: "failed", id: fgeGlbWorkerRequest.id, why: String(why) });
}

function fgeGlbImageType(bytes) {
  return bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 ? "image/png"
       : bytes.length >= 4 && bytes[0] === 0x52 && bytes[1] === 0x49 ? "image/webp" : "image/jpeg";
}

// wasm を取って起こし、main を呼ぶ（WebLayer の入口で頼みを待つ輪へ入り、ここへ手が戻る）。
// brotli の道は頁と同じく .br を取って解く（頁が先に取っているので HTTP のキャッシュか Service Worker から来る）。
function fgeGlbWorkerBoot(init) {
  importScripts(init.runtimeUrl);
  var load;
  // WhyNot: brotli の道で落ちた時に止めない — 頁の fgeLoadWasm と同じく、gzip の classes.wasm で同じ物が動く。
  if (init.brotliUrl) {
    load = Promise.resolve().then(function () {
      importScripts(init.brotliDecoderUrl);
      return fetch(init.brotliUrl);
    }).then(function (res) {
      if (!res.ok) throw new Error(init.brotliUrl + " を取れない（" + res.status + "）");
      return res.arrayBuffer();
    }).then(function (buffer) {
      var b = new Int8Array(buffer);
      var raw = b.length >= 4 && b[0] === 0 && b[1] === 0x61 && b[2] === 0x73 && b[3] === 0x6d ? b : BrotliDecode(b);
      return TeaVM.wasmGC.load(raw);
    }).catch(function () { return TeaVM.wasmGC.load(init.wasmUrl); });
  } else {
    load = TeaVM.wasmGC.load(init.wasmUrl);
  }
  // WhyNot: main が返っただけで使えると言わない — ゲームの WebMain が withProject3d を通らずに終えると、頼みが 30 秒止まる。輪に入った所（fgeGlbWorkerNext）で ready を送る。
  return load.then(function (teavm) {
    teavm.exports.main([]);
    if (!fgeGlbWorkerServing) throw new Error("ゲームの main が glb を待つ輪（WebLayer.withProject3d）に入らなかった");
  });
}

self.onmessage = function (e) {
  var m = e.data;
  if (m.type === "init") {
    fgeGlbWorkerBoot(m).catch(function (err) {
      self.postMessage({ type: "broken", why: String(err && err.stack || err) });
    });
    return;
  }
  if (m.type === "parse") {
    var req = { id: m.id, bytes: new Int8Array(m.bytes), gltf: m.gltf };
    if (fgeGlbWorkerWaiter !== null && fgeGlbWorkerRequest === null) {
      var done = fgeGlbWorkerWaiter;
      fgeGlbWorkerWaiter = null;
      fgeGlbWorkerBegin(req);
      done();
    } else {
      fgeGlbWorkerQueue.push(req);
    }
  }
};
