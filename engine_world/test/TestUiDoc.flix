// TestUiDoc — ui.json 方言の唯一のパーサ（UiDoc）と、UiSpec 経路との一致を固定する。
// enum に Eq を要求しない「射影してタプル比較」流。Float の期待値は割り切れる入力に限る。
mod TestUiDoc {

    // ── 道具 ──

    def parseDoc(s: String): Option[UiDoc.Spec] =
        DocJson.parse(s) |> Option.flatMap(json -> UiDoc.parse(json) |> Result.toOption)

    /// パースが通るか（エラー系テスト用）。JSON 構文エラーも false。
    def parses(s: String): Bool =
        match parseDoc(s) { case Some(_) => true case None => false }

    def childrenOf(spec: UiDoc.Spec): List[UiDoc.Spec] =
        match spec { case UiDoc.Spec.Spec(node) => node#children }

    def widgetOf(spec: UiDoc.Spec): UiDoc.Widget =
        match spec { case UiDoc.Spec.Spec(node) => node#widget }

    def styleOf(spec: UiDoc.Spec): UiLayout.Style =
        match spec { case UiDoc.Spec.Spec(node) => node#style }

    def noteOf(spec: UiDoc.Spec): Option[String] =
        match spec { case UiDoc.Spec.Spec(node) => node#note }

    def originOf(spec: UiDoc.Spec): Option[String] =
        match spec { case UiDoc.Spec.Spec(node) => node#origin }

    def firstChild(spec: UiDoc.Spec): Option[UiDoc.Spec] =
        List.head(childrenOf(spec))

    def colorTuple(c: Color): (Float64, Float64, Float64) =
        (c#r, c#g, c#b)

    def sizeTuple(v: Vec2.Vec2): (Float64, Float64) =
        (v#x, v#y)

    def rect4(r: Rect2.Rect2): (Float64, Float64, Float64, Float64) =
        (r#position#x, r#position#y, r#size#x, r#size#y)

    /// SizeSpec は ToString を持たないので (タグ, 値) に射影して比べる。
    def sizeSpec2(s: UiLayout.SizeSpec): (String, Float64) =
        match s {
            case UiLayout.SizeSpec.Auto    => ("auto", 0.0)
            case UiLayout.SizeSpec.Px(v)   => ("px", v)
            case UiLayout.SizeSpec.Grow(w) => ("grow", w)
        }

    /// 小数4桁へ丸める（回した頂点の浮動小数比較用）。
    def round4(x: Float64): Float64 = Float64.floor(x * 10000.0 + 0.5) / 10000.0

    /// テキスト計測用のダミーアトラス（グリフ無し）。FontAtlas は単純レコードなので直構築できる。
    def dummyAtlas(): FontAtlas =
        { textureName = "dummy", fontSize = 32.0, textureSize = 256.0,
          ascent = 0.0, descent = 0.0, lineGap = 0.0, glyphs = Map.empty() }

    // ── parse: 基本形 ──

    @Test
    def testParseCircleNode(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":18.0,\"color\":\"#ff0000\",\"zIndex\":10}]}}";
        let got = parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.ShapeW(s) => match s#shape#shape {
                    case UiShape.Shape.CircleS(c) => Some((UiDoc.nameOf(child), c#radius, s#shape#zIndex, colorTuple(s#shape#color)))
                    case _ => None
                }
                case _ => None
            });
        Assert.assertEq(expected = Some(("c", 18.0, 10, (1.0, 0.0, 0.0))), got)

    @Test
    def testShapeIntrinsicBecomesPxStyle(): Unit \ Assert =
        // width/height 未指定の circle は内在サイズ 2r が Px として敷かれる。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":18.0,\"color\":\"#ff0000\"}]}}";
        let got = parseDoc(doc) |> Option.flatMap(firstChild) |> Option.map(child ->
            (sizeSpec2(styleOf(child)#width), sizeSpec2(styleOf(child)#height)));
        Assert.assertEq(expected = Some((("px", 36.0), ("px", 36.0))), got)

    // ── parse: templates / use ──

    @Test
    def testTemplateAppliesAndNodeWins(): Unit \ Assert =
        // テンプレの width 52 をノードの width 40 が上書きし、height はテンプレ値が残る。
        let doc = "{\"templates\": {\"shape\": {\"width\": 52, \"height\": 48, \"zIndex\": 10}},"
                + "\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"use\":\"shape\",\"widget\":\"circle\",\"radius\":18.0,\"color\":\"#ff0000\",\"width\":40}]}}";
        let got = parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.ShapeW(s) =>
                    Some((sizeSpec2(styleOf(child)#width), sizeSpec2(styleOf(child)#height), s#shape#zIndex))
                case _ => None
            });
        Assert.assertEq(
            expected = Some((("px", 40.0), ("px", 48.0), 10)),
            got)

    @Test
    def testUnknownTemplateIsError(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"use\":\"nope\"}}";
        Assert.assertEq(expected = false, parses(doc))

    // ── parse: 色 3 形 ──

    @Test
    def testHsvColorMatchesColorHsv(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":1.0,\"color\":{\"hsv\":[0.5,0.72,1.0]}}]}}";
        let expected = Color.hsv({ h = 0.5, s = 0.72, v = 1.0 });
        let got = parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.ShapeW(s) => Some(colorTuple(s#shape#color))
                case _ => None
            });
        Assert.assertEq(expected = Some(colorTuple(expected)), got)

    @Test
    def testRgbColorKeepsTheNumbersAsWritten(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":1.0,\"color\":{\"rgb\":[0.560784,0.588235,0.713726]}}]}}";
        let got = parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.ShapeW(s) => Some(colorTuple(s#shape#color))
                case _ => None
            });
        Assert.assertEq(
            expected = Some((0.560784, 0.588235, 0.713726)),
            got)

    @Test
    def testInvalidHexColorIsError(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":1.0,\"color\":\"#zz0000\"}]}}";
        Assert.assertEq(expected = false, parses(doc))

    // ── parse: エラー系 ──

    @Test
    def testErrorCases(): Unit \ Assert =
        let unknownWidget = "{\"root\": {\"name\":\"g\",\"widget\":\"blob\",\"color\":\"#ffffff\"}}";
        let noRadius      = "{\"root\": {\"name\":\"g\",\"widget\":\"ngon\",\"n\":5,\"color\":\"#ffffff\"}}";
        let dupNames      = "{\"root\": {\"name\":\"g\",\"children\":["
                          + "{\"name\":\"a\"},{\"name\":\"a\"}]}}";
        let polyTwoPoints = "{\"root\": {\"name\":\"g\",\"widget\":\"poly\",\"color\":\"#ffffff\","
                          + "\"points\":[[0,0],[1,1]]}}";
        let okControl     = "{\"root\": {\"name\":\"g\"}}";
        Assert.assertEq(
            expected = (false, false, false, false, true),
            (parses(unknownWidget), parses(noRadius),
             parses(dupNames), parses(polyTwoPoints), parses(okControl)))

    /// doc のパースエラーを編集者向け文言（describe）で返す（成功や JSON 構文エラーは目印文字列）。
    def errTextOf(doc: String): String =
        DocJson.parse(doc)
            |> Option.map(json -> match UiDoc.parse(json) {
                case Ok(_)  => "no error"
                case Err(e) => DocJson.describe(e)
            })
            |> Option.getWithDefault("no json")

    @Test
    def testErrorCarriesNodePath(): Unit \ Assert =
        // 深いノードの必須キー欠落は、そのノードの名前パスでタグされる（編集箇所へ誘導する）。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":[{\"name\":\"row1\",\"children\":["
                + "{\"name\":\"box\",\"widget\":\"circle\",\"radius\":1.0}]}]}}";
        Assert.assertEq(expected = true, String.contains(substr = "g/row1/box", errTextOf(doc)))

    @Test
    def testErrorCarriesChildIndexWhenNameMissing(): Unit \ Assert =
        // name の無い子は名前で指せないので「親パス[兄弟内位置]」で指す。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"a\"},{\"widget\":\"box\",\"color\":\"#000000\"}]}}";
        Assert.assertEq(expected = true, String.contains(substr = "g[1]", errTextOf(doc)))

    @Test
    def testErrorMessageHasNoDecoderNoise(): Unit \ Assert =
        // describe を通した文言にコンテナの定型句("type mismatch: expected")が残らない —
        // 編集者は「どこで・何が要るか」だけを読む。
        let msg = errTextOf("{\"root\": {\"name\":\"g\",\"widget\":\"circle\",\"radius\":1.0}}");
        Assert.assertEq(
            expected = (true, false),
            (String.contains(substr = "at g: 'color' is required", msg),
             String.contains(substr = "type mismatch", msg)))

    // ── parse: palette（"@名前" の色参照）──

    @Test
    def testPaletteRefResolvesAtParse(): Unit \ Assert =
        let doc = "{\"palette\": {\"accent\": \"#ff0000\"},"
                + "\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":10.0,\"color\":\"@accent\","
                + "\"hover\":{\"borderColor\":\"@accent\"}}]}}";
        let got = parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.ShapeW(s) => match child {
                    case UiDoc.Spec.Spec(node) =>
                        Some((colorTuple(s#shape#color),
                              node#hover |> Option.flatMap(h -> Option.map(colorTuple, h#borderColor))))
                }
                case _ => None
            });
        Assert.assertEq(
            expected = Some(((1.0, 0.0, 0.0), Some((1.0, 0.0, 0.0)))),
            got)

    @Test
    def testUnknownPaletteNameIsError(): Unit \ Assert =
        let doc = "{\"palette\": {\"accent\": \"#ff0000\"},"
                + "\"root\": {\"name\":\"g\",\"widget\":\"box\",\"color\":\"@typo\",\"width\":10,\"height\":10}}";
        Assert.assertEq(expected = true,
            String.contains(substr = "unknown palette color '@typo'", errTextOf(doc)))

    @Test
    def testInstancePaletteIsPerDocument(): Unit \ Assert =
        // 参照先は自分の palette で解決する（使う側の accent は漏れない）。
        let btn = ("btn.ui.json",
            "{\"palette\": {\"accent\": \"#00ff00\"},"
            + "\"root\": {\"name\":\"button\",\"widget\":\"box\",\"color\":\"@accent\",\"width\":10,\"height\":10}}");
        let main = "{\"palette\": {\"accent\": \"#ff0000\"},"
                 + "\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"b\",\"instance\":\"btn.ui.json\"}]}}";
        let got = parseWithDocs(btn :: Nil, main)
            |> Option.flatMap(firstChild)
            |> Option.flatMap(b -> match widgetOf(b) {
                case UiDoc.Widget.BoxW(box) => Some(colorTuple(box#box#color))
                case _ => None
            });
        Assert.assertEq(expected = Some((0.0, 1.0, 0.0)), got)

    @Test
    def testWrapValidation(): Unit \ Assert =
        // wrap は Row + 幅高さ明示のみ。column や auto 寸法は loud に Err。
        let ok       = "{\"root\": {\"name\":\"g\",\"dir\":\"row\",\"wrap\":true,\"width\":100,\"height\":50}}";
        let column   = "{\"root\": {\"name\":\"g\",\"wrap\":true,\"width\":100,\"height\":50}}";
        let autoW    = "{\"root\": {\"name\":\"g\",\"dir\":\"row\",\"wrap\":true,\"height\":50}}";
        Assert.assertEq(
            expected = (true, false, false),
            (parses(ok), parses(column), parses(autoW)))

    // ── parse: version / $schema / "//" ──

    @Test
    def testVersionCheck(): Unit \ Assert =
        let v1 = "{\"version\": 1, \"root\": {\"name\":\"g\"}}";
        let v9 = "{\"version\": 9, \"root\": {\"name\":\"g\"}}";
        Assert.assertEq(expected = (true, false), (parses(v1), parses(v9)))

    @Test
    def testSchemaAndCommentKeysAreIgnored(): Unit \ Assert =
        // "$schema"（エディタ検証用）と "//"（コメント）は受理して無視 — 将来 strict 化しても
        // 壊れない契約としてここで固定する。
        let doc = "{\"$schema\": \"./ui.schema.json\", \"//\": \"top note\","
                + "\"root\": {\"name\":\"g\",\"//\":\"node note\"}}";
        Assert.assertEq(expected = true, parses(doc))

    // ── parse: sprite / bind / meta / layer（UiSpec 互換の保持） ──

    @Test
    def testSpriteParses(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"sprite\",\"texture\":\"hero\","
                + "\"scale\":[2.0,2.0],\"hframes\":4,\"frame\":2}}";
        let got = parseDoc(doc) |> Option.flatMap(spec -> match widgetOf(spec) {
            case UiDoc.Widget.SpriteW(s) => Some((s#texture, s#scale#x, s#hframes, s#frame))
            case _ => None
        });
        Assert.assertEq(expected = Some(("hero", 2.0, 4, 2)), got)

    @Test
    def testBindMetaLayerAreKept(): Unit \ Assert =
        // Flex 経路では使わないが Spec には保持する — 同じ JSON が経路で意味を失わない契約。
        let doc = "{\"root\": {\"name\":\"g\",\"layer\":7,\"children\":["
                + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"bind\":\"score\",\"meta\":\"item0\"}]}}";
        let got = parseDoc(doc) |> Option.flatMap(spec -> match spec {
            case UiDoc.Spec.Spec(root) => List.head(root#children) |> Option.map(child -> match child {
                case UiDoc.Spec.Spec(c) => (root#layer, c#binding, c#meta)
            })
        });
        Assert.assertEq(expected = Some((7, Some("score"), Some("item0"))), got)

    // ── hover（宣言 → spawn → extract 適用 → hitTestUi）──

    @Test
    def testHoverParsesPartialOverride(): Unit \ Assert =
        // hover は部分上書き — 書いたフィールドだけ Some になる。
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,"
                + "\"hover\": {\"color\":\"#ff0000\"}}}";
        let got = parseDoc(doc) |> Option.flatMap(spec -> match spec {
            case UiDoc.Spec.Spec(node) => node#hover |> Option.map(h ->
                (Option.map(colorTuple, h#color), Option.isEmpty(h#tint), Option.isEmpty(h#alpha)))
        });
        Assert.assertEq(expected = Some((Some((1.0, 0.0, 0.0)), true, true)), got)

    @Test
    def testHoverAppliesOnExtractOnlyWhenHovered(): Unit \ Assert =
        // setHovered された entity だけ、宣言された hover 上書きが extract で効く。
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,"
                + "\"hover\": {\"color\":\"#ff0000\"}}}";
        let boxColorAt = ui -> {
            let rects = layoutOf(ui);
            let vis = visOf(ui);
            UiExtract.extract(ui, rects, vis, _ -> dummyAtlas(), _ -> None)
                |> List.head
                |> Option.flatMap(placed -> match placed#item {
                    case Render.Item.Box(b) => Some(colorTuple(b#color))
                    case _                  => None
                })
        };
        let got = spawnDoc(doc) |> Option.map(ui ->
            (boxColorAt(ui), boxColorAt(UiStore.setHovered(Some("g"), ui))));
        Assert.assertEq(
            expected = Some((Some((0.0, 0.0, 0.0)), Some((1.0, 0.0, 0.0)))),
            got)

    @Test
    def testHoverAppliesToPolyAndSprite(): Unit \ Assert =
        // hover は poly（color）と sprite（tint）にも効く — 「宣言を受理して黙って無視」を作らない。
        let doc = "{\"root\": {\"name\":\"g\",\"dir\":\"row\",\"children\":["
                + "{\"name\":\"p\",\"widget\":\"poly\",\"color\":\"#000000\",\"width\":10,\"height\":10,"
                + "\"points\":[[0,0],[10,0],[5,10]],\"hover\":{\"color\":\"#ff0000\"}},"
                + "{\"name\":\"s\",\"widget\":\"sprite\",\"texture\":\"t\",\"width\":10,\"height\":10,"
                + "\"hover\":{\"tint\":\"#ff0000\"}}]}}";
        let got = spawnDoc(doc) |> Option.map(ui -> {
            let hovered = p -> UiStore.setHovered(Some(p), ui);
            let polyColor = u -> UiExtract.extractPolys(u, layoutOf(u), visOf(u))
                |> List.head |> Option.map(entry -> {let (_id, _pos, comp) = entry; colorTuple(comp#color)});
            let spriteTint = u -> UiExtract.extract(u, layoutOf(u), visOf(u), _ -> dummyAtlas(), _ -> None)
                |> List.filterMap(placed -> match placed#item {
                    case Render.Item.Sprite(sp) => Some(colorTuple(sp#tint))
                    case _                      => None
                }) |> List.head;
            (polyColor(hovered("g/p")), spriteTint(hovered("g/s")))
        });
        Assert.assertEq(
            expected = Some((Some((1.0, 0.0, 0.0)), Some((1.0, 0.0, 0.0)))),
            got)

    @Test
    def testHitTestUiFindsButtonsByRect(): Unit \ Assert =
        // 縦に並んだ 2 ボタン(10×10)を hitTestUi で引き分ける。ボタン外は root(全面)に当たる。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"b1\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,\"zIndex\":5},"
                + "{\"name\":\"b2\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,\"zIndex\":5}]}}";
        let design = { x = 100.0, y = 100.0 };
        let pathAt = (ui, p) -> UiFocus.hitTestUi(ui, design, p)
            |> Option.flatMap(id -> UiStore.pathOf(id, ui));
        let got = spawnDoc(doc) |> Option.map(ui ->
            (pathAt(ui, { x = 5.0, y = 5.0 }),
             pathAt(ui, { x = 5.0, y = 15.0 }),
             pathAt(ui, { x = 50.0, y = 50.0 })));
        Assert.assertEq(
            expected = Some((Some("g/b1"), Some("g/b2"), Some("g"))),
            got)

    @Test
    def testHitTestUiIgnoresZeroSizeText(): Unit \ Assert =
        // ボタン中心に重なった text（measures 無しで 0×0）が高 zIndex でも当たりを奪わない —
        // 面積 0 の rect は内部を持たない。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"btn\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,"
                + "\"dir\":\"column\",\"mainAlign\":\"center\",\"crossAlign\":\"center\",\"zIndex\":5,\"children\":["
                + "{\"name\":\"label\",\"widget\":\"text\",\"text\":\"+\",\"zIndex\":9}]}]}}";
        let got = spawnDoc(doc) |> Option.map(ui ->
            UiFocus.hitTestUi(ui, { x = 100.0, y = 100.0 }, { x = 5.0, y = 5.0 })
                |> Option.flatMap(id -> UiStore.pathOf(id, ui)));
        Assert.assertEq(expected = Some(Some("g/btn")), got)

    @Test
    def testHitTestUiSkipsInvisible(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"b1\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,"
                + "\"zIndex\":5,\"visible\":false}]}}";
        let got = spawnDoc(doc) |> Option.map(ui ->
            UiFocus.hitTestUi(ui, { x = 100.0, y = 100.0 }, { x = 5.0, y = 5.0 })
                |> Option.flatMap(id -> UiStore.pathOf(id, ui)));
        // 不可視ボタンには当たらず、背後の root に落ちる。
        Assert.assertEq(expected = Some(Some("g")), got)

    @Test
    def testReloadAllWithReportKeepsOldTreeAndReports(): Unit \ {Assert, IO} =
        // 読めないアセットの root は旧ツリーを保ちつつ、(root名, エラー文言) が報告に載る。
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10}}";
        let got = spawnDoc(doc) |> Option.map(ui -> {
            let ui1 = UiStore.putSource("g", "no/such/file.ui.json", ui);
            let (ui2, errs) = run { UiSpec.reloadAllWithReport(ui1) } with Fs.FileRead.runWithIO;
            (Option.isEmpty(UiStore.idOf("g", ui2)) == false,
             List.map(entry -> {let (rootName, _msg) = entry; rootName}, errs))
        });
        Assert.assertEq(expected = Some((true, "g" :: Nil)), got)

    @Test
    def testSetShapeColorChangesExtractedShape(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"circle\",\"radius\":5.0,\"color\":\"#000000\"}}";
        let red = { r = 1.0, g = 0.0, b = 0.0 };
        let shapeColorAt = ui -> {
            UiExtract.extractShapes(ui, layoutOf(ui), visOf(ui))
                |> List.head
                |> Option.flatMap(placed -> match placed#item {
                    case Render.Item.Box(b) => Some(colorTuple(b#color))
                    case _                  => None
                })
        };
        let got = spawnDoc(doc) |> Option.map(ui ->
            shapeColorAt(UiStore.setShapeColor("g", red, ui)));
        Assert.assertEq(expected = Some(Some((1.0, 0.0, 0.0))), got)

    /// doc を parse → UiSpec 射影 → spawn した UiWorld（テスト用の定型）。
    def spawnDoc(doc: String): Option[UiStore.UiWorld] =
        DocJson.parse(doc)
            |> Option.flatMap(json -> UiSpec.parse(json) |> Result.toOption)
            |> Option.map(spec -> { let (_, ui) = UiSpec.spawnRoot(spec, UiStore.empty()); ui })

    /// 全 root を 100×100 の design で解いた rect 表（テスト用）。
    def layoutOf(ui: UiStore.UiWorld): Map[EntityId, Rect2.Rect2] =
        UiStore.rootsOf(ui) |> List.foldLeft((acc, root) -> Map.union(
            UiLayout.computeLayout(
                {styles = ui#styles, parents = ui#parents, order = ui#order,
                 measures = Map.empty(), visible = ui#visible},
                root, {position = {x = 0.0, y = 0.0}, size = {x = 100.0, y = 100.0}}), acc), Map.empty())

    def visOf(ui: UiStore.UiWorld): Map[EntityId, Bool] =
        UiStore.rootsOf(ui) |> List.foldLeft((acc, root) -> Map.union(
            UiHierarchy.resolveInherited(ui#visible, ui#parents, root, ui#order), acc), Map.empty())

    // ── instance / override ──

    /// (パス, JSON 文字列) の組から resolver を組む。
    def docsResolver(docs: List[(String, String)]): Map[String, Util.Json.Json] =
        docs |> List.filterMap(entry -> {
            let (p, text) = entry;
            DocJson.parse(text) |> Option.map(json -> (p, json))
        }) |> List.toMap

    /// (パス, JSON 文字列) の組を resolver にして root をパースする。
    def parseWithDocs(docs: List[(String, String)], root: String): Option[UiDoc.Spec] =
        DocJson.parse(root) |> Option.flatMap(json ->
            UiDoc.parseWith(docsResolver(docs), json) |> Result.toOption)

    /// parseWithDocs のエラー文言（成功時は目印文字列）。
    def errTextWithDocs(docs: List[(String, String)], root: String): String =
        DocJson.parse(root)
            |> Option.map(json -> match UiDoc.parseWith(docsResolver(docs), json) {
                case Ok(_)  => "no error"
                case Err(e) => DocJson.describe(e)
            })
            |> Option.getWithDefault("no json")

    def buttonDoc(): (String, String) =
        ("btn.ui.json",
         "{\"root\": {\"name\":\"button\",\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10,"
         + "\"children\":[{\"name\":\"label\",\"widget\":\"text\",\"text\":\"?\",\"fontSize\":8.0}]}}")

    @Test
    def testInstanceComposesAndOverrides(): Unit \ Assert =
        // 参照先の root がノードとして合成され、name はノード勝ち・override が子に効く。
        let main = "{\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"b1\",\"instance\":\"btn.ui.json\","
                 + "\"override\": {\"label\": {\"text\":\"+\"}}}]}}";
        let got = parseWithDocs(buttonDoc() :: Nil, main)
            |> Option.flatMap(firstChild)
            |> Option.flatMap(b1 -> firstChild(b1) |> Option.flatMap(label ->
                match widgetOf(label) {
                    case UiDoc.Widget.TextW(t) => Some((UiDoc.nameOf(b1), t#text#text))
                    case _                     => None
                }));
        Assert.assertEq(expected = Some(("b1", "+")), got)

    @Test
    def testInstanceNodeFieldsWinOverRoot(): Unit \ Assert =
        // インスタンスノード自身のフィールド（width）が参照先 root の値に勝つ。
        let main = "{\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"b1\",\"instance\":\"btn.ui.json\",\"width\":20}]}}";
        let got = parseWithDocs(buttonDoc() :: Nil, main)
            |> Option.flatMap(firstChild)
            |> Option.map(b1 -> sizeSpec2(styleOf(b1)#width));
        Assert.assertEq(expected = Some(("px", 20.0)), got)

    @Test
    def testInstanceDeepOverride(): Unit \ Assert =
        // 2 階層の相対名パス("menu/slot0")で子孫を上書きできる。
        let menuDoc = ("menu.ui.json",
            "{\"root\": {\"name\":\"panel\",\"children\":[{\"name\":\"menu\",\"children\":["
            + "{\"name\":\"slot0\",\"widget\":\"text\",\"text\":\"?\",\"fontSize\":8.0}]}]}}");
        let main = "{\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"m\",\"instance\":\"menu.ui.json\","
                 + "\"override\": {\"menu/slot0\": {\"meta\":\"m0\"}}}]}}";
        let got = parseWithDocs(menuDoc :: Nil, main)
            |> Option.flatMap(firstChild)      // m (panel)
            |> Option.flatMap(firstChild)      // menu
            |> Option.flatMap(firstChild)      // slot0
            |> Option.map(slot -> match slot { case UiDoc.Spec.Spec(node) => node#meta });
        Assert.assertEq(expected = Some(Some("m0")), got)

    @Test
    def testInstanceErrorCases(): Unit \ Assert =
        let btn = buttonDoc();
        let badPath   = errTextWithDocs(btn :: Nil,
            "{\"root\": {\"name\":\"g\",\"instance\":\"btn.ui.json\",\"override\":{\"nope\":{\"text\":\"x\"}}}}");
        let children  = errTextWithDocs(btn :: Nil,
            "{\"root\": {\"name\":\"g\",\"instance\":\"btn.ui.json\",\"children\":[]}}");
        let withUse   = errTextWithDocs(btn :: Nil,
            "{\"root\": {\"name\":\"g\",\"use\":\"t\",\"instance\":\"btn.ui.json\"}}");
        let badPatch  = errTextWithDocs(btn :: Nil,
            "{\"root\": {\"name\":\"g\",\"instance\":\"btn.ui.json\",\"override\":{\"label\":{\"children\":[]}}}}");
        let unloaded  = errTextWithDocs(Nil,
            "{\"root\": {\"name\":\"g\",\"instance\":\"btn.ui.json\"}}");
        Assert.assertEq(
            expected = (true, true, true, true, true),
            (String.contains(substr = "not found", badPath),
             String.contains(substr = "children", children),
             String.contains(substr = "cannot be combined", withUse),
             String.contains(substr = "leaf fields only", badPatch),
             String.contains(substr = "not loaded", unloaded)))

    // ── note / origin（エディタ向けの印）──

    @Test
    def testNoteAbsentIsNone(): Unit \ Assert =
        // note を書いていない既存ドキュメントはそのまま通る（後方互換）。
        let doc = "{\"root\": {\"name\":\"g\"}}";
        Assert.assertEq(expected = Some(None), parseDoc(doc) |> Option.map(noteOf))

    @Test
    def testNoteParsesAndNodeWinsOnInstance(): Unit \ Assert =
        // instance の「ノード勝ちマージ」が note にも効く:
        // b1 = ノード側にも note → ノード側が勝つ / b2 = ノード側に無し → 参照先 root の note が残る。
        let btn = ("btn.ui.json",
            "{\"root\": {\"name\":\"button\",\"note\":\"ref note\","
            + "\"widget\":\"box\",\"color\":\"#000000\",\"width\":10,\"height\":10}}");
        let main = "{\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"b1\",\"instance\":\"btn.ui.json\",\"note\":\"node note\"},"
                 + "{\"name\":\"b2\",\"instance\":\"btn.ui.json\"}]}}";
        let got = parseWithDocs(btn :: Nil, main)
            |> Option.map(spec -> childrenOf(spec) |> List.map(noteOf));
        Assert.assertEq(expected = Some(Some("node note") :: Some("ref note") :: Nil), got)

    @Test
    def testOriginMarksInstanceRootOnly(): Unit \ Assert =
        // instance の根には参照パスが刻まれ、通常ノードと instance の子孫は None のまま。
        let main = "{\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"b1\",\"instance\":\"btn.ui.json\"},"
                 + "{\"name\":\"plain\"}]}}";
        let got = parseWithDocs(buttonDoc() :: Nil, main)
            |> Option.map(spec -> {
                let kids = childrenOf(spec);
                (List.map(originOf, kids),
                 List.head(kids) |> Option.flatMap(firstChild) |> Option.map(originOf))
            });
        Assert.assertEq(
            expected = Some((Some("btn.ui.json") :: None :: Nil, Some(None))),
            got)

    @Test
    def testInstanceCycleIsError(): Unit \ Assert =
        let a = ("a.ui.json", "{\"root\": {\"name\":\"a\",\"instance\":\"b.ui.json\"}}");
        let b = ("b.ui.json", "{\"root\": {\"name\":\"b\",\"instance\":\"a.ui.json\"}}");
        let msg = errTextWithDocs(a :: b :: Nil,
            "{\"root\": {\"name\":\"g\",\"instance\":\"a.ui.json\"}}");
        Assert.assertEq(expected = true, String.contains(substr = "instance cycle", msg))

    @Test
    def testLoadMissingInstanceFileIsError(): Unit \ {Assert, IO} =
        let got = run { UiDoc.load("no/such/file.ui.json") } with Fs.FileRead.runWithIO;
        Assert.assertEq(
            expected = true,
            match got { case Err(e) => String.contains(substr = "failed to read", DocJson.describe(e)) case Ok(_) => false })

    // ── paletteFile（外部パレットの load 層合成）──

    @Test
    def testPaletteFileMergesAndInlineWins(): Unit \ {Assert, IO} =
        // 外部パレットの base が引け、同名の accent は inline が勝つ。
        // 参照先 (palette_shared.json) は Doc 規約の "version" キーを含む —
        // version が色として解釈されず読み飛ばされることも、この load で同時に確かめている。
        let got = run { UiSpec.load("test/assets/palette_main.ui.json") } with Fs.FileRead.runWithIO;
        let colors = got |> Result.toOption |> Option.flatMap(firstTwoBoxColors);
        Assert.assertEq(
            expected = Some(((1.0, 0.0, 0.0), (0.0, 0.0, 1.0))),
            colors)

    @Test
    def testPaletteFileSkipsNoteKeys(): Unit \ {Assert, IO} =
        // パレットの注記の鍵（$schema・note・"//" で始まる鍵）は色として読まず、残りの色は引ける（inline の "//" も同じ）。
        let got = run { UiSpec.load("test/assets/palette_noted.ui.json") } with Fs.FileRead.runWithIO;
        Assert.assertEq(
            expected = Ok(Some(((1.0, 0.0, 0.0), (0.0, 0.0, 1.0)))),
            got |> Result.map(firstTwoBoxColors) |> Result.mapErr(DocJson.describe))

    @Test
    def testPaletteFileReadsTheExportedColors(): Unit \ {Assert, IO} =
        // PaletteExport.build が書く色票（{version, note, colors}）を paletteFile にしても、colors の中の色が引ける。
        let got = run { UiSpec.load("test/assets/palette_exported.ui.json") } with Fs.FileRead.runWithIO;
        Assert.assertEq(
            expected = Ok(Some(((1.0, 0.0, 0.0), (0.0, 0.0, 1.0)))),
            got |> Result.map(firstTwoBoxColors) |> Result.mapErr(DocJson.describe))

    /// root 直下の子 2 つの box 色を取り出す(paletteFile テスト用)。
    def firstTwoBoxColors(spec: UiSpec.Spec): Option[((Float64, Float64, Float64), (Float64, Float64, Float64))] =
        match spec {
            case UiSpec.Spec.Spec(root) => twoBoxColors(root#children)
        }

    def twoBoxColors(children: List[UiSpec.Spec]): Option[((Float64, Float64, Float64), (Float64, Float64, Float64))] =
        match children {
            case UiSpec.Spec.Spec(a) :: UiSpec.Spec.Spec(b) :: Nil =>
                a#box |> Option.flatMap(ab -> b#box |> Option.map(bb ->
                    (colorTuple(ab#color), colorTuple(bb#color))))
            case _ => None
        }

    @Test
    def testPaletteFileMissingIsLoudError(): Unit \ {Assert, IO} =
        // paletteFile が読めないときは黙って無視せず Err（文言に paletteFile が入る）。
        let got = run { UiDoc.load("test/assets/palette_missing.ui.json") } with Fs.FileRead.runWithIO;
        Assert.assertEq(
            expected = true,
            match got {
                case Err(e) => String.contains(substr = "paletteFile: failed to read", DocJson.describe(e))
                case Ok(_)  => false
            })

    // ── intrinsicSize ──

    @Test
    def testIntrinsicSizes(): Unit \ Assert =
        let circle  = UiShape.intrinsicSize(UiShape.Shape.CircleS({ radius = 18.0 }));
        let star    = UiShape.intrinsicSize(UiShape.Shape.StarS({ points = 5, outer = 21.0, inner = 9.0,
                                                                  via = UiShape.Via.RenderVia }));
        let ellipse = UiShape.intrinsicSize(UiShape.Shape.EllipseS({ radii = { x = 26.0, y = 16.0 },
                                                                     segments = 32, via = UiShape.Via.RenderVia }));
        // 水平線: lineQuad の法線は真上下に ±w/2 → bbox は (長さ, 太さ)。
        let line    = UiShape.intrinsicSize(UiShape.Shape.LineS({ a = { x = 0.0, y = 0.0 },
                                                                  b = { x = 10.0, y = 0.0 }, lineWidth = 4.0 }));
        // 直線の 2 次ベジェ（制御点が中点）: 背骨は y=0 のまま → bbox は (長さ, 0)。
        let bez     = UiShape.intrinsicSize(UiShape.Shape.BezierS({ p0 = { x = -10.0, y = 0.0 },
                                                                    ctrl = { x = 0.0, y = 0.0 },
                                                                    p1 = { x = 10.0, y = 0.0 },
                                                                    steps = 4, widthFrom = 1.0, widthTo = 1.0 }));
        Assert.assertEq(
            expected = ((36.0, 36.0), (42.0, 42.0), (52.0, 32.0), (10.0, 4.0), (20.0, 0.0)),
            (sizeTuple(circle), sizeTuple(star), sizeTuple(ellipse), sizeTuple(line), sizeTuple(bez)))

    // ── build: レイアウト骨格（描画 rect が Flex の骨格と一致する） ──

    @Test
    def testBuildGallerySkeletonRects(): Unit \ Assert =
        // 固定行 = Px 44/28 の box、伸びる行 = grow の box ×5。root は column + stretch。
        let boxRow = h -> "{\"name\":\"b${h}\",\"widget\":\"box\",\"color\":\"#000000\",\"height\":${h}}";
        let row  = i -> "{\"name\":\"r${i}\",\"widget\":\"box\",\"color\":\"#000000\",\"height\":\"grow\"}";
        let doc = "{\"root\": {\"name\":\"g\",\"dir\":\"column\",\"crossAlign\":\"stretch\",\"children\":["
                + boxRow(44) + ","
                + row(1) + "," + row(2) + "," + row(3) + "," + row(4) + "," + row(5) + ","
                + boxRow(28) + "]}}";
        let rh = (530.0 - 44.0 - 28.0) * (1.0 / 5.0);
        let y1 = 44.0;
        let y2 = y1 + rh;
        let y3 = y2 + rh;
        let y4 = y3 + rh;
        let y5 = y4 + rh;
        let yNote = y5 + rh;
        let got = parseDoc(doc) |> Option.map(spec ->
            Flex.leafRects(UiDoc.build(_ -> dummyAtlas(), spec),
                           { position = { x = 0.0, y = 0.0 }, size = { x = 480.0, y = 530.0 } })
                |> List.map(rect4));
        Assert.assertEq(
            expected = Some(
                       (0.0, 0.0, 480.0, 44.0)
                    :: (0.0, y1, 480.0, rh) :: (0.0, y2, 480.0, rh) :: (0.0, y3, 480.0, rh)
                    :: (0.0, y4, 480.0, rh) :: (0.0, y5, 480.0, rh)
                    :: (0.0, yNote, 480.0, 28.0)
                    :: Nil),
            got)

    // ── build: 配置と回転の FP を固定する ──

    @Test
    def testCirclePlacedAtRectCenter(): Unit \ Assert =
        // 100×40 の中央寄せ root に circle r10 → rect (40,10,20,20)、at = 左上 = (40,10)。
        let doc = "{\"root\": {\"name\":\"g\",\"mainAlign\":\"center\",\"crossAlign\":\"center\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":10.0,\"color\":\"#ff0000\"}]}}";
        let got = parseDoc(doc) |> Option.map(spec ->
            UiDoc.render(_ -> dummyAtlas(), spec,
                         { position = { x = 0.0, y = 0.0 }, size = { x = 100.0, y = 40.0 } })
                |> List.map(p -> (p#at#x, p#at#y)));
        Assert.assertEq(expected = Some((40.0, 10.0) :: Nil), got)

    @Test
    def testPolyRotationMatchesRenderRotated(): Unit \ Assert =
        // 時計の針: JSON（左上相対の整数頂点 + rotation）が、コードで書いた
        // 「lineQuad → Render.rotated → at = 中心」と頂点まで一致する。
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"poly\",\"color\":\"#ffffff\",\"rotation\":0.13,"
                + "\"points\":[[28,24],[28,2],[24,2],[24,24]]}}";
        let expectedVerts = Render.rotated(0.13, RawDraw.lineQuad({ x = 0.0, y = 0.0 }, { x = 0.0, y = -22.0 }, 4.0))
            |> List.map(v -> (v#x, v#y));
        let got = parseDoc(doc) |> Option.flatMap(spec ->
            UiDoc.render(_ -> dummyAtlas(), spec,
                         { position = { x = 0.0, y = 0.0 }, size = { x = 52.0, y = 48.0 } })
                |> List.head)
            |> Option.flatMap(placed -> match placed#item {
                case Render.Item.Poly(p) => Some(((placed#at#x, placed#at#y), List.map(v -> (v#x, v#y), p#vertices)))
                case _                   => None
            });
        Assert.assertEq(expected = Some(((26.0, 24.0), expectedVerts)), got)

    @Test
    def testTextBuildsWithDummyAtlas(): Unit \ Assert =
        // グリフ無しアトラスでも text ノードが 1 描画物になる（寸法は pin しない）。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"fontSize\":9.0}]}}";
        let got = parseDoc(doc) |> Option.map(spec ->
            UiDoc.render(_ -> dummyAtlas(), spec,
                         { position = { x = 0.0, y = 0.0 }, size = { x = 100.0, y = 40.0 } })
                |> List.length);
        Assert.assertEq(expected = Some(1), got)

    // ── UiSpec 経路との一致（方言の二重化解消の pin） ──

    @Test
    def testUiSpecParseAgreesWithUiDoc(): Unit \ Assert =
        // 同じ JSON を UiSpec.parse（射影）と UiDoc.parse に通し、box/text の中身が一致する。
        let doc = "{\"root\": {\"name\":\"g\",\"dir\":\"row\",\"children\":["
                + "{\"name\":\"b\",\"widget\":\"box\",\"color\":\"#112233\",\"cornerRadius\":3.0},"
                + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"fontSize\":9.0}]}}";
        let viaSpec = DocJson.parse(doc)
            |> Option.flatMap(json -> UiSpec.parse(json) |> Result.toOption)
            |> Option.flatMap(spec -> match spec {
                case UiSpec.Spec.Spec(root) => match root#children {
                    case UiSpec.Spec.Spec(b) :: UiSpec.Spec.Spec(t) :: Nil =>
                        b#box |> Option.flatMap(box -> t#text |> Option.map(text ->
                            (colorTuple(box#color), box#cornerRadius, text#text, text#fontSize)))
                    case _ => None
                }
            });
        let viaDoc = parseDoc(doc) |> Option.flatMap(spec -> match childrenOf(spec) {
            case b :: t :: Nil => match (widgetOf(b), widgetOf(t)) {
                case (UiDoc.Widget.BoxW(box), UiDoc.Widget.TextW(text)) =>
                    Some((colorTuple(box#box#color), box#box#cornerRadius, text#text#text, text#text#fontSize))
                case _ => None
            }
            case _ => None
        });
        Assert.assertEq(expected = viaDoc, viaSpec)

    @Test
    def testShapeSpawnsAndExtracts(): Unit \ Assert =
        // circle 図形ノードが UiSpec 経路（spawnRoot → extractShapes）でも 1 個の絵になる。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"c\",\"widget\":\"circle\",\"radius\":10.0,\"color\":\"#ff0000\"}]}}";
        let count = DocJson.parse(doc)
            |> Option.flatMap(json -> UiSpec.parse(json) |> Result.toOption)
            |> Option.map(spec -> {
                let (rootId, ui) = UiSpec.spawnRoot(spec, UiStore.empty());
                let rects = UiLayout.computeLayout(
                    {styles = ui#styles, parents = ui#parents, order = ui#order,
                     measures = Map.empty(), visible = ui#visible},
                    rootId, {position = {x = 0.0, y = 0.0}, size = {x = 100.0, y = 100.0}});
                let vis = UiHierarchy.resolveInherited(ui#visible, ui#parents, rootId, ui#order);
                List.length(UiExtract.extractShapes(ui, rects, vis))
            });
        Assert.assertEq(expected = Some(1), count)

    @Test
    def testRectsOfIsKeyedByNamePath(): Unit \ Assert =
        // 敷いた結果を名前の道で引ける。描くのと同じ宣言から当たり矩形が取れる、が要点。
        let doc = "{\"root\": {\"name\":\"g\",\"dir\":\"row\",\"children\":["
                + "{\"name\":\"a\",\"widget\":\"box\",\"color\":\"#ffffff\",\"width\":40,\"height\":20},"
                + "{\"name\":\"b\",\"widget\":\"box\",\"color\":\"#ffffff\",\"width\":60,\"height\":20}]}}";
        let rects = parseDoc(doc) |> Option.map(spec ->
            UiDoc.rectsOf(_ -> dummyAtlas(), spec,
                          { position = { x = 0.0, y = 0.0 }, size = { x = 100.0, y = 20.0 } }));
        let at = key -> rects |> Option.flatMap(m -> Map.get(key, m)) |> Option.map(rect4);
        Assert.assertEq(expected = (Some((0.0, 0.0, 40.0, 20.0)), Some((40.0, 0.0, 60.0, 20.0))),
            (at("g/a"), at("g/b")))

    @Test
    def testRenderWithRectsAgreesWithRenderAndRectsOf(): Unit \ Assert =
        // 1 回で両方返す近道は、別々に呼んだ結果と一致する（片方だけずれると二重管理に戻る）。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"p\",\"widget\":\"box\",\"color\":\"#ffffff\",\"width\":30,\"height\":10}]}}";
        let rootRect = { position = { x = 5.0, y = 7.0 }, size = { x = 50.0, y = 20.0 } };
        let got = parseDoc(doc) |> Option.map(spec -> {
            let (items, rects) = UiDoc.renderWithRects(_ -> dummyAtlas(), spec, rootRect);
            let plain = UiDoc.render(_ -> dummyAtlas(), spec, rootRect);
            let only = UiDoc.rectsOf(_ -> dummyAtlas(), spec, rootRect);
            (List.length(items) == List.length(plain),
             Map.get("g/p", rects) |> Option.map(rect4),
             Map.get("g/p", only) |> Option.map(rect4))
        });
        Assert.assertEq(expected = Some((true, Some((5.0, 7.0, 30.0, 10.0)), Some((5.0, 7.0, 30.0, 10.0)))), got)

    @Test
    def testBoxRotationTurnsAroundRectCenter(): Unit \ Assert =
        // box の rotation は rect の中心が軸。半周（0.5）なら箱は同じ場所に戻り、
        // 傾きだけが Item に載る（軸が中心である証拠）。
        let doc = "{\"root\": {\"name\":\"b\",\"widget\":\"box\",\"color\":\"#ffffff\",\"rotation\":0.5}}";
        let got = parseDoc(doc) |> Option.flatMap(spec ->
            UiDoc.render(_ -> dummyAtlas(), spec,
                         { position = { x = 10.0, y = 20.0 }, size = { x = 40.0, y = 8.0 } })
                |> List.head)
            |> Option.flatMap(placed -> match placed#item {
                case Render.Item.Box(b) => Some(((placed#at#x, placed#at#y), b#rotation))
                case _                  => None
            });
        Assert.assertEq(expected = Some(((10.0, 20.0), 0.5)), got)

    @Test
    def testShapeRotationTurnsShapeAndIsLoudViaUiSpec(): Unit \ Assert =
        // 図形 widget（star）の傾き。半周回した星は、頂点が rect 中心を挟んで反対側へ移る。
        // UiStore 経路は box / poly と同じく loud に Err。
        let doc = "{\"root\": {\"name\":\"s\",\"widget\":\"star\",\"color\":\"#ffffff\","
                + "\"points\":5,\"outer\":10.0,\"inner\":4.0,\"rotation\":0.5}}";
        let vertsOfDoc = d -> parseDoc(d) |> Option.flatMap(spec ->
            UiDoc.render(_ -> dummyAtlas(), spec,
                         { position = { x = 0.0, y = 0.0 }, size = { x = 20.0, y = 20.0 } })
                |> List.head)
            |> Option.flatMap(placed -> match placed#item {
                case Render.Item.Poly(p) => Some(List.map(v -> (round4(v#x + placed#at#x),
                                                                round4(v#y + placed#at#y)), p#vertices))
                case _                   => None
            });
        let flat = vertsOfDoc(String.replace(src = ",\"rotation\":0.5", dst = "", doc));
        let mirrored = flat |> Option.map(List.map(c -> let (x, y) = c; (round4(20.0 - x), round4(20.0 - y))));
        let uiSpecOk = DocJson.parse(doc) |> Option.map(json -> Result.isOk(UiSpec.parse(json)));
        Assert.assertEq(expected = (mirrored, Some(false)), (vertsOfDoc(doc), uiSpecOk))

    @Test
    def testBoxRotationIsLoudErrorViaUiSpec(): Unit \ Assert =
        // poly と同じ契約: 傾きは Flex 経路（UiDoc）だけが解釈でき、UiStore 経路は黙って落とさず Err。
        let doc = "{\"root\": {\"name\":\"b\",\"widget\":\"box\",\"color\":\"#ffffff\",\"rotation\":0.1}}";
        let uiSpecOk = DocJson.parse(doc) |> Option.map(json -> Result.isOk(UiSpec.parse(json)));
        let uiDocOk  = DocJson.parse(doc) |> Option.map(json -> Result.isOk(UiDoc.parse(json)));
        Assert.assertEq(expected = (Some(false), Some(true)), (uiSpecOk, uiDocOk))

    @Test
    def testPolyRotationIsLoudErrorViaUiSpec(): Unit \ Assert =
        // rotation 付き poly は Flex 経路（UiDoc）では通り、UiStore 経路（UiSpec）では loud に Err —
        // 「黙って無視」を作らない契約の pin。
        let doc = "{\"root\": {\"name\":\"g\",\"widget\":\"poly\",\"color\":\"#ffffff\",\"rotation\":0.1,"
                + "\"points\":[[0,0],[4,0],[2,4]]}}";
        let uiSpecOk = DocJson.parse(doc) |> Option.map(json -> Result.isOk(UiSpec.parse(json)));
        let uiDocOk  = DocJson.parse(doc) |> Option.map(json -> Result.isOk(UiDoc.parse(json)));
        Assert.assertEq(expected = (Some(false), Some(true)), (uiSpecOk, uiDocOk))

    // ── box skin（九分割スキン） ──

    def skinDoc(): String =
        "{\"root\": {\"name\":\"g\",\"children\":["
            + "{\"name\":\"panel\",\"widget\":\"box\",\"color\":\"#112233\","
            + "\"skin\":\"winSkin\",\"skinCorner\":4.0,\"width\":100,\"height\":40}]}}"

    def skinBoxOf(doc: String): Option[UiWidget.BoxComp] =
        parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.BoxW(b) => Some(b#box)
                case _                    => None
            })

    @Test
    def testBoxSkinNineSlice(): Unit \ Assert =
        // skin 指定の box は九分割 Sprite になる。置き先の切れ目は skinCorner（角は等倍）から導く。
        let c = 4.0;
        let w = 100.0;
        let h = 40.0;
        let texInfo = _ -> Some({ id = GpuHandle.wrapTextureId(0), width = 12.0, height = 12.0 });
        let expectedOffsets = List.toSet(
            (0.0 :: c :: w - c :: Nil) |> List.flatMap(x -> (0.0 :: c :: h - c :: Nil) |> List.map(y -> (x, y))));
        let got = skinBoxOf(skinDoc()) |> Option.map(b -> {
            let pieces = UiExtract.boxPlacedItems(b, { x = w, y = h }, texInfo);
            let allSkinSprites = pieces |> List.forAll(p -> match p#item {
                case Render.Item.Sprite(s) => s#texture == "winSkin" and Option.nonEmpty(s#regionRect)
                case _                     => false
            });
            (List.length(pieces), allSkinSprites,
             (pieces |> List.map(p -> (p#at#x, p#at#y)) |> List.toSet) == expectedOffsets)
        });
        Assert.assertEq(expected = Some((9, true, true)), got)

    @Test
    def testBoxSkinFailOpen(): Unit \ Assert =
        // skin 名のテクスチャが引けないときは従来の Box 1 枚へ静かに落とす（パネルは壊れない）。
        let got = skinBoxOf(skinDoc()) |> Option.flatMap(b ->
            match UiExtract.boxPlacedItems(b, { x = 100.0, y = 40.0 }, _ -> None) {
                case placed :: Nil => match placed#item {
                    case Render.Item.Box(bx) => Some((placed#at#x, placed#at#y, bx#size#x, bx#size#y))
                    case _                   => None
                }
                case _ => None
            });
        Assert.assertEq(expected = Some((0.0, 0.0, 100.0, 40.0)), got)

    // ── text の wrap / fit 宣言 ──

    /// text ノードの TextComp を取り出す（他の形は None）。
    def textCompOf(doc: String): Option[UiWidget.TextComp] =
        parseDoc(doc) |> Option.flatMap(firstChild) |> Option.flatMap(child ->
            match widgetOf(child) {
                case UiDoc.Widget.TextW(t) => Some(t#text)
                case _                     => None
            })

    @Test
    def testParseTextWrapAuto(): Unit \ Assert =
        // "wrap": "auto" は自分の矩形幅で折る宣言。宣言しなければ折らない（既定 off）。
        let auto = "{\"root\": {\"name\":\"g\",\"children\":["
                 + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"wrap\":\"auto\"}]}}";
        let plain = "{\"root\": {\"name\":\"g\",\"children\":["
                  + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\"}]}}";
        let got = (textCompOf(auto) |> Option.map(t -> t#wrap),
                   textCompOf(plain) |> Option.map(t -> t#wrap));
        Assert.assertEq(expected = (Some(UiWidget.TextWrap.WrapAuto), Some(UiWidget.TextWrap.WrapOff)), got)

    @Test
    def testParseTextWrapNumberIsPx(): Unit \ Assert =
        // 数値の wrap は「その幅(px)で折る」。
        let doc = "{\"root\": {\"name\":\"g\",\"children\":["
                + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"wrap\":96}]}}";
        let got = textCompOf(doc) |> Option.map(t -> t#wrap);
        Assert.assertEq(expected = Some(UiWidget.TextWrap.WrapPx(96.0)), got)

    /// fit の刻みと下限は宣言が無ければスキーマの既定値（UiWidget の既定と対）。
    /// fitStep / fitMin を書けば上書きできる。
    @Test
    def testParseTextFitDefaultsAndOverride(): Unit \ Assert =
        let defaults = "{\"root\": {\"name\":\"g\",\"children\":["
                     + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"wrap\":\"auto\",\"fit\":true}]}}";
        let overridden = "{\"root\": {\"name\":\"g\",\"children\":["
                       + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"wrap\":\"auto\","
                       + "\"fit\":true,\"fitStep\":0.5,\"fitMin\":4}]}}";
        let fitTuple = t -> t#fit |> Option.map(f -> (f#step, f#minSize));
        let got = (textCompOf(defaults) |> Option.flatMap(fitTuple),
                   textCompOf(overridden) |> Option.flatMap(fitTuple));
        Assert.assertEq(
            expected = (Some((UiWidget.fitStepDefault(), UiWidget.fitMinDefault())), Some((0.5, 4.0))),
            got)

    /// コンテナの "wrap": true（flex の折り返し）は今までどおり真偽値で効き、
    /// text の "wrap": "auto" はコンテナ側のスタイルには漏れない（同じキーの住み分け）。
    @Test
    def testWrapKeyContainerAndTextCoexist(): Unit \ Assert =
        let doc = "{\"root\": {\"name\":\"g\",\"dir\":\"row\",\"width\":100,\"height\":40,\"wrap\":true,\"children\":["
                + "{\"name\":\"t\",\"widget\":\"text\",\"text\":\"hi\",\"wrap\":\"auto\"}]}}";
        let got = parseDoc(doc) |> Option.flatMap(spec -> {
            let containerWrap = styleOf(spec)#wrap;
            firstChild(spec) |> Option.flatMap(child -> match widgetOf(child) {
                case UiDoc.Widget.TextW(t) => Some((containerWrap, styleOf(child)#wrap, t#text#wrap))
                case _                     => None
            })
        });
        Assert.assertEq(expected = Some((true, false, UiWidget.TextWrap.WrapAuto)), got)
}
