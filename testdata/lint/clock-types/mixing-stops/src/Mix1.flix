// 遊びの時計で生まれた火花の寿命を、実時間の今で読む（ポーズ中も薄れていく）。
mod Mix1 {
    pub def sparkFade(w: Shapes.World): List[Float64] =
        w#sparks |> List.map(s -> Lifetime.progressOn(w#realNow, s))
}
