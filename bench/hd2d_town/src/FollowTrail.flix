// FollowTrail — 先頭の通った道（新しい点が頭の点の列）と、その道を距離 d だけ戻った所（仲間が立つ所と向き）。
// 座標は地図の座標（x = 東・y = 北・m）。
mod FollowTrail {
    use fge::{Num}

    /// 道。頭が先頭の今の位置で、後ろほど古い点。
    pub type alias Trail = List[(Float64, Float64)]

    /// at に立つ先頭の後ろへ、向き back（長さ 1）に間 spacing で count 人が並ぶ道。
    pub def lineBehind(at: (Float64, Float64), back: (Float64, Float64), spacing: Float64, count: Int32): Trail =
        List.range(0, Int32.max(1, count)) |> List.map(i -> {
            let k = Int32.toFloat64(i) * spacing;
            (fst(at) + fst(back) * k, snd(at) + snd(back) * k)
        })

    /// 先頭が p へ動いた道（頭から keep m を越えた所より古い点は捨てる）。
    pub def push(p: (Float64, Float64), keep: Float64, trail: Trail): Trail = prune(keep, p :: trail)

    def prune(keep: Float64, points: Trail): Trail = match points {
        case a :: b :: rest =>
            let left = keep - distance(a, b);
            if (left <= 0.0) a :: b :: Nil else a :: prune(left, b :: rest)
        case _ => points
    }

    def distance(a: (Float64, Float64), b: (Float64, Float64)): Float64 =
        let dx = fst(a) - fst(b);
        let dy = snd(a) - snd(b);
        Num.sqrt(dx * dx + dy * dy)

    /// 道を頭から d m 戻った点と、そこで動いていた向き（古い点 → 新しい点・長さ 1）。
    /// 道が d より短ければ、一番古い区間をそのまま後ろへ延ばした所。点が 1 つなら頭の点と向き (0, 0)。
    pub def pointBack(trail: Trail, d: Float64): ((Float64, Float64), (Float64, Float64)) = match trail {
        case a :: b :: rest =>
            let length = distance(a, b);
            let dir = if (length < 0.000001) (0.0, 0.0) else ((fst(a) - fst(b)) / length, (snd(a) - snd(b)) / length);
            if (length < 0.000001) pointBack(a :: rest, d)
            else if (d <= length or List.isEmpty(rest)) ((fst(a) - fst(dir) * d, snd(a) - snd(dir) * d), dir)
            else pointBack(b :: rest, d - length)
        case a :: Nil => (a, (0.0, 0.0))
        case Nil      => ((0.0, 0.0), (0.0, 0.0))
    }
}
