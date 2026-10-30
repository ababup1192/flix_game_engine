// CameraRig の単体テスト: 揺れ幅の二乗則・滑らかノイズの格子点一致・
// zoom の防波堤（safeZoom）と順逆変換の往復（centerOn ⇄ toWorldPos）を具体値で固定する。
mod TestCameraRig {

    /// テスト用の design サイズ。
    def rigDesign(): Vec2.Vec2 = { x = 320.0, y = 240.0 }

    // safeZoom: 正常値は素通し、0・負・NaN は minZoom へ、Infinity・過大値は maxZoom へ丸まる
    // （0 除算・鏡映・Infinity×0 の NaN 化の防波堤）。
    @Test
    def testSafeZoomClampsBadValues(): Unit \ Assert =
        Assert.assertEq(
            expected = (2.0, 1.0, CameraRig.minZoom(), CameraRig.minZoom(), CameraRig.minZoom(),
                        CameraRig.maxZoom(), CameraRig.maxZoom()),
            (CameraRig.safeZoom(2.0), CameraRig.safeZoom(1.0),
             CameraRig.safeZoom(0.0), CameraRig.safeZoom(-3.0),
             CameraRig.safeZoom(0.0 / 0.0),
             CameraRig.safeZoom(1.0 / 0.0), CameraRig.safeZoom(99999.0)))

    // zoom 0 でも可視範囲が Infinity に化けない: minZoom（0.01）に丸まり、
    // design/0.01 = 32000×24000 の有限の矩形が center を中心に出る（丸め誤差は ±0.5 で吸収）。
    @Test
    def testVisibleRectSurvivesZeroZoom(): Unit \ Assert =
        let seen = CameraRig.visibleRect({ x = 0.0, y = 0.0 }, zoom = 0.0, design = rigDesign());
        Assert.assertEq(expected = (32000.0, 24000.0, -16000.0, -12000.0),
            (Float64.floor(seen#size#x + 0.5), Float64.floor(seen#size#y + 0.5),
             Float64.floor(seen#position#x + 0.5), Float64.floor(seen#position#y + 0.5)))

    // 往復不変条件: world → (centerOn の式) → screen → toWorldPos → 元の world。
    // 数値は TestApp.testComposeSceneAtZoomTwoScalesOffsets と同じ（center から +10 の点が z=2 で +20 へ）。
    @Test
    def testToWorldPosInvertsCenterOn(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let world = { x = 110.0, y = 50.0 };
        let placed = { at = world, item = RawDraw.box({ x = 1.0, y = 1.0 }, { r = 1.0, g = 0.0, b = 0.0 }, 0) };
        let screen = CameraRig.centerOn(center, zoom = 2.0, design = rigDesign(), placed :: Nil)
            |> List.head |> Option.map(p -> p#at) |> Option.getWithDefault(Vec2.zero());
        let back = CameraRig.toWorldPos(center, zoom = 2.0, design = rigDesign(), screen = screen);
        Assert.assertEq(expected = ((180.0, 120.0), (110.0, 50.0)),
            ((screen#x, screen#y), (back#x, back#y)))

    // trauma は二乗で効く: 満タン 1.0 で maxOffset、半分 0.5 で 1/4、ゼロは揺れない。
    @Test
    def testShakeStrengthIsQuadratic(): Unit \ Assert =
        Assert.assertEq(expected = (8.0, 2.0, 0.0),
            (CameraRig.shakeStrength(1.0, maxOffset = 8.0),
             CameraRig.shakeStrength(0.5, maxOffset = 8.0),
             CameraRig.shakeStrength(0.0, maxOffset = 8.0)))

    // 滑らかノイズは格子点（整数 t）でちょうど Hash01 の値に一致し（フェード 0）、
    // 格子点の中間でも [-1, 1] に収まる。oracle は Hash01（別関数）。
    @Test
    def testSmoothNoiseAnchorsAtLattice(): Unit \ Assert =
        let anchor3 = CameraRig.smoothNoise(3.0, 0) == 2.0 * Hash01.at(3, 0) - 1.0;
        let anchor7 = CameraRig.smoothNoise(7.0, 1) == 2.0 * Hash01.at(7, 1) - 1.0;
        let mid = CameraRig.smoothNoise(3.5, 0);
        let midBounded = mid >= -1.0 and mid <= 1.0;
        Assert.assertEq(expected = (true, true, true), (anchor3, anchor7, midBounded))

    /// テスト用の調整値。
    def spec(): CameraRig.ShakeSpec = { maxOffset = 8.0, freq = 25.0, decayPerSecond = 1.5 }

    /// 小数 4 桁に丸める（2 進で表せない加算の比較用）。
    def round4(x: Float64): Float64 = Float64.floor(x * 10000.0 + 0.5) / 10000.0

    // trauma 0 のシェイクは揺れない（時計が進んでいてもゼロのまま）。
    @Test
    def testZeroTraumaShakeIsStill(): Unit \ Assert =
        let still = CameraRig.shakeOffset(spec(), { trauma = 0.0, fxClock = 5.0 });
        Assert.assertEq(expected = (0.0, 0.0), (still#x, still#y))

    // trauma 満タンのオフセットは揺れ幅（maxOffset）の中に収まる。
    @Test
    def testShakeOffsetIsBounded(): Unit \ Assert =
        let offset = CameraRig.shakeOffset(spec(), { trauma = 1.0, fxClock = 1.25 });
        Assert.assertEq(expected = (true, true),
            (Float64.abs(offset#x) <= 8.0, Float64.abs(offset#y) <= 8.0))

    // 積むと蓄積し（0.3 + 0.45 = 0.75）、上限 1.0 でクランプされる（0.7 + 0.7 → 1.0）。
    // record は丸ごと渡せて、揺れ以外のフィールド（score）は素通しされる。
    @Test
    def testAddTraumaAccumulatesAndClamps(): Unit \ Assert =
        let base = { trauma = 0.0, score = 42 };
        let stacked = base |> CameraRig.addTrauma(0.3) |> CameraRig.addTrauma(0.45);
        let capped = base |> CameraRig.addTrauma(0.7) |> CameraRig.addTrauma(0.7);
        Assert.assertEq(expected = (0.75, 1.0, 42),
            (round4(stacked#trauma), capped#trauma, stacked#score))

    // tick は trauma を decay×dt だけ減らし（下限 0.0）、fxClock を dt だけ進める。
    @Test
    def testTickDecaysAndAdvancesClock(): Unit \ Assert =
        let ticked = CameraRig.tick(0.5, spec(), { trauma = 1.0, fxClock = 2.0 });
        let floored = CameraRig.tick(0.5, spec(), { trauma = 0.1, fxClock = 0.0 });
        Assert.assertEq(expected = (0.25, 2.5, 0.0, 0.5),
            (ticked#trauma, ticked#fxClock, floored#trauma, floored#fxClock))

    /// 追従テスト用の仕様: 不感帯 40px・寄せ率 8/s。
    def follow(): CameraRig.Follow = { deadzone = 40.0, k = 8.0 }

    // 不感帯の中（±40px 以内）では動かない。不感帯の両端ぎりぎりも 0。
    @Test
    def testFollowDeltaHoldsInsideDeadzone(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 0.0, 0.0),
            (CameraRig.followDelta(follow(), 0.25, 100.0, 100.0),
             CameraRig.followDelta(follow(), 0.25, 140.0, 100.0),
             CameraRig.followDelta(follow(), 0.25, 60.0, 100.0)))

    // 不感帯を出たぶん × min(1, k×dt) の移動量。dt=1/8 で係数 1.0 → 出たぶん全部（±60）。
    // k×dt が 1 を超えても行き過ぎない（min で 1.0 に頭打ち）。
    @Test
    def testFollowDeltaMovesByExcess(): Unit \ Assert =
        Assert.assertEq(expected = (60.0, -60.0, 60.0),
            (CameraRig.followDelta(follow(), 0.125, 200.0, 100.0),
             CameraRig.followDelta(follow(), 0.125, 0.0, 100.0),
             CameraRig.followDelta(follow(), 5.0, 200.0, 100.0)))

    // clampAxis は lo..hi へ収め、hi < lo（レベルが 1 画面ぶんしか無い）なら lo に張り付く。
    @Test
    def testClampAxisEdges(): Unit \ Assert =
        Assert.assertEq(expected = (0.0, 960.0, 5.0, 0.0),
            (CameraRig.clampAxis(0.0, 960.0, -10.0),
             CameraRig.clampAxis(0.0, 960.0, 1000.0),
             CameraRig.clampAxis(0.0, 960.0, 5.0),
             CameraRig.clampAxis(0.0, -160.0, 100.0)))

    // ========================================================================
    // 中央映し: centerOn / toWorldPos / visibleRect
    // ========================================================================

    // centerOn: center に置いた item は画面中央 (design/2) に着地する。
    @Test
    def testCenterOnLandsCenterAtMiddle(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let item = { at = center, item = RawDraw.box({ x = 1.0, y = 1.0 }, red(), 0) };
        let moved = CameraRig.centerOn(center, zoom = 1.0, design = { x = 320.0, y = 240.0 }, item :: Nil);
        Assert.assertEq(expected = Some((160.0, 120.0)),
            List.head(moved) |> Option.map(p -> (p#at#x, p#at#y)))

    // toWorldPos は centerOn と互いに逆（等倍）: 画面中央を world に戻すと center そのもの。
    @Test
    def testToWorldPosMiddleIsCenterAtUnitZoom(): Unit \ Assert =
        let center = { x = 100.0, y = 50.0 };
        let back = CameraRig.toWorldPos(center, zoom = 1.0, design = { x = 320.0, y = 240.0 },
                                        screen = { x = 160.0, y = 120.0 });
        Assert.assertEq(expected = (100.0, 50.0), (back#x, back#y))

    // visibleRect は center を中央にした design サイズの矩形（左上 = center - design/2）。
    @Test
    def testVisibleRectSurroundsCenter(): Unit \ Assert =
        let r = CameraRig.visibleRect({ x = 100.0, y = 50.0 }, zoom = 1.0, design = { x = 320.0, y = 240.0 });
        Assert.assertEq(expected = (-60.0, -70.0, 320.0, 240.0),
            (r#position#x, r#position#y, r#size#x, r#size#y))

    def red(): Color = { r = 1.0, g = 0.0, b = 0.0 }

    // ── clampCenter / parallaxCenter ──

    /// テスト用のレベル矩形（(0,0) 起点の 960×720）。
    def stage(): Rect2.Rect2 = { position = { x = 0.0, y = 0.0 }, size = { x = 960.0, y = 720.0 } }

    // clampCenter: 内側は素通し・端では「視界の縁が bounds に触れる」位置 (160,120)/(800,600) で
    // 止まる・bounds が視界より狭い軸は bounds 中央に固定。
    @Test
    def testClampCenterPinsAtEdges(): Unit \ Assert =
        let seen = rigDesign();
        let inside = CameraRig.clampCenter(bounds = stage(), seen = seen, { x = 480.0, y = 360.0 });
        let low    = CameraRig.clampCenter(bounds = stage(), seen = seen, { x = -500.0, y = -500.0 });
        let high   = CameraRig.clampCenter(bounds = stage(), seen = seen, { x = 5000.0, y = 5000.0 });
        let narrow = CameraRig.clampCenter(
            bounds = { position = { x = 0.0, y = 0.0 }, size = { x = 100.0, y = 720.0 } },
            seen = seen, { x = 90.0, y = 360.0 });
        Assert.assertEq(
            expected = ((480.0, 360.0), (160.0, 120.0), (800.0, 600.0), (50.0, 360.0)),
            ((inside#x, inside#y), (low#x, low#y), (high#x, high#y), (narrow#x, narrow#y)))

    // clampCenter は zoom で広がった視界（seen = design/zoom）でも成立する:
    // 引き（z=0.5 → seen 640×480）では止まる位置が内側（320,240）へ寄る。
    @Test
    def testClampCenterRespectsZoomedSeen(): Unit \ Assert =
        let seen = { x = 640.0, y = 480.0 };
        let low = CameraRig.clampCenter(bounds = stage(), seen = seen, { x = 0.0, y = 0.0 });
        Assert.assertEq(expected = (320.0, 240.0), (low#x, low#y))

    // parallaxCenter: factor 1 で本来の center・0 で画面中央（design/2）・0.5 で中点。
    @Test
    def testParallaxCenterLerpsFromScreenMiddle(): Unit \ Assert =
        let center = { x = 480.0, y = 360.0 };
        let full = CameraRig.parallaxCenter(1.0, center, design = rigDesign());
        let none = CameraRig.parallaxCenter(0.0, center, design = rigDesign());
        let half = CameraRig.parallaxCenter(0.5, center, design = rigDesign());
        Assert.assertEq(
            expected = ((480.0, 360.0), (160.0, 120.0), (320.0, 240.0)),
            ((full#x, full#y), (none#x, none#y), (half#x, half#y)))
}
