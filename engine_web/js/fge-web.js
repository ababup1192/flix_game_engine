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

var fgeCopyFramebuffer = null;
// WhyNot: copyTexImage2D で写さない — 透けない絵は RGB8 で上げていて、RGB8 の FBO から RGBA8 へは写せない（ES 3.0 の決まり）。blit は形式を替えて写せる。
// WhyNot: 鋏（SCISSOR_TEST）を付けたまま blit しない — blit も鋏で切られ、描きかけの場面の鋏の外が写らない。
// WhyNot: colorMask を外さない — blit に効く断片の操作は画素の持ち主の検査と鋏だけ（ES 3.0 の決まり）。
function fgeCopyTextureLevel0(source, w, h) {
  var dest = fgeGl.getParameter(fgeGl.TEXTURE_BINDING_2D);
  fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, w, h, 0, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, null);
  if (fgeReadFramebuffer === null) fgeReadFramebuffer = fgeGl.createFramebuffer();
  if (fgeCopyFramebuffer === null) fgeCopyFramebuffer = fgeGl.createFramebuffer();
  var beforeRead = fgeGl.getParameter(fgeGl.READ_FRAMEBUFFER_BINDING);
  var beforeDraw = fgeGl.getParameter(fgeGl.DRAW_FRAMEBUFFER_BINDING);
  var scissor = fgeGl.isEnabled(fgeGl.SCISSOR_TEST);
  fgeGl.bindFramebuffer(fgeGl.READ_FRAMEBUFFER, fgeReadFramebuffer);
  fgeGl.framebufferTexture2D(fgeGl.READ_FRAMEBUFFER, fgeGl.COLOR_ATTACHMENT0, fgeGl.TEXTURE_2D, fgeH[source], 0);
  fgeGl.bindFramebuffer(fgeGl.DRAW_FRAMEBUFFER, fgeCopyFramebuffer);
  fgeGl.framebufferTexture2D(fgeGl.DRAW_FRAMEBUFFER, fgeGl.COLOR_ATTACHMENT0, fgeGl.TEXTURE_2D, dest, 0);
  var complete = fgeGl.checkFramebufferStatus(fgeGl.READ_FRAMEBUFFER) === fgeGl.FRAMEBUFFER_COMPLETE &&
    fgeGl.checkFramebufferStatus(fgeGl.DRAW_FRAMEBUFFER) === fgeGl.FRAMEBUFFER_COMPLETE;
  var copied = false;
  if (complete) {
    if (scissor) fgeGl.disable(fgeGl.SCISSOR_TEST);
    // WhyNot: 前に溜まった誤りを残さない — blit の誤りと見分けられず、写せたのに読み戻しへ落ちる。
    fgeGl.getError();
    fgeGl.blitFramebuffer(0, 0, w, h, 0, 0, w, h, fgeGl.COLOR_BUFFER_BIT, fgeGl.NEAREST);
    copied = fgeGl.getError() === fgeGl.NO_ERROR;
    if (scissor) fgeGl.enable(fgeGl.SCISSOR_TEST);
  }
  fgeGl.framebufferTexture2D(fgeGl.DRAW_FRAMEBUFFER, fgeGl.COLOR_ATTACHMENT0, fgeGl.TEXTURE_2D, null, 0);
  fgeGl.framebufferTexture2D(fgeGl.READ_FRAMEBUFFER, fgeGl.COLOR_ATTACHMENT0, fgeGl.TEXTURE_2D, null, 0);
  fgeGl.bindFramebuffer(fgeGl.DRAW_FRAMEBUFFER, beforeDraw);
  fgeGl.bindFramebuffer(fgeGl.READ_FRAMEBUFFER, beforeRead);
  if (!copied) console.warn("[fge] テクスチャ " + source + " を GPU の中で写せない（" + (complete ? "blit の誤り" : "FBO が不完全") + "）— 読み戻して写す");
  return copied;
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

function fgeImageTypeOfBytes(bytes) {
  var head = bytes[0] & 255;
  return head === 0x89 ? "image/png" : head === 0xff ? "image/jpeg" : head === 0x52 ? "image/webp" : "application/octet-stream";
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
  var type = fgeImageTypeOfBytes(bytes);
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
  // WhyNot: orientationchange を待たない — 発火の時にはまだ前の向きの大きさのままの端末がある。大きさの変化（resize）で見る。
  var orientation = innerWidth >= innerHeight ? "landscape" : "portrait";
  if (fgeLastOrientation !== null && orientation !== fgeLastOrientation) fgePadReleaseAll();
  fgeLastOrientation = orientation;
}

// canvas の上の指: 離した時にタップ（その位置のクリック）・縦のドラッグはホイール・横に払うとスワイプ・長押し。
// 縦のドラッグは、離した時に縦へ払った形なら swipeUp / swipeDown のキーも出す（ホイールは動かしている間に出したまま）。
// 横のドラッグの間は、マウスの左ボタンを押したまま動かすのと同じに見せる（横と決まった所で押し始め、位置は指に付いて動く。離すと押しも離れる）。
// スライダーを指で動かせるように。
// 長押しは、動かさずに fgeLongPressMs 以上置いてから離した時に出す（離した時のタップの代わり）。
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
            mode: "tap", wheelRest: 0, wheelSign: 0, timer: 0, held: false };
  if (fgeGestureKey("longPress")) {
    g.timer = setTimeout(function () {
      // WhyNot: 置いている間に出さない — スライダーのつまみに指を置いて少し止めてから動かすと、戻るが出て画面が閉じる。
      if (fgeGesture === g && g.mode === "tap") g.held = true;
    }, fgeLongPressMs);
  }
  fgeGesture = g;
}
function fgeGestureMove(e, canvasXY) {
  var g = fgeGesture;
  if (!g || g.id !== e.pointerId) return;
  var dx = e.clientX - g.x0, dy = e.clientY - g.y0;
  if (g.mode === "tap" && dx * dx + dy * dy > fgeTouchSlop * fgeTouchSlop) {
    g.mode = Math.abs(dy) > Math.abs(dx) ? "scroll" : "swipe";
    if (g.timer) { clearTimeout(g.timer); g.timer = 0; }
  }
  if (g.mode === "swipe") {
    // WhyNot: 押した拍（latch）を立てない — 横に払っただけで、払い始めの所のボタンが押される。
    fgePointer.x = canvasXY.x;
    fgePointer.y = canvasXY.y;
    fgePointer.buttons[0] = true;
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
  if (g.mode === "swipe") fgePointer.buttons[0] = false;
  if (g.mode === "tap" && g.held) {
    fgeTapKey(fgeGestureKey("longPress"));
  } else if (g.mode === "tap") {
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
  } else if (g.mode === "scroll") {
    var sdx = e.clientX - g.x0, sdy = e.clientY - g.y0;
    // WhyNot: 上下の端から始まった払いを出さない — 通知の引き出しとホームへ戻る指の動きと同じで、両方が起きる。
    var fromEdgeY = g.y0 < fgeEdgeMargin || g.y0 > innerHeight - fgeEdgeMargin;
    if (!fromEdgeY && Math.abs(sdy) >= fgeSwipeMin && Math.abs(sdy) >= Math.abs(sdx) * 1.5) {
      var vkey = fgeGestureKey(sdy < 0 ? "swipeUp" : "swipeDown");
      if (vkey) fgeTapKey(vkey);
    }
  }
}
function fgeGestureCancel(e) {
  var g = fgeGesture;
  if (!g || g.id !== e.pointerId) return;
  if (g.timer) clearTimeout(g.timer);
  if (g.mode === "swipe") fgePointer.buttons[0] = false;
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
    if (e.pointerType === "touch") { fgeGestureMove(e, toCanvas(e)); return; }
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
  if (!bmp) {
    console.warn("[fge] 絵 " + path + " の ImageBitmap が無い — 上げない");
    return false;
  }
  fgeGl.pixelStorei(fgeGl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  if (alpha) fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGBA8, fgeGl.RGBA, fgeGl.UNSIGNED_BYTE, bmp);
  else fgeGl.texImage2D(fgeGl.TEXTURE_2D, 0, fgeGl.RGB8, fgeGl.RGB, fgeGl.UNSIGNED_BYTE, bmp);
  return true;
}

// 版は道の後ろの最後の @ から。
function fgePlatformKey(path) { return fgeNormPath(path) + "@" + fgeVersion; }
function fgeTexImagePlatform(key) { return fgeTexImageBitmap(key.slice(0, key.lastIndexOf("@")), true); }
// WhyNot: 読み直しを「無い」にしない — 2 つの部屋が同じ jpg を貼ると、後の部屋の読み込みが道を読めずに落ちる。空のバイトでも platformImage が持っている絵を使う。
var fgeHeldImages = new Set();
var fgeEmptyBytes = new Uint8Array(0);
// done は必ず後から 1 回呼ぶ。
// WhyNot: ImageBitmap にした後も後回しの道の生のバイトを持たない — iOS Safari の 1 タブのメモリに、同じ絵が解いた物と二重に載る。
// WhyNot: 後回しでない道のバイトは空にしない — 起動の素材はゲームが何度でも読む前提で書かれている。
function fgeHoldImage(path, done) {
  var p = fgeNormPath(path);
  var bytes = fgeAssets.get(p);
  var label = "[loadtime] hold " + p;
  if (fgeDecodeTimes !== null) console.time(label);
  var finish = function () { if (fgeDecodeTimes !== null) console.timeEnd(label); done(); };
  createImageBitmap(new Blob([bytes], { type: fgeImageTypeOfBytes(bytes) }), { premultiplyAlpha: "none", colorSpaceConversion: "none" }).then(function (bitmap) {
    fgeImages.set(p, bitmap);
    if (fgeIsDeferredPath(p)) {
      fgeHeldImages.add(p);
      fgeAssets.set(p, fgeEmptyBytes);
    }
    finish();
  }, function (e) { console.warn("[fge] 絵 " + p + " を解けない: " + (e && e.message || e)); finish(); });
}

// ── 音 ──
var fgeAudio = {
  ctx: null, master: null, sounds: new Map(), wasRunning: false, started: false,
  has: function (name) { return this.sounds.has(name); },
  play: function (name) {
    var s = this.sounds.get(name);
    if (!s || !this.ctx) return;
    if (fgeDecodeTimes !== null && fgeDeferred.byName.has(name)) console.log("[loadtime] 後回しの音 " + name + " を鳴らす at " + performance.now().toFixed(0) + " ms");
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
  isLooping: function (name) { var s = this.sounds.get(name); return !!(s && s.loop); },
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

// ── 起動画面（デスクトップの Splash.flix と同じ配置・色・ゲージ・字）──
// 押す前も押した後（wasm の LoadProgress）も、ここが #fge-splash の canvas に描く 1 枚の絵を出し続ける。
// 寸法の式は engine/src/render2d/Splash.flix の drawables と同じ（design の座標で組み、描き先へ黒帯ありで広げる）。
// WhyNot: 押す前の画面を HTML の字とバーで組まない — 押した後の wasm の起動画面とデスクトップがドットの字で描くので、同じ絵に見えない。
var fgeSplash = {
  data: null, bundle: null, design: { w: 0, h: 0 }, phase: "", ratio: null, ready: false, tapped: false,
  font: null, logo: null, glyphs: null, tints: {}, canvas: null, ctx: null,
  startedAt: performance.now(), drawn: "", running: false, layout: null
};
var fgeSplashColors = { backdrop: "#0b0e12", white: "#ffffff", brand: "rgb(158,204,242)", dim: "rgb(140,148,163)" };
function fgeProgress(phase, done, total) {
  fgeSplash.phase = phase;
  fgeSplash.ratio = total > 0 ? Math.max(0, Math.min(1, done / total)) : null;
}
function fgeSplashInit(bundle) {
  var data = bundle.splash || {};
  fgeSplash.data = data;
  fgeSplash.bundle = bundle;
  fgeSplash.design = fgeSplashDesign(bundle, data);
  var prompt = document.getElementById("fge-prompt");
  if (prompt) prompt.textContent = data.startPrompt || "Tap to start";
  if (data.glyphs) {
    fgeSplash.glyphs = new Map();
    for (var i = 0; i + 14 <= data.glyphs.length; i += 14) {
      var hex = function (at, n) { return parseInt(data.glyphs.substr(i + at, n), 16) || 0; };
      fgeSplash.glyphs.set(hex(0, 4), { x: hex(4, 3), y: hex(7, 3), w: hex(10, 2), adv: hex(12, 2) });
    }
  }
  var load = function (url, key) {
    if (!url) return;
    var img = new Image();
    img.onload = function () { fgeSplash[key] = img; fgeSplash.tints = {}; fgeSplash.drawn = ""; };
    img.src = url;
  };
  load(data.font, "font");
  load(data.logo, "logo");
  fgeSplashRun();
}
// 押した後に WebLayer が選ぶ design と同じ物（縦の design は web.portraitDesign と今の画面の比から ProjectLoader.portraitDesignOf と同じ式で）。
function fgeSplashDesign(bundle, data) {
  var spec = data.portraitDesign;
  if (spec && fgeWantsPortrait() && innerWidth > 0 && innerHeight > 0) {
    var h = Math.round(spec.width * innerHeight / innerWidth);
    return { w: spec.width, h: Math.min(spec.maxHeight, Math.max(spec.minHeight, h)) };
  }
  if (bundle.design && bundle.design.w > 0 && bundle.design.h > 0) return { w: bundle.design.w, h: bundle.design.h };
  return { w: Math.max(1, innerWidth), h: Math.max(1, innerHeight) };
}
function fgeSplashRun() {
  if (fgeSplash.running) return;
  fgeSplash.running = true;
  var tick = function () {
    if (!fgeSplash.running) return;
    fgeSplashDraw();
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
// 後回しの素材の進み具合（配るバイトの割合）。後回しが無ければ null（2 本目の線を出さない）。
function fgeSplashDeferredRatio() {
  var all = 0, got = 0;
  fgeDeferred.entries.forEach(function (e) {
    all += e.bytes;
    if (e.state === "downloaded" || e.state === "loaded" || e.state === "released") got += e.bytes;
  });
  return all > 0 ? got / all : null;
}
function fgeSplashLayout(dw, dh) {
  var d = fgeSplash.data || {};
  var scale = Math.max(1, Math.floor(dh / 200));
  var logoBase = fgeSplash.logo ? fgeSplash.logo.naturalHeight : 0;
  var logoH = 0;
  if (logoBase > 0) {
    logoH = logoBase / 4;
    [logoBase / 4, logoBase / 2, logoBase, logoBase * 2].forEach(function (h) { if (h <= dh * 0.3) logoH = Math.max(logoH, h); });
  }
  var lineH = ((d.ascent || 9) + (d.descent || 2) + (d.lineGap || 0)) * scale;
  var gaugeH = Math.max(2, 3 * scale);
  var gap = 4 * scale;
  var blockH = logoH + gap + lineH + gap * 2 + gaugeH + gap + lineH;
  var top = Math.floor((dh - blockH) / 2);
  var cx = Math.floor(dw / 2);
  var titleTop = top + logoH + gap;
  var gaugeTop = titleTop + lineH + gap * 2;
  var gaugeW = Math.floor(Math.min(dw - 16 * scale, dw * 0.6));
  return { scale: scale, logoH: logoH, lineH: lineH, gaugeH: gaugeH, cx: cx, logoTop: top, titleTop: titleTop,
           gaugeTop: gaugeTop, gaugeW: gaugeW, gaugeLeft: Math.floor(cx - gaugeW / 2), phaseTop: gaugeTop + gaugeH + gap };
}
// 白い字のアトラスを 1 色に塗った写し（色ごとに 1 枚だけ作る）。
function fgeSplashTint(color) {
  var t = fgeSplash.tints[color];
  if (t) return t;
  var f = fgeSplash.font;
  t = document.createElement("canvas");
  t.width = f.naturalWidth; t.height = f.naturalHeight;
  var c = t.getContext("2d");
  c.drawImage(f, 0, 0);
  c.globalCompositeOperation = "source-in";
  c.fillStyle = color;
  c.fillRect(0, 0, t.width, t.height);
  fgeSplash.tints[color] = t;
  return t;
}
function fgeSplashText(ctx, text, L, top, color) {
  if (!text || !fgeSplash.font || !fgeSplash.glyphs) return;
  var cellH = (fgeSplash.data && fgeSplash.data.cellH) || 11;
  var width = 0;
  for (var i = 0; i < text.length; i++) { var g0 = fgeSplash.glyphs.get(text.charCodeAt(i)); if (g0) width += g0.adv; }
  var tint = fgeSplashTint(color);
  var pen = 0;
  var x0 = L.cx - width * L.scale / 2;
  for (var j = 0; j < text.length; j++) {
    var g = fgeSplash.glyphs.get(text.charCodeAt(j));
    if (!g) continue;
    if (g.w > 0) ctx.drawImage(tint, g.x, g.y, g.w, cellH, x0 + pen * L.scale, top, g.w * L.scale, cellH * L.scale);
    pen += g.adv;
  }
}
function fgeSplashDraw() {
  var canvas = fgeSplash.canvas || (fgeSplash.canvas = document.getElementById("fge-splash"));
  if (!canvas) return;
  var dpr = window.devicePixelRatio || 1;
  var cw = Math.max(1, Math.round(canvas.clientWidth * dpr)), ch = Math.max(1, Math.round(canvas.clientHeight * dpr));
  // WhyNot: 押した後に design を測り直さない — 押した後の design は WebLayer が main で 1 回だけ決め、その後は回しても変えない。
  if (!fgeSplash.tapped && fgeSplash.bundle) fgeSplash.design = fgeSplashDesign(fgeSplash.bundle, fgeSplash.data);
  var dw = fgeSplash.design.w, dh = fgeSplash.design.h;
  var turns = 0;
  if (fgeSplash.ratio === null) { var sec = (performance.now() - fgeSplash.startedAt) / 1000; turns = sec - Math.floor(sec); }
  var sub = fgeSplashDeferredRatio();
  var key = [cw, ch, dw, dh, fgeSplash.phase, fgeSplash.ratio, turns, sub, !!fgeSplash.font, !!fgeSplash.logo].join("|");
  if (key === fgeSplash.drawn) return;
  fgeSplash.drawn = key;
  if (canvas.width !== cw || canvas.height !== ch) { canvas.width = cw; canvas.height = ch; }
  var ctx = fgeSplash.ctx || (fgeSplash.ctx = canvas.getContext("2d"));
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.fillStyle = fgeSplashColors.backdrop;
  ctx.fillRect(0, 0, cw, ch);
  if (dw <= 0 || dh <= 0) return;
  // 黒帯の付け方は RenderFrame.calcViewport と同じ（design の比のまま描き先に収まる最大の枠）。
  var vpW, vpH;
  if (cw / ch > dw / dh) { vpH = ch; vpW = Math.trunc(ch * dw / dh); } else { vpW = cw; vpH = Math.trunc(cw * dh / dw); }
  var vpX = Math.floor((cw - vpW) / 2), vpY = Math.floor((ch - vpH) / 2), k = vpW / dw;
  ctx.setTransform(k, 0, 0, k, vpX, vpY);
  ctx.imageSmoothingEnabled = false;
  var L = fgeSplashLayout(dw, dh);
  fgeSplash.layout = { L: L, k: k / dpr, x: vpX / dpr, y: vpY / dpr, dh: dh };
  if (fgeSplash.logo && L.logoH > 0) {
    var lw = L.logoH * fgeSplash.logo.naturalWidth / fgeSplash.logo.naturalHeight;
    ctx.drawImage(fgeSplash.logo, Math.floor(L.cx - lw / 2), L.logoTop, lw, L.logoH);
  }
  fgeSplashText(ctx, "Flix_GE", L, L.titleTop, fgeSplashColors.brand);
  ctx.globalAlpha = 0.18;
  ctx.fillStyle = fgeSplashColors.white;
  ctx.fillRect(L.gaugeLeft, L.gaugeTop, L.gaugeW, L.gaugeH);
  ctx.globalAlpha = 1;
  if (fgeSplash.ratio !== null) {
    var fw = Math.floor(L.gaugeW * fgeSplash.ratio);
    if (fw >= 1) ctx.fillRect(L.gaugeLeft, L.gaugeTop, fw, L.gaugeH);
  } else {
    var bw = Math.floor(L.gaugeW * 0.25);
    ctx.fillRect(L.gaugeLeft + Math.floor((L.gaugeW - bw) * turns), L.gaugeTop, bw, L.gaugeH);
  }
  // 2 本目の細い線: 後回しの素材。押すのを待たせる物ではないので、ゲージより細く薄く。
  if (sub !== null) {
    var sh = Math.max(1, Math.floor(L.gaugeH / 4));
    var sy = L.gaugeTop + L.gaugeH + sh;
    ctx.globalAlpha = 0.10;
    ctx.fillRect(L.gaugeLeft, sy, L.gaugeW, sh);
    ctx.globalAlpha = 0.75;
    ctx.fillStyle = fgeSplashColors.brand;
    ctx.fillRect(L.gaugeLeft, sy, Math.floor(L.gaugeW * sub), sh);
    ctx.globalAlpha = 1;
  }
  fgeSplashText(ctx, fgeSplash.phase, L, L.phaseTop, fgeSplashColors.dim);
  fgeSplashPlacePrompt();
}
// 「押して始める」の文言と指のアイコンを、一行の下の空きへ置く（CSS px）。
function fgeSplashPlacePrompt() {
  var el = document.getElementById("fge-start");
  var at = fgeSplash.layout;
  if (!el || !at) return;
  var L = at.L;
  var below = L.phaseTop + L.lineH;
  var y = at.y + (below + (at.dh - below) * 0.42) * at.k;
  var size = Math.max(15, Math.min(28, L.lineH * at.k * 0.55));
  el.style.top = y.toFixed(1) + "px";
  el.style.fontSize = size.toFixed(1) + "px";
}
function fgeSplashReady() {
  fgeSplash.ready = true;
  fgeProgress("ready", 1, 1);
  fgeShow("fge-start", true);
  fgeSplash.drawn = "";
}
// 触った点からの波紋（Material のリップル）。キーの時は文言の真ん中から。そのまま起動画面のゲージへつなぐ。
function fgeSplashTapped(e) {
  fgeSplash.tapped = true;
  var boot = document.getElementById("fge-boot");
  var start = document.getElementById("fge-start");
  var x = innerWidth / 2, y = innerHeight / 2;
  var point = e && e.changedTouches && e.changedTouches[0] ? e.changedTouches[0] : e;
  if (point && typeof point.clientX === "number" && (point.clientX !== 0 || point.clientY !== 0)) { x = point.clientX; y = point.clientY; }
  else if (start) { var r = start.getBoundingClientRect(); x = r.left + r.width / 2; y = r.top + r.height / 2; }
  if (boot) {
    var radius = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    var ripple = document.createElement("div");
    ripple.className = "fge-ripple";
    ripple.style.cssText = "left:" + (x - radius) + "px;top:" + (y - radius) + "px;width:" + (2 * radius) + "px;height:" + (2 * radius) + "px";
    ripple.addEventListener("animationend", function () { ripple.remove(); });
    boot.appendChild(ripple);
  }
  if (start) {
    start.classList.add("fge-leaving");
    setTimeout(function () { fgeShow("fge-start", false); }, 220);
  }
  fgeProgress("starting up...", 0, 0);
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
  fgeSplash.running = false;
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
// WhyNot: signal を止めた後は取り直さない — 止めるのは後回しの行列が取り直しへ回す時で、ここで取り直すと同じ道を 2 本取る。
async function fgeFetchBytes(path, signal) {
  var url = fgeVersioned(encodeURI(path));
  var last = null;
  for (var attempt = 0; attempt < 4; attempt++) {
    if (attempt > 0) await new Promise(function (r) { setTimeout(r, 500 * attempt * attempt); });
    if (signal && signal.aborted) throw new Error(path + " を取るのを止めた");
    try {
      var res = await fetch(url, signal ? { signal: signal } : undefined);
      if (res.ok) {
        var got = new Uint8Array(await res.arrayBuffer());
        fgeLoadLog.bytes += got.length;
        fgeLoadLog.count++;
        return got;
      }
      last = new Error(path + " を取れない（" + res.status + "）");
      last.status = res.status;
      if (res.status < 500) break;
    } catch (e) {
      if (signal && signal.aborted) throw e;
      last = new Error(path + " を取れない（" + e.message + "）");
    }
  }
  throw last;
}

// 書き出しが替えた配る道（WebP・Opus・gzip）。素材の表と画像の表には論理の道（project.json の道）で入れる。
var fgeTranscoded = {};
// 取ったバイトの和（?loadtime=1 の「押すまでに取った量」。wasm は TeaVM の load が取るので入らない）。
var fgeLoadLog = { bytes: 0, count: 0, tapped: false };
function fgeServedPath(path) { return fgeTranscoded[path] || path; }
// WhyNot: .gz を名前だけで解かない — 置き先によっては Content-Encoding: gzip を付けて配り、fetch が既に解いた中身が届く。
async function fgeFetchAsset(path, signal) {
  var served = fgeServedPath(path);
  var bytes = await fgeFetchBytes("assets/" + served, signal);
  if (/\.fontatlas-webp$/.test(served)) return await fgeJoinAtlasPixels(served, bytes);
  if (!/\.gz$/.test(served) || bytes.length < 2 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
  var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
// 画素だけを WebP にしたアトラス（go/exportweb_compress.go の webAtlasSuffix）を、元のアトラスのバイトに組み直す。
// 中身は「頭（52 バイト）・字の表（76 バイト × 字の数）・検算（16 バイト）」の後ろに、辺×辺の灰色の WebP。
// 組み直した物は RenderFontCache.decode が画素の検算（CRC32）で確かめるので、解き方の誤りは組み込みフォントへの切り替えとして出る。
// WhyNot: WebGL の readPixels で画素を取らない — 起動前で GL の文脈がまだ無い。2D の canvas は色空間の変換を切った ImageBitmap をそのまま写す。
async function fgeJoinAtlasPixels(served, bytes) {
  var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 52 || view.getUint32(0) !== 0x46474546 || view.getUint32(4) !== 0x4F4E5402) throw new Error(served + " はフォントアトラスの形でない");
  var side = view.getInt32(12);
  var tableEnd = 52 + view.getInt32(48) * 76;
  var restEnd = tableEnd + 16;
  if (side <= 0 || restEnd > bytes.length) throw new Error(served + " の頭の数が長さに合わない");
  var bitmap = await createImageBitmap(new Blob([bytes.subarray(restEnd)], { type: "image/webp" }),
    { premultiplyAlpha: "none", colorSpaceConversion: "none" });
  if (bitmap.width !== side || bitmap.height !== side) throw new Error(served + " の絵が " + bitmap.width + "x" + bitmap.height + "（頭は " + side + "）");
  var canvas = new OffscreenCanvas(side, side);
  var ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.drawImage(bitmap, 0, 0);
  bitmap.close();
  var rgba = ctx.getImageData(0, 0, side, side).data;
  var out = new Uint8Array(restEnd - 16 + side * side + 16);
  out.set(bytes.subarray(0, tableEnd), 0);
  for (var i = 0, o = tableEnd; i < side * side; i++, o++) out[o] = rgba[i * 4];
  out.set(bytes.subarray(tableEnd, restEnd), tableEnd + side * side);
  return out;
}
function fgeImageType(path) {
  var ext = (/\.([a-z0-9]+)$/i.exec(path) || [])[1];
  return { webp: "image/webp", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg" }[(ext || "").toLowerCase()] || "";
}
// WhyNot: 解けない音で起動を止めない — 古い Safari は Opus を解けない。元の wav があれば取り直し、それも駄目ならその音だけ黙らせる。
async function fgeDecodeSound(s, signal) {
  try {
    return await fgeAudio.ctx.decodeAudioData((await fgeFetchAsset(s.path, signal)).buffer);
  } catch (e) {
    if (fgeServedPath(s.path) === s.path || (signal && signal.aborted)) throw e;
    console.warn("[fge] " + fgeServedPath(s.path) + " を解けないので " + s.path + " を取り直す（" + (e && e.message || e) + "）");
    return await fgeAudio.ctx.decodeAudioData((await fgeFetchBytes("assets/" + s.path, signal)).buffer);
  }
}
function fgeAddSound(s, buffer) {
  fgeWarnSoundLength([s], buffer);
  fgeAddDecodedSound(s, buffer);
}
// 圧縮で頭や末尾に詰め物が残るブラウザだと、ループの継ぎ目と seconds() がデスクトップとずれる。
function fgeWarnSoundLength(sounds, buffer) {
  var s = sounds[0];
  if (s.seconds > 0 && Math.abs(buffer.duration - s.seconds) > 2 / buffer.sampleRate) {
    console.warn("[fge] 音 " + sounds.map(function (x) { return x.name; }).join("・") + " の長さが元と違う（" + buffer.duration.toFixed(5) + " 秒・元は " + s.seconds.toFixed(5) + " 秒）");
  }
}
function fgeAddDecodedSound(s, buffer) {
  var gain = fgeAudio.ctx.createGain();
  gain.connect(fgeAudio.master);
  fgeAudio.sounds.set(s.name, { buffer: buffer, gain: gain, loop: !!s.looping, pitch: 1, source: null,
    loopStart: s.loopStart || 0, loopEnd: s.loopEnd || s.seconds || 0 });
}
function fgeBitmapOf(bytes, path) {
  // WhyNot: 型を空にしない — 中身から形式を見分けるのに頼ると、ブラウザによって WebP を絵と見なさない恐れがある。
  return createImageBitmap(new Blob([bytes], { type: fgeImageType(fgeServedPath(path)) }), { premultiplyAlpha: "none", colorSpaceConversion: "none" });
}

// ── 後回しの素材（bundle.json の deferred）──
// 状態は queued → downloading → downloaded（files は素材の表・絵は ImageBitmap にある）→ loaded（絵は WebLayer が登録した・音は解いた）。
// 取れなければ failed。failed は間を置いて queued へ戻す（4xx は戻さない）。
// 解き終えて生のバイトを捨てた files は released（stateOf は queued と言い、頼まれたら取り直す）。
var fgeDeferred = { entries: [], byPath: new Map(), byName: new Map(), queue: [], running: 0, started: false, wasmReady: false, bootReady: false, hiddenAt: -1 };
var fgeDeferredLimit = 2;
// WhyNot: 隠れていた間の短いタブ切り替えでは取り直さない — デスクトップでは裏でも取り続けていて、途中まで取った分を捨てる。
var fgeDeferredStaleMs = 2000;
// WhyNot: 失敗した物をすぐ取り直さない — 回線が落ちている間に毎コマの request で戻すと、取っては失敗するのを繰り返して電池を食う。
var fgeDeferredRetryMs = 5000;
// WhyNot: online だけを待たない — iOS Safari は電波が弱い間に online を出さないまま戻り、失敗した物が取られないまま残る。
var fgeDeferredSweepMs = 30000;

function fgeDeferredPrepare(bundle, files, images, sounds) {
  (bundle.deferred || []).forEach(function (d) {
    var e = { path: fgeNormPath(d.path), bytes: d.bytes || 0, names: d.names || [], file: false, image: false, sounds: [],
              state: "queued", why: "", arrivedAtRelease: false, permanent: false, failedAt: 0, gen: 0, abort: null, startedAt: 0 };
    fgeDeferred.entries.push(e);
    fgeDeferred.byPath.set(e.path, e);
    e.names.forEach(function (name) { fgeDeferred.byName.set(name, e); });
  });
  files.forEach(function (path) { var e = fgeDeferred.byPath.get(fgeNormPath(path)); if (e) e.file = true; });
  images.forEach(function (path) { var e = fgeDeferred.byPath.get(fgeNormPath(path)); if (e) e.image = true; });
  sounds.forEach(function (s) {
    var e = fgeDeferred.byPath.get(fgeNormPath(s.path));
    if (e) { e.sounds.push(s); fgeDeferred.byName.set(s.name, e); }
  });
}
function fgeIsDeferredPath(path) { return fgeDeferred.byPath.has(fgeNormPath(path)); }
function fgeDeferredIsDeferred(nameOrPath) { return fgeDeferred.byName.has(nameOrPath) || fgeIsDeferredPath(nameOrPath); }
function fgeDeferredEntry(nameOrPath) { return fgeDeferred.byPath.get(fgeNormPath(nameOrPath)) || fgeDeferred.byName.get(nameOrPath); }
// 後回しでない道は起動の前に全部そろっているので loaded。
// WhyNot: released を downloaded と言わない — 別のグループが同じ道を届いたと見て読み、無いバイトで Failed に固まる。
function fgeDeferredState(nameOrPath) {
  var e = fgeDeferredEntry(nameOrPath);
  if (!e) return "loaded";
  if (e.state === "released") return "queued";
  return e.state === "failed" ? "failed:" + e.why : e.state;
}
// WhyNot: 絵と音を素材の表に入っただけで「届いた」にしない — 絵は WebLayer が登録するまで描けず、音は解くまで鳴らせない。
function fgeDeferredArrived(e) {
  if (e.state === "released") return e.arrivedAtRelease;
  return e.state === "loaded" || (e.state === "downloaded" && !e.image && e.sounds.length === 0);
}
function fgeDeferredMissing() {
  var out = [];
  fgeDeferred.entries.forEach(function (e) {
    if (fgeDeferredArrived(e)) return;
    if (e.names.length > 0) e.names.forEach(function (n) { out.push(n); }); else out.push(e.path);
  });
  return out.join("\n");
}
function fgeDeferredRetryable(e, minAgeMs) { return e.state === "failed" && !e.permanent && performance.now() - e.failedAt >= minAgeMs; }
function fgeDeferredRequeue(e) {
  e.state = "queued";
  e.why = "";
}
// WhyNot: 前から順に頭へ入れない — 頼まれた並びが逆になる。
function fgeDeferredRequest(joined) {
  var paths = String(joined).split("\n").filter(function (p) { return p.length > 0; });
  for (var i = paths.length - 1; i >= 0; i--) {
    var e = fgeDeferred.byPath.get(fgeNormPath(paths[i]));
    if (!e) continue;
    if (fgeDeferredRetryable(e, fgeDeferredRetryMs) || e.state === "released") fgeDeferredRequeue(e);
    if (e.state !== "queued") continue;
    var at = fgeDeferred.queue.indexOf(e);
    if (at >= 0) fgeDeferred.queue.splice(at, 1);
    fgeDeferred.queue.unshift(e);
  }
  fgeDeferredPump();
}
function fgeDeferredRetryFailed(minAgeMs) {
  fgeDeferred.entries.forEach(function (e) {
    if (!fgeDeferredRetryable(e, minAgeMs)) return;
    fgeDeferredRequeue(e);
    fgeDeferred.queue.push(e);
  });
  fgeDeferredPump();
}
// WhyNot: 2D の絵の ImageBitmap を登録の後も持たない — テクスチャへ上げた後は読まれず、iOS Safari の 1 タブのメモリを食う。files にもある絵は readBytes と platformImage が使うので残す。
function fgeDeferredMarkLoaded(path) {
  var e = fgeDeferred.byPath.get(fgeNormPath(path));
  if (!e || e.state === "loaded") return;
  e.state = "loaded";
  if (e.image && !e.file) {
    var bmp = fgeImages.get(e.path);
    if (bmp) { bmp.close(); fgeImages.delete(e.path); }
  }
  fgeDeferredNote(e);
}
// WhyNot: 解き終えた後回しの files の生のバイトを持ち続けない — iOS Safari の 1 タブのメモリに、3D の部屋の glb が解いた形と二重に載る。
// WhyNot: 後回しでない道は捨てない — 起動の素材はゲームが何度でも読む前提で書かれている。ImageBitmap にした絵は空のバイトのまま残す（fgeHoldImage）。
function fgeDeferredRelease(joined) {
  String(joined).split("\n").forEach(function (path) {
    var p = fgeNormPath(path);
    var e = fgeDeferred.byPath.get(p);
    if (!e || fgeHeldImages.has(p) || !fgeAssets.has(p)) return;
    fgeAssets.delete(p);
    if (e.state === "downloaded" || e.state === "loaded") {
      e.arrivedAtRelease = fgeDeferredArrived(e);
      e.state = "released";
    }
  });
}
function fgeDeferredNote(e) {
  if (fgeDecodeTimes === null) return;
  console.log("[loadtime] deferred " + e.path + " " + e.bytes + " B " + fgeDeferredState(e.path) + " at " + performance.now().toFixed(0) + " ms" +
    (e.startedAt > 0 ? "（取り始めから " + (performance.now() - e.startedAt).toFixed(0) + " ms）" : ""));
}
// WhyNot: wasm の load だけを待って始めない — 起動の素材を取っている最中に回線を取り合い、「タッチして開始」が遅れる。
// WhyNot: 起動の素材だけを待って始めない — wasm より先に回線を使い、押してから main までが延びる。
function fgeDeferredStart() {
  if (fgeDeferred.started || !fgeDeferred.wasmReady || !fgeDeferred.bootReady) return;
  fgeDeferred.started = true;
  fgeDeferred.queue = fgeDeferred.entries.filter(function (e) { return e.state === "queued"; });
  fgeDeferredPump();
}
function fgeDeferredPump() {
  if (!fgeDeferred.started) return;
  while (fgeDeferred.running < fgeDeferredLimit && fgeDeferred.queue.length > 0) {
    var e = fgeDeferred.queue.shift();
    if (e.state === "queued") fgeDeferredFetch(e);
  }
}
// WhyNot: 4xx を取り直さない — 束に無い・道の誤りで、何度取っても同じ答え。408（待ちすぎ）と 429（頼みすぎ）は回線の都合なので取り直す。
function fgeIsPermanentFailure(err) {
  var status = err && err.status;
  return typeof status === "number" && status >= 400 && status < 500 && status !== 408 && status !== 429;
}
function fgeDeferredFetch(e) {
  var gen = ++e.gen;
  var ctl = typeof AbortController === "function" ? new AbortController() : null;
  e.state = "downloading";
  e.abort = ctl;
  e.startedAt = performance.now();
  fgeDeferred.running++;
  fgeDeferredReceive(e, gen, ctl ? ctl.signal : undefined).then(function () {
    if (e.gen === gen) fgeDeferredNote(e);
  }, function (err) {
    if (e.gen !== gen) return;
    e.state = "failed";
    e.why = String(err && err.message || err);
    e.permanent = fgeIsPermanentFailure(err);
    e.failedAt = performance.now();
    console.warn("[fge] 後回しの素材 " + e.path + (e.sounds.length > 0 ? "（音 " + e.sounds.map(function (s) { return s.name; }).join("・") + "）" : "") + " を取れない — " + (e.permanent ? "取り直さない" : "間を置いて取り直す") + ": " + e.why);
    fgeDeferredNote(e);
  }).then(function () {
    if (e.gen === gen) { e.abort = null; fgeDeferred.running--; }
    fgeDeferredPump();
  });
}
// WhyNot: 同じ道を名前ごとに解かない — 1 本の音を 2 つの名前で宣言すると、取るのも解くのも 2 回になる。解いた物を全部の名前で使う。
async function fgeDeferredReceive(e, gen, signal) {
  if (e.sounds.length > 0) {
    var buffer = await fgeDecodeSound(e.sounds[0], signal);
    if (e.gen !== gen) return;
    fgeWarnSoundLength(e.sounds, buffer);
    e.sounds.forEach(function (s) { fgeAddDecodedSound(s, buffer); });
    e.state = "loaded";
    return;
  }
  var bytes = await fgeFetchAsset(e.path, signal);
  if (e.gen !== gen) return;
  if (e.file) fgeAssets.set(e.path, bytes);
  if (e.image) {
    var bitmap = await fgeBitmapOf(bytes, e.path);
    if (e.gen !== gen) { bitmap.close(); return; }
    fgeImages.set(e.path, bitmap);
  }
  e.state = "downloaded";
}
function fgeDeferredRestart(e) {
  e.gen++;
  if (e.abort) e.abort.abort();
  e.abort = null;
  e.state = "queued";
  fgeDeferred.running--;
  fgeDeferred.queue.unshift(e);
}
function fgeWireDeferred() {
  window.addEventListener("online", function () { fgeDeferredRetryFailed(0); });
  setInterval(function () { if (!document.hidden) fgeDeferredRetryFailed(fgeDeferredRetryMs); }, fgeDeferredSweepMs);
  // WhyNot: 裏から戻った時に取りかけの物を待ち続けない — iOS Safari は裏で通信を止め、切れた fetch が返らないままになる事がある。
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { fgeDeferred.hiddenAt = performance.now(); return; }
    var hiddenAt = fgeDeferred.hiddenAt;
    fgeDeferred.hiddenAt = -1;
    fgeDeferredRetryFailed(0);
    if (hiddenAt < 0 || performance.now() - hiddenAt < fgeDeferredStaleMs) return;
    fgeDeferred.entries.filter(function (e) { return e.state === "downloading" && e.startedAt < hiddenAt; })
      .reverse().forEach(fgeDeferredRestart);
    fgeDeferredPump();
  });
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
  fgeSplashInit(bundle);
  if (fgeWeb.virtualPad) fgeBuildPad(fgeWeb.virtualPad);
  fgeApplyLayout();
  window.addEventListener("resize", fgeApplyLayout);
  if (fgeCoarseQuery && fgeCoarseQuery.addEventListener) fgeCoarseQuery.addEventListener("change", fgeApplyLayout);
  var allFiles = bundle.files || [];
  var allSounds = bundle.sounds || [];
  var allImages = bundle.images || [];
  fgeDeferredPrepare(bundle, allFiles, allImages, allSounds);
  fgeWireDeferred();
  var files = allFiles.filter(function (path) { return !fgeIsDeferredPath(path); });
  var sounds = allSounds.filter(function (s) { return !fgeIsDeferredPath(s.path); });
  var images = allImages.filter(function (path) { return !fgeIsDeferredPath(path); });
  var inFiles = new Set(files);
  var total = files.length + sounds.length + images.filter(function (path) { return !inFiles.has(path); }).length;
  var done = 0;
  // WhyNot: 押した後に音を解かない — 止まったままの AudioContext でも decodeAudioData は使えるので、素材を取る間に解き終えておく。
  var Ctx = window.AudioContext || window.webkitAudioContext;
  fgeAudio.ctx = new Ctx();
  fgeAudio.master = fgeAudio.ctx.createGain();
  fgeAudio.master.connect(fgeAudio.ctx.destination);
  // WhyNot: wasm を押した後に取らない — 押してから最初のコマまでに取る・compile・instantiate が全部乗る。main は GL の文脈を作った後（押した後）に呼ぶ。
  var wasmFailed = null;
  var wasmLoad = TeaVM.wasmGC.load(fgeVersioned("classes.wasm")).then(function (teavm) {
    if (fgeDecodeTimes !== null) console.log("[loadtime] wasm を読み終えた " + performance.now().toFixed(0) + " ms");
    fgeDeferred.wasmReady = true;
    fgeDeferredStart();
    return teavm;
  }, function (e) {
    wasmFailed = "このブラウザは WebAssembly GC に対応していないか、wasm を読めません（Chrome 119 以降・Safari 18.2 以降で開いてください）: " + (e && e.message || e);
    fgeShow("fge-start", false);
    fgeError(wasmFailed);
    return null;
  });
  fgeProgress("loading assets...", 0, total);
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
      fgeAddSound(s, buffer);
    };
  }));
  await fgeEachLimited(jobs, 6, async function (job) {
    await job();
    fgeProgress("loading assets...", ++done, total);
  });
  // WhyNot: files にもある絵を取り直さない — 同じ URL を 2 回運ぶ。readBytes のために生のバイトが表に残るメモリは、3D の入口の速さを問わない範囲として受ける。
  await fgeEachLimited(images, 6, async function (path) {
    var kept = fgeAssets.get(fgeNormPath(path));
    fgeImages.set(fgeNormPath(path), await fgeBitmapOf(kept || await fgeFetchAsset(path), path));
    if (!kept) fgeProgress("loading assets...", ++done, total);
  });
  fgeDeferred.bootReady = true;
  fgeDeferredStart();
  if (wasmFailed !== null) return;
  fgeSplashReady();
  if (fgeDecodeTimes !== null) console.log("[loadtime] タッチして開始まで " + performance.now().toFixed(0) + " ms");
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
      fgeNoteTap();
      fgeSplashTapped(e);
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
  var teavm = await wasmLoad;
  if (teavm === null) return;
  try {
    teavm.exports.main([]);
  } catch (e) {
    fgeError("止まりました: " + (e && e.stack || e));
  }
}

function fgeNoteTap() {
  if (fgeDecodeTimes === null || fgeLoadLog.tapped) return;
  fgeLoadLog.tapped = true;
  var got = fgeDeferred.entries.filter(function (e) { return e.state === "downloaded" || e.state === "loaded"; });
  var deferredBytes = got.reduce(function (a, e) { return a + e.bytes; }, 0);
  console.log("[loadtime] 押すまでに取った量 " + fgeLoadLog.bytes + " B（起動の素材 " + (fgeLoadLog.bytes - deferredBytes) + " B・後回し " + got.length + "/" +
    fgeDeferred.entries.length + " 本 " + deferredBytes + " B・wasm は別）at " + performance.now().toFixed(0) + " ms");
}

// WhyNot: load だけを待たない — index.html の起動役は version.txt を確かめてからこの js を読むので、読み終えた時には load が済んでいることがある。
function fgeStart() { fgeBoot().catch(function (e) { fgeError("起動できません: " + (e && e.stack || e)); }); }
if (document.readyState === "complete") fgeStart(); else window.addEventListener("load", fgeStart);
