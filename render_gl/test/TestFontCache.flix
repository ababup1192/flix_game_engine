// フォントの焼き上がりを取っておく口の「橋渡し」だけを確かめる。
// 焼き方そのもの（距離場の中身）は見ない — それは GL と実機の目視の仕事。

mod TestFontCache {
    import org.lwjgl.BufferUtils
    import java.io.File
    import java.io.RandomAccessFile
    import java.lang.System
    import java.nio.file.Files
    import java.nio.file.Paths

    /// 本物のキャッシュの置き場を汚さないよう、書き込み先をずらす。行き先は 1 つに固定する —
    /// テストごとに差し替えると、同じ JVM で順不同に走ったとき互いの行き先を奪い合う。
    /// テストどうしのぶつかりは印を毎回変えることで避ける（keyFor）。
    def useScratchDir(): Unit \ IO =
        discard new File(scratchDir()).mkdirs();
        discard System.setProperty("flix.ge.cacheDir", scratchDir())

    def scratchDir(): String \ IO =
        "${System.getProperty("java.io.tmpdir")}/flix_ge_fontcache_test"

    /// 小さな焼き上がりを 1 つ作る（一辺 4・字 2 つ）。
    def sample(): RenderFont.BakedFont \ IO =
        let side = 4;
        let pixels = BufferUtils.createByteBuffer(side * side);
        List.forEach(i -> discard pixels.put(i, Int32.tryToInt8(Int32.remainder(i * 7, 120)) |> Option.getWithDefault(0i8)), List.range(0, side * side));
        discard pixels.position(0);
        let gm = (a: Float64) -> ({ xOff = a, yOff = a + 1.0, glyphW = a + 2.0, glyphH = a + 3.0,
                                    advance = a + 4.0, s0 = a + 5.0, t0 = a + 6.0,
                                    s1 = a + 7.0, t1 = a + 8.0 }: TextLayout.GlyphMetrics);
        let glyphs = Map.empty() |> Map.insert(65, gm(1.0)) |> Map.insert(66, gm(20.0));
        { atlas = { textureName = "font_t", fontSize = 16.0, textureSize = 4.0,
                    ascent = 12.0, descent = 3.0, lineGap = 1.5, glyphs = glyphs },
          side = side, pixels = pixels }

    def entry(): RenderAsset.FontEntry = { name = "t", path = "unused.ttf", fontSize = 16.0 }

    def keyFor(name: String): String \ IO = "test_${name}_${System.nanoTime()}"

    /// 取っておいて読み直すと、字の寸法も画素もそのまま戻る。
    /// ここが崩れると 2 回目の起動だけ字がずれる、という一番気付きにくい壊れ方をする。
    @Test
    def testRoundTripKeepsMetricsAndPixels(): Unit \ IO + Assert =
        useScratchDir();
        let key = keyFor("roundtrip");
        let src = sample();
        RenderFontCache.store(key, src);
        match RenderFontCache.load(key, entry()) {
            case None => Assert.assertTrue(false)
            case Some(back) =>
                Assert.assertEq(expected = src#side, back#side);
                Assert.assertEq(expected = src#atlas#fontSize, back#atlas#fontSize);
                Assert.assertEq(expected = src#atlas#ascent, back#atlas#ascent);
                Assert.assertEq(expected = src#atlas#descent, back#atlas#descent);
                Assert.assertEq(expected = src#atlas#lineGap, back#atlas#lineGap);
                // レコードは等値を持てないので、字ごとに数値をそのまま突き合わせる。
                let fields = (gm: TextLayout.GlyphMetrics) ->
                    gm#xOff :: gm#yOff :: gm#glyphW :: gm#glyphH :: gm#advance
                        :: gm#s0 :: gm#t0 :: gm#s1 :: gm#t1 :: Nil;
                let glyphFields = (m: Map[Int32, TextLayout.GlyphMetrics]) ->
                    m |> Map.toList |> List.map(pair -> { let (cp, gm) = pair; (cp, fields(gm)) });
                Assert.assertEq(expected = glyphFields(src#atlas#glyphs), glyphFields(back#atlas#glyphs));
                let same = List.forAll(i -> src#pixels.get(i) == back#pixels.get(i),
                                       List.range(0, src#side * src#side));
                Assert.assertTrue(same)
        }

    /// 中身が壊れていたら「無かったこと」にする（作り直せば済むので、起動は止めない）。
    @Test
    def testCorruptedPixelsAreRejected(): Unit \ IO + Assert =
        useScratchDir();
        let key = keyFor("corrupt");
        RenderFontCache.store(key, sample());
        let path = "${RenderFontCache.dir()}/${key}.fontatlas";
        let raf = new RandomAccessFile(path, "rw");
        // 画素は先頭の見出しのすぐ後ろ。末尾に控えた検算値と食い違う状態を作る。
        raf.seek(raf.length() - 12i64);
        raf.writeByte(0x5A);
        raf.close();
        Assert.assertEq(expected = true, Option.isEmpty(RenderFontCache.load(key, entry())))

    /// 先頭の目印が違うファイルも「無かったこと」にする（別の形式・別のバージョンのなごり）。
    @Test
    def testForeignFileIsRejected(): Unit \ IO + Assert =
        useScratchDir();
        let key = keyFor("foreign");
        RenderFontCache.store(key, sample());
        let path = "${RenderFontCache.dir()}/${key}.fontatlas";
        let raf = new RandomAccessFile(path, "rw");
        raf.seek(0i64);
        raf.writeLong(1i64);
        raf.close();
        Assert.assertEq(expected = true, Option.isEmpty(RenderFontCache.load(key, entry())))

    /// 同じフォントの前の大きさで取っておいた物は、新しく取っておいた時点で片付く。
    /// アトラス 1 枚は最大 64MB あり、大きさを調整するたびに積み上がると すぐ数百 MB になる。
    @Test
    def testStoreDropsOtherSizesOfSameFont(): Unit \ IO + Assert =
        useScratchDir();
        let font = "aaaa1111bbbb2222";
        let oldKey = "${font}_16x0_1";
        let newKey = "${font}_20x0_1";
        let otherFont = "cccc3333dddd4444_16x0_1";
        RenderFontCache.store(oldKey, sample());
        RenderFontCache.store(otherFont, sample());
        RenderFontCache.store(newKey, sample());
        let exists = key -> new File("${RenderFontCache.dir()}/${key}.fontatlas").exists();
        Assert.assertEq(expected = false, exists(oldKey));
        Assert.assertEq(expected = true, exists(newKey));
        // 別のフォントのキャッシュは巻き込まない。
        Assert.assertEq(expected = true, exists(otherFont))

    /// 用意する字の一覧を書き換えたら、前に生成した物を読み直さない。
    /// 読んでしまうと、足したはずの字が出ないまま気付けない。
    @Test
    def testCharsetChangeChangesKey(): Unit \ IO + Assert =
        let bytes: Array[Int8, Static] = Array#{1i8, 2i8, 3i8} @ Static;
        let a = RenderFontCache.keyOf(bytes, 12.0, Some(Set#{0x3042, 0x3044}));
        let b = RenderFontCache.keyOf(bytes, 12.0, Some(Set#{0x3042, 0x3046}));
        let all = RenderFontCache.keyOf(bytes, 12.0, None);
        Assert.assertEq(expected = false, a == b);
        Assert.assertEq(expected = false, a == all);
        // 同じ一覧なら同じ印（毎回作り直しにならない）。
        Assert.assertEq(expected = a, RenderFontCache.keyOf(bytes, 12.0, Some(Set#{0x3044, 0x3042})))

    /// 走査は、そのゲームが出しうる字を拾い、取り込んだライブラリやビルド成果物には入らない。
    /// 入ると、このゲームが出さない字まで用意して起動が遅くなる。
    @Test
    def testHarvestReadsProjectTextButNotLibs(): Unit \ IO + Assert =
        let root = "${System.getProperty("java.io.tmpdir")}/flix_ge_used_glyphs_test";
        discard new File("${root}/assets").mkdirs();
        discard new File("${root}/lib").mkdirs();
        Files.writeString(Paths.get("${root}/assets/a.json"), "{ \"line\": \"あいう\" }");
        Files.writeString(Paths.get("${root}/lib/other.flix"), "// 漢字漢字");
        Files.writeString(Paths.get("${root}/assets/art.png"), "画像のふり");
        match RenderFont.loadUsedGlyphs(root) {
            case None => Assert.assertTrue(false)
            case Some(cps) =>
                // 拾う: あいう
                Assert.assertEq(expected = true, Set.memberOf(0x3042, cps));
                Assert.assertEq(expected = true, Set.memberOf(0x3046, cps));
                // 拾わない: lib の中 / 中身を読まない拡張子
                Assert.assertEq(expected = false, Set.memberOf(0x6F22, cps));
                Assert.assertEq(expected = false, Set.memberOf(0x753B, cps));
                // ASCII は常に入る（得点などは文字列に書かれていなくても画面に出る）
                Assert.assertEq(expected = true, Set.memberOf(0x30, cps))
        }

    /// 何も拾えない場所なら None（＝フォントの字を全部用意する）にする。
    @Test
    def testHarvestFallsBackWhenNothingFound(): Unit \ IO + Assert =
        let root = "${System.getProperty("java.io.tmpdir")}/flix_ge_used_glyphs_empty";
        discard new File(root).mkdirs();
        Assert.assertEq(expected = true, Option.isEmpty(RenderFont.loadUsedGlyphs(root)))

    /// ファイルを開かずに、取っておいた中身の byte 列から同じ焼き上がりが読める（ファイルの無い機種の読み口）。
    @Test
    def testDecodeReadsStoredBytes(): Unit \ IO + Assert =
        useScratchDir();
        let key = keyFor("decode");
        let src = sample();
        RenderFontCache.store(key, src);
        let bytes = Files.readAllBytes(Paths.get("${RenderFontCache.dir()}/${key}.fontatlas"));
        let sides = RenderFontCache.decode(bytes, "font_t") |> Option.map(b -> (b#side, b#atlas#textureName));
        Assert.assertEq(expected = Some((src#side, "font_t")), sides)

    /// 途中で切れた byte 列は「無かったこと」にする（読み出しの途中で例外にしない）。
    @Test
    def testDecodeRejectsTruncatedBytes(): Unit \ IO + Assert =
        let bytes: Array[Int8, Static] = Array#{0x46i8, 0x47i8, 0x45i8} @ Static;
        Assert.assertEq(expected = true, Option.isEmpty(RenderFontCache.decode(bytes, "font_t")))

    /// 取ってない印は素直に「無い」。
    @Test
    def testMissingKeyIsNone(): Unit \ IO + Assert =
        useScratchDir();
        Assert.assertEq(expected = true,
                        Option.isEmpty(RenderFontCache.load(keyFor("nothing"), entry())))
}
