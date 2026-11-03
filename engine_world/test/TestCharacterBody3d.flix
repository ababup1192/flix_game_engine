// 一人称で歩く体（CharacterBody3d）: 壁で止まる・角で詰まらない・上から落ちて乗る・段差・坂の角・落ちる速さ・
// 速く走っても薄い壁を抜けない・止まっている時に震えない・動く箱に押される、と、
// 壁と手すりと階段のある部屋をたくさんの向きと速さで歩いて食い込まず抜けない性質。
// 体は半径 0.25・高さ 1.6（段 0.3・区切り 0.05 m）。床は y = 0 の上面の大きな板。
mod TestCharacterBody3d {

    def s(): CharacterBody3d.Settings = CharacterBody3d.settings(0.25, 1.6)

    def floor(): CollisionShape3d.Box3d = CollisionShape3d.box3d(Vec3.v3(0.0, -0.5, 0.0), Vec3.v3(50.0, 0.5, 50.0))

    def box(cx: Float64, cy: Float64, cz: Float64, hx: Float64, hy: Float64, hz: Float64): CollisionShape3d.Box3d =
        CollisionShape3d.box3d(Vec3.v3(cx, cy, cz), Vec3.v3(hx, hy, hz))

    /// 床の板と boxes の集まり。
    def worldOf(boxes: List[CollisionShape3d.Box3d]): CollisionWorld3d.CollisionWorld3d = CollisionWorld3d.build(2.0, floor() :: boxes)

    /// (x, y, z) に置いて床に合わせた体。
    def standAt(w: CollisionWorld3d.CollisionWorld3d, x: Float64, y: Float64, z: Float64): CharacterBody3d.Body =
        CharacterBody3d.snapToFloor(w, Nil, s(), CharacterBody3d.bodyAt(Vec3.v3(x, y, z)))

    /// 速さ (vx, 0, vz) で 1/60 秒を n コマ歩いた後の体。
    def walk(w: CollisionWorld3d.CollisionWorld3d, vx: Float64, vz: Float64, n: Int32, b: CharacterBody3d.Body): CharacterBody3d.Body =
        CharacterBody3d.simulate(w, Nil, s(), Vec3.v3(vx, 0.0, vz), 1.0 / 60.0, n, b) |> List.last |> Option.getWithDefault(b)

    def mm(f: Float64): Int32 = Num.roundInt(f * 1000.0)

    def feetMm(b: CharacterBody3d.Body): (Int32, Int32, Int32) = (mm(b#feet#x), mm(b#feet#y), mm(b#feet#z))

    def rad(deg: Float64): Float64 = deg * Num.pi() / 180.0

    // ════════════════════════════════════════════════════════════════════
    // 壁で止まる
    // ════════════════════════════════════════════════════════════════════

    /// x = 2 の面の壁へ 2 m/秒で 2 秒歩くと、壁の手前の半径（2 − 0.25 = 1.75）で止まり、床の高さのまま。
    @Test
    def testWalkStopsAtWall(): Unit \ Assert =
        let w = worldOf(box(2.5, 1.0, 0.0, 0.5, 1.0, 2.0) :: Nil);
        Assert.assertEq(expected = (1750, 0, 0), feetMm(walk(w, 2.0, 0.0, 120, standAt(w, 0.0, 0.0, 0.0))))

    /// x = 2 と z = 2 の 2 枚の壁の角へ斜めに歩くと、どちらの壁からも半径の所（1.75, 1.75）で止まる（角で反対側へ抜けない）。
    @Test
    def testWalkStopsInCorner(): Unit \ Assert =
        let w = worldOf(box(2.5, 1.0, 0.0, 0.5, 1.0, 5.0) :: box(0.0, 1.0, 2.5, 5.0, 1.0, 0.5) :: Nil);
        Assert.assertEq(expected = (1750, 0, 1750), feetMm(walk(w, 2.0, 2.0, 120, standAt(w, 0.0, 0.0, 0.0))))

    /// 1 コマ 0.05 秒・40 m/秒（1 コマ 2 m）で厚さ 2 cm の壁へ走っても、壁の手前（2 − 0.01 − 0.25 = 1.74）で止まる。
    @Test
    def testFastRunDoesNotTunnelThinWall(): Unit \ Assert =
        let w = worldOf(box(2.0, 1.0, 0.0, 0.01, 1.0, 2.0) :: Nil);
        let end = CharacterBody3d.simulate(w, Nil, s(), Vec3.v3(40.0, 0.0, 0.0), 0.05, 10, standAt(w, 0.0, 0.0, 0.0)) |> List.last;
        Assert.assertEq(expected = Some(1740), end |> Option.map(b -> mm(b#feet#x)))

    // ════════════════════════════════════════════════════════════════════
    // 床・段差・坂・落ちる
    // ════════════════════════════════════════════════════════════════════

    /// 高さ 3 から、上面が 1 m の箱の上へ落とすと、1 秒の後には上面に立っている。
    @Test
    def testFallsOntoBoxFromAbove(): Unit \ Assert =
        let w = worldOf(box(0.0, 0.5, 0.0, 1.0, 0.5, 1.0) :: Nil);
        let landed = walk(w, 0.0, 0.0, 60, CharacterBody3d.bodyAt(Vec3.v3(0.0, 3.0, 0.0)));
        Assert.assertEq(expected = (1000, true), (mm(landed#feet#y), CharacterBody3d.isOnFloor(landed)))

    /// 床の無い所で 0.1 秒ずつ 2 コマ落ちると、縦の速さは −0.98 → −1.96、足元は 10 − 0.098 = 9.902 → 9.902 − 0.196 = 9.706。
    @Test
    def testFallFollowsGravity(): Unit \ Assert =
        let path = CharacterBody3d.simulate(CollisionWorld3d.empty(), Nil, s(), Vec3.zero(), 0.1, 2, CharacterBody3d.bodyAt(Vec3.v3(0.0, 10.0, 0.0)));
        let speed = (b: CharacterBody3d.Body) -> match b#footing {
            case CharacterBody3d.Footing.Airborne(vy) => mm(vy)
            case CharacterBody3d.Footing.OnFloor(_)   => bug!("床の無い所で床に立った")
        };
        Assert.assertEq(expected = (9902, -980) :: (9706, -1960) :: Nil, path |> List.map(b -> (mm(b#feet#y), speed(b))))

    /// 段の高さ（0.3）より低い 0.2 の段は上に乗り、0.5 の段は壁になる
    /// （一番下の球の真ん中 0.3 + 0.25 = 0.55 が段の角 (1, 0.5) から半径の所 → x = 1 − √(0.25² − 0.05²) ≒ 0.755 で止まる）。
    @Test
    def testStepHeightDecidesClimbOrWall(): Unit \ Assert =
        let low = worldOf(box(2.0, 0.1, 0.0, 1.0, 0.1, 2.0) :: Nil);
        let high = worldOf(box(2.0, 0.25, 0.0, 1.0, 0.25, 2.0) :: Nil);
        Assert.assertEq(expected = ((2000, 200, 0), (755, 0, 0)),
            (feetMm(walk(low, 2.0, 0.0, 60, standAt(low, 0.0, 0.0, 0.0))), feetMm(walk(high, 2.0, 0.0, 60, standAt(high, 0.0, 0.0, 0.0)))))

    /// +x へ上がる坂（長さ 6・厚さ 0.2 の板を Z まわりに deg 度傾け、低い端の上面を x = 0・y = 0 に合わせる）。
    def ramp(deg: Float64): CollisionShape3d.Box3d =
        let a = rad(deg);
        let center = Vec3.v3(3.0 * Num.cos(a) + 0.1 * Num.sin(a), 3.0 * Num.sin(a) - 0.1 * Num.cos(a), 0.0);
        CollisionShape3d.transformBox(Mat4.mul(Mat4.translate(center), Mat4.rotateZ(a)), box(0.0, 0.0, 0.0, 3.0, 0.1, 2.0))

    /// 床の傾きの上限 45° で、44° の坂は上がり（2 秒で 1 m より高い所へ）、46° の坂は壁で床の高さのまま。坂に立つ間の床は sloped。
    @Test
    def testSlopeAngleDecidesFloorOrWall(): Unit \ Assert =
        let up = (deg: Float64) -> { let w = worldOf(ramp(deg) :: Nil); walk(w, 2.0, 0.0, 120, standAt(w, -1.0, 0.0, 0.0)) };
        let sloped = (b: CharacterBody3d.Body) -> match b#footing {
            case CharacterBody3d.Footing.OnFloor(f) => f#sloped
            case CharacterBody3d.Footing.Airborne(_) => false
        };
        Assert.assertEq(expected = (true, true, 0), ((up(44.0))#feet#y > 1.0, sloped(up(44.0)), mm((up(46.0))#feet#y)))

    /// 床の傾きの上限を 90° にすると、46° の坂も上がる（傾いた箱を全部床として扱う）。
    @Test
    def testFloorMaxAngle90ClimbsSteepSlope(): Unit \ Assert =
        let w = worldOf(ramp(46.0) :: Nil);
        let steep = { floorMaxAngleDeg = 90.0 | s() };
        let start = CharacterBody3d.snapToFloor(w, Nil, steep, CharacterBody3d.bodyAt(Vec3.v3(-1.0, 0.0, 0.0)));
        let end = CharacterBody3d.simulate(w, Nil, steep, Vec3.v3(2.0, 0.0, 0.0), 1.0 / 60.0, 120, start) |> List.last;
        Assert.assertTrue(end |> Option.exists(b -> b#feet#y > 1.0))

    /// 立っていて動かない体は、平らな床でも 30° の坂の途中でも 1 秒の間 1 bit も動かない。
    @Test
    def testStandingStillDoesNotJitter(): Unit \ Assert =
        let w = worldOf(ramp(30.0) :: Nil);
        let still = (b: CharacterBody3d.Body) -> CharacterBody3d.simulate(w, Nil, s(), Vec3.zero(), 1.0 / 60.0, 60, b) |> List.map(p -> (p#feet#x, p#feet#y, p#feet#z));
        let slope = standAt(w, 2.0, 2.0, 0.0);
        let flat = standAt(w, -2.0, 0.0, 0.0);
        Assert.assertEq(expected = (List.repeat(60, (slope#feet#x, slope#feet#y, slope#feet#z)), List.repeat(60, (flat#feet#x, flat#feet#y, flat#feet#z))),
            (still(slope), still(flat)))

    /// 下へ探す: 20 m 下の床に合わせる。床の無い所はそのまま（落ちる前の体）。
    @Test
    def testSnapToFloorSearchesDown(): Unit \ Assert =
        let w = worldOf(Nil);
        Assert.assertEq(expected = ((0, 0, 0), true, (0, -100000, 0)),
            (feetMm(standAt(w, 0.0, 19.0, 0.0)), CharacterBody3d.isOnFloor(standAt(w, 0.0, 19.0, 0.0)),
             feetMm(standAt(CollisionWorld3d.empty(), 0.0, -100.0, 0.0))))

    /// 斜め 30° の坂を上から 2 m/秒で 2.5 秒下りると、途中のどのコマも床に立ったまま（浮いて落ちない）で、下の床（0）に着く。
    @Test
    def testWalkingDownSlopeStaysOnFloor(): Unit \ Assert =
        let w = worldOf(ramp(30.0) :: Nil);
        let path = CharacterBody3d.simulate(w, Nil, s(), Vec3.v3(-2.0, 0.0, 0.0), 1.0 / 60.0, 150, standAt(w, 4.5, 3.0, 0.0));
        Assert.assertEq(expected = (true, Some(0)), (List.forAll(CharacterBody3d.isOnFloor, path), List.last(path) |> Option.map(b -> mm(b#feet#y))))

    /// 高さ 1 の台（x −1..1）の上から縁の外へ歩くと、途中で落ち始め、1.5 秒の後には下の床（0）に立っている
    /// （縁を越えて落ち始めるまで約 0.6 秒・1 m 落ちるのに約 0.45 秒）。
    @Test
    def testWalkingOffLedgeFallsAndLands(): Unit \ Assert =
        let w = worldOf(box(0.0, 0.5, 0.0, 1.0, 0.5, 1.0) :: Nil);
        let path = CharacterBody3d.simulate(w, Nil, s(), Vec3.v3(2.0, 0.0, 0.0), 1.0 / 60.0, 90, standAt(w, 0.0, 1.0, 0.0));
        Assert.assertEq(expected = (true, Some((0, true))),
            (List.exists(b -> not CharacterBody3d.isOnFloor(b), path), List.last(path) |> Option.map(b -> (mm(b#feet#y), CharacterBody3d.isOnFloor(b)))))

    /// 継ぎ目（z = 0）で 2 つに分かれた x = 2 の壁に沿って斜めに歩くと、継ぎ目で詰まらず z へ 2 m 以上進む（−1.5 → 0.5 より先。
    /// x は壁の手前 1.75 のまま）。継ぎ目では箱の角が球を斜めに押すので、z は 2 cm まで余分に進みうる。
    @Test
    def testWallSeamDoesNotSnag(): Unit \ Assert =
        let w = worldOf(box(2.5, 1.0, -1.0, 0.5, 1.0, 1.0) :: box(2.5, 1.0, 1.0, 0.5, 1.0, 1.0) :: Nil);
        let end = walk(w, 2.0, 2.0, 60, standAt(w, 1.5, 0.0, -1.5));
        Assert.assertEq(expected = (1750, 0, true), (mm(end#feet#x), mm(end#feet#y), end#feet#z >= 0.5 and end#feet#z < 0.52))

    // ════════════════════════════════════════════════════════════════════
    // 動く箱（扉の板）
    // ════════════════════════════════════════════════════════════════════

    /// 止まっている体に、x = 0.1 に面のある動く箱が食い込むと、面から半径の所（0.1 − 0.25 = −0.15）へ押し出される。
    @Test
    def testMovingBoxPushesStillBody(): Unit \ Assert =
        let w = worldOf(Nil);
        let door = box(0.3, 1.0, 0.0, 0.2, 1.0, 1.0);
        let pushed = CharacterBody3d.moveAndSlide(w, door :: Nil, s(), Vec3.zero(), 1.0 / 60.0, standAt(w, 0.0, 0.0, 0.0));
        Assert.assertEq(expected = ((-150, 0, 0), 0), (feetMm(pushed), mm(CharacterBody3d.overlapDepth(w, door :: Nil, s(), pushed))))

    /// 動く箱へ歩くと壁と同じく止まる（x = 2 の面 → 1.75）。
    @Test
    def testMovingBoxBlocksLikeWall(): Unit \ Assert =
        let w = worldOf(Nil);
        let door = box(2.05, 1.0, 0.0, 0.05, 1.0, 1.0);
        let end = CharacterBody3d.simulate(w, door :: Nil, s(), Vec3.v3(2.0, 0.0, 0.0), 1.0 / 60.0, 120, standAt(w, 0.0, 0.0, 0.0)) |> List.last;
        Assert.assertEq(expected = Some((1750, 0, 0)), end |> Option.map(feetMm))

    /// 高さ 1 の台の縁（x = 0.9）に止まっている体を、動く箱（x 0.4..1.0）が +x へ押し出す（0.9 + 0.1 + 0.25 = 1.25。台の縁の外）と、
    /// 止まっていても落ち始め、その後 1 秒で下の床（0）に立つ。
    @Test
    def testStillBodyPushedOffLedgeFalls(): Unit \ Assert =
        let w = worldOf(box(0.0, 0.5, 0.0, 1.0, 0.5, 1.0) :: Nil);
        let door = box(0.7, 1.5, 0.0, 0.3, 0.5, 1.0);
        let pushed = CharacterBody3d.moveAndSlide(w, door :: Nil, s(), Vec3.zero(), 1.0 / 60.0, standAt(w, 0.9, 1.0, 0.0));
        let landed = walk(w, 0.0, 0.0, 60, pushed);
        Assert.assertEq(expected = (1250, false, 0, true),
            (mm(pushed#feet#x), CharacterBody3d.isOnFloor(pushed), mm(landed#feet#y), CharacterBody3d.isOnFloor(landed)))

    /// 扉の板（蝶番は原点・閉じて x 0..1）を Y まわりに −45° 回すと、対角線の上に立つ体（0.5, 0.5）の真ん中を横切るので、
    /// 回す前の食い込み 0 が、回した後は半径 0.25 になる（回す前と後を比べ、深くなるなら回さない）。
    @Test
    def testDoorSwingPenetrationGrows(): Unit \ Assert =
        let leaf = box(0.5, 1.0, 0.0, 0.5, 1.0, 0.03);
        let capsule = CharacterBody3d.capsuleOf(s(), CharacterBody3d.bodyAt(Vec3.v3(0.5, 0.0, 0.5)));
        let swung = CollisionShape3d.transformBox(Mat4.rotateY(0.0 - rad(45.0)), leaf);
        Assert.assertEq(expected = (0, 250), (mm(CollisionShape3d.penetration(leaf, capsule)), mm(CollisionShape3d.penetration(swung, capsule))))

    // ════════════════════════════════════════════════════════════════════
    // 格子で引く周りの箱
    // ════════════════════════════════════════════════════════════════════

    /// 番号から作った大きさも向きもばらばらの箱 300 個（地面の板を 1 つ混ぜる）。
    def scattered(): List[CollisionShape3d.Box3d] =
        List.range(0, 300) |> List.map(i -> {
            let b = box((Hash01.at(i, 1) - 0.5) * 60.0, 0.0, (Hash01.at(i, 2) - 0.5) * 60.0, 0.1 + Hash01.at(i, 3) * 3.0, 0.5, 0.1 + Hash01.at(i, 4) * 3.0);
            if (i == 150) floor() else CollisionShape3d.transformBox(Mat4.rotateY(Hash01.at(i, 5) * 6.0), b)
        })

    /// 全部の箱を順に見て、水平に囲む範囲が点の周り reach の四角に掛かる物（boxesNear の決まりをそのまま書いた比べる相手）。
    def scanNear(boxes: List[CollisionShape3d.Box3d], p: Vec3.Vec3, reach: Float64): List[CollisionShape3d.Box3d] =
        boxes |> List.filter(b -> {
            let ex = Float64.abs(b#ax#x) * b#half#x + Float64.abs(b#ay#x) * b#half#y + Float64.abs(b#az#x) * b#half#z;
            let ez = Float64.abs(b#ax#z) * b#half#x + Float64.abs(b#ay#z) * b#half#y + Float64.abs(b#az#z) * b#half#z;
            Float64.abs(b#center#x - p#x) <= ex + reach and Float64.abs(b#center#z - p#z) <= ez + reach
        })

    def centers(boxes: List[CollisionShape3d.Box3d]): List[(Int32, Int32)] = boxes |> List.map(b -> (mm(b#center#x), mm(b#center#z)))

    /// 60 か所・届く距離 0〜6 m で、格子で引いた箱が全部の箱を順に見て絞った物と並びまで同じ（1 マス 2 m）。
    @Test
    def testBoxesNearMatchesFullScanIncludingOrder(): Unit \ Assert =
        let boxes = scattered();
        let w = CollisionWorld3d.build(2.0, boxes);
        let points = List.range(0, 60) |> List.map(k -> (Vec3.v3((Hash01.at(k, 7) - 0.5) * 70.0, 0.0, (Hash01.at(k, 8) - 0.5) * 70.0), Hash01.at(k, 9) * 6.0));
        Assert.assertEq(expected = points |> List.map(e -> centers(scanNear(boxes, fst(e), snd(e)))),
                        points |> List.map(e -> centers(CollisionWorld3d.boxesNear(w, fst(e), snd(e)))))

    /// 全部の箱のうち、真ん中の高さで点から水平に reach の中に触れる箱（closestPoint の距離で見る）は、格子で引いた物に必ず入っている。
    @Test
    def testBoxesNearIncludesEveryTouchingBox(): Unit \ Assert =
        let boxes = scattered();
        let w = CollisionWorld3d.build(2.0, boxes);
        let missing = List.range(0, 60) |> List.flatMap(k -> {
            let p = Vec3.v3((Hash01.at(k, 7) - 0.5) * 70.0, 0.0, (Hash01.at(k, 8) - 0.5) * 70.0);
            let reach = Hash01.at(k, 9) * 6.0;
            let found = centers(CollisionWorld3d.boxesNear(w, p, reach)) |> List.toSet;
            boxes |> List.filter(b -> Vec3.length(Vec3.sub(CollisionShape3d.closestPoint(b, Vec3.v3(p#x, b#center#y, p#z)), Vec3.v3(p#x, b#center#y, p#z))) <= reach)
                  |> centers |> List.filter(c -> not Set.memberOf(c, found))
        });
        Assert.assertEq(expected = Nil, missing)

    // ════════════════════════════════════════════════════════════════════
    // 部屋をたくさん歩く
    // ════════════════════════════════════════════════════════════════════

    /// 10 m 四方の部屋（厚さ 1 m の外壁）・薄い壁（2 cm）で閉じた物置（x 1..3・z −3..−1）・
    /// 35° の階段の板と横の手すり・Y まわりに回した柱・低い段。
    def room(): List[CollisionShape3d.Box3d] =
        let wall = (cx: Float64, cz: Float64, hx: Float64, hz: Float64) -> box(cx, 1.5, cz, hx, 1.5, hz);
        let thin = 0.01;
        let stair = CollisionShape3d.transformBox(Mat4.mul(Mat4.translate(Vec3.v3(-3.5, 1.0, 1.5)), Mat4.rotateX(0.0 - rad(35.0))), box(0.0, 0.0, 0.0, 0.6, 0.05, 1.8));
        let rail = CollisionShape3d.transformBox(Mat4.mul(Mat4.translate(Vec3.v3(-2.85, 1.5, 1.5)), Mat4.rotateX(0.0 - rad(35.0))), box(0.0, 0.0, 0.0, 0.03, 0.5, 1.8));
        let pillar = CollisionShape3d.transformBox(Mat4.mul(Mat4.translate(Vec3.v3(2.0, 1.5, 2.5)), Mat4.rotateY(0.5)), box(0.0, 0.0, 0.0, 0.3, 1.5, 0.3));
        wall(0.0, 5.5, 6.5, 0.5) :: wall(0.0, -5.5, 6.5, 0.5) :: wall(5.5, 0.0, 0.5, 6.5) :: wall(-5.5, 0.0, 0.5, 6.5)
            :: wall(1.0, -2.0, thin, 1.0) :: wall(3.0, -2.0, thin, 1.0) :: wall(2.0, -1.0, 1.0, thin) :: wall(2.0, -3.0, 1.0, thin)
            :: stair :: rail :: pillar :: box(-1.0, 0.1, -3.5, 1.0, 0.1, 1.0) :: Nil

    /// 物置の中（薄い壁の内側）か。
    def insideCloset(b: CharacterBody3d.Body): Bool = b#feet#x > 1.0 and b#feet#x < 3.0 and b#feet#z > -3.0 and b#feet#z < -1.0

    /// 部屋の外（外壁の向こう）か。
    def outsideRoom(b: CharacterBody3d.Body): Bool = Float64.abs(b#feet#x) > 5.0 or Float64.abs(b#feet#z) > 5.0

    /// 1 つの場合: 名前・始まりの足元 (x, z)・歩く向き（ラジアン）・速さ（m/秒）・1 コマの秒・何コマ。
    type alias Case = { name = String, x = Float64, z = Float64, heading = Float64, speed = Float64, dt = Float64, frames = Int32 }

    /// 1 つの場合を歩かせ、どこかのコマで 2 cm より深く食い込んだか、物置に入ったか部屋を出たら、その名前。
    def failure(w: CollisionWorld3d.CollisionWorld3d, c: Case): Option[String] =
        let start = standAt(w, c#x, 0.0, c#z);
        let path = CharacterBody3d.simulate(w, Nil, s(), Vec3.v3(c#speed * Num.sin(c#heading), 0.0, c#speed * Num.cos(c#heading)), c#dt, c#frames, start);
        let deepest = path |> List.map(b -> CharacterBody3d.overlapDepth(w, Nil, s(), b)) |> List.foldLeft(Float64.max, 0.0);
        if (deepest > 0.02 or List.exists(b -> insideCloset(b) or outsideRoom(b), path)) Some("${c#name} (食い込み ${Float64.toString(deepest)} m)") else None

    /// 必ず入れる場合: 薄い壁へ正面・斜め・物置の角・外壁の角・手すり・階段の板の低い端の下・柱の角・1 コマ 0.05 秒で 6 m/秒。
    def edges(): List[Case] =
        let dash = (name: String, x: Float64, z: Float64, deg: Float64) -> { name = name, x = x, z = z, heading = rad(deg), speed = 6.0, dt = 0.05, frames = 40 };
        dash("closet wall head-on", -1.0, -2.0, 90.0) :: dash("closet wall glancing", -1.0, -2.5, 75.0)
            :: dash("closet corner", 0.0, 0.0, 135.0) :: dash("closet far corner", 4.0, -4.0, -45.0)
            :: dash("room corner", 3.0, 3.0, 45.0) :: dash("room corner west", -3.0, -3.0, -135.0)
            :: dash("stair rail side", -1.5, 1.5, -90.0) :: dash("under stair low end", -3.5, 4.5, 180.0)
            :: dash("stair up", -3.5, -0.8, 0.0) :: dash("stair wall side", -4.6, 0.0, 0.0)
            :: dash("pillar corner", 0.5, 2.5, 90.0) :: dash("low step edge", -1.0, -1.0, 180.0)
            :: dash("closet seam", 2.0, 0.5, 180.0) :: dash("closet seam corner", 1.0, -0.5, 180.0) :: Nil

    /// 始まりに置けない所（物置・階段の板の下・柱）か。置けない所の場合は部屋の真ん中から歩かせる。
    def isBlockedStart(x: Float64, z: Float64): Bool =
        (x > 0.6 and x < 3.4 and z > -3.4 and z < -0.6) or (x < -2.3 and z > -0.3 and z < 3.3) or (Float64.abs(x - 2.0) < 0.8 and Float64.abs(z - 2.5) < 0.8)

    /// 番号の乱数で作った n 個の場合（部屋の中の置ける所から、向き・速さ（1〜6 m/秒）・刻み 1/60 か 0.05 秒を振る）。
    def randomCases(n: Int32): List[Case] =
        List.range(0, n) |> List.map(i -> {
            let x0 = (Hash01.at(i, 11) - 0.5) * 8.6;
            let z0 = (Hash01.at(i, 12) - 0.5) * 8.6;
            let (x, z) = if (isBlockedStart(x0, z0)) (0.0, 0.0) else (x0, z0);
            let fast = Hash01.at(i, 14) < 0.3;
            { name = "random-${Int32.toString(i)}", x = x, z = z, heading = Hash01.at(i, 13) * Num.tau(),
              speed = 1.0 + Hash01.at(i, 15) * 5.0, dt = if (fast) 0.05 else 1.0 / 60.0, frames = 60 }
        })

    /// 決まった 14 の場合と番号の乱数で作った 300 の場合で、どのコマでも食い込まず（2 cm 以下）、薄い壁の物置にも外壁の外にも出ない。
    @Test
    def testRoomWalksNeverPenetrate(): Unit \ Assert =
        let w = worldOf(room());
        Assert.assertEq(expected = Nil, List.append(edges(), randomCases(300)) |> List.filterMap(failure(w)))
}
