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

    /// 群れ全体の境界の対角がカメラの far の spreadHintFarRatio() 倍を超える MultiMesh のある場面が spreadHintScenes() 回続いたら、1 回だけ知らせる（場面ごとに呼ぶ）。
    // WhyNot: 1 体ずつ視錐台の外を数えて知らせない — 1 体ずつ間引かないための口で、数えると詰めるのと同じ代金になる。境界の大きさだけで見る。
    // WhyNot: 続く場面の数を noteStaticGroupHint と同じ 120 にしない — 弾のように遠くへ飛んでから消える群れは、境界が一時だけ広がる。
    pub def noteSpreadHint(planner: Planner, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let reach = spreadHintFarRatio() * scene#camera#far;
        let widest = scene#multiMeshes |> List.foldLeft((acc, mm) -> Float64.max(acc, diagonalOf(mm)), 0.0);
        let streak = if (widest > reach) Ref.get(planner#spreadScenesRef) + 1 else 0;
        Ref.put(streak, planner#spreadScenesRef);
        if (streak >= spreadHintScenes())
            warnOnce(planner, "@multimesh-spread-hint", "scene3d: MultiMesh の群れの広がりがカメラの far の ${spreadHintFarRatio()} 倍を超えている — 群れ全体で間引くので、"
                + "見えない所の物まで描いている。区画（数十 m 角）ごとの MultiMesh に分ける・弾は届かない距離で消す（engine の docs/scene3d.md の「描く量」）")
        else ()

    def diagonalOf(mm: MultiMesh3d.MultiMesh3d): Float64 =
        MultiMesh3d.fieldsOf(mm)#bounds |> Option.map(b -> Vec3.length(Vec3.sub(b#max, b#min))) |> Option.getWithDefault(0.0)

    /// noteSpreadHint が広すぎると見る、境界の対角とカメラの far の比（推測の線）。
    pub def spreadHintFarRatio(): Float64 = 2.0

    /// noteSpreadHint が知らせるまでに続く場面の数（60 fps で約 10 秒）。
    pub def spreadHintScenes(): Int32 = 600

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
