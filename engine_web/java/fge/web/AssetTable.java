package fge.web;

import java.nio.charset.StandardCharsets;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.typedarrays.Int8Array;

/** 起動の前に fge-web.js が取ってきた素材の表（project.json からの相対の道 → 中身）と、wasm に埋め込んだ素材（Embedded）。音はここに無く WebAudio が持つ。 */
public final class AssetTable {
    private AssetTable() { }

    @JSBody(params = {"path"}, script = "return fgeAssetHas(path);")
    private static native boolean hasFetched(String path);

    @JSBody(params = {"path"}, script = "return fgeAssetText(path);")
    private static native String fetchedText(String path);

    /** 道の素材が表にあるか（wasm に埋め込んだ物も含む）。 */
    public static boolean has(String path) { return Embedded.has(path) || hasFetched(path); }

    /** 道の素材を UTF-8 の字として。無ければ null。 */
    public static String text(String path) {
        if (Embedded.has(path)) {
            byte[] plain = Embedded.bytes(path);
            return plain == null ? null : new String(plain, StandardCharsets.UTF_8);
        }
        return fetchedText(path);
    }

    @JSBody(params = {"path"}, script = "return fgeAssetBytes(path);")
    private static native JSObject bytesView(String path);

    /** 道の素材のバイト列。無ければ null。 */
    public static byte[] bytes(String path) {
        if (Embedded.has(path)) return Embedded.bytes(path);
        if (!hasFetched(path)) return null;
        Int8Array view = (Int8Array) bytesView(path);
        return view.copyToJavaArray();
    }
}
