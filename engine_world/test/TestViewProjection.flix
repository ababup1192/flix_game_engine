// ViewProjection（world → screen の 4 通りと逆算）— 写した物が戻ること・Side / TopDown の
// world が画面への割合でなく world 単位であること・斜行した Quarter で画面の delta が
// world の 2 軸に散ること・画面を覆うマスを盤の内側から取りこぼさずに奥から手前へ並べること。
mod TestViewProjection {

    def design(): Vec2.Vec2 = { x = 320.0, y = 200.0 }

    /// world 1 が 100px。world (0,0) が画面の中央に来る。
    def side(): ViewProjection.ViewProjection =
        ViewProjection.side({ design = design(), center = Vec2.zero(), zoom = 100.0 })

    /// タイル 32×16 の 2:1 ひし形。高さ 1 = タイル 1 マスの高さ。
    def quarterSpec(): ViewProjection.QuarterSpec =
        { design = design(), tile = { x = 32.0, y = 16.0 },
          rise = 16.0, origin = { x = 160.0, y = 40.0 } }

    def quarter(): ViewProjection.ViewProjection = ViewProjection.quarter(quarterSpec())

    def firstPersonSpec(): ViewProjection.FirstPersonSpec =
        { design = design(),
          camera = ViewProjection.makeCamera({ x = 0.5, y = 0.5 }, Dir4.Dir4.Down),
          persp = { center = { x = 160.0, y = 100.0 }, fx = 192.0, fy = 192.0 },
          near = 0.05 }

    def firstPerson(): ViewProjection.ViewProjection =
        ViewProjection.firstPerson(firstPersonSpec())

    /// 盤の真ん中あたりを映している写し方（world (0,0) は画面の上の外）。盤の端で切れる話と
    /// 画面の端で切れる話が混ざらないよう、覆うマスの検査はこちらで測る。
    def boardSpec(): ViewProjection.QuarterSpec =
        { origin = { x = 160.0, y = -200.0 } | quarterSpec() }

    /// 盤の広さ。
    def boardSize(): { cols = Int32, rows = Int32 } = { cols = 40, rows = 40 }

    def cover(maxHeight: Float64): List[Grid.Cell] =
        coverOn(maxHeight, boardSize()#cols, boardSize()#rows)

    def coverOn(maxHeight: Float64, cols: Int32, rows: Int32): List[Grid.Cell] =
        ViewProjection.coveringCells(boardSpec(),
            { maxHeight = maxHeight, cols = cols, rows = rows, margin = Grid.noMargin() })

    def boardInverse(): ViewProjection.Inverse = ViewProjection.Inverse.QuarterInverse(boardSpec())

    def quarterInverse(): ViewProjection.Inverse =
        ViewProjection.inverseOf(quarter())
            |> Option.getWithDefault(ViewProjection.Inverse.QuarterInverse(quarterSpec()))

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.0001

    @Test
    def testQuarterOriginIsTheDeclaredScreenPoint(): Unit \ Assert =
        // world (0,0,0) は origin にそのまま出る（写し方の原点はゲームが決めた 1 点）。
        let p = ViewProjection.toScreen(quarter(), ViewProjection.worldPos(0.0, 0.0))
            |> Option.getWithDefault(Vec2.zero());
        Assert.assertEq(expected = (true, true), (near(p#x, 160.0), near(p#y, 40.0)))

    @Test
    def testQuarterRoundTripsThroughScreen(): Unit \ Assert =
        // 高さつきの world を画面へ写し、同じ高さで戻すと元の world に帰る（逆変換の要）。
        let at = ViewProjection.worldPosAt(3.25, -1.5, 2.0);
        let back = ViewProjection.toScreen(quarter(), at)
            |> Option.map(s -> ViewProjection.toWorld(quarterInverse(), 2.0, s))
            |> Option.getWithDefault(ViewProjection.worldPos(99.0, 99.0));
        Assert.assertEq(expected = (true, true), (near(back#x, 3.25), near(back#y, -1.5)))

    @Test
    def testQuarterScreenNudgeMovesBothWorldAxes(): Unit \ Assert =
        // 斜行しているので「画面で左へ 16px」は world の x だけでなく y も動かす
        // （タイル 32×16 なら (-0.5, +0.5)）。手で足し引きすると必ず間違える場所。
        let d = ViewProjection.toWorldDelta(quarterInverse(), { x = -16.0, y = 0.0 });
        Assert.assertEq(expected = (true, true), (near(d#x, -0.5), near(d#y, 0.5)))

    @Test
    def testQuarterNudgeAgreesWithProjection(): Unit \ Assert =
        // toWorldDelta で動かした world を写し直すと、画面ではちょうど頼んだ px だけ動く。
        let at = ViewProjection.worldPosAt(2.0, 1.0, 0.0);
        let d = ViewProjection.toWorldDelta(quarterInverse(), { x = -16.0, y = 4.0 });
        let a = ViewProjection.toScreen(quarter(), at) |> Option.getWithDefault(Vec2.zero());
        let b = ViewProjection.toScreen(quarter(),
                    ViewProjection.worldPosAt(at#x + d#x, at#y + d#y, 0.0))
            |> Option.getWithDefault(Vec2.zero());
        Assert.assertEq(expected = (true, true), (near(b#x - a#x, -16.0), near(b#y - a#y, 4.0)))

    @Test
    def testQuarterHeightLiftsOnScreen(): Unit \ Assert =
        // 高さ 1 は rise ぶん画面の上へ持ち上がる（x は動かない）。
        let flat = ViewProjection.toScreen(quarter(), ViewProjection.worldPosAt(1.0, 1.0, 0.0))
            |> Option.getWithDefault(Vec2.zero());
        let up = ViewProjection.toScreen(quarter(), ViewProjection.worldPosAt(1.0, 1.0, 1.0))
            |> Option.getWithDefault(Vec2.zero());
        Assert.assertEq(expected = (true, true), (near(up#x, flat#x), near(flat#y - up#y, 16.0)))

    @Test
    def testCoveringCellsHoldEveryOnScreenPoint(): Unit \ Assert =
        // 画面の中の点を world へ戻して丸めたマスが、盤の内側なら必ず列挙に含まれる
        // （四隅の外接だけでは落ちる四隅・辺を、広げた矩形が拾えているかの裏取り）。
        let occupied = cover(3.0) |> List.map(c -> (c#x, c#y)) |> List.toSet;
        let probes = { x = 1.0, y = 1.0 } :: { x = 319.0, y = 1.0 } ::
                     { x = 1.0, y = 199.0 } :: { x = 319.0, y = 199.0 } ::
                     { x = 160.0, y = 100.0 } :: Nil;
        let missing = probes |> List.count(s -> {
            let cell = cellOf(ViewProjection.toWorld(boardInverse(), 0.0, s));
            not Set.memberOf((cell#x, cell#y), occupied)
        });
        Assert.assertEq(expected = 0, missing)

    @Test
    def testCoveringCellsReachBelowTheScreenForTallCells(): Unit \ Assert =
        // 高いマスは画面の下辺より下から持ち上がって見える。maxHeight を上げたら
        // 列挙は必ず広がる（「逆変換がある」と「覆うマスを列挙できる」が別物である理由）。
        Assert.assertEq(expected = true, List.length(cover(6.0)) > List.length(cover(0.0)))

    @Test
    def testCoveringCellsWidenTheOppositeEdgeForPits(): Unit \ Assert =
        // 高さが負の場面（穴・地下・水面下）では物は画面の**下**へ沈むので、広がるのは
        // 反対の辺 — 画面の上辺より奥のマス（x + y が小さい側）が見えてくる。
        let shallowest = cells -> cells |> List.map(c -> c#x + c#y) |> List.minimum
            |> Option.getWithDefault(0);
        Assert.assertEq(expected = true, shallowest(cover(-6.0)) < shallowest(cover(0.0)))

    @Test
    def testCoveringCellsStayOnTheBoard(): Unit \ Assert =
        // Grid.cellsIn と同じ契約 — 盤の外は返さないので、呼ぶ側に範囲チェックを書かせない
        // （盤を狭めたら本数も減ることまで見て、検査が空回りしないようにする）。
        let small = coverOn(6.0, 20, 20);
        Assert.assertEq(expected = (0, true),
            (small |> List.count(c -> not Grid.inRectOf(c, 20, 20)),
             List.length(small) < List.length(cover(6.0))))

    @Test
    def testCoveringCellsRunBackToFront(): Unit \ Assert =
        // そのまま順に描けば重なりが正しくなる並び（斜め見下ろしの手前 = x + y が大きい）。
        let depths = cover(3.0) |> List.map(c -> c#x + c#y);
        let outOfOrder = List.zip(depths, List.drop(1, depths))
            |> List.count(pair -> { let (a, b) = pair; b < a });
        Assert.assertEq(expected = 0, outOfOrder)

    @Test
    def testSideWorldIsInWorldUnitsNotScreenFractions(): Unit \ Assert =
        // world 1 は design が何であれ zoom px。画面への割合で持っていたら、
        // 同じ 1.0 が 320px の画面で 320px・640px の画面で 640px になってしまう。
        let stepOn = d -> {
            let proj = ViewProjection.side({ design = d, center = Vec2.zero(), zoom = 100.0 });
            let a = ViewProjection.toScreen(proj, ViewProjection.worldPos(0.0, 0.0))
                |> Option.getWithDefault(Vec2.zero());
            let b = ViewProjection.toScreen(proj, ViewProjection.worldPos(1.0, 0.0))
                |> Option.getWithDefault(Vec2.zero());
            b#x - a#x
        };
        Assert.assertEq(expected = (true, true),
            (near(stepOn(design()), 100.0), near(stepOn({ x = 640.0, y = 200.0 }), 100.0)))

    @Test
    def testSideRoundTripsThroughCameraRig(): Unit \ Assert =
        // 逆算は CameraRig.toWorldPos そのもの。center は画面の中央に出る。
        let inv = ViewProjection.inverseOf(side())
            |> Option.getWithDefault(ViewProjection.Inverse.QuarterInverse(quarterSpec()));
        let w = ViewProjection.toWorld(inv, 0.0, { x = 160.0, y = 100.0 });
        Assert.assertEq(expected = (true, true), (near(w#x, 0.0), near(w#y, 0.0)))

    @Test
    def testFirstPersonHasNoInverse(): Unit \ Assert =
        // 画面の 1 点に当たる world の点が奥行きぶん無数にあるので、戻し方を出さない。
        // 「無い」は Option を返す関数でなく、持ち物を取り出す口で 1 回だけ捌く。
        Assert.assertEq(expected = (true, true),
            (Option.isEmpty(ViewProjection.inverseOf(firstPerson())),
             Option.isEmpty(ViewProjection.quarterOf(firstPerson()))))

    @Test
    def testFirstPersonYawIsSignedFromStraightAhead(): Unit \ Assert =
        // 画面の y は下向きなので、+y を向いているカメラの「右」は -x の側になる
        // （Persp.Camera の yaw の決まりをそのまま引き継ぐ）。
        // 「この物を中央へ寄せたい」は、この符号を 0 に近づける向きへ world を動かすこと。
        let toTheRight = ViewProjection.yawOf(firstPersonSpec(), ViewProjection.worldPos(-0.5, 2.5));
        let toTheLeft = ViewProjection.yawOf(firstPersonSpec(), ViewProjection.worldPos(1.5, 2.5));
        Assert.assertEq(expected = (true, true), (toTheRight > 0.0, toTheLeft < 0.0))

    @Test
    def testFirstPersonYawAgreesWithTheScreen(): Unit \ Assert =
        // 符号だけでなく、実際に画面のどちら側に出るかと一致していること
        // （yaw が逆変換の代役になれるのは、この一致があるから）。
        let at = ViewProjection.worldPos(-0.5, 2.5);
        let yaw = ViewProjection.yawOf(firstPersonSpec(), at);
        let sx = ViewProjection.toScreen(firstPerson(), at)
            |> Option.map(p -> p#x) |> Option.getWithDefault(0.0);
        Assert.assertEq(expected = (true, true), (yaw > 0.0, sx > 160.0))

    @Test
    def testVisibleFractionIsOneInsideAndZeroBehind(): Unit \ Assert =
        // 画面に丸ごと入っている物は 1.0・カメラの後ろは 0.0（両端の値まで測る。
        // 「キーが出ている」だけでは、いつも 0 を返す実装が通ってしまう）。
        let inside = ViewProjection.visibleFraction(firstPersonSpec(),
            ViewProjection.worldPos(0.5, 2.5), 0.2);
        let behind = ViewProjection.visibleFraction(firstPersonSpec(),
            ViewProjection.worldPos(0.5, -2.0), 0.2);
        Assert.assertEq(expected = (true, true), (near(inside, 1.0), near(behind, 0.0)))

    @Test
    def testCameraIsTheCallersToMove(): Unit \ Assert =
        // 一人称は構図の半分がカメラ側にある。「カメラを 1 マス下がる」が呼ぶ側から書けること
        // （土台がカメラを 1 つに固定していたら、2 つ目の一人称の場面で破綻する）。
        let backedOff = { camera = ViewProjection.makeCamera({ x = 0.5, y = -0.5 }, Dir4.Dir4.Down)
                        | firstPersonSpec() };
        let at = ViewProjection.worldPos(0.5, 3.0);
        let d0 = ViewProjection.distanceOf(firstPersonSpec(), at);
        let d1 = ViewProjection.distanceOf(backedOff, at);
        Assert.assertEq(expected = true, near(d1 - d0, 1.0))

    @Test
    def testCameraCanFaceAnyDirectionNotJustFourWays(): Unit \ Assert =
        // Persp.Camera をそのまま受けるので、四方位に縛られない（斜めを向く・なめらかに回す）。
        let turned = { camera = ({ pos = { x = 0.5, y = 0.5 }, yaw = Num.pi() / 4.0 }: Persp.Camera)
                     | firstPersonSpec() };
        // yaw 45° の正面は (+x, +y) の斜め。そこに置いた点のずれは 0 度。
        Assert.assertEq(expected = true,
            near(ViewProjection.yawOf(turned, ViewProjection.worldPos(2.5, 2.5)), 0.0))

    @Test
    def testWallQuadTakesEyeHeight(): Unit \ Assert =
        // 目線を壁の中程に置いた壁（hTop = -0.6 / hBot = 0.4）は、消失点をまたぐ。
        // hBot を 0 に決め打ちすると床側が作れない — その口が開いていることの検査。
        let c = wallOf({ x = -0.5, y = 3.0 }, { x = 1.5, y = 3.0 })#corners;
        Assert.assertEq(expected = (true, true), (c#topA#y < 100.0, c#botA#y > 100.0))

    @Test
    def testWallQuadKeepsVerticalEdges(): Unit \ Assert =
        // 同じ端点の上下は同じ x（Persp.stripCorners の保証がそのまま通ること）。
        let c = wallOf({ x = -0.5, y = 3.0 }, { x = 1.5, y = 5.0 })#corners;
        Assert.assertEq(expected = (true, true),
            (near(c#topA#x, c#botA#x), near(c#topB#x, c#botB#x)))

    @Test
    def testWallQuadCarriesTheClipInfoForOrderAndTexture(): Unit \ Assert =
        // 近クリップで手前が切れた壁は t0 が 0 から動く。dist は描画順（Painter.zOrdered）、
        // t0 / t1 は模様を世界に固定する（歩いても滑らせない）ために要る値。
        // 四隅だけ返すと、呼ぶ側が同じクリップをもう一度回すことになる。
        let w = wallOf({ x = 0.5, y = -1.0 }, { x = 0.5, y = 4.0 });
        Assert.assertEq(expected = (true, true, true), (w#t0 > 0.0, near(w#t1, 1.0), w#dist > 0.0))

    @Test
    def testWallQuadDropsWallsBehindTheCamera(): Unit \ Assert =
        // 全部カメラの後ろなら None（近クリップは Persp が持つ）。
        Assert.assertEq(expected = true,
            Option.isEmpty(ViewProjection.wallQuad(firstPersonSpec(), { x = -1.0, y = -2.0 },
                { x = 1.0, y = -2.0 }, { hTop = -0.5, hBot = 0.5 })))

    /// 目線を壁の中程に置いた壁 1 枚。切れて None になる場合は 0 詰めで返す。
    def wallOf(a: Vec2.Vec2, b: Vec2.Vec2):
            { corners = Persp.Corners, dist = Float64, t0 = Float64, t1 = Float64 } =
        ViewProjection.wallQuad(firstPersonSpec(), a, b, { hTop = -0.6, hBot = 0.4 })
            |> Option.getWithDefault(
                { corners = { topA = Vec2.zero(), topB = Vec2.zero(),
                              botA = Vec2.zero(), botB = Vec2.zero() },
                  dist = 0.0, t0 = 0.0, t1 = 0.0 })

    /// world の点がどのマスに属するか（マスの中心が整数）。
    def cellOf(w: ViewProjection.WorldPos): Grid.Cell =
        { x = Float64.round(w#x) |> Float64.tryToInt32 |> Option.getWithDefault(0),
          y = Float64.round(w#y) |> Float64.tryToInt32 |> Option.getWithDefault(0) }
}
