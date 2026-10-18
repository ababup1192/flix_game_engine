// 遊びの時計のヒットストップの合図に、物語の時刻を渡す。
mod Mix8 {
    pub def pace(w: Shapes.World): Clock.Pace[Shapes.Play, Shapes.Halt] =
        Clock.paceOf(Clock.Run.Running) |> Clock.withSlow(w#lineAt, w#plan)
}
