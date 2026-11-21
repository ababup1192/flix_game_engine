// SoftRaster3d.Psx — CPU の描き手（SoftRaster3d）の PS1 風の描き方（Scene3d.PsxLook）: 色の丸め・頂点の丸め・アフィンの uv。
// 式は GPU の描き手の r3d_colorDepth・r3d_vertexSnap・vUvAffine と同じ（docs/scene3d.md の「PS1 風の描き方」）。
pub mod SoftRaster3d.Psx {

    /// 色の丸め（Scene3d.PsxLook の colorDepth・dither・ditherStrength）。bits = 1 成分のビット数（0 で丸めない）・
    /// dither = 4×4 の格子の量（行優先 16 個・強さを掛けた後。1 段 = 1）。
    pub type alias PsxColor = { bits = Int32, dither = Vector[Float64] }

    pub def colorOf(look: Scene3d.PsxLook): PsxColor =
        let strength = Scene3d.Psx.ditherStrengthOf(look);
        { bits = Scene3d.Psx.colorDepthOf(look),
          dither = List.range(0, 16) |> List.map(i -> Scene3d.Psx.ditherAt(look#dither, Int32.remainder(i, 4), i / 4) * strength) |> List.toVector }

    /// 層の画素 (x, y) の画面の値の色 c を PsxColor で丸めた色（Scene3d.Psx.quantize）。
    pub def quantized(p: PsxColor, x: Int32, y: Int32, c: (Float64, Float64, Float64)): (Float64, Float64, Float64) =
        if (p#bits <= 0) c
        else {
            let d = Vector.get(Int32.remainder(y, 4) * 4 + Int32.remainder(x, 4), p#dither);
            let (r, g, b) = c;
            (Scene3d.Psx.quantize(p#bits, d, r), Scene3d.Psx.quantize(p#bits, d, g), Scene3d.Psx.quantize(p#bits, d, b))
        }

    /// clip の段の頂点 v（頭の 4 つが clip の x, y, z, w）の x・y を、size（幅・高さの画素）の画面の格子 grid（画素・左上が 0）の一番近い点へ動かす。
    /// 格子が 0 か、w が 0 以下（目の後ろ）の頂点はそのまま。z と w は変えない。
    pub def snapVertex(grid: Float64, size: (Float64, Float64), v: Vector[Float64]): Vector[Float64] =
        let (sw, sh) = size;
        let w = Vector.get(3, v);
        if (grid <= 0.0 or w <= 0.0) v
        else {
            let sx = Float64.floor((Vector.get(0, v) / w + 1.0) * 0.5 * sw / grid + 0.5) * grid;
            let sy = Float64.floor((1.0 - Vector.get(1, v) / w) * 0.5 * sh / grid + 0.5) * grid;
            let cx = (sx / sw * 2.0 - 1.0) * w;
            let cy = (1.0 - sy / sh * 2.0) * w;
            Vector.mapWithIndex((i, x) -> if (i == 0) cx else if (i == 1) cy else x, v)
        }

    /// 遠近で補正した uv (pu, pv) を、割合 k だけ画面の上でまっすぐつないだ uv へ寄せる（k が 0 なら (pu, pv) のまま）。
    /// weighted = 頂点の (u × w, v × w) を遠近で補正した重み b で足した物・depth = 重みの和の逆数（SoftRaster3d.Internal.perspectiveWeights の 4 つ目）。
    /// まっすぐつないだ uv = Σ λ_i uv_i = Σ b_i (uv_i × w_i) ÷ depth。
    pub def affineUv(k: Float64, depth: Float64, perspective: (Float64, Float64), weighted: (Float64, Float64)): { x = Float64, y = Float64 } =
        let (pu, pv) = perspective;
        let (wu, wv) = weighted;
        if (k <= 0.0 or depth <= 0.0) { x = pu, y = pv }
        else { x = pu + (wu / depth - pu) * k, y = pv + (wv / depth - pv) * k }
}
