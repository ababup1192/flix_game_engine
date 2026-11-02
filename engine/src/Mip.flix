// Mip — 3D の材質が読む絵の段（mipmap）と、読む段の番号（lod）の式。GL（render_gl の Render3d）と CPU（ShaderEval）が
// 同じ関数で段を作り、同じ式で lod を求める。

/// 絵の段と lod の式。
pub mod Mip {
    import java.lang.Math

    /// 絵 tex の段の列（段 0 = tex・1 × 1 まで）。次の段の辺は floor(n / 2)（1 未満にはしない）で、
    /// 次の段のテクセル (i, j) は前の段の (2i..2i+1, 2j..2j+1) の 4 つの平均（前の段の外へはみ出す列と行は端のテクセルを繰り返す）。
    /// 平均は ARGB の成分ごとに (和 + 2) / 4 の切り捨て。
    // WhyNot: GL の glGenerateMipmap に任せない — 縮め方がドライバ任せで、CPU の描き出しと段の中身がそろわない。
    // WhyNot: sRGB を線形へ戻して平均しない — 絵の値はそのまま光の計算に入れる決まりで、段も同じ値のまま取る。
    pub def build(tex: ShaderEval.TexData): List[ShaderEval.TexData] =
        if (tex#width <= 0 or tex#height <= 0 or (tex#width == 1 and tex#height == 1)) tex :: Nil
        else tex :: build(halve(tex))

    def halve(tex: ShaderEval.TexData): ShaderEval.TexData = region rc {
        let (w, h) = (tex#width, tex#height);
        let (nw, nh) = (Int32.max(1, w / 2), Int32.max(1, h / 2));
        let out: Array[Int32, rc] = Array.empty(rc, nw * nh);
        let at = (x: Int32, y: Int32) -> Vector.get(Int32.min(y, h - 1) * w + Int32.min(x, w - 1), tex#pixels);
        List.range(0, nh) |> List.forEach(j -> List.range(0, nw) |> List.forEach(i -> {
            let quad = at(2 * i, 2 * j) :: at(2 * i + 1, 2 * j) :: at(2 * i, 2 * j + 1) :: at(2 * i + 1, 2 * j + 1) :: Nil;
            let mean = (shift: Int32) ->
                Int32.leftShift((List.sum(List.map(c -> Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, c), 255), quad)) + 2) / 4, shift);
            Array.put(Int32.bitwiseOr(Int32.bitwiseOr(mean(24), mean(16)), Int32.bitwiseOr(mean(8), mean(0))), j * nw + i, out)
        }));
        { width = nw, height = nh, pixels = Array.toVector(out) }
    }

    /// 絵を読む座標の、画面の右隣と下隣の画素との差（uv の単位）。
    pub type alias Derivatives = { dudx = Float64, dvdx = Float64, dudy = Float64, dvdy = Float64 }

    /// 読む段の番号（GL と CPU で同じ式）。差の各成分から floor(d + 0.5) を引き（REPEAT で座標が 1 跳ぶ継ぎ目の画素で
    /// 段が急に上がらないようにする）、ρ = max(|(du/dx·w, dv/dx·h)|, |(du/dy·w, dv/dy·h)|)・lod = clamp(log2(ρ), 0, levels − 1)。
    /// width・height は段 0 の寸法・levels は段の数（1 なら 0）。
    // WhyNot: round で差し引かない — GLSL の round は 0.5 をどちらへ丸めるかが実装任せで、GL と CPU がそろわない。
    pub def lodOf(d: Derivatives, width: Int32, height: Int32, levels: Int32): Float64 =
        let wrapped = (x: Float64) -> x - Float64.floor(x + 0.5);
        let (w, h) = (Int32.toFloat64(width), Int32.toFloat64(height));
        let lengthOf = (a: Float64, b: Float64) -> Vec2.sqrt(a * a + b * b);
        let rho = Float64.max(lengthOf(wrapped(d#dudx) * w, wrapped(d#dvdx) * h), lengthOf(wrapped(d#dudy) * w, wrapped(d#dvdy) * h));
        if (levels <= 1 or rho <= 1.0) 0.0
        else Float64.min(Int32.toFloat64(levels - 1), log2(rho))

    def log2(x: Float64): Float64 = unchecked_cast((Math.log(x) / Math.log(2.0)) as _ \ {})
}
