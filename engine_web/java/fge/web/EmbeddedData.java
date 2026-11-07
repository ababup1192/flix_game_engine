package fge.web;

/**
 * 埋め込んだ素材の表。ここにあるのは空の版で、project.json の web.embed がある時だけ
 * 書き出しの道具（fge.teavmfix.Embed）が中身入りの class に差し替える。
 * table は [道, 切れ端の数, 切れ端…] の繰り返し。
 */
public final class EmbeddedData {
    private EmbeddedData() { }

    // WhyNot: 鍵を static final の定数にしない — javac が呼ぶ側へ値を写し込み、差し替えた後も空の版の値で復号してしまう。
    public static long seed() { return 0L; }

    public static String[] table() { return new String[0]; }
}
