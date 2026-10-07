// Clock — 経過時間を貯めて「一定間隔で合図を出す」「残り時間を数える」を数値だけで扱う。
// タイマー用の仕組みを持ち出さなくても、貯めた秒数の足し引きだけで周期処理やカウントダウンが書ける。
// 利用例: 敵を一定間隔で湧かせる / アニメのコマを送る / 開始前の残り秒数を数える。
// 注意: 時間の管理だけで、何を動かすかには関与しない純粋な計算。

pub mod Clock {

    /// 反復タイマー: acc に dt を足し、interval に達したら（== も含む）1回 fire（rest に余りを残す）。
    /// 達しなければ fired=false、rest=acc+dt（貯め続ける）。
    /// 1 tick で最大1回（dt ≪ interval が前提。dt が interval を超えても 1 回だけ発火し
    /// 余りは rest に繰り越す＝脱落しない）。Timer(oneShot=false) 相当。
    pub def tick(acc: Float64, dt: Float64, interval: Float64): {fired = Bool, rest = Float64} =
        let t = acc + dt;
        if (t < interval) {fired = false, rest = t}
        else {fired = true, rest = t - interval}

    /// カウントダウン: 残り時間を dt 減らし、0 で下げ止める。Timer(oneShot=true) 相当。
    pub def countdown(remaining: Float64, dt: Float64): Float64 =
        Float64.max(0.0, remaining - dt)
}
