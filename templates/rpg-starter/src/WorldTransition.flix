// WorldTransition — フィールドの暗転（出入口・宿・出会いの点滅・晴らす）を時間で進め、覆い切った時に World を変える（すべて純粋）。
// 暗転を始めるのは規則の側（WorldField.startWarp・World.startEncounter・WorldShop の宿・World.enterField）、
// 覆い切った時の振り分けはここの transitionDone の 1 か所。暗転の間は歩きを進めない（Controls.tick がどちらか一方を流す）。
mod WorldTransition {
    use fge::Clock
    use World.TransitionThen

    /// 暗転の片道の秒（宿に泊まる時の覆う方は innSeconds・出会いの点滅は flashSeconds・ほかは fadeSeconds）。
    pub def secondsOf(res: Res.Res, then: TransitionThen): Float64 = match then {
        case TransitionThen.InnRest           => RulesDoc.rec(res#rules)#innSeconds
        case TransitionThen.StartBattle(_, _) => RulesDoc.rec(res#rules)#flashSeconds
        case TransitionThen.Warp(_, _, _)     => RulesDoc.rec(res#rules)#fadeSeconds
        case TransitionThen.FadeIn            => RulesDoc.rec(res#rules)#fadeSeconds
    }

    /// 暗転を進め、片道が終わっていれば transitionDone へ。
    pub def tick(res: Res.Res, transition: World.Transition, w: World.World): World.World =
        let length = secondsOf(res, transition#then);
        if (Clock.since(transition#startedAt, World.now(w)) >= length)
            transitionDone(res, Clock.after(length, transition#startedAt), transition#then, w)
        else w

    /// 覆い切った（Warp・InnRest・StartBattle）・晴れ切った（FadeIn）。at = 片道が終わった時刻。
    def transitionDone(res: Res.Res, at: Clock.Time[World.Play], then: TransitionThen, w: World.World): World.World =
        let fadeIn = r -> { transition = Some({ startedAt = at, then = TransitionThen.FadeIn }) | r };
        match then {
            case TransitionThen.Warp(map, cell, facing) => World.mapField(r -> fadeIn(World.arriveAt(map, cell, facing, r)), w)
            case TransitionThen.InnRest                 => World.mapField(fadeIn, WorldShop.rest(res, w))
            case TransitionThen.StartBattle(foes, afterWin) =>
                WorldBattle.enter(res, foes, afterWin, World.mapField(r -> { transition = None | r }, w))
            case TransitionThen.FadeIn                  => World.mapField(r -> { transition = None | r }, w)
        }
}
