// Mat4 — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 4×4 の行列（閉じた型 — 長さ 16 を守る）。点は列ベクトルとして右から掛ける（mul(a, b) は b を先に当てる）。
pub mod Mat4 {

    // 行優先の 16 個（cells[row * 4 + col]）。
    enum Mat4Data { case Mat4Data(Vector[Float64]) }

    pub type alias Mat4 = Mat4Data

    def ofRows(cells: Vector[Float64]): Mat4 = Mat4Data.Mat4Data(cells)

    def cell(m: Mat4, row: Int32, col: Int32): Float64 =
        let Mat4Data.Mat4Data(cells) = m;
        Vector.get(row * 4 + col, cells)

    pub def identity(): Mat4 =
        ofRows(Vector#{ 1.0, 0.0, 0.0, 0.0,
                        0.0, 1.0, 0.0, 0.0,
                        0.0, 0.0, 1.0, 0.0,
                        0.0, 0.0, 0.0, 1.0 })

    /// a × b（点には b を先に当て、次に a を当てる）。
    // WhyNot: 16 個をリストで作ってから詰め直さない — 骨の姿勢と描画で 1 コマに何千回も呼ばれ、リストの組み立てが掛け算より重くなる。
    pub def mul(a: Mat4, b: Mat4): Mat4 =
        let Mat4Data.Mat4Data(x) = a;
        let Mat4Data.Mat4Data(y) = b;
        let at = (row, col) ->
            Vector.get(row * 4, x) * Vector.get(col, y) + Vector.get(row * 4 + 1, x) * Vector.get(4 + col, y) +
            Vector.get(row * 4 + 2, x) * Vector.get(8 + col, y) + Vector.get(row * 4 + 3, x) * Vector.get(12 + col, y);
        ofRows(Vector#{ at(0, 0), at(0, 1), at(0, 2), at(0, 3),
                        at(1, 0), at(1, 1), at(1, 2), at(1, 3),
                        at(2, 0), at(2, 1), at(2, 2), at(2, 3),
                        at(3, 0), at(3, 1), at(3, 2), at(3, 3) })

    /// 点を写す（w = 1 で掛け、w での割り算はしない。射影の行列には applyPerspective）。
    pub def apply(m: Mat4, p: Vec3.Vec3): Vec3.Vec3 =
        Vec3.v3(cell(m, 0, 0) * p#x + cell(m, 0, 1) * p#y + cell(m, 0, 2) * p#z + cell(m, 0, 3),
                cell(m, 1, 0) * p#x + cell(m, 1, 1) * p#y + cell(m, 1, 2) * p#z + cell(m, 1, 3),
                cell(m, 2, 0) * p#x + cell(m, 2, 1) * p#y + cell(m, 2, 2) * p#z + cell(m, 2, 3))

    /// 向きを写す（w = 0。平行移動を受けない）。法線には normalMatrix を掛けた物を使う。
    pub def applyDir(m: Mat4, d: Vec3.Vec3): Vec3.Vec3 =
        Vec3.v3(cell(m, 0, 0) * d#x + cell(m, 0, 1) * d#y + cell(m, 0, 2) * d#z,
                cell(m, 1, 0) * d#x + cell(m, 1, 1) * d#y + cell(m, 1, 2) * d#z,
                cell(m, 2, 0) * d#x + cell(m, 2, 1) * d#y + cell(m, 2, 2) * d#z)

    /// 点を w = 1 で掛け、出た w で割る（projectionMatrix × viewMatrix の後の NDC）。w が 0 以下（目の後ろ）は None。
    pub def applyPerspective(m: Mat4, p: Vec3.Vec3): Option[Vec3.Vec3] =
        let w = cell(m, 3, 0) * p#x + cell(m, 3, 1) * p#y + cell(m, 3, 2) * p#z + cell(m, 3, 3);
        if (w <= 0.0) None else Some(Vec3.mul(apply(m, p), 1.0 / w))

    /// 法線を写す行列（左上 3×3 の逆行列の転置。平行移動は持たない）。
    /// scale が軸ごとに違っても、写した法線が面に直交したままになる。向きだけを使い、長さは呼ぶ側で 1 に直す。
    // WhyNot: 行列式がほぼ 0 の時に bug! で止めない — 1 軸を 0 に潰した物（影の板など）も描けるよう、割らない余因子のまま返す。
    pub def normalMatrix(m: Mat4): Mat4 =
        let a = cell(m, 0, 0); let b = cell(m, 0, 1); let c = cell(m, 0, 2);
        let d = cell(m, 1, 0); let e = cell(m, 1, 1); let f = cell(m, 1, 2);
        let g = cell(m, 2, 0); let h = cell(m, 2, 1); let i = cell(m, 2, 2);
        let c00 = e * i - f * h;
        let c01 = f * g - d * i;
        let c02 = d * h - e * g;
        let c10 = c * h - b * i;
        let c11 = a * i - c * g;
        let c12 = b * g - a * h;
        let c20 = b * f - c * e;
        let c21 = c * d - a * f;
        let c22 = a * e - b * d;
        let det = a * c00 + b * c01 + c * c02;
        let s = if (Float64.abs(det) < 1.0e-12) 1.0 else 1.0 / det;
        ofRows(Vector#{ c00 * s, c01 * s, c02 * s, 0.0,
                        c10 * s, c11 * s, c12 * s, 0.0,
                        c20 * s, c21 * s, c22 * s, 0.0,
                        0.0,     0.0,     0.0,     1.0 })

    /// 行優先の 16 個（cells[row * 4 + col]）。見方を変えるだけで写さない（判定の熱い所が 1 点ずつ record を作らずに引くため）。
    pub def asRows(m: Mat4): Vector[Float64] =
        let Mat4Data.Mat4Data(x) = m;
        x

    /// GL の uniform（glUniformMatrix4fv の transpose = false）に渡す列優先の 16 個。
    pub def toColumns(m: Mat4): Vector[Float64] =
        let Mat4Data.Mat4Data(x) = m;
        let at = i -> Vector.get(i, x);
        Vector#{ at(0), at(4), at(8),  at(12),
                 at(1), at(5), at(9),  at(13),
                 at(2), at(6), at(10), at(14),
                 at(3), at(7), at(11), at(15) }

    /// 列優先の 16 個から作る（toColumns の逆・glTF の MAT4 と同じ並び）。長さが 16 でなければ Err。
    pub def ofColumns(v: Vector[Float64]): Result[String, Mat4] =
        if (Vector.length(v) != 16) Err("Mat4.ofColumns: 数が 16 でない（${Vector.length(v)} 個）")
        else
            List.range(0, 16)
                |> List.map(k -> { let row = k / 4; Vector.get((k - row * 4) * 4 + row, v) })
                |> List.toVector
                |> ofRows
                |> Ok

    /// 逆行列。行列式がほぼ 0（1e-12 未満）なら None。
    // WhyNot: normalMatrix のように割らずに返さない — 逆バインド行列の計算で潰れた行列を黙って使うと、形が原点へ縮んで見える。
    pub def inverse(m: Mat4): Option[Mat4] =
        let Mat4Data.Mat4Data(a) = m;
        let g = i -> Vector.get(i, a);
        let s0 = g(0) * g(5) - g(4) * g(1);
        let s1 = g(0) * g(6) - g(4) * g(2);
        let s2 = g(0) * g(7) - g(4) * g(3);
        let s3 = g(1) * g(6) - g(5) * g(2);
        let s4 = g(1) * g(7) - g(5) * g(3);
        let s5 = g(2) * g(7) - g(6) * g(3);
        let c5 = g(10) * g(15) - g(14) * g(11);
        let c4 = g(9) * g(15) - g(13) * g(11);
        let c3 = g(9) * g(14) - g(13) * g(10);
        let c2 = g(8) * g(15) - g(12) * g(11);
        let c1 = g(8) * g(14) - g(12) * g(10);
        let c0 = g(8) * g(13) - g(12) * g(9);
        let det = s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0;
        if (Float64.abs(det) < 1.0e-12) None
        else {
            let d = 1.0 / det;
            Some(ofRows(Vector#{
                ( g(5) * c5 - g(6) * c4 + g(7) * c3) * d,
                (0.0 - g(1) * c5 + g(2) * c4 - g(3) * c3) * d,
                ( g(13) * s5 - g(14) * s4 + g(15) * s3) * d,
                (0.0 - g(9) * s5 + g(10) * s4 - g(11) * s3) * d,
                (0.0 - g(4) * c5 + g(6) * c2 - g(7) * c1) * d,
                ( g(0) * c5 - g(2) * c2 + g(3) * c1) * d,
                (0.0 - g(12) * s5 + g(14) * s2 - g(15) * s1) * d,
                ( g(8) * s5 - g(10) * s2 + g(11) * s1) * d,
                ( g(4) * c4 - g(5) * c2 + g(7) * c0) * d,
                (0.0 - g(0) * c4 + g(1) * c2 - g(3) * c0) * d,
                ( g(12) * s4 - g(13) * s2 + g(15) * s0) * d,
                (0.0 - g(8) * s4 + g(9) * s2 - g(11) * s0) * d,
                (0.0 - g(4) * c3 + g(5) * c1 - g(6) * c0) * d,
                ( g(0) * c3 - g(1) * c1 + g(2) * c0) * d,
                (0.0 - g(12) * s3 + g(13) * s1 - g(14) * s0) * d,
                ( g(8) * s3 - g(9) * s1 + g(10) * s0) * d
            }))
        }

    /// 平行移動。
    pub def translate(v: Vec3.Vec3): Mat4 =
        ofRows(Vector#{ 1.0, 0.0, 0.0, v#x,
                        0.0, 1.0, 0.0, v#y,
                        0.0, 0.0, 1.0, v#z,
                        0.0, 0.0, 0.0, 1.0 })

    /// 軸ごとの倍率。
    pub def scale(v: Vec3.Vec3): Mat4 =
        ofRows(Vector#{ v#x, 0.0, 0.0, 0.0,
                        0.0, v#y, 0.0, 0.0,
                        0.0, 0.0, v#z, 0.0,
                        0.0, 0.0, 0.0, 1.0 })

    /// 3 本の行で左上 3×3 を組む（平行移動なし）。目の座標の軸を並べる時に使う。
    pub def ofLinearRows(row0: Vec3.Vec3, row1: Vec3.Vec3, row2: Vec3.Vec3): Mat4 =
        ofRows(Vector#{ row0#x, row0#y, row0#z, 0.0,
                        row1#x, row1#y, row1#z, 0.0,
                        row2#x, row2#y, row2#z, 0.0,
                        0.0,    0.0,    0.0,    1.0 })

    /// GL の透視（右手系の目の座標 → clip。奥行きは near で −1・far で +1。w = −z）。
    pub def perspective(lens: { xScale = Float64, yScale = Float64, near = Float64, far = Float64 }): Mat4 =
        let n = lens#near;
        let f = lens#far;
        ofRows(Vector#{ lens#xScale, 0.0,         0.0,               0.0,
                        0.0,         lens#yScale, 0.0,               0.0,
                        0.0,         0.0,         (f + n) / (n - f), 2.0 * f * n / (n - f),
                        0.0,         0.0,         -1.0,              0.0 })

    /// Y 軸まわり（ラジアン）。増えると +Z が +X へ回る（カメラの yaw と同じ向き）。
    pub def rotateY(angle: Float64): Mat4 =
        let s = Num.sin(angle);
        let c = Num.cos(angle);
        ofRows(Vector#{ c,   0.0, s,   0.0,
                        0.0, 1.0, 0.0, 0.0,
                        0.0 - s, 0.0, c, 0.0,
                        0.0, 0.0, 0.0, 1.0 })

    /// X 軸まわり（ラジアン）。増えると +Z が −Y へ倒れる（カメラの pitch と同じ「正で下を向く」）。
    pub def rotateX(angle: Float64): Mat4 =
        let s = Num.sin(angle);
        let c = Num.cos(angle);
        ofRows(Vector#{ 1.0, 0.0, 0.0,     0.0,
                        0.0, c,   0.0 - s, 0.0,
                        0.0, s,   c,       0.0,
                        0.0, 0.0, 0.0,     1.0 })

    /// Z 軸まわり（ラジアン）。増えると +X が +Y へ回る。
    pub def rotateZ(angle: Float64): Mat4 =
        let s = Num.sin(angle);
        let c = Num.cos(angle);
        ofRows(Vector#{ c,   0.0 - s, 0.0, 0.0,
                        s,   c,       0.0, 0.0,
                        0.0, 0.0,     1.0, 0.0,
                        0.0, 0.0,     0.0, 1.0 })
}
