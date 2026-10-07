// RenderUtil — 描画に使う数値変換ヘルパー。
//
// GL の uniform やシェーダに渡す前の Float32 変換・丸め・三角関数をまとめる。
// engine（契約層）に置くことで、フロント・各バックエンド・ゲームが共有して使える。

pub mod RenderUtil {
    import java.lang.Math

    /// Float64 → Float32 (GL uniform 用)
    pub def f32(v: Float64): Float32 =
        Float64.truncateToFloat32(v)

    /// Float64 → Int32 (四捨五入)
    pub def floatToInt32(v: Float64): Int32 =
        Int64.truncateToInt32(unchecked_cast(Math.round(v) as _ \ {}))

    pub def sinF(x: Float64): Float64 =
        unchecked_cast(Math.sin(x) as _ \ {})

    pub def cosF(x: Float64): Float64 =
        unchecked_cast(Math.cos(x) as _ \ {})

    pub def sqrtF(x: Float64): Float64 =
        unchecked_cast(Math.sqrt(x) as _ \ {})

}
