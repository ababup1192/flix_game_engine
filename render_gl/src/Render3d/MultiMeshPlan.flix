// Render3d.MultiMeshPlan — 場面の multiMeshes（MultiMesh3d）の計画（計画の側。GL を呼ばない）。1 つの MultiMesh は 1 本の draw になり、
// 材質は置いた物と同じく backend に聞く。並びを詰めて場面の pass と影の地図の pass へ足すのは Render3d.InstanceValues.mapBatchesWithMultiMeshes。
// WhyNot: 置いた物の計画（Render3d.ScenePlan.groupWith）へ 1 体ずつ通さない — 1 体ごとの分け方・視錐台・詰めの仕事を消すための口で、体はみな同じ形と材質。
pub mod Render3d.MultiMeshPlan {
    use Render3d.{MeshDraw, ProgramKind, ShaderVariant}
    use Render3d.ScenePlan.{MaterialRequest, Planner, Tables, kindOf, requestOf, verifiedHandle, warnOnce}

    /// 材質を聞いた MultiMesh 1 つ。head = 形を原点に置いた 1 体（行の形と材質の版を決める）・surface = 聞いた材質と版（頂点の色で描くなら None）・handle = 聞いた番号（無ければ -1）。
    pub type alias Grouped = { mesh = MultiMesh3d.MultiMesh3d, head = MeshDraw, surface = Option[MaterialRequest], handle = Int32 }

    /// backend の答えを当てた MultiMesh 1 つ。material = (handle, 順の番号, 版, 材質)（頂点の色で描くなら None。backend が使えないと答えた材質も None）。
    pub type alias Planned = { mesh = MultiMesh3d.MultiMesh3d, head = MeshDraw, material = Option[(Int32, Int32, ProgramKind, Scene3d.MaterialFields)] }

    /// 場面の multiMeshes の材質を聞く（0 体の物は外す）。wants = この pass で材質のプログラムを組む材質か（Render3d.ScenePlan の materialWantedIn）。
    /// 半透明を頼まれた物（MultiMesh3d.withMaterial が落とした）と骨の重みを持つ形は、形ごとに 1 回知らせる。
    pub def groupedOf(planner: Planner, tables: Tables, wants: Scene3d.MaterialFields -> Bool, coverage: Bool, variant: ShaderVariant,
                      multis: List[MultiMesh3d.MultiMesh3d]): List[Grouped] \ IO =
        multis |> List.filter(mm -> MultiMesh3d.countOf(mm) > 0) |> List.map(mm -> {
            let r = MultiMesh3d.fieldsOf(mm);
            let head = { fields = Scene3d.instanceFieldsOf(MultiMesh3d.headOf(mm)), pose = None, poseRow = 0, culled = false };
            noteMisuse(planner, r);
            match r#material |> Option.map(Scene3d.materialFieldsOf) |> Option.filter(wants) {
                case Some(m) =>
                    let kind = kindOf(coverage, variant, head, m);
                    { mesh = mm, head = head, surface = Some((m, kind)), handle = verifiedHandle(tables, requestOf(tables, m, kind), m, kind) }
                case None => { mesh = mm, head = head, surface = None, handle = -1 }
            }
        })

    def noteMisuse(planner: Planner, r: MultiMesh3d.MultiMeshFields): Unit \ IO =
        let shape = Mesh3d.contentHash(r#mesh);
        if (r#blendRequested)
            warnOnce(planner, "multimesh-blend:" + shape, "scene3d: 半透明の材質は MultiMesh3d では不透明として描く — 透けて重なって見せたい大きな板は instances へ。"
                + "細い粒（雨・火の粉）は cutout の材質で MultiMesh のままで良い（engine の docs/scene3d.md の「描く量」）")
        else ();
        if (Option.nonEmpty(Mesh3d.maxSkinJoint(r#mesh)))
            warnOnce(planner, "multimesh-skin:" + shape, "scene3d: 骨の重みを持つ形を MultiMesh3d に渡した — 骨で曲げずにバインドポーズで描く。骨で動く物は instances に Scene3d.withPose で置く")
        else ()

    /// backend の答え orders（聞いた番号で引く順の番号・0 なら頂点の色で描く）を当てる。
    pub def plannedOf(orders: Vector[Int32], g: Grouped): Planned =
        let material = g#surface |> Option.flatMap(mk -> {
            let (m, kind) = mk;
            let order = Vector.get(g#handle, orders);
            if (order == 0) None else Some((g#handle, order, kind, m))
        });
        { mesh = g#mesh, head = g#head, material = material }

    /// 群れ全体の境界が視錐台 f に掛かりうるか（頂点の無い形は掛かると見る）。
    pub def isVisibleIn(f: Frustum.Frustum, mm: MultiMesh3d.MultiMesh3d): Bool =
        match MultiMesh3d.fieldsOf(mm)#bounds {
            case Some(b) => Frustum.intersectsBox(f, b#min, b#max, Mat4.identity())
            case None    => true
        }
}
