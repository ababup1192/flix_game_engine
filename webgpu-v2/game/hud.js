// ?hud=1 の時だけ、描き手（URL の backend と console の [backend] の行）と fps を左下に出す。
(function () {
  var q = new URLSearchParams(location.search);
  if (!q.has("hud")) return;
  var lines = [], fps = "", d = null;
  function render() { if (d) d.textContent = "URL: " + (q.get("backend") === "webgpu" ? "webgpu" : "gl") + "  " + fps + (lines.length ? "\n" + lines.join("\n") : ""); }
  ["log", "warn", "info"].forEach(function (k) {
    var o = console[k];
    console[k] = function () {
      try { var s = Array.prototype.join.call(arguments, " "); if (s.indexOf("[backend]") >= 0) { lines.push(s.slice(0, 140)); render(); } } catch (e) {}
      return o.apply(console, arguments);
    };
  });
  document.addEventListener("DOMContentLoaded", function () {
    d = document.createElement("div");
    d.style.cssText = "position:fixed;left:4px;bottom:4px;z-index:10000;font:11px/1.3 monospace;color:#7f7;background:rgba(0,0,0,.65);padding:2px 5px;pointer-events:none;white-space:pre-wrap;max-width:96vw";
    document.body.appendChild(d); render();
  });
  var n = 0, t0 = performance.now();
  function tick(t) { n++; if (t - t0 >= 1000) { fps = (n * 1000 / (t - t0)).toFixed(1) + " fps"; n = 0; t0 = t; render(); } requestAnimationFrame(tick); }
  requestAnimationFrame(tick);
})();
