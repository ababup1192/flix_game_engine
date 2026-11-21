// Gltf.Internal — glb の読み込みが使う、ノードの姿勢と左右の反転の計算と、頂点の色（COLOR_0）の読み方。

/// Gltf の中身。ゲームからは呼ばない。
pub mod Gltf.Internal {
    pub def mirror(): Mat4.Mat4 = Mat4.scale(Vec3.v3(-1.0, 1.0, 1.0))

    /// COLOR_0 の accessor の形 width と型 componentType が読める物か（VEC3・VEC4 と、FLOAT か正規化した UNSIGNED_BYTE・UNSIGNED_SHORT）。読めなければ理由。
    pub def colorAccessorProblem(width: Int32, componentType: Int32, normalized: Bool): Option[String] =
        if (width != 3 and width != 4) Some("glTF: COLOR_0 の幅 ${width} は読まない（VEC3 か VEC4）")
        else if (componentType == 5126 or ((componentType == 5121 or componentType == 5123) and normalized)) None
        else Some("glTF: COLOR_0 の componentType ${componentType} は読まない（FLOAT か正規化した UNSIGNED_BYTE・UNSIGNED_SHORT）")

    /// 頂点の色の欄（頂点ごとに r, g, b の画面の値）。base = baseColorFactor の色（画面の値の 3 つ）・vertex = COLOR_0 の (幅, 値)（正規化の後の 0..1）。
    /// COLOR_0 は glTF の決まりどおり線形の値として読み、0..1 に切ってから画面の値へ戻して base に掛ける（α は読まない）。無ければ base の色だけ。
    // WhyNot: 線形の値のまま描き手へ渡さない — 描き手は頂点の色を画面の値として読む（材質は絵 × 頂点の色を画面の値どうしで掛ける）。
    //   戻さないと Blender でベイクした明るさが暗く沈む。画面の値どうしの掛け算は Blender の線形の掛け算と暗い所で少しずれる（docs/scene3d.md の glTF の頂点の色）。
    pub def colorsOf(count: Int32, base: Vector[Float64], vertex: Option[(Int32, Vector[Float64])]): Vector[Float64] =
        Vector.range(0, count * 3) |> Vector.map(j -> {
            let c = Int32.remainder(j, 3);
            Vector.get(c, base) * vertexChannel(vertex, j / 3, c)
        })

    def vertexChannel(vertex: Option[(Int32, Vector[Float64])], v: Int32, c: Int32): Float64 = match vertex {
        case None              => 1.0
        case Some((w, values)) => screenOfLinear(Vector.get(v * w + c, values))
    }

    // WhyNot: 1 を linearToSrgb に通さない — 式の丸めで 0.9999999999999999 になり、白の COLOR_0 の形が白い頂点の形と別の色（別の鍵）になる。
    def screenOfLinear(x: Float64): Float64 =
        if (x >= 1.0) 1.0 else if (x <= 0.0 or Float64.isNan(x)) 0.0 else Texture3d.linearToSrgb(x)

    /// S·M·S（glTF の座標の行列 → engine の座標の行列）。
    pub def mirrorMat4(m: Mat4.Mat4): Mat4.Mat4 = Mat4.mul(mirror(), Mat4.mul(m, mirror()))

    pub def mirrorPose(p: Skin3d.JointPose): Skin3d.JointPose =
        { translation = Vec3.v3(0.0 - p#translation#x, p#translation#y, p#translation#z),
          rotation = { x = p#rotation#x, y = 0.0 - p#rotation#y, z = 0.0 - p#rotation#z, w = p#rotation#w },
          scale = p#scale }

    /// 列優先の 16 個を平行移動・回転・倍率に分ける（行列式が負なら x の倍率を負にする）。
    pub def decompose(cells: Vector[Float64]): Skin3d.JointPose =
        let c = i -> Vector.get(i, cells);
        let len = (i: Int32) -> Num.sqrt(c(i) * c(i) + c(i + 1) * c(i + 1) + c(i + 2) * c(i + 2));
        let det = c(0) * (c(5) * c(10) - c(9) * c(6)) - c(4) * (c(1) * c(10) - c(9) * c(2)) + c(8) * (c(1) * c(6) - c(5) * c(2));
        let sx = if (det < 0.0) 0.0 - len(0) else len(0);
        let sy = len(4);
        let sz = len(8);
        let safe = s -> if (Float64.abs(s) < 1.0e-12) 1.0 else s;
        let m = (row: Int32, col: Int32) -> c(col * 4 + row) / safe(if (col == 0) sx else if (col == 1) sy else sz);
        { translation = Vec3.v3(c(12), c(13), c(14)), rotation = quatOfRotation(m), scale = Vec3.v3(sx, sy, sz) }

    pub def quatOfRotation(m: (Int32, Int32) -> Float64): Quat.Quat =
        let trace = m(0, 0) + m(1, 1) + m(2, 2);
        let q =
            if (trace > 0.0) {
                let s = Num.sqrt(trace + 1.0) * 2.0;
                { x = (m(2, 1) - m(1, 2)) / s, y = (m(0, 2) - m(2, 0)) / s, z = (m(1, 0) - m(0, 1)) / s, w = 0.25 * s }
            } else if (m(0, 0) > m(1, 1) and m(0, 0) > m(2, 2)) {
                let s = Num.sqrt(1.0 + m(0, 0) - m(1, 1) - m(2, 2)) * 2.0;
                { x = 0.25 * s, y = (m(0, 1) + m(1, 0)) / s, z = (m(0, 2) + m(2, 0)) / s, w = (m(2, 1) - m(1, 2)) / s }
            } else if (m(1, 1) > m(2, 2)) {
                let s = Num.sqrt(1.0 + m(1, 1) - m(0, 0) - m(2, 2)) * 2.0;
                { x = (m(0, 1) + m(1, 0)) / s, y = 0.25 * s, z = (m(1, 2) + m(2, 1)) / s, w = (m(0, 2) - m(2, 0)) / s }
            } else {
                let s = Num.sqrt(1.0 + m(2, 2) - m(0, 0) - m(1, 1)) * 2.0;
                { x = (m(0, 2) + m(2, 0)) / s, y = (m(1, 2) + m(2, 1)) / s, z = 0.25 * s, w = (m(1, 0) - m(0, 1)) / s }
            };
        Quat.normalized(q)

    pub def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 = Vec3.v3(Vector.get(k, v), Vector.get(k + 1, v), Vector.get(k + 2, v))

    pub def quatOf(v: Vector[Float64]): Quat.Quat = { x = Vector.get(0, v), y = Vector.get(1, v), z = Vector.get(2, v), w = Vector.get(3, v) }
}
