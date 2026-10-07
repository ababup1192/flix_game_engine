// Motion — 物の動かし方の小さな道具箱（等速移動と往復運動）。
// 「位置 += 速度 × 経過時間」や「基準 ± 三角波のずれ」を毎回書かずに済む。
// 利用例: 弾をまっすぐ飛ばす / 動く床・上下する敵を時刻から導く。
// 注意: 重力や衝突のはね返りは持たない（必要なら別の処理で）。

pub mod Motion {

    /// position を velocity で dt 秒積分する。両方持つ entity だけ動く。
    pub def integrate(positions: Map[EntityId, Vec2.Vec2],
                      velocities: Map[EntityId, Vec2.Vec2], dt: Float64): Map[EntityId, Vec2.Vec2] =
        Query.updateWith2(positions, velocities, (p, v) -> Vec2.add(p, Vec2.mul(v, dt)))

    /// 物の往復運動の仕様。基準位置からのずれを時刻の純関数で導く（状態を持たない・振り子）。
    /// axis は動く方向・amplitude は振れ幅・period は往復 1 周期の秒数・phase は位相（0..1）。
    /// 利用例: 動く床や上下する敵の「実位置 = 基準 + swingOffset」。
    pub type alias Swing = { axis = Vec2.Vec2, amplitude = Float64, period = Float64, phase = Float64 }

    /// 時刻 t での基準位置からのずれ。triWave で駆動するので速さは一定（4×amplitude/period）。
    pub def swingOffset(osc: Swing, t: Float64): Vec2.Vec2 =
        Vec2.mul(osc#axis, osc#amplitude * Curve.triWave(t / osc#period + osc#phase))
}
