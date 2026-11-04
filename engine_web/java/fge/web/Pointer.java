package fge.web;

import org.teavm.jso.JSBody;

/** マウス（pointer）の表。位置は canvas の描き先の画素（左上原点）。fge-web.js が pointer と wheel のイベントで書く。 */
public final class Pointer {
    private Pointer() { }

    @JSBody(script = "return fgePointer.x;")
    public static native double x();

    @JSBody(script = "return fgePointer.y;")
    public static native double y();

    /** button（0 = 左・1 = 中・2 = 右）が今押されているか、前に読んでから押されたか。 */
    @JSBody(params = {"button"}, script = "return fgePointerDown(button);")
    public static native boolean isDown(int button);

    /** 前に読んでからのホイールの量（上が正・1 刻みがおよそ 1）を返して 0 に戻す。 */
    @JSBody(script = "var v = fgePointer.wheel; fgePointer.wheel = 0; return v;")
    public static native double consumeWheel();

    /** 前に読んでからの横の動き（描き先の画素）を返して 0 に戻す。 */
    @JSBody(script = "var v = fgePointer.dx; fgePointer.dx = 0; return v;")
    public static native double consumeDx();

    /** 前に読んでからの縦の動き（描き先の画素）を返して 0 に戻す。 */
    @JSBody(script = "var v = fgePointer.dy; fgePointer.dy = 0; return v;")
    public static native double consumeDy();
}
