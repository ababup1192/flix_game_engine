// Render3d — 3D の場面（Scene3d.RenderCmd）を GL で深度つきで描く。メッシュの置き場・3D のプログラム・光の uniform を持つ。
// 2D の並び（RenderFrame.emitMerged）からは z の 1 点で呼ばれ、その中だけ深度で前後を決めて、GL の状態を元へ戻して返す。
// 座標の約束（左手系・表の面は時計回り）は engine の scene3d/Scene3d.flix の頭。
//
// 光の式は CPU の描き手（engine_tools の SoftRaster3d）と同じ物にそろえる:
//   light = ambient + hemisphere × max(0, n.y) + Σ 点光源 color × intensity × att × facing
//           + Σ スポット color × intensity × att × facing × cone × shadow
//   att = (max(0, 1 − d² / range²))²・facing = clamp(n·l, 0, 1)
//   cone = smoothstep(outerCos, innerCos, dot(−l, スポットの向き))（2 つの cos は Scene3d.spotConeOf）
//   shadow = 影を落とすスポット 1 本だけ 1 − strength × (1 − 照らされている割合)、他は 1（約束は Scene3d.shadowMatrix の doc）
//   toonSteps > 0 なら light = floor(light × steps + 0.5) / steps（色の成分ごと）
//   色 = 頂点の色 × tint × light。fog は目からの距離で near〜far の間を fog の色へ近づける。
//   材質のある物は 色 = fog(albedo × tint × light) + emission（頂点の色は掛けない）。cutout なら α < 0.5 を捨てる。
//   材質の Tex は unit 0〜5（ShaderDoc.materialTexReads の並び・上限 Scene3d.maxMaterialTextures()）に貼り、材質を描いた後に
//   その unit の sampler を外して unit 0 へ戻す（ビルボードと 2D の面が unit 0 で読む）。法線マップは unit 6・影の地図は unit 7。
//   法線マップ（uv つきの形だけ）: T = normalize(T − N (N·T))・B = cross(N, T) × w・c = 絵の rgb・
//   m = ((c.x·2 − 1)·s, (c.y·2 − 1)·s, c.z·2 − 1)・n' = normalize(T m.x + B m.y + N m.z)。光の計算は n'、Spec の Normal は当てる前の N。
//   ビルボードの法線はカメラへ向く向き（−forward）。Output.Depth の灰色は目からの距離で (d − near) / range。
//   半透明（材質の blend）・両面（doubleSided）・空（sky）の約束は SoftRaster3d の頭と同じ:
//   描く順は 不透明（頂点の色 → 材質をプログラムごと）→ ビルボード → 半透明（Scene3d.blendOrderOf の順・深度は読むが書かない・
//   glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)・出す α は材質の albedo.a）。
//   両面の材質は GL_CULL_FACE をその物だけ切り、裏の面（!gl_FrontFacing）は光の計算の法線を裏返す。
//   空は深度を消した後、深度を書かずに場面の矩形いっぱいの四角で塗る（向きは Scene3d.skyBasisOf・式は Scene3d.skyColorOf）。
mod Render3d {
    import java.lang.System
    import java.lang.{Float => JFloat}
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL12
    import org.lwjgl.opengl.GL13
    import org.lwjgl.opengl.GL14
    import org.lwjgl.opengl.GL15
    import org.lwjgl.opengl.GL20
    import org.lwjgl.opengl.GL30
    import org.lwjgl.opengl.GL31
    import org.lwjgl.opengl.GL33
    import org.lwjgl.system.MemoryUtil

    // ── 型 ──

    /// GPU に置いたメッシュ 1 つ。vbo は位置・法線・色の 9 個ずつを交互に並べた物。lastUsed = 最後に描いたコマの世代。
    /// skin = ジョイントの番号と重みの VBO（ジョイントの無い形は None）。
    /// surface = uv（location 5）とタンジェント（location 6）を 6 個ずつ交互に並べた VBO（uv の無い形は None）。
    // WhyNot: uv を位置・法線・色の並びへ混ぜない — uv の無い形まで stride が伸び、uv の無い形の頂点バッファの中身が変わる。
    pub type alias MeshEntry = {
        vao = Int32, vbo = Int32, ibo = Int32, skin = Option[SkinBuffers], surface = Option[Int32], uv2 = Option[Int32], indexCount = Int32, vertexCount = Int32,
        lastUsed = Int64
    }

    /// 頂点ごとのジョイントの番号（ivec4・location 3）と重み（vec4・location 4）の VBO。
    // WhyNot: 位置・法線・色の交互の並びへ混ぜない — 番号は整数の属性で、float の並びに入れると骨の無い形まで stride が伸びる。
    pub type alias SkinBuffers = { joints = Int32, weights = Int32 }

    /// 描き先の中の design 領域（GL の左下原点の画素）と、design px → 画素の倍率。
    pub type alias Viewport = { x = Int32, y = Int32, width = Int32, height = Int32, scaleX = Float64, scaleY = Float64 }

    /// GL の左下原点の画素の矩形。
    pub type alias PixelBox = { x = Int32, y = Int32, width = Int32, height = Int32 }

    /// ビルボードが貼るテクスチャ。flipped = レンダーターゲット（行 0 が下）で、v を上下反転して読む。
    /// version = 中身の版（実行中に画素を差し替えた絵は字が変わる。3D の材質が段を作り直す合図）。
    pub type alias BillboardTexture = { texId = Int32, width = Float64, height = Float64, flipped = Bool, version = String }

    /// 場面 1 つと、Design の解像度で先に描いておいた描き先（Native なら None）と、先に描いておいた影の地図（無ければ None）と、
    /// 描き先が標本を持つか（multisampled = 真なら cutout の材質を alpha to coverage で描く）。
    pub type alias SceneItem = { cmd = Scene3d.RenderCmd, designTarget = Option[RenderTargetGl.Entry], shadow = Option[ShadowUse],
                                 multisampled = Bool }

    /// 3D の場面を描く描き先。framebuffer = 描き終えた後に戻す FBO（今開いているレンダーターゲットの描く FBO か画面）・
    /// format = その形式・samples = その標本の数（1 なら MSAA なし）。
    pub type alias Dest = { framebuffer = Int32, format = RenderTarget.Format, samples = Int32 }

    /// 塗りのシェーダーへ渡す影。tex = 影の地図（深度テクスチャ）・matrix = Scene3d.shadowMatrix（列優先 16 個）・
    /// spotIndex = pickLights の後のスポットの並びの何番目に掛けるか。
    pub type alias ShadowUse = {
        tex = Int32, matrix = Array[Float32, Static], bias = Float64, pcfRadius = Int32, strength = Float64, spotIndex = Int32
    }

    /// 影の地図の描き先 1 枚（深度テクスチャだけを付けた FBO）。size = 縦横の画素・lastUsed = 最後に描いたコマの世代。
    type alias ShadowTarget = { fbo = Int32, tex = Int32, size = Int32, lastUsed = Int64 }

    /// 影を落とすスポット（pickLights の後の並びで shadow が Some の最初の 1 本）。
    type alias ShadowCaster = { spot = Scene3d.SpotLight, shadowMap = Scene3d.ShadowMap, spotIndex = Int32 }

    /// 光の uniform の location（頂点の色のプログラムとビルボードのプログラムで同じ名前）。
    type alias LightLocs = {
        ambient = Int32, hemisphere = Int32, toonSteps = Int32,
        pointCount = Int32, pointPos = Int32, pointColor = Int32, pointRange = Int32,
        spotCount = Int32, spotPos = Int32, spotDir = Int32, spotColor = Int32, spotRange = Int32, spotCone = Int32,
        fogOn = Int32, fogColor = Int32, fogRange = Int32, eye = Int32
    }

    type alias MeshLocs = { program = Int32, model = Int32, view = Int32, proj = Int32, normal = Int32 }

    /// 影の uniform の location（頂点の色のプログラムと材質のプログラム。ビルボードは影を受けない）。
    type alias ShadowLocs = { on = Int32, spot = Int32, matrix = Int32, map = Int32, bias = Int32, pcf = Int32, strength = Int32 }

    type alias LitLocs = { mesh = MeshLocs, tint = Int32, light = LightLocs, shadow = ShadowLocs }

    /// 1 つの場面の目と光と影（置いた物を描くプログラムへ渡す物）。
    type alias CameraData = { view = Array[Float32, Static], proj = Array[Float32, Static], lights = LightData, shadow = Option[ShadowUse],
                              frustum = Frustum.Frustum }

    type alias DepthLocs = { mesh = MeshLocs, eye = Int32, depthRange = Int32 }

    type alias BillboardLocs = {
        program = Int32, view = Int32, proj = Int32, center = Int32, right = Int32, up = Int32,
        anchor = Int32, size = Int32, uvRect = Int32, tint = Int32, lit = Int32, facing = Int32,
        depthOut = Int32, depthRange = Int32, light = LightLocs
    }

    type alias Programs = { lit = LitLocs, depth = DepthLocs, billboard = BillboardLocs, blit = Int32, quadVao = Int32, quadVbo = Int32 }

    /// 空のプログラムの uniform の location。
    type alias SkyLocs = { program = Int32, viewport = Int32, forward = Int32, right = Int32, up = Int32,
                           zenith = Int32, horizon = Int32, ground = Int32, curve = Int32, depthOut = Int32 }

    /// 骨つきの版のプログラムと、joint 行列の UBO（std140 の mat4 × Skin3d.maxJoints()）と、その UBO へ最後に書いた中身。
    type alias SkinnedPrograms = { lit = LitLocs, depth = DepthLocs, jointsUbo = Int32, uploadedJoints = Ref[Array[Float32, Static], Static] }

    /// 置いた物 1 つと、描く時に曲げる Pose（Scene3d.skinningOf。None なら骨の無い版で曲げずに描く）。
    /// culled = 視錐台の外なので描かない（形と絵は今のコマで使った物として数え、GPU から捨てない）。
    type alias MeshDraw = { fields = Scene3d.InstanceFields, pose = Option[Pose3d.Pose3d], culled = Bool }

    /// 材質のプログラムの uniform の location。params = uParamN の location（paramNames の並び）・
    /// texFlips = uTexFlipN の location（texReads の並び）。
    type alias MaterialLocs = {
        mesh = MeshLocs, tint = Int32, light = LightLocs, shadow = ShadowLocs, time = Int32, cutout = Int32,
        depthOut = Int32, depthRange = Int32, params = List[Int32], texFlips = List[Int32],
        normalStrength = Int32, normalFlip = Int32, texLevels = List[Int32], normalLevels = Int32,
        lightmapLevels = Int32, lightmapSrgb = Int32, lightmapIntensity = Int32
    }

    /// 組んだ材質のプログラム 1 つ。spec と emission は組んだ時の物（次に来た材質と比べる）。
    /// paramNames = ShaderGen.compile3d が uParamN に割り当てた名前の並び・texReads = uTexN に貼る (名前, 補間) の並び
    /// （組んだ時の材質の名前。同じプログラムを名前だけ違う材質が使うので、貼る名前は描く材質から引き直す）。
    /// locs#mesh#program が 0 なら組めなかった。
    type alias MaterialEntry = {
        spec = ShaderDoc.Spec, emission = Option[ShaderDoc.Shade], paramNames = List[String],
        texReads = List[(String, ShaderDoc.FilterMode)], normalMapped = Bool, lightmapped = Bool, coverage = Bool, locs = MaterialLocs, lastUsed = Int64
    }

    /// 材質のある置いた物 1 つを描く材料（プログラムは組めた物だけ）。
    type alias MaterialDraw = { entry = MaterialEntry, material = Scene3d.MaterialFields, draw = MeshDraw }

    /// 材質の Tex の名前を絵に引く元。textureOf = 全体の登録（project.json・レンダーターゲット）・
    /// own = 場面の textures（Texture3d.name → 絵）。
    type alias TextureSource = { textureOf = String -> Option[BillboardTexture] \ IO, own = Map[String, Texture3d.Texture3d] }

    /// GPU に上げた場面の絵 1 枚（Texture3d の contentHash で引く）。levels = 段の数・bytes = 段を合わせた置き場の大きさ・
    /// lastUsed = 最後に貼ったコマの世代。
    type alias Texture3dEntry = { texId = Int32, levels = Int32, bytes = Int64, lastUsed = Int64 }

    /// 全体の登録の絵を 3D の材質のために段つきで上げ直した写し。sourceId と version が元の絵と食い違えば作り直す。
    // WhyNot: 元のテクスチャに段を足さない — 2D の sprite と面は段の無い元の絵を読む決まりで、そちらの絵を変えない。
    type alias MipCopy = { sourceId = Int32, version = String, texId = Int32, levels = Int32, lastUsed = Int64 }

    /// 材質の 1 枚を貼る材料。levels = 段の数（1 なら段の無い sampler で段 0 を読む）。
    type alias BoundTexture = { texId = Int32, flipped = Bool, levels = Int32 }

    /// 材質のプログラムを何のために使うか。Color = 光を当てた色・Depth = cutout で抜いた奥行きの灰色。
    enum MaterialPass {
        case Color
        case Depth({ near = Float64, range = Float64 })
    }

    /// 1 つの場面の光を uniform へ渡す形にした物（点光源・スポットは Scene3d.pickLights で選んだ後）。
    type alias LightData = {
        ambient = Array[Float32, Static], hemisphere = Float32, toonSteps = Int32,
        pointCount = Int32, pointPos = Array[Float32, Static], pointColor = Array[Float32, Static], pointRange = Array[Float32, Static],
        spotCount = Int32, spotPos = Array[Float32, Static], spotDir = Array[Float32, Static], spotColor = Array[Float32, Static],
        spotRange = Array[Float32, Static], spotCone = Array[Float32, Static],
        fogOn = Int32, fogColor = Array[Float32, Static], fogRange = Array[Float32, Static], eye = Array[Float32, Static]
    }

    /// 3D の描き手の状態（GL の文脈ごとに 1 つ）。meshesRef = contentHash → GPU に置いたメッシュ。
    pub type alias State = {
        meshesRef = Ref[Map[String, MeshEntry], Static],
        // 場面の絵を GPU に持つ量の上限（バイト）。
        textureByteBudget = Int64,
        // 場面の絵の置き場の枚数の上限（project.json の scene3dTextureBudgetCount）。
        textureCountBudget = Int32,
        // 置き場の頂点の合計。
        vertexTotal = Array[Int32, Static],
        // [新しい鍵を上げたコマが続いた数, 知らせ済みなら 1, このコマで新しい鍵を上げたら 1]。
        uploadStreak = Array[Int32, Static],
        // uploadStreak と同じ形の、材質のプログラムを新しく組んだコマの続き。
        materialStreak = Array[Int32, Static],
        // 初めての場面で組む（3D を使わないゲームは GLSL のコンパイルを払わない）。
        programsRef = Ref[Option[Programs], Static],
        // 骨つきの物を初めて描く時に組む（ジョイントを使わない場面は骨つきの版のコンパイルを払わない）。
        skinnedRef = Ref[Option[SkinnedPrograms], Static],
        // 空を初めて描く時に組む（空を使わない場面は空のプログラムのコンパイルを払わない）。
        skyRef = Ref[Option[SkyLocs], Static],
        // ジョイントの数の食い違いを知らせた形（contentHash）。
        skinWarnedRef = Ref[Set[String], Static],
        // Design の解像度の描き先（そのコマの Design の場面の並びの番号 → FBO。大きさが同じなら使い回す）。
        designTargetsRef = Ref[Map[(Int32, String), RenderTargetGl.Entry], Static],
        // 見つからないと知らせたビルボードのテクスチャの名前。
        missingTexturesRef = Ref[Set[String], Static],
        // "3d:" + spec の名前 → 材質のプログラム（2D の Shader 面のキャッシュとは分ける）。
        materialsRef = Ref[Map[String, MaterialEntry], Static],
        // 鍵から外れた材質のプログラム。同じコマの先の物がまだ使うので、endFrame で消す。
        retiredMaterialsRef = Ref[List[Int32], Static],
        // 同じコマで中身の違う材質が同じ名前で来たと知らせた鍵。
        thrashWarnedRef = Ref[Set[String], Static],
        // 材質の uTime（秒）。prepareScenes が毎回置く。
        timeHolder = Array[Float64, Static],
        // 作った時の System.nanoTime（elapsedSeconds のものさし）。
        createdAt = Int64,
        // 影の地図の描き先（(mapSize, 同じ prepareScenes の中で同じ mapSize の何枚目か) → FBO）。
        shadowTargetsRef = Ref[Map[(Int32, Int32), ShadowTarget], Static],
        // 影について知らせ済みの種類（同じ知らせを毎コマ出さない）。
        shadowWarnedRef = Ref[Set[String], Static],
        // 場面の絵（Texture3d の contentHash → GPU のテクスチャ）。
        textures3dRef = Ref[Map[String, Texture3dEntry], Static],
        // 材質の絵の sampler（[Repeat Nearest, Repeat Linear, Clamp Nearest, Clamp Linear] の段なし 4 つ・段つき 4 つ。0 は未作成）。
        materialSamplers = Array[Int32, Static],
        // 全体の登録の絵の段つきの写し（絵の名前 → 写し）。
        mipCopiesRef = Ref[Map[String, MipCopy], Static],
        // 見つからない材質の絵に貼る 1 × 1 の透明な黒（0 は未作成）。
        blankTexture = Array[Int32, Static],
        // 場面について知らせ済みの鍵（見つからない絵・上限を超えた材質と光・場面の絵の置き場あふれ・空・lightmap・uv の無い法線マップ）。
        sceneWarnedRef = Ref[Set[String], Static],
        // 前に takeCounts してからの数（[置いた物, 描いた物, draw call, 落とした点光源, 落としたスポット]。FrameDiagnostics.Diagnostics.scene3dCounts の元）。
        countsHolder = Array[Int32, Static]
    }

    // ── 決まりの数 ──

    /// この数のコマ使われなかったメッシュは GPU から捨てる。
    def meshIdleFrames(): Int64 = 128i64

    /// 置き場の頂点の合計の上限。超えたら古い物から捨てる。
    def vertexBudget(): Int32 = 4000000

    /// 新しい形か材質のプログラムがこの数のコマ続けて作られたら、毎コマ作り直していると知らせる。
    def rebuildStreakLimit(): Int32 = 30

    /// 影の地図を貼るテクスチャの unit（2D の Shader 面は 0 から順に使い、描いた後に unit 0 へ戻す）。
    def shadowTextureUnit(): Int32 = 7

    /// 材質の法線マップを貼るテクスチャの unit（材質の絵は 0〜5）。
    def normalMapTextureUnit(): Int32 = 6

    /// ベイクした光（lightmap）を貼るテクスチャの unit（0〜5 は材質の絵・6 は法線マップ・7 は影の地図）。
    def lightmapTextureUnit(): Int32 = 8

    /// joint 行列の UBO を付ける binding の番号（GL の文脈で他に UBO を使う所は無い）。
    def jointsBinding(): Int32 = 1


    def maxShadowMapSize(): Int32 = Scene3d.maxShadowMapSize()

    def maxShadowPcfRadius(): Int32 = Scene3d.maxShadowPcfRadius()

    /// 場面の絵の置き場の上限。megabytes = GPU に持つ量（MB。project.json の scene3dTextureBudgetMB）・
    /// count = 枚数（scene3dTextureBudgetCount）。超えたら今と前のコマで使っていない古い物から捨てる。
    pub type alias TextureBudget = { megabytes = Int32, count = Int32 }

    /// EngineConfig（project.json）の 2 つのキーから場面の絵の置き場の上限を組む。
    pub def textureBudgetOf(config: GameEngine.EngineConfig): TextureBudget =
        { megabytes = config#scene3dTextureBudgetMB, count = config#scene3dTextureBudgetCount }

    /// 3D の描き手を、空の置き場で作る（textureBudget = 場面の絵の置き場の上限）。
    pub def fresh(textureBudget: TextureBudget): State \ IO =
        { textureByteBudget = Int32.toInt64(Int32.max(1, textureBudget#megabytes)) * 1048576i64,
          textureCountBudget = Int32.max(1, textureBudget#count), meshesRef = Ref.fresh(Static, Map.empty()), vertexTotal = Array#{0} @ Static,
          uploadStreak = Array#{0, 0, 0} @ Static, materialStreak = Array#{0, 0, 0} @ Static, programsRef = Ref.fresh(Static, None),
          skinnedRef = Ref.fresh(Static, None), skyRef = Ref.fresh(Static, None), skinWarnedRef = Ref.fresh(Static, Set.empty()),
          designTargetsRef = Ref.fresh(Static, Map.empty()), missingTexturesRef = Ref.fresh(Static, Set.empty()),
          materialsRef = Ref.fresh(Static, Map.empty()), retiredMaterialsRef = Ref.fresh(Static, Nil),
          thrashWarnedRef = Ref.fresh(Static, Set.empty()), timeHolder = Array#{0.0} @ Static,
          createdAt = System.nanoTime(), shadowTargetsRef = Ref.fresh(Static, Map.empty()),
          shadowWarnedRef = Ref.fresh(Static, Set.empty()), textures3dRef = Ref.fresh(Static, Map.empty()),
          materialSamplers = Array#{0, 0, 0, 0, 0, 0, 0, 0} @ Static, mipCopiesRef = Ref.fresh(Static, Map.empty()),
          blankTexture = Array#{0} @ Static,
          sceneWarnedRef = Ref.fresh(Static, Set.empty()), countsHolder = Array#{0, 0, 0, 0, 0} @ Static }

    /// 前に呼んでからの 3D の数（置いた物・描いた物・draw call・落とした点光源とスポット）を返し、0 に戻す。
    pub def takeCounts(state: State): FrameDiagnostics.Scene3dCounts \ IO =
        let h = state#countsHolder;
        let counts = { instances = Array.get(0, h), drawn = Array.get(1, h), drawCalls = Array.get(2, h),
                       droppedPointLights = Array.get(3, h), droppedSpotLights = Array.get(4, h) };
        List.range(0, Array.length(h)) |> List.forEach(i -> Array.put(0, i, h));
        counts

    /// 場面の置いた物 placed 個と、そのうち視錐台の外で間引かずに描いた drawn 個を数える。
    def countInstances(state: State, placed: Int32, drawn: Int32): Unit \ IO =
        let h = state#countsHolder;
        Array.put(Array.get(0, h) + placed, 0, h);
        Array.put(Array.get(1, h) + drawn, 1, h)

    /// 場面 1 つで上限を超えて落とした光を数え、種類ごとに初めての時だけ知らせる。
    def noteDroppedLights(state: State, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let d = Scene3d.droppedLightsOf(scene);
        let h = state#countsHolder;
        Array.put(Array.get(3, h) + d#points, 3, h);
        Array.put(Array.get(4, h) + d#spots, 4, h);
        Scene3d.droppedLightsWarnings(scene) |> List.forEach(kl -> warnSceneOnce(state, fst(kl), snd(kl)))

    /// 3D の draw call を 1 つ数える。
    def countDrawCall(state: State): Unit \ IO =
        Array.put(Array.get(2, state#countsHolder) + 1, 2, state#countsHolder)

    /// 描き手を作ってからの実時間（秒）。
    pub def elapsedSeconds(state: State): Float64 \ IO =
        Int64.toFloat64(System.nanoTime() - state#createdAt) / 1.0e9

    // ── 場面を描く（2D の並びの中から）──

    /// Design の解像度の場面を、そのテクスチャへ先に描いておく（2D の並びを描き始める前に呼ぶ）。
    /// dest#framebuffer = 描き終えた後に戻す描き先（今開いているレンダーターゲットか画面）・dest#format = その形式
    /// （Design の中継の描き先も同じ形式で作る — HDR の Pass の中で、中継だけ 0..1 に切られないように）。
    // WhyNot: 2D の並びの途中で FBO を替えて描かない — タイル型の GPU で描き先の出し入れが重く、viewport と scissor の戻し漏れも増える。
    pub def prepareScenes(state: State, gen: Int64, textureOf: String -> Option[BillboardTexture] \ IO,
                          dest: Dest, cmds: List[Scene3d.RenderCmd]): List[SceneItem] \ IO =
        if (List.isEmpty(cmds)) Nil
        else {
            // 影の地図は Design の場面より先に描く — Design の場面の塗りがその地図を読む。
            let shadows = renderShadows(state, gen, cmds);
            let designCount = Array#{0} @ Static;
            let items = List.zip(cmds, shadows) |> List.map(cs -> {
                let (cmd, shadow) = cs;
                match cmd#scene#resolution {
                    case Scene3d.Resolution.Native => { cmd = cmd, designTarget = None, shadow = shadow, multisampled = dest#samples > 1 }
                    case Scene3d.Resolution.Design =>
                        let index = Array.get(0, designCount);
                        Array.put(index + 1, 0, designCount);
                        // WhyNot: Design の解像度の描き先に標本を持たせない — ドット絵と画素をそろえる場面に縁のならしは要らない。
                        { cmd = cmd, designTarget = renderDesign(state, gen, textureOf, (index, dest#format), shadow, cmd), shadow = shadow,
                          multisampled = false }
                }
            });
            let movedTarget = Array.get(0, designCount) > 0 or List.exists(Option.nonEmpty, shadows);
            if (movedTarget) GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, dest#framebuffer) else ();
            items
        }

    /// 場面 1 つを 2D の並びの中で描く。描き終えたら viewport を vp へ、scissor を切り、blend を Normal へ戻す。
    pub def drawItem(state: State, gen: Int64, textureOf: String -> Option[BillboardTexture] \ IO,
                     vp: Viewport, item: SceneItem): Unit \ IO =
        let scene = item#cmd#scene;
        let rect = sceneRect(vp, item#cmd);
        let scissor = clipBox(vp, rect, item#cmd#clip);
        if (rect#width <= 0 or rect#height <= 0 or scissor#width <= 0 or scissor#height <= 0) ()
        else match item#designTarget {
            case None         => drawScene(state, gen, textureOf, { viewport = rect, scissor = scissor, fillBackground = true, coverage = item#multisampled },
                                           item#shadow, scene)
            case Some(target) => blitDesign(state, rect, scissor, target)
        };
        GL11.glViewport(vp#x, vp#y, vp#width, vp#height);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glEnable(GL11.GL_BLEND);
        RenderSprite.applyBlend(DrawCmd.BlendMode.Normal)

    /// 場面の矩形（at・size）を描き先の画素へ写す（量子化は 2D の clip と同じ DrawCmd.clipPixels）。
    def sceneRect(vp: Viewport, cmd: Scene3d.RenderCmd): PixelBox =
        let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = vp#scaleX, scaleY = vp#scaleY },
                                                  { position = cmd#at, size = cmd#scene#size });
        { x = vp#x + x0, y = vp#y + vp#height - y1, width = x1 - x0, height = y1 - y0 }

    /// scissor = 場面の矩形 ∩ clip ∩ design 領域（clip が外へはみ出しても黒帯を侵さない）。
    def clipBox(vp: Viewport, rect: PixelBox, clip: Option[Rect2.Rect2]): PixelBox =
        let area = { x = vp#x, y = vp#y, width = vp#width, height = vp#height };
        let base = intersect(rect, area);
        match clip {
            case None    => base
            case Some(c) =>
                let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = vp#scaleX, scaleY = vp#scaleY }, c);
                intersect(base, { x = vp#x + x0, y = vp#y + vp#height - y1, width = x1 - x0, height = y1 - y0 })
        }

    def intersect(a: PixelBox, b: PixelBox): PixelBox =
        let x0 = Int32.max(a#x, b#x);
        let y0 = Int32.max(a#y, b#y);
        let x1 = Int32.min(a#x + a#width, b#x + b#width);
        let y1 = Int32.min(a#y + a#height, b#y + b#height);
        { x = x0, y = y0, width = Int32.max(0, x1 - x0), height = Int32.max(0, y1 - y0) }

    // ── Design の解像度 ──

    /// Design の場面を design px の FBO に透明から描く。大きさが 0 なら None。
    def renderDesign(state: State, gen: Int64, textureOf: String -> Option[BillboardTexture] \ IO,
                     slot: (Int32, RenderTarget.Format), shadow: Option[ShadowUse], cmd: Scene3d.RenderCmd): Option[RenderTargetGl.Entry] \ IO =
        let w = Num.floorInt(cmd#scene#size#x + 0.5);
        let h = Num.floorInt(cmd#scene#size#y + 0.5);
        if (w <= 0 or h <= 0) None
        else {
            let target = designTarget(state, slot, w, h);
            RenderTargetGl.bind(target);
            let full = { x = 0, y = 0, width = w, height = h };
            GL11.glViewport(0, 0, w, h);
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            GL11.glClearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);
            drawScene(state, gen, textureOf, { viewport = full, scissor = full, fillBackground = true, coverage = false }, shadow, cmd#scene);
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            Some(target)
        }

    /// (番号, 形式) の Design の描き先。大きさが変わったら作り直し、古い方は捨てる。
    /// WhyNot: 鍵を番号だけにしない — 画面（Rgba8Unorm）と HDR の Pass で同じ番号の場面を描くと、コマごとに作り直しが続く。
    /// 鍵の形式は Format の名前（Map の鍵には Order が要り、Format は Eq と ToString だけを持つ）。
    def designTarget(state: State, slot: (Int32, RenderTarget.Format), w: Int32, h: Int32): RenderTargetGl.Entry \ IO =
        let (index, format) = slot;
        let key = (index, ToString.toString(format));
        let targets = Ref.get(state#designTargetsRef);
        match Map.get(key, targets) {
            case Some(e) if e#width == w and e#height == h => e
            case old =>
                Option.forEach(RenderTargetGl.destroy, old);
                let made = RenderTargetGl.create(w, h, format);
                Ref.put(Map.insert(key, made, targets), state#designTargetsRef);
                made
        }

    /// Design の FBO のテクスチャを、場面の矩形へ最も近い画素で α で重ねる。FBO の色は α を掛けた後の値として重ねる
    /// （GL_ONE, GL_ONE_MINUS_SRC_ALPHA）: 透明から描いた FBO に半透明を重ねると、色は src × α・α は α になるため。
    /// 半透明の無い場面の FBO の画素は α が 0（色も 0）か 1 なので、Normal で重ねた時と 1 bit も同じ。
    def blitDesign(state: State, rect: PixelBox, scissor: PixelBox, target: RenderTargetGl.Entry): Unit \ IO =
        let programs = programsOf(state);
        if (programs#blit == 0) ()
        else {
            GL11.glViewport(rect#x, rect#y, rect#width, rect#height);
            GL11.glEnable(GL11.GL_SCISSOR_TEST);
            GL11.glScissor(scissor#x, scissor#y, scissor#width, scissor#height);
            GL11.glEnable(GL11.GL_BLEND);
            GL11.glBlendFunc(GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA);
            GL20.glUseProgram(programs#blit);
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, target#tex);
            GL30.glBindVertexArray(programs#quadVao);
            GL20.glUniform1i(GL20.glGetUniformLocation(programs#blit, "uImage"), 0);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 6);
            GL30.glBindVertexArray(0);
            GL20.glUseProgram(0)
        }

    // ── 影の地図（§5.6）──

    /// 場面ごとに、影を落とすスポットがあれば影の地図を描き、塗りへ渡す物を返す（cmds と同じ並び）。
    /// 描き終えたら深度と scissor を切り、program と VAO を外す。描き先は呼ぶ側が戻す。
    // WhyNot: viewport をここで戻さない — glGet で前の値を読まない決まり（§5.2）で、この後に描く Design の場面と
    //   2D の並び（RenderFrame.renderFrameMixed）が、どちらも描き始めに自分の viewport を置く。
    def renderShadows(state: State, gen: Int64, cmds: List[Scene3d.RenderCmd]): List[Option[ShadowUse]] \ IO =
        let usedPerSize = Ref.fresh(Static, (Map.empty(): Map[Int32, Int32]));
        let shadows = cmds |> List.map(cmd -> shadowCasterOf(state, cmd#scene) |> Option.map(caster -> {
            let size = shadowMapSizeOf(state, caster#shadowMap);
            // 同じ mapSize の場面が 1 コマに 2 つあっても地図を分ける — 塗るのは全部の地図を描き終えた後。
            let ordinal = Map.getWithDefault(size, 0, Ref.get(usedPerSize));
            Ref.put(Map.insert(size, ordinal + 1, Ref.get(usedPerSize)), usedPerSize);
            let target = shadowTarget(state, gen, size, ordinal);
            renderShadowMap(state, gen, target, caster, cmd#scene);
            shadowUseOf(state, target, caster)
        }));
        if (List.exists(Option.nonEmpty, shadows)) endShadowPass() else ();
        shadows

    /// 影を落とすスポット。Output.Depth の場面と、置いた物の無い場面は None。
    /// mapSize が 0 以下の shadow は無い物として扱う。2 本目以降の shadow は使わない（1 回知らせる）。
    def shadowCasterOf(state: State, scene: Scene3d.Scene3dCmd): Option[ShadowCaster] \ IO =
        match scene#output {
            case Scene3d.Output.Depth(_) => None
            case Scene3d.Output.Color if List.isEmpty(scene#instances) => None
            case Scene3d.Output.Color =>
                let casters = Scene3d.pickLights(scene#camera#eye, scene)#spotLights
                    |> List.mapWithIndex((i, spot) -> spot#shadow |> Option.filter(m -> m#mapSize > 0) |> Option.map(m -> { spot = spot, shadowMap = m, spotIndex = i }))
                    |> List.filterMap(identity);
                if (List.length(casters) > 1)
                    warnShadowOnce(state, "second", "scene3d: 影を落とすスポットが 1 つの場面に 2 本以上ある — 最初の 1 本だけが影を落とす")
                else ();
                List.head(casters)
        }

    def shadowMapSizeOf(state: State, m: Scene3d.ShadowMap): Int32 \ IO =
        if (m#mapSize > maxShadowMapSize()) {
            warnShadowOnce(state, "size", "scene3d: 影の地図の mapSize ${m#mapSize} は大きすぎる — ${maxShadowMapSize()} で描く");
            maxShadowMapSize()
        } else m#mapSize

    /// 大きさ size の ordinal 枚目の影の描き先（無ければ作る）。lastUsed を今の世代にする。
    def shadowTarget(state: State, gen: Int64, size: Int32, ordinal: Int32): ShadowTarget \ IO =
        let targets = Ref.get(state#shadowTargetsRef);
        let target = match Map.get((size, ordinal), targets) {
            case Some(found) => { lastUsed = gen | found }
            case None        => createShadowTarget(gen, size)
        };
        Ref.put(Map.insert((size, ordinal), target, targets), state#shadowTargetsRef);
        target

    /// 深度テクスチャだけを付けた FBO を作る（作った FBO を bind したまま返す）。
    // WhyNot: 深度を renderbuffer にしない — 塗りのシェーダーが標本として読む。
    // WhyNot: 比べを sampler2DShadow（GL_COMPARE_REF_TO_TEXTURE）に任せない — 比べ方と周りの数え方を CPU の描き手とそろえる。
    def createShadowTarget(gen: Int64, size: Int32): ShadowTarget \ IO =
        // 作る間の bind で unit 0（sprite・font が共用する）の中身を替えない。
        GL13.glActiveTexture(GL13.GL_TEXTURE0 + shadowTextureUnit());
        let tex = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL14.GL_DEPTH_COMPONENT24, size, size, 0,
                          GL11.GL_DEPTH_COMPONENT, GL11.GL_FLOAT, 0i64);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_S, GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_T, GL12.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL14.GL_TEXTURE_COMPARE_MODE, GL11.GL_NONE);
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, 0);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
        let fbo = GL30.glGenFramebuffers();
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, fbo);
        GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_DEPTH_ATTACHMENT, GL11.GL_TEXTURE_2D, tex, 0);
        GL11.glDrawBuffer(GL11.GL_NONE);
        GL11.glReadBuffer(GL11.GL_NONE);
        checkShadowFramebuffer(size);
        { fbo = fbo, tex = tex, size = size, lastUsed = gen }

    def checkShadowFramebuffer(size: Int32): Unit \ IO =
        let status = GL30.glCheckFramebufferStatus(GL30.GL_FRAMEBUFFER);
        if (status != GL30.GL_FRAMEBUFFER_COMPLETE)
            Log.warn("scene3d: 影の地図の FBO (${size}×${size}) が完成しない status=${status} — 影が正しく出ない")
        else ()

    /// 影の地図を描く: 光から見た置いた物の一番近い面の深度。ビルボードは影を落とさない。
    def renderShadowMap(state: State, gen: Int64, target: ShadowTarget, caster: ShadowCaster, scene: Scene3d.Scene3dCmd): Unit \ IO =
        let locs = programsOf(state)#depth;
        GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, target#fbo);
        GL11.glViewport(0, 0, target#size, target#size);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL11.glDepthMask(true);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_DEPTH_BUFFER_BIT);
        if (locs#mesh#program == 0) ()
        else {
            GL11.glEnable(GL11.GL_DEPTH_TEST);
            GL11.glDepthFunc(GL11.GL_LESS);
            // WhyNot: 背面を捨てない — 厚みの無い板を裏から照らすと面が全部捨てられ、影が抜ける。
            GL11.glDisable(GL11.GL_CULL_FACE);
            // WhyNot: 深度だけのプログラムを影のために別に組まない — 色の出力は描き先が無いので捨てられる。
            let lightView = matrixArray(Scene3d.shadowMatrix(caster#spot));
            let identity = matrixArray(Mat4.identity());
            let outside = Scene3d.isOutsideFrustum(Scene3d.shadowFrustumOf(caster#spot));
            // WhyNot: 半透明の物に影を落とさせない — 影の地図は 0 か 1 の奥行きで、薄い色ガラスが真っ黒な影を落とす。
            let (skinned, plain) = scene#instances |> List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)))
                |> List.map(meshDrawOf(state, outside)) |> List.partition(isSkinned);
            useMeshProgram(locs#mesh, lightView, identity);
            plain |> List.forEach(drawPosedMesh(state, gen, locs#mesh));
            // 骨つきの物は曲がった形で影を落とす（深度だけの骨つきの版を Output.Depth と共用）。
            if (List.isEmpty(skinned)) ()
            else {
                let skinnedDepth = skinnedProgramsOf(state)#depth;
                if (skinnedDepth#mesh#program == 0) ()
                else {
                    useMeshProgram(skinnedDepth#mesh, lightView, identity);
                    skinned |> List.forEach(drawPosedMesh(state, gen, skinnedDepth#mesh))
                }
            }
        }

    def endShadowPass(): Unit \ IO =
        GL11.glDisable(GL11.GL_DEPTH_TEST);
        GL11.glDisable(GL11.GL_CULL_FACE);
        GL11.glDepthMask(true);
        GL11.glDisable(GL11.GL_SCISSOR_TEST);
        GL20.glUseProgram(0);
        GL30.glBindVertexArray(0)

    def shadowUseOf(state: State, target: ShadowTarget, caster: ShadowCaster): ShadowUse \ IO =
        let r = caster#shadowMap#pcfRadius;
        let radius = if (r > maxShadowPcfRadius()) {
            warnShadowOnce(state, "pcf", "scene3d: 影の pcfRadius ${r} は大きすぎる — ${maxShadowPcfRadius()} で数える");
            maxShadowPcfRadius()
        } else Int32.max(0, r);
        { tex = target#tex, matrix = matrixArray(Scene3d.shadowMatrix(caster#spot)), bias = caster#shadowMap#bias,
          pcfRadius = radius, strength = caster#shadowMap#strength, spotIndex = caster#spotIndex }

    def warnShadowOnce(state: State, kind: String, message: String): Unit \ IO =
        let warned = Ref.get(state#shadowWarnedRef);
        if (Set.memberOf(kind, warned)) ()
        else {
            Ref.put(Set.insert(kind, warned), state#shadowWarnedRef);
            Log.warn(message)
        }

    /// 塗りの間だけ影の地図を影の unit に貼る（unit 0 へ戻して返す）。None なら何もしない。
    def bindShadowMap(shadow: Option[ShadowUse]): Unit \ IO =
        shadow |> Option.forEach(s -> {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + shadowTextureUnit());
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, s#tex);
            GL13.glActiveTexture(GL13.GL_TEXTURE0)
        })

    /// 影の地図を外す — 次のコマに同じテクスチャを描き先に付けた時、貼ったままだと読み書きが重なる。
    def unbindShadowMap(shadow: Option[ShadowUse]): Unit \ IO =
        shadow |> Option.forEach(_ -> {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + shadowTextureUnit());
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, 0);
            GL13.glActiveTexture(GL13.GL_TEXTURE0)
        })

    def putShadow(locs: ShadowLocs, shadow: Option[ShadowUse]): Unit \ IO =
        match shadow {
            // プログラムは場面どうしで共有するので、影の無い場面でも毎回切る（前の場面の影が残る）。
            case None    => GL20.glUniform1i(locs#on, 0)
            case Some(s) =>
                GL20.glUniform1i(locs#on, 1);
                GL20.glUniform1i(locs#spot, s#spotIndex);
                GL20.glUniformMatrix4fv(locs#matrix, false, s#matrix);
                GL20.glUniform1i(locs#map, shadowTextureUnit());
                GL20.glUniform1f(locs#bias, RenderUtil.f32(s#bias));
                GL20.glUniform1i(locs#pcf, s#pcfRadius);
                GL20.glUniform1f(locs#strength, RenderUtil.f32(s#strength))
        }

    /// 使われない影の描き先を捨てる（画面のコマの終わりに 1 回）。
    def sweepShadowTargets(state: State, gen: Int64): Unit \ IO =
        let targets = Ref.get(state#shadowTargetsRef);
        let idle = Map.filter(t -> gen - t#lastUsed > meshIdleFrames(), targets);
        if (Map.isEmpty(idle)) ()
        else {
            Map.forEach((_key, t) -> {
                GL30.glDeleteFramebuffers(t#fbo);
                GL11.glDeleteTextures(t#tex)
            }, idle);
            Ref.put(Map.difference(targets, idle), state#shadowTargetsRef)
        }

    // ── 1 つの場面（§5.2 の手順）──

    /// 場面 1 つを、今 bind されている描き先の area へ描く。描き終えたら深度・カリングを切り、blend・program・VAO を戻す。
    /// viewport と scissor は呼ぶ側が戻す。stencil には触らない（mask 付きの Shader 面が使う）。
    def drawScene(state: State, gen: Int64, textureOf: String -> Option[BillboardTexture] \ IO,
                  area: { viewport = PixelBox, scissor = PixelBox, fillBackground = Bool, coverage = Bool }, shadow: Option[ShadowUse],
                  scene: Scene3d.Scene3dCmd): Unit \ IO =
        Array.put(scene#time, 0, state#timeHolder);
        let frustum = Scene3d.frustumOf(scene);
        let outside = Scene3d.isOutsideFrustum(frustum);
        let programs = programsOf(state);
        let background = if (area#fillBackground and Option.isEmpty(scene#sky)) scene#environment#background else None;
        beginScene(area#viewport, area#scissor, background);
        if (area#fillBackground) drawSky(state, area#viewport, scene) else ();
        let picked = Scene3d.pickLights(scene#camera#eye, scene);
        noteDroppedLights(state, scene);
        let lights = lightDataOf(picked);
        let view = matrixArray(Camera3d.viewMatrix(scene#camera));
        let proj = matrixArray(Camera3d.projectionMatrix(scene#camera, Scene3d.aspectOf(scene)));
        let camera = { view = view, proj = proj, lights = lights, shadow = shadow, frustum = frustum };
        let source = { textureOf = textureOf, own = scene#textures |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap };
        match scene#output {
            case Scene3d.Output.Color =>
                let (plain, materials) = splitByMaterial(state, gen, outside, _ -> true, area#coverage, scene#instances);
                noteCulled(state, gen, source, List.length(scene#instances), plain, materials);
                let (blended, solid) = List.partition(d -> d#material#blend, materials);
                bindShadowMap(shadow);
                drawInstancesLit(state, gen, programs#lit, camera, plain);
                // WhyNot: 不透明の材質をプログラムの番号で並べたまま描く順を保つ — 深度で前後が決まるので順は絵を変えない（同じ深さの面だけが並びで決まる）。
                drawMaterials(state, gen, camera, MaterialPass.Color, source, solid |> List.sortBy(d -> d#entry#locs#mesh#program));
                drawBillboards(state, textureOf, programs#billboard, camera, scene);
                drawBlended(state, gen, camera, source, scene#camera#eye, blended);
                unbindShadowMap(shadow)
            case Scene3d.Output.Depth(dr) =>
                // WhyNot: cutout でも両面でもない材質に材質のプログラムを組まない — 奥行きは形だけで決まり、色の計算は捨てられる
                //   （両面の物は材質の道でカリングを切る。頂点の色の道へ回すと裏の面が捨てられ、CPU の奥行きと食い違う）。
                // WhyNot: 半透明の物を描かない — 奥行きを書くと、ピントの Pass がガラスの手前に合う。
                let solidInstances = List.filter(i -> not Scene3d.isBlendedFields(Scene3d.instanceFieldsOf(i)), scene#instances);
                let (plain, cutouts) = splitByMaterial(state, gen, outside, m -> m#cutout or m#doubleSided, false, solidInstances);
                noteCulled(state, gen, source, List.length(scene#instances), plain, cutouts);
                drawInstancesDepth(state, gen, programs#depth, camera, scene#camera#eye, dr, plain);
                drawMaterials(state, gen, camera, MaterialPass.Depth(dr), source, cutouts |> List.sortBy(d -> d#entry#locs#mesh#program));
                drawBillboards(state, textureOf, programs#billboard, camera, scene)
        };
        endScene()

    /// 半透明の材質の物を Scene3d.blendOrderOf の順（遠い物から）に、深度を読むが書かずに重ねる。無ければ何もしない。
    def drawBlended(state: State, gen: Int64, camera: CameraData, source: TextureSource, eye: Vec3.Vec3, draws: List[MaterialDraw]): Unit \ IO =
        if (List.isEmpty(draws)) ()
        else {
            GL11.glDepthMask(false);
            GL11.glEnable(GL11.GL_BLEND);
            GL14.glBlendFuncSeparate(GL11.GL_SRC_ALPHA, GL11.GL_ONE_MINUS_SRC_ALPHA, GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA);
            drawMaterials(state, gen, camera, MaterialPass.Color, source, Scene3d.blendOrderOf(eye, d -> d#draw#fields, draws));
            GL11.glDisable(GL11.GL_BLEND);
            GL11.glDepthMask(true)
        }

    /// 視錐台の外で間引いた材質の物の絵を、今のコマで使った物として置き場に数え（上げていなければ上げる）、置いた物と描いた物の数を足す。
    /// 描き始める前に済ませ、unit 0 へ戻す（初めての絵を上げる時に今の unit へ貼るので、描いている途中では呼ばない）。
    /// 間引いた物の形は drawPosedMesh が置き場に数える（描く段で culled の物も通す）。
    // WhyNot: 間引いた物を置き場で古いままにしない — 振り向くたびに形と絵を上げ直して止まり、毎コマ作り直しの知らせも鳴る。
    def noteCulled(state: State, gen: Int64, source: TextureSource, total: Int32,
                   plain: List[MeshDraw], materials: List[MaterialDraw]): Unit \ IO =
        let culledMaterials = List.filter(d -> d#draw#culled, materials);
        culledMaterials |> List.forEach(d ->
            materialTextureNames(d) |> List.forEach(lt -> discard resolveTextureAs(state, gen, source, fst(lt), snd(lt))));
        if (List.isEmpty(culledMaterials)) () else GL13.glActiveTexture(GL13.GL_TEXTURE0);
        countInstances(state, total, List.count(d -> not d#culled, plain) + List.count(d -> not d#draw#culled, materials))

    /// 材質のある物 d を描く時に貼る絵の (知らせの中の呼び名, 名前)（材質の絵・法線マップ・lightmap。描く時の知らせと同じ呼び名）。
    def materialTextureNames(d: MaterialDraw): List[(String, String)] =
        let reads = if (List.isEmpty(d#entry#texReads)) Nil
                    else ShaderDoc.materialTexReads(d#material#spec, d#material#emission) |> List.take(Scene3d.maxMaterialTextures())
                        |> List.map(nf -> ("材質の絵", fst(nf)));
        let normal = if (d#entry#normalMapped) d#material#normalMap |> Option.toList |> List.map(n -> ("材質の絵", n#texture)) else Nil;
        let baked = if (d#entry#lightmapped) Scene3d.lightmapOfFields(d#draw#fields) |> Option.toList |> List.map(lm -> ("lightmap の絵", lm#texture)) else Nil;
        List.flatten(reads :: normal :: baked :: Nil)

    /// 深度を使い始める: viewport と scissor を合わせ、地の色と深度を scissor の中だけ消し、深度とカリングを有効にする。
    def beginScene(viewport: PixelBox, scissor: PixelBox, background: Option[Color]): Unit \ IO =
        GL11.glViewport(viewport#x, viewport#y, viewport#width, viewport#height);
        GL11.glEnable(GL11.GL_SCISSOR_TEST);
        GL11.glScissor(scissor#x, scissor#y, scissor#width, scissor#height);
        background |> Option.forEach(c -> {
            GL11.glClearColor(RenderUtil.f32(c#r), RenderUtil.f32(c#g), RenderUtil.f32(c#b), 1.0f32);
            GL11.glClear(GL11.GL_COLOR_BUFFER_BIT)
        });
        GL11.glDepthMask(true);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_DEPTH_BUFFER_BIT);
        GL11.glEnable(GL11.GL_DEPTH_TEST);
        GL11.glDepthFunc(GL11.GL_LESS);
        GL11.glEnable(GL11.GL_CULL_FACE);
        GL11.glFrontFace(GL11.GL_CW);
        GL11.glCullFace(GL11.GL_BACK);
        GL11.glDisable(GL11.GL_BLEND)

    /// 場面の sky が Some なら、今の scissor の中を空で塗る（深度は書かない・深度の判定もしない）。beginScene の後に呼ぶ。
    /// Output.Depth では白（一番奥）。sky と background が両方 Some なら 1 回だけ知らせる（background は beginScene に渡さない）。
    def drawSky(state: State, viewport: PixelBox, scene: Scene3d.Scene3dCmd): Unit \ IO =
        Scene3d.skyWarning(scene) |> Option.forEach(line -> warnSceneOnce(state, "@sky+background", line));
        scene#sky |> Option.forEach(sky -> {
            let locs = skyProgramOf(state);
            if (locs#program == 0) ()
            else {
                let f = Scene3d.skyFieldsOf(sky);
                let basis = Scene3d.skyBasisOf(scene);
                GL11.glDisable(GL11.GL_DEPTH_TEST);
                GL11.glDisable(GL11.GL_CULL_FACE);
                GL20.glUseProgram(locs#program);
                GL20.glUniform4f(locs#viewport, Int32.toFloat32(viewport#x), Int32.toFloat32(viewport#y),
                                 Int32.toFloat32(viewport#width), Int32.toFloat32(viewport#height));
                putVec3(locs#forward, basis#forward);
                putVec3(locs#right, basis#right);
                putVec3(locs#up, basis#up);
                putColor(locs#zenith, f#zenith);
                putColor(locs#horizon, f#horizon);
                putColor(locs#ground, f#ground);
                GL20.glUniform1f(locs#curve, RenderUtil.f32(Scene3d.skyCurveOf(sky)));
                GL20.glUniform1i(locs#depthOut, match scene#output {
                    case Scene3d.Output.Color    => 0
                    case Scene3d.Output.Depth(_) => 1
                });
                GL30.glBindVertexArray(programsOf(state)#quadVao);
                GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 6);
                countDrawCall(state);
                GL30.glBindVertexArray(0);
                GL20.glUseProgram(0);
                GL11.glEnable(GL11.GL_CULL_FACE);
                GL11.glEnable(GL11.GL_DEPTH_TEST)
            }
        })

    /// 深度とカリングを切り、blend を 2D の既定（Normal）へ、program と VAO を外す。
    def endScene(): Unit \ IO =
        GL11.glDisable(GL11.GL_DEPTH_TEST);
        GL11.glDisable(GL11.GL_CULL_FACE);
        GL11.glDepthMask(true);
        GL11.glEnable(GL11.GL_BLEND);
        RenderSprite.applyBlend(DrawCmd.BlendMode.Normal);
        GL20.glUseProgram(0);
        GL30.glBindVertexArray(0)

    // ── 置いた物 ──

    /// 骨の無い物を locs で、骨つきの物を骨つきの版で描く（骨つきの版は骨つきの物がある時だけ組む）。
    def drawInstancesLit(state: State, gen: Int64, locs: LitLocs, camera: CameraData, instances: List[MeshDraw]): Unit \ IO =
        let (skinned, plain) = List.partition(isSkinned, instances);
        drawLitWith(state, gen, locs, camera, plain);
        if (List.isEmpty(skinned)) () else drawLitWith(state, gen, skinnedProgramsOf(state)#lit, camera, skinned)

    def drawLitWith(state: State, gen: Int64, locs: LitLocs, camera: CameraData, instances: List[MeshDraw]): Unit \ IO =
        if (List.isEmpty(instances) or locs#mesh#program == 0) ()
        else {
            useMeshProgram(locs#mesh, camera#view, camera#proj);
            putLights(locs#light, camera#lights);
            putShadow(locs#shadow, camera#shadow);
            instances |> List.forEach(d -> {
                if (d#culled) () else putColor(locs#tint, d#fields#tint);
                drawPosedMesh(state, gen, locs#mesh, d)
            })
        }

    /// Output.Depth の灰色で描く。骨の分け方は drawInstancesLit と同じ。
    def drawInstancesDepth(state: State, gen: Int64, locs: DepthLocs, camera: CameraData, eye: Vec3.Vec3,
                           depthRange: { near = Float64, range = Float64 }, instances: List[MeshDraw]): Unit \ IO =
        let (skinned, plain) = List.partition(isSkinned, instances);
        let pass = { camera = camera, eye = eye, depthRange = depthRange };
        drawDepthWith(state, gen, locs, pass, plain);
        if (List.isEmpty(skinned)) () else drawDepthWith(state, gen, skinnedProgramsOf(state)#depth, pass, skinned)

    def drawDepthWith(state: State, gen: Int64, locs: DepthLocs,
                      pass: { camera = CameraData, eye = Vec3.Vec3, depthRange = { near = Float64, range = Float64 } },
                      instances: List[MeshDraw]): Unit \ IO =
        if (List.isEmpty(instances) or locs#mesh#program == 0) ()
        else {
            useMeshProgram(locs#mesh, pass#camera#view, pass#camera#proj);
            GL20.glUniform3f(locs#eye, RenderUtil.f32(pass#eye#x), RenderUtil.f32(pass#eye#y), RenderUtil.f32(pass#eye#z));
            putDepthRange(locs#depthRange, pass#depthRange);
            instances |> List.forEach(drawPosedMesh(state, gen, locs#mesh))
        }

    def putColor(loc: Int32, c: Color): Unit \ IO =
        GL20.glUniform3f(loc, RenderUtil.f32(c#r), RenderUtil.f32(c#g), RenderUtil.f32(c#b))

    def putDepthRange(loc: Int32, depthRange: { near = Float64, range = Float64 }): Unit \ IO =
        GL20.glUniform2f(loc, RenderUtil.f32(depthRange#near), RenderUtil.f32(Float64.max(0.000001, depthRange#range)))

    // ── 材質のある置いた物 ──

    /// 置いた物を、頂点の色で描く物と材質のプログラムで描く物に分ける。wants が偽の材質と、組めなかった材質は頂点の色の側へ。
    /// 初めての材質はここで組む（3D を使わないゲームと、材質を使わない場面は GLSL のコンパイルを払わない）。
    /// outside = 描かずに済ませる物か（視錐台の外。MeshDraw の culled になる）。間引く物の材質も組む（間引くのは描く段の手前）。
    // WhyNot: 間引いた物を材質の組み立ての前に除かない — 初めて振り向いたコマで GLSL を組んで止まる（読み込み中に先に組ませる作りが効かない）。
    /// coverage = 描き先が標本を持ち、色の段で描く（cutout の材質を alpha to coverage の版で組む）。
    def splitByMaterial(state: State, gen: Int64, outside: Scene3d.Instance3d -> Bool, wants: Scene3d.MaterialFields -> Bool, coverage: Bool,
                        instances: List[Scene3d.Instance3d]): (List[MeshDraw], List[MaterialDraw]) \ IO =
        let classified = instances |> List.map(placed -> {
            Scene3d.lightmapWarning(placed) |> Option.forEach(line ->
                warnSceneOnce(state, "lightmap:" + line + Mesh3d.contentHash(Scene3d.instanceFieldsOf(placed)#mesh), line));
            let draw = meshDrawOf(state, outside, placed);
            let material = draw#fields#material
                |> Option.map(Scene3d.materialFieldsOf)
                |> Option.filter(wants)
                |> Option.flatMap(m -> materialEntry(state, gen, m, vertexKindOf(state, coverage, draw, m))
                    |> Option.map(e -> { entry = e, material = m, draw = draw }));
            (draw, material)
        });
        let plain = classified |> List.filterMap(fd -> if (Option.isEmpty(snd(fd))) Some(fst(fd)) else None);
        let materials = classified |> List.filterMap(snd);
        (plain, materials)

    /// 置いた物 d を材質 m で描くプログラムの頂点の形。法線マップは uv つきの形にだけ当てる（uv の無い形は形ごとに 1 回知らせて無視する）。
    def vertexKindOf(state: State, coverage: Bool, d: MeshDraw, m: Scene3d.MaterialFields): ProgramKind \ IO =
        let uv = hasUv(d);
        let wantsNormalMap = Option.nonEmpty(m#normalMap);
        if (wantsNormalMap and not uv)
            warnSceneOnce(state, "nouv:" + Mesh3d.contentHash(d#fields#mesh),
                "scene3d: uv の無い形に法線マップの材質 '${m#spec#name}' が付いている — 法線マップを当てずに描く（Mesh3d.withUvs か withBoxUvs で uv を付ける）")
        else ();
        { skinned = isSkinned(d), uv = uv, normalMap = wantsNormalMap and uv, lightmap = Option.nonEmpty(Scene3d.lightmapOfFields(d#fields)),
          blend = m#blend, doubleSided = m#doubleSided, coverage = isCoverageCutout(coverage, m) }

    /// 材質のある物を draws の順に描く（呼び手が並べる: 不透明はプログラムの番号で並べて切り替えを減らす・半透明は遠い物から）。
    /// 続く物が同じプログラムなら組み直さない。描き終えたら、絵を貼った unit（材質の絵と法線マップ）の sampler を外して unit 0 へ戻す。
    // WhyNot: 間引いた物を並べる前に除かない — sortBy は安定ソートではなく、減らした列を並べると同じプログラムの物どうしの順が変わり、
    //   同じ平面に重なった面の画素が入れ替わる。呼び手は間引く前の全部で並べ、ここで飛ばす（半透明を外した列は、半透明の無い場面では
    //   前と同じ列。半透明の有る場面の同じ深さの不透明の面の勝ち方は、CPU と揃うことを約束しない）。
    def drawMaterials(state: State, gen: Int64, camera: CameraData, pass: MaterialPass, source: TextureSource,
                      draws: List[MaterialDraw]): Unit \ IO =
        let bound = Array#{0, 0, 0, 0} @ Static;
        draws |> List.forEach(d -> if (d#draw#culled) drawPosedMesh(state, gen, d#entry#locs#mesh, d#draw) else {
            let locs = d#entry#locs;
            if (locs#mesh#program == Array.get(0, bound)) ()
            else {
                Array.put(locs#mesh#program, 0, bound);
                useMaterialProgram(state, camera, pass, locs)
            };
            let units = drawMaterialInstance(state, gen, source, d#entry#coverage, d);
            Array.put(Int32.max(units, Array.get(1, bound)), 1, bound);
            if (d#entry#normalMapped) Array.put(1, 2, bound) else ();
            if (d#entry#lightmapped) Array.put(1, 3, bound) else ()
        });
        releaseMaterialUnits(Array.get(1, bound), Array.get(2, bound) == 1, Array.get(3, bound) == 1)

    /// unit 0〜count−1（と、normalMap が真なら法線マップの unit・lightmap が真なら lightmap の unit）の sampler を外して unit 0 へ戻す。どれも貼っていなければ何もしない。
    // WhyNot: 貼ったテクスチャまでは外さない — ビルボードと 2D の面は描く前に自分のテクスチャを貼り直すが、sampler は貼り直さず unit の物を読む。
    def releaseMaterialUnits(count: Int32, normalMap: Bool, lightmap: Bool): Unit \ IO =
        if (count <= 0 and not normalMap and not lightmap) ()
        else {
            List.range(0, count) |> List.forEach(unit -> GL33.glBindSampler(unit, 0));
            if (normalMap) GL33.glBindSampler(normalMapTextureUnit(), 0) else ();
            if (lightmap) GL33.glBindSampler(lightmapTextureUnit(), 0) else ();
            GL13.glActiveTexture(GL13.GL_TEXTURE0)
        }

    def useMaterialProgram(state: State, camera: CameraData, pass: MaterialPass, locs: MaterialLocs): Unit \ IO =
        useMeshProgram(locs#mesh, camera#view, camera#proj);
        putLights(locs#light, camera#lights);
        putShadow(locs#shadow, camera#shadow);
        GL20.glUniform1f(locs#time, RenderUtil.f32(Array.get(0, state#timeHolder)));
        match pass {
            case MaterialPass.Color     => GL20.glUniform1i(locs#depthOut, 0)
            case MaterialPass.Depth(dr) =>
                GL20.glUniform1i(locs#depthOut, 1);
                putDepthRange(locs#depthRange, dr)
        }

    /// 材質 m の cutout を alpha to coverage で描くか。coverage = 描き先が標本を持ち、色の段で描く（Output.Depth は偽で渡す）。
    // WhyNot: 深度の段（Output.Depth）と半透明に使わない — 深度の灰色は縁で混ぜると奥行きが嘘になり、半透明の α は重ねる量に使う。
    def isCoverageCutout(coverage: Bool, m: Scene3d.MaterialFields): Bool =
        coverage and m#cutout and not m#blend

    /// 材質のある物 1 つを描き、絵を貼った unit の数を返す。coverage = cutout を discard でなく alpha to coverage で抜く
    /// （出す α を標本の数に使い、書く α は 1。GL_SAMPLE_ALPHA_TO_ONE）。
    def drawMaterialInstance(state: State, gen: Int64, source: TextureSource, coverage: Bool, d: MaterialDraw): Int32 \ IO =
        let locs = d#entry#locs;
        putColor(locs#tint, d#draw#fields#tint);
        GL20.glUniform1i(locs#cutout, if (d#material#cutout) 1 else 0);
        // WhyNot: ShaderDoc.materialParamValues で並べない — あちらは上限を超えた tex を 0 にする前の Spec から名前を拾い、
        //   compile3d が uParamN に割り当てた並び（0 にした後）と食い違う余地がある。uniform を宣言した側の並びで引く。
        List.zip(locs#params, d#entry#paramNames) |> List.forEach(ln -> {
            let (paramLoc, name) = ln;
            GL20.glUniform1f(paramLoc, RenderUtil.f32(Map.getWithDefault(name, 0.0, d#material#params)))
        });
        let units = bindMaterialTextures(state, gen, source, d);
        bindNormalMap(state, gen, source, d);
        bindLightmap(state, gen, source, d);
        if (coverage) {
            GL11.glEnable(GL13.GL_SAMPLE_ALPHA_TO_COVERAGE);
            GL11.glEnable(GL13.GL_SAMPLE_ALPHA_TO_ONE)
        } else ();
        if (d#material#doubleSided) {
            GL11.glDisable(GL11.GL_CULL_FACE);
            drawPosedMesh(state, gen, locs#mesh, d#draw);
            GL11.glEnable(GL11.GL_CULL_FACE)
        } else drawPosedMesh(state, gen, locs#mesh, d#draw);
        if (coverage) {
            GL11.glDisable(GL13.GL_SAMPLE_ALPHA_TO_COVERAGE);
            GL11.glDisable(GL13.GL_SAMPLE_ALPHA_TO_ONE)
        } else ();
        units

    /// lightmap を lightmap の unit に貼り、段の数・色空間・強さを入れる（Clamp・段つきの Linear で読む）。lightmap を読まないプログラムは何もしない。
    /// 名前が場面の textures に無い絵は 0（黒）で読み、名前ごとに 1 回知らせる（材質の絵と同じ道）。
    // WhyNot: プログラムごとに 1 回だけ入れない — 同じ形と材質で lightmap だけ違う物は同じプログラムで続けて描かれ、前の物の絵と強さを引き継ぐ。
    def bindLightmap(state: State, gen: Int64, source: TextureSource, d: MaterialDraw): Unit \ IO =
        if (not d#entry#lightmapped) ()
        else Scene3d.lightmapOfFields(d#draw#fields) |> Option.forEach(lm -> {
            let unit = lightmapTextureUnit();
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + unit);
            let bound = resolveTextureAs(state, gen, source, "lightmap の絵", lm#texture);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound#texId);
            GL33.glBindSampler(unit, materialSampler(state, Scene3d.Wrap.Clamp, ShaderDoc.FilterMode.Linear, bound#levels > 1));
            GL20.glUniform1f(d#entry#locs#lightmapLevels, RenderUtil.f32(Int32.toFloat64(Int32.min(bound#levels, lm#maxLevels))));
            GL20.glUniform1i(d#entry#locs#lightmapSrgb, if (lm#colorSpace == Texture3d.ColorSpace.Srgb) 1 else 0);
            GL20.glUniform1f(d#entry#locs#lightmapIntensity, RenderUtil.f32(lm#intensity))
        })

    /// 法線マップを法線マップの unit に貼る（材質の wrap・Linear で読む）。法線マップを当てないプログラムは何もしない。
    def bindNormalMap(state: State, gen: Int64, source: TextureSource, d: MaterialDraw): Unit \ IO =
        match (d#entry#normalMapped, d#material#normalMap) {
            case (true, Some(n)) =>
                let unit = normalMapTextureUnit();
                GL13.glActiveTexture(GL13.GL_TEXTURE0 + unit);
                let bound = resolveMaterialTexture(state, gen, source, n#texture);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound#texId);
                GL33.glBindSampler(unit, materialSampler(state, d#material#wrap, ShaderDoc.FilterMode.Linear, bound#levels > 1));
                GL20.glUniform1f(d#entry#locs#normalStrength, RenderUtil.f32(n#strength));
                GL20.glUniform1f(d#entry#locs#normalFlip, if (bound#flipped) 1.0f32 else 0.0f32);
                GL20.glUniform1f(d#entry#locs#normalLevels, RenderUtil.f32(Int32.toFloat64(bound#levels)))
            case _ => ()
        }

    /// 材質の絵を unit 0〜 に貼り、読み方（wrap と補間）の sampler を付けて、貼った数を返す。
    /// 名前は描く材質から引き直す（eqSpec は tex の名前を並びの番号で比べるので、名前だけ違う材質が同じプログラムを使う）。
    def bindMaterialTextures(state: State, gen: Int64, source: TextureSource, d: MaterialDraw): Int32 \ IO =
        if (List.isEmpty(d#entry#texReads)) 0
        else {
            let reads = ShaderDoc.materialTexReads(d#material#spec, d#material#emission) |> List.take(Scene3d.maxMaterialTextures());
            List.zip(reads, List.zip(d#entry#locs#texFlips, d#entry#locs#texLevels)) |> List.forEachWithIndex((unit, pair) -> {
                let ((name, filter), (flipLoc, levelsLoc)) = pair;
                // WhyNot: 引いてから unit を選ばない — 初めての絵は引く時に上げて今の unit に貼るので、前の unit に貼った絵を外してしまう。
                GL13.glActiveTexture(GL13.GL_TEXTURE0 + unit);
                let bound = resolveMaterialTexture(state, gen, source, name);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound#texId);
                GL33.glBindSampler(unit, materialSampler(state, d#material#wrap, filter, bound#levels > 1));
                GL20.glUniform1f(flipLoc, if (bound#flipped) 1.0f32 else 0.0f32);
                GL20.glUniform1f(levelsLoc, RenderUtil.f32(Int32.toFloat64(bound#levels)))
            });
            List.length(reads)
        }

    /// 材質の Tex の名前を、貼る GPU のテクスチャ・上下を反転して読むか（レンダーターゲット）・段の数へ引く。
    /// "tex3d:" は場面の textures（置き場に無ければ段ごと上げる）・ほかは全体の登録（段つきの写しを作る。レンダーターゲットは
    /// 毎コマ書き換わるので段を作らず、そのまま読む）・どちらにも無ければ透明な黒（名前ごとに 1 回知らせる）。
    def resolveMaterialTexture(state: State, gen: Int64, source: TextureSource, name: String): BoundTexture \ IO =
        resolveTextureAs(state, gen, source, "材質の絵", name)

    /// resolveMaterialTexture の、見つからない時の知らせで何の絵かを label で言う版（鍵は名前ごとに共有）。
    def resolveTextureAs(state: State, gen: Int64, source: TextureSource, label: String, name: String): BoundTexture \ IO =
        let found = if (String.startsWith(prefix = Texture3d.namePrefix(), name))
            Map.get(name, source#own) |> Option.map(t -> texture3dBound(state, gen, t))
        else (source#textureOf)(name) |> Option.map(t ->
            if (t#flipped) { texId = t#texId, flipped = true, levels = 1 } else mipCopyOf(state, gen, name, t));
        match found {
            case Some(hit) => hit
            case None =>
                warnSceneOnce(state, "missing:" + name, "scene3d: ${label} '${name}' が見つからない — 0（黒・透明）で読む"
                    + "（tex3d: の名前は場面の textures に、ほかは project.json の textures に同名の宣言があるか確認）");
                { texId = blankTextureId(state), flipped = false, levels = 1 }
        }

    /// 全体の登録の絵 t の段つきの写し（無いか、元の絵が作り直されていたら、元の段 0 を読み戻して段を作り、上げ直す）。
    // WhyNot: 登録の絵の画素を Java の側に持ち続けない — STB で直に上げているので持っておらず、全部の絵をヒープに二重に持つことになる。
    def mipCopyOf(state: State, gen: Int64, name: String, t: BillboardTexture): BoundTexture \ IO =
        let copies = Ref.get(state#mipCopiesRef);
        let copy = match Map.get(name, copies) {
            case Some(c) if c#sourceId == t#texId and c#version == t#version => { lastUsed = gen | c }
            case old =>
                old |> Option.forEach(c -> GL11.glDeleteTextures(c#texId));
                let w = Float64.tryToInt32(Float64.round(t#width)) |> Option.getWithDefault(1);
                let h = Float64.tryToInt32(Float64.round(t#height)) |> Option.getWithDefault(1);
                let pixels = Array.repeat(Static, Int32.max(1, w * h), 0);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, t#texId);
                GL11.glGetTexImage(GL11.GL_TEXTURE_2D, 0, GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, pixels);
                let chain = Mip.build({ width = w, height = h, pixels = Array.toVector(pixels) });
                { sourceId = t#texId, version = t#version, texId = uploadMipChain(chain), levels = List.length(chain), lastUsed = gen }
        };
        Ref.put(Map.insert(name, copy, copies), state#mipCopiesRef);
        { texId = copy#texId, flipped = false, levels = copy#levels }

    /// 段の列を 1 枚のテクスチャの段 0〜 に上げる（行 0 が絵の上・ARGB）。
    def uploadMipChain(chain: List[ShaderEval.TexData]): Int32 \ IO =
        let texId = GL11.glGenTextures();
        GL11.glBindTexture(GL11.GL_TEXTURE_2D, texId);
        chain |> List.forEachWithIndex((level, td) -> {
            let buf = MemoryUtil.memAllocInt(Int32.max(1, Vector.length(td#pixels)));
            discard buf.put(unchecked_cast(td#pixels as Array[Int32, Static]));
            discard buf.flip();
            GL11.glTexImage2D(GL11.GL_TEXTURE_2D, level, GL11.GL_RGBA, td#width, td#height, 0,
                              GL12.GL_BGRA, GL12.GL_UNSIGNED_INT_8_8_8_8_REV, buf);
            MemoryUtil.memFree(buf)
        });
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL12.GL_TEXTURE_BASE_LEVEL, 0);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL12.GL_TEXTURE_MAX_LEVEL, Int32.max(0, List.length(chain) - 1));
        texId

    def warnSceneOnce(state: State, key: String, message: String): Unit \ IO =
        let warned = Ref.get(state#sceneWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), state#sceneWarnedRef);
            Log.warn(message)
        }

    /// 見つからない絵の代わりに貼る 1 × 1 の透明な黒（初めて要る時に作る）。
    // WhyNot: テクスチャ 0 を貼らない — 完全でないテクスチャの読みはドライバ次第で α が 1 になり、CPU の 0 と食い違う。
    def blankTextureId(state: State): Int32 \ IO =
        let held = Array.get(0, state#blankTexture);
        if (held != 0) held
        else {
            let made = GpuHandle.textureIdInt(RenderTexture.loadTextureFromPixels(1, 1, Vector#{0})#id);
            Array.put(made, 0, state#blankTexture);
            made
        }

    /// wrap と補間と段の有無の組の sampler（初めて要る時に作る）。段つきの Nearest は NEAREST_MIPMAP_LINEAR（段の切り替わりの筋を出さない）・
    /// Linear は LINEAR_MIPMAP_LINEAR（CPU の Mip の読み方と同じ）。段の無い絵（レンダーターゲット・代わりの絵）は段なしで読む。
    def materialSampler(state: State, wrap: Scene3d.Wrap, filter: ShaderDoc.FilterMode, mipped: Bool): Int32 \ IO =
        let linear = filter == ShaderDoc.FilterMode.Linear;
        let index = (if (mipped) 4 else 0) + (if (wrap == Scene3d.Wrap.Clamp) 2 else 0) + (if (linear) 1 else 0);
        let held = Array.get(index, state#materialSamplers);
        if (held != 0) held
        else {
            let sampler = GL33.glGenSamplers();
            let glFilter = if (linear) GL11.GL_LINEAR else GL11.GL_NEAREST;
            let minFilter = match (mipped, linear) {
                case (true, true)  => GL11.GL_LINEAR_MIPMAP_LINEAR
                case (true, false) => GL11.GL_NEAREST_MIPMAP_LINEAR
                case (false, _)    => glFilter
            };
            let glWrap = if (wrap == Scene3d.Wrap.Clamp) GL12.GL_CLAMP_TO_EDGE else GL11.GL_REPEAT;
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_MIN_FILTER, minFilter);
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_MAG_FILTER, glFilter);
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_WRAP_S, glWrap);
            GL33.glSamplerParameteri(sampler, GL11.GL_TEXTURE_WRAP_T, glWrap);
            Array.put(sampler, index, state#materialSamplers);
            sampler
        }

    // ── 場面の絵の置き場 ──

    /// 場面の絵を contentHash で引き、無ければ段を作って段ごと上げる。どちらでも lastUsed を今の世代にする。
    def texture3dBound(state: State, gen: Int64, t: Texture3d.Texture3d): BoundTexture \ IO =
        let key = Texture3d.contentHash(t);
        let held = Ref.get(state#textures3dRef);
        let entry = match Map.get(key, held) {
            case Some(found) => { lastUsed = gen | found }
            case None =>
                let chain = Mip.build({ width = Texture3d.width(t), height = Texture3d.height(t), pixels = Texture3d.argb(t) });
                { texId = uploadMipChain(chain), levels = List.length(chain),
                  bytes = chain |> List.foldLeft((acc, td) -> acc + Int32.toInt64(td#width) * Int32.toInt64(td#height) * 4i64, 0i64),
                  lastUsed = gen }
        };
        Ref.put(Map.insert(key, entry, held), state#textures3dRef);
        { texId = entry#texId, flipped = false, levels = entry#levels }

    /// 使われない場面の絵を捨て、上限を超えたら今と前のコマで使っていない古い物から捨てる（画面のコマの終わりに 1 回）。
    /// 今と前のコマで使う物だけで上限を超えていたら 1 回だけ知らせる（Pass の場面は画面のコマの 1 つ前の世代で描かれる）。
    def sweepTextures3d(state: State, gen: Int64): Unit \ IO =
        let held = Ref.get(state#textures3dRef);
        let isIdle = (e: Texture3dEntry) -> gen - e#lastUsed > meshIdleFrames();
        let kept = Map.filter(e -> not isIdle(e), held);
        let overBudget = (m: Map[String, Texture3dEntry]) ->
            Map.size(m) > state#textureCountBudget or Map.foldLeft((acc, e) -> acc + e#bytes, 0i64, m) > state#textureByteBudget;
        let oldestFirst = Map.toList(kept) |> List.filter(ke -> snd(ke)#lastUsed < gen - 1i64)
            |> List.map(ke -> (snd(ke)#lastUsed, ke)) |> List.sortBy(fst) |> List.map(snd);
        let trimmed = List.foldLeft((acc, ke) -> if (overBudget(acc)) Map.remove(fst(ke), acc) else acc, kept, oldestFirst);
        let dropped = Map.difference(held, trimmed);
        Map.forEach((_key, e) -> GL11.glDeleteTextures(e#texId), dropped);
        Ref.put(trimmed, state#textures3dRef);
        let copies = Ref.get(state#mipCopiesRef);
        let idleCopies = Map.filter(c -> gen - c#lastUsed > meshIdleFrames(), copies);
        Map.forEach((_name, c) -> GL11.glDeleteTextures(c#texId), idleCopies);
        Ref.put(Map.difference(copies, idleCopies), state#mipCopiesRef);
        if (overBudget(trimmed))
            warnSceneOnce(state, "@budget", "scene3d: 場面の絵（Texture3d）が ${state#textureCountBudget} 枚か"
                + " ${Int64.toString(state#textureByteBudget / 1048576i64)} MB を超えて使われている — 絵を減らすか小さくするか、project.json の scene3dTextureBudgetCount / scene3dTextureBudgetMB を上げる")
        else ()

    // ── 材質のプログラムの置き場 ──

    /// 材質のプログラムを分ける形。skinned = 骨つき・uv = uv とタンジェントを持つ・normalMap = 法線マップを当てる（uv つきの時だけ真）・
    /// lightmap = ベイクした光を 2 本目の uv で読む（Scene3d.lightmapOfFields が Some の時だけ真。骨つきには付かない）・
    /// blend = 半透明（出す α を材質の α に）・doubleSided = 裏の面の光の法線を裏返す・
    /// coverage = cutout を discard でなく alpha to coverage で抜く（isCoverageCutout が真の時だけ）。
    // WhyNot: blend・doubleSided・coverage を uniform で切り替えない — 使わない材質の GLSL の字が変わり、どの GPU でも同じ絵になる保証が崩れる。
    //   どれも偽の版は、それらを足す前と 1 字も同じ GLSL を組む。
    pub type alias ProgramKind = { skinned = Bool, uv = Bool, normalMap = Bool, lightmap = Bool, blend = Bool, doubleSided = Bool, coverage = Bool }

    /// 材質のプログラムの鍵（2D の Shader 面の鍵 = spec の名前 と重ならない）。骨つき・uv つき・法線マップつき・lightmap つきの版は GLSL が違うので別の鍵。
    /// 材質の側は spec と emission の中身の鍵（MaterialFields#shaderHash）なので、同じ名前で木の違う材質が並んでも組み直さず、ゲームは名前を分けなくてよい。
    /// cutout・params・wrap は uniform と sampler で渡すので鍵に入れない（blend・doubleSided・法線マップ・coverage は kind の側）。
    pub def materialKey(m: Scene3d.MaterialFields, kind: ProgramKind): String =
        "3d" + (if (kind#skinned) "+skin" else "") + (if (kind#uv) "+uv" else "") + (if (kind#normalMap) "+nm" else "") + (if (kind#lightmap) "+lm" else "")
            + (if (kind#blend) "+bl" else "") + (if (kind#doubleSided) "+ds" else "") + (if (kind#coverage) "+cov" else "")
            + ":" + Int64.toString(force m#shaderHash)

    /// 材質のプログラムを引く。無いか、同じ鍵で中身が違えば組み直す。組めなかった材質は None（頂点の色で描く）。
    def materialEntry(state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind): Option[MaterialEntry] \ IO =
        let key = materialKey(m, kind);
        let cache = Ref.get(state#materialsRef);
        let entry = match Map.get(key, cache) {
            // 来た方の spec を持ち直す — 古い方を持ち続けると、次のコマも参照の一致で抜けられず毎回木を比べる。
            case Some(found) if sameMaterial(found, m) => { spec = m#spec, emission = m#emission, lastUsed = gen | found }
            case old                                   => rebuildMaterial(state, gen, { key = key, kind = kind }, old, m)
        };
        Ref.put(Map.insert(key, entry, Ref.get(state#materialsRef)), state#materialsRef);
        if (entry#locs#mesh#program == 0) None else Some(entry)

    def sameMaterial(entry: MaterialEntry, m: Scene3d.MaterialFields): Bool =
        ShaderGen.eqMaterial(entry#spec, entry#emission, m#spec, m#emission)

    /// 鍵 key の材質を組み直す。古いプログラムはすぐ消さず引退させる（同じコマの先の物がまだ使う）。
    def rebuildMaterial(state: State, gen: Int64, slot: { key = String, kind = ProgramKind }, old: Option[MaterialEntry],
                        m: Scene3d.MaterialFields): MaterialEntry \ IO =
        old |> Option.forEach(e -> {
            if (e#lastUsed == gen) warnMaterialThrash(state, slot#key, m#spec#name) else ();
            retireMaterial(state, e)
        });
        buildMaterial(state, gen, m, slot#kind)

    /// 材質のプログラムを組む。読む絵の組が Scene3d.maxMaterialTextures() を超える材質は、後ろの組を 0 にして組み、1 回知らせる。
    def buildMaterial(state: State, gen: Int64, m: Scene3d.MaterialFields, kind: ProgramKind): MaterialEntry \ IO =
        Array.put(1, 2, state#materialStreak);
        let readCount = List.length(ShaderDoc.materialTexReads(m#spec, m#emission));
        if (readCount > Scene3d.maxMaterialTextures())
            warnSceneOnce(state, "limit:" + m#spec#name, "scene3d: 材質 '${m#spec#name}' が読む絵の組が ${readCount} 組ある"
                + " — ${Scene3d.maxMaterialTextures()} 組目より後ろは 0 で描く")
        else ();
        let (spec, emission) = ShaderDoc.limitMaterialTexReads(Scene3d.maxMaterialTextures(), m#spec, m#emission);
        let glsl = ShaderGen.compile3d(spec, emission);
        let label = "scene3d:material" + (if (kind#skinned) ":skin" else "") + (if (kind#uv) ":uv" else "")
            + (if (kind#normalMap) ":nm" else "") + (if (kind#lightmap) ":lm" else "") + (if (kind#blend) ":bl" else "")
            + (if (kind#doubleSided) ":ds" else "") + (if (kind#coverage) ":cov" else "") + ":${m#spec#name}";
        let vertex = materialVertexSource({ skinned = kind#skinned, uv = kind#uv, lightmap = kind#lightmap });
        let fragment = materialFragmentSource(glsl, kind);
        let program = match RenderShader.tryCreateProgram(vertex, fragment, label) {
            case Some(p) => p
            case None    =>
                Log.warnThen("scene3d: 材質 '${m#spec#name}' のプログラムが組めなかった — この材質の物は頂点の色で描く", 0)
        };
        if (kind#skinned) bindJointsBlock(program) else ();
        bindTextureUnits(program, List.length(glsl#texReads), kind#normalMap, kind#lightmap);
        { spec = m#spec, emission = m#emission, paramNames = glsl#paramNames, texReads = glsl#texReads, normalMapped = kind#normalMap,
          lightmapped = kind#lightmap, coverage = kind#coverage,
          locs = materialLocsOf(program, glsl#paramNames, List.length(glsl#texReads)), lastUsed = gen }

    /// uTexN を unit N へ、uNormalMap を法線マップの unit へ向ける（プログラムごとに 1 回。組めなかったプログラムと、
    /// 絵も法線マップも無い材質は何もしない）。
    def bindTextureUnits(program: Int32, count: Int32, normalMap: Bool, lightmap: Bool): Unit \ IO =
        if (program == 0 or (count == 0 and not normalMap and not lightmap)) ()
        else {
            GL20.glUseProgram(program);
            List.range(0, count) |> List.forEach(unit -> GL20.glUniform1i(loc(program, "uTex${unit}"), unit));
            if (normalMap) GL20.glUniform1i(loc(program, "uNormalMap"), normalMapTextureUnit()) else ();
            if (lightmap) GL20.glUniform1i(loc(program, "uLightmap"), lightmapTextureUnit()) else ();
            GL20.glUseProgram(0)
        }

    def retireMaterial(state: State, e: MaterialEntry): Unit \ IO =
        if (e#locs#mesh#program == 0) ()
        else Ref.put(e#locs#mesh#program :: Ref.get(state#retiredMaterialsRef), state#retiredMaterialsRef)

    def warnMaterialThrash(state: State, key: String, name: String): Unit \ IO =
        let warned = Ref.get(state#thrashWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), state#thrashWarnedRef);
            Log.warn("scene3d: 中身の違う材質の鍵（ShaderGen.hashMaterial）が同じコマにぶつかった（'${name}'）"
                + " — 毎コマ組み直している。spec か emission の数に NaN があれば直す（NaN は自分とも等しくない）。無ければ engine の不具合")
        }

    def materialLocsOf(program: Int32, paramNames: List[String], texCount: Int32): MaterialLocs \ IO =
        { mesh = meshLocsOf(program), tint = loc(program, "uTint"), light = lightLocsOf(program), shadow = shadowLocsOf(program),
          time = loc(program, "uTime"), cutout = loc(program, "uCutout"),
          depthOut = loc(program, "uDepthOut"), depthRange = loc(program, "uDepthRange"),
          params = paramNames |> List.mapWithIndex((i, _) -> loc(program, "uParam${i}")),
          texFlips = List.range(0, texCount) |> List.map(i -> loc(program, "uTexFlip${i}")),
          normalStrength = loc(program, "uNormalStrength"), normalFlip = loc(program, "uNormalFlip"),
          texLevels = List.range(0, texCount) |> List.map(i -> loc(program, "uTexLevels${i}")), normalLevels = loc(program, "uNormalLevels"),
          lightmapLevels = loc(program, "uLightmapLevels"), lightmapSrgb = loc(program, "uLightmapSrgb"),
          lightmapIntensity = loc(program, "uLightmapIntensity") }

    /// 引退した材質のプログラムを消し、使われない材質を LRU で追い出す（画面のコマの終わりに 1 回）。
    /// 今と前のコマで使った材質は捨てない（Pass の場面は画面のコマの 1 つ前の世代で描かれる）。
    def sweepMaterials(state: State, gen: Int64): Unit \ IO =
        Ref.get(state#retiredMaterialsRef) |> List.forEach(program -> GL20.glDeleteProgram(program));
        Ref.put(Nil, state#retiredMaterialsRef);
        let cache = Ref.get(state#materialsRef);
        let isLive = (e: MaterialEntry) -> e#lastUsed >= gen - 1i64;
        let pinned = Map.valuesOf(cache) |> List.filter(isLive) |> List.map(e -> e#locs#mesh#program) |> List.toSet;
        // WhyNot: 上限を固定の数にしない — 材質の数はゲームが決めるので、多いゲームで毎コマ作っては捨てるだけになる。
        let cap = Int32.max(16, Set.size(pinned) * 2);
        let victims = RenderShaderCache.computeEvictions({
            entries = Map.toList(cache) |> List.map(ke -> (fst(ke), snd(ke)#locs#mesh#program, snd(ke)#lastUsed)),
            pinned = pinned, cap = cap });
        if (List.isEmpty(victims)) ()
        else {
            victims |> List.forEach(key -> Map.get(key, cache) |> Option.forEach(e ->
                if (e#locs#mesh#program == 0) () else GL20.glDeleteProgram(e#locs#mesh#program)));
            Ref.put(List.foldLeft((acc, key) -> Map.remove(key, acc), cache, victims), state#materialsRef)
        }

    def useMeshProgram(locs: MeshLocs, view: Array[Float32, Static], proj: Array[Float32, Static]): Unit \ IO =
        GL20.glUseProgram(locs#program);
        GL20.glUniformMatrix4fv(locs#view, false, view);
        GL20.glUniformMatrix4fv(locs#proj, false, proj)

    /// 1 つの形を world の行列で描く（置き場に無ければ上げる）。
    def drawMesh(state: State, gen: Int64, locs: MeshLocs, mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Unit \ IO =
        let entry = meshEntry(state, gen, mesh);
        if (entry#indexCount <= 0) ()
        else {
            GL20.glUniformMatrix4fv(locs#model, false, matrixArray(world));
            GL20.glUniformMatrix4fv(locs#normal, false, matrixArray(Mat4.normalMatrix(world)));
            GL30.glBindVertexArray(entry#vao);
            GL11.glDrawElements(GL11.GL_TRIANGLES, entry#indexCount, GL11.GL_UNSIGNED_INT, 0i64);
            countDrawCall(state)
        }

    /// 骨つきの物は joint 行列を UBO へ置いてから描く（locs は骨つきの版のプログラム）。pose が None なら drawMesh と同じ。
    /// 間引いた物（culled）は描かず、形を今のコマで使った物として置き場に数えるだけ。
    // WhyNot: 間引いた物を meshEntry に通さずに飛ばさない — endFrame は 128 コマ使わなかった形を捨てるので、振り向くたびに頂点を上げ直す。
    def drawPosedMesh(state: State, gen: Int64, locs: MeshLocs, d: MeshDraw): Unit \ IO =
        if (d#culled) discard meshEntry(state, gen, d#fields#mesh)
        else {
            d#pose |> Option.forEach(putJoints(skinnedProgramsOf(state)));
            drawMesh(state, gen, locs, d#fields#mesh, d#fields#world)
        }

    def isSkinned(d: MeshDraw): Bool = Option.nonEmpty(d#pose)

    def hasUv(d: MeshDraw): Bool = Option.nonEmpty(Mesh3d.uvs(d#fields#mesh))

    /// 置いた物を描く材料にする（outside が真なら間引く）。ジョイントの数の食い違いは形ごとに 1 回だけ知らせる（Scene3d.skinningWarning）。
    def meshDrawOf(state: State, outside: Scene3d.Instance3d -> Bool, placed: Scene3d.Instance3d): MeshDraw \ IO =
        let fields = Scene3d.instanceFieldsOf(placed);
        Scene3d.skinningWarning(placed) |> Option.forEach(message -> warnSkinOnce(state, Mesh3d.contentHash(fields#mesh), message));
        { fields = fields, pose = Scene3d.skinningOf(placed), culled = outside(placed) }

    def warnSkinOnce(state: State, meshKey: String, message: String): Unit \ IO =
        let warned = Ref.get(state#skinWarnedRef);
        if (Set.memberOf(meshKey, warned)) ()
        else {
            Ref.put(Set.insert(meshKey, warned), state#skinWarnedRef);
            Log.warn(message)
        }

    /// joint 行列を UBO の頭から詰めて置き、binding に付ける（std140 の mat4 は列優先 16 個 = Mat4.toColumns の並び）。
    /// 前に書いた中身と同じなら書かない。書く時はバッファを作り直してから書く（前のドローが読む古い中身はドライバが別に持つ）。
    // WhyNot: 64 本ぶんを毎回書かない — 頂点が引く番号は skinningOf がジョイントの数未満と確かめてあり、後ろの残りは読まれない。
    // WhyNot: 作り直さずに書き足さない — 前のドローがまだ読んでいる UBO へ書くと、ドライバが GPU を待つ（同じ pose の部品を描くたびに待っていた）。
    // WhyNot: 1 本の大きな UBO の別の場所へ書いて glBindBufferRange で指さない — 1 コマの pose の数を先に数える道とオフセットのそろえが要り、
    //   同じ中身を書き直さないだけで書くのは 1 コマに体の数だけになる。
    def putJoints(skinned: SkinnedPrograms, pose: Pose3d.Pose3d): Unit \ IO =
        let matrices = Pose3d.jointMatrices(pose) |> Vector.take(Skin3d.maxJoints());
        let data = Array.repeat(Static, Int32.max(1, Vector.length(matrices) * 16), 0.0f32);
        matrices |> Vector.forEachWithIndex((j, m) ->
            Mat4.toColumns(m) |> Vector.forEachWithIndex((k, v) -> Array.put(RenderUtil.f32(v), j * 16 + k, data)));
        if (needsUpload(Ref.get(skinned#uploadedJoints), data)) {
            GL15.glBindBuffer(GL31.GL_UNIFORM_BUFFER, skinned#jointsUbo);
            GL15.glBufferData(GL31.GL_UNIFORM_BUFFER, Int32.toInt64(Skin3d.maxJoints() * 64), GL15.GL_DYNAMIC_DRAW);
            GL15.glBufferSubData(GL31.GL_UNIFORM_BUFFER, 0i64, data);
            GL15.glBindBuffer(GL31.GL_UNIFORM_BUFFER, 0);
            Ref.put(data, skinned#uploadedJoints)
        } else ();
        GL30.glBindBufferBase(GL31.GL_UNIFORM_BUFFER, jointsBinding(), skinned#jointsUbo)

    /// 前に UBO へ書いた中身 before と今の中身 after が違うか（長さが違うか、どれか 1 つのビットが違う）。
    /// WhyNot: Float32 の == で比べない — -0.0 と +0.0 を同じと見なし、NaN をいつも違うと見なす。書いた物をそのまま持っているかを見たい。
    def needsUpload(before: Array[Float32, r1], after: Array[Float32, r2]): Bool \ r1 + r2 =
        let n = Array.length(after);
        Array.length(before) != n or not List.forAll(i -> sameBits(Array.get(i, before), Array.get(i, after)), List.range(0, n))

    def sameBits(a: Float32, b: Float32): Bool =
        JFloat.floatToRawIntBits(a) == JFloat.floatToRawIntBits(b)

    /// 列優先 16 個の float の並び（glUniformMatrix4fv に transpose = false で渡す形）。
    def matrixArray(m: Mat4.Mat4): Array[Float32, Static] \ IO =
        let out = Array.repeat(Static, 16, 0.0f32);
        Mat4.toColumns(m) |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, out));
        out

    // ── メッシュの置き場 ──

    /// contentHash で引き、無ければ上げる。どちらでも lastUsed を今の世代にする。
    def meshEntry(state: State, gen: Int64, mesh: Mesh3d.Mesh3d): MeshEntry \ IO =
        let key = Mesh3d.contentHash(mesh);
        let meshes = Ref.get(state#meshesRef);
        let entry = match Map.get(key, meshes) {
            case Some(found) => { lastUsed = gen | found }
            case None =>
                Array.put(1, 2, state#uploadStreak);
                let made = uploadMesh(gen, mesh);
                Array.put(Array.get(0, state#vertexTotal) + made#vertexCount, 0, state#vertexTotal);
                made
        };
        Ref.put(Map.insert(key, entry, meshes), state#meshesRef);
        entry

    /// 形を GPU へ上げる（位置・法線・色を 9 個ずつ交互に並べた vbo と、添え字の ibo）。
    def uploadMesh(gen: Int64, mesh: Mesh3d.Mesh3d): MeshEntry \ IO =
        let n = Mesh3d.vertexCount(mesh);
        let vertices = interleave(mesh, n);
        let indices = Mesh3d.indices(mesh);
        let indexArray = Array.repeat(Static, Int32.max(1, Vector.length(indices)), 0);
        indices |> Vector.forEachWithIndex((i, v) -> Array.put(v, i, indexArray));
        let vao = GL30.glGenVertexArrays();
        let vbo = GL15.glGenBuffers();
        let ibo = GL15.glGenBuffers();
        GL30.glBindVertexArray(vao);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, vbo);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, vertices, GL15.GL_STATIC_DRAW);
        GL20.glEnableVertexAttribArray(0);
        GL20.glVertexAttribPointer(0, 3, GL11.GL_FLOAT, false, 36, 0i64);
        GL20.glEnableVertexAttribArray(1);
        GL20.glVertexAttribPointer(1, 3, GL11.GL_FLOAT, false, 36, 12i64);
        GL20.glEnableVertexAttribArray(2);
        GL20.glVertexAttribPointer(2, 3, GL11.GL_FLOAT, false, 36, 24i64);
        let skin = uploadSkin(mesh);
        let surface = uploadSurface(mesh);
        let uv2 = uploadUv2(mesh);
        GL15.glBindBuffer(GL15.GL_ELEMENT_ARRAY_BUFFER, ibo);
        GL15.glBufferData(GL15.GL_ELEMENT_ARRAY_BUFFER, indexArray, GL15.GL_STATIC_DRAW);
        GL30.glBindVertexArray(0);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, 0);
        GL15.glBindBuffer(GL15.GL_ELEMENT_ARRAY_BUFFER, 0);
        { vao = vao, vbo = vbo, ibo = ibo, skin = skin, surface = surface, uv2 = uv2, indexCount = Vector.length(indices), vertexCount = n, lastUsed = gen }

    /// ジョイントの番号と重みを、bind 中の VAO の location 3・4 へ上げる（ジョイントの無い形は None・何もしない）。
    /// 骨の無い版のプログラムはこの 2 つを宣言しないので、同じ VAO のまま曲げずに描ける。
    def uploadSkin(mesh: Mesh3d.Mesh3d): Option[SkinBuffers] \ IO =
        Mesh3d.skinJoints(mesh) |> Option.flatMap(joints ->
            Mesh3d.skinWeights(mesh) |> Option.map(weights -> uploadSkinArrays(joints, weights)))

    def uploadSkinArrays(joints: Vector[Int32], weights: Vector[Float64]): SkinBuffers \ IO =
        let jointArray = Array.repeat(Static, Int32.max(1, Vector.length(joints)), 0);
        joints |> Vector.forEachWithIndex((i, j) -> Array.put(j, i, jointArray));
        let weightArray = Array.repeat(Static, Int32.max(1, Vector.length(weights)), 0.0f32);
        weights |> Vector.forEachWithIndex((i, w) -> Array.put(RenderUtil.f32(w), i, weightArray));
        let jointVbo = GL15.glGenBuffers();
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, jointVbo);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, jointArray, GL15.GL_STATIC_DRAW);
        GL20.glEnableVertexAttribArray(3);
        // WhyNot: glVertexAttribPointer で渡さない — float に直されて、シェーダーの ivec4 では番号として読めない。
        GL30.glVertexAttribIPointer(3, 4, GL11.GL_INT, 16, 0i64);
        let weightVbo = GL15.glGenBuffers();
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, weightVbo);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, weightArray, GL15.GL_STATIC_DRAW);
        GL20.glEnableVertexAttribArray(4);
        GL20.glVertexAttribPointer(4, 4, GL11.GL_FLOAT, false, 16, 0i64);
        { joints = jointVbo, weights = weightVbo }

    /// 2 本目の uv（lightmap を読む UV）を、bind 中の VAO の location 7 へ別の vbo で上げる（2 本目の uv の無い形は None・何もしない）。
    // WhyNot: 位置・法線・色や uv とタンジェントの vbo に混ぜない — 2 本目の uv の無い形の頂点バッファの中身を変えない。
    def uploadUv2(mesh: Mesh3d.Mesh3d): Option[Int32] \ IO =
        Mesh3d.uvs2(mesh) |> Option.map(uvs -> {
            let data = Array.repeat(Static, Int32.max(1, Vector.length(uvs)), 0.0f32);
            uvs |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, data));
            let vbo = GL15.glGenBuffers();
            GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, vbo);
            GL15.glBufferData(GL15.GL_ARRAY_BUFFER, data, GL15.GL_STATIC_DRAW);
            GL20.glEnableVertexAttribArray(7);
            GL20.glVertexAttribPointer(7, 2, GL11.GL_FLOAT, false, 8, 0i64);
            vbo
        })

    /// uv とタンジェントを、bind 中の VAO の location 5・6 へ上げる（uv の無い形は None・何もしない）。
    /// 頂点の色と骨の無い版のプログラムはこの 2 つを宣言しないので、同じ VAO のまま描ける。
    def uploadSurface(mesh: Mesh3d.Mesh3d): Option[Int32] \ IO =
        Mesh3d.uvs(mesh) |> Option.flatMap(uvs -> Mesh3d.tangents(mesh) |> Option.map(tangents -> {
            let n = Vector.length(uvs) / 2;
            let data = Array.repeat(Static, Int32.max(1, n * 6), 0.0f32);
            uvs |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), (i / 2) * 6 + Int32.remainder(i, 2), data));
            tangents |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), (i / 4) * 6 + 2 + Int32.remainder(i, 4), data));
            let vbo = GL15.glGenBuffers();
            GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, vbo);
            GL15.glBufferData(GL15.GL_ARRAY_BUFFER, data, GL15.GL_STATIC_DRAW);
            GL20.glEnableVertexAttribArray(5);
            GL20.glVertexAttribPointer(5, 2, GL11.GL_FLOAT, false, 24, 0i64);
            GL20.glEnableVertexAttribArray(6);
            GL20.glVertexAttribPointer(6, 4, GL11.GL_FLOAT, false, 24, 8i64);
            vbo
        }))

    def interleave(mesh: Mesh3d.Mesh3d, n: Int32): Array[Float32, Static] \ IO =
        let out = Array.repeat(Static, Int32.max(1, n * 9), 0.0f32);
        let put = (offset: Int32, values: Vector[Float64]) ->
            values |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), (i / 3) * 9 + offset + Int32.remainder(i, 3), out));
        put(0, Mesh3d.positions(mesh));
        put(3, Mesh3d.normals(mesh));
        put(6, Mesh3d.colors(mesh));
        out

    def deleteMesh(entry: MeshEntry): Unit \ IO =
        GL30.glDeleteVertexArrays(entry#vao);
        GL15.glDeleteBuffers(entry#vbo);
        GL15.glDeleteBuffers(entry#ibo);
        entry#skin |> Option.forEach(s -> {
            GL15.glDeleteBuffers(s#joints);
            GL15.glDeleteBuffers(s#weights)
        });
        entry#surface |> Option.forEach(vbo -> GL15.glDeleteBuffers(vbo));
        entry#uv2 |> Option.forEach(vbo -> GL15.glDeleteBuffers(vbo))

    /// 画面のコマを描き終えた後に 1 回呼ぶ。使われないメッシュと上限を超えた分を捨て、毎コマの作り直しを知らせる。
    pub def endFrame(state: State, gen: Int64): Unit \ IO =
        noteUploadStreak(state);
        noteMaterialStreak(state);
        sweepMaterials(state, gen);
        sweepShadowTargets(state, gen);
        sweepTextures3d(state, gen);
        let meshes = Ref.get(state#meshesRef);
        let isIdle = (e: MeshEntry) -> gen - e#lastUsed > meshIdleFrames();
        let idle = Map.filter(isIdle, meshes);
        let kept = Map.filter(e -> not isIdle(e), meshes);
        if (Map.isEmpty(idle)) () else dropMeshes(state, idle, kept);
        if (Array.get(0, state#vertexTotal) > vertexBudget()) trimToBudget(state, gen) else ()

    def dropMeshes(state: State, dropped: Map[String, MeshEntry], kept: Map[String, MeshEntry]): Unit \ IO =
        Map.forEach((_key, e) -> deleteMesh(e), dropped);
        let freed = Map.foldLeft((acc, e) -> acc + e#vertexCount, 0, dropped);
        Array.put(Array.get(0, state#vertexTotal) - freed, 0, state#vertexTotal);
        Ref.put(kept, state#meshesRef)

    /// 頂点の合計が上限に収まるまで、最後に使ったのが古い物から捨てる（今のコマで使った物は捨てない）。
    def trimToBudget(state: State, gen: Int64): Unit \ IO =
        let oldestFirst = Map.toList(Ref.get(state#meshesRef))
            |> List.filter(ke -> snd(ke)#lastUsed < gen)
            |> List.sortBy(ke -> snd(ke)#lastUsed);
        let over = Array.get(0, state#vertexTotal) - vertexBudget();
        let (victims, _) = oldestFirst |> List.foldLeft((acc, ke) -> {
            let (picked, freed) = acc;
            if (freed >= over) acc else (ke :: picked, freed + snd(ke)#vertexCount)
        }, (Nil, 0));
        let dropped = List.toMap(victims);
        let kept = Map.difference(Ref.get(state#meshesRef), dropped);
        // WhyNot: 捨てる物が無いコマで知らせない — 今のコマで使う形だけで上限を超えていると、毎コマ同じ知らせが出る。
        if (Map.isEmpty(dropped)) ()
        else {
            dropMeshes(state, dropped, kept);
            Log.warn("scene3d: メッシュの置き場が頂点 ${vertexBudget()} を超えたので、古い形を ${Map.size(dropped)} 個捨てた")
        }

    def noteUploadStreak(state: State): Unit \ IO =
        noteStreak(state#uploadStreak, "scene3d: 新しい形（Mesh3d）が ${rebuildStreakLimit()} コマ続けて GPU へ上がっている"
            + " — 形を毎コマ作り直している。動きは形を作り直さず、置いた物の行列か tint で付ける")

    /// 材質のプログラムを rebuildStreakLimit() コマ続けて新しく組んだら 1 回知らせる（鍵は木の中身なので、木の数を毎コマ変えると毎コマ組む）。
    def noteMaterialStreak(state: State): Unit \ IO =
        noteStreak(state#materialStreak, "scene3d: 材質のプログラムを ${rebuildStreakLimit()} コマ続けて新しく組んでいる"
            + " — 材質の木（spec か emission）の数を毎コマ変えている。毎コマ変わる数は ShaderDoc の param にして Scene3d.withParams で渡す（数に NaN があっても毎コマ組む）")

    /// streak = [このことが続いたコマの数, 知らせ済みなら 1, このコマで起きたら 1]。コマの終わりに 1 回呼び、続いた数が上限に届いたら 1 回だけ message を出す。
    def noteStreak(streak: Array[Int32, Static], message: String): Unit \ IO =
        let happened = Array.get(2, streak) == 1;
        Array.put(0, 2, streak);
        let next = if (happened) Array.get(0, streak) + 1 else 0;
        Array.put(next, 0, streak);
        if (next >= rebuildStreakLimit() and Array.get(1, streak) == 0) {
            Array.put(1, 1, streak);
            Log.warn(message)
        } else ()

    // ── ビルボード ──

    /// 場面のビルボードを描く。視錐台の外のビルボード（外接球で見る）は描かない（見つからない絵の知らせは描く物と同じに出す）。
    def drawBillboards(state: State, textureOf: String -> Option[BillboardTexture] \ IO, locs: BillboardLocs,
                       camera: CameraData, scene: Scene3d.Scene3dCmd): Unit \ IO =
        if (List.isEmpty(scene#billboards) or locs#program == 0) ()
        else {
            // WhyNot: ビルボードに裏の面の間引き（GL_CULL_FACE）を掛けない — 四角はいつもカメラを向くので裏は来ず、頂点の巻き方を合わせる手間だけが増える。
            GL11.glDisable(GL11.GL_CULL_FACE);
            GL20.glUseProgram(locs#program);
            GL20.glUniformMatrix4fv(locs#view, false, camera#view);
            GL20.glUniformMatrix4fv(locs#proj, false, camera#proj);
            putLights(locs#light, camera#lights);
            putVec3(locs#right, Camera3d.right(scene#camera));
            putVec3(locs#up, Camera3d.up(scene#camera));
            putVec3(locs#facing, Vec3.mul(Camera3d.forward(scene#camera), -1.0));
            putBillboardOutput(locs, scene#output);
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL30.glBindVertexArray(programsOf(state)#quadVao);
            scene#billboards |> List.forEach(b ->
                drawBillboard(state, textureOf, locs, Scene3d.isBillboardOutsideFrustum(camera#frustum, b), Scene3d.billboardFieldsOf(b)));
            GL30.glBindVertexArray(0);
            GL11.glEnable(GL11.GL_CULL_FACE)
        }

    def putBillboardOutput(locs: BillboardLocs, output: Scene3d.Output): Unit \ IO =
        match output {
            case Scene3d.Output.Color => GL20.glUniform1i(locs#depthOut, 0)
            case Scene3d.Output.Depth(dr) =>
                GL20.glUniform1i(locs#depthOut, 1);
                GL20.glUniform2f(locs#depthRange, RenderUtil.f32(dr#near), RenderUtil.f32(Float64.max(0.000001, dr#range)))
        }

    def drawBillboard(state: State, textureOf: String -> Option[BillboardTexture] \ IO, locs: BillboardLocs,
                      culled: Bool, b: Scene3d.BillboardFields): Unit \ IO =
        match textureOf(b#texture) {
            case None          => warnMissingTexture(state, b#texture)
            case Some(_) if culled => ()
            case Some(texture) =>
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, texture#texId);
                putVec3(locs#center, b#position);
                GL20.glUniform2f(locs#anchor, RenderUtil.f32(b#anchor#x), RenderUtil.f32(b#anchor#y));
                GL20.glUniform2f(locs#size, RenderUtil.f32(b#size#x), RenderUtil.f32(b#size#y));
                putUvRect(locs#uvRect, texture, b#regionRect);
                GL20.glUniform3f(locs#tint, RenderUtil.f32(b#tint#r), RenderUtil.f32(b#tint#g), RenderUtil.f32(b#tint#b));
                GL20.glUniform1i(locs#lit, if (b#lit) 1 else 0);
                GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 6);
                countDrawCall(state)
        }

    /// 貼る範囲の uv（左上 u・v と幅・高さ）。レンダーターゲットは行 0 が下なので v を反転する。
    def putUvRect(loc: Int32, texture: BillboardTexture, source: Rect2.Rect2): Unit \ IO =
        let w = Float64.max(1.0, texture#width);
        let h = Float64.max(1.0, texture#height);
        let u0 = source#position#x / w;
        let v0 = source#position#y / h;
        let du = source#size#x / w;
        let dv = source#size#y / h;
        if (texture#flipped)
            GL20.glUniform4f(loc, RenderUtil.f32(u0), RenderUtil.f32(1.0 - v0), RenderUtil.f32(du), RenderUtil.f32(0.0 - dv))
        else
            GL20.glUniform4f(loc, RenderUtil.f32(u0), RenderUtil.f32(v0), RenderUtil.f32(du), RenderUtil.f32(dv))

    def warnMissingTexture(state: State, name: String): Unit \ IO =
        let warned = Ref.get(state#missingTexturesRef);
        if (Set.memberOf(name, warned)) ()
        else {
            Ref.put(Set.insert(name, warned), state#missingTexturesRef);
            Log.warn("scene3d: ビルボードのテクスチャ '${name}' が見つからない — 描かない"
                + "（project.json の textures に同名の宣言があるか確認）")
        }

    def putVec3(loc: Int32, v: Vec3.Vec3): Unit \ IO =
        GL20.glUniform3f(loc, RenderUtil.f32(v#x), RenderUtil.f32(v#y), RenderUtil.f32(v#z))

    // ── 光 ──

    /// 光を uniform の並びへ詰める（点光源・スポットは選んだ後の物）。
    def lightDataOf(scene: Scene3d.Scene3dCmd): LightData \ IO =
        let env = scene#environment;
        let eye = scene#camera#eye;
        let points = scene#pointLights;
        let spots = scene#spotLights;
        let pointPos = Array.repeat(Static, 3 * Scene3d.maxPointLights(), 0.0f32);
        let pointColor = Array.repeat(Static, 3 * Scene3d.maxPointLights(), 0.0f32);
        let pointRange = Array.repeat(Static, Scene3d.maxPointLights(), 1.0f32);
        points |> List.forEachWithIndex((i, l) -> {
            fillVec3(pointPos, i, l#position);
            fillVec3(pointColor, i, Vec3.mul(colorVec(l#color), l#intensity));
            Array.put(RenderUtil.f32(Float64.max(0.000001, l#range)), i, pointRange)
        });
        let spot = spotArrays(spots);
        let fogColor = Array.repeat(Static, 3, 0.0f32);
        let fogRange = Array.repeat(Static, 2, 0.0f32);
        env#fog |> Option.forEach(f -> {
            fillVec3(fogColor, 0, colorVec(f#color));
            Array.put(RenderUtil.f32(f#near), 0, fogRange);
            Array.put(RenderUtil.f32(f#far), 1, fogRange)
        });
        let ambient = Array.repeat(Static, 3, 0.0f32);
        fillVec3(ambient, 0, colorVec(env#ambient));
        let eyeArray = Array.repeat(Static, 3, 0.0f32);
        fillVec3(eyeArray, 0, eye);
        { ambient = ambient, hemisphere = RenderUtil.f32(env#hemisphere), toonSteps = env#toonSteps,
          pointCount = List.length(points), pointPos = pointPos, pointColor = pointColor, pointRange = pointRange,
          spotCount = List.length(spots), spotPos = spot#position, spotDir = spot#direction, spotColor = spot#color,
          spotRange = spot#range, spotCone = spot#cone,
          fogOn = if (Option.isEmpty(env#fog)) 0 else 1, fogColor = fogColor, fogRange = fogRange, eye = eyeArray }

    def spotArrays(spots: List[Scene3d.SpotLight]): { position = Array[Float32, Static], direction = Array[Float32, Static],
                                                       color = Array[Float32, Static], range = Array[Float32, Static],
                                                       cone = Array[Float32, Static] } \ IO =
        let n = Scene3d.maxSpotLights();
        let position = Array.repeat(Static, 3 * n, 0.0f32);
        let direction = Array.repeat(Static, 3 * n, 0.0f32);
        let color = Array.repeat(Static, 3 * n, 0.0f32);
        let range = Array.repeat(Static, n, 1.0f32);
        let cone = Array.repeat(Static, 2 * n, 0.0f32);
        spots |> List.forEachWithIndex((i, l) -> {
            fillVec3(position, i, l#position);
            fillVec3(direction, i, Vec3.normalized(Vec3.sub(l#target, l#position)));
            fillVec3(color, i, Vec3.mul(colorVec(l#color), l#intensity));
            Array.put(RenderUtil.f32(Float64.max(0.000001, l#range)), i, range);
            let edge = Scene3d.spotConeOf(l);
            Array.put(RenderUtil.f32(edge#outerCos), 2 * i, cone);
            Array.put(RenderUtil.f32(edge#innerCos), 2 * i + 1, cone)
        });
        { position = position, direction = direction, color = color, range = range, cone = cone }

    def colorVec(c: Color): Vec3.Vec3 = Vec3.v3(c#r, c#g, c#b)

    def fillVec3(out: Array[Float32, Static], i: Int32, v: Vec3.Vec3): Unit \ IO =
        Array.put(RenderUtil.f32(v#x), 3 * i, out);
        Array.put(RenderUtil.f32(v#y), 3 * i + 1, out);
        Array.put(RenderUtil.f32(v#z), 3 * i + 2, out)

    def putLights(locs: LightLocs, d: LightData): Unit \ IO =
        GL20.glUniform3fv(locs#ambient, d#ambient);
        GL20.glUniform1f(locs#hemisphere, d#hemisphere);
        GL20.glUniform1i(locs#toonSteps, d#toonSteps);
        GL20.glUniform1i(locs#pointCount, d#pointCount);
        GL20.glUniform3fv(locs#pointPos, d#pointPos);
        GL20.glUniform3fv(locs#pointColor, d#pointColor);
        GL20.glUniform1fv(locs#pointRange, d#pointRange);
        GL20.glUniform1i(locs#spotCount, d#spotCount);
        GL20.glUniform3fv(locs#spotPos, d#spotPos);
        GL20.glUniform3fv(locs#spotDir, d#spotDir);
        GL20.glUniform3fv(locs#spotColor, d#spotColor);
        GL20.glUniform1fv(locs#spotRange, d#spotRange);
        GL20.glUniform2fv(locs#spotCone, d#spotCone);
        GL20.glUniform1i(locs#fogOn, d#fogOn);
        GL20.glUniform3fv(locs#fogColor, d#fogColor);
        GL20.glUniform2fv(locs#fogRange, d#fogRange);
        GL20.glUniform3fv(locs#eye, d#eye)

    // ── プログラム ──

    /// プログラムを初めて要る時に組む。組めなかったプログラムは 0 になり、その描き物は描かない（ゲームは止めない）。
    def programsOf(state: State): Programs \ IO =
        match Ref.get(state#programsRef) {
            case Some(p) => p
            case None =>
                let made = buildPrograms();
                Ref.put(Some(made), state#programsRef);
                made
        }

    def buildPrograms(): Programs \ IO =
        let lit = compile(meshVertexSource(), litFragmentSource(), "scene3d:lit");
        let depth = compile(meshVertexSource(), depthFragmentSource(), "scene3d:depth");
        let billboard = compile(billboardVertexSource(), billboardFragmentSource(), "scene3d:billboard");
        let blit = compile(blitVertexSource(), blitFragmentSource(), "scene3d:blit");
        let (quadVao, quadVbo) = buildQuad();
        { lit = litLocsOf(lit), depth = depthLocsOf(depth),
          billboard = billboardLocsOf(billboard), blit = blit, quadVao = quadVao, quadVbo = quadVbo }

    /// 空のプログラムを初めて要る時に組む。組めなかったプログラムは 0（空を描かず、地の色も塗らない）。
    def skyProgramOf(state: State): SkyLocs \ IO =
        match Ref.get(state#skyRef) {
            case Some(p) => p
            case None =>
                let program = compile(blitVertexSource(), skyFragmentSource(), "scene3d:sky");
                let made = { program = program, viewport = loc(program, "uViewport"), forward = loc(program, "uForward"),
                             right = loc(program, "uRight"), up = loc(program, "uUp"), zenith = loc(program, "uZenith"),
                             horizon = loc(program, "uHorizon"), ground = loc(program, "uGround"), curve = loc(program, "uCurve"),
                             depthOut = loc(program, "uDepthOut") };
                Ref.put(Some(made), state#skyRef);
                made
        }

    /// 骨つきの版を初めて要る時に組む。組めなかったプログラムは 0（骨つきの物はその種類だけ描かない）。
    def skinnedProgramsOf(state: State): SkinnedPrograms \ IO =
        match Ref.get(state#skinnedRef) {
            case Some(p) => p
            case None =>
                let made = buildSkinnedPrograms();
                Ref.put(Some(made), state#skinnedRef);
                made
        }

    def buildSkinnedPrograms(): SkinnedPrograms \ IO =
        let lit = compile(skinnedMeshVertexSource(), litFragmentSource(), "scene3d:lit:skin");
        let depth = compile(skinnedMeshVertexSource(), depthFragmentSource(), "scene3d:depth:skin");
        bindJointsBlock(lit);
        bindJointsBlock(depth);
        { lit = litLocsOf(lit), depth = depthLocsOf(depth), jointsUbo = createJointsBuffer(),
          uploadedJoints = Ref.fresh(Static, Array.empty(Static, 0)) }

    /// プログラムの Joints の uniform block を jointsBinding() へ向ける（block の無いプログラムと 0 は何もしない）。
    def bindJointsBlock(program: Int32): Unit \ IO =
        if (program == 0) ()
        else {
            let index = GL31.glGetUniformBlockIndex(program, "Joints");
            if (index == GL31.GL_INVALID_INDEX) () else GL31.glUniformBlockBinding(program, index, jointsBinding())
        }

    /// mat4 × Skin3d.maxJoints() の UBO（std140 の mat4 の配列は 1 本 64 バイトで詰まる）。
    def createJointsBuffer(): Int32 \ IO =
        let ubo = GL15.glGenBuffers();
        GL15.glBindBuffer(GL31.GL_UNIFORM_BUFFER, ubo);
        GL15.glBufferData(GL31.GL_UNIFORM_BUFFER, Int32.toInt64(Skin3d.maxJoints() * 64), GL15.GL_DYNAMIC_DRAW);
        GL15.glBindBuffer(GL31.GL_UNIFORM_BUFFER, 0);
        ubo

    def litLocsOf(program: Int32): LitLocs \ IO =
        { mesh = meshLocsOf(program), tint = loc(program, "uTint"), light = lightLocsOf(program), shadow = shadowLocsOf(program) }

    def depthLocsOf(program: Int32): DepthLocs \ IO =
        { mesh = meshLocsOf(program), eye = loc(program, "uEye"), depthRange = loc(program, "uDepthRange") }

    def compile(vertex: String, fragment: String, label: String): Int32 \ IO =
        match RenderShader.tryCreateProgram(vertex, fragment, label) {
            case Some(p) => p
            case None =>
                Log.warnThen("scene3d: プログラム '${label}' が組めなかった — この種類の 3D の描き物は描かない", 0)
        }

    def loc(program: Int32, name: String): Int32 \ IO =
        if (program == 0) -1 else GL20.glGetUniformLocation(program, name)

    def meshLocsOf(program: Int32): MeshLocs \ IO =
        { program = program, model = loc(program, "uModel"), view = loc(program, "uView"),
          proj = loc(program, "uProj"), normal = loc(program, "uNormal") }

    def lightLocsOf(program: Int32): LightLocs \ IO =
        { ambient = loc(program, "uAmbient"), hemisphere = loc(program, "uHemisphere"), toonSteps = loc(program, "uToonSteps"),
          pointCount = loc(program, "uPointCount"), pointPos = loc(program, "uPointPos"),
          pointColor = loc(program, "uPointColor"), pointRange = loc(program, "uPointRange"),
          spotCount = loc(program, "uSpotCount"), spotPos = loc(program, "uSpotPos"), spotDir = loc(program, "uSpotDir"),
          spotColor = loc(program, "uSpotColor"), spotRange = loc(program, "uSpotRange"), spotCone = loc(program, "uSpotCone"),
          fogOn = loc(program, "uFogOn"), fogColor = loc(program, "uFogColor"), fogRange = loc(program, "uFogRange"),
          eye = loc(program, "uEye") }

    def shadowLocsOf(program: Int32): ShadowLocs \ IO =
        { on = loc(program, "uShadowOn"), spot = loc(program, "uShadowSpot"), matrix = loc(program, "uShadowMatrix"),
          map = loc(program, "uShadowMap"), bias = loc(program, "uShadowBias"), pcf = loc(program, "uShadowPcf"),
          strength = loc(program, "uShadowStrength") }

    def billboardLocsOf(program: Int32): BillboardLocs \ IO =
        if (program == 0) () else {
            GL20.glUseProgram(program);
            GL20.glUniform1i(loc(program, "uImage"), 0);
            GL20.glUseProgram(0)
        };
        { program = program, view = loc(program, "uView"), proj = loc(program, "uProj"),
          center = loc(program, "uCenter"), right = loc(program, "uRight"), up = loc(program, "uUp"),
          anchor = loc(program, "uAnchor"), size = loc(program, "uSize"), uvRect = loc(program, "uUvRect"),
          tint = loc(program, "uTint"), lit = loc(program, "uLit"), facing = loc(program, "uFacing"),
          depthOut = loc(program, "uDepthOut"), depthRange = loc(program, "uDepthRange"), light = lightLocsOf(program) }

    /// 四角の 6 頂点（角の 0〜1。y は下向き = 絵の上が 0）。ビルボードと Design の重ねで共有する。
    def buildQuad(): (Int32, Int32) \ IO =
        let vao = GL30.glGenVertexArrays();
        let vbo = GL15.glGenBuffers();
        let corners = Array#{
            0.0f32, 0.0f32,  1.0f32, 0.0f32,  1.0f32, 1.0f32,
            0.0f32, 0.0f32,  1.0f32, 1.0f32,  0.0f32, 1.0f32
        } @ Static;
        GL30.glBindVertexArray(vao);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, vbo);
        GL15.glBufferData(GL15.GL_ARRAY_BUFFER, corners, GL15.GL_STATIC_DRAW);
        GL20.glEnableVertexAttribArray(0);
        GL20.glVertexAttribPointer(0, 2, GL11.GL_FLOAT, false, 8, 0i64);
        GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, 0);
        GL30.glBindVertexArray(0);
        (vao, vbo)

    // ── GLSL ──

    /// 置いた物の頂点シェーダー（頂点の色のプログラム・深度だけのプログラム・材質のプログラムで共有）。
    pub def meshVertexSource(): String =
        meshVertexSourceOf({ declarations = "", prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = None, uv2 = false })

    /// 骨つきの版: 位置と法線を joint 行列の重みつきの和（Pose3d.jointMatrices の並び）で曲げてから uModel を掛ける。
    // WhyNot: 法線を skin の逆行列の転置で曲げない — 左上 3×3 のままだと倍率が軸ごとに違うジョイントで少し傾くが、
    //   CPU の描き手も同じ式なので GL と CPU の絵は一致する。その差は許す。
    pub def skinnedMeshVertexSource(): String =
        meshVertexSourceOf({
            declarations = skinDeclarations(),
            prelude = skinPrelude(),
            position = "skin * vec4(aPos, 1.0)",
            normal = "mat3(skin) * aNormal",
            tangent = None,
            uv2 = false })

    /// 材質のプログラムの頂点シェーダー。uv の無い形は頂点の色のプログラムと同じ物・uv つきは vUv と vTangent も出す・
    /// lightmap つき（骨の無い版だけ）は 2 本目の uv の vUv2 も出す。骨つきの版は lightmap を読まない（Scene3d.lightmapOf が None）。
    pub def materialVertexSource(kind: { skinned = Bool, uv = Bool, lightmap = Bool }): String =
        match (kind#skinned, kind#uv, kind#lightmap) {
            case (false, false, false) => meshVertexSource()
            case (true, false, _)      => skinnedMeshVertexSource()
            case (false, false, true)  =>
                meshVertexSourceOf({ declarations = uv2Declarations(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                                     tangent = None, uv2 = true })
            case (false, true, lm)     =>
                meshVertexSourceOf({ declarations = surfaceDeclarations() + (if (lm) uv2Declarations() else ""), prelude = "",
                                     position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = Some("aTangent.xyz"), uv2 = lm })
            case (true, true, _)       =>
                meshVertexSourceOf({ declarations = skinDeclarations() + surfaceDeclarations(), prelude = skinPrelude(),
                                     position = "skin * vec4(aPos, 1.0)", normal = "mat3(skin) * aNormal",
                                     tangent = Some("mat3(skin) * aTangent.xyz"), uv2 = false })
        }

    def uv2Declarations(): String =
        "layout (location = 7) in vec2 aUv2;\n" +
        "out vec2 vUv2;\n"

    def skinDeclarations(): String =
        "layout (location = 3) in ivec4 aJoints;\n" +
        "layout (location = 4) in vec4 aWeights;\n" +
        "layout (std140) uniform Joints {\n" +
        "    mat4 uJoints[${Skin3d.maxJoints()}];\n" +
        "};\n"

    def skinPrelude(): String =
        "    mat4 skin = aWeights.x * uJoints[aJoints.x] + aWeights.y * uJoints[aJoints.y]\n" +
        "              + aWeights.z * uJoints[aJoints.z] + aWeights.w * uJoints[aJoints.w];\n"

    def surfaceDeclarations(): String =
        "layout (location = 5) in vec2 aUv;\n" +
        "layout (location = 6) in vec4 aTangent;\n" +
        "out vec2 vUv;\n" +
        "out vec4 vTangent;\n"

    /// 置いた物の頂点シェーダーの組み立て。declarations = 足す属性と uniform・prelude = main の頭・
    /// position = uModel を掛ける前の形の座標（vec4）・normal = uNormal を掛ける前の法線（vec3）・
    /// tangent = uModel の左上 3×3 を掛ける前のタンジェントの xyz（vec3。uv の無い形は None で vUv・vTangent を出さない）。
    /// タンジェントの w には uModel の左上 3×3 の行列式の符号を掛ける（鏡写しの置き方で絵の上の向きを保つ）。
    // WhyNot: タンジェントを uNormal で写さない — 法線の行列は面に垂直な向きを保つための物で、面の上の向きは uModel のまま写る。
    def meshVertexSourceOf(parts: { declarations = String, prelude = String, position = String, normal = String,
                                    tangent = Option[String], uv2 = Bool }): String =
        let surfaceBody = match parts#tangent {
            case None    => ""
            case Some(t) =>
                "    vUv = aUv;\n" +
                "    mat3 modelLinear = mat3(uModel);\n" +
                "    vTangent = vec4(modelLinear * (" + t + "), aTangent.w * sign(determinant(modelLinear)));\n"
        };
        "#version 330 core\n" +
        "layout (location = 0) in vec3 aPos;\n" +
        "layout (location = 1) in vec3 aNormal;\n" +
        "layout (location = 2) in vec3 aColor;\n" +
        parts#declarations +
        "uniform mat4 uModel;\n" +
        "uniform mat4 uView;\n" +
        "uniform mat4 uProj;\n" +
        "uniform mat4 uNormal;\n" +
        "out vec3 vWorld;\n" +
        "out vec3 vNormal;\n" +
        "out vec3 vColor;\n" +
        "void main() {\n" +
        parts#prelude +
        "    vec4 world = uModel * " + parts#position + ";\n" +
        "    vWorld = world.xyz;\n" +
        "    vNormal = (uNormal * vec4(" + parts#normal + ", 0.0)).xyz;\n" +
        "    vColor = aColor;\n" +
        surfaceBody +
        (if (parts#uv2) "    vUv2 = aUv2;\n" else "") +
        "    gl_Position = uProj * uView * world;\n" +
        "}\n"

    /// lightAt と lightBakedAt が共に持つ、点光源とスポットの足し算・toon・返す所（light に足していき、閉じ括弧まで）。
    def dynamicLightAndToon(): String =
        "    for (int i = 0; i < 8; i++) {\n" +
        "        if (i >= uPointCount) break;\n" +
        "        vec3 d = uPointPos[i] - p;\n" +
        "        float d2 = dot(d, d);\n" +
        "        vec3 l = d * inversesqrt(max(d2, 1e-12));\n" +
        "        light += uPointColor[i] * attenuation(d2, uPointRange[i]) * clamp(dot(n, l), 0.0, 1.0);\n" +
        "    }\n" +
        "    for (int i = 0; i < 2; i++) {\n" +
        "        if (i >= uSpotCount) break;\n" +
        "        vec3 d = uSpotPos[i] - p;\n" +
        "        float d2 = dot(d, d);\n" +
        "        vec3 l = d * inversesqrt(max(d2, 1e-12));\n" +
        "        float cone = smoothstep(uSpotCone[i].x, uSpotCone[i].y, dot(-l, uSpotDir[i]));\n" +
        "        light += uSpotColor[i] * attenuation(d2, uSpotRange[i]) * clamp(dot(n, l), 0.0, 1.0) * cone * spotShadow(i, p);\n" +
        "    }\n" +
        "    if (uToonSteps > 0) {\n" +
        "        float steps = float(uToonSteps);\n" +
        "        light = floor(light * steps + 0.5) / steps;\n" +
        "    }\n" +
        "    return light;\n" +
        "}\n"

    /// 光の uniform と式（ファイルの頭の式。CPU の描き手と同じ）。
    def lightSource(): String =
        "uniform vec3 uAmbient;\n" +
        "uniform float uHemisphere;\n" +
        "uniform int uToonSteps;\n" +
        "uniform int uPointCount;\n" +
        "uniform vec3 uPointPos[8];\n" +
        "uniform vec3 uPointColor[8];\n" +
        "uniform float uPointRange[8];\n" +
        "uniform int uSpotCount;\n" +
        "uniform vec3 uSpotPos[2];\n" +
        "uniform vec3 uSpotDir[2];\n" +
        "uniform vec3 uSpotColor[2];\n" +
        "uniform float uSpotRange[2];\n" +
        "uniform vec2 uSpotCone[2];\n" +
        "uniform int uFogOn;\n" +
        "uniform vec3 uFogColor;\n" +
        "uniform vec2 uFogRange;\n" +
        "uniform vec3 uEye;\n" +
        shadowSource() +
        "float attenuation(float d2, float range) {\n" +
        "    float k = max(0.0, 1.0 - d2 / (range * range));\n" +
        "    return k * k;\n" +
        "}\n" +
        "vec3 lightAt(vec3 p, vec3 n) {\n" +
        "    vec3 light = uAmbient + vec3(uHemisphere * max(0.0, n.y));\n" +
        dynamicLightAndToon() +
        "vec3 fogged(vec3 c, vec3 p) {\n" +
        "    if (uFogOn == 0) return c;\n" +
        "    float t = clamp((distance(p, uEye) - uFogRange.x) / max(uFogRange.y - uFogRange.x, 1e-6), 0.0, 1.0);\n" +
        "    return mix(c, uFogColor, t);\n" +
        "}\n"

    /// 影の uniform と、スポット i の光に掛ける割合（Scene3d.shadowMatrix の doc の約束 1〜5。CPU の描き手と同じ）。
    /// 地図の画素は uv = NDC × 0.5 + 0.5 に大きさを掛けて切り捨てた所（行 0 が NDC の y = −1）。周りの画素は端へ寄せる。
    /// uShadowOn = 0 のプログラム（影の無い場面・ビルボード）は 1 を返す。
    // WhyNot: texture() でなく texelFetch で読む — 標本の位置の丸めと端の扱いを GPU のフィルタに任せると、CPU の数え方とずれる。
    // WhyNot: w ≤ 0（光の後ろ）を影にしない — w で割ると x・y が裏返って地図の中に入りうる。その点は円錐の外で光が 0。
    def shadowSource(): String =
        "uniform int uShadowOn;\n" +
        "uniform int uShadowSpot;\n" +
        "uniform mat4 uShadowMatrix;\n" +
        "uniform sampler2D uShadowMap;\n" +
        "uniform float uShadowBias;\n" +
        "uniform int uShadowPcf;\n" +
        "uniform float uShadowStrength;\n" +
        "float shadowLitFraction(vec3 p) {\n" +
        "    vec4 c = uShadowMatrix * vec4(p, 1.0);\n" +
        "    if (c.w <= 0.0) return 1.0;\n" +
        "    vec3 ndc = c.xyz / c.w;\n" +
        "    if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;\n" +
        "    float z = (ndc.z * 0.5 + 0.5) - uShadowBias;\n" +
        "    ivec2 size = textureSize(uShadowMap, 0);\n" +
        "    ivec2 last = size - ivec2(1);\n" +
        "    ivec2 center = clamp(ivec2(floor((ndc.xy * 0.5 + 0.5) * vec2(size))), ivec2(0), last);\n" +
        "    int lit = 0;\n" +
        "    int total = 0;\n" +
        "    for (int dy = -uShadowPcf; dy <= uShadowPcf; dy++) {\n" +
        "        for (int dx = -uShadowPcf; dx <= uShadowPcf; dx++) {\n" +
        "            ivec2 t = clamp(center + ivec2(dx, dy), ivec2(0), last);\n" +
        "            if (z <= texelFetch(uShadowMap, t, 0).r) lit++;\n" +
        "            total++;\n" +
        "        }\n" +
        "    }\n" +
        "    return float(lit) / float(total);\n" +
        "}\n" +
        "float spotShadow(int i, vec3 p) {\n" +
        "    if (uShadowOn == 0 || i != uShadowSpot) return 1.0;\n" +
        "    return 1.0 - uShadowStrength * (1.0 - shadowLitFraction(p));\n" +
        "}\n"

    /// Output.Depth の灰色（目からの距離で near が黒・near + range が白）。uEye は呼ぶ側の frag が宣言する。
    def depthGraySource(): String =
        "uniform vec2 uDepthRange;\n" +
        "float depthGray(vec3 p) {\n" +
        "    return clamp((distance(p, uEye) - uDepthRange.x) / uDepthRange.y, 0.0, 1.0);\n" +
        "}\n"

    def litFragmentSource(): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec3 uTint;\n" +
        lightSource() +
        "void main() {\n" +
        "    vec3 n = normalize(vNormal);\n" +
        "    vec3 c = vColor * uTint * lightAt(vWorld, n);\n" +
        "    fragColor = vec4(fogged(c, vWorld), 1.0);\n" +
        "}\n"

    /// 材質の frag。光の式は litFragmentSource と同じで、頂点の色の代わりに materialEval の albedo を使う（頂点の色は
    /// 材質の Spec が VertexColor で読む）。surface#uv = uv つきの形か（偽なら vUv は (0, 0) の const）・
    /// surface#normalMap = 法線マップを当てるか（uv つきの時だけ。光の計算の法線を、法線マップで傾けた n' にする）・
    /// surface#lightmap = ベイクした光を 2 本目の uv で読み、環境光と hemisphere の代わりに足すか。
    /// uDepthOut = 1 なら cutout で抜いた後の奥行きの灰色を書く（Output.Depth の cutout の材質）。
    /// surface#blend = 出す α を材質の α に（半透明）・surface#doubleSided = 裏の面（!gl_FrontFacing）は光の計算の法線を裏返す・
    /// surface#coverage = cutout を discard でなく alpha to coverage の α で抜く。3 つとも偽なら、足す前と同じ字。
    // WhyNot: 欄を 1 つずつ並べた引数にしない — ProgramKind に欄が増えるたびに、呼び手とテストの字が全部書き換わる。skinned は頂点の側だけが読む。
    pub def materialFragmentSource(glsl: ShaderGen.MaterialGlsl, surface: ProgramKind): String =
        let normalMapped = surface#uv and surface#normalMap;
        // WhyNot: sg_texMip を足すかを normalMapSource と lightmapSource の中で別々に決めない — 両方を使う版で 2 回定義され、コンパイルが落ちる。
        let needsMip = (normalMapped or surface#lightmap) and not String.contains(substr = "vec4 sg_texMip(", glsl#functions);
        let faceNormal = if (surface#doubleSided) "facingNormal" else "normalize(vNormal)";
        let normal = if (normalMapped) "normalMapped(${faceNormal})" else faceNormal;
        let cutout = if (surface#coverage) "" else "    if (uCutout == 1 && " + glsl#cutoutAlpha + " < 0.5) discard;\n";
        let facing = if (surface#doubleSided) "    vec3 facingNormal = gl_FrontFacing ? normalize(vNormal) : -normalize(vNormal);\n" else "";
        // WhyNot: alpha to coverage に絵の α をそのまま渡さない — ぼけた α の絵では縁が数画素の幅で透け、cutout の固い縁に見えない。
        let alpha = if (surface#coverage) "clamp((" + glsl#cutoutAlpha + " - 0.5) / max(fwidth(" + glsl#cutoutAlpha + "), 1e-4) + 0.5, 0.0, 1.0)"
                    else if (surface#blend) "albedo.a" else "1.0";
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        (if (surface#uv) "in vec2 vUv;\n" else "const vec2 vUv = vec2(0.0, 0.0);\n") +
        (if (surface#lightmap) "in vec2 vUv2;\n" else "") +
        "out vec4 fragColor;\n" +
        "uniform vec3 uTint;\n" +
        "uniform int uCutout;\n" +
        "uniform int uDepthOut;\n" +
        lightSource() +
        depthGraySource() +
        glsl#uniforms +
        glsl#functions +
        (if (needsMip) ShaderGen.texMipSource() else "") +
        (if (normalMapped) normalMapSource() else "") +
        (if (surface#lightmap) lightmapSource() else "") +
        "void main() {\n" +
        "    vec4 albedo;\n" +
        "    vec3 emission;\n" +
        "    materialEval(albedo, emission);\n" +
        cutout +
        "    if (uDepthOut == 1) {\n" +
        "        float g = depthGray(vWorld);\n" +
        "        fragColor = vec4(g, g, g, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        facing +
        (if (surface#lightmap)
            "    vec3 c = albedo.rgb * uTint * lightBakedAt(vWorld, " + normal + ", bakedLight());\n"
         else
            "    vec3 c = albedo.rgb * uTint * lightAt(vWorld, " + normal + ");\n") +
        "    fragColor = vec4(fogged(c, vWorld) + emission, " + alpha + ");\n" +
        "}\n"

    /// ベイクした光の uniform と式（ファイルの頭の式。CPU の描き手と同じ）。lightmap は線形の光の量として読み（Srgb なら sRGB の区分の式で戻す）、
    /// intensity を掛けてから、sRGB の区分の式の逆で画面の値へ戻して動く光と足す（光の計算がガンマのままの値で行われているため）。
    /// 段つきの Linear で読む（sg_texMip。段は Lightmap の maxLevels まで）。2 本目の uv の絵は場面の textures だけから引くので上下の反転は無い。
    def lightmapSource(): String =
        "uniform sampler2D uLightmap;\n" +
        "uniform float uLightmapLevels;\n" +
        "uniform int uLightmapSrgb;\n" +
        "uniform float uLightmapIntensity;\n" +
        Texture3d.srgbToLinearGlsl("r3d_srgbToLinear") +
        Texture3d.linearToSrgbGlsl("r3d_linearToSrgb") +
        "vec3 bakedLight() {\n" +
        "    vec3 s = sg_texMip(uLightmap, 0.0, uLightmapLevels, vUv2).rgb;\n" +
        "    vec3 l = (uLightmapSrgb == 1 ? r3d_srgbToLinear(s) : s) * uLightmapIntensity;\n" +
        "    return r3d_linearToSrgb(max(l, vec3(0.0)));\n" +
        "}\n" +
        "vec3 lightBakedAt(vec3 p, vec3 n, vec3 baked) {\n" +
        "    vec3 light = baked;\n" +
        dynamicLightAndToon()

    /// 法線マップの uniform と、外向きの法線 n を法線マップで傾けた n'（式はファイルの頭。CPU の描き手と同じ）。
    /// uNormalFlip = 1 はレンダーターゲット（行 0 が下）で、v を上下反転して読む。
    // WhyNot: タンジェントを頂点の値のまま使わない — 補間で N との直交が崩れ、傾ける向きが法線の側へ漏れる。
    // WhyNot: 長さ 0 のタンジェントで傾けない — normalize が NaN を出し、画素が黒く抜ける。その画素は n のまま。
    /// 法線マップは段つきの Linear で読む（sg_texMip。materialFragmentSource が前に 1 回だけ出す）。
    def normalMapSource(): String =
        "in vec4 vTangent;\n" +
        "uniform sampler2D uNormalMap;\n" +
        "uniform float uNormalStrength;\n" +
        "uniform float uNormalFlip;\n" +
        "uniform float uNormalLevels;\n" +
        "vec3 normalMapped(vec3 n) {\n" +
        "    vec3 t = vTangent.xyz - n * dot(n, vTangent.xyz);\n" +
        "    if (dot(t, t) < 1e-12) return n;\n" +
        "    t = normalize(t);\n" +
        "    vec3 b = cross(n, t) * vTangent.w;\n" +
        "    vec3 c = sg_texMip(uNormalMap, uNormalFlip, uNormalLevels, vUv).rgb;\n" +
        "    vec3 m = vec3((c.x * 2.0 - 1.0) * uNormalStrength, (c.y * 2.0 - 1.0) * uNormalStrength, c.z * 2.0 - 1.0);\n" +
        "    vec3 p = t * m.x + b * m.y + n * m.z;\n" +
        "    return dot(p, p) < 1e-12 ? n : normalize(p);\n" +
        "}\n"

    def depthFragmentSource(): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec3 uEye;\n" +
        depthGraySource() +
        "void main() {\n" +
        "    float g = depthGray(vWorld);\n" +
        "    fragColor = vec4(g, g, g, 1.0);\n" +
        "}\n"

    /// ビルボードの頂点シェーダー: カメラの right / up で四角を立てる（aCorner は 0〜1・y は下向き）。
    def billboardVertexSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 aCorner;\n" +
        "uniform mat4 uView;\n" +
        "uniform mat4 uProj;\n" +
        "uniform vec3 uCenter;\n" +
        "uniform vec3 uRight;\n" +
        "uniform vec3 uUp;\n" +
        "uniform vec2 uAnchor;\n" +
        "uniform vec2 uSize;\n" +
        "uniform vec4 uUvRect;\n" +
        "out vec3 vWorld;\n" +
        "out vec2 vUv;\n" +
        "void main() {\n" +
        "    vec3 world = uCenter + uRight * ((aCorner.x - uAnchor.x) * uSize.x)\n" +
        "                         + uUp * ((uAnchor.y - aCorner.y) * uSize.y);\n" +
        "    vWorld = world;\n" +
        "    vUv = uUvRect.xy + aCorner * uUvRect.zw;\n" +
        "    gl_Position = uProj * uView * vec4(world, 1.0);\n" +
        "}\n"

    def billboardFragmentSource(): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uImage;\n" +
        "uniform vec3 uTint;\n" +
        "uniform int uLit;\n" +
        "uniform vec3 uFacing;\n" +
        "uniform int uDepthOut;\n" +
        lightSource() +
        depthGraySource() +
        "void main() {\n" +
        "    vec4 texel = texture(uImage, vUv);\n" +
        "    if (texel.a < 0.5) discard;\n" +
        "    if (uDepthOut == 1) {\n" +
        "        float g = depthGray(vWorld);\n" +
        "        fragColor = vec4(g, g, g, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    vec3 c = texel.rgb * uTint;\n" +
        "    if (uLit == 1) c = fogged(c * lightAt(vWorld, normalize(uFacing)), vWorld);\n" +
        "    fragColor = vec4(c, 1.0);\n" +
        "}\n"

    /// 空の frag（式は Scene3d.skyColorOf・向きは Scene3d.skyDirectionOf。NDC は画素の真ん中の gl_FragCoord と viewport から）。
    def skyFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec4 uViewport;\n" +
        "uniform vec3 uForward;\n" +
        "uniform vec3 uRight;\n" +
        "uniform vec3 uUp;\n" +
        "uniform vec3 uZenith;\n" +
        "uniform vec3 uHorizon;\n" +
        "uniform vec3 uGround;\n" +
        "uniform float uCurve;\n" +
        "uniform int uDepthOut;\n" +
        "void main() {\n" +
        "    if (uDepthOut == 1) {\n" +
        "        fragColor = vec4(1.0, 1.0, 1.0, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    vec2 ndc = (gl_FragCoord.xy - uViewport.xy) / uViewport.zw * 2.0 - 1.0;\n" +
        "    vec3 d = normalize(uForward + uRight * ndc.x + uUp * ndc.y);\n" +
        "    vec3 c = d.y >= 0.0 ? mix(uHorizon, uZenith, min(1.0, pow(d.y, uCurve)))\n" +
        "                        : mix(uHorizon, uGround, min(1.0, pow(-d.y, uCurve)));\n" +
        "    fragColor = vec4(c, 1.0);\n" +
        "}\n"

    /// Design の FBO を viewport 全面へ貼る（FBO は行 0 が下なので、四角の上を v = 1 に当てる）。
    def blitVertexSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 aCorner;\n" +
        "out vec2 vUv;\n" +
        "void main() {\n" +
        "    vUv = vec2(aCorner.x, 1.0 - aCorner.y);\n" +
        "    gl_Position = vec4(aCorner.x * 2.0 - 1.0, 1.0 - aCorner.y * 2.0, 0.0, 1.0);\n" +
        "}\n"

    def blitFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uImage;\n" +
        "void main() {\n" +
        "    fragColor = texture(uImage, vUv);\n" +
        "}\n"
}
