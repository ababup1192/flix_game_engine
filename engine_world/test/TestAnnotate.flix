// TestAnnotate — 一時停止中の「囲って書き出す」芯の性質を固定する。
// 大事な決まりは 1 つ: 注釈に残る矩形は常にデザイン座標で、ズーム・パンの影響を受けない。
// 座標変換の往復・カーソル固定点ズーム・ドラッグの向き・拡大中ドラッグの記録座標・
// 矩形と描画物の重なり判定・書き出す JSON の形をここで確認する。
//
// テストで使う画面: デザイン解像度 200×100（中央 = (100, 50)）。
//
//   (0,0) ┌──────────────────┐
//         │        ・(100,50) 中央 = ズームの焦点
//         │                  │
//         └──────────────────┘ (200,100)

mod TestAnnotate {

    /// テストで使うデザイン解像度（200×100。中央 (100, 50) が暗算しやすい）。
    def design(): Vec2.Vec2 = { x = 200.0, y = 100.0 }

    /// 矩形を比較しやすいタプル (x, y, w, h) へ写す。
    def rectTuple(rect: Rect2.Rect2): (Float64, Float64, Float64, Float64) =
        (rect#position#x, rect#position#y, rect#size#x, rect#size#y)

    /// 重なった描画物 1 件を比較しやすいタプル (種類, 名前, x, y) へ写す。
    def hitTuple(hit: Annotate.Hit): (String, String, Float64, Float64) =
        (hit#kind, hit#name, hit#position#x, hit#position#y)

    /// 一時停止中のマウス入力。必要な項目だけ変えて使う基準値（何も押していない・動いていない）。
    def idleInput(): Annotate.MouseInput =
        { cursor = Vec2.zero(), leftDown = false, middleDown = false,
          spaceDown = false, scroll = 0.0, design = design() }

    // ========================================================================
    // 座標変換: 画面座標とデザイン座標の往復
    // ========================================================================

    /// 拡大 2 倍 + ずらし (10, -5) の見え方でも、toScreen した点を toDesign すると元に戻る。
    /// （この往復が成り立つから、拡大して囲っても記録座標が狂わない）
    @Test
    def testToDesignInvertsToScreen(): Unit \ Assert =
        let view = { zoom = 2.0, pan = { x = 10.0, y = -5.0 }, design = design() };
        let p = { x = 30.0, y = 40.0 };
        let back = Annotate.toDesign(view, Annotate.toScreen(view, p));
        Assert.assertEq(expected = (30.0, 40.0), (back#x, back#y))

    /// カーソル位置 (150, 75) を焦点にホイール 1 目盛り拡大（1.25 倍）しても、
    /// カーソル直下にあったデザイン座標は同じ画面位置 (150, 75) に映ったまま。
    @Test
    def testZoomAtKeepsCursorPointFixed(): Unit \ Assert =
        let before = { zoom = 1.0, pan = Vec2.zero(), design = design() };
        let cursor = { x = 150.0, y = 75.0 };
        let anchor = Annotate.toDesign(before, cursor);
        let zoomed = Annotate.zoomAt(cursor, 1.0, before);
        let after = { zoom = zoomed#zoom, pan = zoomed#pan, design = design() };
        let mapped = Annotate.toScreen(after, anchor);
        Assert.assertEq(expected = (150.0, 75.0), (mapped#x, mapped#y))

    /// 拡大率は上限 8 倍で頭打ちになる（8 倍の状態でさらに回しても 8 のまま）。
    @Test
    def testZoomClampedAtMax(): Unit \ Assert =
        let view = { zoom = 8.0, pan = Vec2.zero(), design = design() };
        let zoomed = Annotate.zoomAt(Vec2.zero(), 1.0, view);
        Assert.assertEq(expected = 8.0, zoomed#zoom)

    /// 【画面が流れていく不具合の回帰】拡大中にポインタを動かしてから縮小し切ると、
    /// 見え方は必ず等倍・ずれ無しに戻る（等倍では pan の許容範囲が 0 に潰れるため）。
    @Test
    def testZoomOutReturnsToIdentity(): Unit \ Assert =
        let view = { zoom = 2.0, pan = { x = 50.0, y = 25.0 }, design = design() };
        let zoomed = Annotate.zoomAt(Vec2.zero(), -8.0, view);
        Assert.assertEq(expected = (1.0, 0.0, 0.0), (zoomed#zoom, zoomed#pan#x, zoomed#pan#y))

    // ========================================================================
    // 矩形: どちら向きにドラッグしても同じ「左上 + 幅高さ」になる
    // ========================================================================

    /// (10,20)-(30,60) の対角 4 通り（右下へ・左上へ・右上へ・左下へ）は全部同じ矩形。
    @Test
    def testNormRectFourDirections(): Unit \ Assert =
        let a = { x = 10.0, y = 20.0 };
        let b = { x = 30.0, y = 60.0 };
        let c = { x = 10.0, y = 60.0 };
        let d = { x = 30.0, y = 20.0 };
        let expected = (10.0, 20.0, 20.0, 40.0);
        Assert.assertEq(expected = (expected, expected, expected, expected),
            (rectTuple(Annotate.normRect(a, b)), rectTuple(Annotate.normRect(b, a)),
             rectTuple(Annotate.normRect(c, d)), rectTuple(Annotate.normRect(d, c))))

    // ========================================================================
    // step: 押す → 動かす → 離す の 1 連の操作
    // ========================================================================

    /// 等倍のまま (10,20) で押して (30,60) で離すと、その 2 点の矩形が確定する。
    @Test
    def testStepDragEmitsRect(): Unit \ Assert =
        let press = { cursor = { x = 10.0, y = 20.0 }, leftDown = true | idleInput() };
        let release = { cursor = { x = 30.0, y = 60.0 }, leftDown = false | idleInput() };
        let (s1, _) = Annotate.step(press, Annotate.initial());
        let (_, emitted) = Annotate.step(release, s1);
        Assert.assertEq(expected = Some((10.0, 20.0, 20.0, 40.0)),
            Option.map(rectTuple, emitted))

    /// 【この機能の核】2 倍に拡大した状態で画面上 (120,60)-(160,80) をドラッグすると、
    /// 記録される矩形はデザイン座標 (110,55)-(130,65) になる。
    /// 計算: デザイン座標 = (画面座標 - 中央) ÷ 2 + 中央。(120-100)/2+100 = 110 など。
    @Test
    def testStepZoomedDragRecordsDesignRect(): Unit \ Assert =
        let zoomedState = { zoom = 2.0 | Annotate.initial() };
        let press = { cursor = { x = 120.0, y = 60.0 }, leftDown = true | idleInput() };
        let release = { cursor = { x = 160.0, y = 80.0 }, leftDown = false | idleInput() };
        let (s1, _) = Annotate.step(press, zoomedState);
        let (_, emitted) = Annotate.step(release, s1);
        Assert.assertEq(expected = Some((110.0, 55.0, 20.0, 10.0)),
            Option.map(rectTuple, emitted))

    /// 幅も高さも 2 未満のドラッグは誤クリック扱いで捨てられ、ドラッグ状態も残らない。
    @Test
    def testStepTinyDragIsIgnored(): Unit \ Assert =
        let press = { cursor = { x = 10.0, y = 10.0 }, leftDown = true | idleInput() };
        let release = { cursor = { x = 11.0, y = 11.0 }, leftDown = false | idleInput() };
        let (s1, _) = Annotate.step(press, Annotate.initial());
        let (s2, emitted) = Annotate.step(release, s1);
        Assert.assertEq(expected = (true, true),
            (Option.isEmpty(emitted), Option.isEmpty(s2#dragStart)))

    /// 中ボタンでのドラッグは表示のずらし（パン）になる。押した最初のフレームでは
    /// まだ動かず、2 フレーム目でカーソルの移動量 (10, -5) がそのまま pan に足される。
    /// （パンできるのは拡大中だけ。等倍では常に 0 へクランプされるので 2 倍で試す）
    @Test
    def testStepMiddleDragPansView(): Unit \ Assert =
        let hold = { cursor = { x = 100.0, y = 50.0 }, middleDown = true | idleInput() };
        let move = { cursor = { x = 110.0, y = 45.0 }, middleDown = true | idleInput() };
        let (s1, _) = Annotate.step(hold, { zoom = 2.0 | Annotate.initial() });
        let (s2, _) = Annotate.step(move, s1);
        Assert.assertEq(expected = ((0.0, 0.0), (10.0, -5.0)),
            ((s1#pan#x, s1#pan#y), (s2#pan#x, s2#pan#y)))

    /// Space を押しながらの左ドラッグはパン操作なので、矩形ドラッグは始まらない。
    @Test
    def testStepSpaceLeftDragDoesNotStartRect(): Unit \ Assert =
        let panPress = { cursor = { x = 10.0, y = 10.0 }, leftDown = true, spaceDown = true | idleInput() };
        let (s1, _) = Annotate.step(panPress, Annotate.initial());
        Assert.assertEq(expected = true, Option.isEmpty(s1#dragStart))

    // ========================================================================
    // 矩形と描画物の重なり
    // ========================================================================

    /// 中心置き・2 倍拡大のスプライト（元 10×20）の外形は、置き場所 (100,100) を
    /// 中心にした 20×40 の矩形（左上 = (90, 80)）になる。
    @Test
    def testItemAabbCenteredScaledSprite(): Unit \ Assert =
        let sprite = Render.Item.Sprite({
            texture = "ball", tint = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
            scale = { x = 2.0, y = 2.0 }, rotation = 0.0, centered = true,
            flipH = false, flipV = false, regionRect = None, zIndex = 0,
            blend = DrawCmd.BlendMode.Normal, maskPolys = Nil });
        let sizeOf = _ -> Some({ id = GpuHandle.wrapTextureId(0), width = 10.0, height = 20.0 });
        let aabb = Annotate.itemAabb(sizeOf, { at = { x = 100.0, y = 100.0 }, item = sprite });
        Assert.assertEq(expected = (90.0, 80.0, 20.0, 40.0), rectTuple(aabb))

    /// 寸法の分からないテクスチャのスプライトは、置き場所だけの点（サイズ 0）として扱う。
    @Test
    def testItemAabbUnknownTextureIsPoint(): Unit \ Assert =
        let sprite = Render.sprite("unknown", 0);
        let aabb = Annotate.itemAabb(_ -> None, { at = { x = 30.0, y = 40.0 }, item = sprite });
        Assert.assertEq(expected = (30.0, 40.0, 0.0, 0.0), rectTuple(aabb))

    /// 矩形 (5,5)-(15,15) は原点の箱 10×10 とは重なるが、(50,50) の箱とは重ならない。
    @Test
    def testHitsFiltersByRect(): Unit \ Assert =
        let gray = { r = 0.5, g = 0.5, b = 0.5 };
        let near = { at = { x = 0.0, y = 0.0 }, item = RawDraw.box({ x = 10.0, y = 10.0 }, gray, 1) };
        let far = { at = { x = 50.0, y = 50.0 }, item = RawDraw.box({ x = 10.0, y = 10.0 }, gray, 2) };
        let rect = { position = { x = 5.0, y = 5.0 }, size = { x = 10.0, y = 10.0 } };
        match Annotate.hits(_ -> None, rect, near :: far :: Nil) {
            case hit :: Nil => Assert.assertEq(expected = ("box", "", 0.0, 0.0), hitTuple(hit))
            case _          => bug!("矩形に重なる描画物は 1 件だけのはず")
        }

    // ========================================================================
    // 時間スクラブ: ← → で少し前の瞬間へ戻る
    // ========================================================================

    /// ← を押した瞬間は 1 フレームだけ過去へ動く（押しっぱなし扱いにはならない）。
    @Test
    def testScrubBackEdgeMovesOneFrame(): Unit \ Assert =
        let keys = { back = true, backEdge = true, fwd = false, fwdEdge = false };
        let next = Annotate.scrubStep(keys, 300, Annotate.initial());
        Assert.assertEq(expected = 1, next#scrub)

    /// 停止した瞬間（scrub 0）で → を押しても、それより未来へは行けない。
    @Test
    def testScrubForwardStopsAtPresent(): Unit \ Assert =
        let keys = { back = false, backEdge = false, fwd = true, fwdEdge = true };
        let next = Annotate.scrubStep(keys, 300, Annotate.initial());
        Assert.assertEq(expected = 0, next#scrub)

    /// 履歴が 10 フレームしか無ければ、← を押しても 9 フレーム前で止まる。
    @Test
    def testScrubClampedAtHistoryEnd(): Unit \ Assert =
        let keys = { back = true, backEdge = true, fwd = false, fwdEdge = false };
        let next = Annotate.scrubStep(keys, 10, { scrub = 9 | Annotate.initial() });
        Assert.assertEq(expected = 9, next#scrub)

    /// 押しっぱなしは、しきい値（18 フレーム）を超えるまでは動かず、
    /// 超えたら毎フレーム 1 ずつ送られる（キーのリピート入力と同じ感覚）。
    @Test
    def testScrubHoldRepeatsAfterDelay(): Unit \ Assert =
        let held = { back = true, backEdge = false, fwd = false, fwdEdge = false };
        let before = Annotate.scrubStep(held, 300, { scrub = 5, scrubHold = 10 | Annotate.initial() });
        let after = Annotate.scrubStep(held, 300, { scrub = 5, scrubHold = 30 | Annotate.initial() });
        Assert.assertEq(expected = (5, 6), (before#scrub, after#scrub))

    /// 位置表示は操作中 180 フレーム（約 3 秒）に張り直され、手を離すと 1 ずつ減って消えていく。
    @Test
    def testScrubIndicatorFadesAfterRelease(): Unit \ Assert =
        let held = { back = true, backEdge = true, fwd = false, fwdEdge = false };
        let released = { back = false, backEdge = false, fwd = false, fwdEdge = false };
        let shown = Annotate.scrubStep(held, 300, Annotate.initial());
        let fading = Annotate.scrubStep(released, 300, { scrubShow = 100 | Annotate.initial() });
        Assert.assertEq(expected = (180, 99), (shown#scrubShow, fading#scrubShow))

    // ========================================================================
    // 見え方の適用（ズーム中の描画）
    // ========================================================================

    /// 【円が四角に化ける不具合の回帰】半径 5 の円（角丸ボックス）を 2 倍で見ると、
    /// 大きさ（10→20）と一緒に角丸半径（5→10）も 2 倍になり、円のままでいる。
    @Test
    def testApplyInspectKeepsCircleRound(): Unit \ Assert =
        let view = { zoom = 2.0, pan = Vec2.zero(), design = design() };
        let yellow = { r = 1.0, g = 1.0, b = 0.0 };
        let (drawables, _) = Render.draw({ at = { x = 0.0, y = 0.0 }, item = RawDraw.circle(5.0, yellow, 0) } :: Nil);
        match Annotate.applyInspect(view, drawables) {
            case d :: Nil =>
                match DrawCmd.styleOf(d) {
                    case Some(style) =>
                        Assert.assertEq(expected = (20.0, 20.0, 10.0),
                            (DrawCmd.scaleOf(d)#x, DrawCmd.scaleOf(d)#y,
                             DrawCmd.styleToSpec(style)#cornerRadius))
                    case None => bug!("円の描画命令には角丸スタイルが付いているはず")
                }
            case _ => bug!("円 1 個は描画命令 1 件になるはず")
        }

    /// 生の描画命令（Drawable）からの列挙: 中心置き・2 倍のスプライト（元 10×20 → 外形 20×40、
    /// 左上 (90,80)）は矩形に重なり、種類 "sprite" とテクスチャ名で報告される。
    /// （view を持たず生チャンネルを登録するゲーム向けの経路）
    @Test
    def testHitsFromDrawablesFindsSprite(): Unit \ Assert =
        let white = { r = 1.0, g = 1.0, b = 1.0 };
        let drawable = DrawCmd.make({
                         texture = "unit", position = { x = 100.0, y = 100.0 },
                         scale = { x = 2.0, y = 2.0 }, rotation = 0.0, color = white,
                         alpha = 1.0, centered = true, uvOffset = { x = 0.0, y = 0.0 },
                         uvScale = { x = 1.0, y = 1.0 }, zIndex = 5, style = None, clip = None,
                         blend = DrawCmd.BlendMode.Normal, mask = Nil });
        let sizeOf = _ -> Some({ id = GpuHandle.wrapTextureId(0), width = 10.0, height = 20.0 });
        let rect = { position = { x = 95.0, y = 95.0 }, size = { x = 10.0, y = 10.0 } };
        match Annotate.hitsFromDrawables(sizeOf, rect, drawable :: Nil) {
            case hit :: Nil => Assert.assertEq(expected = ("sprite", "unit", 90.0, 80.0),
                (hit#kind, hit#name, hit#aabb#position#x, hit#aabb#position#y))
            case _ => bug!("矩形に重なる描画命令は 1 件だけのはず")
        }

    /// タイルマップへの見え方の適用: 2 倍ズームで置き場所は中央焦点で写り、タイル倍率も 2 倍になる。
    /// （デザイン 200×100・中央 (100,50)。位置 (50,25) → (50-100)*2+100 = 0, (25-50)*2+50 = 0）
    @Test
    def testApplyInspectTilesScalesPositionAndTiles(): Unit \ Assert =
        let view = { zoom = 2.0, pan = Vec2.zero(), design = design() };
        let tile = { textureName = "floor", tileSize = 16.0, position = { x = 50.0, y = 25.0 },
                     tileScale = { x = 1.0, y = 1.0 }, color = { r = 1.0, g = 1.0, b = 1.0 },
                     zIndex = 0, tileVaoId = GpuHandle.wrapTileVao(1), tileCount = 10 };
        match Annotate.applyInspectTiles(view, tile :: Nil) {
            case t :: Nil => Assert.assertEq(expected = (0.0, 0.0, 2.0, 2.0),
                (t#position#x, t#position#y, t#tileScale#x, t#tileScale#y))
            case _ => bug!("タイルマップ命令は 1 件のまま返るはず")
        }

    // ========================================================================
    // 書き出す本文
    // ========================================================================

    /// annotation.json は読み戻せる形で、フレーム番号と矩形の x がそのまま入っている。
    @Test
    def testAnnotationJsonRoundTrip(): Unit \ Assert =
        let rect = { position = { x = 10.0, y = 20.0 }, size = { x = 30.0, y = 40.0 } };
        let text = Annotate.annotationJson({ frame = 7i64, design = design(), rect = rect }, Nil);
        let parsed = forM (
            json <- DocJson.parse(text);
            obj <- JsonCodec.expectObject(json);
            frameJ <- Map.get("frame", obj);
            frame <- JsonCodec.expectInt(frameJ);
            rectJ <- Map.get("rect", obj);
            rectObj <- JsonCodec.expectObject(rectJ);
            xJ <- Map.get("x", rectObj);
            x <- JsonCodec.expectFloat(xJ)
        ) yield (frame, x);
        Assert.assertEq(expected = Some((7, 10.0)), parsed)

    /// README の要約には、囲った矩形の座標と、重なっていた描画物の名前が載る。
    @Test
    def testReadmeBodyListsRectAndHits(): Unit \ Assert =
        let rect = { position = { x = 10.0, y = 20.0 }, size = { x = 30.0, y = 40.0 } };
        let hit = { kind = "sprite", name = "ball", position = { x = 12.0, y = 25.0 },
                    zIndex = 3, aabb = rect };
        let body = Annotate.readmeBody({ frame = 7i64, rect = rect }, hit :: Nil);
        Assert.assertEq(expected = (true, true),
            (String.contains(substr = "x=10.0", body), String.contains(substr = "sprite `ball`", body)))

    // 縮めて動かしたシェーダー面（ページ送りの枠に映した画面など）は、動いた後の場所で当たる。
    // 0.5 倍・中央 (100, 50) まわりで、左上 (0, 0)・40×20 の面は (50, 25)・20×10 へ動く。
    @Test
    def testShaderHitFollowsScaledPosition(): Unit \ Assert =
        let surface = Render.shaderFill(ShaderDoc.demoSurface(),
            { position = Vec2.zero(), size = { x = 40.0, y = 20.0 } }, 0.0, 1);
        let moved = Render.scaledAllAround(0.5, { x = 100.0, y = 50.0 }, surface :: Nil);
        let probe = { position = { x = 55.0, y = 28.0 }, size = { x = 2.0, y = 2.0 } };
        Assert.assertEq(expected = 1, List.length(Annotate.hits(_ -> None, probe, moved)))

    // 1 字ずつ置かれた同じ行の字は 1 件に束ねる。太字の重ね書き（0.5px ずらし）は字を足さない。
    @Test
    def testMergeTextRunsJoinsGlyphsOfOneLine(): Unit \ Assert =
        let glyph = (ch, x) -> { kind = "text", name = ch, position = { x = x, y = 10.0 }, zIndex = 5,
                                 aabb = { position = { x = x, y = 10.0 }, size = { x = 8.0, y = 8.0 } } };
        let hitList = glyph("君", 0.0) :: glyph("君", 0.5) :: glyph("が", 8.0) :: glyph("が", 8.5) :: glyph("い", 16.0) :: Nil;
        Assert.assertEq(expected = "君がい" :: Nil,
            Annotate.mergeTextRuns(hitList) |> List.map(h -> h#name))

    // 行の違う字・z の違う字・字の高さより離れた字（ラベルと値）は束ねない。
    @Test
    def testMergeTextRunsKeepsOtherRunsApart(): Unit \ Assert =
        let glyph = (ch, x, y, z) -> { kind = "text", name = ch, position = { x = x, y = y }, zIndex = z,
                                       aabb = { position = { x = x, y = y }, size = { x = 8.0, y = 8.0 } } };
        let hitList = glyph("一", 0.0, 0.0, 1) :: glyph("二", 0.0, 12.0, 1) :: glyph("三", 8.0, 12.0, 2)
            :: glyph("四", 40.0, 12.0, 2) :: Nil;
        Assert.assertEq(expected = 4, List.length(Annotate.mergeTextRuns(hitList)))

    // ゲームが渡した文脈は README の冒頭に並び、z には層の名前が添う。
    @Test
    def testReadmeBodyWithContextLeadsWithFacts(): Unit \ Assert =
        let rect = { position = { x = 10.0, y = 20.0 }, size = { x = 30.0, y = 40.0 } };
        let hit = { kind = "sprite", name = "ball", position = { x = 12.0, y = 25.0 }, zIndex = 3, aabb = rect };
        let context = { facts = ("場面", "Talk") :: Nil, layers = ("Talk", 0, 9) :: Nil, hudLayers = Nil };
        let body = Annotate.readmeBodyWith(context, { frame = 7i64, rect = rect }, hit :: Nil);
        Assert.assertEq(expected = (true, true),
            (String.startsWith(prefix = "## その瞬間の文脈\n\n- 場面: Talk", body),
             String.contains(substr = "z=3 Talk)", body)))

    enum Band with ToString {
        case Scene
        case Mouse
    }

    instance SortingLayer[Band] {
        pub def zRange(band: Band): (Int32, Int32) = match band {
            case Band.Scene => (0, 199)
            case Band.Mouse => (1000, 1099)
        }
    }

    // 層の enum から作った表で、HUD の物は持ち上がった z から HUD の表で引く（名前は Hud.<層>）。
    @Test
    def testLayerOfLooksUpHudTableForLiftedZ(): Unit \ Assert =
        let table = Annotate.toTable({ facts = Nil, layers = Band.Scene :: Nil, hudLayers = Band.Mouse :: Nil });
        Assert.assertEq(expected = Some("Hud.Mouse"), Annotate.layerOf(table, ZBand.liftHud(1005)))
}
