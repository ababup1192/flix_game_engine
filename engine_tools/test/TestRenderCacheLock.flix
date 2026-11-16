// RenderCache.lockedEngineDigestOf: packages.lock の字から、エンジンの版の fpkg の SHA-256 を取り出す
// （jar を取ってきて lib/ の無い作業場でも、lib のある作業場と同じ塗りのキャッシュの鍵にするため）。
// RenderCache.paintFlagsOf: 鍵に入れる JVM の起動旗は、絵を変えうる物だけ。
mod TestRenderCacheLock {

    def lock(): String =
        "[lock]\nversion = 1\n\n"
        + "[packages.\"github:ababup1192/flix_game_engine\".\"0.53.0\"]\n"
        + "toml    = \"sha256:aaaa\"\n"
        + "fpkg    = \"sha256:bbbb\"\n\n"
        + "[packages.\"github:someone/dep\".\"1.0.0\"]\n"
        + "fpkg    = \"sha256:cccc\"\n"

    /// 版の節の fpkg の記録を取る（toml の記録ではない）。
    @Test
    def testTakesTheFpkgOfTheVersion(): Unit \ Assert =
        Assert.assertEq(expected = Some("bbbb"), RenderCache.lockedEngineDigestOf("0.53.0", lock()))

    /// 記録の無い版なら None（lib/ の fpkg から取る）。
    @Test
    def testOtherVersionIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, RenderCache.lockedEngineDigestOf("0.52.2", lock()))

    /// 次の節（別の依存）の fpkg を取り違えない。
    @Test
    def testDoesNotReadTheNextSection(): Unit \ Assert =
        let onlyToml = "[packages.\"github:ababup1192/flix_game_engine\".\"0.53.0\"]\ntoml = \"sha256:aaaa\"\n\n"
            + "[packages.\"github:someone/dep\".\"1.0.0\"]\nfpkg = \"sha256:cccc\"\n";
        Assert.assertEq(expected = None, RenderCache.lockedEngineDigestOf("0.53.0", onlyToml))

    /// ヒープ・GC の記録・agent の旗は鍵に入らない（migrate shoot の本数ごとの MaxRAMPercentage で冷えない）。
    @Test
    def testHeapAndGcFlagsAreDropped(): Unit \ Assert =
        let flags = "-Xmx4g" :: "-XX:MaxRAMPercentage=20" :: "-Xlog:gc:file=gc.log" :: "-Xss64m" :: "--enable-native-access=ALL-UNNAMED" :: Nil;
        Assert.assertEq(expected = Nil, RenderCache.paintFlagsOf(flags))

    /// 本数を変えた 2 回（MaxRAMPercentage だけが違う）は同じ旗の列になる。
    @Test
    def testJobsCountDoesNotChangeFlags(): Unit \ Assert =
        let one = "-Djava.awt.headless=true" :: "-XX:MaxRAMPercentage=60" :: Nil;
        let three = "-Djava.awt.headless=true" :: "-XX:MaxRAMPercentage=20" :: Nil;
        Assert.assertEq(expected = RenderCache.paintFlagsOf(one), RenderCache.paintFlagsOf(three))

    /// Java2D・AWT・Swing・字の設定は起動の順のまま残る（絵が変わりうるので鍵を分ける）。
    @Test
    def testPaintFlagsAreKeptInOrder(): Unit \ Assert =
        let flags = "-Dsun.java2d.uiScale=2" :: "-Xmx2g" :: "-Dawt.useSystemAAFontSettings=on" :: "-Djava.awt.headless=true"
            :: "-Dswing.aatext=true" :: "-Dsun.font.fontmanager=x" :: "-Dfge.other=1" :: Nil;
        Assert.assertEq(expected = "-Dsun.java2d.uiScale=2" :: "-Dawt.useSystemAAFontSettings=on" :: "-Djava.awt.headless=true"
                                   :: "-Dswing.aatext=true" :: "-Dsun.font.fontmanager=x" :: Nil,
                        RenderCache.paintFlagsOf(flags))
}
