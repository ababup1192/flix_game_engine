// TestClip — clip(切り抜き矩形)の勘定を具体値で固定する: Rect2.intersect の交差と空、
// clipPixels の floor 量子化(GL scissor と SoftRaster setClip が見る共通の画素集合)、
// Render.draw が Clipped を剥がして Drawable / PolygonRenderCmd に clip 矩形を刻むこと、
// 修飾(fade)が clip 矩形をスキップして中身に効くこと、Annotate の外形が clip 矩形と交差すること。
mod TestClip {

    def rect(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 =
        { position = { x = x, y = y }, size = { x = w, y = h } }

    /// 矩形をタプルへ射影(record は比較できないため)。
    def rectTuple(r: Rect2.Rect2): (Float64, Float64, Float64, Float64) =
        (r#position#x, r#position#y, r#size#x, r#size#y)

    @Test
    def testRectIntersectOverlap(): Unit \ Assert =
        // 重なりはその共通部分。
        Assert.assertEq(expected = (10.0, 20.0, 30.0, 10.0),
            rectTuple(Rect2.intersect(rect(0.0, 0.0, 40.0, 30.0), rect(10.0, 20.0, 100.0, 100.0))))

    @Test
    def testRectIntersectEmptyIsNegativeSize(): Unit \ Assert =
        // 離れた矩形の交差は size が負 — 「空」を Option でなく負サイズで返す規約。
        let empty = Rect2.intersect(rect(0.0, 0.0, 10.0, 10.0), rect(20.0, 0.0, 10.0, 10.0));
        Assert.assertEq(expected = true, empty#size#x < 0.0)

    @Test
    def testClipPixelsFloorsAtScale(): Unit \ Assert =
        // 2 倍出力では設計 px の 2 倍を floor。(x0,y0,x1,y1) の 4 点量子化。
        Assert.assertEq(expected = (24, 20, 936, 516),
            DrawCmd.clipPixels({ scaleX = 2.0, scaleY = 2.0 }, rect(12.0, 10.0, 456.0, 248.0)))

    @Test
    def testDrawStampsClipOnDrawables(): Unit \ Assert =
        // clipped で包んだ Box は Drawable の clip に clip 矩形が刻まれ、包まない物は None のまま。
        let box = RawDraw.box({ x = 10.0, y = 10.0 }, { r = 1.0, g = 1.0, b = 1.0 }, 1);
        let items = ({ at = { x = 0.0, y = 0.0 }, item = Render.clipped(rect(1.0, 2.0, 3.0, 4.0), box) }: Render.PlacedItem)
                 :: ({ at = { x = 0.0, y = 0.0 }, item = box }: Render.PlacedItem)
                 :: Nil;
        let (ds, _) = Render.draw(items);
        Assert.assertEq(
            expected = Some((1.0, 2.0, 3.0, 4.0)) :: (None: Option[(Float64, Float64, Float64, Float64)]) :: Nil,
            ds |> List.map(d -> Option.map(rectTuple, DrawCmd.clipOf(d))))

    @Test
    def testNestedClipIntersects(): Unit \ Assert =
        // 入れ子の Clipped は交差した clip 矩形 1 つにまとめられる。
        let box = RawDraw.box({ x = 10.0, y = 10.0 }, { r = 1.0, g = 1.0, b = 1.0 }, 1);
        let nested = Render.clipped(rect(0.0, 0.0, 40.0, 30.0),
                        Render.clipped(rect(10.0, 20.0, 100.0, 100.0), box));
        let (ds, _) = Render.draw(({ at = { x = 0.0, y = 0.0 }, item = nested }: Render.PlacedItem) :: Nil);
        Assert.assertEq(expected = Some((10.0, 20.0, 30.0, 10.0)) :: Nil,
            ds |> List.map(d -> Option.map(rectTuple, DrawCmd.clipOf(d))))

    @Test
    def testClippedPolyRoutesToPolygonWithClip(): Unit \ Assert =
        // Clipped に包まれた Poly も polygon 側へ届き、clip 矩形が刻まれる(Drawable 側は空)。
        let tri = RawDraw.polygon({ x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 4.0 } :: Nil,
                                 { r = 1.0, g = 1.0, b = 1.0 }, 1);
        let (ds, ps) = Render.draw(
            ({ at = { x = 0.0, y = 0.0 }, item = Render.clipped(rect(1.0, 1.0, 2.0, 2.0), tri) }: Render.PlacedItem) :: Nil);
        Assert.assertEq(
            expected = (0, Some((1.0, 1.0, 2.0, 2.0)) :: Nil),
            (List.length(ds), ps |> List.map(p -> Option.map(rectTuple, p#clip))))

    @Test
    def testModifierReachesLeafThroughClip(): Unit \ Assert =
        // fade は clip 矩形をスキップして中身に効く(clip 矩形は変わらない)。
        let box = RawDraw.box({ x = 10.0, y = 10.0 }, { r = 1.0, g = 1.0, b = 1.0 }, 1);
        let faded = Render.clipped(rect(1.0, 2.0, 3.0, 4.0), box) |> Render.fade(0.5);
        let (ds, _) = Render.draw(({ at = { x = 0.0, y = 0.0 }, item = faded }: Render.PlacedItem) :: Nil);
        Assert.assertEq(
            expected = (0.5, Some((1.0, 2.0, 3.0, 4.0))) :: Nil,
            ds |> List.map(d -> (DrawCmd.alphaOf(d), Option.map(rectTuple, DrawCmd.clipOf(d)))))

    @Test
    def testAnnotateAabbShrinksToClipRect(): Unit \ Assert =
        // F8 の外形は clip 矩形と交差した見えている範囲になる(完全に clip 矩形の外なら負サイズ = ヒットしない)。
        let box = RawDraw.box({ x = 100.0, y = 100.0 }, { r = 1.0, g = 1.0, b = 1.0 }, 1);
        let placed: Render.PlacedItem =
            { at = { x = 0.0, y = 0.0 }, item = Render.clipped(rect(10.0, 10.0, 20.0, 20.0), box) };
        let aabb = Annotate.itemAabb(_ -> None, placed);
        Assert.assertEq(expected = (10.0, 10.0, 20.0, 20.0), rectTuple(aabb))

    // ---------------------------------------------------------------
    // 並びの順と 2 列への振り分け
    // ---------------------------------------------------------------

    /// 箱・多角形・スプライト・clip つきスプライト・箱を x = 1〜5 に置いた列。
    def mixedItems(): List[Render.PlacedItem] =
        let red = { r = 1.0, g = 0.0, b = 0.0 };
        let box = RawDraw.box({ x = 10.0, y = 10.0 }, red, 3);
        let tri = RawDraw.polygon({ x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 4.0 } :: Nil, red, 5);
        let sprite = Render.sprite("flag", 7);
        { at = { x = 1.0, y = 0.0 }, item = box }
            :: { at = { x = 2.0, y = 0.0 }, item = tri }
            :: { at = { x = 3.0, y = 0.0 }, item = sprite }
            :: { at = { x = 4.0, y = 0.0 }, item = Render.clipped(rect(1.0, 2.0, 3.0, 4.0), sprite) }
            :: { at = { x = 5.0, y = 0.0 }, item = box }
            :: Nil

    /// 描画命令 2 列を ((絵, x, z, clip) の列, 多角形の z の列) へ射影。
    def drawnTuple(drawn: (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd])):
            (List[(String, Float64, Int32, Option[(Float64, Float64, Float64, Float64)])], List[Int32]) =
        let (ds, ps) = drawn;
        (ds |> List.map(d -> (DrawCmd.textureOf(d), DrawCmd.positionOf(d)#x, DrawCmd.zIndexOf(d), Option.map(rectTuple, DrawCmd.clipOf(d)))),
         ps |> List.map(p -> p#zIndex))

    /// draw は Drawable を列の並びのまま返し、多角形だけを 2 本目の列へ分ける（z で並べ替えない）。
    @Test
    def testDrawKeepsItemOrderAcrossKinds(): Unit \ Assert =
        Assert.assertEq(
            expected = (("", 1.0, 3, None) :: ("flag", 3.0, 7, None) :: ("flag", 4.0, 7, Some((1.0, 2.0, 3.0, 4.0))) :: ("", 5.0, 3, None) :: Nil,
                        5 :: Nil),
            drawnTuple(Render.draw(mixedItems())))

    /// draw が Sprite と Box から作る Drawable は、1 個ずつ Render.toDrawables で作った物と全部の欄が同じ
    /// （薄めて Multiply にしたスプライトと、箱）。
    @Test
    def testDrawMatchesToDrawablesPerItem(): Unit \ Assert =
        let sprite = Render.sprite("flag", 7) |> Render.blended(DrawCmd.BlendMode.Multiply) |> Render.fade(0.5);
        let box = RawDraw.box({ x = 10.0, y = 20.0 }, { r = 1.0, g = 0.5, b = 0.0 }, 3);
        let (ds, _) = Render.draw({ at = { x = 1.0, y = 2.0 }, item = sprite } :: { at = { x = 3.0, y = 4.0 }, item = box } :: Nil);
        Assert.assertEq(
            expected = List.append(Render.toDrawables(sprite, { x = 1.0, y = 2.0 }), Render.toDrawables(box, { x = 3.0, y = 4.0 }))
                           |> List.map(d -> "${d}"),
            ds |> List.map(d -> "${d}"))

    /// region を使わない列では、drawWith は draw と全部の欄が同じ 2 列を返す。
    @Test
    def testDrawWithMatchesDrawWithoutRegions(): Unit \ Assert =
        Assert.assertEq(expected = allFields(Render.draw(mixedItems())),
            allFields(Render.drawWith(_ -> None, mixedItems())))

    // ---------------------------------------------------------------
    // drawInto の近道（clip も region も無い Sprite と Box）が、1 個ずつ作る道と同じ値を積む
    // ---------------------------------------------------------------

    /// 描画命令 2 列を (Drawable の全部の欄の字, 多角形の (z, clip)) へ射影。
    def allFields(drawn: (List[GameEngine.Drawable], List[GameEngine.PolygonRenderCmd])):
            (List[String], List[(Int32, Option[(Float64, Float64, Float64, Float64)])]) =
        let (ds, ps) = drawn;
        (ds |> List.map(d -> "${d}"), ps |> List.map(p -> (p#zIndex, Option.map(rectTuple, p#clip))))

    /// 列の 1 個ずつを Render.toDrawables で作ってつないだ字の列（draw の比べる相手）。
    def perItemFields(items: List[Render.PlacedItem]): List[String] =
        items |> List.flatMap(placed -> Render.toDrawables(placed#item, placed#at)) |> List.map(d -> "${d}")

    /// 列の 1 個ずつを toDrawablesAtlas で作ってつないだ字の列（drawWith の比べる相手）。
    def perItemAtlasFields(items: List[Render.PlacedItem]): List[String] =
        items |> List.flatMap(placed -> Render.Internal.Extract.toDrawablesAtlas(sheetInfo, placed#item, placed#at))
              |> List.map(d -> "${d}")

    /// "sheet" だけが 64 × 32 の絵として引ける。
    def sheetInfo(name: String): Option[GameEngine.TextureInfo] =
        if (name == "sheet") Some({ id = GpuHandle.wrapTextureId(1), width = 64.0, height = 32.0 }) else None

    /// 欄を全部、既定でない値にした Sprite（反転 2 つ・傾き・左上原点・拡大・型抜き・色・濃さ・Add）。
    def busySprite(texture: String, regionRect: Option[Rect2.Rect2]): Render.Item =
        Render.Item.Sprite({ texture = texture, tint = { r = 0.25, g = 0.5, b = 0.75 }, alpha = 0.5,
                             scale = { x = 2.0, y = 3.0 }, rotation = 0.125, centered = false,
                             flipH = true, flipV = true, regionRect = regionRect, zIndex = 9,
                             blend = DrawCmd.BlendMode.Add,
                             maskPolys = ({ x = 0.0, y = 0.0 } :: { x = 4.0, y = 0.0 } :: { x = 0.0, y = 4.0 } :: Nil) :: Nil })

    /// 角丸の style を付けて傾けた Box。
    def busyBox(): Render.Item =
        let color = { r = 0.25, g = 0.5, b = 0.75 };
        Render.Item.Box({ size = { x = 10.0, y = 20.0 }, color = color, alpha = 0.5, rotation = 0.25,
                          style = Some(DrawCmd.defaultStyle(color) |> DrawCmd.withCornerRadius(4.0)), zIndex = 4,
                          blend = DrawCmd.BlendMode.Multiply })

    /// 'A' 1 字だけを持つフォント。
    def oneGlyphFont(): FontAtlas =
        { textureName = "font", fontSize = 16.0, textureSize = 64.0, ascent = 12.0, descent = 4.0, lineGap = 0.0,
          glyphs = Map#{ 65 => { xOff = 0.0, yOff = 0.0, glyphW = 8.0, glyphH = 12.0, advance = 9.0,
                                 s0 = 0.0, t0 = 0.0, s1 = 0.125, t1 = 0.1875 } } }

    def placedAt(x: Float64, item: Render.Item): Render.PlacedItem = { at = { x = x, y = 2.0 }, item = item }

    /// 欄が全部既定でない Sprite も、draw は 1 個ずつ作る道と全部の欄が同じ。
    @Test
    def testDrawMatchesToDrawablesForBusySprite(): Unit \ Assert =
        let items = placedAt(1.0, busySprite("flag", None)) :: Nil;
        Assert.assertEq(expected = perItemFields(items), fst(allFields(Render.draw(items))))

    /// style を付けて傾けた Box も、draw は 1 個ずつ作る道と全部の欄が同じ。
    @Test
    def testDrawMatchesToDrawablesForBusyBox(): Unit \ Assert =
        let items = placedAt(1.0, busyBox()) :: Nil;
        Assert.assertEq(expected = perItemFields(items), fst(allFields(Render.draw(items))))

    /// Clipped に包んだ Box と Sprite は近道を通らず、1 個ずつ作る道と全部の欄が同じ（clip 矩形も）。
    @Test
    def testDrawMatchesToDrawablesForClippedPlainItems(): Unit \ Assert =
        let items = placedAt(1.0, Render.clipped(rect(1.0, 2.0, 3.0, 4.0), busyBox()))
                 :: placedAt(2.0, Render.clipped(rect(1.0, 2.0, 3.0, 4.0), busySprite("flag", None))) :: Nil;
        Assert.assertEq(expected = perItemFields(items), fst(allFields(Render.draw(items))))

    /// 近道を通る物の間に Text を挟んでも、Drawable は列の並びのまま（Box・字・Sprite・字・Box）。
    @Test
    def testDrawKeepsTextBetweenPlainItems(): Unit \ Assert =
        let label = Render.text("AA", oneGlyphFont(), 16.0, 6);
        let items = placedAt(1.0, busyBox()) :: placedAt(2.0, label) :: placedAt(3.0, busySprite("flag", None))
                 :: placedAt(4.0, label) :: placedAt(5.0, busyBox()) :: Nil;
        Assert.assertEq(expected = perItemFields(items), fst(allFields(Render.draw(items))))

    /// 上の列の字は実際に Drawable になっている（字が 0 個だと、順番の比べが何も見ていない）。
    @Test
    def testOneGlyphFontDrawsEachLetter(): Unit \ Assert =
        Assert.assertEq(expected = 2,
            List.length(Render.toDrawables(Render.text("AA", oneGlyphFont(), 16.0, 6), { x = 0.0, y = 0.0 })))

    /// region つき・region 無し・Box を混ぜた列で、drawWith は 1 個ずつ toDrawablesAtlas で作る道と全部の欄が同じ。
    @Test
    def testDrawWithMatchesToDrawablesAtlasPerItem(): Unit \ Assert =
        let items = placedAt(1.0, busySprite("sheet", Some(rect(16.0, 8.0, 32.0, 16.0))))
                 :: placedAt(2.0, busySprite("sheet", None)) :: placedAt(3.0, busyBox()) :: Nil;
        Assert.assertEq(expected = perItemAtlasFields(items), fst(allFields(Render.drawWith(sheetInfo, items))))

    /// region つき Sprite の UV は、region を絵の寸法（64 × 32）で割った始点と大きさ。ほかの欄は region 無しと同じ。
    @Test
    def testDrawWithRegionSpriteUv(): Unit \ Assert =
        let whole = Render.toDrawables(busySprite("sheet", None), { x = 1.0, y = 2.0 });
        let (ds, _) = Render.drawWith(sheetInfo, placedAt(1.0, busySprite("sheet", Some(rect(16.0, 8.0, 32.0, 16.0)))) :: Nil);
        Assert.assertEq(
            expected = whole |> List.map(DrawCmd.withUv({ x = 16.0 / 64.0, y = 8.0 / 32.0 }, { x = 32.0 / 64.0, y = 16.0 / 32.0 }))
                             |> List.map(d -> "${d}"),
            ds |> List.map(d -> "${d}"))

    /// 寸法を引けない絵の region は、絵の全体を指す UV になる。
    @Test
    def testDrawWithRegionOfUnknownTextureUsesWholeTexture(): Unit \ Assert =
        let (ds, _) = Render.drawWith(sheetInfo, placedAt(1.0, busySprite("missing", Some(rect(16.0, 8.0, 32.0, 16.0)))) :: Nil);
        Assert.assertEq(expected = perItemFields(placedAt(1.0, busySprite("missing", None)) :: Nil), ds |> List.map(d -> "${d}"))
}
