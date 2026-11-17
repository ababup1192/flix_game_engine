// Camera3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 透視カメラ（開いたレコード）。
pub mod Camera3d {

    /// eye = 目の位置・yaw / pitch = 向き（ラジアン。座標の約束はファイルの頭）・fovY = 縦の画角（ラジアン）・near / far = 写す奥行きの範囲。
    /// lensShift = 写す範囲を画面の上下左右へずらす量（Unity の Physical Camera の Lens Shift・Blender の Shift X/Y と同じ物）。
    /// 単位は画面の幅（x）と高さ（y）に対する比で、y = −0.5 なら画面の高さの半分だけ下を写す。向き（pitch）は変えないので、
    /// 水平のカメラ（pitch 0）で y を負にすると、縦の線は平行のまま地面だけが奥へすぼまる（HD-2D の見下ろし）。既定は `Vec2.zero()`。
    pub type alias Camera3d = { eye = Vec3.Vec3, yaw = Float64, pitch = Float64, fovY = Float64, near = Float64, far = Float64,
                                lensShift = Vec2.Vec2 }

    /// 目の位置 eye から yaw・pitch の向きを見るカメラ（near 0.1・far 100・lensShift 0）。
    /// ほかの値は `{ far = 60.0, lensShift = Vec2.v2(0.0, -0.8) | Camera3d.camera(eye, yaw, pitch, fovY) }` の形で替える
    /// （欄を全部字で書くと、Camera3d に欄が増えた時に書いた所が全部コンパイルできなくなる）。
    pub def camera(eye: Vec3.Vec3, yaw: Float64, pitch: Float64, fovY: Float64): Camera3d =
        { eye = eye, yaw = yaw, pitch = pitch, fovY = fovY, near = 0.1, far = 100.0, lensShift = Vec2.zero() }

    /// レンズシフトが 0 か（0 の時は 0 の式を通らず、前と同じ値の行列を返すために使う）。
    pub def hasLensShift(c: Camera3d): Bool = c#lensShift#x != 0.0 or c#lensShift#y != 0.0

    /// 画面の真ん中の画素を通る向き（長さ 1）。レンズシフトが 0 なら forward と同じ。
    pub def centerRayDirection(c: Camera3d, aspect: Float64): Vec3.Vec3 =
        if (not hasLensShift(c)) forward(c)
        else {
            let half = c#fovY / 2.0;
            let tanHalf = Num.sin(half) / Num.cos(half);
            Vec3.normalized(Vec3.add(forward(c), Vec3.add(Vec3.mul(right(c), 2.0 * c#lensShift#x * tanHalf * aspect),
                                                          Vec3.mul(up(c), 2.0 * c#lensShift#y * tanHalf))))
        }

    /// 見ている向き（長さ 1）。
    pub def forward(c: Camera3d): Vec3.Vec3 =
        Vec3.v3(Num.sin(c#yaw) * Num.cos(c#pitch), 0.0 - Num.sin(c#pitch), Num.cos(c#yaw) * Num.cos(c#pitch))

    /// 画面の右の向き（長さ 1）。
    pub def right(c: Camera3d): Vec3.Vec3 =
        Vec3.v3(Num.cos(c#yaw), 0.0, 0.0 - Num.sin(c#yaw))

    /// 画面の上の向き（長さ 1）。
    pub def up(c: Camera3d): Vec3.Vec3 =
        Vec3.v3(Num.sin(c#yaw) * Num.sin(c#pitch), Num.cos(c#pitch), Num.cos(c#yaw) * Num.sin(c#pitch))

    /// world → GL の目の座標（右手系・−Z を見る）。左手系の前の向きを −Z へ写すので Z が反転する。
    pub def viewMatrix(c: Camera3d): Mat4.Mat4 =
        Mat4.mul(Mat4.ofLinearRows(right(c), up(c), Vec3.mul(forward(c), -1.0)),
                 Mat4.translate(Vec3.mul(c#eye, -1.0)))

    /// GL の透視の行列（右手系の目の座標 → clip。奥行きは near で −1・far で +1）。aspect = 幅 / 高さ。
    pub def projectionMatrix(c: Camera3d, aspect: Float64): Mat4.Mat4 =
        let half = c#fovY / 2.0;
        let focal = Num.cos(half) / Num.sin(half);
        let base = Mat4.perspective({ xScale = focal / aspect, yScale = focal, near = c#near, far = c#far });
        // WhyNot: 0 の時も translate を掛けると -0.0 が混じり、描き出しのバイトが前と変わりうるので掛けない。
        if (not hasLensShift(c)) base
        else Mat4.mul(Mat4.translate(Vec3.v3(-2.0 * c#lensShift#x, -2.0 * c#lensShift#y, 0.0)), base)

    /// このカメラに写る範囲（視錐台）。aspect = 幅 / 高さ。光や羽虫をゲームの側で間引く・数える時に使う
    /// （置いた物とビルボードは描き手が同じ判定で間引くので、ゲームが間引かなくてよい）。
    pub def frustum(c: Camera3d, aspect: Float64): Frustum.Frustum =
        Frustum.ofClipMatrix(Mat4.mul(projectionMatrix(c, aspect), viewMatrix(c)))

    /// 目から見ている向き（forward）へ伸びるレイ（レンズシフトが 0 なら画面の真ん中・クロスヘアの先。シフトのあるカメラの画面の真ん中は centerRayDirection）。`Ray3d.pickNearest` で見ている物を引く。
    pub def forwardRay(c: Camera3d): Ray3d.Ray3d = Ray3d.ray3d(c#eye, forward(c))

    /// 描き物の中の点 p（左上が 0・y は下へ増える px。size = 描き物の大きさ）を通って目から伸びるレイ（worldToScreen の逆）。
    /// 始まりは目（near の面ではない）。size の幅か高さが 0 以下の時は forwardRay。
    pub def screenPointToRay(c: Camera3d, size: Vec2.Vec2, p: Vec2.Vec2): Ray3d.Ray3d =
        if (not (size#x > 0.0 and size#y > 0.0)) forwardRay(c)
        else {
            let half = c#fovY / 2.0;
            let tanHalf = Num.sin(half) / Num.cos(half);
            let ndcX = p#x / size#x * 2.0 - 1.0 + 2.0 * c#lensShift#x;
            let ndcY = 1.0 - p#y / size#y * 2.0 + 2.0 * c#lensShift#y;
            let toward = Vec3.add(forward(c), Vec3.add(Vec3.mul(right(c), ndcX * tanHalf * size#x / size#y), Vec3.mul(up(c), ndcY * tanHalf)));
            Ray3d.ray3d(c#eye, toward)
        }

    /// 3D の点が描き物の中のどこに写るか（左上が 0・y は下へ増える px）。near より手前と目の後ろは None。
    pub def worldToScreen(c: Camera3d, size: Vec2.Vec2, p: Vec3.Vec3): Option[Vec2.Vec2] =
        let depth = Vec3.dot(Vec3.sub(p, c#eye), forward(c));
        if (depth < c#near or size#y <= 0.0) None
        else {
            let clip = Mat4.mul(projectionMatrix(c, size#x / size#y), viewMatrix(c));
            Mat4.applyPerspective(clip, p)
                |> Option.map(ndc -> { x = (ndc#x + 1.0) / 2.0 * size#x, y = (1.0 - ndc#y) / 2.0 * size#y })
        }
}
