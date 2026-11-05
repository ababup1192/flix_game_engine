package fge.web;

import java.nio.IntBuffer;
import org.teavm.interop.Async;
import org.teavm.interop.AsyncCallback;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSFunctor;
import org.teavm.jso.JSObject;
import org.teavm.jso.typedarrays.Int32Array;
import org.teavm.jso.typedarrays.Int8Array;

/**
 * 起動の前に fge-web.js が createImageBitmap で解いておいた画像（PNG・JPEG）。画素を wasm へ運ばず、JS の中で GPU へ上げる。
 * 色を stb と同じにするため、premultiply と色空間の変換は切って解く。
 * ゲームの中で読んだバイト（glb の中の絵など）は decode で画素へ戻す。
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

    /** 解き終わりの知らせ。 */
    @JSFunctor
    private interface DecodeDone extends JSObject {
        void done();
    }

    @JSBody(params = {"bytes", "done"}, script = "fgeDecodeImage(bytes, done);")
    private static native void startDecode(JSObject bytes, DecodeDone done);

    /** 解き終わるまで止まる（結果は fge-web.js の fgeDecoded）。 */
    @Async
    private static native int waitDecode(JSObject bytes);

    private static void waitDecode(JSObject bytes, AsyncCallback<Integer> callback) {
        startDecode(bytes, () -> callback.complete(0));
    }

    @JSBody(script = "return fgeDecoded.error;")
    private static native String decodedError();

    @JSBody(script = "return fgeDecoded.width;")
    private static native int decodedWidth();

    @JSBody(script = "return fgeDecoded.height;")
    private static native int decodedHeight();

    @JSBody(params = {"out"}, script = "out.set(fgeDecoded.argb); fgeDecoded = null;")
    private static native void takeDecoded(JSObject out);

    /**
     * PNG か JPEG か WebP のバイトを ARGB へ解く。解き終わるまでゲームのループごと止まる（待つ間はブラウザへ手を返す）。
     * WhyNot: 2D canvas の getImageData で読まない — premultiply した値を読み戻すので、半透明の画素の色が崩れる。
     */
    public static DecodedImage decode(byte[] bytes) {
        waitDecode(Int8Array.copyFromJavaArray(bytes));
        String error = decodedError();
        if (!error.isEmpty()) return new DecodedImage(0, 0, new int[0], error);
        int width = decodedWidth();
        int height = decodedHeight();
        int count = width * height;
        IntBuffer direct = WebGl2.directInts(count);
        takeDecoded(Int32Array.fromJavaBuffer(direct));
        int[] argb = new int[count];
        direct.get(argb, 0, count);
        return new DecodedImage(width, height, argb, "");
    }
}
