// Render3d — 3D の場面（Scene3d.RenderCmd）を GL で深度つきで描く。メッシュの置き場・3D のプログラムを持つ。
// makeRenderer で Scene3dRenderer.Renderer として 2D の描き手へ渡り、2D の並びの z の 1 点で draw が呼ばれる。その中だけ深度で前後を決めて、GL の状態を元へ戻して返す。
// 座標の約束（左手系・表の面は時計回り）は engine の scene3d/Scene3d.flix の頭。
// 光の uniform は Render3d.Light・影の地図は Render3d.Shadow・材質のある置いた物と場面の絵は Render3d.Material（render_gl/src/Render3d/）・シェーダーの字は Render3dGlsl。
//
// 光・かすみ・空の式の元は engine の LightModel3d の木。GLSL は木から作り（Render3dGlsl）、CPU の描き手は木から生成した関数を回す。
//   色 = 頂点の色 × tint × light。
//   材質のある物は 色 = fog(albedo × tint × light) + emission（頂点の色は掛けない）。cutout なら α < 0.5 を捨てる。
//   材質の Tex は unit 0〜5（ShaderDoc.materialTexReads の並び・上限 Scene3d.maxMaterialTextures()）に貼り、材質を描いた後に
//   その unit の sampler を外して unit 0 へ戻す（ビルボードと 2D の面が unit 0 で読む）。法線マップは unit 6・影の地図は unit 7。
//   骨つきの物の joint 行列は unit 10 の絵（Render3d.JointTexture）を頂点シェーダーが読む。行は prepare の中で 1 回だけ決めて MeshDraw に持たせる。
//   同じ形と材質の物は batch （Render3d.Batch）にして 1 回の instanced draw で描き、batch にならない物も instance 数 1 で同じプログラムで描く。world・法線の行列・tint・emissionIntensity・joint の行は
//   1 体ごとの値で、unit 11 の絵（Render3d.Instancing）を頂点シェーダーが uInstanceBase + gl_InstanceID で読む。
//   法線マップ（uv つきの形だけ）: T = normalize(T − N (N·T))・B = cross(N, T) × w・c = 絵の rgb・
//   m = ((c.x·2 − 1)·s, (c.y·2 − 1)·s, c.z·2 − 1)・n' = normalize(T m.x + B m.y + N m.z)。光の計算は n'、Spec の Normal は当てる前の N。
//   ビルボードの法線はカメラへ向く向き（−forward）。Output.Depth の灰色は目からの距離で (d − near) / range。
//   半透明（材質の blend）・両面（doubleSided）・空（sky）の約束は SoftRaster3d の頭と同じ:
//   描く順は 不透明（頂点の色 → 材質をプログラムごと）→ ビルボード → 半透明（Scene3d.blendOrderOf の順・深度は読むが書かない・
//   glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)・出す α は材質の albedo.a）。
//   両面の材質は GL_CULL_FACE をその物だけ切り、裏の面（!gl_FrontFacing）は光の計算の法線を裏返す。
//   空は深度を消した後、深度を書かずに場面の矩形いっぱいの四角で塗る（向きは Scene3d.skyBasisOf・式は LightModel3d.skyModel）。
// 先に上げた物（Render3d.Preload）は、置き場の上限で捨てる順を後ろへ回す。形と絵は上限に足りなければそれらも捨てて 1 回知らせ、材質のプログラムは大きさの上限が無いので必ず守る。
mod Render3d {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use Render3dGlsl.{meshVertexSource, skinnedMeshVertexSource, litVertexSource, litFragmentSource,
                       depthFragmentSource, billboardVertexSource, billboardFragmentSource, skyFragmentSource, blitVertexSource, blitFragmentSource}
    use Render3d.Light.{lightDataOf, putLights}
    use Render3d.Batch.{MaterialBatch, MeshBatch}
    use Render3d.ScenePlan.{SceneDraws, SceneInputs, SceneItem, SceneTarget, planScenes}
    use Render3d.Shadow.{bindShadowMap, putShadow, renderShadows, sweepShadowTargets, unbindShadowMap}
    use Render3d.Material.{blankTextureId, budgetEvictions, drawMaterials, resolveTextureAs, sweepMaterials, sweepTextures3d}
    use Render3d.Counts.{Counter, Phase, count, countDrawCall, countInstances, noteDroppedLights, takeCounts, timed}

    // ── 型 ──

    /// GPU に置いたメッシュ 1 つ。vbo は位置・法線・色の 9 個ずつを交互に並べた物。lastUsed = 最後に描いたコマの世代（要素 1 つ）。
    /// skin = ジョイントの番号と重みの VBO（ジョイントの無い形は None）。
    /// surface = uv（location 5）の VBO（uv の無い形は None）。tangents = タンジェント（location 6）の VBO（要素 1 つ・0 はまだ上げていない）。
    // WhyNot: uv を位置・法線・色の並びへ混ぜない — uv の無い形まで stride が伸び、uv の無い形の頂点バッファの中身が変わる。
    // WhyNot: タンジェントを uv と同じ VBO で形を上げる時に上げない — 法線マップの材質で描く時まで求めずに済ませる（Mesh3d が初めて読む時に求める）。
    pub type alias MeshEntry = {
        vao = Int32, vbo = Int32, ibo = Int32, skin = Option[SkinBuffers], surface = Option[Int32], tangents = Array[Int32, Static], uv2 = Option[Int32],
        indexCount = Int32, vertexCount = Int32, lastUsed = Array[Int64, Static]
    }

    /// 頂点ごとのジョイントの番号（ivec4・location 3）と重み（vec4・location 4）の VBO。
    // WhyNot: 位置・法線・色の交互の並びへ混ぜない — 番号は整数の属性で、float の並びに入れると骨の無い形まで stride が伸びる。
    pub type alias SkinBuffers = { joints = Int32, weights = Int32 }

    /// GL の左下原点の画素の矩形。
    pub type alias PixelBox = { x = Int32, y = Int32, width = Int32, height = Int32 }

    /// 塗りのシェーダーへ渡す影。tex = 影の地図（深度テクスチャ）・matrix = Scene3d.shadowMatrix（列優先 16 個）・
    /// spotIndex = pickLights の後のスポットの並びの何番目に掛けるか。
    pub type alias ShadowUse = {
        tex = Int32, matrix = Array[Float32, Static], bias = Float64, pcfRadius = Int32, strength = Float64, spotIndex = Int32
    }

    /// 影の地図の描き先 1 枚（深度テクスチャだけを付けた FBO）。size = 縦横の画素・lastUsed = 最後に描いたコマの世代。
    type alias ShadowTarget = { fbo = Int32, tex = Int32, size = Int32, lastUsed = Int64 }

    /// 影を落とす光 1 つ（光の種類に依らない）。matrix = world → 光の clip（Scene3d が Float64 で出す）・
    /// frustum = 影を落とす物の間引き・settings = mapSize・bias・pcfRadius・strength。
    type alias ShadowCaster = { matrix = Mat4.Mat4, frustum = Frustum.Frustum, settings = Scene3d.ShadowMap }

    /// 影の地図を描く材料。spotIndex = 影を落とすスポットの pickLights の後の並びの番号。plain = 骨の無い物・skinned = 骨つきの物（描く順）。
    type alias ShadowPlan[b] = { caster = ShadowCaster, spotIndex = Int32, plain = List[b], skinned = List[b] }

    /// 光の uniform の location（頂点の色のプログラムとビルボードのプログラムで同じ名前）。
    type alias LightLocs = {
        ambient = Int32, hemisphere = Int32, toonSteps = Int32,
        pointCount = Int32, pointPos = Int32, pointColor = Int32, pointRange = Int32,
        spotCount = Int32, spotPos = Int32, spotDir = Int32, spotColor = Int32, spotRange = Int32, spotCone = Int32,
        fogOn = Int32, fogColor = Int32, fogRange = Int32, eye = Int32
    }

    /// instanceBase = batch の頭の 1 体ごとの値の番号の uniform。
    type alias MeshLocs = { program = Int32, view = Int32, proj = Int32, instanceBase = Int32 }

    /// 影の uniform の location（頂点の色のプログラムと材質のプログラム。ビルボードは影を受けない）。
    type alias ShadowLocs = { on = Int32, spot = Int32, matrix = Int32, map = Int32, bias = Int32, pcf = Int32, strength = Int32 }

    type alias LitLocs = { mesh = MeshLocs, light = LightLocs, shadow = ShadowLocs }

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

    /// 骨つきの版のプログラム。
    type alias SkinnedPrograms = { lit = LitLocs, depth = DepthLocs }

    /// 置いた物 1 つと、描く時に曲げる Pose（Scene3d.skinningOf。None なら骨の無い版で曲げずに描く）と、その joint texture の行（骨の無い物は 0）。
    /// culled = 視錐台の外なので描かない（形と絵は今のコマで使った物として数え、GPU から捨てない）。
    type alias MeshDraw = { fields = Scene3d.InstanceFields, pose = Option[Pose3d.Pose3d], poseRow = Int32, culled = Bool }

    /// 材質のプログラムの uniform の location。params = uParamN の location（paramNames の並び）・
    /// texFlips = uTexFlipN の location（texReads の並び）。
    type alias MaterialLocs = {
        mesh = MeshLocs, light = LightLocs, shadow = ShadowLocs, time = Int32, cutout = Int32,
        depthOut = Int32, depthRange = Int32, params = List[Int32], texFlips = List[Int32],
        normalStrength = Int32, normalFlip = Int32, texLevels = List[Int32], normalLevels = Int32,
        lightmapLevels = Int32, lightmapSrgb = Int32, lightmapIntensity = Int32
    }

    /// 組んだ材質のプログラム 1 つ。spec と emission は組んだ時の物（次に来た材質と比べる）。
    /// known = 同じ GLSL を生むと確かめた材質の参照（最近使った順・Render3d.Material.knownMaterialLimit 個まで。参照が合えば木を比べない）。
    /// paramNames = ShaderGen.compile3d が uParamN に割り当てた名前の並び・texReads = uTexN に貼る (名前, 補間) の並び
    /// （組んだ時の材質の名前。同じプログラムを名前だけ違う材質が使うので、貼る名前は描く材質から引き直す）。
    /// locs#mesh#program が 0 なら組めなかった。
    type alias MaterialEntry = {
        spec = ShaderDoc.Spec, emission = Option[ShaderDoc.Shade], known = List[(ShaderDoc.Spec, Option[ShaderDoc.Shade])], paramNames = List[String],
        texReads = List[(String, ShaderDoc.FilterMode)], normalMapped = Bool, lightmapped = Bool, coverage = Bool, locs = MaterialLocs, lastUsed = Int64
    }

    /// 材質の Tex の名前を絵に引く元。textureOf = 全体の登録（project.json・レンダーターゲット）・
    /// own = 場面の textures（Texture3d.name → 絵）。
    type alias TextureSource = { textureOf = String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, own = Map[String, Texture3d.Texture3d] }

    /// GPU に上げた場面の絵 1 枚（Texture3d の contentHash で引く）。levels = 段の数・bytes = 段を合わせた置き場の大きさ・
    /// lastUsed = 最後に貼ったコマの世代。
    type alias Texture3dEntry = { texId = Int32, levels = Int32, bytes = Int64, lastUsed = Int64 }

    /// 全体の登録の絵を 3D の材質のために段つきで上げ直した写し。sourceId と version が元の絵と食い違えば作り直す。
    /// bytes = 段を合わせた置き場の大きさ（場面の絵と同じ上限に数える）。
    // WhyNot: 元のテクスチャに段を足さない — 2D の sprite と面は段の無い元の絵を読む決まりで、そちらの絵を変えない。
    type alias MipCopy = { sourceId = Int32, version = String, texId = Int32, levels = Int32, bytes = Int64, lastUsed = Int64 }

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

    /// 置いた物をどう描くか。Instanced = batch にして 1 回の instanced draw・OneByOne = 全部の物を batch にせず、物ごとの材質で来た順に描く（batch の鍵と順の確かめの比べ相手）。
    pub enum DrawMode with Eq {
        case Instanced
        case OneByOne
    }

    /// 置き場の上限に数える絵の鍵。Scene = 場面の絵（textures3dRef の鍵）・Copy = 全体の登録の絵の段つきの写し（mipCopiesRef の鍵）。
    pub enum TextureSlot with Eq, Order, ToString {
        case Scene(String)
        case Copy(String)
    }

    /// 材質の絵 1 枚の読み方 (知らせの中の呼び名, 名前, 使い方)。
    pub type alias TextureRead = (String, String, Texture3d.TextureUse)

    /// 先に上げた物の控え。builtKey = 最後に上げた宣言の key・meshes・programs・textures = 上げた物（置き場の鍵か、材質のプログラムの番号）・
    /// rebuilds = 組み直した世代（新しい物が頭・rebuildStreakLimit() 個まで）。
    pub type alias PreloadState = {
        builtKey = Option[DrawCmd.StaticKey], meshes = Set[String], programs = Set[Int32], textures = Set[TextureSlot], rebuilds = List[Int64]
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
        // 機種の側から上げられなかった場面の絵の鍵 → 最後に試したコマの世代（間を置いて試し直す）。
        platformRetryRef = Ref[Map[String, Int64], Static],
        // 場面について知らせ済みの鍵（見つからない絵・上限を超えた材質と光・場面の絵の置き場あふれ・空・lightmap・uv の無い法線マップ）。
        sceneWarnedRef = Ref[Set[String], Static],
        // 前に takeCounts してからの数（添え字は Render3d.Counts.Counter。FrameDiagnostics.Diagnostics.scene3dCounts の元）。
        countsHolder = Array[Int32, Static],
        // 前に takeCounts してからの CPU の区間の時間（ns。添え字は Render3d.Counts.Phase）。
        phaseNsHolder = Array[Int64, Static],
        // 前に takeCounts してから組んだ材質のプログラム（新しい物が頭）。
        materialBuildsRef = Ref[List[FrameDiagnostics.ShaderBuild], Static],
        // 先に上げた物の控え。
        preloadRef = Ref[PreloadState, Static],
        // joint texture の置き場。
        joints = Render3d.DataTexture.DataTextures,
        // 1 体ごとの値のテクスチャの置き場。
        instances = Render3d.DataTexture.DataTextures,
        // 置いた物の描き方。
        drawMode = DrawMode
    }

    // ── 決まりの数 ──

    /// この数のコマ使われなかった影の地図の描き先は GPU から捨てる。
    def idleTargetFrames(): Int64 = 128i64

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

    /// 影の無い場面で影の地図の代わりに使う unit（1 × 1 の透明な黒を貼ったままにする）。
    def blankTextureUnit(): Int32 = 9

    /// joint texture を貼るテクスチャの unit。
    def jointTextureUnit(): Int32 = 10

    /// 1 体ごとの値のテクスチャを貼るテクスチャの unit。
    def instanceTextureUnit(): Int32 = 11

    def maxShadowMapSize(): Int32 = Scene3d.maxShadowMapSize()

    def maxShadowPcfRadius(): Int32 = Scene3d.maxShadowPcfRadius()

    /// 場面の絵の置き場の上限。megabytes = GPU に持つ量（MB。project.json の scene3dTextureBudgetMB）・
    /// count = 枚数（scene3dTextureBudgetCount）。超えたら今と前のコマで使っていない古い物から捨てる。
    pub type alias TextureBudget = { megabytes = Int32, count = Int32 }

    /// EngineConfig（project.json）の 2 つのキーから場面の絵の置き場の上限を組む。
    def textureBudgetOf(config: GameEngine.EngineConfig): TextureBudget =
        { megabytes = config#scene3dTextureBudgetMB, count = config#scene3dTextureBudgetCount }

    /// 3D の描き手を、空の置き場で作る（textureBudget = 場面の絵の置き場の上限）。
    def fresh(textureBudget: TextureBudget, drawMode: DrawMode): State \ IO =
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
          blankTexture = Array#{0} @ Static, platformRetryRef = Ref.fresh(Static, Map.empty()),
          sceneWarnedRef = Ref.fresh(Static, Set.empty()), countsHolder = Array.repeat(Static, Render3d.Counts.counterSlots(), 0),
          phaseNsHolder = Array.repeat(Static, Render3d.Counts.phaseSlots(), 0i64), materialBuildsRef = Ref.fresh(Static, Nil),
          preloadRef = Ref.fresh(Static, Render3d.Preload.empty()),
          joints = Render3d.DataTexture.freshTextures(), instances = Render3d.DataTexture.freshTextures(), drawMode = drawMode }

    /// 2D の描き手へ渡す 3D の描き手を、空の置き場で作る。場面の絵の置き場の上限は config（project.json）から読む。
    pub def makeRenderer(gl: GlContext, config: GameEngine.EngineConfig, drawMode: DrawMode): Scene3dRenderer.Renderer \ IO =
        let state = fresh(textureBudgetOf(config), drawMode);
        { prepare = (gen, textureOf, dest, cmds) -> prepareNumbered(gl, state, gen, textureOf, dest, cmds),
          endFrame = gen -> endFrame(gl, state, gen),
          takeCounts = () -> takeCounts(state),
          readsTexture = readsTexture,
          preload = (gen, textureOf, cmd) -> Render3d.Preload.upload(gl, state, gen, textureOf, cmd) }

    /// 場面のどれかのビルボードが name の絵を貼るか（材質の Tex は数えない）。
    pub def readsTexture(name: String, scenes: List[Scene3d.RenderCmd]): Bool =
        List.exists(cmd -> List.exists(b -> Scene3d.billboardFieldsOf(b)#texture == name, cmd#scene#billboards), scenes)

    /// 場面を先に描いておき、番号で引いて描く形にする。
    def prepareNumbered(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                        dest: Scene3dRenderer.Dest, cmds: List[Scene3d.RenderCmd]): Scene3dRenderer.Prepared \ IO =
        if (List.isEmpty(cmds)) Scene3dRenderer.noScenes()
        else {
            let items = List.toVector(prepareScenes(gl, state, gen, textureOf, dest, cmds));
            { zIndexes = Vector.map(item -> item#cmd#scene#zIndex, items),
              draw = (vp, index) -> drawItem(gl, state, gen, textureOf, vp, Vector.get(index, items)) }
        }

    // ── 場面を描く（2D の並びの中から）──

    /// Design の解像度の場面を、そのテクスチャへ先に描いておく（2D の並びを描き始める前に呼ぶ）。
    /// dest#framebuffer = 描き終えた後に戻す描き先（今開いているレンダーターゲットか画面）・dest#format = その形式
    /// （Design の中継の描き先も同じ形式で作る — HDR の Pass の中で、中継だけ 0..1 に切られないように）。
    // WhyNot: 2D の並びの途中で FBO を替えて描かない — タイル型の GPU で描き先の出し入れが重く、viewport と scissor の戻し漏れも増える。
    def prepareScenes(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                      dest: Scene3dRenderer.Dest, cmds: List[Scene3d.RenderCmd]): List[SceneItem] \ IO =
        // 影の地図は全部の場面の姿勢を上げた後に描く — 影の道も同じ行を読む。
        let (plans, jointTexture, instanceTexture) = timed(state, Phase.Split, () -> {
            let (planned, rows) = planScenes(gl, state, gen, dest, cmds);
            let joints = Render3d.JointTexture.upload(gl, state, gen, rows);
            let (numbered, instances) = Render3d.Instancing.upload(gl, state, gen, planned);
            (numbered, joints, instances)
        });
        // 影の地図は Design の場面より先に描く — Design の場面の塗りがその地図を読む。
        let shadows = timed(state, Phase.Shadows, () -> renderShadows(gl, state, gen, List.map(plan -> plan#shadowPlan, plans)));
        let designCount = Array#{0} @ Static;
        let items = List.zip(plans, shadows) |> List.map(ps -> {
            let (plan, shadow) = ps;
            let inputs = { draws = plan#draws, shadow = shadow, jointTexture = jointTexture, instanceTexture = instanceTexture };
            let target = match plan#cmd#scene#resolution {
                case Scene3d.Resolution.Native => SceneTarget.Native(inputs)
                case Scene3d.Resolution.Design =>
                    let index = Array.get(0, designCount);
                    Array.put(index + 1, 0, designCount);
                    SceneTarget.Design(renderDesign(gl, state, gen, textureOf, (index, dest#format), inputs, plan#cmd))
            };
            { cmd = plan#cmd, target = target }
        });
        let movedTarget = Array.get(0, designCount) > 0 or List.exists(Option.nonEmpty, shadows);
        if (movedTarget) gl.bindFramebuffer(GlConst.FRAMEBUFFER, dest#framebuffer) else ();
        items

    /// 場面 1 つを 2D の並びの中で描く。描き終えたら viewport を vp へ、scissor を切り、blend を Normal へ戻す。
    def drawItem(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                 vp: Scene3dRenderer.Viewport, item: SceneItem): Unit \ IO =
        let scene = item#cmd#scene;
        let rect = sceneRect(vp, item#cmd);
        let scissor = clipBox(vp, rect, item#cmd#clip);
        if (rect#width <= 0 or rect#height <= 0 or scissor#width <= 0 or scissor#height <= 0) ()
        else match item#target {
            case SceneTarget.Native(inputs)       => timed(state, Phase.Draw, () -> drawScene(gl, state, gen, textureOf,
                                                         { viewport = rect, scissor = scissor, fillBackground = true }, inputs, scene))
            case SceneTarget.Design(Some(target)) => blitDesign(gl, state, rect, scissor, target)
            case SceneTarget.Design(None)         => ()
        };
        gl.viewport(vp#x, vp#y, vp#width, vp#height);
        gl.disable(GlConst.SCISSOR_TEST);
        gl.enable(GlConst.BLEND);
        RenderSprite.applyBlend(gl, DrawCmd.BlendMode.Normal)

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

    /// Design の場面を design px の FBO に透明から描く。大きさが 0 以下なら None。1 画素に満たない辺は CPU の描き手と同じ 1 画素で描く。
    def renderDesign(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                     slot: (Int32, RenderTarget.Format), inputs: SceneInputs, cmd: Scene3d.RenderCmd): Option[RenderTargetGl.Entry] \ IO =
        let w = Int32.max(1, Num.floorInt(cmd#scene#size#x + 0.5));
        let h = Int32.max(1, Num.floorInt(cmd#scene#size#y + 0.5));
        if (cmd#scene#size#x <= 0.0 or cmd#scene#size#y <= 0.0) None
        else {
            let target = designTarget(gl, state, slot, w, h);
            RenderTargetGl.bind(gl, target);
            let full = { x = 0, y = 0, width = w, height = h };
            gl.viewport(0, 0, w, h);
            gl.disable(GlConst.SCISSOR_TEST);
            gl.clearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
            gl.clear(GlConst.COLOR_BUFFER_BIT);
            timed(state, Phase.Draw, () -> drawScene(gl, state, gen, textureOf, { viewport = full, scissor = full, fillBackground = true }, inputs, cmd#scene));
            gl.disable(GlConst.SCISSOR_TEST);
            Some(target)
        }

    /// (番号, 形式) の Design の描き先。大きさが変わったら作り直し、古い方は捨てる。
    /// WhyNot: 鍵を番号だけにしない — 画面（Rgba8Unorm）と HDR の Pass で同じ番号の場面を描くと、コマごとに作り直しが続く。
    /// 鍵の形式は Format の名前（Map の鍵には Order が要り、Format は Eq と ToString だけを持つ）。
    def designTarget(gl: GlContext, state: State, slot: (Int32, RenderTarget.Format), w: Int32, h: Int32): RenderTargetGl.Entry \ IO =
        let (index, format) = slot;
        let key = (index, ToString.toString(format));
        let targets = Ref.get(state#designTargetsRef);
        match Map.get(key, targets) {
            case Some(e) if e#width == w and e#height == h => e
            case old =>
                Option.forEach(e -> RenderTargetGl.destroy(gl, e), old);
                count(state, Counter.TargetRebuilds, 1);
                let made = RenderTargetGl.create(gl, w, h, format);
                Ref.put(Map.insert(key, made, targets), state#designTargetsRef);
                made
        }

    /// Design の FBO のテクスチャを、場面の矩形へ最も近い画素で α で重ねる。FBO の色は α を掛けた後の値として重ねる
    /// （GL_ONE, GL_ONE_MINUS_SRC_ALPHA）: 透明から描いた FBO に半透明を重ねると、色は src × α・α は α になるため。
    /// 半透明の無い場面の FBO の画素は α が 0（色も 0）か 1 なので、Normal で重ねた時と 1 bit も同じ。
    def blitDesign(gl: GlContext, state: State, rect: PixelBox, scissor: PixelBox, target: RenderTargetGl.Entry): Unit \ IO =
        let programs = programsOf(gl, state);
        if (programs#blit == 0) ()
        else {
            gl.viewport(rect#x, rect#y, rect#width, rect#height);
            gl.enable(GlConst.SCISSOR_TEST);
            gl.scissor(scissor#x, scissor#y, scissor#width, scissor#height);
            gl.enable(GlConst.BLEND);
            gl.blendFunc(GlConst.ONE, GlConst.ONE_MINUS_SRC_ALPHA);
            gl.useProgram(programs#blit);
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindTexture(GlConst.TEXTURE_2D, target#tex);
            gl.bindVertexArray(programs#quadVao);
            gl.uniform1i(gl.getUniformLocation(programs#blit, "uImage"), 0);
            gl.drawArrays(GlConst.TRIANGLES, 0, 6);
            gl.bindVertexArray(0);
            gl.useProgram(0)
        }

    // ── 1 つの場面 ──

    /// 場面 1 つを、今 bind されている描き先の area へ描く。描き終えたら深度・カリングを切り、blend・program・VAO を戻す。
    /// viewport と scissor は呼ぶ側が戻す。stencil には触らない（mask 付きの Shader 面が使う）。
    def drawScene(gl: GlContext, state: State, gen: Int64, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO,
                  area: { viewport = PixelBox, scissor = PixelBox, fillBackground = Bool }, inputs: SceneInputs,
                  scene: Scene3d.Scene3dCmd): Unit \ IO =
        Array.put(scene#time, 0, state#timeHolder);
        let frustum = Scene3d.frustumOf(scene);
        let programs = programsOf(gl, state);
        let background = if (area#fillBackground and Option.isEmpty(scene#sky)) scene#environment#background else None;
        beginScene(gl, area#viewport, area#scissor, background);
        if (area#fillBackground) drawSky(gl, state, area#viewport, scene) else ();
        let picked = Scene3d.pickLights(scene#camera#eye, scene);
        noteDroppedLights(state, scene);
        let lights = lightDataOf(picked);
        let view = matrixArray(Camera3d.viewMatrix(scene#camera));
        let proj = matrixArray(Camera3d.projectionMatrix(scene#camera, Scene3d.aspectOf(scene)));
        let shadow = inputs#shadow;
        let camera = { view = view, proj = proj, lights = lights, shadow = shadow, frustum = frustum };
        let source = { textureOf = textureOf, own = scene#textures |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap };
        let draws = inputs#draws;
        Render3d.DataTexture.bind(gl, jointTextureUnit(), inputs#jointTexture);
        Render3d.DataTexture.bind(gl, instanceTextureUnit(), inputs#instanceTexture);
        noteCulled(gl, state, gen, source, List.length(scene#instances), List.append(draws#plain, draws#skinned), List.append(draws#opaque, draws#blended));
        match scene#output {
            case Scene3d.Output.Color =>
                bindShadowMap(gl, shadow);
                drawInstancesLit(gl, state, gen, programs#lit, camera, draws);
                drawMaterials(gl, state, gen, camera, MaterialPass.Color, source, draws#opaque);
                drawBillboards(gl, state, textureOf, programs#billboard, camera, scene);
                drawBlended(gl, state, gen, camera, source, scene#camera#eye, draws#blended);
                unbindShadowMap(gl, shadow)
            case Scene3d.Output.Depth(dr) =>
                drawInstancesDepth(gl, state, gen, programs#depth, camera, scene#camera#eye, dr, draws);
                drawMaterials(gl, state, gen, camera, MaterialPass.Depth(dr), source, draws#opaque);
                drawBillboards(gl, state, textureOf, programs#billboard, camera, scene)
        };
        endScene(gl)

    /// 半透明の材質の物を Scene3d.blendOrderOf の順（遠い物から）に、深度を読むが書かずに重ねる。無ければ何もしない。
    def drawBlended(gl: GlContext, state: State, gen: Int64, camera: CameraData, source: TextureSource, eye: Vec3.Vec3, draws: List[MaterialBatch[MeshBatch]]): Unit \ IO =
        if (List.isEmpty(draws)) ()
        else {
            gl.depthMask(false);
            gl.enable(GlConst.BLEND);
            gl.blendFuncSeparate(GlConst.SRC_ALPHA, GlConst.ONE_MINUS_SRC_ALPHA, GlConst.ONE, GlConst.ONE_MINUS_SRC_ALPHA);
            drawMaterials(gl, state, gen, camera, MaterialPass.Color, source, Scene3d.blendOrderOf(eye, d -> d#batch#head#fields, draws));
            gl.disable(GlConst.BLEND);
            gl.depthMask(true)
        }

    /// 全部の物が視錐台の外の材質の batch の絵を、今のコマで使った物として置き場に数え（上げていなければ上げる）、置いた物と描いた物の数を足す。
    /// 描き始める前に済ませ、unit 0 へ戻す（初めての絵を上げる時に今の unit へ貼るので、描いている途中では呼ばない）。
    /// 間引いた batch の形は drawBatch が置き場に数える（描く段で描く物の無い batch も通す）。
    // WhyNot: 間引いた物を置き場で古いままにしない — 振り向くたびに形と絵を上げ直して止まり、毎コマ作り直しの知らせも鳴る。
    def noteCulled(gl: GlContext, state: State, gen: Int64, source: TextureSource, total: Int32,
                   plain: List[MeshBatch], materials: List[MaterialBatch[MeshBatch]]): Unit \ IO =
        let culledMaterials = List.filter(d -> d#batch#count == 0, materials);
        culledMaterials |> List.forEach(d ->
            materialTextureNames(d#entry, d#material, d#batch#head) |> List.forEach(lt -> { let (label, name, textureUse) = lt; discard resolveTextureAs(gl, state, gen, source, label, name, textureUse) }));
        if (List.isEmpty(culledMaterials)) () else gl.activeTexture(GlConst.TEXTURE0);
        countInstances(state, total, List.sumWith(b -> b#count, plain) + List.sumWith(d -> d#batch#count, materials))

    /// プログラム entry と材質 m で頭の物 head の batch を描く時に貼る絵の (知らせの中の呼び名, 名前, 使い方)（材質の絵・法線マップ・lightmap。描く時の知らせと同じ呼び名・同じ段の鍵）。
    def materialTextureNames(entry: MaterialEntry, m: Scene3d.MaterialFields, head: MeshDraw): List[TextureRead] =
        let reads = if (List.isEmpty(entry#texReads)) Nil
                    else ShaderDoc.materialTexReads(m#spec, m#emission) |> List.take(Scene3d.maxMaterialTextures())
                        |> List.map(nf -> ("材質の絵", fst(nf), Texture3d.TextureUse.MaterialTexture));
        let normal = if (entry#normalMapped) m#normalMap |> Option.toList |> List.map(n -> ("材質の絵", n#texture, Texture3d.TextureUse.NormalMap)) else Nil;
        let baked = if (entry#lightmapped) Scene3d.lightmapOfFields(head#fields) |> Option.toList
                        |> List.map(lm -> ("lightmap の絵", lm#texture, Texture3d.TextureUse.Lightmap(lm#colorSpace))) else Nil;
        List.flatten(reads :: normal :: baked :: Nil)

    /// 深度を使い始める: viewport と scissor を合わせ、地の色と深度を scissor の中だけ消し、深度とカリングを有効にする。
    def beginScene(gl: GlContext, viewport: PixelBox, scissor: PixelBox, background: Option[Color]): Unit \ IO =
        gl.viewport(viewport#x, viewport#y, viewport#width, viewport#height);
        gl.enable(GlConst.SCISSOR_TEST);
        gl.scissor(scissor#x, scissor#y, scissor#width, scissor#height);
        background |> Option.forEach(c -> {
            gl.clearColor(RenderUtil.f32(c#r), RenderUtil.f32(c#g), RenderUtil.f32(c#b), 1.0f32);
            gl.clear(GlConst.COLOR_BUFFER_BIT)
        });
        gl.depthMask(true);
        gl.clearDepth(1.0);
        gl.clear(GlConst.DEPTH_BUFFER_BIT);
        gl.enable(GlConst.DEPTH_TEST);
        gl.depthFunc(GlConst.LESS);
        gl.enable(GlConst.CULL_FACE);
        gl.frontFace(GlConst.CW);
        gl.cullFace(GlConst.BACK);
        gl.disable(GlConst.BLEND)

    /// 場面の sky が Some なら、今の scissor の中を空で塗る（深度は書かない・深度の判定もしない）。beginScene の後に呼ぶ。
    /// Output.Depth では白（一番奥）。sky と background が両方 Some なら 1 回だけ知らせる（background は beginScene に渡さない）。
    def drawSky(gl: GlContext, state: State, viewport: PixelBox, scene: Scene3d.Scene3dCmd): Unit \ IO =
        Scene3d.skyWarning(scene) |> Option.forEach(line -> warnSceneOnce(state, "@sky+background", line));
        scene#sky |> Option.forEach(sky -> {
            let locs = skyProgramOf(gl, state);
            if (locs#program == 0) ()
            else {
                let f = Scene3d.skyFieldsOf(sky);
                let basis = Scene3d.skyBasisOf(scene);
                gl.disable(GlConst.DEPTH_TEST);
                gl.disable(GlConst.CULL_FACE);
                gl.useProgram(locs#program);
                gl.uniform4f(locs#viewport, Int32.toFloat32(viewport#x), Int32.toFloat32(viewport#y),
                                 Int32.toFloat32(viewport#width), Int32.toFloat32(viewport#height));
                putVec3(gl, locs#forward, basis#forward);
                putVec3(gl, locs#right, basis#right);
                putVec3(gl, locs#up, basis#up);
                putLinearizedColor(gl, locs#zenith, f#zenith);
                putLinearizedColor(gl, locs#horizon, f#horizon);
                putLinearizedColor(gl, locs#ground, f#ground);
                gl.uniform1f(locs#curve, RenderUtil.f32(Scene3d.skyCurveOf(sky)));
                gl.uniform1i(locs#depthOut, match scene#output {
                    case Scene3d.Output.Color    => 0
                    case Scene3d.Output.Depth(_) => 1
                });
                gl.bindVertexArray(programsOf(gl, state)#quadVao);
                gl.drawArrays(GlConst.TRIANGLES, 0, 6);
                countDrawCall(state);
                gl.bindVertexArray(0);
                gl.useProgram(0);
                gl.enable(GlConst.CULL_FACE);
                gl.enable(GlConst.DEPTH_TEST)
            }
        })

    /// 深度とカリングを切り、blend を 2D の既定（Normal）へ、program と VAO を外す。
    def endScene(gl: GlContext): Unit \ IO =
        gl.disable(GlConst.DEPTH_TEST);
        gl.disable(GlConst.CULL_FACE);
        gl.depthMask(true);
        gl.enable(GlConst.BLEND);
        RenderSprite.applyBlend(gl, DrawCmd.BlendMode.Normal);
        gl.useProgram(0);
        gl.bindVertexArray(0)

    /// victims に先に上げた形 preloaded が入っていたら、1 回だけ知らせる。
    def warnDroppedMeshes(state: State, victims: List[String], preloaded: Set[String]): Unit \ IO =
        if (List.exists(k -> Set.memberOf(k, preloaded), victims))
            warnSceneOnce(state, "@preload-dropped-mesh", "scene3d: 先に上げた形を、頂点の上限 ${vertexBudget()} が足りないので捨てた — 次に出るコマで上げ直す（先に上げる形を減らす）")
        else ()

    /// victims に先に上げた絵 preloaded が入っていたら、1 回だけ知らせる。
    def warnDroppedTextures(state: State, victims: List[TextureSlot], preloaded: Set[TextureSlot]): Unit \ IO =
        if (List.exists(k -> Set.memberOf(k, preloaded), victims))
            warnSceneOnce(state, "@preload-dropped-texture", "scene3d: 先に上げた絵を、置き場の上限が足りないので捨てた — 次に出るコマで上げ直す"
                + "（先に上げる絵を減らすか、project.json の scene3dTextureBudgetCount / scene3dTextureBudgetMB を上げる）")
        else ()

    def warnSceneOnce(state: State, key: String, message: String): Unit \ IO =
        let warned = Ref.get(state#sceneWarnedRef);
        if (Set.memberOf(key, warned)) ()
        else {
            Ref.put(Set.insert(key, warned), state#sceneWarnedRef);
            Log.warn(message)
        }

    // ── 置いた物 ──

    /// 骨の無い物を locs で、骨つきの物を骨つきの版で描く（骨つきの版は骨つきの物がある時だけ組む）。
    def drawInstancesLit(gl: GlContext, state: State, gen: Int64, locs: LitLocs, camera: CameraData, draws: SceneDraws[MeshBatch]): Unit \ IO =
        drawLitWith(gl, state, gen, locs, camera, draws#plain);
        if (List.isEmpty(draws#skinned)) () else drawLitWith(gl, state, gen, skinnedProgramsOf(gl, state)#lit, camera, draws#skinned)

    def drawLitWith(gl: GlContext, state: State, gen: Int64, locs: LitLocs, camera: CameraData, batches: List[MeshBatch]): Unit \ IO =
        if (List.isEmpty(batches) or locs#mesh#program == 0) ()
        else {
            useMeshProgram(gl, locs#mesh, camera#view, camera#proj);
            putLights(gl, locs#light, camera#lights);
            putShadow(gl, locs#shadow, camera#shadow);
            batches |> List.forEach(drawBatch(gl, state, gen, locs#mesh))
        }

    /// Output.Depth の灰色で描く。骨の分け方は drawInstancesLit と同じ。
    def drawInstancesDepth(gl: GlContext, state: State, gen: Int64, locs: DepthLocs, camera: CameraData, eye: Vec3.Vec3,
                           depthRange: { near = Float64, range = Float64 }, draws: SceneDraws[MeshBatch]): Unit \ IO =
        let pass = { camera = camera, eye = eye, depthRange = depthRange };
        drawDepthWith(gl, state, gen, locs, pass, draws#plain);
        if (List.isEmpty(draws#skinned)) () else drawDepthWith(gl, state, gen, skinnedProgramsOf(gl, state)#depth, pass, draws#skinned)

    def drawDepthWith(gl: GlContext, state: State, gen: Int64, locs: DepthLocs,
                      pass: { camera = CameraData, eye = Vec3.Vec3, depthRange = { near = Float64, range = Float64 } },
                      batches: List[MeshBatch]): Unit \ IO =
        if (List.isEmpty(batches) or locs#mesh#program == 0) ()
        else {
            useMeshProgram(gl, locs#mesh, pass#camera#view, pass#camera#proj);
            gl.uniform3f(locs#eye, RenderUtil.f32(pass#eye#x), RenderUtil.f32(pass#eye#y), RenderUtil.f32(pass#eye#z));
            putDepthRange(gl, locs#depthRange, pass#depthRange);
            batches |> List.forEach(drawBatch(gl, state, gen, locs#mesh))
        }

    def putColor(gl: GlContext, loc: Int32, c: Color): Unit \ IO =
        gl.uniform3f(loc, RenderUtil.f32(c#r), RenderUtil.f32(c#g), RenderUtil.f32(c#b))

    /// 場面の色（tint・空の色）を線形へ戻してから入れる（光の色・ambient・かすみは lightDataOf）。
    def putLinearizedColor(gl: GlContext, loc: Int32, c: Color): Unit \ IO =
        putColor(gl, loc, Texture3d.srgbToLinearColor(c))

    def putDepthRange(gl: GlContext, loc: Int32, depthRange: { near = Float64, range = Float64 }): Unit \ IO =
        gl.uniform2f(loc, RenderUtil.f32(depthRange#near), RenderUtil.f32(Float64.max(0.000001, depthRange#range)))

    def useMeshProgram(gl: GlContext, locs: MeshLocs, view: Array[Float32, Static], proj: Array[Float32, Static]): Unit \ IO =
        gl.useProgram(locs#program);
        gl.uniformMatrix4fv(locs#view, false, view);
        gl.uniformMatrix4fv(locs#proj, false, proj)

    /// batch b を描く（形が置き場に無ければ上げる）。描く物の無い batch は、形を今のコマで使った物として置き場に数えるだけ。
    // WhyNot: 間引いた batch を meshEntry に通さずに飛ばさない — 置き場があふれると最後に使ったのが古い形から捨てるので、間引いた物から消え、振り向くたびに頂点を上げ直す。
    def drawBatch(gl: GlContext, state: State, gen: Int64, locs: MeshLocs, b: MeshBatch): Unit \ IO =
        let entry = meshEntry(gl, state, gen, b#head#fields#mesh);
        if (entry#indexCount <= 0 or b#count <= 0) ()
        else {
            gl.uniform1i(locs#instanceBase, b#first);
            gl.bindVertexArray(entry#vao);
            gl.drawElementsInstanced(GlConst.TRIANGLES, entry#indexCount, GlConst.UNSIGNED_INT, 0, b#count);
            countDrawCall(state)
        }

    def isSkinned(d: MeshDraw): Bool = Option.nonEmpty(d#pose)

    /// 描く順の鍵で並べる。鍵が同じ物は来た順（同じ入力はいつも同じ順）。
    // WhyNot: List.sortBy に鍵だけを渡さない — 安定ソートではなく、鍵の同じ物どうしの順が並びの中身で変わる。
    def inDrawOrder(keyOf: a -> Int32, xs: List[a]): List[a] =
        xs |> List.mapWithIndex((i, x) -> ((keyOf(x), i), x)) |> List.sortBy(fst) |> List.map(snd)

    def hasUv(d: MeshDraw): Bool = Option.nonEmpty(Mesh3d.uvs(d#fields#mesh))

    /// 置いた物を描く材料にする（outside が真なら間引く）。姿勢の行は描く物が決まった後で割り当てる。ジョイントの数の食い違いは形ごとに 1 回だけ知らせる（Scene3d.skinningWarning）。
    def meshDrawOf(state: State, outside: Scene3d.Instance3d -> Bool, placed: Scene3d.Instance3d): MeshDraw \ IO =
        let fields = Scene3d.instanceFieldsOf(placed);
        Scene3d.skinningWarning(placed) |> Option.forEach(message -> warnSkinOnce(state, Mesh3d.contentHash(fields#mesh), message));
        { fields = fields, pose = Scene3d.skinningOf(placed), poseRow = 0, culled = outside(placed) }

    def warnSkinOnce(state: State, meshKey: String, message: String): Unit \ IO =
        let warned = Ref.get(state#skinWarnedRef);
        if (Set.memberOf(meshKey, warned)) ()
        else {
            Ref.put(Set.insert(meshKey, warned), state#skinWarnedRef);
            Log.warn(message)
        }

    /// 列優先 16 個の float の並び（glUniformMatrix4fv に transpose = false で渡す形）。
    def matrixArray(m: Mat4.Mat4): Array[Float32, Static] \ IO =
        let out = Array.repeat(Static, 16, 0.0f32);
        Mat4.toColumns(m) |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, out));
        out

    // ── メッシュの置き場 ──

    /// contentHash で引き、無ければ上げる。どちらでも lastUsed を今の世代にする。
    // WhyNot: lastUsed を置き場の Map の値に持ち直さない — batch ごとに Map の道を作り直すことになり、小物の多い場面の draw の代金が増える。
    def meshEntry(gl: GlContext, state: State, gen: Int64, mesh: Mesh3d.Mesh3d): MeshEntry \ IO =
        let key = Mesh3d.contentHash(mesh);
        match Map.get(key, Ref.get(state#meshesRef)) {
            case Some(found) =>
                Array.put(gen, 0, found#lastUsed);
                found
            case None =>
                Array.put(1, 2, state#uploadStreak);
                count(state, Counter.MeshUploads, 1);
                let made = uploadMesh(gl, gen, mesh);
                Array.put(Array.get(0, state#vertexTotal) + made#vertexCount, 0, state#vertexTotal);
                Ref.put(Map.insert(key, made, Ref.get(state#meshesRef)), state#meshesRef);
                made
        }

    /// 形を GPU へ上げる（位置・法線・色を 9 個ずつ交互に並べた vbo と、添え字の ibo）。
    def uploadMesh(gl: GlContext, gen: Int64, mesh: Mesh3d.Mesh3d): MeshEntry \ IO =
        let n = Mesh3d.vertexCount(mesh);
        let vertices = interleave(mesh, n);
        let indices = Mesh3d.indices(mesh);
        let indexArray = Array.repeat(Static, Int32.max(1, Vector.length(indices)), 0);
        indices |> Vector.forEachWithIndex((i, v) -> Array.put(v, i, indexArray));
        let vao = gl.createVertexArray();
        let vbo = gl.createBuffer();
        let ibo = gl.createBuffer();
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, vertices, GlConst.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, GlConst.FLOAT, false, 36, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 3, GlConst.FLOAT, false, 36, 12);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 3, GlConst.FLOAT, false, 36, 24);
        let skin = uploadSkin(gl, mesh);
        let surface = uploadSurface(gl, mesh);
        let uv2 = uploadUv2(gl, mesh);
        gl.bindBuffer(GlConst.ELEMENT_ARRAY_BUFFER, ibo);
        gl.bufferData(GlConst.ELEMENT_ARRAY_BUFFER, indexArray, GlConst.STATIC_DRAW);
        gl.bindVertexArray(0);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindBuffer(GlConst.ELEMENT_ARRAY_BUFFER, 0);
        { vao = vao, vbo = vbo, ibo = ibo, skin = skin, surface = surface, tangents = Array#{0} @ Static, uv2 = uv2, indexCount = Vector.length(indices),
          vertexCount = n, lastUsed = Array#{gen} @ Static }

    /// ジョイントの番号と重みを、bind 中の VAO の location 3・4 へ上げる（ジョイントの無い形は None・何もしない）。
    /// 骨の無い版のプログラムはこの 2 つを宣言しないので、同じ VAO のまま曲げずに描ける。
    def uploadSkin(gl: GlContext, mesh: Mesh3d.Mesh3d): Option[SkinBuffers] \ IO =
        Mesh3d.skinJoints(mesh) |> Option.flatMap(joints ->
            Mesh3d.skinWeights(mesh) |> Option.map(weights -> uploadSkinArrays(gl, joints, weights)))

    def uploadSkinArrays(gl: GlContext, joints: Vector[Int32], weights: Vector[Float64]): SkinBuffers \ IO =
        let jointArray = Array.repeat(Static, Int32.max(1, Vector.length(joints)), 0);
        joints |> Vector.forEachWithIndex((i, j) -> Array.put(j, i, jointArray));
        let weightArray = Array.repeat(Static, Int32.max(1, Vector.length(weights)), 0.0f32);
        weights |> Vector.forEachWithIndex((i, w) -> Array.put(RenderUtil.f32(w), i, weightArray));
        let jointVbo = gl.createBuffer();
        gl.bindBuffer(GlConst.ARRAY_BUFFER, jointVbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, jointArray, GlConst.STATIC_DRAW);
        gl.enableVertexAttribArray(3);
        // WhyNot: glVertexAttribPointer で渡さない — float に直されて、シェーダーの ivec4 では番号として読めない。
        gl.vertexAttribIPointer(3, 4, GlConst.INT, 16, 0);
        let weightVbo = gl.createBuffer();
        gl.bindBuffer(GlConst.ARRAY_BUFFER, weightVbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, weightArray, GlConst.STATIC_DRAW);
        gl.enableVertexAttribArray(4);
        gl.vertexAttribPointer(4, 4, GlConst.FLOAT, false, 16, 0);
        { joints = jointVbo, weights = weightVbo }

    /// 2 本目の uv（lightmap を読む UV）を、bind 中の VAO の location 7 へ別の vbo で上げる（2 本目の uv の無い形は None・何もしない）。
    // WhyNot: 位置・法線・色や uv とタンジェントの vbo に混ぜない — 2 本目の uv の無い形の頂点バッファの中身を変えない。
    def uploadUv2(gl: GlContext, mesh: Mesh3d.Mesh3d): Option[Int32] \ IO =
        Mesh3d.uvs2(mesh) |> Option.map(uvs -> {
            let data = Array.repeat(Static, Int32.max(1, Vector.length(uvs)), 0.0f32);
            uvs |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, data));
            let vbo = gl.createBuffer();
            gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
            gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.STATIC_DRAW);
            gl.enableVertexAttribArray(7);
            gl.vertexAttribPointer(7, 2, GlConst.FLOAT, false, 8, 0);
            vbo
        })

    /// uv を、bind 中の VAO の location 5 へ上げる（uv の無い形は None・何もしない）。
    /// 頂点の色と骨の無い版のプログラムは uv とタンジェントを宣言しないので、同じ VAO のまま描ける。
    def uploadSurface(gl: GlContext, mesh: Mesh3d.Mesh3d): Option[Int32] \ IO =
        Mesh3d.uvs(mesh) |> Option.map(uvs -> {
            let data = Array.repeat(Static, Int32.max(1, Vector.length(uvs)), 0.0f32);
            uvs |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, data));
            let vbo = gl.createBuffer();
            gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
            gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.STATIC_DRAW);
            gl.enableVertexAttribArray(5);
            gl.vertexAttribPointer(5, 2, GlConst.FLOAT, false, 8, 0);
            vbo
        })

    /// 形 mesh のタンジェントを、置き場の VAO の location 6 へ上げる（上げてある・uv の無い形は何もしない）。法線マップの材質で描く前に呼ぶ。
    /// uv つきで法線マップの無いプログラムも aTangent を宣言するが、読んだ値は色に効かないので、上げていない間の既定の値のままで同じ絵になる。
    def ensureTangents(gl: GlContext, state: State, gen: Int64, mesh: Mesh3d.Mesh3d): Unit \ IO =
        let entry = meshEntry(gl, state, gen, mesh);
        if (Array.get(0, entry#tangents) != 0) ()
        else Mesh3d.tangents(mesh) |> Option.forEach(tangents -> {
            let data = Array.repeat(Static, Int32.max(1, Vector.length(tangents)), 0.0f32);
            tangents |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), i, data));
            let vbo = gl.createBuffer();
            gl.bindVertexArray(entry#vao);
            gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
            gl.bufferData(GlConst.ARRAY_BUFFER, data, GlConst.STATIC_DRAW);
            gl.enableVertexAttribArray(6);
            gl.vertexAttribPointer(6, 4, GlConst.FLOAT, false, 16, 0);
            gl.bindVertexArray(0);
            gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
            Array.put(vbo, 0, entry#tangents)
        })

    def interleave(mesh: Mesh3d.Mesh3d, n: Int32): Array[Float32, Static] \ IO =
        let out = Array.repeat(Static, Int32.max(1, n * 9), 0.0f32);
        let put = (offset: Int32, values: Vector[Float64]) ->
            values |> Vector.forEachWithIndex((i, v) -> Array.put(RenderUtil.f32(v), (i / 3) * 9 + offset + Int32.remainder(i, 3), out));
        put(0, Mesh3d.positions(mesh));
        put(3, Mesh3d.normals(mesh));
        put(6, Mesh3d.colors(mesh));
        out

    def deleteMesh(gl: GlContext, entry: MeshEntry): Unit \ IO =
        gl.deleteVertexArray(entry#vao);
        gl.deleteBuffer(entry#vbo);
        gl.deleteBuffer(entry#ibo);
        entry#skin |> Option.forEach(s -> {
            gl.deleteBuffer(s#joints);
            gl.deleteBuffer(s#weights)
        });
        entry#surface |> Option.forEach(vbo -> gl.deleteBuffer(vbo));
        if (Array.get(0, entry#tangents) != 0) gl.deleteBuffer(Array.get(0, entry#tangents)) else ();
        entry#uv2 |> Option.forEach(vbo -> gl.deleteBuffer(vbo))

    /// 画面のコマを描き終えた後に 1 回呼ぶ。上限を超えた分のメッシュを捨て、毎コマの作り直しを知らせる。
    // WhyNot: しばらく使わなかった形を捨てない — たまにしか出ない物（蹴りの脚・手榴弾）を出すたびに上げ直し、そのコマが跳ねる。
    //   毎コマ新しい形を作るゲームは、上限で古い物から押し出される。
    def endFrame(gl: GlContext, state: State, gen: Int64): Unit \ IO = timed(state, Phase.EndFrame, () -> {
        noteUploadStreak(state);
        noteMaterialStreak(state);
        sweepMaterials(gl, state, gen);
        sweepShadowTargets(gl, state, gen);
        sweepTextures3d(gl, state, gen);
        Render3d.DataTexture.endFrame(gl, state#joints, gen);
        Render3d.DataTexture.endFrame(gl, state#instances, gen);
        if (Array.get(0, state#vertexTotal) > vertexBudget()) trimToBudget(gl, state, gen) else ()
    })

    def dropMeshes(gl: GlContext, state: State, dropped: Map[String, MeshEntry], kept: Map[String, MeshEntry]): Unit \ IO =
        Map.forEach((_key, e) -> deleteMesh(gl, e), dropped);
        count(state, Counter.MeshEvictions, Map.size(dropped));
        let freed = Map.foldLeft((acc, e) -> acc + e#vertexCount, 0, dropped);
        Array.put(Array.get(0, state#vertexTotal) - freed, 0, state#vertexTotal);
        Ref.put(kept, state#meshesRef)

    /// 頂点の合計が上限に収まるまで、形を捨てる（捨てる順は meshEvictions）。
    def trimToBudget(gl: GlContext, state: State, gen: Int64): Unit \ IO =
        let meshes = Ref.get(state#meshesRef);
        let preloaded = Ref.get(state#preloadRef)#meshes;
        let victims = meshEvictions(vertexBudget(), gen, preloaded, Map.toList(meshes) |> List.map(ke -> (fst(ke), snd(ke)#vertexCount, Array.get(0, snd(ke)#lastUsed))));
        let dropped = victims |> List.filterMap(key -> Map.get(key, meshes) |> Option.map(e -> (key, e))) |> List.toMap;
        // WhyNot: 捨てる物が無いコマで知らせない — 今のコマで使う形だけで上限を超えていると、毎コマ同じ知らせが出る。
        if (Map.isEmpty(dropped)) ()
        else {
            dropMeshes(gl, state, dropped, Map.difference(meshes, dropped));
            warnDroppedMeshes(state, victims, preloaded);
            Log.warn("scene3d: メッシュの置き場が頂点 ${vertexBudget()} を超えたので、古い形を ${Map.size(dropped)} 個捨てた")
        }

    /// entries = (鍵, 頂点の数, 最後に使った世代)。頂点の合計を vertexLimit に収めるために捨てる形の鍵。今と前のコマで使った物
    /// （Pass の場面は画面のコマの 1 つ前の世代で描かれる）は選ばず、先に上げていない物から、最後に使ったのが古い順に選ぶ。
    def meshEvictions(vertexLimit: Int32, gen: Int64, preloaded: Set[String], entries: List[(String, Int32, Int64)]): List[String] =
        budgetEvictions({ count = Int32.maxValue(), size = Int32.toInt64(vertexLimit) }, gen - 1i64, entries |> List.map(e -> {
            let (key, vertexCount, lastUsed) = e;
            (key, { lastUsed = lastUsed, size = Int32.toInt64(vertexCount), counted = false, preloaded = Set.memberOf(key, preloaded) })
        }))

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
    def drawBillboards(gl: GlContext, state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, locs: BillboardLocs,
                       camera: CameraData, scene: Scene3d.Scene3dCmd): Unit \ IO =
        if (List.isEmpty(scene#billboards) or locs#program == 0) ()
        else {
            // WhyNot: ビルボードに裏の面の間引き（GL_CULL_FACE）を掛けない — 四角はいつもカメラを向くので裏は来ず、頂点の巻き方を合わせる手間だけが増える。
            gl.disable(GlConst.CULL_FACE);
            gl.useProgram(locs#program);
            gl.uniformMatrix4fv(locs#view, false, camera#view);
            gl.uniformMatrix4fv(locs#proj, false, camera#proj);
            putLights(gl, locs#light, camera#lights);
            putVec3(gl, locs#right, Camera3d.right(scene#camera));
            putVec3(gl, locs#up, Camera3d.up(scene#camera));
            putVec3(gl, locs#facing, Vec3.mul(Camera3d.forward(scene#camera), -1.0));
            putBillboardOutput(gl, locs, scene#output);
            gl.activeTexture(GlConst.TEXTURE0);
            gl.bindVertexArray(programsOf(gl, state)#quadVao);
            scene#billboards |> List.forEach(b ->
                drawBillboard(gl, state, textureOf, locs, Scene3d.isBillboardOutsideFrustum(camera#frustum, b), Scene3d.billboardFieldsOf(b)));
            gl.bindVertexArray(0);
            gl.enable(GlConst.CULL_FACE)
        }

    def putBillboardOutput(gl: GlContext, locs: BillboardLocs, output: Scene3d.Output): Unit \ IO =
        match output {
            case Scene3d.Output.Color => gl.uniform1i(locs#depthOut, 0)
            case Scene3d.Output.Depth(dr) =>
                gl.uniform1i(locs#depthOut, 1);
                putDepthRange(gl, locs#depthRange, dr)
        }

    def drawBillboard(gl: GlContext, state: State, textureOf: String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, locs: BillboardLocs,
                      culled: Bool, b: Scene3d.BillboardFields): Unit \ IO =
        match textureOf(b#texture) {
            case None          => warnMissingTexture(state, b#texture)
            case Some(_) if culled => ()
            case Some(texture) =>
                gl.bindTexture(GlConst.TEXTURE_2D, texture#texId);
                putVec3(gl, locs#center, b#position);
                gl.uniform2f(locs#anchor, RenderUtil.f32(b#anchor#x), RenderUtil.f32(b#anchor#y));
                gl.uniform2f(locs#size, RenderUtil.f32(b#size#x), RenderUtil.f32(b#size#y));
                putUvRect(gl, locs#uvRect, texture, b#regionRect);
                putLinearizedColor(gl, locs#tint, b#tint);
                gl.uniform1i(locs#lit, if (b#lit) 1 else 0);
                gl.drawArrays(GlConst.TRIANGLES, 0, 6);
                countDrawCall(state)
        }

    /// 貼る範囲の uv（左上 u・v と幅・高さ）。レンダーターゲットは行 0 が下なので v を反転する。
    def putUvRect(gl: GlContext, loc: Int32, texture: Scene3dRenderer.RegisteredTexture, source: Rect2.Rect2): Unit \ IO =
        let w = Float64.max(1.0, texture#width);
        let h = Float64.max(1.0, texture#height);
        let u0 = source#position#x / w;
        let v0 = source#position#y / h;
        let du = source#size#x / w;
        let dv = source#size#y / h;
        if (texture#flipped)
            gl.uniform4f(loc, RenderUtil.f32(u0), RenderUtil.f32(1.0 - v0), RenderUtil.f32(du), RenderUtil.f32(0.0 - dv))
        else
            gl.uniform4f(loc, RenderUtil.f32(u0), RenderUtil.f32(v0), RenderUtil.f32(du), RenderUtil.f32(dv))

    def warnMissingTexture(state: State, name: String): Unit \ IO =
        let warned = Ref.get(state#missingTexturesRef);
        if (Set.memberOf(name, warned)) ()
        else {
            Ref.put(Set.insert(name, warned), state#missingTexturesRef);
            Log.warn("scene3d: ビルボードのテクスチャ '${name}' が見つからない — 描かない"
                + "（project.json の textures に同名の宣言があるか確認）")
        }

    def putVec3(gl: GlContext, loc: Int32, v: Vec3.Vec3): Unit \ IO =
        gl.uniform3f(loc, RenderUtil.f32(v#x), RenderUtil.f32(v#y), RenderUtil.f32(v#z))

    // ── プログラム ──

    /// プログラムを初めて要る時に組む。組めなかったプログラムは 0 になり、その描き物は描かない（ゲームは止めない）。
    def programsOf(gl: GlContext, state: State): Programs \ IO =
        match Ref.get(state#programsRef) {
            case Some(p) => p
            case None =>
                let made = buildPrograms(gl);
                gl.activeTexture(GlConst.TEXTURE0 + blankTextureUnit());
                gl.bindTexture(GlConst.TEXTURE_2D, blankTextureId(gl, state));
                gl.activeTexture(GlConst.TEXTURE0);
                Ref.put(Some(made), state#programsRef);
                made
        }

    def buildPrograms(gl: GlContext): Programs \ IO =
        let lit = compile(gl, litVertexSource(false), litFragmentSource(), "scene3d:lit");
        let depth = compile(gl, meshVertexSource(), depthFragmentSource(), "scene3d:depth");
        let billboard = compile(gl, billboardVertexSource(), billboardFragmentSource(), "scene3d:billboard");
        let blit = compile(gl, blitVertexSource(), blitFragmentSource(), "scene3d:blit");
        bindDataTextureUnits(gl, lit);
        bindDataTextureUnits(gl, depth);
        let (quadVao, quadVbo) = buildQuad(gl);
        { lit = litLocsOf(gl, lit), depth = depthLocsOf(gl, depth),
          billboard = billboardLocsOf(gl, billboard), blit = blit, quadVao = quadVao, quadVbo = quadVbo }

    /// 空のプログラムを初めて要る時に組む。組めなかったプログラムは 0（空を描かず、地の色も塗らない）。
    def skyProgramOf(gl: GlContext, state: State): SkyLocs \ IO =
        match Ref.get(state#skyRef) {
            case Some(p) => p
            case None =>
                let program = compile(gl, blitVertexSource(), skyFragmentSource(), "scene3d:sky");
                let made = { program = program, viewport = loc(gl, program, "uViewport"), forward = loc(gl, program, "uForward"),
                             right = loc(gl, program, "uRight"), up = loc(gl, program, "uUp"), zenith = loc(gl, program, "uZenith"),
                             horizon = loc(gl, program, "uHorizon"), ground = loc(gl, program, "uGround"), curve = loc(gl, program, "uCurve"),
                             depthOut = loc(gl, program, "uDepthOut") };
                Ref.put(Some(made), state#skyRef);
                made
        }

    /// 骨つきの版を初めて要る時に組む。組めなかったプログラムは 0（骨つきの物はその種類だけ描かない）。
    def skinnedProgramsOf(gl: GlContext, state: State): SkinnedPrograms \ IO =
        match Ref.get(state#skinnedRef) {
            case Some(p) => p
            case None =>
                let made = buildSkinnedPrograms(gl);
                Ref.put(Some(made), state#skinnedRef);
                made
        }

    def buildSkinnedPrograms(gl: GlContext): SkinnedPrograms \ IO =
        let lit = compile(gl, litVertexSource(true), litFragmentSource(), "scene3d:lit:skin");
        let depth = compile(gl, skinnedMeshVertexSource(), depthFragmentSource(), "scene3d:depth:skin");
        bindDataTextureUnits(gl, lit);
        bindDataTextureUnits(gl, depth);
        { lit = litLocsOf(gl, lit), depth = depthLocsOf(gl, depth) }

    /// 置いた物のプログラムの uInstanceTexture と、骨つきの版の uJointTexture をそれぞれの unit へ向ける（プログラムごとに 1 回。組めなかったプログラムは何もしない）。
    def bindDataTextureUnits(gl: GlContext, program: Int32): Unit \ IO =
        if (program == 0) ()
        else {
            gl.useProgram(program);
            gl.uniform1i(loc(gl, program, "uInstanceTexture"), instanceTextureUnit());
            gl.uniform1i(loc(gl, program, "uJointTexture"), jointTextureUnit());
            gl.useProgram(0)
        }

    def litLocsOf(gl: GlContext, program: Int32): LitLocs \ IO =
        { mesh = meshLocsOf(gl, program), light = lightLocsOf(gl, program), shadow = shadowLocsOf(gl, program) }

    def depthLocsOf(gl: GlContext, program: Int32): DepthLocs \ IO =
        { mesh = meshLocsOf(gl, program), eye = loc(gl, program, "uEye"), depthRange = loc(gl, program, "uDepthRange") }

    def compile(gl: GlContext, vertex: String, fragment: String, label: String): Int32 \ IO =
        match RenderShader.tryCreateProgram(gl, vertex, fragment, label) {
            case Some(p) => p
            case None =>
                Log.warnThen("scene3d: プログラム '${label}' が組めなかった — この種類の 3D の描き物は描かない", 0)
        }

    def loc(gl: GlContext, program: Int32, name: String): Int32 \ IO =
        if (program == 0) -1 else gl.getUniformLocation(program, name)

    def meshLocsOf(gl: GlContext, program: Int32): MeshLocs \ IO =
        { program = program, view = loc(gl, program, "uView"), proj = loc(gl, program, "uProj"), instanceBase = loc(gl, program, "uInstanceBase") }

    def lightLocsOf(gl: GlContext, program: Int32): LightLocs \ IO =
        { ambient = loc(gl, program, "uAmbient"), hemisphere = loc(gl, program, "uHemisphere"), toonSteps = loc(gl, program, "uToonSteps"),
          pointCount = loc(gl, program, "uPointCount"), pointPos = loc(gl, program, "uPointPos"),
          pointColor = loc(gl, program, "uPointColor"), pointRange = loc(gl, program, "uPointRange"),
          spotCount = loc(gl, program, "uSpotCount"), spotPos = loc(gl, program, "uSpotPos"), spotDir = loc(gl, program, "uSpotDir"),
          spotColor = loc(gl, program, "uSpotColor"), spotRange = loc(gl, program, "uSpotRange"), spotCone = loc(gl, program, "uSpotCone"),
          fogOn = loc(gl, program, "uFogOn"), fogColor = loc(gl, program, "uFogColor"), fogRange = loc(gl, program, "uFogRange"),
          eye = loc(gl, program, "uEye") }

    def shadowLocsOf(gl: GlContext, program: Int32): ShadowLocs \ IO =
        { on = loc(gl, program, "uShadowOn"), spot = loc(gl, program, "uShadowSpot"), matrix = loc(gl, program, "uShadowMatrix"),
          map = loc(gl, program, "uShadowMap"), bias = loc(gl, program, "uShadowBias"), pcf = loc(gl, program, "uShadowPcf"),
          strength = loc(gl, program, "uShadowStrength") }

    def billboardLocsOf(gl: GlContext, program: Int32): BillboardLocs \ IO =
        if (program == 0) () else {
            gl.useProgram(program);
            gl.uniform1i(loc(gl, program, "uImage"), 0);
            gl.useProgram(0)
        };
        { program = program, view = loc(gl, program, "uView"), proj = loc(gl, program, "uProj"),
          center = loc(gl, program, "uCenter"), right = loc(gl, program, "uRight"), up = loc(gl, program, "uUp"),
          anchor = loc(gl, program, "uAnchor"), size = loc(gl, program, "uSize"), uvRect = loc(gl, program, "uUvRect"),
          tint = loc(gl, program, "uTint"), lit = loc(gl, program, "uLit"), facing = loc(gl, program, "uFacing"),
          depthOut = loc(gl, program, "uDepthOut"), depthRange = loc(gl, program, "uDepthRange"), light = lightLocsOf(gl, program) }

    /// 四角の 6 頂点（角の 0〜1。y は下向き = 絵の上が 0）。ビルボードと Design の重ねで共有する。
    def buildQuad(gl: GlContext): (Int32, Int32) \ IO =
        let vao = gl.createVertexArray();
        let vbo = gl.createBuffer();
        let corners = Array#{
            0.0f32, 0.0f32,  1.0f32, 0.0f32,  1.0f32, 1.0f32,
            0.0f32, 0.0f32,  1.0f32, 1.0f32,  0.0f32, 1.0f32
        } @ Static;
        gl.bindVertexArray(vao);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, vbo);
        gl.bufferData(GlConst.ARRAY_BUFFER, corners, GlConst.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, GlConst.FLOAT, false, 8, 0);
        gl.bindBuffer(GlConst.ARRAY_BUFFER, 0);
        gl.bindVertexArray(0);
        (vao, vbo)

}
