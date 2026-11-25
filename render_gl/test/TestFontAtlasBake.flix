// 窓なしで生成して書き出したアトラスの字が、デスクトップの起動時にキャッシュする物と同じ画素・同じ寸法か。

mod TestFontAtlasBake {
    import java.io.File
    import java.lang.System
    import java.nio.file.Files
    import java.nio.file.Paths

    def ttf(): String = "../templates/rpg-starter/assets/PixelMplus10-Regular.ttf"

    /// 小さなゲームの根（project.json とフォント 1 本）を作り、その根を返す。
    def makeProject(name: String): String \ IO =
        let root = "${System.getProperty("java.io.tmpdir")}/flix_ge_font_bake_${name}_${System.nanoTime()}";
        discard new File("${root}/assets").mkdirs();
        discard Files.write(Paths.get("${root}/assets/f.ttf"), Files.readAllBytes(Paths.get(ttf())));
        let json = "{ \"title\": \"t\", \"designWidth\": 16, \"designHeight\": 16, \"windowWidth\": 16, \"windowHeight\": 16,"
            + " \"clearColor\": { \"r\": 0.0, \"g\": 0.0, \"b\": 0.0 }, \"maxDeltaTime\": 0.05, \"textures\": [], \"sounds\": [],"
            + " \"fonts\": [ { \"name\": \"default\", \"path\": \"assets/f.ttf\", \"fontSize\": 10.0 } ] }";
        discard Files.writeString(Paths.get("${root}/project.json"), json);
        root

    /// アトラスは 1 枚 16MB あるので、走らせるたびに一時の置き場へ積み上げない。
    def deleteTree(f: File): Unit \ IO =
        let children = f.listFiles();
        if (Object.isNull(children)) () else Array.forEach(deleteTree, children);
        discard f.delete()

    def wanted(): Set[Int32] = Set#{0x41, 0x61, 0x3042, 0x6F22, 0x30FC}

    /// 書き出したアトラス（Tight）と、デスクトップの起動時と同じ生成（RenderFont.bakeFontCpu・Growable）のアトラス。
    // WhyNot: デスクトップ側をキャッシュのファイルから読まない — 同じ JVM で並んで走るテストが同じファイルを消し合う。
    def bakeBoth(name: String): (RenderFont.BakedFont, RenderFont.BakedFont) \ IO =
        let root = makeProject(name);
        let out = "${root}/out";
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), out);
        let entry = { name = "default", path = "${root}/assets/f.ttf", fontSize = 10.0 };
        let desktop = RenderFont.bakeFontCpu(entry, Files.readAllBytes(Paths.get(entry#path)), Some(wanted()), (_, _) -> checked_ecast(()));
        let web = RenderFontCache.decode(Files.readAllBytes(Paths.get("${out}/default.fontatlas")), "font_default");
        deleteTree(new File(root));
        match web {
            case Some(w) => (w, desktop)
            case None    => bug!("書き出したアトラスを読み戻せない")
        }

    /// 1 字の距離場の矩形（左上から行ごと）の画素。
    def glyphPixels(font: RenderFont.BakedFont, cp: Int32): List[Int8] \ IO =
        let side = font#side;
        let sideF = Int32.toFloat64(side);
        match Map.get(cp, font#atlas#glyphs) {
            case None    => Nil
            case Some(g) =>
                let px = Float64.round(g#s0 * sideF) |> Float64.tryToInt32 |> Option.getWithDefault(0);
                let py = Float64.round(g#t0 * sideF) |> Float64.tryToInt32 |> Option.getWithDefault(0);
                let gw = Float64.round((g#s1 - g#s0) * sideF) |> Float64.tryToInt32 |> Option.getWithDefault(0);
                let gh = Float64.round((g#t1 - g#t0) * sideF) |> Float64.tryToInt32 |> Option.getWithDefault(0);
                List.range(0, gh) |> List.flatMap(y -> List.range(0, gw) |> List.map(x -> font#pixels.get((py + y) * side + px + x)))
        }

    /// UV を除いた 1 字の寸法（置き場所に依らない値）。
    def shapeOf(font: RenderFont.BakedFont, cp: Int32): Option[(Float64, Float64, Float64, Float64, Float64)] =
        Map.get(cp, font#atlas#glyphs) |> Option.map(g -> (g#xOff, g#yOff, g#glyphW, g#glyphH, g#advance))

    /// 書き出したアトラスの字ごとの距離場の画素は、デスクトップのアトラスの同じ字と 1 バイトも違わない。
    @Test
    def testBakedGlyphPixelsMatchDesktop(): Unit \ IO + Assert =
        let (web, desktop) = bakeBoth("pixels");
        let differ = Set.toList(wanted()) |> List.filter(cp -> glyphPixels(web, cp) != glyphPixels(desktop, cp));
        Assert.assertEq(expected = Nil, differ)

    /// 書き出したアトラスの字の寸法と送り幅は、デスクトップのアトラスと同じ。
    @Test
    def testBakedGlyphShapesMatchDesktop(): Unit \ IO + Assert =
        let (web, desktop) = bakeBoth("shapes");
        let differ = Set.toList(wanted()) |> List.filter(cp -> shapeOf(web, cp) != shapeOf(desktop, cp));
        Assert.assertEq(expected = Nil, differ)

    /// 5 字だけのアトラスの辺は 4096 より小さい 4 の倍数。
    @Test
    def testBakedSideIsSmallMultipleOfFour(): Unit \ IO + Assert =
        let (web, _) = bakeBoth("side");
        Assert.assertTrue(web#side < 4096 and Int32.modulo(web#side, 4) == 0)

    /// デスクトップの生成は実行中に字を足す空きを残すので、5 字でも辺は 4096 のまま。
    @Test
    def testDesktopSideStays4096(): Unit \ IO + Assert =
        let (_, desktop) = bakeBoth("desktop");
        Assert.assertEq(expected = 4096, desktop#side)

    /// 3 字ずつ並ぶ幅では 10 字目が下にはみ出す。
    @Test
    def testShelfFitsFailsWhenLastRowOverflows(): Unit \ Assert =
        Assert.assertFalse(RenderFont.shelfFits(40, List.repeat(10, (10, 10))))

    /// 4 字ずつ並ぶ幅なら 3 行で 10 字が収まる。
    @Test
    def testShelfFitsWhenFourPerRow(): Unit \ Assert =
        Assert.assertTrue(RenderFont.shelfFits(44, List.repeat(10, (10, 10))))

    /// 収まる最小の 4 の倍数の辺を選ぶ。
    @Test
    def testTightAtlasSidePicksSmallestFittingSide(): Unit \ Assert =
        Assert.assertEq(expected = 44, RenderFont.tightAtlasSide(List.repeat(10, (10, 10))))

    /// 場所を取る字が無くても辺は 4（0 の辺は decode が読まない）。
    @Test
    def testTightAtlasSideOfNoCellsIsFour(): Unit \ Assert =
        Assert.assertEq(expected = 4, RenderFont.tightAtlasSide(Nil))

    /// 行の右端からはみ出す字は次の行の頭へ置く（行の間は 1px 空ける）。
    @Test
    def testShelfPlaceWrapsToNextRow(): Unit \ Assert =
        let placed = RenderFont.shelfPlace(20, { cx = 15, cy = 0, rowH = 8 }, 10, 6) |> Option.map(p -> { let (x, y, _) = p; (x, y) });
        Assert.assertEq(expected = Some((0, 9)), placed)

    /// アトラスの下へはみ出す字は置けない。
    @Test
    def testShelfPlaceBelowBottomIsNone(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(RenderFont.shelfPlace(20, { cx = 0, cy = 15, rowH = 0 }, 4, 6)))

    /// フォントが持たない字（絵文字）はアトラスに入らない。入らなかった字を数えるのは呼び手の門の仕事。
    @Test
    def testGlyphTheFontLacksIsLeftOut(): Unit \ IO + Assert =
        let root = makeProject("lack");
        let counts = FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(Set.insert(0x1F600, wanted())), "${root}/out")
            |> Result.map(List.map(w -> w#glyphCount));
        deleteTree(new File(root));
        Assert.assertEq(expected = Ok(Set.size(wanted()) :: Nil), counts)

    /// project.json の無い所は Err（書き出しを止める）。
    @Test
    def testMissingProjectIsErr(): Unit \ IO + Assert =
        let root = "${System.getProperty("java.io.tmpdir")}/flix_ge_font_bake_none_${System.nanoTime()}";
        let result = FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.All, "${root}/out");
        deleteTree(new File(root));
        Assert.assertTrue(Result.isErr(result))

    /// 字の集合のファイルは改行や制御文字を字として数えない。
    @Test
    def testCharsetFileSkipsControlChars(): Unit \ IO + Assert =
        let path = "${System.getProperty("java.io.tmpdir")}/flix_ge_charset_${System.nanoTime()}.txt";
        discard Files.writeString(Paths.get(path), "あA\n漢\t");
        let cps = FontAtlasBake.readCharset(path);
        discard new File(path).delete();
        Assert.assertEq(expected = Set#{0x3042, 0x41, 0x6F22}, cps)

    // ── デスクトップの起動が生成した物を読む（RenderFontCache.loadBaked・RenderFont.growableCopy） ──

    def entryOf(root: String, fontSize: Float64): RenderAsset.FontEntry =
        { name = "default", path = "${root}/assets/f.ttf", fontSize = fontSize }

    def fontBytesOf(root: String): Array[Int8, Static] \ IO =
        Files.readAllBytes(Paths.get("${root}/assets/f.ttf"))

    /// build/font-atlas へ生成したゲームの根で loadBaked を呼んだ結果。
    def loadBakedFrom(name: String, fontSize: Float64): Option[Result[String, RenderFont.BakedFont]] \ IO =
        let root = makeProject(name);
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/build/font-atlas");
        let loaded = RenderFontCache.loadBaked(root, entryOf(root, fontSize), fontBytesOf(root));
        deleteTree(new File(root));
        loaded

    def sideOfLoaded(loaded: Option[Result[String, RenderFont.BakedFont]]): Option[Result[String, Int32]] =
        loaded |> Option.map(Result.map(b -> b#side))

    /// 生成した物の隣の .key は、今のフォントと大きさから作った印と同じ。
    @Test
    def testBakeWritesKeyOfCurrentFont(): Unit \ IO + Assert =
        let root = makeProject("key");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/out");
        let stored = String.trim(Files.readString(Paths.get("${root}/out/default.fontatlas.key")));
        let current = RenderFontCache.bakedKeyOf(fontBytesOf(root), 10.0);
        deleteTree(new File(root));
        Assert.assertEq(expected = current, stored)

    /// 印が合う生成した物は、字を足せる 4096 の辺へ写して読む。
    @Test
    def testLoadBakedMovesToGrowableSide(): Unit \ IO + Assert =
        Assert.assertEq(expected = Some(Ok(4096)), sideOfLoaded(loadBakedFrom("load", 10.0)))

    /// 生成した物が無ければ None（黙って今まで通りに生成する）。
    @Test
    def testLoadBakedWithoutFileIsNone(): Unit \ IO + Assert =
        let root = makeProject("none");
        let loaded = RenderFontCache.loadBaked(root, entryOf(root, 10.0), fontBytesOf(root));
        deleteTree(new File(root));
        Assert.assertTrue(Option.isEmpty(loaded))

    /// 生成した時と fontSize が違えば読まない（Err で理由を返す）。
    @Test
    def testLoadBakedWithOtherFontSizeIsErr(): Unit \ IO + Assert =
        Assert.assertTrue(sideOfLoaded(loadBakedFrom("size", 12.0)) |> Option.exists(Result.isErr))

    /// 生成した後にフォントのファイルが替わったら読まない。
    @Test
    def testLoadBakedAfterFontChangedIsErr(): Unit \ IO + Assert =
        let root = makeProject("font");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/build/font-atlas");
        discard Files.write(Paths.get("${root}/assets/f.ttf"),
            Files.readAllBytes(Paths.get("../templates/retro3d-horror-starter/assets/fonts/KaiseiTokumin-Regular.ttf")));
        let loaded = RenderFontCache.loadBaked(root, entryOf(root, 10.0), fontBytesOf(root));
        deleteTree(new File(root));
        Assert.assertTrue(sideOfLoaded(loaded) |> Option.exists(Result.isErr))

    /// build/font-atlas と font-atlas の両方にあれば build/font-atlas を読む（そちらが使えなければ Err）。
    @Test
    def testLoadBakedPrefersBuildDir(): Unit \ IO + Assert =
        let root = makeProject("order");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/font-atlas");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/build/font-atlas");
        discard Files.writeString(Paths.get("${root}/build/font-atlas/default.fontatlas.key"), "other\n");
        let loaded = RenderFontCache.loadBaked(root, entryOf(root, 10.0), fontBytesOf(root));
        deleteTree(new File(root));
        Assert.assertTrue(sideOfLoaded(loaded) |> Option.exists(Result.isErr))

    /// .key が無い生成した物は読まない。
    @Test
    def testLoadBakedWithoutKeyIsErr(): Unit \ IO + Assert =
        let root = makeProject("nokey");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/build/font-atlas");
        discard new File("${root}/build/font-atlas/default.fontatlas.key").delete();
        let loaded = RenderFontCache.loadBaked(root, entryOf(root, 10.0), fontBytesOf(root));
        deleteTree(new File(root));
        Assert.assertTrue(sideOfLoaded(loaded) |> Option.exists(Result.isErr))

    /// 配った物の置き場（font-atlas）でも読む。
    @Test
    def testLoadBakedFromDistDir(): Unit \ IO + Assert =
        let root = makeProject("dist");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/font-atlas");
        let loaded = RenderFontCache.loadBaked(root, entryOf(root, 10.0), fontBytesOf(root));
        deleteTree(new File(root));
        Assert.assertEq(expected = Some(Ok(4096)), sideOfLoaded(loaded))

    /// 字を足せる辺へ写した後も、字ごとの距離場の画素は生成した物と同じ所から読める。
    @Test
    def testGrowableCopyKeepsGlyphPixels(): Unit \ IO + Assert =
        let (tight, _) = bakeBoth("copy");
        let differ = match RenderFont.growableCopy(tight) {
            case None       => Set.toList(wanted())
            case Some(copy) => Set.toList(wanted()) |> List.filter(cp -> glyphPixels(copy, cp) != glyphPixels(tight, cp))
        };
        Assert.assertEq(expected = Nil, differ)

    /// 下に 512 行残る 3584 までは 4096 へ写す。
    @Test
    def testGrowableSideOf3584Is4096(): Unit \ Assert =
        Assert.assertEq(expected = Some(4096), RenderFont.growableSideFor(3584))

    /// 3588 は 4096 では下の空きが足りないので 8192 へ写す。
    @Test
    def testGrowableSideOf3588Is8192(): Unit \ Assert =
        Assert.assertEq(expected = Some(8192), RenderFont.growableSideFor(3588))

    /// 8192 で下に 1024 行残る 7168 までは写せる。
    @Test
    def testGrowableSideOf7168Is8192(): Unit \ Assert =
        Assert.assertEq(expected = Some(8192), RenderFont.growableSideFor(7168))

    /// 7172 はどちらの辺でも空きが足りないので写さない。
    @Test
    def testGrowableSideOf7172IsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, RenderFont.growableSideFor(7172))

    /// 字の矩形（画素の位置）。
    def rectOf(side: Int32, g: TextLayout.GlyphMetrics): (Int32, Int32, Int32, Int32) =
        let at = (uv: Float64) -> Float64.round(uv * Int32.toFloat64(side)) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        (at(g#s0), at(g#t0), at(g#s1), at(g#t1))

    def overlaps(a: (Int32, Int32, Int32, Int32), b: (Int32, Int32, Int32, Int32)): Bool =
        let (ax0, ay0, ax1, ay1) = a;
        let (bx0, by0, bx1, by1) = b;
        ax0 < bx1 and bx0 < ax1 and ay0 < by1 and by0 < ay1

    /// 生成した物を読んだ後に実行中に足した字は、生成した字のどれとも重ならない所へ置かれる。
    @Test
    def testGlyphGrownAfterLoadDoesNotOverlapBaked(): Unit \ IO + Assert =
        let root = makeProject("grow");
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), "${root}/build/font-atlas");
        let entry = entryOf(root, 10.0);
        let added = 0x3044;
        let overlapping = RenderFontCache.loadBaked(root, entry, fontBytesOf(root))
            |> Option.flatMap(Result.toOption)
            |> Option.flatMap(baked -> grownRect(baked, entry, added) |> Option.map(overlapsBaked(baked)));
        deleteTree(new File(root));
        Assert.assertEq(expected = Some(false), overlapping)

    /// 読んだアトラスへ cp を 1 字足し、置かれた矩形を返す（足せなければ None）。
    def grownRect(baked: RenderFont.BakedFont, entry: RenderAsset.FontEntry, cp: Int32): Option[(Int32, Int32, Int32, Int32)] \ IO =
        let table = RenderGlyphGrow.newTable();
        RenderGlyphGrow.register(table, baked#atlas, { path = entry#path, texId = 0 });
        let writer = { begin = _ -> (), put = (_, _, _, _, _) -> (), finish = () -> () };
        let grown = RenderGlyphGrow.ensureWith(writer, table, baked#atlas, Set#{cp});
        Map.get(cp, grown#glyphs) |> Option.map(rectOf(baked#side))

    def overlapsBaked(baked: RenderFont.BakedFont, rect: (Int32, Int32, Int32, Int32)): Bool =
        Set.toList(wanted())
            |> List.filterMap(cp -> Map.get(cp, baked#atlas#glyphs))
            |> List.exists(other -> overlaps(rect, rectOf(baked#side, other)))
}
