// 正しい使い方（同じ時計どうし）はコンパイルが通る。
mod SameClock {
    use Shapes.World

    pub def sparkFade(w: World): List[Float64] =
        w#sparks |> List.map(s -> Lifetime.progressOn(Clock.nowOf(w#play), s))

    pub def sinceHit(w: World): Float64 = Clock.since(w#hitAt, Clock.nowOf(w#play))

    pub def sounds(w: World): List[String] = Timeline.soundsOnClock(w#play, w#hitAt, Shapes.cue())

    pub def pace(w: World): Clock.Pace[Shapes.Play, Shapes.Halt] =
        Clock.paceOf(Clock.Run.Running) |> Clock.withSlow(w#hitAt, w#plan)

    pub def blink(w: World): Float64 = Clock.secondsOf(w#realNow) * 2.0
}
