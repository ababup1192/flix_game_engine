// WGSL の式の行 — 同じ ShaderDoc の面と 3D の材質を、GL（ShaderGen.compile の GLSL）と WebGPU（ShaderGen.Wgsl の WGSL・PC の Dawn）の両方で
// 256 × 1 の RGBA32F に塗り、8 bit に丸める前の値で比べる。どちらも同じ機械の GPU の f32 なので、式の字が同じなら値も同じになるはず。
// 画素 i の uv は ((i + 0.5) / 256, fract(i × 0.618034))。絵を読む面には、読む名前ごとに 8 × 8 の決まった絵を貼る（GL も WebGPU も同じ並びの同じ絵）。
// 差は |gl − webgpu| / max(1, |gl|) の成分ごとの最大。上限 limit() を超えた物があれば exit 1。
// 上限 1e−4 の理由: sin・cos に大きな引数（uTime を掛けた位相・hash）が入る節は、GLSL と WGSL が別のコンパイラ（GL の driver と Tint）を通り、
//   掛けて足す所の丸め方がそろわない。8 bit の 1/40 段なので絵には出ない（測った値は plans/engine-webgpu.md の 12.17）。
//
// 入口: `make -C bench/gl_parity wgsl-rows`（PARITY_WGSL_ROWS=1 で ParityMain の main がここへ来る）。GPU と Dawn の要る門。
mod WgslRows {
    use fge::{Color, GlOffscreen, LwjglLayer, PostProcess, ShaderDoc, ShaderGen, ShaderJson, Sort, WebGpuDevice, WebGpuOffscreen}
    use fge::GlOffscreen.{RowUniform, RowTexels, RowTexture}
    use fge::ShaderDoc.{Field, Shade, Out, Axis, TexChan, BinOp, UnOp, FilterMode, WorleyOut, Axis3}
    import java.io.File
    import java.lang.System

    /// 環境変数 PARITY_WGSL_ROWS が 1 か。
    pub def isAsked(): Bool \ IO =
        let value = System.getenv("PARITY_WGSL_ROWS");
        not Object.isNull(value) and value == "1"

    def width(): Int32 = 256

    def time(): Float64 = 1.25

    def limit(): Float64 = 1.0e-4

    // ── 面 ──

    def c(v: Float64): Field = Field.Const(v)

    def u(): Field = Field.Uv({ axis = Axis.U })

    def v(): Field = Field.Uv({ axis = Axis.V })

    /// 節の種類ごとに 1 つ（名前は節の名前）。
    def kinds(): List[(String, Field)] =
        ("const", c(0.25)) ::
        ("uv", v()) ::
        ("worleyF1", Field.Worley({ scale = 4.5, seed = 3, out = WorleyOut.F1 })) ::
        ("worleyF2mF1", Field.Worley({ scale = 4.5, seed = 3, out = WorleyOut.F2mF1 })) ::
        ("fbm", Field.Fbm({ octaves = 4, scale = 5.25, seed = 4 })) ::
        ("fbmTile", Field.FbmTile({ octaves = 3, scale = 3.0, period = { x = 3.0, y = 2.0 }, seed = 5 })) ::
        ("smoothstep", Field.Smoothstep({ lo = 0.1, hi = 0.9, of = u() })) ::
        ("scaled", Field.Scaled({ factor = 2.0, scroll = { x = 0.1, y = 0.2 }, of = Field.Fbm({ octaves = 2, scale = 3.0, seed = 1 }) })) ::
        ("warp", Field.Warp({ amount = 0.2, scale = 3.0, seed = 6, of = v() })) ::
        ("mix", Field.Mix({ a = u(), b = v(), t = 0.3 })) ::
        ("blend", Field.Blend({ a = c(0.1), b = c(0.8), by = u() })) ::
        ("disk", Field.Disk({ cx = 0.5, cy = 0.5, radius = 0.3, feather = 0.1 })) ::
        ("radial", Field.Radial({ cx = 0.4, cy = 0.6 })) ::
        ("radialAspect", Field.RadialAspect({ cx = 0.5, cy = 0.5, aspect = 1.5 })) ::
        ("quantize", Field.Quantize({ of = u(), steps = 4 })) ::
        ("scales", Field.Scales({ scale = 6.0, stagger = 0.5 })) ::
        ("glints", Field.Glints({ scale = 8.0, rate = 2.0, density = 0.5, seed = 7 })) ::
        ("ripples", Field.Ripples({ freq = 3.0, amp = 0.1, speed = 1.0, seed = 8 })) ::
        ("sparkle", Field.Sparkle({ scale = 8.0, rate = 1.5, density = 0.4, seed = 9 })) ::
        ("binDiv", Field.Bin({ op = BinOp.Div, a = u(), b = Field.Bin({ op = BinOp.Sub, a = v(), b = c(0.5) }) })) ::
        ("binStep", Field.Bin({ op = BinOp.Step, a = u(), b = v() })) ::
        ("hash1", Field.Hash1({ scale = 16.0, seed = 10, bucket = Some(c(0.5)) })) ::
        ("hash2", Field.Hash2({ scale = 16.0, seed = 11, comp = Axis.V, bucket = None })) ::
        ("sqrt", Field.Un({ op = UnOp.Sqrt, of = Field.Bin({ op = BinOp.Sub, a = u(), b = c(0.25) }) })) ::
        ("log2", Field.Un({ op = UnOp.Log2, of = Field.Bin({ op = BinOp.Mul, a = u(), b = c(8.0) }) })) ::
        ("sin", Field.Un({ op = UnOp.Sin, of = Field.Bin({ op = BinOp.Mul, a = u(), b = c(20.0) }) })) ::
        ("powInt", Field.Pow({ of = u(), p = 3.0 })) ::
        ("powFrac", Field.Pow({ of = u(), p = 2.5 })) ::
        ("powNeg", Field.Pow({ of = u(), p = -1.5 })) ::
        ("time", Field.Time({ scale = 0.5, offset = u() })) ::
        ("tiling", Field.Tiling({ tiles = { x = 2.0, y = 3.0 }, of = Field.Fbm({ octaves = 2, scale = 2.0, seed = 2 }) })) ::
        ("snap", Field.Snap({ cells = { x = 4.0, y = 5.0 }, of = Field.Fbm({ octaves = 2, scale = 2.0, seed = 2 }) })) ::
        ("swirl", Field.Swirl({ cx = 0.5, cy = 0.5, strength = 1.0, rate = 0.1, of = u() })) ::
        ("angle", Field.Angle({ cx = 0.5, cy = 0.4 })) ::
        ("rotate", Field.Rotate({ cx = 0.5, cy = 0.5, turns = 0.25, rate = 0.1, of = v() })) ::
        ("tex", Field.Tex({ name = "a", chan = TexChan.G })) ::
        ("shift", Field.Shift({ dx = c(0.01), dy = c(0.02), of = Field.Tex({ name = "a", chan = TexChan.R }) })) ::
        ("texBlur", Field.TexBlur({ name = "b", chan = TexChan.B, radius = { x = 0.05, y = 0.1 }, taps = 9, amount = u() })) ::
        ("texSize", Field.TexSize({ name = "b", axis = Axis.U })) ::
        ("samplerLinear", Field.Sampler({ filter = FilterMode.Linear, of = Field.Tex({ name = "c", chan = TexChan.A }) })) ::
        ("param", Field.Param({ name = "p" })) ::
        ("world", Field.World({ axis = Axis3.Y })) ::
        ("vertexColor", Field.VertexColor({ chan = TexChan.R })) :: Nil

    def fill(name: String, cycleRate: Float64, shade: Shade, alpha: Field): ShaderDoc.Spec =
        { name = name, cycleRate = cycleRate, bindings = Nil, out = Out.Fill({ shade = shade, alpha = alpha }) }

    /// 節の値を r に、符号を返した値を g に、1000 分の 1 を b に出す（書き込みの決まりで負は 0 に切られるため、負の値は g で見る）。
    def kindSpec(name: String, f: Field): ShaderDoc.Spec =
        fill(name, 0.0, Shade.Rgb({ r = f, g = Field.Un({ op = UnOp.Neg, of = f }), b = Field.Bin({ op = BinOp.Mul, a = f, b = c(0.001) }) }), c(1.0))

    def red(): Color = { r = 0.9, g = 0.2, b = 0.1 }

    def blue(): Color = { r = 0.1, g = 0.3, b = 0.8 }

    def shadeSpecs(): List[ShaderDoc.Spec] =
        let f = Field.Fbm({ octaves = 3, scale = 4.0, seed = 12 });
        fill("ramp-cycle", 0.5, Shade.Ramp({ lo = red(), hi = blue(), field = f }), c(1.0)) ::
        fill("gradient", 0.0, Shade.Gradient({ field = u(), stops = (0.0, red()) :: (0.4, blue()) :: (1.0, red()) :: Nil }), c(1.0)) ::
        fill("gradient-cycle", 0.3, Shade.Gradient({ field = f, stops = (0.0, red()) :: (0.4, blue()) :: (1.0, red()) :: Nil }), c(1.0)) ::
        fill("cosine-cycle", 0.5, Shade.Cosine({ field = u(), a = red(), b = blue(), c = red(), d = blue() }), u()) :: Nil

    /// テンプレの `*.shader.json`（読めない物は飛ばす。読めるかは render_gl の TestWgslDawn が見る）。
    def templateSpecs(): List[ShaderDoc.Spec] \ IO =
        let root = new File("../../templates");
        let dirsOf = (dir: File) -> { let entries = dir.listFiles(); if (Object.isNull(entries)) Nil else Array.toList(entries) };
        dirsOf(root) |> List.flatMap(dir -> dirsOf(new File(dir, "assets")))
            |> List.map(f -> f.getPath())
            |> List.filter(path -> String.endsWith({ suffix = ".shader.json" }, path))
            |> Sort.sortStable
            |> List.filterMap(path -> run { ShaderJson.load(path) |> Result.toOption } with Fs.FileRead.runWithIO)

    def surfaceSpecs(): List[ShaderDoc.Spec] \ IO =
        List.map(nf -> kindSpec(fst(nf), snd(nf)), kinds()) :::
        shadeSpecs() :::
        (ShaderDoc.demoSurface() :: ShaderDoc.waterVeins() :: ShaderDoc.lavaVeins() :: PostProcess.fxaaSpec("a") ::
         PostProcess.tonemapped(PostProcess.Tonemap.AcesFitted, PostProcess.defaultExposure(), PostProcess.defaultWhitePoint(), ShaderDoc.waterVeins()) :: Nil) :::
        templateSpecs()

    /// k 番の読みに貼る 8 × 8 の絵（色は位置と k で決める・α も変える）。
    def textureOf(k: Int32, name: String, filter: FilterMode): RowTexture =
        let px = List.range(0, 64) |> List.map(i -> {
            let x = Int32.remainder(i, 8);
            let y = i / 8;
            let r = Int32.remainder(x * 37 + k * 71, 256);
            let g = Int32.remainder(y * 53 + k * 29, 256);
            let b = Int32.remainder((x + y) * 19 + 40, 256);
            let a = 128 + Int32.remainder(x * y * 11 + k * 7, 128);
            Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(a, 24), Int32.leftShift(r, 16)), Int32.bitwiseOr(Int32.leftShift(g, 8), b))
        }) |> List.toVector;
        { sampler = name, levels = { width = 8, height = 8, texels = RowTexels.Argb8(px) } :: Nil, linear = filter == FilterMode.Linear }

    def texturesOf(reads: List[(String, FilterMode)]): List[RowTexture] =
        List.mapWithIndex((k, rf) -> textureOf(k, "uTex${k}", snd(rf)), reads)

    def paramValue(k: Int32): Float64 = 0.3 + 0.17 * Int32.toFloat64(k)

    /// 画素 i の uv（GLSL と WGSL で同じ式）。
    /// sg_rowUvMip は u の進みが画素ごとに速くなる座標（mip のレベルが行の左の 0 から右の 1 へ移る。fract の継ぎ目は sg_texMip が差から外す）。
    def rowUvGlsl(): String =
        "vec2 sg_rowUv(float x) { float i = floor(x); return vec2((i + 0.5) / 256.0, fract(i * 0.618034)); }\n" +
        "vec2 sg_rowUvMip(float x) { float i = floor(x); return vec2(fract(i * i / 2048.0), 0.5); }\n"

    def rowUvWgsl(): String =
        "fn sg_rowUv(x: f32) -> vec2f { let i = floor(x); return vec2f((i + 0.5) / 256.0, fract(i * 0.618034)); }\n" +
        "fn sg_rowUvMip(x: f32) -> vec2f { let i = floor(x); return vec2f(fract(i * i / 2048.0), 0.5); }\n"

    /// 面の GLSL を 1 行に塗る形へ: vUv を varying から画素の位置の式へ替える（ほかの字は ShaderGen.compile のまま）。
    def surfaceGlsl(spec: ShaderDoc.Spec): String =
        ShaderGen.compile(spec)
            |> String.replace(src = "in vec2 vUv;\n", dst = "vec2 vUv;\n" + rowUvGlsl())
            |> String.replace(src = "void main() {\n", dst = "void main() {\n    vUv = sg_rowUv(gl_FragCoord.x);\n")

    def surfaceWgsl(spec: ShaderDoc.Spec): String =
        ShaderGen.Wgsl.compile(spec)#functions + rowUvWgsl() +
        "@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f { return sg_surface(sg_rowUv(pos.x)); }\n"

    def surfaceGlUniforms(spec: ShaderDoc.Spec): List[(String, RowUniform)] =
        ("uTime", RowUniform.FloatValue(time())) :: ("uAlpha", RowUniform.FloatValue(1.0)) ::
        List.mapWithIndex((k, _) -> ("uParam${k}", RowUniform.FloatValue(paramValue(k))), ShaderDoc.paramNames(spec)) :::
        List.mapWithIndex((k, _) -> ("uTexFlip${k}", RowUniform.FloatValue(0.0)), ShaderDoc.texReads(spec))

    /// levels = 絵の mip のレベルの数（どの絵も同じ数）。
    def slotValue(levels: Int32, slot: ShaderGen.Wgsl.UniformSlot): Float64 = match slot {
        case ShaderGen.Wgsl.UniformSlot.Time         => time()
        case ShaderGen.Wgsl.UniformSlot.Alpha        => 1.0
        case ShaderGen.Wgsl.UniformSlot.TexLevels(_) => Int32.toFloat64(levels)
        case ShaderGen.Wgsl.UniformSlot.Param(k)     => paramValue(k)
        case _                                       => 0.0
    }

    def packSlots(levels: Int32, slots: List[ShaderGen.Wgsl.UniformSlot]): Vector[Float32] =
        slots |> List.map(s -> Float64.truncateToFloat32(slotValue(levels, s))) |> List.toVector

    // ── 3D の材質 ──

    /// 材質の変種（名前・spec・emission・metallicRoughness）。
    def materials(): List[(String, ShaderDoc.Spec, Option[Shade], Option[Shade])] =
        let tinted = (chan: TexChan, name: String) -> Field.Bin({ op = BinOp.Mul, a = Field.VertexColor({ chan = chan }), b = Field.Param({ name = name }) });
        let field = fill("scene3d-field", 0.0, Shade.Rgb({ r = tinted(TexChan.R, "r"), g = tinted(TexChan.G, "g"), b = tinted(TexChan.B, "b") }), Field.Param({ name = "a" }));
        let textured = fill("textured", 0.0, Shade.Rgb({ r = Field.Tex({ name = "albedo", chan = TexChan.R }), g = Field.Tex({ name = "albedo", chan = TexChan.G }),
                                                         b = Field.World({ axis = Axis3.X }) }), Field.Tex({ name = "albedo", chan = TexChan.A }));
        let noisy = fill("noisy", 0.25, Shade.Ramp({ lo = red(), hi = blue(), field = Field.Fbm({ octaves = 3, scale = 4.0, seed = 3 }) }),
                         Field.Normal({ axis = Axis3.Z }));
        ("scene3d-field", field, None, None) ::
        ("textured", textured, None, None) ::
        ("textured-glow-metal", textured, Some(Shade.Solid(blue())), Some(Shade.Rgb({ r = u(), g = Field.Param({ name = "rough" }), b = c(0.0) }))) ::
        ("noisy", noisy, None, None) :: Nil

    /// 画素ごとの varying（GLSL と WGSL で同じ式）。
    def varyingsGlsl(uvFn: String): String =
        "    vUv = " + uvFn + "(gl_FragCoord.x);\n" +
        "    vWorld = vec3(vUv.x * 4.0 - 2.0, vUv.y * 3.0, vUv.x - vUv.y);\n" +
        "    vNormal = vec3(vUv.y - 0.5, 1.0, vUv.x - 0.5);\n" +
        "    vColor = vec3(vUv.x, vUv.y, 0.5);\n"

    def materialGlsl(uvFn: String, spec: ShaderDoc.Spec, emission: Option[Shade], metal: Option[Shade]): String =
        let m = ShaderGen.compile3d(spec, emission, metal, false);
        "#version 330 core\nvec2 vUv;\nvec3 vWorld;\nvec3 vNormal;\nvec3 vColor;\nout vec4 fragColor;\n" + rowUvGlsl() + m#uniforms + m#functions +
        "void main() {\n" + varyingsGlsl(uvFn) +
        "    vec4 albedo;\n    vec3 emission;\n    vec2 metalRough = vec2(0.0);\n" +
        (if (Option.nonEmpty(metal)) "    materialEval(albedo, emission, metalRough);\n" else "    materialEval(albedo, emission);\n") +
        "    fragColor = vec4(albedo.rgb + emission * 0.5 + vec3(metalRough, 0.0) * 0.25, albedo.a + " + m#cutoutAlpha + " * 0.125);\n" +
        "}\n"

    def materialWgsl(uvFn: String, spec: ShaderDoc.Spec, emission: Option[Shade], metal: Option[Shade]): String =
        let m = ShaderGen.Wgsl.compile3d(spec, emission, metal, false, 0);
        m#declarations + rowUvWgsl() + m#functions +
        "@fragment fn fs_main(@builtin(position) pos: vec4f) -> @location(0) vec4f {\n" +
        "    let vUv = " + uvFn + "(pos.x);\n" +
        "    let vWorld = vec3f(vUv.x * 4.0 - 2.0, vUv.y * 3.0, vUv.x - vUv.y);\n" +
        "    let vNormal = vec3f(vUv.y - 0.5, 1.0, vUv.x - 0.5);\n" +
        "    let vColor = vec3f(vUv.x, vUv.y, 0.5);\n" +
        "    let material = materialEval(vUv, vWorld, vNormal, vColor);\n" +
        "    let albedo = material.albedo;\n" +
        "    return vec4f(albedo.rgb + material.emission * 0.5 + vec3f(material.metalRough, 0.0) * 0.25, albedo.a + " + m#cutoutAlpha + " * 0.125);\n" +
        "}\n"

    def materialGlUniforms(spec: ShaderDoc.Spec, emission: Option[Shade], metal: Option[Shade]): List[(String, RowUniform)] =
        let reads = ShaderDoc.materialTexReads(spec, emission, metal);
        ("uTime", RowUniform.FloatValue(time())) ::
        List.mapWithIndex((k, _) -> ("uParam${k}", RowUniform.FloatValue(paramValue(k))), ShaderDoc.materialParamNames(spec, emission, metal)) :::
        List.mapWithIndex((k, _) -> ("uTexFlip${k}", RowUniform.FloatValue(0.0)), reads) :::
        List.mapWithIndex((k, _) -> ("uTexLevels${k}", RowUniform.FloatValue(1.0)), reads)

    // ── 比べる ──

    /// 1 つの行（名前・GLSL・WGSL・GL の uniform・WebGPU の値・絵）。
    /// mustVary = r が行の中で変わるはずの行（変わらなければ、読みが mip のレベルを選んでいない）。
    type alias Row = { name = String, glsl = String, wgsl = String, glUniforms = List[(String, RowUniform)], values = Vector[Float32], textures = List[RowTexture],
                       mustVary = Bool }

    def rows(): List[Row] \ IO =
        let surfaces = surfaceSpecs() |> List.map(spec -> {
            let out = ShaderGen.Wgsl.compile(spec);
            { name = "face " + spec#name, glsl = surfaceGlsl(spec), wgsl = surfaceWgsl(spec), glUniforms = surfaceGlUniforms(spec),
              values = packSlots(1, out#slots), textures = texturesOf(out#texReads), mustVary = false }
        });
        let mats = materials() |> List.map(entry -> {
            let (name, spec, glow, metal) = entry;
            let m = ShaderGen.Wgsl.compile3d(spec, glow, metal, false, 0);
            { name = "material " + name, glsl = materialGlsl("sg_rowUv", spec, glow, metal), wgsl = materialWgsl("sg_rowUv", spec, glow, metal),
              glUniforms = materialGlUniforms(spec, glow, metal), values = packSlots(1, m#slots), textures = texturesOf(m#texReads), mustVary = false }
        });
        surfaces ::: mats ::: mipRow() :: Nil

    /// 2 つのレベルの色が違う（レベル 0 = 暗い赤・レベル 1 = 明るい赤）絵を、mip のレベルが行の中で 0 から 1 へ移る座標で読む材質の行。
    def mipRow(): Row =
        let spec = fill("mip", 0.0, Shade.Rgb({ r = Field.Tex({ name = "albedo", chan = TexChan.R }), g = c(0.0), b = c(0.0) }), c(1.0));
        let m = ShaderGen.Wgsl.compile3d(spec, None, None, false, 0);
        let solid = (size: Int32, red: Int32) -> { width = size, height = size,
                                                   texels = RowTexels.Argb8(Vector.repeat(size * size, Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(red, 16)))) };
        let chain = { sampler = "uTex0", levels = solid(8, 40) :: solid(4, 220) :: Nil, linear = true };
        { name = "material mip（2 レベル）", glsl = materialGlsl("sg_rowUvMip", spec, None, None), wgsl = materialWgsl("sg_rowUvMip", spec, None, None),
          glUniforms = ("uTime", RowUniform.FloatValue(time())) :: ("uTexFlip0", RowUniform.FloatValue(0.0)) :: ("uTexLevels0", RowUniform.FloatValue(2.0)) :: Nil,
          values = packSlots(List.length(chain#levels), m#slots),
          textures = chain :: Nil, mustVary = true }

    def diffOf(gl: Vector[Float32], gpu: Vector[Float32]): Float64 =
        Vector.zip(gl, gpu) |> Vector.foldLeft((acc, p) -> {
            let a = Float32.toFloat64(fst(p));
            let b = Float32.toFloat64(snd(p));
            let d = Float64.abs(a - b) / Float64.max(1.0, Float64.abs(a));
            if (d != d) Float64.positiveInfinity() else Float64.max(acc, d)
        }, 0.0)

    /// r の値の最大と最小の差（行が 1 色で塗られていないか — 式が値を出さずに 0 どうしで一致していないか — を読む数）。
    def spreadOf(xs: Vector[Float32]): Float64 =
        let ys = Vector.range(0, Vector.length(xs) / 4) |> Vector.map(i -> Float32.toFloat64(Vector.get(i * 4, xs)));
        Option.getWithDefault(0.0, Vector.maximum(ys)) - Option.getWithDefault(0.0, Vector.minimum(ys))

    def firstRow(r: Result[String, List[Vector[Float32]]]): Result[String, Vector[Float32]] =
        r |> Result.flatMap(sets -> List.head(sets) |> Option.toOk("行が無い"))

    pub def go(): Unit \ IO =
        let all = rows();
        let glRows = run {
            all |> List.map(r -> firstRow(GlOffscreen.drawFloatRows(r#glsl, width(), r#textures, r#glUniforms :: Nil)))
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO;
        let gpuRows = run {
            match WebGpuOffscreen.open({ width = width(), height = 1 }) {
                case Err(why) => all |> List.map(_ -> Err("WebGPU が開けない: ${why}"))
                case Ok(session) =>
                    let out = all |> List.map(r -> firstRow(WebGpuOffscreen.drawFloatRows(session, r#wgsl, width(), r#textures, r#values :: Nil)));
                    WebGpuOffscreen.close(session);
                    out
            }
        } with WebGpuDevice.runDawn;
        let results = List.zip(all, List.zip(glRows, gpuRows)) |> List.map(entry -> {
            let (r, (gl, gpu)) = entry;
            match (gl, gpu) {
                case (Ok(a), Ok(b)) =>
                    let d = diffOf(a, b);
                    let spread = spreadOf(a);
                    let flat = r#mustVary and spread == 0.0;
                    let ok = d <= limit() and not flat;
                    ("[wgsl-rows] ${r#name}: 差 ${d}・GL の r の幅 ${spread}" + (if (d <= limit()) "" else "（上限 ${limit()} を超えた）") +
                     (if (flat) "（変わるはずの r が変わらない）" else ""), ok)
                case (Err(e), _) => ("[wgsl-rows] ${r#name}: GL で塗れない: ${e}", false)
                case (_, Err(e)) => ("[wgsl-rows] ${r#name}: WebGPU で塗れない: ${e}", false)
            }
        });
        results |> List.forEach(x -> println(fst(x)));
        let bad = results |> List.count(x -> not snd(x));
        println("[wgsl-rows] ${List.length(results)} 行・上限を超えた・塗れない ${bad} 行");
        if (bad > 0) System.exit(1) else ()
}
