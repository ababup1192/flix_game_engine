// テストの共通部品: 実機（Main）と同じ繋ぎの App と、系を直に呼ぶテストの 1 歩。
mod TestKit {

    use fge::App

    /// 実機（Main）と同じ物語の時計の宣言・更新（step → interact）・音だけを繋いだ App。
    pub def app(w0: World.World): App.App[World.World, {}] =
        App.make(w0)
            |> App.addClock({ clockOf = w -> w#storyClock, withClock = (c, w) -> { storyClock = c | w },
                              paceOf = World.paceOf })
            |> App.addSystem((f, w) -> Controls.step(f, w) |> (w1 -> Controls.interact(f, w1)))
            |> App.withAudio(Controls.sounds)

    /// 系を直に呼ぶ 1 歩: 実機と同じく、先に物語の時計を実時間 dt 秒ぶん進めてから World.step。
    pub def stepBy(dt: Float64, w: World.World): World.World =
        World.step(App.tickClocks(app(w), dt, w))
}
