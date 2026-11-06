// 指の押し・動き・離しを、マウスと同じ形でゲームへ渡す橋。bin/export-web.sh が書き出した頁の fge-web.js の後ろへ足す。
// fge-web.js は指を canvas の上で「離した時のタップ」と「縦の動き = ホイール」にしか写さず、押している間の点をゲームへ渡さない。
// ゆっくり振り向く操作は指の今の点が要るので、canvas の上の一番新しい指をマウスの左ボタンとして fgePointer へ書く。
// WhyNot: engine の fge-web.js を書き換えない — engine はこのゲームの担当の外。engine が指の点を渡すようになったら、この橋は消す。
(function () {
  var active = null;
  var waiting = null;
  function toCanvas(e) {
    var rect = fgeCanvas.getBoundingClientRect();
    return { x: (e.clientX - rect.left) * fgeCanvas.width / Math.max(1, rect.width), y: (e.clientY - rect.top) * fgeCanvas.height / Math.max(1, rect.height) };
  }
  function place(e) {
    var p = toCanvas(e);
    fgePointer.x = p.x;
    fgePointer.y = p.y;
  }
  function isFinger(e) { return e.pointerType === "touch"; }
  function press() {
    fgePointer.buttons[0] = true;
    fgePointer.latch[0] = true;
  }
  // WhyNot: 2 本目の指を捨てない — 片手が画面に触れたままだと、もう一方の手の押しが全部消える。
  // WhyNot: ボタンを押したまま持ち替えない — ゲームは離しを見ないと次の押しと数えないので、2 コマ離してから押す。
  function pressAfterLift(id) {
    waiting = id;
    fgePointer.buttons[0] = false;
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        if (waiting !== id) return;
        waiting = null;
        press();
      });
    });
  }
  window.addEventListener("pointerdown", function (e) {
    if (!isFinger(e) || e.target !== fgeCanvas) return;
    e.stopImmediatePropagation();
    var held = active !== null;
    active = e.pointerId;
    fgePointer.touch = true;
    place(e);
    if (held) pressAfterLift(e.pointerId);
    else press();
  }, true);
  window.addEventListener("pointermove", function (e) {
    if (e.pointerId !== active) return;
    e.stopImmediatePropagation();
    place(e);
  }, true);
  function lift(e) {
    if (e.pointerId !== active) return;
    active = null;
    if (waiting === e.pointerId) {
      waiting = null;
      fgePointer.latch[0] = true;
    }
    fgePointer.buttons[0] = false;
  }
  window.addEventListener("pointerup", lift, true);
  window.addEventListener("pointercancel", lift, true);
})();
