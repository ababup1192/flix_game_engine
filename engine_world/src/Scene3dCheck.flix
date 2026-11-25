// Scene3dCheck — 3D の部屋の見た目（置いた物）と当たり（CollisionWorld3d）の食い違いと、外への抜け穴を調べる（純粋）。
// ゲームのテストが `Assert.assertEq(expected = Nil, Scene3dCheck.check(..))` の 1 行で呼び、置き直すたびに止まる。
// WhyNot: lint にしない — 配置は Doc の値からコードで作るので、ソースを読む検査には見えない。
// WhyNot: 重なり・浮きを拾わない — 見た目の磨きで、遊べなくなる不具合（見えない壁・通れる柵・抜け穴）とは重さが違う。
pub mod Scene3dCheck {

    /// 見つけた食い違い 1 つ（座標は m・0.01 に丸める）。
    /// InvisibleWall = 見た目の三角形がどれも掛からない当たりの箱（箱の真ん中）・
    /// PassableVisual = 体の高さに掛かる見た目なのに、体の半径の内に当たりの箱が無い物（置いた物の名前・名前が無ければ "#<番号>"）・
    /// EscapeHole = start から体が歩いて当たりの箱の集まりの外へ出られる所（外へ出る手前の升の真ん中・高さは start）。
    pub enum Problem with Eq, Order, ToString {
        case InvisibleWall(Float64, Float64, Float64)
        case PassableVisual(String)
        case EscapeHole(Float64, Float64, Float64)
    }

    /// visible（見た目）と world（当たり）と body（歩く体）と start（体の足の位置）を照らした食い違い（InvisibleWall → PassableVisual → EscapeHole の順・それぞれ来た順）。
    pub def check(visible: List[Scene3d.Instance3d], world: CollisionWorld3d.CollisionWorld3d, body: CharacterBody3d.Settings, start: Vec3.Vec3): List[Problem] =
        let boxes = CollisionWorld3d.boxes(world) |> List.map(b -> (b, aabbOfBox(b)));
        List.flatten(invisibleWalls(visible, boxes) :: passableVisuals(visible, world, body) :: escapeHoles(world, boxes, body, start) :: Nil)

    // ── 箱の形 ──

    /// 軸にそろった箱 (min, max)。
    type alias Aabb = { min = Vec3.Vec3, max = Vec3.Vec3 }

    def aabbOfBox(b: CollisionShape3d.Box3d): Aabb = aabbOfPoints(CollisionShape3d.cornersOfBox(b))

    def aabbOfPoints(ps: List[Vec3.Vec3]): Aabb =
        let bounds = Mesh3d.boundsOfPoints(ps);
        { min = bounds#min, max = bounds#max }

    def overlaps(a: Aabb, b: Aabb): Bool =
        a#min#x <= b#max#x and b#min#x <= a#max#x and a#min#y <= b#max#y and b#min#y <= a#max#y and a#min#z <= b#max#z and b#min#z <= a#max#z

    def grown(a: Aabb, dx: Float64, dy: Float64): Aabb =
        { min = Vec3.v3(a#min#x - dx, a#min#y - dy, a#min#z - dx), max = Vec3.v3(a#max#x + dx, a#max#y + dy, a#max#z + dx) }

    def round2(x: Float64): Float64 = Float64.round(x * 100.0) / 100.0

    // ── 見えない壁 ──

    /// 三角形の索引の升の幅（m）。
    def triangleCell(): Float64 = 1.0

    /// 箱と三角形が掛かるとみなす隙間（m）。
    // WhyNot: 隙間を 0 にしない — 壁の箱を見た目の面とぴったり同じ所に置くと、丸めで掛からない側に落ちる。
    def touchGap(): Float64 = 0.02

    /// world の三角形 1 枚（頂点 3 つとその AABB）。
    type alias Triangle = { a = Vec3.Vec3, b = Vec3.Vec3, c = Vec3.Vec3, bounds = Aabb }

    def invisibleWalls(visible: List[Scene3d.Instance3d], boxes: List[(CollisionShape3d.Box3d, Aabb)]): List[Problem] = region rc {
        let cells: MutMap[(Int32, Int32), MutList[Triangle, rc], rc] = MutMap.empty(rc);
        visible |> List.forEach(i -> List.forEach(addTriangle(rc, cells), trianglesOf(i)));
        boxes |> List.filterMap(match (b, a) -> if (isCovered(cells, a)) None
                                                else Some(Problem.InvisibleWall(round2(b#center#x), round2(b#center#y), round2(b#center#z))))
    }

    /// i の world の三角形（骨つきは姿勢を当てない形のまま）。
    def trianglesOf(i: Scene3d.Instance3d): List[Triangle] =
        let f = Scene3d.instanceFieldsOf(i);
        let p = Mesh3d.positions(f#mesh);
        let ix = Mesh3d.indices(f#mesh);
        let at = (k: Int32) -> { let v = Vector.get(k, ix) * 3; Mat4.apply(f#world, Vec3.v3(Vector.get(v, p), Vector.get(v + 1, p), Vector.get(v + 2, p))) };
        List.range(0, Vector.length(ix) / 3) |> List.map(t -> {
            let (a, b, c) = (at(t * 3), at(t * 3 + 1), at(t * 3 + 2));
            { a = a, b = b, c = c, bounds = aabbOfPoints(a :: b :: c :: Nil) }
        })

    def cellOf(x: Float64): Int32 = Float64.floor(x / triangleCell()) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    def addTriangle(rc: Region[r], cells: MutMap[(Int32, Int32), MutList[Triangle, r], r], t: Triangle): Unit \ r =
        foreach (ix <- List.range(cellOf(t#bounds#min#x), cellOf(t#bounds#max#x) + 1); iz <- List.range(cellOf(t#bounds#min#z), cellOf(t#bounds#max#z) + 1)) {
            let list = MutMap.getOrElsePut((ix, iz), MutList.empty(rc), cells);
            MutList.push(t, list)
        }

    /// 箱 a に見た目が掛かるか: 中を通る三角形か、箱の面の上に収まる三角形が 1 枚でもある。
    // WhyNot: 三角形の AABB が掛かるだけで見えるとしない — 床の大きな三角形は、床に置いた見えない箱の底の面に必ず触れる。
    def isCovered(cells: MutMap[(Int32, Int32), MutList[Triangle, r], r], a: Aabb): Bool \ r =
        let outer = grown(a, touchGap(), touchGap());
        let inner = grown(a, 0.0 - touchGap(), 0.0 - touchGap());
        let hits = (t: Triangle) -> overlaps(t#bounds, outer) and (isInside(t#bounds, outer) or crossesPlane(t, inner));
        List.range(cellOf(outer#min#x), cellOf(outer#max#x) + 1) |> List.exists(ix ->
            List.range(cellOf(outer#min#z), cellOf(outer#max#z) + 1) |> List.exists(iz ->
                MutMap.get((ix, iz), cells) |> Option.exists(list -> MutList.exists(hits, list))))

    def isInside(t: Aabb, a: Aabb): Bool =
        a#min#x <= t#min#x and t#max#x <= a#max#x and a#min#y <= t#min#y and t#max#y <= a#max#y and a#min#z <= t#min#z and t#max#z <= a#max#z

    /// 三角形 t の面が箱 a の中を通るか（a の角が面の両側にある。a の AABB と t の AABB が掛かることは呼ぶ側が見る）。
    def crossesPlane(t: Triangle, a: Aabb): Bool =
        if (a#min#x > a#max#x or a#min#y > a#max#y or a#min#z > a#max#z) false
        else {
            let n = Vec3.cross(Vec3.sub(t#b, t#a), Vec3.sub(t#c, t#a));
            let sides = cornersOf(a) |> List.map(p -> Vec3.dot(n, Vec3.sub(p, t#a)));
            List.exists(s -> s > 0.0, sides) and List.exists(s -> s < 0.0, sides)
        }

    def cornersOf(a: Aabb): List[Vec3.Vec3] = Mesh3d.cornersOf({ min = a#min, max = a#max })

    // ── 見えるのに通れる物 ──

    /// 同じ名前の物（glb の 1 つのノードの部品）は 1 つにまとめる（初めに見つけた順）。
    def passableVisuals(visible: List[Scene3d.Instance3d], world: CollisionWorld3d.CollisionWorld3d, body: CharacterBody3d.Settings): List[Problem] =
        visible |> List.mapWithIndex((k, i) -> (k, i)) |> List.filterMap(match (k, i) ->
            Scene3d.worldBoundsOf(i) |> Option.filter(b -> isPassable(world, body, { min = b#min, max = b#max })) |> Option.map(_ -> keyOf(k, i)))
            |> List.foldLeft((acc, key) -> if (Set.memberOf(key, fst(acc))) acc else (Set.insert(key, fst(acc)), key :: snd(acc)), (Set.empty(), Nil))
            |> snd |> List.reverse |> List.map(Problem.PassableVisual)

    def keyOf(k: Int32, i: Scene3d.Instance3d): String = if (Scene3d.nameOf(i) == "") "#${k}" else Scene3d.nameOf(i)

    /// b が立つ床の上で体の高さ（段の上から頭まで）に掛かり、b の足元のどこかに体が当たりの箱に掛からずに立てるか。
    def isPassable(world: CollisionWorld3d.CollisionWorld3d, body: CharacterBody3d.Settings, b: Aabb): Bool =
        let mid = Vec3.mul(Vec3.add(b#min, b#max), 0.5);
        let near = CollisionWorld3d.boxesNear(world, mid, Float64.max(b#max#x - b#min#x, b#max#z - b#min#z) / 2.0) |> List.map(aabbOfBox);
        floorUnder(near, mid, b#min#y, body) |> Option.exists(floor ->
            b#max#y > floor + body#stepHeight and b#min#y < floor + body#height
                and List.exists(p -> not isBlocked(world, body, floor, p), footprintOf(b, floor, body)))

    /// b の足元に体の半径の半分ごとに並べた点（高さは floor）。
    def footprintOf(b: Aabb, floor: Float64, body: CharacterBody3d.Settings): List[Vec3.Vec3] =
        let step = Float64.max(0.05, body#radius / 2.0);
        let count = (lo: Float64, hi: Float64) -> Float64.floor((hi - lo) / step) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let along = (lo: Float64, hi: Float64) -> List.range(0, count(lo, hi) + 1) |> List.map(k -> Float64.min(hi, lo + Int32.toFloat64(k) * step));
        along(b#min#x, b#max#x) |> List.flatMap(x -> along(b#min#z, b#max#z) |> List.map(z -> Vec3.v3(x, floor, z)))

    /// 点 mid の真下で、上の面が bottom + 段の高さ以下の、体が乗れる広さ（縦横とも体の直径以上）の箱の一番高い上の面（無ければ None）。
    // WhyNot: 狭い箱の上を床にしない — 窓の下の腰壁や戸の上の鴨居の上を床と見ると、窓の障子や吊った灯りが体の高さに入って通れる物に見える。
    def floorUnder(near: List[Aabb], mid: Vec3.Vec3, bottom: Float64, body: CharacterBody3d.Settings): Option[Float64] =
        let standable = (a: Aabb) -> a#max#x - a#min#x >= 2.0 * body#radius and a#max#z - a#min#z >= 2.0 * body#radius;
        near |> List.filter(a -> a#min#x <= mid#x and mid#x <= a#max#x and a#min#z <= mid#z and mid#z <= a#max#z and a#max#y <= bottom + body#stepHeight and standable(a))
             |> List.map(a -> a#max#y) |> List.maximum

    // ── 抜け穴 ──

    def escapeHoles(world: CollisionWorld3d.CollisionWorld3d, boxes: List[(CollisionShape3d.Box3d, Aabb)], body: CharacterBody3d.Settings, start: Vec3.Vec3): List[Problem] =
        boxes |> List.map(snd) |> List.reduceLeft(union) |> Option.flatMap(all -> escapeFrom(world, gridOf(all, body, start), body, start)) |> Option.toList

    def union(a: Aabb, b: Aabb): Aabb =
        { min = Vec3.v3(Float64.min(a#min#x, b#min#x), Float64.min(a#min#y, b#min#y), Float64.min(a#min#z, b#min#z)),
          max = Vec3.v3(Float64.max(a#max#x, b#max#x), Float64.max(a#max#y, b#max#y), Float64.max(a#max#z, b#max#z)) }

    /// 体をたどる升の並び。x0・z0 = 升 (0, 0) の角・step = 升の幅・nx・nz = 升の数（外周の 1 列は当たりの箱の集まりの外）・feet = 体の足の高さ。
    type alias Grid = { x0 = Float64, z0 = Float64, step = Float64, nx = Int32, nz = Int32, feet = Float64 }

    /// 当たりの箱の集まり all を外周 1 列の升で囲んだ升の並び。升の幅は体の半径（細かすぎる時は 0.1 m）。
    def gridOf(all: Aabb, body: CharacterBody3d.Settings, start: Vec3.Vec3): Grid =
        let step = Float64.max(0.1, body#radius);
        let (x0, z0) = (all#min#x - step, all#min#z - step);
        { x0 = x0, z0 = z0, step = step, nx = indexOf(all#max#x + step, x0, step) + 1, nz = indexOf(all#max#z + step, z0, step) + 1, feet = start#y }

    def indexOf(v: Float64, origin: Float64, step: Float64): Int32 = Float64.floor((v - origin) / step) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    def centerOf(g: Grid, c: (Int32, Int32)): Vec3.Vec3 =
        let (x, z) = c;
        Vec3.v3(g#x0 + (Int32.toFloat64(x) + 0.5) * g#step, g#feet, g#z0 + (Int32.toFloat64(z) + 0.5) * g#step)

    def isOutside(g: Grid, c: (Int32, Int32)): Bool =
        let (x, z) = c;
        x <= 0 or z <= 0 or x >= g#nx - 1 or z >= g#nz - 1

    /// 体の足の升から、体の通れる升を 4 方向にたどり、外周の升に着いたら、その手前の升の真ん中。
    // WhyNot: 升の数に上限を置かない — 当たりの箱の集まりの広さで決まり、ゲームのテストが 1 回流すだけの検査。
    def escapeFrom(world: CollisionWorld3d.CollisionWorld3d, g: Grid, body: CharacterBody3d.Settings, start: Vec3.Vec3): Option[Problem] = region rc {
        let seen: MutSet[(Int32, Int32), rc] = MutSet.empty(rc);
        let queue: MutDeque[((Int32, Int32), (Int32, Int32)), rc] = MutDeque.empty(rc);
        let first = (indexOf(start#x, g#x0, g#step), indexOf(start#z, g#z0, g#step));
        MutSet.add(first, seen);
        MutDeque.pushBack((first, first), queue);
        walk(world, g, body, seen, queue)
    }

    def walk(world: CollisionWorld3d.CollisionWorld3d, g: Grid, body: CharacterBody3d.Settings,
             seen: MutSet[(Int32, Int32), r], queue: MutDeque[((Int32, Int32), (Int32, Int32)), r]): Option[Problem] \ r =
        match MutDeque.popFront(queue) {
            case None => None
            case Some((c, prev)) if isOutside(g, c) =>
                let at = centerOf(g, prev);
                Some(Problem.EscapeHole(round2(at#x), round2(at#y), round2(at#z)))
            case Some((c, _)) =>
                let (x, z) = c;
                ((x + 1, z) :: (x - 1, z) :: (x, z + 1) :: (x, z - 1) :: Nil) |> List.forEach(n ->
                    if (MutSet.memberOf(n, seen) or isBlocked(world, body, g#feet, centerOf(g, n))) ()
                    else { MutSet.add(n, seen); MutDeque.pushBack((n, c), queue) });
                walk(world, g, body, seen, queue)
        }

    /// 体（足の高さ feet）を p に立たせると、段の高さより上で当たりの箱に掛かるか。
    def isBlocked(world: CollisionWorld3d.CollisionWorld3d, body: CharacterBody3d.Settings, feet: Float64, p: Vec3.Vec3): Bool =
        let band = { min = Vec3.v3(p#x - body#radius, feet + body#stepHeight, p#z - body#radius),
                     max = Vec3.v3(p#x + body#radius, feet + body#height, p#z + body#radius) };
        CollisionWorld3d.boxesNear(world, p, body#radius) |> List.exists(b -> overlaps(aabbOfBox(b), band))
}
