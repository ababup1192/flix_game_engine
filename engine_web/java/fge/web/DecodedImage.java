package fge.web;

/** WebImages.decode の結果。解けなければ error に理由が入り、argb は空。 */
public final class DecodedImage {
    private final int width;
    private final int height;
    private final int[] argb;
    private final String error;

    DecodedImage(int width, int height, int[] argb, String error) {
        this.width = width;
        this.height = height;
        this.argb = argb;
        this.error = error;
    }

    public int width() { return width; }
    public int height() { return height; }
    public int[] argb() { return argb; }
    public String error() { return error; }
}
