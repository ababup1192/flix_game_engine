// Render3dGlsl — 3D の描き手（Render3d）のシェーダーの字。座標と式の約束は Render3d.flix の頭。
//
// 光・かすみ・空の式は LightModel3d の木から LightModel3d.Codegen.toGlsl で作る（CPU の描き手は同じ木から生成した SoftRaster3dLight を回す）。
// 光の uniform を光ごとに引く式（点光源・スポットの配列の [i]）は、このファイルと字を作る LightModel3d.Codegen の外に書かない（bin/lint-rules/forbid.json が止める）。
// 木の外に残る GLSL（影の地図の PCF・法線マップの TBN・lightmap の段つきの読み・色を作る最後の組み立て r3d_surfaceOut）は、
// gl-parity の式の行が CPU の描き手と同じ値になることを確かめる。
// 3D の色（Scene3d の頭の「3D の色」）: 光の color・ambient・かすみ・空・tint は描き手が線形の量へ戻して uniform に入れ、
// 頂点の色は lit の頂点シェーダーで、材質の albedo.rgb・emission とビルボードの絵は frag で線形へ戻し、色を作った直後に 1 回だけ画面の値へ戻す。
// WhyNot: 描き先を GL_SRGB8_ALPHA8 にして GL_FRAMEBUFFER_SRGB で戻さない — 2D の Pass が描き先を sRGB の絵として線形へ戻して読み、2D の絵が変わる。
// WhyNot: 3D を別の float の描き先へ描いて貼る時に戻さない — 背景の無い場面の縁は 2D の上で結局画面の値で混ざり、場面ごとに描き先と貼り直しが増える。
//   半透明の混ぜと MSAA の平均は戻した後の画面の値どうし。
pub mod Render3dGlsl {
    use LightModel3d.Vec3Input

    /// 置いた物の頂点シェーダー（深度だけのプログラム・uv の無い材質のプログラムで共有。頂点の色は値のまま渡す）。
    pub def meshVertexSource(): String =
        meshVertexSourceOf({ declarations = "", prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = None, uv2 = false,
                             vertexColorToLinear = false })

    /// 頂点の色のプログラム（lit）の頂点シェーダー。頂点の色を線形の量へ戻してから渡す（三角形の中は線形の量でつなぐ）。
    /// skinned なら骨つきの版。
    // WhyNot: meshVertexSource と共有しない — uv の無い材質の Spec の VertexColor まで線形の値になり、出口でもう一度戻して暗くなる。
    pub def litVertexSource(skinned: Bool): String =
        if (skinned)
            meshVertexSourceOf({ declarations = skinDeclarations() + colorSpaceSource(), prelude = skinPrelude(), position = "skin * vec4(aPos, 1.0)",
                                 normal = "mat3(skin) * aNormal", tangent = None, uv2 = false, vertexColorToLinear = true })
        else
            meshVertexSourceOf({ declarations = colorSpaceSource(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                                 tangent = None, uv2 = false, vertexColorToLinear = true })

    /// 骨つきの版: 位置と法線を joint 行列の重みつきの和（Pose3d.jointMatrices の並び）で曲げてから uModel を掛ける。
    // WhyNot: 法線を skin の逆行列の転置で曲げない — 左上 3×3 のままだと倍率が軸ごとに違うジョイントで少し傾くが、
    //   CPU の描き手も同じ式なので GL と CPU の絵は一致する。その差は許す。
    pub def skinnedMeshVertexSource(): String =
        meshVertexSourceOf({
            declarations = skinDeclarations(),
            prelude = skinPrelude(),
            position = "skin * vec4(aPos, 1.0)",
            normal = "mat3(skin) * aNormal",
            tangent = None,
            uv2 = false,
            vertexColorToLinear = false })

    /// 材質のプログラムの頂点シェーダー。uv の無い形は頂点の色のプログラムと同じ物・uv つきは vUv と vTangent も出す・
    /// lightmap つき（骨の無い版だけ）は 2 本目の uv の vUv2 も出す。骨つきの版は lightmap を読まない（Scene3d.lightmapOf が None）。
    pub def materialVertexSource(kind: { skinned = Bool, uv = Bool, lightmap = Bool }): String =
        match (kind#skinned, kind#uv, kind#lightmap) {
            case (false, false, false) => meshVertexSource()
            case (true, false, _)      => skinnedMeshVertexSource()
            case (false, false, true)  =>
                meshVertexSourceOf({ declarations = uv2Declarations(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                                     tangent = None, uv2 = true, vertexColorToLinear = false })
            case (false, true, lm)     =>
                meshVertexSourceOf({ declarations = surfaceDeclarations() + (if (lm) uv2Declarations() else ""), prelude = "",
                                     position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = Some("aTangent.xyz"), uv2 = lm,
                                     vertexColorToLinear = false })
            case (true, true, _)       =>
                meshVertexSourceOf({ declarations = skinDeclarations() + surfaceDeclarations(), prelude = skinPrelude(),
                                     position = "skin * vec4(aPos, 1.0)", normal = "mat3(skin) * aNormal",
                                     tangent = Some("mat3(skin) * aTangent.xyz"), uv2 = false, vertexColorToLinear = false })
        }

    def uv2Declarations(): String =
        "layout (location = 7) in vec2 aUv2;\n" +
        "out vec2 vUv2;\n"

    def skinDeclarations(): String =
        "layout (location = 3) in ivec4 aJoints;\n" +
        "layout (location = 4) in vec4 aWeights;\n" +
        "uniform sampler2D uJointTexture;\n" +
        "uniform int uPoseRow;\n" +
        "mat4 jointMatrix(int joint) {\n" +
        "    int x = joint * 4;\n" +
        "    return mat4(texelFetch(uJointTexture, ivec2(x, uPoseRow), 0), texelFetch(uJointTexture, ivec2(x + 1, uPoseRow), 0),\n" +
        "                texelFetch(uJointTexture, ivec2(x + 2, uPoseRow), 0), texelFetch(uJointTexture, ivec2(x + 3, uPoseRow), 0));\n" +
        "}\n"

    def skinPrelude(): String =
        "    mat4 skin = aWeights.x * jointMatrix(aJoints.x) + aWeights.y * jointMatrix(aJoints.y)\n" +
        "              + aWeights.z * jointMatrix(aJoints.z) + aWeights.w * jointMatrix(aJoints.w);\n"

    def surfaceDeclarations(): String =
        "layout (location = 5) in vec2 aUv;\n" +
        "layout (location = 6) in vec4 aTangent;\n" +
        "out vec2 vUv;\n" +
        "out vec4 vTangent;\n"

    /// 置いた物の頂点シェーダーの組み立て。declarations = 足す属性と uniform・prelude = main の頭・
    /// position = uModel を掛ける前の形の座標（vec4）・normal = uNormal を掛ける前の法線（vec3）・
    /// tangent = uModel の左上 3×3 を掛ける前のタンジェントの xyz（vec3。uv の無い形は None で vUv・vTangent を出さない）。
    /// タンジェントの w には uModel の左上 3×3 の行列式の符号を掛ける（鏡写しの置き方で絵の上の向きを保つ）。
    /// vertexColorToLinear = 頂点の色を r3d_srgbToLinear3 に通すか（declarations に colorSpaceSource() を入れる）。
    // WhyNot: タンジェントを uNormal で写さない — 法線の行列は面に垂直な向きを保つための物で、面の上の向きは uModel のまま写る。
    def meshVertexSourceOf(parts: { declarations = String, prelude = String, position = String, normal = String,
                                    tangent = Option[String], uv2 = Bool, vertexColorToLinear = Bool }): String =
        let surfaceBody = match parts#tangent {
            case None    => ""
            case Some(t) =>
                "    vUv = aUv;\n" +
                "    mat3 modelLinear = mat3(uModel);\n" +
                "    vTangent = vec4(modelLinear * (" + t + "), aTangent.w * sign(determinant(modelLinear)));\n"
        };
        "#version 330 core\n" +
        "layout (location = 0) in vec3 aPos;\n" +
        "layout (location = 1) in vec3 aNormal;\n" +
        "layout (location = 2) in vec3 aColor;\n" +
        parts#declarations +
        "uniform mat4 uModel;\n" +
        "uniform mat4 uView;\n" +
        "uniform mat4 uProj;\n" +
        "uniform mat4 uNormal;\n" +
        "out vec3 vWorld;\n" +
        "out vec3 vNormal;\n" +
        "out vec3 vColor;\n" +
        "void main() {\n" +
        parts#prelude +
        "    vec4 world = uModel * " + parts#position + ";\n" +
        "    vWorld = world.xyz;\n" +
        "    vNormal = (uNormal * vec4(" + parts#normal + ", 0.0)).xyz;\n" +
        (if (parts#vertexColorToLinear) "    vColor = r3d_srgbToLinear3(aColor);\n" else "    vColor = aColor;\n") +
        surfaceBody +
        (if (parts#uv2) "    vUv2 = aUv2;\n" else "") +
        "    gl_Position = uProj * uView * world;\n" +
        "}\n"

    /// 光の uniform と、光の式（lightAt）・かすみ（fogged）。式は LightModel3d の木から作る（CPU の描き手と同じ木）。
    pub def lightSource(): String =
        "uniform vec3 uAmbient;\n" +
        "uniform float uHemisphere;\n" +
        "uniform int uToonSteps;\n" +
        "uniform int uPointCount;\n" +
        "uniform vec3 uPointPos[${Scene3d.maxPointLights()}];\n" +
        "uniform vec3 uPointColor[${Scene3d.maxPointLights()}];\n" +
        "uniform float uPointRange[${Scene3d.maxPointLights()}];\n" +
        "uniform int uSpotCount;\n" +
        "uniform vec3 uSpotPos[${Scene3d.maxSpotLights()}];\n" +
        "uniform vec3 uSpotDir[${Scene3d.maxSpotLights()}];\n" +
        "uniform vec3 uSpotColor[${Scene3d.maxSpotLights()}];\n" +
        "uniform float uSpotRange[${Scene3d.maxSpotLights()}];\n" +
        "uniform vec2 uSpotCone[${Scene3d.maxSpotLights()}];\n" +
        "uniform int uFogOn;\n" +
        "uniform vec3 uFogColor;\n" +
        "uniform vec2 uFogRange;\n" +
        "uniform vec3 uEye;\n" +
        shadowSource() +
        LightModel3d.Codegen.toGlsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModel()) +
        LightModel3d.Codegen.toGlsl("fogAt", Vec3Input.Position :: Vec3Input.Color :: Nil, LightModel3d.fogModel()) +
        "vec3 fogged(vec3 c, vec3 p) {\n" +
        "    if (uFogOn == 0) return c;\n" +
        "    return fogAt(p, c);\n" +
        "}\n" +
        surfaceOutSource()

    /// 3D の色を作る最後の組み立て r3d_surfaceOut(albedoLinear, tint, light, emission, intensity, p, fogOn)（CPU の描き手は SoftRaster3d.materialColor と shadePixel）:
    /// 色 = albedoLinear × tint × light（fogOn ならかすみ）+ 線形へ戻した emission × intensity を、画面の値へ戻した物。
    /// albedoLinear は線形へ戻し済みの色（材質は r3d_srgbToLinear3(albedo.rgb)・ビルボードは絵・lit は頂点で戻した vColor）。
    /// lightSource が含め、colorSpaceSource() を先に置く。
    // WhyNot: albedo をここで戻さない — lit の頂点の色は頂点シェーダーで戻してあり、ここで戻すと 2 回かかる。
    // WhyNot: emission にかすみを掛けない — 自分で光る物（溶岩・目）は遠くでもかすみに沈まずに見えてほしい。
    // WhyNot: 光の式の木（LightModel3d）に入れない — かすみの有無・ビルボードの lit・Depth の枝まで木の入力にすることになる。
    pub def surfaceOutSource(): String =
        "vec3 r3d_surfaceOut(vec3 albedoLinear, vec3 tint, vec3 light, vec3 emission, float intensity, vec3 p, bool fogOn) {\n" +
        "    vec3 c = albedoLinear * tint * light;\n" +
        "    if (fogOn) c = fogged(c, p);\n" +
        "    return r3d_linearToSrgb3(c + r3d_srgbToLinear3(emission) * intensity);\n" +
        "}\n"

    /// 色の空間の変換: Texture3d の式のスカラーの r3d_srgbToLinear / r3d_linearToSrgb と、
    /// その vec3 の版 r3d_srgbToLinear3 / r3d_linearToSrgb3。frag と lit の頂点シェーダーが 1 回ずつ含める。
    pub def colorSpaceSource(): String =
        Texture3d.srgbToLinearGlsl("r3d_srgbToLinear") +
        Texture3d.linearToSrgbGlsl("r3d_linearToSrgb") +
        "vec3 r3d_srgbToLinear3(vec3 c) {\n" +
        "    return vec3(r3d_srgbToLinear(c.r), r3d_srgbToLinear(c.g), r3d_srgbToLinear(c.b));\n" +
        "}\n" +
        "vec3 r3d_linearToSrgb3(vec3 c) {\n" +
        "    return vec3(r3d_linearToSrgb(c.r), r3d_linearToSrgb(c.g), r3d_linearToSrgb(c.b));\n" +
        "}\n"

    /// 影の uniform と、スポット i の光に掛ける割合（Scene3d.shadowMatrix の doc の約束 1〜5。CPU の描き手と同じ）。
    /// 地図の画素は uv = NDC × 0.5 + 0.5 に大きさを掛けて切り捨てた所（行 0 が NDC の y = −1）。周りの画素は端へ寄せる。
    /// uShadowOn = 0 のプログラム（影の無い場面・ビルボード）は 1 を返す。
    // WhyNot: texture() でなく texelFetch で読む — 標本の位置の丸めと端の扱いを GPU のフィルタに任せると、CPU の数え方とずれる。
    // WhyNot: w ≤ 0（光の後ろ）を影にしない — w で割ると x・y が裏返って地図の中に入りうる。その点は円錐の外で光が 0。
    def shadowSource(): String =
        "uniform int uShadowOn;\n" +
        "uniform int uShadowSpot;\n" +
        "uniform mat4 uShadowMatrix;\n" +
        "uniform sampler2D uShadowMap;\n" +
        "uniform float uShadowBias;\n" +
        "uniform int uShadowPcf;\n" +
        "uniform float uShadowStrength;\n" +
        "float shadowLitFraction(vec3 p) {\n" +
        "    vec4 c = uShadowMatrix * vec4(p, 1.0);\n" +
        "    if (c.w <= 0.0) return 1.0;\n" +
        "    vec3 ndc = c.xyz / c.w;\n" +
        "    if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;\n" +
        "    float z = (ndc.z * 0.5 + 0.5) - uShadowBias;\n" +
        "    ivec2 size = textureSize(uShadowMap, 0);\n" +
        "    ivec2 last = size - ivec2(1);\n" +
        "    ivec2 center = clamp(ivec2(floor((ndc.xy * 0.5 + 0.5) * vec2(size))), ivec2(0), last);\n" +
        "    int lit = 0;\n" +
        "    int total = 0;\n" +
        "    for (int dy = -uShadowPcf; dy <= uShadowPcf; dy++) {\n" +
        "        for (int dx = -uShadowPcf; dx <= uShadowPcf; dx++) {\n" +
        "            ivec2 t = clamp(center + ivec2(dx, dy), ivec2(0), last);\n" +
        "            if (z <= texelFetch(uShadowMap, t, 0).r) lit++;\n" +
        "            total++;\n" +
        "        }\n" +
        "    }\n" +
        "    return float(lit) / float(total);\n" +
        "}\n" +
        "float spotShadow(int i, vec3 p) {\n" +
        "    if (uShadowOn == 0 || i != uShadowSpot) return 1.0;\n" +
        "    return 1.0 - uShadowStrength * (1.0 - shadowLitFraction(p));\n" +
        "}\n"

    /// Output.Depth の灰色（目からの距離で near が黒・near + range が白）。uEye は呼ぶ側の frag が宣言する。
    def depthGraySource(): String =
        "uniform vec2 uDepthRange;\n" +
        "float depthGray(vec3 p) {\n" +
        "    return clamp((distance(p, uEye) - uDepthRange.x) / uDepthRange.y, 0.0, 1.0);\n" +
        "}\n"

    /// 頂点の色のプログラムの frag（vColor は litVertexSource が線形へ戻し済み）。
    pub def litFragmentSource(): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec3 uTint;\n" +
        colorSpaceSource() +
        lightSource() +
        "void main() {\n" +
        "    vec3 n = normalize(vNormal);\n" +
        "    fragColor = vec4(r3d_surfaceOut(vColor, uTint, lightAt(vWorld, n), vec3(0.0), 1.0, vWorld, true), 1.0);\n" +
        "}\n"

    /// 材質の frag。光の式は litFragmentSource と同じで、頂点の色の代わりに materialEval の albedo を使う（頂点の色は
    /// 材質の Spec が VertexColor で読む）。surface#uv = uv つきの形か（偽なら vUv は (0, 0) の const）・
    /// surface#normalMap = 法線マップを当てるか（uv つきの時だけ。光の計算の法線を、法線マップで傾けた n' にする）・
    /// surface#lightmap = ベイクした光を 2 本目の uv で読み、環境光と hemisphere の代わりに足すか。
    /// uDepthOut = 1 なら cutout で抜いた後の奥行きの灰色を書く（Output.Depth の cutout の材質）。
    /// surface#blend = 出す α を材質の α に（半透明）・surface#doubleSided = 裏の面（!gl_FrontFacing）は光の計算の法線を裏返す・
    /// surface#coverage = cutout を discard でなく alpha to coverage の α で抜く。3 つとも偽なら、足す前と同じ字。
    // WhyNot: 欄を 1 つずつ並べた引数にしない — ProgramKind に欄が増えるたびに、呼び手とテストの字が全部書き換わる。skinned は頂点の側だけが読む。
    pub def materialFragmentSource(glsl: ShaderGen.MaterialGlsl, surface: Render3d.ProgramKind): String =
        let normalMapped = surface#uv and surface#normalMap;
        // WhyNot: sg_texMip を足すかを normalMapSource と lightmapSource の中で別々に決めない — 両方を使う版で 2 回定義され、コンパイルが落ちる。
        let needsMip = (normalMapped or surface#lightmap) and not String.contains(substr = "vec4 sg_texMip(", glsl#functions);
        let faceNormal = if (surface#doubleSided) "facingNormal" else "normalize(vNormal)";
        let normal = if (normalMapped) "normalMapped(${faceNormal})" else faceNormal;
        let cutout = if (surface#coverage) "" else "    if (uCutout == 1 && " + glsl#cutoutAlpha + " < 0.5) discard;\n";
        let facing = if (surface#doubleSided) "    vec3 facingNormal = gl_FrontFacing ? normalize(vNormal) : -normalize(vNormal);\n" else "";
        // WhyNot: alpha to coverage に絵の α をそのまま渡さない — ぼけた α の絵では縁が数画素の幅で透け、cutout の固い縁に見えない。
        let alpha = if (surface#coverage) "clamp((" + glsl#cutoutAlpha + " - 0.5) / max(fwidth(" + glsl#cutoutAlpha + "), 1e-4) + 0.5, 0.0, 1.0)"
                    else if (surface#blend) "albedo.a" else "1.0";
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        (if (surface#uv) "in vec2 vUv;\n" else "const vec2 vUv = vec2(0.0, 0.0);\n") +
        (if (surface#lightmap) "in vec2 vUv2;\n" else "") +
        "out vec4 fragColor;\n" +
        "uniform vec3 uTint;\n" +
        "uniform int uCutout;\n" +
        "uniform int uDepthOut;\n" +
        "uniform float uEmissionIntensity;\n" +
        colorSpaceSource() +
        lightSource() +
        depthGraySource() +
        glsl#uniforms +
        glsl#functions +
        (if (needsMip) ShaderGen.texMipSource() else "") +
        (if (normalMapped) normalMapSource() else "") +
        (if (surface#lightmap) lightmapSource() else "") +
        "void main() {\n" +
        "    vec4 albedo;\n" +
        "    vec3 emission;\n" +
        "    materialEval(albedo, emission);\n" +
        cutout +
        "    if (uDepthOut == 1) {\n" +
        "        float g = depthGray(vWorld);\n" +
        "        fragColor = vec4(g, g, g, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        facing +
        (if (surface#lightmap)
            "    vec3 light = lightmapLightAt(vWorld, " + normal + ", lightmapColor());\n"
         else
            "    vec3 light = lightAt(vWorld, " + normal + ");\n") +
        "    fragColor = vec4(r3d_surfaceOut(r3d_srgbToLinear3(albedo.rgb), uTint, light, emission, uEmissionIntensity, vWorld, true), " + alpha + ");\n" +
        "}\n"

    /// ベイクした光の uniform と、lightmap の絵の読み（lightmapColor）と、lightmap のある面の光の式（lightmapLightSource）。
    /// 段つきの Linear で読む（sg_texMip。段は Lightmap の maxLevels まで）。2 本目の uv の絵は場面の textures だけから引くので上下の反転は無い。
    def lightmapSource(): String =
        "uniform sampler2D uLightmap;\n" +
        "uniform float uLightmapLevels;\n" +
        "vec3 lightmapColor() {\n" +
        "    return sg_texMip(uLightmap, 0.0, uLightmapLevels, vUv2).rgb;\n" +
        "}\n" +
        lightmapLightSource()

    /// lightmap のある面の光の式 lightmapLightAt(p, n, lightmap の色)（LightModel3d の木から作る）と、それが読む uniform。
    /// colorSpaceSource()（色の空間の関数）と lightSource の後に置く（光の uniform と spotShadow を読む）。
    pub def lightmapLightSource(): String =
        "uniform int uLightmapSrgb;\n" +
        "uniform float uLightmapIntensity;\n" +
        LightModel3d.Codegen.toGlsl("lightmapLightAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.LightmapColor :: Nil,
                                    LightModel3d.lightmapLightingModel())

    /// 法線マップの uniform と、外向きの法線 n を法線マップで傾けた n'（normalMapped）。
    /// uNormalFlip = 1 はレンダーターゲット（行 0 が下）で、v を上下反転して読む。
    // WhyNot: 絵を読むのをタンジェントの長さを見た後にしない — 読みの段を選ぶ微分（dFdx）は、画素ごとに分かれる if の中では値が決まらない。
    /// 法線マップは段つきの Linear で読む（sg_texMip。materialFragmentSource が前に 1 回だけ出す）。
    def normalMapSource(): String =
        "in vec4 vTangent;\n" +
        "uniform sampler2D uNormalMap;\n" +
        "uniform float uNormalStrength;\n" +
        "uniform float uNormalFlip;\n" +
        "uniform float uNormalLevels;\n" +
        applyNormalMapSource() +
        "vec3 normalMapped(vec3 n) {\n" +
        "    return applyNormalMap(n, vTangent, uNormalStrength, sg_texMip(uNormalMap, uNormalFlip, uNormalLevels, vUv).rgb);\n" +
        "}\n"

    /// 外向きの法線 n をタンジェント（xyz と w）と法線マップの rgb c で傾けた applyNormalMap(n, tangent, strength, c)（式は Render3d.flix の頭。
    /// CPU の描き手は SoftRaster3d.applyNormalMap）。
    // WhyNot: タンジェントを頂点の値のまま使わない — 補間で N との直交が崩れ、傾ける向きが法線の側へ漏れる。
    // WhyNot: 長さ 0 のタンジェントで傾けない — normalize が NaN を出し、画素が黒く抜ける。その画素は n のまま。
    pub def applyNormalMapSource(): String =
        "vec3 applyNormalMap(vec3 n, vec4 tangent, float strength, vec3 c) {\n" +
        "    vec3 t = tangent.xyz - n * dot(n, tangent.xyz);\n" +
        "    if (dot(t, t) < 1e-12) return n;\n" +
        "    t = normalize(t);\n" +
        "    vec3 b = cross(n, t) * tangent.w;\n" +
        "    vec3 m = vec3((c.x * 2.0 - 1.0) * strength, (c.y * 2.0 - 1.0) * strength, c.z * 2.0 - 1.0);\n" +
        "    vec3 p = t * m.x + b * m.y + n * m.z;\n" +
        "    return dot(p, p) < 1e-12 ? n : normalize(p);\n" +
        "}\n"

    pub def depthFragmentSource(): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec3 uEye;\n" +
        depthGraySource() +
        "void main() {\n" +
        "    float g = depthGray(vWorld);\n" +
        "    fragColor = vec4(g, g, g, 1.0);\n" +
        "}\n"

    /// ビルボードの頂点シェーダー: カメラの right / up で四角を立てる（aCorner は 0〜1・y は下向き）。
    pub def billboardVertexSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 aCorner;\n" +
        "uniform mat4 uView;\n" +
        "uniform mat4 uProj;\n" +
        "uniform vec3 uCenter;\n" +
        "uniform vec3 uRight;\n" +
        "uniform vec3 uUp;\n" +
        "uniform vec2 uAnchor;\n" +
        "uniform vec2 uSize;\n" +
        "uniform vec4 uUvRect;\n" +
        "out vec3 vWorld;\n" +
        "out vec2 vUv;\n" +
        "void main() {\n" +
        "    vec3 world = uCenter + uRight * ((aCorner.x - uAnchor.x) * uSize.x)\n" +
        "                         + uUp * ((uAnchor.y - aCorner.y) * uSize.y);\n" +
        "    vWorld = world;\n" +
        "    vUv = uUvRect.xy + aCorner * uUvRect.zw;\n" +
        "    gl_Position = uProj * uView * vec4(world, 1.0);\n" +
        "}\n"

    pub def billboardFragmentSource(): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uImage;\n" +
        "uniform vec3 uTint;\n" +
        "uniform int uLit;\n" +
        "uniform vec3 uFacing;\n" +
        "uniform int uDepthOut;\n" +
        colorSpaceSource() +
        lightSource() +
        depthGraySource() +
        "void main() {\n" +
        "    vec4 texel = texture(uImage, vUv);\n" +
        "    if (texel.a < 0.5) discard;\n" +
        "    if (uDepthOut == 1) {\n" +
        "        float g = depthGray(vWorld);\n" +
        "        fragColor = vec4(g, g, g, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    vec3 light = uLit == 1 ? lightAt(vWorld, normalize(uFacing)) : vec3(1.0);\n" +
        "    fragColor = vec4(r3d_surfaceOut(r3d_srgbToLinear3(texel.rgb), uTint, light, vec3(0.0), 1.0, vWorld, uLit == 1), 1.0);\n" +
        "}\n"

    /// 空の frag（式は LightModel3d.skyModel・向きは Scene3d.skyDirectionOf。NDC は画素の真ん中の gl_FragCoord と viewport から）。
    pub def skyFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec4 uViewport;\n" +
        "uniform vec3 uForward;\n" +
        "uniform vec3 uRight;\n" +
        "uniform vec3 uUp;\n" +
        "uniform int uDepthOut;\n" +
        colorSpaceSource() +
        skyLightSource() +
        "void main() {\n" +
        "    if (uDepthOut == 1) {\n" +
        "        fragColor = vec4(1.0, 1.0, 1.0, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    vec2 ndc = (gl_FragCoord.xy - uViewport.xy) / uViewport.zw * 2.0 - 1.0;\n" +
        "    vec3 d = normalize(uForward + uRight * ndc.x + uUp * ndc.y);\n" +
        "    fragColor = vec4(r3d_linearToSrgb3(skyAt(d)), 1.0);\n" +
        "}\n"

    /// 空の色の式 skyAt(向き)（LightModel3d の木から作る）と、それが読む uniform。
    pub def skyLightSource(): String =
        "uniform vec3 uZenith;\n" +
        "uniform vec3 uHorizon;\n" +
        "uniform vec3 uGround;\n" +
        "uniform float uCurve;\n" +
        LightModel3d.Codegen.toGlsl("skyAt", Vec3Input.SkyDirection :: Nil, LightModel3d.skyModel())

    /// Design の FBO を viewport 全面へ貼る（FBO は行 0 が下なので、四角の上を v = 1 に当てる）。
    pub def blitVertexSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 aCorner;\n" +
        "out vec2 vUv;\n" +
        "void main() {\n" +
        "    vUv = vec2(aCorner.x, 1.0 - aCorner.y);\n" +
        "    gl_Position = vec4(aCorner.x * 2.0 - 1.0, 1.0 - aCorner.y * 2.0, 0.0, 1.0);\n" +
        "}\n"

    pub def blitFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uImage;\n" +
        "void main() {\n" +
        "    fragColor = texture(uImage, vUv);\n" +
        "}\n"
}
