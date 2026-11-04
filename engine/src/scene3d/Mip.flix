// Mip — 3D の材質が読む絵の段（mipmap）と、読む段の番号（lod）の式。GL（render_gl の Render3d）と CPU（ShaderEval）が
// 同じ関数で段を作り、同じ式で lod を求める。

/// 絵の段と lod の式。
pub mod Mip {
    import java.lang.Math

    /// 段を作る時の、4 つのテクセルの色の平均の仕方。SrgbCurve = 8bit の値を sRGB の曲線の値と見て、線形の量へ戻して平均し、
    /// 8bit の sRGB の値へ戻す（色の絵）・Raw = 8bit の値のまま平均する（法線マップ・数の絵）。α はどちらも 8bit の値のまま平均する。
    pub enum Average with Eq, ToString {
        case SrgbCurve
        case Raw
    }

    /// 絵 tex の段の列（段 0 = tex・1 × 1 まで）。次の段の辺は floor(n / 2)（1 未満にはしない）で、
    /// 次の段のテクセル (i, j) は前の段の (2i..2i+1, 2j..2j+1) の 4 つの平均（前の段の外へはみ出す列と行は端のテクセルを繰り返す）。
    /// Raw と α は ARGB の成分ごとに (和 + 2) / 4 の切り捨て。SrgbCurve の rgb は 4 つの線形の量の平均を、
    /// Texture3d.linearToSrgb × 255 の四捨五入と同じ 8bit の値へ戻す（白と黒の市松の 1 段上は 188）。
    // WhyNot: GL の glGenerateMipmap に任せない — 縮め方がドライバ任せで、CPU の描き出しと段の中身がそろわない。
    // WhyNot: sRGB の式を Mip に写さない — 式は Texture3d に 1 つだけ置く（今の呼び手は 3D の描き手だけで、2D の絵は段を作らない）。
    // WhyNot: テクセルごとに pow を呼ばない — GL は描く糸の中で最初に貼る時に段を作るので、2048² の絵でそのコマがつっかえる。
    //   8bit の値は 256 通りなので、戻す表と 8bit へ戻すしきい値を 1 回作って引く。
    pub def build(average: Average, tex: ShaderEval.TexData): List[ShaderEval.TexData] =
        buildWith(meanOf(average), tex)

    def buildWith(mean: Mean, tex: ShaderEval.TexData): List[ShaderEval.TexData] =
        if (tex#width <= 0 or tex#height <= 0 or (tex#width == 1 and tex#height == 1)) tex :: Nil
        else tex :: buildWith(mean, halve(mean, tex))

    /// tex の長い辺が maxSide 以下になるまで、Raw の段と同じ縮め方で半分にした絵（もう収まっていれば tex のまま）。
    /// Raw の段の列の頭を落とした物と同じ画素になる（読み込みの時に大きすぎる絵を縮める・取り込みの最大サイズと同じ）。
    // WhyNot: 色の絵を SrgbCurve で縮めない — 読み込みの時は絵の使い方（色か法線か）を知らない。
    pub def shrinkTo(maxSide: Int32, tex: ShaderEval.TexData): ShaderEval.TexData =
        if (Int32.max(tex#width, tex#height) <= Int32.max(1, maxSide) or (tex#width <= 1 and tex#height <= 1)) tex
        else shrinkTo(maxSide, halve(Mean.RawMean, tex))

    /// rgb の平均の材料。SrgbCurveMean = 8bit の値 → 線形の量の表と、8bit へ戻すしきい値（k − 1 番 = 8bit の値 k の下の端を線形の量にした値）。
    enum Mean {
        case RawMean
        case SrgbCurveMean(Vector[Float64], Vector[Float64])
    }

    def meanOf(average: Average): Mean = match average {
        case Average.Raw       => Mean.RawMean
        case Average.SrgbCurve =>
            Mean.SrgbCurveMean(Vector.range(0, 256) |> Vector.map(v -> Texture3d.srgbToLinear(Int32.toFloat64(v) / 255.0)),
                               Vector.range(1, 256) |> Vector.map(k -> Texture3d.srgbToLinear((Int32.toFloat64(k) - 0.5) / 255.0)))
    }

    def halve(mean: Mean, tex: ShaderEval.TexData): ShaderEval.TexData = region rc {
        let (w, h) = (tex#width, tex#height);
        let (nw, nh) = (Int32.max(1, w / 2), Int32.max(1, h / 2));
        let out: Array[Int32, rc] = Array.empty(rc, nw * nh);
        let src = tex#pixels;
        List.range(0, nh) |> List.forEach(j -> {
            let row0 = Int32.min(2 * j, h - 1) * w;
            let row1 = Int32.min(2 * j + 1, h - 1) * w;
            List.range(0, nw) |> List.forEach(i -> {
                let x0 = Int32.min(2 * i, w - 1);
                let x1 = Int32.min(2 * i + 1, w - 1);
                let (a, b, c, d) = (Vector.get(row0 + x0, src), Vector.get(row0 + x1, src), Vector.get(row1 + x0, src), Vector.get(row1 + x1, src));
                let pixel = Int32.bitwiseOr(Int32.bitwiseOr(rawMeanOf(24, a, b, c, d), colorMeanOf(mean, 16, a, b, c, d)),
                                            Int32.bitwiseOr(colorMeanOf(mean, 8, a, b, c, d), colorMeanOf(mean, 0, a, b, c, d)));
                Array.put(pixel, j * nw + i, out)
            })
        });
        { width = nw, height = nh, pixels = Array.toVector(out) }
    }

    /// 4 つの ARGB の、shift ビット目から 8 ビットの色の成分の平均を同じ位置に置いた値（SrgbCurveMean は線形の量の平均を 8bit の sRGB の値へ）。
    def colorMeanOf(mean: Mean, shift: Int32, a: Int32, b: Int32, c: Int32, d: Int32): Int32 = match mean {
        case Mean.RawMean => rawMeanOf(shift, a, b, c, d)
        case Mean.SrgbCurveMean(toLinear, edges) =>
            let linearOf = (x: Int32) -> Vector.get(channelOf(shift, x), toLinear);
            let m = (linearOf(a) + linearOf(b) + linearOf(c) + linearOf(d)) / 4.0;
            Int32.leftShift(countAtMost(m, edges, 0, Vector.length(edges)), shift)
    }

    /// 並び edges（小さい順）のうち lo..hi の範囲で x 以下の物の数 + lo（二分探索）。
    def countAtMost(x: Float64, edges: Vector[Float64], lo: Int32, hi: Int32): Int32 =
        if (lo >= hi) lo
        else {
            let mid = (lo + hi) / 2;
            if (Vector.get(mid, edges) <= x) countAtMost(x, edges, mid + 1, hi) else countAtMost(x, edges, lo, mid)
        }

    def channelOf(shift: Int32, x: Int32): Int32 = Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, x), 255)

    /// 4 つの ARGB の、shift ビット目から 8 ビットの成分の平均（(和 + 2) / 4 の切り捨て）を同じ位置に置いた値。
    def rawMeanOf(shift: Int32, a: Int32, b: Int32, c: Int32, d: Int32): Int32 =
        Int32.leftShift((channelOf(shift, a) + channelOf(shift, b) + channelOf(shift, c) + channelOf(shift, d) + 2) / 4, shift)

    /// 絵を読む座標の、画面の右隣と下隣の画素との差（uv の単位）。
    pub type alias Derivatives = { dudx = Float64, dvdx = Float64, dudy = Float64, dvdy = Float64 }

    /// 読む段の番号（GL と CPU で同じ式）。差の各成分から floor(d + 0.5) を引き（REPEAT で座標が 1 跳ぶ継ぎ目の画素で
    /// 段が急に上がらないようにする）、ρ = max(|(du/dx·w, dv/dx·h)|, |(du/dy·w, dv/dy·h)|)・lod = clamp(log2(ρ), 0, levels − 1)。
    /// width・height は段 0 の寸法・levels は段の数（1 なら 0）。
    // WhyNot: round で差し引かない — GLSL の round は 0.5 をどちらへ丸めるかが実装任せで、GL と CPU がそろわない。
    pub def lodOf(d: Derivatives, width: Int32, height: Int32, levels: Int32): Float64 =
        let wrapped = (x: Float64) -> x - Float64.floor(x + 0.5);
        let (w, h) = (Int32.toFloat64(width), Int32.toFloat64(height));
        let lengthOf = (a: Float64, b: Float64) -> Num.sqrt(a * a + b * b);
        let rho = Float64.max(lengthOf(wrapped(d#dudx) * w, wrapped(d#dvdx) * h), lengthOf(wrapped(d#dudy) * w, wrapped(d#dvdy) * h));
        if (levels <= 1 or rho <= 1.0) 0.0
        else Float64.min(Int32.toFloat64(levels - 1), log2(rho))

    def log2(x: Float64): Float64 = unchecked_cast((Math.log(x) / Math.log(2.0)) as _ \ {})
}
