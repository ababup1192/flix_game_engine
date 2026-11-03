// Ray3d — 3D のレイと、形との交わり（純粋）。座標の約束は scene3d/Scene3d.flix の頭。
// 一人称で見ている物を調べる（Camera3d.forwardRay → pickNearest）・足元の床を探す（CharacterBody3d）に使う。

/// 半直線（閉じた型 — 向きは長さ 1 に直して持つ）。ray3d で作る。
pub mod Ray3d {

    enum RayData { case RayData({ origin = Vec3.Vec3, direction = Vec3.Vec3 }) }

    pub type alias Ray3d = RayData

    /// 当たった所。distance = 始まりからの距離（m）・point = 当たった点・normal = 当たった面の向き（長さ 1・レイの来た側を向く）。
    pub type alias RayHit = { distance = Float64, point = Vec3.Vec3, normal = Vec3.Vec3 }

    /// pickNearest の的。Shape = 当たり判定の形・Mesh = 形と、形の座標 → world の行列（三角形を全部見る）。
    pub enum RayTarget {
        case Shape(CollisionShape3d)
        case Mesh(Mesh3d.Mesh3d, Mat4.Mat4)
    }

    /// origin から toward の向きへ伸びるレイ。toward の長さが 0 か NaN・無限大を含む時は、何にも当たらないレイ。
    pub def ray3d(origin: Vec3.Vec3, toward: Vec3.Vec3): Ray3d =
        let finite = Float64.isFinite(toward#x) and Float64.isFinite(toward#y) and Float64.isFinite(toward#z);
        RayData.RayData({ origin = origin, direction = if (finite) Vec3.normalized(toward) else Vec3.zero() })

    /// 始まりの点。
    pub def origin(r: Ray3d): Vec3.Vec3 = match r { case RayData.RayData(d) => d#origin }

    /// 向き（長さ 1。何にも当たらないレイは 0）。
    pub def direction(r: Ray3d): Vec3.Vec3 = match r { case RayData.RayData(d) => d#direction }

    /// 始まりから distance だけ進んだ点。
    pub def pointAt(r: Ray3d, distance: Float64): Vec3.Vec3 = Vec3.add(origin(r), Vec3.mul(direction(r), distance))

    // ════════════════════════════════════════════════════════════════════
    // 箱
    // ════════════════════════════════════════════════════════════════════

    /// 箱の向きの座標で、軸 1 本の板の間にいる距離の範囲（向きがその軸に平行で板の外なら None）。
    def slab(o: Float64, d: Float64, h: Float64): Option[(Float64, Float64)] =
        if (Float64.abs(d) < 1.0e-12) (if (Float64.abs(o) <= h) Some(((0.0 - Float64.maxValue()), Float64.maxValue())) else None)
        else {
            let t1 = (0.0 - h - o) / d;
            let t2 = (h - o) / d;
            Some((Float64.min(t1, t2), Float64.max(t1, t2)))
        }

    /// レイが箱の中にいる距離の範囲と、入る面の向き（world。レイの来た側を向く）。範囲が空なら None。
    def boxSpan(r: Ray3d, b: CollisionShape3d.Box3d): Option[(Float64, Float64, Vec3.Vec3)] =
        let rel = Vec3.sub(origin(r), b#center);
        let d = direction(r);
        let along = (a: Vec3.Vec3, h: Float64) -> {
            let dl = Vec3.dot(d, a);
            slab(Vec3.dot(rel, a), dl, h) |> Option.map(s -> (fst(s), snd(s), if (dl > 0.0) Vec3.mul(a, -1.0) else a))
        };
        forM (
            sx <- along(b#ax, b#half#x);
            sy <- along(b#ay, b#half#y);
            sz <- along(b#az, b#half#z);
            span <- {
                let ss = sx :: sy :: sz :: Nil;
                let entry = ss |> List.foldLeft((best, s) -> { let (t, _, _) = s; let (bt, _, _) = best; if (t > bt) s else best },
                                                 ((0.0 - Float64.maxValue()), Float64.maxValue(), Vec3.zero()));
                let (tmin, _, normal) = entry;
                let tmax = ss |> List.foldLeft((acc, s) -> { let (_, t, _) = s; Float64.min(acc, t) }, Float64.maxValue());
                if (tmin <= tmax) Some((tmin, tmax, normal)) else None
            }
        ) yield span

    /// 箱 b に外から当たる所（maxDistance まで）。始まりが箱の中（面の上を含まない）なら None（Unity の Raycast・Godot の intersect_ray と同じ）。
    pub def hitBox(r: Ray3d, maxDistance: Float64, b: CollisionShape3d.Box3d): Option[RayHit] =
        boxSpan(r, b) |> Option.flatMap(span -> {
            let (tmin, _, normal) = span;
            if (tmin >= 0.0 and tmin <= maxDistance) Some({ distance = tmin, point = pointAt(r, tmin), normal = normal }) else None
        })

    /// 0 から maxDistance までのレイの区間が箱 b に触れるか（始まりが中でも真）。
    def touchesBox(r: Ray3d, maxDistance: Float64, b: CollisionShape3d.Box3d): Bool =
        match boxSpan(r, b) {
            case Some((tmin, tmax, _)) => tmax >= 0.0 and tmin <= maxDistance
            case None                  => false
        }

    // ════════════════════════════════════════════════════════════════════
    // 球とカプセル
    // ════════════════════════════════════════════════════════════════════

    /// 球 s に外から当たる所（maxDistance まで）。始まりが球の中（面の上を含まない）・半径が 0 以下なら None。
    pub def hitSphere(r: Ray3d, maxDistance: Float64, s: CollisionShape3d.Sphere3d): Option[RayHit] =
        let oc = Vec3.sub(origin(r), s#center);
        let b = Vec3.dot(oc, direction(r));
        let c = Vec3.dot(oc, oc) - s#radius * s#radius;
        let disc = b * b - c;
        if (not (s#radius > 0.0) or c < 0.0 or disc < 0.0) None
        else {
            let t = 0.0 - b - Num.sqrt(disc);
            if (t >= 0.0 and t <= maxDistance) {
                let p = pointAt(r, t);
                Some({ distance = t, point = p, normal = Vec3.mul(Vec3.sub(p, s#center), 1.0 / s#radius) })
            } else None
        }

    /// 縦のカプセル c に外から当たる所（maxDistance まで）。始まりがカプセルの中（面の上を含まない）・半径が 0 以下なら None。
    pub def hitCapsule(r: Ray3d, maxDistance: Float64, c: CollisionShape3d.Capsule3d): Option[RayHit] =
        let rad = c#radius;
        let lo = c#feet#y + rad;
        let hi = Float64.max(lo, c#feet#y + c#height - rad);
        let o = origin(r);
        let axisPoint = Vec3.v3(c#feet#x, Float64.max(lo, Float64.min(hi, o#y)), c#feet#z);
        if (not (rad > 0.0) or Vec3.length(Vec3.sub(o, axisPoint)) < rad) None
        else {
            let bottom = hitSphere(r, maxDistance, { center = Vec3.v3(c#feet#x, lo, c#feet#z), radius = rad });
            let top = hitSphere(r, maxDistance, { center = Vec3.v3(c#feet#x, hi, c#feet#z), radius = rad });
            nearestOf(bottom :: top :: hitSide(r, maxDistance, c#feet, rad, lo, hi) :: Nil)
        }

    /// カプセルの筒（半球の真ん中の高さ lo..hi の間）に外から当たる所。
    def hitSide(r: Ray3d, maxDistance: Float64, feet: Vec3.Vec3, rad: Float64, lo: Float64, hi: Float64): Option[RayHit] =
        let o = origin(r);
        let d = direction(r);
        let (ox, oz) = (o#x - feet#x, o#z - feet#z);
        let a = d#x * d#x + d#z * d#z;
        let b = ox * d#x + oz * d#z;
        let c = ox * ox + oz * oz - rad * rad;
        let disc = b * b - a * c;
        if (a < 1.0e-12 or disc < 0.0) None
        else {
            let t = (0.0 - b - Num.sqrt(disc)) / a;
            let p = pointAt(r, t);
            if (t >= 0.0 and t <= maxDistance and p#y >= lo and p#y <= hi)
                Some({ distance = t, point = p, normal = Vec3.v3((p#x - feet#x) / rad, 0.0, (p#z - feet#z) / rad) })
            else None
        }

    /// 当たった所のうち一番近い物（同じ距離なら並びの前）。
    def nearestOf(hits: List[Option[RayHit]]): Option[RayHit] =
        hits |> List.foldLeft((best, h) -> match (best, h) {
            case (Some(bh), Some(nh)) => if (nh#distance < bh#distance) h else best
            case (None, _)            => h
            case (_, None)            => best
        }, None)

    // ════════════════════════════════════════════════════════════════════
    // 三角形と形
    // ════════════════════════════════════════════════════════════════════

    /// 三角形 (a, b, c) に当たる所（表裏とも・縁を含む・maxDistance まで）。面積 0 の三角形とレイが面に平行な時は None。
    pub def hitTriangle(r: Ray3d, maxDistance: Float64, a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3): Option[RayHit] =
        let d = direction(r);
        let e1 = Vec3.sub(b, a);
        let e2 = Vec3.sub(c, a);
        let p = Vec3.cross(d, e2);
        let det = Vec3.dot(e1, p);
        if (Float64.abs(det) < 1.0e-12) None
        else {
            let inv = 1.0 / det;
            let s = Vec3.sub(origin(r), a);
            let u = Vec3.dot(s, p) * inv;
            let q = Vec3.cross(s, e1);
            let v = Vec3.dot(d, q) * inv;
            let t = Vec3.dot(e2, q) * inv;
            if (u < 0.0 or v < 0.0 or u + v > 1.0 or t < 0.0 or t > maxDistance) None
            else {
                let n = Vec3.normalized(Vec3.cross(e1, e2));
                Some({ distance = t, point = pointAt(r, t), normal = if (Vec3.dot(n, d) > 0.0) Vec3.mul(n, -1.0) else n })
            }
        }

    /// 形 mesh（形の座標）を world で置いた物に当たる所（三角形の表裏とも）。境界の箱に触れない時は三角形を見ない。
    /// 三角形を全部見るので、調べる物 1 つに 1 回の想定（部屋の壁を全部並べて毎コマ引かない — 壁は箱で）。
    pub def hitMesh(r: Ray3d, maxDistance: Float64, mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Option[RayHit] =
        if (Mesh3d.vertexCount(mesh) == 0 or not touchesBox(r, maxDistance, CollisionShape3d.boxOfBounds(world, Mesh3d.bounds(mesh)))) None
        else {
            let pos = Mesh3d.positions(mesh);
            let idx = Mesh3d.indices(mesh);
            let vertex = (k: Int32) -> {
                let i = Vector.get(k, idx);
                Mat4.apply(world, Vec3.v3(Vector.get(3 * i, pos), Vector.get(3 * i + 1, pos), Vector.get(3 * i + 2, pos)))
            };
            List.range(0, Mesh3d.triangleCount(mesh)) |> List.foldLeft((best, tri) -> {
                let limit = best |> Option.map(h -> h#distance) |> Option.getWithDefault(maxDistance);
                match hitTriangle(r, limit, vertex(3 * tri), vertex(3 * tri + 1), vertex(3 * tri + 2)) {
                    case Some(h) if Option.forAll(bh -> h#distance < bh#distance, best) => Some(h)
                    case _                                                            => best
                }
            }, None)
        }

    /// 置いた物 i に当たる所。骨つきの物（Scene3d.skinningOf が Some）は形の境界の箱だけで見る
    /// （曲げた形は CPU に無い。曲げで境界の外へ出た所には当たらない）。
    pub def hitInstance(r: Ray3d, maxDistance: Float64, i: Scene3d.Instance3d): Option[RayHit] =
        let f = Scene3d.instanceFieldsOf(i);
        if (Option.nonEmpty(Scene3d.skinningOf(i)))
            CollisionShape3d.boxOfMesh(f#mesh, f#world) |> Option.flatMap(hitBox(r, maxDistance))
        else hitMesh(r, maxDistance, f#mesh, f#world)

    /// 形 1 つに当たる所。
    pub def hitShape(r: Ray3d, maxDistance: Float64, shape: CollisionShape3d): Option[RayHit] =
        match shape {
            case CollisionShape3d.BoxShape3d(b)     => hitBox(r, maxDistance, b)
            case CollisionShape3d.SphereShape3d(s)  => hitSphere(r, maxDistance, s)
            case CollisionShape3d.CapsuleShape3d(c) => hitCapsule(r, maxDistance, c)
        }

    /// 的 1 つに当たる所。
    def hitTarget(r: Ray3d, maxDistance: Float64, target: RayTarget): Option[RayHit] =
        match target {
            case RayTarget.Shape(shape)       => hitShape(r, maxDistance, shape)
            case RayTarget.Mesh(mesh, world)  => hitMesh(r, maxDistance, mesh, world)
        }

    // ════════════════════════════════════════════════════════════════════
    // 名前つきの的から一番近い物
    // ════════════════════════════════════════════════════════════════════

    /// 的の列のうち、レイが最初に当たる物と当たった所（maxDistance まで。同じ距離なら並びの前）。
    /// key はゲームが決める鍵（調べる物の enum・ノードの名前）。壁も「壁」の鍵で同じ列に入れると、壁の向こうの物は選ばれない。
    pub def pickNearest(r: Ray3d, maxDistance: Float64, targets: List[(a, RayTarget)]): Option[(a, RayHit)] =
        targets |> List.foldLeft((best, entry) -> {
            let (key, target) = entry;
            let limit = best |> Option.map(b -> snd(b)#distance) |> Option.getWithDefault(maxDistance);
            match hitTarget(r, limit, target) {
                case Some(h) if Option.forAll(b -> h#distance < snd(b)#distance, best) => Some((key, h))
                case _                                                               => best
            }
        }, None)

    /// glTF のノードの列から、当たり判定の箱の的の列を作る（mesh の無いノードは飛ばす）。鍵は keyOf がノードから決める。
    /// `Ray3d.boxTargetsOf(n -> n#name, Model3d.nodesWithPrefix("COL_", model))`。読み込みで 1 回作って持つ（毎コマ呼ばない）。
    pub def boxTargetsOf(keyOf: Model3d.ModelNode -> a, nodes: List[Model3d.ModelNode]): List[(a, RayTarget)] =
        nodes |> List.filterMap(n -> CollisionShape3d.boxOfNode(n) |> Option.map(b -> (keyOf(n), RayTarget.Shape(CollisionShape3d.BoxShape3d(b)))))
}
