// Curve — 時間から値をひとつ計算する、状態を持たない小さな関数の詰め合わせ。
// 「今 t 秒でこの値」をその場で導けるので、揺れ・回転・周回といった時間変化を、
// 覚えておく変数なしに描ける（保存も更新も要らない）。
// 利用例: 落ち物を端まで来たら反対側から出し直す / 旗を左右にゆらす / 針を回す /
//   宣言した折れ線をなめらかに読む。
// 注意: どれも t の純粋な関数。速さも位相もすべて呼び側が渡す値で決まる。

pub mod Curve {

    /// 進行度0から始まり、中央で1、進行度1で0へ戻る放物線。
    /// 通常は0から1を渡す。範囲外は補正せず、同じ式の延長として負の値を返す。
    pub def arch01(progress: Float64): Float64 =
        4.0 * progress * (1.0 - progress)

    /// 速さ `speed` で増える量を `span` で折り返し、[0, span) に収めた値。落ち物や流れる
    /// 絵が端まで来たら反対側から出直す、途切れない周回に使う。
    pub def loop(speed: Float64, span: Float64, t: Float64): Float64 =
        Num.fract(speed * t / span) * span

    /// 中心 0 のまわりを振幅 `amp` で往復する波。`freq` は 1 秒あたりの角速度（ラジアン）、
    /// `phase` は t=0 での位相。ゆらぎ・点滅・上下動などの反復に使う。
    pub def sine(amp: Float64, freq: Float64, phase: Float64, t: Float64): Float64 =
        amp * RenderUtil.sinF(freq * t + phase)

    /// 一定の角速度 `rate`（ラジアン毎秒）で回り続ける角度。回転する装飾や針に使う。
    pub def spin(rate: Float64, t: Float64): Float64 =
        rate * t

    /// 周期 `period` で 0→1→0 を往復する三角波。前半で 0 から 1 へ直線で昇り、後半で
    /// 1 から 0 へ直線で降りる。sine より角ばった、行きも帰りも一定速の脈動に使う
    /// （フェード往復・点滅・ピストン運動など）。値は常に [0, 1]。
    pub def tri(period: Float64, t: Float64): Float64 =
        if (period <= 0.0) 0.0
        else {
            let phase = Num.fract(t / period);      // [0, 1) の周期内位置
            1.0 - Float64.abs(2.0 * phase - 1.0)    // 0→1→0 の山
        }

    /// [-1,1] の三角波（sin の直線版・速さ一定）。0 から立ち上がり、1/4 周期で +1、1/2 で 0、
    /// 3/4 で -1、1 周期で 0 に戻る。tri が [0,1] の脈動なのに対し、こちらは符号つきの往復運動
    /// （振り子・行き来する床）に使う。
    /// 注意: Unity/Godot の PingPong（値域 0〜length）とは値域が違うので、混同を避けるため
    /// triWave という別名にしている。
    pub def triWave(u: Float64): Float64 =
        let p = u - Float64.floor(u);
        if (p < 0.25) 4.0 * p
        else if (p < 0.75) 2.0 - 4.0 * p
        else 4.0 * p - 4.0

    /// 減衰バネ: 振幅 `amp` から始まり、`decay`（1 秒あたりの減り・大きいほど早く静まる）で
    /// 小さくなりながら `freq`（1 秒あたりの角速度・ラジアン）で往復する波。
    /// 式は amp · e^(−decay·t) · cos(freq·t)。t=0 で amp、時間とともに 0 へ落ち着く。
    /// 着地のあとの「ぷるん」、UI が跳ねて収まる動きに使う。
    pub def dampedSpring(amp: Float64, decay: Float64, freq: Float64, t: Float64): Float64 =
        amp * Float64.exp(-decay * t) * RenderUtil.cosF(freq * t)

    /// (時刻, 値) の折れ線を `t` で読んだ値。`keyframes` は時刻の昇順。区間内は線形に
    /// 補間し、先頭の時刻より前は先頭値・末尾の時刻より後は末尾値で平ら（外挿しない）。
    /// 宣言データで表した時間変化をそのまま評価する土台に使う。
    pub def pieces(keyframes: List[(Float64, Float64)], t: Float64): Float64 =
        match keyframes {
            case Nil               => 0.0
            case (t0, v0) :: rest  => walk(t0, v0, rest, t)
        }

    def walk(t0: Float64, v0: Float64, rest: List[(Float64, Float64)], t: Float64): Float64 =
        match rest {
            case Nil              => v0                              // 末尾以降は末尾値で平ら
            case (t1, v1) :: more =>
                if (t <= t0) v0                                     // 先頭以前は先頭値で平ら
                else if (t < t1)
                    if (t1 - t0 <= 0.0) v1                          // 同時刻は急な切り替わりとして扱う
                    else v0 + (v1 - v0) * ((t - t0) / (t1 - t0))
                else walk(t1, v1, more, t)
        }
}
