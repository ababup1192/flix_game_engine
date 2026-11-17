// Render3d.ShadowMaps — 影の地図の pass の計画と、影の地図の描き先の寿命の表（前半。GPU を呼ばない）。GL（Render3d.Shadow）と WebGPU（Render3d.WebGpuShadows）が同じ関数を使う。
// 計画: prepare 1 回の場面ごとの影の材料（Render3d.ScenePlan の shadowPlans）に、描き先の鍵（一辺の画素と、同じ prepare の中で同じ大きさの何枚目か）と、
// 色の pass が地図を引く値（Render3d.ShadowMaps.ShadowSampling）を決め（assign）、1 体ごとの値の番号を振った材料から行（Render3d.SceneList）を作る（buildPasses）。
// 寿命: 鍵ごとに作った事と最後に使った世代を持ち、使わなくなった描き先を捨てる物を決める。GPU の描き先を作る・捨てるのは backend の Allocator。
// WhyNot: 影の地図の pass を Render3d.ScenePlan.ScenePassSpec の case にしない — 場面の pass の列（Render3d.SceneList.ScenePasses）は「場面の描き先 1 つへ書く」前提で、
//   影の地図は鍵ごとの別の描き先へ深度だけを書き、GL では Design の場面より先に prepare の全部の場面の分を描く。case にすると場面の列を流す 2 つの backend に読まない case が生える。
mod Render3d.ShadowMaps {
    use Render3d.{ShadowLight, ShadowPlan, maxShadowMapSize, maxShadowPcfRadius}
    use Render3d.Batch.{MeshBatch}
    use Render3d.ScenePlan.{Planner, ScenePlan, warnShadowOnce}
    use Render3d.SceneList.{SceneList, Tables}

    /// 影の地図の描き先 1 枚の鍵: Key(一辺の画素, 同じ prepare の中で同じ一辺の何枚目か)・Atlas(幅, 高さ, 同じ prepare の中で同じ大きさの atlas の何枚目か)
    /// （点光源の影の atlas。Scene3d.PointShadows.Atlas）。作るのは keyOf と atlasKeyOf。
    pub enum Key with Eq, Order, ToString {
        case Key(Int32, Int32)
        case Atlas(Int32, Int32, Int32)
    }

    pub def keyOf(size: Int32, ordinal: Int32): Key = Key.Key(size, ordinal)

    pub def atlasKeyOf(width: Int32, height: Int32, ordinal: Int32): Key = Key.Atlas(width, height, ordinal)

    /// 鍵の描き先の (幅, 高さ) の画素。
    pub def extentOf(key: Key): (Int32, Int32) = match key {
        case Key.Key(size, _)          => (size, size)
        case Key.Atlas(width, height, _) => (width, height)
    }

    /// 鍵の (一辺の画素, 何枚目か)（Atlas は (幅, 何枚目か)）。
    pub def pairOf(key: Key): (Int32, Int32) = match key {
        case Key.Key(size, ordinal)      => (size, ordinal)
        case Key.Atlas(width, _, ordinal) => (width, ordinal)
    }

    /// 色の pass が影の地図を引く値（Render3dGlsl の uShadow* と uSun* の欄）。Spot = スポットの影（spotIndex = pickLights の後のスポットの並びの番号）・
    /// Sun = 太陽の影（Scene3d.directionalShadowOf の値。bias = 地図の値から引く量・normalShift = 受ける点を法線へずらす world の長さ・forward = カメラの前の向き）・
    /// Point = 点光源の影の atlas（Render3dGlsl の uPointShadow*）。
    pub enum ShadowSampling {
        case Spot({ matrix = Mat4.Mat4, bias = Float64, pcfRadius = Int32, strength = Float64, spotIndex = Int32 })
        case Sun({ matrix = Mat4.Mat4, bias = Float64, normalShift = Float64, pcfRadius = Int32, strength = Float64, forward = Vec3.Vec3,
                   distance = Float64, fadeWidth = Float64 })
        case Point(Scene3d.PointShadows.Atlas)
    }

    /// 描き先の中の面 1 つ（点光源の影の atlas の 1 面）。x と y = 原点の画素（行 0 が ndc.y = −1 の数え方・Scene3d.PointShadows.tileOriginOf）・size = 一辺の画素。
    /// GL はこのまま viewport と scissor に置き、WebGPU は (x, 高さ − (y + size)) に置く。
    pub type alias Tile = { x = Int32, y = Int32, size = Int32 }

    /// 影を落とす光 1 つに決めた描き先と引く値。view = world → 光の clip（地図を描く頂点シェーダーの目の行列。射影は単位行列）・
    /// tile = 描き先の中の描く面（None なら描き先の全体。点光源の影の atlas の面は Some）。
    pub type alias ShadowMapUse = { key = Key, view = Mat4.Mat4, sampling = ShadowSampling, tile = Option[Tile] }

    /// 影の地図を描く pass 1 つ（map の描き先へ list の行を深度だけで描く）。行は頂点の色の行（骨の無い物）と骨つきの行と、太陽の地図だけはその後に
    /// castShadows のビルボードの行（Scene3d.shadowCastingBillboardsOf）で、どれも分かれた理由は影の pass。
    /// billboardRight = ビルボードの板の横の向き（Scene3d.billboardShadowRightOf。縦は world の上）。
    pub type alias ShadowPass = { map = ShadowMapUse, list = SceneList, billboardRight = Vec3.Vec3 }

    /// backend が描き先を作る・捨てる関数の組（鍵で控える）。
    pub type alias Allocator = { create = Key -> Unit \ IO, destroy = Key -> Unit \ IO }

    /// 寿命の表（作った鍵 → 最後に使った世代）。
    pub type alias Table = { lastUsed = Ref[Map[Key, Int64], Static] }

    pub def fresh(): Table \ IO = { lastUsed = Ref.fresh(Static, Map.empty()) }

    /// 作ってある描き先の鍵 → 最後に使った世代。
    pub def createdOf(table: Table): Map[Key, Int64] \ IO = Ref.get(table#lastUsed)

    /// prepare 1 回の場面ごとの影の材料（場面の並び・場面の中はスポットの次に太陽、その次に点光源の面）に、描き先と引く値を決める（同じ並び）。
    /// 一辺が上限を超えた地図は上限で描き、スポットの pcfRadius は上限で頭打ちにする（どちらも種類ごとに 1 回知らせる）。
    /// 点光源の面は、場面ごとに 1 枚の atlas（Atlas の鍵）の、その面の塊（tile）へ描く。
    // WhyNot: 同じ一辺の地図を場面をまたいで使い回さない — GL は全部の場面の地図を描き終えてから塗るので、同じ一辺の場面が 2 つ（1 つの場面のスポットと太陽でも）あれば地図を分ける。
    pub def assign(planner: Planner, plans: List[List[ShadowPlan[b]]]): List[List[ShadowMapUse]] \ IO =
        let used = Ref.fresh(Static, (Map.empty(): Map[Int32, Int32]));
        let usedAtlases = Ref.fresh(Static, (Map.empty(): Map[(Int32, Int32), Int32]));
        plans |> List.map(scenePlans -> {
            let sceneAtlas = Ref.fresh(Static, None);
            scenePlans |> List.map(plan -> match plan#light {
                case ShadowLight.Point(p) => atlasUseOf(usedAtlases, sceneAtlas, plan#caster#matrix, p)
                case _                    => squareUseOf(planner, used, plan)
            })
        })

    def squareUseOf(planner: Planner, used: Ref[Map[Int32, Int32], Static], plan: ShadowPlan[b]): ShadowMapUse \ IO =
        let size = mapSizeOf(planner, plan#caster#settings);
        let ordinal = Map.getWithDefault(size, 0, Ref.get(used));
        Ref.put(Map.insert(size, ordinal + 1, Ref.get(used)), used);
        { key = keyOf(size, ordinal), view = plan#caster#matrix, sampling = samplingOf(planner, plan), tile = None }

    /// 点光源の面 1 つの描き先。場面の atlas の鍵は場面で初めての面が決め（sceneAtlas）、同じ大きさの atlas の何枚目かは prepare の中で数える（usedAtlases）。
    def atlasUseOf(usedAtlases: Ref[Map[(Int32, Int32), Int32], Static], sceneAtlas: Ref[Option[Key], Static], view: Mat4.Mat4,
                   p: { atlas = Scene3d.PointShadows.Atlas, light = Scene3d.PointShadows.ShadowedPointLight, face = Int32 }): ShadowMapUse \ IO =
        let atlas = p#atlas;
        let key = match Ref.get(sceneAtlas) {
            case Some(k) => k
            case None    => nextAtlasKey(usedAtlases, sceneAtlas, atlas)
        };
        let (x, y) = Scene3d.PointShadows.tileOriginOf(atlas, p#light#slot, p#face);
        { key = key, view = view, sampling = ShadowSampling.Point(atlas), tile = Some({ x = x, y = y, size = atlas#tileSize }) }

    def mapSizeOf(planner: Planner, m: Scene3d.ShadowMap): Int32 \ IO =
        if (m#mapSize > maxShadowMapSize()) {
            warnShadowOnce(planner, "size", "scene3d: 影の地図の mapSize ${m#mapSize} は大きすぎる — ${maxShadowMapSize()} で描く");
            maxShadowMapSize()
        } else m#mapSize

    def nextAtlasKey(usedAtlases: Ref[Map[(Int32, Int32), Int32], Static], sceneAtlas: Ref[Option[Key], Static], atlas: Scene3d.PointShadows.Atlas): Key \ IO =
        let extent = (atlas#width, atlas#height);
        let ordinal = Map.getWithDefault(extent, 0, Ref.get(usedAtlases));
        Ref.put(Map.insert(extent, ordinal + 1, Ref.get(usedAtlases)), usedAtlases);
        let made = atlasKeyOf(atlas#width, atlas#height, ordinal);
        Ref.put(Some(made), sceneAtlas);
        made

    def samplingOf(planner: Planner, plan: ShadowPlan[b]): ShadowSampling \ IO =
        let caster = plan#caster;
        match plan#light {
            case ShadowLight.Spot(spotIndex) =>
                let r = caster#settings#pcfRadius;
                let radius = if (r > maxShadowPcfRadius()) {
                    warnShadowOnce(planner, "pcf", "scene3d: 影の pcfRadius ${r} は大きすぎる — ${maxShadowPcfRadius()} で数える");
                    maxShadowPcfRadius()
                } else Int32.max(0, r);
                ShadowSampling.Spot({ matrix = caster#matrix, bias = caster#settings#bias, pcfRadius = radius, strength = caster#settings#strength, spotIndex = spotIndex })
            case ShadowLight.Sun(setup) =>
                ShadowSampling.Sun({ matrix = caster#matrix, bias = setup#depthBias, normalShift = setup#normalShift, pcfRadius = setup#pcfRadius,
                                     strength = setup#strength, forward = setup#forward, distance = setup#distance, fadeWidth = setup#fadeWidth })
            case ShadowLight.Point(p) => ShadowSampling.Point(p#atlas)
        }

    /// 1 体ごとの値の番号を振り終えた場面の計画 plan の影の材料を、uses（assign の答えの、その場面の分）の描き先へ描く pass にする（同じ並び）。
    /// 行の形の番号は tables で振る（GPU には作らない）。
    pub def buildPasses(tables: Tables, uses: List[ShadowMapUse], plan: ScenePlan[MeshBatch]): List[ShadowPass] \ IO =
        let scene = plan#cmd#scene;
        let ctx = Render3d.SceneList.contextOf(tables, scene);
        let right = Scene3d.billboardShadowRightOfScene(scene);
        List.zip(uses, plan#shadowPlans) |> List.map(match (m, sp) -> {
            // WhyNot: 点光源の面にビルボードを描かない — 板の向きを光ごと面ごとに決める約束が無く、HD-2D の点光源の影は別の話（plans/engine-point-shadows.md §7）。
            let billboards = match sp#light {
                case ShadowLight.Sun(_)   => Scene3d.shadowCastingBillboardsOf(sp#caster#frustum, scene)
                case ShadowLight.Spot(_)  => Nil
                case ShadowLight.Point(_) => Nil
            };
            { map = m, list = Render3d.SceneList.buildShadowList(ctx, sp#plain, sp#skinned, billboards), billboardRight = right }
        })

    /// 鍵 key の描き先を（無ければ allocator で作って）今の世代 gen で使ったと控える。作ったら真。
    pub def ensure(table: Table, allocator: Allocator, gen: Int64, key: Key): Bool \ IO =
        let held = Ref.get(table#lastUsed);
        let made = not Map.memberOf(key, held);
        if (made) allocator#create(key) else ();
        Ref.put(Map.insert(key, gen, held), table#lastUsed);
        made

    /// Render3d.idleTargetFrames() の数の画面のコマ使わなかった描き先を allocator で捨て、捨てた数を返す（画面のコマの終わりに 1 回）。
    pub def sweep(table: Table, allocator: Allocator, gen: Int64): Int32 \ IO =
        let held = Ref.get(table#lastUsed);
        let idle = Map.filter(lastUsed -> gen - lastUsed > Render3d.idleTargetFrames(), held);
        if (Map.isEmpty(idle)) 0
        else {
            Map.forEach((key, _) -> allocator#destroy(key), idle);
            Ref.put(Map.difference(held, idle), table#lastUsed);
            Map.size(idle)
        }

    /// 作ってある描き先を全部 allocator で捨てる。
    pub def release(table: Table, allocator: Allocator): Unit \ IO =
        Map.forEach((key, _) -> allocator#destroy(key), Ref.get(table#lastUsed));
        Ref.put(Map.empty(), table#lastUsed)
}
