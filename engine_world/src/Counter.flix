// Counter — 整数を 1 つずつ数えて start から end へ動かす（数え下がり・数え上がり・ルーレット）。
// 「盾の量が 3 → 0 へ 1 つずつ減る」「光る枠が 9 回移って止まる」のように、値が飛び飛びに
// 変わる演出を時刻の純関数で導く。移る間隔の伸び縮みは EcsTween.Easing で決める
// （EaseOut なら出だしが速く、だんだん遅く止まる = ルーレット）。
// 絵（valueAt）と音（tickAt・ticksBetween）が同じ式を読むので、数が減る拍と刻みの音がずれない。
// 利用例: HP の数え下がり / 得点の数え上がり / 候補を巡って止まる枠。

pub mod Counter {

    /// at 秒から dur 秒かけて start → end へ数える。easing は「何回目の移りが、いつ来るか」の曲線。
    pub type alias Counter = { start = Int32, end = Int32, at = Float64, dur = Float64,
                               easing = EcsTween.Easing }

    pub def make(start: Int32, end: Int32, at: Float64, dur: Float64, easing: EcsTween.Easing): Counter =
        { start = start, end = end, at = at, dur = Float64.max(0.0, dur), easing = easing }

    /// 移る回数（|end − start|）。
    pub def stepsOf(c: Counter): Int32 = Int32.abs(c#end - c#start)

    /// t 秒時点の値。始まる前は start、終わった後は end。
    pub def valueAt(c: Counter, t: Float64): Int32 =
        let dir = if (c#end >= c#start) 1 else -1;
        c#start + dir * doneAt(c, t)

    /// t 秒までに移った回数（0..stepsOf）。
    pub def doneAt(c: Counter, t: Float64): Int32 =
        let n = stepsOf(c);
        if (t < c#at) 0
        else if (c#dur <= 0.0) n
        else {
            let eased = EcsTween.eased(c#easing, Num.clamp01((t - c#at) / c#dur));
            // 割り切れる回の境目で浮動小数の誤差に負けて 1 つ手前に落ちないよう、ごくわずかに足す。
            Int32.min(n, Num.floorInt(eased * Int32.toFloat64(n) + 0.000001))
        }

    /// i 回目（1 起点）に移る時刻。0 回目は at。曲線を逆に解いて求める。
    pub def tickAt(c: Counter, i: Int32): Float64 =
        let n = Int32.max(1, stepsOf(c));
        let k = Num.clamp01(Int32.toFloat64(i) / Int32.toFloat64(n));
        c#at + c#dur * EcsTween.inverseEased(c#easing, k)

    /// 前のフレーム t0 から今の t1 までに移った回数（刻みの音を鳴らす数）。
    pub def ticksBetween(c: Counter, t0: Float64, t1: Float64): Int32 =
        Int32.max(0, doneAt(c, t1) - doneAt(c, t0))
}
