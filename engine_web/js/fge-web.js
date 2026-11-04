// fge-web.js — ブラウザ版の頁の中身。素材を取ってきて表にし、「押して始める」で音を起こしてから wasm の main を呼ぶ。
// wasm（fge.web の Java）は下の fge* の名前だけを呼ぶ。GL の物・音・キーの表はここに置き、wasm には int と字と数だけを渡す。
// 束の形（bundle.json）は書き出しの道具（bin/fge export-web）が決める。
"use strict";

// ── GL の物の表（0 は null）──
// WhyNot: 消した id を使い回さない — 古い id のまま別の種類の物（テクスチャの所にバッファ）が渡り、WebGL が TypeError で落ちる。
//   デスクトップの GL は種類ごとに名前が分かれているのでそうならない。
var fgeGl = null;
var fgeH = [null];
function fgeNew(obj) { fgeH.push(obj); return fgeH.length - 1; }
function fgeFree(id) { if (id > 0) fgeH[id] = null; }

var fgeU = [];
var fgeUByProgram = new Map();
function fgeUniformLocation(program, name) {
  var names = fgeUByProgram.get(program);
  if (names === undefined) { names = new Map(); fgeUByProgram.set(program, names); }
  var known = names.get(name);
  if (known !== undefined) return known;
  var loc = fgeGl.getUniformLocation(fgeH[program], name);
  var id = -1;
  if (loc !== null) { id = fgeU.length; fgeU.push(loc); }
  names.set(name, id);
  return id;
}
function fgeDeleteProgram(program) {
  fgeGl.deleteProgram(fgeH[program]);
  fgeFree(program);
  var names = fgeUByProgram.get(program);
  if (names !== undefined) { names.forEach(function (id) { if (id >= 0) fgeU[id] = null; }); fgeUByProgram.delete(program); }
}

function fgeEsSource(src) {
  var head = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n";
  var m = /^\s*#version[^\n]*\n/.exec(src);
  return m ? head + src.slice(m[0].length) : head + src;
}

var fgeArgbScratch = new Uint8Array(0);
function fgeTexImageArgb(w, h, argb, from) {
  var n = w * h;
  if (fgeArgbScratch.length < n * 4) fgeArgbScratch = new Uint8Array(n * 4);
  var out = fgeArgbScratch;
  for (var i = 0; i < n; i++) {
    var p = argb[from + i];
    var o = i * 4;
    out[o] = (p >>> 16) & 255;
    out[o + 1] = (p >>> 8) & 255;
    out[o + 2] = p & 255;
    out[o + 3] = (p >>> 24) & 255;
  }
  fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, w, h, 0, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, out.subarray(0, n * 4));
}

// ── canvas ──
var fgeCanvas = null;
function fgeResizeCanvas() {
  var dpr = window.devicePixelRatio || 1;
  var rect = fgeCanvas.getBoundingClientRect();
  var w = Math.max(1, Math.round(rect.width * dpr));
  var h = Math.max(1, Math.round(rect.height * dpr));
  if (fgeCanvas.width !== w || fgeCanvas.height !== h) { fgeCanvas.width = w; fgeCanvas.height = h; }
}
function fgeCanvasWidth() { return fgeCanvas.width; }
function fgeCanvasHeight() { return fgeCanvas.height; }
function fgeSetCursor(css) { fgeCanvas.style.cursor = css; }

// WhyNot: いつも次のイベントまで待たない — メニューの Enter で選んだ時、もう 1 回押すまで入らない。操作の直後（userActivation）ならその場で行う。
var fgeFullscreenWanted = null;
function fgeRequestFullscreen(on) {
  if (on === !!document.fullscreenElement) { fgeFullscreenWanted = null; return; }
  fgeFullscreenWanted = on;
  if (navigator.userActivation && navigator.userActivation.isActive) fgeApplyFullscreen();
}
function fgeApplyFullscreen() {
  if (fgeFullscreenWanted === null) return;
  var on = fgeFullscreenWanted;
  fgeFullscreenWanted = null;
  try {
    if (on && document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(function () {});
    if (!on && document.exitFullscreen && document.fullscreenElement) document.exitFullscreen().catch(function () {});
  } catch (e) { /* 断られたらウィンドウのまま */ }
}

// ── キーと pointer ──
var fgeKeys = Object.create(null);
var fgeLatch = Object.create(null);
var fgeFrameLatch = Object.create(null);
var fgePointer = { x: 0, y: 0, dx: 0, dy: 0, wheel: 0, buttons: [false, false, false], latch: [false, false, false], frameLatch: [false, false, false] };
function fgeKeyDown(code) { return !!(fgeKeys[code] || fgeFrameLatch[code]); }
function fgePointerDown(button) { return !!(fgePointer.buttons[button] || fgePointer.frameLatch[button]); }
function fgeBeginFrame() {
  fgeFrameLatch = fgeLatch;
  fgeLatch = Object.create(null);
  fgePointer.frameLatch = fgePointer.latch;
  fgePointer.latch = [false, false, false];
}
function fgeReleaseAll() {
  fgeKeys = Object.create(null);
  fgePointer.buttons = [false, false, false];
  fgePointer.dx = 0;
  fgePointer.dy = 0;
}
// ページがスクロールする・ブラウザの機能（Tab の移動・Firefox のクイック検索・ヘルプ・読み直し）が動くキー。F11 と F12 は残す。
var fgeSwallow = { ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1, Space: 1, Tab: 1, Backspace: 1, PageUp: 1, PageDown: 1,
                   Home: 1, End: 1, Slash: 1, Quote: 1, F1: 1, F3: 1, F5: 1, F7: 1 };
function fgeWireInput() {
  window.addEventListener("keydown", function (e) {
    if (fgeSwallow[e.code]) e.preventDefault();
    fgeKeys[e.code] = true;
    if (!e.repeat) fgeLatch[e.code] = true;
    fgeApplyFullscreen();
  });
  window.addEventListener("keyup", function (e) { fgeKeys[e.code] = false; });
  window.addEventListener("blur", fgeReleaseAll);
  window.addEventListener("focus", fgeReleaseAll);
  document.addEventListener("visibilitychange", function () { if (document.hidden) fgeReleaseAll(); fgeAudio.onVisibility(); });
  var scale = function () {
    var rect = fgeCanvas.getBoundingClientRect();
    return { rect: rect, sx: fgeCanvas.width / Math.max(1, rect.width), sy: fgeCanvas.height / Math.max(1, rect.height) };
  };
  var place = function (e) {
    var s = scale();
    fgePointer.x = (e.clientX - s.rect.left) * s.sx;
    fgePointer.y = (e.clientY - s.rect.top) * s.sy;
    return s;
  };
  fgeCanvas.addEventListener("pointermove", function (e) {
    var s = place(e);
    // WhyNot: 位置の差で動きを出さない — 初めの 1 回と、canvas の外から戻った時に跳ぶ。
    if (document.hasFocus()) { fgePointer.dx += (e.movementX || 0) * s.sx; fgePointer.dy += (e.movementY || 0) * s.sy; }
  });
  fgeCanvas.addEventListener("pointerenter", place);
  fgeCanvas.addEventListener("pointerdown", function (e) {
    place(e);
    if (e.button >= 0 && e.button < 3) { fgePointer.buttons[e.button] = true; fgePointer.latch[e.button] = true; }
    fgeApplyFullscreen();
  });
  window.addEventListener("pointerup", function (e) { if (e.button >= 0 && e.button < 3) fgePointer.buttons[e.button] = false; });
  fgeCanvas.addEventListener("wheel", function (e) {
    e.preventDefault();
    var unit = e.deltaMode === 1 ? 1 : e.deltaMode === 2 ? 3 : 1 / 100;
    fgePointer.wheel -= e.deltaY * unit;
  }, { passive: false });
  fgeCanvas.addEventListener("contextmenu", function (e) { e.preventDefault(); });
  // 人の決定（コンテキストロスト）: 戻すのは頁の読み直しとセーブから。
  fgeCanvas.addEventListener("webglcontextlost", function (e) {
    e.preventDefault();
    fgeError("画面の描き先（WebGL）が失われました。頁を読み直すと、最後のセーブから続けられます。");
  });
}

// ── 素材の表 ──
var fgeAssets = new Map();
var fgeDecoder = new TextDecoder("utf-8");
function fgeNormPath(path) {
  var p = String(path).replace(/\\/g, "/");
  while (p.startsWith("./")) p = p.slice(2);
  return p;
}
function fgeAssetHas(path) { return fgeAssets.has(fgeNormPath(path)); }
function fgeAssetText(path) {
  var b = fgeAssets.get(fgeNormPath(path));
  return b === undefined ? null : fgeDecoder.decode(b);
}
function fgeAssetBytes(path) {
  var b = fgeAssets.get(fgeNormPath(path));
  return b === undefined ? null : new Int8Array(b.buffer, b.byteOffset, b.byteLength);
}

// ── 画像（createImageBitmap で解いた物）──
var fgeImages = new Map();
function fgeTexImageBitmap(path, alpha) {
  var bmp = fgeImages.get(path);
  if (!bmp) return;
  fgeGl.pixelStorei(fgeGl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  if (alpha) fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, bmp);
  else fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGB8, fgeGl.RGB, fgeGl.UNSIGNED_BYTE, bmp);
}

// ── 音 ──
var fgeAudio = {
  ctx: null, master: null, sounds: new Map(), wasRunning: false,
  has: function (name) { return this.sounds.has(name); },
  play: function (name) {
    var s = this.sounds.get(name);
    if (!s || !this.ctx) return;
    this.stop(name);
    var src = this.ctx.createBufferSource();
    src.buffer = s.buffer;
    src.loop = s.loop;
    src.playbackRate.value = s.pitch;
    src.connect(s.gain);
    src.onended = function () { if (s.source === src) s.source = null; };
    s.source = src;
    src.start();
  },
  stop: function (name) {
    var s = this.sounds.get(name);
    if (!s || !s.source) return;
    var src = s.source;
    s.source = null;
    try { src.stop(); } catch (e) { /* 鳴り終えた物 */ }
  },
  setVolume: function (name, v) { var s = this.sounds.get(name); if (s) s.gain.gain.value = Math.max(0, v); },
  setPitch: function (name, p) {
    var s = this.sounds.get(name);
    if (!s) return;
    s.pitch = Math.max(0.01, p);
    if (s.source) s.source.playbackRate.value = s.pitch;
  },
  setLooping: function (name, loop) {
    var s = this.sounds.get(name);
    if (!s) return;
    s.loop = !!loop;
    if (s.source) s.source.loop = s.loop;
  },
  setMaster: function (g) { if (this.master) this.master.gain.value = Math.max(0, Math.min(1, g)); },
  seconds: function (name) { var s = this.sounds.get(name); return s ? s.buffer.duration : 0; },
  // WhyNot: タブが裏の間も鳴らし続けない — ゲームのループは止まるのに、ループの曲だけ先へ進む。
  onVisibility: function () {
    if (!this.ctx) return;
    if (document.hidden) { this.wasRunning = this.ctx.state === "running"; this.ctx.suspend(); }
    else if (this.wasRunning) this.ctx.resume();
  }
};

// ── 1 コマの CPU と、描き替えから wasm が戻るまでの遅れの控え ──
function fgeRing(size) {
  return {
    values: new Float64Array(size), count: 0,
    push: function (v) { this.values[this.count % this.values.length] = v; this.count++; },
    summary: function () {
      var n = Math.min(this.count, this.values.length);
      if (n === 0) return { frames: 0 };
      var s = Array.prototype.slice.call(this.values, 0, n).sort(function (a, b) { return a - b; });
      var at = function (q) { return s[Math.min(n - 1, Math.floor(q * n))]; };
      var sum = s.reduce(function (a, b) { return a + b; }, 0);
      return { frames: n, mean: +(sum / n).toFixed(3), median: +at(0.5).toFixed(3), p95: +at(0.95).toFixed(3), max: +s[n - 1].toFixed(3) };
    },
    reset: function () { this.count = 0; }
  };
}
var fgeStats = {
  cpuRing: fgeRing(600), lagRing: fgeRing(600),
  cpu: function (ms) { this.cpuRing.push(ms); },
  lag: function (ms) { this.lagRing.push(ms); },
  summary: function () { return { cpu: this.cpuRing.summary(), lag: this.lagRing.summary() }; },
  reset: function () { this.cpuRing.reset(); this.lagRing.reset(); }
};

// ── 起動の進み具合と終わりの画面 ──
function fgeProgress(phase, done, total) {
  var bar = document.getElementById("fge-bar");
  var text = document.getElementById("fge-phase");
  if (text) text.textContent = phase + (total > 0 ? " " + done + "/" + total : "");
  if (bar) bar.style.width = (total > 0 ? Math.round(100 * done / total) : 100) + "%";
}
function fgeShow(id, on) { var el = document.getElementById(id); if (el) el.style.display = on ? "" : "none"; }
function fgeStarted() { fgeShow("fge-boot", false); }
function fgeEnded() { fgeShow("fge-end", true); }
function fgeError(message) {
  var el = document.getElementById("fge-error");
  if (el) { el.textContent = message; el.style.display = ""; }
  console.error(message);
}
window.addEventListener("error", function (e) { fgeError("止まりました: " + (e.message || e)); });
window.addEventListener("unhandledrejection", function (e) { fgeError("止まりました: " + (e.reason && e.reason.stack || e.reason)); });

// ── 起動 ──
var fgeGameId = "game";
// WhyNot: 素材と wasm を版なしの URL で取らない — 置き先のキャッシュで、古い wasm と新しい素材が混ざる。版は index.html が付けた ?v= を使う。
var fgeVersion = (function () {
  var src = document.currentScript ? document.currentScript.src : "";
  var m = /[?&]v=([^&]+)/.exec(src);
  return m ? m[1] : "";
})();
function fgeVersioned(path) { return fgeVersion ? path + "?v=" + fgeVersion : path; }
async function fgeFetchBytes(path) {
  var res = await fetch(fgeVersioned(encodeURI(path)));
  if (!res.ok) throw new Error(path + " を取れない（" + res.status + "）");
  return new Uint8Array(await res.arrayBuffer());
}

async function fgeBoot() {
  fgeCanvas = document.getElementById("fge-canvas");
  var bundle = JSON.parse(fgeDecoder.decode(await fgeFetchBytes("bundle.json")));
  document.title = bundle.title || document.title;
  fgeGameId = bundle.id || "game";
  var files = bundle.files || [];
  var sounds = bundle.sounds || [];
  var images = bundle.images || [];
  var total = files.length + sounds.length + images.length;
  var done = 0;
  // WhyNot: 押した後に音を解かない — 止まったままの AudioContext でも decodeAudioData は使えるので、素材を取る間に解き終えておく。
  var Ctx = window.AudioContext || window.webkitAudioContext;
  fgeAudio.ctx = new Ctx();
  fgeAudio.master = fgeAudio.ctx.createGain();
  fgeAudio.master.connect(fgeAudio.ctx.destination);
  fgeProgress("loading", 0, total);
  await Promise.all(files.map(async function (path) {
    fgeAssets.set(fgeNormPath(path), await fgeFetchBytes("assets/" + path));
    fgeProgress("loading", ++done, total);
  }).concat(images.map(async function (path) {
    var blob = new Blob([await fgeFetchBytes("assets/" + path)]);
    fgeImages.set(fgeNormPath(path), await createImageBitmap(blob, { premultiplyAlpha: "none", colorSpaceConversion: "none" }));
    fgeProgress("loading", ++done, total);
  })).concat(sounds.map(async function (s) {
    var bytes = await fgeFetchBytes("assets/" + s.path);
    var buffer = await fgeAudio.ctx.decodeAudioData(bytes.buffer);
    var gain = fgeAudio.ctx.createGain();
    gain.connect(fgeAudio.master);
    fgeAudio.sounds.set(s.name, { buffer: buffer, gain: gain, loop: !!s.looping, pitch: 1, source: null });
    fgeProgress("loading", ++done, total);
  })));
  fgeShow("fge-start", true);
  fgeProgress("click / tap to start", total, total);
  // WhyNot: 音を起こすのを await の後にしない — Safari は押した操作の処理の中で resume しないと断る版がある。
  await new Promise(function (resolve) {
    var go = function () {
      fgeAudio.ctx.resume();
      window.removeEventListener("keydown", go);
      window.removeEventListener("pointerdown", go);
      resolve();
    };
    window.addEventListener("keydown", go);
    window.addEventListener("pointerdown", go);
  });
  fgeShow("fge-start", false);

  fgeResizeCanvas();
  new ResizeObserver(fgeResizeCanvas).observe(fgeCanvas);
  window.addEventListener("resize", fgeResizeCanvas);
  // alpha を持たない（ページの背景が透けない）・MSAA を切る（ドット絵がにじまない）・ステンシルを取る（多角形のマスク）。
  fgeGl = fgeCanvas.getContext("webgl2", { alpha: false, antialias: false, stencil: true, depth: true, premultipliedAlpha: false, preserveDrawingBuffer: false });
  if (!fgeGl) throw new Error("このブラウザは WebGL2 を使えない");
  fgeGl.getExtension("EXT_color_buffer_float");
  fgeGl.pixelStorei(fgeGl.UNPACK_COLORSPACE_CONVERSION_WEBGL, fgeGl.NONE);
  fgeWireInput();
  fgeProgress("starting", 0, 0);
  var teavm = await TeaVM.wasmGC.load(fgeVersioned("classes.wasm"));
  try {
    teavm.exports.main([]);
  } catch (e) {
    fgeError("止まりました: " + (e && e.stack || e));
  }
}

window.addEventListener("load", function () { fgeBoot().catch(function (e) { fgeError("起動できません: " + (e && e.stack || e)); }); });
