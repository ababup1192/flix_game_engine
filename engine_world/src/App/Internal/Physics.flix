// App.Internal.Physics — App.addPhysics2d の中身: 物理だけのアキュムレータ（遊びの時計の秒をナノ秒の整数で貯める）と、刻みごとの step と出来事の受け渡し。
// 系（addSystem）は今までどおり実時間の貯めで回し、物理の step だけをこの貯めで回す（Bevy の Time<Fixed> が Time<Virtual> から貯めるのと同じ）。
// ゲームからは呼ばない（App の中身）。
pub mod App.Internal.Physics {

    /// addPhysics2d が App に置く物: このコマの遊びの時計の秒・1 刻み進めて出来事を渡す関数・物理の World の刻みの秒。
    pub type alias Hook[w] = { dtOf = w -> Float64, stepOnce = w -> w, stepSecondsOf = w -> Float64 }

    /// App.addPhysics2d の引数。physicsOf・withPhysics = World の欄の読み書き・clockOf = 物理を進める遊びの時計（App.addClock で進めている物）・
    /// onEvents = 刻みごとの出来事を World へ渡す（ふつうは Emit.Events に積む）。
    pub type alias Spec2d[w, c] = { physicsOf = w -> PhysicsWorld2d.PhysicsWorld2d, withPhysics = (PhysicsWorld2d.PhysicsWorld2d, w) -> w,
                                    clockOf = w -> Clock.Clock[c], onEvents = (PhysicsWorld2d.Events, w) -> w }

    /// 1 コマに回す刻みの上限（これを超えた貯めは捨てる。処理落ちの後に追いつこうとして重くなるのを止める）。
    def maxStepsPerFrame(): Int64 = 5i64

    pub def add2d(spec: Spec2d[w, c], app: App.App[w, ef]): App.App[w, ef] =
        let r = App.rec(app);
        let hook = { dtOf = w -> Clock.dtOf(spec#clockOf(w)),
                     stepOnce = w -> {
                         let stepped = PhysicsWorld2d.step(spec#physicsOf(w));
                         spec#onEvents(PhysicsWorld2d.events(stepped), spec#withPhysics(stepped, w))
                     },
                     stepSecondsOf = w -> PhysicsWorld2d.stepSecondsOf(spec#physicsOf(w)) };
        App.App({ physics = Some(hook), fixedStep = Some(fixedStepOrBug(r#fixedStep)) | firstPhysicsOrBug(r) })

    /// withFixedStep の刻み。無ければ止める（可変の dt で物理を進めない）。
    def fixedStepOrBug(fixedStep: Option[Float64]): Float64 = match fixedStep {
        case Some(dt) => dt
        case None => bug!("App.addPhysics2d は App.withFixedStep の後に呼ぶ（物理は固定刻みでしか進めない）")
    }

    /// まだ物理を繋いでいない App の中身。繋いであれば止める（2 つの物理の貯めを持たない）。
    def firstPhysicsOrBug(r: App.Rec[w, ef]): App.Rec[w, ef] =
        if (Option.isEmpty(r#physics)) r else bug!("App.addPhysics2d は 1 つの App に 1 回だけ")

    /// 刻みのナノ秒。物理の World の刻みが withFixedStep と違えば止める（刻みの持ち主は withFixedStep の 1 か所）。
    def stepNanosOrBug(hook: Hook[w], fixedDt: Float64, world: w): Int64 =
        let stepNanos = nanosOf(fixedDt);
        if (nanosOf(hook#stepSecondsOf(world)) == stepNanos) stepNanos
        else bug!("PhysicsWorld2d.empty の刻み（${hook#stepSecondsOf(world)} 秒）が App.withFixedStep（${fixedDt} 秒）と違う")

    /// 秒をナノ秒の整数に（四捨五入）。
    pub def nanosOf(seconds: Float64): Int64 =
        Float64.tryToInt64(Float64.round(seconds * 1.0e9)) |> Option.getWithDefault(0i64)

    /// 貯め carry にこのコマの dtNanos を足し、stepNanos ごとの刻みの回数と、次へ持ち越す端数を返す。上限を超えたら上限の回数で端数を 0 に戻す。
    // WhyNot: Float64 の秒で貯めない — total / 刻み が 0.9999… になり、0 回のコマの後に 2 回のコマが来て刻みが偏る。
    pub def stepsFor(carry: Int64, dtNanos: Int64, stepNanos: Int64): (Int32, Int64) =
        let total = carry + Int64.max(0i64, dtNanos);
        let raw = if (stepNanos > 0i64) total / stepNanos else 0i64;
        if (raw > maxStepsPerFrame()) (Int64.tryToInt32(maxStepsPerFrame()) |> Option.getWithDefault(5), 0i64)
        else (Int64.tryToInt32(raw) |> Option.getWithDefault(0), total - raw * stepNanos)

    /// 系を回した後の World を、物理の貯めで 0〜5 刻み進める（addPhysics2d が無ければそのまま）。返すのは (World, 次の貯め)。
    pub def advance(app: App.App[w, ef], fixedDt: Float64, carry: Int64, world: w): (w, Int64) =
        match App.rec(app)#physics {
            case None => (world, carry)
            case Some(hook) =>
                let stepNanos = stepNanosOrBug(hook, fixedDt, world);
                let (steps, next) = stepsFor(carry, nanosOf(hook#dtOf(world)), stepNanos);
                (List.foldLeft((acc, _) -> hook#stepOnce(acc), world, List.range(0, steps)), next)
        }

    /// ViewCtx#fixedAlpha: 物理の貯めの端数 ÷ 刻み（addPhysics2d があれば）、無ければ系の貯めの端数 ÷ 刻み（withFixedStep だけ）、どちらも無ければ 0。
    pub def alphaOf(app: App.App[w, ef], state: App.StepState): Float64 =
        let r = App.rec(app);
        match r#fixedStep {
            case None => 0.0
            case Some(dt) =>
                let raw = if (Option.isEmpty(r#physics)) state#carry / dt
                          else Int64.toFloat64(state#physicsCarry) / Int64.toFloat64(Int64.max(1i64, nanosOf(dt)));
                Num.clamp01(raw)
        }

    /// 跳んだコマ（F8 の巻き戻し・命令口の差し替え）の後の StepState: 物理の貯めを 0 に戻す（跳ぶ前の端数で刻みが 1 つ多く回らないように）。
    pub def afterJump(state: App.StepState): App.StepState = { physicsCarry = 0i64 | state }
}
