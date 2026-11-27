// Render3d.WebGpuMipmaps — 全体の登録の絵（2D の描き手の絵）の mip つきの写しを GPU の render pass で作る（GL の PC の Render3d.Material.mipCopyOf と対）。
// レベル 0 は元の絵をそのまま写し、レベル k はレベル k − 1 の 2 × 2 のテクセルを Mip.build と同じ決まり（はみ出す列と行は端を繰り返す・Raw は (和 + 2) / 4 の切り捨て・
// SrgbCurve の rgb は線形の量の平均を 8bit の sRGB の値へ戻す）で平均して、レベル 1 つの view を描き先にして描く。
// WhyNot: 元の絵を読み戻して CPU の Mip.build で作らない — readBuffer は答えが出るまで返らず、ブラウザでは requestAnimationFrame の中で待てない。
// WhyNot: 2D の描き手が絵を上げた時の CPU の画素を持っておかない — 全部の絵をヒープに二重に持つことになる（GL が持たないと決めた理由と同じ）。
// WhyNot: 前のレベルを線形のフィルタで 1 回読んで平均しない — sRGB の曲線の平均と端の繰り返しと (和 + 2) / 4 の丸めが Mip.build とそろわない。
mod Render3d.WebGpuMipmaps {
    import fge.webgpu.BindGroup
    import fge.webgpu.BindGroupDesc
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.CommandEncoder
    import fge.webgpu.CullMode
    import fge.webgpu.FrontFace
    import fge.webgpu.PrimitiveTopology
    import fge.webgpu.RenderPassDesc
    import fge.webgpu.RenderPipeline
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.ShaderModule
    import fge.webgpu.ShaderStage
    import fge.webgpu.Texture
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.TextureUsage
    import fge.webgpu.TextureView
    import fge.webgpu.WebGpu

    /// 写しを作る道具。layout = 読むレベルの group 0（絵 1 枚）・pipelines = frag の入口の名前（entryOf）→ pipeline（初めて使う時に作る）・
    /// views と groups = 今の encoder で使ったレベルの view と group（submit の後に手放す）。
    pub type alias Mipmaps = {
        gpu = WebGpu, layout = BindGroupLayout, vertexModule = ShaderModule, fragmentModule = ShaderModule,
        pipelines = Ref[Map[String, RenderPipeline], Static],
        views = Ref[List[TextureView], Static], groups = Ref[List[BindGroup], Static]
    }

    /// 写しを描き込む encoder と、pass を 1 つ積んだと知らせる口（3D の描き手の Host の物）。
    pub type alias Encoding = { encoder = Unit -> CommandEncoder \ IO, notePass = Unit -> Unit \ IO }

    /// 作った写し 1 枚。levels = レベルの数・bytes = レベルを合わせた置き場の大きさ。
    pub type alias MipCopy = { texture = Texture, levels = Int32, bytes = Int64 }

    /// レベル 1 つの作り方。Copy = レベル 0（元の絵を写す）・その上のレベルは平均の仕方ごと。
    enum Step {
        case Copy
        case Halve(Mip.Average)
    }

    def entryOf(step: Step): String = match step {
        case Step.Copy                          => "fs_copy"
        case Step.Halve(Mip.Average.Raw)        => "fs_raw"
        case Step.Halve(Mip.Average.SrgbCurve)  => "fs_srgb"
    }

    /// device の上に shader module と layout を作る（pipeline は初めて使う時に）。vertex は空の vertex（shaders の SkyVertex）を使う。
    pub def create(gpu: WebGpu, shaders: Render3d.ShaderLibrary.ShaderSources): Mipmaps \ IO =
        let layoutDesc = new BindGroupLayoutDesc("fge mip copy");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT);
        { gpu = gpu, layout = gpu.createBindGroupLayout(layoutDesc),
          vertexModule = gpu.createShaderModule("fge mip copy vs", Render3d.ShaderLibrary.wgslOrBug(shaders, Render3d.ShaderSourceKey.SkyVertex)),
          fragmentModule = gpu.createShaderModule("fge mip copy fs", fragmentSource()),
          pipelines = Ref.fresh(Static, Map.empty()), views = Ref.fresh(Static, Nil), groups = Ref.fresh(Static, Nil) }

    /// device の上に作った物を全部手放す。この後 mm は使えない。
    pub def release(mm: Mipmaps): Unit \ IO =
        afterSubmit(mm);
        Map.forEach((_, p) -> p.release(), Ref.get(mm#pipelines));
        Ref.put(Map.empty(), mm#pipelines);
        mm#layout.release();
        mm#vertexModule.release();
        mm#fragmentModule.release()

    /// encoder を submit した後に呼ぶ（レベルの view と group を手放す）。
    pub def afterSubmit(mm: Mipmaps): Unit \ IO =
        Ref.get(mm#groups) |> List.forEach(g -> g.release());
        Ref.put(Nil, mm#groups);
        Ref.get(mm#views) |> List.forEach(v -> v.release());
        Ref.put(Nil, mm#views)

    /// 元の絵 source の mip つきの写しを作り、レベルを作る pass を enc の encoder へ積む（呼ぶのは pass を開いていない時だけ）。
    /// レベルの数は 1 × 1 まで（TextureTable3d.levelsOf・Mip.build と同じ数え方）・平均の仕方は average。
    pub def copyOf(mm: Mipmaps, enc: Encoding, label: String, source: Texture, average: Mip.Average): MipCopy \ IO =
        let width = source.width();
        let height = source.height();
        let levels = Render3d.TextureTable3d.levelsOf(width, height);
        let usage = Int32.bitwiseOr(Int32.bitwiseOr(TextureUsage.TEXTURE_BINDING, TextureUsage.RENDER_ATTACHMENT), TextureUsage.COPY_SRC);
        let texture = mm#gpu.createTexture(label, width, height, TextureFormat.RGBA8_UNORM, usage, levels, 1);
        encodeStep(mm, enc, Step.Copy, source.createView(), texture.createView(0, 1));
        { texture = texture, levels = levels, bytes = buildMipLevels(mm, enc, texture, levels, average) }

    /// レベル 0 が埋まった texture（levels レベル・RGBA8・usage に RENDER_ATTACHMENT と TEXTURE_BINDING）のレベル 1 から上を作る pass を enc の encoder へ積み
    /// （平均の仕方は average・呼ぶのは pass を開いていない時だけ）、レベルを合わせた置き場の大きさを返す。
    pub def buildMipLevels(mm: Mipmaps, enc: Encoding, texture: Texture, levels: Int32, average: Mip.Average): Int64 \ IO =
        List.range(1, levels) |> List.forEach(level ->
            encodeStep(mm, enc, Step.Halve(average), texture.createView(level - 1, 1), texture.createView(level, 1)));
        bytesOf(texture.width(), texture.height(), levels)

    /// レベル 0 から levels レベルの、RGBA8 の置き場の大きさ。
    def bytesOf(width: Int32, height: Int32, levels: Int32): Int64 =
        if (levels <= 0) 0i64
        else Int32.toInt64(width * height * 4) + bytesOf(Int32.max(1, width / 2), Int32.max(1, height / 2), levels - 1)

    /// reads を読んで target へ描く pass を 1 つ積む（view 2 つと group は submit の後に手放す）。
    def encodeStep(mm: Mipmaps, enc: Encoding, step: Step, reads: TextureView, target: TextureView): Unit \ IO =
        let desc = new BindGroupDesc("fge mip copy", mm#layout);
        discard desc.textureView(0, reads);
        let group = mm#gpu.createBindGroup(desc);
        Ref.put(reads :: target :: Ref.get(mm#views), mm#views);
        Ref.put(group :: Ref.get(mm#groups), mm#groups);
        let pass = (enc#encoder)().beginRenderPass(new RenderPassDesc("fge mip copy").clearColor(target, 0.0, 0.0, 0.0, 0.0));
        (enc#notePass)();
        pass.setPipeline(pipelineOf(mm, step));
        pass.setBindGroup(0, group);
        pass.draw(3, 1, 0, 0);
        pass.end()

    def pipelineOf(mm: Mipmaps, step: Step): RenderPipeline \ IO =
        let key = entryOf(step);
        match Map.get(key, Ref.get(mm#pipelines)) {
            case Some(p) => p
            case None =>
                let desc = new RenderPipelineDesc("fge mip copy");
                discard desc.bindGroupLayout(mm#layout);
                discard desc.vertex(mm#vertexModule, "vs_main").fragment(mm#fragmentModule, key);
                discard desc.colorTarget(TextureFormat.RGBA8_UNORM);
                discard desc.primitive(PrimitiveTopology.TRIANGLE_LIST, FrontFace.CW, CullMode.NONE);
                let made = mm#gpu.createRenderPipeline(desc);
                Ref.put(Map.insert(key, made, Ref.get(mm#pipelines)), mm#pipelines);
                made
        }

    /// レベルを作る frag（入口は fs_copy・fs_raw・fs_srgb）。読むレベルは group 0 の binding 0 のレベル 1 つの view。
    /// 成分は 8bit の値（0〜255 の整数）に直して Mip.build と同じ式で平均し、k / 255 を書く（unorm の描き先は k に戻る）。
    // WhyNot: 線形の量を 8bit の sRGB の値へ戻す所を 255 本のしきい値の表で数えない — しきい値 (k − 0.5) / 255 を線形にした値以下を数えるのは、
    //   linearToSrgb(平均) × 255 + 0.5 の切り捨てと同じ数（曲線が単調）。f32 の丸めでしきい値の際だけ ±1 ずれうる。
    // WhyNot: 成分を実行時の番号で引いて 1 つずつ平均しない — 値の配列を定数でない番号で引く形を拒む WGSL の実装がある。
    pub def fragmentSource(): String =
        "@group(0) @binding(0) var src: texture_2d<f32>;\n" +
        "fn texel(p: vec2i) -> vec4f { return round(textureLoad(src, p, 0) * 255.0); }\n" +
        "fn quad(at: vec4f) -> array<vec4f, 4> {\n" +
        "    let last = vec2i(textureDimensions(src, 0)) - vec2i(1, 1);\n" +
        "    let p0 = min(vec2i(at.xy) * 2, last);\n" +
        "    let p1 = min(vec2i(at.xy) * 2 + vec2i(1, 1), last);\n" +
        "    return array<vec4f, 4>(texel(p0), texel(vec2i(p1.x, p0.y)), texel(vec2i(p0.x, p1.y)), texel(p1));\n" +
        "}\n" +
        "fn rawMean(q: array<vec4f, 4>) -> vec4f { return floor((q[0] + q[1] + q[2] + q[3] + 2.0) / 4.0); }\n" +
        "fn toLinear(v: vec3f) -> vec3f {\n" +
        "    let s = v / 255.0;\n" +
        "    return select(pow((s + 0.055) / 1.055, vec3f(2.4)), s / 12.92, s <= vec3f(0.04045));\n" +
        "}\n" +
        "fn toSrgb8(l: vec3f) -> vec3f {\n" +
        "    let x = max(l, vec3f(0.0));\n" +
        "    let s = select(1.055 * pow(x, vec3f(1.0 / 2.4)) - 0.055, x * 12.92, x <= vec3f(0.0031308));\n" +
        "    return clamp(floor(s * 255.0 + 0.5), vec3f(0.0), vec3f(255.0));\n" +
        "}\n" +
        "fn srgbMean(q: array<vec4f, 4>) -> vec3f {\n" +
        "    return toSrgb8((toLinear(q[0].rgb) + toLinear(q[1].rgb) + toLinear(q[2].rgb) + toLinear(q[3].rgb)) / 4.0);\n" +
        "}\n" +
        "@fragment fn fs_copy(@builtin(position) at: vec4f) -> @location(0) vec4f { return textureLoad(src, vec2i(at.xy), 0); }\n" +
        "@fragment fn fs_raw(@builtin(position) at: vec4f) -> @location(0) vec4f { return rawMean(quad(at)) / 255.0; }\n" +
        "@fragment fn fs_srgb(@builtin(position) at: vec4f) -> @location(0) vec4f {\n" +
        "    let q = quad(at);\n" +
        "    return vec4f(srgbMean(q), rawMean(q).a) / 255.0;\n" +
        "}\n"
}
