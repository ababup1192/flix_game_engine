// Transform3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 置き場所（開いたレコード — ゲームが書く値）。
pub mod Transform3d {

    /// at = 形の原点を置く world の点・yaw / pitch / roll = 回す角（ラジアン）・pivot = 回す中心（形の座標）・scale = 軸ごとの倍率。
    /// 回す順は roll（Z）→ pitch（X）→ yaw（Y）。pivot の点は回しても倍率を変えても at + pivot に留まる。
    pub type alias Transform3d = { at = Vec3.Vec3, yaw = Float64, pitch = Float64, roll = Float64, pivot = Vec3.Vec3, scale = Vec3.Vec3 }

    /// 回さず・等倍で at に置く。
    pub def of(at: Vec3.Vec3): Transform3d =
        { at = at, yaw = 0.0, pitch = 0.0, roll = 0.0, pivot = Vec3.zero(), scale = Vec3.one() }

    /// 形の座標 → world の行列。
    pub def toMat4(t: Transform3d): Mat4.Mat4 =
        (Mat4.translate(Vec3.add(t#at, t#pivot)) :: Mat4.rotateY(t#yaw) :: Mat4.rotateX(t#pitch) :: Mat4.rotateZ(t#roll) ::
         Mat4.scale(t#scale) :: Mat4.translate(Vec3.mul(t#pivot, -1.0)) :: Nil)
            |> List.foldLeft(Mat4.mul, Mat4.identity())

    /// 親の行列の下に子を置いた行列（親 × 子）。鎖 → 枠 → 蝋燭のように何段でも重ねられる。
    pub def toWorld(parent: Mat4.Mat4, child: Transform3d): Mat4.Mat4 =
        Mat4.mul(parent, toMat4(child))
}
