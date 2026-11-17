// Render3d.ScenePlan — 3D の描き手（Render3d）の、prepare の中で場面を描く物へ分ける所（計画の側。GL を呼ばない）。描く順（半透明の物の遠い順も）と姿勢の行はここで決まる。約束は Render3d.flix の頭。
// WhyNot: backend を計画の中から呼ばない — 計画が GL を知ることになり、WebGPU の backend が同じ計画を使えない。描き先の能力と材質の答えは値で受け取る（groupScenes の後・planScenes の前に backend が材質を引く）。
mod Render3d.ScenePlan {
    import java.lang.Object
    import java.util.HashMap
    import java.util.IdentityHashMap
    import java.util.Objects
    use Render3d.{DrawMode, MeshDraw, ProgramKind, ShadowCaster, ShadowLight, ShadowPlan, maxShadowMapSize, maxShadowPcfRadius}
    use Render3d.Batch.{BatchKey, MaterialBatch, SpanBatch, batchKeyOf}
    use Render3d.PoseRows.{PoseRows, noRows, withPoseRow}

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

    /// 場面 1 つを描く材料を batch に分け終えた物（どれも描く順に並べてある）。plain = 材質の無い骨の無い物・skinned = 材質の無い骨つきの物・
    /// opaque = 不透明の材質の物（Output.Depth では材質で描く物）・blended = 半透明の材質の物（1 体ずつの batch を Scene3d.blendOrderOf の順＝目から遠い物から。Output.Depth では空）・
    /// billboards = 場面のビルボード（来た順のまま・視錐台の外の物も culled を立てて残す）。
    pub type alias SceneDraws[b] = { plain = List[b], skinned = List[b], opaque = List[MaterialBatch[b]], blended = List[MaterialBatch[b]], billboards = List[BillboardDraw] }

    /// ビルボード 1 つ。culled = 視錐台の外（外接球で見る・Scene3d.isBillboardOutsideFrustum）なので描かない（見つからない絵の知らせは描く物と同じに出す）。
    pub type alias BillboardDraw = { fields = Scene3d.BillboardFields, culled = Bool }

    /// 場面の pass 1 つが場面の描き先へ書く物。Color = 光を当てた色・DepthOut = 目からの距離の灰色（near が黒・near + range が白。Output.Depth）。
    /// どちらも描き先の attachment は色 1 つ（場面の描き先の形式）と深度で、2D の pass（RenderFrame.Internal.RenderList.PassSpec の
    /// ColorAttachment と DepthStencil.Depth）と同じ組。光ごとの影の地図（深度だけを書き、色を持たない pass）は Render3d.ShadowMaps.ShadowPass（場面の列の外）。
    // WhyNot: 描き先の texture の番号を持たない — 場面の描き先は backend が場面の番号で持つ（WebGPU の Render3d.WebGpuRenderer.SceneTarget・GL は 2D の描き先か Design の描き先）。
    pub enum ScenePassSpec {
        case Color
        case DepthOut({ near = Float64, range = Float64 })
    }

    /// 場面の Output で決まる pass。
    def passSpecOf(output: Scene3d.Output): ScenePassSpec = match output {
        case Scene3d.Output.Color    => ScenePassSpec.Color
        case Scene3d.Output.Depth(r) => ScenePassSpec.DepthOut(r)
    }

    /// prepare の中で分け終えた場面 1 つ。mainPass = 場面の置いた物を場面の描き先へ描く pass（影の地図の pass は含まない）・shadowPlans = 影の地図を描く材料（影を落とす光ごとに 1 つ。無ければ空。スポットの次に太陽）。
    pub type alias ScenePlan[b] = { cmd = Scene3d.RenderCmd, mainPass = ScenePassSpec, draws = SceneDraws[b], shadowPlans = List[ShadowPlan[b]] }

    /// 材質を backend に聞く 1 つ（材質とプログラムの版）。聞く並びの番号が、そのまま材質の表の番号（MaterialBatch#handle）になる。
    pub type alias MaterialRequest = (Scene3d.MaterialFields, ProgramKind)

    /// batch の候補 1 つ。surface = 頭の物の材質とプログラムの版（無ければ頂点の色で描く）・handle = surface を聞いた番号（surface が無ければ -1）。
    pub type alias Group = { batch = SpanBatch, surface = Option[MaterialRequest], handle = Int32 }

    /// 置いた物を batch の候補に分け終えた場面 1 つ。shadowPlans = 影の地図の batch（姿勢の行はまだ振っていない）。
    pub type alias GroupedScene = { cmd = Scene3d.RenderCmd, mainPass = ScenePassSpec, groups = List[Group], shadowPlans = List[ShadowPlan[SpanBatch]] }

    /// 1 回の prepare の計画の答え。members = batch の描く物（batch ごとに続けて並ぶ・SpanBatch の start が指す）・requests = backend に聞く材質（聞いた順）。
    pub type alias Grouped = { scenes = List[GroupedScene], requests = Vector[MaterialRequest], members = MutList[MeshDraw, Static] }

    // ── 置いた物 1 つ ──

    pub def isSkinned(d: MeshDraw): Bool = Option.nonEmpty(d#pose)

    pub def hasUv(d: MeshDraw): Bool = Option.nonEmpty(Mesh3d.uvs(d#fields#mesh))

    /// 置いた物を描く材料にする（outside が真なら間引く）。姿勢の行は描く物が決まった後で割り当てる。ジョイントの数の食い違いは形ごとに 1 回だけ知らせる（Scene3d.skinningWarning）。
    pub def meshDrawOf(planner: Planner, outside: Scene3d.Instance3d -> Bool, placed: Scene3d.Instance3d): MeshDraw \ IO =
        let fields = Scene3d.instanceFieldsOf(placed);
        Scene3d.skinningWarning(placed) |> Option.forEach(message -> warnOnceIn(planner#skinWarnedRef, Mesh3d.contentHash(fields#mesh), message));
        { fields = fields, pose = Scene3d.skinningOf(placed), poseRow = 0, culled = outside(placed) }

    /// 材質 m の cutout を alpha to coverage で描くか。coverage = 描き先が標本を持ち、色の段で描く（Output.Depth は偽で渡す）。
    // WhyNot: 深度の段（Output.Depth）と半透明に使わない — 深度の灰色は縁で混ぜると奥行きが嘘になり、半透明の α は重ねる量に使う。
    pub def isCoverageCutout(coverage: Bool, m: Scene3d.MaterialFields): Bool =
        coverage and m#cutout and not m#blend

    /// 描く順の鍵で並べる。鍵が同じ物は来た順（同じ入力はいつも同じ順）。
    // WhyNot: 並べ替えにしない — 鍵（材質の順の番号）はほとんど並んで来る入力で、1 棟 1 個の都市では鍵の種類が物の数に近い。
    // 鍵ごとに集めて小さい順につなげば、並び方に関わらず物の数 × log(鍵の種類) で済む。
    pub def inDrawOrder(keyOf: a -> Int32, xs: List[a]): List[a] =
        let byKey = List.foldLeft((m, x) -> {
            let key = keyOf(x);
            Map.insert(key, x :: Map.getWithDefault(key, Nil, m), m)
        }, (Map.empty(): Map[Int32, List[a]]), xs);
        Map.foldRightWithKey((_, group, acc) -> List.reverse(group) ::: acc, Nil, byKey)

    /// 置いた物 d を材質 m で描くプログラムの版。法線マップは uv つきの形にだけ当てる。
    pub def kindOf(coverage: Bool, d: MeshDraw, m: Scene3d.MaterialFields): ProgramKind =
        let uv = hasUv(d);
        { skinned = isSkinned(d), uv = uv, normalMap = Option.nonEmpty(m#normalMap) and uv, lightmap = Option.nonEmpty(Scene3d.lightmapOfFields(d#fields)),
          blend = m#blend, doubleSided = m#doubleSided, coverage = isCoverageCutout(coverage, m),
          metallicRoughness = Option.nonEmpty(m#metallicRoughnessShade) }

    /// プログラムの版の 8 つの欄を 1 つの数にした物（Render3d.materialKey の版の部分と同じ欄）。
    // WhyNot: Render3d.Batch.kindBits を使わない — あちらは batch にしない版（lightmap・blend）を落とした batch の鍵で、材質の問い合わせは別のプログラムの版を分けなければいけない。
    def kindCodeOf(kind: ProgramKind): Int32 =
        let bit = (on, value) -> if (on) value else 0;
        bit(kind#skinned, 1) + bit(kind#uv, 2) + bit(kind#normalMap, 4) + bit(kind#lightmap, 8) + bit(kind#blend, 16) + bit(kind#doubleSided, 32)
            + bit(kind#coverage, 64) + bit(kind#metallicRoughness, 128)

    // ── 候補に分ける ──

    /// 1 回の prepare の控え。keys = batch の鍵 → 番号・textures = 材質の絵の名前の並び → 番号・requests = backend に聞く材質・
    /// requestIds = (プログラムの版, 材質の木の鍵) → requests の番号・members = batch の描く物。
    pub type alias Tables = {
        keys = Ref[Map[BatchKey, Int32], Static], textures = Ref[Map[List[String], Int32], Static], requests = MutList[MaterialRequest, Static],
        requestIds = Ref[Map[(Int32, Int64), Int32], Static], members = MutList[MeshDraw, Static]
    }

    pub def freshTables(): Tables \ IO =
        { keys = Ref.fresh(Static, Map.empty()), textures = Ref.fresh(Static, Map.empty()), requests = MutList.empty(Static),
          requestIds = Ref.fresh(Static, Map.empty()), members = MutList.empty(Static) }

    /// 材質の値と頂点の形 1 組の分け方。surface = 聞く材質（頂点の色で描くなら None）・handle = その聞いた番号（無ければ -1）・
    /// key = batch の鍵の番号（-1 = batch にしない）・texture = 材質の絵の名前の並びの番号・needsUv = 法線マップを持つ材質（uv の無い形なら知らせる）。
    type alias Placement = { surface = Option[MaterialRequest], handle = Int32, key = Int32, texture = Int32, needsUv = Bool }

    /// 候補に分ける時に変わらない物。cache = 材質の値（同じ 1 つの値）→ 頂点の形の番号 → Placement。
    type alias Grouping = {
        planner = Planner, tables = Tables, outside = Scene3d.Instance3d -> Bool, wants = Scene3d.MaterialFields -> Bool, coverage = Bool,
        cache = IdentityHashMap[Object, Object]
    }

    /// 1 回の prepare の場面を候補に分け、backend に聞く材質を、その材質の物が初めて来た順に並べる。samples = 描き先の標本の数。
    /// 同じプログラム（版と材質の木の鍵が同じで、同じ GLSL を生む）の材質は 1 回だけ聞く（requestOf）。
    pub def groupScenes(planner: Planner, caps: PlanCaps, samples: Int32, cmds: List[Scene3d.RenderCmd]): Grouped \ IO =
        groupScenesWith(planner, caps, samples, cmds |> List.map(c -> (c, Scene3d.instancesOf(c#scene))))

    /// groupScenes の、場面ごとに計画へ通す置いた物を場面と組で渡す形（組の外の集まりの物は backend が持ち越した行で描く・Render3d.StaticRows）。
    /// 影を落とす光があるかは組の物でなく場面の全部の物で決める。
    pub def groupScenesWith(planner: Planner, caps: PlanCaps, samples: Int32, cmds: List[(Scene3d.RenderCmd, List[Scene3d.Instance3d])]): Grouped \ IO =
        let tables = freshTables();
        let scenes = cmds |> List.map(groupScene(planner, tables, caps, samples));
        { scenes = scenes, requests = MutList.toArray(Static, tables#requests) |> Array.toVector, members = tables#members }

    /// 持ち越す物 items を、視錐台で間引かずに候補に分ける（色の pass の材質の候補と、影の地図の形だけの候補）。
    /// 答えは (色の pass の候補, 影の地図の候補, backend に聞く材質, batch の描く物)。
    // WhyNot: alpha to coverage の版を聞かない — 持ち越すのは alpha to coverage を持たない WebGPU の backend だけ（GL は持ち越さない・Render3d.StaticRows の頭）。
    pub def groupCarried(planner: Planner, items: List[Scene3d.Instance3d]): (List[Group], List[SpanBatch], Vector[MaterialRequest], MutList[MeshDraw, Static]) \ IO =
        let tables = freshTables();
        let lit = groupWith(grouping(planner, tables, _ -> false, _ -> true, false), items);
        let shadow = groupWith(grouping(planner, tables, _ -> false, _ -> false, false), items) |> List.map(gr -> gr#batch);
        (lit, shadow, MutList.toArray(Static, tables#requests) |> Array.toVector, tables#members)

    /// 置いた物を候補に分ける（Preload の形。場面の矩形も影も持たない）。outside = 間引く物か。
    pub def groupInstances(planner: Planner, outside: Scene3d.Instance3d -> Bool, wants: Scene3d.MaterialFields -> Bool, coverage: Bool,
                           instances: List[Scene3d.Instance3d]): (List[Group], Vector[MaterialRequest]) \ IO =
        let tables = freshTables();
        let groups = groupWith(grouping(planner, tables, outside, wants, coverage), instances);
        (groups, MutList.toArray(Static, tables#requests) |> Array.toVector)

    def grouping(planner: Planner, tables: Tables, outside: Scene3d.Instance3d -> Bool, wants: Scene3d.MaterialFields -> Bool, coverage: Bool): Grouping \ IO =
        { planner = planner, tables = tables, outside = outside, wants = wants, coverage = coverage, cache = new IdentityHashMap() }

    /// 場面の置いた物を、Output に合わせて batch の候補に分け、影の地図の batch も分ける。
    // WhyNot: Design の解像度の描き先に標本を持たせない — ドット絵と画素をそろえる場面に縁のならしは要らない。
    def groupScene(planner: Planner, tables: Tables, caps: PlanCaps, samples: Int32, cd: (Scene3d.RenderCmd, List[Scene3d.Instance3d])): GroupedScene \ IO =
        let (cmd, drawn) = cd;
        let scene = cmd#scene;
        let outside = Scene3d.isOutsideFrustum(Scene3d.frustumOf(scene));
        let coverage = match scene#resolution {
            case Scene3d.Resolution.Native => samples > 1 and caps#alphaToOne
            case Scene3d.Resolution.Design => false
        };
        let mainPass = passSpecOf(scene#output);
        let groups = match mainPass {
            case ScenePassSpec.Color => groupWith(grouping(planner, tables, outside, _ -> true, coverage), drawn)
            case ScenePassSpec.DepthOut(_) =>
                // WhyNot: cutout でも両面でもない材質に材質のプログラムを組まない — 奥行きは形だけで決まり、色の計算は捨てられる
                //   （両面の物は材質の道でカリングを切る。頂点の色の道へ回すと裏の面が捨てられ、CPU の奥行きと食い違う）。
                // WhyNot: 半透明の物を描かない — 奥行きを書くと、ピントの Pass がガラスの手前に合う。
                let solidInstances = List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)), drawn);
                groupWith(grouping(planner, tables, outside, m -> m#cutout or m#doubleSided, false), solidInstances)
        };
        { cmd = cmd, mainPass = mainPass, groups = groups, shadowPlans = shadowPlansOf(planner, tables, scene, drawn) }

    /// instances を候補に分ける。候補の並びは、(形, batch の鍵) が初めて来た順・その中は材質の絵の名前の並びが初めて来た順（Render3d.Batch.groupInOrder と
    /// groupByTextures の並びと同じ）。batch の鍵が無い物は 1 体の候補。
    def groupWith(g: Grouping, instances: List[Scene3d.Instance3d]): List[Group] \ IO =
        let placed = List.toArray(Static, instances);
        let n = Array.length(placed);
        let draws: Array[MeshDraw, Static] = Array.empty(Static, n);
        let placements: Array[Placement, Static] = Array.empty(Static, n);
        let levels = Array.repeat(Static, n, 0);
        let subs = Array.repeat(Static, n, 0);
        let split = { buckets = (new HashMap(): HashMap[String, Object]), firstTexture = MutList.empty(Static), subCount = MutList.empty(Static),
                      extraSubs = Ref.fresh(Static, (Map.empty(): Map[(Int32, Int32), Int32])) };
        placeFrom(g, split, placed, draws, placements, levels, subs, 0, n);
        spansOf(g#tables, split, draws, placements, levels, subs)

    /// (形, 鍵) の候補の番号を振る控え。buckets = 形の鍵の字 → (batch の鍵の番号 → 候補の番号)・firstTexture = 候補ごとの最初の絵の並びの番号・
    /// subCount = 候補ごとの絵の並びの数・extraSubs = (候補, 2 つ目からの絵の並び) → その中の番号。
    type alias Split = {
        buckets = HashMap[String, Object], firstTexture = MutList[Int32, Static], subCount = MutList[Int32, Static],
        extraSubs = Ref[Map[(Int32, Int32), Int32], Static]
    }

    def placeFrom(g: Grouping, split: Split, placed: Array[Scene3d.Instance3d, Static], draws: Array[MeshDraw, Static], placements: Array[Placement, Static],
                  levels: Array[Int32, Static], subs: Array[Int32, Static], i: Int32, n: Int32): Unit \ IO =
        if (i >= n) ()
        else {
            placeOne(g, split, placed, draws, placements, levels, subs, i);
            placeFrom(g, split, placed, draws, placements, levels, subs, i + 1, n)
        }

    /// i 番目の置いた物を描く材料にし、分け方と候補の番号を控える（lightmap と法線マップの食い違いは形ごとに 1 回知らせる）。
    // WhyNot: 末尾を呼び出しで終えない — 物の数だけ回る placeFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def placeOne(g: Grouping, split: Split, placed: Array[Scene3d.Instance3d, Static], draws: Array[MeshDraw, Static], placements: Array[Placement, Static],
                 levels: Array[Int32, Static], subs: Array[Int32, Static], i: Int32): Unit \ IO =
        let item = Array.get(i, placed);
        Scene3d.lightmapWarning(item) |> Option.forEach(line ->
            warnOnce(g#planner, "lightmap:" + line + Mesh3d.contentHash(Scene3d.instanceFieldsOf(item)#mesh), line));
        let d = meshDrawOf(g#planner, g#outside, item);
        let p = placementOf(g, d);
        if (p#needsUv and not hasUv(d)) warnNoUv(g#planner, d, p) else ();
        let level = levelOf(split, d, p);
        Array.put(d, i, draws);
        Array.put(p, i, placements);
        Array.put(level, i, levels);
        Array.put(subOf(split, level, p#texture), i, subs);
        ()

    def warnNoUv(planner: Planner, d: MeshDraw, p: Placement): Unit \ IO =
        p#surface |> Option.forEach(mk ->
            warnOnce(planner, "nouv:" + Mesh3d.contentHash(d#fields#mesh),
                "scene3d: uv の無い形に法線マップの材質 '${fst(mk)#spec#name}' が付いている — 法線マップを当てずに描く（Mesh3d.withUvs か withBoxUvs で uv を付ける）"))

    /// 頂点の形の番号（uv・骨・lightmap）。プログラムの版のうち置いた物で決まる欄。
    def shapeBitsOf(d: MeshDraw): Int32 =
        (if (hasUv(d)) 1 else 0) + (if (isSkinned(d)) 2 else 0) + (if (Option.nonEmpty(Scene3d.lightmapOfFields(d#fields))) 4 else 0)

    /// d の分け方。材質の値が同じ 1 つの値で頂点の形が同じなら、前に決めた物を使う。
    // WhyNot: 材質の値の中身で引かない — 中身の比べ（木・params）が物の数だけ要り、それを避けるための控え。値が別なら中身が同じでも作り直すだけで、答えは同じ。
    def placementOf(g: Grouping, d: MeshDraw): Placement \ IO =
        match d#fields#material {
            case None    => plainPlacement(g, d)
            case Some(m) => cachedPlacement(g, d, m)
        }

    /// 材質 m の値と d の頂点の形の分け方（控えに無ければ決めて控える）。
    def cachedPlacement(g: Grouping, d: MeshDraw, m: Scene3d.Material3d): Placement \ IO =
        let bits = shapeBitsOf(d);
        let byShape = byShapeOf(g#cache, unchecked_cast(m as Object));
        match Map.get(bits, Ref.get(byShape)) {
            case Some(p) => p
            case None    =>
                let made = materialPlacement(g, d, Scene3d.materialFieldsOf(m));
                Ref.put(Map.insert(bits, made, Ref.get(byShape)), byShape);
                made
        }

    def byShapeOf(cache: IdentityHashMap[Object, Object], key: Object): Ref[Map[Int32, Placement], Static] \ IO =
        let found = cache.get(key);
        if (Objects.isNull(found)) {
            let made: Ref[Map[Int32, Placement], Static] = Ref.fresh(Static, Map.empty());
            discard cache.put(key, unchecked_cast(made as Object));
            made
        } else unchecked_cast(found as Ref[Map[Int32, Placement], Static])

    def plainPlacement(g: Grouping, d: MeshDraw): Placement \ IO =
        { surface = None, handle = -1, key = keySlotOf(g#tables, batchKeyOf(g#planner#drawMode, d, None)), texture = textureSlotOf(g#tables, Nil), needsUv = false }

    def materialPlacement(g: Grouping, d: MeshDraw, m: Scene3d.MaterialFields): Placement \ IO =
        if (not (g#wants)(m)) plainPlacement(g, d)
        else {
            let kind = kindOf(g#coverage, d, m);
            let names = ShaderDoc.materialTexReads(m#spec, m#emission, m#metallicRoughnessShade) |> List.map(fst);
            { surface = Some((m, kind)), handle = requestOf(g#tables, m, kind), key = keySlotOf(g#tables, batchKeyOf(g#planner#drawMode, d, Some((m, kind)))),
              texture = textureSlotOf(g#tables, names), needsUv = Option.nonEmpty(m#normalMap) }
        }

    /// 材質 m を版 kind で聞いた番号（版と木の鍵が同じ材質を前に聞いていれば、その番号。木の中身は比べない — 候補の頭で verifiedHandle が比べる）。
    pub def requestOf(tables: Tables, m: Scene3d.MaterialFields, kind: ProgramKind): Int32 \ IO =
        let id = (kindCodeOf(kind), force m#shaderHash);
        match Map.get(id, Ref.get(tables#requestIds)) {
            case Some(handle) => handle
            case None         =>
                let handle = pushRequest(tables, m, kind);
                Ref.put(Map.insert(id, handle, Ref.get(tables#requestIds)), tables#requestIds);
                handle
        }

    /// handle 番の材質と m が同じ GLSL を生むならその番号・違えば（木の鍵の衝突）新しい番号で聞く。
    // WhyNot: 物ごとに比べない — 材質の値を毎コマ作り直すゲームでは参照で比べられず、物の数だけ木を辿る。候補の中の物は頭の材質で描くので、頭で 1 回比べれば足りる。
    // WhyNot: ぶつかった 2 つを同じ控えの中で両方保たない — backend の控えの鍵は木の鍵なので、ぶつかった 2 つは毎コマ組み直しになるが、64 ビットの衝突でだけ起き、絵は正しい。
    pub def verifiedHandle(tables: Tables, handle: Int32, m: Scene3d.MaterialFields, kind: ProgramKind): Int32 \ IO =
        if (isSameProgram(fst(MutList.get(handle, tables#requests)), m)) handle else pushRequest(tables, m, kind)

    def pushRequest(tables: Tables, m: Scene3d.MaterialFields, kind: ProgramKind): Int32 \ IO =
        let handle = MutList.size(tables#requests);
        MutList.push((m, kind), tables#requests);
        handle

    /// a と b が同じ GLSL を生むか（参照が同じ木なら木を辿らない・ShaderGen.eqMaterial）。
    def isSameProgram(a: Scene3d.MaterialFields, b: Scene3d.MaterialFields): Bool =
        ShaderGen.eqMaterial(a#spec, a#emission, a#metallicRoughnessShade, b#spec, b#emission, b#metallicRoughnessShade)

    /// batch の鍵の番号（鍵が無ければ -1）。
    def keySlotOf(tables: Tables, key: Option[BatchKey]): Int32 \ IO =
        key |> Option.map(k -> slotIn(tables#keys, k)) |> Option.getWithDefault(-1)

    def textureSlotOf(tables: Tables, names: List[String]): Int32 \ IO = slotIn(tables#textures, names)

    /// 表 table の中の k の番号（無ければ次の番号を振る）。
    def slotIn(table: Ref[Map[k, Int32], Static], k: k): Int32 \ IO with Order[k] =
        match Map.get(k, Ref.get(table)) {
            case Some(slot) => slot
            case None       =>
                let slot = Map.size(Ref.get(table));
                Ref.put(Map.insert(k, slot, Ref.get(table)), table);
                slot
        }

    /// d の (形, batch の鍵) の候補の番号（鍵が無ければ新しい番号）。
    def levelOf(split: Split, d: MeshDraw, p: Placement): Int32 \ IO =
        if (p#key < 0) newLevel(split, p#texture)
        else {
            let byKey = bucketOf(split#buckets, Mesh3d.contentHash(d#fields#mesh));
            match Map.get(p#key, Ref.get(byKey)) {
                case Some(level) => level
                case None        =>
                    let level = newLevel(split, p#texture);
                    Ref.put(Map.insert(p#key, level, Ref.get(byKey)), byKey);
                    level
            }
        }

    def newLevel(split: Split, texture: Int32): Int32 \ IO =
        let level = MutList.size(split#firstTexture);
        MutList.push(texture, split#firstTexture);
        MutList.push(1, split#subCount);
        level

    def bucketOf(buckets: HashMap[String, Object], name: String): Ref[Map[Int32, Int32], Static] \ IO =
        let found = buckets.get(name);
        if (Objects.isNull(found)) {
            let made: Ref[Map[Int32, Int32], Static] = Ref.fresh(Static, Map.empty());
            discard buckets.put(name, unchecked_cast(made as Object));
            made
        } else unchecked_cast(found as Ref[Map[Int32, Int32], Static])

    /// 候補 level の中の、材質の絵の並び texture の番号（初めて来た並びは次の番号）。
    def subOf(split: Split, level: Int32, texture: Int32): Int32 \ IO =
        if (MutList.get(level, split#firstTexture) == texture) 0
        else match Map.get((level, texture), Ref.get(split#extraSubs)) {
            case Some(sub) => sub
            case None      =>
                let sub = MutList.get(level, split#subCount);
                MutList.put(sub + 1, level, split#subCount);
                Ref.put(Map.insert((level, texture), sub, Ref.get(split#extraSubs)), split#extraSubs);
                sub
        }

    /// 物ごとの候補の番号から、候補ごとの頭の物と描く物の範囲を作る（描く物は members の後ろへ候補の順に足す・候補の中は来た順）。
    def spansOf(tables: Tables, split: Split, draws: Array[MeshDraw, Static], placements: Array[Placement, Static],
                levels: Array[Int32, Static], subs: Array[Int32, Static]): List[Group] \ IO =
        let levelCount = MutList.size(split#subCount);
        let offsets = Array.repeat(Static, levelCount + 1, 0);
        prefixFrom(offsets, l -> MutList.get(l, split#subCount), 0, levelCount);
        let groupCount = Array.get(levelCount, offsets);
        let n = Array.length(draws);
        let span = { draws = draws, groupOf = Array.repeat(Static, n, 0), heads = Array.repeat(Static, groupCount, -1), counts = Array.repeat(Static, groupCount, 0) };
        countFrom(span, levels, subs, offsets, 0, n);
        let starts = Array.repeat(Static, groupCount + 1, 0);
        prefixFrom(starts, k -> Array.get(k, span#counts), 0, groupCount);
        let base = MutList.size(tables#members);
        let ordered: Array[MeshDraw, Static] = Array.empty(Static, Array.get(groupCount, starts));
        let filled = Array.repeat(Static, groupCount + 1, 0);
        Array.copyInto(srcPos = 0, dstPos = 0, len = groupCount + 1, src = starts, filled);
        orderFrom(span, ordered, filled, 0, n);
        pushFrom(ordered, tables#members, 0, Array.length(ordered));
        List.range(0, groupCount) |> List.map(k -> {
            let head = Array.get(k, span#heads);
            let p = Array.get(head, placements);
            { batch = { head = Array.get(head, draws), start = base + Array.get(k, starts), count = Array.get(k, span#counts) }, surface = p#surface,
              handle = p#surface |> Option.map(mk -> verifiedHandle(tables, p#handle, fst(mk), snd(mk))) |> Option.getWithDefault(-1) }
        })

    /// spansOf の物ごとの控え。groupOf = 物の候補の番号・heads = 候補の頭の物の番号・counts = 候補の描く物の数。
    type alias SpanWork = { draws = Array[MeshDraw, Static], groupOf = Array[Int32, Static], heads = Array[Int32, Static], counts = Array[Int32, Static] }

    /// out[k + 1] = out[k] + sizeOf(k)（k = from..n − 1）。
    def prefixFrom(out: Array[Int32, Static], sizeOf: Int32 -> Int32 \ IO, k: Int32, n: Int32): Unit \ IO =
        if (k >= n) ()
        else {
            Array.put(Array.get(k, out) + sizeOf(k), k + 1, out);
            prefixFrom(out, sizeOf, k + 1, n)
        }

    def pushFrom(xs: Array[MeshDraw, Static], out: MutList[MeshDraw, Static], i: Int32, n: Int32): Unit \ IO =
        if (i >= n) ()
        else {
            MutList.push(Array.get(i, xs), out);
            pushFrom(xs, out, i + 1, n)
        }

    def countFrom(span: SpanWork, levels: Array[Int32, Static], subs: Array[Int32, Static], offsets: Array[Int32, Static], i: Int32, n: Int32): Unit \ IO =
        if (i >= n) ()
        else {
            countOne(span, levels, subs, offsets, i);
            countFrom(span, levels, subs, offsets, i + 1, n)
        }

    // WhyNot: 末尾を呼び出しで終えない — 物の数だけ回る countFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    def countOne(span: SpanWork, levels: Array[Int32, Static], subs: Array[Int32, Static], offsets: Array[Int32, Static], i: Int32): Unit \ IO =
        let group = Array.get(Array.get(i, levels), offsets) + Array.get(i, subs);
        Array.put(group, i, span#groupOf);
        if (Array.get(group, span#heads) < 0) Array.put(i, group, span#heads) else ();
        if (Array.get(i, span#draws)#culled) () else Array.put(Array.get(group, span#counts) + 1, group, span#counts);
        ()

    def orderFrom(span: SpanWork, ordered: Array[MeshDraw, Static], filled: Array[Int32, Static], i: Int32, n: Int32): Unit \ IO =
        if (i >= n) ()
        else {
            orderOne(span, ordered, filled, i);
            orderFrom(span, ordered, filled, i + 1, n)
        }

    // WhyNot: 末尾を呼び出しで終えない — 物の数だけ回る orderFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    def orderOne(span: SpanWork, ordered: Array[MeshDraw, Static], filled: Array[Int32, Static], i: Int32): Unit \ IO =
        let d = Array.get(i, span#draws);
        if (d#culled) ()
        else {
            let group = Array.get(i, span#groupOf);
            Array.put(d, Array.get(group, filled), ordered);
            Array.put(Array.get(group, filled) + 1, group, filled)
        };
        ()

    // ── 影 ──

    /// 影を落とす光（スポットと太陽）ごとに、影の地図を描く batch を分ける。スポットの次に太陽。無ければ空。
    /// 太陽を使えない理由（Scene3d.directionalLightWarning）は、影の有無に関わらずここで鍵ごとに初回 1 回だけ知らせる（場面ごとにここを通る）。
    // WhyNot: 半透明の物に影を落とさせない — 影の地図は 0 か 1 の奥行きで、薄い色ガラスが真っ黒な影を落とす。
    def shadowPlansOf(planner: Planner, tables: Tables, scene: Scene3d.Scene3dCmd, drawn: List[Scene3d.Instance3d]): List[ShadowPlan[SpanBatch]] \ IO =
        Scene3d.directionalLightWarning(scene) |> Option.forEach(line -> warnShadowOnce(planner, "@sun:direction", line));
        let solid = drawn |> List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)));
        shadowCastersOf(planner, scene) |> List.map(found -> {
            let (light, caster) = found;
            let outside = Scene3d.isOutsideFrustum(caster#frustum);
            let groups = groupWith(grouping(planner, tables, outside, _ -> false, false), solid) |> List.map(gr -> gr#batch);
            let (skinned, plain) = List.partition(b -> isSkinned(b#head), groups);
            { caster = caster, light = light, plain = plain, skinned = skinned }
        })

    /// 影を落とす光（スポットがあれば先・太陽が後）。Output.Depth の場面と、置いた物の無い場面は空。
    def shadowCastersOf(planner: Planner, scene: Scene3d.Scene3dCmd): List[(ShadowLight, ShadowCaster)] \ IO =
        let spot = spotCasterOf(planner, scene) |> Option.map(found -> { let (i, caster) = found; (ShadowLight.Spot(i), caster) }) |> Option.toList;
        let sun = Scene3d.directionalShadowOf(scene) |> Option.map(sunCasterOf(planner, scene)) |> Option.toList;
        List.append(spot, sun)

    /// 太陽の影の地図を描く光。設定が上限を超えて頭打ちになった時は 1 回知らせる（頭打ちの値は Scene3d.directionalShadowOf が決める）。
    def sunCasterOf(planner: Planner, scene: Scene3d.Scene3dCmd, setup: Scene3d.SunShadowSetup): (ShadowLight, ShadowCaster) \ IO =
        Scene3d.directionalLightOf(scene) |> Option.flatMap(l -> l#shadow) |> Option.forEach(s -> {
            if (s#mapSize > maxShadowMapSize())
                warnShadowOnce(planner, "sunSize", "scene3d: 太陽の影の mapSize ${s#mapSize} は大きすぎる — ${maxShadowMapSize()} で描く")
            else ();
            if (s#pcfRadius > maxShadowPcfRadius())
                warnShadowOnce(planner, "sunPcf", "scene3d: 太陽の影の pcfRadius ${s#pcfRadius} は大きすぎる — ${maxShadowPcfRadius()} で数える")
            else ()
        });
        (ShadowLight.Sun(setup), { matrix = setup#matrix, frustum = setup#frustum,
                                   settings = { mapSize = setup#mapSize, bias = setup#depthBias, pcfRadius = setup#pcfRadius, strength = setup#strength } })

    /// 影を落とすスポット。Output.Depth の場面と、置いた物の無い場面は None。
    /// mapSize が 0 以下の shadow は無い物として扱う。2 本目以降の shadow は使わない（1 回知らせる）。
    /// 返すのは (pickLights の後の並びの番号, 光)。
    def spotCasterOf(planner: Planner, scene: Scene3d.Scene3dCmd): Option[(Int32, ShadowCaster)] \ IO =
        match scene#output {
            case Scene3d.Output.Depth(_) => None
            case Scene3d.Output.Color if not Render3d.StaticRows.hasDrawnItem(scene) => None
            case Scene3d.Output.Color =>
                let casters = Scene3d.pickLights(scene)#spotLights
                    |> List.mapWithIndex((i, spot) -> spot#shadow |> Option.filter(m -> m#mapSize > 0)
                        |> Option.map(m -> (i, { matrix = Scene3d.shadowMatrix(spot), frustum = Scene3d.shadowFrustumOf(spot),
                                                 settings = { bias = Scene3d.spotShadowDepthBiasOf(spot, m#bias) | m } })))
                    |> List.filterMap(identity);
                if (List.length(casters) > 1)
                    warnShadowOnce(planner, "second", "scene3d: 影を落とすスポットが 1 つの場面に 2 本以上ある — 最初の 1 本だけが影を落とす")
                else ();
                List.head(casters)
        }

    /// 影についての知らせを種類ごとに 1 回だけ出す。
    pub def warnShadowOnce(planner: Planner, kind: String, message: String): Unit \ IO = warnOnceIn(planner#shadowWarnedRef, kind, message)

    // ── batch に分けて並べる ──

    /// 候補に分けた場面を batch に分けて描く順に並べ、描く物の姿勢の行を振って、割り当てと一緒に返す。orders = backend が聞いた材質の順に返した順の番号。
    /// 姿勢の行は場面の順に、頂点の色の骨つき → 不透明の材質 → 半透明（遠い順）→ 影の地図の骨つきの batch の順で振る（1 体ごとの値の番号も同じ並び）。
    /// 姿勢の行か 1 体ごとの値が上限を超えると後ろから落ちるので、半透明の物は目に近い物から落ちる。
    pub def planScenes(planner: Planner, caps: PlanCaps, orders: Vector[Int32], grouped: Grouped): (List[ScenePlan[SpanBatch]], PoseRows) \ IO =
        let rows = Ref.fresh(Static, noRows(caps#poseRowLimit));
        let plans = grouped#scenes |> List.map(s -> {
            let draws = sceneDrawsOf(planner, orders, s);
            withPoseRows(rows, grouped#members, draws);
            s#shadowPlans |> List.forEach(sp -> sp#skinned |> List.forEach(spanPoseRows(rows, grouped#members)));
            { cmd = s#cmd, mainPass = s#mainPass, draws = draws, shadowPlans = s#shadowPlans }
        });
        (plans, Ref.get(rows))

    /// 候補を頂点の色で描く batch と材質の batch に分ける。orders = backend の答え（handle の番号で引く。0 なら頂点の色で描く）。
    pub def splitGroups(groups: List[Group], orders: Vector[Int32]): (List[SpanBatch], List[MaterialBatch[SpanBatch]]) =
        let (plain, materials) = groups |> List.foldLeft(addGroup(orders), (Nil, Nil));
        (List.reverse(plain), List.reverse(materials))

    def addGroup(orders: Vector[Int32], acc: (List[SpanBatch], List[MaterialBatch[SpanBatch]]), g: Group): (List[SpanBatch], List[MaterialBatch[SpanBatch]]) =
        let (plain, materials) = acc;
        match g#surface |> Option.flatMap(materialBatchOf(orders, g)) {
            case Some(d) => (plain, d :: materials)
            case None    => (g#batch :: plain, materials)
        }

    /// 候補 g の材質 mk の batch（backend が使えないと答えたら None）。
    def materialBatchOf(orders: Vector[Int32], g: Group, mk: MaterialRequest): Option[MaterialBatch[SpanBatch]] =
        let (m, kind) = mk;
        let order = Vector.get(g#handle, orders);
        if (order == 0) None else Some({ handle = g#handle, order = order, kind = kind, material = m, batch = g#batch })

    /// 描く骨つきの物に姿勢の行を割り当てる（members の中の物を、行を振った物に置き換える）。
    def withPoseRows(rows: Ref[PoseRows, Static], members: MutList[MeshDraw, Static], draws: SceneDraws[SpanBatch]): Unit \ IO =
        draws#skinned |> List.forEach(spanPoseRows(rows, members));
        draws#opaque |> List.forEach(d -> spanPoseRows(rows, members, d#batch));
        draws#blended |> List.forEach(d -> spanPoseRows(rows, members, d#batch))

    def spanPoseRows(rows: Ref[PoseRows, Static], members: MutList[MeshDraw, Static], b: SpanBatch): Unit \ IO =
        if (not isSkinned(b#head)) () else poseRowsFrom(rows, members, b#start, b#start + b#count)

    def poseRowsFrom(rows: Ref[PoseRows, Static], members: MutList[MeshDraw, Static], i: Int32, end: Int32): Unit \ IO =
        if (i >= end) ()
        else {
            MutList.put(withPoseRow(rows, MutList.get(i, members)), i, members);
            poseRowsFrom(rows, members, i + 1, end)
        }

    /// 候補を batch に分けて描く順に並べる。
    // WhyNot: 不透明の物を来た順のまま描かない — 深度で前後が決まるので順は同じ深さの面の勝ち方しか変えず、batch にするとプログラムの切り替えも draw も減る。
    def sceneDrawsOf(planner: Planner, orders: Vector[Int32], s: GroupedScene): SceneDraws[SpanBatch] =
        let (vertexColored, materials) = splitGroups(s#groups, orders);
        let (skinned, plain) = List.partition(b -> isSkinned(b#head), vertexColored);
        let billboards = billboardDrawsOf(s#cmd#scene);
        match s#mainPass {
            case ScenePassSpec.Color =>
                let (blended, solid) = List.partition(d -> d#material#blend, materials);
                { plain = plain, skinned = skinned, opaque = materialsInOrder(planner, solid),
                  blended = Scene3d.blendOrderOf(s#cmd#scene#camera#eye, d -> d#batch#head#fields, blended), billboards = billboards }
            case ScenePassSpec.DepthOut(_) =>
                { plain = plain, skinned = skinned, opaque = materialsInOrder(planner, materials), blended = Nil, billboards = billboards }
        }

    /// 場面のビルボード（来た順）。視錐台は置いた物の間引きと同じ Scene3d.frustumOf。
    // WhyNot: 視錐台の外のビルボードを列から外さない — GL は絵が見つからない知らせを間引く前に出すので、外した物の知らせが消える。
    def billboardDrawsOf(scene: Scene3d.Scene3dCmd): List[BillboardDraw] =
        let frustum = Scene3d.frustumOf(scene);
        scene#billboards |> List.map(b -> { fields = Scene3d.billboardFieldsOf(b), culled = Scene3d.isBillboardOutsideFrustum(frustum, b) })

    /// 材質の batch の描く順。backend の順の番号で並べる。DrawMode.OneByOne は来た順のまま（並べ替えの影響も on と off の差に出す）。
    pub def materialsInOrder(planner: Planner, batches: List[MaterialBatch[SpanBatch]]): List[MaterialBatch[SpanBatch]] =
        match planner#drawMode {
            case DrawMode.Instanced => inDrawOrder(d -> d#order, batches)
            case DrawMode.OneByOne  => batches
        }
}
