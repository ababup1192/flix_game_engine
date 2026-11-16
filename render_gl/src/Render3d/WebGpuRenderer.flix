// Render3d.WebGpuRenderer — 3D の場面を WebGPU で描く所（WebGPU の backend の 3D の分）。2D の描き手（RenderPaint.Internal.WebGpuPaint）が 1 つ持つ。
// 1 回の renderCommands で、2D の pass を開く前に prepare が場面ごとに自分の texture（色と深度。標本つきなら resolve まで）へ描き、
// 2D の並びの z の位置で 2D の描き手がその texture を貼る（plans/engine-webgpu.md の 5.4）。計画（Render3d.ScenePlan）と行（Render3d.SceneList）は GL と同じ物を使い、
// 行を流すのは Render3d.WebGpuRows。式は GL と同じ WGSL（Render3dWgsl の頂点の色の頂点シェーダーと frag）。
// 描くのは不透明の頂点の色の物と光（点光源・スポット・太陽・環境光・hemisphere・かすみ）と、奥行きの書き出し（Output.Depth の場面の形の灰色）。
// 材質・骨つき・ビルボード・空・影・環境マップ・lightmap は描かずに種類ごとの回数を host へ数えさせる（材質の物は GL が「使えない」と答えた材質と同じく頂点の色か形で描く）。
// 場面は計画の pass（Render3d.ScenePlan.ScenePassSpec）ごとの行の列（Render3d.SceneList.ScenePasses）で描き、pass の種類で frag を替える。
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
    use Render3d.{LightData, MeshDraw, PixelBox, clipBox, matrixArray, sceneRect}
    use Render3d.Batch.{MeshBatch, SpanBatch}
    use Render3d.Instancing.{PackMode, numberSpan}
    use Render3d.Light.{lightDataOf}
    use Render3d.ScenePlan.{Group, GroupedScene, MaterialRequest, PlanCaps, Planner, ScenePassSpec, ScenePlan, freshPlanner, groupScenes, isSkinned, planScenes}
    use Render3d.SceneList.{SceneList, ScenePasses, buildScenePasses}
    use Render3d.WebGpuRows.{MeshTable, drawRows, freshMeshes, releaseMeshes, trimMeshes, uploadRows}
    use RenderPaint.Internal.WebGpuPipelines

    /// 場面 1 つの描き先と、その場面の値の buffer と bind group（2D の描き手の描き先の鍵とそのコマの場面の番号ごとに 1 つ・大きさか形式か標本が変われば作り直す）。
    /// color = 貼る時に読む 1 標本の texture・msaa = 標本つきの描き先（標本 1 なら None）・depth = 深度（DEPTH24_PLUS）・
    /// sceneValues = Render3dWgsl の R3dScene・camera = R3dCamera・sceneGroup = group 0・paste = 貼る矩形（WebGpuShader.sceneWgsl の Paste）・pasteGroup = 貼る形の group 1・
    /// lastUsed = 最後に描いたコマの世代（要素 1 つ）。
    type alias SceneTarget = {
        width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32,
        color = Texture, msaa = Option[Texture], depth = Texture,
        sceneValues = Buffer, camera = Buffer, sceneGroup = BindGroup, paste = Buffer, pasteGroup = BindGroup, lastUsed = Array[Int64, Static]
    }

    /// 2D の描き手から借りる物。encoder = 今のコマの encoder・notePass = encoder に pass を 1 つ積んだと知らせる・
    /// flush = 積んだ pass があれば submit する（submit したら afterSubmit が呼ばれる）・skip(種類, 回数) = 描かずに飛ばした物を種類ごとに数える。
    pub type alias Host = { encoder = Unit -> CommandEncoder \ IO, notePass = Unit -> Unit \ IO, flush = Unit -> Unit \ IO, skip = (String, Int32) -> Unit \ IO }

    /// 場面を描く描き先。key = 2D の描き手の描き先の鍵（画面は 0）・format・samples = 2D の pass の形式と標本（WebGPU の描き先の標本は 1 か 4）・
    /// viewport = 描き先の中の design 領域（GL の左下が原点）と倍率・height = 描き先の高さ（画素）。
    pub type alias Dest = { key = Int32, format = RenderTarget.Format, samples = Int32, viewport = Scene3dRenderer.Viewport, height = Int32 }

    /// 場面 1 つを貼る物。group = 貼る形の group 1・scissor = 貼る矩形 ∩ clip ∩ design 領域（描き先の左上が原点の x・y・幅・高さ）・
    /// key = 描き先の鍵（貼った時に notePasted へ渡す）。
    pub type alias Paste = { group = BindGroup, scissor = (Int32, Int32, Int32, Int32), key = (Int32, Int32) }

    /// prepare の答え（i 番目 = 番号 i の場面を貼る物。描く物の無い場面は None）。
    pub type alias Prepared = Vector[Option[Paste]]

    /// 描き手の状態。欄の中身:
    /// pipelines = (形式の番号, 標本の数, pass の番号（passCodeOf）) → 頂点の色の pipeline・depthModule = 奥行きの書き出しの frag・blankDepth と blankImage = 影の地図と環境マップの代わり（場面の値が影と環境マップを切っているので読まれない）・
    /// written = 今の encoder（submit まで）で値を書いたか、貼る pass を積んだ描き先の鍵・instances = 1 体ごとの値の buffer（頂点の buffer の 1 番）・
    /// instanceUsed = 今の encoder で使ったそのバイト数・cpuInstances・cpuScene・cpuCamera・cpuPaste・scratch = 毎回作らずに使い回す CPU の入れ物
    /// （cpuInstances は足りなければ倍に作り直す）・gen = 画面のコマの世代（endFrame で進む）。
    enum RendererData {
        case RendererData({
            gpu = WebGpu,
            planner = Planner,
            sceneLayout = BindGroupLayout,
            pasteLayout = BindGroupLayout,
            vertexModule = ShaderModule,
            fragmentModule = ShaderModule,
            depthModule = ShaderModule,
            pipelines = Ref[Map[(Int32, Int32, Int32), RenderPipeline], Static],
            blankDepth = Texture,
            blankImage = Texture,
            environmentSampler = Sampler,
            meshes = MeshTable,
            targets = Ref[Map[(Int32, Int32), SceneTarget], Static],
            written = Ref[Set[(Int32, Int32)], Static],
            instances = Array[Buffer, Static],
            instanceUsed = Array[Int32, Static],
            cpuInstances = Array[ByteBuffer, Static],
            cpuScene = ByteBuffer,
            cpuCamera = ByteBuffer,
            cpuPaste = ByteBuffer,
            scratch = Array[Float32, Static],
            gen = Array[Int64, Static]
        })
    }

    pub type alias Renderer = RendererData

    /// 1 体ごとの値の buffer の始めの大きさ（体の数）。
    def initialInstances(): Int32 = 1024

    /// この数の画面のコマ描かなかった場面の描き先は捨てる（GL の Render3d.idleTargetFrames と同じ）。
    def idleTargetFrames(): Int64 = 128i64

    /// device の上に shader module・layout・代わりの絵・1 体ごとの値の buffer を作る。pasteLayout = 貼る形の group 1（WebGpuPipelines の持ち物）。
    pub def create(gpu: WebGpu, pasteLayout: BindGroupLayout): Renderer \ IO =
        let layoutDesc = new BindGroupLayoutDesc("fge scene3d");
        discard layoutDesc.buffer(0, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        discard layoutDesc.texture(1, ShaderStage.FRAGMENT, TextureSampleType.DEPTH).texture(2, ShaderStage.FRAGMENT, TextureSampleType.DEPTH);
        discard layoutDesc.texture(3, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(4, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        discard layoutDesc.buffer(5, ShaderStage.VERTEX, BufferBindingType.UNIFORM);
        let blankImage = gpu.createTexture("fge scene3d blank", 1, 1, TextureFormat.RGBA8_UNORM,
                                           Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        gpu.writeTexture(blankImage, 0, 0, 0, 1, 1, ByteBuffer.allocateDirect(4), 0, 4);
        let r = RendererData.RendererData({
            gpu = gpu, planner = freshPlanner(Render3d.DrawMode.Instanced),
            sceneLayout = gpu.createBindGroupLayout(layoutDesc), pasteLayout = pasteLayout,
            vertexModule = gpu.createShaderModule("fge scene3d lit vs", Render3dWgsl.litVertexSource()),
            fragmentModule = gpu.createShaderModule("fge scene3d lit fs", Render3dWgsl.litFragmentSource()),
            depthModule = gpu.createShaderModule("fge scene3d depth fs", Render3dWgsl.depthFragmentSource()),
            pipelines = Ref.fresh(Static, Map.empty()),
            blankDepth = gpu.createTexture("fge scene3d blank depth", 1, 1, TextureFormat.DEPTH32_FLOAT, TextureUsage.TEXTURE_BINDING, 1, 1),
            blankImage = blankImage,
            environmentSampler = gpu.createSampler("fge scene3d environment", FilterMode.LINEAR, FilterMode.LINEAR, AddressMode.REPEAT),
            meshes = freshMeshes(), targets = Ref.fresh(Static, Map.empty()), written = Ref.fresh(Static, Set.empty()),
            instances = Array#{createInstanceBuffer(gpu, initialInstances() * Render3dWgsl.instanceBytes())} @ Static,
            instanceUsed = Array#{0} @ Static,
            cpuInstances = Array#{directBytes(initialInstances() * Render3dWgsl.instanceBytes())} @ Static,
            cpuScene = directBytes(sceneValueBytes()), cpuCamera = directBytes(128), cpuPaste = directBytes(16),
            scratch = Array.repeat(Static, Render3dWgsl.instanceBytes() / 4, 0.0f32),
            gen = Array#{1i64} @ Static
        });
        // WhyNot: 画面（RGBA8・標本 1）の pipeline を初めて場面が出たコマで作らない — Dawn は pipeline を作り終えるまで待つので、そのコマが詰まる（WebGpuPipelines.buildStartupPipelines と同じ）。
        discard pipelineOf(r, RenderTarget.Format.Rgba8Unorm, 1, ScenePassSpec.Color);
        r

    def directBytes(bytes: Int32): ByteBuffer \ IO = ByteBuffer.allocateDirect(Int32.max(4, bytes)).order(ByteOrder.LITTLE_ENDIAN)

    def createInstanceBuffer(gpu: WebGpu, bytes: Int32): Buffer \ IO =
        gpu.createBuffer("fge scene3d instances", Int32.toInt64(bytes), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST))

    /// device の上に作った物を全部手放す（pasteLayout は持ち主が手放す）。この後 r は使えない。
    pub def release(r: Renderer): Unit \ IO =
        let RendererData.RendererData(s) = r;
        Map.forEach((_, t) -> destroyTarget(t), Ref.get(s#targets));
        Ref.put(Map.empty(), s#targets);
        Map.forEach((_, p) -> p.release(), Ref.get(s#pipelines));
        Ref.put(Map.empty(), s#pipelines);
        releaseMeshes(s#meshes);
        Array.get(0, s#instances).destroy();
        s#blankDepth.destroy();
        s#blankImage.destroy();
        s#environmentSampler.release();
        s#vertexModule.release();
        s#fragmentModule.release();
        s#depthModule.release();
        s#sceneLayout.release()

    /// 2D の描き手が encoder を submit した後に呼ぶ（1 体ごとの値の buffer と場面の値を頭から書き直せる）。
    pub def afterSubmit(r: Renderer): Unit \ IO =
        let RendererData.RendererData(s) = r;
        Array.put(0, 0, s#instanceUsed);
        Ref.put(Set.empty(), s#written)

    /// 2D の pass に paste を貼った時に呼ぶ（その描き先の値を、今の encoder の中で使い中と控える）。
    // WhyNot: prepare で書いた時の控えだけで済ませない — prepare から 2D の pass を積むまでの間に submit が入る（1 体ごとの値の buffer があふれる・
    //   2D の Stream を伸ばす）と控えが消え、同じ encoder で同じ描き先がもう一度来た時に、まだ submit していない pass の貼る矩形と場面の値を先回りして書き換える。
    //   貼るのは pass の中で、pass を閉じるまで submit は入らない。
    pub def notePasted(r: Renderer, paste: Paste): Unit \ IO = noteWritten(r, paste#key)

    /// 画面のコマを締めて submit した後に 1 回呼ぶ。頂点の上限を超えた形と、しばらく描かなかった場面の描き先を捨てて、世代を進める。
    pub def endFrame(r: Renderer): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let gen = Array.get(0, s#gen);
        Array.put(gen + 1i64, 0, s#gen);
        let targets = Ref.get(s#targets);
        let isIdle = (t: SceneTarget) -> Array.get(0, t#lastUsed) + idleTargetFrames() < gen;
        Map.forEach((_, t) -> if (isIdle(t)) destroyTarget(t) else (), targets);
        Ref.put(Map.filter(t -> not isIdle(t), targets), s#targets);
        let dropped = trimMeshes(s#meshes, gen);
        // WhyNot: 捨てる物が無いコマで知らせない — 今のコマで使う形だけで上限を超えていると、毎コマ同じ知らせが出る（GL の Render3d.trimToBudget と同じ）。
        if (dropped == 0) ()
        else Log.warn("scene3d: メッシュの置き場が頂点 ${Render3d.vertexBudget()} を超えたので、古い形を ${dropped} 個捨てた")

    // ── 1 回の renderCommands ──

    /// 積んだ順の場面 cmds を、それぞれの texture へ描いて貼る物を返す（2D の pass を開く前に呼ぶ）。
    pub def prepare(r: Renderer, host: Host, dest: Dest, cmds: List[Scene3d.RenderCmd]): Prepared \ IO =
        let RendererData.RendererData(s) = r;
        if (List.isEmpty(cmds)) Vector.empty()
        else {
            // WhyNot: 姿勢の行を配らない — 骨つきの物は描かない（P8）。
            let caps = { alphaToOne = false, poseRowLimit = 0 };
            let grouped = groupScenes(s#planner, caps, dest#samples, cmds);
            List.forEach(scene -> noteSkips(host, skipsOf(grouped#members, scene)), grouped#scenes);
            let (plans, _) = planScenes(s#planner, caps, Vector.map(_ -> 0, grouped#requests), grouped);
            plans |> List.mapWithIndex((i, plan) -> prepareScene(r, host, dest, grouped#members, i, plan)) |> List.toVector
        }

    /// 場面 1 つを描いて貼る物を返す（描かない場面・場面の矩形か scissor が空なら None）。
    def prepareScene(r: Renderer, host: Host, dest: Dest, members: MutList[MeshDraw, Static], index: Int32, plan: ScenePlan[SpanBatch]): Option[Paste] \ IO =
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
            drawInto(r, host, target, members, plan);
            writePaste(r, target, topLeftOf(dest#height, rect));
            noteWritten(r, (dest#key, index));
            Some({ group = target#pasteGroup, scissor = topLeftOf(dest#height, scissor), key = (dest#key, index) })
        }

    /// 場面 1 つのまだ描けない物の種類と回数（0 回の種類も並べる。数えるのは host#skip）。
    /// 物は計画が間引かなかった物（culled でない物・骨つきの物は Scene3d.isOutsideFrustum が間引かない）を 1 体 1 回だけ数える
    /// （骨つきの物は材質があっても骨つきの物・lightmap の物は材質の物の内数）。
    /// 影は影を落とす光の数・ビルボードは数・空と環境マップは場面の数。
    /// 奥行きの書き出しの場面は、形だけで書く物のうち材質の道で書くはずの物（cutout と両面。計画が半透明の物と、cutout でも両面でもない材質を外してある）と
    /// 骨つきの物とビルボードだけを数える（空は一番奥の白で塗り、影と環境マップは読まない）。
    def skipsOf(members: MutList[MeshDraw, Static], scene: GroupedScene): List[(String, Int32)] \ IO =
        let cmd = scene#cmd#scene;
        let t = List.foldLeft((acc, g) -> tallyGroup(members, g, g#batch#start, g#batch#start + g#batch#count, acc),
                              { opaque = 0, blended = 0, lightmapped = 0, skinned = 0 }, scene#groups);
        match scene#pass {
            case ScenePassSpec.DepthOut(_) =>
                ("3D の骨つきの物", t#skinned) :: ("3D の奥行きの書き出しの材質の物（cutout と両面を見ずに形で書く）", t#opaque) ::
                ("3D のビルボード", List.length(cmd#billboards)) :: Nil
            case ScenePassSpec.Color =>
                ("3D の骨つきの物", t#skinned) :: ("3D の材質の物（頂点の色で描く）", t#opaque) ::
                ("3D の半透明の材質の物（頂点の色で不透明に描く）", t#blended) :: ("3D の lightmap の物（今の光で描く）", t#lightmapped) ::
                ("3D の影（影を落とす光）", List.length(scene#shadowPlans)) :: ("3D のビルボード", List.length(cmd#billboards)) ::
                ("3D の空", Option.count(_ -> true, cmd#sky)) :: ("3D の環境マップ", Option.count(_ -> true, cmd#environmentMap)) :: Nil
        }

    /// skipsOf の物の数え。
    type alias Tally = { opaque = Int32, blended = Int32, lightmapped = Int32, skinned = Int32 }

    /// group の batch の members の i から end の前までを acc へ数える。
    def tallyGroup(members: MutList[MeshDraw, Static], g: Group, i: Int32, end: Int32, acc: Tally): Tally \ IO =
        if (i >= end) acc
        else tallyGroup(members, g, i + 1, end, tallyDraw(g#surface, MutList.get(i, members), acc))

    /// 物 d 1 つを acc へ数える（視錐台の外の物は数えない）。surface = d の group の材質。
    // WhyNot: 骨つきの物を材質の道（surface）で分けない — WebGPU は材質の順の番号を 0 で答えるので、材質つきの骨つきの物も計画では骨つきの batch へ入り、描かれずに消える。
    def tallyDraw(surface: Option[MaterialRequest], d: MeshDraw, acc: Tally): Tally =
        if (d#culled) acc
        else if (isSkinned(d)) { skinned = acc#skinned + 1 | acc }
        else match surface {
            case Some((fields, _)) =>
                let lit = { lightmapped = acc#lightmapped + (if (Option.isEmpty(Scene3d.lightmapOfFields(d#fields))) 0 else 1) | acc };
                if (fields#blend) { blended = lit#blended + 1 | lit } else { opaque = lit#opaque + 1 | lit }
            case None => acc
        }

    def noteSkips(host: Host, skips: List[(String, Int32)]): Unit \ IO =
        List.forEach(match (kind, n) -> host#skip(kind, n), skips)

    /// GL の左下が原点の画素の矩形を、描き先の左上が原点の (x, y, 幅, 高さ) にする。
    def topLeftOf(height: Int32, box: PixelBox): (Int32, Int32, Int32, Int32) =
        (box#x, height - box#y - box#height, box#width, box#height)

    /// 場面を target へ描く: 計画の pass ごとに、地の色（clearOf）と深度を消して行を描く pass を積む。
    // WhyNot: pass ごとに描き先を替えない — 今の pass（色と奥行きの書き出し）はどちらも場面の描き先へ書き、場面 1 つに 1 つ。描き先の違う影の地図の pass を足す時に替える。
    def drawInto(r: Renderer, host: Host, target: SceneTarget, members: MutList[MeshDraw, Static], plan: ScenePlan[SpanBatch]): Unit \ IO =
        let staged = stageScene(r, host, target, members, plan);
        let scene = plan#cmd#scene;
        let drawn = target#msaa |> Option.getWithDefault(target#color);
        let full = (0, 0, target#width, target#height);
        staged#passes |> List.forEach(match (spec, list, meshes) ->
            encodeScene(r, host, target, { spec = spec, list = list, meshes = meshes, instanceBase = staged#instanceBase },
                        { color = drawn.defaultView(), resolve = target#msaa |> Option.map(_ -> target#color.defaultView()),
                          clear = Some(clearOf(spec, scene)), depth = target#depth.defaultView(), viewport = full, scissor = full }))

    /// pass spec の地の色（GL の Render3d.drawScene の beginScene と drawSky と同じ）: 空の無い場面は background（無ければ透明）。
    /// 奥行きの書き出しは、空を塗る場面（Scene3d.drawnSkyOf）なら一番奥の白。
    def clearOf(spec: ScenePassSpec, scene: Scene3d.Scene3dCmd): (Float64, Float64, Float64, Float64) =
        let background = if (Option.isEmpty(scene#sky)) scene#environment#background else None;
        let ground = background |> Option.map(c -> (c#r, c#g, c#b, 1.0)) |> Option.getWithDefault((0.0, 0.0, 0.0, 0.0));
        match spec {
            case ScenePassSpec.DepthOut(_) if Option.nonEmpty(Scene3d.drawnSkyOf(scene)) => (1.0, 1.0, 1.0, 1.0)
            case _                                                                       => ground
        }

    /// 場面 1 つを描く前の仕事を済ませる: 1 体ごとの値を送り、pass ごとの行の形を上げ、場面の値を target の buffer へ書く。返すのは pass ごとの行と形と、1 体ごとの値の位置。
    def stageScene(r: Renderer, host: Host, target: SceneTarget, members: MutList[MeshDraw, Static], plan: ScenePlan[SpanBatch]): Staged \ IO =
        let RendererData.RendererData(s) = r;
        let (passes, instanceBase) = numberInstances(r, host, members, plan);
        let gen = Array.get(0, s#gen);
        let uploaded = passes |> List.map(match (spec, list) -> (spec, list, uploadRows(s#gpu, s#meshes, gen, list)));
        writeSceneValues(r, target, plan);
        { passes = uploaded, instanceBase = instanceBase }

    /// 行 list の形の置き場（Render3d.WebGpuRows.uploadRows の答え）。
    type alias Meshes = Array[Option[Render3d.WebGpuRows.MeshBuffers], Static]

    /// stageScene の答え。passes = 計画の pass ごとの (pass, 行, 形)。
    type alias Staged = { passes = List[(ScenePassSpec, SceneList, Meshes)], instanceBase = Int32 }

    /// encodeScene が描く pass 1 つ。
    type alias StagedPass = { spec = ScenePassSpec, list = SceneList, meshes = Meshes, instanceBase = Int32 }

    /// 場面を描く pass の描き先。color = 描く view・resolve = 標本つきの描き先なら resolve する先・clear = 消す色（None なら前の中身に描き足す）・
    /// depth = 深度の view（いつも 1 で消す）・viewport と scissor = 描き先の左上が原点の (x, y, 幅, 高さ)。
    type alias PassTarget = {
        color = TextureView, resolve = Option[TextureView], clear = Option[(Float64, Float64, Float64, Float64)],
        depth = TextureView, viewport = (Int32, Int32, Int32, Int32), scissor = (Int32, Int32, Int32, Int32)
    }

    /// 場面の pass 1 つの行を onto へ描く pass を積む（pipeline は target の形式と標本と pass の種類・場面の値は target の group 0）。
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
        pass.setPipeline(pipelineOf(r, target#format, target#samples, staged#spec));
        pass.setBindGroup(0, target#sceneGroup);
        let instances = Array.get(0, s#instances);
        pass.setVertexBuffer(1, instances, 0i64, instances.size());
        drawRows(pass, staged#list, staged#meshes, staged#instanceBase);
        pass.end()

    /// 場面の頂点の色の batch に 1 体ごとの値の番号を振って 1 体ごとの値の buffer へ送り、計画の pass ごとの行の列と、送った位置（体の番号）を返す。
    /// 骨つきの batch は描く物を 0 にする（形も上げない）。材質の batch は無い（prepare が材質を全部「使えない」と答える）。
    def numberInstances(r: Renderer, host: Host, members: MutList[MeshDraw, Static], plan: ScenePlan[SpanBatch]): (ScenePasses, Int32) \ IO =
        let RendererData.RendererData(s) = r;
        let draws = plan#draws;
        let total = List.sumWith(b -> b#count, draws#plain);
        let bytes = total * Render3dWgsl.instanceBytes();
        let raw = cpuInstancesFor(r, bytes);
        let out = raw.asFloatBuffer();
        let next = Array#{0} @ Static;
        let plain = List.map(numberSpan(out, s#scratch, Int32.maxValue(), next, members, PackMode.Lit), draws#plain);
        let unseen = (b: SpanBatch) -> ({ head = b#head, count = 0, first = 0 }: MeshBatch);
        let passes = buildScenePasses(plan#pass, { plain = plain, skinned = List.map(unseen, draws#skinned), opaque = Nil, blended = Nil });
        (passes, sendInstances(r, host, raw, bytes))

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
        let capacity = Int64.tryToInt32(Array.get(0, s#instances).size()) |> Option.getWithDefault(Int32.maxValue());
        if (Array.get(0, s#instanceUsed) + bytes > capacity) flushHost(r, host) else ();
        if (bytes > capacity) {
            Array.get(0, s#instances).destroy();
            Array.put(createInstanceBuffer(s#gpu, Int32.max(bytes, 2 * capacity)), 0, s#instances)
        } else ();
        let at = Array.get(0, s#instanceUsed);
        if (bytes > 0) s#gpu.writeBuffer(Array.get(0, s#instances), Int32.toInt64(at), data, 0, bytes) else ();
        Array.put(at + bytes, 0, s#instanceUsed);
        at / Render3dWgsl.instanceBytes()

    /// 積んだ pass を submit し、1 体ごとの値と場面の値を頭から書けるようにする（積んだ pass が無く submit しなかった時も、書いた物を読む pass が無いので頭から書いてよい）。
    def flushHost(r: Renderer, host: Host): Unit \ IO =
        host#flush();
        afterSubmit(r)

    // ── 場面の値 ──

    /// R3dScene のバイト数（Render3dWgsl.sceneDeclarations の並び: 頭の 400 バイトの後に光の vec4 の配列が点光源 3 本・スポット 5 本）。
    pub def sceneValueBytes(): Int32 = 400 + 16 * (3 * Scene3d.maxPointLights() + 5 * Scene3d.maxSpotLights())

    /// 場面の値（光・かすみ・目・奥行きの書き出し）と目と射影の行列を target の buffer へ書く。影・環境マップ・lightmap は切る。
    def writeSceneValues(r: Renderer, target: SceneTarget, plan: ScenePlan[SpanBatch]): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let scene = plan#cmd#scene;
        let picked = Scene3d.pickLights(scene#camera#eye, scene);
        let values = s#cpuScene;
        packSceneValues(values, lightDataOf(picked, 0));
        packPassValues(values, plan#pass);
        s#gpu.writeBuffer(target#sceneValues, 0i64, values, 0, sceneValueBytes());
        let camera = s#cpuCamera;
        let floats = camera.asFloatBuffer();
        discard floats.put(matrixArray(Camera3d.viewMatrix(scene#camera)));
        discard floats.put(matrixArray(Camera3d.projectionMatrix(scene#camera, Scene3d.aspectOf(scene))));
        s#gpu.writeBuffer(target#camera, 0i64, camera, 0, 128)

    /// 光の値 d を R3dScene の並びで buf へ詰める（欄の位置は Render3dWgsl.sceneDeclarations の頭のコメント）。影・環境マップ・lightmap の欄は切る値（奥行きの書き出しの欄は packPassValues）。
    /// GL の Render3d.Light.putLights が渡す欄と同じ値を、同じ名前の欄へ入れる。
    // WhyNot: 書く欄の組を場面ごとに変えない — buf は場面をまたいで使い回すので、ある場面だけ書いた欄には次の場面で前の値が残る。
    //   ここで書く欄は毎回すべて書き、書かない欄（影の on など）は作った時の 0 のまま読ませる。
    pub def packSceneValues(buf: ByteBuffer, d: LightData): Unit \ IO =
        putVec3(buf, 0, d#ambient, 0);
        discard buf.putFloat(12, d#hemisphere);
        putVec3(buf, 16, d#eye, 0);
        discard buf.putInt(28, d#toonSteps);
        putVec3(buf, 32, d#fogColor, 0);
        discard buf.putInt(44, d#fogOn);
        discard buf.putFloat(48, Array.get(0, d#fogRange));
        discard buf.putFloat(52, Array.get(1, d#fogRange));
        discard buf.putInt(56, d#pointCount);
        discard buf.putInt(60, d#spotCount);
        putVec3(buf, 64, d#sunDir, 0);
        putVec3(buf, 80, d#sunColor, 0);
        // WhyNot: 太陽の影の fade の幅を 0 のままにしない — 影を切っていて読まれないが、0 で割る式を残さない。
        discard buf.putFloat(116, 1.0f32);
        putVec3(buf, 128, d#reflectZenith, 0);
        discard buf.putFloat(140, d#reflectCurve);
        putVec3(buf, 144, d#reflectHorizon, 0);
        putVec3(buf, 160, d#reflectGround, 0);
        discard buf.putFloat(188, d#envLevels);
        discard buf.putFloat(204, d#envIntensity);
        discard buf.putInt(232, -1);
        discard buf.putFloat(256, 1.0f32);
        let p = Scene3d.maxPointLights();
        let sp = Scene3d.maxSpotLights();
        let arrays = 400;
        putVec3Array(buf, arrays, d#pointPos, p);
        putVec3Array(buf, arrays + 16 * p, d#pointColor, p);
        putScalarArray(buf, arrays + 32 * p, d#pointRange, 1, p);
        let spots = arrays + 48 * p;
        putVec3Array(buf, spots, d#spotPos, sp);
        putVec3Array(buf, spots + 16 * sp, d#spotDir, sp);
        putVec3Array(buf, spots + 32 * sp, d#spotColor, sp);
        putScalarArray(buf, spots + 48 * sp, d#spotRange, 1, sp);
        putScalarArray(buf, spots + 64 * sp, d#spotCone, 2, sp)

    /// pass spec の奥行きの書き出しの欄を R3dScene の並びで buf へ詰める: uDepthRange（224・228。GL の Render3d.putDepthRange と同じく幅は 0 にしない）と uDepthOut（248）。
    /// 色の pass では uDepthOut が 0 で、uDepthRange は読まれない（0 で割る式を残さないよう幅は 1）。
    pub def packPassValues(buf: ByteBuffer, spec: ScenePassSpec): Unit \ IO =
        let (near, range, on) = match spec {
            case ScenePassSpec.Color        => (0.0, 1.0, 0)
            case ScenePassSpec.DepthOut(dr) => (dr#near, Float64.max(0.000001, dr#range), 1)
        };
        discard buf.putFloat(224, RenderUtil.f32(near));
        discard buf.putFloat(228, RenderUtil.f32(range));
        discard buf.putInt(248, on)

    /// values の i 番目の vec3（3 個ずつ）を buf の at へ。
    def putVec3(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], i: Int32): Unit \ IO =
        discard buf.putFloat(at, Array.get(3 * i, values));
        discard buf.putFloat(at + 4, Array.get(3 * i + 1, values));
        discard buf.putFloat(at + 8, Array.get(3 * i + 2, values))

    /// 3 個ずつの values の count 本を、16 バイト刻みの vec4 の配列として at から。
    def putVec3Array(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], count: Int32): Unit \ IO =
        List.range(0, count) |> List.forEach(i -> putVec3(buf, at + 16 * i, values, i))

    /// width 個ずつの values の count 本を、16 バイト刻みの vec4 の頭の width 個として at から。
    def putScalarArray(buf: ByteBuffer, at: Int32, values: Array[Float32, Static], width: Int32, count: Int32): Unit \ IO =
        List.range(0, count * width) |> List.forEach(k -> discard buf.putFloat(at + 16 * (k / width) + 4 * Int32.remainder(k, width), Array.get(k, values)))

    /// 貼る矩形 rect（描き先の左上が原点）を target の Paste へ書く: 左上と、texture の画素 ÷ 矩形の画素。
    def writePaste(r: Renderer, target: SceneTarget, rect: (Int32, Int32, Int32, Int32)): Unit \ IO =
        let RendererData.RendererData(s) = r;
        let (x, y, w, h) = rect;
        let data = s#cpuPaste;
        discard data.putFloat(0, Int32.toFloat32(x)).putFloat(4, Int32.toFloat32(y));
        discard data.putFloat(8, RenderUtil.f32(Int32.toFloat64(target#width) / Int32.toFloat64(Int32.max(1, w))));
        discard data.putFloat(12, RenderUtil.f32(Int32.toFloat64(target#height) / Int32.toFloat64(Int32.max(1, h))));
        s#gpu.writeBuffer(target#paste, 0i64, data, 0, 16)

    // ── 描き先と pipeline ──

    /// 鍵 key の描き先の値（場面の値・目・貼る矩形）を今の encoder で書いたと控える。
    // WhyNot: targetOf の頭で控えない — 値を書く途中で 1 体ごとの値の buffer があふれて submit すると控えが消え、
    //   同じ encoder で同じ鍵を 2 回目に書く時に、まだ submit していない 2D の pass の貼る矩形を上書きする。
    def noteWritten(r: Renderer, key: (Int32, Int32)): Unit \ IO =
        let RendererData.RendererData(s) = r;
        Ref.put(Set.insert(key, Ref.get(s#written)), s#written)

    /// 鍵 key の描き先（今の encoder で既に値を書いた鍵なら先に submit する）。大きさ・形式・標本が違えば作り直す。lastUsed を今の世代にする。
    /// 値を書き終えたら noteWritten で控える。
    def targetOf(r: Renderer, host: Host, key: (Int32, Int32), shape: { width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32 }): SceneTarget \ IO =
        let RendererData.RendererData(s) = r;
        if (Set.memberOf(key, Ref.get(s#written))) flushHost(r, host) else ();
        let found = Map.get(key, Ref.get(s#targets));
        let same = (t: SceneTarget) -> t#width == shape#width and t#height == shape#height and t#format == shape#format and t#samples == shape#samples;
        let target = match found {
            case Some(t) if same(t) => t
            case _ =>
                Option.forEach(destroyTarget, found);
                let made = createTarget(r, shape);
                Ref.put(Map.insert(key, made, Ref.get(s#targets)), s#targets);
                made
        };
        Array.put(Array.get(0, s#gen), 0, target#lastUsed);
        target

    def createTarget(r: Renderer, shape: { width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32 }): SceneTarget \ IO =
        let RendererData.RendererData(s) = r;
        let gpu = s#gpu;
        let format = WebGpuPipelines.textureFormatOf(shape#format);
        let color = gpu.createTexture("fge scene3d color", shape#width, shape#height, format,
                                      Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.TEXTURE_BINDING), 1, 1);
        let msaa = if (shape#samples > 1) Some(gpu.createTexture("fge scene3d msaa", shape#width, shape#height, format, TextureUsage.RENDER_ATTACHMENT, 1, shape#samples))
                   else None;
        let depth = gpu.createTexture("fge scene3d depth", shape#width, shape#height, TextureFormat.DEPTH24_PLUS, TextureUsage.RENDER_ATTACHMENT, 1, shape#samples);
        let uniformUsage = Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST);
        let sceneValues = gpu.createBuffer("fge scene3d values", Int32.toInt64(sceneValueBytes()), uniformUsage);
        let camera = gpu.createBuffer("fge scene3d camera", 128i64, uniformUsage);
        let paste = gpu.createBuffer("fge scene3d paste", 16i64, uniformUsage);
        let sceneDesc = new BindGroupDesc("fge scene3d", s#sceneLayout);
        discard sceneDesc.buffer(0, sceneValues, 0i64, Int32.toInt64(sceneValueBytes()));
        discard sceneDesc.textureView(1, s#blankDepth.defaultView()).textureView(2, s#blankDepth.defaultView());
        discard sceneDesc.textureView(3, s#blankImage.defaultView()).sampler(4, s#environmentSampler).buffer(5, camera, 0i64, 128i64);
        let pasteDesc = new BindGroupDesc("fge scene3d paste", s#pasteLayout);
        discard pasteDesc.textureView(0, color.defaultView()).buffer(1, paste, 0i64, 16i64);
        { width = shape#width, height = shape#height, format = shape#format, samples = shape#samples, color = color, msaa = msaa, depth = depth,
          sceneValues = sceneValues, camera = camera, sceneGroup = gpu.createBindGroup(sceneDesc),
          paste = paste, pasteGroup = gpu.createBindGroup(pasteDesc), lastUsed = Array#{0i64} @ Static }

    def destroyTarget(t: SceneTarget): Unit \ IO =
        t#sceneGroup.release();
        t#pasteGroup.release();
        t#color.destroy();
        Option.forEach(m -> m.destroy(), t#msaa);
        t#depth.destroy();
        t#sceneValues.destroy();
        t#camera.destroy();
        t#paste.destroy()

    /// pass の種類の番号（pipeline の鍵）。
    def passCodeOf(spec: ScenePassSpec): Int32 = match spec {
        case ScenePassSpec.Color       => 0
        case ScenePassSpec.DepthOut(_) => 1
    }

    /// pass の種類の frag（色の pass は光の frag・奥行きの書き出しは灰色の frag）。
    def fragmentOf(r: Renderer, spec: ScenePassSpec): ShaderModule =
        let RendererData.RendererData(s) = r;
        match spec {
            case ScenePassSpec.Color       => s#fragmentModule
            case ScenePassSpec.DepthOut(_) => s#depthModule
        }

    /// 形式 format・標本 samples・pass spec の頂点の色の pipeline（無ければ作る）。表の面は時計回り（Render3d の頭の約束）で裏を間引き、深度は LESS で書く。
    def pipelineOf(r: Renderer, format: RenderTarget.Format, samples: Int32, spec: ScenePassSpec): RenderPipeline \ IO =
        let RendererData.RendererData(s) = r;
        let key = (WebGpuPipelines.formatCode(format), samples, passCodeOf(spec));
        match Map.get(key, Ref.get(s#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d lit");
                discard desc.bindGroupLayout(s#sceneLayout).vertex(s#vertexModule, "vs_main").fragment(fragmentOf(r, spec), "fs_main");
                discard desc.vertexBuffer(36, false).attribute(VertexFormat.FLOAT32X3, 0, 0).attribute(VertexFormat.FLOAT32X3, 12, 1).attribute(VertexFormat.FLOAT32X3, 24, 2);
                discard desc.vertexBuffer(Render3dWgsl.instanceBytes(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 3).attribute(VertexFormat.FLOAT32X4, 16, 4);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 5).attribute(VertexFormat.FLOAT32X4, 48, 6);
                discard desc.attribute(VertexFormat.FLOAT32X4, 64, 7).attribute(VertexFormat.FLOAT32X4, 80, 8);
                discard desc.attribute(VertexFormat.FLOAT32X4, 96, 9).attribute(VertexFormat.FLOAT32X4, 112, 10);
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(format));
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.BACK);
                discard desc.depthStencil(TextureFormat.DEPTH24_PLUS, true, CompareFunction.LESS).multisample(samples);
                let made = s#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(s#pipelines)), s#pipelines);
                made
        }
}
