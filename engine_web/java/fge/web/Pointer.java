package fge.web;

import org.teavm.jso.JSBody;

/** マウス（pointer）の表。位置は canvas の描き先の画素（左上原点）。fge-web.js が pointer と wheel のイベントで書く。 */
public final class Pointer {
    private Pointer() { }

    @JSBody(script = "return fgePointer.x;")
    public static native double x();

    @JSBody(script = "return fgePointer.y;")
    public static native double y();

    /** button（0 = 左・1 = 中・2 = 右）が今押されているか、このコマの前に押されたか。読んでも表は変えない。 */
    @JSBody(params = {"button"}, script = "return fgePointerDown(button);")
    public static native boolean isDown(int button);

    /** 前に読んでからのホイールの量（上が正・1 刻みがおよそ 1）を返して 0 に戻す。 */
    @JSBody(script = "var v = fgePointer.wheel; fgePointer.wheel = 0; return v;")
    public static native double consumeWheel();

    /** 前に読んでからの横の動き（描き先の画素）を返して 0 に戻す。頁にフォーカスが無い間と戻った直後は 0。 */
    @JSBody(script = "var v = fgePointer.dx; fgePointer.dx = 0; return v;")
    public static native double consumeDx();

    /** 前に読んでからの縦の動き（描き先の画素）を返して 0 に戻す。 */
    @JSBody(script = "var v = fgePointer.dy; fgePointer.dy = 0; return v;")
    public static native double consumeDy();

    /** canvas の pointer lock を掛けるか。掛けている間の動きは consumeDx と consumeDy にだけ出る。ブラウザが断ったら次の操作で頼み直す。 */
    @JSBody(params = {"on"}, script = "fgeSetMouseCaptured(on);")
    public static native void setCaptured(boolean on);

    /** 最後に来た pointer の入力が指（pointerType が touch）か。マウス・ペンが来たら偽。 */
    @JSBody(script = "return fgePointer.touch;")
    public static native boolean isTouch();
}
