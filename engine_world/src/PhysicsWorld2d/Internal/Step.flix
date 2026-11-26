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
    pub def step(d: Data): (Data, List[Int32]) = region rc {
        let n = Vector.length(d#ids);
        let dt = d#stepSeconds;
        let bs = Array.repeat(rc, n * bStride(), 0.0);
        let dyn = Array.repeat(rc, n, false);
        let kin = Array.repeat(rc, n, false);
        let kinMoving = Array.repeat(rc, n, false);
        let asleep = Array.repeat(rc, n, false);
        let woken = Array.repeat(rc, n, false);
        let touchWake = Array.repeat(rc, n, false);
        packAll(d, { bs = bs, dyn = dyn, kin = kin, kinMoving = kinMoving, asleep = asleep }, 0, n);
        let polys = Vector.mapWithIndex((i, shape) -> PhysicsWorld2d.Internal.Narrowphase.worldPolygonOf(shape, poseOf(bs, i)), d#shapes);
        let box = Array.repeat(rc, n * 4, 0.0);
        Vector.forEachWithIndex((i, poly) -> fillBox(bs, box, i, poly), polys);
        let order = sortedByLeft(rc, box, n);
        let parent = Array.repeat(rc, n, 0);
        fillIdentity(parent, 0, n);
        let out = { points = MutList.empty(rc), manifolds = MutList.empty(rc), contactSeps = MutList.empty(rc),
                    kept = MutList.empty(rc), sensed = MutList.empty(rc), keptSensed = MutList.empty(rc) };
        let flags = flagsOf(rc, d, n);
        sweep({ shapes = d#shapes, ids = d#ids, polys = polys, box = box, bs = bs, dyn = dyn, kin = kin, kinMoving = kinMoving, asleep = asleep,
                parent = parent, touchWake = touchWake, sensor = fst3(flags), layer = snd3(flags), mask = thd3(flags), out = out }, order, 0, n);
        wakeIslands(rc, { dyn = dyn, asleep = asleep, woken = woken, touchWake = touchWake, bs = bs, parent = parent }, n);
        let pts = MutList.toVector(out#points);
        let manifolds = MutList.toVector(out#manifolds);
        let pab = Array.repeat(rc, Vector.length(pts) * 2, 0);
        let sv: Solve[_] = { bs = bs, dyn = dyn, kin = kin, asleep = asleep, woken = woken, pab = pab, n = n };
        let s = d#settings;
        let impulses = PhysicsWorld2d.Internal.Solver.solveStep(rc, sv, pts, d#warm,
            { dt = dt, gx = s#gravity#x, gy = s#gravity#y, substeps = Int32.max(1, s#solverSubsteps) });
        updateTimers(sv, { dt = dt, linear = s#sleepLinearThreshold, angular = s#sleepAngularThreshold }, 0);
        sleepIslands(rc, sv, parent);
        snapKinematic(d, bs, kin, 0, n);
        let keptSorted = PhysicsWorld2d.Internal.Solver.sortedKeys(rc, MutList.toVector(out#kept));
        let warm = keepRestingWarm(rc, PhysicsWorld2d.Internal.Solver.warmOf(rc, pts, manifolds, impulses), d#warm, keptSorted);
        let broken = List.range(0, n) |> List.filter(i -> not isFinitePose(bs, i)) |> List.map(i -> Vector.get(i, d#ids));
        let next = Array.repeat(rc, n * stateStride(), 0.0);
        let prev = Array.repeat(rc, n * 4, 0.0);
        unpackAll(bs, next, prev, 0, n);
        let (touching, collisions) = diffTouching(rc, d#touching, MutList.toVector(out#contactSeps), keptSorted);
        let (sensing, sensors) = diffSensing(rc, d, MutList.toVector(out#sensed), MutList.toVector(out#keptSensed));
        let earlier = d#pending |> List.reverse;
        let events = { collisions = List.append(List.flatMap(e -> e#collisions, earlier), collisions),
                       sensors = List.append(List.flatMap(e -> e#sensors, earlier), sensors) };
        ({ state = Array.toVector(next), prev = Array.toVector(prev), asleep = Array.toVector(asleep), warm = warm,
           touching = touching, sensing = sensing, events = events, pending = Nil, targets = Map.empty(), steps = d#steps + 1i64 | d },
         broken)
    }

    def fst3(t: (a, b, c)): a = let (x, _, _) = t; x
    def snd3(t: (a, b, c)): b = let (_, x, _) = t; x
    def thd3(t: (a, b, c)): c = let (_, _, x) = t; x

    /// 形ごとの sensor の印・当たり層・mask。
    def flagsOf(rc: Region[r], d: Data, n: Int32): (Array[Bool, r], Array[Int32, r], Array[Int32, r]) \ r =
        let sensor = Array.repeat(rc, n, false);
        let layer = Array.repeat(rc, n, 0);
        let mask = Array.repeat(rc, n, 0);
        Vector.forEachWithIndex((i, c) -> {
            Array.put(Collider2d.isSensor(c), i, sensor);
            Array.put(Collider2d.collisionLayer(c), i, layer);
            Array.put(Collider2d.collisionMask(c), i, mask)
        }, d#colliders);
        (sensor, layer, mask)

    type alias Pack[r: Region] = { bs = Array[Float64, r], dyn = Array[Bool, r], kin = Array[Bool, r], kinMoving = Array[Bool, r], asleep = Array[Bool, r] }

    def packAll(d: Data, pk: Pack[r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) () else { packOne(d, pk, i); packAll(d, pk, i + 1, n) }

    def packOne(d: Data, pk: Pack[r], i: Int32): Unit \ r =
        let bs = pk#bs;
        let o = i * bStride();
        let so = i * stateStride();
        let po = i * propStride();
        let st = k -> Vector.get(so + k, d#state);
        let pr = k -> Vector.get(po + k, d#props);
        let sleeping = Vector.get(i, d#asleep);
        let bodyType = Vector.get(i, d#types);
        let isKin = bodyType == RigidBody2d.BodyType.Kinematic;
        let material = Vector.get(Vector.get(i, d#materialIndex), d#materials);
        let (vx, vy, w) = if (isKin) kinematicVelocity(d, i, d#stepSeconds) else (st(4), st(5), st(6));
        Array.put(st(0), o, bs); Array.put(st(1), o + 1, bs);
        Array.put(st(2), o + 2, bs); Array.put(st(3), o + 3, bs);
        Array.put(vx, o + 4, bs); Array.put(vy, o + 5, bs); Array.put(w, o + 6, bs);
        // 眠っている体はこの刻みだけ重さ無限として扱う（起こすのは次の刻みから）。
        Array.put(if (sleeping) 0.0 else pr(1), o + 7, bs);
        Array.put(if (sleeping) 0.0 else pr(2), o + 8, bs);
        Array.put(pr(0), o + 9, bs); Array.put(st(7), o + 10, bs);
        Array.put(material#friction, o + 11, bs); Array.put(material#restitution, o + 12, bs);
        Array.put(st(0), o + 13, bs); Array.put(st(1), o + 14, bs);
        Array.put(st(2), o + 15, bs); Array.put(st(3), o + 16, bs);
        Array.put(bodyType == RigidBody2d.BodyType.Dynamic, i, pk#dyn);
        Array.put(isKin, i, pk#kin);
        Array.put(isKin and (vx != 0.0 or vy != 0.0 or w != 0.0), i, pk#kinMoving);
        Array.put(sleeping, i, pk#asleep)

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

    /// AABB の左端で並べた番号。同じ値は番号（= id）の順。
    def sortedByLeft(rc: Region[r], box: Array[Float64, r], n: Int32): Array[Int32, r] \ r =
        let lefts = Vector.range(0, n) |> Vector.map(i -> Array.get(i * 4, box));
        // WhyNot: Array.sortWith を使わない — 単純なクイックソートで、前の刻みとほぼ同じ並びの入力で二乗になる。
        let sorted = Sort.sortStableWith((i, j) -> compareLeft(lefts, i, j), List.range(0, n));
        List.toArray(rc, sorted)

    def compareLeft(lefts: Vector[Float64], i: Int32, j: Int32): Comparison =
        let li = Vector.get(i, lefts);
        let lj = Vector.get(j, lefts);
        if (li < lj) Comparison.LessThan else if (li > lj) Comparison.GreaterThan
        else if (i < j) Comparison.LessThan else if (i > j) Comparison.GreaterThan else Comparison.EqualTo

    // ── 粗い当たりと細かい当たり ──

    /// 掃いて集めた物: 接触の点・組ごとの (鍵, 最初の点, 点の数)・組ごとの (鍵, 一番近い離れ)・眠った組（触れたままと見る）・sensor に重なった組・眠った sensor の組。
    type alias Found[r: Region] = {
        points = MutList[Point, r], manifolds = MutList[(Int64, Int32, Int32), r], contactSeps = MutList[(Int64, Float64), r],
        kept = MutList[Int64, r], sensed = MutList[Int64, r], keptSensed = MutList[Int64, r]
    }

    type alias Sweep[r: Region] = {
        shapes = Vector[Shape], ids = Vector[Int32], polys = Vector[WorldPolygon], box = Array[Float64, r], bs = Array[Float64, r],
        dyn = Array[Bool, r], kin = Array[Bool, r], kinMoving = Array[Bool, r], asleep = Array[Bool, r], parent = Array[Int32, r], touchWake = Array[Bool, r],
        sensor = Array[Bool, r], layer = Array[Int32, r], mask = Array[Int32, r], out = Found[r]
    }

    // WhyNot: 輪の中で st#box・st#order を引かない — record の欄は名前で探すので、組の数だけ重さが乗る。配列は輪の外で 1 回だけ取り出す。
    def sweep(st: Sweep[r], order: Array[Int32, r], k: Int32, n: Int32): Unit \ r =
        sweepEach(st, order, st#box, k, n)

    def sweepEach(st: Sweep[r], order: Array[Int32, r], box: Array[Float64, r], k: Int32, n: Int32): Unit \ r =
        if (k >= n) ()
        else {
            let i = Array.get(k, order);
            let right = Array.get(i * 4 + 1, box) + margin();
            sweepFrom(st, order, box, i, right, k + 1, n);
            sweepEach(st, order, box, k + 1, n)
        }

    def sweepFrom(st: Sweep[r], order: Array[Int32, r], box: Array[Float64, r], i: Int32, right: Float64, k: Int32, n: Int32): Unit \ r =
        if (k >= n) ()
        else {
            let j = Array.get(k, order);
            if (Array.get(j * 4, box) > right) ()
            else {
                let a = Int32.min(i, j);
                let b = Int32.max(i, j);
                let separated = Array.get(a * 4 + 2, box) > Array.get(b * 4 + 3, box) + margin() or Array.get(b * 4 + 2, box) > Array.get(a * 4 + 3, box) + margin();
                if (separated) () else pairOf(st, a, b);
                sweepFrom(st, order, box, i, right, k + 1, n)
            }
        }

    def isActive(st: Sweep[r], i: Int32): Bool \ r =
        (Array.get(i, st#dyn) and not Array.get(i, st#asleep)) or Array.get(i, st#kinMoving)

    /// 組 1 つ（a < b の番号）: 当たり層で絞り、sensor の組と押し合う組に分ける。
    def pairOf(st: Sweep[r], a: Int32, b: Int32): Unit \ r =
        let layered = Int32.bitwiseAnd(Array.get(a, st#layer), Array.get(b, st#mask)) != 0
                  and Int32.bitwiseAnd(Array.get(b, st#layer), Array.get(a, st#mask)) != 0;
        let sa = Array.get(a, st#sensor);
        let sb = Array.get(b, st#sensor);
        if (not layered or (sa and sb)) ()
        else if (sa) sensorPair(st, a, b, b)
        else if (sb) sensorPair(st, a, b, a)
        else contactPair(st, a, b)

    /// sensor の組（other は sensor でない方）。動かない体は出来事を出さない。
    def sensorPair(st: Sweep[r], a: Int32, b: Int32, other: Int32): Unit \ r =
        let movable = Array.get(other, st#dyn) or Array.get(other, st#kin);
        let key = PhysicsWorld2d.Internal.Data.pairKey(Vector.get(a, st#ids), Vector.get(b, st#ids));
        if (not movable) ()
        else if (not isActive(st, a) and not isActive(st, b)) MutList.push(key, st#out#keptSensed)
        else {
            let contacts = collide(st, a, b);
            if (List.exists(c -> sepOf(c) <= 0.0, contacts)) MutList.push(key, st#out#sensed) else ()
        }

    def sepOf(c: PhysicsWorld2d.Internal.Narrowphase.Contact): Float64 = let (_, _, _, _, sep, _) = c; sep

    def collide(st: Sweep[r], a: Int32, b: Int32): List[PhysicsWorld2d.Internal.Narrowphase.Contact] \ r =
        PhysicsWorld2d.Internal.Narrowphase.collideWith(Vector.get(a, st#shapes), Vector.get(a, st#polys), poseOf(st#bs, a),
                                                        Vector.get(b, st#shapes), Vector.get(b, st#polys), poseOf(st#bs, b))

    /// 押し合う組: どちらも Dynamic でなければ捨て、どちらも止まっている（眠りか止まった Kinematic・Fixed）なら島だけつないで触れたままと見る。
    def contactPair(st: Sweep[r], a: Int32, b: Int32): Unit \ r =
        let da = Array.get(a, st#dyn);
        let db = Array.get(b, st#dyn);
        let key = PhysicsWorld2d.Internal.Data.pairKey(Vector.get(a, st#ids), Vector.get(b, st#ids));
        if (not da and not db) ()
        else if (not isActive(st, a) and not isActive(st, b)) {
            if (da and db) union(st#parent, a, b) else ();
            MutList.push(key, st#out#kept)
        }
        else narrowPair(st, a, b, key)

    def narrowPair(st: Sweep[r], a: Int32, b: Int32, key: Int64): Unit \ r =
        let manifold = collide(st, a, b);
        if (List.isEmpty(manifold)) ()
        else {
            let da = Array.get(a, st#dyn);
            let db = Array.get(b, st#dyn);
            if (da and db) union(st#parent, a, b) else ();
            if (Array.get(a, st#kinMoving) and db and Array.get(b, st#asleep)) Array.put(true, b, st#touchWake) else ();
            if (Array.get(b, st#kinMoving) and da and Array.get(a, st#asleep)) Array.put(true, a, st#touchWake) else ();
            let points = st#out#points;
            let first = MutList.size(points);
            manifold |> List.forEach(m -> {
                let (nx, ny, px, py, sep, feature) = m;
                MutList.push((a, b, nx, ny, px, py, sep, key, feature), points)
            });
            MutList.push((key, first, List.length(manifold)), st#out#manifolds);
            let nearest = manifold |> List.foldLeft((acc, c) -> Float64.min(acc, sepOf(c)), Float64.maxValue());
            MutList.push((key, nearest), st#out#contactSeps)
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

    type alias Islands[r: Region] = { dyn = Array[Bool, r], asleep = Array[Bool, r], woken = Array[Bool, r], touchWake = Array[Bool, r],
                                      bs = Array[Float64, r], parent = Array[Int32, r] }

    /// 起きた体が 1 つでもある島（と動く Kinematic が触れた体の島）の、眠っていた体を次の刻みから起こす。
    def wakeIslands(rc: Region[r], il: Islands[r], n: Int32): Unit \ r =
        let islandAwake = Array.repeat(rc, n, false);
        markAwakeIslands(il, islandAwake, 0, n);
        wakeMarked(il, islandAwake, 0, n)

    def markAwakeIslands(il: Islands[r], islandAwake: Array[Bool, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            let awake = Array.get(i, il#dyn) and not Array.get(i, il#asleep);
            if (awake or Array.get(i, il#touchWake)) Array.put(true, find(il#parent, i), islandAwake) else ();
            markAwakeIslands(il, islandAwake, i + 1, n)
        }

    def wakeMarked(il: Islands[r], islandAwake: Array[Bool, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            if (Array.get(i, il#dyn) and Array.get(i, il#asleep) and Array.get(find(il#parent, i), islandAwake)) {
                Array.put(false, i, il#asleep); Array.put(0.0, i * bStride() + 10, il#bs); Array.put(true, i, il#woken)
            } else ();
            wakeMarked(il, islandAwake, i + 1, n)
        }

    type alias SleepLimits = { dt = Float64, linear = Float64, angular = Float64 }

    /// 眠りの時計を足す（解いた後の速さで見る。食い込みを戻す速さが残った値で見ると、積んだ物がいつまでも眠らない）。
    def updateTimers(sv: Solve[r], limits: SleepLimits, i: Int32): Unit \ r =
        if (i >= sv#n) ()
        else {
            if (PhysicsWorld2d.Internal.Solver.moving(sv#dyn, sv#asleep, sv#woken, i)) {
                let bs = sv#bs;
                let o = i * bStride();
                let vx = Array.get(o + 4, bs);
                let vy = Array.get(o + 5, bs);
                let w = Array.get(o + 6, bs);
                let slow = limits#linear > 0.0 and limits#angular > 0.0 and vx * vx + vy * vy < limits#linear * limits#linear and w * w < limits#angular * limits#angular;
                Array.put(if (slow) Array.get(o + 10, bs) + limits#dt else 0.0, o + 10, bs)
            } else ();
            updateTimers(sv, limits, i + 1)
        }

    /// 島ごとに、全部の体が sleepAfter 秒続けて遅ければ眠らせる。
    def sleepIslands(rc: Region[r], sv: Solve[r], parent: Array[Int32, r]): Unit \ r =
        let n = sv#n;
        let islandMin = Array.repeat(rc, n, Float64.maxValue());
        minTimers(sv, parent, islandMin, 0);
        sleepWhere(sv, parent, islandMin, 0)

    def minTimers(sv: Solve[r], parent: Array[Int32, r], islandMin: Array[Float64, r], i: Int32): Unit \ r =
        if (i >= sv#n) ()
        else {
            if (Array.get(i, sv#dyn)) {
                let root = find(parent, i);
                let t = if (Array.get(i, sv#woken)) 0.0 else Array.get(i * bStride() + 10, sv#bs);
                Array.put(Float64.min(t, Array.get(root, islandMin)), root, islandMin)
            } else ();
            minTimers(sv, parent, islandMin, i + 1)
        }

    def sleepWhere(sv: Solve[r], parent: Array[Int32, r], islandMin: Array[Float64, r], i: Int32): Unit \ r =
        if (i >= sv#n) ()
        else {
            if (PhysicsWorld2d.Internal.Solver.moving(sv#dyn, sv#asleep, sv#woken, i) and Array.get(find(parent, i), islandMin) >= sleepAfter()) {
                let o = i * bStride();
                Array.put(true, i, sv#asleep); Array.put(0.0, o + 4, sv#bs); Array.put(0.0, o + 5, sv#bs); Array.put(0.0, o + 6, sv#bs)
            } else ();
            sleepWhere(sv, parent, islandMin, i + 1)
        }

    // ── 出来事（前の刻みの組との差分） ──

    /// 前に触れていた組 prev（並んだ鍵）と、この刻みの組から、今触れている組（並んだ鍵）と出来事（鍵の順）。
    def diffTouching(rc: Region[r], prev: Vector[Int64], seps: Vector[(Int64, Float64)],
                     kept: Vector[Int64]): (Vector[Int64], List[CollisionEvent2d.CollisionEvent2d]) \ r =
        let active = PhysicsWorld2d.Internal.Solver.sortedKeys(rc, Vector.map(fst, seps));
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
