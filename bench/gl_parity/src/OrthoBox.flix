// 正射影の三角形の道（E 段階）: 箱 1 つを正射影で size × size の深度の地図に塗り、GL（GlOffscreen.drawDepthTriangles）と
// CPU（SoftRaster3d.depthMapOf）の深度を突き合わせる。箱は near と far の両方の面をまたぐので、z ≥ −w の切りと w = 1 の深度が両方効く。
// 正射影のカメラを場面に置く口は無いので、行列と箱はここで組む（Camera3d は変えない）。
// 深度は NDC の z × 0.5 + 0.5（何も無い画素は 1）で、行 0 が NDC の y = −1 側。
mod OrthoBox {
    use fge::{Color, GlOffscreen, Mat4, Mesh3d, Scene3d, SoftRaster3d, Vec3}

    /// 地図の縦横の画素数。
    def size(): Int32 = 64

    /// 深度の差の上限。測った最大 8.7e-5（GL の頂点は 1/256 画素の格子へ丸まるので、傾いた面の深度が画素の中でその分ずれる）。
    def limitDepth(): Float64 = 3.0e-4

    /// 縁の画素で片方だけが塗る組の数の上限（画素の真ん中の判定が Float32 と Float64 で割れる分）。
    def limitCoverage(): Int32 = 8

    /// 箱が少なくとも塗られているはずの画素数（0 のまま一致して通るのを防ぐ）。
    def coveredAtLeast(): Int32 = 200

    def box(): Mesh3d.Mesh3d =
        let p = (x: Float64, y: Float64, z: Float64) -> Vec3.v3(x, y, z);
        let face = (pts: List[Vec3.Vec3]) -> { points = pts, color = Color.rgb(1.0, 1.0, 1.0) };
        Mesh3d.fromPolygons(
            face(p(1.0, -1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::
            face(p(-1.0, -1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, 1.0, -1.0) :: p(-1.0, -1.0, -1.0) :: Nil) ::
            face(p(-1.0, 1.0, -1.0) :: p(-1.0, 1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(1.0, 1.0, -1.0) :: Nil) ::
            face(p(-1.0, -1.0, 1.0) :: p(-1.0, -1.0, -1.0) :: p(1.0, -1.0, -1.0) :: p(1.0, -1.0, 1.0) :: Nil) ::
            face(p(1.0, -1.0, 1.0) :: p(1.0, 1.0, 1.0) :: p(-1.0, 1.0, 1.0) :: p(-1.0, -1.0, 1.0) :: Nil) ::
            face(p(-1.0, -1.0, -1.0) :: p(-1.0, 1.0, -1.0) :: p(1.0, 1.0, -1.0) :: p(1.0, -1.0, -1.0) :: Nil) ::
            Nil)

    /// 目の前（−z）へ 0.5..3.0 の箱を −2..2 の四角で見る正射影。
    def ortho(): Mat4.Mat4 =
        Mat4.orthographic({ left = -2.0, right = 2.0, bottom = -2.0, top = 2.0, near = 0.5, far = 3.0 })

    /// 箱の置き場（z −3.2..0.2 に広がるので near の面と far の面の両方を切る）。
    def world(): Mat4.Mat4 =
        Mat4.mul(Mat4.translate(Vec3.v3(0.1, -0.05, -1.5)), Mat4.mul(Mat4.rotateX(0.45), Mat4.rotateY(0.6)))

    /// GL の側の深度（今の糸の GL の文脈で）。
    pub def drawGl(): Result[String, Vector[Float32]] \ IO =
        let mesh = box();
        GlOffscreen.drawDepthTriangles(Mesh3d.positions(mesh) |> positionsIn(world()), Mesh3d.indices(mesh), ortho(), size())

    /// 頂点を world で写した後の位置（GL の側に world を掛ける道を作らず、行列を 1 つにする）。
    def positionsIn(m: Mat4.Mat4, positions: Vector[Float64]): Vector[Float64] =
        Vector.range(0, Vector.length(positions) / 3) |> Vector.flatMap(k -> {
            let v = Mat4.apply(m, Vec3.v3(Vector.get(k * 3, positions), Vector.get(k * 3 + 1, positions), Vector.get(k * 3 + 2, positions)));
            Vector#{ v#x, v#y, v#z }
        })

    /// CPU の側の深度（置いた物の world が頂点を写す。GL の側は同じ写しを頂点へ先に掛けてある）。
    def drawCpu(): Vector[Float64] \ IO =
        let placed = Scene3d.meshInstance(box(), world());
        SoftRaster3d.depthMapOf(placed :: Nil, { view = Mat4.identity(), proj = ortho(), projection = SoftRaster3d.Projection.Orthographic }, size())

    /// 1 行（行頭タグ・列順は ExprRows の行と同じ）を出し、合っていれば真。
    pub def report(gl: Result[String, Vector[Float32]]): Bool \ IO =
        match gl {
            case Err(why) =>
                println("[parity] orthoBox       E  比較不能（${why}）");
                false
            case Ok(glDepths) =>
                let cpuDepths = drawCpu();
                let pairs = Vector.zip(glDepths, cpuDepths) |> Vector.map(pr -> (Float32.toFloat64(fst(pr)), snd(pr)));
                let covered = pairs |> Vector.count(pr -> fst(pr) < 1.0 or snd(pr) < 1.0);
                let split = pairs |> Vector.count(pr -> (fst(pr) < 1.0) != (snd(pr) < 1.0));
                let worst = pairs |> Vector.filter(pr -> fst(pr) < 1.0 and snd(pr) < 1.0)
                    |> Vector.foldLeft((acc, pr) -> Float64.max(acc, Float64.abs(fst(pr) - snd(pr))), 0.0);
                let ok = worst <= limitDepth() and split <= limitCoverage() and covered >= coveredAtLeast();
                let verdict = if (ok) "一致" else "違う";
                println("[parity] orthoBox       E  ${verdict} (深度の最大の差 ${worst}・上限 ${limitDepth()}・片方だけ塗る画素 ${split}/${covered}・上限 ${limitCoverage()})");
                ok
        }
}
