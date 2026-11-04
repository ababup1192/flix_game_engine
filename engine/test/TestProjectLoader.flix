// ProjectLoader.loadProject が project.json の任意キー scene3dTextureBudgetCount を読む・既定へ倒す。
mod TestProjectLoader {
    /// project.json の中身 json を、どのパスにも答える Fs.FileRead で読んだ時の枚数の上限。読めなければ -1。
    def budgetCountOf(json: String): Int32 =
        let config = run { ProjectLoader.loadProject("game") } with handler Fs.FileRead {
            def read(_path, k)      = k(Ok(json))
            def readLines(_path, k) = k(Ok(String.lines(json)))
            def readBytes(_path, k) = k(Ok(String.toBytes(json)))
        };
        config |> Result.map(p -> p#config#scene3dTextureBudgetCount) |> Result.getWithDefault(-1)

    /// 必須のキーだけの project.json に、extra（`, "キー": 値` の形）を足した字。
    def projectJson(extra: String): String =
        "{\"title\": \"t\", \"designWidth\": 320, \"designHeight\": 180, \"windowWidth\": 640, \"windowHeight\": 360,"
            + " \"clearColor\": {\"r\": 0.0, \"g\": 0.0, \"b\": 0.0}, \"maxDeltaTime\": 0.1,"
            + " \"textures\": [], \"fonts\": [], \"sounds\": []${extra}}"

    // ── 枚数の上限 ──

    /// キーが無ければ既定（64）。
    @Test
    def testBudgetCountDefaultsWhenMissing(): Unit \ Assert =
        Assert.assertEq(expected = GameEngine.defaultScene3dTextureBudgetCount(), budgetCountOf(projectJson("")))

    /// 書いた値がそのまま入る。
    @Test
    def testBudgetCountReadsValue(): Unit \ Assert =
        Assert.assertEq(expected = 128, budgetCountOf(projectJson(", \"scene3dTextureBudgetCount\": 128")))

    /// 1 未満（0・負）と数でない値は既定へ倒す。
    @Test
    def testBudgetCountBelowOneFallsBackToDefault(): Unit \ Assert =
        let fallback = GameEngine.defaultScene3dTextureBudgetCount();
        Assert.assertEq(expected = (fallback, fallback, fallback),
                        (budgetCountOf(projectJson(", \"scene3dTextureBudgetCount\": 0")),
                         budgetCountOf(projectJson(", \"scene3dTextureBudgetCount\": -5")),
                         budgetCountOf(projectJson(", \"scene3dTextureBudgetCount\": \"many\""))))

}
