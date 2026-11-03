// SoftRaster3dLightCases — 生成した物（LightModel3d.Codegen.generateFlixCases）。手で直さない。直すのは LightModel3d の木で、
// `make gen-light3d` で作り直す（入っている物と作り直した物が同じことは engine_tools の TestSoftRaster3dLight が確かめる）。

/// 生成器のエッジケースが組める字になることを、テストの作業場で組んで確かめる。
pub mod SoftRaster3dLightCases {

    def toon(steps: Int32, x: Float64): Float64 =
        if (steps <= 0) x
        else {
            let s = Int32.toFloat64(steps);
            Float64.floor(x * s + 0.5) / s
        }

    /// y だけ使う vec3 の Let。
    pub def oneComponentLet(_nX: Float64, nY: Float64, _nZ: Float64): (Float64, Float64, Float64) =
        let v_0Y = (nY + nY);
        (v_0Y, v_0Y, v_0Y)

    /// 引数を読まず x だけ使う光のループ。
    pub def loopWithoutParams(points: Vector[Float64]): (Float64, Float64, Float64) =
        let (points_0X, _points_0Y, _points_0Z) = loopWithoutParamsPoints(points, 0, 0.0, 0.0, 0.0);
        (points_0X, points_0X, points_0X)

    /// 同じエントリの中身の違う 2 つのループ。
    pub def twoLoops(points: Vector[Float64]): (Float64, Float64, Float64) =
        let (points_0X, points_0Y, points_0Z) = twoLoopsPoints(points, 0, 0.0, 0.0, 0.0);
        let (points_1X, points_1Y, points_1Z) = loopWithoutParamsPoints(points, 0, 0.0, 0.0, 0.0);
        ((points_0X + points_1X), (points_0Y + points_1Y), (points_0Z + points_1Z))

    /// 枝に Let のあるスカラーの Select。
    pub def scalarBranchWithLet(_nX: Float64, nY: Float64, _nZ: Float64): (Float64, Float64, Float64) =
        let t_1 = if ((nY > 0.0)) {
            let a_0 = (nY * nY);
            (a_0 + a_0)
        } else {
            0.0
        };
        (t_1, t_1, t_1)

    /// 枝に Let のある vec3 の Select。
    pub def vec3BranchWithLet(nX: Float64, nY: Float64, nZ: Float64): (Float64, Float64, Float64) =
        let (t_1X, t_1Y, t_1Z) = if ((nY > 0.0)) {
            let w_0X = (nX + nX);
            let w_0Y = (nY + nY);
            let w_0Z = (nZ + nZ);
            (w_0X, w_0Y, w_0Z)
        } else {
            (nX, nY, nZ)
        };
        (t_1X, t_1Y, t_1Z)

    /// エントリに書いた引数の順（法線が先）。値は 点 − 法線。
    pub def declaredOrder(nX: Float64, nY: Float64, nZ: Float64, pX: Float64, pY: Float64, pZ: Float64): (Float64, Float64, Float64) =
        ((pX - nX), (pY - nY), (pZ - nZ))

    /// 成分が同じ名前でも数でもない式の Make（1 回だけ計算する）と負の数。
    pub def sameComponents(_nX: Float64, nY: Float64, _nZ: Float64): (Float64, Float64, Float64) =
        let t_0 = ((nY * nY) * (-2.0));
        (t_0, t_0, t_0)

    /// スポットのループで読む欄（外の cos・内の cos・range²・color）と toon。
    pub def spotFields(steps: Int32, spots: Vector[Float64]): (Float64, Float64, Float64) =
        let (spots_0X, spots_0Y, spots_0Z) = spotFieldsSpots(spots, 0, 0.0, 0.0, 0.0);
        (toon(steps, spots_0X), toon(steps, spots_0Y), toon(steps, spots_0Z))

    def loopWithoutParamsPoints(lights: Vector[Float64], i: Int32, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 7 > Vector.length(lights)) (accX, accY, accZ)
        else {
            loopWithoutParamsPoints(lights, i + 7, (accX + Vector.get(i + 3, lights)), (accY + Vector.get(i + 4, lights)), (accZ + Vector.get(i + 5, lights)))
        }

    def twoLoopsPoints(lights: Vector[Float64], i: Int32, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 7 > Vector.length(lights)) (accX, accY, accZ)
        else {
            twoLoopsPoints(lights, i + 7, (accX + (Vector.get(i + 3, lights) * 2.0)), (accY + (Vector.get(i + 4, lights) * 2.0)), (accZ + (Vector.get(i + 5, lights) * 2.0)))
        }

    def spotFieldsSpots(lights: Vector[Float64], i: Int32, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 12 > Vector.length(lights)) (accX, accY, accZ)
        else {
            let t_l0 = ((Vector.get(i + 6, lights) + Vector.get(i + 7, lights)) + Vector.get(i + 11, lights));
            spotFieldsSpots(lights, i + 12, (accX + (Vector.get(i + 8, lights) * t_l0)), (accY + (Vector.get(i + 9, lights) * t_l0)), (accZ + (Vector.get(i + 10, lights) * t_l0)))
        }
}
