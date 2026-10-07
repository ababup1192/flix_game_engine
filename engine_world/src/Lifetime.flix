// Lifetime — 一過性のもの（発火して、時刻で進み、寿命で消える）の「誕生時刻＋長さ」だけを持つ値。
// 何をする物: 「いつ始まったか(startedAt)・どれだけ続くか(dur)」の2つから、経過秒・進行度(0..1)・
//   残り秒・まだ生きているか、を今の時刻(now)の純関数で導く。値そのもの(色や粒)は持たない。
// 何が嬉しい: 一過性演出の寿命管理をアプリが各所で手書きすると、画面遷移などで演出が飛ぶ抜けが出る。
//   Lifetime に集約すれば「生きてる間は次画面を待つ」も一行(alive)で書ける。
// 利用例: 得点ポップ/ダメージ数字/通知トーストの表示期間。Fx.Burst(粒子効果)も誕生時刻＋寿命を
//   これで持てる(同じ「now から導く」一族)。
//
// なぜ now から導くか — Clock/EcsTween の「dt を毎フレーム足す」蓄積式と違い、これは startedAt を1つ
// 持って now との差で導くので、巻き戻し・リプレイでも値がぶれない(Fx.Burst と同じ流儀)。
pub mod Lifetime {

    pub type alias Lifetime = { startedAt = Float64, dur = Float64 }

    /// 時刻 now に、長さ dur で発火する。
    pub def fire(now: Float64, dur: Float64): Lifetime = { startedAt = now, dur = dur }

    /// 発火からの経過秒（負にもなり得る＝startedAt を未来に置けば「遅延」になる）。
    pub def elapsedOf(now: Float64, l: Lifetime): Float64 = now - l#startedAt

    /// 進行度 0..1（開始で 0・寿命で 1）。
    pub def progressOf(now: Float64, l: Lifetime): Float64 =
        Num.clamp01((now - l#startedAt) / l#dur)

    /// 残り秒（0 未満にはならない）。
    pub def remaining(now: Float64, l: Lifetime): Float64 =
        Float64.max(0.0, l#dur - (now - l#startedAt))

    /// まだ再生中か（0 ≤ 経過 < 寿命）。
    pub def alive(now: Float64, l: Lifetime): Bool =
        let e = now - l#startedAt;
        e >= 0.0 and e < l#dur
}
