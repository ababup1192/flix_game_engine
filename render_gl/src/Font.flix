// RenderFont — フォントアトラスベイク (STBTruetype SDF + OpenGL R8 テクスチャ)
//
// 各グリフを stb_truetype の単チャンネル SDF (符号付き距離場) としてベイクし、
// シェルフパッキングで 1 枚のアトラスに敷き詰める。描画側 (Shader.flix) は距離場を
// smoothstep で再構成するため、16px ベイクのアトラスでも任意サイズで輪郭がくっきりする。
//
// 出力フォーマット:
//   - 単一チャンネルアトラス (GL_R8)。辺長は必要面積から 4096/8192 を自動選択。
//   - Swizzle で R=1, G=1, B=1, A=red にして「白色 + 距離場を alpha」テクスチャ化
//   - LINEAR フィルタ (距離場を滑らかに補間 → SDF のエッジが綺麗に出る)

mod RenderFont {
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL30
    import org.lwjgl.opengl.GL33
    import org.lwjgl.stb.STBTruetype
    import org.lwjgl.stb.STBTTFontinfo
    import org.lwjgl.BufferUtils
    import org.lwjgl.system.MemoryStack
    import org.lwjgl.system.MemoryUtil
    import java.nio.ByteBuffer
    import java.lang.System
    import java.lang.Exception
    import java.io.File
    import java.nio.file.Files

    /// 用意する字。フォントが持っている字のうち、用意すると決めた物だけ。
    ///
    /// `wanted` が None なら、そのフォントが持つ BMP の字を全部用意する。日本語フォントでは
    /// 数千〜2万字になり、1 字あたり約 2 ミリ秒かかるので起動が数十秒止まる。
    /// `wanted` を渡すと（project.json の `fonts[].charset`）その中の字だけになり、
    /// 見た目を 1 画素も変えずに 1 桁以上速くなる。
    ///
    /// 欲しい字をフォントが持っていなくても黙って落とす — 画面からその字が消えるが、
    /// 起動は止めない。持っているかどうかの見張りはゲーム側の仕事（kaidan の lint-font）。
    def fontCodepoints(fontInfo: STBTTFontinfo, wanted: Option[Set[Int32]]): List[Int32] \ IO =
        let candidates = match wanted {
            case Some(cps) => Set.toList(cps)
            case None      => List.range(0x20, 0x10000)
        };
        candidates |> List.filter(cp -> STBTruetype.stbtt_FindGlyphIndex(fontInfo, cp) != 0)

    /// 起動時に用意する字を決める。mode は project.json の `glyphs`（"used" / "all" / "auto"）。
    /// 環境変数 FLIX_GE_GLYPHS があればそちらが勝つ（作り替えずに試せるように）。
    /// None を返すと「フォントが持つ字を全部」の意味になる。
    pub def startupGlyphs(rootDir: String, mode: String): Option[Set[Int32]] \ IO =
        let env = System.getenv("FLIX_GE_GLYPHS");
        let chosen = if (Object.isNull(env)) mode else env;
        match chosen {
            case "all"  => None
            case "auto" =>
                println("[RenderFont] 起動時は用意せず、出た字から順に用意します");
                Some(Set.empty())
            case "used" => loadUsedGlyphs(rootDir)
            case other  =>
                println("[RenderFont] glyphs に知らない値 '${other}' が指定されたので "
                    + "'auto'（出た字から順に用意する）として扱います");
                Some(Set.empty())
        }

    /// このゲームが画面に出しうる字を、プロジェクト配下のソースとアセットから集める。
    ///
    /// 画面に出る字は、必ずソースの文字列かアセットのどこかに書いてある。だから機械的に
    /// 全部集めれば、実際に出る字を必ず含む。多めに拾っても 1 字 1 ミリ秒弱なので損は小さく、
    /// 取りこぼして字が消える方がずっと痛い — だからコメントの字まで区別せずに拾う。
    ///
    /// ASCII は常に入れる。得点や残り時間のように、文字列として書かれていなくても
    /// 実行中に組み立てられて画面に出る字があるため。
    ///
    /// 1 字も拾えなければ None を返す（＝フォントの字を全部用意する）。走査に失敗しても
    /// 用意し直しが遅いだけで、字が消えることはない。
    pub def loadUsedGlyphs(rootDir: String): Option[Set[Int32]] \ IO =
        try {
            let found = Ref.fresh(Static, Set.empty());
            walkText(new File(rootDir), 0, found);
            let ascii = List.range(0x20, 0x7F) |> List.toSet;
            let cps = Set.union(ascii, Ref.get(found));
            if (Set.size(cps) <= Set.size(ascii)) None else Some(cps)
        } catch {
            case _: Exception => None
        }

    /// 中身を読む相手。実行ファイルや画像を読んでも字は出てこない。
    /// 説明書（.md）は読まない — 人に読ませる文で、ゲームが画面に出す物ではない。
    def textSuffixes(): List[String] = ".flix" :: ".json" :: ".txt" :: ".csv" :: Nil

    /// 入らない場所。取り込んだライブラリ・ビルド成果物・生成した絵・説明書には、
    /// このゲームが画面に出さない字が大量に入っている（拾うと用意する量が跳ね上がる）。
    def skipDirs(): List[String] =
        "lib" :: "build" :: "target" :: ".git" :: ".devbox" :: "node_modules"
            :: "docs" :: "debug" :: "gallery" :: "reference" :: Nil

    /// 配布用に固めた物（dist / dist-win / ...）はゲーム本体の複製なので、
    /// 読むと同じ字を二度拾ったうえ、古い置き土産まで一緒に拾ってしまう。
    def skipPrefixes(): List[String] = "dist" :: Nil

    /// 深追いしすぎないための上限。ゲームの木はこれより浅い。
    def maxDepth(): Int32 = 8

    def walkText(dir: File, depth: Int32, found: Ref[Set[Int32], Static]): Unit \ IO =
        if (depth > maxDepth()) ()
        else {
            let entries = dir.listFiles();
            if (Object.isNull(entries)) ()
            else Array.forEach(f -> {
                let name = f.getName();
                if (f.isDirectory())
                    (if (List.memberOf(name, skipDirs())
                            or String.startsWith({ prefix = "." }, name)
                            or List.exists(pre -> String.startsWith({ prefix = pre }, name), skipPrefixes())) ()
                     else walkText(f, depth + 1, found))
                else if (List.exists(sfx -> String.endsWith({ suffix = sfx }, name), textSuffixes()))
                    collectFrom(f, found)
                else ()
            }, entries)
        }

    def collectFrom(file: File, found: Ref[Set[Int32], Static]): Unit \ IO =
        try {
            let raw = Files.readString(file.toPath());
            // まるごと注釈の行は読まない。画面に出す文が「// で始まる行そのもの」に
            // なることはないので、落としても字は消えない。日本語で説明を書く流儀だと
            // 注釈の字の方が多く、拾うと用意する量が倍増する。
            let text = if (String.endsWith({ suffix = ".flix" }, file.getName()))
                           String.lines(raw)
                               |> List.filter(line -> not String.startsWith({ prefix = "//" }, String.trimLeft(line)))
                               |> List.join("\n")
                       else raw;
            let cps = text |> String.toList |> List.filterMap(ch -> {
                let cp = Char.toBmpCodePoint(ch);
                // 空白と制御文字は用意する意味が無い。ASCII は後でまとめて足す。
                if (cp <= 0x7F) None else Some(Int32.bitwiseAnd(cp, 0xFFFF))
            });
            Ref.put(Set.union(Ref.get(found), List.toSet(cps)), found)
        } catch {
            case _: Exception => ()
        }

    /// アトラス辺長の候補。R8 単チャンネルなので 8192² でも 64MB。
    /// それ以上は CPU 側の直接バッファが巨大になるため候補に入れない。
    /// 最大の候補でも収まらない焼きサイズは fitBakeSize が事前に縮めるので、
    /// 実ベイクの溢れ検査まで届いたら engine 側の詰め方の不具合。
    def atlasSizeCandidates(): List[Int32] = 4096 :: 8192 :: Nil

    def maxAtlasSize(): Int32 = 8192

    /// 焼きサイズの下限。これ以下に縮めても読める字にならないので、
    /// ここで止めて（収まらないまま）実ベイクの検査に委ねる。
    def minBakeSize(): Float64 = 6.0

    /// 収まる最大の焼きサイズを選ぶ。要求どおりで収まるならそのまま返し、
    /// 収まらないときだけ 8192 に入る大きさまで縮める。
    ///
    /// 焼きサイズは「絵の細かさ」だけを決めるつまみで、文字の並びには効かない
    /// （描画時に 出したい大きさ / 焼きサイズ で拡縮するため）。だから勝手に縮めても
    /// レイアウトは 1px も動かない — 少しぼやけるだけで、ゲームは必ず起動する。
    ///
    /// 探し方は二分探索。必要面積の下見（矩形の計算だけ）はラスタライズより桁違いに軽い。
    /// onProbe は 1 回の下見ごとに呼ぶ。下見は全字を走査するので日本語フォントでは数秒かかり、
    /// ここで何も知らせないと起動画面が止まって見える。
    def fitBakeSize(fontInfo: STBTTFontinfo, requested: Float64, padding: Int32,
                    oversample: Float64, cps: List[Int32],
                    onProbe: Unit -> Unit \ IO): Float64 \ IO =
        let fitsAt = size -> {
            onProbe();
            neededArea(fontInfo, scaleOf(fontInfo, size, oversample), padding, cps)
                <= atlasCapacity()
        };
        // 要求が下限より小さいなら縮める余地は無い（縮めるつまみなので、要求より
        // 大きい値を返してはいけない — 大きく返すと収まらないまま実ベイクへ落ちる）。
        if (requested <= minBakeSize() or fitsAt(requested)) requested
        else narrow(fitsAt, minBakeSize(), requested, 8)

    /// lo（収まる）と hi（収まらない）の間を詰めて、収まる最大を返す。
    def narrow(fitsAt: Float64 -> Bool \ IO, lo: Float64, hi: Float64, steps: Int32): Float64 \ IO =
        if (steps <= 0 or hi - lo < 0.5) lo
        else {
            let mid = (lo + hi) / 2.0;
            if (fitsAt(mid)) narrow(fitsAt, mid, hi, steps - 1)
            else narrow(fitsAt, lo, mid, steps - 1)
        }

    /// 最大アトラスに敷ける面積（シェルフ詰めの取りこぼし余裕を差し引いた実効値）。
    def atlasCapacity(): Int32 =
        let side = maxAtlasSize();
        side * side - (side * side) / 8

    def scaleOf(fontInfo: STBTTFontinfo, bakeSize: Float64, oversample: Float64): Float32 \ IO =
        RenderUtil.f32(
            Float32.toFloat64(STBTruetype.stbtt_ScaleForMappingEmToPixels(
                fontInfo, RenderUtil.f32(bakeSize))) * oversample)

    /// 全グリフの SDF セル（bitmap box + 両側 padding + 詰めの 1px）の合計面積。
    def neededArea(fontInfo: STBTTFontinfo, scale: Float32, padding: Int32,
                   cps: List[Int32]): Int32 \ IO =
        let cellArea = cp -> {
            let stack = MemoryStack.stackPush();
            let x0Buf = stack.mallocInt(1);
            let y0Buf = stack.mallocInt(1);
            let x1Buf = stack.mallocInt(1);
            let y1Buf = stack.mallocInt(1);
            STBTruetype.stbtt_GetCodepointBitmapBox(fontInfo, cp, scale, scale, x0Buf, y0Buf, x1Buf, y1Buf);
            let w = x1Buf.get(0) - x0Buf.get(0) + 2 * padding + 1;
            let h = y1Buf.get(0) - y0Buf.get(0) + 2 * padding + 1;
            discard MemoryStack.stackPop();
            w * h
        };
        List.foldLeft((acc, cp) -> acc + cellArea(cp), 0, cps)

    /// 下見: 各グリフの SDF セル寸法（bitmap box + 両側 padding + 詰めの 1px）を合計し、
    /// シェルフパッキングの取りこぼし余裕 (+約14%) を上乗せして、収まる最小の辺長を選ぶ。
    /// SDF 本体の生成より桁違いに軽い（矩形の計算だけでラスタライズしない）。
    /// どの候補にも収まらない見積もりでも最大候補を返し、実ベイクの溢れ検査に委ねる。
    def chooseAtlasSize(fontInfo: STBTTFontinfo, scale: Float32, padding: Int32, cps: List[Int32]): Int32 \ IO =
        let needed = neededArea(fontInfo, scale, padding, cps);
        let fits = size -> needed + needed / 7 <= size * size;
        match List.find(fits, atlasSizeCandidates()) {
            case Some(size) => size
            case None       => 8192
        }

    /// シェルフパッキングの進行状態。
    ///   glyphs   = 確定したグリフメトリクス (cp → GlyphMetrics)
    ///   cx/cy    = 次に置く左上カーソル (px)
    ///   rowH     = 現在の行の最大グリフ高 (px)
    ///   overflow = アトラスに収まらず空白（advance のみ）になった字数
    type alias PackState = {
        glyphs   = Map[Int32, TextLayout.GlyphMetrics],
        cx       = Int32,
        cy       = Int32,
        rowH     = Int32,
        overflow = Int32
    }

    /// advance のみ持つ（矩形を持たない）グリフメトリクスを作る。スペースや溢れ字用。
    pub def advanceOnlyGlyph(advance: Float64): TextLayout.GlyphMetrics =
        { xOff = 0.0, yOff = 0.0, glyphW = 0.0, glyphH = 0.0,
          advance = advance, s0 = 0.0, t0 = 0.0, s1 = 0.0, t1 = 0.0 }

    /// 作り方のバージョン。SDF の詰め方・padding・oversample・用意する字の選び方を変えたら 1 つ上げる。
    /// 上げないと、前の作り方で取っておいた物をそのまま読んでしまう。
    pub def bakeVersion(): Int32 = 1

    /// 距離場の作り方。起動時にまとめて用意する道と、あとから 1 字ずつ足す道
    /// （RenderGlyphGrow）が同じ見た目になるよう、決め事はここ 1 か所だけに置く。
    ///
    /// oversample: 距離場を焼きサイズの倍率ぶん高い解像度でラスタ化する。集 のように横線が
    /// 密な漢字は等倍だと線の隙間が距離場で潰れるため。幾何の寸法は 1/oversample して
    /// 論理サイズへ戻すので、文字の並びも表示サイズも変わらない。
    /// onedge=127 を境界(≈0.5)とし、1px あたりの距離値を onedge/padding で正規化する。
    pub def oversample(): Float64 = 3.0
    pub def padding(): Int32 = 5
    pub def onedge(): Int8 = 127i8
    pub def pixDist(): Float32 = RenderUtil.f32(127.0 / 5.0)

    /// 1 字ぶんの寸法と切り出し位置。距離場を作った結果（画素の大きさ・はみ出し量・送り幅）と
    /// 置いた場所から組む。**起動時に用意するときと後から足すときで同じ式を使う** — ずれると、
    /// あとから足した字だけ位置がおかしい、という気付きにくい壊れ方をする。
    pub def glyphMetricsOf(place: { px = Int32, py = Int32, gw = Int32, gh = Int32 },
                           shape: { xoff = Int32, yoff = Int32, advance = Float64 },
                           sideF: Float64): TextLayout.GlyphMetrics =
        let inv = 1.0 / oversample();
        let pxF = Int32.toFloat64(place#px);
        let pyF = Int32.toFloat64(place#py);
        let gwF = Int32.toFloat64(place#gw);
        let ghF = Int32.toFloat64(place#gh);
        { xOff = Int32.toFloat64(shape#xoff) * inv, yOff = Int32.toFloat64(shape#yoff) * inv,
          glyphW = gwF * inv, glyphH = ghF * inv,
          advance = shape#advance,
          s0 = pxF / sideF, t0 = pyF / sideF,
          s1 = (pxF + gwF) / sideF, t1 = (pyF + ghF) / sideF }

    /// CPU 側だけで焼き上がったアトラス。GL へ上げる前の姿で、
    /// ディスクに取っておく（RenderFontCache）のもこの形。
    pub type alias BakedFont = { atlas = FontAtlas, side = Int32, pixels = ByteBuffer }

    /// 1 つの FontEntry をアトラスにベイクして GPU へ載せる。
    /// 戻り値: (FontAtlas, TextureInfo) — TextureInfo は registry に登録する用。
    /// onGlyph には「焼き終えた字数 / 全字数」を渡す。日本語フォントは 1 本で数千字あり
    /// 起動時間の大半を占めるので、起動画面はここまで細かく進み具合を見せる。
    pub def bakeFontAtlas(entry: RenderAsset.FontEntry, wanted: Option[Set[Int32]],
                          onGlyph: (Int32, Int32) -> Unit \ IO): (FontAtlas, RenderAsset.TextureInfo) \ IO =
        let baked = RenderFontCache.loadOrBake(entry, wanted, onGlyph);
        (baked#atlas, uploadFont(baked))

    /// 焼き上がりを GPU へ載せる。距離場は滑らかに補間して読ませる — 拡大しても輪郭が
    /// 階段にならず、1 枚のアトラスからどの大きさの字もくっきり出せる。
    pub def uploadFont(baked: BakedFont): RenderAsset.TextureInfo \ IO =
        let side = baked#side;
        discard baked#pixels.position(0);
        let texId = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, texId);
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL30.GL_R8, side, side, 0, GL11.GL_RED, GL11.GL_UNSIGNED_BYTE, baked#pixels);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_LINEAR);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_LINEAR);
        // Swizzle: (ONE, ONE, ONE, RED) → 白色 + 距離場を alpha に載せる
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_R, GL11.GL_ONE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_G, GL11.GL_ONE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_B, GL11.GL_ONE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL33.GL_TEXTURE_SWIZZLE_A, GL11.GL_RED);
        let sideF = Int32.toFloat64(side);
        { id = GpuHandle.wrapTextureId(texId), width = sideF, height = sideF }

    /// 全グリフを SDF にして 1 枚へ敷き詰める（GL には一切触らない）。
    /// fontBytes は TTF の中身 — 呼び手が既に読んでいる物を渡す（見分けの印を作るのに要るので二度読みしない）。
    pub def bakeFontCpu(entry: RenderAsset.FontEntry, fontBytes: Array[Int8, Static],
                        wanted: Option[Set[Int32]],
                        onGlyph: (Int32, Int32) -> Unit \ IO): BakedFont \ IO =
        let f32 = RenderUtil.f32;
        let startNanos = System.nanoTime();

        let fontBuffer = BufferUtils.createByteBuffer(Array.length(fontBytes));
        discard fontBuffer.put(fontBytes);
        discard fontBuffer.flip();

        let fontInfo = STBTTFontinfo.malloc();
        discard STBTruetype.stbtt_InitFont(fontInfo, fontBuffer);

        // 作り方の決め事は共有（後から足すときと同じ見た目にするため）。
        let oversample = oversample();
        let padding = padding();
        let onedge = onedge();
        let pixDist = pixDist();

        // このフォントが持つ字を全部数え、要求された焼きサイズが最大アトラスに収まるか下見する。
        // 収まらなければ収まる大きさまで自動で縮める（少しぼやけるだけで、文字の並びは変わらない）。
        let cps = fontCodepoints(fontInfo, wanted);
        let glyphCount = List.length(cps);
        // 下見（収まる焼きサイズ探し・アトラス辺長選び）も全字を 2 度走査するので体感に出る。
        // まだ何割かは言えないので、本数不明（0）として知らせる — 起動画面は
        // 溜まる棒でなく流れるバーになり、進み具合が出せない間も止まって見えない。
        onGlyph(0, 0);
        let bakeSize = fitBakeSize(fontInfo, entry#fontSize, padding, oversample, cps,
            () -> onGlyph(0, 0));
        if (bakeSize < entry#fontSize)
            println("[RenderFont] '${entry#name}': ${List.length(cps)} 字は焼きサイズ "
                + "${entry#fontSize} では最大アトラスに入らないので ${bakeSize} に縮めました"
                + "（文字の並びは変わりません。くっきりさせたいなら字数の少ないフォントにするか、"
                + "project.json の fontSize を下げて意図した値を明示してください）")
        else ();

        // em ベースの補正サイズ。SDF/advance のスケールはこの emScale を使う（従来の
        // PackFontRanges が内部で使う ScaleForPixelHeight(bakeSize) と数学的に一致する）。
        let emScale = Float32.toFloat64(
            STBTruetype.stbtt_ScaleForMappingEmToPixels(fontInfo, f32(bakeSize)));

        // フォントの正式メトリクスを取得
        let metricStack = MemoryStack.stackPush();
        let ascentBuf = metricStack.mallocInt(1);
        let descentBuf = metricStack.mallocInt(1);
        let lineGapBuf = metricStack.mallocInt(1);
        STBTruetype.stbtt_GetFontVMetrics(fontInfo, ascentBuf, descentBuf, lineGapBuf);
        let ascent = Int32.toFloat64(ascentBuf.get(0)) * emScale;
        let descent = -1.0 * Int32.toFloat64(descentBuf.get(0)) * emScale;
        let lineGap = Int32.toFloat64(lineGapBuf.get(0)) * emScale;
        discard MemoryStack.stackPop();

        let scale = f32(emScale * oversample);

        // 焼きサイズが決まったので、それが収まる最小のアトラス辺長を選ぶ。
        // 日本語フルフォントでも自動で 8192 に広がり、それでも足りなければ上で縮んでいるので、
        // ゲーム側は fontSize を品質だけで選べばよい（容量の心配をしない）。
        let bitmapSize  = chooseAtlasSize(fontInfo, scale, padding, cps);
        let bitmapSizeF = Int32.toFloat64(bitmapSize);
        println("[RenderFont] '${entry#name}': ${List.length(cps)} グリフ → ${bitmapSize}x${bitmapSize} アトラス");

        // 全グリフを SDF 化してアトラスに敷き詰める（シェルフパッキング）。
        // bitmap は破壊的に書き込む。1 グリフ生成→blit→メトリクス確定をクロージャで回す。
        let bitmap = BufferUtils.createByteBuffer(bitmapSize * bitmapSize);
        let bakeGlyph = (st: PackState, cp: Int32) -> {
                let stack = MemoryStack.stackPush();
                let wBuf = stack.mallocInt(1);
                let hBuf = stack.mallocInt(1);
                let xoffBuf = stack.mallocInt(1);
                let yoffBuf = stack.mallocInt(1);
                let advBuf = stack.mallocInt(1);
                let lsbBuf = stack.mallocInt(1);
                STBTruetype.stbtt_GetCodepointHMetrics(fontInfo, cp, advBuf, lsbBuf);
                let advance = Int32.toFloat64(advBuf.get(0)) * emScale;
                let sdf = STBTruetype.stbtt_GetCodepointSDF(fontInfo, scale, cp, padding, onedge,
                                                             pixDist, wBuf, hBuf, xoffBuf, yoffBuf);
                let next =
                    if (Object.isNull(sdf))
                        // グリフ無し（スペース等）。advance だけ記録し矩形は 0。
                        { glyphs = Map.insert(cp, advanceOnlyGlyph(advance), st#glyphs) | st }
                    else {
                        let gw = wBuf.get(0);
                        let gh = hBuf.get(0);
                        // 行に収まらなければ次の行へ折り返す。
                        let (cx0, cy0, rowH0) =
                            if (st#cx + gw > bitmapSize) (0, st#cy + st#rowH + 1, 0)
                            else (st#cx, st#cy, st#rowH);
                        if (cx0 + gw > bitmapSize or cy0 + gh > bitmapSize) {
                            // アトラス溢れ。描けないが advance は活かし、末尾で警告を出す。
                            STBTruetype.stbtt_FreeSDF(sdf);
                            { glyphs = Map.insert(cp, advanceOnlyGlyph(advance), st#glyphs),
                              cx = cx0, cy = cy0, rowH = rowH0, overflow = st#overflow + 1 }
                        } else {
                            // SDF ビットマップ (gw×gh) をアトラスの (cx0,cy0) に書き込む。
                            // 行ごとにまとめて写す。1 画素ずつ運ぶ書き方と焼き時間は変わらない
                            // （実測で差は出ない — 時間は距離場を作る側に入っている）。
                            let srcAddr = MemoryUtil.memAddress(sdf);
                            let dstAddr = MemoryUtil.memAddress(bitmap);
                            let rowBytes = Int32.toInt64(gw);
                            List.forEach(y ->
                                MemoryUtil.memCopy(
                                    srcAddr + Int32.toInt64(y * gw),
                                    dstAddr + Int32.toInt64((cy0 + y) * bitmapSize + cx0),
                                    rowBytes),
                                List.range(0, gh));
                            STBTruetype.stbtt_FreeSDF(sdf);
                            let gm = glyphMetricsOf(
                                { px = cx0, py = cy0, gw = gw, gh = gh },
                                { xoff = xoffBuf.get(0), yoff = yoffBuf.get(0), advance = advance },
                                bitmapSizeF);
                            { glyphs = Map.insert(cp, gm, st#glyphs),
                              cx = cx0 + gw + 1, cy = cy0, rowH = Int32.max(rowH0, gh),
                              overflow = st#overflow }
                        }
                    };
                discard MemoryStack.stackPop();
                next
        };
        let initSt: PackState = { glyphs = Map.empty(), cx = 0, cy = 0, rowH = 0, overflow = 0 };
        // 焼けた字数の数え上げは PackState に載せず、報告のためだけの数として外に置く
        // （詰め方の状態と、進み具合の見せ方を混ぜない）。
        let bakedCount = Array#{0} @ Static;
        let finalSt = List.foldLeft((st, cp) -> {
            let next = bakeGlyph(st, cp);
            let done = Array.get(0, bakedCount) + 1;
            Array.put(done, 0, bakedCount);
            onGlyph(done, glyphCount);
            next
        }, initSt, cps);
        // 溢れは起動エラーにする: 空白文字での出荷は「フォントが壊れた」ように見え、
        // 警告 1 行では見逃されるため。焼きサイズは fitBakeSize が収まる大きさまで縮めて
        // あるので、ここへ届くのは詰め方（シェルフパッキング）側の不具合。
        let glyphs =
            if (finalSt#overflow > 0)
                bug!("フォント '${entry#name}' の ${finalSt#overflow} 字が ${bitmapSize}x${bitmapSize} "
                    + "アトラスに収まりません（焼きサイズ ${bakeSize} は下見では収まる見積もりでした "
                    + "— engine の詰め方の不具合）")
            else
                finalSt#glyphs;

        fontInfo.free();

        // 焼きに何秒かかったかは起動時間の内訳そのもの。字数と一緒に必ず出す。
        let seconds = Int64.toFloat64(System.nanoTime() - startNanos) / 1000000000.0;
        println("[RenderFont] '${entry#name}': ${List.length(cps)} グリフを ${seconds} 秒で焼きました");

        let atlas: FontAtlas = {
            textureName = "font_${entry#name}",
            fontSize = bakeSize,
            textureSize = bitmapSizeF,
            ascent = ascent,
            descent = descent,
            lineGap = lineGap,
            glyphs = glyphs
        };
        { atlas = atlas, side = bitmapSize, pixels = bitmap }

    /// 全 FontEntry をベイクし、(名前→FontAtlas) と更新済み TextureRegistry を返す。
    /// onProgress には「フォント名・焼き終えた字数・全字数」を渡す。
    /// wanted は「このゲームが出しうる字」。None なら各フォントが持つ字を全部用意する。
    pub def bakeFontAtlases(manifest: List[RenderAsset.FontEntry],
                            registry: RenderAsset.TextureRegistry,
                            wanted: Option[Set[Int32]],
                            onProgress: (String, Int32, Int32) -> Unit \ IO): (Map[String, FontAtlas], RenderAsset.TextureRegistry) \ IO =
        List.foldLeft((acc, entry) -> {
            let (atlases, reg) = acc;
            // 文言の組み立ては字ごとでなくフォントごとに 1 回。進捗は数千回呼ばれる。
            let report = (done, total) -> onProgress(entry#name, done, total);
            let (atlas, texInfo) = bakeFontAtlas(entry, wanted, report);
            println("  Font '${entry#name}' baked (${atlas#textureName})");
            let newAtlases = Map.insert(entry#name, atlas, atlases);
            let newReg = Map.insert(atlas#textureName, texInfo, reg);
            (newAtlases, newReg)
        }, (Map.empty(), registry), manifest)

}
