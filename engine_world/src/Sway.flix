// Sway — ゆらゆらの共通口。時刻から微小な揺れを作る純粋な道具。
// 蓮の葉の浮遊・草や旗の風・吊るした物など「位置を周期的に少し揺らす」演出に使う。
// このエンジンは render-from-World(絵は毎フレーム World から組む)なので、揺れも
// 「時刻 → オフセット」の純関数として置く。掛け方(一様にずらす / 高さに比例して曲げる)は
// 呼び側が決める — 一様に足せば浮遊、高さ比例で足せば根が止まって先だけしなる。
//
// 利用例:
//   浮遊(蓮): pos + Sway.drift(time, phase, { x = 1.5, y = 1.1 })
//   風(草先端): tipX + Sway.wave(time, phase, 1.3) * windAmp

pub mod Sway {

    /// 基本の揺れ。sin(time*freq + phase*2π)、範囲 -1..1。phase(0..1)で個体ごとに位相をずらす。
    /// これ 1 本を振幅で掛け・高さで掛け、と使い回すのが芯。
    pub def wave(time: Float64, phase: Float64, freq: Float64): Float64 =
        Vec2.sin(time * freq + phase * 6.2831853)

    /// 円を描くように漂う 2D オフセット(浮かぶ蓮の葉など)。amp = 振幅(x,y)。
    /// 縦横で周期をずらして単調な往復に見せない。phase で個体ごとにずらす。
    pub def drift(time: Float64, phase: Float64, amp: Vec2.Vec2): Vec2.Vec2 =
        { x = wave(time, phase, 0.8) * amp#x,
          y = wave(time, phase + 0.18, 0.62) * amp#y }
}
