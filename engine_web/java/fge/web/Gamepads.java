package fge.web;

import org.teavm.jso.JSBody;

/**
 * ブラウザのゲームパッド（navigator.getGamepads の 1 台目）と、指の端末の画面のスティック（web.virtualPad.stick）。
 * 読む式は fge-web.js の fgeGamepadAxis。つないでいない・読めない端末は 0 を返す。
 */
public final class Gamepads {
    private Gamepads() { }

    /** 軸 index の生の値（-1..1・右と下が正。Standard Gamepad は 0・1 が左・2・3 が右のスティック）。 */
    @JSBody(params = {"index"}, script = "return fgeGamepadAxis(index);")
    public static native double axis(int index);
}
