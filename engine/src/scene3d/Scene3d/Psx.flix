// Scene3d.Psx — 3D の場面（Scene3d）の部品。PS1 風の描き方（Scene3d.PsxLook）の値のそろえ方と、色の丸めの式・ディザの表。

/// PS1 風の描き方（Scene3d.withPsx）を描き手（GL・WebGPU・CPU）が同じ式で描くための材料。
pub mod Scene3d.Psx {

    /// 色の 1 成分のビット数を 0（切る）か 1〜8 にそろえた物。
    pub def colorDepthOf(look: Scene3d.PsxLook): Int32 = if (look#colorDepth <= 0) 0 else Int32.min(8, look#colorDepth)

    /// 頂点を丸める格子（0 以下・NaN は 0 = 切る）。
    pub def vertexSnapOf(look: Scene3d.PsxLook): Float64 = if (Float64.isNan(look#vertexSnap) or look#vertexSnap <= 0.0) 0.0 else look#vertexSnap

    /// アフィンの割合を 0..1 にそろえた物（NaN は 0）。
    pub def affineOf(look: Scene3d.PsxLook): Float64 = unit01(look#affineTextureMapping)

    /// ディザの強さ（0 以下・NaN は 0）。
    pub def ditherStrengthOf(look: Scene3d.PsxLook): Float64 =
        if (Float64.isNan(look#ditherStrength) or look#ditherStrength <= 0.0) 0.0 else look#ditherStrength

    /// PS1 風の手が 1 つでも効くか（偽なら描き手は今までと同じプログラムと同じ絵）。
    pub def isOn(look: Scene3d.PsxLook): Bool =
        colorDepthOf(look) > 0 or vertexSnapOf(look) > 0.0 or affineOf(look) > 0.0

    /// ディザの表の値（4×4 の格子の x・y。上の行が y = 0）。色の 1 段（2^(8 − ビット数) の 8 bit の段）を 1 とした量で、ditherStrength を掛ける前。
    /// Psx = PS1 の表 ÷ 8・Bayer4x4 = (Bayer の値 + 0.5) ÷ 16 − 0.5・Off = 0。
    pub def ditherAt(pattern: Scene3d.DitherPattern, x: Int32, y: Int32): Float64 =
        let i = Int32.remainder(Int32.remainder(y, 4) + 4, 4) * 4 + Int32.remainder(Int32.remainder(x, 4) + 4, 4);
        match pattern {
            case Scene3d.DitherPattern.Psx      => Int32.toFloat64(List.nth(i, psxTable()) |> Option.getWithDefault(0)) / 8.0
            case Scene3d.DitherPattern.Bayer4x4 => (Int32.toFloat64(List.nth(i, bayer4Table()) |> Option.getWithDefault(0)) + 0.5) / 16.0 - 0.5
            case Scene3d.DitherPattern.Off      => 0.0
        }

    /// PS1 の GPU のディザの表（行優先 4×4・8 bit の値に足す量）。
    pub def psxTable(): List[Int32] = -4 :: 0 :: -3 :: 1 :: 2 :: -2 :: 3 :: -1 :: -3 :: 1 :: -4 :: 0 :: 3 :: -1 :: 2 :: -2 :: Nil

    /// 4×4 の Bayer 行列（行優先・0〜15）。
    pub def bayer4Table(): List[Int32] = 0 :: 8 :: 2 :: 10 :: 12 :: 4 :: 14 :: 6 :: 3 :: 11 :: 1 :: 9 :: 15 :: 7 :: 13 :: 5 :: Nil

    /// ディザの表の番号（描き手の uniform・CPU の分岐で使う。Psx = 0・Bayer4x4 = 1・Off = 2）。
    pub def patternCode(pattern: Scene3d.DitherPattern): Int32 = match pattern {
        case Scene3d.DitherPattern.Psx      => 0
        case Scene3d.DitherPattern.Bayer4x4 => 1
        case Scene3d.DitherPattern.Off      => 2
    }

    /// 画面の値の色の 1 成分 c（0..1）を、ビット数 bits・ディザの量 d（ditherAt × 強さ。1 段 = 1）で丸めた値（3 つの描き手が同じ式を書く）:
    /// 8 bit の値 v = floor(clamp01(c) × 255 + 0.5) に d × 2^(8 − bits) を足して 0..255 に切り、2^(8 − bits) で割って切り捨てた段 q を q ÷ (2^bits − 1) へ。
    pub def quantize(bits: Int32, d: Float64, c: Float64): Float64 =
        if (bits <= 0) c
        else {
            let step = Int32.toFloat64(Int32.leftShift(1, 8 - Int32.min(8, bits)));
            let levels = Int32.toFloat64(Int32.leftShift(1, Int32.min(8, bits)) - 1);
            let v = Float64.floor(unit01(c) * 255.0 + 0.5) + d * step;
            Float64.floor(Float64.max(0.0, Float64.min(255.0, v)) / step) / levels
        }

    def unit01(x: Float64): Float64 = if (Float64.isNan(x)) 0.0 else Float64.max(0.0, Float64.min(1.0, x))
}
