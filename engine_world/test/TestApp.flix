// TestApp — App の純粋な芯を具体値で固定する: frameOf のエッジ判定（新規押下だけが
// justPressed に立ち、押しっぱなし・離しは立たない）、applySystems の適用順（追加順 =
// 左から右。+1 して ×2 なら 2、逆なら 1 なので順序が数字に出る）、quit の既定
// （Escape のエッジで終了・押しっぱなしでは終了しない）。
// Frame は record なので、比較はタプルへ射影して行う。
// lint-view: 対象外 — スロットと z の並びを数字で固定するための目印。画面に出す絵ではない。

mod TestApp {

    /// Frame を比較できるタプル (down, justPressed, dt) へ射影する。
    def frameTuple(frame: App.Frame): (Set[GameEngine.Key], Set[GameEngine.Key], Float64) =
        (frame#down, frame#justPressed, frame#dt)

    /// テスト用の design サイズ。ここのテストは viewport を見ないので値は任意。
    def testViewport(): Vec2.Vec2 = { x = 320.0, y = 240.0 }

    /// マウス無し（ボタン未押下・ホイール停止）。キーだけを見るテストの frameOf に渡す。
    def noMouse(): { prevDown = Bool, down = Bool, wheel = Float64 } =
        { prevDown = false, down = false, wheel = 0.0 }

    /// カーソル無し（原点のまま・前の位置も無し）。キーだけを見るテストの frameOf に渡す。
    def noCursor(): { prevCursor = Option[Vec2.Vec2], cursor = Vec2.Vec2 } =
        { prevCursor = None, cursor = Vec2.zero() }

    /// キー無し・dt 0 の Frame。
    def emptyFrame(): App.Frame =
        App.frameOf(prev = Set#{}, current = Set#{}, 0.0, testViewport(), noCursor(), noMouse())

    // ========================================================================
    // frameOf: エッジ判定
    // ========================================================================

    // 新規押下: 前に無く今ある Left は down にも justPressed にも立つ。dt は素通し。
    @Test
    def testFrameOfNewPressIsEdge(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{}, current = Set#{GameEngine.Key.Left}, 0.016, testViewport(), noCursor(), noMouse());
        Assert.assertEq(expected = (Set#{GameEngine.Key.Left}, Set#{GameEngine.Key.Left}, 0.016),
            frameTuple(actual))

    // 押しっぱなし: 前も今もある Left は down のまま、justPressed には立たない。
    @Test
    def testFrameOfHeldKeyIsNotEdge(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{GameEngine.Key.Left}, current = Set#{GameEngine.Key.Left}, 0.016, testViewport(), noCursor(), noMouse());
        Assert.assertEq(expected = (Set#{GameEngine.Key.Left}, Set#{}, 0.016),
            frameTuple(actual))

    // 離し: 前にあって今無い Left はどちらにも立たない（離しエッジは追わない）。
    @Test
    def testFrameOfReleaseIsSilent(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{GameEngine.Key.Left}, current = Set#{}, 0.016, testViewport(), noCursor(), noMouse());
        Assert.assertEq(expected = (Set#{}, Set#{}, 0.016),
            frameTuple(actual))

    // 混在: 押しっぱなしの Left と新規の Space が並ぶと、エッジは Space だけ。
    @Test
    def testFrameOfMixedKeysSplitEdges(): Unit \ Assert =
        let actual = App.frameOf(
            prev = Set#{GameEngine.Key.Left},
            current = Set#{GameEngine.Key.Left, GameEngine.Key.Space}, 0.016, testViewport(), noCursor(), noMouse());
        Assert.assertEq(
            expected = (Set#{GameEngine.Key.Left, GameEngine.Key.Space}, Set#{GameEngine.Key.Space}, 0.016),
            frameTuple(actual))

    // ========================================================================
    // frameOf: マウスのエッジ判定（キーと同じ考え方）
    // ========================================================================

    // 新規押下: 前に離れていて今押されていれば mouseDown と mouseClicked の両方が立つ。
    // cursor は素通し。
    @Test
    def testFrameOfMousePressIsEdge(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{}, current = Set#{}, 0.016, testViewport(),
            { prevCursor = None, cursor = { x = 10.0, y = 20.0 } }, { prevDown = false, down = true, wheel = 0.0 });
        Assert.assertEq(expected = (true, true, (10.0, 20.0)),
            (actual#mouseDown, actual#mouseClicked, (actual#cursor#x, actual#cursor#y)))

    // 押しっぱなし: 前も今も押されていれば mouseDown のみ（クリックのエッジは立たない）。
    @Test
    def testFrameOfHeldMouseIsNotEdge(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{}, current = Set#{}, 0.016, testViewport(),
            noCursor(), { prevDown = true, down = true, wheel = 0.0 });
        Assert.assertEq(expected = (true, false), (actual#mouseDown, actual#mouseClicked))

    // 離し: どちらも立たない。
    @Test
    def testFrameOfMouseReleaseIsSilent(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{}, current = Set#{}, 0.016, testViewport(),
            noCursor(), { prevDown = true, down = false, wheel = 0.0 });
        Assert.assertEq(expected = (false, false), (actual#mouseDown, actual#mouseClicked))

    // ホイール: バックエンドが貯めた量がそのまま Frame に乗る（上が正・下が負）。
    @Test
    def testFrameOfWheelPassesThrough(): Unit \ Assert =
        let actual = App.frameOf(prev = Set#{}, current = Set#{}, 0.016, testViewport(),
            noCursor(), { prevDown = false, down = false, wheel = -2.0 });
        Assert.assertEq(expected = -2.0, actual#wheel)

    // ========================================================================
    // frameOf: マウス移動（前フレームとの座標比較）
    // ========================================================================

    /// カーソルの前後だけ違う frameOf 呼び出し（キー・ボタンは無し）。
    def frameWithCursor(prevCursor: Option[Vec2.Vec2], cursor: Vec2.Vec2): App.Frame =
        App.frameOf(prev = Set#{}, current = Set#{}, 0.016, testViewport(),
            { prevCursor = prevCursor, cursor = cursor }, noMouse())

    // 座標が前フレームと違えば mouseMoved が立つ。
    @Test
    def testFrameOfCursorMoveIsDetected(): Unit \ Assert =
        let actual = frameWithCursor(Some({ x = 10.0, y = 20.0 }), { x = 11.0, y = 20.0 });
        Assert.assertEq(expected = true, actual#mouseMoved)

    // 同じ座標のままなら立たない。
    @Test
    def testFrameOfStillCursorIsSilent(): Unit \ Assert =
        let actual = frameWithCursor(Some({ x = 10.0, y = 20.0 }), { x = 10.0, y = 20.0 });
        Assert.assertEq(expected = false, actual#mouseMoved)

    // 最初のフレーム（前の位置が無い）は動いた扱いにしない。
    @Test
    def testFrameOfFirstFrameCursorIsSilent(): Unit \ Assert =
        let actual = frameWithCursor(None, { x = 10.0, y = 20.0 });
        Assert.assertEq(expected = false, actual#mouseMoved)

    // ========================================================================
    // applySystems: 追加順 = 適用順
    // ========================================================================

    // +1 → ×2 の順なら (0+1)*2 = 2。逆順なら 0*2+1 = 1 なので、順序の取り違えは数字に出る。
    @Test
    def testApplySystemsRunsInOrder(): Unit \ Assert =
        let systems = ((_frame, n) -> n + 1) :: ((_frame, n) -> n * 2) :: Nil;
        Assert.assertEq(expected = 2, App.applySystems(emptyFrame(), systems, 0))

    // システム無しなら World はそのまま。
    @Test
    def testApplySystemsEmptyIsIdentity(): Unit \ Assert =
        Assert.assertEq(expected = 7, App.applySystems(emptyFrame(), Nil, 7))

    // ========================================================================
    // axis: 負・正キーの押し下げ → -1 / 0 / +1
    // ========================================================================

    // 正キーだけ +1・負キーだけ -1・無押下 0・両押しは打ち消して 0。押しっぱなしも効く（down 判定）。
    @Test
    def testAxisFoldsKeysToScalar(): Unit \ Assert =
        let frameWith = keys -> App.frameOf(prev = keys, current = keys, 0.016, testViewport(), noCursor(), noMouse());
        let pos = App.axis(negative = GameEngine.Key.Left, positive = GameEngine.Key.Right, frameWith(Set#{GameEngine.Key.Right}));
        let neg = App.axis(negative = GameEngine.Key.Left, positive = GameEngine.Key.Right, frameWith(Set#{GameEngine.Key.Left}));
        let idle = App.axis(negative = GameEngine.Key.Left, positive = GameEngine.Key.Right, frameWith(Set#{}));
        let both = App.axis(negative = GameEngine.Key.Left, positive = GameEngine.Key.Right, frameWith(Set#{GameEngine.Key.Left, GameEngine.Key.Right}));
        Assert.assertEq(expected = (1.0, -1.0, 0.0, 0.0), (pos, neg, idle, both))

    // ========================================================================
    // composeScene: camera は world の絵だけに掛かり、hud には掛からない
    // ========================================================================

    def sceneDesign(): Vec2.Vec2 = { x = 320.0, y = 240.0 }

    def boxAtOrigin(): Render.PlacedItem =
        { at = { x = 0.0, y = 0.0 },
          item = RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 0.0, b = 0.0 }, 0) }

    def atOf(items: List[Render.PlacedItem]): Option[(Float64, Float64)] =
        List.head(items) |> Option.map(p -> (p#at#x, p#at#y))

    // camera なし: world の絵は恒等・hud が後ろに繋がる（順序も本数もそのまま）。
    @Test
    def testComposeSceneWithoutCameraIsIdentityAppend(): Unit \ Assert =
        let composed = App.composeScene(None, 1.0, sceneDesign(),
            { world = boxAtOrigin() :: Nil, hud = boxAtOrigin() :: Nil });
        Assert.assertEq(expected = (2, Some((0.0, 0.0))), (List.length(composed), atOf(composed)))

    // camera あり: world の絵だけがずれ（原点は design/2 - center へ）、hud は不動のまま。
    @Test
    def testComposeSceneShiftsWorldButNotHud(): Unit \ Assert =
        let composed = App.composeScene(Some({ x = 100.0, y = 50.0 }), 1.0, sceneDesign(),
            { world = boxAtOrigin() :: Nil, hud = boxAtOrigin() :: Nil });
        let hudAt = List.head(List.drop(1, composed)) |> Option.map(p -> (p#at#x, p#at#y));
        Assert.assertEq(expected = (Some((60.0, 70.0)), Some((0.0, 0.0))), (atOf(composed), hudAt))

    // center に置いた item は画面中央 design/2 に着地する（round-trip）。
    @Test
    def testComposeSceneLandsCenterAtMiddle(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let onCenter = { at = center | boxAtOrigin() };
        let composed = App.composeScene(Some(center), 1.0, sceneDesign(),
            { world = onCenter :: Nil, hud = Nil });
        Assert.assertEq(expected = Some((160.0, 120.0)), atOf(composed))

    // ========================================================================
    // composeScene: hud の z は HUD の範囲へ持ち上がる（world の z には触らない）
    // ========================================================================

    def boxAtZ(z: Int32): Render.PlacedItem =
        { at = { x = 0.0, y = 0.0 },
          item = RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 0.0, b = 0.0 }, z) }

    def zAt(i: Int32, items: List[Render.PlacedItem]): Option[Int32] =
        List.head(List.drop(i, items)) |> Option.flatMap(p -> match p#item {
            case Render.Item.Box(b) => Some(b#zIndex)
            case _                  => None
        })

    // world z=1000（爆発など）より hud z=10 の方が手前になる（範囲への持ち上げ）。
    @Test
    def testComposeSceneLiftsHudAboveWorld(): Unit \ Assert =
        let composed = App.composeScene(None, 1.0, sceneDesign(),
            { world = boxAtZ(1000) :: Nil, hud = boxAtZ(10) :: Nil });
        Assert.assertEq(expected = (Some(1000), Some(1_000_000_010)),
            (zAt(0, composed), zAt(1, composed)))

    // 範囲からはみ出す hud の z は clamp（wrap しない）: 負は範囲の底・過大は範囲の上限。
    @Test
    def testComposeSceneClampsHudZIntoRange(): Unit \ Assert =
        let composed = App.composeScene(None, 1.0, sceneDesign(),
            { world = Nil, hud = boxAtZ(-5) :: boxAtZ(2_000_000_000) :: Nil });
        Assert.assertEq(expected = (Some(1_000_000_000), Some(1_099_999_999)),
            (zAt(0, composed), zAt(1, composed)))

    // ========================================================================
    // composeScene / visibleOf: 寄り引き（zoom ≠ 1）の合成
    // ========================================================================

    // zoom 2 倍: center に置いた item は画面中央に着地したまま、Box の大きさは 2 倍になる。
    @Test
    def testComposeSceneAtZoomTwoScalesAroundCenter(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let onCenter = { at = center | boxAtOrigin() };
        let composed = App.composeScene(Some(center), 2.0, sceneDesign(),
            { world = onCenter :: Nil, hud = Nil });
        let size = match List.head(composed) |> Option.map(p -> p#item) {
            case Some(Render.Item.Box(b)) => (b#size#x, b#size#y)
            case _                        => bug!("composeScene の先頭は Box のはず")
        };
        Assert.assertEq(expected = (Some((160.0, 120.0)), (2.0, 2.0)), (atOf(composed), size))

    // zoom 2 倍: center から (10, 0) 離れた item は画面中央から (20, 0) 離れて着地する。
    @Test
    def testComposeSceneAtZoomTwoScalesOffsets(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let offCenter = { at = { x = 110.0, y = 50.0 } | boxAtOrigin() };
        let composed = App.composeScene(Some(center), 2.0, sceneDesign(),
            { world = offCenter :: Nil, hud = Nil });
        Assert.assertEq(expected = Some((180.0, 120.0)), atOf(composed))

    // camera 無し（center = None）でも zoom ≠ 1 なら画面中央 design/2 を軸に寄る:
    // 中央 (160,120) に置いた item は動かず、Box の大きさだけ 2 倍になる（zoom の黙殺はしない）。
    @Test
    def testComposeSceneAtZoomTwoWithoutCameraZoomsAroundScreenCenter(): Unit \ Assert =
        let onMiddle = { at = { x = 160.0, y = 120.0 } | boxAtOrigin() };
        let composed = App.composeScene(None, 2.0, sceneDesign(),
            { world = onMiddle :: Nil, hud = Nil });
        let size = match List.head(composed) |> Option.map(p -> p#item) {
            case Some(Render.Item.Box(b)) => (b#size#x, b#size#y)
            case _                        => bug!("composeScene の先頭は Box のはず")
        };
        Assert.assertEq(expected = (Some((160.0, 120.0)), (2.0, 2.0)), (atOf(composed), size))

    // 同じ規則が可視範囲にも効く: camera 無し + zoom 2 は design/2 中心の 160×120。
    @Test
    def testVisibleOfAtZoomTwoWithoutCameraCentersOnScreen(): Unit \ Assert =
        let visible = App.visibleOf(None, 2.0, sceneDesign());
        Assert.assertEq(expected = ((80.0, 60.0), (160.0, 120.0)),
            ((visible#position#x, visible#position#y), (visible#size#x, visible#size#y)))

    // zoom 2 倍の可視範囲: 大きさは design の半分（160×120）で、center を中心に据える。
    @Test
    def testVisibleOfAtZoomTwoShrinksSeenRect(): Unit \ Assert =
        let visible = App.visibleOf(Some({ x = 100.0, y = 50.0 }), 2.0, sceneDesign());
        Assert.assertEq(expected = ((20.0, -10.0), (160.0, 120.0)),
            ((visible#position#x, visible#position#y), (visible#size#x, visible#size#y)))

    // ========================================================================
    // visibleOf: ViewCtx の visible（見えている world 矩形）の源
    // ========================================================================

    // camera なし: 原点起点の design 全体が見えている。
    @Test
    def testVisibleOfWithoutCameraIsDesignRect(): Unit \ Assert =
        let visible = App.visibleOf(None, 1.0, sceneDesign());
        Assert.assertEq(expected = ((0.0, 0.0), (320.0, 240.0)),
            ((visible#position#x, visible#position#y), (visible#size#x, visible#size#y)))

    // camera あり: center − design/2 を左上とする design 大の矩形。
    // composeScene のずらし（testComposeSceneShiftsWorldButNotHud と同じ center）と表裏一体。
    @Test
    def testVisibleOfWithCameraCentersRect(): Unit \ Assert =
        let visible = App.visibleOf(Some({ x = 100.0, y = 50.0 }), 1.0, sceneDesign());
        Assert.assertEq(expected = ((-60.0, -70.0), (320.0, 240.0)),
            ((visible#position#x, visible#position#y), (visible#size#x, visible#size#y)))

    // ========================================================================
    // makeWith: 初期 World は design サイズから組める
    // ========================================================================

    // makeWith の init は design サイズを受け取る（launch が画面サイズを渡して呼ぶ）。
    // 320 の半分 = 160 が出れば、画面中央のような導出をゲーム側がベタ書きせずに書ける。
    @Test
    def testMakeWithBuildsInitFromViewport(): Unit \ Assert =
        let app = App.makeWith(design -> design#x / 2.0);
        let init = app#init;
        Assert.assertEq(expected = 160.0, init(testViewport()))

    // make(値) は design サイズに依らず同じ初期 World を返す（既存ゲームの入口は不変）。
    @Test
    def testMakeIgnoresViewport(): Unit \ Assert =
        let init = App.make(42)#init;
        Assert.assertEq(expected = 42, init(testViewport()))

    // ========================================================================
    // quit: 既定は Escape のエッジ・quitWhen で差し替え
    // ========================================================================

    // 既定の quit は Escape の新規押下で true。
    @Test
    def testQuitDefaultFiresOnEscapeEdge(): Unit \ Assert =
        let frame = App.frameOf(prev = Set#{}, current = Set#{GameEngine.Key.Escape}, 0.016, testViewport(), noCursor(), noMouse());
        let wantsQuit = App.make(0)#quit;
        Assert.assertEq(expected = true, wantsQuit(frame, 0))

    // 押しっぱなしの Escape では終了しない（起動時に押されていたキーの誤発火を防ぐ）。
    @Test
    def testQuitDefaultIgnoresHeldEscape(): Unit \ Assert =
        let frame = App.frameOf(
            prev = Set#{GameEngine.Key.Escape}, current = Set#{GameEngine.Key.Escape}, 0.016, testViewport(), noCursor(), noMouse());
        let wantsQuit = App.make(0)#quit;
        Assert.assertEq(expected = false, wantsQuit(frame, 0))

    // quitWhen は判定を丸ごと差し替える（World も見られる）。
    @Test
    def testQuitWhenReplacesJudge(): Unit \ Assert =
        let app = App.make(9) |> App.quitWhen((_frame, n) -> n == 9);
        let wantsQuit = app#quit;
        Assert.assertEq(expected = true, wantsQuit(emptyFrame(), 9))

    // ========================================================================
    // fixedSteps: accumulator の量子化（withFixedStep の芯）
    // ========================================================================

    // 貯金 0 で 1/60 秒（≈0.01667s）ぶん経過・刻み 1/60: ちょうど 1 回分に届かず 0 回・
    // 経過秒がそのまま持ち越しに残る。
    @Test
    def testFixedStepsBelowOneQuantumIsZeroSteps(): Unit \ Assert =
        Assert.assertEq(expected = (0, 0.01), App.fixedSteps(0.0, 0.01, 1.0 / 60.0))

    // 刻みちょうど 2 回分（1/30 秒）: 2 回分回り、持ち越しはほぼ 0（浮動小数の丸め誤差のみ）。
    @Test
    def testFixedStepsExactMultipleConsumesCarry(): Unit \ Assert =
        let (steps, carry) = App.fixedSteps(0.0, 1.0 / 30.0, 1.0 / 60.0);
        Assert.assertEq(expected = (2, true), (steps, Float64.abs(carry) < 0.000001))

    // 端数の持ち越し: 前フレームの余り 0.02 + 今回 0.01 = 0.03 秒、刻み 1/60（≈0.01667s）で
    // 1 回分消費し、残り約 0.0133 秒が次へ持ち越る。
    @Test
    def testFixedStepsCarriesRemainderToNextFrame(): Unit \ Assert =
        let (steps, carry) = App.fixedSteps(0.02, 0.01, 1.0 / 60.0);
        Assert.assertEq(expected = (1, true), (steps, Float64.abs(carry - (0.03 - 1.0 / 60.0)) < 0.000001))

    // 暴走防止: 1 秒分もの貯金（本来 60 回分）があっても上限 5 回でクランプし、
    // 超過ぶんの貯金は次フレームへ持ち越さず捨てる（carry = 0）。
    @Test
    def testFixedStepsClampsToFiveAndDropsOverflow(): Unit \ Assert =
        Assert.assertEq(expected = (5, 0.0), App.fixedSteps(0.0, 1.0, 1.0 / 60.0))

    // スライシング不変: 16.667ms を 3 回に分けて渡しても、50ms を 1 回で渡しても、
    // 合計ステップ数と最終持ち越しは一致する（固定ステップが存在する意義そのもの）。
    @Test
    def testFixedStepsSlicingInvarianceMatchesTotal(): Unit \ Assert =
        let fixedDt = 1.0 / 60.0;
        let sliced = List.range(0, 3) |> List.foldLeft((state, _i) -> {
            let (stepsSoFar, carry) = state;
            let (steps, nextCarry) = App.fixedSteps(carry, 0.016667, fixedDt);
            (stepsSoFar + steps, nextCarry)
        }, (0, 0.0));
        let lumped = App.fixedSteps(0.0, 0.050001, fixedDt);
        let (slicedSteps, slicedCarry) = sliced;
        let (lumpedSteps, lumpedCarry) = lumped;
        Assert.assertEq(expected = (slicedSteps, true),
            (lumpedSteps, Float64.abs(slicedCarry - lumpedCarry) < 0.000001))

    // ========================================================================
    // suppressEdges: 2 回目以降のサブステップでエッジが消える（held 系は残る）
    // ========================================================================

    /// 全エッジが立ち・キーも押されている Frame（suppressEdges の入力サンプル）。
    def edgyFrame(): App.Frame =
        App.frameOf(prev = Set#{}, current = Set#{GameEngine.Key.Left}, 0.016, testViewport(),
            { prevCursor = Some({ x = 0.0, y = 0.0 }), cursor = { x = 5.0, y = 5.0 } },
            { prevDown = false, down = true, wheel = 1.5 })

    // 元の Frame は justPressed・mouseClicked・mouseMoved・wheel が全部立っている（前提確認）。
    @Test
    def testEdgyFrameHasAllEdgesSet(): Unit \ Assert =
        let frame = edgyFrame();
        Assert.assertEq(expected = (Set#{GameEngine.Key.Left}, true, true, 1.5),
            (frame#justPressed, frame#mouseClicked, frame#mouseMoved, frame#wheel))

    // suppressEdges 後はエッジ 4 種が全部消え、down / mouseDown は生きたまま
    // （押しっぱなし入力は消えない）。
    @Test
    def testSuppressEdgesClearsEdgesKeepsHeld(): Unit \ Assert =
        let suppressed = App.suppressEdges(edgyFrame());
        Assert.assertEq(
            expected = (Set#{}, false, false, 0.0, Set#{GameEngine.Key.Left}, true),
            (suppressed#justPressed, suppressed#mouseClicked, suppressed#mouseMoved, suppressed#wheel,
             suppressed#down, suppressed#mouseDown))

    // dt はそのまま素通し（fixedStep の呼び出し側が固定値をセットしてから渡す想定であり、
    // suppressEdges 自体は dt に触れない）。
    @Test
    def testSuppressEdgesLeavesDtUntouched(): Unit \ Assert =
        Assert.assertEq(expected = 0.016, App.suppressEdges(edgyFrame())#dt)

    // ========================================================================
    // advanceFrame: 0 ステップのフレームで立ったエッジは取り置かれ、
    // 次にサブステップが回るフレームでちょうど 1 回だけ消費される
    // ========================================================================

    /// キーとホイールだけ違う Frame（advanceFrame のエッジ持ち越しテスト用）。
    def stepFrame(prev: Set[GameEngine.Key], current: Set[GameEngine.Key], dt: Float64,
                  wheel: Float64): App.Frame =
        App.frameOf(prev = prev, current = current, dt, testViewport(), noCursor(),
            { prevDown = false, down = false, wheel = wheel })

    /// PendingEdges を比較できるタプルへ射影する。
    def pendingTuple(p: App.PendingEdges): (Set[GameEngine.Key], Bool, Bool, Float64) =
        (p#justPressed, p#mouseClicked, p#mouseMoved, p#wheel)

    // 0 ステップのフレーム（dt 0.02 < 刻み 0.03）で押した Z は、World を進めないまま
    // 取り置かれ、次のフレーム（貯金 0.04 で 1 ステップ）でちょうど 1 回だけ数えられる。
    @Test
    def testAdvanceFrameLatchesEdgeAcrossZeroStepFrame(): Unit \ Assert =
        let app = App.make(0)
            |> App.withFixedStep(0.03)
            |> App.addSystem((f, n) -> if (App.justPressed(GameEngine.Key.Z, f)) n + 1 else n);
        let (w1, s1) = App.advanceFrame(app, stepFrame(Set#{}, Set#{GameEngine.Key.Z}, 0.02, 0.0),
                                        App.freshStepState(), 0);
        let (w2, _s2) = App.advanceFrame(app, stepFrame(Set#{}, Set#{}, 0.02, 0.0), s1, w1);
        Assert.assertEq(expected = (0, 1), (w1, w2))

    // 0 ステップが 2 連続: justPressed は和集合・wheel は加算で貯まり、3 フレーム目の
    // 1 サブステップでまとめて 1 回だけ観測される（calls=1 が「二重消費なし」の証明）。
    @Test
    def testAdvanceFramePendingAccumulatesAcrossTwoZeroStepFrames(): Unit \ Assert =
        let observe = (f, w) -> {
            let (calls, edges, wheelSum) = w;
            (calls + 1, edges + Set.size(f#justPressed), wheelSum + f#wheel)
        };
        let app = App.make((0, 0, 0.0)) |> App.withFixedStep(0.05) |> App.addSystem(observe);
        let (w1, s1) = App.advanceFrame(app, stepFrame(Set#{}, Set#{GameEngine.Key.Z}, 0.015, 1.0),
                                        App.freshStepState(), (0, 0, 0.0));
        let (w2, s2) = App.advanceFrame(app, stepFrame(Set#{GameEngine.Key.Z}, Set#{GameEngine.Key.Z, GameEngine.Key.X}, 0.015, 0.5),
                                        s1, w1);
        let (w3, _s3) = App.advanceFrame(app, stepFrame(Set#{}, Set#{}, 0.03, 0.0), s2, w2);
        Assert.assertEq(expected = ((0, 0, 0.0), (1, 2, 1.5)), (w2, w3))

    // 消費したフレームの後はバッファが空に戻る（同じエッジが後で二度と発火しない）。
    @Test
    def testAdvanceFrameClearsPendingAfterConsumption(): Unit \ Assert =
        let app = App.make(0) |> App.withFixedStep(0.03) |> App.addSystem((_f, n) -> n + 1);
        let (w1, s1) = App.advanceFrame(app, stepFrame(Set#{}, Set#{GameEngine.Key.Z}, 0.02, 2.0),
                                        App.freshStepState(), 0);
        let (_w2, s2) = App.advanceFrame(app, stepFrame(Set#{}, Set#{}, 0.02, 0.0), s1, w1);
        Assert.assertEq(
            expected = ((Set#{GameEngine.Key.Z}, false, false, 2.0), (Set#{}, false, false, 0.0)),
            (pendingTuple(s1#pending), pendingTuple(s2#pending)))

    // 可変 dt（fixedStep = None）の経路: バッファは合流も更新もされず素通し
    // （既存ゲームの挙動不変の証明。system は今フレームのエッジだけを見る）。
    @Test
    def testAdvanceFrameVariableDtIgnoresPending(): Unit \ Assert =
        let app = App.make(0)
            |> App.addSystem((f, n) -> n + Set.size(f#justPressed));
        let seeded = { carry = 0.0, real = Clock.start(),
                       pending = App.pendingOf(stepFrame(Set#{}, Set#{GameEngine.Key.Z}, 0.016, 0.0)) };
        let (w1, s1) = App.advanceFrame(app, stepFrame(Set#{}, Set#{}, 0.016, 0.0), seeded, 0);
        Assert.assertEq(
            expected = (0, (Set#{GameEngine.Key.Z}, false, false, 0.0)),
            (w1, pendingTuple(s1#pending)))

    // ========================================================================
    // changedPaths: 保存検知の判定（watchFile の純粋な芯）
    // ========================================================================

    // 変化なし: 前回と今回の更新時刻が同じなら何も発火しない。
    @Test
    def testChangedPathsNoChangeIsEmpty(): Unit \ Assert =
        let times = Map#{"a.json" => 100i64, "b.json" => 200i64};
        Assert.assertEq(expected = Nil,
            App.changedPaths("a.json" :: "b.json" :: Nil, times, times))

    // 更新時刻の変化: 変わったパスだけが返る。
    @Test
    def testChangedPathsMtimeChangeFires(): Unit \ Assert =
        Assert.assertEq(expected = "a.json" :: Nil,
            App.changedPaths("a.json" :: "b.json" :: Nil,
                Map#{"a.json" => 100i64, "b.json" => 200i64},
                Map#{"a.json" => 150i64, "b.json" => 200i64}))

    // 新規出現: 前回に無く今回見えたパスは発火する。
    @Test
    def testChangedPathsNewFileFires(): Unit \ Assert =
        Assert.assertEq(expected = "a.json" :: Nil,
            App.changedPaths("a.json" :: Nil, Map#{}, Map#{"a.json" => 100i64}))

    // 消失: 今回見えないパス（消えた・読めない）は発火しない。
    @Test
    def testChangedPathsMissingFileIsSilent(): Unit \ Assert =
        Assert.assertEq(expected = Nil,
            App.changedPaths("a.json" :: Nil, Map#{"a.json" => 100i64}, Map#{}))

    // 登録順: 複数のパスが同時に変わっても、返る順は watch の登録順のまま。
    @Test
    def testChangedPathsKeepsRegistrationOrder(): Unit \ Assert =
        Assert.assertEq(expected = "b.json" :: "a.json" :: Nil,
            App.changedPaths("b.json" :: "a.json" :: Nil,
                Map#{"a.json" => 100i64, "b.json" => 200i64},
                Map#{"a.json" => 101i64, "b.json" => 201i64}))

    // ========================================================================
    // TileCache: 世代と生成し直しの判定
    // ========================================================================

    def testVao(): GpuHandle.TileVao = GpuHandle.wrapTileVao(7)

    // 置いたスロット・key は同じ世代のうちは引ける（インスタンス数がそのまま返る）。
    @Test
    def testTileCacheHitSameGen(): Unit \ Assert =
        let cache = App.tileCacheStore("0", "map-1", testVao(), 42, App.freshTileCache());
        Assert.assertEq(expected = Some(42),
            App.tileCacheHit("0", "map-1", cache) |> Option.map(snd))

    // 読み直しが起きた（世代が進んだ）後は、同じスロット・key でも引けない = 生成し直しになる。
    @Test
    def testTileCacheMissAfterBump(): Unit \ Assert =
        let cache = App.tileCacheStore("0", "map-1", testVao(), 42, App.freshTileCache());
        Assert.assertEq(expected = None,
            App.tileCacheHit("0", "map-1", App.bumpTileGen(true, cache)) |> Option.map(snd))

    // 読み直しの無いフレームでは世代は動かず、事前に生成した物は生きたまま。
    @Test
    def testTileCacheBumpFalseKeepsHit(): Unit \ Assert =
        let cache = App.tileCacheStore("0", "map-1", testVao(), 42, App.freshTileCache());
        Assert.assertEq(expected = Some(42),
            App.tileCacheHit("0", "map-1", App.bumpTileGen(false, cache)) |> Option.map(snd))

    // key が変わってもスロットの VAO は残る（updateTileBuffer の入れ直し先に使う）—
    // 一覧表は 1 スロット = 1 件のままで、key がいくら変わっても育たない。
    @Test
    def testTileCacheRollingKeyKeepsSlotVao(): Unit \ Assert =
        let c0 = App.tileCacheStore("0", "light:1", testVao(), 42, App.freshTileCache());
        Assert.assertEq(expected = (None, Some(testVao() |> GpuHandle.tileVaoInt), 1),
            (App.tileCacheHit("0", "light:2", c0) |> Option.map(snd),
             App.tileCacheVaoAt("0", c0) |> Option.map(GpuHandle.tileVaoInt),
             Map.size(c0#entries)));
        let c1 = App.tileCacheStore("0", "light:2", testVao(), 43, c0);
        Assert.assertEq(expected = (1, Some(43)),
            (Map.size(c1#entries), App.tileCacheHit("0", "light:2", c1) |> Option.map(snd)))

    // 別のスロットは独立に生成して置かれ、世代が同じ間はどちらも引ける。
    @Test
    def testTileCacheTwoSlotsIndependent(): Unit \ Assert =
        let cache = App.tileCacheStore("0", "floor", testVao(), 10,
                    App.tileCacheStore("1", "walls", testVao(), 20, App.freshTileCache()));
        Assert.assertEq(expected = (Some(10), Some(20)),
            (App.tileCacheHit("0", "floor", cache) |> Option.map(snd),
             App.tileCacheHit("1", "walls", cache) |> Option.map(snd)))

    // decideBranch: F8 と停止状態から決まる、このフレームの進み方

    /// 何も押していない、走っているフレーム。
    def running(): { f8Pressed = Bool, canDebug = Bool, remoteHold = Bool, wasPaused = Bool } =
        { f8Pressed = false, canDebug = true, remoteHold = false, wasPaused = false }

    // 走っているときに F8 を押すと止まる。
    @Test
    def testDecideBranchF8Pauses(): Unit \ Assert =
        Assert.assertEq(expected = (App.Branch.Paused, true),
            App.decideBranch({ f8Pressed = true | running() }) |> b -> (b#branch, b#toggled))

    // 止まっているときに F8 を押すと、その場では再開のフレームになる（まだ World は進めない）。
    @Test
    def testDecideBranchF8Resumes(): Unit \ Assert =
        Assert.assertEq(expected = App.Branch.Resuming,
            App.decideBranch({ f8Pressed = true, wasPaused = true | running() })#branch)

    // 再開の次のフレームは、ふつうに走る。
    @Test
    def testDecideBranchAfterResumeRuns(): Unit \ Assert =
        Assert.assertEq(expected = App.Branch.Running, App.decideBranch(running())#branch)

    // 止まっていて F8 を押さなければ、止まったまま。
    @Test
    def testDecideBranchStaysPaused(): Unit \ Assert =
        Assert.assertEq(expected = App.Branch.Paused,
            App.decideBranch({ wasPaused = true | running() })#branch)

    // HTTP 側が停止の主導権を持っている間は、F8 が効かない。
    @Test
    def testDecideBranchRemoteHoldBlocksF8(): Unit \ Assert =
        Assert.assertEq(expected = (App.Branch.Running, false),
            App.decideBranch({ f8Pressed = true, remoteHold = true | running() })
                |> b -> (b#branch, b#toggled))

    // デバッグ機能が使えない構成では、F8 が効かない。
    @Test
    def testDecideBranchNoDebugBlocksF8(): Unit \ Assert =
        Assert.assertEq(expected = App.Branch.Running,
            App.decideBranch({ f8Pressed = true, canDebug = false | running() })#branch)

    // 停止中に HTTP 側が主導権を取ると、F8 では解除できない（止まったまま）。
    @Test
    def testDecideBranchRemoteHoldKeepsPaused(): Unit \ Assert =
        Assert.assertEq(expected = App.Branch.Paused,
            App.decideBranch({ f8Pressed = true, remoteHold = true, wasPaused = true | running() })#branch)
}
