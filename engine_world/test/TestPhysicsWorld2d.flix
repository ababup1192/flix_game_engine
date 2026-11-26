// PhysicsWorld2d（2D の剛体の物理）: 決定性・積み重ね・眠り・出来事・sensor・kinematic・光線

mod TestPhysicsWorld2d {

    def dt(): Float64 = 1.0 / 60.0

    def emptyWorld(): PhysicsWorld2d.PhysicsWorld2d = PhysicsWorld2d.empty(PhysicsWorld2d.settings(), dt())

    /// 床（上の面が y = 0）と左右の壁。id 1〜3。
    def withJar(w: PhysicsWorld2d.PhysicsWorld2d): PhysicsWorld2d.PhysicsWorld2d =
        w |> PhysicsWorld2d.insert(1, RigidBody2d.fixed({ x = 0.0, y = 0.5 }, Collider2d.box(11.7, 0.5)))
          |> PhysicsWorld2d.insert(2, RigidBody2d.fixed({ x = -12.2, y = -10.0 }, Collider2d.box(0.5, 10.0)))
          |> PhysicsWorld2d.insert(3, RigidBody2d.fixed({ x = 12.2, y = -10.0 }, Collider2d.box(0.5, 10.0)))

    /// 正六角形（頂点を左右に置く。√3 は平方根で作る）。
    def hexagon(radius: Float64): Collider2d.Collider2d =
        let h = radius * PortableMath.sqrt(3.0) / 2.0;
        let half = radius / 2.0;
        Collider2d.convex(List#{{ x = radius, y = 0.0 }, { x = half, y = h }, { x = -half, y = h },
                                { x = -radius, y = 0.0 }, { x = -half, y = -h }, { x = half, y = -h }})

    /// 番号 k の物（7 つに 4 つが円・2 つが六角形・1 つが箱。大きさは番号から決める）。
    def pieceOf(k: Int32): RigidBody2d.RigidBody2d =
        let size = 0.16 + Int32.toFloat64(Int32.modulo(k * 7, 11)) * 0.01;
        let col = Int32.modulo(k, 40);
        let row = k / 40;
        let pos = { x = -9.75 + Int32.toFloat64(col) * 0.5, y = -1.0 - Int32.toFloat64(row) * 0.55 };
        let kind = Int32.modulo(k, 7);
        let collider = if (kind < 4) Collider2d.circle(size) else if (kind < 6) hexagon(size) else Collider2d.box(size, size);
        RigidBody2d.dynamic(pos, collider)

    /// 物 n 個の場面（id 10 から順）。
    def pile(n: Int32): PhysicsWorld2d.PhysicsWorld2d =
        List.range(0, n) |> List.foldLeft((w, k) -> PhysicsWorld2d.insert(10 + k, pieceOf(k), w), withJar(emptyWorld()))

    def advance(steps: Int32, w: PhysicsWorld2d.PhysicsWorld2d): PhysicsWorld2d.PhysicsWorld2d =
        if (steps <= 0) w else advance(steps - 1, PhysicsWorld2d.step(w))

    /// 毎刻みの出来事を集めながら進める（新しい順）。
    def advanceCollecting(steps: Int32, w: PhysicsWorld2d.PhysicsWorld2d, acc: List[PhysicsWorld2d.Events]): (PhysicsWorld2d.PhysicsWorld2d, List[PhysicsWorld2d.Events]) =
        if (steps <= 0) (w, acc)
        else {
            let next = PhysicsWorld2d.step(w);
            advanceCollecting(steps - 1, next, PhysicsWorld2d.events(next) :: acc)
        }

    def collisionsOf(evs: List[PhysicsWorld2d.Events]): List[CollisionEvent2d.CollisionEvent2d] =
        evs |> List.reverse |> List.flatMap(e -> e#collisions)

    def sensorsOf(evs: List[PhysicsWorld2d.Events]): List[SensorEvent2d.SensorEvent2d] =
        evs |> List.reverse |> List.flatMap(e -> e#sensors)

    // ── 決定性 ──

    /// 同じ場面を 2 回流すと 300 刻みの後の指紋が同じ
    @Test
    def testSameInputSameHash(): Unit \ Assert =
        Assert.assertEq(expected = PhysicsWorld2d.stateHash(advance(300, pile(60))), PhysicsWorld2d.stateHash(advance(300, pile(60))))

    /// 体を足す順を逆にしても 300 刻みの後の指紋が同じ
    @Test
    def testInsertOrderDoesNotMatter(): Unit \ Assert =
        let backward = List.range(0, 60) |> List.reverse |> List.foldLeft((w, k) -> PhysicsWorld2d.insert(10 + k, pieceOf(k), w), emptyWorld()) |> withJar;
        Assert.assertEq(expected = PhysicsWorld2d.stateHash(advance(300, pile(60))), PhysicsWorld2d.stateHash(advance(300, backward)))

    /// 100 刻み目の World を取っておき、そこから流し直すと同じ指紋になる（巻き戻し）
    @Test
    def testRewindReplaysSameHash(): Unit \ Assert =
        let saved = advance(100, pile(60));
        let first = advance(200, saved);
        let again = advance(200, saved);
        Assert.assertEq(expected = PhysicsWorld2d.stateHash(first), PhysicsWorld2d.stateHash(again))

    /// 物 100 個・600 刻みの指紋は基準の値（JVM と wasm の比べの元。ソルバーを替えたら撮り直す）
    @Test
    def testReferenceHash100(): Unit \ Assert =
        Assert.assertEq(expected = referenceHash100(), PhysicsWorld2d.stateHash(advance(600, pile(100))))

    def referenceHash100(): Int64 = 2064364921975254338i64

    // ── 積み重ね・眠り・跳ね返り ──

    /// 一辺 0.5 m の箱 12 個の塔は 600 刻みの後も立っている（横のずれ 5 cm 未満・上の箱の中心は理想の 5.75 m から 20 cm 以内）
    @Test
    def testTowerStands(): Unit \ Assert =
        let tower = List.range(0, 12) |> List.foldLeft((w, k) ->
            PhysicsWorld2d.insert(10 + k, RigidBody2d.dynamic({ x = 0.0, y = -0.25 - 0.5 * Int32.toFloat64(k) }, Collider2d.box(0.25, 0.25)), w), withJar(emptyWorld()));
        let after = advance(600, tower);
        let drift = List.range(0, 12) |> List.foldLeft((acc, k) ->
            Float64.max(acc, PhysicsWorld2d.positionOf(10 + k, after) |> Option.map(p -> Float64.abs(p#x)) |> Option.getWithDefault(99.0)), 0.0);
        let topY = PhysicsWorld2d.positionOf(21, after) |> Option.map(p -> p#y) |> Option.getWithDefault(0.0);
        Assert.assertTrue(drift < 0.05 and topY < -5.55 and topY > -5.95)

    /// 物 100 個は 60 秒（3,600 刻み）の中で全部眠る（しきい 0.01 m/s では、山の端の転がる円が止まるまでかかる）
    @Test
    def testPileFallsAsleep(): Unit \ Assert =
        Assert.assertEq(expected = 0, PhysicsWorld2d.awakeCount(advance(3600, pile(100))))

    /// 跳ね返り 0.8 の球を 2 m から落とすと、最初に跳ねた頂点は 0.5 m より高く 2 m より低い
    @Test
    def testBallBounces(): Unit \ Assert =
        let w0 = withJar(emptyWorld())
            |> PhysicsWorld2d.withMaterials(Map#{"rubber" => { friction = 0.5, restitution = 0.8, density = 1.0 }})
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -2.2 }, Collider2d.circle(0.2) |> Collider2d.withMaterial("rubber")));
        let (_, peak, _) = List.range(0, 150) |> List.foldLeft((acc, _) -> {
            let (w, best, bounced) = acc;
            let next = PhysicsWorld2d.step(w);
            let vy = PhysicsWorld2d.linearVelocityOf(10, next) |> Option.map(v -> v#y) |> Option.getWithDefault(0.0);
            let y = PhysicsWorld2d.positionOf(10, next) |> Option.map(p -> p#y) |> Option.getWithDefault(0.0);
            let nowBounced = bounced or vy < -0.5;
            (next, if (nowBounced) Float64.min(best, y) else best, nowBounced)
        }, (w0, 0.0, false));
        let height = -peak - 0.2;
        Assert.assertTrue(height > 0.5 and height < 2.0)

    /// 摩擦 0 の箱を横に押すと滑り続ける（10 刻みの後も速さの 9 割が残る）
    @Test
    def testFrictionlessBoxSlides(): Unit \ Assert =
        let ice = { friction = 0.0, restitution = 0.0, density = 1.0 };
        let w0 = emptyWorld()
            |> PhysicsWorld2d.withMaterials(Map#{"ice" => ice})
            |> PhysicsWorld2d.insert(1, RigidBody2d.fixed({ x = 0.0, y = 0.5 }, Collider2d.box(50.0, 0.5) |> Collider2d.withMaterial("ice")))
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.25 }, Collider2d.box(0.25, 0.25) |> Collider2d.withMaterial("ice"))
                                         |> RigidBody2d.withLinearVelocity({ x = 2.0, y = 0.0 }));
        let vx = advance(10, w0) |> PhysicsWorld2d.linearVelocityOf(10) |> Option.map(v -> v#x) |> Option.getWithDefault(0.0);
        Assert.assertTrue(vx > 1.8)

    /// withMass は重さを直に決める（同じ衝撃で、重さ 2 kg の箱は速さ 1 m/s 増える）
    @Test
    def testWithMassSetsMass(): Unit \ Assert =
        let w = PhysicsWorld2d.empty({ gravity = Vec2.zero() | PhysicsWorld2d.settings() }, dt())
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic(Vec2.zero(), Collider2d.box(0.5, 0.5) |> Collider2d.withMass(2.0)))
            |> PhysicsWorld2d.applyImpulse(10, { x = 2.0, y = 0.0 });
        Assert.assertEq(expected = Some(1.0), PhysicsWorld2d.linearVelocityOf(10, w) |> Option.map(v -> v#x))

    // ── 出来事 ──

    /// 床に落とした球は Started を 1 回だけ出す（2 秒の間）
    @Test
    def testDropStartsOnce(): Unit \ Assert =
        let w0 = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -1.0 }, Collider2d.circle(0.2)));
        let (_, evs) = advanceCollecting(120, w0, Nil);
        Assert.assertEq(expected = (1, 10) :: Nil, collisionsOf(evs) |> List.filterMap(CollisionEvent2d.startedPair))

    /// 床に載った球を消すと、次の刻みに removed = true の Stopped が出る
    @Test
    def testRemoveStopsWithRemovedFlag(): Unit \ Assert =
        let w0 = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.5 }, Collider2d.circle(0.2)));
        let resting = advance(60, w0);
        let after = PhysicsWorld2d.step(PhysicsWorld2d.remove(10, resting));
        Assert.assertEq(expected = CollisionEvent2d.CollisionEvent2d.Stopped(1, 10, true) :: Nil, PhysicsWorld2d.events(after)#collisions)

    /// 跳ね上げて床から離れた球は removed = false の Stopped を出す
    @Test
    def testLiftOffStops(): Unit \ Assert =
        let w0 = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.5 }, Collider2d.circle(0.2)));
        let launched = advance(60, w0) |> PhysicsWorld2d.setLinearVelocity(10, { x = 0.0, y = -5.0 });
        let (_, evs) = advanceCollecting(10, launched, Nil);
        Assert.assertTrue(collisionsOf(evs) |> List.exists(e -> e == CollisionEvent2d.CollisionEvent2d.Stopped(1, 10, false)))

    /// 床で眠った球は Stopped を出さない（触れたままと見る）
    @Test
    def testSleepingKeepsTouching(): Unit \ Assert =
        let w0 = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.5 }, Collider2d.circle(0.2)));
        let (w, evs) = advanceCollecting(300, w0, Nil);
        Assert.assertTrue(PhysicsWorld2d.isSleeping(10, w) and List.isEmpty(collisionsOf(evs) |> List.filterMap(CollisionEvent2d.stoppedPair)))

    /// sensor の箱の中を落ちていく球は Started と Stopped を 1 回ずつ出す（sensor が先・押し返さない）
    @Test
    def testSensorEntersAndLeaves(): Unit \ Assert =
        let w0 = withJar(emptyWorld())
            |> PhysicsWorld2d.insert(5, RigidBody2d.fixed({ x = 0.0, y = -3.0 }, Collider2d.box(1.0, 0.5) |> Collider2d.withSensor(true)))
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -5.0 }, Collider2d.circle(0.2)));
        let (_, evs) = advanceCollecting(90, w0, Nil);
        Assert.assertEq(expected = SensorEvent2d.SensorEvent2d.Started(5, 10) :: SensorEvent2d.SensorEvent2d.Stopped(5, 10, false) :: Nil, sensorsOf(evs))

    /// 当たり層が重ならない球は床をすり抜ける
    @Test
    def testCollisionLayersFilter(): Unit \ Assert =
        let w0 = withJar(emptyWorld())
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.5 }, Collider2d.circle(0.2) |> Collider2d.withCollisionLayers(2, 2)));
        let y = advance(60, w0) |> PhysicsWorld2d.positionOf(10) |> Option.map(p -> p#y) |> Option.getWithDefault(0.0);
        Assert.assertTrue(y > 1.0)

    // ── kinematic・外から動かす ──

    /// 毎刻み右へ動かす kinematic の箱は、眠った箱を押して起こす
    @Test
    def testKinematicPushesSleepingBody(): Unit \ Assert =
        let w0 = withJar(emptyWorld())
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.25 }, Collider2d.box(0.25, 0.25)))
            |> PhysicsWorld2d.insert(11, RigidBody2d.kinematic({ x = -1.0, y = -0.3 }, Collider2d.box(0.25, 0.25)));
        let asleep = advance(120, w0);
        let pushed = List.range(1, 61) |> List.foldLeft((w, k) ->
            PhysicsWorld2d.step(PhysicsWorld2d.setKinematicTarget(11, { x = -1.0 + 0.03 * Int32.toFloat64(k), y = -0.3 }, Rot2.identity(), w)), asleep);
        let x = PhysicsWorld2d.positionOf(10, pushed) |> Option.map(p -> p#x) |> Option.getWithDefault(0.0);
        Assert.assertTrue(PhysicsWorld2d.isSleeping(10, asleep) and x > 0.5)

    /// setKinematicTarget の次の刻みで、kinematic の体はちょうど目標に居る
    @Test
    def testKinematicReachesTarget(): Unit \ Assert =
        let w = emptyWorld()
            |> PhysicsWorld2d.insert(11, RigidBody2d.kinematic(Vec2.zero(), Collider2d.circle(0.2)))
            |> PhysicsWorld2d.setKinematicTarget(11, { x = 0.3, y = -0.1 }, Rot2.identity())
            |> PhysicsWorld2d.step;
        Assert.assertEq(expected = Some((0.3, -0.1)), PhysicsWorld2d.positionOf(11, w) |> Option.map(p -> (p#x, p#y)))


    /// setPosition は補間の前の姿勢もそろえる（alpha 0 でも新しい位置）
    @Test
    def testSetPositionResetsInterpolation(): Unit \ Assert =
        let w = emptyWorld()
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic(Vec2.zero(), Collider2d.circle(0.2)))
            |> PhysicsWorld2d.setPosition(10, { x = 4.0, y = 1.0 }, Rot2.identity());
        Assert.assertEq(expected = Some((4.0, 1.0)), PhysicsWorld2d.interpolatedPoseOf(10, 0.0, w) |> Option.map(p -> (p#position#x, p#position#y)))

    // ── 光線と点 ──

    /// 上から下へ飛ばした光線は床の上の面（y = 0）に当たる
    @Test
    def testCastRayHitsFloor(): Unit \ Assert =
        let hit = PhysicsWorld2d.castRay({ x = 0.0, y = -5.0 }, { x = 0.0, y = 1.0 }, 20.0, -1, withJar(emptyWorld()));
        Assert.assertEq(expected = Some((1, 5.0)), hit |> Option.map(h -> (h#id, h#distance)))

    /// 光線は手前の円に先に当たる
    @Test
    def testCastRayHitsNearestFirst(): Unit \ Assert =
        let w = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.fixed({ x = 0.0, y = -2.0 }, Collider2d.circle(0.5)));
        let hit = PhysicsWorld2d.castRay({ x = 0.0, y = -5.0 }, { x = 0.0, y = 1.0 }, 20.0, -1, w);
        Assert.assertEq(expected = Some(10), hit |> Option.map(h -> h#id))

    /// 点を含む体を id の順に返す
    @Test
    def testQueryPoint(): Unit \ Assert =
        let w = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.fixed({ x = 0.0, y = 0.2 }, Collider2d.circle(0.5)));
        Assert.assertEq(expected = 1 :: 10 :: Nil, PhysicsWorld2d.queryPoint({ x = 0.1, y = 0.3 }, -1, w))

    /// 光線は当たり層の mask に入らない形を的にしない
    @Test
    def testCastRaySkipsMaskedLayer(): Unit \ Assert =
        let w = withJar(emptyWorld()) |> PhysicsWorld2d.insert(10, RigidBody2d.fixed({ x = 0.0, y = -2.0 }, Collider2d.circle(0.5) |> Collider2d.withCollisionLayers(4, -1)));
        let hit = PhysicsWorld2d.castRay({ x = 0.0, y = -5.0 }, { x = 0.0, y = 1.0 }, 20.0, 1, w);
        Assert.assertEq(expected = Some(1), hit |> Option.map(h -> h#id))

    // ── 材質と Doc ──

    /// 材質の表を差し替えると、もう居る体の摩擦も次の刻みから変わる（摩擦 0 で滑っていた箱が止まる）
    @Test
    def testWithMaterialsAppliesToExistingBodies(): Unit \ Assert =
        let ice = { friction = 0.0, restitution = 0.0, density = 1.0 };
        let w0 = emptyWorld()
            |> PhysicsWorld2d.withMaterials(Map#{"floor" => ice})
            |> PhysicsWorld2d.insert(1, RigidBody2d.fixed({ x = 0.0, y = 0.5 }, Collider2d.box(50.0, 0.5) |> Collider2d.withMaterial("floor")))
            |> PhysicsWorld2d.insert(10, RigidBody2d.dynamic({ x = 0.0, y = -0.25 }, Collider2d.box(0.25, 0.25) |> Collider2d.withMaterial("floor"))
                                         |> RigidBody2d.withLinearVelocity({ x = 2.0, y = 0.0 }));
        let rough = advance(5, w0) |> PhysicsWorld2d.withMaterials(Map#{"floor" => { friction = 1.0 | ice }}) |> advance(60);
        let vx = PhysicsWorld2d.linearVelocityOf(10, rough) |> Option.map(v -> Float64.abs(v#x)) |> Option.getWithDefault(9.0);
        Assert.assertTrue(vx < 0.01)

    /// Doc の材質と world の欄を読む
    @Test
    def testDocParsesMaterialsAndWorld(): Unit \ Assert =
        let text = "{\"version\": 1, \"world\": {\"gravity\": [0, 5], \"solverSubsteps\": 2}, \"materials\": {\"stone\": {\"friction\": 0.6, \"restitution\": 0.1, \"density\": 2.0}}}";
        let doc = DocJson.parse(text) |> Option.flatMap(j -> PhysicsDoc2d.parse(j) |> Result.toOption);
        Assert.assertEq(expected = Some((5.0, 2, Some(2.0))),
                        doc |> Option.map(d -> (d#settings#gravity#y, d#settings#solverSubsteps, Map.get("stone", d#materials) |> Option.map(m -> m#density))))

    /// 密度 0 の材質は Err
    @Test
    def testDocRejectsZeroDensity(): Unit \ Assert =
        let text = "{\"materials\": {\"foam\": {\"friction\": 0.6, \"restitution\": 0.1, \"density\": 0}}}";
        let parsed = DocJson.parse(text) |> Option.map(j -> PhysicsDoc2d.parse(j) |> Result.isErr);
        Assert.assertEq(expected = Some(true), parsed)

    /// world を省いた Doc は既定の設定
    @Test
    def testDocWithoutWorldKeepsDefaults(): Unit \ Assert =
        let doc = DocJson.parse("{}") |> Option.flatMap(j -> PhysicsDoc2d.parse(j) |> Result.toOption);
        Assert.assertEq(expected = Some(4), doc |> Option.map(d -> d#settings#solverSubsteps))
}
