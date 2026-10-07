// Collision — たくさんの物体の中から、実際に重なっている組を見つけて返す。
// 当たり判定を手書きしなくても、各物体に Collider を付けて detectCollisions を呼ぶだけで
// 重なりペアが得られる。全組み合わせを総当りせず空間を格子で区切って調べるので、物体が増えても速い。
// 利用例: 弾と敵の衝突を集める / プレイヤーが踏んだ床を探す / 押し合う物体の対を列挙する。
// 注意: 重なりの形状判定と layer/mask のビット照合は engine の純粋関数をそのまま使う。
// 注意: 巨大な 1 枚の多角形は格子のセル幅を押し広げて broadphase を退化させる
// （セル幅は最大の形状から決まるため）。地形の多角形は 1〜2 画面幅・〜64 頂点のチャンクに分けること。

pub mod Collision {

    /// 衝突の形（engine の CollisionShape2D を再利用）＋ layer/mask（engine と同じ意味論）。
    pub type alias Collider = {
        shape = CollisionShape2D,
        layer = Int32,   // 自分が属するレイヤー
        mask  = Int32    // 観測するレイヤー（mask & 相手 layer != 0 で判定対象）
    }

    // ── 公開 API ──

    /// position と collider を両方持つ entity から、衝突しているペアを列挙する。
    /// 同じペアは (idA < idB) で1回だけ。layer/mask で除外されたペアは含めない。
    /// 注: layer/mask 判定は無方向（どちらかが相手を観測していれば検出）。engine の
    /// monitoring/monitorable に当たる概念は持たない。
    pub def detectCollisions(positions: Map[EntityId, Vec2.Vec2],
                             colliders: Map[EntityId, Collider]): List[(EntityId, EntityId)] =
        let bodies = Query.with2(positions, colliders);   // Map[EntityId, (Vec2, Collider)]
        let cs = cellSize(colliders);
        let grid = buildGrid(cs, bodies);
        Map.foldLeftWithKey((acc, id, body) ->
            let (pos, col) = body;
            let pairs = neighborhoodIds(cellOf(cs, pos), grid)
                |> List.filter(other -> id < other)            // dedup＋自己ペア除外
                |> List.filterMap(other -> tryPair(id, pos, col, other, bodies));
            List.append(pairs, acc), Nil, bodies)

    // ── broadphase（一様空間グリッド）──
    // セル幅は「衝突しうる最大の中心間距離 = 2×最大 extent」以上にすると、重なるペアは
    // 必ず同一/隣接セルに入り、3×3 近傍探索で取りこぼさない。固定値ではなく collider から
    // 導出するので、どんな形状サイズのゲームでも正しい（再利用 lib の不変条件をコードで満たす）。

    def cellSize(colliders: Map[EntityId, Collider]): Float64 =
        let maxExtent = Map.foldLeftWithKey((acc, _id, c) -> Float64.max(acc, extentOf(c)), 0.0, colliders);
        Float64.max(1.0, 2.0 * maxExtent)

    /// 形状の境界半径（中心から最遠点までの距離）。
    def extentOf(c: Collider): Float64 =
        match c#shape {
            case CollisionShape2D.CircleShape2D(s)  => s#radius
            case CollisionShape2D.RectShape2D(s)    => Vec2.length({x = s#width / 2.0, y = s#height / 2.0})
            case CollisionShape2D.CapsuleShape2D(s) => s#height / 2.0
            case CollisionShape2D.SlopeShape2D(s)   => Vec2.length({x = s#width / 2.0, y = s#height / 2.0})
            case CollisionShape2D.PolygonShape2D(s) =>
                List.foldLeft((acc, p) -> Float64.max(acc, Vec2.length(p)), 0.0, s#points)
        }

    def buildGrid(cs: Float64, bodies: Map[EntityId, (Vec2.Vec2, Collider)]):
            Map[(Int32, Int32), List[EntityId]] =
        Map.foldLeftWithKey((g, id, body) -> let (pos, _) = body; addToGrid(cs, id, pos, g),
                             Map.empty(), bodies)

    def toCell(cs: Float64, v: Float64): Int32 =
        Num.floorInt(v / cs)

    def cellOf(cs: Float64, p: Vec2.Vec2): (Int32, Int32) = (toCell(cs, p#x), toCell(cs, p#y))

    def addToGrid(cs: Float64, id: EntityId, pos: Vec2.Vec2,
                  grid: Map[(Int32, Int32), List[EntityId]]): Map[(Int32, Int32), List[EntityId]] =
        let c = cellOf(cs, pos);
        let cur = Map.get(c, grid) |> Option.getWithDefault(Nil);
        Map.insert(c, id :: cur, grid)

    /// セル自身＋8 近傍に居る entity id を集める。
    def neighborhoodIds(c: (Int32, Int32), grid: Map[(Int32, Int32), List[EntityId]]): List[EntityId] =
        let (cx, cy) = c;
        let offs = -1 :: 0 :: 1 :: Nil;
        List.flatMap(dx ->
            List.flatMap(dy ->
                Map.get((cx + dx, cy + dy), grid) |> Option.getWithDefault(Nil), offs),
            offs)

    // ── narrowphase（engine の純粋関数を再利用）──

    def tryPair(idA: EntityId, posA: Vec2.Vec2, colA: Collider, idB: EntityId,
                bodies: Map[EntityId, (Vec2.Vec2, Collider)]): Option[(EntityId, EntityId)] =
        match Map.get(idB, bodies) {
            case Some((posB, colB)) =>
                if (masksMatch(colA, colB) and
                    CollisionShape2D.checkOverlap(posA, colA#shape, posB, colB#shape))
                    Some((idA, idB))
                else None
            case None => None
        }

    /// どちらか一方が相手を観測していれば判定対象（engine の (mask & layer) と同じ）。
    def masksMatch(a: Collider, b: Collider): Bool =
        Int32.bitwiseAnd(a#mask, b#layer) != 0i32 or Int32.bitwiseAnd(b#mask, a#layer) != 0i32
}
