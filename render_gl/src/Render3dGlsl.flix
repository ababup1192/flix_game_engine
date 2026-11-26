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
    pub def meshVertexSource(): String = meshVertexSourceFor(false)

    /// psx（PS1 風の変種 +psx）なら頂点を丸める版の meshVertexSource。
    def meshVertexSourceFor(psx: Bool): String =
        meshVertexSourceOf({ declarations = "", prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = None, uv2 = false,
                             vertexColorToLinear = false, psx = psx })

    /// 頂点の色のプログラム（lit）の頂点シェーダー。頂点の色を線形の量へ戻してから渡す（三角形の中は線形の量でつなぐ）。
    /// skinned なら骨つきの版。
    // WhyNot: meshVertexSource と共有しない — uv の無い材質の Spec の VertexColor まで線形の値になり、出口でもう一度戻して暗くなる。
    pub def litVertexSource(skinned: Bool): String = litVertexSourceFor(skinned, Render3d.defaultShaderVariant())

    /// 変種 v の litVertexSource（v#psx なら頂点を丸める）。
    pub def litVertexSourceFor(skinned: Bool, v: Render3d.ShaderVariant): String =
        if (skinned)
            meshVertexSourceOf({ declarations = skinDeclarations() + colorSpaceSource(), prelude = skinPrelude(), position = "skin * vec4(aPos, 1.0)",
                                 normal = "mat3(skin) * aNormal", tangent = None, uv2 = false, vertexColorToLinear = true, psx = v#psx })
        else
            meshVertexSourceOf({ declarations = colorSpaceSource(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                                 tangent = None, uv2 = false, vertexColorToLinear = true, psx = v#psx })

    /// 骨つきの版: 位置と法線を joint 行列の重みつきの和（Pose3d.jointMatrices の並び）で曲げてから model を掛ける。
    // WhyNot: 法線を skin の逆行列の転置で曲げない — 左上 3×3 のままだと倍率が軸ごとに違うジョイントで少し傾くが、
    //   CPU の描き手も同じ式なので GL と CPU の絵は一致する。その差は許す。
    pub def skinnedMeshVertexSource(): String = skinnedMeshVertexSourceFor(false)

    def skinnedMeshVertexSourceFor(psx: Bool): String =
        meshVertexSourceOf({
            declarations = skinDeclarations(),
            prelude = skinPrelude(),
            position = "skin * vec4(aPos, 1.0)",
            normal = "mat3(skin) * aNormal",
            tangent = None,
            uv2 = false,
            vertexColorToLinear = false,
            psx = psx })

    /// 材質のプログラムの頂点シェーダー。uv の無い形は頂点の色のプログラムと同じ物・uv つきは vUv と vTangent も出す・
    /// lightmap つき（骨の無い版だけ）は 2 本目の uv の vUv2 も出す。骨つきの版は lightmap を読まない（Scene3d.lightmapOf が None）。
    pub def materialVertexSource(kind: { skinned = Bool, uv = Bool, lightmap = Bool }): String = materialVertexSourceFor(kind, false)

    /// psx（PS1 風の変種 +psx）なら頂点を丸め、uv つきの版は遠近で補正する uv（vUvPerspective）と画面の上でまっすぐつなぐ uv（vUvAffine）の 2 本を出す版の
    /// materialVertexSource（materialFragmentSource が uPsx.w で混ぜる）。
    pub def materialVertexSourceFor(kind: { skinned = Bool, uv = Bool, lightmap = Bool }, psx: Bool): String =
        match (kind#skinned, kind#uv, kind#lightmap) {
            case (false, false, false) => meshVertexSourceFor(psx)
            case (true, false, _)      => skinnedMeshVertexSourceFor(psx)
            case (false, false, true)  =>
                meshVertexSourceOf({ declarations = uv2Declarations(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                                     tangent = None, uv2 = true, vertexColorToLinear = false, psx = psx })
            case (false, true, lm)     =>
                meshVertexSourceOf({ declarations = surfaceDeclarations(psx) + (if (lm) uv2Declarations() else ""), prelude = "",
                                     position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = Some("aTangent.xyz"), uv2 = lm,
                                     vertexColorToLinear = false, psx = psx })
            case (true, true, _)       =>
                meshVertexSourceOf({ declarations = skinDeclarations() + surfaceDeclarations(psx), prelude = skinPrelude(),
                                     position = "skin * vec4(aPos, 1.0)", normal = "mat3(skin) * aNormal",
                                     tangent = Some("mat3(skin) * aTangent.xyz"), uv2 = false, vertexColorToLinear = false, psx = psx })
        }

    def uv2Declarations(): String =
        "layout (location = 7) in vec2 aUv2;\n" +
        "out vec2 vUv2;\n"

    def skinDeclarations(): String =
        "layout (location = 3) in ivec4 aJoints;\n" +
        "layout (location = 4) in vec4 aWeights;\n" +
        "uniform sampler2D uJointTexture;\n" +
        "mat4 jointMatrix(int row, int joint) {\n" +
        "    int x = joint * 4;\n" +
        "    return mat4(texelFetch(uJointTexture, ivec2(x, row), 0), texelFetch(uJointTexture, ivec2(x + 1, row), 0),\n" +
        "                texelFetch(uJointTexture, ivec2(x + 2, row), 0), texelFetch(uJointTexture, ivec2(x + 3, row), 0));\n" +
        "}\n"

    def skinPrelude(): String =
        "    int poseRow = int(instanceNormal1.w);\n" +
        "    mat4 skin = aWeights.x * jointMatrix(poseRow, aJoints.x) + aWeights.y * jointMatrix(poseRow, aJoints.y)\n" +
        "              + aWeights.z * jointMatrix(poseRow, aJoints.z) + aWeights.w * jointMatrix(poseRow, aJoints.w);\n"

    def surfaceDeclarations(psx: Bool): String =
        "layout (location = 5) in vec2 aUv;\n" +
        "layout (location = 6) in vec4 aTangent;\n" +
        (if (psx) "out vec2 vUvPerspective;\nout vec3 vUvAffine;\n" else "out vec2 vUv;\n") +
        "out vec4 vTangent;\n"

    /// PS1 風の変種の頂点を丸める式 r3d_vertexSnap(clip の位置)（CPU の描き手は SoftRaster3d.Psx.snapVertex）。uPsxTarget.zw = 場面の描き先の幅と高さ（画素）・
    /// uVertexSnap = 格子の大きさ（画素。0 で丸めない）。x・y を描き先の左上を 0 とする画素へ写して格子の一番近い点へ丸め、clip へ戻す（z と w は変えない）。
    // WhyNot: w が 0 以下（目の後ろ）の頂点を丸めない — 画素へ写せず、GPU が手前の面で切る前の形を壊す。
    def vertexSnapSource(): String =
        "uniform vec4 uPsxTarget;\n" +
        "uniform float uVertexSnap;\n" +
        "vec4 r3d_vertexSnap(vec4 p) {\n" +
        "    if (uVertexSnap <= 0.0 || p.w <= 0.0) return p;\n" +
        "    vec2 s = floor(vec2((p.x / p.w + 1.0) * 0.5 * uPsxTarget.z, (1.0 - p.y / p.w) * 0.5 * uPsxTarget.w) / uVertexSnap + 0.5) * uVertexSnap;\n" +
        "    return vec4((s.x / uPsxTarget.z * 2.0 - 1.0) * p.w, (1.0 - s.y / uPsxTarget.w * 2.0) * p.w, p.z, p.w);\n" +
        "}\n"

    /// PS1 風の変種の色の丸め r3d_colorDepth(画面の値の色)（式は Scene3d.Psx.quantize・CPU の描き手は SoftRaster3d.Psx.quantized）と、それが読む uniform。
    /// uPsx = (段の数 2^bits − 1（0 で丸めない）, ディザの表の番号 Scene3d.Psx.patternCode, ディザの強さ, アフィンの割合)・
    /// uPsxTarget = (描き先の左下の画素の x, y, 幅, 高さ)。ディザの格子は描き先の左上を 0 とする画素の x・y の下 2 ビット。
    // WhyNot: 表を uniform の配列で渡さない — 2 つの表は決まった値で、const の配列なら変種の uniform が 2 つで済む。
    def colorDepthSource(): String =
        let table = (xs: List[Int32]) -> String.intercalate(", ", xs |> List.map(x -> "${x}.0"));
        "uniform vec4 uPsx;\n" +
        "uniform vec4 uPsxTarget;\n" +
        "const float r3d_psxTable[16] = float[16](${table(Scene3d.Psx.psxTable())});\n" +
        "const float r3d_bayerTable[16] = float[16](${table(Scene3d.Psx.bayer4Table())});\n" +
        "float r3d_psxDither(ivec2 p) {\n" +
        "    int i = (p.y & 3) * 4 + (p.x & 3);\n" +
        "    if (uPsx.y < 0.5) return r3d_psxTable[i] / 8.0;\n" +
        "    if (uPsx.y < 1.5) return (r3d_bayerTable[i] + 0.5) / 16.0 - 0.5;\n" +
        "    return 0.0;\n" +
        "}\n" +
        "vec3 r3d_colorDepth(vec3 c) {\n" +
        "    if (uPsx.x <= 0.0) return c;\n" +
        "    ivec2 p = ivec2(int(floor(gl_FragCoord.x - uPsxTarget.x)), int(floor(uPsxTarget.y + uPsxTarget.w - gl_FragCoord.y)));\n" +
        "    float step = 256.0 / (uPsx.x + 1.0);\n" +
        "    vec3 v = floor(clamp(c, 0.0, 1.0) * 255.0 + 0.5) + r3d_psxDither(p) * uPsx.z * step;\n" +
        "    return floor(clamp(v, 0.0, 255.0) / step) / uPsx.x;\n" +
        "}\n"

    /// 変種 v の frag の色の出口: v#psx なら r3d_colorDepth に通した式、ほかは c のまま。
    def colorOut(v: Render3d.ShaderVariant, c: String): String = if (v#psx) "r3d_colorDepth(" + c + ")" else c

    /// 頂点シェーダーへ数を渡すテクスチャの幅（texel）。
    pub def dataTextureWidth(): Int32 = Skin3d.maxJoints() * 4

    /// 1 体ごとの値の 1 体の幅（texel）。
    pub def texelsPerInstance(): Int32 = Render3d.InstanceValues.texelsPerInstance()

    /// 1 体ごとの値のテクスチャの 1 行の体の数（dataTextureWidth は texelsPerInstance で割り切れる）。
    pub def instancesPerRow(): Int32 = dataTextureWidth() / texelsPerInstance()

    /// 1 体ごとの値のテクスチャの宣言（並びは Render3d.InstanceValues の頭）。
    def instanceDeclarations(): String =
        "uniform sampler2D uInstanceTexture;\n" +
        "uniform int uInstanceBase;\n" +
        "flat out vec3 vTint;\n" +
        "flat out float vEmissionIntensity;\n"

    /// main の頭: 1 体ごとの値を読む。model = world の行列・normalMatrix = 法線の行列。
    def instancePrelude(): String =
        let texel = (i: Int32) -> "texelFetch(uInstanceTexture, instanceAt + ivec2(${i}, 0), 0)";
        "    int instanceIndex = uInstanceBase + gl_InstanceID;\n" +
        "    ivec2 instanceAt = ivec2((instanceIndex % ${instancesPerRow()}) * ${texelsPerInstance()}, instanceIndex / ${instancesPerRow()});\n" +
        "    mat4 model = mat4(${texel(0)}, ${texel(1)},\n" +
        "                      ${texel(2)}, ${texel(3)});\n" +
        "    vec4 instanceNormal0 = ${texel(4)};\n" +
        "    vec4 instanceNormal1 = ${texel(5)};\n" +
        "    vec4 instanceNormal2 = ${texel(6)};\n" +
        "    mat4 normalMatrix = mat4(vec4(instanceNormal0.xyz, 0.0), vec4(instanceNormal1.xyz, 0.0), vec4(instanceNormal2.xyz, 0.0), vec4(0.0, 0.0, 0.0, 1.0));\n" +
        "    vTint = ${texel(7)}.rgb;\n" +
        "    vEmissionIntensity = instanceNormal0.w;\n"

    /// 置いた物の頂点シェーダーの組み立て。declarations = 足す属性と uniform・prelude = main の頭・
    /// position = model を掛ける前の形の座標（vec4）・normal = normalMatrix を掛ける前の法線（vec3）・
    /// tangent = model の左上 3×3 を掛ける前のタンジェントの xyz（vec3。uv の無い形は None で vUv・vTangent を出さない）。
    /// タンジェントの w には model の左上 3×3 の行列式の符号を掛ける（鏡写しの置き方で絵の上の向きを保つ）。
    /// vertexColorToLinear = 頂点の色を r3d_srgbToLinear3 に通すか（declarations に colorSpaceSource() を入れる）。
    // WhyNot: タンジェントを normalMatrix で写さない — 法線の行列は面に垂直な向きを保つための物で、面の上の向きは model のまま写る。
    def meshVertexSourceOf(parts: { declarations = String, prelude = String, position = String, normal = String,
                                    tangent = Option[String], uv2 = Bool, vertexColorToLinear = Bool, psx = Bool }): String =
        // WhyNot: 画面の上でまっすぐつなぐ uv を noperspective で出さない — GLSL ES 3.00（WebGL2）には無い語で、スマホの GL ES の上の ANGLE ではコンパイルが落ちる。
        // uv と w を掛けて遠近で補正する普通の varying で送り、フラグメントで w で割り戻すと同じ値になる（gl_Position が決まった後に書く）。
        let affineUv = match parts#tangent {
            case Some(_) if parts#psx => "    vUvAffine = vec3(aUv * gl_Position.w, gl_Position.w);\n"
            case _                    => ""
        };
        let surfaceBody = match parts#tangent {
            case None    => ""
            case Some(t) =>
                (if (parts#psx) "    vUvPerspective = aUv;\n" else "    vUv = aUv;\n") +
                "    mat3 modelLinear = mat3(model);\n" +
                "    vTangent = vec4(modelLinear * (" + t + "), aTangent.w * sign(determinant(modelLinear)));\n"
        };
        "#version 330 core\n" +
        "layout (location = 0) in vec3 aPos;\n" +
        "layout (location = 1) in vec3 aNormal;\n" +
        "layout (location = 2) in vec3 aColor;\n" +
        parts#declarations +
        (if (parts#psx) vertexSnapSource() else "") +
        instanceDeclarations() +
        "uniform mat4 uView;\n" +
        "uniform mat4 uProj;\n" +
        "out vec3 vWorld;\n" +
        "out vec3 vNormal;\n" +
        "out vec3 vColor;\n" +
        "void main() {\n" +
        instancePrelude() +
        parts#prelude +
        "    vec4 world = model * " + parts#position + ";\n" +
        "    vWorld = world.xyz;\n" +
        "    vNormal = (normalMatrix * vec4(" + parts#normal + ", 0.0)).xyz;\n" +
        (if (parts#vertexColorToLinear) "    vColor = r3d_srgbToLinear3(aColor);\n" else "    vColor = aColor;\n") +
        surfaceBody +
        (if (parts#uv2) "    vUv2 = aUv2;\n" else "") +
        (if (parts#psx) "    gl_Position = r3d_vertexSnap(uProj * uView * world);\n" else "    gl_Position = uProj * uView * world;\n") +
        affineUv +
        "}\n"

    /// 光の uniform と、光の式（lightAt）・かすみ（fogged）。式は LightModel3d の木から作る（CPU の描き手と同じ木）。
    pub def lightSource(): String = lightSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の lightSource。v#pointShadows なら点光源の影の uniform と r3d_pointShadowsAt（pointShadowSource）・
    /// v#physicalUnits なら uInverseUnitsPerMeterSquared を・v#skyIrradiance なら景色の拡散の光の uSh・uSkyContribution を、光の式の前に置く（どれも偽なら lightSource と同じ字）。
    pub def lightSourceFor(v: Render3d.ShaderVariant): String =
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
        (if (v#pointShadows) pointShadowSource() else "") +
        (if (v#physicalUnits) "uniform float uInverseUnitsPerMeterSquared;\n" else "") +
        (if (v#psx) colorDepthSource() else "") +
        (if (v#skyIrradiance) "uniform vec3 uSh[9];\nuniform float uSkyContribution;\n" else "") +
        LightModel3d.Codegen.toGlsl("lightAt", Vec3Input.Position :: Vec3Input.Normal :: Nil, LightModel3d.lightingModelFor(Render3d.lightVariantOf(v))) +
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
        "float shadowLitFraction(sampler2D map, mat4 lightMatrix, float bias, int pcf, float shift, vec3 n, vec3 p) {\n" +
        "    vec4 c = lightMatrix * vec4(p + n * shift, 1.0);\n" +
        "    if (c.w <= 0.0) return 1.0;\n" +
        "    vec3 ndc = c.xyz / c.w;\n" +
        "    if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0) return 1.0;\n" +
        "    float z = (ndc.z * 0.5 + 0.5) - bias;\n" +
        "    ivec2 size = textureSize(map, 0);\n" +
        "    ivec2 last = size - ivec2(1);\n" +
        "    ivec2 center = clamp(ivec2(floor((ndc.xy * 0.5 + 0.5) * vec2(size))), ivec2(0), last);\n" +
        "    int lit = 0;\n" +
        "    int total = 0;\n" +
        "    for (int dy = -pcf; dy <= pcf; dy++) {\n" +
        "        for (int dx = -pcf; dx <= pcf; dx++) {\n" +
        "            ivec2 t = clamp(center + ivec2(dx, dy), ivec2(0), last);\n" +
        "            if (z <= texelFetch(map, t, 0).r) lit++;\n" +
        "            total++;\n" +
        "        }\n" +
        "    }\n" +
        "    return float(lit) / float(total);\n" +
        "}\n" +
        "float spotShadow(int i, vec3 p) {\n" +
        "    if (uShadowOn == 0 || i != uShadowSpot) return 1.0;\n" +
        "    return 1.0 - uShadowStrength * (1.0 - shadowLitFraction(uShadowMap, uShadowMatrix, uShadowBias, uShadowPcf, 0.0, vec3(0.0), p));\n" +
        "}\n" +
        sunShadowSource()

    /// 太陽の uniform（向き・color × intensity）と、その影の割合 sunLitAt(p, g, n)（Scene3d.directionalShadowOf の doc の約束・LightModel3d の SunLit。
    /// CPU の描き手は SoftRaster3d.Sun.litAt）。g = 点をずらす向きの法線（法線マップを当てる前・裏の面は裏返した物）・n = 光の計算の法線。
    /// 光の式の木は r3d_sunLit（frag の main が先に代入する。ビルボードは 1 のまま）を読む。uSunShadowOn = 0 のプログラムは 1 を返す。
    // WhyNot: 太陽へ背を向けた点（n·l ≤ 0）で地図を引かない — facing が 0 なので結果は同じで、pcf の (2r+1)² 回が無駄になる。
    def sunShadowSource(): String =
        "uniform vec3 uSunDir;\n" +
        "uniform vec3 uSunColor;\n" +
        "uniform int uSunShadowOn;\n" +
        "uniform mat4 uSunMatrix;\n" +
        "uniform sampler2D uSunMap;\n" +
        "uniform float uSunBias;\n" +
        "uniform float uSunNormalShift;\n" +
        "uniform int uSunPcf;\n" +
        "uniform float uSunStrength;\n" +
        "uniform vec3 uSunForward;\n" +
        "uniform vec2 uSunFade;\n" +
        "float r3d_sunLit = 1.0;\n" +
        "float sunLitAt(vec3 p, vec3 g, vec3 n) {\n" +
        "    if (uSunShadowOn == 0 || dot(n, uSunDir) <= 0.0) return 1.0;\n" +
        "    float fade = clamp((uSunFade.x - dot(p - uEye, uSunForward)) / uSunFade.y, 0.0, 1.0);\n" +
        "    if (fade <= 0.0) return 1.0;\n" +
        "    return 1.0 - uSunStrength * fade * (1.0 - shadowLitFraction(uSunMap, uSunMatrix, uSunBias, uSunPcf, uSunNormalShift, g, p));\n" +
        "}\n"

    /// 点光源の影の uniform と、点光源 i の光に掛ける割合 r3d_pointShadowLit(i, p, g, n)・それを点光源の数だけ r3d_pointLit へ埋める r3d_pointShadowsAt(p, g, n)
    /// （r3d_pointShadowLit は LightModel3d.PointShadowCodegen.toGlsl の生成物。CPU の描き手も同じ所から作る）。g = 点をずらす向きの法線（法線マップを当てる前・裏の面は裏返した物）・n = 光の計算の法線。
    /// uPointShadow[i] = (slot, A, B, strength)（slot が負なら影なし・near = B / (A + 1)）・uPointShadowAtlas = (面の一辺 S, 塊の横の数, 面の射影の倍率 s, pcf)・
    /// uPointShadowBias = (bias, normalBias)。frag の main が光の計算の前に r3d_pointShadowsAt を呼び、光の式の木は r3d_pointLit[i] を読む。
    // WhyNot: 光の式の木の中で地図を引かない — PBR の材質は拡散と鏡面の 2 つのループを回し、1 本につき 2 回引くことになる。
    def pointShadowSource(): String =
        let p = Scene3d.maxPointLights();
        "uniform vec4 uPointShadow[${p}];\n" +
        "uniform vec4 uPointShadowAtlas;\n" +
        "uniform vec2 uPointShadowBias;\n" +
        "uniform sampler2D uPointShadowMap;\n" +
        "float r3d_pointLit[${p}];\n" +
        LightModel3d.PointShadowCodegen.toGlsl() +
        "void r3d_pointShadowsAt(vec3 p, vec3 g, vec3 n) {\n" +
        "    for (int i = 0; i < ${p}; i++) r3d_pointLit[i] = r3d_pointShadowLit(i, p, g, n);\n" +
        "}\n"

    /// Output.Depth の灰色（目からの距離で near が黒・near + range が白）。uEye は呼ぶ側の frag が宣言する。
    def depthGraySource(): String =
        "uniform vec2 uDepthRange;\n" +
        "float depthGray(vec3 p) {\n" +
        "    return clamp((distance(p, uEye) - uDepthRange.x) / uDepthRange.y, 0.0, 1.0);\n" +
        "}\n"

    /// 頂点の色のプログラムの frag（vColor は litVertexSource が線形へ戻し済み）。
    pub def litFragmentSource(): String = litFragmentSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の litFragmentSource。
    pub def litFragmentSourceFor(v: Render3d.ShaderVariant): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec3 vNormal;\n" +
        "in vec3 vColor;\n" +
        "flat in vec3 vTint;\n" +
        "out vec4 fragColor;\n" +
        colorSpaceSource() +
        lightSourceFor(v) +
        "void main() {\n" +
        "    vec3 n = normalize(vNormal);\n" +
        "    r3d_sunLit = sunLitAt(vWorld, n, n);\n" +
        (if (v#pointShadows) "    r3d_pointShadowsAt(vWorld, n, n);\n" else "") +
        "    fragColor = vec4(" + colorOut(v, "r3d_surfaceOut(vColor, vTint, lightAt(vWorld, n), vec3(0.0), 1.0, vWorld, true)") + ", 1.0);\n" +
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
        let v = Render3d.shaderVariantOfKind(surface);
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
        "flat in vec3 vTint;\n" +
        "flat in float vEmissionIntensity;\n" +
        (if (surface#uv and v#psx) "in vec2 vUvPerspective;\nin vec3 vUvAffine;\nvec2 vUv;\n"
         else if (surface#uv) "in vec2 vUv;\n" else "const vec2 vUv = vec2(0.0, 0.0);\n") +
        (if (surface#lightmap) "in vec2 vUv2;\n" else "") +
        "out vec4 fragColor;\n" +
        "uniform int uCutout;\n" +
        "uniform int uDepthOut;\n" +
        colorSpaceSource() +
        lightSourceFor(v) +
        depthGraySource() +
        glsl#uniforms +
        glsl#functions +
        (if (needsMip) ShaderGen.texMipSource() else "") +
        (if (normalMapped) normalMapSource() else "") +
        (if (surface#lightmap) lightmapSource(v) else "") +
        (if (surface#metallicRoughness) metallicRoughnessSourceFor(v) else "") +
        "void main() {\n" +
        (if (surface#uv and v#psx) "    vUv = mix(vUvPerspective, vUvAffine.xy / vUvAffine.z, uPsx.w);\n" else "") +
        "    vec4 albedo;\n" +
        "    vec3 emission;\n" +
        (if (surface#metallicRoughness) "    vec2 metalRough;\n    materialEval(albedo, emission, metalRough);\n" else "    materialEval(albedo, emission);\n") +
        cutout +
        "    if (uDepthOut == 1) {\n" +
        "        float g = depthGray(vWorld);\n" +
        "        fragColor = vec4(g, g, g, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        facing +
        "    vec3 n = " + normal + ";\n" +
        "    r3d_sunLit = sunLitAt(vWorld, " + faceNormal + ", n);\n" +
        (if (v#pointShadows) "    r3d_pointShadowsAt(vWorld, " + faceNormal + ", n);\n" else "") +
        (if (surface#metallicRoughness)
            (if (surface#lightmap) "    vec3 light = lightmapLightAt(vWorld, n, lightmapColor());\n" else "    vec3 light = lightAt(vWorld, n);\n") +
            "    vec3 base = r3d_srgbToLinear3(albedo.rgb) * vTint;\n" +
            "    vec3 envColor = vec3(0.0);\n" +
            "    if (uEnvOn == 1) envColor = environmentColorAt(vWorld, n, base, vec3(metalRough, 0.0));\n" +
            "    vec3 lit = pbrAt(vWorld, n, base, light, vec3(metalRough, 0.0), envColor);\n" +
            "    fragColor = vec4(" + colorOut(v, "r3d_surfaceOutLit(lit, emission, vEmissionIntensity, vWorld)") + ", " + alpha + ");\n"
         else
            (if (surface#lightmap)
                "    vec3 light = lightmapLightAt(vWorld, n, lightmapColor());\n"
             else
                "    vec3 light = lightAt(vWorld, n);\n") +
            "    fragColor = vec4(" + colorOut(v, "r3d_surfaceOut(r3d_srgbToLinear3(albedo.rgb), vTint, light, emission, vEmissionIntensity, vWorld, true)") + ", " + alpha + ");\n") +
        "}\n"

    /// metallic と roughness を持つ材質の色 pbrAt(p, n, albedo × tint, 拡散の光, vec3(metallic, roughness, 0))（LightModel3d.pbrModel の木から作る）と、
    /// それが読む空の uniform と、かすみ → emission の組み立て r3d_surfaceOutLit(pbrAt の色, emission, intensity, p)。
    /// 色 = albedo × (1 − metallic) × light + 鏡面 + 映り込みをかすみに通してから、線形へ戻した emission × intensity を足して画面の値へ戻した物
    /// （CPU の描き手は SoftRaster3d.materialPixel と materialColor）。lightSource と colorSpaceSource() の後に置く。
    // WhyNot: r3d_surfaceOut を使い回さない — あちらは albedo × tint × light を中で掛けるので、鏡面を足すには掛け算の前後を別に書く必要があり、
    //   持たない材質の GLSL の字を変えることになる。
    pub def metallicRoughnessSource(): String = metallicRoughnessSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の metallicRoughnessSource（lightSourceFor(v) の後に置く）。
    pub def metallicRoughnessSourceFor(v: Render3d.ShaderVariant): String =
        "uniform vec3 uZenith;\n" +
        "uniform vec3 uHorizon;\n" +
        "uniform vec3 uGround;\n" +
        "uniform float uCurve;\n" +
        environmentSource() +
        LightModel3d.Codegen.toGlsl("pbrAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.Albedo :: Vec3Input.Light :: Vec3Input.MetallicRoughness ::
                                             Vec3Input.EnvironmentColor :: Nil,
                                    LightModel3d.pbrModelFor(Render3d.lightVariantOf(v))) +
        "vec3 r3d_surfaceOutLit(vec3 lit, vec3 emission, float intensity, vec3 p) {\n" +
        "    vec3 c = fogged(lit, p);\n" +
        "    return r3d_linearToSrgb3(c + r3d_srgbToLinear3(emission) * intensity);\n" +
        "}\n"

    /// 環境マップの uniform と、跳ね返りの向き（LightModel3d.environmentDirection の木から作る environmentDirectionAt）で絵を読む
    /// environmentColorAt(p, n, albedo × tint, vec3(metallic, roughness, 0))（線形の量・強さを掛けた色。CPU の描き手は SoftRaster3d.Internal.environmentColorAt）。
    /// 絵は向き → 座標（LightModel3d.environmentUvOf）で、段は roughness × (段の数 − 1)（LightModel3d.environmentLodOf）を明示して読む。
    /// uEnvOn = 0 のプログラムは読まない（呼ぶ側が分ける）。
    // WhyNot: sg_texMip（微分で段を選ぶ読み）を使わない — 向きの atan2 は継ぎ目（u = 0 と 1）で値が 1 跳び、その画素だけ段が最大になって縦の筋が出る。
    // WhyNot: 極（向きが真上・真下）の atan を GLSL に任せない — 引数が両方 0 の atan は値が決まらない。Flix の atan2 は 0 を返すので、同じ 0 にそろえる。
    def environmentSource(): String =
        "uniform int uEnvOn;\n" +
        "uniform int uEnvBoxOn;\n" +
        "uniform vec3 uEnvBoxMin;\n" +
        "uniform vec3 uEnvBoxMax;\n" +
        "uniform vec3 uEnvBoxCenter;\n" +
        "uniform sampler2D uEnvMap;\n" +
        "uniform float uEnvLevels;\n" +
        "uniform float uEnvIntensity;\n" +
        LightModel3d.Codegen.toGlsl("environmentDirectionAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.Albedo :: Vec3Input.MetallicRoughness :: Nil,
                                    LightModel3d.environmentDirection()) +
        environmentUvSource() +
        "vec3 environmentColorAt(vec3 p, vec3 n, vec3 albedo, vec3 metalRough) {\n" +
        "    vec3 d = environmentDirectionAt(p, n, albedo, metalRough);\n" +
        "    float lod = metalRough.y * (uEnvLevels - 1.0);\n" +
        "    return r3d_srgbToLinear3(textureLod(uEnvMap, environmentUv(d), lod).rgb) * uEnvIntensity;\n" +
        "}\n"

    /// 向き d（長さ 1）で環境マップを読む座標 environmentUv(d)（LightModel3d.environmentUvOf と同じ式）。
    def environmentUvSource(): String =
        "vec2 environmentUv(vec3 d) {\n" +
        "    float azimuth = (abs(d.x) + abs(d.z) < 1e-12) ? 0.0 : atan(d.x, -d.z);\n" +
        "    return vec2(0.5 + azimuth / 6.283185307179586, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / 3.141592653589793);\n" +
        "}\n"

    /// ベイクした光の uniform と、lightmap の絵の読み（lightmapColor）と、lightmap のある面の光の式（lightmapLightSource）。
    /// 段つきの Linear で読む（sg_texMip。段は Lightmap の maxLevels まで）。2 本目の uv の絵は場面の textures だけから引くので上下の反転は無い。
    def lightmapSource(v: Render3d.ShaderVariant): String =
        "uniform sampler2D uLightmap;\n" +
        "uniform float uLightmapLevels;\n" +
        "vec3 lightmapColor() {\n" +
        "    return sg_texMip(uLightmap, 0.0, uLightmapLevels, vUv2).rgb;\n" +
        "}\n" +
        lightmapLightSourceFor(v)

    /// lightmap のある面の光の式 lightmapLightAt(p, n, lightmap の色)（LightModel3d の木から作る）と、それが読む uniform。
    /// colorSpaceSource()（色の空間の関数）と lightSource の後に置く（光の uniform と spotShadow を読む）。
    pub def lightmapLightSource(): String = lightmapLightSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の lightmapLightSource（lightSourceFor(v) の後に置く）。
    pub def lightmapLightSourceFor(v: Render3d.ShaderVariant): String =
        "uniform int uLightmapSrgb;\n" +
        "uniform float uLightmapIntensity;\n" +
        LightModel3d.Codegen.toGlsl("lightmapLightAt", Vec3Input.Position :: Vec3Input.Normal :: Vec3Input.LightmapColor :: Nil,
                                    LightModel3d.lightmapLightingModelFor(Render3d.lightVariantOf(v)))

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

    /// ビルボードの頂点シェーダー: カメラの right / up で四角を立てる（aCorner は 0〜1・y は下向き）。板ごとの値は instance の attribute（location 1〜4・
    /// 並びは Render3d.SceneList.billboardValueFloats: 点と光の当て方・anchor と size・貼る範囲の uv・tint と影を受ける点を離す長さ）。
    /// uRightPerBillboard = 1 なら板の横の向きを tint の欄から読む（影の地図の点光源の面）。
    pub def billboardVertexSource(): String = billboardVertexSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の billboardVertexSource（v#psx なら四角の角を丸める）。
    pub def billboardVertexSourceFor(v: Render3d.ShaderVariant): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 aCorner;\n" +
        "layout (location = 1) in vec4 aCenterLit;\n" +
        "layout (location = 2) in vec4 aAnchorSize;\n" +
        "layout (location = 3) in vec4 aUvRect;\n" +
        "layout (location = 4) in vec4 aTintOffset;\n" +
        "uniform mat4 uView;\n" +
        "uniform mat4 uProj;\n" +
        "uniform vec3 uRight;\n" +
        "uniform vec3 uUp;\n" +
        "uniform int uRightPerBillboard;\n" +
        (if (v#psx) vertexSnapSource() else "") +
        "out vec3 vWorld;\n" +
        "out vec2 vUv;\n" +
        "out vec3 vShadowBase;\n" +
        "flat out vec3 vTint;\n" +
        "flat out int vLit;\n" +
        "flat out float vShadowOffset;\n" +
        "void main() {\n" +
        "    vec3 center = aCenterLit.xyz;\n" +
        "    vec2 anchor = aAnchorSize.xy;\n" +
        "    vec2 size = aAnchorSize.zw;\n" +
        "    vec3 right = uRightPerBillboard == 1 ? aTintOffset.xyz : uRight;\n" +
        "    vec3 world = center + right * ((aCorner.x - anchor.x) * size.x)\n" +
        "                        + uUp * ((anchor.y - aCorner.y) * size.y);\n" +
        "    vWorld = world;\n" +
        "    vUv = aUvRect.xy + aCorner * aUvRect.zw;\n" +
        "    vShadowBase = center + vec3(0.0, (anchor.y - aCorner.y) * size.y, 0.0);\n" +
        "    vTint = aTintOffset.xyz;\n" +
        "    vLit = int(aCenterLit.w + 0.5);\n" +
        "    vShadowOffset = aTintOffset.w;\n" +
        (if (v#psx) "    gl_Position = r3d_vertexSnap(uProj * uView * vec4(world, 1.0));\n" else "    gl_Position = uProj * uView * vec4(world, 1.0);\n") +
        "}\n"

    /// vLit（光の当て方）が 2 なら太陽の影を受ける。受ける点は vShadowBase（Scene3d.billboardShadowPointOf の太陽の方へ進める前の点）を
    /// 太陽の方へ vShadowOffset / max(太陽への向きの水平の長さ, Scene3d.billboardShadowMinFlat()) だけ進めた点。影の地図に描く時（Render3d.Shadow）は uDepthOut = 1 で、α で捨てた後に色を出さずに返る。
    pub def billboardFragmentSource(): String = billboardFragmentSourceFor(Render3d.defaultShaderVariant())

    /// 変種 v の billboardFragmentSource。ビルボードは点光源の影を受けないので v#pointShadows は読まない（Physical の光だけを変える）。
    pub def billboardFragmentSourceFor(v: Render3d.ShaderVariant): String =
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec2 vUv;\n" +
        "in vec3 vShadowBase;\n" +
        "flat in vec3 vTint;\n" +
        "flat in int vLit;\n" +
        "flat in float vShadowOffset;\n" +
        "out vec4 fragColor;\n" +
        "uniform sampler2D uImage;\n" +
        "uniform vec3 uFacing;\n" +
        "uniform int uDepthOut;\n" +
        colorSpaceSource() +
        lightSourceFor(Render3d.billboardVariantOf(v)) +
        depthGraySource() +
        "void main() {\n" +
        "    vec4 texel = texture(uImage, vUv);\n" +
        "    if (texel.a < 0.5) discard;\n" +
        "    if (uDepthOut == 1) {\n" +
        "        float g = depthGray(vWorld);\n" +
        "        fragColor = vec4(g, g, g, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    if (vLit == 2) r3d_sunLit = sunLitAt(vShadowBase + uSunDir * (vShadowOffset / max(length(uSunDir.xz), ${Scene3d.billboardShadowMinFlat()})), uSunDir, normalize(uFacing));\n" +
        "    vec3 light = vLit >= 1 ? lightAt(vWorld, normalize(uFacing)) : vec3(1.0);\n" +
        "    fragColor = vec4(" + colorOut(v, "r3d_surfaceOut(r3d_srgbToLinear3(texel.rgb), vTint, light, vec3(0.0), 1.0, vWorld, vLit >= 1)") + ", 1.0);\n" +
        "}\n"

    /// 空の frag（式は LightModel3d.skyModel・向きは Scene3d.skyDirectionOf。NDC は画素の真ん中の gl_FragCoord と viewport から）。
    /// uEnvOn = 1 なら空の代わりに環境マップの絵を段 0 で読む（Scene3d.backgroundEnvironmentOf。CPU の描き手は SoftRaster3d.Internal.environmentBackgroundAt）。
    pub def skyFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        "uniform vec4 uViewport;\n" +
        "uniform vec3 uForward;\n" +
        "uniform vec3 uRight;\n" +
        "uniform vec3 uUp;\n" +
        "uniform int uDepthOut;\n" +
        "uniform int uEnvOn;\n" +
        "uniform sampler2D uEnvMap;\n" +
        "uniform float uEnvIntensity;\n" +
        colorSpaceSource() +
        skyLightSource() +
        environmentUvSource() +
        "void main() {\n" +
        "    if (uDepthOut == 1) {\n" +
        "        fragColor = vec4(1.0, 1.0, 1.0, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    vec2 ndc = (gl_FragCoord.xy - uViewport.xy) / uViewport.zw * 2.0 - 1.0;\n" +
        "    vec3 d = normalize(uForward + uRight * ndc.x + uUp * ndc.y);\n" +
        "    if (uEnvOn == 1) {\n" +
        "        fragColor = vec4(r3d_linearToSrgb3(r3d_srgbToLinear3(textureLod(uEnvMap, environmentUv(d), 0.0).rgb) * uEnvIntensity), 1.0);\n" +
        "        return;\n" +
        "    }\n" +
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
