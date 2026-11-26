// X1 案 c のスパイク: engine の頁の requestAnimationFrame を包み、溜めた callback を外から 1 つずつ呼んで、
// その呼び出しの中で engine の 1 コマが submit まで進み、次の rAF を予約してから戻るかを数える。
// 書き出した頁の index.html で fge-web.js より前に読ませる（harness/spike/run-spike.mjs が差し込む）。
// 結果は window.__spike（run-spike.mjs が CDP で読む）。
(function () {
  "use strict";
  var realRaf = window.requestAnimationFrame.bind(window);
  var s = {
    queue: [],
    started: false,
    pumping: false,
    submitsTotal: 0,
    submitsInside: 0,
    presentsInside: 0,
    frames: [],
    outsideSubmits: 0,
    clock: 0
  };
  window.__spike = s;

  window.requestAnimationFrame = function (cb) {
    s.queue.push(cb);
    return s.queue.length;
  };

  var submit = GPUQueue.prototype.submit;
  GPUQueue.prototype.submit = function () {
    s.submitsTotal++;
    if (s.pumping) s.submitsInside++; else s.outsideSubmits++;
    s.started = true;
    return submit.apply(this, arguments);
  };
  var current = GPUCanvasContext.prototype.getCurrentTexture;
  GPUCanvasContext.prototype.getCurrentTexture = function () {
    if (s.pumping) s.presentsInside++;
    return current.apply(this, arguments);
  };

  // harness の frame(t, dt) に当たる 1 回: 溜まっている callback を全部呼ぶ。呼ぶ時刻はコマの番号 × 16.67 ms の単調な時計。
  function frame() {
    var batch = s.queue.splice(0, s.queue.length);
    s.clock += 1000 / 60;
    var submits0 = s.submitsInside, presents0 = s.presentsInside;
    var t0 = performance.now();
    s.pumping = true;
    for (var i = 0; i < batch.length; i++) batch[i](s.clock);
    s.pumping = false;
    var t1 = performance.now();
    if (s.started) {
      s.frames.push({
        called: batch.length,
        ms: t1 - t0,
        submits: s.submitsInside - submits0,
        presents: s.presentsInside - presents0,
        requeued: s.queue.length
      });
    }
  }

  // 押して始める画面を通す（keydown を待つ）。始まるまで 100 ms ごとに送る。
  function tap() {
    if (s.started) return;
    window.dispatchEvent(new KeyboardEvent("keydown", { code: "Space", key: " " }));
    setTimeout(tap, 100);
  }
  setTimeout(tap, 100);

  function loop() {
    frame();
    if (s.frames.length < 600) realRaf(loop);
  }
  realRaf(loop);
})();
