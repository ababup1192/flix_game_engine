// TestUiApi — UiStore の読み戻し getter、UiSpec の defaultFont、UiRender の注入版を固定する。
// UiWorld は（既知のコンパイラ制約を避けるため）レコード直構築せず、必ず parse→spawnRoot で作る。
mod TestUiApi {

    /// JSON テキストを parse して空 UiWorld へ spawnRoot した結果（失敗時 None）。
    def spawnFrom(jsonText: String): Option[UiStore.UiWorld] =
        DocJson.parse(jsonText)
            |> Option.flatMap(json -> UiSpec.parse(json) |> Result.toOption)
            |> Option.map(spec -> let (_, ui) = UiSpec.spawnRoot(spec, UiStore.empty()); ui)

    /// text ノード 1 つを持つ最小ページ。font は明示しない（defaultFont 検証用）。
    def textJson(topLevel: String): String =
        "{" + topLevel
        + "\"root\": {\"name\":\"Page\",\"widget\":\"none\","
        + "\"children\":[{\"name\":\"label\",\"widget\":\"text\",\"text\":\"hi\",\"fontSize\":8.0}]}}"

    /// 塗り箱 1 つだけのページ（text 無し＝atlas 不要）。renderUiWith の純粋性検証用。
    def boxJson(): String =
        "{\"root\": {\"name\":\"Box\",\"widget\":\"box\",\"color\":\"#ff0000\",\"width\":10,\"height\":10}}"

    /// spawn 済みノードの font 名を白箱で覗く（font の公開 getter は無い）。
    def fontOf(path: String, ui: UiStore.UiWorld): Option[String] =
        UiStore.idOf(path, ui)
            |> Option.flatMap(id -> Map.get(id, ui#texts))
            |> Option.map(comp -> comp#font)

    // ── UiStore 読み戻し getter ──

    @Test
    def testTextOfReadsBackSetText(): Unit \ Assert =
        let got = spawnFrom(textJson("")) |> Option.map(ui ->
            let ui1 = UiStore.setText("Page/label", "world", ui);
            (UiStore.textOf("Page/label", ui1), UiStore.textOf("Page/missing", ui1)));
        Assert.assertEq(expected = Some((Some("world"), None)), got)

    @Test
    def testVisibleOfReadsBackSetVisible(): Unit \ Assert =
        let got = spawnFrom(textJson("")) |> Option.map(ui ->
            let ui1 = UiStore.setVisible("Page/label", false, ui);
            // spec 既定は visible=true。設定後は false。未登録パスは None。
            (UiStore.visibleOf("Page", ui1), UiStore.visibleOf("Page/label", ui1),
             UiStore.visibleOf("Page/missing", ui1)));
        Assert.assertEq(expected = Some((Some(true), Some(false), None)), got)

    // ── UiSpec: defaultFont ──

    @Test
    def testDefaultFontFallsBackToUi(): Unit \ Assert =
        // defaultFont 省略・ノード font 省略 → 既定 "ui"。
        let got = spawnFrom(textJson("")) |> Option.flatMap(ui -> fontOf("Page/label", ui));
        Assert.assertEq(expected = Some("ui"), got)

    @Test
    def testDefaultFontAppliesToFontlessText(): Unit \ Assert =
        // トップレベル defaultFont が font 未指定の text に届く。
        let got = spawnFrom(textJson("\"defaultFont\":\"pixel\",")) |> Option.flatMap(ui -> fontOf("Page/label", ui));
        Assert.assertEq(expected = Some("pixel"), got)

    @Test
    def testExplicitFontOverridesDefaultFont(): Unit \ Assert =
        let json =
            "{\"defaultFont\":\"pixel\","
            + "\"root\": {\"name\":\"Page\",\"widget\":\"none\","
            + "\"children\":[{\"name\":\"label\",\"widget\":\"text\",\"text\":\"hi\",\"font\":\"serif\",\"fontSize\":8.0}]}}";
        let got = spawnFrom(json) |> Option.flatMap(ui -> fontOf("Page/label", ui));
        Assert.assertEq(expected = Some("serif"), got)

    // ── UiRender.renderUiWith: 純粋な resolver で描ける（Platform.GpuResources を要求しない）──

    @Test
    def testRenderUiWithIsPureForTexturelessUi(): Unit \ Assert =
        // 箱だけのページ（text 無し）を、純粋な resolver で射影する。この @Test の
        // effect が Assert だけで通ること自体が「Platform.GpuResources 不要」の証明。
        let count = spawnFrom(boxJson()) |> Option.map(ui ->
            let out = UiRender.renderUiWith(
                _ -> bug!("no text nodes in this fixture"),
                _ -> None,
                ui, {x = 320.0, y = 240.0});
            List.length(out#drawables));
        Assert.assertEq(expected = Some(1), count)
}
