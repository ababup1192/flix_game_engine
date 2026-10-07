// Num — 数の小さな道具。0〜1 に収める・小数部だけ残す・周期で折り返す。
//
// どれも 1 行で書けるが、書き方が少しずつ違うと結果も少しずつ違う
// （折り返しは負の値の扱いで割れる）。同じ答えを全員が使えるよう 1 箇所に置く。
// engine（契約層）にあるので、フロント・バックエンド・工具箱・ゲームのどこからでも呼べる。
pub mod Num {

    /// 0 以上 1 以下に収める。濃さ・進み具合・混ぜ具合など「0〜1 のはずの値」を
    /// 計算した直後に通す。
    pub def clamp01(x: Float64): Float64 =
        Float64.max(0.0, Float64.min(1.0, x))

    /// lo 以上 hi 以下に収める。lo > hi のときは lo を返す（範囲が無いので下端に丸める）。
    pub def clamp(lo: Float64, hi: Float64, x: Float64): Float64 =
        Float64.max(lo, Float64.min(hi, x))

    /// 整数版の clamp。lo > hi のときは lo を返す（clamp と同じ）。
    /// Flix 標準の `Int32.clamp` は pub でなく呼べないので、こちらを使う。
    pub def clampInt(lo: Int32, hi: Int32, x: Int32): Int32 =
        Int32.max(lo, Int32.min(hi, x))

    /// 小数部だけを残す（1.25 → 0.25）。負でも 0 以上 1 未満になる（-0.25 → 0.75）ので、
    /// 歩行の位相・明滅・繰り返す模様がどちら向きに進んでも途切れない。
    pub def fract(x: Float64): Float64 =
        x - Float64.floor(x)

    /// 0 以上 period 未満へ折り返す。画面の端から端へ回り込む物（流れる雲・スクロールする床・
    /// 繰り返すアニメの時刻）に使う。period が 0 以下なら折り返しようがないのでそのまま返す。
    /// x/period の丸めが商を 1 つ繰り上げると微小な負が漏れる（wrapTo(0.1, 1.7) など）ので、
    /// 0 未満は 1 周期戻して「0 以上」を守る — 時刻に使うと -ε が「-1 時」に化けるため。
    pub def wrapTo(period: Float64, x: Float64): Float64 =
        if (period <= 0.0 or not Float64.isFinite(period)) x
        else {
            let f = x - period * Float64.floor(x / period);
            if (f < 0.0) f + period else f
        }

    /// a と b の間を t（0〜1）で混ぜる。範囲外の t は伸ばしたまま（外挿）— 収めたいなら
    /// clamp01 を通してから渡す。
    pub def lerp(a: Float64, b: Float64, t: Float64): Float64 =
        a + (b - a) * t

    /// 床へ丸めて Int32 に落とす（-1.5 → -2）。ゼロ向き切り捨てではない — 負の座標でも
    /// マスの並びが 0 の両側で揃う。Int32 に収まらない大きさは 0（画面・マス目の範囲では
    /// 起きない）。
    pub def floorInt(x: Float64): Int32 =
        Float64.floor(x) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    /// 最も近い整数へ丸めて Int32 に落とす（0.5 は上へ）。負でも床基準（-1.5 → -1）。
    pub def roundInt(x: Float64): Int32 =
        floorInt(x + 0.5)
}
