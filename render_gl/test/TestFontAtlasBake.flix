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
}
