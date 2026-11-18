// measure.js — 昼の町のブラウザ版の頁に足す script（make explore-web が index.html の fge-web.js より前へ差し込む）。
// ?dpr=<数> … 描き先の画素の細かさ（window.devicePixelRatio）を差し替える（描く解像度を落とす手。0.5 なら CSS px 2 つに 1 画素）。
// ?measure=1 … 押せるようになるまで・押してから最初のコマまでの時間を頁の左下に出す（1 コマの時間は engine の ?fps=1 が左上に出す）。
// WhyNot: engine_web の fge-web.js に入れない — 描く解像度の差し替えと起動の時間の表示は、この試作の重さを測る段取りだけが使う。
(function () {
  "use strict";
  var q = new URLSearchParams(location.search);
  var dpr = parseFloat(q.get("dpr") || "");
  if (dpr > 0) Object.defineProperty(window, "devicePixelRatio", { get: function () { return dpr; }, configurable: true });
  if (q.get("measure") !== "1") return;

  var tappedAt = null, readyAt = null;
  var mark = function () { if (tappedAt === null && readyAt !== null) tappedAt = performance.now(); };
  ["pointerdown", "touchstart", "keydown"].forEach(function (name) { addEventListener(name, mark, true); });

  var poll = setInterval(function () {
    if (readyAt === null && window.fgeSplash && window.fgeSplash.ready) readyAt = performance.now();
    var boot = document.getElementById("fge-boot");
    if (boot && boot.style.display === "none") { clearInterval(poll); show(performance.now()); }
  }, 50);

  function ms(v) { return v === null ? "-" : Math.round(v) + " ms"; }

  function show(firstFrame) {
    var canvas = document.getElementById("fge-canvas");
    var line = "押せるまで " + ms(readyAt) + " / 押してから最初のコマまで " + ms(tappedAt === null ? null : firstFrame - tappedAt) +
      " / canvas " + (canvas ? canvas.width + "x" + canvas.height : "-") + " / dpr " + (window.devicePixelRatio || 1) + " / " + location.search;
    console.log("[measure] " + line);
    var box = document.createElement("div");
    box.style.cssText = "position:fixed;left:8px;bottom:calc(8px + env(safe-area-inset-bottom,0px));z-index:9999;padding:4px 8px;" +
      "font:12px/1.4 ui-monospace,Menlo,monospace;color:#fff;background:rgba(0,0,0,.65);pointer-events:none;max-width:90vw";
    box.textContent = line;
    document.body.appendChild(box);
  }
})();
