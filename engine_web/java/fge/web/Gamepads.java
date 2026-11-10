package fge.web;

import org.teavm.jso.JSBody;

/** ブラウザのゲームパッド（navigator.getGamepads の 1 台目）。つないでいない・読めない端末は 0 を返す。 */
public final class Gamepads {
    private Gamepads() { }

    /** 1 台目のパッドの軸 index の生の値（-1..1・右と下が正。Standard Gamepad は 0・1 が左・2・3 が右のスティック）。 */
    @JSBody(params = {"index"}, script =
        "var list = (navigator.getGamepads ? navigator.getGamepads() : []) || [];"
      + "for (var i = 0; i < list.length; i++) {"
      + "  var g = list[i];"
      + "  if (g && g.connected) { var v = g.axes[index]; return (typeof v === 'number' && isFinite(v)) ? v : 0; }"
      + "}"
      + "return 0;")
    public static native double axis(int index);
}
