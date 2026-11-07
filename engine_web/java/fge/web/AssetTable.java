package fge.web;

import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.typedarrays.Int8Array;

/** 起動の前に fge-web.js が取ってきた素材の表（project.json からの相対の道 → 中身）。音はここに無く WebAudio が持つ。 */
public final class AssetTable {
    private AssetTable() { }

    /** 道の素材が表にあるか。 */
    @JSBody(params = {"path"}, script = "return fgeAssetHas(path);")
    public static native boolean has(String path);

    /** 道の素材を UTF-8 の字として。無ければ null。 */
    @JSBody(params = {"path"}, script = "return fgeAssetText(path);")
    public static native String text(String path);

    @JSBody(params = {"path"}, script = "return fgeAssetBytes(path);")
    private static native JSObject bytesView(String path);

    /** 道の素材のバイト列。無ければ null。 */
    public static byte[] bytes(String path) {
        if (!has(path)) return null;
        Int8Array view = (Int8Array) bytesView(path);
        return view.copyToJavaArray();
    }
}
