// fge-web.js — ブラウザ版の頁の中身。素材を取ってきて表にし、「押して始める」で音を起こしてから wasm の main を呼ぶ。
// wasm（fge.web の Java）は下の fge* の名前だけを呼ぶ。GL の物・音・キーの表はここに置き、wasm には int と字と数だけを渡す。
// bundle.json（書き出しの道具が作る）: { id, title, files: [道], images: [道], sounds: [{name, path, looping}] }。道は project.json から相対で、中身は assets/ の下に同じ道で置く。
"use strict";

// ── GL の物の表（0 は null）──
var fgeGl = null;
var fgeH = [null];
var fgeFreeIds = [];
function fgeNew(obj) {
  var id = fgeFreeIds.length > 0 ? fgeFreeIds.pop() : fgeH.length;
  fgeH[id] = obj;
  return id;
}
function fgeFree(id) {
  if (id > 0 && fgeH[id] !== null) { fgeH[id] = null; fgeFreeIds.push(id); }
}

// uniform の location: program と名前の組ごとに 1 つの int。-1 は無い名前。
var fgeU = [];
var fgeUByKey = new Map();
function fgeUniformLocation(program, name) {
  var key = program + ":" + name;
  var known = fgeUByKey.get(key);
  if (known !== undefined) return known;
  var loc = fgeGl.getUniformLocation(fgeH[program], name);
  var id = -1;
  if (loc !== null) { id = fgeU.length; fgeU.push(loc); }
  fgeUByKey.set(key, id);
  return id;
}
function fgeDeleteProgram(program) {
  fgeGl.deleteProgram(fgeH[program]);
  fgeFree(program);
  var prefix = program + ":";
  fgeUByKey.forEach(function (id, key) {
    if (key.startsWith(prefix)) { if (id >= 0) fgeU[id] = null; fgeUByKey.delete(key); }
  });
}

// デスクトップの GLSL（#version 330 core）を GLSL ES 3.00 の頭へ。
function fgeEsSource(src) {
  var head = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n";
  var m = /^\s*#version[^\n]*\n/.exec(src);
  return m ? head + src.slice(m[0].length) : head + src;
}

// ARGB の int 列（Int32Array の view・from から w*h 個）を RGBA のバイトへ並べ替えて上げる。
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

// 全画面はユーザーの操作の中でしか通らないので、頼まれた事を覚えて次のキーか pointer のイベントで行う。
var fgeFullscreenWanted = null;
function fgeRequestFullscreen(on) {
  if (on === !!document.fullscreenElement) { fgeFullscreenWanted = null; return; }
  fgeFullscreenWanted = on;
}
function fgeApplyFullscreen() {
  if (fgeFullscreenWanted === null) return;
  var on = fgeFullscreenWanted;
  fgeFullscreenWanted = null;
  try {
    if (on && document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(function () {});
    if (!on && document.exitFullscreen && document.fullscreenElement) document.exitFullscreen().catch(function () {});
  } catch (e) { /* 断られたら窓のまま */ }
}

// ── キーと pointer ──
var fgeKeys = Object.create(null);
var fgeLatch = Object.create(null);
function fgeKeyDown(code) {
  var v = !!(fgeKeys[code] || fgeLatch[code]);
  fgeLatch[code] = false;
  return v;
}
var fgePointer = { x: 0, y: 0, dx: 0, dy: 0, wheel: 0, buttons: [false, false, false], latch: [false, false, false] };
function fgePointerDown(button) {
  var v = !!(fgePointer.buttons[button] || fgePointer.latch[button]);
  fgePointer.latch[button] = false;
  return v;
}
function fgeReleaseAll() {
  fgeKeys = Object.create(null);
  fgePointer.buttons = [false, false, false];
}
// ページがスクロールしたり、ブラウザの機能（Tab の移動・空白で下へ）が動いたりするキー。
var fgeSwallow = { ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1, Space: 1, Tab: 1, Backspace: 1, PageUp: 1, PageDown: 1, Home: 1, End: 1 };
function fgeWireInput() {
  window.addEventListener("keydown", function (e) {
    if (fgeSwallow[e.code]) e.preventDefault();
    fgeKeys[e.code] = true;
    if (!e.repeat) fgeLatch[e.code] = true;
    fgeApplyFullscreen();
  });
  window.addEventListener("keyup", function (e) { fgeKeys[e.code] = false; });
  window.addEventListener("blur", fgeReleaseAll);
  document.addEventListener("visibilitychange", function () { if (document.hidden) fgeReleaseAll(); fgeAudio.onVisibility(); });
  var toCanvas = function (e) {
    var rect = fgeCanvas.getBoundingClientRect();
    var sx = fgeCanvas.width / Math.max(1, rect.width);
    var sy = fgeCanvas.height / Math.max(1, rect.height);
    var x = (e.clientX - rect.left) * sx;
    var y = (e.clientY - rect.top) * sy;
    fgePointer.dx += x - fgePointer.x;
    fgePointer.dy += y - fgePointer.y;
    fgePointer.x = x;
    fgePointer.y = y;
  };
  fgeCanvas.addEventListener("pointermove", toCanvas);
  fgeCanvas.addEventListener("pointerdown", function (e) {
    toCanvas(e);
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
function fgeTexImageBitmap(path) {
  var bmp = fgeImages.get(path);
  if (!bmp) return;
  fgeGl.pixelStorei(fgeGl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, bmp);
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
  // タブが裏に回ったら止め、戻ったら続ける（ループの曲だけ先へ進むのを防ぐ）。
  onVisibility: function () {
    if (!this.ctx) return;
    if (document.hidden) { this.wasRunning = this.ctx.state === "running"; this.ctx.suspend(); }
    else if (this.wasRunning) this.ctx.resume();
  }
};

// ── 1 コマの CPU の控え（AnimationFrame が毎コマ ms を渡す）──
var fgeStats = {
  samples: [], max: 600,
  cpu: function (ms) { this.samples.push(ms); if (this.samples.length > this.max) this.samples.shift(); },
  summary: function () {
    var s = this.samples.slice().sort(function (a, b) { return a - b; });
    if (s.length === 0) return { frames: 0 };
    var at = function (q) { return s[Math.min(s.length - 1, Math.floor(q * s.length))]; };
    var sum = s.reduce(function (a, b) { return a + b; }, 0);
    return { frames: s.length, mean: +(sum / s.length).toFixed(3), median: +at(0.5).toFixed(3), p95: +at(0.95).toFixed(3), max: +s[s.length - 1].toFixed(3) };
  }
};

// ── 起動の帯と終わりの画面 ──
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
async function fgeFetchBytes(path) {
  var res = await fetch(encodeURI(path));
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
  var soundBytes = new Map();
  fgeProgress("loading", 0, total);
  await Promise.all(files.map(async function (path) {
    fgeAssets.set(fgeNormPath(path), await fgeFetchBytes("assets/" + path));
    fgeProgress("loading", ++done, total);
  }).concat(images.map(async function (path) {
    var blob = new Blob([await fgeFetchBytes("assets/" + path)]);
    fgeImages.set(fgeNormPath(path), await createImageBitmap(blob, { premultiplyAlpha: "none", colorSpaceConversion: "none" }));
    fgeProgress("loading", ++done, total);
  })).concat(sounds.map(async function (s) {
    soundBytes.set(s.name, await fgeFetchBytes("assets/" + s.path));
    fgeProgress("loading", ++done, total);
  })));
  fgeShow("fge-start", true);
  fgeProgress("click / tap to start", total, total);
  await new Promise(function (resolve) {
    var go = function () { window.removeEventListener("keydown", go); window.removeEventListener("pointerdown", go); resolve(); };
    window.addEventListener("keydown", go);
    window.addEventListener("pointerdown", go);
  });
  fgeShow("fge-start", false);
  // 押した操作の中で音を起こす（自動再生の決まり）。鳴らす前に全部デコードし終える（終わる前の 1 回目が落ちるため）。
  var Ctx = window.AudioContext || window.webkitAudioContext;
  fgeAudio.ctx = new Ctx();
  fgeAudio.master = fgeAudio.ctx.createGain();
  fgeAudio.master.connect(fgeAudio.ctx.destination);
  var resumed = fgeAudio.ctx.resume();
  fgeProgress("decoding sounds", 0, sounds.length);
  var decoded = 0;
  await Promise.all(sounds.map(async function (s) {
    var bytes = soundBytes.get(s.name);
    var buffer = await fgeAudio.ctx.decodeAudioData(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
    var gain = fgeAudio.ctx.createGain();
    gain.connect(fgeAudio.master);
    fgeAudio.sounds.set(s.name, { buffer: buffer, gain: gain, loop: !!s.looping, pitch: 1, source: null });
    fgeProgress("decoding sounds", ++decoded, sounds.length);
  }));
  await resumed;

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
  var teavm = await TeaVM.wasmGC.load("classes.wasm");
  try {
    teavm.exports.main([]);
  } catch (e) {
    fgeError("止まりました: " + (e && e.stack || e));
  }
}

window.addEventListener("load", function () { fgeBoot().catch(function (e) { fgeError("起動できません: " + (e && e.stack || e)); }); });
