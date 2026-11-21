// fge-switches.js — 頁の旗の読み手。URL の ?fge=<語>,<語>,… と、道具が頁より先に入れる window.fgeDev と、前の鍵（?fps=1 など）を 1 つの形にする。
// 書き出し（bin/fge export-web）が index.html の頭と sw.js に中身を埋める。字の決まりは docs/web-export.md の「頁の旗」。
// WhyNot: 頁の JS・頭の script・Service Worker のそれぞれで読まない — ?fge= の字の決まりが 3 つに分かれ、テーブルのテスト（testdata/web-switches.cases.json）を 1 本で流せない。
// WhyNot: 読み出しの関数の外で window を触らない — Service Worker（window が無い）にも同じ中身を埋める。
"use strict";

// 1 行 = 1 つの旗。field は window.fgeDev と読んだ結果の欄の名前・name は ?fge= の名前（小文字）・values は取れる値（無ければ真偽・"int" は正の整数）・
// short は値だけで書ける語・legacy は前の鍵（読んだら知らせる。sw だけは期限なしで知らせない）。
var FGE_SWITCHES = [
  { field: "fps", name: "fps", legacy: "fps" },
  { field: "backend", name: "backend", values: ["webgl2", "gl", "webgpu"], short: ["webgl2", "gl", "webgpu"], legacy: "backend" },
  { field: "net", name: "net", values: ["4g"], short: ["4g"], legacy: "net" },
  { field: "sw", name: "sw", values: ["0"], short: [], legacy: "sw", keep: true },
  { field: "input", name: "input", values: ["touch", "mouse"], short: ["touch", "mouse"], legacy: "input" },
  { field: "orientation", name: "orientation", values: ["portrait", "landscape"], short: ["portrait", "landscape"], legacy: "orientation" },
  { field: "size", name: "size", values: ["small", "medium", "large"], short: ["small", "medium", "large"], legacy: "size" },
  { field: "glcheck", name: "glcheck", legacy: "glcheck" },
  { field: "loadtime", name: "loadtime", legacy: "loadtime" },
  { field: "capture", name: "capture", values: "int", legacy: "capture" },
  { field: "deferred", name: "deferred", values: ["all"], short: [], legacy: "deferred" },
  { field: "usedAssets", name: "usedassets", legacy: "usedAssets" },
  { field: "webgpuFail", name: "webgpufail", values: ["prepare", "canvas"], short: [], legacy: "webgpuFail" }
];

// 何も頼まれていない時の値。backend の "" は既定（WebGPU を使えれば WebGPU）。
function fgeSwitchDefaults() {
  return { fps: false, backend: "", net: "", sw: true, input: "", orientation: "", size: "", glcheck: false, loadtime: false,
           capture: 0, deferred: "", usedAssets: false, webgpuFail: "" };
}

// 旗 s の字の値 raw を欄の値にする（読めなければ undefined）。前の鍵の真偽は "1" だけを真と読む。
function fgeSwitchValueOf(s, raw) {
  var v = String(raw).toLowerCase();
  if (s.field === "sw") return v === "0" ? false : undefined;
  if (s.field === "backend") return v === "webgl2" || v === "gl" ? "webgl2" : (v === "webgpu" ? "" : undefined);
  if (s.values === "int") { var n = /^[0-9]+$/.test(v) ? parseInt(v, 10) : 0; return n > 0 ? n : undefined; }
  if (!s.values) return v === "1" ? true : undefined;
  return s.values.indexOf(v) >= 0 ? v : undefined;
}

function fgeSwitchOf(field) {
  return FGE_SWITCHES.filter(function (s) { return s.field === field; })[0];
}

// window.fgeDev の欄の値 v を欄の値にする（読めなければ undefined）。真偽と数はそのまま・字は ?fge= の値と同じ読み方。
function fgeSwitchDevValueOf(s, v) {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "boolean") return s.field === "sw" || !s.values ? v : undefined;
  if (typeof v === "number") return s.values === "int" && v > 0 ? Math.floor(v) : undefined;
  return fgeSwitchValueOf(s, v);
}

// ?fge= の 1 語を { s, value } にする（知らない語は null）。
function fgeSwitchWordOf(word) {
  var w = word.toLowerCase();
  if (w === "nosw") return { s: fgeSwitchOf("sw"), value: false };
  var colon = w.indexOf(":");
  var name = colon < 0 ? w : w.slice(0, colon);
  for (var i = 0; i < FGE_SWITCHES.length; i++) {
    var s = FGE_SWITCHES[i];
    if (colon < 0 && s.short && s.short.indexOf(w) >= 0) return { s: s, value: fgeSwitchValueOf(s, w) };
    if (s.name !== name) continue;
    if (colon < 0) return s.values ? null : { s: s, value: true };
    var value = s.values ? fgeSwitchValueOf(s, w.slice(colon + 1)) : undefined;
    return value === undefined ? null : { s: s, value: value };
  }
  return null;
}

// 頁の旗を読む。search は location.search の形（"?a=1&fge=fps"）・dev は window.fgeDev（無ければ null）。
// 返す物: switches（全部の欄）・legacy（読んだ前の鍵ごとに { from: "fps=1", to: "fps" }）・unknown（?fge= の知らない語）。
// 旗ごとに window.fgeDev → ?fge= → 前の鍵の順で、最初に値を持つ所を使う。同じ旗が ?fge= に 2 回あれば後の語。
// WhyNot: backend を順で上書きしない — WebGPU で落ちて開き直した頁は URL に webgl2 を持つ。fgeDev が別の値でも webgl2 を取らないと開き直しを繰り返す。
// WhyNot: 知らない語で止めない — 打ち間違いも、後の版の語を前の版の頁で開いた時も、旗が効かないだけで遊べる。
function fgeReadSwitches(search, dev) {
  var out = fgeSwitchDefaults();
  var params = new URLSearchParams(search || "");
  var fromWords = {}, legacy = [], unknown = [];
  (params.get("fge") || "").split(",").forEach(function (raw) {
    var word = raw.trim();
    if (word.length === 0) return;
    var got = fgeSwitchWordOf(word);
    if (got === null) unknown.push(word);
    else fromWords[got.s.field] = got.value;
  });
  var webgl2 = false;
  FGE_SWITCHES.forEach(function (s) {
    var old = params.get(s.legacy);
    var fromLegacy = old === null ? undefined : fgeSwitchValueOf(s, old);
    if (old !== null && !s.keep) legacy.push({ from: s.legacy + "=" + old, to: fgeSwitchWordFor(s, old) });
    var fromDev = dev ? fgeSwitchDevValueOf(s, dev[s.field]) : undefined;
    var picked = [fromDev, fromWords[s.field], fromLegacy].filter(function (v) { return v !== undefined; });
    if (s.field === "backend") webgl2 = picked.indexOf("webgl2") >= 0;
    if (picked.length > 0) out[s.field] = picked[0];
  });
  out.backend = webgl2 ? "webgl2" : "";
  return { switches: out, legacy: legacy, unknown: unknown };
}

// 前の鍵の旗 s の値 raw に当たる ?fge= の語（前の鍵の知らせに出す）。
function fgeSwitchWordFor(s, raw) {
  var v = String(raw).toLowerCase();
  if (!s.values) return s.name;
  if (s.short && s.short.indexOf(v) >= 0) return v;
  return fgeSwitchValueOf(s, v) === undefined ? s.name + ":…" : s.name + ":" + v;
}

// search の ?fge= に word を足した search（前の鍵 drop は外す）。WebGPU で落ちた頁を webgl2 で開き直す時に使う。
function fgeSearchWithWord(search, word, drop) {
  var params = new URLSearchParams(search || "");
  var words = (params.get("fge") || "").split(",").map(function (w) { return w.trim(); }).filter(function (w) { return w.length > 0; });
  if (words.indexOf(word) < 0) words.push(word);
  params.set("fge", words.join(","));
  if (drop) params.delete(drop);
  return "?" + params.toString().replace(/%2C/gi, ",").replace(/%3A/gi, ":");
}

// この頁の旗（頁で 1 回だけ読む。頭の script と fge-web.js が同じ答えを使う）。
function fgePageSwitches() {
  if (!window.fgeSwitchesRead) window.fgeSwitchesRead = fgeReadSwitches(location.search, window.fgeDev || null);
  return window.fgeSwitchesRead;
}
