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

// WhyNot: 普段の起動で見ない — getError は GPU の待ちになり、1 コマが何倍にも延びる。
function fgeQueryParam(name) { return new URLSearchParams(location.search).get(name); }

var fgeGlCheck = { calls: 0, errors: 0, seen: Object.create(null), counts: Object.create(null) };
function fgeCheckedGl(gl) {
  if (fgeQueryParam("glcheck") !== "1") return gl;
  var wrapped = Object.create(null);
  return new Proxy(gl, {
    get: function (target, name) {
      var v = target[name];
      if (typeof v !== "function") return v;
      if (wrapped[name]) return wrapped[name];
      wrapped[name] = function () {
        var result = v.apply(target, arguments);
        fgeGlCheck.calls++;
        fgeGlCheck.counts[name] = (fgeGlCheck.counts[name] || 0) + 1;
        var code = target.getError();
        if (code !== target.NO_ERROR) {
          fgeGlCheck.errors++;
          var key = String(name) + ":" + code;
          if (!fgeGlCheck.seen[key]) { fgeGlCheck.seen[key] = true; console.error("[glcheck] " + String(name) + " の後に GL の誤り 0x" + code.toString(16)); }
        }
        return result;
      };
      return wrapped[name];
    }
  });
}

function fgeEsSource(src) {
  var head = "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n";
  var m = /^\s*#version[^\n]*\n/.exec(src);
  return m ? head + src.slice(m[0].length) : head + src;
}

var fgeArgbScratch = new Uint8Array(0);
function fgeArgbBytes(n) {
  if (fgeArgbScratch.length < n * 4) fgeArgbScratch = new Uint8Array(n * 4);
  return fgeArgbScratch;
}
function fgeTexImageArgbLevel(level, w, h, argb, from) {
  var n = w * h;
  var out = fgeArgbBytes(n);
  for (var i = 0; i < n; i++) {
    var p = argb[from + i];
    var o = i * 4;
    out[o] = (p >>> 16) & 255;
    out[o + 1] = (p >>> 8) & 255;
    out[o + 2] = p & 255;
    out[o + 3] = (p >>> 24) & 255;
  }
  fgeGl.texImage2D(fgeGl.TEXTURE_2D, level, fgeGl.RGBA8, w, h, 0, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, out.subarray(0, n * 4));
}

var fgeDecodeTimes = fgeQueryParam("loadtime") === "1" ? { count: 0, ms: 0 } : null;

var fgeReadFramebuffer = null;
function fgeReadTextureArgb(texture, w, h, argb) {
  if (!fgeReadGlTextureArgb(fgeH[texture], w, h, argb)) console.warn("[fge] テクスチャ " + texture + " を読み戻せない（FBO が不完全）— 透明な黒で続ける");
}
function fgeReadGlTextureArgb(texture, w, h, argb) {
  if (fgeReadFramebuffer === null) fgeReadFramebuffer = fgeGl.createFramebuffer();
  var n = w * h;
  var bytes = fgeArgbBytes(n).subarray(0, n * 4);
  // WhyNot: FRAMEBUFFER へ付けない — 描画の途中で呼ばれるので、描き先まで替わる。読む側の READ_FRAMEBUFFER だけを替えて戻す。
  var before = fgeGl.getParameter(fgeGl.READ_FRAMEBUFFER_BINDING);
  fgeGl.bindFramebuffer(fgeGl.READ_FRAMEBUFFER, fgeReadFramebuffer);
  fgeGl.framebufferTexture2D(fgeGl.READ_FRAMEBUFFER, fgeGl.COLOR_ATTACHMENT0, fgeGl.TEXTURE_2D, texture, 0);
  // WhyNot: 確かめずに読まない — 不完全な FBO の readPixels は誤りだけを残し、使い回す置き場の前の絵が成功として返る。
  var complete = fgeGl.checkFramebufferStatus(fgeGl.READ_FRAMEBUFFER) === fgeGl.FRAMEBUFFER_COMPLETE;
  if (complete) fgeGl.readPixels(0, 0, w, h, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, bytes);
  fgeGl.framebufferTexture2D(fgeGl.READ_FRAMEBUFFER, fgeGl.COLOR_ATTACHMENT0, fgeGl.TEXTURE_2D, null, 0);
  fgeGl.bindFramebuffer(fgeGl.READ_FRAMEBUFFER, before);
  if (!complete) return false;
  for (var i = 0; i < n; i++) {
    var o = i * 4;
    argb[i] = (bytes[o + 3] << 24) | (bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2];
  }
  return true;
}

function fgeDecodeFailed(why) { return { error: "絵を解けない: " + why, width: 0, height: 0, argb: null }; }
function fgeBitmapArgb(bitmap) {
  var w = bitmap.width, h = bitmap.height;
  var before = fgeGl.getParameter(fgeGl.TEXTURE_BINDING_2D);
  var texture = fgeGl.createTexture();
  fgeGl.bindTexture(fgeGl.TEXTURE_2D, texture);
  fgeGl.pixelStorei(fgeGl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, bitmap);
  var argb = new Int32Array(w * h);
  var read = fgeReadGlTextureArgb(texture, w, h, argb);
  fgeGl.bindTexture(fgeGl.TEXTURE_2D, before);
  fgeGl.deleteTexture(texture);
  return read ? { error: "", width: w, height: h, argb: argb } : fgeDecodeFailed("読み戻しの FBO が不完全");
}

var fgeDecoded = null;
var fgeDecodeCount = 0;
function fgeDecodeImage(bytes, done) {
  var label = "[loadtime] decode " + (++fgeDecodeCount) + "（" + bytes.length + " バイト）";
  var began = performance.now();
  if (fgeDecodeTimes !== null) console.time(label);
  var finish = function (result) {
    fgeDecoded = result;
    if (fgeDecodeTimes !== null) {
      console.timeEnd(label);
      fgeDecodeTimes.count++;
      fgeDecodeTimes.ms += performance.now() - began;
    }
    done();
  };
  // WhyNot: 型を空にしない — 中身から形式を見分けるのに頼ると、ブラウザによって WebP を絵と見なさない恐れがある。ゲームが読むバイトに道は無いので頭のバイトで決める。
  var head = bytes[0] & 255;
  var type = head === 0x89 ? "image/png" : head === 0xff ? "image/jpeg" : head === 0x52 ? "image/webp" : "application/octet-stream";
  // WhyNot: .then(...).catch(...) の形にしない — done() の先で走るゲームの例外まで受けて、解読の失敗として 2 回目の done() を呼ぶ。
  createImageBitmap(new Blob([bytes], { type: type }), { premultiplyAlpha: "none", colorSpaceConversion: "none" }).then(function (bitmap) {
    var result;
    try { result = fgeBitmapArgb(bitmap); } catch (e) { result = fgeDecodeFailed(e && e.message || e); }
    bitmap.close();
    finish(result);
  }, function (e) { finish(fgeDecodeFailed(e && e.message || e)); });
}

// ── canvas ──
var fgeCanvas = null;
var fgeCaptureFrame = parseInt(fgeQueryParam("capture") || "0", 10) || 0;
var fgeCaptureDesign = null;
var fgeDrawnFrames = 0;
function fgeFrameDrawn() {
  if (fgeCaptureFrame <= 0 || ++fgeDrawnFrames !== fgeCaptureFrame) return;
  var w = fgeGl.drawingBufferWidth, h = fgeGl.drawingBufferHeight;
  var rgba = new Uint8Array(w * h * 4);
  fgeGl.bindFramebuffer(fgeGl.FRAMEBUFFER, null);
  fgeGl.readPixels(0, 0, w, h, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, rgba);
  var text = "";
  for (var i = 0; i < rgba.length; i += 8192) text += String.fromCharCode.apply(null, rgba.subarray(i, i + 8192));
  var info = fgeGl.getExtension("WEBGL_debug_renderer_info");
  var shot = { width: w, height: h, rgba: btoa(text), origin: "bottom-left",
               renderer: info ? fgeGl.getParameter(info.UNMASKED_RENDERER_WEBGL) : fgeGl.getParameter(fgeGl.VERSION) };
  window.fgeCapture = function () { return shot; };
  window.fgeCaptureReady = true;
}

function fgeResizeCanvas() {
  if (fgeCaptureFrame > 0 && fgeCaptureDesign !== null) {
    if (fgeCanvas.width !== fgeCaptureDesign.w || fgeCanvas.height !== fgeCaptureDesign.h) {
      fgeCanvas.width = fgeCaptureDesign.w;
      fgeCanvas.height = fgeCaptureDesign.h;
    }
    return;
  }
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
    // WhyNot: 断られた要求を捨てない — WebLayer は同じ値を頼み直さないので、次のキーか pointer で試し直す。
    var retry = function () { if (fgeFullscreenWanted === null) fgeFullscreenWanted = on; };
    if (on && document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(retry);
    if (!on && document.exitFullscreen && document.fullscreenElement) document.exitFullscreen().catch(retry);
  } catch (e) { fgeFullscreenWanted = on; }
}

// ── キーと pointer ──
var fgeKeys = Object.create(null);
var fgeLatch = Object.create(null);
var fgeFrameLatch = Object.create(null);
// パッドが押しているキー。指ごとの押しから fgePadSync が毎回作り直す。
// WhyNot: fgeKeys に混ぜない — キーボードの keyup や blur の全部離すで、指を置いたままのボタンが離れる。
var fgePadHeld = Object.create(null);
var fgePointer = { x: 0, y: 0, dx: 0, dy: 0, wheel: 0, touch: false,
                   buttons: [false, false, false], latch: [false, false, false], frameLatch: [false, false, false] };
function fgeKeyDown(code) { return !!(fgeKeys[code] || fgePadHeld[code] || fgeFrameLatch[code]); }
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

// ── 指の端末（パッド・タップ・ジェスチャー）──
// 束の web の設定（bin/fge export-web が project.json の web から作る。キーは KeyboardEvent.code に解いてある）。
var fgeWeb = { virtualPad: null, touchGestures: null, orientation: "any" };
// 主な pointer が指の端末か。?input=touch|mouse で上書きできる（PC で指の並べ方を確かめる時）。
var fgeCoarseQuery = window.matchMedia ? window.matchMedia("(pointer: coarse)") : null;
var fgeInputOverride = (function () {
  var m = /[?&]input=(touch|mouse)\b/.exec(location.search);
  return m ? m[1] : null;
})();
function fgeIsCoarse() {
  if (fgeInputOverride) return fgeInputOverride === "touch";
  return !!(fgeCoarseQuery && fgeCoarseQuery.matches);
}
// 端末の区分の材料（WebLayer が Display.sizeClassOf で区分にする）。起動の時に 1 回だけ測る。
// WhyNot: 毎コマ測らない — 区分は World の当たりの並べ方も変えるので、回す・アドレスバーが出入りするたびに変わってはいけない。
//   pointer: coarse も同じで、遊んでいる間にマウスをつないでも区分は変えない（パッドの出し入れだけがライブ）。
// WhyNot: 端末の画面（screen）だけで測らない — 分割画面や折りたたみを開いた時は、窓の方が小さい。
// WhyNot: 0 を拾わない — 裏のタブや iframe で innerWidth が 0 のまま測ると、どの端末も Small になる。
var fgeCoarseAtBoot = fgeIsCoarse();
var fgeScreenShortSide = (function () {
  var sides = [screen.width, screen.height, innerWidth, innerHeight].filter(function (v) { return v > 0; });
  return sides.length ? Math.min.apply(null, sides) : 1000;
})();
var fgeSizeOverride = (function () {
  var m = /[?&]size=(small|medium|large)\b/.exec(location.search);
  return m ? m[1] : "";
})();

// 縦の design を選ぶか（WebLayer が起動の時に 1 回だけ聞く）。?orientation=portrait|landscape があればそれ（PC で縦を確かめる時）、
// 無ければスマホ（区分 Small と同じ: 指の端末で短い辺が 600 CSS px 未満・?size=small）で、今の画面が縦長か。
// WhyNot: マウスの端末で窓が縦長なだけでは縦にしない — PC で開発者の道具を横に付けた窓や縦置きのモニタで、横の画面が変わってしまう。
// WhyNot: タブレットを縦に持った時は縦にしない — 縦の design の下限（9:16）より太い 3:4 の画面で左右に帯が出て、横の design の時と見た目が大きく変わる。
var fgeOrientationOverride = (function () {
  var m = /[?&]orientation=(portrait|landscape)\b/.exec(location.search);
  return m ? m[1] : "";
})();
function fgeWantsPortrait() {
  if (fgeOrientationOverride) return fgeOrientationOverride === "portrait";
  var phone = fgeSizeOverride ? fgeSizeOverride === "small" : (fgeCoarseAtBoot && fgeScreenShortSide < 600);
  return phone && innerHeight > innerWidth;
}
// 縦の design の時の描き先の大きさ（CSS px）。class を付けて切り欠きの内側へ寄せてから測る（測った比と描き先の比をそろえる）。
// WhyNot: パッドの時に canvas を測らない — 縦持ちのパッドの canvas は design の比から高さが決まるので、比を決める前の大きさにならない。
var fgePortraitBox = { w: 0, h: 0 };
function fgePreparePortraitView() {
  document.body.classList.add("fge-portrait-design");
  var r = fgeCanvas.getBoundingClientRect();
  var w = r.width > 0 ? r.width : innerWidth;
  var h = r.height > 0 ? r.height : innerHeight;
  if (document.body.classList.contains("fge-pad-on")) {
    var pad = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--fge-pad-min")) || 0;
    h = Math.max(1, innerHeight - pad);
  }
  fgePortraitBox = { w: w, h: h };
}
// 縦の design で起動すると決めた後: 描き先の比を縦の design にし、回した時は「縦にしてください」を出す。
function fgeUsePortraitDesign(aspect) {
  document.documentElement.style.setProperty("--fge-aspect", String(aspect));
  fgeWeb.orientation = "portrait";
  fgeApplyLayout();
  fgeResizeCanvas();
}

fgePointer.touch = fgeCoarseAtBoot;
var fgePad = { fingers: new Map(), targets: [], dpad: null };
function fgePadSync() {
  var held = Object.create(null);
  fgePad.fingers.forEach(function (f) { if (f.code) held[f.code] = true; });
  for (var code in held) if (!fgePadHeld[code]) fgeLatch[code] = true;
  fgePadHeld = held;
  fgePad.targets.forEach(function (t) { t.el.classList.toggle("on", !!held[t.code]); });
}
function fgePadReleaseAll() { fgePad.fingers.clear(); fgePadSync(); }

// 十字キーの向き。中心の不感帯の中は無し、今の向きの軸は他の軸が 1.2 倍を超えるまで保つ（斜めで向きがばたつかない）。
function fgeDpadDir(prev, x, y) {
  var r = fgePad.dpad.el.getBoundingClientRect();
  var dx = x - (r.left + r.width / 2), dy = y - (r.top + r.height / 2);
  var dead = r.width * 0.5 * 0.25;
  if (dx * dx + dy * dy < dead * dead) return null;
  var ax = Math.abs(dx), ay = Math.abs(dy);
  var wasH = prev === "left" || prev === "right", wasV = prev === "up" || prev === "down";
  var horizontal = wasH ? ax * 1.2 >= ay : wasV ? ax > ay * 1.2 : ax >= ay;
  return horizontal ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down");
}
function fgePadButtonAt(x, y) {
  var best = null, bestD = Infinity;
  fgePad.targets.forEach(function (t) {
    if (t.dir) return;
    var r = t.el.getBoundingClientRect();
    var slop = 12;
    if (x < r.left - slop || x > r.right + slop || y < r.top - slop || y > r.bottom + slop) return;
    var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    var d = (x - cx) * (x - cx) + (y - cy) * (y - cy);
    if (d < bestD) { bestD = d; best = t; }
  });
  return best;
}
function fgeInDpad(x, y) {
  if (!fgePad.dpad) return false;
  var r = fgePad.dpad.el.getBoundingClientRect();
  var slop = 24;
  return x >= r.left - slop && x <= r.right + slop && y >= r.top - slop && y <= r.bottom + slop;
}
function fgePadAim(f, x, y) {
  if (f.kind === "dpad") {
    f.dir = fgeDpadDir(f.dir, x, y);
    f.code = f.dir ? fgePad.dpad.codes[f.dir] : null;
  } else {
    var t = fgePadButtonAt(x, y);
    f.code = t ? t.code : null;
  }
}

function fgeBuildPad(cfg) {
  var pad = document.getElementById("fge-pad");
  var left = document.createElement("div");
  left.className = "fge-pad-zone fge-pad-left";
  var right = document.createElement("div");
  right.className = "fge-pad-zone fge-pad-right";
  if (cfg.dpad) {
    var dpad = document.createElement("div");
    dpad.className = "fge-dpad";
    fgePad.dpad = { el: dpad, codes: cfg.dpad };
    [["up", "▲"], ["left", "◀"], ["right", "▶"], ["down", "▼"]].forEach(function (d) {
      var arm = document.createElement("div");
      arm.className = "fge-dpad-arm fge-dpad-" + d[0];
      arm.textContent = d[1];
      dpad.appendChild(arm);
      fgePad.targets.push({ el: arm, code: cfg.dpad[d[0]], dir: d[0] });
    });
    left.appendChild(dpad);
  }
  var buttons = document.createElement("div");
  buttons.className = "fge-pad-buttons";
  (cfg.buttons || []).forEach(function (b, i) {
    var el = document.createElement("div");
    el.className = "fge-pad-button fge-pad-button-" + i;
    el.textContent = b.label;
    buttons.appendChild(el);
    fgePad.targets.push({ el: el, code: b.code, dir: null });
  });
  right.appendChild(buttons);
  pad.appendChild(left);
  pad.appendChild(right);
  [left, right].forEach(function (zone) {
    zone.addEventListener("pointerdown", function (e) {
      e.preventDefault();
      fgeNotePointer(e);
      // WhyNot: 暗黙の capture を当てにしない — マウスで確かめる時は capture されず、指を滑らせた後の move が帯の外へ逃げる。
      try { zone.setPointerCapture(e.pointerId); } catch (err) { /* 押し終えた指 */ }
      var f = { kind: fgeInDpad(e.clientX, e.clientY) ? "dpad" : "button", dir: null, code: null };
      fgePadAim(f, e.clientX, e.clientY);
      fgePad.fingers.set(e.pointerId, f);
      fgePadSync();
    });
    zone.addEventListener("pointermove", function (e) {
      var f = fgePad.fingers.get(e.pointerId);
      if (!f) return;
      fgePadAim(f, e.clientX, e.clientY);
      fgePadSync();
    });
    var lift = function (e) { if (fgePad.fingers.delete(e.pointerId)) fgePadSync(); };
    zone.addEventListener("pointerup", lift);
    zone.addEventListener("pointercancel", lift);
    zone.addEventListener("lostpointercapture", lift);
  });
}

// パッド・指の並べ方・向きの案内を、今の端末に合わせる（body の class で CSS が並べ替える）。
var fgeLastOrientation = null;
function fgeApplyLayout() {
  var coarse = fgeIsCoarse();
  var padOn = coarse && !!fgeWeb.virtualPad;
  var body = document.body;
  if (body.classList.contains("fge-pad-on") !== padOn) fgePadReleaseAll();
  body.classList.toggle("fge-touch", coarse);
  body.classList.toggle("fge-pad-on", padOn);
  body.classList.toggle("fge-want-landscape", fgeWeb.orientation === "landscape");
  body.classList.toggle("fge-want-portrait", fgeWeb.orientation === "portrait");
  var start = document.getElementById("fge-start");
  if (start) start.textContent = coarse ? "タップで始める" : "クリックかキーで始める";
  // WhyNot: orientationchange を待たない — 発火の時にはまだ前の向きの大きさのままの端末がある。大きさの変化（resize）で見る。
  var orientation = innerWidth >= innerHeight ? "landscape" : "portrait";
  if (fgeLastOrientation !== null && orientation !== fgeLastOrientation) fgePadReleaseAll();
  fgeLastOrientation = orientation;
}

// canvas の上の指: 離した時にタップ（その位置のクリック）・縦のドラッグはホイール・横に払うとスワイプ・長押し。
// 主な指（isPrimary）だけを追う。
var fgeTouchSlop = 16;
var fgeWheelStep = 40;
var fgeSwipeMin = 60;
var fgeLongPressMs = 650;
var fgeEdgeMargin = 24;
var fgeGesture = null;
function fgeGestureKey(name) {
  var g = fgeWeb.touchGestures;
  return g && g[name] ? g[name] : null;
}
function fgeTapKey(code) { fgeLatch[code] = true; }
function fgeGestureDown(e, canvasXY) {
  if (!e.isPrimary) return;
  if (fgeGesture && fgeGesture.timer) clearTimeout(fgeGesture.timer);
  var g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, lastY: e.clientY, px: canvasXY.x, py: canvasXY.y,
            mode: "tap", wheelRest: 0, wheelSign: 0, timer: 0 };
  if (fgeGestureKey("longPress")) {
    g.timer = setTimeout(function () {
      if (fgeGesture === g && g.mode === "tap") { g.mode = "done"; fgeTapKey(fgeGestureKey("longPress")); }
    }, fgeLongPressMs);
  }
  fgeGesture = g;
}
function fgeGestureMove(e) {
  var g = fgeGesture;
  if (!g || g.id !== e.pointerId) return;
  var dx = e.clientX - g.x0, dy = e.clientY - g.y0;
  if (g.mode === "tap" && dx * dx + dy * dy > fgeTouchSlop * fgeTouchSlop) {
    g.mode = Math.abs(dy) > Math.abs(dx) ? "scroll" : "swipe";
    if (g.timer) { clearTimeout(g.timer); g.timer = 0; }
  }
  if (g.mode === "scroll") {
    // 指を下へ引くと上へ回したホイール（前の行へ）。1 回のドラッグの中で、最初に出た向きと逆の刻みは捨てる（開いた直後に閉じない）。
    g.wheelRest += (e.clientY - g.lastY) / fgeWheelStep;
    while (Math.abs(g.wheelRest) >= 1) {
      var sign = g.wheelRest > 0 ? 1 : -1;
      g.wheelRest -= sign;
      if (g.wheelSign === 0) g.wheelSign = sign;
      if (sign === g.wheelSign) fgePointer.wheel += sign;
    }
  }
  g.lastY = e.clientY;
}
function fgeGestureUp(e) {
  var g = fgeGesture;
  if (!g || g.id !== e.pointerId) return;
  fgeGesture = null;
  if (g.timer) clearTimeout(g.timer);
  if (g.mode === "tap") {
    // WhyNot: 離した所で押さない — 指を離す時のずれで隣のボタンを押す。押した時の位置に戻してから押す。
    fgePointer.x = g.px;
    fgePointer.y = g.py;
    fgePointer.latch[0] = true;
  } else if (g.mode === "swipe") {
    var dx = e.clientX - g.x0, dy = e.clientY - g.y0;
    // WhyNot: 画面の端から始まった払いをスワイプにしない — Android・iOS の「戻る」のジェスチャーと同じ指の動きで、両方が起きる。
    var fromEdge = g.x0 < fgeEdgeMargin || g.x0 > innerWidth - fgeEdgeMargin;
    if (!fromEdge && Math.abs(dx) >= fgeSwipeMin && Math.abs(dx) >= Math.abs(dy) * 1.5) {
      var key = fgeGestureKey(dx < 0 ? "swipeLeft" : "swipeRight");
      if (key) fgeTapKey(key);
    }
  }
}
function fgeGestureCancel(e) {
  var g = fgeGesture;
  if (!g || g.id !== e.pointerId) return;
  if (g.timer) clearTimeout(g.timer);
  fgeGesture = null;
}

function fgeNotePointer(e) { fgePointer.touch = e.pointerType === "touch"; }

// WhyNot: 断られたら諦めない — ブラウザは操作の直後しか許さず、Esc で抜けた直後も断るので、次の操作で頼み直す。
var fgeMouseCapture = { wanted: false, asking: false, releasing: false };
function fgeRequestMouseCapture() {
  var c = fgeMouseCapture;
  if (!c.wanted || c.asking || document.pointerLockElement === fgeCanvas || !fgeCanvas.requestPointerLock) return;
  c.asking = true;
  var failed = function () { c.asking = false; };
  try {
    var asked = fgeCanvas.requestPointerLock();
    if (asked && asked.catch) asked.catch(failed);
  } catch (e) { failed(); }
}
function fgeSetMouseCaptured(on) {
  var c = fgeMouseCapture;
  c.wanted = on;
  if (on) { fgeRequestMouseCapture(); return; }
  if (document.pointerLockElement === fgeCanvas) { c.releasing = true; document.exitPointerLock(); }
}
function fgeWireMouseCapture() {
  document.addEventListener("pointerlockchange", function () {
    var c = fgeMouseCapture;
    c.asking = false;
    var locked = document.pointerLockElement === fgeCanvas;
    // WhyNot: 頼んだ後に宣言が変わった lock を残さない — 返事を待つ間に放すと、lock だけが後から掛かる。
    if (locked && !c.wanted) { c.releasing = true; document.exitPointerLock(); return; }
    // WhyNot: フォーカスが外れた解除を Esc にしない — 窓を切り替えただけでゲームのメニューが開く。戻って次の操作で掛け直す。
    if (!locked && c.wanted && !c.releasing && document.hasFocus() && document.visibilityState === "visible") fgeLatch.Escape = true;
    if (!locked) c.releasing = false;
  });
  document.addEventListener("pointerlockerror", function () { fgeMouseCapture.asking = false; });
  window.addEventListener("mousedown", fgeRequestMouseCapture);
  // WhyNot: Esc で頼み直さない — Esc で放した状態の Esc（メニューの閉じる）で、また掛かる。
  window.addEventListener("keydown", function (e) { if (e.code !== "Escape") fgeRequestMouseCapture(); });
}

function fgeWireInput() {
  window.addEventListener("keydown", function (e) {
    if (fgeSwallow[e.code]) e.preventDefault();
    fgeKeys[e.code] = true;
    if (!e.repeat) fgeLatch[e.code] = true;
    fgeApplyFullscreen();
    fgeAudio.wake();
  });
  window.addEventListener("keyup", function (e) { fgeKeys[e.code] = false; });
  window.addEventListener("blur", function () { fgeReleaseAll(); fgePadReleaseAll(); });
  window.addEventListener("focus", fgeReleaseAll);
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { fgeReleaseAll(); fgePadReleaseAll(); }
    fgeAudio.onVisibility();
  });
  var scale = function () {
    var rect = fgeCanvas.getBoundingClientRect();
    return { rect: rect, sx: fgeCanvas.width / Math.max(1, rect.width), sy: fgeCanvas.height / Math.max(1, rect.height) };
  };
  var toCanvas = function (e) {
    var s = scale();
    return { x: (e.clientX - s.rect.left) * s.sx, y: (e.clientY - s.rect.top) * s.sy, s: s };
  };
  var place = function (e) {
    var p = toCanvas(e);
    fgePointer.x = p.x;
    fgePointer.y = p.y;
    return p;
  };
  fgeCanvas.addEventListener("pointermove", function (e) {
    if (e.pointerType !== "touch") fgeNotePointer(e);
    if (e.pointerType === "touch") { fgeGestureMove(e); return; }
    var p = place(e);
    // WhyNot: 位置の差で動きを出さない — 初めの 1 回と、canvas の外から戻った時に跳ぶ。
    if (document.hasFocus()) { fgePointer.dx += (e.movementX || 0) * p.s.sx; fgePointer.dy += (e.movementY || 0) * p.s.sy; }
  });
  fgeCanvas.addEventListener("pointerenter", function (e) { if (e.pointerType !== "touch") place(e); });
  fgeCanvas.addEventListener("pointerdown", function (e) {
    fgeNotePointer(e);
    if (e.pointerType === "touch") {
      // WhyNot: 指は押した時にクリックにしない — 縦に払う（バックログ）・長押しと見分けられない。離した時に決める。
      if (e.isPrimary) fgeGestureDown(e, place(e));
      return;
    }
    place(e);
    if (e.button >= 0 && e.button < 3) { fgePointer.buttons[e.button] = true; fgePointer.latch[e.button] = true; }
    fgeApplyFullscreen();
  });
  window.addEventListener("pointerup", function (e) {
    fgeApplyFullscreen();
    fgeAudio.wake();
    if (e.pointerType === "touch") { fgeGestureUp(e); return; }
    if (e.button >= 0 && e.button < 3) fgePointer.buttons[e.button] = false;
  });
  window.addEventListener("pointercancel", function (e) { if (e.pointerType === "touch") fgeGestureCancel(e); });
  fgeCanvas.addEventListener("wheel", function (e) {
    e.preventDefault();
    var unit = e.deltaMode === 1 ? 1 : e.deltaMode === 2 ? 3 : 1 / 100;
    fgePointer.wheel -= e.deltaY * unit;
  }, { passive: false });
  // 長押しのメニュー・2 本指の拡大（iOS は user-scalable=no を無視する）・ダブルタップの拡大を止める。
  // WhyNot: エラー表示の中は止めない — 右クリックでコピーできなくなる。
  document.addEventListener("contextmenu", function (e) { if (!(e.target.closest && e.target.closest("#fge-error"))) e.preventDefault(); });
  document.addEventListener("gesturestart", function (e) { e.preventDefault(); });
  document.addEventListener("dblclick", function (e) { e.preventDefault(); });
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
  ctx: null, master: null, sounds: new Map(), wasRunning: false, started: false,
  has: function (name) { return this.sounds.has(name); },
  play: function (name) {
    var s = this.sounds.get(name);
    if (!s || !this.ctx) return;
    this.stop(name);
    var src = this.ctx.createBufferSource();
    src.buffer = s.buffer;
    src.loop = s.loop;
    // 頭から 1 回鳴らした後は [loopStart, loopEnd) を回す（デスクトップの smpl のループ点と同じ回り方）。
    if (s.loopEnd > 0) { src.loopStart = s.loopStart; src.loopEnd = s.loopEnd; }
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
  },
  // 始めた後に止まっていたら（断られた・電話などで iOS が止めた）、次の操作の中で起こし直す。
  wake: function () {
    if (this.ctx && this.started && !document.hidden && this.ctx.state !== "running") this.ctx.resume();
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
function fgeWireFpsOverlay() {
  if (fgeQueryParam("fps") !== "1") return;
  var el = document.createElement("div");
  el.style.cssText = "position:fixed;left:8px;top:calc(8px + env(safe-area-inset-top,0px));z-index:9999;padding:4px 8px;font:14px/1.3 monospace;color:#fff;background:rgba(0,0,0,.65);pointer-events:none";
  document.body.appendChild(el);
  var frames = 0, since = performance.now();
  var tick = function (now) {
    frames++;
    if (now - since >= 500) {
      var cpu = fgeStats.cpuRing.summary();
      el.textContent = (frames * 1000 / (now - since)).toFixed(1) + " fps / cpu " + (cpu.frames ? cpu.median : "-") + " ms";
      frames = 0; since = now;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
function fgeStarted() {
  fgeShow("fge-boot", false);
  fgeWireFpsOverlay();
  if (fgeDecodeTimes !== null) console.log("[loadtime] 最初のコマまで " + performance.now().toFixed(0) + " ms");
}
function fgeEnded() { fgeShow("fge-end", true); }
function fgeError(message) {
  var el = document.getElementById("fge-error");
  if (el) { el.textContent = message; el.style.display = ""; }
  console.error(message);
  // WhyNot: 撮る道具に待ち切らせない — 止まった頁は合図を出さないので、絵の遅れと見分けが付かないまま上限の秒数を待つ。
  if (fgeCaptureFrame > 0) window.fgeCaptureError = message;
}
window.addEventListener("error", function (e) {
  var err = e.error;
  fgeError("止まりました: " + (err && (err.message || String(err)) || e.message || e) + "（詳しくは開発者の道具の console）");
});
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
// WhyNot: 1 回で諦めない — スマホの回線では、大きな束を取る途中で通信が切れる（Failed to fetch）ことがあり、取り直せば通る。
async function fgeFetchBytes(path) {
  var url = fgeVersioned(encodeURI(path));
  var last = null;
  for (var attempt = 0; attempt < 4; attempt++) {
    if (attempt > 0) await new Promise(function (r) { setTimeout(r, 500 * attempt * attempt); });
    try {
      var res = await fetch(url);
      if (res.ok) return new Uint8Array(await res.arrayBuffer());
      last = new Error(path + " を取れない（" + res.status + "）");
      if (res.status < 500) break;
    } catch (e) {
      last = new Error(path + " を取れない（" + e.message + "）");
    }
  }
  throw last;
}

// 書き出しが替えた配る道（WebP・Opus・gzip）。素材の表と画像の表には論理の道（project.json の道）で入れる。
var fgeTranscoded = {};
function fgeServedPath(path) { return fgeTranscoded[path] || path; }
// WhyNot: .gz を名前だけで解かない — 置き先によっては Content-Encoding: gzip を付けて配り、fetch が既に解いた中身が届く。
async function fgeFetchAsset(path) {
  var served = fgeServedPath(path);
  var bytes = await fgeFetchBytes("assets/" + served);
  if (!/\.gz$/.test(served) || bytes.length < 2 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
  var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
function fgeImageType(path) {
  var ext = (/\.([a-z0-9]+)$/i.exec(path) || [])[1];
  return { webp: "image/webp", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg" }[(ext || "").toLowerCase()] || "";
}
// WhyNot: 解けない音で起動を止めない — 古い Safari は Opus を解けない。元の wav があれば取り直し、それも駄目ならその音だけ黙らせる。
async function fgeDecodeSound(s) {
  try {
    return await fgeAudio.ctx.decodeAudioData((await fgeFetchAsset(s.path)).buffer);
  } catch (e) {
    if (fgeServedPath(s.path) === s.path) throw e;
    console.warn("[fge] " + fgeServedPath(s.path) + " を解けないので " + s.path + " を取り直す（" + (e && e.message || e) + "）");
    return await fgeAudio.ctx.decodeAudioData((await fgeFetchBytes("assets/" + s.path)).buffer);
  }
}

// WhyNot: 全部を同時に取りに行かない — 数十本を一度に投げると、スマホの回線で途中の物が切れやすくなる。
async function fgeEachLimited(items, limit, fn) {
  var next = 0;
  var workers = [];
  for (var w = 0; w < Math.min(limit, items.length); w++) {
    workers.push((async function () {
      while (next < items.length) {
        var item = items[next++];
        await fn(item);
      }
    })());
  }
  await Promise.all(workers);
}

async function fgeBoot() {
  fgeCanvas = document.getElementById("fge-canvas");
  var bundle = JSON.parse(fgeDecoder.decode(await fgeFetchBytes("bundle.json")));
  document.title = bundle.title || document.title;
  fgeGameId = bundle.id || "game";
  fgeWeb.virtualPad = bundle.virtualPad || null;
  fgeWeb.touchGestures = bundle.touchGestures || null;
  fgeWeb.orientation = bundle.orientation || "any";
  fgeTranscoded = bundle.transcoded || {};
  if (bundle.design && bundle.design.w > 0 && bundle.design.h > 0) {
    fgeCaptureDesign = bundle.design;
    document.documentElement.style.setProperty("--fge-aspect", String(bundle.design.w / bundle.design.h));
  }
  if (fgeWeb.virtualPad) fgeBuildPad(fgeWeb.virtualPad);
  fgeApplyLayout();
  window.addEventListener("resize", fgeApplyLayout);
  if (fgeCoarseQuery && fgeCoarseQuery.addEventListener) fgeCoarseQuery.addEventListener("change", fgeApplyLayout);
  var files = bundle.files || [];
  var sounds = bundle.sounds || [];
  var images = bundle.images || [];
  var inFiles = new Set(files);
  var total = files.length + sounds.length + images.filter(function (path) { return !inFiles.has(path); }).length;
  var done = 0;
  // WhyNot: 押した後に音を解かない — 止まったままの AudioContext でも decodeAudioData は使えるので、素材を取る間に解き終えておく。
  var Ctx = window.AudioContext || window.webkitAudioContext;
  fgeAudio.ctx = new Ctx();
  fgeAudio.master = fgeAudio.ctx.createGain();
  fgeAudio.master.connect(fgeAudio.ctx.destination);
  fgeProgress("loading", 0, total);
  var jobs = files.map(function (path) {
    return async function () { fgeAssets.set(fgeNormPath(path), await fgeFetchAsset(path)); };
  }).concat(sounds.map(function (s) {
    return async function () {
      var buffer;
      try {
        buffer = await fgeDecodeSound(s);
      } catch (e) {
        console.error("[fge] 音 " + s.name + "（" + s.path + "）を解けない — この音は鳴らさない: " + (e && e.message || e));
        return;
      }
      // 圧縮で頭や末尾に詰め物が残るブラウザだと、ループの継ぎ目と seconds() がデスクトップとずれる。
      if (s.seconds > 0 && Math.abs(buffer.duration - s.seconds) > 2 / buffer.sampleRate) {
        console.warn("[fge] 音 " + s.name + " の長さが元と違う（" + buffer.duration.toFixed(5) + " 秒・元は " + s.seconds.toFixed(5) + " 秒）");
      }
      var gain = fgeAudio.ctx.createGain();
      gain.connect(fgeAudio.master);
      fgeAudio.sounds.set(s.name, { buffer: buffer, gain: gain, loop: !!s.looping, pitch: 1, source: null,
        loopStart: s.loopStart || 0, loopEnd: s.loopEnd || s.seconds || 0 });
    };
  }));
  await fgeEachLimited(jobs, 6, async function (job) {
    await job();
    fgeProgress("loading", ++done, total);
  });
  // WhyNot: files にもある絵を取り直さない — 同じ URL を 2 回運ぶ。readBytes のために生のバイトが表に残るメモリは、3D の入口の速さを問わない範囲として受ける。
  await fgeEachLimited(images, 6, async function (path) {
    var kept = fgeAssets.get(fgeNormPath(path));
    // WhyNot: 型を空にしない — 中身から形式を見分けるのに頼ると、ブラウザによって WebP を絵と見なさない恐れがある。
    var blob = new Blob([kept || await fgeFetchAsset(path)], { type: fgeImageType(fgeServedPath(path)) });
    fgeImages.set(fgeNormPath(path), await createImageBitmap(blob, { premultiplyAlpha: "none", colorSpaceConversion: "none" }));
    if (!kept) fgeProgress("loading", ++done, total);
  });
  fgeShow("fge-start", true);
  fgeProgress("click / tap to start", total, total);
  // WhyNot: 音を起こすのを await の後にしない — Safari は押した操作の処理の中で resume しないと断る版がある。
  // WhyNot: pointerdown で待たない — 指の pointerdown はユーザーの操作に数えられず（HTML の決まり）、Chrome は resume を断る。
  // WhyNot: click だけで待たない — iOS の Safari は押せる要素（ボタン・リンク・cursor: pointer）の上でしか指のタップを click にしないので、最初のタップが届かない。
  // 指の pointerup と touchend は操作に数えられる。
  var events = ["keydown", "click", "pointerup", "touchend"];
  if (fgeCaptureFrame <= 0) await new Promise(function (resolve) {
    var go = function (e) {
      if (e.type === "pointerup" && e.pointerType === "mouse") return;
      // iOS の消音スイッチで WebAudio が黙らないように（Safari 17 以降）。
      try { if (navigator.audioSession) navigator.audioSession.type = "playback"; } catch (e) { /* 無い版 */ }
      fgeAudio.ctx.resume();
      fgeAudio.started = true;
      events.forEach(function (name) { window.removeEventListener(name, go); });
      resolve();
    };
    events.forEach(function (name) { window.addEventListener(name, go); });
  });
  if (navigator.storage && navigator.storage.persist) {
    navigator.storage.persist().then(function (granted) {
      console.log("[fge] storage.persist: " + (granted ? "granted（セーブは消されにくい）" : "denied（ブラウザが容量に困るとセーブが消えうる）"));
    }, function () { /* 頼めない頁 */ });
  }
  fgeShow("fge-start", false);

  fgeResizeCanvas();
  new ResizeObserver(fgeResizeCanvas).observe(fgeCanvas);
  window.addEventListener("resize", fgeResizeCanvas);
  // alpha を持たない（ページの背景が透けない）・MSAA を切る（ドット絵がにじまない）・ステンシルを取る（多角形のマスク）。
  fgeGl = fgeCanvas.getContext("webgl2", { alpha: false, antialias: false, stencil: true, depth: true, premultipliedAlpha: false, preserveDrawingBuffer: false });
  if (!fgeGl) throw new Error("このブラウザは WebGL2 を使えない");
  fgeGl.getExtension("EXT_color_buffer_float");
  fgeGl.pixelStorei(fgeGl.UNPACK_COLORSPACE_CONVERSION_WEBGL, fgeGl.NONE);
  fgeGl = fgeCheckedGl(fgeGl);
  fgeWireInput();
  fgeWireMouseCapture();
  fgeProgress("starting", 0, 0);
  var teavm;
  try {
    teavm = await TeaVM.wasmGC.load(fgeVersioned("classes.wasm"));
  } catch (e) {
    throw new Error("このブラウザは WebAssembly GC に対応していないか、wasm を読めません（Chrome 119 以降・Safari 18.2 以降で開いてください）: " + (e && e.message || e));
  }
  try {
    teavm.exports.main([]);
  } catch (e) {
    fgeError("止まりました: " + (e && e.stack || e));
  }
}

// WhyNot: load だけを待たない — index.html の起動役は version.txt を確かめてからこの js を読むので、読み終えた時には load が済んでいることがある。
function fgeStart() { fgeBoot().catch(function (e) { fgeError("起動できません: " + (e && e.stack || e)); }); }
if (document.readyState === "complete") fgeStart(); else window.addEventListener("load", fgeStart);
