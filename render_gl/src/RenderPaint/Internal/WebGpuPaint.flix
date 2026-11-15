// RenderPaint.Internal.WebGpuPaint — 塗りのコア（RenderPaint と RenderPaintHandlers）の WebGPU の分。2D のスプライト・字・箱と、
// 絵とフォントのアトラスを上げる・Pass を 1 つ挟む・中間の texture から画面へ写す、だけを持つ。
// コマは中間の texture（RGBA8・描き先の画素の大きさ）へ描き、present で画面の texture へ 1 回写す。encoder はコマに 1 つで、submit はコマの終わり。
// ただし、そのコマに積んだ pass があるうちに絵を作る・書き替える・捨てる・Pass の texture を作り直す・instance buffer を伸ばす時は、先に submit する
// （そのままだと、前に積んだ pass が新しい絵で描かれ、捨てた物を指したまま submit することになる）。
// V1 で描かない物（多角形・タイルの層・static layer・面・3D の場面・mask つきスプライト・MSAA・起動の後に足す字）は名前ごとに 1 回知らせて捨てる。
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
    import fge.webgpu.FilterMode
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
    import fge.webgpu.VertexFormat
    import fge.webgpu.WebGpu
    import java.lang.System
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.FloatBuffer
    use RenderFrame.Internal.RenderList
    use RenderFrame.Internal.RenderList.{DepthStencil, PassSpec}
    use RenderFrame.Internal.WebGpuRows
    use RenderPaint.Internal.TextureTable
    use RenderPaint.Internal.WebGpuShader

    /// 絵の表の 1 枚（番号 → texture と、それを読む bind group）。
    type alias TextureSlot = { texture = Texture, group = BindGroup, width = Int32, height = Int32 }

    /// Pass の描き先 1 枚。id = 絵の表の番号（本編が Render.sprite(name) で読む）。
    type alias TargetSlot = { id = Int32, texture = Texture, format = RenderTarget.Format, width = Int32, height = Int32 }

    /// 塗りのコアの状態。作るのは create だけ。
    enum PaintData {
        case PaintData({
            gpu = WebGpu,
            designW = Float64,
            designH = Float64,
            clearColor = Color,
            spriteModule = ShaderModule,
            presentModule = ShaderModule,
            frameLayout = BindGroupLayout,
            imageLayout = BindGroupLayout,
            presentLayout = BindGroupLayout,
            uniform = Buffer,
            frameGroup = BindGroup,
            // 鍵 = blend の番号 × 2 + 形式（0 = RGBA8_UNORM・1 = RGBA16_FLOAT）。
            pipelines = Ref[Map[Int32, RenderPipeline], Static],
            // 画面の形式と、中間の texture を写す pipeline。
            presentPipeline = Ref[Option[(TextureFormat, RenderPipeline)], Static],
            // 中間の texture を読む bind group（中間の texture を作り直したら作り直す）。
            presentGroup = Ref[Option[BindGroup], Static],
            nearestRepeat = Sampler,
            linearRepeat = Sampler,
            nearestClamp = Sampler,
            // 1 × 1 の透明な黒（pass の頭で group 1 に付けておく）。
            blank = TextureSlot,
            slots = Ref[Map[Int32, TextureSlot], Static],
            nextSlot = Array[Int32, Static],
            registryRef = Ref[RenderAsset.TextureRegistry, Static],
            textureKeyRef = Ref[Map[String, String], Static],
            targetsRef = Ref[Map[String, TargetSlot], Static],
            activeTarget = Array[Option[RenderTarget.TargetSpec], Static],
            // instance buffer（GPU）・その大きさ（体数）・このコマで次に空いている位置（体）。
            instanceBuffer = Array[Buffer, Static],
            instanceCounts = Array[Int32, Static],
            // instance の入れ物（CPU）。bytes と、その float の見方。
            cpuBytes = Array[ByteBuffer, Static],
            cpuFloats = Array[FloatBuffer, Static],
            // 多角形の頂点の入れ物（CPU）。WebGPU の行に多角形がまだ無いので空のまま貸す。
            cpuVertices = FloatBuffer,
            // 中間の texture と、その画素の大きさ（幅・高さ）。
            frameTexture = Array[Texture, Static],
            frameSize = Array[Int32, Static],
            encoder = Array[Option[CommandEncoder], Static],
            // 0 = 今の encoder に積んだ pass の数・1 = このコマの submit の数・2 = 前のコマの submit の数・
            // 3〜5 = takeSubmitCounts の後のコマの数・そのうち submit が 2 回以上のコマの数・1 コマの submit の一番多い回数。
            frameCounters = Array[Int32, Static],
            lastFrame = Array[RenderPaint.Frame, Static],
            texWarnLog = Ref[Set[String], Static],
            skipped = Ref[Set[String], Static],
            diagnosticsRef = Ref[Option[FrameDiagnostics.Diagnostics], Static],
            drawCounts = RenderDrawCounts.Holder
        })
    }

    pub type alias Paint = PaintData

    /// instance の 1 体のバイト数（RenderFrame.writeInstAt の float の並び）。
    def instanceBytes(): Int32 = 4 * RenderList.instanceFloats()

    /// device の上に pipeline・buffer・中間の texture・組み込みの絵（起動画面の字とロゴ・Render.lightAt と darkAt の絵）を作る。
    /// design = 射影の寸・clearColor = design の中の地の色・width × height = 中間の texture の画素の大きさ。
    pub def create(gpu: WebGpu, cfg: { designWidth = Int32, designHeight = Int32, clearColor = Color, width = Int32, height = Int32 }): Paint \ IO =
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
        let blankTexture = gpu.createTexture("fge blank", 1, 1, TextureFormat.RGBA8_UNORM,
                                             Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST), 1, 1);
        gpu.writeTexture(blankTexture, 0, 0, 0, 1, 1, ByteBuffer.allocateDirect(4), 0, 4);
        let blankDesc = new BindGroupDesc("fge blank", imageLayout);
        discard blankDesc.textureView(0, blankTexture.defaultView()).sampler(1, nearestRepeat);
        let blank = { texture = blankTexture, width = 1, height = 1, group = gpu.createBindGroup(blankDesc) };
        let firstCount = 4096;
        let bytes = ByteBuffer.allocateDirect(firstCount * instanceBytes()).order(ByteOrder.LITTLE_ENDIAN);
        let paint = PaintData.PaintData({
            gpu = gpu, designW = designW, designH = designH, clearColor = cfg#clearColor,
            spriteModule = gpu.createShaderModule("fge sprite", WebGpuShader.spriteWgsl()),
            presentModule = gpu.createShaderModule("fge present", WebGpuShader.presentWgsl()),
            frameLayout = frameLayout, imageLayout = imageLayout, presentLayout = presentLayout,
            uniform = uniform, frameGroup = frameGroup,
            pipelines = Ref.fresh(Static, Map.empty()), presentPipeline = Ref.fresh(Static, None),
            presentGroup = Ref.fresh(Static, None),
            nearestRepeat = nearestRepeat, linearRepeat = linearRepeat, nearestClamp = nearestClamp,
            blank = blank, slots = Ref.fresh(Static, Map.empty()), nextSlot = Array#{1} @ Static,
            registryRef = Ref.fresh(Static, Map.empty()), textureKeyRef = Ref.fresh(Static, Map.empty()),
            targetsRef = Ref.fresh(Static, Map.empty()), activeTarget = Array#{(None: Option[RenderTarget.TargetSpec])} @ Static,
            instanceBuffer = Array#{createInstanceBuffer(gpu, firstCount)} @ Static,
            instanceCounts = Array#{firstCount, 0} @ Static,
            cpuBytes = Array#{bytes} @ Static, cpuFloats = Array#{bytes.asFloatBuffer()} @ Static,
            cpuVertices = FloatBuffer.allocate(0),
            frameTexture = Array#{createFrameTexture(gpu, cfg#width, cfg#height)} @ Static,
            frameSize = Array#{cfg#width, cfg#height} @ Static,
            encoder = Array#{(None: Option[CommandEncoder])} @ Static,
            frameCounters = Array#{0, 0, 0, 0, 0, 0} @ Static,
            lastFrame = Array#{RenderPaint.emptyFrame()} @ Static,
            texWarnLog = Ref.fresh(Static, Set.empty()), skipped = Ref.fresh(Static, Set.empty()),
            diagnosticsRef = Ref.fresh(Static, None), drawCounts = RenderDrawCounts.fresh()
        });
        // 起動の時に作る pipeline（RGBA8 の 3 本）。RGBA16_FLOAT は初めて要る Pass で作る。
        List.forEach(b -> discard pipelineOf(paint, b, RenderTarget.Format.Rgba8Unorm), 0 :: 1 :: 2 :: Nil);
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

    def createInstanceBuffer(gpu: WebGpu, count: Int32): Buffer \ IO =
        gpu.createBuffer("fge instances", Int32.toInt64(count * instanceBytes()), Int32.bitwiseOr(BufferUsage.VERTEX, BufferUsage.COPY_DST))

    def createFrameTexture(gpu: WebGpu, width: Int32, height: Int32): Texture \ IO =
        gpu.createTexture("fge frame", Int32.max(1, width), Int32.max(1, height), TextureFormat.RGBA8_UNORM,
                          Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_SRC)), 1, 1)

    // ── pipeline ──

    def formatCode(format: RenderTarget.Format): Int32 = match format {
        case RenderTarget.Format.Rgba8Unorm  => 0
        case RenderTarget.Format.Rgba16Float => 1
    }

    def textureFormatOf(format: RenderTarget.Format): TextureFormat = match format {
        case RenderTarget.Format.Rgba8Unorm  => TextureFormat.RGBA8_UNORM
        case RenderTarget.Format.Rgba16Float => TextureFormat.RGBA16_FLOAT
    }

    /// blend の番号（RenderFrame.blendCode）と描き先の形式の pipeline（無ければ作る）。
    def pipelineOf(paint: Paint, blendC: Int32, format: RenderTarget.Format): RenderPipeline \ IO =
        let PaintData.PaintData(p) = paint;
        let key = blendC * 2 + formatCode(format);
        match Map.get(key, Ref.get(p#pipelines)) {
            case Some(pipeline) => pipeline
            case None =>
                let pipeline = buildPipeline(paint, blendC, textureFormatOf(format));
                Ref.put(Map.insert(key, pipeline, Ref.get(p#pipelines)), p#pipelines);
                pipeline
        }

    /// glBlendFunc と同じ因子を色と alpha の両方に書く。Normal = (src-alpha, 1 − src-alpha)・Add = (src-alpha, 1)・Multiply = (dst, 1 − src-alpha)。
    def buildPipeline(paint: Paint, blendC: Int32, format: TextureFormat): RenderPipeline \ IO =
        let PaintData.PaintData(p) = paint;
        let (src, dst, entry) =
            if (blendC == 1) (BlendFactor.SRC_ALPHA, BlendFactor.ONE, "fs_main")
            else if (blendC == 2) (BlendFactor.DST, BlendFactor.ONE_MINUS_SRC_ALPHA, "fs_multiply")
            else (BlendFactor.SRC_ALPHA, BlendFactor.ONE_MINUS_SRC_ALPHA, "fs_main");
        let desc = new RenderPipelineDesc("fge sprite ${entry} ${Int32.toString(blendC)}");
        discard desc.bindGroupLayout(p#frameLayout).bindGroupLayout(p#imageLayout);
        discard desc.vertex(p#spriteModule, "vs_main").fragment(p#spriteModule, entry);
        discard desc.vertexBuffer(instanceBytes(), true);
        discard desc.attribute(VertexFormat.FLOAT32X4, 0, 1).attribute(VertexFormat.FLOAT32X2, 16, 2);
        discard desc.attribute(VertexFormat.FLOAT32X4, 24, 3).attribute(VertexFormat.FLOAT32X4, 40, 4);
        discard desc.attribute(VertexFormat.FLOAT32X4, 56, 5).attribute(VertexFormat.FLOAT32X4, 72, 6);
        discard desc.attribute(VertexFormat.FLOAT32X4, 88, 7).attribute(VertexFormat.FLOAT32X4, 104, 8);
        discard desc.attribute(VertexFormat.FLOAT32X4, 120, 9).attribute(VertexFormat.FLOAT32X4, 136, 10);
        discard desc.colorTarget(format).blend(src, dst, BlendOperation.ADD, src, dst, BlendOperation.ADD);
        p#gpu.createRenderPipeline(desc)

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

    /// ARGB の int の列を little-endian のバイトにする。
    // WhyNot: 1 要素ずつ put しない — Flix の Vector は JVM の int[] のままで、1 回で写せる（RenderTexture.withArgbBuffer と同じ）。
    def argbBytes(argb: Vector[Int32]): ByteBuffer \ IO =
        let arr = unchecked_cast(argb as Array[Int32, Static]);
        let bytes = ByteBuffer.allocateDirect(Int32.max(4, Vector.length(argb) * 4)).order(ByteOrder.LITTLE_ENDIAN);
        discard bytes.asIntBuffer().put(arr);
        bytes

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
        Array.put(None, 0, p#encoder);
        Map.forEach((_, slot) -> { slot#group.release(); slot#texture.destroy() }, Ref.get(p#slots));
        Ref.put(Map.empty(), p#slots);
        Ref.put(Map.empty(), p#targetsRef);
        p#blank#group.release();
        p#blank#texture.destroy();
        Option.forEach(g -> g.release(), Ref.get(p#presentGroup));
        Ref.put(None, p#presentGroup);
        Option.forEach(fp -> snd(fp).release(), Ref.get(p#presentPipeline));
        Ref.put(None, p#presentPipeline);
        Map.forEach((_, pipeline) -> pipeline.release(), Ref.get(p#pipelines));
        Ref.put(Map.empty(), p#pipelines);
        Array.get(0, p#frameTexture).destroy();
        Array.get(0, p#instanceBuffer).destroy();
        p#frameGroup.release();
        p#uniform.destroy();
        p#nearestRepeat.release();
        p#linearRepeat.release();
        p#nearestClamp.release();
        p#frameLayout.release();
        p#imageLayout.release();
        p#presentLayout.release();
        p#spriteModule.release();
        p#presentModule.release()

    /// 1 枚を名前で置く（同じ名前は置き換える）。
    pub def putTexture(name: String, info: RenderAsset.TextureInfo, paint: Paint): Unit \ IO =
        TextureTable.putTexture(textureTables(paint), name, info)

    /// 絵の CPU の側の表。
    def textureTables(paint: Paint): TextureTable.Tables =
        let PaintData.PaintData(p) = paint;
        { registryRef = p#registryRef, textureKeyRef = p#textureKeyRef }

    /// WebGPU で絵を上げる関数の組（どれも、そのコマに積んだ pass があれば先に submit する）。
    def webGpuUploads(paint: Paint): TextureTable.Uploads =
        { createArgb = (width, height, argb) -> uploadBgra(paint, width, height, argb),
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

    /// 今の encoder を submit する（無ければ何もしない）。instance buffer は頭から使い直せる（queue の書き込みは submit の順に並ぶ）。
    def submitEncoder(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        match Array.get(0, p#encoder) {
            case None => ()
            case Some(e) =>
                p#gpu.submit(e.finish());
                Array.put(None, 0, p#encoder);
                Array.put(0, 0, p#frameCounters);
                Array.put(Array.get(1, p#frameCounters) + 1, 1, p#frameCounters);
                Array.put(0, 1, p#instanceCounts)
        }

    /// このコマに積んだ pass があれば submit する（絵や buffer を作る・書く・捨てる前に呼ぶ）。
    def flushPending(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        if (Array.get(0, p#frameCounters) > 0) submitEncoder(paint) else ()

    // ── 1 回の renderCommands ──

    /// n 体ぶん書ける instance の入れ物（CPU）。足りなければ倍に作り直す。
    def instancesFor(paint: Paint, n: Int32): FloatBuffer \ IO =
        let PaintData.PaintData(p) = paint;
        let bytes = Array.get(0, p#cpuBytes);
        if (bytes.capacity() >= n * instanceBytes()) Array.get(0, p#cpuFloats)
        else {
            let raw = ByteBuffer.allocateDirect(Int32.max(n, 2 * bytes.capacity() / instanceBytes()) * instanceBytes());
            let grown = raw.order(ByteOrder.LITTLE_ENDIAN);
            let floats = grown.asFloatBuffer();
            Array.put(grown, 0, p#cpuBytes);
            Array.put(floats, 0, p#cpuFloats);
            floats
        }

    /// 入れ物の頭 n 体を GPU の instance buffer の空いている所へ送り、送った位置（体）を返す。
    /// 足りなければ先に submit し（頭から使い直せる）、それでも足りなければ buffer を伸ばす。
    def sendInstances(paint: Paint, n: Int32): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        if (Array.get(1, p#instanceCounts) + n > Array.get(0, p#instanceCounts)) flushPending(paint) else ();
        let capacity = Array.get(0, p#instanceCounts);
        if (n > capacity) {
            let grown = Int32.max(n, 2 * capacity);
            Array.get(0, p#instanceBuffer).destroy();
            Array.put(createInstanceBuffer(p#gpu, grown), 0, p#instanceBuffer);
            Array.put(grown, 0, p#instanceCounts)
        } else ();
        let base = Array.get(1, p#instanceCounts);
        if (n > 0) p#gpu.writeBuffer(Array.get(0, p#instanceBuffer), Int32.toInt64(base * instanceBytes()),
                                     Array.get(0, p#cpuBytes), 0, n * instanceBytes()) else ();
        Array.put(base + n, 1, p#instanceCounts);
        base

    /// texture の render pass を op で始末して開き、group 0・空の絵・instance buffer を付ける。
    def openPass(paint: Paint, texture: Texture, n: Int32, op: RenderTarget.LoadOp): (RenderPass, Int32) \ IO =
        let PaintData.PaintData(p) = paint;
        let base = sendInstances(paint, n);
        let view = texture.defaultView();
        let desc = match op {
            case RenderTarget.LoadOp.Clear(c)         => new RenderPassDesc("fge pass").clearColor(view, c#r, c#g, c#b, 1.0)
            case RenderTarget.LoadOp.ClearTransparent => new RenderPassDesc("fge pass").clearColor(view, 0.0, 0.0, 0.0, 0.0)
            case RenderTarget.LoadOp.Keep             => new RenderPassDesc("fge pass").loadColor(view)
        };
        let pass = encoderOf(paint).beginRenderPass(desc);
        Array.put(Array.get(0, p#frameCounters) + 1, 0, p#frameCounters);
        pass.setBindGroup(0, p#frameGroup);
        pass.setBindGroup(1, p#blank#group);
        let buffer = Array.get(0, p#instanceBuffer);
        pass.setVertexBuffer(0, buffer, 0i64, buffer.size());
        (pass, base)

    /// sprites を texture へ描く。pass = 描き先の指定（画面は中間の texture・Pass はその texture）。
    def paintInto(paint: Paint, texture: Texture, pass: PassSpec, sprites: List[RenderType.Drawable]): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        // WhyNot: 画面の形式を描き先に問わない — 画面は中間の texture（RGBA8）へ描き、present で画面の形式へ写す。
        let format = RenderList.targetFormatOf(pass) |> Option.getWithDefault(RenderTarget.Format.Rgba8Unorm);
        WebGpuRows.renderFrame({
            sprites = sprites, registry = Ref.get(p#registryRef),
            designW = p#designW, designH = p#designH, pass = pass,
            texWarnLog = p#texWarnLog, drawCounts = p#drawCounts,
            instancesFor = n -> instancesFor(paint, n),
            verticesFor = _ -> checked_ecast(p#cpuVertices),
            openPass = (n, op) -> openPass(paint, texture, n, op),
            setPipeline = (pass1, blendC) -> pass1.setPipeline(pipelineOf(paint, blendC, format)),
            setTexture = (pass1, id) -> pass1.setBindGroup(1, groupOf(paint, id)),
            skip = name -> skip(paint, name)
        })

    def groupOf(paint: Paint, id: Int32): BindGroup \ IO =
        let PaintData.PaintData(p) = paint;
        Map.get(id, Ref.get(p#slots)) |> Option.map(slot -> slot#group) |> Option.getWithDefault(p#blank#group)

    /// V1 で描かない物 name を、名前ごとに初めの 1 回だけ知らせる。
    def skip(paint: Paint, name: String): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let seen = Ref.get(p#skipped);
        if (Set.memberOf(name, seen)) ()
        else {
            Ref.put(Set.insert(name, seen), p#skipped);
            Log.warn("[webgpu] V1 では描かない: ${name}")
        }

    /// Draw2d.renderCommands の中身。Pass が開いていればそこへ描いて false。開いていなければ中間の texture へ描き、控えを置いて true。
    def submitFrame(paint: Paint, sprites: List[RenderType.Drawable], tileMaps: List[RenderType.TileMapRenderCmd],
                    polygons: List[RenderType.PolygonCmd], staticLayer: Option[GameEngine.StaticLayerCmd]): Bool \ IO =
        let PaintData.PaintData(p) = paint;
        if (List.isEmpty(tileMaps)) () else skip(paint, "タイルの層");
        if (List.isEmpty(polygons)) () else skip(paint, "多角形");
        if (Option.isEmpty(staticLayer)) () else skip(paint, "static layer");
        match Array.get(0, p#activeTarget) {
            case Some(spec) =>
                paintTarget(paint, spec, sprites);
                false
            case None =>
                let frame = { sprites = sprites, tileMaps = tileMaps, polygons = polygons, staticLayer = staticLayer | RenderPaint.emptyFrame() };
                Array.put(frame, 0, p#lastFrame);
                paintScreen(paint, sprites);
                RenderDrawCounts.endScreenFrame(p#drawCounts);
                if (Option.isEmpty(Ref.get(p#diagnosticsRef))) RenderDrawCounts.discardTotal(p#drawCounts) else ();
                true
        }

    /// 開いている Pass の texture へ描く（表に無い名前なら何もしない）。
    def paintTarget(paint: Paint, spec: RenderTarget.TargetSpec, sprites: List[RenderType.Drawable]): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        Map.get(spec#name, Ref.get(p#targetsRef))
            |> Option.forEach(t -> paintInto(paint, t#texture,
                   RenderList.targetPass((t#width, t#height), { texture = t#id, format = t#format, load = spec#clear, resolveTo = None },
                                         DepthStencil.NoDepthStencil, 1), sprites))

    def paintScreen(paint: Paint, sprites: List[RenderType.Drawable]): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        let size = (Array.get(0, p#frameSize), Array.get(1, p#frameSize));
        paintInto(paint, Array.get(0, p#frameTexture),
                  RenderList.screenPass(size, (p#designW, p#designH), p#clearColor, DepthStencil.NoDepthStencil), sprites)

    /// 最後に画面へ描いたコマを中間の texture へ描き直す（大きさが変わった時。控えも数も進めない）。続けて present を呼ぶ。
    pub def repaintLast(paint: Paint): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        paintScreen(paint, Array.get(0, p#lastFrame)#sprites)

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
        let submits = Array.get(1, p#frameCounters);
        Array.put(submits, 2, p#frameCounters);
        Array.put(0, 1, p#frameCounters);
        noteFrameSubmits(submits, p#frameCounters)

    /// 1 コマの submit の回数 submits を、counters（frameCounters の並び）の 3〜5 へ足す。
    def noteFrameSubmits(submits: Int32, counters: Array[Int32, Static]): Unit \ IO =
        Array.put(Array.get(3, counters) + 1, 3, counters);
        if (submits >= 2) Array.put(Array.get(4, counters) + 1, 4, counters) else ();
        Array.put(Int32.max(submits, Array.get(5, counters)), 5, counters)

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

    /// RenderTarget.Target.beginTarget の中身。表に無いか形が違えば texture を作り、登録簿に design の大きさで載せ、開いている Pass として控える。
    def beginTarget(paint: Paint, spec: RenderTarget.TargetSpec): Unit \ IO =
        let PaintData.PaintData(p) = paint;
        if (spec#samples > 1) skip(paint, "MSAA（標本 2 以上は 1 で描く）") else ();
        let slot = match Map.get(spec#name, Ref.get(p#targetsRef)) {
            case Some(t) if t#width == spec#width and t#height == spec#height and t#format == spec#format => t
            case old =>
                Option.forEach(t -> dropSlot(paint, t#id), old);
                flushPending(paint);
                let texture = p#gpu.createTexture("fge pass ${spec#name}", spec#width, spec#height, textureFormatOf(spec#format),
                    Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_SRC)), 1, 1);
                let fresh = { id = addSlot(paint, texture, p#nearestClamp, spec#width, spec#height), texture = texture,
                              format = spec#format, width = spec#width, height = spec#height };
                Ref.put(Map.insert(spec#name, fresh, Ref.get(p#targetsRef)), p#targetsRef);
                fresh
        };
        putTexture(spec#name, { id = GpuHandle.wrapTextureId(slot#id), width = p#designW, height = p#designH }, paint);
        Array.put(Some(spec), 0, p#activeTarget)

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
                { textureUploads = List.reverse(d#textureUploads), draw2dCounts = draw2d | d }
        }

    // ── handler ──

    /// GPU の資源を paint の登録簿で受ける。fonts = 名前 → アトラス（getFontAtlas の元。足す字は V1 では足さず、フォントごとに 1 回知らせる）。
    pub def handleGpuResources(paint: Paint, fonts: RenderPaint.Fonts, f: Unit -> a \ ef): a \ (ef - Platform.GpuResources) + IO =
        let uploads = webGpuUploads(paint);
        let tables = textureTables(paint);
        run f() with handler Platform.GpuResources {
            def initTileBuffer(_instances, k) = {
                skip(paint, "タイルの層");
                k((GpuHandle.wrapTileVao(0), 0))
            }
            def updateTileBuffer(vaoId, _instances, k) = {
                skip(paint, "タイルの層");
                k((vaoId, 0))
            }
            def ensureTexture(name, key, width, height, argb, k) = {
                TextureTable.ensureTexture(uploads, tables, () -> noteDiagnostics(paint, d -> { textureUploads = name :: d#textureUploads | d }),
                                           name, key, width, height, argb);
                k(())
            }
            def ensureGlyphs(textureName, codepoints, k) = {
                if (Set.isEmpty(codepoints)) () else skip(paint, "起動の後に足す字（${textureName}）");
                k(())
            }
            def getFontAtlas(name, k) = k(RenderPaint.fontAtlas(fonts, name))
            def getTextureInfo(name, k) = {
                let PaintData.PaintData(p) = paint;
                k(Map.get(name, Ref.get(p#registryRef)))
            }
            def buildProgram(_spec, k) = {
                skip(paint, "面（ShaderDoc）");
                k(GpuHandle.wrapShaderProgram(0))
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
            def drawSurface(_cmd, k) = {
                skip(paint, "面（ShaderDoc）");
                k(())
            }
        }

    /// 3D の場面は V1 では描かない（1 回知らせて捨てる）。
    pub def handleDraw3d(paint: Paint, f: Unit -> a \ ef): a \ (ef - Platform.Draw3d) + IO =
        run f() with handler Platform.Draw3d {
            def drawScene3d(_cmd, k) = {
                skip(paint, "3D の場面");
                k(())
            }
            def preload3d(_cmd, k) = {
                skip(paint, "3D の場面");
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
                Array.put(None, 0, p#activeTarget);
                k(())
            }
            def pixelScale(k) = k(pixelScaleOf(paint))
        }
}
