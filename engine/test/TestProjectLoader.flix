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

    // ── 縦の design（web.portraitDesign）──

    /// project.json の中身 json を読んだ結果。
    def projectOf(json: String): Result[String, ProjectLoader.Project] =
        run { ProjectLoader.loadProject("game") } with handler Fs.FileRead {
            def read(_path, k)      = k(Ok(json))
            def readLines(_path, k) = k(Ok(String.lines(json)))
            def readBytes(_path, k) = k(Ok(String.toBytes(json)))
        }

    def spec(): ProjectLoader.PortraitDesign = { width = 540, minHeight = 960, maxHeight = 1296 }

    def shapeOf(p: ProjectLoader.PortraitDesign): (Int32, Int32, Int32) = (p#width, p#minHeight, p#maxHeight)

    /// web が無い・web に portraitDesign が無いなら None。
    @Test
    def testPortraitDesignAbsentIsNone(): Unit \ Assert =
        Assert.assertEq(expected = (Ok(None), Ok(None)),
                        (projectOf(projectJson("")) |> Result.map(p -> p#portraitDesign |> Option.map(shapeOf)),
                         projectOf(projectJson(", \"web\": {\"orientation\": \"any\"}")) |> Result.map(p -> p#portraitDesign |> Option.map(shapeOf))))

    /// maxHeight を書かなければ width × 2.4。
    @Test
    def testPortraitDesignReadsWithDefaultMax(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some(shapeOf(spec()))),
                        projectOf(projectJson(", \"web\": {\"portraitDesign\": {\"width\": 540, \"minHeight\": 960}}")) |> Result.map(p -> p#portraitDesign |> Option.map(shapeOf)))

    /// 1 未満・minHeight の欠け・maxHeight < minHeight は読めない。
    @Test
    def testPortraitDesignRejectsBadShape(): Unit \ Assert =
        let bad = body -> Result.isErr(projectOf(projectJson(", \"web\": {\"portraitDesign\": ${body}}")));
        Assert.assertEq(expected = (true, true, true, true),
                        (bad("{\"width\": 0, \"minHeight\": 960}"), bad("{\"width\": 540}"),
                         bad("{\"width\": 540, \"minHeight\": 960, \"maxHeight\": 959}"), bad("{\"width\": 540, \"minHeight\": 540}")))

    /// maxHeight を書かず、minHeight が width × 2.4 より大きい時は、既定の maxHeight を minHeight に上げて読める。
    @Test
    def testPortraitDesignDefaultMaxFollowsMinHeight(): Unit \ Assert =
        Assert.assertEq(expected = Ok(Some((300, 800, 800))),
                        projectOf(projectJson(", \"web\": {\"portraitDesign\": {\"width\": 300, \"minHeight\": 800}}")) |> Result.map(p -> p#portraitDesign |> Option.map(shapeOf)))

    /// 幅は固定、高さは画面の比から（390×844 → 1169）。
    @Test
    def testPortraitDesignHeightFollowsView(): Unit \ Assert =
        Assert.assertEq(expected = (540, 1169), ProjectLoader.portraitDesignOf(spec(), { x = 390.0, y = 844.0 }))

    /// 9:16 より太い画面は minHeight、極端に細い画面は maxHeight で切る。
    @Test
    def testPortraitDesignHeightIsClamped(): Unit \ Assert =
        Assert.assertEq(expected = ((540, 960), (540, 1296), (540, 960)),
                        (ProjectLoader.portraitDesignOf(spec(), { x = 768.0, y = 1024.0 }),
                         ProjectLoader.portraitDesignOf(spec(), { x = 300.0, y = 2000.0 }),
                         ProjectLoader.portraitDesignOf(spec(), { x = 0.0, y = 0.0 })))

    /// 縦の指定があれば design と窓を差し替え、無ければ None。
    @Test
    def testPortraitConfigReplacesDesignAndWindow(): Unit \ Assert =
        let withSpec = projectOf(projectJson(", \"web\": {\"portraitDesign\": {\"width\": 540, \"minHeight\": 960}}"));
        let without = projectOf(projectJson(""));
        let view = { x = 390.0, y = 844.0 };
        let shape = c -> (c#designWidth, c#designHeight, c#windowWidth, c#windowHeight);
        Assert.assertEq(expected = (Ok(Some((540, 1169, 390, 844))), Ok(None)),
                        (withSpec |> Result.map(p -> ProjectLoader.portraitConfigOf(p, view) |> Option.map(shape)),
                         without |> Result.map(p -> ProjectLoader.portraitConfigOf(p, view) |> Option.map(shape))))

}
