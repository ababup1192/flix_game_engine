// Render3d.JointTexture — 3D の描き手（Render3d）の、1 回の prepare の姿勢を 1 枚の RGBA32F のテクスチャへ詰めて上げる所。
// 1 行 = 1 姿勢・1 ジョイント = 横に 4 texel（mat4 の列の順）。頂点シェーダーは texelFetch 4 本で mat4 に組む（Render3dGlsl.skinDeclarations）。テクスチャの回し方は Render3d.DataTexture。約束は Render3d.flix の頭。
// WhyNot: UBO に置かない — 最低保証の 16 KB に重複の無い姿勢が入り切らず、1 体ごとに書き直すことになる。SSBO は GL 3.3 と WebGL2 に無い。
mod Render3d.JointTexture {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import java.nio.FloatBuffer
    import java.util.Objects
    use Render3d.{MeshDraw, State, jointTextureUnit, warnSceneOnce}
    use Render3d.Batch.{PlannedBatch}
    use Render3d.DataTexture.{bufferFor, heightFor, takeTexture}
    use Render3d.Counts.{Counter, count}

    /// 1 回の prepare の姿勢の行の割り当て。buckets = 姿勢の鍵 → その鍵の (姿勢, 行)・poses = 割り当てた姿勢（新しい物が頭）・
    /// used = 割り当てた行の数・limit = 行の数の上限・dropped = 上限を超えて行をもらえなかった姿勢の数・
    /// joints = 1 行に要るジョイントの数（行をもらえなかった姿勢の分も含む。1 以上・Skin3d.maxJoints() まで）。
    pub type alias PoseRows = {
        buckets = Map[Int64, List[(Pose3d.Pose3d, Int32)]], poses = List[Pose3d.Pose3d], used = Int32, limit = Int32, dropped = Int32, joints = Int32
    }

    /// 1 つの joint 行列の幅（texel）。
    def texelsPerJoint(): Int32 = 4

    // ── 行の割り当て ──

    /// 空の割り当て（行の数の上限 limit）。
    pub def noRows(limit: Int32): PoseRows =
        { buckets = Map.empty(), poses = Nil, used = 0, limit = limit, dropped = 0, joints = 1 }

    /// pose の行と、それを覚えた割り当てを返す。同じ姿勢には同じ行・新しい姿勢には次の行。上限を超えた姿勢は最後の行を読む。
    /// 同じ姿勢かは、鍵で束ねてから、同じ 1 つの値か → 中身が同じか の順で見る。
    pub def assignRow(pose: Pose3d.Pose3d, rows: PoseRows): (Int32, PoseRows) =
        let key = Pose3d.keyOf(pose);
        let bucket = Map.getWithDefault(key, Nil, rows#buckets);
        match List.find(pr -> isSamePose(pose, fst(pr)), bucket) {
            case Some(found) => (snd(found), rows)
            case None if rows#used >= rows#limit => (rows#limit - 1, { dropped = rows#dropped + 1, joints = jointsWith(pose, rows) | rows })
            case None =>
                let row = rows#used;
                (row, { buckets = Map.insert(key, (pose, row) :: bucket, rows#buckets), poses = pose :: rows#poses, used = row + 1, joints = jointsWith(pose, rows) | rows })
        }

    def jointsWith(pose: Pose3d.Pose3d, rows: PoseRows): Int32 =
        Int32.max(rows#joints, Int32.min(Pose3d.jointCount(pose), Skin3d.maxJoints()))

    /// d が描かれる骨つきの物なら、rows に姿勢の行を割り当てた d を返す。
    // WhyNot: 間引いた物に行を配らない — 今の骨つきの物は間引かれないが、形の境界で間引くようになると、画面の外の姿勢の数だけ上げる量が増える。影に映る物は影の道が自分で行をもらう。
    pub def withPoseRow(rows: Ref[PoseRows, Static], d: MeshDraw): MeshDraw \ IO =
        match d#pose {
            case Some(pose) if not d#culled =>
                let (row, next) = assignRow(pose, Ref.get(rows));
                Ref.put(next, rows);
                { poseRow = row | d }
            case _ => d
        }

    /// batch の描く物に姿勢の行を割り当てる。骨の無い batch は何もしない。
    pub def withBatchPoseRows(rows: Ref[PoseRows, Static], b: PlannedBatch): PlannedBatch \ IO =
        if (Option.isEmpty(b#head#pose)) b else { draws = List.map(withPoseRow(rows), b#draws) | b }

    /// a と b が同じ姿勢か。同じ 1 つの値なら中身を比べない。
    // WhyNot: 鍵だけで決めない — 違う並びが同じ鍵になりうる。
    def isSamePose(a: Pose3d.Pose3d, b: Pose3d.Pose3d): Bool =
        isSameValue(a, b) or hasSameMatrices(Pose3d.jointMatrices(a), Pose3d.jointMatrices(b))

    def hasSameMatrices(a: Vector[Mat4.Mat4], b: Vector[Mat4.Mat4]): Bool =
        Vector.length(a) == Vector.length(b) and matricesAgreeFrom(0, a, b)

    def matricesAgreeFrom(i: Int32, a: Vector[Mat4.Mat4], b: Vector[Mat4.Mat4]): Bool =
        i >= Vector.length(a) or (Mat4.toColumns(Vector.get(i, a)) == Mat4.toColumns(Vector.get(i, b)) and matricesAgreeFrom(i + 1, a, b))

    /// a と b が同じ 1 つの値か（中身が同じ別の値は偽）。
    // WhyNot: Eq で比べない — 姿勢の行列を全部比べることになり、飛ばしたい手間そのものになる。
    pub def isSameValue(a: x, b: x): Bool = match (Reflect.reflectValue(a), Reflect.reflectValue(b)) {
        case (Reflect.JvmValue.JvmObject(p), Reflect.JvmValue.JvmObject(q)) => unchecked_cast(Objects.equals(p, q) as _ \ {})
        case _                                                              => false
    }

    // ── 詰める ──

    /// poses を row の順に、1 行 joints 本ずつ out の頭から詰める（列優先 16 個 = Mat4.toColumns の並び）。読む範囲が out の position から limit になる。
    // WhyNot: 行の残りを 0 で埋めない — 頂点が引く番号は Scene3d.skinningOf がジョイントの数未満と確かめてあり、残りを読むのは行をもらえなかった姿勢だけで、その形は知らせた上で崩れる。
    pub def packRows(joints: Int32, poses: List[Pose3d.Pose3d], out: FloatBuffer): Unit \ IO =
        let floatsPerRow = joints * 16;
        discard out.clear();
        poses |> List.forEachWithIndex((row, pose) -> {
            discard out.position(row * floatsPerRow);
            Pose3d.jointMatrices(pose) |> Vector.take(joints) |> Vector.forEach(m ->
                Mat4.toColumns(m) |> Vector.forEach(v -> discard out.put(RenderUtil.f32(v))))
        });
        discard out.position(List.length(poses) * floatsPerRow);
        discard out.flip()

    // ── 上げる ──

    /// 今の prepare の姿勢をテクスチャへ 1 回で上げて joint の unit に貼り、テクスチャの番号を返す。姿勢が無ければテクスチャを作らず None。
    pub def upload(gl: GlContext, state: State, gen: Int64, rows: PoseRows): Option[Int32] \ IO =
        if (rows#dropped > 0)
            warnSceneOnce(state, "@joint-rows", Log.fellBackLine("scene3d", "1 回の prepare の違う姿勢", "最後の行の姿勢", "${rows#limit} 行を超えた（${rows#dropped} 個）"))
        else ();
        if (rows#used == 0) None
        else {
            let poses = List.reverse(rows#poses);
            let buffer = bufferFor(gl, state#joints, rows#joints * 16 * rows#used);
            packRows(rows#joints, poses, buffer);
            gl.activeTexture(GlConst.TEXTURE0 + jointTextureUnit());
            let texture = takeTexture(gl, state#joints, gen, heightFor(rows#limit, rows#used));
            gl.texSubImageRgba32f(0, 0, rows#joints * texelsPerJoint(), rows#used, buffer);
            gl.activeTexture(GlConst.TEXTURE0);
            count(state, Counter.JointUploads, 1);
            Some(texture#texId)
        }
}
