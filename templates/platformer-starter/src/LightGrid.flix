// LightGrid — 洞窟の明度場。terra_like の LightField の縮小版。すべて純粋。
//
// 松明は動かないので、明度は面を組んだ時に 1 回だけ計算して Map に焼き置く —
// 走行中は参照だけ(terra_like のようなカメラ・時刻の節奏は要らない)。
//
// 伝播は Dial 法(重み付き幅優先): 距離が小さい整数なので、距離ごとのバケツを
// 順にさらうだけでダイクストラと同じ答えになる。距離の単位は「半歩」:
// 空気の 1 歩 = 2、斜め = 3(8 近傍にすると光が四角でなく丸く広がる)、
// 固体は 3 倍(壁越しは早く暗くなる)。白さ s = 1 - 距離 × decay に松明の暖色を
// 掛ける — 減衰しても 3 チャンネルの比が保たれ、遠くでも暖色のまま沈む。
mod LightGrid {

    pub type alias Rgb = (Float64, Float64, Float64)

    /// 洞窟の環境光(真っ暗にしない — 黒は使わない画風の決まり)。
    ///
    /// これは**地色に掛ける係数**であって明るさそのものではない。壁の地色
    /// wallCave は既に (58,62,82) と暗いので、0.3 台まで下げると壁が背景の
    /// caveBottom (40,44,66) より暗くなり、画面が「テクスチャの無い黒い穴」に
    /// 見える(足場が読めない)。壁が背景と同じくらいに出る 0.6 台が下限。
    pub def ambient(): Rgb = (0.46, 0.48, 0.62)

    /// 松明の色(暖色)と減衰(半歩あたり)。decay を下げるほど遠くまで届く —
    /// 松明の数を増やすより、1 本の届く範囲を広げる方が絵が均される。
    def torchColor(): Rgb = (1.0, 0.76, 0.47)
    def decay(): Float64 = 0.030
    def maxDist(): Int32 = 56

    /// 面全体の明度場。outdoor / tower は空(= どこでも白)。
    pub def compute(st: Stage.Stage): Map[(Int32, Int32), Rgb] =
        let grid = Stage.rec(st);
        if (grid#kind != "cave") Map.empty()
        else {
            let seeds = grid#torches |> List.map(c -> (c#x, c#y));
            let dist = dial(st, Map.empty(), Map#{ 0 => seeds }, 0);
            dist |> Map.map(d -> {
                let s = Float64.max(0.0, 1.0 - Int32.toFloat64(d) * decay());
                let (tr, tg, tb) = torchColor();
                let (ar, ag, ab) = ambient();
                (Float64.max(ar, s * tr), Float64.max(ag, s * tg), Float64.max(ab, s * tb))
            })
        }

    /// マスの明度。cave 以外と場の外は白 / cave の未到達マスは環境光。
    pub def brightnessAt(st: Stage.Stage, light: Map[(Int32, Int32), Rgb],
                         x: Int32, y: Int32): Rgb =
        if (Stage.rec(st)#kind != "cave") (1.0, 1.0, 1.0)
        else Map.get((x, y), light) |> Option.getWithDefault(ambient())

    /// (Float64 の 0..1)³ → 描画色。GPU 層の tint と動的な絵の両方が同じ丸めを通る。
    pub def toColor(b: Rgb): Color =
        let (r, g, bl) = b;
        Color.rgb(Num.clamp01(r), Num.clamp01(g), Num.clamp01(bl))

    // ── Dial 法 ──

    /// バケツ d を処理して d+1 へ。seen は確定した最短距離。
    def dial(st: Stage.Stage, seen: Map[(Int32, Int32), Int32],
             buckets: Map[Int32, List[(Int32, Int32)]], d: Int32):
            Map[(Int32, Int32), Int32] =
        if (d > maxDist()) seen
        else {
            // 同じマスは 8 近傍のどこからでも同じ距離で入るので、バケツには
            // 重複が溜まる。ここで潰さないと 1 歩ごとに展開が数倍へ膨らみ、
            // 面が大きいほど破滅的に遅くなる(232×24 の洞窟で 72 秒かかっていた)。
            let cells = Map.get(d, buckets) |> Option.getWithDefault(Nil)
                |> List.filter(c -> Map.get(c, seen) == None)
                |> List.toSet |> Set.toList;
            let seen1 = List.foldLeft((acc, c) -> Map.insert(c, d, acc), seen, cells);
            let pushed = List.foldLeft((acc, c) -> pushNeighbors(st, seen1, c, d, acc),
                                       buckets, cells);
            dial(st, seen1, Map.remove(d, pushed), d + 1)
        }

    def pushNeighbors(st: Stage.Stage, seen: Map[(Int32, Int32), Int32],
                      cell: (Int32, Int32), d: Int32,
                      buckets: Map[Int32, List[(Int32, Int32)]]):
                     Map[Int32, List[(Int32, Int32)]] =
        let (x, y) = cell;
        let s = Stage.rec(st);
        let steps = ((1, 0, 2)) :: ((-1, 0, 2)) :: ((0, 1, 2)) :: ((0, -1, 2))
                 :: ((1, 1, 3)) :: ((1, -1, 3)) :: ((-1, 1, 3)) :: ((-1, -1, 3)) :: Nil;
        List.foldLeft((acc, step) -> {
            let (dx, dy, base) = step;
            let n = (x + dx, y + dy);
            let (nx, ny) = n;
            if (nx < 0 or nx >= s#width or ny < 0 or ny >= s#height
                or Map.get(n, seen) != None) acc
            else {
                let cost = if (Stage.solidAt(st, nx, ny)) base * 3 else base;
                let nd = d + cost;
                if (nd > maxDist()) acc
                else Map.insertWith((newL, oldL) -> newL ::: oldL, nd, n :: Nil, acc)
            }
        }, buckets, steps)
}
