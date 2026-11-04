// BootFontGen — 起動画面が使う「組み込みフォント」と「ロゴ」を Flix ソースへ焼き込む生成器。
//
// 走らせ方: make boot-font   （中身は java bin/BootFontGen.java）
// 出力先:   engine/src/render2d/BootFontData.flix
//
// なぜ Flix ソースに焼くのか: 配布パッケージ (fpkg) は .flix しか運べないので、PNG や TTF を
// アセットとして同梱できない。数十 KB のビットマップならソースの文字列リテラルで運べる。
//
// なぜ SDF でなく 1bit ビットマップなのか: 起動画面は決まった大きさでしか字を出さないので
// SDF の利点 (任意拡大) を使わない。1bit なら埋め込み量が 2 桁小さく、生成も AWT だけで済む。
//
// 素材: templates/rpg-starter/assets/PixelMplus10-Regular.ttf (PixelMplus / M+ FONT LICENSE)
//       docs/brand/flix_ge_icon.png
import java.awt.Color;
import java.awt.Font;
import java.awt.FontMetrics;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.FileInputStream;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import javax.imageio.ImageIO;

public class BootFontGen {

    static final String TTF = "templates/rpg-starter/assets/PixelMplus10-Regular.ttf";
    static final String LOGO = "docs/brand/flix_ge_icon.png";
    static final String OUT = "engine/src/render2d/BootFontData.flix";
    static final String SOURCE_NOTE = "PixelMplus10-Regular.ttf / 10px / M+ FONT LICENSE";

    /** 焼き込みピクセル高さ。PixelMplus10 は 10px 設計なので等倍でドットが揃う。 */
    static final int FONT_PX = 10;
    static final int LOGO_SIDE = 64;
    static final int LOGO_COLORS = 16;
    /** Java の文字列定数は 65535 バイトまで。余裕を見て hex をこの長さで割る。 */
    static final int CHUNK = 32768;

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");

        Font font = loadFont();
        List<Integer> charset = charset();
        assertCoverage(font, charset);

        Atlas atlas = bakeAtlas(font, charset);
        Logo logo = bakeLogo();

        try (PrintWriter w = new PrintWriter(OUT, "UTF-8")) {
            emit(w, atlas, logo);
        }
        System.out.printf("[boot-font] %s: %d 字 / アトラス %dx%d / 画素 %d バイト / ロゴ %d 色%n",
                OUT, atlas.glyphs.size(), atlas.side, atlas.side, atlas.bits.length, LOGO_COLORS);

        // 焼いた結果は実機に出るまで目で見られないので、目視用の PNG を書ける口を付けておく。
        if (args.length == 2 && args[0].equals("--preview")) writePreview(args[1], atlas, logo);
    }

    // ── 焼く字 ────────────────────────────────────────────────

    /**
     * 起動画面が出せる字 = ASCII だけ。起動画面の文言は英語に決めてあるので、これで足りる。
     * ここに無い字は起動画面から黙って消える（フォントが持っていなければ生成が止まる）。
     */
    static List<Integer> charset() {
        List<Integer> cps = new ArrayList<>();
        for (int cp = 0x20; cp <= 0x7E; cp++) cps.add(cp);
        return cps;
    }

    static Font loadFont() throws Exception {
        try (FileInputStream fis = new FileInputStream(TTF)) {
            return Font.createFont(Font.TRUETYPE_FONT, fis).deriveFont((float) FONT_PX);
        }
    }

    /** 焼く字をフォントが 1 つでも持っていなければ止める（起動画面から字が消えるのを出荷前に捕まえる）。 */
    static void assertCoverage(Font font, List<Integer> cps) {
        StringBuilder missing = new StringBuilder();
        for (int cp : cps) if (!font.canDisplay(cp)) missing.append(String.format("U+%04X ", cp));
        if (missing.length() > 0)
            throw new IllegalStateException(TTF + " が持っていない字: " + missing);
    }

    // ── フォントアトラス ──────────────────────────────────────

    static class Glyph {
        int cp, x, y, w, advance;
    }

    static class Atlas {
        int side, cellH, ascent, descent, leading;
        List<Glyph> glyphs;
        byte[] bits;
    }

    static Atlas bakeAtlas(Font font, List<Integer> cps) {
        BufferedImage probe = new BufferedImage(1, 1, BufferedImage.TYPE_INT_ARGB);
        Graphics2D pg = probe.createGraphics();
        pg.setFont(font);
        FontMetrics fm = pg.getFontMetrics();
        int ascent = fm.getAscent();
        int descent = fm.getDescent();
        int leading = fm.getLeading();
        pg.dispose();

        int cellH = ascent + descent;
        int side = fitSide(fm, cps, cellH);

        // 1 枚のアトラスへ全部の字を描いてから 1bit へ落とす。ドット絵フォントなので
        // アンチエイリアスは切る（切らないと灰色の縁が出て、しきい値で字が太る）。
        BufferedImage img = new BufferedImage(side, side, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = img.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_OFF);
        g.setFont(font);
        g.setColor(Color.WHITE);

        List<Glyph> glyphs = new ArrayList<>();
        int penX = 0, penY = 0;
        for (int cp : cps) {
            int advance = fm.charWidth(cp);
            if (advance <= 0) continue;
            if (penX + advance > side) { penX = 0; penY += cellH; }
            if (penY + cellH > side) throw new IllegalStateException("アトラスに入りきらない: side=" + side);
            g.drawString(new String(Character.toChars(cp)), penX, penY + ascent);
            Glyph gl = new Glyph();
            gl.cp = cp; gl.x = penX; gl.y = penY; gl.w = advance; gl.advance = advance;
            glyphs.add(gl);
            penX += advance;
        }
        g.dispose();

        Atlas a = new Atlas();
        a.side = side; a.cellH = cellH;
        a.ascent = ascent; a.descent = descent; a.leading = leading;
        a.glyphs = glyphs;
        a.bits = toBits(img, side);
        return a;
    }

    /** 全部の字が収まる最小の正方の辺。Text の表示サイズ計算がアトラスを正方と決め打つので正方に限る。 */
    static int fitSide(FontMetrics fm, List<Integer> cps, int cellH) {
        for (int side : new int[]{64, 128, 256, 512, 1024}) {
            int penX = 0, rows = 1;
            for (int cp : cps) {
                int advance = fm.charWidth(cp);
                if (advance <= 0) continue;
                if (advance > side) { rows = Integer.MAX_VALUE; break; }
                if (penX + advance > side) { penX = 0; rows++; }
                penX += advance;
            }
            if (rows != Integer.MAX_VALUE && (long) rows * cellH <= side) return side;
        }
        throw new IllegalStateException("1024 でも収まらない — 焼く字を減らすこと");
    }

    /** alpha > 127 を 1 とみなす。行優先・MSB 先頭。side は 8 の倍数なので行は自然にバイト境界へ揃う。 */
    static byte[] toBits(BufferedImage img, int side) {
        byte[] bits = new byte[side * side / 8];
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                int alpha = (img.getRGB(x, y) >>> 24) & 0xFF;
                if (alpha > 127) {
                    int i = y * side + x;
                    bits[i >> 3] |= (byte) (0x80 >>> (i & 7));
                }
            }
        }
        return bits;
    }

    // ── ロゴ ──────────────────────────────────────────────────

    static class Logo {
        int[] palette;   // 0xAARRGGBB を LOGO_COLORS 個。index 0 は必ず透明。
        byte[] indices;  // 1 バイト = 2 画素（上位 4bit が左）
    }

    static Logo bakeLogo() throws Exception {
        BufferedImage src = ImageIO.read(new File(LOGO));
        BufferedImage small = new BufferedImage(LOGO_SIDE, LOGO_SIDE, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = small.createGraphics();
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        g.drawImage(src, 0, 0, LOGO_SIDE, LOGO_SIDE, null);
        g.dispose();

        boolean[] outside = outsideMask(small);

        List<int[]> opaque = new ArrayList<>();
        for (int y = 0; y < LOGO_SIDE; y++)
            for (int x = 0; x < LOGO_SIDE; x++) {
                if (outside[y * LOGO_SIDE + x]) continue;
                int argb = small.getRGB(x, y);
                opaque.add(new int[]{(argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF});
            }

        int[] palette = new int[LOGO_COLORS];
        palette[0] = 0;  // 透明。角の丸みと外側はここへ倒す。
        List<int[]> reps = medianCut(opaque, LOGO_COLORS - 1);
        for (int i = 0; i < reps.size(); i++) {
            int[] c = reps.get(i);
            palette[i + 1] = 0xFF000000 | (c[0] << 16) | (c[1] << 8) | c[2];
        }

        byte[] indices = new byte[LOGO_SIDE * LOGO_SIDE / 2];
        for (int y = 0; y < LOGO_SIDE; y++)
            for (int x = 0; x < LOGO_SIDE; x++) {
                int argb = small.getRGB(x, y);
                int idx = outside[y * LOGO_SIDE + x] ? 0 : nearest(palette, argb);
                int i = y * LOGO_SIDE + x;
                if ((i & 1) == 0) indices[i / 2] |= (byte) (idx << 4);
                else indices[i / 2] |= (byte) idx;
            }

        Logo logo = new Logo();
        logo.palette = palette;
        logo.indices = indices;
        return logo;
    }

    /**
     * ロゴの外側（角の丸みの外）を見つける。素材の PNG は角が透明ではなく地色で塗ってあるので、
     * 透明かどうかだけでは角を抜けない。画像の縁から地色をたどって届く範囲を外側とみなす。
     */
    static boolean[] outsideMask(BufferedImage img) {
        int n = LOGO_SIDE * LOGO_SIDE;
        boolean[] outside = new boolean[n];
        int seed = img.getRGB(0, 0);
        int[] queue = new int[n];
        int head = 0, tail = 0;
        for (int i = 0; i < LOGO_SIDE; i++) {
            for (int p : new int[]{i, (LOGO_SIDE - 1) * LOGO_SIDE + i, i * LOGO_SIDE, i * LOGO_SIDE + LOGO_SIDE - 1})
                if (!outside[p] && likeBackground(img.getRGB(p % LOGO_SIDE, p / LOGO_SIDE), seed)) {
                    outside[p] = true;
                    queue[tail++] = p;
                }
        }
        while (head < tail) {
            int p = queue[head++];
            int x = p % LOGO_SIDE, y = p / LOGO_SIDE;
            for (int[] d : new int[][]{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
                int nx = x + d[0], ny = y + d[1];
                if (nx < 0 || ny < 0 || nx >= LOGO_SIDE || ny >= LOGO_SIDE) continue;
                int q = ny * LOGO_SIDE + nx;
                if (outside[q] || !likeBackground(img.getRGB(nx, ny), seed)) continue;
                outside[q] = true;
                queue[tail++] = q;
            }
        }
        // 縁を 1 画素ぶん外側へ広げる。縮小でできた中間色（地と絵が混ざった画素）は
        // 地の色から離れていて上のたどりでは残り、角のまわりに点々として見えてしまう。
        boolean[] grown = outside.clone();
        for (int y = 0; y < LOGO_SIDE; y++)
            for (int x = 0; x < LOGO_SIDE; x++) {
                if (!outside[y * LOGO_SIDE + x]) continue;
                for (int[] d : new int[][]{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
                    int nx = x + d[0], ny = y + d[1];
                    if (nx >= 0 && ny >= 0 && nx < LOGO_SIDE && ny < LOGO_SIDE)
                        grown[ny * LOGO_SIDE + nx] = true;
                }
            }
        return grown;
    }

    /** 透明か、四隅の色とほぼ同じなら地とみなす。 */
    static boolean likeBackground(int argb, int seed) {
        if (((argb >>> 24) & 0xFF) < 128) return true;
        int dr = ((argb >> 16) & 0xFF) - ((seed >> 16) & 0xFF);
        int dg = ((argb >> 8) & 0xFF) - ((seed >> 8) & 0xFF);
        int db = (argb & 0xFF) - (seed & 0xFF);
        return dr * dr + dg * dg + db * db < 900;
    }

    /** 色の箱を「いちばん広がっている軸」で半分に割り続けて代表色を選ぶ（メディアンカット）。 */
    static List<int[]> medianCut(List<int[]> pixels, int want) {
        List<List<int[]>> boxes = new ArrayList<>();
        boxes.add(pixels);
        while (boxes.size() < want) {
            int target = -1, bestSpread = -1, bestAxis = 0;
            for (int i = 0; i < boxes.size(); i++) {
                List<int[]> box = boxes.get(i);
                if (box.size() < 2) continue;
                for (int axis = 0; axis < 3; axis++) {
                    int lo = 255, hi = 0;
                    for (int[] p : box) { lo = Math.min(lo, p[axis]); hi = Math.max(hi, p[axis]); }
                    if (hi - lo > bestSpread) { bestSpread = hi - lo; target = i; bestAxis = axis; }
                }
            }
            if (target < 0 || bestSpread <= 0) break;
            List<int[]> box = boxes.remove(target);
            final int axis = bestAxis;
            box.sort(Comparator.comparingInt(p -> p[axis]));
            int mid = box.size() / 2;
            boxes.add(new ArrayList<>(box.subList(0, mid)));
            boxes.add(new ArrayList<>(box.subList(mid, box.size())));
        }
        List<int[]> reps = new ArrayList<>();
        for (List<int[]> box : boxes) {
            long r = 0, g = 0, b = 0;
            for (int[] p : box) { r += p[0]; g += p[1]; b += p[2]; }
            int n = Math.max(1, box.size());
            reps.add(new int[]{(int) (r / n), (int) (g / n), (int) (b / n)});
        }
        return reps;
    }

    /** 色票の中でいちばん近い色。index 0 は透明なので選ばない。 */
    static int nearest(int[] palette, int argb) {
        int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
        int best = 1, bestD = Integer.MAX_VALUE;
        for (int i = 1; i < palette.length; i++) {
            int pr = (palette[i] >> 16) & 0xFF, pg = (palette[i] >> 8) & 0xFF, pb = palette[i] & 0xFF;
            int d = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb);
            if (d < bestD) { bestD = d; best = i; }
        }
        return best;
    }

    // ── 書き出し ──────────────────────────────────────────────

    static void emit(PrintWriter w, Atlas a, Logo logo) {
        w.println("// BootFontData — 生成物。手で編集しない（`make boot-font` で焼き直す）。");
        w.println("//");
        w.println("// 起動画面 (Splash) が使う組み込みフォントとロゴの素データ。fpkg は .flix しか運べないので、");
        w.println("// ビットマップを 16 進の文字列として持つ。読み解くのは BootFont。");
        w.println("//");
        w.println("// 素材: " + SOURCE_NOTE);
        w.println("//       docs/brand/flix_ge_icon.png");
        w.println("mod BootFontData {");
        w.println();
        w.println("    /// 素材の出どころ（ライセンス表記のため実行時にも名乗れるようにしてある）。");
        w.println("    pub def source(): String = \"" + SOURCE_NOTE + "\"");
        w.println();
        w.println("    /// アトラスの一辺。Text の表示サイズ計算がアトラスを正方と決め打つので正方。");
        w.println("    pub def side(): Int32 = " + a.side);
        w.println();
        w.println("    /// 焼き込みピクセル高さ。この大きさで出すとドットが 1:1 で揃う。");
        w.println("    pub def fontSize(): Float64 = " + fmt(FONT_PX));
        w.println();
        w.println("    pub def ascent(): Float64 = " + fmt(a.ascent));
        w.println("    pub def descent(): Float64 = " + fmt(a.descent));
        w.println("    pub def lineGap(): Float64 = " + fmt(a.leading));
        w.println();
        w.println("    /// 字の高さ（アトラス上の 1 マスの縦）。");
        w.println("    pub def cellH(): Int32 = " + a.cellH);
        w.println();
        w.println("    /// 1 字 14 桁: 文字番号(4) 左(3) 上(3) 幅(2) 送り幅(2)。すべて 16 進。");
        w.print("    pub def glyphsHex(): String = \"");
        for (Glyph g : a.glyphs)
            w.print(hex(g.cp, 4) + hex(g.x, 3) + hex(g.y, 3) + hex(g.w, 2) + hex(g.advance, 2));
        w.println("\"");
        w.println();
        w.println("    /// アトラスの 1bit 画素。行優先・上位ビットが左・16 進 2 桁 = 1 バイト。");
        emitChunks(w, "bitsHex", bytesToHex(a.bits));
        w.println();
        w.println("    /// ロゴの一辺。");
        w.println("    pub def logoSide(): Int32 = " + LOGO_SIDE);
        w.println();
        w.println("    /// ロゴの色票。1 色 8 桁 rrggbbaa。先頭は透明。");
        StringBuilder pal = new StringBuilder();
        for (int c : logo.palette)
            pal.append(hex((c >> 16) & 0xFF, 2)).append(hex((c >> 8) & 0xFF, 2))
               .append(hex(c & 0xFF, 2)).append(hex((c >>> 24) & 0xFF, 2));
        w.println("    pub def logoPaletteHex(): String = \"" + pal + "\"");
        w.println();
        w.println("    /// ロゴの画素。色票の番号を 4bit で 1 画素、上位が左。");
        emitChunks(w, "logoHex", bytesToHex(logo.indices));
        w.println("}");
    }

    /** 長い 16 進を Java の文字列定数上限より短く割って List[String] にする。 */
    static void emitChunks(PrintWriter w, String name, String hex) {
        List<String> chunks = new ArrayList<>();
        for (int i = 0; i < hex.length(); i += CHUNK)
            chunks.add(hex.substring(i, Math.min(hex.length(), i + CHUNK)));
        w.println("    pub def " + name + "(): List[String] =");
        for (int i = 0; i < chunks.size(); i++)
            w.println("        \"" + chunks.get(i) + "\" ::");
        w.println("        Nil");
    }

    static String bytesToHex(byte[] bs) {
        StringBuilder sb = new StringBuilder(bs.length * 2);
        for (byte b : bs) sb.append(hex(b & 0xFF, 2));
        return sb.toString();
    }

    static String hex(int v, int digits) {
        String s = Integer.toHexString(v);
        if (s.length() > digits) throw new IllegalStateException(v + " が " + digits + " 桁に入らない");
        return "0".repeat(digits - s.length()) + s;
    }

    static String fmt(int v) { return v + ".0"; }

    // ── 目視用 ────────────────────────────────────────────────

    /** 焼いた結果を PNG に戻す（実機に出るまで目で見られないので、確認できる口を残す）。 */
    static void writePreview(String dir, Atlas a, Logo logo) throws Exception {
        BufferedImage fontImg = new BufferedImage(a.side, a.side, BufferedImage.TYPE_INT_ARGB);
        for (int y = 0; y < a.side; y++)
            for (int x = 0; x < a.side; x++) {
                int i = y * a.side + x;
                boolean on = (a.bits[i >> 3] & (0x80 >>> (i & 7))) != 0;
                fontImg.setRGB(x, y, on ? 0xFFFFFFFF : 0xFF202020);
            }
        ImageIO.write(fontImg, "png", new File(dir, "boot-font.png"));

        BufferedImage logoImg = new BufferedImage(LOGO_SIDE, LOGO_SIDE, BufferedImage.TYPE_INT_ARGB);
        for (int y = 0; y < LOGO_SIDE; y++)
            for (int x = 0; x < LOGO_SIDE; x++) {
                int i = y * LOGO_SIDE + x;
                int idx = ((i & 1) == 0) ? ((logo.indices[i / 2] >> 4) & 0xF) : (logo.indices[i / 2] & 0xF);
                logoImg.setRGB(x, y, logo.palette[idx]);
            }
        ImageIO.write(logoImg, "png", new File(dir, "boot-logo.png"));
        System.out.println("[boot-font] preview: " + dir + "/boot-font.png, boot-logo.png");
    }
}
