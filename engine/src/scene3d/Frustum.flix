// Frustum — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 視錐台（カメラに写る範囲の 6 つの面。閉じた型）。Camera3d.frustum で作る。
/// 判定は外れる側に倒してある（迷ったら中）: 描き手は「外」と言われた物だけを描かずに済ませ、絵は変わらない。
pub mod Frustum {

    /// 面 1 つ = 内向きの法線 n（長さ 1）と d。点 p は n·p + d ≧ −margin の時に面の内側。
    type alias Plane = { nx = Float64, ny = Float64, nz = Float64, d = Float64 }

    // 面 6 つを 5 個ずつ（nx, ny, nz, d, marginOf）平らに並べた Float64 の列。
    // WhyNot: Plane の record を物ごとに引かない — 置いた物 1 つにつき面 6 つ×角 8 つの判定が 1 コマに 3 回走り、record の欄の引きが時間の大半になる。
    enum FrustumData { case FrustumData(Vector[Float64]) }

    def planeStride(): Int32 = 5

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
        let planes = planeOf(1.0, row(0)) :: planeOf(-1.0, row(0)) :: planeOf(1.0, row(1)) :: planeOf(-1.0, row(1))
            :: planeOf(1.0, row(2)) :: planeOf(-1.0, row(2)) :: Nil;
        FrustumData.FrustumData(
            planes |> List.flatMap(p -> p#nx :: p#ny :: p#nz :: p#d :: marginOf(p) :: Nil) |> List.toVector)

    // WhyNot: 長さ 0 の面で割らない — 潰れた行列（fovY 0 など）の面は全部の点を内側と見なす（間引かない）。
    def normalized(a: Float64, b: Float64, c: Float64, d: Float64): Plane =
        let len = Num.sqrt(a * a + b * b + c * c);
        if (len < 1.0e-12 or Float64.isNan(len)) { nx = 0.0, ny = 0.0, nz = 0.0, d = 1.0 }
        else { nx = a / len, ny = b / len, nz = c / len, d = d / len }

    /// 形の座標の箱（min・max）を world で写した物が、視錐台に掛かりうるか。8 つの角が 1 つの面の外に全部あれば偽。
    // WhyNot: 角を Vec3 の List にして Mat4.apply で写さない — 角と面の組ごとに record を作って引くので、1 コマに何百回も走ると確保と欄の引きが支配する。
    //   写す式は Mat4.apply と同じ順で足す（丸めを変えない — GL と CPU と影の地図が同じ判定を使う）。
    pub def intersectsBox(f: Frustum, min: Vec3.Vec3, max: Vec3.Vec3, world: Mat4.Mat4): Bool =
        let FrustumData.FrustumData(planes) = f;
        let m = Mat4.asRows(world);
        let x0 = min#x; let y0 = min#y; let z0 = min#z;
        let x1 = max#x; let y1 = max#y; let z1 = max#z;
        let corners = Vector#{ rowAt(m, 0, x0, y0, z0), rowAt(m, 4, x0, y0, z0), rowAt(m, 8, x0, y0, z0),
                               rowAt(m, 0, x1, y0, z0), rowAt(m, 4, x1, y0, z0), rowAt(m, 8, x1, y0, z0),
                               rowAt(m, 0, x0, y1, z0), rowAt(m, 4, x0, y1, z0), rowAt(m, 8, x0, y1, z0),
                               rowAt(m, 0, x1, y1, z0), rowAt(m, 4, x1, y1, z0), rowAt(m, 8, x1, y1, z0),
                               rowAt(m, 0, x0, y0, z1), rowAt(m, 4, x0, y0, z1), rowAt(m, 8, x0, y0, z1),
                               rowAt(m, 0, x1, y0, z1), rowAt(m, 4, x1, y0, z1), rowAt(m, 8, x1, y0, z1),
                               rowAt(m, 0, x0, y1, z1), rowAt(m, 4, x0, y1, z1), rowAt(m, 8, x0, y1, z1),
                               rowAt(m, 0, x1, y1, z1), rowAt(m, 4, x1, y1, z1), rowAt(m, 8, x1, y1, z1) };
        not isOutsideSomePlane(planes, corners, 0)

    // 行列の行（cells の o から 4 つ）で点を写した 1 成分。Mat4.apply と同じ足す順。
    def rowAt(m: Vector[Float64], o: Int32, x: Float64, y: Float64, z: Float64): Float64 =
        Vector.get(o, m) * x + Vector.get(o + 1, m) * y + Vector.get(o + 2, m) * z + Vector.get(o + 3, m)

    // 面 i（番号）から先に、8 つの角が全部外にある面があるか。
    def isOutsideSomePlane(planes: Vector[Float64], corners: Vector[Float64], i: Int32): Bool =
        if (i >= 6) false
        else {
            let o = i * planeStride();
            allBelow(Vector.get(o, planes), Vector.get(o + 1, planes), Vector.get(o + 2, planes), Vector.get(o + 3, planes),
                     0.0 - Vector.get(o + 4, planes), corners, 0)
                or isOutsideSomePlane(planes, corners, i + 1)
        }

    // 角 k（番号）から先の全部が、面 (n, d) への距離 < limit か。
    def allBelow(nx: Float64, ny: Float64, nz: Float64, d: Float64, limit: Float64, corners: Vector[Float64], k: Int32): Bool =
        if (k >= 8) true
        else {
            let o = k * 3;
            nx * Vector.get(o, corners) + ny * Vector.get(o + 1, corners) + nz * Vector.get(o + 2, corners) + d < limit
                and allBelow(nx, ny, nz, d, limit, corners, k + 1)
        }

    /// 中心 center・半径 radius の球が、視錐台に掛かりうるか。
    pub def intersectsSphere(f: Frustum, center: Vec3.Vec3, radius: Float64): Bool =
        let FrustumData.FrustumData(planes) = f;
        let cx = center#x; let cy = center#y; let cz = center#z;
        let reach = Float64.abs(radius);
        let outside = (i: Int32) -> {
            let o = i * planeStride();
            Vector.get(o, planes) * cx + Vector.get(o + 1, planes) * cy + Vector.get(o + 2, planes) * cz + Vector.get(o + 3, planes)
                < 0.0 - reach - Vector.get(o + 4, planes)
        };
        not (outside(0) or outside(1) or outside(2) or outside(3) or outside(4) or outside(5))

    /// 点 p が視錐台の中か（面の上は中）。
    pub def containsPoint(f: Frustum, p: Vec3.Vec3): Bool = intersectsSphere(f, p, 0.0)

}
