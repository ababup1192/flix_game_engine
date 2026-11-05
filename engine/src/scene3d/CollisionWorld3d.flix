// CollisionWorld3d — 動かない当たり判定の箱の集まりと、足元の近くの箱だけを引く口（純粋）。座標の約束は scene3d/Scene3d.flix の頭。
// 歩く体（engine_world の CharacterBody3d）が毎コマ周りの箱だけを見るために使う。動く箱（扉の板）はここに入れず、毎コマ別に渡す。

/// 動かない箱の集まり（閉じた型）。build で作る。
pub mod CollisionWorld3d {

    /// 箱 1 つの水平の広がり（x と z の最小・最大。向きのある箱を囲む軸にそろった範囲）。
    type alias Footprint = { minX = Float64, maxX = Float64, minZ = Float64, maxZ = Float64 }

    /// boxes = 箱（build に渡した並びから NaN・無限大の箱を除いた物）・footprints = 箱ごとの水平の広がり・
    /// cellSize = xz の格子の 1 マスの幅・cells = マス → そこに掛かる箱の番号・cellCount = cells のマスの数・
    /// wide = 掛かるマスが多すぎて全部の問いで見る箱の番号。
    // WhyNot: マスの数を問いのたびに Map.size で数えない — 木を全部たどるので、毎コマ体の数だけ呼ばれると格子の大きさに比例して重い。
    type alias WorldRec = { boxes = Vector[CollisionShape3d.Box3d], footprints = Vector[Footprint], cellSize = Float64,
                            cells = Map[(Int32, Int32), List[Int32]], cellCount = Int32, wide = List[Int32] }

    enum WorldData { case WorldData(WorldRec) }

    pub type alias CollisionWorld3d = WorldData

    /// cellSize が 0 以下・NaN・無限大の時に使う 1 マスの幅（m）。
    pub def defaultCellSize(): Float64 = 2.0

    /// 箱 1 つがこれより多くのマスに掛かる時は、格子に入れず全部の問いで見る（地面の大きな板で格子が膨らまない）。
    def wideCellLimit(): Int32 = 64

    /// 問いの範囲がこれより多くのマスに掛かる時は、格子を引かず全部の箱を見る。
    def queryCellLimit(): Int32 = 1024

    def recOf(w: CollisionWorld3d): WorldRec = match w { case WorldData.WorldData(r) => r }

    /// 箱の無い集まり（扉など動く箱だけで歩かせる時）。
    pub def empty(): CollisionWorld3d = build(defaultCellSize(), Nil)

    /// 箱の列を xz の格子（1 マスの幅 cellSize m）に入れた集まり。並びはそのまま保つ（押し出しは並びの順に足すので答えが並びで決まる）。
    /// 幅は体の直径から部屋の幅くらい（1〜4 m）が目安。NaN・無限大を含む箱は入れず 1 行知らせる。
    pub def build(cellSize: Float64, boxes: List[CollisionShape3d.Box3d]): CollisionWorld3d =
        let cs = if (Float64.isFinite(cellSize) and cellSize > 0.0) cellSize
                 else Log.fellBackThen("collision3d", "CollisionWorld3d.build の cellSize ${Float64.toString(cellSize)}", "既定の ${Float64.toString(defaultCellSize())} m",
                                       "0 以下か NaN・無限大", defaultCellSize());
        let kept = List.filter(CollisionShape3d.isFinite, boxes);
        let dropped = List.length(boxes) - List.length(kept);
        let kept1 = if (dropped == 0) kept else Log.warnThen("CollisionWorld3d.build: NaN か無限大を含む箱 ${Int32.toString(dropped)} 個を入れませんでした", kept);
        let footprints = List.map(footprintOf, kept1);
        let (cells, wide) = footprints |> List.zipWithIndex |> List.foldLeft((acc, entry) -> {
            let (i, fp) = entry;
            let (cellMap, wideAcc) = acc;
            let (x0, x1, z0, z1) = cellRange(cs, fp);
            if (cellCount(x0, x1, z0, z1) > wideCellLimit()) (cellMap, i :: wideAcc)
            else {
                let keys = List.range(x0, x1 + 1) |> List.flatMap(ix -> List.range(z0, z1 + 1) |> List.map(iz -> (ix, iz)));
                (keys |> List.foldLeft((m, k) -> Map.insertWith((fresh, old) -> List.append(fresh, old), k, i :: Nil, m), cellMap), wideAcc)
            }
        }, (Map.empty(), Nil));
        WorldData.WorldData({ boxes = List.toVector(kept1), footprints = List.toVector(footprints), cellSize = cs, cells = cells,
                              cellCount = Map.size(cells), wide = wide })

    /// 集まりの全部の箱（build の並び）。
    pub def boxes(w: CollisionWorld3d): List[CollisionShape3d.Box3d] = Vector.toList(recOf(w)#boxes)

    /// 点 point（y は使わない）から水平に reach m の四角の範囲に、水平の広がりが掛かる箱（build の並びの順・重複なし）。
    /// 全部の箱を同じ条件で絞った物と、並びまで同じ。reach が負・NaN の時は 0。
    pub def boxesNear(w: CollisionWorld3d, point: Vec3.Vec3, reach: Float64): List[CollisionShape3d.Box3d] =
        let r = recOf(w);
        let d = if (reach > 0.0) reach else 0.0;
        let area = { minX = point#x - d, maxX = point#x + d, minZ = point#z - d, maxZ = point#z + d };
        let (x0, x1, z0, z1) = cellRange(r#cellSize, area);
        let candidates =
            if (cellCount(x0, x1, z0, z1) > Int32.min(queryCellLimit(), r#cellCount + 1)) List.range(0, Vector.length(r#boxes))
            else {
                let fromCells = List.range(x0, x1 + 1) |> List.flatMap(ix -> List.range(z0, z1 + 1)
                    |> List.flatMap(iz -> Map.getWithDefault((ix, iz), Nil, r#cells)));
                Set.toList(List.foldLeft((s, i) -> Set.insert(i, s), Set.empty(), List.append(fromCells, r#wide)))
            };
        candidates
            |> List.filter(i -> overlaps(area, Vector.get(i, r#footprints)))
            |> List.map(i -> Vector.get(i, r#boxes))

    /// 2 つの水平の広がりが重なるか（縁が触れるだけでも真）。
    def overlaps(a: Footprint, b: Footprint): Bool =
        a#minX <= b#maxX and b#minX <= a#maxX and a#minZ <= b#maxZ and b#minZ <= a#maxZ

    /// 向きのある箱を囲む水平の広がり。
    def footprintOf(b: CollisionShape3d.Box3d): Footprint =
        let ex = Float64.abs(b#ax#x) * b#half#x + Float64.abs(b#ay#x) * b#half#y + Float64.abs(b#az#x) * b#half#z;
        let ez = Float64.abs(b#ax#z) * b#half#x + Float64.abs(b#ay#z) * b#half#y + Float64.abs(b#az#z) * b#half#z;
        { minX = b#center#x - ex, maxX = b#center#x + ex, minZ = b#center#z - ez, maxZ = b#center#z + ez }

    /// 水平の広がりが掛かるマスの番号の範囲（x の最小・最大・z の最小・最大）。
    def cellRange(cs: Float64, fp: Footprint): (Int32, Int32, Int32, Int32) =
        (cellOf(cs, fp#minX), cellOf(cs, fp#maxX), cellOf(cs, fp#minZ), cellOf(cs, fp#maxZ))

    /// 座標 v のマスの番号（Int32 に収まらない遠さは端のマスに寄せる。寄せても大小の順は保つので取りこぼさない）。
    def cellOf(cs: Float64, v: Float64): Int32 =
        let limit = 1.0e9;
        let k = Float64.floor(v / cs);
        if (k >= limit) 1000000000
        else if (k <= 0.0 - limit) -1000000000
        else Float64.tryToInt32(k) |> Option.getWithDefault(0)

    /// マスの範囲のマスの数（大きすぎる時は Int32 の上限）。
    def cellCount(x0: Int32, x1: Int32, z0: Int32, z1: Int32): Int32 =
        let n = (Int32.toInt64(x1) - Int32.toInt64(x0) + 1i64) * (Int32.toInt64(z1) - Int32.toInt64(z0) + 1i64);
        if (n > 2147483647i64) 2147483647 else Int64.tryToInt32(n) |> Option.getWithDefault(2147483647)
}
