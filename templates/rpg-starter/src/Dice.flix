// Dice — 乱数。引いた回数 dice と用途（Channel）から Hash01 で引き、引くたびに 1 足す。
// 同じ操作の列は同じ結果になり、テスト・e2e・描き出しが毎回同じになる。
// 回数を持つ物は World（遊びの間）と戦いの式（Battle.resolveRound が回数を受けて返す）の 2 つなので、
// dice の欄を持つ record なら何でも受ける（World を名指ししない。戦いの式が World を使わずに済む）。
// WhyNot: Math.Random と RandomUtil を使わない — 引いた値が World の外にあると、同じ手で流し直しても戦いや出会いが変わる
// （bin/lint-rules/forbid.local.json が止める）。
mod Dice {
    use fge::Hash01

    /// 乱数の用途。同じ回数でも用途が違えば値が違う（用途を足すときは case と numberOf に 1 行）。
    ///   EncounterSteps … 次の戦いまでの歩数 / EncounterGroup … 出会う組 / Order … 戦いの行動順 / Damage … ダメージのぶれ /
    ///   Critical … 会心 / FoeMove … 敵の技 / FoeTarget … 敵の的 / Flee … にげる / Sleep … 眠らせるのが効くか / Wake … 眠った人が起きるか
    pub enum Channel with Eq, ToString {
        case EncounterSteps
        case EncounterGroup
        case Order
        case Damage
        case Critical
        case FoeMove
        case FoeTarget
        case Flee
        case Sleep
        case Wake
    }

    def numberOf(c: Channel): Int32 = match c {
        case Channel.EncounterSteps => 1
        case Channel.EncounterGroup => 2
        case Channel.Order          => 3
        case Channel.Damage         => 4
        case Channel.Critical       => 5
        case Channel.FoeMove        => 6
        case Channel.FoeTarget      => 7
        case Channel.Flee           => 8
        case Channel.Sleep          => 9
        case Channel.Wake           => 10
    }

    /// 0 以上 1 未満の値を 1 つ引く。
    pub def roll(channel: Channel, w: { dice = Int32 | r }): (Float64, { dice = Int32 | r }) =
        (Hash01.at(w#dice, numberOf(channel)), { dice = w#dice + 1 | w })

    /// lo 以上 hi 以下の整数を 1 つ引く（hi が lo より小さければ lo）。
    pub def range(channel: Channel, lo: Int32, hi: Int32, w: { dice = Int32 | r }): (Int32, { dice = Int32 | r }) =
        let (r, after) = roll(channel, w);
        (lo + indexOf(r, Int32.max(0, hi - lo) + 1), after)

    /// 重み付きで 1 つ選ぶ（重み 0 以下の物は選ばない。全部 0 以下か空なら None で、回数は進めない）。
    pub def weighted(channel: Channel, rows: List[(a, Int32)], w: { dice = Int32 | r }): (Option[a], { dice = Int32 | r }) =
        let live = rows |> List.filter(row -> snd(row) > 0);
        let total = live |> List.map(snd) |> List.sum;
        if (total <= 0) (None, w)
        else {
            let (r, after) = roll(channel, w);
            (pickAt(indexOf(r, total), live), after)
        }

    /// 0..count-1 のうち、r（0 以上 1 未満）の当たる番号。
    def indexOf(r: Float64, count: Int32): Int32 =
        let pick = Float64.floor(r * Int32.toFloat64(count)) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        Int32.min(count - 1, Int32.max(0, pick))

    def pickAt(at: Int32, rows: List[(a, Int32)]): Option[a] = match rows {
        case (x, weight) :: rest => if (at < weight) Some(x) else pickAt(at - weight, rest)
        case Nil                 => None
    }

    /// 乱数の回数を seed から始める（Starts の seed=N）。
    pub def withSeed(seed: Int32, w: { dice = Int32 | r }): { dice = Int32 | r } = { dice = seed | w }
}
