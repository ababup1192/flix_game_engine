// Render の単体テスト: draw の 2 系統振り分け（Box→Drawable / Poly→PolygonRenderCmd と
// 置き場所の頂点織り込み）、修飾（半透明・角丸素通し・枠・縞・ブレンド）、置き配管
// （atCenter・movedAll・scaledAllAround・rotatedAround・turnedAll・glyphFingerprint）を
// 具体値で固定する。図形そのものの幾何は TestRawDraw を見る。
mod TestRender {

    def red(): Color = { r = 1.0, g = 0.0, b = 0.0 }

    // draw の振り分け: Box は Drawable に、Poly は PolygonRenderCmd に出る。
    // Poly の頂点は置き場所相対 → 出力では加算済み（(0,0) が (100,200) になる）。
    @Test
    def testDrawSplitsAndOffsetsPoly(): Unit \ Assert =
        let items =
            { at = { x = 1.0, y = 2.0 }, item = RawDraw.box({ x = 10.0, y = 5.0 }, red(), 3) } ::
            { at = { x = 100.0, y = 200.0 },
              item = RawDraw.polygon({ x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 3.0 } :: Nil, red(), 7) } :: Nil;
        let (drawables, polygons) = Render.draw(items);
        let firstVertex = polygons |> List.head |> Option.flatMap(p -> List.head(p#vertices)) |> Option.map(v -> (v#x, v#y));
        Assert.assertEq(expected = (1, 1, Some((100.0, 200.0)), Some(7)),
            (List.length(drawables), List.length(polygons), firstVertex,
             polygons |> List.head |> Option.map(p -> p#zIndex)))

    // flipH: 頂点の x が符号反転し（y 不変）、2 回で元に戻る。
    @Test
    def testFlipHMirrorsVerticesAndIsInvolutive(): Unit \ Assert =
        let verts = { x = 4.0, y = 0.0 } :: { x = 0.0, y = 3.0 } :: Nil;
        let once = Render.flipH(verts);
        let twice = Render.flipH(once);
        let headOf = vs -> List.head(vs) |> Option.map(v -> (v#x, v#y));
        Assert.assertEq(expected = (Some((-4.0, 0.0)), Some((4.0, 0.0))), (headOf(once), headOf(twice)))

    // flipV: 頂点の y が符号反転する（x 不変）。
    @Test
    def testFlipVMirrorsVerticesVertically(): Unit \ Assert =
        let verts = { x = 4.0, y = 3.0 } :: Nil;
        Assert.assertEq(expected = Some((4.0, -3.0)),
            List.head(Render.flipV(verts)) |> Option.map(v -> (v#x, v#y)))

    // spriteFlipped: 名前渡しの flip がそのまま Sprite のフィールドに立つ。
    @Test
    def testSpriteFlippedSetsFlags(): Unit \ Assert =
        let flags = match Render.spriteFlipped("hero", 5, { flipH = true, flipV = false }) {
            case Render.Item.Sprite(s) => Some((s#flipH, s#flipV, s#centered))
            case _                           => None
        };
        Assert.assertEq(expected = Some((true, false, true)), flags)

    // 修飾: fade は Box の α を差し替え、rounded は Poly には効かず素通し（Poly は Poly のまま出る）。
    @Test
    def testModifiersApplyAndPassThrough(): Unit \ Assert =
        let faded = RawDraw.box({ x = 1.0, y = 1.0 }, red(), 0) |> Render.fade(0.5);
        let (ds, _) = Render.draw({ at = { x = 0.0, y = 0.0 }, item = faded } :: Nil);
        let untouched = RawDraw.polygon({ x = 0.0, y = 0.0 } :: Nil, red(), 0) |> Render.rounded(4.0);
        let (_, ps) = Render.draw({ at = { x = 9.0, y = 9.0 }, item = untouched } :: Nil);
        Assert.assertEq(expected = (Some(0.5), 1),
            (ds |> List.head |> Option.map(d -> DrawCmd.alphaOf(d)), List.length(ps)))

    // fadeAll は字にも効く: 字の画素 1 つずつの α が薄めた値になり、色（tint）はそのまま。
    @Test
    def testFadeAllReachesTextGlyphs(): Unit \ Assert =
        let placed = { at = { x = 0.0, y = 0.0 },
                       item = Render.textTinted("AB", testAtlas(), 1.0, red(), 0) };
        let (ds, _) = Render.draw(Render.fadeAll(0.25, placed :: Nil));
        Assert.assertEq(expected = (0.25 :: 0.25 :: Nil, Some((1.0, 0.0, 0.0))),
            (ds |> List.map(DrawCmd.alphaOf),
             ds |> List.head |> Option.map(DrawCmd.colorOf) |> Option.map(c -> (c#r, c#g, c#b))))

    // 薄めていない字は不透明のまま（fade(1.0) を掛けても濃さは変わらない）。
    @Test
    def testUnfadedTextStaysOpaque(): Unit \ Assert =
        let placed = { at = { x = 0.0, y = 0.0 }, item = Render.text("AB", testAtlas(), 1.0, 0) };
        let (plain, _) = Render.draw(placed :: Nil);
        let (once, _) = Render.draw(Render.fadeAll(1.0, placed :: Nil));
        Assert.assertEq(expected = (1.0 :: 1.0 :: Nil, 1.0 :: 1.0 :: Nil),
            (plain |> List.map(DrawCmd.alphaOf), once |> List.map(DrawCmd.alphaOf)))

    // outline と striped は同じ Box の style に重なる（枠幅・縞の濃度と周期を同時に pin）。
    @Test
    def testOutlineAndStripedStack(): Unit \ Assert =
        let item = RawDraw.box({ x = 2.0, y = 2.0 }, red(), 0)
            |> Render.outline(red(), 1.5)
            |> Render.striped({ color = red(), alpha = 0.25, width = 2.0, period = 6.0, dir = 0 });
        let (ds, _) = Render.draw({ at = { x = 0.0, y = 0.0 }, item = item } :: Nil);
        let style = ds |> List.head |> Option.flatMap(d -> DrawCmd.styleOf(d));
        Assert.assertEq(expected = (Some(1.5), Some(0.25), Some(6.0)),
            (style |> Option.map(s -> DrawCmd.styleToSpec(s)#borderWidth),
             style |> Option.map(s -> DrawCmd.styleToSpec(s)#stripeAlpha),
             style |> Option.map(s -> DrawCmd.styleToSpec(s)#stripePeriod)))

    // striped の dir（0 = 斜め / 1 = 横 / 2 = 縦）がそのまま style の stripeDir に載る。
    @Test
    def testStripedDirVariants(): Unit \ Assert =
        let dirOf = dir -> {
            let item = RawDraw.box({ x = 2.0, y = 2.0 }, red(), 0)
                |> Render.striped({ color = red(), alpha = 0.25, width = 2.0, period = 6.0, dir = dir });
            let (ds, _) = Render.draw({ at = { x = 0.0, y = 0.0 }, item = item } :: Nil);
            ds |> List.head |> Option.flatMap(d -> DrawCmd.styleOf(d)) |> Option.map(s -> DrawCmd.styleToSpec(s)#stripeDir)
        };
        Assert.assertEq(expected = (Some(0), Some(1), Some(2)), (dirOf(0), dirOf(1), dirOf(2)))

    // checker は Box の style に市松（色・濃度・セル辺）を書き込む。
    @Test
    def testCheckerSetsStyle(): Unit \ Assert =
        let item = RawDraw.box({ x = 8.0, y = 8.0 }, red(), 0)
            |> Render.checker({ color = red(), alpha = 0.5, cell = 4.0 });
        let (ds, _) = Render.draw({ at = { x = 0.0, y = 0.0 }, item = item } :: Nil);
        let style = ds |> List.head |> Option.flatMap(d -> DrawCmd.styleOf(d));
        Assert.assertEq(expected = (Some(0.5), Some(4.0)),
            (style |> Option.map(s -> DrawCmd.styleToSpec(s)#checkerAlpha),
             style |> Option.map(s -> DrawCmd.styleToSpec(s)#checkerCell)))

    // ── blend（ピクセルの重ね方）──

    /// blend テスト用の小さな三角形。
    def triangle(): List[Vec2.Vec2] =
        { x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 3.0 } :: Nil

    // 何も指定しなければ全部 Normal — 既存の描画の見た目が 1 ビットも変わらない前提条件。
    @Test
    def testBlendDefaultsToNormal(): Unit \ Assert =
        let items =
            { at = Vec2.zero(), item = Render.sprite("ball", 0) } ::
            { at = Vec2.zero(), item = RawDraw.box({ x = 2.0, y = 2.0 }, red(), 0) } ::
            { at = Vec2.zero(), item = RawDraw.polygon(triangle(), red(), 0) } :: Nil;
        let (ds, ps) = Render.draw(items);
        Assert.assertEq(
            expected = (Some(DrawCmd.BlendMode.Normal), Some(DrawCmd.BlendMode.Normal), Some(DrawCmd.BlendMode.Normal)),
            (ds |> List.head |> Option.map(d -> DrawCmd.blendOf(d)),
             ds |> List.drop(1) |> List.head |> Option.map(d -> DrawCmd.blendOf(d)),
             ps |> List.head |> Option.map(p -> p#blend)))

    // blended は Sprite / Box / Poly に効き、draw の出口（Drawable / PolygonRenderCmd）まで届く。
    @Test
    def testBlendedReachesDrawOutput(): Unit \ Assert =
        let items =
            { at = Vec2.zero(), item = Render.sprite("ball", 0) |> Render.blended(DrawCmd.BlendMode.Add) } ::
            { at = Vec2.zero(), item = RawDraw.box({ x = 2.0, y = 2.0 }, red(), 0) |> Render.blended(DrawCmd.BlendMode.Multiply) } ::
            { at = Vec2.zero(), item = RawDraw.polygon(triangle(), red(), 0) |> Render.blended(DrawCmd.BlendMode.Add) } :: Nil;
        let (ds, ps) = Render.draw(items);
        Assert.assertEq(
            expected = (Some(DrawCmd.BlendMode.Add), Some(DrawCmd.BlendMode.Multiply), Some(DrawCmd.BlendMode.Add)),
            (ds |> List.head |> Option.map(d -> DrawCmd.blendOf(d)),
             ds |> List.drop(1) |> List.head |> Option.map(d -> DrawCmd.blendOf(d)),
             ps |> List.head |> Option.map(p -> p#blend)))

    // blended は Clipped の clip 矩形越しに葉へ届く（fade と同じ onLeaf 規約）。clip 矩形（clip）はそのまま残る。
    @Test
    def testBlendedThroughClip(): Unit \ Assert =
        let clipRect = { position = Vec2.zero(), size = { x = 4.0, y = 4.0 } };
        let boxed = Render.clipped(clipRect, RawDraw.box({ x = 2.0, y = 2.0 }, red(), 0))
            |> Render.blended(DrawCmd.BlendMode.Add);
        let (ds, _) = Render.draw({ at = Vec2.zero(), item = boxed } :: Nil);
        Assert.assertEq(expected = (Some(DrawCmd.BlendMode.Add), Some(true)),
            (ds |> List.head |> Option.map(d -> DrawCmd.blendOf(d)),
             ds |> List.head |> Option.map(d -> Option.nonEmpty(DrawCmd.clipOf(d)))))

    // atCenter は「左上原点の item」の中心置き — 同じ box なら boxAt と同じ場所に着地する
    // （2 つの公開 API の整合。Poly を渡す誤用は bug! で loud に落ちる設計なのでテストしない）。
    @Test
    def testAtCenterAgreesWithBoxAt(): Unit \ Assert =
        let viaAtCenter = RawDraw.box({ x = 40.0, y = 30.0 }, red(), 0)
            |> Render.atCenter({ x = 100.0, y = 50.0 }, { x = 40.0, y = 30.0 });
        let viaBoxAt = RawDraw.boxAt({ x = 100.0, y = 50.0 }, { x = 40.0, y = 30.0 }, red(), 0);
        Assert.assertEq(expected = (viaBoxAt#at#x, viaBoxAt#at#y),
            (viaAtCenter#at#x, viaAtCenter#at#y))

    // ── rotated / rotatedAround / 半周超の扇形 ──

    // 1/4 回転（時計回り）: 真上 (0,-10) は右 (10,0) へ。1 周でちょうど元へ戻る。
    @Test
    def testRotatedQuarterTurnMovesTopToRight(): Unit \ Assert =
        let top = { x = 0.0, y = -10.0 } :: Nil;
        let quarter = Render.rotated(0.25, top) |> List.map(v -> (round4(v#x), round4(v#y)));
        let full = Render.rotated(1.0, top) |> List.map(v -> (round4(v#x), round4(v#y)));
        Assert.assertEq(expected = ((10.0, 0.0) :: Nil, (0.0, -10.0) :: Nil), (quarter, full))

    // 蝶番回転: 根元を pivot にした針は、半回転しても根元が動かず先端だけ反対側へ移る。
    @Test
    def testRotatedAroundKeepsPivotStill(): Unit \ Assert =
        let hand = { x = 5.0, y = 5.0 } :: { x = 5.0, y = -15.0 } :: Nil;
        let swung = Render.rotatedAround(0.5, { x = 5.0, y = 5.0 }, hand)
            |> List.map(v -> (round4(v#x), round4(v#y)));
        Assert.assertEq(expected = (5.0, 5.0) :: (5.0, 25.0) :: Nil, swung)

    // 群回転 rotatedAroundAll: 1/4 回転で at は pivot（原点）まわりに公転し、
    // Box は rotation に 0.25 が乗る（自転と公転で 1 枚の破片のように回る）。
    @Test
    def testRotatedAroundAllRevolvesAtAndSpinsBox(): Unit \ Assert =
        let placed = { at = { x = 10.0, y = 0.0 }, item = RawDraw.box({ x = 4.0, y = 2.0 }, red(), 0) };
        let got = Render.rotatedAroundAll(0.25, Vec2.zero(), placed :: Nil)
            |> List.head
            |> Option.flatMap(p -> match p#item {
                case Render.Item.Box(b) => Some((round4(p#at#x), round4(p#at#y), round4(b#rotation)))
                case _                  => None
            });
        Assert.assertEq(expected = Some((0.0, 10.0, 0.25)), got)

    // 群回転 rotatedAroundAll: at が pivot と一致する Poly は at が動かず、
    // 頂点だけが原点まわりに 1/4 回る（右 (5,0) → 下 (0,5)。全体では pivot まわりの剛体回転）。
    @Test
    def testRotatedAroundAllSpinsPolyVerticesInPlace(): Unit \ Assert =
        let placed = { at = { x = 10.0, y = 10.0 },
                       item = RawDraw.polygon({ x = 5.0, y = 0.0 } :: Nil, red(), 0) };
        let got = Render.rotatedAroundAll(0.25, { x = 10.0, y = 10.0 }, placed :: Nil)
            |> List.head
            |> Option.flatMap(p -> match p#item {
                case Render.Item.Poly(poly) => poly#vertices |> List.head
                    |> Option.map(v -> (round4(p#at#x), round4(p#at#y), round4(v#x), round4(v#y)))
                case _                      => None
            });
        Assert.assertEq(expected = Some((10.0, 10.0, 0.0, 5.0)), got)

    // ── 傾き（回転数 → 描画命令のラジアン・群回転）──

    // 傾きの単位は回転数。1/4 周を渡すと描画命令には τ/4 ラジアンで届く。
    @Test
    def testTurnedBoxIsQuarterTurnInRadians(): Unit \ Assert =
        let item = RawDraw.box({ x = 4.0, y = 2.0 }, red(), 0) |> Render.turned(0.25);
        let (ds, _) = Render.draw({ at = { x = 0.0, y = 0.0 }, item = item } :: Nil);
        Assert.assertEq(expected = Some(round4(Vec2.tau() / 4.0)),
            ds |> List.head |> Option.map(d -> round4(DrawCmd.rotationOf(d))))

    // 自分の中心を軸にすれば、群回転をかけても置き場所は動かない（その場で回るだけ）。
    @Test
    def testTurnedAllAroundOwnCenterKeepsPlace(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let placed = RawDraw.boxAt(center, { x = 20.0, y = 10.0 }, red(), 0);
        let turned = Render.turnedAll(0.25, center, placed :: Nil) |> List.head;
        Assert.assertEq(expected = Some((90.0, 45.0)),
            turned |> Option.map(p -> (round4(p#at#x), round4(p#at#y))))

    // 半周を 2 回かけると元の並びに戻る（群回転が可逆＝ずれを溜め込まない）。
    @Test
    def testTurnedAllHalfTurnTwiceIsIdentity(): Unit \ Assert =
        let pivot = { x = 0.0, y = 0.0 };
        let items = RawDraw.boxAt({ x = 30.0, y = 10.0 }, { x = 4.0, y = 4.0 }, red(), 0) :: Nil;
        let back = items |> Render.turnedAll(0.5, pivot) |> Render.turnedAll(0.5, pivot) |> List.head;
        Assert.assertEq(expected = Some((28.0, 8.0)),
            back |> Option.map(p -> (round4(p#at#x), round4(p#at#y))))

    // テキストは置き場所が軸なので、群回転では pivot のまわりを公転して自分も同じだけ傾く。
    // 1/4 周（時計回り）で (10,0) は (0,10) へ移る。
    @Test
    def testTurnedAllOrbitsTextAndSpinsIt(): Unit \ Assert =
        let item = Render.text("A", testAtlas(), 1.0, 0);
        let turned = Render.turnedAll(0.25, { x = 0.0, y = 0.0 },
                                      { at = { x = 10.0, y = 0.0 }, item = item } :: Nil) |> List.head;
        let spin = turned |> Option.map(p -> match p#item {
            case Render.Item.Text(t) => t#rotation
            case _                   => 0.0
        });
        Assert.assertEq(expected = (Some((0.0, 10.0)), Some(0.25)),
            (turned |> Option.map(p -> (round4(p#at#x), round4(p#at#y))), spin))

    // 半周傾けた文字は、文字の四角が置き場所を挟んで反対側へ回る（文字列が 1 枚の板として
    // 回っている証拠 — 文字ごとにその場で回るだけなら中心は動かない）。
    @Test
    def testHalfTurnedTextMirrorsGlyphCenters(): Unit \ Assert =
        let pos = { x = 100.0, y = 40.0 };
        let centersOf = t -> {
            let item = Render.text("AB", testAtlas(), 1.0, 0) |> Render.turned(t);
            let (ds, _) = Render.draw({ at = pos, item = item } :: Nil);
            ds |> List.map(dd -> {
                let d = DrawCmd.toSpec(dd);
                (round4(d#position#x + d#scale#x / 2.0),
                 round4(d#position#y + d#scale#y / 2.0))
            })
        };
        let mirrored = centersOf(0.0) |> List.map(c -> {
            let (x, y) = c; (round4(2.0 * pos#x - x), round4(2.0 * pos#y - y))
        });
        Assert.assertEq(expected = mirrored, centersOf(0.5))

    /// 幅・高さのある四角を持つ小さなアトラス（textureSize=1 なので scale がそのまま px）。
    def testAtlas(): FontAtlas =
        let gm = { xOff = 0.0, yOff = 0.0, glyphW = 6.0, glyphH = 8.0, advance = 10.0,
                   s0 = 0.0, t0 = 0.0, s1 = 1.0, t1 = 1.0 };
        { textureName = "test", fontSize = 1.0, textureSize = 1.0,
          ascent = 1.0, descent = 0.0, lineGap = 0.0,
          glyphs = Map.insert(66, gm, Map.insert(65, gm, Map.empty())) }

    /// 小数4桁へ丸める（円周上の点の浮動小数比較用）。
    def round4(x: Float64): Float64 = Float64.floor(x * 10000.0 + 0.5) / 10000.0
    /// 列の先頭の (置き場所, 大きさ, z)。動かしたとき何が変わって何が変わらないかを見る。
    def shapeOf(items: List[Render.PlacedItem]): (Float64, Float64, Float64, Int32) =
        match List.head(items) {
            case None => (0.0, 0.0, -1.0, -1)
            case Some(p) => match p#item {
                case Render.Item.Box(b) => (p#at#x, p#at#y, b#size#x, b#zIndex)
                case _                  => (p#at#x, p#at#y, -1.0, -1)
            }
        }

    @Test
    def testMovedAllShiftsPlacesOnly(): Unit \ Assert =
        // 置き場所だけが動き、中身（大きさ・z）は触られない。
        let items = { at = { x = 1.0, y = 2.0 }, item = RawDraw.box({ x = 4.0, y = 4.0 }, red(), 7) } :: Nil;
        Assert.assertEq(expected = (11.0, 22.0, 4.0, 7),
            shapeOf(Render.movedAll({ x = 10.0, y = 20.0 }, items)))

    @Test
    def testMovedAllComposes(): Unit \ Assert =
        // 2 度動かすのは、足した量で 1 度動かすのと同じ。
        let items = { at = { x = 3.0, y = 5.0 }, item = RawDraw.box(Vec2.one(), red(), 0) } :: Nil;
        let twice = items |> Render.movedAll({ x = 1.0, y = 2.0 }) |> Render.movedAll({ x = 4.0, y = 8.0 });
        Assert.assertEq(expected = shapeOf(items |> Render.movedAll({ x = 5.0, y = 10.0 })),
            shapeOf(twice))

    /// 列の先頭の Clipped の clip 矩形 (x, y, w, h)。clip 矩形が追随したかを見る。
    def clipRectOf(items: List[Render.PlacedItem]): (Float64, Float64, Float64, Float64) =
        match List.head(items) {
            case Some(p) => match p#item {
                case Render.Item.Clipped(c) =>
                    (c#rect#position#x, c#rect#position#y, c#rect#size#x, c#rect#size#y)
                case _ => (-1.0, -1.0, -1.0, -1.0)
            }
            case None => (-1.0, -1.0, -1.0, -1.0)
        }

    def clippedBox(): List[Render.PlacedItem] =
        RawDraw.box({ x = 4.0, y = 4.0 }, red(), 7)
            |> Render.clipped({ position = { x = 10.0, y = 20.0 }, size = { x = 30.0, y = 40.0 } })
            |> Render.at({ x = 12.0, y = 24.0 })
            |> (p -> p :: Nil)

    @Test
    def testMovedAllShiftsClipRectToo(): Unit \ Assert =
        // clip 矩形の規約: 平行移動は clip 矩形 rect も追随する（中身だけ clip 矩形の外へ歩かない）。
        Assert.assertEq(expected = (15.0, 26.0, 30.0, 40.0),
            clipRectOf(Render.movedAll({ x = 5.0, y = 6.0 }, clippedBox())))

    @Test
    def testScaledAllAroundStretchesAtAndSize(): Unit \ Assert =
        // pivot を不動点に、at は pivot からの距離が factor 倍・中身の大きさも factor 倍。
        let items = { at = { x = 10.0, y = 20.0 }, item = RawDraw.box({ x = 4.0, y = 6.0 }, red(), 7) } :: Nil;
        Assert.assertEq(expected = (18.0, 36.0, 8.0, 7),
            shapeOf(Render.scaledAllAround(2.0, { x = 2.0, y = 4.0 }, items)))

    @Test
    def testScaledAllAroundStretchesClipRectToo(): Unit \ Assert =
        // clip 矩形の規約: 一様 scale は clip 矩形 rect も追随する（位置は pivot 不動点・大きさは factor 倍）。
        Assert.assertEq(expected = (20.0, 40.0, 60.0, 80.0),
            clipRectOf(Render.scaledAllAround(2.0, Vec2.zero(), clippedBox())))

    @Test
    def testAtPlacesTopLeft(): Unit \ Assert =
        // Render.at は { at = pos, item = item } の純糖衣（パイプ末尾に載る形）。
        let placed = RawDraw.box({ x = 4.0, y = 4.0 }, red(), 7) |> Render.at({ x = 3.0, y = 5.0 });
        Assert.assertEq(expected = (3.0, 5.0, 4.0, 7), shapeOf(placed :: Nil))

    // ── glyphFingerprint（前フレームと同じ字を描くかを見分ける鍵）──

    /// テクスチャ名だけ差し替えたアトラス。
    def testAtlasNamed(name: String): FontAtlas =
        { textureName = name | testAtlas() }

    def textPlaced(content: String, atlas: FontAtlas): Render.PlacedItem =
        { at = { x = 0.0, y = 0.0 }, item = Render.text(content, atlas, 1.0, 0) }

    // 同じ items からは同じ指紋が出る。実装が変わったら気付けるよう具体値で pin する。
    @Test
    def testGlyphFingerprintIsStableForSameItems(): Unit \ Assert =
        let items = textPlaced("AB", testAtlas()) :: textPlaced("A", testAtlasNamed("other")) :: Nil;
        Assert.assertEq(expected = -8678883010997511569i64, Render.glyphFingerprint(items))

    // 文が 1 字変わると指紋が変わる。
    @Test
    def testGlyphFingerprintChangesWhenTextChanges(): Unit \ Assert =
        let a = Render.glyphFingerprint(textPlaced("AB", testAtlas()) :: Nil);
        let b = Render.glyphFingerprint(textPlaced("AA", testAtlas()) :: Nil);
        Assert.assertEq(expected = false, a == b)

    // Text 2 個の並びを入れ替えると指紋が変わる（acc を可換に混ぜていない証拠 —
    // 多項式 fold を可換な演算に戻す退行が起きたらここで落ちる）。
    @Test
    def testGlyphFingerprintIsOrderSensitive(): Unit \ Assert =
        let forward = textPlaced("AB", testAtlas()) :: textPlaced("A", testAtlasNamed("other")) :: Nil;
        let backward = textPlaced("A", testAtlasNamed("other")) :: textPlaced("AB", testAtlas()) :: Nil;
        Assert.assertEq(expected = false, Render.glyphFingerprint(forward) == Render.glyphFingerprint(backward))

    // 同じ文でも textureName（フォントの出処）が違えば別の指紋になる。
    @Test
    def testGlyphFingerprintChangesWhenTextureNameChanges(): Unit \ Assert =
        let a = Render.glyphFingerprint(textPlaced("AB", testAtlas()) :: Nil);
        let b = Render.glyphFingerprint(textPlaced("AB", testAtlasNamed("other")) :: Nil);
        Assert.assertEq(expected = false, a == b)

    // Text を含まない items（Box だけなど）は基底値そのまま。
    @Test
    def testGlyphFingerprintOfNonTextItemsIsBase(): Unit \ Assert =
        let items = { at = { x = 0.0, y = 0.0 }, item = RawDraw.box({ x = 1.0, y = 1.0 }, red(), 0) } :: Nil;
        Assert.assertEq(expected = -3750763034362895579i64, Render.glyphFingerprint(items))

}
