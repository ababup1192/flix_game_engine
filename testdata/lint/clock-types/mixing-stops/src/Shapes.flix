// 見本が共有する時計の名前と World。Play = 遊びの時計・Story = 物語の時計・実時間は Clock.Real。
pub mod Shapes {
    pub enum Play
    pub enum Story
    pub enum Halt { case Menu }

    pub type alias World = {
        play = Clock.Clock[Play],
        story = Clock.Clock[Story],
        realNow = Clock.Time[Clock.Real],
        hitAt = Clock.Time[Play],
        lineAt = Clock.Time[Story],
        sparks = List[Lifetime.Span[Play]],
        plan = TimeScale.Plan
    }

    pub enum Beat with Eq, Order, ToString { case Hit }

    pub def cue(): Timeline.Timeline[Beat] =
        Timeline.buildOrPanic("cue", Timeline.noTempo(), List#{
            Timeline.append(Beat.Hit, Timeline.Duration.Seconds(0.3)) |> Timeline.withSound("hit")
        })
}
