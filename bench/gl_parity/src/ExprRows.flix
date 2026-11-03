// 式の行 — 3D の光の式を、GL のシェーダー（LightModel3d の木から作った GLSL）と CPU の描き手が回す関数（木から生成した
// SoftRaster3dLight と、木の外の SoftRaster3d.shadowLitFractionAt・applyNormalMap・ShaderEval.sampleMipRgb）に同じ入力を入れ、
// 8 bit に丸める前の値で比べる。絵の行（Scenes）は 8 bit の色の差の画素数しか見ないので、式の小さな食い違いが許容の中に隠れる。
//
// 入力は種つきの乱数の 256 組（GPU と同じ入力にするため Float32 に丸めてから CPU へも渡す）。GPU は 256 × 1 の RGBA32F の描き先へ
// 1 画素 = 1 組で塗り、GL_FLOAT で読み返す（GlOffscreen.drawFloatRows）。差は |gpu − cpu| / max(1, |cpu|) の成分ごとの最大。
//
// 上限と外す組（2026-11-03・Apple M4 Pro・macOS 27 の GL で測った値から決めた。測った差は行の表に毎回出る）:
//   光（lightAt・lightmapLightAt）: 測った最大 3.2e−6 → 上限 limitTree() = 1e−5。霧 3.2e−7・空 9.0e−8・TBN 2.5e−7 も同じ上限。
//     トゥーンの段は当てずに比べる（境目の近くで 1/steps 跳ねるため）。range の端（d² / range² が 1 から edgeGap() の内）と
//     cone の縁（光への向きとスポットの向きの cos が外・内の cos から edgeGap() の内）の組は外す。この種の入力では外さなくても
//     最大は 3.2e−6 で変わらなかったが、傾きの大きい所なので入力を替えた時の守りに残す（外すのは 4096 組のうち約 50）。
//   影を落とすスポットのある光（exprShadowLight）: 上限 limitTree()（測った最大 1.0e−7）。木の中の「届く光と cone が共に正の時だけ地図を引く」を通す。
//     地図を引いて値の変わった組が 1 つも無ければ落とす（この種では 256 組のうち 3）。
//   トゥーンの段: CPU の SoftRaster3dLight.lightAt に段の数を渡した値と GPU の値の段の番号が同じか（段を当てる前の値が境目から 1e−4 以上離れた組だけ。測った時は違う組 0）。
//   影の地図の PCF: 照らされている割合の差が 1 / (2r + 1)² の 1 段まで（割合が 0 と 1 の間の組が無ければ落とす）（奥行きの比べが Float32 と Float64 で入れ替わる画素がありうる。測った時は 3e−7 段）。
//   lightmap の段つきの読み: 測った最大 9.7e−3（約 2.5 / 255）→ 上限 limitTexture() = 3 / 255（GPU は画素と段の間の重みを 8 bit ほどの細かさで持つ）。
//     段の境目の近くの組は外さない（GL の LINEAR_MIPMAP_LINEAR は段の間もなめらかにつなぐので、境目で値が跳ねない）。lod は入力で渡すので、
//     sg_texMip の lod の決め方（dFdx・dFdy と Mip.lodOf）はこの行では確かめない（絵の行の mipFloor などが見る）。
//   色の空間の変換（exprColorSpace）: r3d_srgbToLinear3 と r3d_linearToSrgb3 を Texture3d の式と比べる。入力は 0〜1.5。
//     測った最大 2.0e−7 → 上限 limitTree()。
//   色を作る最後の組み立て（exprSurfaceOut）: r3d_surfaceOut をかすみありで SoftRaster3d.surfaceOutAt と比べる。
//     測った最大 3.3e−7 → 上限 limitTree()。かすみの色は surfaceOutAt が中で線形へ戻すので、GL の uFogColor には戻した値を入れる。
//   わざと壊した式（減衰の 2 乗を外す → 差 0.31・cone の内と外を入れ替える → 差 1.08）は、光の行の差が brokenAtLeast() = 1e−2 を
//   超えることを毎回確かめる（上限が緩すぎて式の食い違いを見逃していないことの確かめ）。
mod ExprRows {
    use fge::{Color, GlOffscreen, LightModel3d, Mat4, Render3dGlsl, Scene3d, ShaderEval, SoftRaster3d, SoftRaster3dLight, Texture3d, Vec3}
    use fge::GlOffscreen.{RowUniform, RowTexels, RowTexture}
    import java.util.Random
    import java.lang.{Math => JMath}

    // ── 上限 ──

    def count(): Int32 = 256

    def limitTree(): Float64 = 1.0e-5

    def limitTexture(): Float64 = 3.0 / 255.0

    def brokenAtLeast(): Float64 = 1.0e-2

    def edgeGap(): Float64 = 1.0e-3

    /// 影の地図の PCF の差の上限（段の数。1 段 = 1 / (2r + 1)²）。
    def pcfStepsLimit(): Float64 = 1.0 + 1.0e-6

    def toonSteps(): Int32 = 4

    // ── 入力 ──

    /// 1 組の画素ごとの入力（a・b・c は行ごとに意味が違う。光の行なら 点・法線・3 本目（lightmap の色・霧の前の色・空の向き））。
    type alias Probe = { a = (Float64, Float64, Float64, Float64), b = (Float64, Float64, Float64, Float64), c = (Float64, Float64, Float64, Float64) }

    /// 光の行の frag が出す式（uMode の値は modeOf）。
    enum TreeRow with Eq {
        case Light
        case LightmapLight
        case Fog
        case Sky
    }

    def treeRows(): List[TreeRow] = TreeRow.Light :: TreeRow.LightmapLight :: TreeRow.Fog :: TreeRow.Sky :: Nil

    def modeOf(row: TreeRow): Int32 = match row {
        case TreeRow.Light         => 0
        case TreeRow.LightmapLight => 1
        case TreeRow.Fog           => 2
        case TreeRow.Sky           => 3
    }

    /// 光の点が range の端や cone の縁の近くにある組を外す式か（霧と空は光を読まない）。
    def readsLights(row: TreeRow): Bool = row == TreeRow.Light or row == TreeRow.LightmapLight

    /// 1 回の描きで共通の光と霧と空。
    type alias LightSet = {
        points = List[Scene3d.PointLight], spots = List[Scene3d.SpotLight], ambient = Vec3.Vec3, hemisphere = Float64,
        eye = Vec3.Vec3, fogColor = Vec3.Vec3, fogNear = Float64, fogFar = Float64,
        lightmapSrgb = Bool, lightmapIntensity = Float64,
        zenith = Vec3.Vec3, horizon = Vec3.Vec3, ground = Vec3.Vec3, curve = Float64
    }

    /// 影の地図の行の入力（点は probes の a）。
    type alias ShadowCase = { matrix = Mat4.Mat4, size = Int32, bias = Float64, map = Vector[Float64] }

    /// 色を作る最後の組み立ての行の 1 回の描きの uniform（かすみ・目は同じ番号の光の組から取る）。
    type alias SurfaceDraw = { tint = Vec3.Vec3, intensity = Float64 }

    /// 全部の行の入力。
    pub type alias Inputs = {
        light = List[Probe], sets = List[LightSet], shadowPoints = List[Probe], shadow = ShadowCase,
        tbn = List[Probe], strength = Float64, lightmapUv = List[Probe], chain = Vector[ShaderEval.TexData],
        colorSpace = List[Probe], surface = List[Probe], surfaceDraws = List[SurfaceDraw]
    }

    /// GPU で読み返した値（行ごと・描きごとに 256 × 4 個）。
    pub type alias GlRows = {
        tree = List[Vector[Float32]], toon = List[Vector[Float32]], shadowedLight = Vector[Float32], brokenFalloff = Vector[Float32], brokenCone = Vector[Float32],
        shadow = List[Vector[Float32]], tbn = Vector[Float32], lightmap = Vector[Float32],
        colorSpace = List[Vector[Float32]], surface = List[Vector[Float32]]
    }

    def f32(x: Float64): Float64 = Float32.toFloat64(Float64.truncateToFloat32(x))

    def uniform(rng: Random, lo: Float64, hi: Float64): Float64 \ IO = f32(lo + (hi - lo) * rng.nextDouble())

    def vec3In(rng: Random, lo: Float64, hi: Float64): Vec3.Vec3 \ IO =
        let x = uniform(rng, lo, hi);
        let y = uniform(rng, lo, hi);
        let z = uniform(rng, lo, hi);
        Vec3.v3(x, y, z)

    /// 長さ 1 の向き（成分は Float32 に丸める。丸めの後の長さは 1 から 1e−7 ほどずれる）。
    def direction(rng: Random): Vec3.Vec3 \ IO =
        let v = Vec3.normalized(Vec3.v3(rng.nextGaussian(), rng.nextGaussian(), rng.nextGaussian()));
        Vec3.v3(f32(v#x), f32(v#y), f32(v#z))

    def withW(v: Vec3.Vec3, w: Float64): (Float64, Float64, Float64, Float64) = (v#x, v#y, v#z, w)

    def colorOf(v: Vec3.Vec3): Color = { r = v#x, g = v#y, b = v#z }

    /// 光の行の入力（種は固定。並びの順で乱数を引くので、足す時は後ろへ）。
    pub def inputs(): Inputs \ IO =
        let rng = new Random(20261103i64);
        let light = List.range(0, count()) |> List.map(_ -> {
            let p = vec3In(rng, -4.0, 4.0);
            let n = direction(rng);
            let third = if (rng.nextBoolean()) direction(rng) else vec3In(rng, 0.0, 1.0);
            { a = withW(p, 0.0), b = withW(n, 0.0), c = withW(third, 0.0) }
        });
        let sets = List.range(0, 8) |> List.map(k -> lightSet(rng, k));
        let shadowPoints = List.range(0, count()) |> List.map(_ -> { let p = vec3In(rng, -2.5, 2.5); { a = withW(p, 0.0), b = (0.0, 0.0, 0.0, 0.0), c = (0.0, 0.0, 0.0, 0.0) } });
        let size = 64;
        let map = Vector.range(0, size * size) |> Vector.map(_ -> uniform(rng, 0.3, 1.0));
        let caster = Scene3d.spotLight(Vec3.v3(0.5, 5.0, -6.0), Vec3.v3(0.0, 0.0, 0.0), 1.1);
        let tbn = List.range(0, count()) |> List.map(_ -> {
            let n = direction(rng);
            let raw = vec3In(rng, -1.5, 1.5);
            let w = if (rng.nextBoolean()) 1.0 else -1.0;
            let c = vec3In(rng, 0.0, 1.0);
            { a = withW(raw, w), b = withW(n, 0.0), c = withW(c, 0.0) }
        });
        let chain = Vector.range(0, 5) |> Vector.map(level -> {
            let side = Vector.get(level, Vector#{16, 8, 4, 2, 1});
            { width = side, height = side, pixels = Vector.range(0, side * side) |> Vector.map(_ -> -16777216 + rng.nextInt(16777216)) }
        });
        let lightmapUv = List.range(0, count()) |> List.map(_ -> {
            let u = uniform(rng, 0.0, 1.0);
            let v = uniform(rng, 0.0, 1.0);
            let lod = uniform(rng, 0.0, 4.0);
            { a = (u, v, lod, 0.0), b = (0.0, 0.0, 0.0, 0.0), c = (0.0, 0.0, 0.0, 0.0) }
        });
        let colorSpace = List.range(0, count()) |> List.map(_ -> { let v = vec3In(rng, 0.0, 1.5); { a = withW(v, 0.0), b = (0.0, 0.0, 0.0, 0.0), c = (0.0, 0.0, 0.0, 0.0) } });
        // 光の色は a・b・c の w に 1 成分ずつ入れる（frag の入力の絵を 3 枚のままにする）。
        let surface = List.range(0, count()) |> List.map(_ -> {
            let p = vec3In(rng, -6.0, 6.0);
            let albedo = vec3In(rng, 0.0, 1.2);
            let emission = vec3In(rng, 0.0, 1.5);
            let lit = vec3In(rng, 0.0, 2.0);
            { a = withW(p, lit#x), b = withW(albedo, lit#y), c = withW(emission, lit#z) }
        });
        let surfaceDraws = sets |> List.map(_ -> {
            let tint = vec3In(rng, 0.2, 1.2);
            let intensity = uniform(rng, 0.5, 4.0);
            { tint = tint, intensity = intensity }
        });
        { light = light, sets = sets, shadowPoints = shadowPoints,
          shadow = { matrix = Scene3d.shadowMatrix(caster), size = size, bias = 0.002, map = map },
          tbn = tbn, strength = 1.5, lightmapUv = lightmapUv, chain = chain,
          colorSpace = colorSpace, surface = surface, surfaceDraws = surfaceDraws }

    /// k 番目の光の組（点光源とスポットの数を組ごとに変える。0 本の組も持つ）。
    def lightSet(rng: Random, k: Int32): LightSet \ IO =
        let pointCount = Vector.get(k, Vector#{0, 1, 2, 3, 5, 8, 8, 4});
        let spotCount = Vector.get(k, Vector#{0, 1, 2, 1, 2, 0, 2, 1});
        let points = List.range(0, pointCount) |> List.map(_ -> {
            let position = vec3In(rng, -5.0, 5.0);
            let color = colorOf(vec3In(rng, 0.0, 1.5));
            let range = uniform(rng, 2.0, 9.0);
            { position = position, color = color, intensity = 1.0, range = range }
        });
        let spots = List.range(0, spotCount) |> List.map(_ -> {
            let position = vec3In(rng, -5.0, 5.0);
            let target = vec3In(rng, -2.0, 2.0);
            let fov = uniform(rng, 0.4, 2.0);
            let inner = uniform(rng, 0.0, 1.0);
            let color = colorOf(vec3In(rng, 0.0, 1.5));
            let range = uniform(rng, 4.0, 14.0);
            { innerFovY = Some(f32(fov * inner)), color = color, range = range | Scene3d.spotLight(position, target, fov) }
        });
        let ambient = vec3In(rng, 0.0, 0.3);
        let hemisphere = uniform(rng, 0.0, 0.5);
        let eye = vec3In(rng, -6.0, 6.0);
        let fogColor = vec3In(rng, 0.0, 1.0);
        let fogNear = uniform(rng, 0.0, 4.0);
        let fogFar = f32(fogNear + uniform(rng, 0.5, 8.0));
        let lightmapSrgb = rng.nextBoolean();
        let lightmapIntensity = uniform(rng, 0.0, 2.0);
        let zenith = vec3In(rng, 0.0, 1.0);
        let horizon = vec3In(rng, 0.0, 1.0);
        let ground = vec3In(rng, 0.0, 1.0);
        let curve = uniform(rng, 0.3, 3.0);
        { points = points, spots = spots, ambient = ambient, hemisphere = hemisphere, eye = eye, fogColor = fogColor,
          fogNear = fogNear, fogFar = fogFar, lightmapSrgb = lightmapSrgb, lightmapIntensity = lightmapIntensity,
          zenith = zenith, horizon = horizon, ground = ground, curve = curve }

    // ── GPU ──

    /// 光の行の frag。uMode は modeOf（0 lightAt・1 lightmapLightAt・2 fogAt・3 skyAt。式の字は 3D の描き手と同じ Render3dGlsl の物）。
    def treeFragment(edit: String -> String): String =
        "#version 330 core\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uIn0;\n" +
        "uniform sampler2D uIn1;\n" +
        "uniform sampler2D uIn2;\n" +
        "uniform int uMode;\n" +
        Render3dGlsl.colorSpaceSource() +
        edit(Render3dGlsl.lightSource() + Render3dGlsl.lightmapLightSource()) + Render3dGlsl.skyLightSource() +
        "void main() {\n" +
        "    ivec2 at = ivec2(int(gl_FragCoord.x), 0);\n" +
        "    vec3 a = texelFetch(uIn0, at, 0).xyz;\n" +
        "    vec3 b = texelFetch(uIn1, at, 0).xyz;\n" +
        "    vec3 c = texelFetch(uIn2, at, 0).xyz;\n" +
        "    vec3 v = uMode == 0 ? lightAt(a, b) : uMode == 1 ? lightmapLightAt(a, b, c) : uMode == 2 ? fogAt(a, c) : skyAt(c);\n" +
        "    fragColor = vec4(v, 1.0);\n" +
        "}\n"

    def shadowFragment(): String =
        "#version 330 core\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uIn0;\n" +
        Render3dGlsl.colorSpaceSource() +
        Render3dGlsl.lightSource() +
        "void main() {\n" +
        "    fragColor = vec4(shadowLitFraction(texelFetch(uIn0, ivec2(int(gl_FragCoord.x), 0), 0).xyz), 0.0, 0.0, 1.0);\n" +
        "}\n"

    def tbnFragment(): String =
        "#version 330 core\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uIn0;\n" +
        "uniform sampler2D uIn1;\n" +
        "uniform sampler2D uIn2;\n" +
        "uniform float uStrength;\n" +
        Render3dGlsl.applyNormalMapSource() +
        "void main() {\n" +
        "    ivec2 at = ivec2(int(gl_FragCoord.x), 0);\n" +
        "    fragColor = vec4(applyNormalMap(texelFetch(uIn1, at, 0).xyz, texelFetch(uIn0, at, 0), uStrength, texelFetch(uIn2, at, 0).xyz), 1.0);\n" +
        "}\n"

    /// lightmap の段つきの読み（3D の描き手の sg_texMip は lod を微分から決めた後、この textureLod で読む）。
    def lightmapFragment(): String =
        "#version 330 core\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uIn0;\n" +
        "uniform sampler2D uChain;\n" +
        "void main() {\n" +
        "    vec3 q = texelFetch(uIn0, ivec2(int(gl_FragCoord.x), 0), 0).xyz;\n" +
        "    fragColor = vec4(textureLod(uChain, q.xy, q.z).rgb, 1.0);\n" +
        "}\n"

    /// 色の空間の変換（uMode 0 = r3d_srgbToLinear3・1 = r3d_linearToSrgb3）。
    def colorSpaceFragment(): String =
        "#version 330 core\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uIn0;\n" +
        "uniform int uMode;\n" +
        Render3dGlsl.colorSpaceSource() +
        "void main() {\n" +
        "    vec3 a = texelFetch(uIn0, ivec2(int(gl_FragCoord.x), 0), 0).xyz;\n" +
        "    fragColor = vec4(uMode == 0 ? r3d_srgbToLinear3(a) : r3d_linearToSrgb3(a), 1.0);\n" +
        "}\n"

    /// 色を作る最後の組み立て r3d_surfaceOut（a = 点・b = 線形の albedo・c = emission・a.w b.w c.w = 光。かすみあり）。
    def surfaceFragment(): String =
        "#version 330 core\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uIn0;\n" +
        "uniform sampler2D uIn1;\n" +
        "uniform sampler2D uIn2;\n" +
        "uniform vec3 uTint;\n" +
        "uniform float uEmissionIntensity;\n" +
        Render3dGlsl.colorSpaceSource() +
        Render3dGlsl.lightSource() +
        "void main() {\n" +
        "    ivec2 at = ivec2(int(gl_FragCoord.x), 0);\n" +
        "    vec4 a = texelFetch(uIn0, at, 0);\n" +
        "    vec4 b = texelFetch(uIn1, at, 0);\n" +
        "    vec4 c = texelFetch(uIn2, at, 0);\n" +
        "    fragColor = vec4(r3d_surfaceOut(b.xyz, uTint, vec3(a.w, b.w, c.w), c.xyz, uEmissionIntensity, a.xyz, true), 1.0);\n" +
        "}\n"

    def colorSpaceModes(): List[Int32] = 0 :: 1 :: Nil

    def colorSpaceSets(): List[List[(String, RowUniform)]] =
        colorSpaceModes() |> List.map(m -> ("uMode", RowUniform.IntValue(m)) :: Nil)

    /// 色を作る最後の組み立ての行の uniform。かすみの色は CPU の surfaceOutAt が中で線形へ戻すのと同じ値を、外で戻してから渡す。
    def surfaceUniforms(s: LightSet, d: SurfaceDraw): List[(String, RowUniform)] =
        let fog = Texture3d.srgbToLinearColor(colorOf(s#fogColor));
        ("uFogOn", RowUniform.IntValue(1)) :: ("uFogColor", RowUniform.Vec3Value(fog#r, fog#g, fog#b)) ::
        ("uFogRange", RowUniform.Vec2Value(s#fogNear, s#fogFar)) :: ("uEye", vec3U(s#eye)) ::
        ("uTint", vec3U(d#tint)) :: ("uEmissionIntensity", RowUniform.FloatValue(d#intensity)) :: Nil

    def surfaceSets(inputs: Inputs): List[List[(String, RowUniform)]] =
        List.zip(inputs#sets, inputs#surfaceDraws) |> List.map(sd -> { let (s, d) = sd; surfaceUniforms(s, d) })

    def rowTexture(name: String, probes: List[Probe], pick: Probe -> (Float64, Float64, Float64, Float64)): RowTexture =
        let values = probes |> List.flatMap(pr -> { let (x, y, z, w) = pick(pr); x :: y :: z :: w :: Nil })
                            |> List.map(Float64.truncateToFloat32) |> List.toVector;
        { sampler = name, levels = { width = List.length(probes), height = 1, texels = RowTexels.Float32Rgba(values) } :: Nil, linear = false }

    def probeTextures(probes: List[Probe]): List[RowTexture] =
        rowTexture("uIn0", probes, pr -> pr#a) :: rowTexture("uIn1", probes, pr -> pr#b) :: rowTexture("uIn2", probes, pr -> pr#c) :: Nil

    def flatten(vs: List[Vec3.Vec3], size: Int32): Vector[Float64] =
        let given = vs |> List.flatMap(v -> v#x :: v#y :: v#z :: Nil);
        List.toVector(given ::: List.repeat(3 * (size - List.length(vs)), 0.0))

    def padded(xs: List[Float64], size: Int32, fill: Float64): Vector[Float64] =
        List.toVector(xs ::: List.repeat(size - List.length(xs), fill))

    def vec3U(v: Vec3.Vec3): RowUniform = RowUniform.Vec3Value(v#x, v#y, v#z)

    def lightColor(c: Color, intensity: Float64): Vec3.Vec3 = Vec3.v3(c#r * intensity, c#g * intensity, c#b * intensity)

    /// 3D の描き手が光を uniform へ渡す形（Render3d の lightDataOf と同じ値）。
    def lightUniforms(s: LightSet, steps: Int32, row: TreeRow): List[(String, RowUniform)] =
        let np = Scene3d.maxPointLights();
        let ns = Scene3d.maxSpotLights();
        let cones = s#spots |> List.flatMap(l -> { let e = Scene3d.spotConeOf(l); e#outerCos :: e#innerCos :: Nil });
        ("uMode", RowUniform.IntValue(modeOf(row))) ::
        ("uAmbient", vec3U(s#ambient)) :: ("uHemisphere", RowUniform.FloatValue(s#hemisphere)) :: ("uToonSteps", RowUniform.IntValue(steps)) ::
        ("uPointCount", RowUniform.IntValue(List.length(s#points))) ::
        ("uPointPos", RowUniform.Vec3Array(flatten(s#points |> List.map(l -> l#position), np))) ::
        ("uPointColor", RowUniform.Vec3Array(flatten(s#points |> List.map(l -> lightColor(l#color, l#intensity)), np))) ::
        ("uPointRange", RowUniform.FloatArray(padded(s#points |> List.map(l -> Float64.max(0.000001, l#range)), np, 1.0))) ::
        ("uSpotCount", RowUniform.IntValue(List.length(s#spots))) ::
        ("uSpotPos", RowUniform.Vec3Array(flatten(s#spots |> List.map(l -> l#position), ns))) ::
        ("uSpotDir", RowUniform.Vec3Array(flatten(s#spots |> List.map(l -> Vec3.normalized(Vec3.sub(l#target, l#position))), ns))) ::
        ("uSpotColor", RowUniform.Vec3Array(flatten(s#spots |> List.map(l -> lightColor(l#color, l#intensity)), ns))) ::
        ("uSpotRange", RowUniform.FloatArray(padded(s#spots |> List.map(l -> Float64.max(0.000001, l#range)), ns, 1.0))) ::
        ("uSpotCone", RowUniform.Vec2Array(padded(cones, 2 * ns, 0.0))) ::
        ("uShadowOn", RowUniform.IntValue(0)) ::
        ("uFogOn", RowUniform.IntValue(1)) :: ("uFogColor", vec3U(s#fogColor)) :: ("uFogRange", RowUniform.Vec2Value(s#fogNear, s#fogFar)) ::
        ("uEye", vec3U(s#eye)) ::
        ("uLightmapSrgb", RowUniform.IntValue(if (s#lightmapSrgb) 1 else 0)) :: ("uLightmapIntensity", RowUniform.FloatValue(s#lightmapIntensity)) ::
        ("uZenith", vec3U(s#zenith)) :: ("uHorizon", vec3U(s#horizon)) :: ("uGround", vec3U(s#ground)) :: ("uCurve", RowUniform.FloatValue(s#curve)) :: Nil

    def treeSets(sets: List[LightSet]): List[List[(String, RowUniform)]] =
        sets |> List.flatMap(s -> treeRows() |> List.map(row -> lightUniforms(s, 0, row)))

    def shadowUniforms(sc: ShadowCase, radius: Int32): List[(String, RowUniform)] =
        ("uShadowMatrix", RowUniform.Matrix(sc#matrix)) :: ("uShadowBias", RowUniform.FloatValue(sc#bias)) ::
        ("uShadowPcf", RowUniform.IntValue(radius)) :: Nil

    /// 光の組の 0 番のスポットが影を落とす時の uniform（地図は影の行と同じ物。lightUniforms の後に置いて uShadowOn を上書きする）。
    def shadowedSpotUniforms(sc: ShadowCase, s: LightSet): List[(String, RowUniform)] =
        ("uShadowOn", RowUniform.IntValue(1)) :: ("uShadowSpot", RowUniform.IntValue(0)) ::
        ("uShadowMatrix", RowUniform.Matrix(shadowMatrixOf(s))) :: ("uShadowBias", RowUniform.FloatValue(sc#bias)) ::
        ("uShadowPcf", RowUniform.IntValue(shadowedPcf())) :: ("uShadowStrength", RowUniform.FloatValue(shadowedStrength())) :: Nil

    def shadowedPcf(): Int32 = 1

    def shadowedStrength(): Float64 = 0.75

    def shadowMatrixOf(s: LightSet): Mat4.Mat4 = match List.head(s#spots) {
        case Some(spot) => Scene3d.shadowMatrix(spot)
        case None       => Mat4.identity()
    }

    /// CPU の描き手へ渡す同じ影（shadowedSpotUniforms と同じ値）。
    def cpuShadowOf(sc: ShadowCase, s: LightSet): SoftRaster3d.SpotShadow =
        SoftRaster3d.spotShadowOf(0, SoftRaster3d.rowMajorOf(shadowMatrixOf(s)), sc#size, sc#bias, shadowedPcf(), shadowedStrength(), sc#map)

    def shadowRadii(): List[Int32] = 0 :: 1 :: 2 :: Nil

    def shadowMapTexture(sc: ShadowCase): RowTexture =
        let values = sc#map |> Vector.flatMap(d -> Vector#{Float64.truncateToFloat32(d), 0.0f32, 0.0f32, 1.0f32});
        { sampler = "uShadowMap", levels = { width = sc#size, height = sc#size, texels = RowTexels.Float32Rgba(values) } :: Nil, linear = false }

    def chainTexture(chain: Vector[ShaderEval.TexData]): RowTexture =
        { sampler = "uChain", linear = true,
          levels = chain |> Vector.toList |> List.map(td -> { width = td#width, height = td#height, texels = RowTexels.Argb8(td#pixels) }) }

    /// 減衰の 2 乗を外した式（壊した式の確かめ）。字が変わって置き換えが当たらないと差が出ず、行が落ちて知らせる。
    def breakFalloff(glsl: String): String = String.replace(src = "(falloff_l2 * falloff_l2)", dst = "falloff_l2", glsl)

    /// cone の内と外を入れ替えた式。
    def breakCone(glsl: String): String = String.replace(src = "smoothstep(", dst = "1.0 - smoothstep(", glsl)

    /// GPU の値を全部読み返す（今の糸に GL の文脈がある所で呼ぶ）。
    pub def drawGl(inputs: Inputs): Result[String, GlRows] \ IO =
        let texs = probeTextures(inputs#light);
        let brokenSet = setWithSpotsAndPoints(inputs) |> Option.map(s -> lightUniforms(s, 0, TreeRow.Light) :: Nil) |> Option.getWithDefault(Nil);
        let shadowedSet = setWithSpotsAndPoints(inputs) |> Option.map(s -> (lightUniforms(s, 0, TreeRow.Light) ::: shadowedSpotUniforms(inputs#shadow, s)) :: Nil)
                                          |> Option.getWithDefault(Nil);
        forM (
            tree <- GlOffscreen.drawFloatRows(treeFragment(x -> x), count(), texs, treeSets(inputs#sets));
            shadowedLight <- GlOffscreen.drawFloatRows(treeFragment(x -> x), count(), texs ::: shadowMapTexture(inputs#shadow) :: Nil, shadowedSet);
            toon <- GlOffscreen.drawFloatRows(treeFragment(x -> x), count(), texs, inputs#sets |> List.map(s -> lightUniforms(s, toonSteps(), TreeRow.Light)));
            brokenFalloff <- GlOffscreen.drawFloatRows(treeFragment(breakFalloff), count(), texs, brokenSet);
            brokenCone <- GlOffscreen.drawFloatRows(treeFragment(breakCone), count(), texs, brokenSet);
            shadow <- GlOffscreen.drawFloatRows(shadowFragment(), count(),
                          rowTexture("uIn0", inputs#shadowPoints, pr -> pr#a) :: shadowMapTexture(inputs#shadow) :: Nil,
                          shadowRadii() |> List.map(r -> shadowUniforms(inputs#shadow, r)));
            tbn <- GlOffscreen.drawFloatRows(tbnFragment(), count(), probeTextures(inputs#tbn), (("uStrength", RowUniform.FloatValue(inputs#strength)) :: Nil) :: Nil);
            lightmap <- GlOffscreen.drawFloatRows(lightmapFragment(), count(),
                            rowTexture("uIn0", inputs#lightmapUv, pr -> pr#a) :: chainTexture(inputs#chain) :: Nil, Nil :: Nil);
            colorSpace <- GlOffscreen.drawFloatRows(colorSpaceFragment(), count(), rowTexture("uIn0", inputs#colorSpace, pr -> pr#a) :: Nil, colorSpaceSets());
            surface <- GlOffscreen.drawFloatRows(surfaceFragment(), count(), probeTextures(inputs#surface), surfaceSets(inputs))
        ) yield {
            tree = tree, toon = toon, shadowedLight = firstOf(shadowedLight), brokenFalloff = firstOf(brokenFalloff), brokenCone = firstOf(brokenCone),
            shadow = shadow, tbn = firstOf(tbn), lightmap = firstOf(lightmap),
            colorSpace = colorSpace, surface = surface
        }

    /// 点光源とスポットを共に持つ最初の光の組（壊した式と影の行が使う）。
    def setWithSpotsAndPoints(inputs: Inputs): Option[LightSet] =
        inputs#sets |> List.find(s -> not List.isEmpty(s#spots) and not List.isEmpty(s#points))

    def firstOf(rows: List[Vector[Float32]]): Vector[Float32] = List.head(rows) |> Option.getWithDefault(Vector.empty())

    // ── CPU と比べる ──

    def rgbAt(row: Vector[Float32], i: Int32): (Float64, Float64, Float64) =
        (Float32.toFloat64(Vector.get(4 * i, row)), Float32.toFloat64(Vector.get(4 * i + 1, row)), Float32.toFloat64(Vector.get(4 * i + 2, row)))

    def relDiff(g: (Float64, Float64, Float64), c: (Float64, Float64, Float64)): Float64 =
        let (gx, gy, gz) = g;
        let (cx, cy, cz) = c;
        let one = (a: Float64, b: Float64) -> Float64.abs(a - b) / Float64.max(1.0, Float64.abs(b));
        Float64.max(one(gx, cx), Float64.max(one(gy, cy), one(gz, cz)))

    def xyz(t: (Float64, Float64, Float64, Float64)): Vec3.Vec3 = { let (x, y, z, _) = t; Vec3.v3(x, y, z) }

    /// 光の式の CPU の値（3D の CPU の描き手が回す SoftRaster3dLight の関数そのもの）。
    def cpuTree(s: LightSet, steps: Int32, row: TreeRow, pr: Probe): (Float64, Float64, Float64) = cpuTreeWith(None, s, steps, row, pr)

    def cpuTreeWith(shadow: SoftRaster3d.SpotShadow, s: LightSet, steps: Int32, row: TreeRow, pr: Probe): (Float64, Float64, Float64) =
        let p = xyz(pr#a);
        let n = xyz(pr#b);
        let e = xyz(pr#c);
        let points = LightModel3d.packPointLights(s#points);
        let spots = LightModel3d.packSpotLights(s#spots);
        match row {
            case TreeRow.Light => SoftRaster3dLight.lightAt(steps, points, spots, shadow, p#x, p#y, p#z, n#x, n#y, n#z, s#ambient#x, s#ambient#y, s#ambient#z, s#hemisphere)
            case TreeRow.LightmapLight => SoftRaster3dLight.lightmapLightAt(steps, points, spots, shadow, p#x, p#y, p#z, n#x, n#y, n#z, e#x, e#y, e#z,
                                                        if (s#lightmapSrgb) 1.0 else 0.0, s#lightmapIntensity)
            case TreeRow.Fog => SoftRaster3dLight.fogAt(p#x, p#y, p#z, s#eye#x, s#eye#y, s#eye#z, e#x, e#y, e#z, s#fogColor#x, s#fogColor#y, s#fogColor#z, s#fogNear, s#fogFar)
            case TreeRow.Sky => SoftRaster3dLight.skyAt(e#x, e#y, e#z, s#zenith#x, s#zenith#y, s#zenith#z, s#horizon#x, s#horizon#y, s#horizon#z,
                                              s#ground#x, s#ground#y, s#ground#z, s#curve)
        }

    /// 光の組 s で、点 p が range の端か cone の縁の近くにあるか（光の行で外す組）。
    def nearEdge(s: LightSet, p: Vec3.Vec3): Bool =
        let rangeEdge = (pos: Vec3.Vec3, range: Float64) -> {
            let d = Vec3.sub(pos, p);
            let r = Float64.max(range, 0.000001);
            Float64.abs(Vec3.dot(d, d) / (r * r) - 1.0) < edgeGap()
        };
        let coneEdge = (l: Scene3d.SpotLight) -> {
            let e = Scene3d.spotConeOf(l);
            let toward = Vec3.normalized(Vec3.sub(p, l#position));
            let c = Vec3.dot(toward, Vec3.normalized(Vec3.sub(l#target, l#position)));
            Float64.abs(c - e#outerCos) < edgeGap() or Float64.abs(c - e#innerCos) < edgeGap()
        };
        List.exists(l -> rangeEdge(l#position, l#range), s#points) or
        List.exists(l -> rangeEdge(l#position, l#range) or coneEdge(l), s#spots)

    /// 比べた結果。worst = 外さなかった組の差の最大・skipped = 外した組の数・total = 組の数。
    type alias Outcome = { worst = Float64, skipped = Int32, total = Int32 }

    def outcomeOf(pairs: List[Option[Float64]]): Outcome =
        { worst = pairs |> List.filterMap(x -> x) |> List.foldLeft(Float64.max, 0.0),
          skipped = pairs |> List.count(Option.isEmpty), total = List.length(pairs) }

    def treeOutcome(inputs: Inputs, rows: GlRows, wanted: TreeRow -> Bool): Outcome =
        let draws = List.zip(inputs#sets |> List.flatMap(s -> treeRows() |> List.map(row -> (s, row))), rows#tree);
        outcomeOf(draws |> List.filter(d -> wanted(snd(fst(d)))) |> List.flatMap(d -> {
            let ((s, kind), values) = d;
            inputs#light |> List.mapWithIndex((i, pr) ->
                if (readsLights(kind) and nearEdge(s, xyz(pr#a))) None else Some(relDiff(rgbAt(values, i), cpuTree(s, 0, kind, pr))))
        }))

    /// 0 番のスポットが影を落とす光の組の lightAt の差（木の中の「届く光と cone が共に正の時だけ地図を引く」を通す）。
    def shadowedOutcome(inputs: Inputs, rows: GlRows): Outcome =
        match setWithSpotsAndPoints(inputs) {
            case None    => { worst = 1.0, skipped = 0, total = 0 }
            case Some(s) =>
                let shadow = cpuShadowOf(inputs#shadow, s);
                outcomeOf(inputs#light |> List.mapWithIndex((i, pr) ->
                    if (nearEdge(s, xyz(pr#a))) None else Some(relDiff(rgbAt(rows#shadowedLight, i), cpuTreeWith(shadow, s, 0, TreeRow.Light, pr)))))
        }

    /// 影の掛かった組（影を外した CPU の値と違う組）が 1 つも無ければ、地図を引く道を通っていないので落とす。
    def shadowedLine(inputs: Inputs, rows: GlRows): (String, Bool) =
        let shaded = match setWithSpotsAndPoints(inputs) {
            case None    => 0
            case Some(s) =>
                let shadow = cpuShadowOf(inputs#shadow, s);
                inputs#light |> List.count(pr -> relDiff(cpuTreeWith(shadow, s, 0, TreeRow.Light, pr), cpuTree(s, 0, TreeRow.Light, pr)) > 1.0e-6)
        };
        let o = shadowedOutcome(inputs, rows);
        let ok = o#worst <= limitTree() and shaded > 0;
        ("[parity] ${pad("exprShadowLight")} E  ${verdict(ok)} (最大の差 ${sci(o#worst)}・上限 ${sci(limitTree())}・影の掛かった組 ${shaded}/${count()})", ok)

    /// トゥーンの段の番号が違う組の数（境目から 1e−4 以上離れた組だけを数える）と、数えた組の数。
    def toonMismatch(inputs: Inputs, rows: GlRows): (Int32, Int32) =
        let steps = Int32.toFloat64(toonSteps());
        let checked = List.zip(inputs#sets, rows#toon) |> List.flatMap(d -> {
            let (s, row) = d;
            inputs#light |> List.mapWithIndex((i, pr) -> {
                let (rx, ry, rz) = cpuTree(s, 0, TreeRow.Light, pr);
                let (tx, ty, tz) = cpuTree(s, toonSteps(), TreeRow.Light, pr);
                let (gx, gy, gz) = rgbAt(row, i);
                let farFromEdge = (x: Float64) -> { let t = x * steps + 0.5; Float64.abs(t - Float64.round(t)) >= 1.0e-4 };
                let same = (cpu: Float64, g: Float64) -> Float64.round(cpu * steps) == Float64.round(g * steps);
                if (nearEdge(s, xyz(pr#a)) or not (farFromEdge(rx) and farFromEdge(ry) and farFromEdge(rz))) None
                else Some(same(tx, gx) and same(ty, gy) and same(tz, gz))
            })
        }) |> List.filterMap(x -> x);
        (List.count(ok -> not ok, checked), List.length(checked))

    def brokenOutcome(inputs: Inputs, row: Vector[Float32]): Float64 =
        match setWithSpotsAndPoints(inputs) {
            case None    => 0.0
            case Some(s) =>
                if (Vector.isEmpty(row)) 0.0
                else inputs#light |> List.mapWithIndex((i, pr) -> relDiff(rgbAt(row, i), cpuTree(s, 0, TreeRow.Light, pr))) |> List.foldLeft(Float64.max, 0.0)
        }

    /// 影の行の差の最大（割合の差を 1 段 = 1 / (2r + 1)² で割った値）。
    def shadowSteps(inputs: Inputs, rows: GlRows): Float64 =
        let sc = inputs#shadow;
        let rowsMajor = SoftRaster3d.rowMajorOf(sc#matrix);
        List.zip(shadowRadii(), rows#shadow) |> List.flatMap(d -> {
            let (r, row) = d;
            let side = Int32.toFloat64(2 * r + 1);
            inputs#shadowPoints |> List.mapWithIndex((i, pr) -> {
                let p = xyz(pr#a);
                let cpu = SoftRaster3d.shadowLitFractionAt(rowsMajor, sc#size, sc#bias, r, sc#map, p#x, p#y, p#z);
                let (g, _, _) = rgbAt(row, i);
                Float64.abs(g - cpu) * side * side
            })
        }) |> List.foldLeft(Float64.max, 0.0)

    /// PCF の行で、照らされている割合が 0 と 1 の間の組の数（0 なら地図の数え方を通っていないので落とす）。
    def partlyShadowed(inputs: Inputs): Int32 =
        let sc = inputs#shadow;
        let m = SoftRaster3d.rowMajorOf(sc#matrix);
        shadowRadii() |> List.map(r -> inputs#shadowPoints |> List.count(pr -> {
            let p = xyz(pr#a);
            let lit = SoftRaster3d.shadowLitFractionAt(m, sc#size, sc#bias, r, sc#map, p#x, p#y, p#z);
            lit > 0.0 and lit < 1.0
        })) |> List.sum

    def tbnOutcome(inputs: Inputs, rows: GlRows): Outcome =
        outcomeOf(inputs#tbn |> List.mapWithIndex((i, pr) -> {
            let (_, _, _, w) = pr#a;
            let (cx, cy, cz, _) = pr#c;
            let v = SoftRaster3d.applyNormalMap(xyz(pr#b), xyz(pr#a), w, inputs#strength, (cx, cy, cz));
            Some(relDiff(rgbAt(rows#tbn, i), (v#x, v#y, v#z)))
        }))

    def lightmapOutcome(inputs: Inputs, rows: GlRows): Outcome =
        outcomeOf(inputs#lightmapUv |> List.mapWithIndex((i, pr) -> {
            let (u, v, lod, _) = pr#a;
            Some(relDiff(rgbAt(rows#lightmap, i), ShaderEval.sampleMipRgb(inputs#chain, { linear = true, repeat = false }, lod, u, v)))
        }))

    /// r3d_srgbToLinear3（uMode 0）と r3d_linearToSrgb3（uMode 1）の値と Texture3d の式の差。
    def colorSpaceOutcome(inputs: Inputs, rows: GlRows): Outcome =
        let convert = (mode: Int32, x: Float64) -> if (mode == 0) Texture3d.srgbToLinear(x) else Texture3d.linearToSrgb(x);
        outcomeOf(List.zip(colorSpaceModes(), rows#colorSpace) |> List.flatMap(d -> {
            let (mode, values) = d;
            inputs#colorSpace |> List.mapWithIndex((i, pr) -> {
                let (x, y, z, _) = pr#a;
                Some(relDiff(rgbAt(values, i), (convert(mode, x), convert(mode, y), convert(mode, z))))
            })
        }))

    /// r3d_surfaceOut と SoftRaster3d.surfaceOutAt（かすみあり）の差。
    def surfaceOutcome(inputs: Inputs, rows: GlRows): Outcome =
        let draws = List.zip(List.zip(inputs#sets, inputs#surfaceDraws), rows#surface);
        outcomeOf(draws |> List.flatMap(d -> {
            let ((s, sd), values) = d;
            let env = { ambient = Color.rgb(0.0, 0.0, 0.0), hemisphere = 0.0, toonSteps = 0, background = None,
                        fog = Some({ color = colorOf(s#fogColor), near = s#fogNear, far = s#fogFar }) };
            inputs#surface |> List.mapWithIndex((i, pr) -> {
                let (px, py, pz, lr) = pr#a;
                let (ar, ag, ab, lg) = pr#b;
                let (er, eg, eb, lb) = pr#c;
                let c = SoftRaster3d.surfaceOutAt(env, s#eye, Vec3.v3(px, py, pz), Color.rgb(ar, ag, ab), colorOf(sd#tint),
                                                  Color.rgb(lr, lg, lb), Color.rgb(er, eg, eb), sd#intensity, true);
                Some(relDiff(rgbAt(values, i), (c#r, c#g, c#b)))
            })
        }))

    /// 行の合否の字。
    def verdict(ok: Bool): String = if (ok) "一致" else "違う"

    /// x を「1.23e-7」の形の字に。
    def sci(x: Float64): String =
        if (x == 0.0) "0"
        else unsafe IO {
            let e = JMath.floor(JMath.log10(Float64.abs(x)));
            let m = JMath.round(x / JMath.pow(10.0, e) * 100.0);
            "${Float64.toString(Int64.toFloat64(m) / 100.0)}e${Int64.toString(JMath.round(e))}"
        }

    def pad(s: String): String = if (String.length(s) >= 14) s else pad(s + " ")

    def lineOf(name: String, o: Outcome, limit: Float64): (String, Bool) =
        let ok = o#worst <= limit;
        let skipped = if (o#skipped == 0) "" else "・外した組 ${o#skipped}/${o#total}";
        ("[parity] ${pad(name)} E  ${verdict(ok)} (最大の差 ${sci(o#worst)}・上限 ${sci(limit)}${skipped})", ok)

    /// 全部の式の行を CPU と比べて 1 行ずつ出し、全部が上限の中なら真。
    pub def report(inputs: Inputs, gl: Result[String, GlRows]): Bool \ IO =
        match gl {
            case Err(why) =>
                println("[parity] exprRows       E  比較不能（${why}）");
                false
            case Ok(rows) =>
                let (toonBad, toonTotal) = toonMismatch(inputs, rows);
                let toonOk = toonBad == 0 and toonTotal > 0;
                let brokenFalloff = brokenOutcome(inputs, rows#brokenFalloff);
                let brokenCone = brokenOutcome(inputs, rows#brokenCone);
                let brokenOk = brokenFalloff > brokenAtLeast() and brokenCone > brokenAtLeast();
                let shadowWorst = shadowSteps(inputs, rows);
                let partial = partlyShadowed(inputs);
                let shadowOk = shadowWorst <= pcfStepsLimit() and partial > 0;
                let lines =
                    lineOf("exprLight", treeOutcome(inputs, rows, readsLights), limitTree()) ::
                    shadowedLine(inputs, rows) ::
                    lineOf("exprFog", treeOutcome(inputs, rows, k -> k == TreeRow.Fog), limitTree()) ::
                    lineOf("exprSky", treeOutcome(inputs, rows, k -> k == TreeRow.Sky), limitTree()) ::
                    ("[parity] ${pad("exprToon")} E  ${verdict(toonOk)} (段の番号が違う組 ${toonBad}/${toonTotal})", toonOk) ::
                    ("[parity] ${pad("exprBroken")} E  ${verdict(brokenOk)} (壊した式の差 減衰 ${sci(brokenFalloff)}・cone ${sci(brokenCone)}・どちらも ${sci(brokenAtLeast())} を超えるはず)", brokenOk) ::
                    ("[parity] ${pad("exprPcf")} E  ${verdict(shadowOk)} (最大の差 ${sci(shadowWorst)} 段・上限 1 段・一部だけ影の組 ${partial})", shadowOk) ::
                    lineOf("exprTbn", tbnOutcome(inputs, rows), limitTree()) ::
                    lineOf("exprLightmapLod", lightmapOutcome(inputs, rows), limitTexture()) ::
                    lineOf("exprColorSpace", colorSpaceOutcome(inputs, rows), limitTree()) ::
                    lineOf("exprSurfaceOut", surfaceOutcome(inputs, rows), limitTree()) :: Nil;
                List.forEach(l -> println(fst(l)), lines);
                List.forAll(snd, lines)
        }
}
