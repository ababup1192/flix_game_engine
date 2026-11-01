// Skin3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// ジョイントの木（閉じた型 — make が確かめた物だけ）。並びは親が子より先。
pub mod Skin3d {

    /// ジョイント 1 本の局所の姿勢（親のジョイントの座標で。根は rootTransform の座標で）。
    pub type alias JointPose = { translation = Vec3.Vec3, rotation = Quat.Quat, scale = Vec3.Vec3 }

    type alias SkinRec = { names = Vector[String], parents = Vector[Int32], rest = Vector[JointPose],
                           inverseBinds = Vector[Mat4.Mat4], rootTransform = Mat4.Mat4, indexByName = Map[String, Int32] }

    enum SkinData { case SkinData(SkinRec) }

    pub type alias Skin3d = SkinData

    def recOf(s: Skin3d): SkinRec = let SkinData.SkinData(r) = s; r

    /// 1 体のジョイントの上限。GL のジョイントの行列の UBO（64 × mat4）と CPU が同じ値を使う。
    pub def maxJoints(): Int32 = 64

    /// names・parents（-1 が根。親の番号は自分より小さい）・レストポーズ・逆バインド行列から作る。
    /// inverseBinds が None ならレストポーズから計算する（レストポーズの joint 行列が単位行列になる物）。
    /// rootTransform = 根のジョイントより上の、ジョイントでないノードの world 行列。
    /// 数の食い違い・上限を超えた数・自分より後ろの親・逆行列の無いレストポーズは Err。回転は長さ 1 に直す。
    pub def make(spec: { names = Vector[String], parents = Vector[Int32], rest = Vector[JointPose],
                         inverseBinds = Option[Vector[Mat4.Mat4]], rootTransform = Mat4.Mat4 }): Result[String, Skin3d] =
        let count = Vector.length(spec#names);
        let rest = Vector.map(p -> { rotation = Quat.normalized(p#rotation) | p }, spec#rest);
        let badParent = Vector.range(0, count)
            |> Vector.exists(i -> { let p = Vector.get(i, spec#parents); p < -1 or p >= i });
        if (count == 0) Err("Skin3d: ジョイントが 1 本も無い")
        else if (count > maxJoints()) Err("Skin3d: ジョイントが ${count} 本（上限 ${maxJoints()} 本）")
        else if (Vector.length(spec#parents) != count or Vector.length(rest) != count)
            Err("Skin3d: names・parents・rest の数が食い違う")
        else if (badParent) Err("Skin3d: 親の番号が -1 か自分より小さい数でない（親が子より先の並びにする）")
        else {
            let bindsR = match spec#inverseBinds {
                case Some(binds) =>
                    if (Vector.length(binds) != count) Err("Skin3d: inverseBinds の数が ${Vector.length(binds)}（ジョイントは ${count} 本）")
                    else Ok(binds)
                case None => restInverseBinds(spec#rootTransform, spec#parents, rest)
            };
            Result.map(binds -> SkinData.SkinData({
                names = spec#names, parents = spec#parents, rest = rest, inverseBinds = binds,
                rootTransform = spec#rootTransform,
                indexByName = Vector.range(0, count) |> Vector.foldRight((i, m) -> Map.insert(Vector.get(i, spec#names), i, m), Map.empty())
            }), bindsR)
        }

    def restInverseBinds(root: Mat4.Mat4, parents: Vector[Int32], rest: Vector[JointPose]): Result[String, Vector[Mat4.Mat4]] =
        let worlds = jointWorlds(parents, rest);
        Vector.range(0, Vector.length(rest))
            |> Vector.toList
            |> List.map(i -> Mat4.inverse(Mat4.mul(root, Vector.get(i, worlds)))
                             |> Option.toOk("Skin3d: ジョイント ${i} のレストポーズの行列に逆行列が無い（倍率 0 など）"))
            |> List.sequence
            |> Result.map(List.toVector)

    /// ジョイントごとの「根からの行列」（rootTransform は掛けない）。parents は親が子より先の並び。
    /// local の数が parents より少なければ、足りない所は単位の姿勢として重ねる。
    pub def jointWorlds(parents: Vector[Int32], local: Vector[JointPose]): Vector[Mat4.Mat4] =
        let count = Vector.length(parents);
        let (_, revWorlds) = Vector.range(0, count) |> Vector.foldLeft((acc, i) -> {
            let (byIndex, out) = acc;
            let localMat = Vector.nth(i, local) |> Option.map(jointPoseToMat4) |> Option.getWithDefault(Mat4.identity());
            let parent = Vector.get(i, parents);
            let world = if (parent < 0) localMat
                        else Mat4.mul(Map.get(parent, byIndex) |> Option.getWithDefault(Mat4.identity()), localMat);
            (Map.insert(i, world, byIndex), world :: out)
        }, (Map.empty(), Nil));
        List.toVector(List.reverse(revWorlds))

    /// 局所の姿勢の行列（平行移動 × 回転 × 倍率）。
    pub def jointPoseToMat4(p: JointPose): Mat4.Mat4 =
        Mat4.mul(Mat4.translate(p#translation), Mat4.mul(Quat.toMat4(p#rotation), Mat4.scale(p#scale)))

    pub def jointCount(s: Skin3d): Int32 = Vector.length(recOf(s)#names)

    /// 名前からジョイントの番号（同じ名前が 2 つあれば前の物）。
    pub def jointIndex(s: Skin3d, name: String): Option[Int32] = Map.get(name, recOf(s)#indexByName)

    /// ジョイントの名前（番号の順）。
    pub def names(s: Skin3d): Vector[String] = recOf(s)#names

    /// 親の番号（根は -1）。
    pub def parents(s: Skin3d): Vector[Int32] = recOf(s)#parents

    pub def restPose(s: Skin3d): Vector[JointPose] = recOf(s)#rest

    /// 逆バインド行列（番号の順）。
    pub def inverseBinds(s: Skin3d): Vector[Mat4.Mat4] = recOf(s)#inverseBinds

    pub def rootTransform(s: Skin3d): Mat4.Mat4 = recOf(s)#rootTransform
}
