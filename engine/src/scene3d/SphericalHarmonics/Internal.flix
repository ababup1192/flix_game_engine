// SphericalHarmonics.Internal — 拡散の光（SH）の基底と、正距円筒の画素から係数を求める中身。

/// SphericalHarmonics の中身。ゲームは呼ばない（SphericalHarmonics.fromEquirectangular を呼ぶ）。
pub mod SphericalHarmonics.Internal {

    /// 向き (x, y, z) の基底 9 個（SphericalHarmonics の doc の順）。
    pub def basisAt(x: Float64, y: Float64, z: Float64): Vector[Float64] =
        basisWith(c -> c, (a, b) -> a * b, (a, b) -> a - b, x, y, z) |> List.toVector

    /// 基底 9 個の式を、数 num・積 mul・差 sub で組んだ物（Float64 の値にも、光の式の木（LightModel3d）にも使う）。
    // WhyNot: 木の側に同じ 9 個の数を書き写さない — 求める側（basisAt）と読む側（3 つの描き手の木）の式が 1 字でもずれると、陰の色が静かにずれる。
    pub def basisWith(num: Float64 -> a, mul: (a, a) -> a, sub: (a, a) -> a, x: a, y: a, z: a): List[a] =
        num(0.282095) :: mul(num(0.488603), y) :: mul(num(0.488603), z) :: mul(num(0.488603), x) ::
            mul(num(1.092548), mul(x, y)) :: mul(num(1.092548), mul(y, z)) :: mul(num(0.315392), sub(mul(num(3.0), mul(z, z)), num(1.0))) ::
            mul(num(1.092548), mul(x, z)) :: mul(num(0.546274), sub(mul(x, x), mul(y, y))) :: Nil

    /// 縮めた後の横の上限（縦は半分）。
    def gridWidth(): Int32 = 128

    /// 正距円筒の絵（width × height・行 0 が真上）から係数を求める。linearAt(x, y, out) は画素 (x, y) の線形の rgb を out の 0..2 へ書く。
    /// 絵を gridWidth() × gridWidth()/2 以下のセルへ箱の平均で縮め（線形の量で平均）、セルごとに向きと立体角で足し込む。
    /// セルの向き: lat = π(0.5 − v)・φ = 2π(u − 0.5)・d = (cos lat sin φ, sin lat, −cos lat cos φ)（LightModel3d.environmentUvOf の逆）。
    /// 立体角の和が 4π になるように割り直す（一様な景色で irradianceAt がちょうど 1）。
    // WhyNot: 画素ごとに 9 個の基底を足し込まない — 2048 × 1024 の絵で 1,800 万回の積になり、読み込みが 1 秒を超える。縮めてから足しても低い周波数の 9 個はほぼ変わらない。
    // WhyNot: 画素の色を組で返させない — 画素ごとに組の箱が作られる（Mip.build の WhyNot と同じ）。呼ぶ側の配列へ書かせる。
    pub def fromLinear(rc: Region[r], width: Int32, height: Int32, linearAt: (Int32, Int32, Array[Float64, r]) -> Unit \ r): Option[SphericalHarmonics.SphericalHarmonics] \ r =
        let gw = Int32.max(1, Int32.min(gridWidth(), width));
        let gh = Int32.max(1, Int32.min(gridWidth() / 2, height));
        let sums = Array.repeat(rc, 3 * gw * gh, 0.0);
        let counts = Array.repeat(rc, gw * gh, 0);
        let rgb = Array.repeat(rc, 3, 0.0);
        accumulateRows(rc, width, height, gw, gh, linearAt, sums, counts, rgb, 0);
        let acc = Array.repeat(rc, 27, 0.0);
        let total = Ref.fresh(rc, 0.0);
        let pi = Num.pi();
        foreach (j <- List.range(0, gh)) {
            let lat = pi * (0.5 - (Int32.toFloat64(j) + 0.5) / Int32.toFloat64(gh));
            let weight = (2.0 * pi / Int32.toFloat64(gw)) * (pi / Int32.toFloat64(gh)) * Num.cos(lat);
            foreach (i <- List.range(0, gw)) {
                let cell = j * gw + i;
                let n = Int32.toFloat64(Int32.max(1, Array.get(cell, counts)));
                let phi = 2.0 * pi * ((Int32.toFloat64(i) + 0.5) / Int32.toFloat64(gw) - 0.5);
                let basis = basisAt(Num.cos(lat) * Num.sin(phi), Num.sin(lat), 0.0 - Num.cos(lat) * Num.cos(phi));
                Ref.put(Ref.get(total) + weight, total);
                foreach (k <- List.range(0, 9)) {
                    let b = Vector.get(k, basis) * weight / n;
                    foreach (c <- List.range(0, 3)) {
                        Array.put(Array.get(3 * k + c, acc) + Array.get(3 * cell + c, sums) * b, 3 * k + c, acc)
                    }
                }
            }
        };
        let norm = 4.0 * pi / Float64.max(Ref.get(total), 1.0e-12);
        List.range(0, 9)
            |> List.map(k -> {
                let s = norm * bandScale(k);
                Vec3.v3(Array.get(3 * k, acc) * s, Array.get(3 * k + 1, acc) * s, Array.get(3 * k + 2, acc) * s)
            })
            |> SphericalHarmonics.fromCoefficients
            |> Result.toOption

    /// 基底 k の畳み込みの係数 ÷ π（l = 0: 1・l = 1: 2/3・l = 2: 1/4）。
    def bandScale(k: Int32): Float64 = if (k == 0) 1.0 else if (k < 4) 2.0 / 3.0 else 0.25

    /// 行 y から下の画素をセルの和へ積む。
    // WhyNot: List.range の foreach で画素を回さない — 2048 × 1024 の絵で 200 万個の箱になる。数を数える輪で回す。
    def accumulateRows(rc: Region[r], width: Int32, height: Int32, gw: Int32, gh: Int32, linearAt: (Int32, Int32, Array[Float64, r]) -> Unit \ r,
                       sums: Array[Float64, r], counts: Array[Int32, r], rgb: Array[Float64, r], y: Int32): Unit \ r =
        if (y >= height) ()
        else {
            accumulateRow(width, gw, (y * gh / height) * gw, y, linearAt, sums, counts, rgb, 0);
            accumulateRows(rc, width, height, gw, gh, linearAt, sums, counts, rgb, y + 1)
        }

    def accumulateRow(width: Int32, gw: Int32, rowCell: Int32, y: Int32, linearAt: (Int32, Int32, Array[Float64, r]) -> Unit \ r,
                      sums: Array[Float64, r], counts: Array[Int32, r], rgb: Array[Float64, r], x: Int32): Unit \ r =
        if (x >= width) ()
        else {
            let cell = rowCell + x * gw / width;
            linearAt(x, y, rgb);
            Array.put(Array.get(3 * cell, sums) + Array.get(0, rgb), 3 * cell, sums);
            Array.put(Array.get(3 * cell + 1, sums) + Array.get(1, rgb), 3 * cell + 1, sums);
            Array.put(Array.get(3 * cell + 2, sums) + Array.get(2, rgb), 3 * cell + 2, sums);
            Array.put(Array.get(cell, counts) + 1, cell, counts);
            accumulateRow(width, gw, rowCell, y, linearAt, sums, counts, rgb, x + 1)
        }
}
