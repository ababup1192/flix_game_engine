package fge.web;

import org.teavm.jso.JSBody;

/**
 * 後回しの素材（bundle.json の deferred）。fge-web.js が wasm を読み終えた後に別の行列で取る。
 * 状態の字は "queued" / "downloading" / "downloaded" / "loaded" / "failed:理由"。後回しでない道はいつも "loaded"。
 * 道と名前を並べる所は改行でつなぐ（JS へ配列を渡さずに済ませる）。
 */
public final class Deferred {
    private Deferred() { }

    /** 道か名前（project.json の textures・sounds の名前）が後回しの素材か。 */
    @JSBody(params = {"nameOrPath"}, script = "return fgeDeferredIsDeferred(nameOrPath);")
    public static native boolean isDeferred(String nameOrPath);

    /** 道 1 本か、名前（textures・sounds の名前）の道の状態の字。 */
    @JSBody(params = {"nameOrPath"}, script = "return fgeDeferredState(nameOrPath);")
    public static native String state(String nameOrPath);

    /** 道（改行でつなぐ）を並べた順で行列の頭へ。 */
    @JSBody(params = {"paths"}, script = "fgeDeferredRequest(paths);")
    public static native void request(String paths);

    /** 道（改行でつなぐ）の生のバイトを素材の表から捨てる（後回しの道だけ。捨てた道は読めなくなる）。 */
    @JSBody(params = {"paths"}, script = "fgeDeferredRelease(paths);")
    public static native void release(String paths);

    /** 道の 2D の絵を全部の名前で登録し終えた（WebLayer が道ごとに 1 回呼ぶ。この後 ImageBitmap を捨てる）。 */
    @JSBody(params = {"path"}, script = "fgeDeferredMarkLoaded(path);")
    public static native void markLoaded(String path);

    /** 後回しで、まだ届いていない名前（名前の無い素材は道）を改行でつないだ字。 */
    @JSBody(script = "return fgeDeferredMissing();")
    public static native String missing();

    /** missing の字が変わるたびに 1 つ増える数。 */
    @JSBody(script = "return fgeDeferredMissingGen();")
    public static native int missingGen();

    /** 名前の扱い（project.json の web.deferredPolicy）。"onMissing\ngroup" の形（無い欄は空）。 */
    @JSBody(params = {"name"}, script = "return fgeDeferredPolicy(name);")
    public static native String policy(String name);

    /** 後から取る wasm の状態の字（"none" は分けていない束）。 */
    @JSBody(script = "return fgeCodeState();")
    public static native String codeState();

    /** 押した後のロゴを出している間か。 */
    @JSBody(script = "return fgeIsSplashShowing();")
    public static native boolean isSplashShowing();

    /** App のループの今の待ちを知らせる（names は改行でつなぐ）。 */
    @JSBody(params = {"reason", "names", "waited", "progress", "pressed"}, script = "fgeSetLoadWait(reason, names, waited, progress, pressed);")
    public static native void setLoadWait(String reason, String names, double waited, double progress, boolean pressed);

    /** App のループの待ちが明けた。 */
    @JSBody(script = "fgeSetLoadWait(null);")
    public static native void clearLoadWait();
}
