// Steering — 距離場（GridSearch）を使って、マス目の上の「動きの意図」を 1 歩に変える
// 道具箱。target へ詰める chase / 遠ざかる flee / 気の向くままの wander を持ち、
// 敵 AI とイベントシーンが同じ 1 歩を使える。マスは (列, 行) のタプル、
// 「そのマスに入れるか」は述語 canEnter で外から注入する（GridSearch と同じ流儀）。
// 壁・住人・扉の規則はゲーム側の canEnter が持つ。
//
// 使いどころ:
//   - 敵 AI: 毎拍 chase で主人公へ 1 歩詰める / flee で逃げる
//   - イベントシーン: 目的のマスへ 1 歩ずつ歩かせる（descend を毎コマ引き直す —
//     途中で道がふさがれても、その時の盤面から最短の 1 歩を選び直す）
//
// 経路をまるごと持たず「いまの 1 歩」だけを返すのがミソ — 盤面が動いても壊れない。
pub mod Steering {

    /// target から流した距離場を 1 歩下る = target へ最短で近づく隣のマス。
    /// 着けない（道が無い・自分が場の外）なら None — 呼び側が「動かない」にする。
    /// 同着は 上→下→左→右 の固定順で選ぶ（乱数を持たない — 生成すれば毎回同じ、スナップショットが効く）。
    /// limit は距離場を流す上限歩数（盤のマス数を渡せば全域）。
    pub def chase(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32),
                  target: (Int32, Int32), limit: Int32): Option[(Int32, Int32)] =
        let field = GridSearch.distances(canEnter, target :: Nil, limit);
        Map.get(self, field) |> Option.flatMap(here ->
            neighborsOf(self)
                |> List.filterMap(cell -> Map.get(cell, field)
                    |> Option.map(dist -> (dist, cell)))
                |> List.filter(entry -> fst(entry) < here)
                |> firstMinBy(fst)
                |> Option.map(snd))

    /// threat から遠ざかる 1 歩。距離場でいまより遠くなる隣のうち、一番遠いものを選ぶ。
    /// どこへ行っても近づくだけなら None（袋小路 — 呼び側が「立ちすくむ」等にする）。
    pub def flee(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32),
                 threat: (Int32, Int32), limit: Int32): Option[(Int32, Int32)] =
        let field = GridSearch.distances(canEnter, threat :: Nil, limit);
        Map.get(self, field) |> Option.flatMap(here ->
            neighborsOf(self)
                |> List.filterMap(cell -> Map.get(cell, field)
                    |> Option.map(dist -> (dist, cell)))
                |> List.filter(entry -> fst(entry) > here)
                |> firstMinBy(entry -> 0 - fst(entry))
                |> Option.map(snd))

    /// 気の向くままの 1 歩。何歩目か（beat）と塩（salt）のハッシュで向きを引くので、
    /// 乱数の種を持たず、同じ場面を生成すれば同じ道をたどる（スナップショットが効く）。
    /// 引いた向きへ入れなければ None — 呼び側が「今回は留まる」にする
    /// （beat が進めば次は別の向きを引くので、隅で固まらない）。
    pub def wander(canEnter: ((Int32, Int32)) -> Bool, self: (Int32, Int32),
                   beat: Int32, salt: Int32): Option[(Int32, Int32)] =
        let r = Hash01.at(beat, salt);
        let (x, y) = self;
        let cell = if (r < 0.25) (x, y - 1)
                   else if (r < 0.5) (x, y + 1)
                   else if (r < 0.75) (x - 1, y)
                   else (x + 1, y);
        if (canEnter(cell)) Some(cell) else None

    /// 4 近傍（上→下→左→右 の固定順。選び方の決定性はこの順が担う）。
    def neighborsOf(cell: (Int32, Int32)): List[(Int32, Int32)] =
        let (x, y) = cell;
        (x, y - 1) :: (x, y + 1) :: (x - 1, y) :: (x + 1, y) :: Nil

    /// 並び順で最初に現れる最小（同値では置き換えない = 先勝ち）。
    /// ソートに頼らず foldLeft で畳み込む — 同着の決定性を neighborsOf の順が担保する。
    def firstMinBy(key: a -> Int32, l: List[a]): Option[a] =
        List.foldLeft((acc, x) -> match acc {
            case None    => Some(x)
            case Some(b) => if (key(x) < key(b)) Some(x) else acc
        }, None, l)
}
