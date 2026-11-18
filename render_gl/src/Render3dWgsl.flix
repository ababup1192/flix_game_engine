// Render3dWgsl — 3D の描き手の WebGPU の frag の WGSL（Render3dGlsl の材質の frag・頂点の色の frag と、それが使う光・影・色の空間・法線マップ・環境マップ・lightmap の関数）。
// 式は Render3dGlsl と 1 行ずつ同じに書き、光・かすみ・空の式は同じ LightModel3d の木から LightModel3d.Codegen.toWgsl で作る。
//
// bind group: 0 = 場面（`var<uniform> r3d: R3dScene`・影の地図・太陽の影の地図・環境マップ・目と射影の行列とカメラの向き）・1 = 材質（ShaderGen.Wgsl.compile3d の `sg` と絵・
// `var<uniform> r3dDraw: R3dDraw`・法線マップ・lightmap。ビルボードは 2D の描き手の絵と sampler）・2 = storage（姿勢）。varying の location は R3dIn の並び。
// 射影の行列は GL の物のまま使い、頂点シェーダーが ShaderGen.Wgsl.clipFromGlSource の sg_clipFromGl で clip の z を 0..w へ移す前提
// （奥行きの値が GL のウィンドウの奥行きと同じになり、影の比べ ndc.z × 0.5 + 0.5 をそのまま使える）。
pub mod Render3dWgsl {
    use LightModel3d.Vec3Input

    /// 場面の値の struct と、場面の絵の宣言（group 0）。struct の欄と並びは Render3d.UniformLayout.sceneFields（詰める側も同じ表から位置を引く）。
    /// f32 と vec2 の光の配列は、uniform の配列の 16 バイト刻みに合わせて vec4 の配列にした（x・y を読む。LightModel3d.Codegen の WGSL の欄と同じ）。
    pub def sceneDeclarations(): String =
        Render3d.UniformLayout.structSource("R3dScene", Render3d.UniformLayout.sceneFields()) +
        "@group(0) @binding(0) var<uniform> r3d: R3dScene;\n" +
        "@group(0) @binding(1) var uShadowMap: texture_depth_2d;\n" +
        "@group(0) @binding(2) var uSunMap: texture_depth_2d;\n" +
        "@group(0) @binding(3) var uEnvMap: texture_2d<f32>;\n" +
        "@group(0) @binding(4) var uEnvSampler: sampler;\n"

    /// 変種 v の pipeline だけが group 0 に足す binding（どちらも偽なら空の字）。6 = 点光源の影と光の量の読み方の値の buffer（R3dLight・+ps か +pu）・
    /// 7 = 点光源の影の atlas（+ps だけ）。R3dLight の欄の名前は Render3dGlsl の uniform と同じで、並びは Render3d.UniformLayout.lightFields。
    // WhyNot: 既定の R3dScene の struct に欄を足さない — 既定の pipeline の WGSL の字と group 0 の layout が変わり、変種を使わない場面まで値の並びが動く。
    pub def variantDeclarations(v: Render3d.ShaderVariant): String =
        if (not v#pointShadows and not v#physicalUnits) ""
        else
            Render3d.UniformLayout.structSource("R3dLight", Render3d.UniformLayout.lightFields()) +
            "@group(0) @binding(${lightBinding()}) var<uniform> r3dLight: R3dLight;\n" +
            (if (v#pointShadows) "@group(0) @binding(${pointShadowMapBinding()}) var uPointShadowMap: texture_depth_2d;\n" else "")

    /// 変種の group 0 の R3dLight の binding。
    pub def lightBinding(): Int32 = 6

    /// 変種 +ps の group 0 の点光源の影の atlas の binding。
    pub def pointShadowMapBinding(): Int32 = 7

    /// R3dLight のバイト数（並びは Render3d.UniformLayout.lightFields）。
    pub def lightValueBytes(): Int32 = Render3d.UniformLayout.bytesOf(Render3d.UniformLayout.lightFields())

    /// 物ごとの値（group 1 の drawBinding() から）。uCutout = cutout の材質か（1.0）・法線マップの強さと mip のレベルの数・lightmap の mip のレベルの数と
    /// 色空間（sRGB なら 1.0）と強さ（LightModel3d.Codegen の WGSL が r3dDraw.uLightmapSrgb・uLightmapIntensity で読む）。
    /// 法線マップは drawBinding() + 1・+ 2、lightmap は + 3・+ 4（使う版だけ宣言する）。並びは Render3d.MaterialValues の物ごとの値の区画と同じ。
    // WhyNot: 法線マップの読みの v を上下に返す値（GLSL の uNormalFlip）を持たない — WebGPU の描き先の texture は上の行が先で、ほかの絵と同じ向き。
    // WhyNot: uCutout を i32 にしない — 値は計画の Float32 の values から読み、整数の bit で書く道を持たない。
    def drawDeclarations(normalMapped: Bool, lightmap: Bool): String =
        let b = drawBinding();
        "struct R3dDraw { uCutout: f32, uNormalStrength: f32, uNormalLevels: f32, uLightmapLevels: f32, uLightmapSrgb: f32, uLightmapIntensity: f32 };\n" +
        "@group(1) @binding(${b}) var<uniform> r3dDraw: R3dDraw;\n" +
        (if (normalMapped) "@group(1) @binding(${b + 1}) var uNormalMap: texture_2d<f32>;\n@group(1) @binding(${b + 2}) var uNormalMapSampler: sampler;\n" else "") +
        (if (lightmap) "@group(1) @binding(${b + 3}) var uLightmap: texture_2d<f32>;\n@group(1) @binding(${b + 4}) var uLightmapSampler: sampler;\n" else "")

    /// group 1 の物ごとの値の binding（材質の絵は ShaderGen.Wgsl の 1〜2 × Scene3d.maxMaterialTextures() を使う）。
    pub def drawBinding(): Int32 = 16

    /// 色の空間の変換（Render3dGlsl.colorSpaceSource と同じ）。
    pub def colorSpaceSource(): String =
        Texture3d.srgbToLinearWgsl("r3d_srgbToLinear") +
        Texture3d.linearToSrgbWgsl("r3d_linearToSrgb") +
        "fn r3d_srgbToLinear3(c: vec3f) -> vec3f {\n" +
        "    return vec3f(r3d_srgbToLinear(c.r), r3d_srgbToLinear(c.g), r3d_srgbToLinear(c.b));\n" +
        "}\n" +
        "fn r3d_linearToSrgb3(c: vec3f) -> vec3f {\n" +
        "    return vec3f(r3d_linearToSrgb(c.r), r3d_linearToSrgb(c.g), r3d_linearToSrgb(c.b));\n" +
        "}\n"

    /// 光の式（lightAt）・かすみ（fogged）・影と、色を作る最後の組み立て（Render3dGlsl.lightSource と同じ）。sceneDeclarations と colorSpaceSource の後に置く。
    pub def lightSource(): String = lightSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の lightSource（Render3dGlsl.lightSourceFor と同じ。v が既定でなければ variantDeclarations(v) も置く）。
    pub def lightSourceFor(v: Render3d.ShaderVariant): String = lightSourceWith(shadowSource(), v)

    /// lightSourceFor の、影の関数（spotShadow と r3d_sunLit）を shadows に替えた版。
    def lightSourceWith(shadows: String, v: Render3d.ShaderVariant): String =
        shadows +
        (if (v#pointShadows) pointShadowSource() else "") +
        LightModel3d.Codegen.toWgsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModelFor(Render3d.lightVariantOf(v))) +
        LightModel3d.Codegen.toWgsl("fogAt", Vec3Input.Position :: Vec3Input.Color :: Nil, LightModel3d.fogModel()) +
        "fn fogged(c: vec3f, p: vec3f) -> vec3f {\n" +
        "    if (r3d.uFogOn == 0) { return c; }\n" +
        "    return fogAt(p, c);\n" +
        "}\n" +
        surfaceOutSource()

    /// Render3dGlsl.surfaceOutSource と同じ式。
    pub def surfaceOutSource(): String =
        "fn r3d_surfaceOut(albedoLinear: vec3f, tint: vec3f, light: vec3f, emission: vec3f, intensity: f32, p: vec3f, fogOn: bool) -> vec3f {\n" +
        "    var c = albedoLinear * tint * light;\n" +
        "    if (fogOn) { c = fogged(c, p); }\n" +
        "    return r3d_linearToSrgb3(c + r3d_srgbToLinear3(emission) * intensity);\n" +
        "}\n"

    /// 影の地図の PCF（Render3dGlsl.shadowSource と同じ約束 1〜5）と、スポットと太陽の影の割合。
    /// 地図の画素の数え方は GL と同じ（行 0 が NDC の y = −1）で、読む時だけ行を上下に返す: WebGPU で描いた地図は行 0 が NDC の y = +1。
    // WhyNot: 周りの画素を返した後の行で端にそろえない — 端にそろえる（clamp）のを GL の行で済ませてから返せば、CPU の描き手と同じ画素の組を読む。
    pub def shadowSource(): String =
        shadowLitFractionSource() +
        "fn spotShadow(i: i32, p: vec3f) -> f32 {\n" +
        "    if (r3d.uShadowOn == 0 || i != r3d.uShadowSpot) { return 1.0; }\n" +
        "    return 1.0 - r3d.uShadowStrength * (1.0 - shadowLitFraction(uShadowMap, r3d.uShadowMatrix, r3d.uShadowBias, r3d.uShadowPcf, 0.0, vec3f(0.0), p));\n" +
        "}\n" +
        sunShadowSource()

    /// 影の地図の PCF（shadowSource の頭）。
    def shadowLitFractionSource(): String =
        "fn shadowLitFraction(map: texture_depth_2d, lightMatrix: mat4x4f, bias: f32, pcf: i32, shift: f32, n: vec3f, p: vec3f) -> f32 {\n" +
        "    let c = lightMatrix * vec4f(p + n * shift, 1.0);\n" +
        "    if (c.w <= 0.0) { return 1.0; }\n" +
        "    let ndc = c.xyz / c.w;\n" +
        "    if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) { return 1.0; }\n" +
        "    let z = (ndc.z * 0.5 + 0.5) - bias;\n" +
        "    let size = vec2i(textureDimensions(map, 0));\n" +
        "    let last = size - vec2i(1);\n" +
        "    let center = clamp(vec2i(floor((ndc.xy * 0.5 + 0.5) * vec2f(size))), vec2i(0), last);\n" +
        "    var lit = 0;\n" +
        "    var total = 0;\n" +
        "    for (var dy = -pcf; dy <= pcf; dy++) {\n" +
        "        for (var dx = -pcf; dx <= pcf; dx++) {\n" +
        "            let t = clamp(center + vec2i(dx, dy), vec2i(0), last);\n" +
        "            if (z <= textureLoad(map, vec2i(t.x, last.y - t.y), 0)) { lit++; }\n" +
        "            total++;\n" +
        "        }\n" +
        "    }\n" +
        "    return f32(lit) / f32(total);\n" +
        "}\n"

    /// 太陽の影の割合 sunLitAt と r3d_sunLit（shadowSource の末尾）。
    def sunShadowSource(): String =
        "var<private> r3d_sunLit: f32 = 1.0;\n" +
        "fn sunLitAt(p: vec3f, g: vec3f, n: vec3f) -> f32 {\n" +
        "    if (r3d.uSunShadowOn == 0 || dot(n, r3d.uSunDir) <= 0.0) { return 1.0; }\n" +
        "    let fade = clamp((r3d.uSunFade.x - dot(p - r3d.uEye, r3d.uSunForward)) / r3d.uSunFade.y, 0.0, 1.0);\n" +
        "    if (fade <= 0.0) { return 1.0; }\n" +
        "    return 1.0 - r3d.uSunStrength * fade * (1.0 - shadowLitFraction(uSunMap, r3d.uSunMatrix, r3d.uSunBias, r3d.uSunPcf, r3d.uSunNormalShift, g, p));\n" +
        "}\n"

    /// 点光源の影の割合 r3d_pointShadowLit と、それを点光源の数だけ r3d_pointLit へ埋める r3d_pointShadowsAt（Render3dGlsl.pointShadowSource と同じ式）。
    /// atlas の画素の数え方は GL と同じ（行 0 が ndc.y = −1）で、読む時だけ行を atlas の高さ − 1 − 行 に返す（WebGPU で描いた atlas は行 0 が上）。
    // WhyNot: 周りの画素を返した後の行で面の塊へ寄せない — 面の中へ寄せるのを GL の行で済ませてから返せば、CPU の描き手と同じ画素の組を読む。
    def pointShadowSource(): String =
        let p = Scene3d.maxPointLights();
        "var<private> r3d_pointLit: array<f32, ${p}>;\n" +
        "fn r3d_pointShadowLit(i: i32, p: vec3f, g: vec3f, n: vec3f) -> f32 {\n" +
        "    let shadowed = r3dLight.uPointShadow[i];\n" +
        "    if (shadowed.x < 0.0) { return 1.0; }\n" +
        "    let toLight = r3d.uPointPos[i].xyz - p;\n" +
        "    let reach = r3d.uPointRange[i].x;\n" +
        "    if (dot(toLight, toLight) >= reach * reach || dot(n, toLight) <= 0.0) { return 1.0; }\n" +
        "    let tile = r3dLight.uPointShadowAtlas.x;\n" +
        "    let scale = r3dLight.uPointShadowAtlas.z;\n" +
        "    let d0 = -toLight;\n" +
        "    let major = max(abs(d0.x), max(abs(d0.y), abs(d0.z)));\n" +
        "    let d = d0 + g * (r3dLight.uPointShadowBias.y * 2.0 * major / (scale * tile));\n" +
        "    let a = abs(d);\n" +
        "    var face = 0;\n" +
        "    var along = 0.0;\n" +
        "    var rx = 0.0;\n" +
        "    var uy = 0.0;\n" +
        "    if (a.x >= a.y && a.x >= a.z) {\n" +
        "        let sx = select(-1.0, 1.0, d.x >= 0.0);\n" +
        "        face = select(1, 0, d.x >= 0.0);\n" +
        "        along = sx * d.x;\n" +
        "        rx = -sx * d.z;\n" +
        "        uy = d.y;\n" +
        "    } else if (a.y >= a.z) {\n" +
        "        let sy = select(-1.0, 1.0, d.y >= 0.0);\n" +
        "        face = select(3, 2, d.y >= 0.0);\n" +
        "        along = sy * d.y;\n" +
        "        rx = -sy * d.x;\n" +
        "        uy = d.z;\n" +
        "    } else {\n" +
        "        let sz = select(-1.0, 1.0, d.z >= 0.0);\n" +
        "        face = select(5, 4, d.z >= 0.0);\n" +
        "        along = sz * d.z;\n" +
        "        rx = sz * d.x;\n" +
        "        uy = d.y;\n" +
        "    }\n" +
        "    let near = shadowed.z / (shadowed.y + 1.0);\n" +
        "    if (along <= near) { return 1.0; }\n" +
        "    let refDepth = (shadowed.y - shadowed.z / max(along - r3dLight.uPointShadowBias.x, near)) * 0.5 + 0.5;\n" +
        "    let size = i32(tile);\n" +
        "    let last = vec2i(size - 1);\n" +
        "    let center = clamp(vec2i(floor((vec2f(scale * rx / along, scale * uy / along) * 0.5 + 0.5) * tile)), vec2i(0), last);\n" +
        "    let slot = i32(shadowed.x);\n" +
        "    let columns = i32(r3dLight.uPointShadowAtlas.y);\n" +
        "    let origin = vec2i((slot % columns) * 3 * size + (face % 3) * size, (slot / columns) * 2 * size + (face / 3) * size);\n" +
        "    let pcf = i32(r3dLight.uPointShadowAtlas.w);\n" +
        "    let top = i32(textureDimensions(uPointShadowMap, 0).y) - 1;\n" +
        "    var lit = 0;\n" +
        "    var total = 0;\n" +
        "    for (var dy = -pcf; dy <= pcf; dy++) {\n" +
        "        for (var dx = -pcf; dx <= pcf; dx++) {\n" +
        "            let t = origin + clamp(center + vec2i(dx, dy), vec2i(0), last);\n" +
        "            if (refDepth <= textureLoad(uPointShadowMap, vec2i(t.x, top - t.y), 0)) { lit++; }\n" +
        "            total++;\n" +
        "        }\n" +
        "    }\n" +
        "    return 1.0 - shadowed.w * (1.0 - f32(lit) / f32(total));\n" +
        "}\n" +
        "fn r3d_pointShadowsAt(p: vec3f, g: vec3f, n: vec3f) {\n" +
        "    for (var i = 0; i < ${p}; i++) { r3d_pointLit[i] = r3d_pointShadowLit(i, p, g, n); }\n" +
        "}\n"

    /// ビルボードの影の関数: スポットは遮らない（GLSL のビルボードのプログラムは uShadowOn を付けず 0 のまま読む）。太陽の sunLitAt は置いた物と同じで、
    /// r3d_sunLit は frag が受ける物（vLit が 2）の時だけ代入する（GLSL の uReceive）。
    // WhyNot: 場面の値の uShadowOn で切らない — 場面の group 0 は同じ場面の物の影の地図と on を持ち、ビルボードだけ値を替える binding が無い。
    def billboardShadowSource(): String =
        shadowLitFractionSource() +
        "fn spotShadow(i: i32, p: vec3f) -> f32 { return 1.0; }\n" +
        sunShadowSource()

    def depthGraySource(): String =
        "fn depthGray(p: vec3f) -> f32 {\n" +
        "    return clamp((distance(p, r3d.uEye) - r3d.uDepthRange.x) / r3d.uDepthRange.y, 0.0, 1.0);\n" +
        "}\n"

    /// metallic と roughness を持つ材質の色 pbrAt と、環境マップの読み・かすみ → emission の組み立て（Render3dGlsl.metallicRoughnessSource と同じ）。
    pub def metallicRoughnessSource(): String = metallicRoughnessSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の metallicRoughnessSource。
    pub def metallicRoughnessSourceFor(v: Render3d.ShaderVariant): String =
        environmentSource() +
        LightModel3d.Codegen.toWgsl("pbrAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.Albedo :: Vec3Input.Light :: Vec3Input.MetallicRoughness ::
                                             Vec3Input.EnvironmentColor :: Nil,
                                    LightModel3d.pbrModelFor(Render3d.lightVariantOf(v))) +
        "fn r3d_surfaceOutLit(lit: vec3f, emission: vec3f, intensity: f32, p: vec3f) -> vec3f {\n" +
        "    let c = fogged(lit, p);\n" +
        "    return r3d_linearToSrgb3(c + r3d_srgbToLinear3(emission) * intensity);\n" +
        "}\n"

    /// 環境マップの読み environmentColorAt(p, n, albedo × tint, vec3(metallic, roughness, 0))（Render3dGlsl.environmentSource と同じ式。mip のレベルは roughness × (レベルの数 − 1)）。
    pub def environmentSource(): String =
        LightModel3d.Codegen.toWgsl("environmentDirectionAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.Albedo :: Vec3Input.MetallicRoughness :: Nil,
                                    LightModel3d.environmentDirection()) +
        environmentUvSource() +
        "fn environmentColorAt(p: vec3f, n: vec3f, albedo: vec3f, metalRough: vec3f) -> vec3f {\n" +
        "    let d = environmentDirectionAt(p, n, albedo, metalRough);\n" +
        "    let lod = metalRough.y * (r3d.uEnvLevels - 1.0);\n" +
        "    return r3d_srgbToLinear3(textureSampleLevel(uEnvMap, uEnvSampler, environmentUv(d), lod).rgb) * r3d.uEnvIntensity;\n" +
        "}\n"

    /// 向き d（長さ 1）で環境マップを読む座標 environmentUv(d)（Render3dGlsl.environmentUvSource と同じ式）。
    // WhyNot: 極で atan2 を選ばない形を if にしない — select は両側を計算するが、atan2(0, 0) の値は捨てられる（Flix の atan2 と同じ 0 を選ぶ）。
    def environmentUvSource(): String =
        "fn environmentUv(d: vec3f) -> vec2f {\n" +
        "    let pole = abs(d.x) + abs(d.z) < 1e-12;\n" +
        "    let azimuth = select(atan2(d.x, -d.z), 0.0, pole);\n" +
        "    return vec2f(0.5 + azimuth / 6.283185307179586, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / 3.141592653589793);\n" +
        "}\n"

    /// lightmap の読みと、lightmap のある面の光の式（Render3dGlsl.lightmapSource と同じ）。
    def lightmapSource(v: Render3d.ShaderVariant): String =
        "fn lightmapColor(uv2: vec2f) -> vec3f {\n" +
        "    return sg_texMip(uLightmap, uLightmapSampler, r3dDraw.uLightmapLevels, uv2).rgb;\n" +
        "}\n" +
        LightModel3d.Codegen.toWgsl("lightmapLightAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.LightmapColor :: Nil,
                                    LightModel3d.lightmapLightingModelFor(Render3d.lightVariantOf(v)))

    /// 法線マップで傾けた法線（Render3dGlsl.normalMapSource と同じ式）。
    def normalMapSource(): String =
        applyNormalMapSource() +
        "fn normalMapped(n: vec3f, uv: vec2f, tangent: vec4f) -> vec3f {\n" +
        "    return applyNormalMap(n, tangent, r3dDraw.uNormalStrength, sg_texMip(uNormalMap, uNormalMapSampler, r3dDraw.uNormalLevels, uv).rgb);\n" +
        "}\n"

    /// Render3dGlsl.applyNormalMapSource と同じ式。
    // WhyNot: 長さ 0 の p の normalize を if で避けない — select は両側を計算するが、NaN の側は捨てられる。
    pub def applyNormalMapSource(): String =
        "fn applyNormalMap(n: vec3f, tangent: vec4f, strength: f32, c: vec3f) -> vec3f {\n" +
        "    var t = tangent.xyz - n * dot(n, tangent.xyz);\n" +
        "    if (dot(t, t) < 1e-12) { return n; }\n" +
        "    t = normalize(t);\n" +
        "    let b = cross(n, t) * tangent.w;\n" +
        "    let m = vec3f((c.x * 2.0 - 1.0) * strength, (c.y * 2.0 - 1.0) * strength, c.z * 2.0 - 1.0);\n" +
        "    let p = t * m.x + b * m.y + n * m.z;\n" +
        "    return select(normalize(p), n, dot(p, p) < 1e-12);\n" +
        "}\n"

    /// frag が受ける varying（Render3dGlsl の in の並び）。uv・2 本目の uv・タンジェント・表裏は使う版だけ。
    // WhyNot: flat の値を最後の頂点から取る形（GL の既定）にそろえない — WGSL の flat は最初の頂点を取るが、vTint と vEmissionIntensity は置いた物 1 つで同じ値。
    def inputStruct(surface: Render3d.ProgramKind, normalMapped: Bool): String =
        "struct R3dIn {\n" +
        "    @location(0) vWorld: vec3f,\n" +
        "    @location(1) vNormal: vec3f,\n" +
        "    @location(2) vColor: vec3f,\n" +
        "    @location(3) @interpolate(flat) vTint: vec3f,\n" +
        "    @location(4) @interpolate(flat) vEmissionIntensity: f32,\n" +
        (if (surface#uv) "    @location(5) vUv: vec2f,\n" else "") +
        (if (surface#lightmap) "    @location(6) vUv2: vec2f,\n" else "") +
        (if (normalMapped) "    @location(7) vTangent: vec4f,\n" else "") +
        (if (surface#doubleSided) "    @builtin(front_facing) frontFacing: bool,\n" else "") +
        "};\n"

    /// 材質の frag（Render3dGlsl.materialFragmentSource と同じ組み立て）。入口は fs_main。
    /// 材質の部品は group 1 で作った物（ShaderGen.Wgsl.compile3d(…, 1)）を渡す。
    pub def materialFragmentSource(m: ShaderGen.Wgsl.MaterialWgsl, surface: Render3d.ProgramKind): String =
        let v = Render3d.shaderVariantOfKind(surface);
        let normalMapped = surface#uv and surface#normalMap;
        let needsMip = (normalMapped or surface#lightmap) and List.isEmpty(m#texReads);
        let faceNormal = if (surface#doubleSided) "facingNormal" else "normalize(vNormal)";
        let normal = if (normalMapped) "normalMapped(${faceNormal}, vUv, i.vTangent)" else faceNormal;
        let cutout = if (surface#coverage) "" else "    if (r3dDraw.uCutout > 0.5 && " + m#cutoutAlpha + " < 0.5) { discard; }\n";
        let facing = if (surface#doubleSided) "    let facingNormal = select(-normalize(vNormal), normalize(vNormal), i.frontFacing);\n" else "";
        let alpha = if (surface#coverage) "clamp((" + m#cutoutAlpha + " - 0.5) / max(fwidth(" + m#cutoutAlpha + "), 1e-4) + 0.5, 0.0, 1.0)"
                    else if (surface#blend) "albedo.a" else "1.0";
        let light = if (surface#lightmap) "    let light = lightmapLightAt(vWorld, n, lightmapColor(i.vUv2));\n" else "    let light = lightAt(vWorld, n);\n";
        sceneDeclarations() +
        variantDeclarations(v) +
        drawDeclarations(normalMapped, surface#lightmap) +
        m#declarations +
        inputStruct(surface, normalMapped) +
        colorSpaceSource() +
        lightSourceFor(v) +
        depthGraySource() +
        m#functions +
        (if (needsMip) ShaderGen.Wgsl.texMipSource() else "") +
        (if (normalMapped) normalMapSource() else "") +
        (if (surface#lightmap) lightmapSource(v) else "") +
        (if (surface#metallicRoughness) metallicRoughnessSourceFor(v) else "") +
        "@fragment fn fs_main(i: R3dIn) -> @location(0) vec4f {\n" +
        "    let vWorld = i.vWorld;\n" +
        "    let vNormal = i.vNormal;\n" +
        "    let vColor = i.vColor;\n" +
        "    let vTint = i.vTint;\n" +
        "    let vEmissionIntensity = i.vEmissionIntensity;\n" +
        (if (surface#uv) "    let vUv = i.vUv;\n" else "    let vUv = vec2f(0.0, 0.0);\n") +
        "    let material = materialEval(vUv, vWorld, vNormal, vColor);\n" +
        "    let albedo = material.albedo;\n" +
        "    let emission = material.emission;\n" +
        cutout +
        "    if (r3d.uDepthOut == 1) {\n" +
        "        let g = depthGray(vWorld);\n" +
        "        return vec4f(g, g, g, 1.0);\n" +
        "    }\n" +
        facing +
        "    let n = " + normal + ";\n" +
        "    r3d_sunLit = sunLitAt(vWorld, " + faceNormal + ", n);\n" +
        (if (v#pointShadows) "    r3d_pointShadowsAt(vWorld, " + faceNormal + ", n);\n" else "") +
        light +
        (if (surface#metallicRoughness)
            "    let metalRough = material.metalRough;\n" +
            "    let base = r3d_srgbToLinear3(albedo.rgb) * vTint;\n" +
            "    var envColor = vec3f(0.0);\n" +
            "    if (r3d.uEnvOn == 1) { envColor = environmentColorAt(vWorld, n, base, vec3f(metalRough, 0.0)); }\n" +
            "    let lit = pbrAt(vWorld, n, base, light, vec3f(metalRough, 0.0), envColor);\n" +
            "    return vec4f(r3d_surfaceOutLit(lit, emission, vEmissionIntensity, vWorld), " + alpha + ");\n"
         else
            "    return vec4f(r3d_surfaceOut(r3d_srgbToLinear3(albedo.rgb), vTint, light, emission, vEmissionIntensity, vWorld, true), " + alpha + ");\n") +
        "}\n"

    /// 奥行きの書き出し（Output.Depth）の形だけの frag（Render3dGlsl.depthFragmentSource と同じ）。頂点シェーダーは litVertexSource で、読む varying は vWorld だけ。入口は fs_main。
    pub def depthFragmentSource(): String =
        sceneDeclarations() +
        depthGraySource() +
        "@fragment fn fs_main(@location(0) vWorld: vec3f) -> @location(0) vec4f {\n" +
        "    let g = depthGray(vWorld);\n" +
        "    return vec4f(g, g, g, 1.0);\n" +
        "}\n"

    /// 頂点の色のプログラムの frag（Render3dGlsl.litFragmentSource と同じ。vColor は頂点シェーダーが線形へ戻し済み）。入口は fs_main。
    pub def litFragmentSource(): String = litFragmentSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の litFragmentSource。
    pub def litFragmentSourceFor(v: Render3d.ShaderVariant): String =
        sceneDeclarations() +
        variantDeclarations(v) +
        "struct R3dLitIn {\n" +
        "    @location(0) vWorld: vec3f,\n" +
        "    @location(1) vNormal: vec3f,\n" +
        "    @location(2) vColor: vec3f,\n" +
        "    @location(3) @interpolate(flat) vTint: vec3f,\n" +
        "};\n" +
        colorSpaceSource() +
        lightSourceFor(v) +
        "@fragment fn fs_main(i: R3dLitIn) -> @location(0) vec4f {\n" +
        "    let n = normalize(i.vNormal);\n" +
        "    r3d_sunLit = sunLitAt(i.vWorld, n, n);\n" +
        (if (v#pointShadows) "    r3d_pointShadowsAt(i.vWorld, n, n);\n" else "") +
        "    return vec4f(r3d_surfaceOut(i.vColor, i.vTint, lightAt(i.vWorld, n), vec3f(0.0), 1.0, i.vWorld, true), 1.0);\n" +
        "}\n"

    /// 1 体ごとの値の 1 体のバイト数（Render3d.InstanceValues の 1 体 = 32 float）。
    pub def instanceBytes(): Int32 = 4 * Render3d.InstanceValues.floatsPerInstance()

    /// 目と射影の行列とカメラの向き（group 0 の binding 5）。詰める側は uView・uProj の順に列優先で 128 バイトの後に、
    /// カメラの right・up・カメラへ向く向き（−forward）を xyz に 16 バイトずつ（ビルボードが四角を立て、法線にする。GLSL の uRight・uUp・uFacing）。
    pub def cameraDeclarations(): String =
        "struct R3dCamera { uView: mat4x4f, uProj: mat4x4f, uRight: vec4f, uUp: vec4f, uFacing: vec4f };\n" +
        "@group(0) @binding(5) var<uniform> r3dCamera: R3dCamera;\n"

    /// R3dCamera のバイト数。
    pub def cameraBytes(): Int32 = 176

    /// ビルボードの頂点シェーダー（Render3dGlsl.billboardVertexSource と同じ式）。入口は vs_main。
    /// 四角の角は vertex_index の 6 点（GL の Render3d.buildQuad と同じ並び・y は下向き）。ビルボードの値は buffer 0（instance ごと・stride は値 1 つ）の location 0〜3
    /// （並びは Render3d.SceneList.billboardValueFloats: 点と光の当て方・anchor と size・貼る範囲の uv・tint と影を受ける点を板から離す長さ）。影の地図へ描く時も同じ（group 0 が光の目と板の向き）。
    pub def billboardVertexSource(): String = billboardVertexSourceWith("r3dCamera.uRight.xyz")

    /// 板の横の向きを行の値の tint の rgb から読む billboardVertexSource（点光源の影の面へ描く時。Render3d.SceneList.putBillboardRights）。
    pub def billboardRowRightVertexSource(): String = billboardVertexSourceWith("v.tint.xyz")

    /// right = 板の横の向きの式。
    def billboardVertexSourceWith(right: String): String =
        cameraDeclarations() +
        "struct R3dBillboardIn {\n" +
        "    @location(0) center: vec4f,\n" +
        "    @location(1) anchorSize: vec4f,\n" +
        "    @location(2) uvRect: vec4f,\n" +
        "    @location(3) tint: vec4f,\n" +
        "};\n" +
        billboardVaryings("R3dBillboardOut", true) +
        ShaderGen.Wgsl.clipFromGlSource() +
        "@vertex fn vs_main(@builtin(vertex_index) i: u32, v: R3dBillboardIn) -> R3dBillboardOut {\n" +
        "    var corners = array<vec2f, 6>(vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0));\n" +
        "    let corner = corners[i];\n" +
        "    let world = v.center.xyz + " + right + " * ((corner.x - v.anchorSize.x) * v.anchorSize.z)\n" +
        "                             + r3dCamera.uUp.xyz * ((v.anchorSize.y - corner.y) * v.anchorSize.w);\n" +
        "    var o: R3dBillboardOut;\n" +
        "    o.vWorld = world;\n" +
        "    o.vUv = v.uvRect.xy + corner * v.uvRect.zw;\n" +
        "    o.vTint = v.tint.rgb;\n" +
        "    o.vLit = v.center.w;\n" +
        "    o.vFacing = r3dCamera.uFacing.xyz;\n" +
        "    o.vShadowBase = v.center.xyz + vec3f(0.0, (v.anchorSize.y - corner.y) * v.anchorSize.w, 0.0);\n" +
        "    o.vShadowOffset = v.tint.w;\n" +
        "    o.position = sg_clipFromGl(r3dCamera.uProj * r3dCamera.uView * vec4f(world, 1.0));\n" +
        "    return o;\n" +
        "}\n"

    /// ビルボードの varying（頂点シェーダーの出口は position つき）。vLit = 光の当て方（Render3d.SceneList.billboardValueFloats）・
    /// vShadowBase と vShadowOffset = 太陽の影を受ける点を太陽の方へ進める前の点と、板から水平に離す長さ（Render3dGlsl の vShadowBase・uShadowOffset）。
    def billboardVaryings(name: String, withPosition: Bool): String =
        "struct ${name} {\n" +
        (if (withPosition) "    @builtin(position) position: vec4f,\n" else "") +
        "    @location(0) vWorld: vec3f,\n" +
        "    @location(1) vUv: vec2f,\n" +
        "    @location(2) @interpolate(flat) vTint: vec3f,\n" +
        "    @location(3) @interpolate(flat) vLit: f32,\n" +
        "    @location(4) @interpolate(flat) vFacing: vec3f,\n" +
        "    @location(5) vShadowBase: vec3f,\n" +
        "    @location(6) @interpolate(flat) vShadowOffset: f32,\n" +
        "};\n"

    /// ビルボードの frag（Render3dGlsl.billboardFragmentSource と同じ式）。貼る絵は group 1（2D の描き手の絵の group: binding 0 = 絵・1 = sampler）。入口は fs_main。
    /// vLit が 2（光を当てて太陽の影も受ける）の物だけ、太陽の影の地図を引く。
    pub def billboardFragmentSource(): String = billboardFragmentSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の billboardFragmentSource（点光源の影を受けないので billboardVariantOf(v) の字）。
    pub def billboardFragmentSourceFor(v: Render3d.ShaderVariant): String =
        let bv = Render3d.billboardVariantOf(v);
        sceneDeclarations() +
        variantDeclarations(bv) +
        "@group(1) @binding(0) var uImage: texture_2d<f32>;\n" +
        "@group(1) @binding(1) var uImageSampler: sampler;\n" +
        billboardVaryings("R3dBillboardIn", false) +
        colorSpaceSource() +
        lightSourceWith(billboardShadowSource(), bv) +
        depthGraySource() +
        "@fragment fn fs_main(i: R3dBillboardIn) -> @location(0) vec4f {\n" +
        "    let texel = textureSample(uImage, uImageSampler, i.vUv);\n" +
        "    if (texel.a < 0.5) { discard; }\n" +
        "    if (r3d.uDepthOut == 1) {\n" +
        "        let g = depthGray(i.vWorld);\n" +
        "        return vec4f(g, g, g, 1.0);\n" +
        "    }\n" +
        "    let lit = i.vLit > 0.5;\n" +
        "    if (i.vLit > 1.5) { r3d_sunLit = sunLitAt(i.vShadowBase + r3d.uSunDir * (i.vShadowOffset / max(length(r3d.uSunDir.xz), ${Scene3d.billboardShadowMinFlat()})), r3d.uSunDir, normalize(i.vFacing)); }\n" +
        "    var light = vec3f(1.0);\n" +
        "    if (lit) { light = lightAt(i.vWorld, normalize(i.vFacing)); }\n" +
        "    return vec4f(r3d_surfaceOut(r3d_srgbToLinear3(texel.rgb), i.vTint, light, vec3f(0.0), 1.0, i.vWorld, lit), 1.0);\n" +
        "}\n"

    /// ビルボードを影の地図へ描く frag（色を出さず、絵の α < 0.5 の画素を捨てるだけ。GL は billboardFragmentSource の uDepthOut の枝で同じ事をする）。
    /// 頂点シェーダーは billboardVertexSource（group 0 は影の地図の光の目・R3dCamera の uRight と uUp に板の向き）。貼る絵は group 1。入口は fs_main。
    pub def billboardShadowFragmentSource(): String =
        "@group(1) @binding(0) var uImage: texture_2d<f32>;\n" +
        "@group(1) @binding(1) var uImageSampler: sampler;\n" +
        "@fragment fn fs_main(@location(1) vUv: vec2f) {\n" +
        "    if (textureSample(uImage, uImageSampler, vUv).a < 0.5) { discard; }\n" +
        "}\n"

    /// 姿勢の行列（group 2 の binding 0・読むだけの storage）。詰める側（Render3d.WebGpuRenderer）は頭の 16 バイトに 1 行のジョイントの数（u32）、
    /// その後に行の順に 1 行 jointsPerRow 本の mat4（列優先・Render3d.PoseRows.packRows の並び）。
    // WhyNot: uniform にしない — 1 回の prepare の違う姿勢を 1 つの binding に入れると 64 KiB を超える（ジョイント 64 本の姿勢 1 つで 4 KiB）。
    //   姿勢ごとに区画を bind すると行ごとに group を作ることになり、同じ姿勢を共有する batch が分かれる。
    // WhyNot: GL と同じ RGBA32F の絵にしない — 絵の 1 行の幅（4 × ジョイント数）で行の数が決まり、storage は番号で引くだけで済む。
    def poseDeclarations(): String =
        "struct R3dPoses { jointsPerRow: u32, matrices: array<mat4x4f> };\n" +
        "@group(2) @binding(0) var<storage, read> r3dPoses: R3dPoses;\n" +
        "fn r3d_jointMatrix(row: u32, joint: f32) -> mat4x4f { return r3dPoses.matrices[row * r3dPoses.jointsPerRow + u32(joint)]; }\n"

    /// 姿勢の group（group 2）の binding 0 の頭のバイト数（R3dPoses の matrices の位置）。
    pub def poseHeaderBytes(): Int32 = 16

    /// 骨つきの版の頂点の入力（形の版の buffer の location 14・15。ジョイントの番号は float の 4 つ）。
    // WhyNot: ジョイントの番号を u32 の属性にしない — 形の版は 1 本の Float32 の buffer に交互に並べ（Render3d.WebGpuRows）、番号は 64 未満で float に正確に入る。
    def skinInputs(skinned: Bool): String =
        if (skinned) "    @location(14) aJoints: vec4f,\n    @location(15) aWeights: vec4f,\n" else ""

    /// 骨つきの版の main の頭: 姿勢の行（1 体ごとの値の normal1.w）の joint 行列を重みで足す（Render3dGlsl.skinPrelude と同じ式）。
    def skinPrelude(skinned: Bool): String =
        if (skinned)
            "    let poseRow = u32(v.normal1.w);\n" +
            "    let skin = v.aWeights.x * r3d_jointMatrix(poseRow, v.aJoints.x) + v.aWeights.y * r3d_jointMatrix(poseRow, v.aJoints.y)\n" +
            "             + v.aWeights.z * r3d_jointMatrix(poseRow, v.aJoints.z) + v.aWeights.w * r3d_jointMatrix(poseRow, v.aJoints.w);\n" +
            "    let skinLinear = mat3x3f(skin[0].xyz, skin[1].xyz, skin[2].xyz);\n"
        else ""

    /// 形の座標の位置・法線・タンジェントの xyz を、骨つきの版なら joint 行列で曲げた式（model を掛ける前）。
    def localOf(skinned: Bool): { position = String, normal = String, tangent = String } =
        if (skinned) { position = "skin * vec4f(v.aPos, 1.0)", normal = "skinLinear * v.aNormal", tangent = "skinLinear * v.aTangent.xyz" }
        else { position = "vec4f(v.aPos, 1.0)", normal = "v.aNormal", tangent = "v.aTangent.xyz" }

    /// 1 体ごとの値の入力（buffer 1 の location 3〜10）。
    def instanceInputs(): String =
        "    @location(3) model0: vec4f,\n" +
        "    @location(4) model1: vec4f,\n" +
        "    @location(5) model2: vec4f,\n" +
        "    @location(6) model3: vec4f,\n" +
        "    @location(7) normal0: vec4f,\n" +
        "    @location(8) normal1: vec4f,\n" +
        "    @location(9) normal2: vec4f,\n" +
        "    @location(10) tint: vec4f,\n"

    /// main の頭: 1 体ごとの値から model と法線の行列を組む。
    def instancePrelude(): String =
        "    let model = mat4x4f(v.model0, v.model1, v.model2, v.model3);\n" +
        "    let normalMatrix = mat4x4f(vec4f(v.normal0.xyz, 0.0), vec4f(v.normal1.xyz, 0.0), vec4f(v.normal2.xyz, 0.0), vec4f(0.0, 0.0, 0.0, 1.0));\n"

    /// 頂点の色のプログラムの頂点シェーダー（Render3dGlsl.litVertexSource と同じ式）。入口は vs_main。
    /// 形の頂点は buffer 0（位置・法線・色の 9 float から）を location 0〜2 で、1 体ごとの値は buffer 1（Render3d.InstanceValues の 1 体の並び・instanceBytes()）を
    /// location 3〜10 で読む。行の頭の物は draw の firstInstance で引く。skinned なら骨つきの版（location 14・15 と group 2 の姿勢）。varying は litFragmentSource の R3dLitIn と同じ並び。
    // WhyNot: 1 体ごとの値を storage buffer から instance_index で引かない — 頂点の属性で読む形と 1 コマの時間の差が揺れの内（plans/engine-webgpu.md の 12.29）で、属性の数は一番多い版（uv つきの骨つきの材質）でも 15 個で上限 16 の内。
    //   storage から引く形は、頂点の段で storage を読めない機種（WebGPU の互換の版）で骨の無い物まで描けなくなる（姿勢の storage は骨つきの物だけが読む）。
    pub def litVertexSource(skinned: Bool): String =
        let local = localOf(skinned);
        cameraDeclarations() +
        (if (skinned) poseDeclarations() else "") +
        "struct R3dVertexIn {\n" +
        "    @location(0) aPos: vec3f,\n" +
        "    @location(1) aNormal: vec3f,\n" +
        "    @location(2) aColor: vec3f,\n" +
        instanceInputs() +
        skinInputs(skinned) +
        "};\n" +
        "struct R3dLitOut {\n" +
        "    @builtin(position) position: vec4f,\n" +
        "    @location(0) vWorld: vec3f,\n" +
        "    @location(1) vNormal: vec3f,\n" +
        "    @location(2) vColor: vec3f,\n" +
        "    @location(3) @interpolate(flat) vTint: vec3f,\n" +
        "};\n" +
        colorSpaceSource() +
        ShaderGen.Wgsl.clipFromGlSource() +
        "@vertex fn vs_main(v: R3dVertexIn) -> R3dLitOut {\n" +
        instancePrelude() +
        skinPrelude(skinned) +
        "    let world = model * " + local#position + ";\n" +
        "    var o: R3dLitOut;\n" +
        "    o.vWorld = world.xyz;\n" +
        "    o.vNormal = (normalMatrix * vec4f(" + local#normal + ", 0.0)).xyz;\n" +
        "    o.vColor = r3d_srgbToLinear3(v.aColor);\n" +
        "    o.vTint = v.tint.rgb;\n" +
        "    o.position = sg_clipFromGl(r3dCamera.uProj * r3dCamera.uView * world);\n" +
        "    return o;\n" +
        "}\n"

    /// 材質のプログラムの頂点シェーダー（Render3dGlsl.materialVertexSource と同じ式）。入口は vs_main。
    /// 形の頂点は buffer 0 の location 0〜2（位置・法線・色）と、uv つきの版は 11（uv）・12（タンジェント）、2 本目の uv つきは 13、骨つきの版は 14・15（Render3d.WebGpuRows の並び）。
    /// 1 体ごとの値は litVertexSource と同じ buffer 1 の location 3〜10。varying は materialFragmentSource の R3dIn の並び（frag が読まない物も出す）。
    /// 頂点の色は線形へ戻さない（材質の式が VertexColor を sRGB のまま読む・GLSL と同じ）。骨つきの版は lightmap を読まない（Scene3d.lightmapOf が None）。
    pub def materialVertexSource(uv: Bool, lightmap: Bool, skinned: Bool): String =
        let local = localOf(skinned);
        let lm = lightmap and not skinned;
        cameraDeclarations() +
        (if (skinned) poseDeclarations() else "") +
        "struct R3dVertexIn {\n" +
        "    @location(0) aPos: vec3f,\n" +
        "    @location(1) aNormal: vec3f,\n" +
        "    @location(2) aColor: vec3f,\n" +
        instanceInputs() +
        (if (uv) "    @location(11) aUv: vec2f,\n    @location(12) aTangent: vec4f,\n" else "") +
        (if (lm) "    @location(13) aUv2: vec2f,\n" else "") +
        skinInputs(skinned) +
        "};\n" +
        "struct R3dMaterialOut {\n" +
        "    @builtin(position) position: vec4f,\n" +
        "    @location(0) vWorld: vec3f,\n" +
        "    @location(1) vNormal: vec3f,\n" +
        "    @location(2) vColor: vec3f,\n" +
        "    @location(3) @interpolate(flat) vTint: vec3f,\n" +
        "    @location(4) @interpolate(flat) vEmissionIntensity: f32,\n" +
        (if (uv) "    @location(5) vUv: vec2f,\n" else "") +
        (if (lm) "    @location(6) vUv2: vec2f,\n" else "") +
        (if (uv) "    @location(7) vTangent: vec4f,\n" else "") +
        "};\n" +
        ShaderGen.Wgsl.clipFromGlSource() +
        "@vertex fn vs_main(v: R3dVertexIn) -> R3dMaterialOut {\n" +
        instancePrelude() +
        skinPrelude(skinned) +
        "    let world = model * " + local#position + ";\n" +
        "    var o: R3dMaterialOut;\n" +
        "    o.vWorld = world.xyz;\n" +
        "    o.vNormal = (normalMatrix * vec4f(" + local#normal + ", 0.0)).xyz;\n" +
        "    o.vColor = v.aColor;\n" +
        "    o.vTint = v.tint.rgb;\n" +
        "    o.vEmissionIntensity = v.normal0.w;\n" +
        (if (uv)
            "    o.vUv = v.aUv;\n" +
            "    let modelLinear = mat3x3f(model[0].xyz, model[1].xyz, model[2].xyz);\n" +
            "    o.vTangent = vec4f(modelLinear * (" + local#tangent + "), v.aTangent.w * sign(determinant(modelLinear)));\n"
         else "") +
        (if (lm) "    o.vUv2 = v.aUv2;\n" else "") +
        "    o.position = sg_clipFromGl(r3dCamera.uProj * r3dCamera.uView * world);\n" +
        "    return o;\n" +
        "}\n"

    /// 空の色の式 skyAt(向き)（Render3dGlsl.skyLightSource と同じ木）。
    pub def skyLightSource(): String =
        LightModel3d.Codegen.toWgsl("skyAt", Vec3Input.SkyDirection :: Nil, LightModel3d.skyModel())

    /// R3dScene の uSkyForward のバイトの位置（光の配列の後ろ・uSkyRight と uSkyUp が 16 バイトずつ続く）。
    pub def skyValuesAt(): Int32 = Render3d.UniformLayout.offsetOf(Render3d.UniformLayout.sceneOffsets(), Render3d.UniformLayout.SceneField.SkyForward)

    /// 空の頂点シェーダー: 頂点の buffer を読まず、vertex_index の 3 点で描き先いっぱいを覆う三角形を出す。入口は vs_main。
    // WhyNot: GL と同じ 6 点の四角の buffer を持たない — 覆う画素は同じで、buffer と頂点の属性の宣言が要らない。
    pub def skyVertexSource(): String =
        "@vertex fn vs_main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {\n" +
        "    let x = f32((i << 1u) & 2u);\n" +
        "    let y = f32(i & 2u);\n" +
        "    return vec4f(x * 2.0 - 1.0, y * 2.0 - 1.0, 0.0, 1.0);\n" +
        "}\n"

    /// 空の frag（Render3dGlsl.skyFragmentSource と同じ式）。空の 3 色と曲がりは場面の値（group 0 の uZenith・uHorizon・uGround・uCurve。
    /// 空のある場面では LightModel3d.reflectionSkyOf が空の色を線形へ戻した物）、画素の向きの材料と描き先の大きさは同じ R3dScene の末尾の uSky*。
    /// uSkyUp.w が 1（景色を背景に描く場面）なら、空の代わりに環境マップの絵を mip のレベル 0 で読み、uEnvIntensity を掛ける。入口は fs_main。
    // WhyNot: NDC の y を GLSL と同じ（画素の y − 原点）÷ 高さで作らない — 描き先の画素の y は上の行が 0 で、GL の gl_FragCoord と向きが逆。
    // WhyNot: 奥行きの書き出しの枝（GLSL の uDepthOut）を持たない — 奥行きの書き出しの pass は空を描かず、地の色の白で消す（WebGpuRenderer.clearOf）。
    pub def skyFragmentSource(): String =
        sceneDeclarations() +
        colorSpaceSource() +
        skyLightSource() +
        environmentUvSource() +
        "@fragment fn fs_main(@builtin(position) at: vec4f) -> @location(0) vec4f {\n" +
        "    let ndc = vec2f(at.x / r3d.uSkyForward.w * 2.0 - 1.0, 1.0 - at.y / r3d.uSkyRight.w * 2.0);\n" +
        "    let d = normalize(r3d.uSkyForward.xyz + r3d.uSkyRight.xyz * ndc.x + r3d.uSkyUp.xyz * ndc.y);\n" +
        "    if (r3d.uSkyUp.w > 0.5) {\n" +
        "        return vec4f(r3d_linearToSrgb3(r3d_srgbToLinear3(textureSampleLevel(uEnvMap, uEnvSampler, environmentUv(d), 0.0).rgb) * r3d.uEnvIntensity), 1.0);\n" +
        "    }\n" +
        "    return vec4f(r3d_linearToSrgb3(skyAt(d)), 1.0);\n" +
        "}\n"
}
