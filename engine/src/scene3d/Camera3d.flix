// Camera3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 透視カメラ（開いたレコード）。
pub mod Camera3d {

    /// eye = 目の位置・yaw / pitch = 向き（ラジアン。座標の約束はファイルの頭）・fovY = 縦の画角（ラジアン）・near / far = 写す奥行きの範囲。
    pub type alias Camera3d = { eye = Vec3.Vec3, yaw = Float64, pitch = Float64, fovY = Float64, near = Float64, far = Float64 }

    /// 見ている向き（長さ 1）。
    pub def forward(c: Camera3d): Vec3.Vec3 =
        Vec3.v3(Vec2.sin(c#yaw) * Vec2.cos(c#pitch), 0.0 - Vec2.sin(c#pitch), Vec2.cos(c#yaw) * Vec2.cos(c#pitch))

    /// 画面の右の向き（長さ 1）。
    pub def right(c: Camera3d): Vec3.Vec3 =
        Vec3.v3(Vec2.cos(c#yaw), 0.0, 0.0 - Vec2.sin(c#yaw))

    /// 画面の上の向き（長さ 1）。
    pub def up(c: Camera3d): Vec3.Vec3 =
        Vec3.v3(Vec2.sin(c#yaw) * Vec2.sin(c#pitch), Vec2.cos(c#pitch), Vec2.cos(c#yaw) * Vec2.sin(c#pitch))

    /// world → GL の目の座標（右手系・−Z を見る）。左手系の前の向きを −Z へ写すので Z が反転する。
    pub def viewMatrix(c: Camera3d): Mat4.Mat4 =
        Mat4.mul(Mat4.ofLinearRows(right(c), up(c), Vec3.mul(forward(c), -1.0)),
                 Mat4.translate(Vec3.mul(c#eye, -1.0)))

    /// GL の透視の行列（右手系の目の座標 → clip。奥行きは near で −1・far で +1）。aspect = 幅 / 高さ。
    pub def projectionMatrix(c: Camera3d, aspect: Float64): Mat4.Mat4 =
        let half = c#fovY / 2.0;
        let focal = Vec2.cos(half) / Vec2.sin(half);
        Mat4.perspective({ xScale = focal / aspect, yScale = focal, near = c#near, far = c#far })

    /// このカメラに写る範囲（視錐台）。aspect = 幅 / 高さ。光や羽虫をゲームの側で間引く・数える時に使う
    /// （置いた物とビルボードは描き手が同じ判定で間引くので、ゲームが間引かなくてよい）。
    pub def frustum(c: Camera3d, aspect: Float64): Frustum.Frustum =
        Frustum.ofClipMatrix(Mat4.mul(projectionMatrix(c, aspect), viewMatrix(c)))

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
