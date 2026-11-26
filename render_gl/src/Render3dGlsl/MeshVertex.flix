// Render3dGlsl.MeshVertex — 置いた物（深度だけ・材質・lit）の頂点シェーダーの GLSL の字。Render3dWgsl.MeshVertex と式を 1 行ずつそろえる。
// WhyNot: ShaderAst の木で書かない — 木の組み立てを足すと wasm の brotli が上限（S0 の +6%）に届く。木にする時は varying の表の書き手として VertexEntry に載せる。
mod Render3dGlsl.MeshVertex {
    use Render3d.Uniforms.R3dUniform

    /// 骨の無い・uv の無い版（Render3dGlsl.meshVertexSource）。psx なら頂点を丸める。
    pub def meshSource(psx: Bool): String =
        meshSourceOf({ declarations = "", prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = None, uv2 = false,
                       vertexColorToLinear = false, psx = psx })

    /// 頂点の色のプログラム（lit）の版（Render3dGlsl.litVertexSourceFor）。頂点の色を線形の量へ戻してから渡す。
    pub def litSource(skinned: Bool, psx: Bool): String =
        if (skinned)
            meshSourceOf({ declarations = skinDeclarations() + Render3dGlsl.colorSpaceSource(), prelude = skinPrelude(), position = "skin * vec4(aPos, 1.0)",
                           normal = "mat3(skin) * aNormal", tangent = None, uv2 = false, vertexColorToLinear = true, psx = psx })
        else
            meshSourceOf({ declarations = Render3dGlsl.colorSpaceSource(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                           tangent = None, uv2 = false, vertexColorToLinear = true, psx = psx })

    /// 骨つきの・uv の無い版（Render3dGlsl.skinnedMeshVertexSource）。
    pub def skinnedSource(psx: Bool): String =
        meshSourceOf({
            declarations = skinDeclarations(),
            prelude = skinPrelude(),
            position = "skin * vec4(aPos, 1.0)",
            normal = "mat3(skin) * aNormal",
            tangent = None,
            uv2 = false,
            vertexColorToLinear = false,
            psx = psx })

    /// 材質のプログラムの版（Render3dGlsl.materialVertexSourceFor）。
    pub def materialSource(kind: { skinned = Bool, uv = Bool, lightmap = Bool }, psx: Bool): String =
        match (kind#skinned, kind#uv, kind#lightmap) {
            case (false, false, false) => meshSource(psx)
            case (true, false, _)      => skinnedSource(psx)
            case (false, false, true)  =>
                meshSourceOf({ declarations = uv2Declarations(), prelude = "", position = "vec4(aPos, 1.0)", normal = "aNormal",
                               tangent = None, uv2 = true, vertexColorToLinear = false, psx = psx })
            case (false, true, lm)     =>
                meshSourceOf({ declarations = surfaceDeclarations(psx) + (if (lm) uv2Declarations() else ""), prelude = "",
                               position = "vec4(aPos, 1.0)", normal = "aNormal", tangent = Some("aTangent.xyz"), uv2 = lm,
                               vertexColorToLinear = false, psx = psx })
            case (true, true, _)       =>
                meshSourceOf({ declarations = skinDeclarations() + surfaceDeclarations(psx), prelude = skinPrelude(),
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

    /// 1 体ごとの値のテクスチャの宣言（並びは Render3d.InstanceValues の頭）。
    def instanceDeclarations(): String =
        Render3d.Uniforms.glslDeclarations(R3dUniform.InstanceTexture :: R3dUniform.InstanceBase :: Nil) +
        "flat out vec3 vTint;\n" +
        "flat out float vEmissionIntensity;\n"

    /// main の頭: 1 体ごとの値を読む。model = world の行列・normalMatrix = 法線の行列。
    def instancePrelude(): String =
        let texel = (i: Int32) -> "texelFetch(uInstanceTexture, instanceAt + ivec2(${i}, 0), 0)";
        let perRow = Render3dGlsl.instancesPerRow();
        let width = Render3dGlsl.texelsPerInstance();
        "    int instanceIndex = uInstanceBase + gl_InstanceID;\n" +
        "    ivec2 instanceAt = ivec2((instanceIndex % ${perRow}) * ${width}, instanceIndex / ${perRow});\n" +
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
    /// vertexColorToLinear = 頂点の色を r3d_srgbToLinear3 に通すか（declarations に Render3dGlsl.colorSpaceSource() を入れる）。
    // WhyNot: タンジェントを normalMatrix で写さない — 法線の行列は面に垂直な向きを保つための物で、面の上の向きは model のまま写る。
    def meshSourceOf(parts: { declarations = String, prelude = String, position = String, normal = String,
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
}
