// RenderGlyphGrow — アトラスに無い字を、その場で作って足す。
//
// 起動時に用意するのは「ソースとアセットに書いてある字」なので、実行中に計算で作った字
// （半角→全角の変換など）やプレイヤーが入れた名前は入っていない。そのままだと画面から
// 黙って消えるので、出そうとしたときにここが作って足す。
//
// アトラスは作り直さない。起動時に選んだ辺長には大きな空きがあるので、空いている場所へ
// 置いて**その区画だけ**を GPU へ上げ直す。既に置いた字は 1 画素も動かないため、
// 前のフレームで組んだ描画命令もそのまま使える。
//
// 作るのは 1 字 1 ミリ秒弱。漏れるのは多くて数字なので、1 コマの中で片付く。
mod RenderGlyphGrow {
    import org.lwjgl.opengl.GL11
    import org.lwjgl.stb.STBTruetype
    import org.lwjgl.stb.STBTTFontinfo
    import org.lwjgl.BufferUtils
    import org.lwjgl.system.MemoryStack
    import java.io.FileInputStream
    import java.nio.ByteBuffer
    import java.lang.Exception

    /// 1 つのフォントへ字を足せる状態。cx/cy/rowH は「次に置く場所」で、
    /// 起動時の詰め方（左から並べ、行に入らなければ下の行へ）の続きから使う。
    pub type alias Font = {
        path = String,
        bakeSize = Float64,
        side = Int32,
        texId = Int32,
        cx = Int32,
        cy = Int32,
        rowH = Int32,
        info = Option[STBTTFontinfo],
        // TTF の中身。**手放してはいけない** — 字形情報は中身への場所を覚えているだけなので、
        // これを捨てると片付けられたメモリを読みに行って落ちる。
        source = Option[ByteBuffer]
    }

    /// テクスチャ名 → 字を足せる状態。
    type alias Table = Map[String, Font]

    pub def newTable(): Ref[Table, Static] \ IO = Ref.fresh(Static, Map.empty())

    /// 用意し終わったフォントをテーブルに載せる。ここに載っていないフォントは字を足せない
    /// （字が消えるだけで、落ちはしない）。
    /// 置き始めの場所は、既に置いてある字より下の空き行から。キャッシュから読んだアトラスには
    /// 詰め位置が付いてこないので、アトラスの中身から導く（最後の行の残りは使わないが、
    /// 空きは辺長ぶん潤沢にあるので惜しくない）。
    pub def register(table: Ref[Table, Static], atlas: FontAtlas,
                     source: { path = String, texId = Int32 }): Unit \ IO =
        let side = Float64.tryToInt32(atlas#textureSize) |> Option.getWithDefault(0);
        let font = { path = source#path, bakeSize = atlas#fontSize, side = side,
                     texId = source#texId, cx = 0, cy = freeRowTop(atlas, side),
                     rowH = 0, info = None, source = None };
        Ref.put(Map.insert(atlas#textureName, font, Ref.get(table)), table)

    /// 既に置いてある字の下端。ここから下が空いている。
    def freeRowTop(atlas: FontAtlas, side: Int32): Int32 =
        atlas#glyphs |> Map.foldLeft((acc, gm) -> {
            let bottom = Float64.ceil(gm#t1 * Int32.toFloat64(side))
                |> Float64.tryToInt32 |> Option.getWithDefault(0);
            Int32.max(acc, bottom + 1)
        }, 0)

    /// cps のうちアトラスに無い字を作って足し、増えた分を載せたアトラスを返す。
    /// 足せなかった字（フォントが持っていない・アトラスが満杯）は黙って諦める —
    /// その字が出ないだけで、ゲームは動き続ける。
    pub def ensure(table: Ref[Table, Static], atlas: FontAtlas,
                   cps: Set[Int32]): FontAtlas \ IO =
        let missing = cps |> Set.filter(cp -> Option.isEmpty(Map.get(cp, atlas#glyphs)));
        if (Set.isEmpty(missing)) atlas
        else match Map.get(atlas#textureName, Ref.get(table)) {
            case None       => atlas
            case Some(font) => growAll(table, atlas, font, Set.toList(missing))
        }

    // ── 内部 ──────────────────────────────────────────────────

    def growAll(table: Ref[Table, Static], atlas: FontAtlas, font0: Font,
                cps: List[Int32]): FontAtlas \ IO =
        try {
            let font1 = ensureInfo(font0);
            // 上げ直す区画は幅が 4 の倍数とは限らない。既定の詰め方のままだと
            // GL が行の先頭を 4 バイト境界へ揃えようとして絵がずれる。
            GL11.glPixelStorei(GL11.GL_UNPACK_ALIGNMENT, 1);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, font1#texId);
            let result = List.foldLeft((acc, cp) -> {
                let (glyphs, font) = acc;
                match growOne(font, cp) {
                    case None            => (glyphs, font)
                    case Some((gm, next)) => (Map.insert(cp, gm, glyphs), next)
                }
            }, (atlas#glyphs, font1), cps);
            GL11.glPixelStorei(GL11.GL_UNPACK_ALIGNMENT, 4);
            let (glyphs, font) = result;
            Ref.put(Map.insert(atlas#textureName, font, Ref.get(table)), table);
            { glyphs = glyphs | atlas }
        } catch {
            case _: Exception => atlas
        }

    /// TTF を読み直して stb の字形情報を用意する。キャッシュから読んだアトラスには
    /// 字形情報が付いてこないので、字を足す必要が出たときに初めて開く。
    def ensureInfo(font: Font): Font \ IO =
        match font#info {
            case Some(_) => font
            case None    =>
                let fis = new FileInputStream(font#path);
                let bytes = fis.readAllBytes();
                fis.close();
                let buf = BufferUtils.createByteBuffer(Array.length(bytes));
                discard buf.put(bytes);
                discard buf.flip();
                let info = STBTTFontinfo.malloc();
                discard STBTruetype.stbtt_InitFont(info, buf);
                { info = Some(info), source = Some(buf) | font }
        }

    def growOne(font: Font, cp: Int32): Option[(TextLayout.GlyphMetrics, Font)] \ IO =
        match font#info {
            case None       => None
            case Some(info) =>
                let f32 = RenderUtil.f32;
                let emScale = Float32.toFloat64(
                    STBTruetype.stbtt_ScaleForMappingEmToPixels(info, f32(font#bakeSize)));
                let scale = f32(emScale * RenderFont.oversample());
                let stack = MemoryStack.stackPush();
                let wBuf = stack.mallocInt(1);
                let hBuf = stack.mallocInt(1);
                let xoffBuf = stack.mallocInt(1);
                let yoffBuf = stack.mallocInt(1);
                let advBuf = stack.mallocInt(1);
                let lsbBuf = stack.mallocInt(1);
                STBTruetype.stbtt_GetCodepointHMetrics(info, cp, advBuf, lsbBuf);
                let advance = Int32.toFloat64(advBuf.get(0)) * emScale;
                let sdf = STBTruetype.stbtt_GetCodepointSDF(info, scale, cp, RenderFont.padding(),
                                                            RenderFont.onedge(), RenderFont.pixDist(),
                                                            wBuf, hBuf, xoffBuf, yoffBuf);
                let out =
                    if (Object.isNull(sdf)) {
                        // 形の無い字（半角・全角スペース）は送り幅だけ載せる。載せないと幅 0 の字として
                        // 詰まって描かれ、打った空白が画面から消える。フォントが持っていない字は諦める。
                        if (STBTruetype.stbtt_FindGlyphIndex(info, cp) == 0) None
                        else Some((RenderFont.advanceOnlyGlyph(advance), font))
                    } else {
                        let gw = wBuf.get(0);
                        let gh = hBuf.get(0);
                        let side = font#side;
                        // 行に入らなければ下の行へ。どちらにも入らなければアトラス満杯。
                        let (px, py, rowH) =
                            if (font#cx + gw > side) (0, font#cy + font#rowH + 1, 0)
                            else (font#cx, font#cy, font#rowH);
                        if (px + gw > side or py + gh > side) {
                            STBTruetype.stbtt_FreeSDF(sdf);
                            None
                        } else {
                            GL11.glTexSubImage2D(GL11.GL_TEXTURE_2D, 0, px, py, gw, gh,
                                                 GL11.GL_RED, GL11.GL_UNSIGNED_BYTE, sdf);
                            STBTruetype.stbtt_FreeSDF(sdf);
                            let gm = RenderFont.glyphMetricsOf(
                                { px = px, py = py, gw = gw, gh = gh },
                                { xoff = xoffBuf.get(0), yoff = yoffBuf.get(0), advance = advance },
                                Int32.toFloat64(side));
                            Some((gm, { cx = px + gw + 1, cy = py,
                                        rowH = Int32.max(rowH, gh) | font }))
                        }
                    };
                discard MemoryStack.stackPop();
                out
        }
}
