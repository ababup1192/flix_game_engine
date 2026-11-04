package fge.web;

import org.teavm.jso.JSBody;

/**
 * 起動の前に fge-web.js が createImageBitmap で解いておいた画像（PNG・JPEG）。画素を wasm へ運ばず、JS の中で GPU へ上げる。
 * 色を stb と同じにするため、premultiply と色空間の変換は切って解く。
 */
public final class WebImages {
    private WebImages() { }

    /** 道の画像があるか。 */
    @JSBody(params = {"path"}, script = "return fgeImages.has(fgeNormPath(path));")
    public static native boolean has(String path);

    @JSBody(params = {"path"}, script = "var b = fgeImages.get(fgeNormPath(path)); return b ? b.width : 0;")
    public static native int width(String path);

    @JSBody(params = {"path"}, script = "var b = fgeImages.get(fgeNormPath(path)); return b ? b.height : 0;")
    public static native int height(String path);

    /**
     * 今 bind している TEXTURE_2D へ道の画像を上げる（無ければ何もしない）。alpha が偽なら RGB で上げてアルファを捨てる
     * （デスクトップが stb で 3 チャンネルに読むのと同じ。透明な所を不透明にする）。
     */
    @JSBody(params = {"path", "alpha"}, script = "fgeTexImageBitmap(fgeNormPath(path), alpha);")
    public static native void texImage(String path, boolean alpha);
}
