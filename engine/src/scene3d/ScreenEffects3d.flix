// ScreenEffects3d — 3D の画面の上の技（SSAO）の値と、3 つの描き手が同じに使う表の値。
// 式は GPU（render_gl の Render3d.ScreenPasses の AST）と CPU（engine_tools の SoftRaster3d.ScreenEffects の Flix）が同じ並びで書き、
// gl-parity の許す画素の数でそろえる。表の値（tap の並び・模様の定数・ぼかしの重み）はこのモジュールの 1 か所から両方へ流す。
//
// SSAO の式（mask の 1 画素。座標は奥行きの絵の場面の矩形の中の画素・左上が 0）:
//   c      = mask の画素の真ん中が乗る奥行きの画素・d = 奥行きの値（目からの距離 / depthRange。1 は何も無い）
//   P(q)   = eye + normalize(F' + X' × ndcX(q) + U' × ndcY(q)) × d(q) × depthRange        F'・X'・U' は Scene3d.Internal.ScreenInputs.rayBasisOf
//   n      = 左右・上下の差の短い方どうしの外積（目の方へ向ける）
//   rPix   = min(radius × projScale / (d(c) × depthRange), 場面の高さ × maxRadiusFraction)      projScale = 場面の高さ / (2 tan(fovY / 2))
//   tap i  = 角 2π (ign + (i + 0.5) / taps × spiralTurns)・半径 rPix × (i + 0.5) / taps の画素（ign = interleaved gradient noise）
//   寄与   = max(0, (Q − P)·n / √(|Q − P|² + ε) − bias) × clamp01(1 − |Q − P|² / thickness²)（何も無い画素は 0）
//   ao     = clamp01(1 − intensity × Σ 寄与 / taps)^power
// ぼかし: 横と縦に 1 回ずつ。重み (1, 4, 6, 4, 1) で、奥行きが真ん中から相対で blurDepthTolerance を超えて違う画素は外す。
// mask の値は R8 の描き先に書くので、各回の後で 1/255 に丸める（CPU の描き手も同じに丸める）。

/// 3D の画面の上の技の値（PostStack が組み、3D の描き手が読む）。
pub mod ScreenEffects3d {

    /// SSAO の値（Godot の Environment の ssao_*・Unity URP の SSAO と同じ物）。
    /// radius = 調べる半径（m。場面の unitsPerMeter を掛けて使う）・intensity = 暗くする強さ・power = 暗さの曲線（1 で直線・大きいほど隅だけが暗い）・
    /// taps = 1 画素で調べる点の数（4〜16 に丸める）・thickness = この距離（m）より離れた点は数えない（手前の物の輪郭の後ろが暗く縁取られるのを抑える）・
    /// scale = mask の解像度の倍率（0.25〜1 に丸める）・lightAffect = 直接光（点光源・スポット・太陽）にも掛ける割合（0..1。Godot の ssao_light_affect）。
    /// 組む時は `{ radius = 0.5 | ScreenEffects3d.ambientOcclusion() }` の形で書く（欄を足してもゲームの字が止まらないように）。
    pub type alias AmbientOcclusion = { radius = Float64, intensity = Float64, power = Float64, taps = Int32, thickness = Float64, scale = Float64,
                                        lightAffect = Float64 }

    /// 既定の SSAO（半径 1 m・強さ 2・曲線 1.5・12 点・2 m より離れた点は数えない・mask は半分の解像度・直接光には掛けない）。
    pub def ambientOcclusion(): AmbientOcclusion =
        { radius = 1.0, intensity = 2.0, power = 1.5, taps = 12, thickness = 2.0, scale = 0.5, lightAffect = 0.0 }

    /// 場面の色の代わりに描き手が出す内側の絵（PostStack.DebugView の行き先）。AmbientOcclusion = SSAO の mask（灰色）。
    pub enum ScreenDebug with Eq, ToString {
        case AmbientOcclusion
    }

    /// taps を 4〜16 に丸めた数。
    pub def tapsOf(ao: AmbientOcclusion): Int32 = Int32.max(4, Int32.min(16, ao#taps))

    /// scale を 0.25〜1 に丸めた倍率（有限でない値は 1）。
    pub def scaleOf(ao: AmbientOcclusion): Float64 =
        if (not Float64.isFinite(ao#scale)) 1.0 else Float64.max(0.25, Float64.min(1.0, ao#scale))

    /// power を 0.1 以上に丸めた曲線（0 以下の pow は値が決まらない）。
    pub def powerOf(ao: AmbientOcclusion): Float64 = if (Float64.isFinite(ao#power)) Float64.max(0.1, ao#power) else 1.0

    /// lightAffect を 0..1 に丸めた割合。
    pub def lightAffectOf(ao: AmbientOcclusion): Float64 = if (Float64.isFinite(ao#lightAffect)) Num.clamp01(ao#lightAffect) else 0.0

    /// 場面の描き先 width × height の画素に対する mask の大きさ（1 画素以上）。
    pub def maskSizeOf(ao: AmbientOcclusion, width: Int32, height: Int32): (Int32, Int32) =
        let side = (n: Int32) -> Int32.max(1, Float64.tryToInt32(Float64.floor(Int32.toFloat64(n) * scaleOf(ao) + 0.5)) |> Option.getWithDefault(1));
        (side(width), side(height))

    // ── 表の値（式の定数。GPU の AST と CPU の Flix が両方ここから読む） ──

    /// 寄与から引く cos の閾（平らな面の小さな凹凸を数えない）。
    pub def bias(): Float64 = 0.05

    /// |Q − P|² に足す小さな値（場面の長さ²）。
    pub def epsilon(): Float64 = 1.0e-4

    /// tap の渦の巻き数。
    pub def spiralTurns(): Float64 = 7.0

    /// 調べる半径の画素の上限（場面の高さに対する割合。目の前の面で tap が画面の端まで飛ばないように）。
    pub def maxRadiusFraction(): Float64 = 0.25

    /// interleaved gradient noise の 3 つの係数（Jimenez 2014）: ign = fract(c × fract(a × x + b × y))。
    pub def noiseA(): Float64 = 0.06711056
    pub def noiseB(): Float64 = 0.00583715
    pub def noiseC(): Float64 = 52.9829189

    /// ぼかしの重み（真ん中から 0・1・2 画素）。
    pub def blurCenterWeight(): Float64 = 6.0
    pub def blurNearWeight(): Float64 = 4.0
    pub def blurFarWeight(): Float64 = 1.0

    /// ぼかしで外す奥行きの違い（真ん中の奥行きに対する割合）。
    pub def blurDepthTolerance(): Float64 = 0.05
}
