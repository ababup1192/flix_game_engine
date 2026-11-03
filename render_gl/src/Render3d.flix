// Render3d — 3D の場面（Scene3d.RenderCmd）を GL で深度つきで描く。メッシュの置き場・3D のプログラム・光の uniform を持つ。
// makeRenderer で Scene3dRenderer.Renderer として 2D の描き手へ渡り、2D の並びの z の 1 点で draw が呼ばれる。その中だけ深度で前後を決めて、GL の状態を元へ戻して返す。
// 座標の約束（左手系・表の面は時計回り）は engine の scene3d/Scene3d.flix の頭。
// 影の地図は Render3d.Shadow・材質のある置いた物と場面の絵は Render3d.Material（render_gl/src/Render3d/）・シェーダーの字は Render3dGlsl。
//
// 光・かすみ・空の式の元は engine の LightModel3d の木。GLSL は木から作り（Render3dGlsl）、CPU の描き手は木から生成した関数を回す。
//   色 = 頂点の色 × tint × light。
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
//   空は深度を消した後、深度を書かずに場面の矩形いっぱいの四角で塗る（向きは Scene3d.skyBasisOf・式は LightModel3d.skyModel）。
mod Render3d {
    import java.lang.{Float => JFloat}
    import org.lwjgl.opengl.GL11
    import org.lwjgl.opengl.GL13
    import org.lwjgl.opengl.GL14
    import org.lwjgl.opengl.GL15
    import org.lwjgl.opengl.GL20
    import org.lwjgl.opengl.GL30
    import org.lwjgl.opengl.GL31
    use Render3dGlsl.{meshVertexSource, skinnedMeshVertexSource, litVertexSource, litFragmentSource,
                       depthFragmentSource, billboardVertexSource, billboardFragmentSource, skyFragmentSource, blitVertexSource, blitFragmentSource}
    use Render3d.Shadow.{bindShadowMap, putShadow, renderShadows, sweepShadowTargets, unbindShadowMap}
    use Render3d.Material.{drawMaterials, resolveTextureAs, splitByMaterial, sweepMaterials, sweepTextures3d}

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

    /// GL の左下原点の画素の矩形。
    pub type alias PixelBox = { x = Int32, y = Int32, width = Int32, height = Int32 }

    /// 場面 1 つと、Design の解像度で先に描いておいた描き先（Native なら None）と、先に描いておいた影の地図（無ければ None）と、
    /// 描き先が標本を持つか（multisampled = 真なら cutout の材質を alpha to coverage で描く）。
    type alias SceneItem = { cmd = Scene3d.RenderCmd, designTarget = Option[RenderTargetGl.Entry], shadow = Option[ShadowUse],
                                 multisampled = Bool }

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
        lightmapLevels = Int32, lightmapSrgb = Int32, lightmapIntensity = Int32, emissionIntensity = Int32
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
    type alias TextureSource = { textureOf = String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, own = Map[String, Texture3d.Texture3d] }

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
    def textureBudgetOf(config: GameEngine.EngineConfig): TextureBudget =
        { megabytes = config#scene3dTextureBudgetMB, count = config#scene3dTextureBudgetCount }

    /// 3D の描き手を、空の置き場で作る（textureBudget = 場面の絵の置き場の上限）。
    def fresh(textureBudget: TextureBudget): State \ IO =
        { textureByteBudget = Int32.toInt64(Int32.max(1, textureBudget#megabytes)) * 1048576i64,
          textureCountBudget = Int32.max(1, textureBudget#count), meshesRef = Ref.fresh(Static, Map.empty()), vertexTotal = Array#{0} @ Static,
          uploadStreak = Array#{0, 0, 0} @ Static, materialStreak = Array#{0, 0, 0} @ Static, programsRef = Ref.fresh(Static, None),
          skinnedRef = Ref.fresh(Static, None), skyRef = Ref.fresh(Static, None), skinWarnedRef = Ref.fresh(Static, Set.empty()),
          designTargetsRef = Ref.fresh(Static, Map.empty()), missingTexturesRef = Ref.fresh(Static, Set.empty()),
          materialsRef = Ref.fresh(Static, Map.empty()), retiredMaterialsRef = Ref.fresh(Static, Nil),
          thrashWarnedRef = Ref.fresh(Static, Set.empty()), timeHolder = Array#{0.0} @ Static,
          shadowTargetsRef = Ref.fresh(Static, Map.empty()),
          shadowWarnedRef = Ref.fresh(Static, Set.empty()), textures3dRef = Ref.fresh(Static, Map.empty()),
          materialSamplers = Array#{0, 0, 0, 0, 0, 0, 0, 0} @ Static, mipCopiesRef = Ref.fresh(Static, Map.empty()),
          blankTexture = Array#{0} @ Static,
          sceneWarnedRef = Ref.fresh(Static, Set.empty()), countsHolder = Array#{0, 0, 0, 0, 0} @ Static }

    /// 2D の描き手へ渡す 3D の描き手を、空の置き場で作る。場面の絵の置き場の上限は config（project.json）から読む。
    pub def makeRenderer(config: GameEngine.EngineConfig): Scene3dRenderer.Renderer \ IO =
        let state = fresh(textureBudgetOf(config));
        { prepare = (gen, textureOf, dest, cmds) -> prepareNumbered(state, gen, textureOf, dest, cmds),
          endFrame = gen -> endFrame(state, gen),
          takeCounts = () -> takeCounts(state),
          readsTexture = readsTexture }

    /// 場面のどれかのビルボードが name の絵を貼るか（材質の Tex は数えない）。
    pub def readsTexture(name: String, scenes: List[Scene3d.RenderCmd]): Bool =
        List.exists(cmd -> List.exists(b -> Scene3d.billboardFieldsOf(b)#texture == name, cmd#scene#billboards), scenes)

    /// 場面を先に描いておき、番号で引いて描く形にする。
    def prepareNumbered(state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                        dest: Scene3dRenderer.Dest, cmds: List[Scene3d.RenderCmd]): Scene3dRenderer.Prepared \ IO =
        if (List.isEmpty(cmds)) Scene3dRenderer.noScenes()
        else {
            let items = List.toVector(prepareScenes(state, gen, textureOf, dest, cmds));
            { zIndexes = Vector.map(item -> item#cmd#scene#zIndex, items),
              draw = (vp, index) -> drawItem(state, gen, textureOf, vp, Vector.get(index, items)) }
        }

    /// 前に呼んでからの 3D の数（置いた物・描いた物・draw call・落とした点光源とスポット）を返し、0 に戻す。
    def takeCounts(state: State): FrameDiagnostics.Scene3dCounts \ IO =
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

    // ── 場面を描く（2D の並びの中から）──

    /// Design の解像度の場面を、そのテクスチャへ先に描いておく（2D の並びを描き始める前に呼ぶ）。
    /// dest#framebuffer = 描き終えた後に戻す描き先（今開いているレンダーターゲットか画面）・dest#format = その形式
    /// （Design の中継の描き先も同じ形式で作る — HDR の Pass の中で、中継だけ 0..1 に切られないように）。
    // WhyNot: 2D の並びの途中で FBO を替えて描かない — タイル型の GPU で描き先の出し入れが重く、viewport と scissor の戻し漏れも増える。
    def prepareScenes(state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                      dest: Scene3dRenderer.Dest, cmds: List[Scene3d.RenderCmd]): List[SceneItem] \ IO =
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

    /// 場面 1 つを 2D の並びの中で描く。描き終えたら viewport を vp へ、scissor を切り、blend を Normal へ戻す。
    def drawItem(state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                 vp: Scene3dRenderer.Viewport, item: SceneItem): Unit \ IO =
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
    def sceneRect(vp: Scene3dRenderer.Viewport, cmd: Scene3d.RenderCmd): PixelBox =
        let (x0, y0, x1, y1) = DrawCmd.clipPixels({ scaleX = vp#scaleX, scaleY = vp#scaleY },
                                                  { position = cmd#at, size = cmd#scene#size });
        { x = vp#x + x0, y = vp#y + vp#height - y1, width = x1 - x0, height = y1 - y0 }

    /// scissor = 場面の矩形 ∩ clip ∩ design 領域（clip が外へはみ出しても黒帯を侵さない）。
    def clipBox(vp: Scene3dRenderer.Viewport, rect: PixelBox, clip: Option[Rect2.Rect2]): PixelBox =
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
    def renderDesign(state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
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

    // ── 1 つの場面 ──

    /// 場面 1 つを、今 bind されている描き先の area へ描く。描き終えたら深度・カリングを切り、blend・program・VAO を戻す。
    /// viewport と scissor は呼ぶ側が戻す。stencil には触らない（mask 付きの Shader 面が使う）。
    def drawScene(state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
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
            materialTextureNames(d) |> List.forEach(lt -> { let (label, name, textureUse) = lt; discard resolveTextureAs(state, gen, source, label, name, textureUse) }));
        if (List.isEmpty(culledMaterials)) () else GL13.glActiveTexture(GL13.GL_TEXTURE0);
        countInstances(state, total, List.count(d -> not d#culled, plain) + List.count(d -> not d#draw#culled, materials))

    /// 材質のある物 d を描く時に貼る絵の (知らせの中の呼び名, 名前, 使い方)（材質の絵・法線マップ・lightmap。描く時の知らせと同じ呼び名・同じ段の鍵）。
    def materialTextureNames(d: MaterialDraw): List[(String, String, Texture3d.TextureUse)] =
        let reads = if (List.isEmpty(d#entry#texReads)) Nil
                    else ShaderDoc.materialTexReads(d#material#spec, d#material#emission) |> List.take(Scene3d.maxMaterialTextures())
                        |> List.map(nf -> ("材質の絵", fst(nf), Texture3d.TextureUse.MaterialTexture));
        let normal = if (d#entry#normalMapped) d#material#normalMap |> Option.toList |> List.map(n -> ("材質の絵", n#texture, Texture3d.TextureUse.NormalMap)) else Nil;
        let baked = if (d#entry#lightmapped) Scene3d.lightmapOfFields(d#draw#fields) |> Option.toList
                        |> List.map(lm -> ("lightmap の絵", lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace))) else Nil;
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
                putLinearizedColor(locs#zenith, f#zenith);
                putLinearizedColor(locs#horizon, f#horizon);
                putLinearizedColor(locs#ground, f#ground);
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

    def warnSceneOnce(state: State, key: String, message: String): Unit \ IO =
        let warned = Ref.get(state#sceneWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), state#sceneWarnedRef);
            Log.warn(message)
        }

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
                if (d#culled) () else putLinearizedColor(locs#tint, d#fields#tint);
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

    /// 場面の色（tint・空の色）を線形へ戻してから入れる（光の色・ambient・かすみは lightDataOf）。
    def putLinearizedColor(loc: Int32, c: Color): Unit \ IO =
        putColor(loc, Texture3d.srgbToLinearColor(c))

    def putDepthRange(loc: Int32, depthRange: { near = Float64, range = Float64 }): Unit \ IO =
        GL20.glUniform2f(loc, RenderUtil.f32(depthRange#near), RenderUtil.f32(Float64.max(0.000001, depthRange#range)))

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
    def endFrame(state: State, gen: Int64): Unit \ IO =
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
    def drawBillboards(state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, locs: BillboardLocs,
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

    def drawBillboard(state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, locs: BillboardLocs,
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
                putLinearizedColor(locs#tint, b#tint);
                GL20.glUniform1i(locs#lit, if (b#lit) 1 else 0);
                GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 6);
                countDrawCall(state)
        }

    /// 貼る範囲の uv（左上 u・v と幅・高さ）。レンダーターゲットは行 0 が下なので v を反転する。
    def putUvRect(loc: Int32, texture: Scene3dRenderer.RegisteredTexture, source: Rect2.Rect2): Unit \ IO =
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

    /// 光を uniform の並びへ詰める（点光源・スポットは選んだ後の物）。光の color・ambient・かすみの色は線形の量へ戻してから詰める
    /// （hemisphere・intensity・range は線形の量のまま）。
    def lightDataOf(scene: Scene3d.Scene3dCmd): LightData \ IO =
        let toLinear = Texture3d.srgbToLinearColor;
        let env = { ambient = toLinear(scene#environment#ambient),
                    fog = scene#environment#fog |> Option.map(f -> { color = toLinear(f#color) | f }) | scene#environment };
        let eye = scene#camera#eye;
        let points = scene#pointLights |> List.map(l -> { color = toLinear(l#color) | l });
        let spots = scene#spotLights |> List.map(l -> { color = toLinear(l#color) | l });
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
        let lit = compile(litVertexSource(false), litFragmentSource(), "scene3d:lit");
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
        let lit = compile(litVertexSource(true), litFragmentSource(), "scene3d:lit:skin");
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

}
