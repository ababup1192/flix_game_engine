// 窓なしで生成して書き出したアトラスが、デスクトップの起動時にキャッシュする物とバイトまで同じか。

mod TestFontAtlasBake {
    import java.io.File
    import java.lang.System
    import java.nio.file.Files
    import java.nio.file.Paths
    import java.util.Arrays

    def ttf(): String = "../templates/rpg-starter/assets/PixelMplus10-Regular.ttf"

    /// TestFontCache と同じキャッシュの置き場。テストごとに差し替えると、同じ JVM で並んで走るテストと行き先を奪い合う。
    def scratchCacheDir(): String \ IO =
        "${System.getProperty("java.io.tmpdir")}/flix_ge_fontcache_test"

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

    /// 書き出した物と、デスクトップの起動時の道（RenderFontCache.loadOrBake）がキャッシュした物が 1 バイトも違わない。
    @Test
    def testBakedFileMatchesDesktopCacheBytes(): Unit \ IO + Assert =
        let root = makeProject("same");
        let out = "${root}/out";
        discard new File(scratchCacheDir()).mkdirs();
        discard System.setProperty("flix.ge.cacheDir", scratchCacheDir());
        discard FontAtlasBake.bakeProject(root, FontAtlasBake.Glyphs.Only(wanted()), out);
        let entry = { name = "default", path = "${root}/assets/f.ttf", fontSize = 10.0 };
        discard RenderFontCache.loadOrBake(entry, Some(wanted()), (_, _) -> checked_ecast(()));
        let fontBytes = Files.readAllBytes(Paths.get(entry#path));
        let cachedPath = "${RenderFontCache.dir()}/${RenderFontCache.keyOf(fontBytes, 10.0, Some(wanted()))}.fontatlas";
        let same = Arrays.equals(Files.readAllBytes(Paths.get(cachedPath)), Files.readAllBytes(Paths.get("${out}/default.fontatlas")));
        discard new File(cachedPath).delete();
        deleteTree(new File(root));
        Assert.assertTrue(same)

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
