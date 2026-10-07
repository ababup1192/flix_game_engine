// GridSearch — 正方タイルのマス目の上で「どこまで行けるか・何歩かかるか・どこが射程か」を求める。
// 4方向（上下左右）の幅優先探索と、マンハッタン距離の環（リング）を一箇所にまとめるので、
// 盤面を扱うたびに同じ探索ループを書き直さずに済む。
// 「そのマスに入れるか」の政策（壁・他のコマ・立入禁止など）は述語で外から注入するため、
// この module 自体はゲームのルールを知らない汎用の探索エンジンでいられる。
// 利用例: コマの移動可能マスを塗る / 押して動かす歩数を数える / 追いかける最短の一歩を選ぶ /
//         武器・スキルの届くマス（ドーナツ状の射程）を並べる。
// 注意: 斜めへは進まない（4近傍のみ）。距離は歩数（各マス 1 歩）で、地形ごとの重みは扱わない
//       （重み付き探索が要るならこの上に別途組む）。セルは (列, 行) のタプルで Grid と同じ流儀。

pub mod GridSearch {

    /// 4近傍のうち `canEnter` を満たすマスだけを通って、`start` から `maxSteps` 歩以内に
    /// 到達できるマスの一覧。`start` 自身（0 歩）は `canEnter` に関わらず必ず先頭に含む
    /// （出発点にはいつでも居られる、という素直な決まり）。返る順は幅優先の訪問順
    /// （start → 1 歩 → 2 歩 …、各マスの近傍は 上→下→左→右 の固定順）。
    /// `canEnter` が政策の注入点: 壁・他のコマ・立入禁止のマスで false を返せばそこを避ける。
    /// 利用例: コマの移動範囲を塗る / いま何マス動けるかを一覧する。
    pub def reachable(canEnter: ((Int32, Int32)) -> Bool, start: (Int32, Int32),
                       maxSteps: Int32): List[(Int32, Int32)] =
        floodList(canEnter, maxSteps, 0, start :: Nil, Set.singleton(start), start :: Nil)

    /// `reachable` の幅優先ループ。距離 `depth` のマス群 `frontier` の 4 近傍を次のレベルへ送り、
    /// `maxSteps` に達したらそれ以上広げない。再訪問は `seen` で弾き、返す順は `acc` が持つ
    /// （`acc` は逆順に積んで最後に 1 回ひっくり返す）。
    /// 会員判定と戻り値を 1 本のリストで兼ねると、どちらも要素数の二乗で効いてくる。
    def floodList(canEnter: ((Int32, Int32)) -> Bool, maxSteps: Int32, depth: Int32,
                   frontier: List[(Int32, Int32)],
                   seen: Set[(Int32, Int32)],
                   acc: List[(Int32, Int32)]): List[(Int32, Int32)] =
        if (List.isEmpty(frontier) or depth >= maxSteps) List.reverse(acc)
        else
            let (nextFrontier, nextSeen, nextAcc) =
                List.foldLeft((outer, cur) ->
                    List.foldLeft((inner, n) -> {
                        let (f, s, a) = inner;
                        if (canEnter(n) and not Set.memberOf(n, s))
                            (n :: f, Set.insert(n, s), n :: a)
                        else inner
                    }, outer, neighbors(cur)),
                    (Nil, seen, acc), frontier);
            floodList(canEnter, maxSteps, depth + 1, List.reverse(nextFrontier), nextSeen, nextAcc)

    /// `sources` を 0 歩とする多始点の幅優先探索で、`canEnter` を満たして到達できる各マスの
    /// 最短歩数を Map で返す（距離場）。到達できないマスは Map に載らない（= ∞ 扱い）。
    /// 歩数が均一なので優先度キューは要らない（幅優先 = ダイクストラ）。
    /// `maxSteps = 0` は sources（の canEnter を満たすもの）だけが 0 歩で載る（reachable と同じ端）。
    /// 利用例: ゴールから塗った距離場を下って追う一歩を選ぶ / n 歩圏内のマスを判定する。
    pub def distances(canEnter: ((Int32, Int32)) -> Bool, sources: List[(Int32, Int32)],
                       maxSteps: Int32): Map[(Int32, Int32), Int32] =
        let seeds = List.filter(canEnter, sources);
        let dist0 = List.foldLeft((m, c) -> Map.insert(c, 0, m), Map.empty(), seeds);
        floodField(canEnter, maxSteps, 0, seeds, dist0)

    /// 距離 `depth` のマス群 `frontier` の 4 近傍を距離 `depth+1` で登録し、次のレベルへ進む。
    /// 既登録マスは持ち回った Map で弾く（同レベル内の重複もこれで防ぐ）。
    def floodField(canEnter: ((Int32, Int32)) -> Bool, maxSteps: Int32, depth: Int32,
                    frontier: List[(Int32, Int32)],
                    dist: Map[(Int32, Int32), Int32]): Map[(Int32, Int32), Int32] =
        if (List.isEmpty(frontier) or depth >= maxSteps) dist
        else
            let (nextFrontier, nextDist) =
                List.foldLeft((acc, cur) ->
                    List.foldLeft((acc2, n) -> {
                        let (f2, m2) = acc2;
                        if (canEnter(n) and not Map.memberOf(n, m2))
                            (n :: f2, Map.insert(n, depth + 1, m2))
                        else acc2
                    }, acc, neighbors(cur)),
                    (Nil, dist), frontier);
            floodField(canEnter, maxSteps, depth + 1, nextFrontier, nextDist)

    /// 2 マス間のマンハッタン距離 |dx| + |dy|（4方向で辿る最短歩数の下限）。
    /// 近さの比較や射程内判定に使う素の 1 行。
    pub def manhattanDistance(a: (Int32, Int32), b: (Int32, Int32)): Int32 =
        let (ax, ay) = a;
        let (bx, by) = b;
        Int32.abs(ax - bx) + Int32.abs(ay - by)

    /// `center` からマンハッタン距離が `minR`..`maxR`（両端含む）にあるマスの一覧
    /// （ドーナツ状の環）。`minR == 0` を許すかは呼び側の判断（中心を外したいなら `minR >= 1`）。
    /// `minR > maxR` は空。返る順は dx 昇順・その中で dy 昇順で決定的。
    /// 利用例: 武器・スキルの届くマスを並べる / 爆風の輪郭 / 一定距離の湧き出し候補。
    pub def manhattanRing(center: (Int32, Int32), minR: Int32, maxR: Int32): List[(Int32, Int32)] =
        let (cx, cy) = center;
        let coords = List.range(-maxR, maxR + 1);
        List.flatMap(dx ->
            List.foldRight(dy -> acc -> {
                let d = Int32.abs(dx) + Int32.abs(dy);
                if (d >= minR and d <= maxR) ((cx + dx, cy + dy): (Int32, Int32)) :: acc
                else acc
            }, Nil, coords),
            coords)

    /// マスの 4 近傍（上→下→左→右 の固定順）。探索の広げ方と訪問順をこの 1 箇所で決める。
    def neighbors(cell: (Int32, Int32)): List[(Int32, Int32)] =
        Dir4.all() |> List.map(d -> Grid.neighbor(cell, d))
}
