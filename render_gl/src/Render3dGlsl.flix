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
    use Render3d.Uniforms.R3dUniform

    /// 置いた物の頂点シェーダー（深度だけのプログラム・uv の無い材質のプログラムで共有。頂点の色は値のまま渡す）。
    pub def meshVertexSource(): String = meshVertexSourceFor(false)

    /// psx（PS1 風の変種 +psx）なら頂点を丸める版の meshVertexSource。
    def meshVertexSourceFor(psx: Bool): String =
        meshVertexSourceOf({ declarations = "", prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = None, uv2 = false,
                             vertexColorToLinear = false, psx = psx })

    /// 頂点の色のプログラム（lit）の頂点シェーダー。頂点の色を線形の量へ戻してから渡す（三角形の中は線形の量でつなぐ）。
    /// skinned なら骨つきの版。
    // WhyNot: meshVertexSource と共有しない — uv の無い材質の Spec の VertexColor まで線形の値になり、出口でもう一度戻して暗くなる。
    pub def litVertexSource(skinned: Bool): String = litVertexSourceFor(skinned, Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の litVertexSource（v#psx なら頂点を丸める）。
    pub def litVertexSourceFor(skinned: Bool, v: Render3d.ProgramKey.ShaderVariant): String =
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
        Render3d.Uniforms.glslDeclarations(R3dUniform.JointTexture :: Nil) +
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
    def vertexSnapSource(): String = ShaderAst.Glsl.print(Render3dShaders.vertexSnap() :: Nil)

    /// 変種 v の frag の色の出口の字（c は画面の値の色の式の字。v の feature の colorOut に通す）。
    def colorOut(v: Render3d.ProgramKey.ShaderVariant, c: String): String =
        ShaderAst.Glsl.expression(Render3dShaders.featureOf(v)#colorOut(ShaderAst.rawExpr(ShaderAst.Vec3.Vec3, c, c, Nil, false)))

    /// 頂点シェーダーへ数を渡すテクスチャの幅（texel）。
    pub def dataTextureWidth(): Int32 = Skin3d.maxJoints() * 4

    /// 1 体ごとの値の 1 体の幅（texel）。
    pub def texelsPerInstance(): Int32 = Render3d.InstanceValues.texelsPerInstance()

    /// 1 体ごとの値のテクスチャの 1 行の体の数（dataTextureWidth は texelsPerInstance で割り切れる）。
    pub def instancesPerRow(): Int32 = dataTextureWidth() / texelsPerInstance()

    /// 1 体ごとの値のテクスチャの宣言（並びは Render3d.InstanceValues の頭）。
    def instanceDeclarations(): String =
        Render3d.Uniforms.glslDeclarations(R3dUniform.InstanceTexture :: R3dUniform.InstanceBase :: Nil) +
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
        Render3d.Uniforms.glslDeclarations(R3dUniform.View :: R3dUniform.Proj :: Nil) +
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

    /// 光の uniform と、光の式（lightAt）・かすみ（fogged）・影・色を作る最後の組み立て。式は LightModel3d の木から作る（CPU の描き手と同じ木）。
    pub def lightSource(): String = lightSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の lightSource（v の feature が足す定義を含める）。
    pub def lightSourceFor(v: Render3d.ProgramKey.ShaderVariant): String = ShaderAst.Glsl.print(Render3dShaders.lightDefinitions(v, Render3dShaders.featureOf(v)))

    /// 3D の色を作る最後の組み立て r3d_surfaceOut(albedoLinear, tint, light, emission, intensity, p, fogOn)（CPU の描き手は SoftRaster3d.materialColor と shadePixel）:
    /// 色 = albedoLinear × tint × light（fogOn ならかすみ）+ 線形へ戻した emission × intensity を、画面の値へ戻した物。
    /// albedoLinear は線形へ戻し済みの色（材質は r3d_srgbToLinear3(albedo.rgb)・ビルボードは絵・lit は頂点で戻した vColor）。
    // WhyNot: albedo をここで戻さない — lit の頂点の色は頂点シェーダーで戻してあり、ここで戻すと 2 回かかる。
    // WhyNot: emission にかすみを掛けない — 自分で光る物（溶岩・目）は遠くでもかすみに沈まずに見えてほしい。
    // WhyNot: 光の式の木（LightModel3d）に入れない — かすみの有無・ビルボードの lit・Depth の枝まで木の入力にすることになる。
    pub def surfaceOutSource(): String = ShaderAst.Glsl.print(Render3dShaders.surfaceOut() :: Nil)

    /// 色の空間の変換: Texture3d の式のスカラーの r3d_srgbToLinear / r3d_linearToSrgb と、
    /// その vec3 の版 r3d_srgbToLinear3 / r3d_linearToSrgb3。lit の頂点シェーダーが含める（frag は使う所から辿る）。
    pub def colorSpaceSource(): String = ShaderAst.Glsl.print(Render3dShaders.colorSpace())

    /// 頂点の色のプログラムの frag（vColor は litVertexSource が線形へ戻し済み）。
    pub def litFragmentSource(): String = litFragmentSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の litFragmentSource。
    pub def litFragmentSourceFor(v: Render3d.ProgramKey.ShaderVariant): String = ShaderAst.Glsl.fragment(Render3dShaders.litFragment(v, Nil))

    /// 材質の frag（本文は Render3dShaders.materialFragmentBody）。surface#uv = uv つきの形か（偽なら vUv は (0, 0) の const）・
    /// surface#normalMap = 法線マップを当てるか（uv つきの時だけ。光の計算の法線を、法線マップで傾けた n' にする）。
    /// 材質の部品（glsl#functions の materialEval）は大域の vUv・vWorld・vNormal・vColor を読む。psx の uv つきの vUv は main の頭で代入する大域の変数。
    // WhyNot: 欄を 1 つずつ並べた引数にしない — ProgramKind に欄が増えるたびに、呼び手とテストの字が全部書き換わる。skinned は頂点の側だけが読む。
    pub def materialFragmentSource(glsl: ShaderGen.MaterialGlsl, surface: Render3d.ProgramKey.ProgramKind): String =
        ShaderAst.Glsl.fragment(Render3dShaders.materialFragment(surface, Render3dShaders.glslMaterialPart(glsl, surface), Nil))

    /// metallic と roughness を持つ材質の色 pbrAt(p, n, albedo × tint, 拡散の光, vec3(metallic, roughness, 0), 映り込み)（LightModel3d.pbrModel の木から作る）と、
    /// それが読む環境マップの読みと、かすみ → emission の組み立て r3d_surfaceOutLit(pbrAt の色, emission, intensity, p)。
    /// 色 = albedo × (1 − metallic) × light + 鏡面 + 映り込みをかすみに通してから、線形へ戻した emission × intensity を足して画面の値へ戻した物
    /// （CPU の描き手は SoftRaster3d.materialPixel と materialColor）。
    // WhyNot: r3d_surfaceOut を使い回さない — あちらは albedo × tint × light を中で掛けるので、鏡面を足すには掛け算の前後を別に書く必要があり、
    //   持たない材質の GLSL の字を変えることになる。
    pub def metallicRoughnessSource(): String = metallicRoughnessSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の metallicRoughnessSource。
    pub def metallicRoughnessSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Glsl.print(Render3dShaders.metallicRoughnessDefinitions(v, Render3dShaders.featureOf(v)))

    /// lightmap のある面の光の式 lightmapLightAt(p, n, lightmap の色)（LightModel3d の木から作る）と、それが読む uniform と関数。
    pub def lightmapLightSource(): String = lightmapLightSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の lightmapLightSource。
    pub def lightmapLightSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        ShaderAst.Glsl.print(Render3dShaders.lightmapLightAt(v, Render3dShaders.featureOf(v)#spotShadow(Render3dShaders.spotShadow())) :: Nil)

    /// 外向きの法線 n をタンジェント（xyz と w）と法線マップの rgb c で傾けた applyNormalMap(n, tangent, strength, c)（式は Render3d.flix の頭。
    /// CPU の描き手は SoftRaster3d.applyNormalMap）。
    // WhyNot: タンジェントを頂点の値のまま使わない — 補間で N との直交が崩れ、傾ける向きが法線の側へ漏れる。
    // WhyNot: 長さ 0 のタンジェントで傾けない — normalize が NaN を出し、画素が黒く抜ける。その画素は n のまま。
    pub def applyNormalMapSource(): String = ShaderAst.Glsl.print(Render3dShaders.applyNormalMap() :: Nil)

    /// 奥行きの書き出し（Output.Depth）の形だけの frag（本文は Render3dShaders.depthFragment）。
    pub def depthFragmentSource(): String = ShaderAst.Glsl.fragment(Render3dShaders.depthFragment(Nil))

    /// ビルボードの頂点シェーダー: カメラの right / up で四角を立てる（aCorner は 0〜1・y は下向き）。板ごとの値は instance の attribute（location 1〜4・
    /// 並びは Render3d.SceneList.billboardValueFloats: 点と光の当て方・anchor と size・貼る範囲の uv・tint と影を受ける点を離す長さ）。
    /// uRightPerBillboard = 1 なら板の横の向きを tint の欄から読む（影の地図の点光源の面）。
    pub def billboardVertexSource(): String = billboardVertexSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の billboardVertexSource（v#psx なら四角の角を丸める）。
    pub def billboardVertexSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec2 aCorner;\n" +
        "layout (location = 1) in vec4 aCenterLit;\n" +
        "layout (location = 2) in vec4 aAnchorSize;\n" +
        "layout (location = 3) in vec4 aUvRect;\n" +
        "layout (location = 4) in vec4 aTintOffset;\n" +
        Render3d.Uniforms.glslDeclarations(R3dUniform.View :: R3dUniform.Proj :: R3dUniform.Right :: R3dUniform.Up :: R3dUniform.RightPerBillboard :: Nil) +
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
    pub def billboardFragmentSource(): String = billboardFragmentSourceFor(Render3d.ProgramKey.defaultShaderVariant())

    /// 変種 v の billboardFragmentSource。ビルボードは点光源の影を受けないので v#pointShadows は読まない（Physical の光だけを変える）。
    pub def billboardFragmentSourceFor(v: Render3d.ProgramKey.ShaderVariant): String =
        let bv = Render3d.ProgramKey.billboardVariantOf(v);
        "#version 330 core\n" +
        "in vec3 vWorld;\n" +
        "in vec2 vUv;\n" +
        "in vec3 vShadowBase;\n" +
        "flat in vec3 vTint;\n" +
        "flat in int vLit;\n" +
        "flat in float vShadowOffset;\n" +
        "out vec4 fragColor;\n" +
        Render3d.Uniforms.glslDeclarations(R3dUniform.Image :: R3dUniform.Facing :: R3dUniform.DepthOut :: Nil) +
        ShaderAst.Glsl.print(Render3dShaders.colorSpace() ::: Render3dShaders.depthGray() ::
                             Render3dShaders.lightDefinitions(bv, Render3dShaders.featureOf(bv))) +
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
        "    fragColor = vec4(" + colorOut(bv, "r3d_surfaceOut(r3d_srgbToLinear3(texel.rgb), vTint, light, vec3(0.0), 1.0, vWorld, vLit >= 1)") + ", 1.0);\n" +
        "}\n"

    /// 空の frag（式は LightModel3d.skyModel・向きは Scene3d.skyDirectionOf。NDC は画素の真ん中の gl_FragCoord と viewport から）。
    /// uEnvOn = 1 なら空の代わりに環境マップの絵を段 0 で読む（Scene3d.backgroundEnvironmentOf。CPU の描き手は SoftRaster3d.Internal.environmentBackgroundAt）。
    pub def skyFragmentSource(): String =
        "#version 330 core\n" +
        "in vec2 vUv;\n" +
        "out vec4 fragColor;\n" +
        Render3d.Uniforms.glslDeclarations(R3dUniform.Viewport :: R3dUniform.Forward :: R3dUniform.Right :: R3dUniform.Up :: R3dUniform.DepthOut :: R3dUniform.EnvOn :: R3dUniform.EnvMap :: R3dUniform.EnvIntensity :: R3dUniform.EnvSrgb :: Nil) +
        ShaderAst.Glsl.print(Render3dShaders.colorSpace() ::: Render3dShaders.skyAt() :: Render3dShaders.environmentUv() :: Nil) +
        "void main() {\n" +
        "    if (uDepthOut == 1) {\n" +
        "        fragColor = vec4(1.0, 1.0, 1.0, 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    vec2 ndc = (gl_FragCoord.xy - uViewport.xy) / uViewport.zw * 2.0 - 1.0;\n" +
        "    vec3 d = normalize(uForward + uRight * ndc.x + uUp * ndc.y);\n" +
        "    if (uEnvOn == 1) {\n" +
        "        vec3 c = textureLod(uEnvMap, environmentUv(d), 0.0).rgb;\n" +
        "        fragColor = vec4(r3d_linearToSrgb3((uEnvSrgb == 1 ? r3d_srgbToLinear3(c) : c) * uEnvIntensity), 1.0);\n" +
        "        return;\n" +
        "    }\n" +
        "    fragColor = vec4(r3d_linearToSrgb3(skyAt(d)), 1.0);\n" +
        "}\n"

    /// 空の色の式 skyAt(向き)（LightModel3d の木から作る）と、それが読む uniform。
    pub def skyLightSource(): String = ShaderAst.Glsl.print(Render3dShaders.skyAt() :: Nil)

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
        Render3d.Uniforms.glslDeclarations(R3dUniform.Image :: Nil) +
        "void main() {\n" +
        "    fragColor = texture(uImage, vUv);\n" +
        "}\n"
}
