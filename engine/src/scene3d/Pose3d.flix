// Pose3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 描く時のジョイントの行列（閉じた型 — compute で作った物だけ）。
/// joint 行列 = rootTransform × ジョイントの world 行列 × 逆バインド行列。頂点には Σ 重み × joint 行列 を掛けてから、インスタンスの world 行列を掛ける。
pub mod Pose3d {
    import java.lang.Double

    type alias PoseRec = { skin = Skin3d.Skin3d, transforms = Vector[Mat4.Mat4], matrices = Vector[Mat4.Mat4], key = Lazy[Int64] }

    enum PoseData { case PoseData(PoseRec) }

    pub type alias Pose3d = PoseData

    def recOf(p: Pose3d): PoseRec = let PoseData.PoseData(r) = p; r

    /// 局所の姿勢（AnimationClip3d.sample か blend の結果）を親から順に重ねる。
    /// local がジョイントの数より短ければ、足りないジョイントはレストポーズ。長い分は捨てる。
    // WhyNot: 数の食い違いを Err にしない — 毎コマの描画で使うので、ゲームに Result を捌かせないため。
    pub def compute(skin: Skin3d.Skin3d, local: Vector[Skin3d.JointPose]): Pose3d =
        let rest = Skin3d.restPose(skin);
        let filled = Vector.mapWithIndex((i, r) -> Vector.nth(i, local) |> Option.getWithDefault(r), rest);
        let root = Skin3d.rootTransform(skin);
        let transforms = Skin3d.jointWorlds(Skin3d.parents(skin), filled) |> Vector.map(w -> Mat4.mul(root, w));
        let matrices = Vector.mapWithIndex((i, tr) -> Mat4.mul(tr, Vector.get(i, Skin3d.inverseBinds(skin))), transforms);
        PoseData.PoseData({ skin = skin, transforms = transforms, matrices = matrices, key = lazy keyOfMatrices(matrices) })

    pub def jointCount(p: Pose3d): Int32 = Vector.length(recOf(p)#matrices)

    /// 2 つの局所の姿勢を混ぜる（t = 0 で a・1 で b）。平行移動と倍率は 2 つの値の間をなめらかにつなぎ、回転は球面の上で。
    /// 数が違えば短い方に合わせる。
    pub def blend(a: Vector[Skin3d.JointPose], b: Vector[Skin3d.JointPose], t: Float64): Vector[Skin3d.JointPose] =
        Vector.zip(a, b) |> Vector.map(pair -> {
            let (pa, pb) = pair;
            { translation = Vec3.add(pa#translation, Vec3.mul(Vec3.sub(pb#translation, pa#translation), t)),
              rotation = Quat.slerp(pa#rotation, pb#rotation, t),
              scale = Vec3.add(pa#scale, Vec3.mul(Vec3.sub(pb#scale, pa#scale), t)) }
        })

    /// 姿勢の鍵: joint 行列の並びの全部の数のビットから作る 64 bit（初めて読んだ時に求める）。同じ並びは必ず同じ鍵になり、
    /// 1 つの数だけが違う 2 つは必ず違う鍵になる。違う並びが同じ鍵になることはありうるので、同じ中身かは鍵で決めない
    /// （GL の描き手が同じ姿勢の物を隣に並べるのに使う）。
    pub def keyOf(p: Pose3d): Int64 = force recOf(p)#key

    // WhyNot: 鍵の後で混ぜ直さない（ずらして散らす手を入れない）— 並べる時の束ね方にだけ使い、表の引きの偏りは気にしない。
    //   1 語ずつ xor してから奇数を掛ける形は 1 歩ごとに元へ戻せるので、1 つの数だけが違えば鍵も必ず違う。
    def keyOfMatrices(matrices: Vector[Mat4.Mat4]): Int64 =
        matrices |> Vector.foldLeft((acc, m) ->
            Mat4.toColumns(m) |> Vector.foldLeft((a, v) -> Int64.bitwiseXor(a, Double.doubleToLongBits(v)) * 1099511628211i64, acc),
            -3750763034362895579i64)

    /// ジョイントの番号の順の joint 行列（GL の UBO・CPU のスキニングが読む）。
    pub def jointMatrices(p: Pose3d): Vector[Mat4.Mat4] = recOf(p)#matrices

    /// ジョイントの変換（rootTransform × world。形の座標で、インスタンスの world 行列はまだ掛かっていない）。
    /// 手に物を持たせる時はインスタンスの world 行列 × これ。番号が範囲の外なら単位行列。
    pub def jointTransform(p: Pose3d, joint: Int32): Mat4.Mat4 =
        Vector.nth(joint, recOf(p)#transforms) |> Option.getWithDefault(Mat4.identity())
}
