// HoldPress — 長押しで決める（Unity の Input System の Hold interaction と同じ考え方）。
// 押している間だけ秒を貯め、決めた秒に届いたフレームで 1 回だけ合図を出す。離すと速めに戻り、
// 合図を出した後は一度離すまで貯めない（押しっぱなしで次の場面まで続けて決めてしまわない）。
// 押した瞬間には決まらないので、読み進めるつもりの決定キーで誤って飛ばす・消すことがない。
// 利用例: 会話・オープニングを長押しで飛ばす / セーブの消去を長押しで確かめる。円のゲージは progress を読む。
// 押した・離したの拍そのものは InputEdge（1 フレームだけの立ち上がり・立ち下がり）。

pub mod HoldPress {

    /// 貯まった秒・いま貯めているか（ゲージを出すか）・合図を出した後で離すのを待っているか。
    pub type alias HoldPress = { charge = Float64, holding = Bool, latched = Bool }

    /// seconds = 合図までに押し続ける秒、drain = 離したときに戻る速さ（押す速さの何倍か）。
    pub type alias Config = { seconds = Float64, drain = Float64 }

    pub def empty(): HoldPress = { charge = 0.0, holding = false, latched = false }

    /// 1 フレーム分。held = キーを押しているか、enabled = いま長押しを受け付ける画面か。
    /// 戻り値の Bool はこのフレームで満ちた（合図）か。
    pub def step(cfg: Config, held: Bool, enabled: Bool, dt: Float64, s: HoldPress): (HoldPress, Bool) =
        let drained = Float64.max(0.0, s#charge - dt * cfg#drain);
        if (not held) ({ charge = drained, holding = false, latched = false }, false)
        else if (s#latched or not enabled) ({ charge = drained, holding = false | s }, false)
        else {
            let filled = s#charge + dt;
            if (filled >= cfg#seconds) ({ charge = 0.0, holding = false, latched = true }, true)
            else ({ charge = filled, holding = true | s }, false)
        }

    /// ゲージがどこまで満ちたか（0 → 1）。
    pub def progress(cfg: Config, s: HoldPress): Float64 =
        if (cfg#seconds <= 0.0) 0.0 else Num.clamp01(s#charge / cfg#seconds)

    /// 貯めた秒を捨てる（確認の窓を開いた・場面が切り替わった）。離すのを待つ印は残す。
    pub def cleared(s: HoldPress): HoldPress = { charge = 0.0, holding = false | s }
}
