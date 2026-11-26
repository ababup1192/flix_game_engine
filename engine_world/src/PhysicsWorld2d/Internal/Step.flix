// PhysicsWorld2d.Internal.Step — 1 刻みの中身。体の欄を Float64 の 1 本の配列へ詰め、region の中で書き換えて回し、最後に Vector へ戻す。
// 順: 詰める → 体ごとの AABB → x の左端で並べて掃く（sort and sweep）→ 細かい当たり → 島を起こす → 解く → 眠り → 出来事の差分。
// 決まり: 回る順は id の順（体は id の順に並んでいる）・並べ替えは安定な物か long の並べ替えだけ・三角関数を使わない。ゲームからは呼ばない。
pub mod PhysicsWorld2d.Internal.Step {
    use PhysicsWorld2d.Internal.Data.Data
    use PhysicsWorld2d.Internal.Data.Events
    use PhysicsWorld2d.Internal.Solver.Point
    use PhysicsWorld2d.Internal.Solver.Solve
    use PhysicsWorld2d.Internal.Narrowphase.WorldPolygon
    use PhysicsWorld2d.Internal.Shape.Shape
    import java.util.Arrays

    def bStride(): Int32 = PhysicsWorld2d.Internal.Solver.bStride()
    def stateStride(): Int32 = PhysicsWorld2d.Internal.Data.stateStride()
    def propStride(): Int32 = PhysicsWorld2d.Internal.Data.propStride()
    def margin(): Float64 = PhysicsWorld2d.Internal.Narrowphase.margin()
    def sleepAfter(): Float64 = 0.5

    /// 当たり始めとみなす離れ（食い込みを許す幅 slop の 2 倍）・離れたとみなす離れ（接触の点を作る余白）。
    // WhyNot: 2 つを同じ値にしない — 触れたり離れたりの境目で Started と Stopped が毎刻み交互に出る。
    def startDistance(): Float64 = 2.0 * PhysicsWorld2d.Internal.Solver.slop()
    def stopDistance(): Float64 = margin()

    /// 1 刻み進めた中身と、NaN・無限大になった体の id（呼ぶ側が消す）。出来事は d#pending の後ろに足して events に置く。
    pub def step(d: Data): (Data, List[Int32]) =
        if (isAtRest(d)) (restingStep(d), Nil) else movingStep(d)

    /// どの体も動かない（Dynamic は全部眠り・Kinematic は止まっていて目標も無い）か。
    def isAtRest(d: Data): Bool =
        let ss = stateStride();
        Map.isEmpty(d#targets) and Vector.range(0, Vector.length(d#ids)) |> Vector.forAll(i -> match Vector.get(i, d#types) {
            case RigidBody2d.BodyType.Dynamic => Vector.get(i, d#asleep)
            case RigidBody2d.BodyType.Kinematic =>
                Vector.get(i * ss + 4, d#state) == 0.0 and Vector.get(i * ss + 5, d#state) == 0.0 and Vector.get(i * ss + 6, d#state) == 0.0
            case RigidBody2d.BodyType.Fixed => true
        })

    /// 動かない刻み: 当たりも解き手も回さず、前の姿勢を今の姿勢にそろえ、消した体の出来事だけを出す（組と控えはそのまま続く）。
    // WhyNot: 眠った体だけの刻みでも全部を詰めて掃かない — 眠った物 1,000 個で 1 刻み 1 ms かかり、予算（0.2 ms）を超えた。
    def restingStep(d: Data): Data =
        let ss = stateStride();
        let earlier = d#pending |> List.reverse;
        let prev = Vector.range(0, Vector.length(d#ids) * 4) |> Vector.map(k -> Vector.get((k / 4) * ss + Int32.modulo(k, 4), d#state));
        { prev = prev, events = { collisions = List.flatMap(e -> e#collisions, earlier), sensors = List.flatMap(e -> e#sensors, earlier) },
          pending = Nil, steps = d#steps + 1i64 | d }

    def movingStep(d: Data): (Data, List[Int32]) = region rc {
        let n = Vector.length(d#ids);
        let dt = d#stepSeconds;
        let bs = Array.repeat(rc, n * bStride(), 0.0);
        let dyn = Array.repeat(rc, n, false);
        let kin = Array.repeat(rc, n, false);
        let kinMoving = Array.repeat(rc, n, false);
        let asleep = Array.repeat(rc, n, false);
        let woken = Array.repeat(rc, n, false);
        let touchWake = Array.repeat(rc, n, false);
        packAll(d, (bs, dyn, kin, kinMoving, asleep), n);
        let polys = Vector.mapWithIndex((i, shape) -> PhysicsWorld2d.Internal.Narrowphase.worldPolygonOf(shape, poseOf(bs, i)), d#shapes);
        let box = Array.repeat(rc, n * 4, 0.0);
        Vector.forEachWithIndex((i, poly) -> fillBox(bs, box, i, poly), polys);
        let order = sortedByLeft(rc, box, n);
        let parent = Array.repeat(rc, n, 0);
        fillIdentity(parent, 0, n);
        let out = { points = MutList.empty(rc), manifolds = MutList.empty(rc), contactSeps = MutList.empty(rc),
                    kept = MutList.empty(rc), sensed = MutList.empty(rc), keptSensed = MutList.empty(rc) };
        let (bits, layer, mask) = flagsOf(rc, d, (dyn, kin, kinMoving, asleep), n);
        sweepEach((bits, layer, mask, bs, parent, touchWake, d#shapes, polys, d#ids, out), order, box, 0, n);
        wakeIslands(rc, (dyn, asleep, woken, touchWake, bs, parent), n);
        let pts = MutList.toVector(out#points);
        let manifolds = MutList.toVector(out#manifolds);
        let pab = Array.repeat(rc, Vector.length(pts) * 2, 0);
        let sv: Solve[_] = { bs = bs, dyn = dyn, kin = kin, asleep = asleep, woken = woken, pab = pab, n = n };
        let s = d#settings;
        let impulses = PhysicsWorld2d.Internal.Solver.solveStep(rc, sv, pts, d#warm,
            { dt = dt, gx = s#gravity#x, gy = s#gravity#y, substeps = Int32.max(1, s#solverSubsteps) });
        updateTimers(sv, { dt = dt, linear = s#sleepLinearThreshold, angular = s#sleepAngularThreshold });
        sleepIslands(rc, sv, parent);
        snapKinematic(d, bs, kin, 0, n);
        let keptSorted = PhysicsWorld2d.Internal.Solver.sortedKeys(rc, MutList.toVector(out#kept));
        let fresh = PhysicsWorld2d.Internal.Solver.warmOf(rc, pts, manifolds, impulses);
        let (freshKeys, _, _, _) = fresh;
        let warm = keepRestingWarm(rc, fresh, d#warm, keptSorted);
        let broken = List.range(0, n) |> List.filter(i -> not isFinitePose(bs, i)) |> List.map(i -> Vector.get(i, d#ids));
        let next = Array.repeat(rc, n * stateStride(), 0.0);
        let prev = Array.repeat(rc, n * 4, 0.0);
        unpackAll(bs, next, prev, 0, n);
        let (touching, collisions) = diffTouching(rc, d#touching, freshKeys, MutList.toVector(out#contactSeps), keptSorted);
        let (sensing, sensors) = diffSensing(rc, d, MutList.toVector(out#sensed), MutList.toVector(out#keptSensed));
        let earlier = d#pending |> List.reverse;
        let events = { collisions = List.append(List.flatMap(e -> e#collisions, earlier), collisions),
                       sensors = List.append(List.flatMap(e -> e#sensors, earlier), sensors) };
        ({ state = Array.toVector(next), prev = Array.toVector(prev), asleep = Array.toVector(asleep), warm = warm,
           touching = touching, sensing = sensing, events = events, pending = Nil, targets = Map.empty(), steps = d#steps + 1i64 | d },
         broken)
    }

    /// 体ごとの印（Dynamic・Kinematic・動く Kinematic・眠り・sensor）・当たり層・mask。
    def flagsOf(rc: Region[r], d: Data, kinds: (Array[Bool, r], Array[Bool, r], Array[Bool, r], Array[Bool, r]),
                n: Int32): (Array[Int32, r], Array[Int32, r], Array[Int32, r]) \ r =
        let (dyn, kin, kinMoving, asleep) = kinds;
        let bits = Array.repeat(rc, n, 0);
        let layer = Array.repeat(rc, n, 0);
        let mask = Array.repeat(rc, n, 0);
        let bit = (on, b) -> if (on) b else 0;
        Vector.forEachWithIndex((i, c) -> {
            Array.put(bit(Array.get(i, dyn), bitDyn()) + bit(Array.get(i, kin), bitKin()) + bit(Array.get(i, kinMoving), bitKinMoving())
                      + bit(Array.get(i, asleep), bitAsleep()) + bit(Collider2d.isSensor(c), bitSensor()), i, bits);
            Array.put(Collider2d.collisionLayer(c), i, layer);
            Array.put(Collider2d.collisionMask(c), i, mask)
        }, d#colliders);
        (bits, layer, mask)

    /// 詰める先（体の欄・Dynamic か・Kinematic か・動く Kinematic か・眠り）。
    type alias Pack[r: Region] = (Array[Float64, r], Array[Bool, r], Array[Bool, r], Array[Bool, r], Array[Bool, r])

    // WhyNot: 体ごとに d#… を引かない — record の欄は名前で探すので、体の数 × 欄の数だけ重さが乗る。欄は輪の外で 1 回だけ取り出す。
    def packAll(d: Data, pk: Pack[r], n: Int32): Unit \ r =
        let friction = Vector.map(m -> m#friction, d#materials);
        let restitution = Vector.map(m -> m#restitution, d#materials);
        let src = (d#state, d#props, d#asleep, d#types, d#materialIndex, friction, restitution);
        List.range(0, n) |> List.forEach(i -> packOne(d, src, pk, i))

    def packOne(d: Data, src: (Vector[Float64], Vector[Float64], Vector[Bool], Vector[RigidBody2d.BodyType], Vector[Int32], Vector[Float64], Vector[Float64]),
                pk: Pack[r], i: Int32): Unit \ r =
        let (state, props, sleepingAll, types, materialIndex, friction, restitution) = src;
        let (bs, dyn, kin, kinMoving, asleep) = pk;
        let o = i * bStride();
        let so = i * stateStride();
        let po = i * propStride();
        let sleeping = Vector.get(i, sleepingAll);
        let bodyType = Vector.get(i, types);
        let isKin = bodyType == RigidBody2d.BodyType.Kinematic;
        let mat = Vector.get(i, materialIndex);
        let (vx, vy, w) = if (isKin) kinematicVelocity(d, i, d#stepSeconds)
                          else (Vector.get(so + 4, state), Vector.get(so + 5, state), Vector.get(so + 6, state));
        let x = Vector.get(so, state);
        let y = Vector.get(so + 1, state);
        let c = Vector.get(so + 2, state);
        let s = Vector.get(so + 3, state);
        Array.put(x, o, bs); Array.put(y, o + 1, bs); Array.put(c, o + 2, bs); Array.put(s, o + 3, bs);
        Array.put(vx, o + 4, bs); Array.put(vy, o + 5, bs); Array.put(w, o + 6, bs);
        // 眠っている体はこの刻みだけ重さ無限として扱う（起こすのは次の刻みから）。
        Array.put(if (sleeping) 0.0 else Vector.get(po + 1, props), o + 7, bs);
        Array.put(if (sleeping) 0.0 else Vector.get(po + 2, props), o + 8, bs);
        Array.put(Vector.get(po, props), o + 9, bs); Array.put(Vector.get(so + 7, state), o + 10, bs);
        Array.put(Vector.get(mat, friction), o + 11, bs); Array.put(Vector.get(mat, restitution), o + 12, bs);
        Array.put(x, o + 13, bs); Array.put(y, o + 14, bs); Array.put(c, o + 15, bs); Array.put(s, o + 16, bs);
        Array.put(bodyType == RigidBody2d.BodyType.Dynamic, i, dyn);
        Array.put(isKin, i, kin);
        Array.put(isKin and (vx != 0.0 or vy != 0.0 or w != 0.0), i, kinMoving);
        Array.put(sleeping, i, asleep)

    /// Kinematic の体の、この刻みの速さ: 目標があれば 1 刻みでそこへ着く速さ、無ければ持っている速さ。
    def kinematicVelocity(d: Data, i: Int32, dt: Float64): (Float64, Float64, Float64) =
        let so = i * stateStride();
        let st = k -> Vector.get(so + k, d#state);
        match Map.get(Vector.get(i, d#ids), d#targets) {
            case None => (st(4), st(5), st(6))
            case Some((tx, ty, tc, ts)) =>
                let c = st(2);
                let s = st(3);
                let dc = tc * c + ts * s;
                let ds = ts * c - tc * s;
                ((tx - st(0)) / dt, (ty - st(1)) / dt, PortableMath.atan2(ds, dc) / dt)
        }

    /// 目標へ動かした Kinematic の体を目標の姿勢ちょうどに置き、速さを 0 に戻す（次の刻みに目標が無ければ止まる）。
    def snapKinematic(d: Data, bs: Array[Float64, r], kin: Array[Bool, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            if (Array.get(i, kin)) {
                match Map.get(Vector.get(i, d#ids), d#targets) {
                    case None => ()
                    case Some((tx, ty, tc, ts)) =>
                        let o = i * bStride();
                        Array.put(tx, o, bs); Array.put(ty, o + 1, bs); Array.put(tc, o + 2, bs); Array.put(ts, o + 3, bs);
                        Array.put(0.0, o + 4, bs); Array.put(0.0, o + 5, bs); Array.put(0.0, o + 6, bs)
                }
            } else ();
            snapKinematic(d, bs, kin, i + 1, n)
        }

    def isFinitePose(bs: Array[Float64, r], i: Int32): Bool \ r =
        let o = i * bStride();
        let sum = Array.get(o, bs) + Array.get(o + 1, bs) + Array.get(o + 2, bs) + Array.get(o + 3, bs)
                  + Array.get(o + 4, bs) + Array.get(o + 5, bs) + Array.get(o + 6, bs);
        PhysicsWorld2d.Internal.Data.isFinite(sum)

    /// 両方とも止まっていて当たりを見なかった組（眠った島）の warm start の衝撃を、前の控えから持ち越す（起こした刻みに 0 から解き直して山が跳ねないように）。
    def keepRestingWarm(rc: Region[r], fresh: PhysicsWorld2d.Internal.Data.Warm, old: PhysicsWorld2d.Internal.Data.Warm,
                        kept: Vector[Int64]): PhysicsWorld2d.Internal.Data.Warm \ r =
        let (oldKeys, _, _, _) = old;
        let carried = Vector.range(0, Vector.length(oldKeys)) |> Vector.filter(i -> isKept(Vector.get(i, oldKeys), kept));
        if (Vector.isEmpty(carried)) fresh
        else {
            let keys = MutList.empty(rc);
            let features = MutList.empty(rc);
            let normal = MutList.empty(rc);
            let tangent = MutList.empty(rc);
            mergeWarm({ fresh = fresh, old = old, carried = carried, keys = keys, features = features, normal = normal, tangent = tangent }, 0, 0);
            (MutList.toVector(keys), MutList.toVector(features), MutList.toVector(normal), MutList.toVector(tangent))
        }

    type alias WarmMerge[r: Region] = { fresh = PhysicsWorld2d.Internal.Data.Warm, old = PhysicsWorld2d.Internal.Data.Warm, carried = Vector[Int32],
                                        keys = MutList[Int64, r], features = MutList[Int32, r], normal = MutList[Float64, r], tangent = MutList[Float64, r] }

    /// 2 つの並んだ控え（今の刻みの物と、持ち越す物）を鍵の順に 1 つへ（同じ鍵は今の刻みの物）。
    def mergeWarm(wm: WarmMerge[r], i: Int32, j: Int32): Unit \ r =
        let (fk, _, _, _) = wm#fresh;
        let (ok, _, _, _) = wm#old;
        let nf = Vector.length(fk);
        let nc = Vector.length(wm#carried);
        if (i >= nf and j >= nc) ()
        else {
            let kf = if (i < nf) Vector.get(i, fk) else Int64.maxValue();
            let at = if (j < nc) Vector.get(j, wm#carried) else 0;
            let kc = if (j < nc) Vector.get(at, ok) else Int64.maxValue();
            if (i < nf and (j >= nc or kf <= kc)) {
                pushWarm(wm, wm#fresh, i);
                mergeWarm(wm, i + 1, if (j < nc and kf == kc) j + 1 else j)
            } else {
                pushWarm(wm, wm#old, at);
                mergeWarm(wm, i, j + 1)
            }
        }

    def pushWarm(wm: WarmMerge[r], src: PhysicsWorld2d.Internal.Data.Warm, at: Int32): Unit \ r =
        let (keys, features, normal, tangent) = src;
        MutList.push(Vector.get(at, keys), wm#keys);
        MutList.push(Vector.get(at * 2, features), wm#features); MutList.push(Vector.get(at * 2 + 1, features), wm#features);
        MutList.push(Vector.get(at * 2, normal), wm#normal); MutList.push(Vector.get(at * 2 + 1, normal), wm#normal);
        MutList.push(Vector.get(at * 2, tangent), wm#tangent); MutList.push(Vector.get(at * 2 + 1, tangent), wm#tangent)

    def unpackAll(bs: Array[Float64, r], next: Array[Float64, r], prev: Array[Float64, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            let o = i * bStride();
            let so = i * stateStride();
            let po = i * 4;
            Array.put(Array.get(o, bs), so, next); Array.put(Array.get(o + 1, bs), so + 1, next);
            Array.put(Array.get(o + 2, bs), so + 2, next); Array.put(Array.get(o + 3, bs), so + 3, next);
            Array.put(Array.get(o + 4, bs), so + 4, next); Array.put(Array.get(o + 5, bs), so + 5, next);
            Array.put(Array.get(o + 6, bs), so + 6, next); Array.put(Array.get(o + 10, bs), so + 7, next);
            Array.put(Array.get(o + 13, bs), po, prev); Array.put(Array.get(o + 14, bs), po + 1, prev);
            Array.put(Array.get(o + 15, bs), po + 2, prev); Array.put(Array.get(o + 16, bs), po + 3, prev);
            unpackAll(bs, next, prev, i + 1, n)
        }

    def poseOf(bs: Array[Float64, r], i: Int32): PhysicsWorld2d.Internal.Narrowphase.Pose \ r =
        let o = i * bStride();
        (Array.get(o, bs), Array.get(o + 1, bs), Array.get(o + 2, bs), Array.get(o + 3, bs))

    def fillIdentity(a: Array[Int32, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) () else { Array.put(i, i, a); fillIdentity(a, i + 1, n) }

    /// 体 i の AABB（box の stride 4: 左・右・上・下）。多角形は world の頂点の端・円は中心 ± 半径。
    // WhyNot: 体を囲む円で組を選ばない — 床と壁の箱は囲む円の半径が 12〜15 m になり、全部の体と組になって毎刻みナローフェーズを回す。
    def fillBox(bs: Array[Float64, r], box: Array[Float64, r], i: Int32, poly: WorldPolygon): Unit \ r =
        let (xs, ys, _, _) = poly;
        let o = i * bStride();
        let b = i * 4;
        if (Vector.length(xs) == 0) {
            let x = Array.get(o, bs);
            let y = Array.get(o + 1, bs);
            let r = Array.get(o + 9, bs);
            Array.put(x - r, b, box); Array.put(x + r, b + 1, box); Array.put(y - r, b + 2, box); Array.put(y + r, b + 3, box)
        } else {
            Array.put(Vector.foldLeft(Float64.min, Float64.maxValue(), xs), b, box);
            Array.put(Vector.foldLeft(Float64.max, Float64.minValue(), xs), b + 1, box);
            Array.put(Vector.foldLeft(Float64.min, Float64.maxValue(), ys), b + 2, box);
            Array.put(Vector.foldLeft(Float64.max, Float64.minValue(), ys), b + 3, box)
        }

    /// 左端を刻む細かさ（1 / 8192 m ≒ 0.12 mm）。
    def leftScale(): Float64 = 8192.0

    /// 左端の刻み（下へ丸めた整数）。q(x) > q(y) なら x > y。
    def leftStep(x: Float64): Int64 =
        Float64.tryToInt64(Float64.floor(Float64.max(-1.0e9, Float64.min(1.0e9, x)) * leftScale())) |> Option.getWithDefault(0i64)

    /// AABB の左端の刻みで並べた番号（同じ刻みは番号 = id の順）。(刻み << 32 | 番号) を long のまま並べる。
    // WhyNot: 比べる関数を渡す並べ替え（Sort.sortStableWith の List）にしない — 毎刻み List と閉包を作る定まった代金が、物 100 個の小さい山の 1 刻みの重さの多くを占めた。
    def sortedByLeft(rc: Region[r], box: Array[Float64, r], n: Int32): Array[Int32, r] \ r =
        let keys = Array.repeat(rc, n, 0i64);
        List.range(0, n) |> List.forEach(i -> Array.put(Int64.bitwiseOr(Int64.leftShift(leftStep(Array.get(i * 4, box)), 32), Int32.toInt64(i)), i, keys));
        unchecked_cast(Arrays.sort(keys) as _ \ r);
        let order = Array.repeat(rc, n, 0);
        List.range(0, n) |> List.forEach(k -> Array.put(Int64.tryToInt32(Int64.bitwiseAnd(Array.get(k, keys), 4294967295i64)) |> Option.getWithDefault(0), k, order));
        order

    // ── 粗い当たりと細かい当たり ──

    /// 掃いて集めた物: 接触の点・組ごとの (鍵, 最初の点, 点の数)・組ごとの (鍵, 一番近い離れ)・眠った組（触れたままと見る）・sensor に重なった組・眠った sensor の組。
    type alias Found[r: Region] = {
        points = MutList[Point, r], manifolds = MutList[(Int64, Int32, Int32), r], contactSeps = MutList[(Int64, Float64), r],
        kept = MutList[Int64, r], sensed = MutList[Int64, r], keptSensed = MutList[Int64, r]
    }

    /// 体ごとの印（bits の bit）。
    def bitDyn(): Int32 = 1
    def bitKin(): Int32 = 2
    def bitKinMoving(): Int32 = 4
    def bitAsleep(): Int32 = 8
    def bitSensor(): Int32 = 16

    def has(bits: Array[Int32, r], i: Int32, bit: Int32): Bool \ r = Int32.bitwiseAnd(Array.get(i, bits), bit) != 0

    /// 掃く時に読む物: 体ごとの印・当たり層・mask・体の欄・union-find の親・動く Kinematic が触れた眠りの体・形・world の頂点・id・集める先。
    // WhyNot: record にしない — 組ごとに 10 回ほど欄を引き、record の欄は名前で探すので、組の数だけ重さが乗る（ブラウザで重い）。
    type alias Sweep[r: Region] = (Array[Int32, r], Array[Int32, r], Array[Int32, r], Array[Float64, r], Array[Int32, r], Array[Bool, r],
                                   Vector[Shape], Vector[WorldPolygon], Vector[Int32], Found[r])

    def bitsOf(st: Sweep[r]): Array[Int32, r] = let (x, _, _, _, _, _, _, _, _, _) = st; x
    def parentOf(st: Sweep[r]): Array[Int32, r] = let (_, _, _, _, x, _, _, _, _, _) = st; x
    def touchWakeOf(st: Sweep[r]): Array[Bool, r] = let (_, _, _, _, _, x, _, _, _, _) = st; x
    def idsOf(st: Sweep[r]): Vector[Int32] = let (_, _, _, _, _, _, _, _, x, _) = st; x
    def foundOf(st: Sweep[r]): Found[r] = let (_, _, _, _, _, _, _, _, _, x) = st; x

    def sweepEach(st: Sweep[r], order: Array[Int32, r], box: Array[Float64, r], k: Int32, n: Int32): Unit \ r =
        if (k >= n) ()
        else {
            let i = Array.get(k, order);
            let right = leftStep(Array.get(i * 4 + 1, box) + margin());
            sweepFrom(st, order, box, i, right, k + 1, n);
            sweepEach(st, order, box, k + 1, n)
        }

    def sweepFrom(st: Sweep[r], order: Array[Int32, r], box: Array[Float64, r], i: Int32, right: Int64, k: Int32, n: Int32): Unit \ r =
        if (k >= n) ()
        else {
            let j = Array.get(k, order);
            // 並びは左端の刻みの順なので、刻みで比べて止める（刻みが right を超えた後の体は、本当の左端も i の右端 + 余白を超える）。
            if (leftStep(Array.get(j * 4, box)) > right) ()
            else {
                let a = Int32.min(i, j);
                let b = Int32.max(i, j);
                let separated = Array.get(a * 4 + 2, box) > Array.get(b * 4 + 3, box) + margin() or Array.get(b * 4 + 2, box) > Array.get(a * 4 + 3, box) + margin();
                if (separated) () else pairOf(st, a, b);
                sweepFrom(st, order, box, i, right, k + 1, n)
            }
        }

    def isActive(bits: Array[Int32, r], i: Int32): Bool \ r =
        let v = Array.get(i, bits);
        (Int32.bitwiseAnd(v, bitDyn()) != 0 and Int32.bitwiseAnd(v, bitAsleep()) == 0) or Int32.bitwiseAnd(v, bitKinMoving()) != 0

    /// 組 1 つ（a < b の番号）: 当たり層で絞り、sensor の組と押し合う組に分ける。
    def pairOf(st: Sweep[r], a: Int32, b: Int32): Unit \ r =
        let (bits, layer, mask, _, _, _, _, _, _, _) = st;
        let layered = Int32.bitwiseAnd(Array.get(a, layer), Array.get(b, mask)) != 0
                  and Int32.bitwiseAnd(Array.get(b, layer), Array.get(a, mask)) != 0;
        let sa = has(bits, a, bitSensor());
        let sb = has(bits, b, bitSensor());
        if (not layered or (sa and sb)) ()
        else if (sa) sensorPair(st, a, b, b)
        else if (sb) sensorPair(st, a, b, a)
        else contactPair(st, a, b)

    /// sensor の組（other は sensor でない方）。動かない体は出来事を出さない。
    def sensorPair(st: Sweep[r], a: Int32, b: Int32, other: Int32): Unit \ r =
        let bits = bitsOf(st);
        let movable = has(bits, other, bitDyn()) or has(bits, other, bitKin());
        let key = PhysicsWorld2d.Internal.Data.pairKey(Vector.get(a, idsOf(st)), Vector.get(b, idsOf(st)));
        if (not movable) ()
        else if (not isActive(bits, a) and not isActive(bits, b)) MutList.push(key, foundOf(st)#keptSensed)
        else {
            let contacts = collide(st, a, b);
            if (List.exists(c -> sepOf(c) <= 0.0, contacts)) MutList.push(key, foundOf(st)#sensed) else ()
        }

    def sepOf(c: PhysicsWorld2d.Internal.Narrowphase.Contact): Float64 = let (_, _, _, _, sep, _) = c; sep

    def collide(st: Sweep[r], a: Int32, b: Int32): List[PhysicsWorld2d.Internal.Narrowphase.Contact] \ r =
        let (_, _, _, bs, _, _, shapes, polys, _, _) = st;
        PhysicsWorld2d.Internal.Narrowphase.collideWith(Vector.get(a, shapes), Vector.get(a, polys), poseOf(bs, a),
                                                        Vector.get(b, shapes), Vector.get(b, polys), poseOf(bs, b))

    /// 押し合う組: どちらも Dynamic でなければ捨て、どちらも止まっている（眠りか止まった Kinematic・Fixed）なら島だけつないで触れたままと見る。
    def contactPair(st: Sweep[r], a: Int32, b: Int32): Unit \ r =
        let bits = bitsOf(st);
        let da = has(bits, a, bitDyn());
        let db = has(bits, b, bitDyn());
        if (not da and not db) ()
        else {
            let key = PhysicsWorld2d.Internal.Data.pairKey(Vector.get(a, idsOf(st)), Vector.get(b, idsOf(st)));
            if (not isActive(bits, a) and not isActive(bits, b)) {
                if (da and db) union(parentOf(st), a, b) else ();
                MutList.push(key, foundOf(st)#kept)
            }
            else narrowPair(st, a, b, key)
        }

    def narrowPair(st: Sweep[r], a: Int32, b: Int32, key: Int64): Unit \ r =
        let manifold = collide(st, a, b);
        if (List.isEmpty(manifold)) ()
        else {
            let bits = bitsOf(st);
            let da = has(bits, a, bitDyn());
            let db = has(bits, b, bitDyn());
            if (da and db) union(parentOf(st), a, b) else ();
            if (has(bits, a, bitKinMoving()) and db and has(bits, b, bitAsleep())) Array.put(true, b, touchWakeOf(st)) else ();
            if (has(bits, b, bitKinMoving()) and da and has(bits, a, bitAsleep())) Array.put(true, a, touchWakeOf(st)) else ();
            let found = foundOf(st);
            let points = found#points;
            let first = MutList.size(points);
            manifold |> List.forEach(m -> {
                let (nx, ny, px, py, sep, feature) = m;
                MutList.push((a, b, nx, ny, px, py, sep, key, feature), points)
            });
            MutList.push((key, first, List.length(manifold)), found#manifolds);
            let nearest = manifold |> List.foldLeft((acc, c) -> Float64.min(acc, sepOf(c)), Float64.maxValue());
            MutList.push((key, nearest), found#contactSeps)
        }

    // ── 島と眠り ──

    /// union-find の根（途中を半分ずつ縮める）。
    def find(parent: Array[Int32, r], i: Int32): Int32 \ r =
        let p = Array.get(i, parent);
        if (p == i) i
        else {
            let gp = Array.get(p, parent);
            Array.put(gp, i, parent);
            if (gp == p) p else find(parent, gp)
        }

    /// 小さい番号の根の下へつなぐ（つなぐ順に結果がよらない）。
    def union(parent: Array[Int32, r], i: Int32, j: Int32): Unit \ r =
        let ri = find(parent, i);
        let rj = find(parent, j);
        if (ri == rj) () else if (ri < rj) Array.put(ri, rj, parent) else Array.put(rj, ri, parent)

    /// 島を見る時に読む物（Dynamic か・眠り・この刻みに起こした体・動く Kinematic が触れた体・体の欄・union-find の親）。
    type alias Islands[r: Region] = (Array[Bool, r], Array[Bool, r], Array[Bool, r], Array[Bool, r], Array[Float64, r], Array[Int32, r])

    // WhyNot: 体ごとの輪で record の欄を引かない — 名前で探すので、体の数 × 欄の数だけ重さが乗る。配列は輪の外で 1 回だけ取り出す。

    /// 起きた体が 1 つでもある島（と動く Kinematic が触れた体の島）の、眠っていた体を次の刻みから起こす。
    def wakeIslands(rc: Region[r], il: Islands[r], n: Int32): Unit \ r =
        let (dyn, asleep, woken, touchWake, bs, parent) = il;
        let islandAwake = Array.repeat(rc, n, false);
        List.range(0, n) |> List.forEach(i -> {
            let awake = Array.get(i, dyn) and not Array.get(i, asleep);
            if (awake or Array.get(i, touchWake)) Array.put(true, find(parent, i), islandAwake) else ()
        });
        List.range(0, n) |> List.forEach(i ->
            if (Array.get(i, dyn) and Array.get(i, asleep) and Array.get(find(parent, i), islandAwake)) {
                Array.put(false, i, asleep); Array.put(0.0, i * bStride() + 10, bs); Array.put(true, i, woken)
            } else ())

    type alias SleepLimits = { dt = Float64, linear = Float64, angular = Float64 }

    /// 眠りの時計を足す（解いた後の速さで見る。食い込みを戻す速さが残った値で見ると、積んだ物がいつまでも眠らない）。
    def updateTimers(sv: Solve[r], limits: SleepLimits): Unit \ r =
        let (bs, dyn, asleep, woken) = (sv#bs, sv#dyn, sv#asleep, sv#woken);
        let dt = limits#dt;
        let linear = limits#linear;
        let angular = limits#angular;
        let sleeps = linear > 0.0 and angular > 0.0;
        List.range(0, sv#n) |> List.forEach(i ->
            if (PhysicsWorld2d.Internal.Solver.moving(dyn, asleep, woken, i)) {
                let o = i * bStride();
                let vx = Array.get(o + 4, bs);
                let vy = Array.get(o + 5, bs);
                let w = Array.get(o + 6, bs);
                let slow = sleeps and vx * vx + vy * vy < linear * linear and w * w < angular * angular;
                Array.put(if (slow) Array.get(o + 10, bs) + dt else 0.0, o + 10, bs)
            } else ())

    /// 島ごとに、全部の体が sleepAfter 秒続けて遅ければ眠らせる。
    def sleepIslands(rc: Region[r], sv: Solve[r], parent: Array[Int32, r]): Unit \ r =
        let (bs, dyn, asleep, woken, n) = (sv#bs, sv#dyn, sv#asleep, sv#woken, sv#n);
        let islandMin = Array.repeat(rc, n, Float64.maxValue());
        List.range(0, n) |> List.forEach(i ->
            if (Array.get(i, dyn)) {
                let root = find(parent, i);
                let t = if (Array.get(i, woken)) 0.0 else Array.get(i * bStride() + 10, bs);
                Array.put(Float64.min(t, Array.get(root, islandMin)), root, islandMin)
            } else ());
        List.range(0, n) |> List.forEach(i ->
            if (PhysicsWorld2d.Internal.Solver.moving(dyn, asleep, woken, i) and Array.get(find(parent, i), islandMin) >= sleepAfter()) {
                let o = i * bStride();
                Array.put(true, i, asleep); Array.put(0.0, o + 4, bs); Array.put(0.0, o + 5, bs); Array.put(0.0, o + 6, bs)
            } else ())

    // ── 出来事（前の刻みの組との差分） ──

    /// 前に触れていた組 prev（並んだ鍵）と、この刻みの組から、今触れている組（並んだ鍵）と出来事（鍵の順）。
    /// active は今の刻みの組の鍵（並べた物。warm start の控えの鍵と同じ）。
    def diffTouching(rc: Region[r], prev: Vector[Int64], active: Vector[Int64], seps: Vector[(Int64, Float64)],
                     kept: Vector[Int64]): (Vector[Int64], List[CollisionEvent2d.CollisionEvent2d]) \ r =
        let sepAt = Array.repeat(rc, Vector.length(active), 0.0);
        Vector.forEach(p -> Array.put(snd(p), PhysicsWorld2d.Internal.Data.searchKey(fst(p), active, 0, Vector.length(active) - 1), sepAt), seps);
        let now = MutList.empty(rc);
        let events = MutList.empty(rc);
        mergeTouching({ prev = prev, active = active, sepAt = sepAt, kept = kept, now = now, events = events }, 0, 0);
        (MutList.toVector(now), MutList.toList(events))

    type alias Merge[r: Region] = { prev = Vector[Int64], active = Vector[Int64], sepAt = Array[Float64, r], kept = Vector[Int64],
                                    now = MutList[Int64, r], events = MutList[CollisionEvent2d.CollisionEvent2d, r] }

    def mergeTouching(mg: Merge[r], i: Int32, j: Int32): Unit \ r =
        let np = Vector.length(mg#prev);
        let na = Vector.length(mg#active);
        if (i >= np and j >= na) ()
        else {
            let kp = if (i < np) Vector.get(i, mg#prev) else Int64.maxValue();
            let ka = if (j < na) Vector.get(j, mg#active) else Int64.maxValue();
            if (i < np and (j >= na or kp < ka)) {
                if (isKept(kp, mg#kept)) MutList.push(kp, mg#now)
                else MutList.push(CollisionEvent2d.CollisionEvent2d.Stopped(PhysicsWorld2d.Internal.Data.pairA(kp), PhysicsWorld2d.Internal.Data.pairB(kp), false), mg#events);
                mergeTouching(mg, i + 1, j)
            } else if (i < np and kp == ka) {
                if (isKept(kp, mg#kept) or Array.get(j, mg#sepAt) <= stopDistance()) MutList.push(kp, mg#now)
                else MutList.push(CollisionEvent2d.CollisionEvent2d.Stopped(PhysicsWorld2d.Internal.Data.pairA(kp), PhysicsWorld2d.Internal.Data.pairB(kp), false), mg#events);
                mergeTouching(mg, i + 1, j + 1)
            } else {
                if (Array.get(j, mg#sepAt) <= startDistance()) {
                    MutList.push(ka, mg#now);
                    MutList.push(CollisionEvent2d.CollisionEvent2d.Started(PhysicsWorld2d.Internal.Data.pairA(ka), PhysicsWorld2d.Internal.Data.pairB(ka)), mg#events)
                } else ();
                mergeTouching(mg, i, j + 1)
            }
        }

    def isKept(key: Int64, kept: Vector[Int64]): Bool =
        PhysicsWorld2d.Internal.Data.searchKey(key, kept, 0, Vector.length(kept) - 1) >= 0

    /// sensor の組: 今重なっている組 = 重なった組 ∪（前に重なっていて、眠っているので見なかった組）。
    def diffSensing(rc: Region[r], d: Data, sensed: Vector[Int64], keptSensed: Vector[Int64]): (Vector[Int64], List[SensorEvent2d.SensorEvent2d]) \ r =
        let keptSorted = PhysicsWorld2d.Internal.Solver.sortedKeys(rc, keptSensed);
        let stillKept = d#sensing |> Vector.filter(k -> isKept(k, keptSorted));
        let now = PhysicsWorld2d.Internal.Solver.sortedKeys(rc, Vector.append(sensed, stillKept));
        let started = now |> Vector.filter(k -> not isKept(k, d#sensing)) |> Vector.toList
            |> List.map(k -> { let (s, o) = sensorFirst(d, k); (k, SensorEvent2d.SensorEvent2d.Started(s, o)) });
        let stopped = d#sensing |> Vector.filter(k -> not isKept(k, now)) |> Vector.toList
            |> List.map(k -> { let (s, o) = sensorFirst(d, k); (k, SensorEvent2d.SensorEvent2d.Stopped(s, o, false)) });
        (now, Sort.sortStableBy(fst, List.append(stopped, started)) |> List.map(snd))

    /// 組の鍵を (sensor の id, もう片方の id) にする。
    pub def sensorFirst(d: Data, key: Int64): (Int32, Int32) =
        let a = PhysicsWorld2d.Internal.Data.pairA(key);
        let b = PhysicsWorld2d.Internal.Data.pairB(key);
        let aIsSensor = PhysicsWorld2d.Internal.Data.indexOf(a, d#ids)
            |> Option.map(i -> Collider2d.isSensor(Vector.get(i, d#colliders))) |> Option.getWithDefault(false);
        if (aIsSensor) (a, b) else (b, a)
}
