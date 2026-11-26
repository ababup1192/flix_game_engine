// Simulation3d.Internal.Step — 刻みの数え・作り直し（reset）の判定・prewarm の始点（純粋な関数。WebGPU の道と CPU の道が同じ物を呼ぶ）。

/// 宣言の時刻から、このコマで何刻み進めるか・作り直すかを決める。刻みの dt は 1/60 秒の固定。
pub mod Simulation3d.Internal.Step {
    use Simulation3d.Internal.{Structure}

    /// 1 コマで進める刻みの上限。
    pub def maxStepsPerFrame(): Int64 = 4i64

    /// 前の刻みからこれより先へ飛んだら作り直す（1 秒・頭出し）。
    pub def resetJumpSteps(): Int64 = 60i64

    /// cache の無い道が同じ始点から進める区切り（5 秒）。
    // WhyNot: 計画の 600（10 秒）にしない — 8,000 個の GPU の格子で 720 刻みが PC で 約 85 ms（C0）、スマホで 5 倍とみると作り直しの 1 コマが 0.4 秒を超える。
    pub def prewarmPeriod(): Int64 = 300i64

    /// 時刻 time（秒）の刻みの番号（負の時刻は 0）。
    // WhyNot: 床を素で取らない — 足し続けた Float64 の秒が 1/60 の倍数のわずか下に来ると、境目で 1 刻み遅れる。
    pub def stepIndexOf(time: Float64): Int64 =
        Float64.floor(Float64.max(time, 0.0) * Int32.toFloat64(Simulation3d.Internal.stepsPerSecond()) + 1.0e-6)
            |> Float64.tryToInt64 |> Option.getWithDefault(0i64)

    /// 作り直す時の始点: 刻み step の状態は、始点 A の初めの状態から step − A 刻み進めた物（A = 区切りの頭 − prewarmSteps・0 以上）。
    /// 同じ区切りの中のコマは同じ始点から進めるので、cache の無い描き手でも続いた動きになる。
    pub def prewarmStartOf(prewarmSteps: Int32, step: Int64): Int64 =
        Int64.max(0i64, (step / prewarmPeriod()) * prewarmPeriod() - Int32.toInt64(Int32.max(0, prewarmSteps)))

    /// 状態を持つ描き手が覚えておく物: 状態の刻みの番号と構造の値。
    pub type alias Progress = { step = Int64, structure = Structure }

    /// このコマの進め方。Reset = 始点 start の初めの状態から steps 刻み進め直す・Advance = 今の状態から steps 刻み（0 もある）。
    pub enum StepPlan with Eq, ToString {
        case Reset(Int64, Int64)
        case Advance(Int64)
    }

    /// 前の進み prev・今の構造の値 structure・今の刻み step から進め方を決める。
    /// 作り直すのは: 初めて見た・構造の値が変わった・刻みが戻った・resetJumpSteps を超えて飛んだ時だけ（毎コマの値は比べない）。
    /// 進めるのは maxStepsPerFrame まで（超えた分は捨て、状態の刻みを今の刻みへ合わせる）。
    // WhyNot: 超えた分を次のコマへ持ち越さない — 遅い機械で毎コマ上限まで進め続け、追いつかないまま重さが続く。
    pub def planOf(prewarmSteps: Int32, prev: Option[Progress], structure: Structure, step: Int64): StepPlan =
        let reset = () -> { let start = prewarmStartOf(prewarmSteps, step); StepPlan.Reset(start, step - start) };
        match prev {
            case None => reset()
            case Some(p) =>
                if (p#structure != structure or step < p#step or step - p#step > resetJumpSteps()) reset()
                else StepPlan.Advance(Int64.min(step - p#step, maxStepsPerFrame()))
        }
}
