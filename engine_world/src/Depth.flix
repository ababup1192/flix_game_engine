// Depth — 見下ろし画面で「足元が下にある物ほど手前」を、重なり順（zIndex）の数として決める。
// 使う口は orderAt だけ: ZStack.zIndex(Depth.orderAt(足元の y), ZStack.leaf(1 人の絵))。
// 人・木・柵・家を 1 つの of に並べると、すれ違うたびに前後が入れ替わる。
// 利用例: 主人公が木の手前に出たり裏に隠れたりする / 柵の向こうに立つ / 落ちている物をまたぐ。
// 注意: 決めるのは数だけで、並べ替えは ZStack の of の仕事（同じ zIndex 同士は積んだ順のまま）。
//
// 1 画面に帯が何本も要るとき（奥・遠景・地面・影・中景・近景・手前）は ZStack.of に奥 → 手前の順で
// 積む（帯の底の数を持たない）。足元の順は帯の中で ZStack.zIndex(Depth.orderAt(足元の y), 1 人の葉)。
pub mod Depth {

    /// ZStack の木で足元の順に並べるときの zIndex（1 画素ごとに 1 つ・下にある物ほど大きい）。
    /// `ZStack.of(people |> List.map(p -> ZStack.zIndex(Depth.orderAt(p.footY), ZStack.leaf(p.parts))))`。
    /// 範囲を持たないので、帯の幅を数える必要が無い。同じ行に立つ物は積んだ順。
    pub def orderAt(footY: Float64): Int32 =
        Float64.floor(footY) |> Float64.tryToInt32 |> Option.getWithDefault(if (footY > 0.0) Int32.maxValue() else Int32.minValue())
}
