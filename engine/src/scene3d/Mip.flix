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
    // WhyNot: 段ごとに Vector と List.range のクロージャーで回さない — 画素ごとに箱が作られ、1024² の絵 1 枚で 20 ms かかる
    //   （たまにしか出ない物を初めて描くコマが跳ねる）。中間の段は配列のまま次の段へ渡す。
    pub def build(average: Average, tex: ShaderEval.TexData): List[ShaderEval.TexData] = region rc {
        let tables = tablesOf(rc, average);
        if (isLastLevel(tex#width, tex#height)) tex :: Nil
        else tex :: halveAll(rc, tables, tex#width, tex#height, Vector.toArray(rc, tex#pixels))
    }

    def isLastLevel(w: Int32, h: Int32): Bool = w <= 0 or h <= 0 or (w == 1 and h == 1)

    def halveAll(rc: Region[r], tables: Tables[r], w: Int32, h: Int32, src: Array[Int32, r]): List[ShaderEval.TexData] \ r =
        let (nw, nh) = halfSize(w, h);
        let out = halveArray(rc, tables, w, h, src);
        let level = { width = nw, height = nh, pixels = Array.toVector(out) };
        if (isLastLevel(nw, nh)) level :: Nil else level :: halveAll(rc, tables, nw, nh, out)

    /// tex の長い辺が maxSide 以下になるまで、Raw の段と同じ縮め方で半分にした絵（もう収まっていれば tex のまま）。
    /// Raw の段の列の頭を落とした物と同じ画素になる（読み込みの時に大きすぎる絵を縮める・取り込みの最大サイズと同じ）。
    // WhyNot: 色の絵を SrgbCurve で縮めない — 読み込みの時は絵の使い方（色か法線か）を知らない。
    pub def shrinkTo(maxSide: Int32, tex: ShaderEval.TexData): ShaderEval.TexData =
        if (fitsIn(maxSide, tex#width, tex#height)) tex
        else region rc {
            let (w, h, pixels) = shrinkArray(rc, tablesOf(rc, Average.Raw), maxSide, tex#width, tex#height, Vector.toArray(rc, tex#pixels));
            { width = w, height = h, pixels = Array.toVector(pixels) }
        }

    def fitsIn(maxSide: Int32, w: Int32, h: Int32): Bool =
        Int32.max(w, h) <= Int32.max(1, maxSide) or (w <= 1 and h <= 1)

    def shrinkArray(rc: Region[r], tables: Tables[r], maxSide: Int32, w: Int32, h: Int32, src: Array[Int32, r]): (Int32, Int32, Array[Int32, r]) \ r =
        if (fitsIn(maxSide, w, h)) (w, h, src)
        else {
            let (nw, nh) = halfSize(w, h);
            shrinkArray(rc, tables, maxSide, nw, nh, halveArray(rc, tables, w, h, src))
        }

    /// rgb の平均の材料。srgb = 偽なら 8bit の値のまま平均する（Raw）。真なら toLinear = 8bit の値 → 線形の量の表と、
    /// edges = 8bit へ戻すしきい値（k − 1 番 = 8bit の値 k の下の端を線形の量にした値）で平均する（SrgbCurve）。
    /// starts = 線形の量の 0〜1 を bucketCount() 等分した区間 b の左の端 b / bucketCount() 以下のしきい値の数（数え始める位置）。
    type alias Tables[r: Region] = { srgb = Bool, toLinear = Array[Float64, r], edges = Array[Float64, r], starts = Array[Int32, r] }

    def tablesOf(rc: Region[r], average: Average): Tables[r] \ r = match average {
        case Average.Raw       => { srgb = false, toLinear = Array.empty(rc, 0), edges = Array.empty(rc, 0), starts = Array.empty(rc, 0) }
        case Average.SrgbCurve =>
            let edges = Vector.range(1, 256) |> Vector.map(k -> Texture3d.srgbToLinear((Int32.toFloat64(k) - 0.5) / 255.0)) |> Vector.toArray(rc);
            let starts = Vector.range(0, bucketCount() + 1)
                |> Vector.map(b -> countFrom(Int32.toFloat64(b) / Int32.toFloat64(bucketCount()), edges, 0)) |> Vector.toArray(rc);
            { srgb = true,
              toLinear = Vector.range(0, 256) |> Vector.map(v -> Texture3d.srgbToLinear(Int32.toFloat64(v) / 255.0)) |> Vector.toArray(rc),
              edges = edges, starts = starts }
    }

    /// 線形の量の 0〜1 を分ける区間の数（2 の冪なので、区間の端は Float64 で丸めずに表せる）。
    def bucketCount(): Int32 = 4096

    def halfSize(w: Int32, h: Int32): (Int32, Int32) = (Int32.max(1, w / 2), Int32.max(1, h / 2))

    /// w × h の src の 1 段上（halfSize の大きさ）。
    def halveArray(rc: Region[r], tables: Tables[r], w: Int32, h: Int32, src: Array[Int32, r]): Array[Int32, r] \ r =
        let (nw, nh) = halfSize(w, h);
        let out = Array.empty(rc, nw * nh);
        halveRows(tables, { w = w, h = h, nw = nw, nh = nh }, src, out, 0);
        out

    def halveRows(tables: Tables[r], size: { w = Int32, h = Int32, nw = Int32, nh = Int32 }, src: Array[Int32, r], out: Array[Int32, r], j: Int32): Unit \ r =
        if (j >= size#nh) ()
        else {
            let row0 = Int32.min(2 * j, size#h - 1) * size#w;
            let row1 = Int32.min(2 * j + 1, size#h - 1) * size#w;
            let cols = { w = size#w, row0 = row0, row1 = row1, nw = size#nw, outRow = j * size#nw };
            halveCols(tables#srgb, { toLinear = tables#toLinear, edges = tables#edges, starts = tables#starts }, cols, src, out, 0);
            halveRows(tables, size, src, out, j + 1)
        }

    // WhyNot: 画素ごとにレコードのフィールドを引かず、平均の仕方を関数で渡さない — フィールドは名前で探し、関数の値は呼ぶたびに
    //   作り直すので、内側のループでは毎回の手間になる。行ごとに 1 回だけ取り出して素の引数で回す。
    def halveCols(srgb: Bool, t: { toLinear = Array[Float64, r], edges = Array[Float64, r], starts = Array[Int32, r] },
                  cols: { w = Int32, row0 = Int32, row1 = Int32, nw = Int32, outRow = Int32 }, src: Array[Int32, r], out: Array[Int32, r], i: Int32): Unit \ r =
        halveColsFrom(srgb, t#toLinear, t#edges, t#starts, cols#w, cols#row0, cols#row1, cols#nw, cols#outRow, src, out, i)

    def halveColsFrom(srgb: Bool, toLinear: Array[Float64, r], edges: Array[Float64, r], starts: Array[Int32, r], w: Int32, row0: Int32, row1: Int32,
                      nw: Int32, outRow: Int32, src: Array[Int32, r], out: Array[Int32, r], i: Int32): Unit \ r =
        if (i >= nw) ()
        else {
            let x0 = Int32.min(2 * i, w - 1);
            let x1 = Int32.min(2 * i + 1, w - 1);
            let a = Array.get(row0 + x0, src);
            let b = Array.get(row0 + x1, src);
            let c = Array.get(row1 + x0, src);
            let d = Array.get(row1 + x1, src);
            let pixel = if (srgb) srgbPixel(toLinear, edges, starts, a, b, c, d) else rawPixel(a, b, c, d);
            Array.put(pixel, outRow + i, out);
            halveColsFrom(srgb, toLinear, edges, starts, w, row0, row1, nw, outRow, src, out, i + 1)
        }

    /// 4 つの ARGB の成分ごとの平均（8bit の値のまま）。
    def rawPixel(a: Int32, b: Int32, c: Int32, d: Int32): Int32 =
        Int32.bitwiseOr(Int32.bitwiseOr(rawMeanOf(24, a, b, c, d), rawMeanOf(16, a, b, c, d)),
                        Int32.bitwiseOr(rawMeanOf(8, a, b, c, d), rawMeanOf(0, a, b, c, d)))

    /// 4 つの ARGB の平均（α は 8bit の値のまま・rgb は線形の量の平均を 8bit の sRGB の値へ）。
    def srgbPixel(toLinear: Array[Float64, r], edges: Array[Float64, r], starts: Array[Int32, r], a: Int32, b: Int32, c: Int32, d: Int32): Int32 \ r =
        Int32.bitwiseOr(Int32.bitwiseOr(rawMeanOf(24, a, b, c, d), srgbMeanOf(toLinear, edges, starts, 16, a, b, c, d)),
                        Int32.bitwiseOr(srgbMeanOf(toLinear, edges, starts, 8, a, b, c, d), srgbMeanOf(toLinear, edges, starts, 0, a, b, c, d)))

    /// 4 つの ARGB の、shift ビット目から 8 ビットの色の成分の、線形の量の平均を 8bit の sRGB の値へ戻して同じ位置に置いた値。
    def srgbMeanOf(toLinear: Array[Float64, r], edges: Array[Float64, r], starts: Array[Int32, r], shift: Int32, a: Int32, b: Int32, c: Int32, d: Int32): Int32 \ r =
        let m = (Array.get(channelOf(shift, a), toLinear) + Array.get(channelOf(shift, b), toLinear)
                 + Array.get(channelOf(shift, c), toLinear) + Array.get(channelOf(shift, d), toLinear)) / 4.0;
        let bucket = Int32.min(bucketCount(), Int32.max(0, Float64.truncateToInt32(m * Int32.toFloat64(bucketCount()))));
        Int32.leftShift(countFrom(m, edges, Array.get(bucket, starts)), shift)

    /// 並び edges（小さい順）の k 番から先で x 以下の物を数え足した数（k 番より前は x 以下と分かっている時に呼ぶ）。
    // WhyNot: 255 本のしきい値を毎回二分探索しない — 平均は画素ごとにばらつき、分かれ道の読みが外れ続けて 1024² の絵 1 枚に 30 ms かかる。
    //   区間の左の端までの数から数え始めれば、ほとんどの画素は 1〜2 本比べて済む（同じ比べで決めるので、答えは二分探索と同じ）。
    def countFrom(x: Float64, edges: Array[Float64, r], k: Int32): Int32 \ r =
        if (k < Array.length(edges) and Array.get(k, edges) <= x) countFrom(x, edges, k + 1) else k

    // WhyNot: Int32.logicalRightShift で取り出さない — 呼ぶたびに引数のレコードを作る。下の 8 ビットだけを残すので、符号を引きずる rightShift で同じ値になる。
    def channelOf(shift: Int32, x: Int32): Int32 = Int32.bitwiseAnd(Int32.rightShift(x, shift), 255)

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
