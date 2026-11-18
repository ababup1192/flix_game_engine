// Render3d.WebGpuRenderer — 3D の場面を WebGPU で描く所（WebGPU の backend の 3D の分）。2D の描き手（RenderPaint.Internal.WebGpuPaint）が 1 つ持つ。
// 1 回の renderCommands で、2D の pass を開く前に prepare が場面ごとに自分の texture（色と深度。標本つきなら resolve まで）へ描き、
// 2D の並びの z の位置で 2D の描き手がその texture を貼る（plans/engine-webgpu.md の 5.4）。計画（Render3d.ScenePlan）と行（Render3d.SceneList）は GL と同じ物を使い、
// 行を流すのは Render3d.WebGpuRows・材質の program と絵と値は Render3d.WebGpuMaterials。式は GL と同じ WGSL（Render3dWgsl と ShaderGen.Wgsl.compile3d）。
// 描くのは不透明の頂点の色の物と、材質の物（Render3d.WebGpuMaterials.isDrawable の版。半透明の物は計画が並べた行の順に、深度を書かずに α で重ねる）と、
// そのどちらも骨つきの物（姿勢は group 2 の storage）と
// 光（点光源・スポット・太陽・環境光・hemisphere・かすみ）と、スポットと太陽の影（Render3d.WebGpuShadows）と、lightmap（材質の group 1）と、空（Render3d.WebGpuSky）と、
// ビルボード（Render3d.WebGpuBillboards・行の順で不透明の行と半透明の行の間）と、
// 奥行きの書き出し（Output.Depth の場面の形の灰色）と、環境マップ（metallic と roughness を持つ材質の映り込みと、景色を背景に描く場面の空。場面の group 0 の binding 3）。
// alpha to coverage の材質は描かずに回数を host へ数えさせる（GL が「使えない」と答えた材質と同じく頂点の色か形で描く）。3D の診断の数（Render3d.Counts）も GL と同じ欄で数える。
// 場面は、影の地図の pass（Render3d.ShadowMaps.ShadowPass）を先に積み、計画の pass（Render3d.ScenePlan.ScenePassSpec）ごとの行の列（Render3d.SceneList.ScenePasses）で描き、pass の種類で frag を替える。
// WhyNot: 兄弟（Render3d.GlRows など）と同じく pub を外さない — 呼び手の RenderPaint.Internal.WebGpuPaint は Render3d の子孫でなく、pub でない子の mod には届かない
//   （親の Render3d が pub でないので、別のパッケージのゲームからは見えない）。
pub mod Render3d.WebGpuRenderer {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CommandEncoder
    import fge.webgpu.CompareFunction
    import fge.webgpu.CullMode
    import fge.webgpu.FilterMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderCommands
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Sampler
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.TextureView
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.FloatBuffer
    import java.lang.Object
    import java.util.Objects
    use Render3d.{LightData, MeshDraw, PixelBox, ShaderVariant, TextureSlot, TextureSource, clipBox, defaultShaderVariant, matrixArray, passVariantOf, sceneRect, variantKeyOf}
    use Render3d.Batch.{MeshBatch, SpanBatch}
    use Render3d.InstanceValues.{PackMode, numberSpan}
    use Render3d.Light.{lightDataOf}
    use Render3d.ScenePlan.{Group, GroupedScene, MaterialRequest, PlanCaps, Planner, ScenePassSpec, ScenePlan, freshPlanner, groupScenesWith, isSkinned, planScenes}
    use Render3d.SceneList.{SceneList, ScenePasses, buildScenePasses}
    use Render3d.Counts.{Phase, countDrawCallAt, countInstances, noteMaterialBuild, timed}
    use Render3d.MeshTable
    use Render3d.PoseRows.{PoseRows, floatCountOf, packRows, posesInRowOrder}
    use Render3d.SceneList.{countAt, firstBillboardRowOf, firstBlendedRowOf, missingBillboardTexturesOf, rowCountOf, textureIdAt, valuesAt}
    use Render3d.WebGpuBillboards
    use Render3d.WebGpuMaterials
    use Render3d.WebGpuMaterials.{BoundPipeline, ValuesBinding}
    use Render3d.WebGpuRows.{MeshBuffers, MeshStore, RowDrawer, countRowsOf, drawRows, freshStore, meshAllocator, uploadRows}
    use Render3d.StaticRows
    use Render3d.WebGpuStatic
    use Render3d.WebGpuStatic.{Carried}
    use Render3d.ShadowMaps.{ShadowMapUse, ShadowPass, ShadowSampling}
    use Render3d.WebGpuShadows
    use Render3d.WebGpuSky
    use Render3d.WebGpuSceneValues
    use RenderPaint.Internal.WebGpuPipelines

    /// 場面 1 つの描き先と、その場面の値の buffer と bind group（2D の描き手の描き先の鍵とそのコマの場面の番号ごとに 1 つ・大きさか形式か標本が変われば作り直す）。
    /// color = 貼る時に読む 1 標本の texture・msaa = 標本つきの描き先（標本 1 なら None）・depth = 深度（DEPTH24_PLUS）・
    /// sceneValues = Render3dWgsl の R3dScene・camera = R3dCamera・sceneGroup = group 0・paste = 貼る矩形（WebGpuShader.sceneWgsl の Paste）・pasteGroup = 貼る形の group 1・
    /// lightValues = 変種の場面の R3dLight（Render3dWgsl.variantDeclarations。既定の場面は読まない）。
    type alias SceneTarget = {
        width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32,
        color = Texture, msaa = Option[Texture], depth = Texture,
        sceneValues = Buffer, camera = Buffer, sceneGroup = BindGroup, paste = Buffer, pasteGroup = BindGroup, lightValues = Buffer
    }

    /// 2D の描き手から借りる物。encoder = 今のコマの encoder・notePass = encoder に pass を 1 つ積んだと知らせる・
    /// flush = 積んだ pass があれば submit する（submit したら afterSubmit が呼ばれる）・skip(種類, 回数) = 描かずに飛ばした物を種類ごとに数える・
    /// textureOf = 2D の絵の登録（材質が名前で読む全体の登録の絵）・textureById = 登録の絵の番号 → 2D の描き手の texture・
    /// groupById = 登録の絵の番号 → 2D の描き手がその絵を読む group（絵と sampler・ビルボードが group 1 に借りる）。
    pub type alias Host = {
        encoder = Unit -> CommandEncoder \ IO, notePass = Unit -> Unit \ IO, flush = Unit -> Unit \ IO, skip = (String, Int32) -> Unit \ IO,
        textureOf = String -> Option[Scene3dRenderer.RegisteredTexture] \ IO, textureById = Int32 -> Option[Texture] \ IO,
        groupById = Int32 -> Option[BindGroup] \ IO
    }

    /// 場面を描く描き先。key = 2D の描き手の描き先の鍵（画面は 0）・format・samples = 2D の pass の形式と標本（WebGPU の描き先の標本は 1 か 4）・
    /// viewport = 描き先の中の design 領域（GL の左下が原点）と倍率・height = 描き先の高さ（画素）。
    pub type alias Dest = { key = Int32, format = RenderTarget.Format, samples = Int32, viewport = Scene3dRenderer.Viewport, height = Int32 }

    /// 場面 1 つを貼る物。group = 貼る形の group 1・scissor = 貼る矩形 ∩ clip ∩ design 領域（描き先の左上が原点の x・y・幅・高さ）・
    /// key = 描き先の鍵（貼った時に notePasted へ渡す）。
    pub type alias Paste = { group = BindGroup, scissor = (Int32, Int32, Int32, Int32), key = (Int32, Int32) }

    /// prepare の答え（i 番目 = 番号 i の場面を貼る物。描く物の無い場面は None）。
    pub type alias Prepared = Vector[Option[Paste]]

    /// 描き手の状態。欄の中身:
    /// vertexModule と skinnedModule = 頂点の色の頂点シェーダー（骨の無い版と骨つきの版）・poseLayout = group 2（姿勢）の layout・
    /// emptyLayout と emptyGroup = 骨つきの頂点の色の pipeline の group 1（材質を読まない版で、group 2 の前を埋める）・
    /// lightLayout と atlasLayout = 変種の場面の group 0 の layout（sceneLayout に R3dLight を足した物・さらに点光源の影の atlas を足した物。layoutCodeOf）・
    /// variantFragments = 変種の鍵（Render3d.variantKeyOf）→ 頂点の色の frag・cpuLight = R3dLight を詰める入れ物・sceneOffsets = R3dScene の欄の位置（作る時に 1 回求める）・
    /// pipelines = LitPipelineKey → 頂点の色の pipeline・depthModule = 奥行きの書き出しの frag・blankDepth と blankImage = 影の地図と環境マップの代わり（影は場面の値が切るので読まれない・環境マップは絵が見つからない時に透明な黒として読む）・
    /// written = 今の encoder（submit まで）で値を書いたか、貼る pass を積んだ描き先の鍵・instances = 1 体ごとの値の buffer（頂点の buffer の 1 番）・
    /// instanceUsed = 今の encoder で使ったそのバイト数・poses = 姿勢の storage の buffer・posesUsed = 今の encoder で使ったそのバイト数・
    /// poseGroups = 今の encoder の group 2（submit の後に手放す）・sceneGroups = 影の地図か環境マップを読む場面の group 0 の控え（描き先と読む絵が同じなら使い回し、コマの間に使わなかった物を手放す）・shadows = 影の地図の描き先と pass・epoch = submit の数（姿勢をこの encoder で書いたかを見る）・
    /// cpuInstances・cpuPoses・cpuScene・cpuCamera・cpuPaste・scratch = 毎回作らずに使い回す CPU の入れ物
    /// （cpuInstances と cpuPoses は足りなければ倍に作り直す）・gen = 画面のコマの世代（endFrame で進む）。
    enum RendererData {
        case RendererData({
            gpu = WebGpu,
            planner = Planner,
            sceneLayout = BindGroupLayout,
            lightLayout = BindGroupLayout,
            atlasLayout = BindGroupLayout,
            variantFragments = Ref[Map[String, ShaderModule], Static],
            cpuLight = ByteBuffer, sceneOffsets = Map[Render3d.UniformLayout.SceneField, Int32],
            pasteLayout = BindGroupLayout,
            vertexModule = ShaderModule,
            skinnedModule = ShaderModule,
            fragmentModule = ShaderModule,
            depthModule = ShaderModule,
            poseLayout = BindGroupLayout,
            emptyLayout = BindGroupLayout,
            emptyGroup = BindGroup,
            pipelines = Ref[Map[LitPipelineSlot, RenderPipeline], Static],
            blankDepth = Texture,
            blankImage = Texture,
            environmentSampler = Sampler,
            meshes = MeshTable.Table,
            meshStore = MeshStore,
            materials = WebGpuMaterials.Materials,

            layouts = Render3d.MaterialValues.Layouts,
            countsHolder = Array[Int32, Static],
            phaseNsHolder = Array[Int64, Static],
            materialBuildsRef = Ref[List[FrameDiagnostics.ShaderBuild], Static],
            targets = Render3d.SceneTargets.Table[(Int32, Int32), SceneTarget],
            written = Ref[Set[(Int32, Int32)], Static],
            instances = Array[Buffer, Static],
            instanceUsed = Array[Int32, Static],
            poses = Array[Buffer, Static],
            posesUsed = Array[Int32, Static],
            poseGroups = Ref[List[BindGroup], Static],
            sceneGroups = Ref[List[SceneGroup], Static],
            shadows = WebGpuShadows.Shadows,
            sky = WebGpuSky.Sky,
            billboards = WebGpuBillboards.Billboards,
            preloaded = Ref[Preloaded, Static],
            epoch = Array[Int64, Static],
            cpuInstances = Array[ByteBuffer, Static],
            cpuPoses = Array[ByteBuffer, Static],
            cpuScene = ByteBuffer,
            cpuCamera = ByteBuffer,
            cpuPaste = ByteBuffer,
            scratch = Array[Float32, Static],
            statics = WebGpuStatic.StaticCache,
            gen = Array[Int64, Static]
        })
    }

    pub type alias Renderer = RendererData

    /// 1 体ごとの値の buffer の始めの大きさ（体の数）。
    def initialInstances(): Int32 = 1024

    /// 姿勢の buffer の始めの大きさ（バイト）。
    def initialPoseBytes(): Int32 = 65536

    /// 1 回の prepare の姿勢の行の数の上限（計画へ渡す）。姿勢の予算（poseBudgetBytes）を、ジョイントが一番多い行（Skin3d.maxJoints() 本の mat4）で割った数。
    // WhyNot: device の maxStorageBufferBindingSize から求めない — 予算の 64 MiB はスマホ（12.24 の S24 Ultra の 128 MiB）の内で、core の最低保証（128 MiB）の内でもある。
    def poseRowLimit(): Int32 = poseBudgetBytes() / (Skin3d.maxJoints() * 64)

    /// 1 回の prepare の姿勢に使ってよいバイト数。
    def poseBudgetBytes(): Int32 = 64 * 1048576

    /// storage の binding の位置のそろえ（core の minStorageBufferOffsetAlignment の上限）。
    def storageAlignBytes(): Int32 = 256

    /// device の上に shader module・layout・代わりの絵・1 体ごとの値の buffer を作る。pasteLayout = 貼る形の group 1（WebGpuPipelines の持ち物）・
    /// imageLayout = 2D の描き手の絵の group の layout（ビルボードの group 1・2D の描き手の持ち物）。材質の値は uniform の区画で読む（12.28）。
    pub def create(gpu: WebGpu, pasteLayout: BindGroupLayout, imageLayout: BindGroupLayout): Renderer \ IO = createWith(gpu, pasteLayout, imageLayout, ValuesBinding.Uniform)

    /// create の、材質の値の binding の形を選ぶ版（uniform と storage の比べ・bench/webgpu_v2）。
    pub def createWith(gpu: WebGpu, pasteLayout: BindGroupLayout, imageLayout: BindGroupLayout, binding: ValuesBinding): Renderer \ IO =
        let layoutDesc = sceneLayoutDesc("fge scene3d", 0);
        let poseDesc = new BindGroupLayoutDesc("fge scene3d poses");
        discard poseDesc.buffer(0, ShaderStage.VERTEX, BufferBindingType.READ_ONLY_STORAGE);
        let emptyLayout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("fge scene3d empty"));
        let blankImage = gpu.createTexture("fge scene3d blank", 1, 1, TextureFormat.RGBA8_UNORM,
                                           Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        gpu.writeTexture(blankImage, 0, 0, 0, 1, 1, ByteBuffer.allocateDirect(4), 0, 4);
        let sceneLayout = gpu.createBindGroupLayout(layoutDesc);
        let r = RendererData.RendererData({
            gpu = gpu, planner = freshPlanner(Render3d.DrawMode.Instanced),
            sceneLayout = sceneLayout, pasteLayout = pasteLayout,
            lightLayout = gpu.createBindGroupLayout(sceneLayoutDesc("fge scene3d light", 1)),
            atlasLayout = gpu.createBindGroupLayout(sceneLayoutDesc("fge scene3d point shadows", 2)),
            variantFragments = Ref.fresh(Static, Map.empty()), cpuLight = directBytes(Render3dWgsl.lightValueBytes()), sceneOffsets = Render3d.UniformLayout.sceneOffsets(),
            vertexModule = gpu.createShaderModule("fge scene3d lit vs", Render3dWgsl.litVertexSource(false)),
            skinnedModule = gpu.createShaderModule("fge scene3d skinned vs", Render3dWgsl.litVertexSource(true)),
            fragmentModule = gpu.createShaderModule("fge scene3d lit fs", Render3dWgsl.litFragmentSource()),
            depthModule = gpu.createShaderModule("fge scene3d depth fs", Render3dWgsl.depthFragmentSource()),
            poseLayout = gpu.createBindGroupLayout(poseDesc), emptyLayout = emptyLayout,
            emptyGroup = gpu.createBindGroup(new BindGroupDesc("fge scene3d empty", emptyLayout)),
            pipelines = Ref.fresh(Static, Map.empty()),
            blankDepth = gpu.createTexture("fge scene3d blank depth", 1, 1, TextureFormat.DEPTH32_FLOAT, TextureUsage.TEXTURE_BINDING, 1, 1),
            blankImage = blankImage,
            environmentSampler = gpu.createSampler("fge scene3d environment", FilterMode.LINEAR, FilterMode.LINEAR, AddressMode.REPEAT),
            meshes = MeshTable.fresh(), meshStore = freshStore(), materials = WebGpuMaterials.create(gpu, binding), layouts = Render3d.MaterialValues.freshLayouts(),

            countsHolder = Array.repeat(Static, Render3d.Counts.counterSlots(), 0), phaseNsHolder = Array.repeat(Static, Render3d.Counts.phaseSlots(), 0i64),
            materialBuildsRef = Ref.fresh(Static, Nil),
            targets = Render3d.SceneTargets.fresh(), written = Ref.fresh(Static, Set.empty()),
            instances = Array#{createInstanceBuffer(gpu, initialInstances() * Render3dWgsl.instanceBytes())} @ Static,
            instanceUsed = Array#{0} @ Static,
            poses = Array#{createPoseBuffer(gpu, initialPoseBytes())} @ Static, posesUsed = Array#{0} @ Static,
            poseGroups = Ref.fresh(Static, Nil), sceneGroups = Ref.fresh(Static, Nil), shadows = WebGpuShadows.create(gpu), sky = WebGpuSky.create(gpu, sceneLayout),
            billboards = WebGpuBillboards.create(gpu, sceneLayout, imageLayout),
            preloaded = Ref.fresh(Static, { builtKey = None, meshes = Set.empty(), textures = Set.empty(), rebuilds = Nil }), epoch = Array#{0i64} @ Static,
            cpuInstances = Array#{directBytes(initialInstances() * Render3dWgsl.instanceBytes())} @ Static,
            cpuPoses = Array#{directBytes(initialPoseBytes())} @ Static,
            cpuScene = directBytes(WebGpuSceneValues.sceneValueBytes()), cpuCamera = directBytes(Render3dWgsl.cameraBytes()), cpuPaste = directBytes(16),
            scratch = Array.repeat(Static, Render3dWgsl.instanceBytes() / 4, 0.0f32),
            statics = WebGpuStatic.fresh(),
            gen = Array#{1i64} @ Static
        });
        // WhyNot: 画面（RGBA8・標本 1）の pipeline を初めて場面が出たコマで作らない — Dawn は pipeline を作り終えるまで待つので、そのコマが詰まる（WebGpuPipelines.buildStartupPipelines と同じ）。
        discard pipelineOf(r, RenderTarget.Format.Rgba8Unorm, 1, ScenePassSpec.Color, 36, None, defaultShaderVariant());
        r

    /// 場面の group 0 の layout の作り方。code = layoutCodeOf の番号（0 = 既定・1 = R3dLight を足す・2 = R3dLight と点光源の影の atlas を足す）。
    // WhyNot: 既定の layout に変種の binding を足しておかない — 既定の pipeline の group 0 の layout が変わる（変種を使わない場面は今の layout のまま）。
    def sceneLayoutDesc(label: String, code: Int32): BindGroupLayoutDesc \ IO =
        let desc = new BindGroupLayoutDesc(label);
        discard desc.buffer(0, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        discard desc.texture(1, ShaderStage.FRAGMENT, TextureSampleType.DEPTH).texture(2, ShaderStage.FRAGMENT, TextureSampleType.DEPTH);
        discard desc.texture(3, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(4, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        discard desc.buffer(5, ShaderStage.VERTEX, BufferBindingType.UNIFORM);
        if (code >= 1) discard desc.buffer(Render3dWgsl.lightBinding(), ShaderStage.FRAGMENT, BufferBindingType.UNIFORM) else ();
        if (code >= 2) discard desc.texture(Render3dWgsl.pointShadowMapBinding(), ShaderStage.FRAGMENT, TextureSampleType.DEPTH) else ();
        desc

    /// 変種 v の場面の group 0 の形の番号（0 = 既定・1 = +pu だけ・2 = +ps がある。ビルボード・空も同じ場面の pass ではこの layout で作る）。
    pub def layoutCodeOf(v: ShaderVariant): Int32 = if (v#pointShadows) 2 else if (v#physicalUnits) 1 else 0

    /// 形の番号 code の group 0 の layout。
    def sceneLayoutOf(r: Renderer, code: Int32): BindGroupLayout =
        let RendererData.RendererData(s) = r;
        if (code >= 2) s#atlasLayout else if (code == 1) s#lightLayout else s#sceneLayout

    /// 場面の描き先の深度の形式（描き先・pipeline・持ち越した集まりの bundle で同じ物）。
    def sceneDepthFormat(): TextureFormat = TextureFormat.DEPTH24_PLUS

    def directBytes(bytes: Int32): ByteBuffer \ IO = ByteBuffer.allocateDirect(Int32.max(4, bytes)).order(ByteOrder.LITTLE_ENDIAN)

    def createInstanceBuffer(gpu: WebGpu, bytes: Int32): Buffer \ IO =
        gpu.createBuffer("fge scene3d instances", Int32.toInt64(bytes), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST))

    def createPoseBuffer(gpu: WebGpu, bytes: Int32): Buffer \ IO =
        gpu.createBuffer("fge scene3d poses", Int32.toInt64(bytes), Int32.bitwiseOr(BufferUsage.STORAGE, BufferUsage.COPY_DST))

    /// device の上に作った物を全部手放す（pasteLayout は持ち主が手放す）。この後 r は使えない。
    pub def release(r: Renderer): Unit \ IO =
        let RendererData.RendererData(s) = r;
        Render3d.SceneTargets.release(s#targets, targetAllocator(r));
        Map.forEach((_, p) -> p.release(), Ref.get(s#pipelines));
        Ref.put(Map.empty(), s#pipelines);
        MeshTable.release(s#meshes, meshAllocator(s#gpu, s#meshStore));
        WebGpuStatic.release(s#statics);
        Ref.get(s#sceneGroups) |> List.forEach(e -> e#group.release());
        Ref.put(Nil, s#sceneGroups);
        WebGpuMaterials.release(s#materials);
        afterSubmit(r);
        WebGpuShadows.release(s#shadows);
        WebGpuSky.release(s#sky);
        WebGpuBillboards.release(s#billboards);
        Array.get(0, s#instances).destroy();
        Array.get(0, s#poses).destroy();
        s#emptyGroup.release();
        s#emptyLayout.release();
        s#poseLayout.release();
        s#skinnedModule.release();
        s#blankDepth.destroy();
        s#blankImage.destroy();
        s#environmentSampler.release();
        s#vertexModule.release();
        s#fragmentModule.release();
        s#depthModule.release();
        Map.forEach((_, m) -> m.release(), Ref.get(s#variantFragments));
        s#lightLayout.release();
        s#atlasLayout.release();
        s#sceneLayout.release()

    /// 場面のどれかのビルボードが name の絵を貼るか（GL の Render3d.readsTexture と同じ。2D の描き手が Pass の history の要否を決める）。
    // WhyNot: WebGpuPaint から Render3d.readsTexture を直に呼ばない — 親の Render3d は pub でない mod で、Render3d の子孫でない WebGpuPaint からは届かない（この mod の頭）。
    pub def readsTexture(name: String, scenes: List[Scene3d.RenderCmd]): Bool = Render3d.readsTexture(name, scenes)

    /// 2D の描き手が encoder を submit した後に呼ぶ（1 体ごとの値の buffer と場面の値を頭から書き直せる）。
    pub def afterSubmit(r: Renderer): Unit \ IO =
        let RendererData.RendererData(s) = r;
        Array.put(0, 0, s#instanceUsed);
        Array.put(0, 0, s#posesUsed);
        Array.put(Array.get(0, s#epoch) + 1i64, 0, s#epoch);
        Ref.get(s#poseGroups) |> List.forEach(g -> g.release());
        Ref.put(Nil, s#poseGroups);
        WebGpuShadows.afterSubmit(s#shadows);
        WebGpuMaterials.afterSubmit(s#materials);
        Ref.put(Set.empty(), s#written)

    /// 前に呼んでからの 3D の数（FrameDiagnostics.Scene3dCounts）を返して 0 に戻す。
    pub def takeCounts(r: Renderer): FrameDiagnostics.Scene3dCounts \ IO =
        let RendererData.RendererData(s) = r;
        Render3d.Counts.takeCounts(s)

    /// 2D の pass に paste を貼った時に呼ぶ（その描き先の値を、今の encoder の中で使い中と控える）。
    // WhyNot: prepare で書いた時の控えだけで済ませない — prepare から 2D の pass を積むまでの間に submit が入る（1 体ごとの値の buffer があふれる・
    //   2D の Stream を伸ばす）と控えが消え、同じ encoder で同じ描き先がもう一度来た時に、まだ submit していない pass の貼る矩形と場面の値を先回りして書き換える。
    //   貼るのは pass の中で、pass を閉じるまで submit は入らない。
    pub def notePasted(r: Renderer, paste: Paste): Unit \ IO = noteWritten(r, paste#key)

    /// 画面のコマを締めて submit した後に 1 回呼ぶ。頂点の上限を超えた形と、置き場の上限を超えた材質の絵（先に上げた物は後へ回す）と、
    /// しばらく描かなかった場面の描き先を捨てて、世代を進める。
    // WhyNot: project.json の scene3dTextureBudgetMB・Count を読まない — WebGPU の描き手を作る所（WebGpuPaint）に config が届いていない。届けるのは engine の口に触れる時（持ち越し）。
    pub def endFrame(r: Renderer): Unit \ IO =
        endFrameWithin(r, { vertices = Render3d.vertexBudget(),
                            textures = { count = GameEngine.defaultScene3dTextureBudgetCount(), size = Int32.toInt64(GameEngine.defaultScene3dTextureBudgetMB()) * 1048576i64 } })

    /// endFrame の、形の頂点の上限 vertices と材質の絵の置き場の上限 textures を受ける版。
    def endFrameWithin(r: Renderer, limits: { vertices = Int32, textures = Render3d.Material.Budget }): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let gen = Array.get(0, s#gen);
        Array.put(gen + 1i64, 0, s#gen);
        discard Render3d.SceneTargets.sweep(s#targets, targetAllocator(r), gen);
        let preloaded = Ref.get(s#preloaded);
        let droppedTextures = WebGpuMaterials.endFrame(s#materials, gen, limits#textures, preloaded#textures);
        Render3d.warnDroppedTextures(s#planner, droppedTextures, preloaded#textures);
        discard WebGpuShadows.endFrame(s#shadows, gen);
        let (usedGroups, idleGroups) = List.partition(e -> Array.get(0, e#lastUsed) >= gen, Ref.get(s#sceneGroups));
        List.forEach(e -> e#group.release(), idleGroups);
        Ref.put(usedGroups, s#sceneGroups);
        let victims = MeshTable.trim(s#meshes, meshAllocator(s#gpu, s#meshStore), gen, limits#vertices, preloaded#meshes);
        Render3d.warnDroppedMeshes(s#planner, victims, preloaded#meshes);
        WebGpuStatic.endFrame(s#statics, gen, not List.isEmpty(droppedTextures) or not List.isEmpty(victims));
        let dropped = List.length(victims);
        Render3d.Counts.count(s, Render3d.Counts.Counter.MeshEvictions, dropped);
        // WhyNot: 捨てる物が無いコマで知らせない — 今のコマで使う形だけで上限を超えていると、毎コマ同じ知らせが出る（GL の Render3d.trimToBudget と同じ）。
        if (dropped == 0) ()
        else Log.warn("scene3d: メッシュの置き場が頂点 ${limits#vertices} を超えたので、古い形を ${dropped} 個捨てた")

    // ── 先に上げる物（withPreload3d）──

    /// 先に上げた物の控え（GL の Render3d.PreloadState の WebGPU の分。材質の program は捨てないので控えない）。builtKey = 最後に上げた宣言の key・
    /// meshes = 上げた形の鍵（Mesh3d.contentHash）・textures = 上げた絵の置き場の鍵・rebuilds = 組み直した世代（Render3d.Preload.noteRebuild）。
    type alias Preloaded = { builtKey = Option[DrawCmd.StaticKey], meshes = Set[String], textures = Set[TextureSlot], rebuilds = List[Int64] }

    /// 宣言 cmd の形と絵と材質の program と、画面の形式（RGBA8・標本 1）の pipeline を上げる（GL の Render3d.Preload.upload と同じ約束）。
    /// 最後に上げた宣言と同じ key なら何もしない（cmd の中身も読まない）。
    // WhyNot: pipeline を場面の描き先の形式ごとに作らない — 描き先の形式と標本は場面ごとに決まり、宣言の時には分からない（GL の coverageVersions と同じ）。
    //   画面へ直に描く場面の形だけを作り、ほかは初めて描くコマで作る。
    pub def preload(r: Renderer, host: Host, cmd: Scene3d.PreloadCmd): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let held = Ref.get(s#preloaded);
        if (held#builtKey == Some(cmd#key)) ()
        else {
            let gen = Array.get(0, s#gen);
            let rebuilds = Render3d.Preload.noteRebuild(s#planner, gen, held#rebuilds);
            let uploaded = timed(s, Phase.Preload, () -> preloadCmd(r, host, gen, cmd));
            Ref.put({ rebuilds = rebuilds | uploaded }, s#preloaded)
        }

    /// cmd の置いた物を、既定の版と cmd#variants の版ごとに候補に分け、候補ごとに形と、材質の program と絵か頂点の色の pipeline を上げて、上げた物の控えを返す。
    /// 材質の pipeline は変種の group 0 の layout で作る（場面を描く時と同じ layout の物が控えに残る）。
    def preloadCmd(r: Renderer, host: Host, gen: Int64, cmd: Scene3d.PreloadCmd): Preloaded \ IO =
        let RendererData.RendererData(s) = r;
        let instances = (cmd#instances)();
        let groups = (Render3d.defaultShaderVariant() :: Render3d.Preload.extraVariantsOf(cmd))
            |> List.flatMap(v -> Render3d.ScenePlan.groupInstances(s#planner, v, _ -> true, _ -> true, false, instances) |> fst |> List.map(g -> (v, g)));
        let source = { textureOf = host#textureOf, own = (cmd#textures)() |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap };
        let allocator = countingAllocator(r);
        let mp = { base = 0, values = WebGpuMaterials.valuesBufferOf(s#materials), programs = Vector.empty(), format = RenderTarget.Format.Rgba8Unorm, samples = 1,
                   sceneLayout = s#sceneLayout, poseLayout = s#poseLayout, hasPoses = false, bound = Ref.fresh(Static, BoundPipeline.Unbound), groupRow = Array#{-1} @ Static,
                   groups = WebGpuMaterials.frameGroupsOf(s#materials) };
        let noteBuild = name -> noteMaterialBuild(s, name, FrameDiagnostics.BuildReason.First);
        let missing = name -> Render3d.ScenePlan.warnOnce(s#planner, "preload:" + name, Render3d.Preload.missingTextureLine(name));
        let textures = groups |> List.flatMap(vg -> {
            let (v, g) = vg;
            let head = g#batch#head;
            let mesh = Map.get(MeshTable.ensure(s#meshes, allocator, gen, head#fields#mesh), Ref.get(s#meshStore));
            match g#surface {
                case Some(request) => WebGpuMaterials.preloadMaterial(s#materials, noteBuild, missing, { sceneLayout = sceneLayoutOf(r, layoutCodeOf(v)) | mp }, source,
                                                                      registeredOf(r, host), gen, request, head, mesh)
                case None =>
                    mesh |> Option.forEach(b -> preloadShape(r, b, isSkinned(head), v));
                    Nil
            }
        });
        { builtKey = Some(cmd#key), rebuilds = Nil, meshes = groups |> List.map(vg -> Mesh3d.contentHash(snd(vg)#batch#head#fields#mesh)) |> List.toSet,
          textures = List.toSet(textures) }

    /// 形 mesh の頂点の色の pipeline（画面の形式・標本 1・色の pass）を作る。骨つきの物は形にジョイントがある時だけ。
    def preloadShape(r: Renderer, mesh: MeshBuffers, skinned: Bool, variant: ShaderVariant): Unit \ IO =
        if (skinned and Option.isEmpty(mesh#skinAt)) ()
        else discard pipelineOf(r, RenderTarget.Format.Rgba8Unorm, 1, ScenePassSpec.Color, mesh#stride, if (skinned) mesh#skinAt else None, variant)

    // ── 1 回の renderCommands ──

    /// 積んだ順の場面 cmds を、それぞれの texture へ描いて貼る物を返す（2D の pass を開く前に呼ぶ）。
    pub def prepare(r: Renderer, host: Host, dest: Dest, cmds: List[Scene3d.RenderCmd]): Prepared \ IO =
        let RendererData.RendererData(s) = r;
        if (List.isEmpty(cmds)) Vector.empty()
        else {
            // WhyNot: alpha to one を持つと答えない — 答えると計画が cutout を alpha to coverage の版にし、その版は描けない（Render3d.WebGpuMaterials の頭）。
            let caps = { alphaToOne = false, poseRowLimit = poseRowLimit() };
            let (plans, grouped, poses, carried) = timed(s, Phase.Split, () -> {
                let carried = cmds |> List.map(cmd -> WebGpuStatic.carriedOf(s#statics, staticBuilderOf(r, host), cmd#scene));
                let perFrame = List.zip(cmds, carried) |> List.map(match (cmd, cs) -> (cmd, StaticRows.perFrameOf(cmd#scene, List.map(c -> c#rows, cs))));
                let grouped = groupScenesWith(s#planner, caps, dest#samples, perFrame);
                let orders = WebGpuMaterials.resolve(s#materials, name -> noteMaterialBuild(s, name, FrameDiagnostics.BuildReason.First), grouped#requests);
                List.forEach(scene -> noteSkips(host, skipsOf(grouped#members, scene)), grouped#scenes);
                let (planned, rows) = planScenes(s#planner, caps, orders, grouped);
                let shadowUses = Render3d.ShadowMaps.assign(s#planner, List.map(plan -> plan#shadowPlans, planned));
                (List.zip(planned, shadowUses), grouped, packPoses(r, rows), carried)
            });
            let inputs = { members = grouped#members, poses = poses };
            timed(s, Phase.Draw, () -> List.zip(plans, carried) |> List.mapWithIndex((i, pc) -> prepareScene(r, host, dest, inputs, i, pc)) |> List.toVector)
        }

    /// 持ち越す集まりの行を作る材料（Render3d.WebGpuStatic）。
    def staticBuilderOf(r: Renderer, host: Host): WebGpuStatic.Builder \ IO =
        let RendererData.RendererData(s) = r;
        { gpu = s#gpu, planner = s#planner, materials = s#materials, allocator = countingAllocator(r),
          noteBuild = name -> noteMaterialBuild(s, name, FrameDiagnostics.BuildReason.First),
          tables = tablesOf(r, host) }

    /// 前半の行の番号を振る表（今のコマの世代）。
    def tablesOf(r: Renderer, host: Host): Render3d.SceneList.Tables \ IO =
        let RendererData.RendererData(s) = r;
        { meshes = s#meshes, textures = WebGpuMaterials.texturesOf(s#materials), layouts = s#layouts, gen = Array.get(0, s#gen), gpuMip = false,
          textureOf = host#textureOf, flipsTargetV = false }

    /// 1 回の prepare の場面をまたいで変わらない物。members = batch の描く物（Render3d.ScenePlan.Grouped#members）・poses = その prepare の姿勢（無ければ None）。
    type alias PrepareInputs = { members = MutList[MeshDraw, Static], poses = Option[Poses] }

    /// 1 回の prepare の姿勢。data = 詰めた値（頭の Render3dWgsl.poseHeaderBytes() に 1 行のジョイントの数）・bytes = その長さ・
    /// written = 今の encoder で送った時の (epoch, group 2)（送っていないか、送った後に submit したら書き直す）。
    type alias Poses = { data = ByteBuffer, bytes = Int32, written = Ref[Option[(Int64, BindGroup)], Static] }

    /// 場面 1 つを描いて貼る物を返す（描かない場面・場面の矩形か scissor が空なら None）。pc = (場面の計画と、その影の地図の描き先（Render3d.ShadowMaps.assign の答え）, 場面の持ち越した集まり)。
    def prepareScene(r: Renderer, host: Host, dest: Dest, inputs: PrepareInputs, index: Int32,
                     pc: ((ScenePlan[SpanBatch], List[ShadowMapUse]), List[Carried])): Option[Paste] \ IO =
        let ((plan, uses), carried) = pc;
        let cmd = plan#cmd;
        let vp = dest#viewport;
        let rect = sceneRect(vp, cmd);
        let scissor = clipBox(vp, rect, cmd#clip);
        let visible = rect#width > 0 and rect#height > 0 and scissor#width > 0 and scissor#height > 0
                      and cmd#scene#size#x > 0.0 and cmd#scene#size#y > 0.0;
        if (not visible) None
        else {
            let (width, height, samples) = match cmd#scene#resolution {
                case Scene3d.Resolution.Native => (rect#width, rect#height, dest#samples)
                // WhyNot: Design の解像度の描き先に標本を持たせない — GL の Render3d.renderDesign と同じ（ドット絵と画素をそろえる場面にふちのならしは要らない）。
                case Scene3d.Resolution.Design => (Int32.max(1, Num.floorInt(cmd#scene#size#x + 0.5)), Int32.max(1, Num.floorInt(cmd#scene#size#y + 0.5)), 1)
            };
            let target = targetOf(r, host, (dest#key, index), { width = width, height = height, format = dest#format, samples = samples });
            drawInto(r, host, target, inputs, plan, uses, carried, "${dest#key}:${index}");
            writePaste(r, target, topLeftOf(dest#height, rect));
            noteWritten(r, (dest#key, index));
            Some({ group = target#pasteGroup, scissor = topLeftOf(dest#height, scissor), key = (dest#key, index) })
        }

    /// 場面 1 つのまだ描けない物の種類と回数（0 回の種類も並べる。数えるのは host#skip）。
    /// 物は計画が間引かなかった物（culled でない物・骨つきの物は Scene3d.isOutsideFrustum が間引かない）を 1 体 1 回だけ数える（影の地図・空・ビルボード・環境マップは描く）。
    /// 奥行きの書き出しの場面は、形だけで書く物のうち材質の道で書くはずの物（cutout と両面。計画が半透明の物と、cutout でも両面でもない材質を外してある）だけを数える
    /// （空は一番奥の白で塗り、影と環境マップは読まない）。
    def skipsOf(members: MutList[MeshDraw, Static], scene: GroupedScene): List[(String, Int32)] \ IO =
        let undrawable = List.foldLeft((acc, g) -> tallyGroup(members, g, g#batch#start, g#batch#start + g#batch#count, acc), 0, scene#groups);
        match scene#mainPass {
            case ScenePassSpec.DepthOut(_) =>
                ("3D の奥行きの書き出しの材質の物（描けない版を形で書く）", undrawable) :: Nil
            case ScenePassSpec.Color =>
                ("3D の alpha to coverage の材質の物（頂点の色で描く）", undrawable) :: Nil
        }

    /// group の batch の members の i から end の前までの、描けない版の材質の物の数を acc に足して返す。
    def tallyGroup(members: MutList[MeshDraw, Static], g: Group, i: Int32, end: Int32, acc: Int32): Int32 \ IO =
        if (i >= end) acc
        else tallyGroup(members, g, i + 1, end, acc + undrawableCountOf(g#surface, MutList.get(i, members)))

    /// 物 d が描けない版の材質の物なら 1（視錐台の外の物は数えない）。surface = d の group の材質（骨つきの物も同じ。描けない版の材質の骨つきの物は骨つきの頂点の色で描く）。
    def undrawableCountOf(surface: Option[MaterialRequest], d: MeshDraw): Int32 =
        if (d#culled) 0
        else match surface {
            case Some((_, kind)) if not WebGpuMaterials.isDrawable(kind) => 1
            case _ => 0
        }

    def noteSkips(host: Host, skips: List[(String, Int32)]): Unit \ IO =
        List.forEach(match (kind, n) -> host#skip(kind, n), skips)

    /// GL の左下が原点の画素の矩形を、描き先の左上が原点の (x, y, 幅, 高さ) にする。
    def topLeftOf(height: Int32, box: PixelBox): (Int32, Int32, Int32, Int32) =
        (box#x, height - box#y - box#height, box#width, box#height)

    /// 場面を target へ描く: 影の地図の pass を積んでから、計画の pass ごとに、地の色（clearOf）と深度を消して行を描く pass を積む。uses = 場面の影の地図の描き先。
    // WhyNot: 列の頭の pass だけ消して残りを前の中身から描く形（GL は場面の頭で 1 回だけ消す）にしない — 場面の描き先へ書く pass は今は場面 1 つに 1 つ（影の地図は描き先が違い、列の外）。
    /// targetKey = 描き先の鍵の字（持ち越した集まりの bundle を描き先ごとに分ける）。
    def drawInto(r: Renderer, host: Host, target: SceneTarget, inputs: PrepareInputs, plan: ScenePlan[SpanBatch], uses: List[ShadowMapUse],
                 carried: List[Carried], targetKey: String): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let staged = stageScene(r, host, target, inputs, plan, uses, carried);
        let encoder = host#encoder();
        let instances = Array.get(0, s#instances);
        let shadowDraw = { encoder = encoder, notePass = host#notePass, meshStore = s#meshStore, instances = instances, instanceBase = staged#instanceBase,
                           poseGroup = staged#poseGroup, vertexModule = s#vertexModule, skinnedModule = s#skinnedModule, emptyLayout = s#emptyLayout,
                           emptyGroup = s#emptyGroup, poseLayout = s#poseLayout,
                           created = () -> Render3d.Counts.count(s, Render3d.Counts.Counter.TargetRebuilds, 1),
                           unbound = n -> host#skip("3D の付けられなかった行の物（pipeline か group が無い・飛ばす）", n),
                           carried = List.map(c -> WebGpuStatic.shadowRunnerOf(s#statics, s#gpu, Array.get(0, s#gen), c, WebGpuShadows.depthFormat()), carried),
                           billboard = drawShadowBillboardRow(r, host) };
        staged#shadows |> List.forEach(WebGpuShadows.encode(s#shadows, Array.get(0, s#gen), shadowDraw));
        let scene = plan#cmd#scene;
        let variant = passVariantOf(scene);
        let sceneGroup = sceneGroupOf(r, target, List.map(st -> st#pass, staged#shadows), staged#environment, variant);
        Scene3d.skyWarning(scene) |> Option.forEach(line -> Render3d.ScenePlan.warnOnce(s#planner, "@sky+background", line));
        let drawn = target#msaa |> Option.getWithDefault(target#color);
        let full = (0, 0, target#width, target#height);
        staged#passes |> List.forEach(match (spec, list, valuesBase) ->
            encodeScene(r, host, target, { spec = spec, list = list, instanceBase = staged#instanceBase, valuesBase = valuesBase, poseGroup = staged#poseGroup,
                                           sceneGroup = sceneGroup, sky = WebGpuSky.isDrawn(scene), carried = carried, targetKey = targetKey, variant = variant },
                        { color = drawn.defaultView(), resolve = target#msaa |> Option.map(_ -> target#color.defaultView()),
                          clear = Some(clearOf(spec, scene)), depth = target#depth.defaultView(), viewport = full, scissor = full }))

    /// 場面の group 0: 影の地図も環境マップも無い既定の変種の場面なら target の物。ほかは、スポットと太陽の影の地図（無い方は代わりの絵）を binding 1・2 に、
    /// 環境マップの絵 environment（無ければ代わりの絵）を binding 3 に、変種 variant の場面は R3dLight（target#lightValues）を 6 に・+ps なら点光源の影の atlas
    /// （無ければ代わりの絵）を 7 に付けた物を作る（submit の後に手放す）。影の地図の pass を積んだ後に呼ぶ（その間の submit で手放さない）。
    /// 描き先と読む絵が同じ group は前のコマの物を使う（持ち越した集まりの bundle が group 0 を参照で比べて使い続ける）。
    def sceneGroupOf(r: Renderer, target: SceneTarget, shadows: List[ShadowPass], environment: Option[(Texture, Int32)], variant: ShaderVariant): BindGroup \ IO =
        let RendererData.RendererData(s) = r;
        let code = layoutCodeOf(variant);
        if (code == 0 and List.isEmpty(shadows) and Option.isEmpty(environment)) target#sceneGroup
        else {
            let viewFor = (kind: Int32) -> shadows |> List.find(p -> samplingCodeOf(p#map#sampling) == kind) |> Option.flatMap(p -> WebGpuShadows.viewOf(s#shadows, p#map#key))
                                                  |> Option.getWithDefault(s#blankDepth.defaultView());
            let envImage = environment |> Option.map(fst) |> Option.getWithDefault(s#blankImage);
            let base: Vector[Object] = Vector#{checked_cast(target#sceneValues), checked_cast(target#camera), checked_cast(viewFor(0)), checked_cast(viewFor(1)),
                                               checked_cast(envImage.defaultView())};
            let extra: Vector[Object] = if (code == 0) Vector.empty()
                                        else if (code == 1) Vector#{checked_cast(target#lightValues)}
                                        else Vector#{checked_cast(target#lightValues), checked_cast(viewFor(2))};
            let parts = Vector.append(base, extra);
            let gen = Array.get(0, s#gen);
            match Ref.get(s#sceneGroups) |> List.find(e -> isSameParts(e#parts, parts)) {
                case Some(e) =>
                    Array.put(gen, 0, e#lastUsed);
                    e#group
                case None =>
                    let desc = new BindGroupDesc("fge scene3d shadowed or environment", sceneLayoutOf(r, code));
                    discard desc.buffer(0, target#sceneValues, 0i64, Int32.toInt64(WebGpuSceneValues.sceneValueBytes()));
                    discard desc.textureView(1, viewFor(0)).textureView(2, viewFor(1));
                    discard desc.textureView(3, envImage.defaultView()).sampler(4, s#environmentSampler).buffer(5, target#camera, 0i64, Int32.toInt64(Render3dWgsl.cameraBytes()));
                    if (code >= 1) discard desc.buffer(Render3dWgsl.lightBinding(), target#lightValues, 0i64, Int32.toInt64(Render3dWgsl.lightValueBytes())) else ();
                    if (code >= 2) discard desc.textureView(Render3dWgsl.pointShadowMapBinding(), viewFor(2)) else ();
                    let group = s#gpu.createBindGroup(desc);
                    Ref.put({ parts = parts, group = group, lastUsed = Array#{gen} @ Static } :: Ref.get(s#sceneGroups), s#sceneGroups);
                    group
            }
        }

    /// 影の地図か環境マップを読む場面の group 0 の控え 1 つ。parts = 付けた物（描き先の値と目の buffer・スポットと太陽の影の地図の view・環境マップの view。参照で比べる）・
    /// lastUsed = 最後に使ったコマの世代（要素 1 つ）。
    // WhyNot: 鍵を影の地図の鍵（Render3d.ShadowMaps.Key）にしない — 地図の鍵は prepare ごとに場面の並びで決まり、同じ描き先が次のコマで別の地図を読む。付けた view そのもので比べる。
    type alias SceneGroup = { parts = Vector[Object], group = BindGroup, lastUsed = Array[Int64, Static] }

    def isSameParts(a: Vector[Object], b: Vector[Object]): Bool \ IO =
        Vector.length(a) == Vector.length(b) and Vector.forAll(i -> Objects.equals(Vector.get(i, a), Vector.get(i, b)), Vector.range(0, Vector.length(a)))

    /// 影の地図の種類の番号（0 = スポット・1 = 太陽・2 = 点光源の atlas）。
    def samplingCodeOf(s: ShadowSampling): Int32 = match s {
        case ShadowSampling.Spot(_)  => 0
        case ShadowSampling.Sun(_)   => 1
        case ShadowSampling.Point(_) => 2
    }

    /// pass spec の地の色（GL の Render3d.drawScene の beginScene と drawSky と同じ）: 空の無い場面は background（無ければ透明）。
    /// 奥行きの書き出しは、空を塗る場面（Scene3d.drawnSkyOf）なら一番奥の白。
    def clearOf(spec: ScenePassSpec, scene: Scene3d.Scene3dCmd): (Float64, Float64, Float64, Float64) =
        let background = if (Option.isEmpty(scene#sky)) scene#environment#background else None;
        let ground = background |> Option.map(c -> (c#r, c#g, c#b, 1.0)) |> Option.getWithDefault((0.0, 0.0, 0.0, 0.0));
        match spec {
            case ScenePassSpec.DepthOut(_) if Option.nonEmpty(Scene3d.drawnSkyOf(scene)) => (1.0, 1.0, 1.0, 1.0)
            case _                                                                       => ground
        }

    /// 場面 1 つを描く前の仕事を済ませる: 1 体ごとの値と姿勢を送り、影の地図の pass と計画の pass ごとの行の形を上げ、場面の値を target の buffer へ書く。
    /// 返すのは影の地図の pass と、pass ごとの行と形と、1 体ごとの値の位置と姿勢の group。uses = 場面の影の地図の描き先。
    def stageScene(r: Renderer, host: Host, target: SceneTarget, inputs: PrepareInputs, plan: ScenePlan[SpanBatch], uses: List[ShadowMapUse],
                   carried: List[Carried]): Staged \ IO =
        let RendererData.RendererData(s) = r;
        let (passes, shadows, instances) = numberInstances(r, host, inputs#members, plan, uses);
        let gen = Array.get(0, s#gen);
        let allocator = countingAllocator(r);
        let source = { textureOf = host#textureOf, own = plan#cmd#scene#textures |> List.map(t -> (Texture3d.name(t), t)) |> List.toMap };
        passes |> List.forEach(match (_, list) -> {
            uploadRows(s#meshes, allocator, gen, list);
            WebGpuMaterials.uploadTextures(s#materials, source, registeredOf(r, host), gen, list)
        });
        shadows |> List.forEach(p -> uploadRows(s#meshes, allocator, gen, p#list));
        carried |> List.forEach(WebGpuStatic.stage(s#gpu, s#materials, source, registeredOf(r, host), gen, plan#cmd#scene#time));
        let shadowValueBytes = List.sumWith(p -> if (hasBillboardRows(p#list)) 4 * Array.length(p#list#values) + 4 * Render3d.MaterialValues.valueAlign() else 0, shadows);
        let valueBytes = List.sumWith(pl -> 4 * Array.length(snd(pl)#values) + 4 * Render3d.MaterialValues.valueAlign(), passes) + shadowValueBytes;
        let poseBytes = inputs#poses |> Option.filter(p -> not isWrittenNow(r, p)) |> Option.map(p -> p#bytes + storageAlignBytes()) |> Option.getWithDefault(0);
        // WhyNot: 1 体ごとの値・姿勢・材質の値を別々に「入らなければ submit」で送らない — 後に送る方が submit すると、先に送った方を次の場面が頭から上書きする。
        // WhyNot: 影の地図の描き先を描き直す submit を送った後に回さない — 送った姿勢の group 2 と 1 体ごとの値の位置を、submit の後の影の描き込みが使う。
        if (needsFlush(r, instances#bytes, valueBytes, poseBytes) or WebGpuShadows.needsFlush(s#shadows, shadows)) flushHost(r, host) else ();
        WebGpuMaterials.reserveValues(s#materials, valueBytes);
        let instanceBase = sendInstances(r, host, instances#data, instances#bytes);
        let poseGroup = inputs#poses |> Option.map(sendPoses(r));
        let staged = passes |> List.map(match (spec, list) -> (spec, list, WebGpuMaterials.sendValues(s#materials, list)));
        let stagedShadows = shadows |> List.map(p -> { pass = p, valuesBase = if (hasBillboardRows(p#list)) WebGpuMaterials.sendValues(s#materials, p#list) else -1 });
        passes |> List.forEach(pl -> missingBillboardTexturesOf(snd(pl)) |> List.forEach(name ->
            Render3d.ScenePlan.warnOnce(s#planner, "@billboard:" + name, Render3d.missingBillboardTextureLine(name))));
        countRows(r, plan, passes, shadows, carried);
        let environment = ensureEnvironment(r, host, source, gen, plan#cmd#scene);
        writeSceneValues(r, target, plan, shadows, environment);
        { shadows = stagedShadows, passes = staged, instanceBase = instanceBase, poseGroup = poseGroup, environment = environment }

    /// 影の地図の行の列 list にビルボードの行があるか。
    def hasBillboardRows(list: SceneList): Bool = firstBillboardRowOf(list) < firstBlendedRowOf(list)

    /// 場面の環境マップの絵と mip のレベルの数（環境マップの無い場面は None）。絵が見つからなければ代わりの絵（透明な黒・mip 無し）で読み、名前ごとに 1 回知らせる
    /// （GL の Render3d.Material.bindEnvironmentMap と同じ）。
    def ensureEnvironment(r: Renderer, host: Host, source: TextureSource, gen: Int64, scene: Scene3d.Scene3dCmd): Option[(Texture, Int32)] \ IO =
        let RendererData.RendererData(s) = r;
        Scene3d.environmentTextureNamesOf(scene) |> List.head |> Option.map(name ->
            match WebGpuMaterials.ensureEnvironmentTexture(s#materials, source, registeredOf(r, host), gen, name) {
                case Some(found) => found
                case None =>
                    Render3d.ScenePlan.warnOnce(s#planner, "missing:" + name, "scene3d: 環境マップの絵 '${name}' が見つからない — 0（黒・透明）で読む"
                        + "（tex3d: の名前は場面の textures に、ほかは project.json の textures に同名の宣言があるか確認）");
                    (s#blankImage, 1)
            })

    /// 形を作るたびに MeshUploads を数える、形の表へ渡す関数の組。
    def countingAllocator(r: Renderer): MeshTable.MeshAllocator =
        let RendererData.RendererData(s) = r;
        let inner = meshAllocator(s#gpu, s#meshStore);
        { create = (handle, mesh) -> { Render3d.Counts.count(s, Render3d.Counts.Counter.MeshUploads, 1); inner#create(handle, mesh) }, destroy = inner#destroy }

    /// 1 体ごとの値 instanceBytes・材質の値 valueBytes・姿勢 poseBytes（そろえの余りを含む）の、どれかが今の encoder の空きに入らないか。
    def needsFlush(r: Renderer, instanceBytes: Int32, valueBytes: Int32, poseBytes: Int32): Bool \ IO =
        let RendererData.RendererData(s) = r;
        let capacity = sizeOf(Array.get(0, s#instances));
        Array.get(0, s#instanceUsed) + instanceBytes > capacity or not WebGpuMaterials.hasRoom(s#materials, valueBytes)
            or (poseBytes > 0 and Array.get(0, s#posesUsed) + poseBytes > sizeOf(Array.get(0, s#poses)))

    def sizeOf(b: Buffer): Int32 \ IO =Int64.tryToInt32(b.size()) |> Option.getWithDefault(Int32.maxValue())

    /// 場面の置いた物と描く物の数と、行ごとの draw call と分かれた理由を数える（GL の Render3d.GlRows.uploadRows と drawMeshRange と Render3d.drawBillboards と同じ欄）。
    /// 描く行は描く物のある頂点の色の行・骨つきの行と、値のある材質の行とビルボードの行（ビルボードは描く物の数に入れない）。
    /// 数えるのは描く前（GL は描いた時）なので、描く時に pipeline か group が付かずに飛ばした行も数に残る（その行は host#skip にも出る）。
    /// 影の地図の pass の行は draw call と分かれた理由だけを数える（描く物の数は GL と同じく場面の pass の分）。
    /// 持ち越した集まり carried の行は、色の pass の行と、影の地図の pass ごとの影の行を数える。
    def countRows(r: Renderer, plan: ScenePlan[SpanBatch], passes: ScenePasses, shadows: List[ShadowPass], carried: List[Carried]): Unit \ IO =
        let RendererData.RendererData(s) = r;
        shadows |> List.forEach(p -> discard countRowsOf(s, p#list));
        shadows |> List.forEach(_ -> carried |> List.forEach(c -> WebGpuStatic.addRowCounts(s, c#shadowCounts)));
        carried |> List.forEach(c -> WebGpuStatic.addRowCounts(s, c#litCounts));
        let drawn = passes |> List.sumWith(match (_, list) -> countRowsOf(s, list)) + List.sumWith(c -> c#litCounts#drawn, carried);
        let placed = StaticRows.placedCountOf(plan#cmd#scene, List.map(c -> c#rows, carried));
        countInstances(s, placed, drawn);
        passes |> List.forEach(pl -> Render3d.Counts.countBillboardRuns(s, snd(pl)));
        Render3d.ScenePlan.noteStaticGroupHint(s#planner, placed, plan#cmd#scene);
        Render3d.Counts.countDroppedLights(s, plan#cmd#scene)

    /// stageScene の答え。shadows = 影の地図の pass（行の形は上げてある）・passes = 計画の pass ごとの (pass, 行, 行の values を送った位置（バイト）)（行の形と絵は上げてある）・
    /// poseGroup = 姿勢の group 2（姿勢の無い prepare は None）・environment = 環境マップの絵と mip のレベルの数（ensureEnvironment）。
    type alias Staged = { shadows = List[WebGpuShadows.StagedShadow], passes = List[(ScenePassSpec, SceneList, Int32)], instanceBase = Int32, poseGroup = Option[BindGroup],
                          environment = Option[(Texture, Int32)] }

    /// encodeScene が描く pass 1 つ。valuesBase = 行の values を送った位置（バイト）・poseGroup = 姿勢の group 2・sceneGroup = 場面の group 0（sceneGroupOf）・
    /// sky = 色の pass の頭で空を描くか（WebGpuSky.isDrawn）・carried = 場面の持ち越した集まり（空の後・行の前に描く）・targetKey = 描き先の鍵の字・
    /// variant = 場面の pass の変種（passVariantOf。pass の pipeline の group 0 の layout と frag を決める）。
    type alias StagedPass = { spec = ScenePassSpec, list = SceneList, instanceBase = Int32, valuesBase = Int32, poseGroup = Option[BindGroup], sceneGroup = BindGroup,
                              sky = Bool, carried = List[Carried], targetKey = String, variant = ShaderVariant }

    /// 場面を描く pass の描き先。color = 描く view・resolve = 標本つきの描き先なら resolve する先・clear = 消す色（None なら前の中身に描き足す）・
    /// depth = 深度の view（いつも 1 で消す）・viewport と scissor = 描き先の左上が原点の (x, y, 幅, 高さ)。
    type alias PassTarget = {
        color = TextureView, resolve = Option[TextureView], clear = Option[(Float64, Float64, Float64, Float64)],
        depth = TextureView, viewport = (Int32, Int32, Int32, Int32), scissor = (Int32, Int32, Int32, Int32)
    }

    /// 場面の pass 1 つの行を onto へ描く pass を積む（pipeline は行ごとに RowDrawer が付ける・場面の値は staged の group 0）。
    def encodeScene(r: Renderer, host: Host, target: SceneTarget, staged: StagedPass, onto: PassTarget): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let desc = new RenderPassDesc("fge scene3d");
        match onto#clear {
            case Some((cr, cg, cb, ca)) => discard desc.clearColor(onto#color, cr, cg, cb, ca)
            case None                   => discard desc.loadColor(onto#color)
        };
        Option.forEach(v -> discard desc.resolveTo(v), onto#resolve);
        discard desc.clearDepth(onto#depth, 1.0);
        let pass = host#encoder().beginRenderPass(desc);
        host#notePass();
        let (vx, vy, vw, vh) = onto#viewport;
        pass.setViewport(Int32.toFloat64(vx), Int32.toFloat64(vy), Int32.toFloat64(vw), Int32.toFloat64(vh), 0.0, 1.0);
        let (sx, sy, sw, sh) = onto#scissor;
        pass.setScissorRect(sx, sy, sw, sh);
        pass.setBindGroup(0, staged#sceneGroup);
        let code = layoutCodeOf(staged#variant);
        if (staged#sky and isColorPass(staged#spec)) {
            WebGpuSky.draw(s#sky, pass, target#format, target#samples, (code, sceneLayoutOf(r, code)));
            Render3d.Counts.countDrawCall(s, Render3d.Counts.BatchBreak.Sky)
        } else ();
        let materialPass = (base: Int32, values: Buffer, programs: Vector[Option[WebGpuMaterials.Program]], groups: Ref[List[BindGroup], Static]) ->
            { base = base, values = values, programs = programs, format = target#format, samples = target#samples, sceneLayout = sceneLayoutOf(r, code),
              poseLayout = s#poseLayout, hasPoses = Option.nonEmpty(staged#poseGroup), bound = Ref.fresh(Static, BoundPipeline.Unbound), groupRow = Array#{-1} @ Static,
              groups = groups };
        let bundleTarget = { color = Some(WebGpuPipelines.textureFormatOf(target#format)), depth = sceneDepthFormat(), samples = target#samples };
        // WhyNot: 鍵に描き先を入れずに形式と標本だけにしない — group 0 は描き先ごとに違い、同じ集まりを 2 つの描き先の場面で描くと毎コマ積み直しになる。
        let bundleKey = "color:${staged#targetKey}:${WebGpuPipelines.formatCode(target#format)}:${target#samples}:${passCodeOf(staged#spec)}${variantKeyOf(staged#variant)}";
        let epoch = WebGpuMaterials.textureEpochOf(s#materials);
        // WhyNot: 持ち越した物を場面の行の後に描かない — 半透明の行は場面の行の末尾にあり、持ち越した不透明の物より後に重ねる。同じ深さで重なる面の勝ち方は GL（集まりを instances の後ろに並べる）と逆になりうる。
        staged#carried |> List.forEach(c -> WebGpuStatic.runBundle(s#statics, s#gpu, Array.get(0, s#gen), c, bundleKey, staged#sceneGroup, epoch, bundleTarget, (commands, groups) -> {
            commands.setVertexBuffer(1, c#instances, 0i64, c#instances.size());
            drawRows(commands, s#meshStore, rowDrawerOf(r, host, target, staged, materialPass(0, c#values, c#programs, groups)), c#rows#list, 0)
        }, pass));
        // WhyNot: bundle を流した後に group 0 を付け直さずに描かない — bundle を流すと pass の bind group と頂点の buffer は付いていない形に戻る。
        if (List.isEmpty(staged#carried)) () else pass.setBindGroup(0, staged#sceneGroup);
        Option.forEach(g -> pass.setBindGroup(2, g), staged#poseGroup);
        let instances = Array.get(0, s#instances);
        pass.setVertexBuffer(1, instances, 0i64, instances.size());
        let mp = materialPass(staged#valuesBase, WebGpuMaterials.valuesBufferOf(s#materials), WebGpuMaterials.currentPrograms(s#materials), WebGpuMaterials.frameGroupsOf(s#materials));
        let drawer = rowDrawerOf(r, host, target, staged, mp);
        // WhyNot: 不透明の行・ビルボードの行・半透明の行を GL の drawPass のように 3 回に分けて流さない — 行の順（SceneList の頭）がその 3 つの順で、
        //   GL が分ける理由の深度の書き込みと blend は WebGPU では pipeline ごとに決まっている。
        drawRows(checked_cast(pass), s#meshStore, drawer, staged#list, staged#instanceBase);
        pass.end()

    /// 場面の pass の行を描く時に pipeline と group を付ける関数の組（材質の行は mp の値と program で付ける）。
    def rowDrawerOf(r: Renderer, host: Host, target: SceneTarget, staged: StagedPass, mp: WebGpuMaterials.MaterialPass): RowDrawer =
        let RendererData.RendererData(s) = r;
        let bindShape = (p: RenderCommands, mesh: MeshBuffers, skin: Option[Int32]) -> {
            let key = BoundPipeline.Shape(passCodeOf(staged#spec), mesh#stride, Option.nonEmpty(skin));
            if (Ref.get(mp#bound) == key) () else {
                p.setPipeline(pipelineOf(r, target#format, target#samples, staged#spec, mesh#stride, skin, staged#variant));
                // WhyNot: 骨つきの版で group 1 を付けずに描かない — pipeline の layout に group 2 があると group 1 も付いていなければならず、前の材質の group 1 は layout が違う。
                if (Option.nonEmpty(skin)) p.setBindGroup(1, s#emptyGroup) else ();
                Ref.put(key, mp#bound);
                Array.put(-1, 0, mp#groupRow)
            };
            true
        };
        { shape = (p, mesh) -> bindShape(p, mesh, None),
          skinned = (p, mesh) -> Option.nonEmpty(staged#poseGroup) and Option.nonEmpty(mesh#skinAt) and bindShape(p, mesh, mesh#skinAt),
          material = (p, list, row, mesh) -> WebGpuMaterials.bindRow(s#materials, mp, p, list, row, mesh),
          billboard = (p, list, row) -> drawBillboardRow(r, host, mp, staged#variant, p, list, row),
          unbound = n -> host#skip("3D の付けられなかった行の物（pipeline か group が無い・飛ばす）", n) }

    /// ビルボードの行 row（同じ絵の板の並び）を 1 回の instanced draw で描く（貼る絵の group が無ければ偽）。絵が見つからなかった行（値の無い行・知らせは stageScene）は描かずに真。
    /// 値は行の values を送った位置（mp#base）から頂点の buffer 0（instance ごと）として読む。
    /// 付けた pipeline と group 1 は材質の行と共用の控え（mp）に書き、次の材質の行が付け直すようにする。
    def drawBillboardRow(r: Renderer, host: Host, mp: WebGpuMaterials.MaterialPass, variant: ShaderVariant, p: RenderCommands, list: SceneList, row: Int32): Bool \ IO =
        let RendererData.RendererData(s) = r;
        let values = valuesAt(list, row);
        let n = countAt(list, row);
        match host#groupById(textureIdAt(list, row)) {
            case _ if values < 0 => true
            case None => false
            case Some(group) =>
                if (Ref.get(mp#bound) == BoundPipeline.Billboard) () else {
                    p.setPipeline(WebGpuBillboards.pipelineOf(s#billboards, mp#format, mp#samples, variant, (layoutCodeOf(variant), mp#sceneLayout)));
                    Ref.put(BoundPipeline.Billboard, mp#bound)
                };
                Array.put(-1, 0, mp#groupRow);
                p.setBindGroup(1, group);
                p.setVertexBuffer(0, WebGpuMaterials.valuesBufferOf(s#materials), Int32.toInt64(mp#base + 4 * values), Int32.toInt64(n) * WebGpuBillboards.valueBytes());
                p.draw(6, n, 0, 0);
                true
        }

    /// 影の地図のビルボードの行 row（同じ絵の板の並び）を描く（貼る絵の group が無ければ偽）。値は行の values を送った位置 valuesBase から頂点の buffer 0 として読む（場面の行の drawBillboardRow と同じ）。
    /// group 0（光の目と板の向き）は pass の頭で付けてある。rightPerBillboard なら板の横の向きを行の値から読む pipeline（点光源の面）。
    def drawShadowBillboardRow(r: Renderer, host: Host, p: RenderCommands, list: SceneList, row: Int32, valuesBase: Int32, rightPerBillboard: Bool): Bool \ IO =
        let RendererData.RendererData(s) = r;
        let values = valuesAt(list, row);
        let n = countAt(list, row);
        match host#groupById(textureIdAt(list, row)) {
            case _ if values < 0 => true
            case None => false
            case Some(group) =>
                p.setPipeline(WebGpuBillboards.shadowPipelineOf(s#billboards, WebGpuShadows.layoutOf(s#shadows), WebGpuShadows.depthFormat(), rightPerBillboard));
                p.setBindGroup(1, group);
                p.setVertexBuffer(0, WebGpuMaterials.valuesBufferOf(s#materials), Int32.toInt64(valuesBase + 4 * values), Int32.toInt64(n) * WebGpuBillboards.valueBytes());
                p.draw(6, n, 0, 0);
                true
        }

    /// 場面の頂点の色の batch・骨つきの batch・材質の batch（半透明も）と、影の地図の batch（world と姿勢の行だけ）に 1 体ごとの値の番号を振って CPU の入れ物へ詰め、
    /// 計画の pass ごとの行の列と、uses の描き先への影の地図の pass と、詰めた値（送るのは呼ぶ側）を返す。
    def numberInstances(r: Renderer, host: Host, members: MutList[MeshDraw, Static], plan: ScenePlan[SpanBatch], uses: List[ShadowMapUse]):
            (ScenePasses, List[ShadowPass], { data = ByteBuffer, bytes = Int32 }) \ IO =
        let RendererData.RendererData(s) = r;
        let bytes = Render3d.InstanceValues.countOf(plan) * Render3dWgsl.instanceBytes();
        let raw = cpuInstancesFor(r, bytes);
        let out = raw.asFloatBuffer();
        let next = Array#{0} @ Static;
        let numbered = Render3d.InstanceValues.mapBatches(mode -> numberSpan(out, s#scratch, Int32.maxValue(), next, members, mode), plan);
        let tables = tablesOf(r, host);
        let passes = buildScenePasses(tables, numbered);
        (passes, Render3d.ShadowMaps.buildPasses(tables, uses, numbered), { data = raw, bytes = bytes })

    /// bytes を書ける 1 体ごとの値の CPU の入れ物（足りなければ要る大きさか倍の大きい方へ作り直す）。
    def cpuInstancesFor(r: Renderer, bytes: Int32): ByteBuffer \ IO =
        let RendererData.RendererData(s) = r;
        let held = Array.get(0, s#cpuInstances);
        if (held.capacity() >= bytes) held
        else {
            let grown = directBytes(Int32.max(bytes, 2 * held.capacity()));
            Array.put(grown, 0, s#cpuInstances);
            grown
        }

    /// bytes の 1 体ごとの値を buffer の空きへ書き、書いた位置（体の番号）を返す。空きに入らなければ積んだ pass を submit して頭から書き、
    /// 頭からでも入らなければ buffer を要る大きさか倍の大きい方へ作り直す。
    def sendInstances(r: Renderer, host: Host, data: ByteBuffer, bytes: Int32): Int32 \ IO =
        let RendererData.RendererData(s) = r;
        let capacity = sizeOf(Array.get(0, s#instances));
        if (Array.get(0, s#instanceUsed) + bytes > capacity) flushHost(r, host) else ();
        if (bytes > capacity) {
            Array.get(0, s#instances).destroy();
            Array.put(createInstanceBuffer(s#gpu, Int32.max(bytes, 2 * capacity)), 0, s#instances)
        } else ();
        let at = Array.get(0, s#instanceUsed);
        if (bytes > 0) s#gpu.writeBuffer(Array.get(0, s#instances), Int32.toInt64(at), data, 0, bytes) else ();
        Array.put(at + bytes, 0, s#instanceUsed);
        at / Render3dWgsl.instanceBytes()

    // ── 姿勢 ──

    /// 1 回の prepare の姿勢 rows を CPU の入れ物へ詰める（頭の Render3dWgsl.poseHeaderBytes() に 1 行のジョイントの数）。姿勢が無ければ None。
    /// 行をもらえなかった姿勢があれば 1 回知らせる（GL の Render3d.GlRows.JointTexture.upload と同じ文）。
    /// 診断の JointUploads は GL と同じく prepare 1 回に 1 つ数える（submit の後に送り直した分は数えない）。
    def packPoses(r: Renderer, rows: PoseRows): Option[Poses] \ IO =
        let RendererData.RendererData(s) = r;
        if (rows#dropped > 0)
            Render3d.ScenePlan.warnOnce(s#planner, "@joint-rows", Log.fellBackLine("scene3d", "1 回の prepare の違う姿勢", "最後の行の姿勢", "${rows#limit} 行を超えた（${rows#dropped} 個）"))
        else ();
        if (rows#used == 0) None
        else {
            let header = Render3dWgsl.poseHeaderBytes();
            let bytes = header + 4 * floatCountOf(rows);
            let held = Array.get(0, s#cpuPoses);
            let data = if (held.capacity() >= bytes) held else {
                let grown = directBytes(Int32.max(bytes, 2 * held.capacity()));
                Array.put(grown, 0, s#cpuPoses);
                grown
            };
            discard data.putInt(0, rows#joints);
            discard data.position(header);
            let floats = data.slice().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
            discard data.position(0);
            packRows(rows#joints, posesInRowOrder(rows), floats);
            Render3d.Counts.count(s, Render3d.Counts.Counter.JointUploads, 1);
            Some({ data = data, bytes = bytes, written = Ref.fresh(Static, None) })
        }

    /// 姿勢 p を今の encoder で送ってあるか。
    def isWrittenNow(r: Renderer, p: Poses): Bool \ IO =
        let RendererData.RendererData(s) = r;
        Option.exists(w -> fst(w) == Array.get(0, s#epoch), Ref.get(p#written))

    /// 姿勢 p の group 2（今の encoder で送ってなければ姿勢の buffer の空きへ送って作る）。呼ぶ前に needsFlush で空きを確かめておく。
    /// それでも入らない（buffer を使っていない時に 1 つの prepare で足りない）なら、buffer を要る大きさか倍の大きい方へ作り直す。
    // WhyNot: prepare の頭で 1 回だけ送らない — 場面の間で submit が入る（1 体ごとの値の buffer があふれる）と、次の prepare が同じ encoder の頭から書き、
    //   まだ submit していない後の場面の姿勢を上書きする。submit の後の最初の場面で送り直す。
    def sendPoses(r: Renderer, p: Poses): BindGroup \ IO =
        let RendererData.RendererData(s) = r;
        let now = Array.get(0, s#epoch);
        match Ref.get(p#written) {
            case Some((epoch, group)) if epoch == now => group
            case _ =>
                let capacity = sizeOf(Array.get(0, s#poses));
                if (Array.get(0, s#posesUsed) == 0 and p#bytes > capacity) {
                    Array.get(0, s#poses).destroy();
                    Array.put(createPoseBuffer(s#gpu, Int32.max(p#bytes, 2 * capacity)), 0, s#poses)
                } else ();
                let at = roundUp(Array.get(0, s#posesUsed), storageAlignBytes());
                let buffer = Array.get(0, s#poses);
                s#gpu.writeBuffer(buffer, Int32.toInt64(at), p#data, 0, p#bytes);
                Array.put(at + p#bytes, 0, s#posesUsed);
                let desc = new BindGroupDesc("fge scene3d poses", s#poseLayout);
                discard desc.buffer(0, buffer, Int32.toInt64(at), Int32.toInt64(p#bytes));
                let group = s#gpu.createBindGroup(desc);
                Ref.put(group :: Ref.get(s#poseGroups), s#poseGroups);
                Ref.put(Some((now, group)), p#written);
                group
        }

    def roundUp(n: Int32, step: Int32): Int32 = ((n + step - 1) / step) * step

    /// 積んだ pass を submit し、1 体ごとの値と場面の値を頭から書けるようにする（積んだ pass が無く submit しなかった時も、書いた物を読む pass が無いので頭から書いてよい）。
    def flushHost(r: Renderer, host: Host): Unit \ IO =
        host#flush();
        afterSubmit(r)

    /// 材質が全体の登録の絵を読む道（2D の描き手の絵と、その段つきの写しを作る pass を積む encoder）。
    def registeredOf(r: Renderer, host: Host): WebGpuMaterials.Registered =
        let RendererData.RendererData(s) = r;
        { textureById = host#textureById, encoding = { encoder = host#encoder, notePass = host#notePass },
          noteCopy = () -> Render3d.Counts.count(s, Render3d.Counts.Counter.MipCopies, 1) }

    // ── 場面の値 ──

    /// 場面の値（光・かすみ・目・環境マップ・奥行きの書き出し・影の地図 shadows を引く値・空の向きの材料）と目と射影の行列とカメラの向き（Render3dWgsl.cameraDeclarations）を
    /// target の buffer へ書く。environment = 環境マップの絵と mip のレベルの数（ensureEnvironment。lightmap は物ごとの値・Render3d.MaterialValues）。
    def writeSceneValues(r: Renderer, target: SceneTarget, plan: ScenePlan[SpanBatch], shadows: List[ShadowPass], environment: Option[(Texture, Int32)]): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let scene = plan#cmd#scene;
        let picked = Scene3d.pickLights(scene);
        let values = s#cpuScene;
        WebGpuSceneValues.packSceneValues(values, s#sceneOffsets, lightDataOf(picked, environment |> Option.map(snd) |> Option.getWithDefault(0)));
        WebGpuSceneValues.packShadowValues(values, s#sceneOffsets, List.map(p -> p#map#sampling, shadows));
        writeLightValues(r, target, scene, shadows);
        // WhyNot: pass ごとに場面の値を書き分けない — 場面の値の buffer は描き先ごとに 1 つで、writeBuffer は encoder の pass より先に効くので、
        //   1 つの encoder の中で pass ごとに書き替えると、どの pass も最後に書いた値で描く。pass が場面の置いた物の 1 つの間は mainPass で足りる。
        WebGpuSceneValues.packPassValues(values, s#sceneOffsets, plan#mainPass);
        WebGpuSky.packValues(values, s#sceneOffsets, scene, target#width, target#height);
        s#gpu.writeBuffer(target#sceneValues, 0i64, values, 0, WebGpuSceneValues.sceneValueBytes());
        let camera = s#cpuCamera;
        let floats = camera.asFloatBuffer();
        discard floats.put(matrixArray(Camera3d.viewMatrix(scene#camera)));
        discard floats.put(matrixArray(Camera3d.projectionMatrix(scene#camera, Scene3d.aspectOf(scene))));
        WebGpuSceneValues.putVec3(camera, 128, cameraVec(Camera3d.right(scene#camera)), 0);
        WebGpuSceneValues.putVec3(camera, 144, cameraVec(Camera3d.up(scene#camera)), 0);
        WebGpuSceneValues.putVec3(camera, 160, cameraVec(Vec3.mul(Camera3d.forward(scene#camera), -1.0)), 0);
        s#gpu.writeBuffer(target#camera, 0i64, camera, 0, Render3dWgsl.cameraBytes())

    /// 変種の場面の R3dLight（点光源の影の値と 1 / unitsPerMeter²。GL の Render3d.Shadow.putPointShadow と Render3d.Light.putLights が渡す値と同じ）を target#lightValues へ書く。
    /// 既定の変種の場面は書かない。影を落とす灯りの無い場面は全部の slot が −1。
    def writeLightValues(r: Renderer, target: SceneTarget, scene: Scene3d.Scene3dCmd, shadows: List[ShadowPass]): Unit \ IO =
        let RendererData.RendererData(s) = r;
        if (layoutCodeOf(passVariantOf(scene)) == 0) ()
        else {
            WebGpuShadows.packLightValues(s#cpuLight, scene, List.map(p -> p#map#sampling, shadows));
            s#gpu.writeBuffer(target#lightValues, 0i64, s#cpuLight, 0, Render3dWgsl.lightValueBytes())
        }

    /// v を 3 個の float にする（GL の Render3d.putVec3 と同じく 1 つずつ f32 へ）。
    def cameraVec(v: Vec3.Vec3): Array[Float32, Static] \ IO = Array#{RenderUtil.f32(v#x), RenderUtil.f32(v#y), RenderUtil.f32(v#z)} @ Static

    /// 貼る矩形 rect（描き先の左上が原点）を target の Paste へ書く: 左上と大きさ。
    def writePaste(r: Renderer, target: SceneTarget, rect: (Int32, Int32, Int32, Int32)): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let (x, y, w, h) = rect;
        let data = s#cpuPaste;
        discard data.putFloat(0, Int32.toFloat32(x)).putFloat(4, Int32.toFloat32(y));
        discard data.putFloat(8, Int32.toFloat32(Int32.max(1, w))).putFloat(12, Int32.toFloat32(Int32.max(1, h)));
        s#gpu.writeBuffer(target#paste, 0i64, data, 0, 16)

    // ── 描き先と pipeline ──

    /// 鍵 key の描き先の値（場面の値（空の向きの材料を含む）・目・貼る矩形）を今の encoder で書いたと控える。
    // WhyNot: targetOf の頭で控えない — 値を書く途中で 1 体ごとの値の buffer があふれて submit すると控えが消え、
    //   同じ encoder で同じ鍵を 2 回目に書く時に、まだ submit していない 2D の pass の貼る矩形を上書きする。
    def noteWritten(r: Renderer, key: (Int32, Int32)): Unit \ IO =
        let RendererData.RendererData(s) = r;
        Ref.put(Set.insert(key, Ref.get(s#written)), s#written)

    /// 鍵 key の描き先（今の encoder で既に値を書いた鍵なら先に submit する）。寿命の表 Render3d.SceneTargets が、大きさ・形式・標本が違えば作り直し、
    /// 最後に使った世代を今の世代にする。値を書き終えたら noteWritten で控える。
    // WhyNot: 作り直しを TargetRebuilds に数えない — GL は Native の場面を描き先なしで描くので、WebGPU の場面ごとの描き先を数えると GL と数がそろわない
    //   （Design の場面だけを数えても、WebGPU は描き先の番号ごと・GL は形式ごとに鍵を作るので、同じ場面で数が分かれる）。
    def targetOf(r: Renderer, host: Host, key: (Int32, Int32), shape: Render3d.SceneTargets.Shape): SceneTarget \ IO =
        let RendererData.RendererData(s) = r;
        if (Set.memberOf(key, Ref.get(s#written))) flushHost(r, host) else ();
        fst(Render3d.SceneTargets.ensure(s#targets, targetAllocator(r), Array.get(0, s#gen), key, shape))

    def targetAllocator(r: Renderer): Render3d.SceneTargets.Allocator[SceneTarget] = { create = createTarget(r), destroy = destroyTarget }

    def createTarget(r: Renderer, shape: Render3d.SceneTargets.Shape): SceneTarget \ IO =
        let RendererData.RendererData(s) = r;
        let gpu = s#gpu;
        let format = WebGpuPipelines.textureFormatOf(shape#format);
        let color = gpu.createTexture("fge scene3d color", shape#width, shape#height, format,
                                      Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.TEXTURE_BINDING), 1, 1);
        let msaa = if (shape#samples > 1) Some(gpu.createTexture("fge scene3d msaa", shape#width, shape#height, format, TextureUsage.RENDER_ATTACHMENT, 1, shape#samples))
                   else None;
        let depth = gpu.createTexture("fge scene3d depth", shape#width, shape#height, sceneDepthFormat(), TextureUsage.RENDER_ATTACHMENT, 1, shape#samples);
        let uniformUsage = Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST);
        let sceneValues = gpu.createBuffer("fge scene3d values", Int32.toInt64(WebGpuSceneValues.sceneValueBytes()), uniformUsage);
        let camera = gpu.createBuffer("fge scene3d camera", Int32.toInt64(Render3dWgsl.cameraBytes()), uniformUsage);
        let paste = gpu.createBuffer("fge scene3d paste", 16i64, uniformUsage);
        let lightValues = gpu.createBuffer("fge scene3d light", Int32.toInt64(Render3dWgsl.lightValueBytes()), uniformUsage);
        let sceneDesc = new BindGroupDesc("fge scene3d", s#sceneLayout);
        discard sceneDesc.buffer(0, sceneValues, 0i64, Int32.toInt64(WebGpuSceneValues.sceneValueBytes()));
        discard sceneDesc.textureView(1, s#blankDepth.defaultView()).textureView(2, s#blankDepth.defaultView());
        discard sceneDesc.textureView(3, s#blankImage.defaultView()).sampler(4, s#environmentSampler).buffer(5, camera, 0i64, Int32.toInt64(Render3dWgsl.cameraBytes()));
        let pasteDesc = new BindGroupDesc("fge scene3d paste", s#pasteLayout);
        discard pasteDesc.textureView(0, color.defaultView()).buffer(1, paste, 0i64, 16i64);
        { width = shape#width, height = shape#height, format = shape#format, samples = shape#samples, color = color, msaa = msaa, depth = depth,
          sceneValues = sceneValues, camera = camera, sceneGroup = gpu.createBindGroup(sceneDesc),
          paste = paste, pasteGroup = gpu.createBindGroup(pasteDesc), lightValues = lightValues }

    def destroyTarget(t: SceneTarget): Unit \ IO =
        t#sceneGroup.release();
        t#pasteGroup.release();
        t#color.destroy();
        Option.forEach(m -> m.destroy(), t#msaa);
        t#depth.destroy();
        t#sceneValues.destroy();
        t#camera.destroy();
        t#paste.destroy();
        t#lightValues.destroy()

    def isColorPass(spec: ScenePassSpec): Bool = match spec {
        case ScenePassSpec.Color       => true
        case ScenePassSpec.DepthOut(_) => false
    }

    /// pass の種類の番号（pipeline の鍵）。
    def passCodeOf(spec: ScenePassSpec): Int32 = match spec {
        case ScenePassSpec.Color       => 0
        case ScenePassSpec.DepthOut(_) => 1
    }

    /// pass の種類の frag（色の pass は変種 variant の光の frag・奥行きの書き出しは灰色の frag）。変種の光の frag は初めて要る時に作る。
    def fragmentOf(r: Renderer, spec: ScenePassSpec, variant: ShaderVariant): ShaderModule \ IO =
        let RendererData.RendererData(s) = r;
        let key = variantKeyOf(variant);
        match spec {
            case ScenePassSpec.Color if key == "" => s#fragmentModule
            case ScenePassSpec.Color              => variantFragmentOf(r, variant, key)
            case ScenePassSpec.DepthOut(_) => s#depthModule
        }

    /// 変種 variant（鍵 key）の光の frag（初めて要る時に作って控える）。
    def variantFragmentOf(r: Renderer, variant: ShaderVariant, key: String): ShaderModule \ IO =
        let RendererData.RendererData(s) = r;
        match Map.get(key, Ref.get(s#variantFragments)) {
            case Some(m) => m
            case None    =>
                let made = s#gpu.createShaderModule("fge scene3d lit fs" + key, Render3dWgsl.litFragmentSourceFor(variant));
                Ref.put(Map.insert(key, made, Ref.get(s#variantFragments)), s#variantFragments);
                made
        }

    /// 頂点の色の pipeline の鍵（format = formatCode・pass = passCodeOf・stride = 頂点のバイト数・skinned = 骨つきか・variant = variantKeyOf）。
    type alias LitPipelineKey = { format = Int32, samples = Int32, pass = Int32, stride = Int32, skinned = Bool, variant = String }
    // WhyNot: レコードを Map の鍵に直に使わない — レコードは Order を持てない。並べ方は litPipelineSlotOf の 1 か所だけにして、呼ぶ側は欄の名前で書く。
    enum LitPipelineSlot with Eq, Order { case LitPipelineSlot(Int32, Int32, Int32, Int32, Bool, String) }
    def litPipelineSlotOf(k: LitPipelineKey): LitPipelineSlot = LitPipelineSlot.LitPipelineSlot(k#format, k#samples, k#pass, k#stride, k#skinned, k#variant)

    /// 形式 format・標本 samples・pass spec・頂点のバイト数 stride（Render3d.WebGpuRows の形の版）の頂点の色の pipeline（無ければ作る）。
    /// skin = 骨つきの版なら形の版のジョイントの番号の位置（バイト。group 1 は空・group 2 に姿勢）。表の面は時計回り（Render3d の頭の約束）で裏を間引き、深度は LESS で書く。variant = 場面の pass の変種（frag と group 0 の layout）。
    // WhyNot: 鍵にジョイントの番号の位置を入れない — 位置は形の版の末尾の 8 float（Render3d.WebGpuRows.floatsPerVertex）で、頂点のバイト数から 1 つに決まる。
    def pipelineOf(r: Renderer, format: RenderTarget.Format, samples: Int32, spec: ScenePassSpec, stride: Int32, skin: Option[Int32], variant: ShaderVariant): RenderPipeline \ IO =
        let RendererData.RendererData(s) = r;
        let key = litPipelineSlotOf({ format = WebGpuPipelines.formatCode(format), samples = samples, pass = passCodeOf(spec), stride = stride, skinned = Option.nonEmpty(skin), variant = variantKeyOf(variant) });
        match Map.get(key, Ref.get(s#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d lit");
                let vertexModule = if (Option.nonEmpty(skin)) s#skinnedModule else s#vertexModule;
                discard desc.bindGroupLayout(sceneLayoutOf(r, layoutCodeOf(variant))).vertex(vertexModule, "vs_main").fragment(fragmentOf(r, spec, variant), "fs_main");
                if (Option.nonEmpty(skin)) discard desc.bindGroupLayout(s#emptyLayout).bindGroupLayout(s#poseLayout) else ();
                discard desc.vertexBuffer(stride, false).attribute(VertexFormat.FLOAT32X3, 0, 0).attribute(VertexFormat.FLOAT32X3, 12, 1).attribute(VertexFormat.FLOAT32X3, 24, 2);
                skin |> Option.forEach(at -> discard desc.attribute(VertexFormat.FLOAT32X4, at, 14).attribute(VertexFormat.FLOAT32X4, at + 16, 15));
                discard desc.vertexBuffer(Render3dWgsl.instanceBytes(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 3).attribute(VertexFormat.FLOAT32X4, 16, 4);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 5).attribute(VertexFormat.FLOAT32X4, 48, 6);
                discard desc.attribute(VertexFormat.FLOAT32X4, 64, 7).attribute(VertexFormat.FLOAT32X4, 80, 8);
                discard desc.attribute(VertexFormat.FLOAT32X4, 96, 9).attribute(VertexFormat.FLOAT32X4, 112, 10);
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.BACK);
                discard desc.depthStencil(sceneDepthFormat(), true, CompareFunction.LESS).multisample(samples);
                let made = s#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(s#pipelines)), s#pipelines);
                made
        }
}
