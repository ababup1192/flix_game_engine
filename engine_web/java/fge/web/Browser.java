package fge.web;

import org.teavm.jso.JSBody;

/** 頁と canvas の口（時刻・知らせ・canvas の画素の大きさ・全画面・起動の進み具合・終わりの画面）。中身は fge-web.js。 */
public final class Browser {
    private Browser() { }

    /** 頁を開いてからの時刻（ms・小数）。 */
    @JSBody(script = "return performance.now();")
    public static native double now();

    /** 開発者の道具の console へ 1 行。 */
    @JSBody(params = {"line"}, script = "console.log(line);")
    public static native void log(String line);

    /** canvas の描き先の幅（画素）。CSS の大きさ × devicePixelRatio に合わせて fge-web.js が作り直す。 */
    @JSBody(script = "return fgeCanvasWidth();")
    public static native int canvasWidth();

    /** canvas の描き先の高さ（画素）。 */
    @JSBody(script = "return fgeCanvasHeight();")
    public static native int canvasHeight();

    /** 全画面を頼む。ブラウザはユーザーの操作の中でしか通さないので、fge-web.js が次のキーか pointer のイベントの中で行う。 */
    @JSBody(params = {"on"}, script = "fgeRequestFullscreen(on);")
    public static native void requestFullscreen(boolean on);

    /** 今全画面か。 */
    @JSBody(script = "return !!document.fullscreenElement;")
    public static native boolean isFullscreen();

    /** 起動の進み具合を頁の帯に出す。 */
    @JSBody(params = {"phase", "done", "total"}, script = "fgeProgress(phase, done, total);")
    public static native void progress(String phase, int done, int total);

    /** 起動の帯を消して canvas を見せる。 */
    @JSBody(script = "fgeStarted();")
    public static native void started();

    /** ループを抜けた後の「おわり」の画面を出す。 */
    @JSBody(script = "fgeEnded();")
    public static native void ended();

    /** ゲームの題を頁の題に。 */
    @JSBody(params = {"title"}, script = "document.title = title;")
    public static native void setTitle(String title);

    /** canvas の上のマウスの形（CSS の cursor の値。"none" で隠す）。 */
    @JSBody(params = {"css"}, script = "fgeSetCursor(css);")
    public static native void setCursor(String css);

    /** ゲームの id（bundle.json の id。localStorage の鍵の頭に付ける）。 */
    @JSBody(script = "return fgeGameId;")
    public static native String gameId();

    /** 頁にキーボードとマウスが来ているか（窓が前・タブが表）。 */
    @JSBody(script = "return document.hasFocus() && !document.hidden;")
    public static native boolean hasFocus();
}
