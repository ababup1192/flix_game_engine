// HoldSkip — 長押しで飛ばす（会話・ムービー・演出のスキップ）。押している間だけ秒を貯め、
// 決めた秒に届いたフレームで 1 回だけ合図を出す。離すと速めに戻り、飛ばした後は一度離すまで
// 貯めない（押しっぱなしで次の場面まで飛ばしてしまわない）。
// 押した瞬間には飛ばさないので、読み進めるつもりの決定キーで誤って飛ばすことがない。
// 利用例: 会話を X の長押しで飛ばす / オープニングを長押しで飛ばす。円のゲージは progress を読む。

pub mod HoldSkip {

    /// 貯まった秒・いま貯めているか（ゲージを出すか）・飛ばした後で離すのを待っているか。
    pub type alias HoldSkip = { charge = Float64, holding = Bool, latched = Bool }

    /// seconds = 飛ばすまでに押し続ける秒、drain = 離したときに戻る速さ（押す速さの何倍か）。
    pub type alias Config = { seconds = Float64, drain = Float64 }

    pub def idle(): HoldSkip = { charge = 0.0, holding = false, latched = false }

    /// 1 フレーム分。held = 飛ばすキーを押しているか、enabled = いま飛ばせる画面か。
    /// 戻り値の Bool はこのフレームで満ちた（飛ばす）か。
    pub def step(cfg: Config, held: Bool, enabled: Bool, dt: Float64, s: HoldSkip): (HoldSkip, Bool) =
        let drained = Float64.max(0.0, s#charge - dt * cfg#drain);
        if (not held) ({ charge = drained, holding = false, latched = false }, false)
        else if (s#latched or not enabled) ({ charge = drained, holding = false | s }, false)
        else {
            let filled = s#charge + dt;
            if (filled >= cfg#seconds) ({ charge = 0.0, holding = false, latched = true }, true)
            else ({ charge = filled, holding = true | s }, false)
        }

    /// ゲージがどこまで満ちたか（0 → 1）。
    pub def progress(cfg: Config, s: HoldSkip): Float64 =
        if (cfg#seconds <= 0.0) 0.0 else Num.clamp01(s#charge / cfg#seconds)

    /// 貯めた秒を捨てる（確認の窓を開いた・場面が切り替わった）。離すのを待つ印は残す。
    pub def cleared(s: HoldSkip): HoldSkip = { charge = 0.0, holding = false | s }
}
