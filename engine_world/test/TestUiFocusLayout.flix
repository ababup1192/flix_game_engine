// UiFocus.layoutRectsWith / hitTestUiWith — 当たり判定の枠が、描く側（UiRender.itemsWith）と同じ所に来ること。
// 字の兄弟がある列では、字を 0 の大きさで並べる layoutRects だと後ろの枠が字の高さぶん上にずれる。
mod TestUiFocusLayout {

    /// どの字も送り 6・行の高さ 16（ascent 12 + descent 4）の作り物のアトラス。
    def atlas(): FontAtlas =
        let glyph = { xOff = 0.0, yOff = 0.0, glyphW = 6.0, glyphH = 12.0, advance = 6.0, s0 = 0.0, t0 = 0.0, s1 = 0.0, t1 = 0.0 };
        { textureName = "font_ui", fontSize = 16.0, textureSize = 256.0, ascent = 12.0, descent = 4.0, lineGap = 0.0,
          glyphs = List.range(32, 127) |> List.map(cp -> (cp, glyph)) |> List.toMap }

    /// 縦の列: 字の見出し → ボタン（10×10）。
    def ui(): UiStore.UiWorld =
        let doc = "{\"root\": {\"name\":\"menu\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":100,\"height\":100,\"dir\":\"column\","
                + "\"children\":["
                + "{\"name\":\"head\",\"widget\":\"text\",\"text\":\"Title\",\"fontSize\":16},"
                + "{\"name\":\"button\",\"widget\":\"box\",\"color\":\"#ff0000\",\"width\":10,\"height\":10,\"meta\":\"m/0\"}]}}";
        DocJson.parse(doc)
            |> Option.flatMap(json -> UiSpec.parse(json) |> Result.toOption)
            |> Option.map(spec -> { let (_, spawned) = UiSpec.spawnRoot(spec, UiStore.empty()); spawned })
            |> Option.getWithDefault(UiStore.empty())

    def design(): Vec2.Vec2 = { x = 100.0, y = 100.0 }

    def topOf(path: String, rects: Map[EntityId, Rect2.Rect2], ui: UiStore.UiWorld): Option[Float64] =
        UiStore.idOf(path, ui) |> Option.flatMap(id -> Map.get(id, rects)) |> Option.map(r -> r#position#y)

    /// 描く側がボタンを置いた y（赤い箱の描き物）。
    def drawnButtonTop(): Option[Float64] =
        UiRender.itemsWith(_ -> atlas(), _ -> None, ui(), design())
            |> List.filterMap(placed -> {
                let (drawables, _) = Render.draw(placed :: Nil);
                drawables |> List.head |> Option.flatMap(dd -> {
                    let d = DrawCmd.toSpec(dd);
                    if (d#color#r == 1.0 and d#color#g == 0.0) Some(d#position#y) else None
                })
            }) |> List.head

    /// 字を測った枠のボタンは、描いた所（字の高さ 16 の下）にある。
    @Test
    def testButtonRectMatchesTheDrawing(): Unit \ Assert =
        Assert.assertEq(expected = (Some(16.0), Some(16.0)),
            (topOf("menu/button", UiFocus.layoutRectsWith(_ -> atlas(), ui(), design()), ui()), drawnButtonTop()))

    /// 字だけの要素にも枠がある（字を測らない layoutRects には無い）。
    @Test
    def testTextOnlyElementHasARect(): Unit \ Assert =
        Assert.assertEq(expected = (true, false),
            (Option.nonEmpty(topOf("menu/head", UiFocus.layoutRectsWith(_ -> atlas(), ui(), design()), ui())),
             Option.nonEmpty(topOf("menu/head", UiFocus.layoutRects(ui(), design()), ui()))))

    /// 描いたボタンの上（y = 20）をクリックすると、hitTestUiWith はボタンに当たる。
    @Test
    def testHitTestUiWithHitsTheDrawnButton(): Unit \ Assert =
        Assert.assertEq(expected = UiStore.idOf("menu/button", ui()),
            UiFocus.hitTestUiWith(_ -> atlas(), ui(), design(), { x = 5.0, y = 20.0 }))

    /// メニューの項目の枠も、字を測った所になる。
    @Test
    def testTargetsOfUiWithUseTheDrawnRects(): Unit \ Assert =
        Assert.assertEq(expected = List#{("menu/button", 16.0)},
            UiFocusNav.targetsOfUiWith(_ -> atlas(), "menu", ui(), design()) |> List.map(t -> (t#key, t#rect#position#y)))
}
