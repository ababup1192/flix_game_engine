// ExposureAdaptation — 露出を、ゲームが決めた場所の狙いの明るさへ時間をかけて近づける（明るい所へ入った直後の白飛び・暗い所へ入った直後の暗さ）。
// 絵から明るさを測る自動露出（Unreal の Auto Exposure・Bevy の AutoExposure）ではない。測らないので同じ部屋で振り向いても露出は変わらず、
// 3 つの描き手と描き出しで同じ値になる。AutoExposure の名前は測る形のために空けておく。
//
// 使い方: World に今の明るさ（ev）を持ち、毎コマ
//   `let ev = ExposureAdaptation.step(settings, dt, targetEvOf(place), w#ev)` で近づけ、
//   `PostStack.withExposure(ExposureAdaptation.computeExposure(settings, ev), stack)` に渡す（露出は Param なので program は作り直さない）。
// dt は実時間の秒を渡す（目はポーズ中も慣れる・ヒットストップで止めない。docs/clock.md）。
// ev は場所の平均の明るさの log2（線形の値。0.18 の灰色 = log2(0.18) ≈ −2.47）。明るい外へ出る時は targetEv を上げる。
pub mod ExposureAdaptation {

    /// compensation = 狙いのずらし（stop・+ で明るめ）・minExposure / maxExposure = 掛ける露出の上下限（stop）・
    /// speedUp = 場所が明るくなる時に追う速さ（1/秒）・speedDown = 暗くなる時に追う速さ（1/秒）。
    /// 名前は Unity HDRP の Exposure（Limit Min / Max・Compensation・Adaptation Speed）と Bevy の AutoExposure（speed_brighten / speed_darken）にそろえた。
    pub type alias Settings = { compensation = Float64, minExposure = Float64, maxExposure = Float64, speedUp = Float64, speedDown = Float64 }

    /// 0・−4・+4・3・1（明るい所へは速く、暗い所へはゆっくり慣れる）。
    pub def defaults(): Settings = { compensation = 0.0, minExposure = -4.0, maxExposure = 4.0, speedUp = 3.0, speedDown = 1.0 }

    /// 前に追った明るさ prevEv から、狙い targetEv へ dt 秒ぶん近づけた明るさ（1 − e^(−速さ × dt) の割合だけ寄る。dt を細かく刻んでも同じ所へ着く）。
    /// dt ≤ 0 なら prevEv のまま。
    pub def step(s: Settings, dt: Float64, targetEv: Float64, prevEv: Float64): Float64 =
        if (dt <= 0.0) prevEv
        else {
            let speed = Float64.max(0.0, if (targetEv > prevEv) s#speedUp else s#speedDown);
            prevEv + (targetEv - prevEv) * (1.0 - Float64.exp(0.0 - speed * dt))
        }

    /// 追った明るさ ev（stop）→ 掛ける露出（stop）。その明るさを中間の灰色 0.18 に持っていく露出に compensation を足し、上下限で切る。
    pub def computeExposure(s: Settings, ev: Float64): Float64 =
        let midGray = Num.log(0.18) / Num.log(2.0);
        Float64.max(s#minExposure, Float64.min(s#maxExposure, midGray - ev + s#compensation))

    /// 線形の明るさ（0 より大きい）→ ev（log2）。0 以下は −16（真っ暗）として扱う。
    pub def evOf(luminance: Float64): Float64 =
        if (luminance <= 0.0) -16.0 else Num.log(luminance) / Num.log(2.0)
}
