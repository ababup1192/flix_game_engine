// RenderCache.lockedEngineDigestOf: packages.lock の字から、エンジンの版の fpkg の SHA-256 を取り出す
// （jar を取ってきて lib/ の無い作業場でも、lib のある作業場と同じ塗りのキャッシュの鍵にするため）。
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
}
