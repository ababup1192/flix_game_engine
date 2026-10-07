// AudioFade — BGM や効果音の音量を、進行度 t だけからひとつ決める道具箱。
// 「フェードイン・フェードアウト・2 曲の入れ替え（クロスフェード）」が、状態を持たない
// 計算だけで組めるので、実機でもテストでも WAV 焼き込みでも同じカーブになる。
// 利用例: Transition.Progress で t を進め、毎フレーム volumeOf の値を Audio.setVolume へ渡す。
// イージングは持たない: 呼び側で t を変形して渡せば効く（例: t*t でゆっくり立ち上がる。Transition と同じ思想）。

pub mod AudioFade {

    /// フェードの端点。start = 進行度 0 のときの音量、target = 進行度 1 のときの音量
    /// （同じ Float64 が並ぶので取り違えないよう名前渡しにする）。
    pub type alias Fade = { start = Float64, target = Float64 }

    /// フェードイン（無音 → 全開）の端点。
    pub def fadeIn(): Fade = { start = 0.0, target = 1.0 }

    /// フェードアウト（全開 → 無音）の端点。
    pub def fadeOut(): Fade = { start = 1.0, target = 0.0 }

    /// 進行度 t（[0,1] にクランプ）から音量をひとつ決める。start と target の間の直線上の値。
    pub def volumeOf(fade: Fade, t: Float64): Float64 =
        let tc = Float64.max(0.0, Float64.min(1.0, t));
        fade#start + (fade#target - fade#start) * tc

    /// 2 曲の入れ替え: 同じ t で「消える側・現れる側」の音量の組を返す。
    /// 線形どうしなので 2 つの和は常に 1.0（合計音量が途中で凹まない）。
    pub def crossfadeOf(t: Float64): (Float64, Float64) =
        (volumeOf(fadeOut(), t), volumeOf(fadeIn(), t))
}
