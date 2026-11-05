// Render3d.ScenePlan — 3D の描き手（Render3d）の、prepare の中で場面を描く物へ分ける所。半透明を除く描く順と姿勢の行はここで決まる。約束は Render3d.flix の頭。
mod Render3d.ScenePlan {
    import fge.gl.GlContext
    use Render3d.{MaterialDraw, MeshDraw, ShadowPlan, ShadowUse, State, inDrawOrder, isSkinned, poseKeyOf}
    use Render3d.JointTexture.{PoseRows, noRows, rowLimit, withPoseRow}
    use Render3d.Material.{splitByMaterial}
    use Render3d.Shadow.{shadowPlanOf}

    /// 場面 1 つを描く材料を分け終えた物（半透明の物の順だけは draw で決める。ほかは描く順に並べてある）。plain = 材質の無い骨の無い物・skinned = 材質の無い骨つきの物・
    /// opaque = 不透明の材質の物（Output.Depth では材質で描く物）・blended = 半透明の材質の物（Output.Depth では空）。
    pub type alias SceneDraws = { plain = List[MeshDraw], skinned = List[MeshDraw], opaque = List[MaterialDraw], blended = List[MaterialDraw] }

    /// prepare の中で分け終えた場面 1 つ。shadowPlan = 影の地図を描く材料（影を落とす光が無ければ None）。
    pub type alias ScenePlan = { cmd = Scene3d.RenderCmd, draws = SceneDraws, shadowPlan = Option[ShadowPlan] }

    /// 場面を描く時に場面の外から渡す物。shadow = 先に描いておいた影の地図（無ければ None）・jointTexture = その prepare の joint texture（姿勢が無ければ None）。
    pub type alias SceneInputs = { draws = SceneDraws, shadow = Option[ShadowUse], jointTexture = Option[Int32] }

    /// 場面をどう 2D の並びへ出すか。Native = その場で描く・Design = 先に描いておいた描き先を貼る（大きさの無い場面は None で、何も出さない）。
    pub enum SceneTarget {
        case Native(SceneInputs)
        case Design(Option[RenderTargetGl.Entry])
    }

    /// 2D の並びへ渡す場面 1 つ。
    pub type alias SceneItem = { cmd = Scene3d.RenderCmd, target = SceneTarget }

    /// 1 回の prepare の場面を全部分け、描く物の姿勢の行の割り当てと一緒に返す。
    pub def planScenes(gl: GlContext, state: State, gen: Int64, dest: Scene3dRenderer.Dest, cmds: List[Scene3d.RenderCmd]): (List[ScenePlan], PoseRows) \ IO =
        let rows = Ref.fresh(Static, noRows(rowLimit(gl, state)));
        let plans = cmds |> List.map(planScene(gl, state, gen, rows, dest));
        (plans, Ref.get(rows))

    /// 場面 1 つの置いた物を、描く材料に分ける。
    // WhyNot: Design の解像度の描き先に標本を持たせない — ドット絵と画素をそろえる場面に縁のならしは要らない。
    def planScene(gl: GlContext, state: State, gen: Int64, rows: Ref[PoseRows, Static], dest: Scene3dRenderer.Dest, cmd: Scene3d.RenderCmd): ScenePlan \ IO =
        let coverage = match cmd#scene#resolution {
            case Scene3d.Resolution.Native => dest#samples > 1 and gl.hasAlphaToOne()
            case Scene3d.Resolution.Design => false
        };
        { cmd = cmd, draws = withPoseRows(rows, sceneDrawsOf(gl, state, gen, coverage, cmd#scene)), shadowPlan = shadowPlanOf(state, rows, cmd#scene) }

    /// 描く骨つきの物に姿勢の行を割り当てる。
    def withPoseRows(rows: Ref[PoseRows, Static], draws: SceneDraws): SceneDraws \ IO =
        let materialRow = (d: MaterialDraw) -> { draw = withPoseRow(rows, d#draw) | d };
        { skinned = List.map(withPoseRow(rows), draws#skinned), opaque = List.map(materialRow, draws#opaque), blended = List.map(materialRow, draws#blended) | draws }

    /// 場面の置いた物を、Output に合わせて描く物へ分けて描く順に並べる。
    // WhyNot: 不透明の物を来た順のまま描かない — 深度で前後が決まるので順は同じ深さの面の勝ち方しか変えず、プログラムで並べると切り替えが減る。
    // WhyNot: 並べる鍵から姿勢の鍵を外さない — 行を指すだけなので速さの得は無いが、外すと同じ深さの面の勝ち方が変わる。
    def sceneDrawsOf(gl: GlContext, state: State, gen: Int64, coverage: Bool, scene: Scene3d.Scene3dCmd): SceneDraws \ IO =
        let outside = Scene3d.isOutsideFrustum(Scene3d.frustumOf(scene));
        match scene#output {
            case Scene3d.Output.Color =>
                let (vertexColored, materials) = splitByMaterial(gl, state, gen, outside, _ -> true, coverage, scene#instances);
                let (skinned, plain) = List.partition(isSkinned, vertexColored);
                let (blended, solid) = List.partition(d -> d#material#blend, materials);
                { plain = plain, skinned = inDrawOrder(d -> (0, poseKeyOf(d)), skinned), opaque = inDrawOrder(materialOrderOf, solid), blended = blended }
            case Scene3d.Output.Depth(_) =>
                // WhyNot: cutout でも両面でもない材質に材質のプログラムを組まない — 奥行きは形だけで決まり、色の計算は捨てられる
                //   （両面の物は材質の道でカリングを切る。頂点の色の道へ回すと裏の面が捨てられ、CPU の奥行きと食い違う）。
                // WhyNot: 半透明の物を描かない — 奥行きを書くと、ピントの Pass がガラスの手前に合う。
                let solidInstances = List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)), scene#instances);
                let (vertexColored, cutouts) = splitByMaterial(gl, state, gen, outside, m -> m#cutout or m#doubleSided, false, solidInstances);
                let (skinned, plain) = List.partition(isSkinned, vertexColored);
                { plain = plain, skinned = skinned, opaque = inDrawOrder(materialOrderOf, cutouts), blended = Nil }
        }

    /// 材質のある物の描く順の鍵: プログラムの番号・姿勢の鍵。
    def materialOrderOf(d: MaterialDraw): (Int32, Int64) = (d#entry#locs#mesh#program, poseKeyOf(d#draw))
}
