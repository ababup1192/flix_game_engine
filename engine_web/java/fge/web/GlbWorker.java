package fge.web;

import org.teavm.interop.Async;
import org.teavm.interop.AsyncCallback;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSFunctor;
import org.teavm.jso.JSObject;
import org.teavm.jso.typedarrays.Float64Array;
import org.teavm.jso.typedarrays.Int32Array;
import org.teavm.jso.typedarrays.Int8Array;

/**
 * 後から届く glb をメインの外（Web Worker）で解く道。中身は頁の fge-web.js（頼む側）と fge-glb-worker.js（解く側）。
 * 解く側: 同じ wasm を Worker で起こし、WebLayer の入口が serve の輪へ入る。頼みを 1 本ずつ待ち、解いた並びを配列のまま返す。
 * 頼む側: 解き終えた結果を鍵（道と版）で引き、配列を wasm へ写す。
 */
public final class GlbWorker {
    private GlbWorker() { }

    // ── 解く側（Worker）──

    /** この wasm が glb の Worker の中で動いているか。 */
    @JSBody(script = "return typeof fgeGlbWorkerScope !== 'undefined';")
    public static native boolean isWorker();

    /** 頼みが来た知らせ。 */
    @JSFunctor
    private interface Ready extends JSObject {
        void ready();
    }

    @JSBody(params = {"done"}, script = "fgeGlbWorkerNext(done);")
    private static native void startNext(Ready done);

    @Async
    private static native int waitNext();

    private static void waitNext(AsyncCallback<Integer> callback) {
        startNext(() -> callback.complete(0));
    }

    /** 次の頼みが来るまで止まる（待つ間は Worker の JS へ手を返す）。 */
    public static void awaitRequest() {
        waitNext();
    }

    @JSBody(script = "return fgeGlbWorkerRequest.bytes;")
    private static native Int8Array requestBytesView();

    /** 今の頼みの glb のバイト。 */
    public static byte[] requestBytes() {
        return requestBytesView().copyToJavaArray();
    }

    /** 今の頼みの project.json の "gltf" の値の JSON の字（無ければ空）。 */
    @JSBody(script = "return fgeGlbWorkerRequest.gltf;")
    public static native String requestGltf();

    /** 解いた並びの字を 1 つ足す。 */
    @JSBody(params = {"s"}, script = "fgeGlbWorkerResult.strings.push(s);")
    public static native void putString(String s);

    @JSBody(params = {"a"}, script = "fgeGlbWorkerResult.ints = a;")
    private static native void putIntsArray(Int32Array a);

    /** 解いた並びの数の列。 */
    public static void putInts(int[] values) {
        putIntsArray(Int32Array.copyFromJavaArray(values));
    }

    @JSBody(params = {"a"}, script = "fgeGlbWorkerResult.floats = a;")
    private static native void putFloatsArray(Float64Array a);

    /** 解いた並びの小数の列。 */
    public static void putFloats(double[] values) {
        putFloatsArray(Float64Array.copyFromJavaArray(values));
    }

    @JSBody(params = {"a"}, script = "fgeGlbWorkerResult.f64s.push(a);")
    private static native void pushF64sArray(Float64Array a);

    /** 解いた並びの頂点などの配列（Float64）を 1 本足す。 */
    public static void pushF64s(double[] values) {
        pushF64sArray(Float64Array.copyFromJavaArray(values));
    }

    @JSBody(params = {"a"}, script = "fgeGlbWorkerResult.i32s.push(a);")
    private static native void pushI32sArray(Int32Array a);

    /** 解いた並びの頂点の番号などの配列（Int32）を 1 本足す。 */
    public static void pushI32s(int[] values) {
        pushI32sArray(Int32Array.copyFromJavaArray(values));
    }

    /** 使う絵（画像の番号・バイトの中の始まり・長さ）を 1 つ足す。Worker の JS が ImageBitmap に解いて渡す。 */
    @JSBody(params = {"index", "start", "length"}, script = "fgeGlbWorkerResult.images.push([index, start, length]);")
    public static native void putImage(int index, int start, int length);

    /** 今の頼みを解き終えた（頁へ送る）。 */
    @JSBody(script = "fgeGlbWorkerFinish();")
    public static native void finish();

    /** 今の頼みを解けなかった（頁はメインで読み直す）。 */
    @JSBody(params = {"why"}, script = "fgeGlbWorkerFail(why);")
    public static native void fail(String why);

    // ── 頼む側（頁）──

    /** 頁で結果の入れ物を空にして作る（読み込みの間に、受け渡しの道を 1 度通す時）。 */
    @JSBody(script = "fgeGlbLocalBegin();")
    public static native void beginLocal();

    /** 頁で積んだ結果を鍵 key で表に置く。 */
    @JSBody(params = {"key"}, script = "fgeGlbLocalStore(key);")
    public static native void storeLocal(String key);

    /** 鍵 key の結果を表から捨てる。 */
    @JSBody(params = {"key"}, script = "fgeGlbParsed.delete(fgeNormPath(key));")
    public static native void dropParsed(String key);

    /** この頁が後回しの glb を Worker で解く見込みか（後回しの glb があり、Worker を使える）。 */
    @JSBody(script = "return typeof fgeGlbWorkerExpected === 'function' && fgeGlbWorkerExpected();")
    public static native boolean expected();

    /** 鍵（道と版）の glb を Worker で解いた結果があるか。 */
    @JSBody(params = {"key"}, script = "return fgeGlbParsedHas(key);")
    public static native boolean hasParsed(String key);

    /** 結果の字を全部つないだ物（strLens の長さで切る）。 */
    @JSBody(params = {"key"}, script = "return fgeGlbParsedOf(key).text;")
    public static native String text(String key);

    @JSBody(params = {"key", "field"}, script = "return fgeGlbParsedOf(key)[field];")
    private static native Int32Array intField(String key, String field);

    @JSBody(params = {"key", "field"}, script = "return fgeGlbParsedOf(key)[field];")
    private static native Float64Array floatField(String key, String field);

    /** 結果の数の並びの欄（strLens・ints・f64Lens・i32・i32Lens）。 */
    public static int[] ints(String key, String field) {
        return intField(key, field).copyToJavaArray();
    }

    /** 結果の小数の並びの欄（floats・f64）。 */
    public static double[] floats(String key, String field) {
        return floatField(key, field).copyToJavaArray();
    }
}
