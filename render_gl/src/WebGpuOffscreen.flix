// WebGpuOffscreen — ウィンドウを使わず WebGPU の texture へ描いて読む session（GlOffscreen の WebGPU 版の土台）。
// 持つのは device・描き先・読み戻し・式の行の突き合わせ（塗りのコア RenderPaint は持たない）。
// device は GpuDevice の handler が開く（PC は WebGpuOffscreen.runDawn・ブラウザは WebLayer.runWebGpu）。session を使うコードは PC とブラウザで同じ。
//
// 使い方（open から close まで同じ糸で呼ぶ）:
//   run {
//       match WebGpuOffscreen.open({ width = 320, height = 180 }) {
//           case Err(why)    => WebGPU の無い所（SoftRaster か GL の道へ）
//           case Ok(session) =>
//               WebGpuOffscreen.gpuOf(session) と targetOf(session) で描く;
//               WebGpuOffscreen.readRgba(session, buf);
//               WebGpuOffscreen.close(session)
//       }
//   } with WebGpuOffscreen.runDawn
//
// WhyNot: GLFW の隠しウィンドウの surface に描かない — 隠したウィンドウでも画面に出す待ち（約 8 ms）が毎コマ入り、描き出しが遅くなる。
// WhyNot: open の中で実装（Dawn か JSO）を選ばない — ブラウザの書き出しに Dawn の JNI が、PC に JSO が届く。選ぶのは入口で差す handler の 1 か所。
pub mod WebGpuOffscreen {
    import fge.webgpu.AddressMode
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.Buffer
    import fge.webgpu.BufferBindingType
    import fge.webgpu.BufferUsage
    import fge.webgpu.FilterMode
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.Sampler
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.WebGpu
    import fge.webgpu.dawn.DawnWebGpu
    import java.lang.Throwable
    import java.nio.ByteBuffer
    import java.nio.ByteOrder

    /// 開いた 1 本。外から作らせない（open だけが作る）。
    /// target = 描き先（RGBA8）・readback = 読み戻しの置き場（行は 256 バイトにそろえる）・padded = readback を写す CPU の側。
    enum SessionData {
        case SessionData({
            gpu = WebGpu,
            target = Texture,
            readback = Buffer,
            padded = ByteBuffer,
            width = Int32,
            height = Int32
        })
    }

    pub type alias Session = SessionData

    /// WebGPU の device を取る口。handler が機種ごとの実装を開く（PC は runDawn・ブラウザは WebLayer.runWebGpu）。
    pub eff GpuDevice {
        /// device を開く。開けなければ Err(理由)。開いた device は呼び手が持ち、destroy する。
        def requestDevice(): Result[String, WebGpu]
    }

    /// GpuDevice を Dawn（PC・ネイティブは既定の置き場）で受ける。
    pub def runDawn(f: Unit -> a \ ef): a \ (ef - GpuDevice) + IO =
        run f() with handler GpuDevice {
            def requestDevice(k) = k(openDawn())
        }

    def openDawn(): Result[String, WebGpu] \ IO =
        try {
            let gpu: WebGpu = checked_cast(DawnWebGpu.open(""));
            Ok(gpu)
        } catch {
            case e: Throwable => Err("WebGPU の device を開けない: ${e.toString()}")
        }

    /// device を取り、width × height の RGBA8 の描き先を作る。device を開けない・大きさが 1 から device の 2D の上限の外なら Err(理由)。
    pub def open(cfg: { width = Int32, height = Int32 }): Result[String, Session] \ IO + GpuDevice =
        GpuDevice.requestDevice() |> Result.flatMap(gpu -> sized(gpu, cfg))

    /// 大きさが device の 2D の上限の内なら描き先を作る。外なら device を捨てて Err。
    def sized(gpu: WebGpu, cfg: { width = Int32, height = Int32 }): Result[String, Session] \ IO =
        let largest = gpu.limits().maxTextureDimension2D();
        if (cfg#width < 1 or cfg#height < 1 or cfg#width > largest or cfg#height > largest) {
            gpu.destroy();
            Err("描き先の大きさ ${cfg#width}x${cfg#height} は 1〜${largest} の外")
        } else Ok(withDevice(gpu, cfg))

    /// 開いた device の上に描き先を作る（device を作り直した後に session を組み直す時に使う）。
    pub def withDevice(gpu: WebGpu, cfg: { width = Int32, height = Int32 }): Session \ IO =
        let bytesPerRow = rowBytes(cfg#width * 4);
        let size = bytesPerRow * cfg#height;
        let target = gpu.createTexture("fge offscreen", cfg#width, cfg#height, TextureFormat.RGBA8_UNORM,
                                       Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, Int32.bitwiseOr(TextureUsage.COPY_SRC, TextureUsage.TEXTURE_BINDING)), 1, 1);
        let readback = gpu.createBuffer("fge offscreen readback", Int32.toInt64(size), Int32.bitwiseOr(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        SessionData.SessionData({ gpu = gpu, target = target, readback = readback,
                                  padded = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN),
                                  width = cfg#width, height = cfg#height })

    /// session の device。
    pub def gpuOf(session: Session): WebGpu =
        let SessionData.SessionData(s) = session;
        s#gpu

    /// session の描き先（RGBA8・RENDER_ATTACHMENT と COPY_SRC と TEXTURE_BINDING）。
    pub def targetOf(session: Session): Texture =
        let SessionData.SessionData(s) = session;
        s#target

    /// 描き先の画素の大きさ。
    pub def sizeOf(session: Session): (Int32, Int32) =
        let SessionData.SessionData(s) = session;
        (s#width, s#height)

    /// 描き先を捨て、device も捨てる。
    pub def close(session: Session): Unit \ IO =
        let SessionData.SessionData(s) = session;
        s#target.destroy();
        s#readback.destroy();
        s#gpu.destroy()

    /// copyTextureToBuffer の 1 行のバイト数（256 の倍数）。
    def rowBytes(bytes: Int32): Int32 = (bytes + 255) / 256 * 256

    /// 描き先を RGBA の生の画素で buf へ読む（width × height × 4 バイト・GlOffscreen.readRgba と同じく下の行から）。
    /// submit した描きが終わるまで待つ。buf は呼ぶ側が持ち回す。
    pub def readRgba(session: Session, buf: ByteBuffer): Unit \ IO =
        let SessionData.SessionData(s) = session;
        let bytesPerRow = rowBytes(s#width * 4);
        let encoder = s#gpu.createCommandEncoder("fge offscreen read");
        encoder.copyTextureToBuffer(s#target, 0, 0, 0, s#width, s#height, s#readback, 0i64, bytesPerRow);
        s#gpu.submit(encoder.finish());
        s#gpu.readBuffer(s#readback, 0i64, bytesPerRow * s#height, s#padded);
        discard buf.clear();
        copyRowsFlipped(s#padded, bytesPerRow, buf, s#width * 4, s#height, 0)

    // WhyNot: 上の行から写さない — GlOffscreen.readRgba が下の行から返し、動画の書き出し（ffmpeg の vflip）がそれを前提にしている。
    def copyRowsFlipped(src: ByteBuffer, srcRowBytes: Int32, dst: ByteBuffer, rowBytesOut: Int32, height: Int32, row: Int32): Unit \ IO =
        if (row >= height) ()
        else {
            discard dst.put(row * rowBytesOut, src, (height - 1 - row) * srcRowBytes, rowBytesOut);
            copyRowsFlipped(src, srcRowBytes, dst, rowBytesOut, height, row + 1)
        }

    // ── 式の行の突き合わせ ──────────────────────────────

    /// 画面いっぱいの三角形 1 枚（頂点の属性は読まない）。
    def rowVertexSource(): String =
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    let corner = vec2f(f32((i & 1u) * 4u) - 1.0, f32((i & 2u) * 2u) - 1.0);\n" +
        "    return vec4f(corner, 0.0, 1.0);\n" +
        "}\n"

    /// fragment（WGSL・`@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f`）を width × 1 の RGBA32F の描き先へ
    /// uniform の組ごとに 1 回ずつ塗り、組ごとに画素の rgba を左から width × 4 個の Float32 で読み返す（GlOffscreen.drawFloatRows の WebGPU 版）。
    /// uniform の組は WGSL の struct の並び（16 バイトそろえ）に詰めた Float32 の列で、`@group(0) @binding(0) var<uniform>` に入る。
    /// textures の k 番目は binding 1 + 2k（texture_2d<f32>）と 2 + 2k（sampler）（sampler の名前は見ない）。
    /// Float32Rgba の絵は rgba32float で上げるので、linear は Err（float32-filterable を求めていない）。組めなければ Err(理由)。
    pub def drawFloatRows(session: Session, fragment: String, width: Int32, textures: List[GlOffscreen.RowTexture],
                          uniformSets: List[Vector[Float32]]): Result[String, List[Vector[Float32]]] \ IO =
        let gpu = gpuOf(session);
        let linearFloat = textures |> List.exists(t -> t#linear and isFloatTexture(t));
        if (linearFloat) Err("rgba32float の絵は linear で読めない（float32-filterable を求めていない）")
        else {
            let errorsBefore = gpu.errorCount();
            let module = gpu.createShaderModule("fge rows", rowVertexSource() + fragment);
            let info = gpu.getCompilationInfo(module);
            if (String.contains({substr = "Error"}, info)) {
                module.release();
                Err("WGSL が組めない: ${info}")
            }
            else drawRowsWith(gpu, module, width, textures, uniformSets, errorsBefore)
        }

    def isFloatTexture(t: GlOffscreen.RowTexture): Bool =
        t#levels |> List.head |> Option.map(l -> isFloatTexels(l#texels)) |> Option.getWithDefault(false)

    def isFloatTexels(texels: GlOffscreen.RowTexels): Bool = match texels {
        case GlOffscreen.RowTexels.Float32Rgba(_) => true
        case GlOffscreen.RowTexels.Argb8(_)       => false
    }

    def drawRowsWith(gpu: WebGpu, module: ShaderModule, width: Int32, textures: List[GlOffscreen.RowTexture],
                     uniformSets: List[Vector[Float32]], errorsBefore: Int32): Result[String, List[Vector[Float32]]] \ IO =
        let layoutDesc = new BindGroupLayoutDesc("fge rows").buffer(0, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        textures |> List.forEachWithIndex((k, t) -> {
            let floatTex = isFloatTexture(t);
            discard layoutDesc.texture(1 + 2 * k, ShaderStage.FRAGMENT,
                                       if (floatTex) TextureSampleType.UNFILTERABLE_FLOAT else TextureSampleType.FLOAT);
            discard layoutDesc.sampler(2 + 2 * k, ShaderStage.FRAGMENT,
                                       if (t#linear) SamplerBindingType.FILTERING else SamplerBindingType.NON_FILTERING)
        });
        let layout = gpu.createBindGroupLayout(layoutDesc);
        let pipelineDesc = new RenderPipelineDesc("fge rows");
        discard pipelineDesc.bindGroupLayout(layout).vertex(module, "vs_main").fragment(module, "fs_main");
        discard pipelineDesc.colorTarget(TextureFormat.RGBA32_FLOAT);
        let pipeline = gpu.createRenderPipeline(pipelineDesc);
        let target = gpu.createTexture("fge rows target", width, 1, TextureFormat.RGBA32_FLOAT,
                                       Int32.bitwiseOr(TextureUsage.RENDER_ATTACHMENT, TextureUsage.COPY_SRC), 1, 1);
        let longest = uniformSets |> List.map(Vector.length) |> List.maximum |> Option.getWithDefault(0);
        let uniformBytes = Int32.max(16, (longest * 4 + 15) / 16 * 16);
        let uniforms = gpu.createBuffer("fge rows uniforms", Int32.toInt64(uniformBytes), Int32.bitwiseOr(BufferUsage.UNIFORM, BufferUsage.COPY_DST));
        let uploaded = textures |> List.map(t -> uploadRowTexture(gpu, t));
        let groupDesc = new BindGroupDesc("fge rows", layout).buffer(0, uniforms, 0i64, Int32.toInt64(uniformBytes));
        uploaded |> List.forEachWithIndex((k, ts) -> {
            let (texture, sampler) = ts;
            discard groupDesc.textureView(1 + 2 * k, texture.defaultView());
            discard groupDesc.sampler(2 + 2 * k, sampler)
        });
        let group = gpu.createBindGroup(groupDesc);
        let bytesPerRow = rowBytes(width * 16);
        let readback = gpu.createBuffer("fge rows readback", Int32.toInt64(bytesPerRow), Int32.bitwiseOr(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let uniformData = ByteBuffer.allocateDirect(uniformBytes).order(ByteOrder.LITTLE_ENDIAN);
        let rowData = ByteBuffer.allocateDirect(bytesPerRow).order(ByteOrder.LITTLE_ENDIAN);
        let rows = uniformSets |> List.map(set -> {
            putFloats(uniformData, set);
            gpu.writeBuffer(uniforms, 0i64, uniformData, 0, uniformBytes);
            let encoder = gpu.createCommandEncoder("fge rows");
            let pass = encoder.beginRenderPass(new RenderPassDesc("fge rows").clearColor(target.defaultView(), 0.0, 0.0, 0.0, 0.0));
            pass.setPipeline(pipeline);
            pass.setBindGroup(0, group);
            pass.draw(3, 1, 0, 0);
            pass.end();
            encoder.copyTextureToBuffer(target, 0, 0, 0, width, 1, readback, 0i64, bytesPerRow);
            gpu.submit(encoder.finish());
            gpu.readBuffer(readback, 0i64, bytesPerRow, rowData);
            Vector.range(0, width * 4) |> Vector.map(i -> rowData.getFloat(i * 4))
        });
        group.release();
        pipeline.release();
        layout.release();
        module.release();
        uploaded |> List.forEach(ts -> { let (texture, sampler) = ts; texture.destroy(); sampler.release() });
        target.destroy();
        uniforms.destroy();
        readback.destroy();
        if (gpu.errorCount() > errorsBefore) Err("GPU の誤り: ${gpu.lastError()}") else Ok(rows)

    /// set を buf の先頭から Float32 で詰め、残りを 0 にする。
    def putFloats(buf: ByteBuffer, set: Vector[Float32]): Unit \ IO =
        discard buf.clear();
        Vector.forEachWithIndex((i, v) -> discard buf.putFloat(i * 4, v), set);
        putZeros(buf, Vector.length(set) * 4)

    def putZeros(buf: ByteBuffer, at: Int32): Unit \ IO =
        if (at >= buf.capacity()) () else {
            discard buf.putInt(at, 0);
            putZeros(buf, at + 4)
        }

    /// 入力の絵を段ごとに上げ、読み方の sampler と組にして返す。
    def uploadRowTexture(gpu: WebGpu, t: GlOffscreen.RowTexture): (Texture, Sampler) \ IO =
        let floatTex = isFloatTexture(t);
        let base = t#levels |> List.head;
        let width = base |> Option.map(l -> l#width) |> Option.getWithDefault(1);
        let height = base |> Option.map(l -> l#height) |> Option.getWithDefault(1);
        let format = if (floatTex) TextureFormat.RGBA32_FLOAT else TextureFormat.RGBA8_UNORM;
        let texture = gpu.createTexture("fge rows input", width, height, format,
                                        Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.COPY_DST),
                                        Int32.max(1, List.length(t#levels)), 1);
        t#levels |> List.forEachWithIndex((mip, l) -> uploadRowLevel(gpu, texture, mip, l));
        let filter = if (t#linear) FilterMode.LINEAR else FilterMode.NEAREST;
        (texture, gpu.createSampler("fge rows input", filter, filter, AddressMode.CLAMP_TO_EDGE))

    def uploadRowLevel(gpu: WebGpu, texture: Texture, mip: Int32, level: GlOffscreen.RowLevel): Unit \ IO = match level#texels {
        case GlOffscreen.RowTexels.Float32Rgba(values) =>
            let buf = ByteBuffer.allocateDirect(Int32.max(16, Vector.length(values) * 4)).order(ByteOrder.LITTLE_ENDIAN);
            Vector.forEachWithIndex((i, v) -> discard buf.putFloat(i * 4, v), values);
            gpu.writeTexture(texture, mip, 0, 0, level#width, level#height, buf, 0, level#width * 16)
        case GlOffscreen.RowTexels.Argb8(pixels) =>
            let buf = ByteBuffer.allocateDirect(Int32.max(4, Vector.length(pixels) * 4)).order(ByteOrder.LITTLE_ENDIAN);
            Vector.forEachWithIndex((i, argb) -> discard buf.putInt(i * 4, argbToRgbaBytes(argb)), pixels);
            gpu.writeTexture(texture, mip, 0, 0, level#width, level#height, buf, 0, level#width * 4)
    }

    /// ARGB の 1 画素を、小さい方のバイトから r, g, b, a の並びの Int32 にする（rgba8unorm のメモリの並び）。
    def argbToRgbaBytes(argb: Int32): Int32 =
        let a = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 24, argb), 255);
        let r = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 16, argb), 255);
        let g = Int32.bitwiseAnd(Int32.logicalRightShift(dist = 8, argb), 255);
        let b = Int32.bitwiseAnd(argb, 255);
        Int32.bitwiseOr(Int32.bitwiseOr(r, Int32.leftShift(g, 8)), Int32.bitwiseOr(Int32.leftShift(b, 16), Int32.leftShift(a, 24)))
}
