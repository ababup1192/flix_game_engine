// Frustum — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 視錐台（カメラに写る範囲の 6 つの面。閉じた型）。Camera3d.frustum で作る。
/// 判定は外れる側に倒してある（迷ったら中）: 描き手は「外」と言われた物だけを描かずに済ませ、絵は変わらない。
pub mod Frustum {

    /// 面 1 つ = 内向きの法線 n（長さ 1）と d。点 p は n·p + d ≧ −margin の時に面の内側。
    type alias Plane = { nx = Float64, ny = Float64, nz = Float64, d = Float64 }

    enum FrustumData { case FrustumData(List[Plane]) }

    pub type alias Frustum = FrustumData

    /// 面 p の外と見なす距離の余裕（world の長さ）: 1e-4 に、面の距離の項 |d| の 1e-5 倍を足す。
    // WhyNot: 一定の 1e-4 にしない — GL は単精度の行列で深度を出すので、far が大きい場面や原点から遠い場面では
    //   面のすぐ外の三角形を描く丸めが 1e-4 を超える。横の面は画素の中心まで半画素あるので余計に描くだけで済む。
    def marginOf(p: Plane): Float64 = 0.0001 + Float64.abs(p#d) * 0.00001

    /// clip の行列（projectionMatrix × viewMatrix）の行から 6 つの面を取り出す（左・右・下・上・near・far）。
    pub def ofClipMatrix(clip: Mat4.Mat4): Frustum =
        let c = Mat4.toColumns(clip);
        let row = (i: Int32) -> (Vector.get(i, c), Vector.get(4 + i, c), Vector.get(8 + i, c), Vector.get(12 + i, c));
        let (w0, w1, w2, w3) = row(3);
        let planeOf = (sign: Float64, r: (Float64, Float64, Float64, Float64)) -> {
            let (a, b, cc, dd) = r;
            normalized(w0 + sign * a, w1 + sign * b, w2 + sign * cc, w3 + sign * dd)
        };
        FrustumData.FrustumData(
            planeOf(1.0, row(0)) :: planeOf(-1.0, row(0)) :: planeOf(1.0, row(1)) :: planeOf(-1.0, row(1))
                :: planeOf(1.0, row(2)) :: planeOf(-1.0, row(2)) :: Nil)

    // WhyNot: 長さ 0 の面で割らない — 潰れた行列（fovY 0 など）の面は全部の点を内側と見なす（間引かない）。
    def normalized(a: Float64, b: Float64, c: Float64, d: Float64): Plane =
        let len = Num.sqrt(a * a + b * b + c * c);
        if (len < 1.0e-12 or Float64.isNan(len)) { nx = 0.0, ny = 0.0, nz = 0.0, d = 1.0 }
        else { nx = a / len, ny = b / len, nz = c / len, d = d / len }

    def distance(p: Plane, v: Vec3.Vec3): Float64 = p#nx * v#x + p#ny * v#y + p#nz * v#z + p#d

    /// 形の座標の箱（min・max）を world で写した物が、視錐台に掛かりうるか。8 つの角が 1 つの面の外に全部あれば偽。
    pub def intersectsBox(f: Frustum, min: Vec3.Vec3, max: Vec3.Vec3, world: Mat4.Mat4): Bool =
        let FrustumData.FrustumData(planes) = f;
        let corners = Mesh3d.cornersOf({ min = min, max = max }) |> List.map(Mat4.apply(world));
        not List.exists(p -> List.forAll(v -> distance(p, v) < 0.0 - marginOf(p), corners), planes)

    /// 中心 center・半径 radius の球が、視錐台に掛かりうるか。
    pub def intersectsSphere(f: Frustum, center: Vec3.Vec3, radius: Float64): Bool =
        let FrustumData.FrustumData(planes) = f;
        not List.exists(p -> distance(p, center) < 0.0 - Float64.abs(radius) - marginOf(p), planes)

    /// 点 p が視錐台の中か（面の上は中）。
    pub def containsPoint(f: Frustum, p: Vec3.Vec3): Bool = intersectsSphere(f, p, 0.0)

}
