package fge.web;

/**
 * 3D の描き手のシェーダーの字の表（書き出しの時に作る・WebLayer.Internal.WebShaderLibrary が読む）。ここにあるのは空の版で、
 * 書き出しの道具（fge.teavmfix.ShaderEmbed）が記録（web/shader-variants.json）から作った表入りの class に差し替える。
 * table は [鍵, 切れ端の数, 切れ端…] の繰り返し（鍵は "glsl:" か "wgsl:" + Render3d.ShaderSourceKey.toKeyString）。
 */
public final class ShaderLibraryData {
    private ShaderLibraryData() { }

    // WhyNot: 表を static final の定数にしない — javac が呼ぶ側へ値を写し込み、差し替えた後も空の版を読む。
    public static String[] table() { return new String[0]; }
}
