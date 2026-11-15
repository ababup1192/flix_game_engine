// Render3dWgsl — 3D の描き手の WebGPU の frag の WGSL（Render3dGlsl の材質の frag・頂点の色の frag と、それが使う光・影・色の空間・法線マップ・環境マップ・lightmap の関数）。
// 式は Render3dGlsl と 1 行ずつ同じに書き、光・かすみ・空の式は同じ LightModel3d の木から LightModel3d.Codegen.toWgsl で作る。
//
// bind group: 0 = 場面（`var<uniform> r3d: R3dScene`・影の地図・太陽の影の地図・環境マップ）・1 = 材質（ShaderGen.Wgsl.compile3d の `sg` と絵）・
// 2 = 物ごと（`var<uniform> r3dDraw: R3dDraw`・法線マップ・lightmap）。varying の location は R3dIn の並び。
// 射影の行列は GL の物のまま使い、頂点シェーダーが ShaderGen.Wgsl.clipFromGlSource の sg_clipFromGl で clip の z を 0..w へ移す前提
// （奥行きの値が GL のウィンドウの奥行きと同じになり、影の比べ ndc.z × 0.5 + 0.5 をそのまま使える）。
pub mod Render3dWgsl {
    use LightModel3d.Vec3Input

    /// 場面の値の struct と、場面の絵の宣言（group 0）。欄の名前は Render3dGlsl の uniform と同じ。
    /// f32 と vec2 の光の配列は、uniform の配列の 16 バイト刻みに合わせて vec4 の配列にした（x・y を読む。LightModel3d.Codegen の WGSL の欄と同じ）。
    /// 詰める側は WGSL の並びの決まり（vec3 と vec4 と mat4 は 16 バイトそろえ・vec2 は 8）に従う。vec3 の後ろの 4 バイトに f32 か i32 を 1 つ入れ、
    /// mat4 の前の隙間は pad0〜pad2 で埋めてあるので、欄は書いた順に 4 バイトずつ続く（uShadowMatrix は 272 バイト目）。
    pub def sceneDeclarations(): String =
        let p = Scene3d.maxPointLights();
        let s = Scene3d.maxSpotLights();
        "struct R3dScene {\n" +
        "    uAmbient: vec3f, uHemisphere: f32,\n" +
        "    uEye: vec3f, uToonSteps: i32,\n" +
        "    uFogColor: vec3f, uFogOn: i32,\n" +
        "    uFogRange: vec2f, uPointCount: i32, uSpotCount: i32,\n" +
        "    uSunDir: vec3f, uSunShadowOn: i32,\n" +
        "    uSunColor: vec3f, uSunNormalShift: f32,\n" +
        "    uSunForward: vec3f, uSunBias: f32,\n" +
        "    uSunFade: vec2f, uSunPcf: i32, uSunStrength: f32,\n" +
        "    uZenith: vec3f, uCurve: f32,\n" +
        "    uHorizon: vec3f, uEnvOn: i32,\n" +
        "    uGround: vec3f, uEnvBoxOn: i32,\n" +
        "    uEnvBoxMin: vec3f, uEnvLevels: f32,\n" +
        "    uEnvBoxMax: vec3f, uEnvIntensity: f32,\n" +
        "    uEnvBoxCenter: vec3f, uShadowOn: i32,\n" +
        "    uDepthRange: vec2f, uShadowSpot: i32, uShadowPcf: i32,\n" +
        "    uShadowBias: f32, uShadowStrength: f32, uDepthOut: i32, uLightmapSrgb: i32,\n" +
        "    uLightmapIntensity: f32, pad0: f32, pad1: f32, pad2: f32,\n" +
        "    uShadowMatrix: mat4x4f,\n" +
        "    uSunMatrix: mat4x4f,\n" +
        "    uPointPos: array<vec4f, ${p}>,\n" +
        "    uPointColor: array<vec4f, ${p}>,\n" +
        "    uPointRange: array<vec4f, ${p}>,\n" +
        "    uSpotPos: array<vec4f, ${s}>,\n" +
        "    uSpotDir: array<vec4f, ${s}>,\n" +
        "    uSpotColor: array<vec4f, ${s}>,\n" +
        "    uSpotRange: array<vec4f, ${s}>,\n" +
        "    uSpotCone: array<vec4f, ${s}>,\n" +
        "};\n" +
        "@group(0) @binding(0) var<uniform> r3d: R3dScene;\n" +
        "@group(0) @binding(1) var uShadowMap: texture_depth_2d;\n" +
        "@group(0) @binding(2) var uSunMap: texture_depth_2d;\n" +
        "@group(0) @binding(3) var uEnvMap: texture_2d<f32>;\n" +
        "@group(0) @binding(4) var uEnvSampler: sampler;\n"

    /// 物ごとの値（group 2）。uCutout = cutout の材質か（1）・法線マップの強さと mip のレベルの数・lightmap の mip のレベルの数。
    /// 法線マップは binding 1・2、lightmap は binding 3・4（使う版だけ宣言する）。
    // WhyNot: 法線マップの読みの v を上下に返す値（GLSL の uNormalFlip）を持たない — WebGPU の描き先の texture は上の行が先で、ほかの絵と同じ向き。
    def drawDeclarations(normalMapped: Bool, lightmap: Bool): String =
        "struct R3dDraw { uCutout: i32, uNormalStrength: f32, uNormalLevels: f32, uLightmapLevels: f32 };\n" +
        "@group(2) @binding(0) var<uniform> r3dDraw: R3dDraw;\n" +
        (if (normalMapped) "@group(2) @binding(1) var uNormalMap: texture_2d<f32>;\n@group(2) @binding(2) var uNormalMapSampler: sampler;\n" else "") +
        (if (lightmap) "@group(2) @binding(3) var uLightmap: texture_2d<f32>;\n@group(2) @binding(4) var uLightmapSampler: sampler;\n" else "")

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
    pub def lightSource(): String =
        shadowSource() +
        LightModel3d.Codegen.toWgsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModel()) +
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
        "}\n" +
        "fn spotShadow(i: i32, p: vec3f) -> f32 {\n" +
        "    if (r3d.uShadowOn == 0 || i != r3d.uShadowSpot) { return 1.0; }\n" +
        "    return 1.0 - r3d.uShadowStrength * (1.0 - shadowLitFraction(uShadowMap, r3d.uShadowMatrix, r3d.uShadowBias, r3d.uShadowPcf, 0.0, vec3f(0.0), p));\n" +
        "}\n" +
        "var<private> r3d_sunLit: f32 = 1.0;\n" +
        "fn sunLitAt(p: vec3f, g: vec3f, n: vec3f) -> f32 {\n" +
        "    if (r3d.uSunShadowOn == 0 || dot(n, r3d.uSunDir) <= 0.0) { return 1.0; }\n" +
        "    let fade = clamp((r3d.uSunFade.x - dot(p - r3d.uEye, r3d.uSunForward)) / r3d.uSunFade.y, 0.0, 1.0);\n" +
        "    if (fade <= 0.0) { return 1.0; }\n" +
        "    return 1.0 - r3d.uSunStrength * fade * (1.0 - shadowLitFraction(uSunMap, r3d.uSunMatrix, r3d.uSunBias, r3d.uSunPcf, r3d.uSunNormalShift, g, p));\n" +
        "}\n"

    def depthGraySource(): String =
        "fn depthGray(p: vec3f) -> f32 {\n" +
        "    return clamp((distance(p, r3d.uEye) - r3d.uDepthRange.x) / r3d.uDepthRange.y, 0.0, 1.0);\n" +
        "}\n"

    /// metallic と roughness を持つ材質の色 pbrAt と、環境マップの読み・かすみ → emission の組み立て（Render3dGlsl.metallicRoughnessSource と同じ）。
    pub def metallicRoughnessSource(): String =
        environmentSource() +
        LightModel3d.Codegen.toWgsl("pbrAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.Albedo :: Vec3Input.Light :: Vec3Input.MetallicRoughness ::
                                             Vec3Input.EnvironmentColor :: Nil,
                                    LightModel3d.pbrModel()) +
        "fn r3d_surfaceOutLit(lit: vec3f, emission: vec3f, intensity: f32, p: vec3f) -> vec3f {\n" +
        "    let c = fogged(lit, p);\n" +
        "    return r3d_linearToSrgb3(c + r3d_srgbToLinear3(emission) * intensity);\n" +
        "}\n"

    // WhyNot: 極で atan2 を選ばない形を if にしない — select は両側を計算するが、atan2(0, 0) の値は捨てられる（Flix の atan2 と同じ 0 を選ぶ）。
    pub def environmentSource(): String =
        LightModel3d.Codegen.toWgsl("environmentDirectionAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.Albedo :: Vec3Input.MetallicRoughness :: Nil,
                                    LightModel3d.environmentDirection()) +
        "fn environmentUv(d: vec3f) -> vec2f {\n" +
        "    let pole = abs(d.x) + abs(d.z) < 1e-12;\n" +
        "    let azimuth = select(atan2(d.x, -d.z), 0.0, pole);\n" +
        "    return vec2f(0.5 + azimuth / 6.283185307179586, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / 3.141592653589793);\n" +
        "}\n" +
        "fn environmentColorAt(p: vec3f, n: vec3f, albedo: vec3f, metalRough: vec3f) -> vec3f {\n" +
        "    let d = environmentDirectionAt(p, n, albedo, metalRough);\n" +
        "    let lod = metalRough.y * (r3d.uEnvLevels - 1.0);\n" +
        "    return r3d_srgbToLinear3(textureSampleLevel(uEnvMap, uEnvSampler, environmentUv(d), lod).rgb) * r3d.uEnvIntensity;\n" +
        "}\n"

    /// lightmap の読みと、lightmap のある面の光の式（Render3dGlsl.lightmapSource と同じ）。
    def lightmapSource(): String =
        "fn lightmapColor(uv2: vec2f) -> vec3f {\n" +
        "    return sg_texMip(uLightmap, uLightmapSampler, r3dDraw.uLightmapLevels, uv2).rgb;\n" +
        "}\n" +
        LightModel3d.Codegen.toWgsl("lightmapLightAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.LightmapColor :: Nil,
                                    LightModel3d.lightmapLightingModel())

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
        let normalMapped = surface#uv and surface#normalMap;
        let needsMip = (normalMapped or surface#lightmap) and List.isEmpty(m#texReads);
        let faceNormal = if (surface#doubleSided) "facingNormal" else "normalize(vNormal)";
        let normal = if (normalMapped) "normalMapped(${faceNormal}, vUv, i.vTangent)" else faceNormal;
        let cutout = if (surface#coverage) "" else "    if (r3dDraw.uCutout == 1 && " + m#cutoutAlpha + " < 0.5) { discard; }\n";
        let facing = if (surface#doubleSided) "    let facingNormal = select(-normalize(vNormal), normalize(vNormal), i.frontFacing);\n" else "";
        let alpha = if (surface#coverage) "clamp((" + m#cutoutAlpha + " - 0.5) / max(fwidth(" + m#cutoutAlpha + "), 1e-4) + 0.5, 0.0, 1.0)"
                    else if (surface#blend) "albedo.a" else "1.0";
        let light = if (surface#lightmap) "    let light = lightmapLightAt(vWorld, n, lightmapColor(i.vUv2));\n" else "    let light = lightAt(vWorld, n);\n";
        sceneDeclarations() +
        drawDeclarations(normalMapped, surface#lightmap) +
        m#declarations +
        inputStruct(surface, normalMapped) +
        colorSpaceSource() +
        lightSource() +
        depthGraySource() +
        m#functions +
        (if (needsMip) ShaderGen.Wgsl.texMipSource() else "") +
        (if (normalMapped) normalMapSource() else "") +
        (if (surface#lightmap) lightmapSource() else "") +
        (if (surface#metallicRoughness) metallicRoughnessSource() else "") +
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

    /// 頂点の色のプログラムの frag（Render3dGlsl.litFragmentSource と同じ。vColor は頂点シェーダーが線形へ戻し済み）。入口は fs_main。
    pub def litFragmentSource(): String =
        sceneDeclarations() +
        "struct R3dLitIn {\n" +
        "    @location(0) vWorld: vec3f,\n" +
        "    @location(1) vNormal: vec3f,\n" +
        "    @location(2) vColor: vec3f,\n" +
        "    @location(3) @interpolate(flat) vTint: vec3f,\n" +
        "};\n" +
        colorSpaceSource() +
        lightSource() +
        "@fragment fn fs_main(i: R3dLitIn) -> @location(0) vec4f {\n" +
        "    let n = normalize(i.vNormal);\n" +
        "    r3d_sunLit = sunLitAt(i.vWorld, n, n);\n" +
        "    return vec4f(r3d_surfaceOut(i.vColor, i.vTint, lightAt(i.vWorld, n), vec3f(0.0), 1.0, i.vWorld, true), 1.0);\n" +
        "}\n"

    /// 空の色の式 skyAt(向き)（Render3dGlsl.skyLightSource と同じ木）。
    pub def skyLightSource(): String =
        LightModel3d.Codegen.toWgsl("skyAt", Vec3Input.SkyDirection :: Nil, LightModel3d.skyModel())
}
