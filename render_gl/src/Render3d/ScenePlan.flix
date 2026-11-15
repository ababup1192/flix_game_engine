// Render3d.ScenePlan — 3D の描き手（Render3d）の、prepare の中で場面を描く物へ分ける所（計画の側。GL を呼ばない）。半透明を除く描く順と姿勢の行はここで決まる。約束は Render3d.flix の頭。
// backend に聞く物は 3 つだけ: 描き先の能力（PlanCaps）・材質ごとの順の番号と使えるか（Render3d.Material.resolveMaterials の orders）。
// 1 回の prepare は groupScenes（候補に分けて聞く材質を並べる）→ backend が材質を引く → planScenes（batch に分けて並べる）の順に通る。
mod Render3d.ScenePlan {
    use Render3d.{DrawMode, ShadowPlan, inDrawOrder, isSkinned}
    use Render3d.Batch.{MaterialBatch, PlannedBatch}
    use Render3d.JointTexture.{PoseRows, noRows, withBatchPoseRows}
    use Render3d.Material.{MaterialRequest, PlacedDraw, groupPlaced, requestsOf, splitGroups}
    use Render3d.Shadow.{shadowPlansOf}

    /// 計画の側の状態（GL の物を持たない）。drawMode = 置いた物の描き方・sceneWarnedRef = 場面について知らせ済みの鍵（見つからない絵・上限を超えた材質と光・
    /// 場面の絵の置き場あふれ・空・lightmap・uv の無い法線マップ）・skinWarnedRef = ジョイントの数の食い違いを知らせた形（contentHash）・shadowWarnedRef = 影について知らせ済みの種類。
    pub type alias Planner = {
        drawMode = DrawMode, sceneWarnedRef = Ref[Set[String], Static], skinWarnedRef = Ref[Set[String], Static], shadowWarnedRef = Ref[Set[String], Static]
    }

    pub def freshPlanner(drawMode: DrawMode): Planner \ IO =
        { drawMode = drawMode, sceneWarnedRef = Ref.fresh(Static, Set.empty()), skinWarnedRef = Ref.fresh(Static, Set.empty()),
          shadowWarnedRef = Ref.fresh(Static, Set.empty()) }

    /// 場面についての知らせを鍵ごとに 1 回だけ出す。
    pub def warnOnce(planner: Planner, key: String, message: String): Unit \ IO = warnOnceIn(planner#sceneWarnedRef, key, message)

    /// warned に無い鍵なら控えて message を出す。
    pub def warnOnceIn(warned: Ref[Set[String], Static], key: String, message: String): Unit \ IO =
        if (Set.memberOf(key, Ref.get(warned))) ()
        else {
            Ref.put(Set.insert(key, Ref.get(warned)), warned);
            Log.warn(message)
        }

    /// backend に聞いて決める描き先の能力。alphaToOne = 標本つきの描き先で cutout を alpha to coverage で抜けるか・poseRowLimit = 姿勢の行の数の上限。
    pub type alias PlanCaps = { alphaToOne = Bool, poseRowLimit = Int32 }

    /// 場面 1 つを描く材料を batch に分け終えた物（半透明の物の順だけは draw で決める。ほかは描く順に並べてある）。plain = 材質の無い骨の無い物・skinned = 材質の無い骨つきの物・
    /// opaque = 不透明の材質の物（Output.Depth では材質で描く物）・blended = 半透明の材質の物（1 体ずつの batch。Output.Depth では空）。
    pub type alias SceneDraws[b] = { plain = List[b], skinned = List[b], opaque = List[MaterialBatch[b]], blended = List[MaterialBatch[b]] }

    /// prepare の中で分け終えた場面 1 つ。shadowPlans = 影の地図を描く材料（影を落とす光ごとに 1 つ。無ければ空。スポットの次に太陽）。
    pub type alias ScenePlan[b] = { cmd = Scene3d.RenderCmd, draws = SceneDraws[b], shadowPlans = List[ShadowPlan[b]] }

    /// 置いた物を batch の候補に分け終えた場面 1 つ。firstRequest = この場面の最初の材質を聞いた番号。
    pub type alias GroupedScene = { cmd = Scene3d.RenderCmd, groups = List[List[PlacedDraw]], firstRequest = Int32 }

    /// 1 回の prepare の場面を候補に分け、backend に聞く材質を場面の順・候補の順に並べる。samples = 描き先の標本の数。
    pub def groupScenes(planner: Planner, caps: PlanCaps, samples: Int32, cmds: List[Scene3d.RenderCmd]): (List[GroupedScene], Vector[MaterialRequest]) \ IO =
        let (scenes, asked, _) = cmds |> List.foldLeft((acc, cmd) -> {
            let (done, chunks, next) = acc;
            let groups = groupScene(planner, caps, samples, cmd);
            let requests = requestsOf(groups);
            ({ cmd = cmd, groups = groups, firstRequest = next } :: done, requests :: chunks, next + List.length(requests))
        }, (Nil, Nil, 0));
        (List.reverse(scenes), asked |> List.reverse |> List.flatten |> List.toVector)

    /// 候補に分けた場面を batch に分けて描く順に並べ、描く物の姿勢の行の割り当てと一緒に返す。orders = backend が聞いた材質の順に返した順の番号。
    pub def planScenes(planner: Planner, caps: PlanCaps, orders: Vector[Int32], scenes: List[GroupedScene]): (List[ScenePlan[PlannedBatch]], PoseRows) \ IO =
        let rows = Ref.fresh(Static, noRows(caps#poseRowLimit));
        let plans = scenes |> List.map(planScene(planner, rows, orders));
        (plans, Ref.get(rows))

    def planScene(planner: Planner, rows: Ref[PoseRows, Static], orders: Vector[Int32], s: GroupedScene): ScenePlan[PlannedBatch] \ IO =
        { cmd = s#cmd, draws = withPoseRows(rows, sceneDrawsOf(planner, orders, s)), shadowPlans = shadowPlansOf(planner, rows, s#cmd#scene) }

    /// 場面の置いた物を、Output に合わせて batch の候補に分ける。
    // WhyNot: Design の解像度の描き先に標本を持たせない — ドット絵と画素をそろえる場面に縁のならしは要らない。
    def groupScene(planner: Planner, caps: PlanCaps, samples: Int32, cmd: Scene3d.RenderCmd): List[List[PlacedDraw]] \ IO =
        let scene = cmd#scene;
        let outside = Scene3d.isOutsideFrustum(Scene3d.frustumOf(scene));
        let coverage = match scene#resolution {
            case Scene3d.Resolution.Native => samples > 1 and caps#alphaToOne
            case Scene3d.Resolution.Design => false
        };
        match scene#output {
            case Scene3d.Output.Color => groupPlaced(planner, outside, _ -> true, coverage, scene#instances)
            case Scene3d.Output.Depth(_) =>
                // WhyNot: cutout でも両面でもない材質に材質のプログラムを組まない — 奥行きは形だけで決まり、色の計算は捨てられる
                //   （両面の物は材質の道でカリングを切る。頂点の色の道へ回すと裏の面が捨てられ、CPU の奥行きと食い違う）。
                // WhyNot: 半透明の物を描かない — 奥行きを書くと、ピントの Pass がガラスの手前に合う。
                let solidInstances = List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)), scene#instances);
                groupPlaced(planner, outside, m -> m#cutout or m#doubleSided, false, solidInstances)
        }

    /// 描く骨つきの物に姿勢の行を割り当てる。
    def withPoseRows(rows: Ref[PoseRows, Static], draws: SceneDraws[PlannedBatch]): SceneDraws[PlannedBatch] \ IO =
        let materialRow = (d: MaterialBatch[PlannedBatch]) -> { batch = withBatchPoseRows(rows, d#batch) | d };
        { skinned = List.map(withBatchPoseRows(rows), draws#skinned), opaque = List.map(materialRow, draws#opaque), blended = List.map(materialRow, draws#blended) | draws }

    /// 候補を batch に分けて描く順に並べる。
    // WhyNot: 不透明の物を来た順のまま描かない — 深度で前後が決まるので順は同じ深さの面の勝ち方しか変えず、batch にするとプログラムの切り替えも draw も減る。
    def sceneDrawsOf(planner: Planner, orders: Vector[Int32], s: GroupedScene): SceneDraws[PlannedBatch] =
        let (vertexColored, materials) = splitGroups(s#groups, s#firstRequest, orders);
        let (skinned, plain) = List.partition(isSkinnedBatch, vertexColored);
        match s#cmd#scene#output {
            case Scene3d.Output.Color =>
                let (blended, solid) = List.partition(d -> d#material#blend, materials);
                { plain = plain, skinned = skinned, opaque = materialsInOrder(planner, solid), blended = blended }
            case Scene3d.Output.Depth(_) =>
                { plain = plain, skinned = skinned, opaque = materialsInOrder(planner, materials), blended = Nil }
        }

    def isSkinnedBatch(b: PlannedBatch): Bool = isSkinned(b#head)

    /// 材質の batch の描く順。backend の順の番号で並べる。DrawMode.OneByOne は来た順のまま（並べ替えの影響も on と off の差に出す）。
    def materialsInOrder(planner: Planner, batches: List[MaterialBatch[PlannedBatch]]): List[MaterialBatch[PlannedBatch]] =
        match planner#drawMode {
            case DrawMode.Instanced => inDrawOrder(d -> d#order, batches)
            case DrawMode.OneByOne  => batches
        }
}
