// Render3dWgsl.MeshVertex — 置いた物（材質・lit）の頂点シェーダーの WGSL の字。Render3dGlsl.MeshVertex と式を 1 行ずつそろえる。
// WhyNot: ShaderAst の木で書かない — 木の組み立てを足すと wasm の brotli の大きさが上限に届く（docs/performance.md の 8 節）。木にする時は varying の表の書き手として VertexEntry に載せる。
mod Render3dWgsl.MeshVertex {

    /// 頂点の色のプログラムの版。psx なら頂点を丸める。
    pub def litSource(skinned: Bool, psx: Bool): String =
        let local = localOf(skinned);
        cameraDeclarationsFor(psx) +
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
        Render3dWgsl.colorSpaceSource() +
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
        "    o.position = " + clipOut(psx, "r3dCamera.uProj * r3dCamera.uView * world") + ";\n" +
        "    return o;\n" +
        "}\n"

    /// 材質のプログラムの版。psx なら頂点を丸め、uv つきの版は location 8 の vUvAffine も出す。
    pub def materialSource(uv: Bool, lightmap: Bool, skinned: Bool, psx: Bool): String =
        let local = localOf(skinned);
        let lm = lightmap and not skinned;
        cameraDeclarationsFor(psx) +
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
        (if (uv and psx) "    @location(8) @interpolate(linear) vUvAffine: vec2f,\n" else "") +
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
            (if (psx) "    o.vUvAffine = v.aUv;\n" else "") +
            "    let modelLinear = mat3x3f(model[0].xyz, model[1].xyz, model[2].xyz);\n" +
            "    o.vTangent = vec4f(modelLinear * (" + local#tangent + "), v.aTangent.w * sign(determinant(modelLinear)));\n"
         else "") +
        (if (lm) "    o.vUv2 = v.aUv2;\n" else "") +
        "    o.position = " + clipOut(psx, "r3dCamera.uProj * r3dCamera.uView * world") + ";\n" +
        "    return o;\n" +
        "}\n"

    /// PS1 風の変種の頂点を丸める式 r3d_vertexSnap(GL の clip の位置)（Render3dGlsl.MeshVertex と同じ式）。r3dCamera.uSnap = (描き先の幅, 高さ, 格子, 0)。
    def vertexSnapSource(): String = ShaderAst.Wgsl.print(Render3dShaders.vertexSnap() :: Nil)

    /// 頂点シェーダーの clip の位置の出口（GL の clip の式 c を sg_clipFromGl へ。psx なら先に r3d_vertexSnap で丸める）。
    def clipOut(psx: Bool, c: String): String = if (psx) "sg_clipFromGl(r3d_vertexSnap(" + c + "))" else "sg_clipFromGl(" + c + ")"

    /// psx（PS1 風の変種）なら末尾に uSnap つきの struct と r3d_vertexSnap を置く版の Render3dWgsl.cameraDeclarations。
    // WhyNot: 既定の struct に uSnap を足さない — 既定の頂点シェーダーの字が変わる。buffer は cameraBytes() の大きさで作るので、短い struct の版もそのまま読める。
    def cameraDeclarationsFor(psx: Bool): String = Render3dWgsl.cameraStructFor(psx) + (if (psx) vertexSnapSource() else "")

    /// 姿勢の行列（group 2 の binding 0・読むだけの storage）。詰める側（Render3d.WebGpuRenderer）は頭の 16 バイトに 1 行のジョイントの数（u32）、
    /// その後に行の順に 1 行 jointsPerRow 本の mat4（列優先・Render3d.PoseRows.packRows の並び）。
    // WhyNot: uniform にしない — 1 回の prepare の違う姿勢を 1 つの binding に入れると 64 KiB を超える（ジョイント 64 本の姿勢 1 つで 4 KiB）。
    //   姿勢ごとに区画を bind すると行ごとに group を作ることになり、同じ姿勢を共有する batch が分かれる。
    // WhyNot: GL と同じ RGBA32F の絵にしない — 絵の 1 行の幅（4 × ジョイント数）で行の数が決まり、storage は番号で引くだけで済む。
    def poseDeclarations(): String =
        "struct R3dPoses { jointsPerRow: u32, matrices: array<mat4x4f> };\n" +
        "@group(2) @binding(0) var<storage, read> r3dPoses: R3dPoses;\n" +
        "fn r3d_jointMatrix(row: u32, joint: f32) -> mat4x4f { return r3dPoses.matrices[row * r3dPoses.jointsPerRow + u32(joint)]; }\n"

    /// 骨つきの版の頂点の入力（形の版の buffer の location 14・15。ジョイントの番号は float の 4 つ）。
    // WhyNot: ジョイントの番号を u32 の属性にしない — 形の版は 1 本の Float32 の buffer に交互に並べ（Render3d.WebGpuRows）、番号は 64 未満で float に正確に入る。
    def skinInputs(skinned: Bool): String =
        if (skinned) "    @location(14) aJoints: vec4f,\n    @location(15) aWeights: vec4f,\n" else ""

    /// 骨つきの版の main の頭: 姿勢の行（1 体ごとの値の normal1.w）の joint 行列を重みで足す（Render3dGlsl.MeshVertex と同じ式）。
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
}
