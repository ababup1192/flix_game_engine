// 生成した WGSL を PC の Dawn（Tint）で組み、誤りが 0 件かを確かめる（ブラウザを開かない）。
// 形式: 1 つのテストが device を 1 つ開き、全部の変種を組んで、組めなかった物の名前と誤りの文の列が空かを見る
// （Dawn は呼ぶスレッドを 1 つにする約束なので、テストを変種ごとに分けない）。
// 組まずに通すのは、Dawn のネイティブが無い OS（今は macOS の arm64 だけにある）と、adapter が無い機械（GPU が無い）だけで、`[wgsl] SKIP:` の行を出す
// （jWebGPU 0.3.4 の Dawn には Null の backend が無く、GPU の無い機械では Tint に届かない）。ほかの理由で開けなければ落とす。
// GPU に頼らない検査（GLSL にしか無い字が無いか）は同じファイルの CPU のテストが見る。
mod TestWgslDawn {
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.RenderPipelineDesc
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureFormat
    import fge.webgpu.TextureSampleType
    import fge.webgpu.WebGpu
    import java.io.File
    import java.nio.file.Files
    use ShaderDoc.{Field, Shade, Out, Axis, TexChan, BinOp, UnOp, FilterMode, WorleyOut, Axis3}

    // ── 変種 ──

    def c(v: Float64): Field = Field.Const(v)

    def fill(name: String, cycleRate: Float64, bindings: List[(String, Field)], shade: Shade, alpha: Field): ShaderDoc.Spec =
        { name = name, cycleRate = cycleRate, bindings = bindings, out = Out.Fill({ shade = shade, alpha = alpha }) }

    /// Field の全部の種類を 1 つずつ（TestShaderGenFieldKinds.allKinds と同じ並び）。
    def allKinds(): List[Field] =
           Field.Const(0.25)
        :: Field.Uv({ axis = Axis.V })
        :: Field.Worley({ scale = 1.5, seed = 3, out = WorleyOut.F1 })
        :: Field.Worley({ scale = 1.5, seed = 3, out = WorleyOut.F2mF1 })
        :: Field.Fbm({ octaves = 2, scale = 1.25, seed = 4 })
        :: Field.FbmTile({ octaves = 3, scale = 1.0, period = { x = 1.0, y = 2.0 }, seed = 5 })
        :: Field.Smoothstep({ lo = 0.1, hi = 0.9, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Scaled({ factor = 2.0, scroll = { x = 0.1, y = 0.2 }, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Warp({ amount = 0.2, scale = 1.0, seed = 6, of = Field.Uv({ axis = Axis.V }) })
        :: Field.Mix({ a = c(0.1), b = c(0.2), t = 0.5 })
        :: Field.Blend({ a = c(0.1), b = c(0.2), by = Field.Uv({ axis = Axis.U }) })
        :: Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.1 })
        :: Field.Radial({ cx = 0.4, cy = 0.6 })
        :: Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 1.5 })
        :: Field.Quantize({ of = Field.Uv({ axis = Axis.U }), steps = 4 })
        :: Field.Scales({ scale = 1.0, stagger = 0.5 })
        :: Field.Glints({ scale = 1.0, rate = 2.0, density = 0.5, seed = 7 })
        :: Field.Ripples({ freq = 3.0, amp = 0.1, speed = 1.0, seed = 8 })
        :: Field.Sparkle({ scale = 1.0, rate = 1.5, density = 0.4, seed = 9 })
        :: Field.Bin({ op = BinOp.Add, a = c(0.1), b = Field.Uv({ axis = Axis.U }) })
        :: Field.Bin({ op = BinOp.Sub, a = c(0.1), b = c(0.2) })
        :: Field.Bin({ op = BinOp.Mul, a = c(0.1), b = c(0.2) })
        :: Field.Bin({ op = BinOp.Min, a = c(0.1), b = c(0.2) })
        :: Field.Bin({ op = BinOp.Max, a = c(0.1), b = c(0.2) })
        :: Field.Bin({ op = BinOp.Step, a = c(0.1), b = Field.Uv({ axis = Axis.V }) })
        :: Field.Bin({ op = BinOp.Div, a = c(0.1), b = Field.Uv({ axis = Axis.V }) })
        :: Field.Hash1({ scale = 1.0, seed = 10, bucket = Some(c(0.5)) })
        :: Field.Hash1({ scale = 1.0, seed = 10, bucket = None })
        :: Field.Hash2({ scale = 2.0, seed = 11, comp = Axis.U, bucket = Some(c(0.25)) })
        :: Field.Un({ op = UnOp.Neg, of = c(0.6) })
        :: Field.Un({ op = UnOp.Abs, of = c(0.6) })
        :: Field.Un({ op = UnOp.Fract, of = c(0.6) })
        :: Field.Un({ op = UnOp.Floor, of = c(0.6) })
        :: Field.Un({ op = UnOp.Sin, of = c(0.6) })
        :: Field.Un({ op = UnOp.Cos, of = c(0.6) })
        :: Field.Un({ op = UnOp.Sat, of = c(0.6) })
        :: Field.Un({ op = UnOp.OneMinus, of = c(0.6) })
        :: Field.Un({ op = UnOp.Sqrt, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Un({ op = UnOp.Log2, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Pow({ of = Field.Uv({ axis = Axis.U }), p = 2.0 })
        :: Field.Pow({ of = Field.Uv({ axis = Axis.U }), p = 2.5 })
        :: Field.Pow({ of = Field.Uv({ axis = Axis.U }), p = -2.0 })
        :: Field.Pow({ of = Field.Uv({ axis = Axis.U }), p = -0.5 })
        :: Field.Time({ scale = 1.0, offset = c(0.1) })
        :: Field.Tiling({ tiles = { x = 2.0, y = 3.0 }, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Snap({ cells = { x = 4.0, y = 5.0 }, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Swirl({ cx = 0.5, cy = 0.5, strength = 1.0, rate = 0.1, of = Field.Uv({ axis = Axis.U }) })
        :: Field.Angle({ cx = 0.5, cy = 0.4 })
        :: Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.25, rate = 0.1, of = Field.Uv({ axis = Axis.V }) })
        :: Field.Ref("k0")
        :: Field.Tex({ name = "a", chan = TexChan.G })
        :: Field.Shift({ dx = c(0.01), dy = c(0.02), of = Field.Tex({ name = "a", chan = TexChan.R }) })
        :: Field.TexBlur({ name = "b", chan = TexChan.B, radius = { x = 1.0, y = 2.0 }, taps = 5, amount = c(0.5) })
        :: Field.TexSize({ name = "b", axis = Axis.U })
        :: Field.TexSize({ name = "b", axis = Axis.V })
        :: Field.Sampler({ filter = FilterMode.Linear, of = Field.Tex({ name = "c", chan = TexChan.A }) })
        :: Field.Param({ name = "p" })
        :: Field.World({ axis = Axis3.Y })
        :: Field.Normal({ axis = Axis3.Z })
        :: Field.VertexColor({ chan = TexChan.R })
        :: Field.VertexColor({ chan = TexChan.A })
        :: Nil

    def allKindsBindings(): List[(String, Field)] =
        List.zipWithIndex(allKinds()) |> List.map(p -> ("k${fst(p)}", snd(p)))

    def red(): Color = { r = 0.9, g = 0.2, b = 0.1 }

    def blue(): Color = { r = 0.1, g = 0.3, b = 0.8 }

    def shades(): List[(String, Shade)] =
        let u = Field.Uv({ axis = Axis.U });
        ("solid", Shade.Solid(red())) ::
        ("ramp", Shade.Ramp({ lo = red(), hi = blue(), field = u })) ::
        ("gradient", Shade.Gradient({ field = u, stops = (0.0, red()) :: (0.5, blue()) :: (1.0, red()) :: Nil })) ::
        ("cosine", Shade.Cosine({ field = u, a = red(), b = blue(), c = red(), d = blue() })) ::
        ("rgb", Shade.Rgb({ r = u, g = Field.Ref("k3"), b = Field.Tex({ name = "a", chan = TexChan.B }) })) :: Nil

    /// 全部の Field の種類を bindings に並べ、Shade の種類 × cycleRate（0 と 0.5）で出す面。
    def allKindsSpecs(): List[ShaderDoc.Spec] =
        shades() |> List.flatMap(ns -> {
            let (name, shade) = ns;
            fill("all-${name}", 0.0, allKindsBindings(), shade, Field.Ref("k2")) ::
            fill("all-${name}-cycle", 0.5, allKindsBindings(), shade, Field.Ref("k2")) :: Nil
        })

    /// 値で分かれる分岐（ぼかしの半径が絵の値で 0 になる）の後で絵を読む面。WGSL の uniformity に触れる形。
    def nonUniformBlurSpec(): ShaderDoc.Spec =
        let amount = Field.Tex({ name = "mask", chan = TexChan.R });
        fill("blur-by-texture", 0.0, Nil, Shade.Solid(red()),
             Field.TexBlur({ name = "photo", chan = TexChan.A, radius = { x = 0.01, y = 0.01 }, taps = 16, amount = amount }))

    /// smoothstep の端が等しい・逆の面（Disk の feather 0・同じ位置の stop・lo == hi と lo > hi で x まで定数）。
    /// 引数が全部定数の組み込みの smoothstep は、端が等しいとシェーダーを作る所で誤りになりうる形。
    def equalEdgeSpecs(): List[ShaderDoc.Spec] =
        let world = Field.World({ axis = Axis3.X });
        fill("disk-feather-0", 0.0, Nil, Shade.Solid(red()), Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.0 })) ::
        fill("gradient-same-stop", 0.0, Nil, Shade.Gradient({ field = world, stops = (0.0, red()) :: (0.5, blue()) :: (0.5, red()) :: Nil }), c(1.0)) ::
        fill("smoothstep-equal-const", 0.0, Nil, Shade.Solid(red()), Field.Smoothstep({ lo = 0.5, hi = 0.5, of = world })) ::
        fill("smoothstep-reversed-const", 0.0, Nil, Shade.Solid(red()), Field.Smoothstep({ lo = 0.8, hi = 0.2, of = c(0.4) })) :: Nil

    /// エンジンが持つ面（例・後がけ）。
    def engineSpecs(): List[ShaderDoc.Spec] =
        ShaderDoc.demoSurface() :: ShaderDoc.waterVeins() :: ShaderDoc.lavaVeins() ::
        PostProcess.fxaaSpec("scene") ::
        PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, PostProcess.defaultExposure(), PostProcess.defaultWhitePoint(), ShaderDoc.demoSurface()) ::
        PostProcess.tonemapped(PostProcess.Tonemap.Reinhard, PostProcess.defaultExposure(), PostProcess.defaultWhitePoint(), ShaderDoc.waterVeins()) :: Nil

    /// テンプレの `*.shader.json`（テンプレが読み込む面。読めない物は名前と理由を Err で返す）。
    def templateSpecs(): List[Result[String, ShaderDoc.Spec]] \ IO =
        let root = new File("../templates");
        let dirs = if (root.isDirectory()) filesOf(root) else Nil;
        dirs |> List.flatMap(dir -> filesOf(new File(dir, "assets")))
             |> List.map(f -> (f.getPath(), f))
             |> List.filter(pf -> String.endsWith({ suffix = ".shader.json" }, fst(pf)))
             |> Sort.sortStableBy(fst)
             |> List.map(pf -> {
                 let (path, f) = pf;
                 let text = Files.readString(f.toPath());
                 Util.Json.parse(String.trim(text))
                     |> Result.flatMap(ShaderJson.parse)
                     |> Result.mapErr(e -> "${path}: ${e}")
             })

    def filesOf(dir: File): List[File] \ IO =
        let entries = dir.listFiles();
        if (Object.isNull(entries)) Nil else Array.toList(entries)

    /// 3D の材質の変種（spec・emission・metallicRoughness）。
    def materialVariants(): List[(String, ShaderDoc.Spec, Option[Shade], Option[Shade])] =
        let vertexTint = (chan: TexChan, name: String) -> Field.Bin({ op = BinOp.Mul, a = Field.VertexColor({ chan = chan }), b = Field.Param({ name = name }) });
        let field = fill("scene3d-field", 0.0, Nil,
                         Shade.Rgb({ r = vertexTint(TexChan.R, "r"), g = vertexTint(TexChan.G, "g"), b = vertexTint(TexChan.B, "b") }),
                         Field.Param({ name = "a" }));
        let textured = fill("textured", 0.0, Nil,
                            Shade.Rgb({ r = Field.Tex({ name = "albedo", chan = TexChan.R }), g = Field.Tex({ name = "albedo", chan = TexChan.G }),
                                        b = Field.Tex({ name = "albedo", chan = TexChan.B }) }),
                            Field.Tex({ name = "albedo", chan = TexChan.A }));
        let glow = Some(Shade.Ramp({ lo = red(), hi = blue(), field = Field.Ref("k1") }));
        let metal = Some(Shade.Rgb({ r = Field.Ref("k2"), g = Field.Param({ name = "rough" }), b = c(0.0) }));
        let all = (name: String, shade: Shade) -> fill("mat-" + name, 0.25, allKindsBindings(), shade, Field.Ref("k2"));
        ("scene3d-field", field, None, None) ::
        ("deep-pow", deepPow(), None, None) ::
        ("textured", textured, None, None) ::
        ("textured-metal", textured, None, metal) ::
        (shades() |> List.flatMap(ns -> {
            let (name, shade) = ns;
            ("all-" + name, all(name, shade), None, None) ::
            ("all-" + name + "-glow-metal", all(name, shade), glow, metal) :: Nil
        }))

    /// 指数 180 の Pow（海の材質の照り返しと同じ形・底も Sat と積の入れ子）を albedo と emission に使う材質。
    def deepPow(): ShaderDoc.Spec =
        let glint = Field.Pow({ of = Field.Un({ op = UnOp.Sat, of = Field.Bin({ op = BinOp.Mul, a = Field.Param({ name = "g" }), b = Field.World({ axis = Axis3.Y }) }) }), p = 180.0 });
        let dim = Field.Pow({ of = Field.Param({ name = "d" }), p = -40.0 });
        fill("deep-pow", 0.0, Nil, Shade.Rgb({ r = glint, g = dim, b = c(0.5) }), c(1.0))

    // ── Dawn で組む ──

    /// WGSL を組んだ誤りの文（無ければ空）。
    def compileErrors(gpu: WebGpu, label: String, wgsl: String): String \ IO =
        let module = gpu.createShaderModule(label, wgsl);
        let info = gpu.getCompilationInfo(module);
        module.release();
        String.lines(info) |> List.filter(l -> String.startsWith({ prefix = "Error" }, l)) |> List.join("\n")

    /// 2D の面の WGSL を組み、ShaderGen.Wgsl の約束（group 0 = sg と絵・group 1 = 射影）の layout で pipeline まで作る。
    def surfaceErrors(gpu: WebGpu, spec: ShaderDoc.Spec): String \ IO =
        let out = ShaderGen.Wgsl.compile(spec);
        let errors = compileErrors(gpu, spec#name, out#module);
        if (not String.isEmpty(errors)) errors
        else {
            let before = gpu.errorCount();
            let module = gpu.createShaderModule(spec#name, out#module);
            let values = new BindGroupLayoutDesc("sg").buffer(0, Int32.bitwiseOr(ShaderStage.VERTEX, ShaderStage.FRAGMENT), BufferBindingType.UNIFORM);
            out#texReads |> List.forEachWithIndex((k, _) -> {
                discard values.texture(1 + 2 * k, ShaderStage.FRAGMENT, TextureSampleType.FLOAT);
                discard values.sampler(2 + 2 * k, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING)
            });
            let valuesLayout = gpu.createBindGroupLayout(values);
            let frameLayout = gpu.createBindGroupLayout(new BindGroupLayoutDesc("frame").buffer(0, ShaderStage.VERTEX, BufferBindingType.UNIFORM));
            let desc = new RenderPipelineDesc(spec#name);
            discard desc.bindGroupLayout(valuesLayout).bindGroupLayout(frameLayout).vertex(module, "vs_main").fragment(module, "fs_main");
            discard desc.colorTarget(TextureFormat.RGBA8_UNORM);
            let pipeline = gpu.createRenderPipeline(desc);
            pipeline.release();
            frameLayout.release();
            valuesLayout.release();
            module.release();
            if (gpu.errorCount() > before) gpu.lastError() else ""
        }

    /// 3D の材質の部品を、varying を引数で受ける小さな frag に差して組む。
    def materialErrors(gpu: WebGpu, label: String, spec: ShaderDoc.Spec, emission: Option[Shade], metallicRoughness: Option[Shade]): String \ IO =
        compileErrors(gpu, label, materialHarness(spec, emission, metallicRoughness))

    def materialHarness(spec: ShaderDoc.Spec, emission: Option[Shade], metallicRoughness: Option[Shade]): String =
        let m = ShaderGen.Wgsl.compile3d(spec, emission, metallicRoughness, 1);
        m#declarations + m#functions +
            "@fragment fn fs_main(@location(0) vUv: vec2f, @location(1) vWorld: vec3f, @location(2) vNormal: vec3f, @location(3) vColor: vec3f) -> @location(0) vec4f {\n" +
            "    let material = materialEval(vUv, vWorld, vNormal, vColor);\n" +
            "    let albedo = material.albedo;\n" +
            "    let cutout = " + m#cutoutAlpha + ";\n" +
            "    return vec4f(albedo.rgb + material.emission + vec3f(material.metalRough, cutout), albedo.a);\n" +
            "}\n"

    /// 材質の frag の字を変える ProgramKind の欄の組（skinned は頂点シェーダーだけを変えるので偽のまま。法線マップは uv つきの時だけ）。
    def programKinds(): List[Render3d.ProgramKey.ProgramKind] =
        let flags = true :: false :: Nil;
        let surfaces = (false, false) :: (true, false) :: (true, true) :: Nil;
        surfaces |> List.flatMap(un -> {
            let (uv, normalMap) = un;
            flags |> List.flatMap(lightmap -> flags |> List.flatMap(blend -> flags |> List.flatMap(doubleSided ->
                flags |> List.flatMap(coverage -> flags |> List.map(metallic ->
                    { skinned = false, uv = uv, normalMap = normalMap, lightmap = lightmap, blend = blend, doubleSided = doubleSided,
                      coverage = coverage, metallicRoughness = metallic, screenAoOnBlend = false, variant = { pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = false } })))))
        })

    def kindLabel(k: Render3d.ProgramKey.ProgramKind): String =
        let bit = (b: Bool, ch: String) -> if (b) ch else "-";
        bit(k#uv, "u") + bit(k#normalMap, "n") + bit(k#lightmap, "l") + bit(k#blend, "b") + bit(k#doubleSided, "d") + bit(k#coverage, "c") + bit(k#metallicRoughness, "m")
            + bit(k#variant#pointShadows, "s") + bit(k#variant#physicalUnits, "p") + bit(k#variant#psx, "x")

    /// 3D の材質の frag の変種: 絵を読む材質と読まない材質は ProgramKind の全部の組・ほかの材質は 2 つの組。
    def materialFragments(): List[(String, String)] =
        let kinds = programKinds();
        let few = kinds |> List.filter(k -> (not k#blend) and (not k#coverage) and (not k#lightmap));
        materialVariants() |> List.flatMap(v -> {
            let (name, spec, glow, metal) = v;
            let m = ShaderGen.Wgsl.compile3d(spec, glow, metal, 1);
            let chosen = if (name == "scene3d-field" or name == "textured-metal") kinds else few;
            let variants = if (name == "textured-metal") few |> List.flatMap(k -> { variant = { ambientOcclusion = true | k#variant } | k } :: { variant = { pointShadows = true | k#variant } | k } :: { variant = { physicalUnits = true | k#variant } | k } :: { variant = { pointShadows = true, physicalUnits = true | k#variant } | k } :: { variant = { psx = true | k#variant } | k } :: { variant = { pointShadows = true, psx = true | k#variant } | k } :: Nil) else Nil;
            (chosen ::: variants) |> List.map(k -> ("frag ${name} ${kindLabel(k)}", Render3dWgsl.materialFragmentSource(m, k)))
        })

    /// 手で書いた 2D の面の WGSL（組めない面の単色の代わり）。
    def builtinSurfaces(): List[(String, String)] =
        ("surface fallback", RenderPaint.Internal.WebGpuShader.surfaceFallbackWgsl()) ::
        ("scene3d paste", RenderPaint.Internal.WebGpuShader.sceneWgsl()) :: Nil

    /// 3D の光の式の関数（材質の frag に入らない空の式を含む）を、場面の宣言と一緒に組む。
    def sceneFunctions(): List[(String, String)] =
        let head = Render3dWgsl.sceneDeclarations() + Render3dWgsl.lightSource();
        ("frag lit", Render3dWgsl.litFragmentSource()) ::
        ("frag lit +ps", Render3dWgsl.litFragmentSourceFor({ pointShadows = true, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = false })) ::
        ("frag lit +pu", Render3dWgsl.litFragmentSourceFor({ pointShadows = false, physicalUnits = true, psx = false, skyIrradiance = false, ambientOcclusion = false })) ::
        ("frag lit +ps+pu", Render3dWgsl.litFragmentSourceFor({ pointShadows = true, physicalUnits = true, psx = false, skyIrradiance = false, ambientOcclusion = false })) ::
        ("frag billboard +pu", Render3dWgsl.billboardFragmentSourceFor({ pointShadows = true, physicalUnits = true, psx = false, skyIrradiance = false, ambientOcclusion = false })) ::
        ("frag lit +psx", Render3dWgsl.litFragmentSourceFor({ pointShadows = false, physicalUnits = false, psx = true, skyIrradiance = false, ambientOcclusion = false })) ::
        ("frag billboard +psx", Render3dWgsl.billboardFragmentSourceFor({ pointShadows = false, physicalUnits = false, psx = true, skyIrradiance = false, ambientOcclusion = false })) ::
        ("vertex lit +psx", Render3dWgsl.litVertexSourceFor(false, true)) ::
        ("vertex lit skinned +psx", Render3dWgsl.litVertexSourceFor(true, true)) ::
        ("vertex material uv +psx", Render3dWgsl.materialVertexSourceFor(true, false, false, true)) ::
        ("vertex material uv skinned +psx", Render3dWgsl.materialVertexSourceFor(true, false, true, true)) ::
        ("vertex material +psx", Render3dWgsl.materialVertexSourceFor(false, true, false, true)) ::
        ("vertex billboard +psx", Render3dWgsl.billboardVertexSourceFor({ pointShadows = false, physicalUnits = false, psx = true, skyIrradiance = false, ambientOcclusion = false })) ::
        ("frag lit +ao", Render3dWgsl.litFragmentSourceFor({ pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = true })) ::
        ("frag lit +ps+pu+psx+sh+ao", Render3dWgsl.litFragmentSourceFor({ pointShadows = true, physicalUnits = true, psx = true, skyIrradiance = true, ambientOcclusion = true })) ::
        ("frag billboard +ao", Render3dWgsl.billboardFragmentSourceFor({ pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = true })) ::
        ("frag screen ao mask", ShaderAst.Wgsl.fragment(Render3d.ScreenPasses.fragment(Render3d.ScreenPasses.ScreenPassKind.AoMask, Render3d.ScreenPasses.wgslBindings() :: Nil))) ::
        ("frag screen ao blur", ShaderAst.Wgsl.fragment(Render3d.ScreenPasses.fragment(Render3d.ScreenPasses.ScreenPassKind.AoBlurH, Render3d.ScreenPasses.wgslBindings() :: Nil))) ::
        ("frag screen ao show", ShaderAst.Wgsl.fragment(Render3d.ScreenPasses.fragment(Render3d.ScreenPasses.ScreenPassKind.ShowAo, Render3d.ScreenPasses.wgslBindings() :: Nil))) ::
        ("vertex screen", ShaderAst.Wgsl.vertex(Render3dShaders.skyVertex())) ::
        ("frag depth", Render3dWgsl.depthFragmentSource()) ::
        ("vertex lit", Render3dWgsl.litVertexSource(false)) ::
        ("vertex material", Render3dWgsl.materialVertexSource(false, false, false)) ::
        ("vertex material uv", Render3dWgsl.materialVertexSource(true, false, false)) ::
        ("vertex material uv lightmap", Render3dWgsl.materialVertexSource(true, true, false)) ::
        ("vertex material lightmap", Render3dWgsl.materialVertexSource(false, true, false)) ::
        ("vertex lit skinned", Render3dWgsl.litVertexSource(true)) ::
        ("vertex material skinned", Render3dWgsl.materialVertexSource(false, false, true)) ::
        ("vertex material uv skinned", Render3dWgsl.materialVertexSource(true, false, true)) ::
        ("vertex sky", Render3dWgsl.skyVertexSource()) ::
        ("frag sky", Render3dWgsl.skyFragmentSource()) ::
        ("vertex billboard", Render3dWgsl.billboardVertexSource()) ::
        ("vertex billboard row right", Render3dWgsl.billboardRowRightVertexSource()) ::
        ("frag billboard", Render3dWgsl.billboardFragmentSource()) ::
        ("sky", head + Render3dWgsl.skyLightSource() +
                "@fragment fn fs_main(@location(0) d: vec3f) -> @location(0) vec4f { return vec4f(skyAt(d), 1.0); }\n") :: Nil

    /// 組めなかった物の (名前, 誤り) と、組んだ数。
    // WhyNot: わざと壊した WGSL で誤りを拾えるかをこのテストの中で確かめない — Dawn は誤りを標準エラーにも出し、テストの道具は
    //   標準エラーに出たテストを落とす。拾えることは、壊した WGSL の誤りの文が getCompilationInfo の "Error" の行で返るのを手で確かめた。
    def checkAll(gpu: WebGpu): (List[(String, String)], Int32) \ IO =
        let fromTemplates = templateSpecs();
        let unreadable = fromTemplates |> List.filterMap(r -> match r {
            case Err(e) => Some(("template", e))
            case Ok(_)  => None
        });
        let surfaces = allKindsSpecs() ::: nonUniformBlurSpec() :: equalEdgeSpecs() ::: engineSpecs() ::: (fromTemplates |> List.filterMap(Result.toOption));
        let surfaceFails = surfaces |> List.map(s -> (s#name, surfaceErrors(gpu, s)));
        let materialFails = materialVariants() |> List.map(v -> {
            let (name, spec, glow, metal) = v;
            ("material " + name, materialErrors(gpu, name, spec, glow, metal))
        });
        let fragFails = (materialFragments() ::: sceneFunctions() ::: builtinSurfaces()) |> List.map(nw -> {
            let (name, wgsl) = nw;
            (name, compileErrors(gpu, name, wgsl))
        });
        let all = surfaceFails ::: materialFails ::: fragFails;
        let fails = unreadable ::: (all |> List.filter(p -> not String.isEmpty(snd(p))));
        (fails, List.length(all))

    /// 組まずに通してよい理由か: Dawn のネイティブを配っていない機種（DawnNatives の文）か、adapter が無い（DawnWebGpu.open の「adapter が無い」・Dawn の「No supported adapters」）。
    // WhyNot: OS と CPU の名前をここで見ない — 配る機種の表は DawnNatives の 1 か所にあり、写すと機種を足した時に片方だけ古くなる。
    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    /// 生成した WGSL の全部（2D の面・材質の部品を差した frag・3D の材質の frag・lit・空）の (名前, 字)。Dawn の検査と同じ並び。
    def allWgsl(): List[(String, String)] \ IO =
        let surfaces = allKindsSpecs() ::: nonUniformBlurSpec() :: equalEdgeSpecs() ::: engineSpecs() ::: (templateSpecs() |> List.filterMap(Result.toOption));
        let materials = materialVariants() |> List.map(v -> {
            let (name, spec, glow, metal) = v;
            ("material " + name, materialHarness(spec, glow, metal))
        });
        (surfaces |> List.map(sp -> (sp#name, ShaderGen.Wgsl.compile(sp)#module))) ::: materials ::: materialFragments() ::: sceneFunctions() ::: builtinSurfaces()

    /// GLSL にしか無い字（WGSL に出たら言葉の切り替え漏れ）。
    def glslOnlyTokens(): List[String] =
        "float(" :: "vec2 " :: "vec4 " :: "texture(" :: "textureLod(" :: "textureSize(" :: " ? " :: "atan(" :: "mod(" :: "inversesqrt" :: "dFdx" :: "uniform " ::
        "bool " :: "ivec" :: "texelFetch(" :: "gl_" :: Nil

    /// tok が字 s に、名前の途中でない所（直前が英数字と _ でない所）から出てくるか（sg_mod( の mod( は数えない）。
    def hasToken(tok: String, s: String): Bool =
        let isPart = (ch: Char) -> Char.isLetter(ch) or Char.isDigit(ch) or ch == '_';
        let starts = String.splitOn({ substr = tok }, s);
        List.zip(starts, List.drop(1, starts)) |> List.exists(p -> {
            let before = fst(p);
            String.isEmpty(before) or not isPart(String.charAt(String.length(before) - 1, before)) or not isPart(String.charAt(0, tok))
        })

    @Test
    def testGeneratedWgslHasNoGlslOnlyText(): Unit \ {Assert, IO} =
        let found = allWgsl() |> List.flatMap(nw -> {
            let (name, wgsl) = nw;
            glslOnlyTokens() |> List.filter(tok -> hasToken(tok, wgsl)) |> List.map(tok -> "${name}: ${tok}")
        });
        Assert.assertEq(expected = (Nil: List[String]), found)

    @Test
    def testEveryGeneratedWgslCompilesOnDawn(): Unit \ {Assert, IO} =
        let device = WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice());
        match device {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[wgsl] SKIP: Dawn で組まない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let (fails, count) = checkAll(gpu);
                gpu.destroy();
                fails |> List.forEach(f -> println("[wgsl] 組めない: ${fst(f)}: ${snd(f)}"));
                println("[wgsl] Dawn で組んだ WGSL: ${count} 本（${gpu.adapterInfo()}）");
                Assert.assertEq(expected = (Nil: List[(String, String)]), fails)
        }

    /// 影の地図の画素は GL の数え方（行 0 が NDC の y = −1）で決めて端にそろえ、読む時だけ行を返す（WebGPU の地図は行 0 が NDC の y = +1）。
    @Test
    def testShadowMapRowIsFlippedOnlyWhenRead(): Unit \ Assert =
        let wgsl = Render3dWgsl.lightSource();
        Assert.assertEq(expected = (true, true),
                        (String.contains(substr = "let t = clamp(center + vec2i(dx, dy), vec2i(0), last);", wgsl),
                         String.contains(substr = "textureLoad(map, vec2i(t.x, i32(textureDimensions(map, 0).y) - 1 - t.y), 0)", wgsl)))

    @Test
    def testNormalMappedFragmentDoesNotFlipRows(): Unit \ Assert =
        let textured = fill("textured", 0.0, Nil, Shade.Solid(red()), Field.Tex({ name = "albedo", chan = TexChan.A }));
        let kind = { skinned = false, uv = true, normalMap = true, lightmap = true, blend = false, doubleSided = false, coverage = false, metallicRoughness = false, screenAoOnBlend = false, variant = { pointShadows = false, physicalUnits = false, psx = false, skyIrradiance = false, ambientOcclusion = false } };
        Assert.assertFalse(String.contains(substr = "Flip", Render3dWgsl.materialFragmentSource(ShaderGen.Wgsl.compile3d(textured, None, None, 1), kind)))
}
