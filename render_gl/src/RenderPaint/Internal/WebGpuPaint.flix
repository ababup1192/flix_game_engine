// RenderPaint.Internal.WebGpuPaint — 塗りのコア（RenderPaint と RenderPaintHandlers）の WebGPU の分。2D のスプライト・字・箱（mask つきを含む）・多角形・タイルの層・面・
// static layer と、絵とフォントのアトラスを上げる・Pass を 1 つ挟む・中間の texture から画面へ写す、だけを持つ。
// コマは中間の texture（RGBA8・描き先の画素の大きさ）へ描き、present で画面の texture へ 1 回写す。encoder はコマに 1 つで、submit はコマの終わり。
// ただし、そのコマに積んだ pass があるうちに絵や頂点の buffer を作る・書き替える・捨てる・Pass の texture を作り直す・instance などの buffer を伸ばす時は、
// 先に submit する（そのままだと、前に積んだ pass が新しい絵で描かれ、捨てた物を指したまま submit することになる）。
// 面（ShaderDoc）の program と pipeline と draw は WebGpuSurfaces。3D の場面は Render3d.WebGpuRenderer が 2D の pass の前に自分の texture へ描き、2D の並びの z の位置で貼る（呼ぶ所は WebGpuPaint.Scenes）。
// まだ描かない物（起動の後に足せなかった字など）は描かずに飛ばし、種類ごとの回数を数える（RenderPaint.Internal.SkippedDraws）。
//
// 使い方（device を開いた糸で、create から順に）:
//   let paint = WebGpuPaint.create(gpu, { designWidth, designHeight, clearColor, width, height });
//   WebGpuPaint.putTexture(name, WebGpuPaint.uploadRgba(paint, w, h, rgba), paint);
//   handleTarget(paint, () -> handleDiagnostics(paint, () -> handleDraw3d(paint, () ->
//       handleDraw2d(paint, onScreen, () -> handleGpuResources(paint, fonts, f)))));
//   コマの終わりに WebGpuPaint.present(paint, 画面の texture か None)
pub mod RenderPaint.Internal.WebGpuPaint {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BlendFactor
    import fge.webgpu.BlendOperation
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.CommandEncoder
    import fge.webgpu.CompareFunction
    import fge.webgpu.FilterMode
    import fge.webgpu.RenderPass
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Sampler
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.StencilOperation
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.FloatBuffer
    use RenderFrame.Internal.RenderList
    use RenderFrame.Internal.RenderList.{DepthStencil, PassHistory, PassSpec}
    use RenderFrame.Internal.WebGpuRows
    use RenderPaint.Internal.SkippedDraws
    use RenderPaint.Internal.TargetTable
    use RenderPaint.Internal.TextureTable
    use RenderPaint.Internal.TileTable
    use RenderPaint.Internal.WebGpuPaint.Scenes
    use RenderPaint.Internal.WebGpuPipelines
    use RenderPaint.Internal.WebGpuShader
    use RenderPaint.Internal.WebGpuSurfaces

    /// 絵の表の 1 枚（番号 → texture と、それを読む bind group）。
    type alias TextureSlot = { texture = Texture, group = BindGroup, width = Int32, height = Int32 }

    /// GPU へ毎コマ送る float の Stream 1 本: CPU の入れ物（LITTLE_ENDIAN の bytes と、その float の見方）と、送り先の GPU の buffer（usage = その使い道）。
    /// sizes: 0 = GPU の buffer の bytes・1 = 今の encoder（submit まで）に使った bytes。
    type alias Stream = {
        label = String,
        usage = Int32,
        cpuBytes = Array[ByteBuffer, Static],
        cpuFloats = Array[FloatBuffer, Static],
        gpuBuffer = Array[Buffer, Static],
        sizes = Array[Int32, Static]
    }

    /// 塗りのコアの状態。作るのは create だけ。
    enum PaintData {
        case PaintData({
            gpu = WebGpu,
            designW = Float64,
            designH = Float64,
            clearColor = Color,
            presentModule = ShaderModule,
            frameLayout = BindGroupLayout,
            imageLayout = BindGroupLayout,
            presentLayout = BindGroupLayout,
            uniform = Buffer,
            frameGroup = BindGroup,
            // 形・blend・形式・標本・stencil の使い方ごとの pipeline と、mask の stencil の表。
            pipes = WebGpuPipelines.Pipelines,
            // history へ写す pipeline（形式の番号 → pipeline。present と同じ WGSL で、1 画素ずつ写す）。
            copyPipelines = Ref[Map[Int32, RenderPipeline], Static],
            // 画面の形式と、中間の texture を写す pipeline。
            presentPipeline = Ref[Option[(TextureFormat, RenderPipeline)], Static],
            // 中間の texture を読む bind group（中間の texture を作り直したら作り直す）。
            presentGroup = Ref[Option[BindGroup], Static],
            nearestRepeat = Sampler,
            linearRepeat = Sampler,
            nearestClamp = Sampler,
            linearClamp = Sampler,
            // 1 × 1 の透明な黒（pass の頭で group 1 に付けておく）。
            blank = TextureSlot,
            slots = Ref[Map[Int32, TextureSlot], Static],
            nextSlot = Array[Int32, Static],
            registryRef = Ref[RenderAsset.TextureRegistry, Static],
            textureKeyRef = Ref[Map[String, String], Static],
            // レンダーターゲットと開いているターゲットの表（ターゲットの texture は slots の番号で引く）。
            targets = TargetTable.Table,
            // 標本を持つターゲットの描き先（slots の番号 → 標本つきの texture と標本の数。pass の終わりに slots の texture へ resolve する）。
            msaaTargets = Ref[Map[Int32, (Texture, Int32)], Static],
            // history へ写す元の bind group（写す元の描き先の slots の番号 → bind group。描き先を捨てる時に手放す）。
            copyGroups = Ref[Map[Int32, BindGroup], Static],
            // 窓いっぱいに広げて貼る絵（App.withLetterboxView の Pass）を、2 つの画素の間をなめらかにつないで読む bind group（slots の番号 → bind group。dropSlot が手放す）。
            linearGroups = Ref[Map[Int32, BindGroup], Static],
            lastFrame = Array[RenderPaint.Frame, Static],
            // このコマ（か Pass）に溜まった 3D の場面と面（drawScene3d と drawSurface が積み、submitFrame が取り出す。新しい順）。
            pendingScenes = Array[List[Scene3d.RenderCmd], Static],
            pendingSurfaces = Array[List[DrawCmd.SurfaceRenderCmd], Static],
            // 次の画面のコマで design の外へ広げる絵の名前（fillLetterbox が置き、submitFrame が取り出す）。
            pendingLetterbox = Array[Option[String], Static],
            // 面の program と pipeline の表。
            surfaces = WebGpuSurfaces.Surfaces,
            // スプライトの instance・多角形の頂点・draw ごとの値（RenderList の values）の Stream。
            instances = Stream,
            vertices = Stream,
            values = Stream,
            // 頂点の buffer の表: タイルの層の instance（番号 → buffer と、入る枚数）・static layer の頂点（番号 → buffer と、頂点の数）。番号は nextBuffer から振る。
            tiles = TileTable.Table,
            tileBuffers = Ref[Map[Int32, (Buffer, Int32)], Static],
            staticBuffers = Ref[Map[Int32, (Buffer, Int32)], Static],
            staticCell = Array[Option[RenderStatic.Entry], Static],
            nextBuffer = Array[Int32, Static],
            // 中間の texture と、その画素の大きさ（幅・高さ）。
            frameTexture = Array[Texture, Static],
            frameSize = Array[Int32, Static],
            encoder = Array[Option[CommandEncoder], Static],
            // 0 = 今の encoder に積んだ pass の数・1 = このコマの submit の数・2 = 前のコマの submit の数・
            // 3〜5 = takeSubmitCounts の後のコマの数・そのうち submit が 2 回以上のコマの数・1 コマの submit の一番多い回数。
            frameCounters = Array[Int32, Static],
            texWarnLog = Ref[Set[String], Static],
            // 標本の数を丸めたと知らせ終えた描き先の名前（"MSAA " + 名前）。
            msaaWarned = Ref[Set[String], Static],
            // まだ描けずに飛ばした物の種類ごとの回数。
            skips = SkippedDraws.Counts,
            diagnosticsRef = Ref[Option[FrameDiagnostics.Diagnostics], Static],
            drawCounts = RenderDrawCounts.Holder,
            // 3D の場面を描く所（2D の pass の前に場面を自分の texture へ描き、貼る行で貼る）。
            scenes3d = Render3d.WebGpuRenderer.Scenes,
            // Pass の history に前のコマの絵を写すか（偽なら毎回透明。GL の RenderPaint の keepHistory と同じ）。
            keepHistory = Bool
        })
    }

    pub type alias Paint = PaintData

    /// Pass の history を毎回透明にした paint（窓なしの 1 枚撮り。GL の GlOffscreen と同じく、続けて撮った前の 1 枚や
    /// 字の欠けで描き直す前の試しを history として読まない）。
    pub def withoutHistory(paint: Paint): Paint =
        let PaintData.PaintData(p) = paint;
        PaintData.PaintData({ keepHistory = false | p })

    /// instance の 1 体のバイト数（RenderFrame.writeInstAt の float の並び）。
    def instanceBytes(): Int32 = 4 * RenderList.instanceFloats()

    /// device の上に pipeline・buffer・中間の texture・組み込みの絵（起動画面の字とロゴ・Render.lightAt と darkAt の絵）を作る。
    /// design = 射影の寸・clearColor = design の中の地の色・width × height = 中間の texture の画素の大きさ・
    /// scene3d = 3D の場面の描き手の作り方（Render3d.WebGpuRenderer.makeScenes・3D を描かないなら (_, _, _) -> checked_ecast(Render3d.WebGpuRenderer.none())）。
    pub def create(gpu: WebGpu, cfg: { designWidth = Int32, designHeight = Int32, clearColor = Color, width = Int32, height = Int32,
                                       scene3d = (WebGpu, BindGroupLayout, BindGroupLayout) -> Render3d.WebGpuRenderer.Scenes \ IO }): Paint \ IO =
        let designW = Int32.toFloat64(cfg#designWidth);
        let designH = Int32.toFloat64(cfg#designHeight);
        let frameLayout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("fge frame").buffer(0, ShaderStage.VERTEX, BufferBindingType.UNIFORM));
        let imageLayoutDesc = new BindGroupLayoutDesc("fge image");
        discard imageLayoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(1, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        let imageLayout = gpu.createBindGroupLayout(imageLayoutDesc);
        let presentLayout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("fge present").texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT));
        let uniform = gpu.createBuffer("fge projection", 64i64, Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST));
        let projection = projectionBytes(designW, designH);
        gpu.writeBuffer(uniform, 0i64, projection, 0, 64);
        let frameGroup = gpu.createBindGroup(new BindGroupDesc("fge frame", frameLayout).buffer(0, uniform, 0i64, 64i64));
        let nearestRepeat = gpu.createSampler("fge nearest repeat", FilterMode.NEAREST, FilterMode.NEAREST, AddressMode.REPEAT);
        let linearRepeat = gpu.createSampler("fge linear repeat", FilterMode.LINEAR, FilterMode.NEAREST, AddressMode.REPEAT);
        let nearestClamp = gpu.createSampler("fge nearest clamp", FilterMode.NEAREST, FilterMode.NEAREST, AddressMode.CLAMP_TO_EDGE);
        let linearClamp = gpu.createSampler("fge linear clamp", FilterMode.LINEAR, FilterMode.NEAREST, AddressMode.CLAMP_TO_EDGE);
        let blankTexture = gpu.createTexture("fge blank", 1, 1, TextureFormat.RGBA8_UNORM,
                                             Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        gpu.writeTexture(blankTexture, 0, 0, 0, 1, 1, ByteBuffer.allocateDirect(4), 0, 4);
        let blankDesc = new BindGroupDesc("fge blank", imageLayout);
        discard blankDesc.textureView(0, blankTexture.defaultView()).sampler(1, nearestRepeat);
        let blank = { texture = blankTexture, width = 1, height = 1, group = gpu.createBindGroup(blankDesc) };
        let pipes = WebGpuPipelines.fresh(gpu, frameLayout, imageLayout, (designW, designH));
        WebGpuPipelines.buildStartupPipelines(pipes);
        let paint = PaintData.PaintData({
            gpu = gpu, designW = designW, designH = designH, clearColor = cfg#clearColor,
            presentModule = gpu.createShaderModule("fge present", WebGpuShader.presentWgsl()),
            frameLayout = frameLayout, imageLayout = imageLayout, presentLayout = presentLayout,
            uniform = uniform, frameGroup = frameGroup,
            pipes = pipes, copyPipelines = Ref.fresh(Static, Map.empty()), presentPipeline = Ref.fresh(Static, None),
            presentGroup = Ref.fresh(Static, None),
            nearestRepeat = nearestRepeat, linearRepeat = linearRepeat, nearestClamp = nearestClamp, linearClamp = linearClamp,
            blank = blank, slots = Ref.fresh(Static, Map.empty()), nextSlot = Array#{1} @ Static,
            registryRef = Ref.fresh(Static, Map.empty()), textureKeyRef = Ref.fresh(Static, Map.empty()),
            targets = TargetTable.fresh(), msaaTargets = Ref.fresh(Static, Map.empty()), copyGroups = Ref.fresh(Static, Map.empty()),
            linearGroups = Ref.fresh(Static, Map.empty()),
            lastFrame = Array#{RenderPaint.emptyFrame()} @ Static,
            pendingScenes = Array#{(Nil: List[Scene3d.RenderCmd])} @ Static,
            pendingSurfaces = Array#{(Nil: List[DrawCmd.SurfaceRenderCmd])} @ Static,
            pendingLetterbox = Array#{(None: Option[String])} @ Static,
            surfaces = WebGpuSurfaces.fresh(gpu, { layout = frameLayout, group = frameGroup }, { nearest = nearestClamp, linear = linearClamp }),
            instances = freshStream(gpu, "fge instances", vertexUsage(), 4096 * instanceBytes()),
            vertices = freshStream(gpu, "fge vertices", vertexUsage(), 4096 * 4 * RenderList.vertexFloats()),
            // 面の値も読むので uniform の buffer としても bind する。
            values = freshStream(gpu, "fge values", Int32.bitwiseOr(vertexUsage(), BufferUsage.UNIFORM), 4096 * 4),
            tiles = TileTable.fresh(), tileBuffers = Ref.fresh(Static, Map.empty()), staticBuffers = Ref.fresh(Static, Map.empty()),
            staticCell = Array#{(None: Option[RenderStatic.Entry])} @ Static, nextBuffer = Array#{1} @ Static,
            frameTexture = Array#{createFrameTexture(gpu, cfg#width, cfg#height)} @ Static,
            frameSize = Array#{cfg#width, cfg#height} @ Static,
            encoder = Array#{(None: Option[CommandEncoder])} @ Static,
            frameCounters = Array#{0, 0, 0, 0, 0, 0} @ Static,
            texWarnLog = Ref.fresh(Static, Set.empty()), msaaWarned = Ref.fresh(Static, Set.empty()), skips = SkippedDraws.fresh(),
            diagnosticsRef = Ref.fresh(Static, None), drawCounts = RenderDrawCounts.fresh(),
            scenes3d = (cfg#scene3d)(gpu, pipes#sceneLayout, imageLayout),
            keepHistory = true
        });
        installBuiltins(paint);
        paint

    /// 起動画面の字とロゴ・Render.lightAt と darkAt の組み込みの絵を上げて名前で引けるようにする（GL の RenderSplash.install と loadAssets の分）。
    def installBuiltins(paint: Paint): Unit \ IO =
        let side = BootFontData.side();
        putTexture(BootFont.textureName(), uploadBgra(paint, side, side, BootFont.pixelsArgb()), paint);
        let logoSide = BootFont.logoSide();
        putTexture(BootFont.logoTextureName(), uploadBgra(paint, logoSide, logoSide, BootFont.logoArgb()), paint);
        TextureTable.putRadialBuiltins(webGpuUploads(paint), textureTables(paint))

    /// GL の RenderShader.setProjectionMatrix と同じ行列（列の順・64 バイト）。
    def projectionBytes(width: Float64, height: Float64): ByteBuffer \ IO =
        let buf = ByteBuffer.allocateDirect(64).order(ByteOrder.LITTLE_ENDIAN);
        let values = RenderUtil.f32(2.0 / width) :: 0.0f32 :: 0.0f32 :: 0.0f32 ::
                     0.0f32 :: RenderUtil.f32(-2.0 / height) :: 0.0f32 :: 0.0f32 ::
                     0.0f32 :: 0.0f32 :: -1.0f32 :: 0.0f32 ::
                     -1.0f32 :: 1.0f32 :: 0.0f32 :: 1.0f32 :: Nil;
        List.forEach(v -> discard buf.putFloat(v), values);
        discard buf.flip();
        buf

    /// 頂点の buffer として読み、queue から書く buffer の使い道。
    def vertexUsage(): Int32 = Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST)

    /// bytes の GPU の buffer（使い道 usage）。
    def createStreamBuffer(gpu: WebGpu, label: String, usage: Int32, bytes: Int32): Buffer \ IO =
        gpu.createBuffer(label, Int32.toInt64(bytes), usage)

    def freshStream(gpu: WebGpu, label: String, usage: Int32, bytes: Int32): Stream \ IO =
        let cpu = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN);
        { label = label, usage = usage, cpuBytes = Array#{cpu} @ Static, cpuFloats = Array#{cpu.asFloatBuffer()} @ Static,
          gpuBuffer = Array#{createStreamBuffer(gpu, label, usage, bytes)} @ Static, sizes = Array#{bytes, 0} @ Static }

    def createFrameTexture(gpu: WebGpu, width: Int32, height: Int32): Texture \ IO =
        gpu.createTexture("fge frame", Int32.max(1, width), Int32.max(1, height), TextureFormat.RGBA8_UNORM,
                          Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_SRC)), 1, 1)

    // ── pipeline ──

    /// 画面の形式 format へ中間の texture を写す pipeline（形式が変われば作り直す）。
    def presentPipelineOf(paint: Paint, format: TextureFormat): RenderPipeline \ IO =
        let PaintData.PaintData(p) = paint;
        let current = Ref.get(p#presentPipeline);
        let kept = current |> Option.filter(fp -> fst(fp).ordinal() == format.ordinal());
        match kept {
            case Some((_, pipeline)) => pipeline
            case None =>
                Option.forEach(fp -> snd(fp).release(), current);
                let desc = new RenderPipelineDesc("fge present");
                discard desc.bindGroupLayout(p#presentLayout).vertex(p#presentModule, "vs_present").fragment(p#presentModule, "fs_present");
                discard desc.colorTarget(format);
                let pipeline = p#gpu.createRenderPipeline(desc);
                Ref.put(Some((format, pipeline)), p#presentPipeline);
                pipeline
        }

    def presentGroupOf(paint: Paint): BindGroup \ IO =
        let PaintData.PaintData(p) = paint;
        match Ref.get(p#presentGroup) {
            case Some(group) => group
            case None =>
                let desc = new BindGroupDesc("fge present", p#presentLayout);
                discard desc.textureView(0, Array.get(0, p#frameTexture).defaultView());
                let group = p#gpu.createBindGroup(desc);
                Ref.put(Some(group), p#presentGroup);
                group
        }

    // ── 絵の表 ──

    /// 絵を表に足して番号を返す。
    def addSlot(paint: Paint, texture: Texture, sampler: Sampler, width: Int32, height: Int32): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        let id = Array.get(0, p#nextSlot);
        Array.put(id + 1, 0, p#nextSlot);
        let desc = new BindGroupDesc("fge image", p#imageLayout);
        discard desc.textureView(0, texture.defaultView()).sampler(1, sampler);
        let group = p#gpu.createBindGroup(desc);
        Ref.put(Map.insert(id, { texture = texture, group = group, width = width, height = height }, Ref.get(p#slots)), p#slots);
        id

    /// 番号 id の絵を捨てる（積んだ pass があれば先に submit する）。
    def dropSlot(paint: Paint, id: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match Map.get(id, Ref.get(p#slots)) {
            case None => ()
            case Some(slot) =>
                flushPending(paint);
                slot#group.release();
                Map.get(id, Ref.get(p#linearGroups)) |> Option.forEach(g -> g.release());
                Ref.put(Map.remove(id, Ref.get(p#linearGroups)), p#linearGroups);
                slot#texture.destroy();
                Ref.put(Map.remove(id, Ref.get(p#slots)), p#slots)
        }

    def infoOf(id: Int32, width: Int32, height: Int32): RenderAsset.TextureInfo =
        { id = GpuHandle.wrapTextureId(id), width = Int32.toFloat64(width), height = Int32.toFloat64(height) }

    def imageUsage(): Int32 = Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST)

    /// 解いた画像（1 画素 4 バイトの RGBA・上の行から）を RGBA8_UNORM の絵にする。NEAREST・REPEAT。名前で引くには putTexture。
    pub def uploadRgba(paint: Paint, width: Int32, height: Int32, rgba: ByteBuffer): RenderAsset.TextureInfo \ IO =
        let PaintData.PaintData(p) = paint;
        flushPending(paint);
        let texture = p#gpu.createTexture("fge image", width, height, TextureFormat.RGBA8_UNORM, imageUsage(), 1, 1);
        p#gpu.writeTexture(texture, 0, 0, 0, width, height, rgba, 0, width * 4);
        infoOf(addSlot(paint, texture, p#nearestRepeat, width, height), width, height)

    /// ARGB の int の列（行優先・上の行から）を BGRA8_UNORM の絵にする（little-endian に並べたバイトが B・G・R・A）。NEAREST・REPEAT。
    pub def uploadBgra(paint: Paint, width: Int32, height: Int32, argb: Vector[Int32]): RenderAsset.TextureInfo \ IO =
        let PaintData.PaintData(p) = paint;
        flushPending(paint);
        let texture = p#gpu.createTexture("fge image", width, height, TextureFormat.BGRA8_UNORM, imageUsage(), 1, 1);
        p#gpu.writeTexture(texture, 0, 0, 0, width, height, argbBytes(argb), 0, width * 4);
        infoOf(addSlot(paint, texture, p#nearestRepeat, width, height), width, height)

    /// 字の距離場（1 画素 1 バイト・上の行から）を R8_UNORM の絵にする。LINEAR・REPEAT（シェーダーは .r を読む）。
    pub def uploadR8(paint: Paint, width: Int32, height: Int32, pixels: ByteBuffer): RenderAsset.TextureInfo \ IO =
        let PaintData.PaintData(p) = paint;
        flushPending(paint);
        discard pixels.position(0);
        let texture = p#gpu.createTexture("fge font", width, height, TextureFormat.R8_UNORM, imageUsage(), 1, 1);
        p#gpu.writeTexture(texture, 0, 0, 0, width, height, pixels, 0, width);
        infoOf(addSlot(paint, texture, p#linearRepeat, width, height), width, height)

    /// uploadR8 で作った番号 id の絵の (x, y) から width × height を、字の距離場（1 画素 1 バイト・上の行から）で書き替える。
    // WhyNot: 積んだ pass を先に submit しない（rewriteSlot と違う）— 書くのは字を置いていない所だけで、前に置いた字の画素は変わらない。
    pub def writeR8Region(paint: Paint, id: Int32, x: Int32, y: Int32, width: Int32, height: Int32, pixels: ByteBuffer): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match Map.get(id, Ref.get(p#slots)) {
            case None       => ()
            case Some(slot) => p#gpu.writeTexture(slot#texture, 0, x, y, width, height, pixels, 0, width)
        }

    /// ARGB の int の列を little-endian のバイトにする。
    // WhyNot: 1 要素ずつ put しない — Flix の Vector は JVM の int[] のままで、1 回で写せる（RenderTexture.withArgbBuffer と同じ）。
    def argbBytes(argb: Vector[Int32]): ByteBuffer \ IO =
        let arr = unchecked_cast(argb as Array[Int32, Static]);
        let bytes = ByteBuffer.allocateDirect(Int32.max(4, Vector.length(argb) * 4)).order(ByteOrder.LITTLE_ENDIAN);
        discard bytes.asIntBuffer().put(arr);
        bytes

    /// 解いた画像（alpha が真なら RGBA、偽なら RGB の 3 バイト・上の行から）を RGBA8_UNORM の絵にする。RGB は alpha を 255 にして 4 バイトへ広げる
    /// （GL が RGB8 で上げて alpha を 1 で読むのと同じ）。
    // WhyNot: GPU の側で広げない — WebGPU に 3 バイトの形式が無く、広げるのは読み込みの時だけなので CPU で足りる。
    def uploadImage(paint: Paint, width: Int32, height: Int32, bytes: ByteBuffer, alpha: Bool): RenderAsset.TextureInfo \ IO =
        if (alpha) uploadRgba(paint, width, height, bytes)
        else uploadRgba(paint, width, height, TextureTable.opaqueRgbaOf(bytes, width * height))

    /// RGBA（1 画素 4 バイト）の頭 count 画素の alpha を 255 で埋める（hasAlpha が偽の絵。GL が RGB8 で上げて alpha を 1 で読むのと同じ）。
    pub def makeOpaque(rgba: ByteBuffer, count: Int32): Unit \ IO = fillAlphaFrom(rgba, count, 0)

    def fillAlphaFrom(rgba: ByteBuffer, count: Int32, i: Int32): Unit \ IO =
        if (i >= count) ()
        else {
            discard rgba.put(i * 4 + 3, -1i8);
            fillAlphaFrom(rgba, count, i + 1)
        }

    /// device の上に作った物（pipeline・sampler・layout・bind group・texture・buffer・shader module）を全部手放す。device は呼ぶ側が捨てる。
    /// この後 paint は使えない。
    pub def release(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        warnTable(SkippedDraws.tableOf(p#skips, "終わり"));
        Array.put(None, 0, p#encoder);
        Map.forEach((_, slot) -> { slot#group.release(); slot#texture.destroy() }, Ref.get(p#slots));
        Ref.put(Map.empty(), p#slots);
        Map.forEach((_, msaa) -> fst(msaa).destroy(), Ref.get(p#msaaTargets));
        Ref.put(Map.empty(), p#msaaTargets);
        Map.forEach((_, group) -> group.release(), Ref.get(p#copyGroups));
        Ref.put(Map.empty(), p#copyGroups);
        TargetTable.clear(p#targets);
        p#blank#group.release();
        p#blank#texture.destroy();
        Option.forEach(g -> g.release(), Ref.get(p#presentGroup));
        Ref.put(None, p#presentGroup);
        Option.forEach(fp -> snd(fp).release(), Ref.get(p#presentPipeline));
        Ref.put(None, p#presentPipeline);
        WebGpuPipelines.release(p#pipes);
        WebGpuSurfaces.release(p#surfaces);
        (p#scenes3d#release)();
        Map.forEach((_, pipeline) -> pipeline.release(), Ref.get(p#copyPipelines));
        Ref.put(Map.empty(), p#copyPipelines);
        Array.get(0, p#frameTexture).destroy();
        RenderStatic.release(webGpuStaticAllocator(paint), p#staticCell);
        Map.forEach((_, b) -> fst(b).destroy(), Ref.get(p#tileBuffers));
        Map.forEach((_, b) -> fst(b).destroy(), Ref.get(p#staticBuffers));
        Ref.put(Map.empty(), p#staticBuffers);
        Ref.put(Map.empty(), p#tileBuffers);
        List.forEach(stream -> Array.get(0, stream#gpuBuffer).destroy(), p#instances :: p#vertices :: p#values :: Nil);
        p#frameGroup.release();
        p#uniform.destroy();
        p#nearestRepeat.release();
        p#linearRepeat.release();
        p#nearestClamp.release();
        p#linearClamp.release();
        p#frameLayout.release();
        p#imageLayout.release();
        p#presentLayout.release();
        p#presentModule.release()

    /// 1 枚を名前で置く（同じ名前は置き換える）。
    pub def putTexture(name: String, info: RenderAsset.TextureInfo, paint: Paint): Unit \ IO =
        TextureTable.putTexture(textureTables(paint), name, info)

    /// 絵の CPU の側の表。
    def textureTables(paint: Paint): TextureTable.Tables =
        let PaintData.PaintData(p) = paint;
        { registryRef = p#registryRef, textureKeyRef = p#textureKeyRef }

    /// WebGPU で絵を上げる関数の組（どれも、そのコマに積んだ pass があれば先に submit する）。
    pub def webGpuUploads(paint: Paint): TextureTable.Uploads =
        { createArgb = (width, height, argb) -> uploadBgra(paint, width, height, argb),
          createImage = (width, height, bytes, alpha) -> uploadImage(paint, width, height, bytes, alpha),
          writeArgb = (info, width, height, argb) -> rewriteSlot(paint, GpuHandle.textureIdInt(info#id), width, height, argb),
          drop = info -> dropSlot(paint, GpuHandle.textureIdInt(info#id)) }

    /// 番号 id の絵の画素を差し替える（積んだ pass があれば先に submit する）。
    def rewriteSlot(paint: Paint, id: Int32, width: Int32, height: Int32, argb: Vector[Int32]): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match Map.get(id, Ref.get(p#slots)) {
            case None => ()
            case Some(slot) =>
                flushPending(paint);
                p#gpu.writeTexture(slot#texture, 0, 0, 0, width, height, argbBytes(argb), 0, width * 4)
        }

    // ── encoder と submit ──

    def encoderOf(paint: Paint): CommandEncoder \ IO =
        let PaintData.PaintData(p) = paint;
        match Array.get(0, p#encoder) {
            case Some(e) => e
            case None =>
                let e = p#gpu.createCommandEncoder("fge frame");
                Array.put(Some(e), 0, p#encoder);
                e
        }

    /// 今の encoder を submit する（無ければ何もしない）。流れの buffer は頭から使い直せる（queue の書き込みは submit の順に並ぶ）。
    def submitEncoder(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match Array.get(0, p#encoder) {
            case None => ()
            case Some(e) =>
                p#gpu.submit(e.finish());
                Array.put(None, 0, p#encoder);
                Array.put(0, 0, p#frameCounters);
                Array.put(Array.get(1, p#frameCounters) + 1, 1, p#frameCounters);
                List.forEach(stream -> Array.put(0, 1, stream#sizes), p#instances :: p#vertices :: p#values :: Nil);
                WebGpuSurfaces.afterSubmit(p#surfaces);
                (p#scenes3d#afterSubmit)()
        }

    /// このコマに積んだ pass があれば submit する（絵や buffer を作る・書く・捨てる前に呼ぶ）。
    def flushPending(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        if (Array.get(0, p#frameCounters) > 0) submitEncoder(paint) else ()

    // ── 1 回の renderCommands ──

    /// n 個の float を書ける stream の CPU の入れ物。足りなければ倍に作り直す。
    def floatsFor(stream: Stream, n: Int32): FloatBuffer \ IO =
        let bytes = Array.get(0, stream#cpuBytes);
        if (bytes.capacity() >= 4 * n) Array.get(0, stream#cpuFloats)
        else {
            let raw = ByteBuffer.allocateDirect(Int32.max(4 * n, 2 * bytes.capacity()));
            let grown = raw.order(ByteOrder.LITTLE_ENDIAN);
            let floats = grown.asFloatBuffer();
            Array.put(grown, 0, stream#cpuBytes);
            Array.put(floats, 0, stream#cpuFloats);
            floats
        }

    /// 1 つの pass の送り方を決める。3 本の Stream（instance・頂点・values）ごとに (GPU の buffer の bytes, 今の encoder に使った bytes, 送る bytes)。
    /// 返すのは (先に submit するか, 3 本それぞれの (送った後の GPU の buffer の bytes, 送る位置の bytes))。
    /// どれかが空きに入らなければ submit して 3 本とも頭から送る（1 本だけ submit の後へ送ると、前の本が今の encoder の外で後の書き込みに上書きされる）。
    /// 頭からでも入らない本は、要る大きさか倍の大きい方へ伸ばす。
    def planUpload(instances: (Int32, Int32, Int32), vertices: (Int32, Int32, Int32), values: (Int32, Int32, Int32)):
            (Bool, (Int32, Int32), (Int32, Int32), (Int32, Int32)) =
        let submit = overflows(instances) or overflows(vertices) or overflows(values);
        (submit, placeIn(submit, instances), placeIn(submit, vertices), placeIn(submit, values))

    def overflows(demand: (Int32, Int32, Int32)): Bool =
        let (capacity, used, need) = demand;
        used + need > capacity

    /// 1 本の (送った後の GPU の buffer の bytes, 送る位置)。submit したら頭から・頭からでも入らなければ要る大きさか倍の大きい方。
    def placeIn(submit: Bool, demand: (Int32, Int32, Int32)): (Int32, Int32) =
        let (capacity, used, need) = demand;
        let base = if (submit) 0 else used;
        (if (base + need <= capacity) capacity else Int32.max(base + need, 2 * capacity), base)

    /// stream の (GPU の buffer の bytes, 使った bytes を align の倍数へ切り上げた物, 送る bytes)。
    def demandOf(stream: Stream, align: Int32, bytes: Int32): (Int32, Int32, Int32) \ IO =
        (Array.get(0, stream#sizes), (Array.get(1, stream#sizes) + align - 1) / align * align, bytes)

    /// planUpload の 1 本ぶんを行う: GPU の buffer を planned の大きさに作り直し（変わる時だけ）、CPU の入れ物の頭 bytes を送る位置へ書く。返すのは送る位置。
    def sendPlanned(paint: Paint, stream: Stream, planned: (Int32, Int32), bytes: Int32): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        let (capacity, base) = planned;
        if (capacity == Array.get(0, stream#sizes)) ()
        else {
            Array.get(0, stream#gpuBuffer).destroy();
            Array.put(createStreamBuffer(p#gpu, stream#label, stream#usage, capacity), 0, stream#gpuBuffer);
            Array.put(capacity, 0, stream#sizes)
        };
        if (bytes > 0) p#gpu.writeBuffer(Array.get(0, stream#gpuBuffer), Int32.toInt64(base), Array.get(0, stream#cpuBytes), 0, bytes) else ();
        Array.put(base + bytes, 1, stream#sizes);
        base

    /// 1 つの pass の instance（体数）・頂点（数）・values（values の頭 valueCount 個）を GPU へ送り、送った位置（instance の番号, 頂点の番号, values の bytes）を返す。
    /// 送り方は planUpload が決める（伸ばす時はいつも submit の後になる — 伸ばす本は頭からでも入らないので、空きにも入らない）。
    /// values は面の値を uniform として読む位置（RenderList.surfaceValueAlign の 4 倍のバイト）が buffer の中でもその倍数になるよう、送る位置をそろえる。
    def upload(paint: Paint, instanceCount: Int32, vertexCount: Int32, values: Array[Float32, Static], valueCount: Int32): (Int32, Int32, Int32) \ IO =
        let PaintData.PaintData(p) = paint;
        let instanceSize = instanceCount * instanceBytes();
        let vertexSize = vertexCount * 4 * RenderList.vertexFloats();
        let valueSize = valueCount * 4;
        let (submit, instancePlan, vertexPlan, valuePlan) =
            planUpload(demandOf(p#instances, 4, instanceSize), demandOf(p#vertices, 4, vertexSize),
                       demandOf(p#values, 4 * RenderList.surfaceValueAlign(), valueSize));
        if (submit) {
            flushPending(paint);
            List.forEach(stream -> Array.put(0, 1, stream#sizes), p#instances :: p#vertices :: p#values :: Nil)
        } else ();
        discard floatsFor(p#values, valueCount).put(0, values, 0, valueCount);
        let instanceBase = sendPlanned(paint, p#instances, instancePlan, instanceSize) / instanceBytes();
        let vertexBase = sendPlanned(paint, p#vertices, vertexPlan, vertexSize) / (4 * RenderList.vertexFloats());
        (instanceBase, vertexBase, sendPlanned(paint, p#values, valuePlan, valueSize))

    /// texture の render pass を spec の色の始末（RenderList.loadOpOf）で開き、group 0・空の絵・instance buffer を付ける。
    /// msaa = 標本を持つ描き先と標本の数（Some なら描くのはそちらで、pass の終わりに texture へ resolve する）。
    /// spec の depthStencil が DepthAndStencil なら、stencilKey の stencil（描き先と同じ大きさと標本の数）を 0 で clear して付ける。
    def openPass(paint: Paint, texture: Texture, msaa: Option[(Texture, Int32)], stencilKey: Int32, spec: PassSpec): RenderPass \ IO =
        let PaintData.PaintData(p) = paint;
        let drawn = msaa |> Option.map(fst) |> Option.getWithDefault(texture);
        let view = drawn.defaultView();
        let desc = match RenderList.loadOpOf(spec) {
            case RenderTarget.LoadOp.Clear(c)         => new RenderPassDesc("fge pass").clearColor(view, c#r, c#g, c#b, 1.0)
            case RenderTarget.LoadOp.ClearTransparent => new RenderPassDesc("fge pass").clearColor(view, 0.0, 0.0, 0.0, 0.0)
            case RenderTarget.LoadOp.Keep             => new RenderPassDesc("fge pass").loadColor(view)
        };
        if (Option.isEmpty(msaa)) () else discard desc.resolveTo(texture.defaultView());
        match spec#depthStencil {
            case DepthStencil.DepthAndStencil =>
                let samples = msaa |> Option.map(snd) |> Option.getWithDefault(1);
                discard desc.clearDepthStencil(WebGpuPipelines.stencilOf(p#pipes, () -> flushPending(paint), stencilKey, drawn.width(), drawn.height(), samples).defaultView(), 1.0, 0)
            case _ => ()
        };
        let pass = encoderOf(paint).beginRenderPass(desc);
        Array.put(Array.get(0, p#frameCounters) + 1, 0, p#frameCounters);
        pass.setBindGroup(0, p#frameGroup);
        pass.setBindGroup(1, p#blank#group);
        bindWhole(pass, 0, Array.get(0, p#instances#gpuBuffer));
        pass

    def bindWhole(pass: RenderPass, slot: Int32, buffer: Buffer): Unit \ IO = pass.setVertexBuffer(slot, buffer, 0i64, buffer.size())

    /// 頂点の buffer の 0 番を、積む物 source（WebGpuRows.vertexSource*）の buffer にする（WebGpuRows.renderFrame の setVertices）。返すのはその buffer に入っている要素の数
    /// （タイルは枚数・static は頂点の数・stencil を 0 に戻す矩形は 6・スプライトと多角形はこのコマに送った分なので上限を設けない）。表に無い番号は 0（その行は描かない）。
    def setVertices(paint: Paint, pass: RenderPass, source: Int32, buffer: Int32): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        if (source == RenderFrame.Internal.WebGpuRows.vertexSourcePoly()) { bindWhole(pass, 0, Array.get(0, p#vertices#gpuBuffer)); Int32.maxValue() }
        else if (source == RenderFrame.Internal.WebGpuRows.vertexSourceStencilQuad()) { bindWhole(pass, 0, p#pipes#stencilResetQuad); 6 }
        else if (source == RenderFrame.Internal.WebGpuRows.vertexSourceTile()) bindCounted(pass, Map.get(buffer, Ref.get(p#tileBuffers)))
        else if (source == RenderFrame.Internal.WebGpuRows.vertexSourceStatic()) bindCounted(pass, Map.get(buffer, Ref.get(p#staticBuffers)))
        else { bindWhole(pass, 0, Array.get(0, p#instances#gpuBuffer)); Int32.maxValue() }

    /// 表の (buffer, 要素の数) を頂点の buffer の 0 番に付けて要素の数を返す（表に無ければ 0）。
    def bindCounted(pass: RenderPass, entry: Option[(Buffer, Int32)]): Int32 \ IO = match entry {
        case Some((buffer, count)) =>
            bindWhole(pass, 0, buffer);
            count
        case None => 0
    }

    /// 頂点の buffer の 1 番を、values の buffer の bytes の位置からにする。
    def setValues(paint: Paint, pass: RenderPass, bytes: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let buffer = Array.get(0, p#values#gpuBuffer);
        pass.setVertexBuffer(1, buffer, Int32.toInt64(bytes), buffer.size() - Int32.toInt64(bytes))

    /// 1 回の renderCommands の描き物を texture へ描く。pass = 描き先の指定（画面は中間の texture・Pass はその texture）。
    /// msaa = 標本を持つ描き先と標本の数（Pass の pass の samples が 2 以上の時だけ Some）・stencilKey = mask の stencil を引く描き先の番号（中間の texture は 0）。
    def paintInto(paint: Paint, texture: Texture, msaa: Option[(Texture, Int32)], stencilKey: Int32, pass: PassSpec, frame: RenderPaint.Frame): Unit \ IO =
        paintIntoWith(paint, groupOf(paint), texture, msaa, stencilKey, pass, frame)

    /// paintInto の、行の絵の bind group を groupFor で引く形（広げて貼る絵は linearGroupOf で読む）。
    def paintIntoWith(paint: Paint, groupFor: Int32 -> BindGroup \ IO, texture: Texture, msaa: Option[(Texture, Int32)], stencilKey: Int32,
                      pass: PassSpec, frame: RenderPaint.Frame): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        // WhyNot: 画面の形式を描き先に問わない — 画面は中間の texture（RGBA8）へ描き、present で画面の形式へ写す。
        let format = RenderList.targetFormatOf(pass) |> Option.getWithDefault(RenderTarget.Format.Rgba8Unorm);
        let samples = pass#samples;
        let pipes = p#pipes;
        let staticRanges = match frame#staticLayer {
            case None    => Nil
            case Some(l) => RenderStatic.resolve(webGpuStaticAllocator(paint), p#staticCell, l)
        };
        let surfaces = p#surfaces;
        let textureOf = id -> Map.get(id, Ref.get(p#slots)) |> Option.map(slot -> slot#texture);
        let scenes = Scenes.prepare(paint, stencilKey, (format, samples), pass, frame#scenes);
        WebGpuRows.renderFrame({
            sprites = frame#sprites, tileMaps = frame#tileMaps, polygons = frame#polygons, staticRanges = staticRanges, surfaces = frame#surfaces,
            sceneZs = List.toVector(List.map(cmd -> cmd#scene#zIndex, frame#scenes)),
            registry = Ref.get(p#registryRef),
            designW = p#designW, designH = p#designH, pass = pass,
            texWarnLog = p#texWarnLog, drawCounts = p#drawCounts,
            instancesFor = n -> floatsFor(p#instances, n * RenderList.instanceFloats()),
            verticesFor = n -> floatsFor(p#vertices, n * RenderList.vertexFloats()),
            upload = (n, m, values, k) -> upload(paint, n, m, values, k),
            openPass = spec -> openPass(paint, texture, msaa, stencilKey, spec),
            setPipeline = (pass1, shape, blendC, stencil) -> pass1.setPipeline(WebGpuPipelines.pipelineOf(pipes, shape, blendC, format, samples, stencil)),
            setTexture = (pass1, id) -> pass1.setBindGroup(1, groupFor(id)),
            setVertices = (pass1, kind, buffer) -> setVertices(paint, pass1, kind, buffer),
            setValues = (pass1, bytes) -> setValues(paint, pass1, bytes),
            drawSurface = (pass1, rows, row, reads, stencil, bytes) ->
                WebGpuSurfaces.draw(surfaces, pass1, (format, samples), stencil, Array.get(0, p#values#gpuBuffer), bytes, textureOf, name -> skip(paint, name),
                                    rows, row, reads),
            drawScene = (pass1, index, stencil) -> Scenes.paste(paint, (format, samples), Vector.get(index, scenes), pass1, stencil),
            skip = name -> skip(paint, name)
        })

    // ── 頂点の buffer（タイルの層・static layer）──

    /// 頂点の buffer の次の番号。
    def takeBufferNumber(paint: Paint): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        let id = Array.get(0, p#nextBuffer);
        Array.put(id + 1, 0, p#nextBuffer);
        id

    /// floats の頭 count 個を入れた、頂点の buffer として読む GPU の buffer（積んだ pass があれば先に submit する）。
    def createFilledBuffer(paint: Paint, label: String, floats: Array[Float32, Static], count: Int32): (Buffer, Int32) \ IO =
        let PaintData.PaintData(p) = paint;
        flushPending(paint);
        let bytes = Int32.max(4, 4 * count);
        let buffer = createStreamBuffer(p#gpu, label, vertexUsage(), bytes);
        writeFloats(paint, buffer, floats, count);
        (buffer, bytes)

    def writeFloats(paint: Paint, buffer: Buffer, floats: Array[Float32, Static], count: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        if (count <= 0) ()
        else {
            let data = ByteBuffer.allocateDirect(4 * count).order(ByteOrder.LITTLE_ENDIAN);
            discard data.asFloatBuffer().put(0, floats, 0, count);
            p#gpu.writeBuffer(buffer, 0i64, data, 0, 4 * count)
        }

    /// WebGPU でタイルの層の instance の buffer を作る・入れ直す・大きくする関数の組（積んだ pass があれば先に submit する）。
    /// 大きくする時は同じ番号のまま buffer を捨てて作り直し、表を差し替える。
    /// 表の値は (buffer, 入る枚数)。
    def webGpuTileAllocator(paint: Paint): TileTable.TileAllocator =
        let PaintData.PaintData(p) = paint;
        { create = (floats, count) -> {
              let id = takeBufferNumber(paint);
              let buffer = fst(createFilledBuffer(paint, "fge tiles", floats, count * TileTable.tileFloats()));
              Ref.put(Map.insert(id, (buffer, count), Ref.get(p#tileBuffers)), p#tileBuffers);
              id
          },
          write = (id, floats, count) -> Map.get(id, Ref.get(p#tileBuffers)) |> Option.forEach(match (buffer, _) -> {
              flushPending(paint);
              writeFloats(paint, buffer, floats, count * TileTable.tileFloats())
          }),
          grow = (id, floats, count) -> Map.get(id, Ref.get(p#tileBuffers)) |> Option.forEach(match (buffer, _) -> {
              flushPending(paint);
              buffer.destroy();
              let grown = fst(createFilledBuffer(paint, "fge tiles", floats, count * TileTable.tileFloats()));
              Ref.put(Map.insert(id, (grown, count), Ref.get(p#tileBuffers)), p#tileBuffers)
          }) }

    /// WebGPU で static layer の頂点の buffer を作る・捨てる関数の組（積んだ pass があれば先に submit する）。
    def webGpuStaticAllocator(paint: Paint): RenderStatic.StaticAllocator =
        let PaintData.PaintData(p) = paint;
        { create = (data, count) -> {
              let id = takeBufferNumber(paint);
              let buffer = fst(createFilledBuffer(paint, "fge static", data, count * RenderList.vertexFloats()));
              Ref.put(Map.insert(id, (buffer, count), Ref.get(p#staticBuffers)), p#staticBuffers);
              id
          },
          destroy = id -> Map.get(id, Ref.get(p#staticBuffers)) |> Option.forEach(match (buffer, _) -> {
              flushPending(paint);
              buffer.destroy();
              Ref.put(Map.remove(id, Ref.get(p#staticBuffers)), p#staticBuffers)
          }) }

    /// 番号 id の絵を、2 つの画素の間をなめらかにつないで読む bind group（無ければ作って控える）。表に無い番号は空の絵。
    // WhyNot: Pass の slot の sampler を linear に替えない — Pass を読むほかの描き物（後がけ・合成）は画素を 1 つずつ読む前提で組んである。
    def linearGroupOf(paint: Paint, id: Int32): BindGroup \ IO =
        let PaintData.PaintData(p) = paint;
        match (Map.get(id, Ref.get(p#linearGroups)), Map.get(id, Ref.get(p#slots))) {
            case (Some(group), _) => group
            case (None, Some(slot)) =>
                let desc = new BindGroupDesc("fge image linear", p#imageLayout);
                discard desc.textureView(0, slot#texture.defaultView()).sampler(1, p#linearClamp);
                let group = p#gpu.createBindGroup(desc);
                Ref.put(Map.insert(id, group, Ref.get(p#linearGroups)), p#linearGroups);
                group
            case (None, None) => p#blank#group
        }

    def groupOf(paint: Paint, id: Int32): BindGroup \ IO =
        let PaintData.PaintData(p) = paint;
        Map.get(id, Ref.get(p#slots)) |> Option.map(slot -> slot#group) |> Option.getWithDefault(p#blank#group)

    def skip(paint: Paint, name: String): Unit \ IO = skipMany(paint, name, 1)

    /// まだ描かない物 name を n 回飛ばしたと数える（種類ごとの初めの 1 回だけ知らせる）。
    def skipMany(paint: Paint, name: String, n: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        if (SkippedDraws.add(p#skips, name, n)) Log.warn("[webgpu] まだ描かない: ${name}") else ()

    /// 飛ばした物の表 table があれば 1 回知らせる。
    // WhyNot: 純粋な Unit のまま返さない — 呼ぶ側は文として `;` で捨てるので、純粋な呼び出しは消える（LwjglLayer.announceFixedDt と同じ）。
    def warnTable(table: Option[String]): Unit \ IO = match table {
        case Some(t) => checked_ecast(Log.warn(t))
        case None    => ()
    }

    /// Draw2d.renderCommands の中身。Pass が開いていればそこへ描いて false。開いていなければ中間の texture へ描き、控えを置いて true。
    def submitFrame(paint: Paint, sprites: List[RenderType.Drawable], tileMaps: List[RenderType.TileMapRenderCmd],
                    polygons: List[RenderType.PolygonCmd], staticLayer: Option[GameEngine.StaticLayerCmd]): Bool \ IO =
        let PaintData.PaintData(p) = paint;
        let scenes = List.reverse(Array.get(0, p#pendingScenes));
        Array.put(Nil, 0, p#pendingScenes);
        let surfaces = List.reverse(Array.get(0, p#pendingSurfaces));
        Array.put(Nil, 0, p#pendingSurfaces);
        let frame = { sprites = sprites, tileMaps = tileMaps, polygons = polygons, staticLayer = staticLayer, surfaces = surfaces, scenes = scenes,
                      letterbox = None };
        match TargetTable.activeSpec(p#targets) {
            case Some(spec) =>
                // タイルの層と static layer は画面のコマの物（GL の RenderPaint.paintTarget と同じく Pass には乗せない）。
                paintTarget(paint, spec, { tileMaps = Nil, staticLayer = None | frame });
                false
            case None =>
                let screenFrame = { letterbox = Array.get(0, p#pendingLetterbox) | frame };
                Array.put(None, 0, p#pendingLetterbox);
                Array.put(screenFrame, 0, p#lastFrame);
                paintScreen(paint, screenFrame);
                RenderDrawCounts.endScreenFrame(p#drawCounts);
                // WhyNot: 集めていない間の 3D の数を溜め続けない — 誰も引き取らない数が増え続ける（GL の RenderPaint.noteGpuTime と同じ）。
                if (Option.isEmpty(Ref.get(p#diagnosticsRef))) {
                    RenderDrawCounts.discardTotal(p#drawCounts);
                    discard (p#scenes3d#takeCounts)()
                } else ();
                true
        }

    /// 開いている Pass の texture へ描く（表に無い名前なら何もしない）。描く物（スプライト・面・3D の場面のビルボード）が自分の history を読むなら、pass を開く前に前のコマの絵を写す。
    def paintTarget(paint: Paint, spec: RenderTarget.TargetSpec, frame: RenderPaint.Frame): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let history = TargetTable.historyFor(webGpuTargetAllocator(paint), textureTables(paint), p#targets, (p#designW, p#designH), spec,
                                             isHistoryReadIn(spec#name, frame), p#keepHistory);
        TargetTable.rowByName(p#targets, spec#name)
            |> Option.flatMap(row -> Map.get(row#texture, Ref.get(p#slots)) |> Option.map(slot -> (row, slot)))
            |> Option.forEach(match (row, slot) -> {
                   let msaa = Map.get(row#texture, Ref.get(p#msaaTargets));
                   let samples = msaa |> Option.map(snd) |> Option.getWithDefault(1);
                   let pass = RenderList.targetPass((row#width, row#height), { texture = row#texture, format = row#format, load = spec#clear },
                                                    DepthStencil.NoDepthStencil, samples, history);
                   applyHistory(paint, row#texture, slot#texture, row#format, pass#history);
                   paintInto(paint, slot#texture, msaa, row#texture, pass, frame)
               })

    /// 描き先 name へ描く frame が name の history を読むか（GL の RenderPaint.paintTarget と同じく、スプライトと面と 3D の場面のビルボードを見る）。
    pub def isHistoryReadIn(name: String, frame: RenderPaint.Frame): Bool =
        TargetTable.isHistoryRead(name, frame#sprites, frame#surfaces) or Render3d.WebGpuRenderer.readsTexture(RenderTarget.historyName(name), frame#scenes)

    /// pass を開く前の history の始末（TargetTable.historyFor の答え）を、同じ encoder へ積む。
    /// sourceId・source = 開いている描き先の slots の番号と texture（resolve 済みの 1 標本）。
    def applyHistory(paint: Paint, sourceId: Int32, source: Texture, format: RenderTarget.Format, history: PassHistory): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match history {
            case PassHistory.NoHistory           => ()
            case PassHistory.CopyTo(n)           => Map.get(n, Ref.get(p#slots)) |> Option.forEach(h -> copyInto(paint, sourceId, source, h#texture, format))
            case PassHistory.ClearTransparent(n) =>
                Map.get(n, Ref.get(p#slots)) |> Option.forEach(h -> {
                    let pass = encoderOf(paint).beginRenderPass(new RenderPassDesc("fge history").clearColor(h#texture.defaultView(), 0.0, 0.0, 0.0, 0.0));
                    pass.end();
                    Array.put(Array.get(0, p#frameCounters) + 1, 0, p#frameCounters)
                })
        }

    /// source の画素を同じ大きさの dest へ 1 画素ずつ写す pass を積む（present と同じ WGSL・blend なし）。
    // WhyNot: encoder の copyTextureToTexture で写さない — render_gl/java の WebGpu の口に足す事になり、GL の層の jar のハッシュとブラウザの実装が動く。
    def copyInto(paint: Paint, sourceId: Int32, source: Texture, dest: Texture, format: RenderTarget.Format): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let group = copyGroupOf(paint, sourceId, source);
        let pass = encoderOf(paint).beginRenderPass(new RenderPassDesc("fge history copy").loadColor(dest.defaultView()));
        pass.setPipeline(copyPipelineOf(paint, format));
        pass.setBindGroup(0, group);
        pass.draw(3, 1, 0, 0);
        pass.end();
        Array.put(Array.get(0, p#frameCounters) + 1, 0, p#frameCounters)

    /// 描き先 sourceId を写す元として読む bind group（無ければ作って控える）。
    def copyGroupOf(paint: Paint, sourceId: Int32, source: Texture): BindGroup \ IO =
        let PaintData.PaintData(p) = paint;
        match Map.get(sourceId, Ref.get(p#copyGroups)) {
            case Some(group) => group
            case None =>
                let group = p#gpu.createBindGroup(new BindGroupDesc("fge history copy", p#presentLayout).textureView(0, source.defaultView()));
                Ref.put(Map.insert(sourceId, group, Ref.get(p#copyGroups)), p#copyGroups);
                group
        }

    /// 形式 format の history へ写す pipeline（無ければ作る）。
    def copyPipelineOf(paint: Paint, format: RenderTarget.Format): RenderPipeline \ IO =
        let PaintData.PaintData(p) = paint;
        let key = WebGpuPipelines.formatCode(format);
        match Map.get(key, Ref.get(p#copyPipelines)) {
            case Some(pipeline) => pipeline
            case None =>
                let desc = new RenderPipelineDesc("fge history copy");
                discard desc.bindGroupLayout(p#presentLayout).vertex(p#presentModule, "vs_present").fragment(p#presentModule, "fs_present");
                discard desc.colorTarget(WebGpuPipelines.textureFormatOf(format));
                let pipeline = p#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, pipeline, Ref.get(p#copyPipelines)), p#copyPipelines);
                pipeline
        }

    def paintScreen(paint: Paint, frame: RenderPaint.Frame): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let size = (Array.get(0, p#frameSize), Array.get(1, p#frameSize));
        let screen = RenderList.screenPass(size, (p#designW, p#designH), p#clearColor, DepthStencil.NoDepthStencil);
        let pass = if (fillLetterbox(paint, size, screen, frame#letterbox)) RenderList.withLetterboxKept(screen) else screen;
        paintInto(paint, Array.get(0, p#frameTexture), None, 0, pass, frame)

    /// 画面の pass に余りがあり、広げる絵 letterbox が登録簿にあれば、中間の texture の全面を viewport にした pass でその絵を窓いっぱいに広げて塗り、真を返す。
    /// 塗らなかった時は偽（本編の pass が余りを黒で塗る）。GL の RenderPaint.fillLetterbox と同じ。
    def fillLetterbox(paint: Paint, size: (Int32, Int32), screen: PassSpec, letterbox: Option[String]): Bool \ IO =
        let PaintData.PaintData(p) = paint;
        let texInfo = letterbox |> Option.filter(_ -> RenderList.hasLetterbox(screen))
                                |> Option.flatMap(name -> Map.get(name, Ref.get(p#registryRef)) |> Option.map(info -> (name, info)));
        match texInfo {
            case None => false
            case Some((name, info)) =>
                let fill = RenderFrame.letterboxFillOf(size, (p#designW, p#designH), name, (info#width, info#height));
                paintIntoWith(paint, linearGroupOf(paint), Array.get(0, p#frameTexture), None, 0,
                              RenderList.fullTargetPass(size, p#clearColor, DepthStencil.NoDepthStencil), { sprites = fill :: Nil | RenderPaint.emptyFrame() });
                true
        }

    /// 最後に画面へ描いたコマを中間の texture へ描き直す（大きさが変わった時。控えも数も進めない）。続けて present を呼ぶ。
    pub def repaintLast(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        paintScreen(paint, Array.get(0, p#lastFrame))

    // ── 画面へ出す・読む・大きさ ──

    /// コマを締める。screen があれば中間の texture をそこへ写す pass を積み、encoder を submit する（surface の present は呼ぶ側）。
    pub def present(paint: Paint, screen: Option[Texture]): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match screen {
            case None => ()
            case Some(target) =>
                let pass = encoderOf(paint).beginRenderPass(new RenderPassDesc("fge present").clearColor(target.defaultView(), 0.0, 0.0, 0.0, 1.0));
                pass.setPipeline(presentPipelineOf(paint, target.format()));
                pass.setBindGroup(0, presentGroupOf(paint));
                pass.draw(3, 1, 0, 0);
                pass.end();
                Array.put(Array.get(0, p#frameCounters) + 1, 0, p#frameCounters)
        };
        submitEncoder(paint);
        warnTable(SkippedDraws.endFrame(p#skips));
        (p#scenes3d#endFrame)();
        WebGpuSurfaces.endFrame(p#surfaces, Array.get(0, p#lastFrame)#surfaces |> List.map(cmd -> GpuHandle.shaderProgramInt(cmd#program)) |> List.toSet);
        let submits = Array.get(1, p#frameCounters);
        Array.put(submits, 2, p#frameCounters);
        Array.put(0, 1, p#frameCounters);
        noteFrameSubmits(submits, p#frameCounters)

    /// 1 コマの submit の回数 submits を、counters（frameCounters の並び）の 3〜5 へ足す。
    def noteFrameSubmits(submits: Int32, counters: Array[Int32, Static]): Unit \ IO =
        Array.put(Array.get(3, counters) + 1, 3, counters);
        if (submits >= 2) Array.put(Array.get(4, counters) + 1, 4, counters) else ();
        Array.put(Int32.max(submits, Array.get(5, counters)), 5, counters)

    /// 最後に画面へ描き終えたコマの 2D の draw call の数（GL の RenderPaint.lastDraw2dCounts と同じ物差し）。
    pub def lastDraw2dCounts(paint: Paint): FrameDiagnostics.Draw2dCounts \ IO =
        let PaintData.PaintData(p) = paint;
        RenderDrawCounts.lastScreenFrame(p#drawCounts)

    /// 前のコマ（present まで）の submit の数。
    pub def submitCount(paint: Paint): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        Array.get(2, p#frameCounters)

    /// 前にこれを呼んだ後のコマ（present の数）の submit の回数を読んで数え直す。frames = コマの数・twoOrMore = submit が 2 回以上のコマの数・most = 1 コマの一番多い回数。
    /// 半分を超えるコマが 2 回以上なら、upload を staging buffer へ移す目安。
    pub def takeSubmitCounts(paint: Paint): { frames = Int32, twoOrMore = Int32, most = Int32 } \ IO =
        let PaintData.PaintData(p) = paint;
        takeSubmitCountsOf(p#frameCounters)

    /// counters（frameCounters の並び）の 3〜5 を読んで 0 に戻す。
    def takeSubmitCountsOf(counters: Array[Int32, Static]): { frames = Int32, twoOrMore = Int32, most = Int32 } \ IO =
        let counts = { frames = Array.get(3, counters), twoOrMore = Array.get(4, counters), most = Array.get(5, counters) };
        Array.put(0, 3, counters);
        Array.put(0, 4, counters);
        Array.put(0, 5, counters);
        counts

    /// 中間の texture を RGBA の生の画素で buf へ読む（幅 × 高さ × 4 バイト・GlOffscreen.readRgba と同じく下の行から）。present の後に呼ぶ。
    pub def readFrame(paint: Paint, buf: ByteBuffer): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let width = Array.get(0, p#frameSize);
        let height = Array.get(1, p#frameSize);
        let bytesPerRow = (width * 4 + 255) / 256 * 256;
        let readback = p#gpu.createBuffer("fge frame read", Int32.toInt64(bytesPerRow * height), Int32.bitwiseOr(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let encoder = p#gpu.createCommandEncoder("fge frame read");
        encoder.copyTextureToBuffer(Array.get(0, p#frameTexture), 0, 0, 0, width, height, readback, 0i64, bytesPerRow);
        p#gpu.submit(encoder.finish());
        let padded = ByteBuffer.allocateDirect(bytesPerRow * height);
        p#gpu.readBuffer(readback, 0i64, bytesPerRow * height, padded);
        readback.destroy();
        discard buf.clear();
        copyRowsFlipped(padded, bytesPerRow, buf, width * 4, height, 0)

    // WhyNot: 上の行から写さない — GlOffscreen.readRgba が下の行から返し、比べと動画の書き出し（ffmpeg の vflip）がそれを前提にしている。
    def copyRowsFlipped(src: ByteBuffer, srcRowBytes: Int32, dst: ByteBuffer, rowBytesOut: Int32, height: Int32, row: Int32): Unit \ IO =
        if (row >= height) ()
        else {
            discard dst.put(row * rowBytesOut, src, (height - 1 - row) * srcRowBytes, rowBytesOut);
            copyRowsFlipped(src, srcRowBytes, dst, rowBytesOut, height, row + 1)
        }

    /// 中間の texture を width × height で作り直す（同じなら何もしない）。
    pub def resize(paint: Paint, width: Int32, height: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        if (Array.get(0, p#frameSize) == width and Array.get(1, p#frameSize) == height) ()
        else {
            flushPending(paint);
            Array.get(0, p#frameTexture).destroy();
            Option.forEach(g -> g.release(), Ref.get(p#presentGroup));
            Ref.put(None, p#presentGroup);
            Array.put(createFrameTexture(p#gpu, width, height), 0, p#frameTexture);
            Array.put(width, 0, p#frameSize);
            Array.put(height, 1, p#frameSize)
        }

    // ── Pass ──

    /// RenderTarget.Target.beginTarget の中身。作り直すか・registry への載せ方は TargetTable が決める（標本の数が変われば作り直す）。
    def beginTarget(paint: Paint, spec: RenderTarget.TargetSpec): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        discard TargetTable.begin(webGpuTargetAllocator(paint), textureTables(paint), p#targets, (p#designW, p#designH), spec)

    /// WebGPU でレンダーターゲットを作る・捨てる関数の組。表の番号は絵の表（slots）の番号（積んだ pass があれば先に submit する）。
    def webGpuTargetAllocator(paint: Paint): TargetTable.TargetAllocator =
        { create = spec -> createTargetSlot(paint, spec), destroy = id -> dropTargetSlot(paint, id) }

    /// spec の 1 標本の texture（読む側が引く・history を写す元）を作り、標本が 2 以上なら標本つきの描き先も作って msaaTargets へ置く。
    /// 標本の数は 1 か 4（RenderList.drawSamplesOf）。頼まれた数と違う時（標本 2 を 4 で描く）は名前ごとに 1 回知らせる。
    def createTargetSlot(paint: Paint, spec: RenderTarget.TargetSpec): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        flushPending(paint);
        let format = WebGpuPipelines.textureFormatOf(spec#format);
        let texture = p#gpu.createTexture("fge pass ${spec#name}", spec#width, spec#height, format,
            Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_SRC)), 1, 1);
        let id = addSlot(paint, texture, p#nearestClamp, spec#width, spec#height);
        let samples = RenderList.drawSamplesOf(spec#samples, 1 :: 4 :: Nil);
        if (samples > 1) {
            let msaa = p#gpu.createTexture("fge pass ${spec#name} msaa", spec#width, spec#height, format, TextureUsage.RENDER_ATTACHMENT, 1, samples);
            Ref.put(Map.insert(id, (msaa, samples), Ref.get(p#msaaTargets)), p#msaaTargets)
        } else ();
        if (samples > spec#samples and spec#samples > 1) warnMsaaRounded(paint, spec#name, spec#samples, samples) else ();
        id

    /// ターゲットの texture と、あれば標本を持つ描き先を捨てる（積んだ pass があれば先に submit する）。
    def dropTargetSlot(paint: Paint, id: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        dropSlot(paint, id);
        WebGpuPipelines.dropStencil(p#pipes, () -> flushPending(paint), id);
        Map.get(id, Ref.get(p#msaaTargets)) |> Option.forEach(msaa -> {
            fst(msaa).destroy();
            Ref.put(Map.remove(id, Ref.get(p#msaaTargets)), p#msaaTargets)
        });
        Map.get(id, Ref.get(p#copyGroups)) |> Option.forEach(group -> {
            group.release();
            Ref.put(Map.remove(id, Ref.get(p#copyGroups)), p#copyGroups)
        })

    def warnMsaaRounded(paint: Paint, name: String, requested: Int32, drawn: Int32): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let key = "MSAA ${name}";
        if (Set.memberOf(key, Ref.get(p#msaaWarned))) ()
        else {
            Ref.put(Set.insert(key, Ref.get(p#msaaWarned)), p#msaaWarned);
            Log.fellBack("render-target", name, "標本 ${Int32.toString(drawn)}",
                         "WebGPU の描き先の標本は 1 か 4（標本 ${Int32.toString(requested)} は ${Int32.toString(drawn)} で描く）")
        }

    /// 描き先 fbW × fbH へ design を収めた時の倍率（黒帯の分は入れない）。
    def pixelScaleOf(paint: Paint): Float64 \ IO =
        let PaintData.PaintData(p) = paint;
        let (_, _, vpW, _) = RenderFrame.calcViewport(Array.get(0, p#frameSize), Array.get(1, p#frameSize), p#designW, p#designH);
        Int32.toFloat64(vpW) / Float64.max(1.0, p#designW)

    // ── 診断 ──

    def noteDiagnostics(paint: Paint, f: FrameDiagnostics.Diagnostics -> FrameDiagnostics.Diagnostics): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match Ref.get(p#diagnosticsRef) {
            case Some(d) => Ref.put(Some(f(d)), p#diagnosticsRef)
            case None    => ()
        }

    def consumeDiagnostics(paint: Paint): FrameDiagnostics.Diagnostics \ IO =
        let PaintData.PaintData(p) = paint;
        let draw2d = RenderDrawCounts.take(p#drawCounts);
        match Ref.get(p#diagnosticsRef) {
            case None    => FrameDiagnostics.empty()
            case Some(d) =>
                Ref.put(Some(FrameDiagnostics.empty()), p#diagnosticsRef);
                { textureUploads = List.reverse(d#textureUploads), draw2dCounts = draw2d, scene3dCounts = (p#scenes3d#takeCounts)() | d }
        }

    // ── handler ──

    /// 起動の後に出た字を fonts#grow で足す（GL と同じ数え方で glyphsAdded）。足せずに残った字（ブラウザの書き出しのアトラス・
    /// フォントに無い字・アトラスが満杯）があれば、まだ描かない物として数える。
    def ensureGlyphsIn(paint: Paint, fonts: RenderPaint.Fonts, textureName: String, codepoints: Set[Int32]): Unit \ IO =
        if (Set.isEmpty(codepoints)) ()
        else {
            RenderPaint.ensureGlyphs(fonts, textureName, codepoints);
            noteDiagnostics(paint, d -> { glyphsAdded = d#glyphsAdded + Set.size(codepoints) | d });
            let grown = Ref.get(fonts#atlases) |> Map.findLeft((_, a) -> a#textureName == textureName) |> Option.map(snd);
            let left = grown |> Option.map(a -> Set.filter(cp -> not Map.memberOf(cp, a#glyphs), codepoints)) |> Option.getWithDefault(codepoints);
            if (Set.isEmpty(left)) () else skip(paint, "起動の後に足せなかった字（${textureName}）")
        }

    /// GPU の資源を paint の登録簿で受ける。fonts = 名前 → アトラス（getFontAtlas の元。起動の後に出た字は fonts#grow で足す）。
    pub def handleGpuResources(paint: Paint, fonts: RenderPaint.Fonts, f: Unit -> a \ ef): a \ (ef - Platform.GpuResources) + IO =
        let uploads = webGpuUploads(paint);
        let tables = textureTables(paint);
        run f() with handler Platform.GpuResources {
            def initTileBuffer(instances, k) = {
                let PaintData.PaintData(p) = paint;
                k(TileTable.init(webGpuTileAllocator(paint), p#tiles, instances))
            }
            def updateTileBuffer(vaoId, instances, k) = {
                let PaintData.PaintData(p) = paint;
                k(TileTable.update(webGpuTileAllocator(paint), p#tiles, vaoId, instances))
            }
            def ensureTexture(name, key, width, height, argb, k) = {
                TextureTable.ensureTexture(uploads, tables, () -> noteDiagnostics(paint, d -> { textureUploads = name :: d#textureUploads | d }),
                                           name, key, width, height, argb);
                k(())
            }
            def ensureGlyphs(textureName, codepoints, k) = {
                ensureGlyphsIn(paint, fonts, textureName, codepoints);
                k(())
            }
            def getFontAtlas(name, k) = k(RenderPaint.fontAtlas(fonts, name))
            def getTextureInfo(name, k) = {
                let PaintData.PaintData(p) = paint;
                k(Map.get(name, Ref.get(p#registryRef)))
            }
            def buildProgram(spec, k) = {
                let PaintData.PaintData(p) = paint;
                k(GpuHandle.wrapShaderProgram(WebGpuSurfaces.buildProgram(p#surfaces, spec)))
            }
        }

    /// 2D の描き物の列を paint で描く。onScreen = 画面（Pass の外）へ描いた時に、描き始めと描き終わりの時刻（System.nanoTime）と、
    /// そのコマの 2D の draw call の数を読む口（FrameStats が行を出す時だけ読む）を受け取る。
    pub def handleDraw2d(paint: Paint, onScreen: (Int64, Int64, Unit -> FrameDiagnostics.Draw2dCounts \ IO) -> Unit \ fx,
                         f: Unit -> a \ ef): a \ (ef - Platform.Draw2d) + fx + IO =
        run f() with handler Platform.Draw2d {
            def renderCommands(sprites, tileMaps, polygons, staticLayer, k) = {
                let paintFrom = System.nanoTime();
                let toScreen = submitFrame(paint, sprites, tileMaps, polygons, staticLayer);
                let paintTo = System.nanoTime();
                noteDiagnostics(paint, d -> { submitNs = d#submitNs + (paintTo - paintFrom),
                                              drawItems = d#drawItems + List.length(sprites) | d });
                if (toScreen) {
                    let PaintData.PaintData(p) = paint;
                    onScreen(paintFrom, paintTo, () -> RenderDrawCounts.lastScreenFrame(p#drawCounts))
                } else ();
                k(())
            }
            def drawSurface(cmd, k) = {
                let PaintData.PaintData(p) = paint;
                Array.put(cmd :: Array.get(0, p#pendingSurfaces), 0, p#pendingSurfaces);
                k(())
            }
            def fillLetterbox(texture, k) = {
                let PaintData.PaintData(p) = paint;
                Array.put(Some(texture), 0, p#pendingLetterbox);
                k(())
            }
        }

    /// 3D の場面は溜めて、次の renderCommands で 2D の pass の前に描き、2D の並びに z の位置で貼る（Render3d.WebGpuRenderer・WebGpuRows）。
    /// 先に上げる物の宣言は、その場で 3D の描き手に上げさせる（Scenes.preload）。
    pub def handleDraw3d(paint: Paint, f: Unit -> a \ ef): a \ (ef - Platform.Draw3d) + IO =
        run f() with handler Platform.Draw3d {
            def drawScene3d(cmd, k) = {
                let PaintData.PaintData(p) = paint;
                Array.put(cmd :: Array.get(0, p#pendingScenes), 0, p#pendingScenes);
                k(())
            }
            def preload3d(cmd, k) = {
                Scenes.preload(paint, cmd);
                k(())
            }
        }

    /// 1 コマごとの描く側の診断を paint で集める。
    pub def handleDiagnostics(paint: Paint, f: Unit -> a \ ef): a \ (ef - Platform.Diagnostics) + IO =
        run f() with handler Platform.Diagnostics {
            def setDiagnosticsEnabled(on, k) = {
                let PaintData.PaintData(p) = paint;
                Ref.put(if (on) Some(FrameDiagnostics.empty()) else None, p#diagnosticsRef);
                k(())
            }
            def consumeDiagnostics(k) = k(consumeDiagnostics(paint))
        }

    /// Pass の切り替えを paint で受ける。
    pub def handleTarget(paint: Paint, f: Unit -> a \ ef): a \ (ef - RenderTarget.Target) + IO =
        run f() with handler RenderTarget.Target {
            def beginTarget(spec, k) = {
                beginTarget(paint, spec);
                k(())
            }
            def endTarget(k) = {
                let PaintData.PaintData(p) = paint;
                discard TargetTable.end(p#targets);
                k(())
            }
            def pixelScale(k) = k(pixelScaleOf(paint))
        }
}
