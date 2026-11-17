// Render3d.WebGpuShadows — 3D の影の地図の WebGPU の backend（GL の Render3d.Shadow と対）。鍵 → 描き先（深度の texture と光の目の値）を持ち、影の地図の pass を積む。
// どの描き先へ何を描くかと描き先の寿命は前半の Render3d.ShadowMaps が決める。行は Render3d.WebGpuRows.drawRows で流し、頂点シェーダーは頂点の色の物と同じ（Render3dWgsl.litVertexSource）。
// bind group: 0 = 光の目と射影（R3dCamera と同じ並び・binding 5）・1 = 空（骨つきの版で group 2 の前を埋める）・2 = 姿勢（色の pass と同じ group）。
// WhyNot: 光の目の値を場面の値の buffer に混ぜない — writeBuffer は encoder の pass より先に効き、1 つの encoder の中の影の pass と色の pass が最後に書いた値を読む。描き先ごとに持つ。
mod Render3d.WebGpuShadows {
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
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderCommands
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureUsage
    import fge.webgpu.TextureView
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    use Render3d.{matrixArray}
    use Render3d.SceneList.{SceneList}
    use Render3d.ShadowMaps.{Key, ShadowPass}
    use Render3d.WebGpuRows.{MeshBuffers, MeshStore, drawRows}

    /// 影の地図の描き先 1 枚。depth = 深度の texture（色の pass が texture_depth_2d で読む）・camera = 光の目と単位行列の射影とビルボードの板の横と縦（Render3dWgsl.cameraBytes() の並び・uFacing は読まない）・group = group 0。
    type alias ShadowTarget = { depth = Texture, camera = Buffer, group = BindGroup }

    /// 影の地図の backend の状態。table = 前半の寿命の表・targets = 鍵 → 描き先・layout = group 0 の layout・pipelines = (頂点のバイト数, ジョイントの番号の位置) → pipeline・
    /// written = 今の encoder（submit まで）で描いた描き先の鍵・cpuCamera = 光の目の値を詰める入れ物。
    pub type alias Shadows = {
        gpu = WebGpu, table = Render3d.ShadowMaps.Table, targets = Ref[Map[Key, ShadowTarget], Static], layout = BindGroupLayout,
        pipelines = Ref[Map[(Int32, Option[Int32]), RenderPipeline], Static], written = Ref[Set[Key], Static], cpuCamera = ByteBuffer
    }

    /// 影の地図の pass を積む材料（どれも 3D の描き手 Render3d.WebGpuRenderer の持ち物）。encoder と notePass = 2D の描き手から借りる encoder と、pass を積んだ知らせ・
    /// meshStore = 形の置き場・instances = 1 体ごとの値の buffer・instanceBase = この場面の 1 体ごとの値を送った位置（体の番号）・poseGroup = 姿勢の group 2・
    /// vertexModule と skinnedModule = 頂点の色の頂点シェーダー（骨の無い版と骨つきの版）・emptyLayout と emptyGroup = 空の group 1・poseLayout = group 2 の layout・
    /// created = 描き先を作った知らせ（診断の数）・unbound = 付けられずに飛ばした行の物の数の知らせ・
    /// carried = 場面の持ち越した集まりの影の地図の行を流す関数（pass, 地図の鍵の字, 地図の group 0, 行を積む関数 (積み先, 行, 1 体ごとの値の buffer)）（Render3d.WebGpuStatic.shadowRunnerOf）。
    pub type alias ShadowDraw = {
        encoder = CommandEncoder, notePass = Unit -> Unit \ IO, meshStore = MeshStore, instances = Buffer, instanceBase = Int32, poseGroup = Option[BindGroup],
        vertexModule = ShaderModule, skinnedModule = ShaderModule, emptyLayout = BindGroupLayout, emptyGroup = BindGroup, poseLayout = BindGroupLayout,
        created = Unit -> Unit \ IO, unbound = Int32 -> Unit \ IO,
        carried = List[(RenderPass, String, BindGroup, (RenderCommands, SceneList, Buffer) -> Unit \ IO) -> Unit \ IO],
        billboard = (RenderCommands, SceneList, Int32, Int32) -> Bool \ IO
    }

    /// 影の地図の pass 1 つと、その行の values を送った位置（バイト。ビルボードの行の無い pass は -1）。
    pub type alias StagedShadow = { pass = ShadowPass, valuesBase = Int32 }

    /// 描き先の深度の形式（色の pass の group 0 の binding 1・2 で読む）。
    // WhyNot: DEPTH24_PLUS にしない — 機種ごとに中身の形式が決まらず、比べる値（ndc.z × 0.5 + 0.5 − bias）との丸めが機種で変わる。GL の 24 bit との違いは比べの最後の bit だけ。
    pub def depthFormat(): TextureFormat = TextureFormat.DEPTH32_FLOAT

    pub def create(gpu: WebGpu): Shadows \ IO =
        let layoutDesc = new BindGroupLayoutDesc("fge scene3d shadow camera");
        discard layoutDesc.buffer(5, ShaderStage.VERTEX, BufferBindingType.UNIFORM);
        { gpu = gpu, table = Render3d.ShadowMaps.fresh(), targets = Ref.fresh(Static, Map.empty()), layout = gpu.createBindGroupLayout(layoutDesc),
          pipelines = Ref.fresh(Static, Map.empty()), written = Ref.fresh(Static, Set.empty()),
          cpuCamera = ByteBuffer.allocateDirect(Render3dWgsl.cameraBytes()).order(ByteOrder.LITTLE_ENDIAN) }

    /// device の上に作った物を全部手放す。この後 sh は使えない。
    pub def release(sh: Shadows): Unit \ IO =
        Render3d.ShadowMaps.release(sh#table, allocatorOf(sh, () -> checked_ecast(())));
        Map.forEach((_, p) -> p.release(), Ref.get(sh#pipelines));
        Ref.put(Map.empty(), sh#pipelines);
        sh#layout.release()

    /// group 0（光の目）の layout（ビルボードの影の地図の pipeline も同じ layout で作る）。
    pub def layoutOf(sh: Shadows): BindGroupLayout = sh#layout

    /// encoder を submit した後に呼ぶ（どの描き先の光の目の値も書き直せる）。
    pub def afterSubmit(sh: Shadows): Unit \ IO = Ref.put(Set.empty(), sh#written)

    /// passes のどれかの描き先を今の encoder で描いてあるか（描き直す前に submit が要る）。
    // WhyNot: 同じ encoder の 2 回目の prepare の地図を、前の地図を読む色の pass の後に積んで済ませない — 地図の中身は pass の順に描き替わるが、
    //   光の目の値（writeBuffer）は encoder の全部の pass より先に効き、前の prepare の影の pass が後の prepare の目で描く。
    pub def needsFlush(sh: Shadows, passes: List[ShadowPass]): Bool \ IO =
        let written = Ref.get(sh#written);
        List.exists(p -> Set.memberOf(p#map#key, written), passes)

    /// 使わなくなった描き先を捨て、捨てた数を返す（画面のコマを submit した後に 1 回）。
    pub def endFrame(sh: Shadows, gen: Int64): Int32 \ IO = Render3d.ShadowMaps.sweep(sh#table, allocatorOf(sh, () -> checked_ecast(())), gen)

    /// 鍵 key の描き先の深度の view（作っていなければ None）。
    pub def viewOf(sh: Shadows, key: Key): Option[TextureView] \ IO = Map.get(key, Ref.get(sh#targets)) |> Option.map(t -> t#depth.defaultView())

    def allocatorOf(sh: Shadows, created: Unit -> Unit \ IO): Render3d.ShadowMaps.Allocator =
        { create = key -> {
              created();
              Ref.put(Map.insert(key, createTarget(sh, fst(Render3d.ShadowMaps.extentOf(key))), Ref.get(sh#targets)), sh#targets)
          },
          destroy = key -> {
              Map.get(key, Ref.get(sh#targets)) |> Option.forEach(destroyTarget);
              Ref.put(Map.remove(key, Ref.get(sh#targets)), sh#targets)
          } }

    def createTarget(sh: Shadows, size: Int32): ShadowTarget \ IO =
        let gpu = sh#gpu;
        let depth = gpu.createTexture("fge scene3d shadow map", size, size, depthFormat(), Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.TEXTURE_BINDING), 1, 1);
        let camera = gpu.createBuffer("fge scene3d shadow camera", Int32.toInt64(Render3dWgsl.cameraBytes()), Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST));
        let desc = new BindGroupDesc("fge scene3d shadow camera", sh#layout);
        discard desc.buffer(5, camera, 0i64, Int32.toInt64(Render3dWgsl.cameraBytes()));
        { depth = depth, camera = camera, group = gpu.createBindGroup(desc) }

    def destroyTarget(t: ShadowTarget): Unit \ IO =
        t#group.release();
        t#camera.destroy();
        t#depth.destroy()

    /// 影の地図の pass 1 つを積む: 描き先を（無ければ作って）光の目の値を書き、深度を 1 で消して行を形だけで描く。呼ぶ前に needsFlush で submit を済ませておく。
    /// 骨つきの行は姿勢の group 2 がある時だけ描く。裏の面も描く（GL の Render3d.Shadow と同じ）。ビルボードの行は draw#billboard が描く（values は staged#valuesBase から）。
    pub def encode(sh: Shadows, gen: Int64, draw: ShadowDraw, staged: StagedShadow): Unit \ IO =
        let pass = staged#pass;
        let key = pass#map#key;
        discard Render3d.ShadowMaps.ensure(sh#table, allocatorOf(sh, draw#created), gen, key);
        Map.get(key, Ref.get(sh#targets)) |> Option.forEach(target -> {
            writeCamera(sh, target, pass);
            Ref.put(Set.insert(key, Ref.get(sh#written)), sh#written);
            let size = fst(Render3d.ShadowMaps.extentOf(key));
            let desc = new RenderPassDesc("fge scene3d shadow map");
            discard desc.clearDepth(target#depth.defaultView(), 1.0);
            let rp = draw#encoder.beginRenderPass(desc);
            draw#notePass();
            rp.setViewport(0.0, 0.0, Int32.toFloat64(size), Int32.toFloat64(size), 0.0, 1.0);
            rp.setScissorRect(0, 0, size, size);
            rp.setBindGroup(0, target#group);
            Option.forEach(g -> rp.setBindGroup(2, g), draw#poseGroup);
            rp.setVertexBuffer(1, draw#instances, 0i64, draw#instances.size());
            drawRows(checked_cast(rp), draw#meshStore, drawerOf(sh, draw, staged#valuesBase), pass#list, draw#instanceBase);
            let drawCarried = (commands: RenderCommands, list: SceneList, instances: Buffer) -> {
                commands.setVertexBuffer(1, instances, 0i64, instances.size());
                drawRows(commands, draw#meshStore, drawerOf(sh, draw, -1), list, 0)
            };
            draw#carried |> List.forEach(runCarried -> runCarried(rp, ToString.toString(key), target#group, drawCarried));
            rp.end()
        })

    /// 影の地図の行を形だけで描く時に pipeline を付ける関数の組（付けた pipeline の控えは組ごと・bundle は付けた物を持たずに始まる）。
    /// valuesBase = 行の values を送った位置（ビルボードの行の無い列は -1）。ビルボードの行は draw#billboard が付けて描き、次の形の行が pipeline を付け直す。
    def drawerOf(sh: Shadows, draw: ShadowDraw, valuesBase: Int32): Render3d.WebGpuRows.RowDrawer \ IO =
        let bound = Ref.fresh(Static, (-1, (None: Option[Int32])));
        let bindShape = (p: RenderCommands, mesh: MeshBuffers, skin: Option[Int32]) -> {
            let k = (mesh#stride, skin);
            if (Ref.get(bound) == k) () else {
                p.setPipeline(pipelineOf(sh, draw, mesh#stride, skin));
                if (Option.nonEmpty(skin)) p.setBindGroup(1, draw#emptyGroup) else ();
                Ref.put(k, bound)
            };
            true
        };
        { shape = (p, mesh) -> bindShape(p, mesh, None),
          skinned = (p, mesh) -> Option.nonEmpty(draw#poseGroup) and Option.nonEmpty(mesh#skinAt) and bindShape(p, mesh, mesh#skinAt),
          material = (_, _, _, _) -> checked_ecast(false),
          billboard = (p, list, row) -> {
              Ref.put((-1, None), bound);
              valuesBase >= 0 and (draw#billboard)(p, list, row, valuesBase)
          },
          unbound = draw#unbound }

    /// 光の目（world → 光の clip）と単位行列の射影と、ビルボードの板の横（pass#billboardRight）と縦（world の上）を、R3dCamera の並び（uView・uProj・uRight・uUp）で
    /// target の buffer へ書く（uFacing は読まない）。
    def writeCamera(sh: Shadows, target: ShadowTarget, pass: ShadowPass): Unit \ IO =
        let floats = sh#cpuCamera.asFloatBuffer();
        let r = pass#billboardRight;
        discard floats.put(matrixArray(pass#map#view));
        discard floats.put(matrixArray(Mat4.identity()));
        discard floats.put(Array#{RenderUtil.f32(r#x), RenderUtil.f32(r#y), RenderUtil.f32(r#z), 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32,
                                  0.0f32, 0.0f32, 0.0f32, 0.0f32} @ Static);
        sh#gpu.writeBuffer(target#camera, 0i64, sh#cpuCamera, 0, Render3dWgsl.cameraBytes())

    /// 頂点のバイト数 stride（Render3d.WebGpuRows の形の版）・ジョイントの番号の位置 skin の、深度だけを書く pipeline（無ければ作る）。
    // WhyNot: frag を付けない — 描き先は深度だけで、色を書く段は捨てられる（GL は色の描き先の無い FBO で同じ事をする）。
    def pipelineOf(sh: Shadows, draw: ShadowDraw, stride: Int32, skin: Option[Int32]): RenderPipeline \ IO =
        let key = (stride, skin);
        match Map.get(key, Ref.get(sh#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge scene3d shadow map");
                let module = if (Option.nonEmpty(skin)) draw#skinnedModule else draw#vertexModule;
                discard desc.bindGroupLayout(sh#layout).vertex(module, "vs_main");
                if (Option.nonEmpty(skin)) discard desc.bindGroupLayout(draw#emptyLayout).bindGroupLayout(draw#poseLayout) else ();
                discard desc.vertexBuffer(stride, false).attribute(VertexFormat.FLOAT32X3, 0, 0).attribute(VertexFormat.FLOAT32X3, 12, 1).attribute(VertexFormat.FLOAT32X3, 24, 2);
                skin |> Option.forEach(at -> discard desc.attribute(VertexFormat.FLOAT32X4, at, 14).attribute(VertexFormat.FLOAT32X4, at + 16, 15));
                discard desc.vertexBuffer(Render3dWgsl.instanceBytes(), true);
                discard desc.attribute(VertexFormat.FLOAT32X4, 0, 3).attribute(VertexFormat.FLOAT32X4, 16, 4);
                discard desc.attribute(VertexFormat.FLOAT32X4, 32, 5).attribute(VertexFormat.FLOAT32X4, 48, 6);
                discard desc.attribute(VertexFormat.FLOAT32X4, 64, 7).attribute(VertexFormat.FLOAT32X4, 80, 8);
                discard desc.attribute(VertexFormat.FLOAT32X4, 96, 9).attribute(VertexFormat.FLOAT32X4, 112, 10);
                // WhyNot: 裏の面を間引かない — 厚みの無い板を裏から照らすと面が全部捨てられ、影が抜ける（GL の Render3d.Shadow と同じ）。
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                discard desc.depthStencil(depthFormat(), true, CompareFunction.LESS).multisample(1);
                let made = sh#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(sh#pipelines)), sh#pipelines);
                made
        }
}
