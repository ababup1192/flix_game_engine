// RenderPaint.Internal.WebGpuShader — WebGPU の 2D の道の WGSL（スプライト・字・箱を 1 本、多角形を 1 本、タイルの層を 1 本、中間の texture を画面へ写す 1 本）。
// 対の GLSL は RenderShader の同じ種類の物で、式は 1 行ずつ同じに書く。
// スプライトの頂点の属性（location 1〜10・stride 152 バイト）は RenderFrame.writeInstAt の並びのまま instance の頂点バッファから読む。
pub mod RenderPaint.Internal.WebGpuShader {

    /// スプライト・字・箱の WGSL。入口は vs_main・fs_main・fs_multiply（Multiply の blend の時の rgb × a）。
    /// group 0 = 射影の行列（uniform）・group 1 = 絵の view と sampler。字の絵（R8_UNORM）は .r を距離場として読む。
    // WhyNot: 標本と微分を分岐の中で取らない — WGSL は値で分かれる分岐の中で textureSample と fwidth を呼べない（式の値は GLSL と同じ）。
    // WhyNot: % で縞と市松を取らない — WGSL の % は 0 の向きに切り、負の値で GLSL の mod と答えが違う。
    pub def spriteWgsl(): String =
        "struct Frame { projection: mat4x4f };\n" +
        "@group(0) @binding(0) var<uniform> frame: Frame;\n" +
        "@group(1) @binding(0) var image: texture_2d<f32>;\n" +
        "@group(1) @binding(1) var imageSampler: sampler;\n" +
        "struct VsOut {\n" +
        "    @builtin(position) position: vec4f,\n" +
        "    @location(0) texCoords: vec2f,\n" +
        "    @location(1) color: vec4f,\n" +
        "    @location(2) flags: vec4f,\n" +
        "    @location(3) rect: vec4f,\n" +
        "    @location(4) border: vec4f,\n" +
        "    @location(5) hatch: vec4f,\n" +
        "    @location(6) hatchDim: vec4f,\n" +
        "    @location(7) checker: vec4f,\n" +
        "};\n" +
        "@vertex fn vs_main(@builtin(vertex_index) vi: u32,\n" +
        "                   @location(1) inst1: vec4f, @location(2) inst2: vec2f, @location(3) inst3: vec4f,\n" +
        "                   @location(4) inst4: vec4f, @location(5) inst5: vec4f, @location(6) inst6: vec4f,\n" +
        "                   @location(7) inst7: vec4f, @location(8) inst8: vec4f, @location(9) inst9: vec4f,\n" +
        "                   @location(10) inst10: vec4f) -> VsOut {\n" +
        "    var quad = array<vec4f, 6>(vec4f(0.0, 1.0, 0.0, 1.0), vec4f(1.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 0.0),\n" +
        "                               vec4f(0.0, 1.0, 0.0, 1.0), vec4f(1.0, 1.0, 1.0, 1.0), vec4f(1.0, 0.0, 1.0, 0.0));\n" +
        "    let vertex = quad[vi];\n" +
        "    var o: VsOut;\n" +
        "    let world = mat2x2f(inst1.xy, inst1.zw) * vertex.xy + inst2;\n" +
        "    o.position = frame.projection * vec4f(world, 0.0, 1.0);\n" +
        "    o.texCoords = vertex.zw * inst3.zw + inst3.xy;\n" +
        "    o.color = inst4;\n" +
        "    o.flags = inst5;\n" +
        "    o.rect = inst6;\n" +
        "    o.border = inst7;\n" +
        "    o.hatch = inst8;\n" +
        "    o.hatchDim = inst9;\n" +
        "    o.checker = inst10;\n" +
        "    return o;\n" +
        "}\n" +
        "fn roundedBox(p: vec2f, hsz: vec2f, r: f32) -> f32 {\n" +
        "    let q = abs(p) - hsz + r;\n" +
        "    return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0))) - r;\n" +
        "}\n" +
        "fn glslMod(x: f32, y: f32) -> f32 { return x - y * floor(x / y); }\n" +
        "fn shade(i: VsOut) -> vec4f {\n" +
        "    let t = textureSample(image, imageSampler, i.texCoords);\n" +
        "    let d = t.r;\n" +
        "    let aaText = fwidth(d);\n" +
        "    let hsz = i.rect.xy * 0.5;\n" +
        "    let p = i.texCoords * i.rect.xy - hsz;\n" +
        "    let cr = clamp(i.rect.z, 0.0, min(hsz.x, hsz.y));\n" +
        "    let dOuter = roundedBox(p, hsz, cr);\n" +
        "    let aaO = max(fwidth(dOuter), 0.0001);\n" +
        "    let ri = max(cr - i.rect.w, 0.0);\n" +
        "    let hi = max(hsz - vec2f(i.rect.w), vec2f(0.0));\n" +
        "    let dInner = roundedBox(p, hi, ri);\n" +
        "    let aaI = max(fwidth(dInner), 0.0001);\n" +
        "    let hv = select(select(p.x - p.y, p.y, i.hatchDim.z > 0.5), p.x, i.hatchDim.z > 1.5);\n" +
        "    let hvAa = max(fwidth(hv), 0.0001);\n" +
        "    if (i.flags.x > 0.5) {\n" +
        "        if (i.flags.y > 0.5) {\n" +
        "            let a = smoothstep(0.5 - aaText, 0.5 + aaText, d);\n" +
        "            if (a < 0.004) { discard; }\n" +
        "            return vec4f(i.color.rgb, i.color.a * a);\n" +
        "        }\n" +
        "        let ta = clamp(t.a, 0.0, 1.0);\n" +
        "        return i.color * vec4f(t.rgb, ta);\n" +
        "    }\n" +
        "    if (i.flags.z > 0.5) {\n" +
        "        let outerCov = 1.0 - smoothstep(0.0, aaO, dOuter);\n" +
        "        let fillCov = 1.0 - smoothstep(0.0, aaI, dInner);\n" +
        "        var fillRgb = i.color.rgb;\n" +
        "        var fillA = i.color.a;\n" +
        "        if (i.flags.w > 0.5) {\n" +
        "            let m = glslMod(hv, i.hatchDim.y);\n" +
        "            let haa = select(hvAa, 0.0001, i.hatchDim.z > 0.5);\n" +
        "            let sOn = smoothstep(0.0, haa, m) - smoothstep(i.hatchDim.x, i.hatchDim.x + haa, m);\n" +
        "            let sa = i.hatch.a * clamp(sOn, 0.0, 1.0);\n" +
        "            let outA = sa + fillA * (1.0 - sa);\n" +
        "            fillRgb = select(fillRgb, (i.hatch.rgb * sa + fillRgb * fillA * (1.0 - sa)) / outA, outA > 0.0001);\n" +
        "            fillA = outA;\n" +
        "        }\n" +
        "        if (i.hatchDim.w > 0.0 && i.checker.a > 0.0) {\n" +
        "            let on = glslMod(floor(p.x / i.hatchDim.w) + floor(p.y / i.hatchDim.w), 2.0) < 0.5;\n" +
        "            let ca = select(0.0, i.checker.a, on);\n" +
        "            let outA = ca + fillA * (1.0 - ca);\n" +
        "            fillRgb = select(fillRgb, (i.checker.rgb * ca + fillRgb * fillA * (1.0 - ca)) / outA, outA > 0.0001);\n" +
        "            fillA = outA;\n" +
        "        }\n" +
        "        let rgb = mix(i.border.rgb, fillRgb, fillCov);\n" +
        "        let a = mix(i.border.a, fillA, fillCov) * outerCov;\n" +
        "        if (a < 0.004) { discard; }\n" +
        "        return vec4f(rgb, a);\n" +
        "    }\n" +
        "    return i.color;\n" +
        "}\n" +
        "@fragment fn fs_main(i: VsOut) -> @location(0) vec4f { return shade(i); }\n" +
        "@fragment fn fs_multiply(i: VsOut) -> @location(0) vec4f {\n" +
        "    let c = shade(i);\n" +
        "    return vec4f(c.rgb * c.a, c.a);\n" +
        "}\n"

    /// 多角形（動く物と static layer）の WGSL。入口は vs_main・fs_main・fs_multiply。対の GLSL は RenderShader.polyBatchVertexShaderSource と
    /// polyBatchFragmentShaderSource。頂点の属性: location 0〜1 = 頂点（位置・色。1 頂点 24 バイト）・
    /// location 2〜4 = view（viewOffset・viewScale・halfDesign。stride 0 の instance の buffer で、draw ごとに offset を替える）。
    // WhyNot: view を uniform で受けない — draw ごとの uniform は bind group を offset ごとに作るか dynamic offset が要る。
    //   stride 0 の頂点の buffer なら setVertexBuffer の offset だけで替えられる（4 バイト刻みでよい）。
    pub def polyWgsl(): String =
        "struct Frame { projection: mat4x4f };\n" +
        "@group(0) @binding(0) var<uniform> frame: Frame;\n" +
        "struct VsOut {\n" +
        "    @builtin(position) position: vec4f,\n" +
        "    @location(0) color: vec4f,\n" +
        "};\n" +
        "@vertex fn vs_main(@location(0) vertex: vec2f, @location(1) vColor: vec4f,\n" +
        "                   @location(2) viewOffset: vec2f, @location(3) viewScale: vec2f, @location(4) halfDesign: vec2f) -> VsOut {\n" +
        "    var o: VsOut;\n" +
        "    let screenPos = (vertex - viewOffset) * viewScale + halfDesign;\n" +
        "    o.position = frame.projection * vec4f(screenPos, 0.0, 1.0);\n" +
        "    o.color = vColor;\n" +
        "    return o;\n" +
        "}\n" +
        "@fragment fn fs_main(i: VsOut) -> @location(0) vec4f { return i.color; }\n" +
        "@fragment fn fs_multiply(i: VsOut) -> @location(0) vec4f {\n" +
        "    return vec4f(i.color.rgb * i.color.a, i.color.a);\n" +
        "}\n"

    /// タイルの層の WGSL。入口は vs_main・fs_main。対の GLSL は RenderShader.tileVertexShaderSource と tileFragmentShaderSource。
    /// group 0 = 射影の行列・group 1 = 絵の view と sampler。頂点の属性: location 1〜5 = タイル 1 枚（TileTable.instanceFloats の並び・40 バイト）・
    /// location 6〜9 = 層の値（layerPos・tileSize・tileScale・layerColor。stride 0 の instance の buffer）。四角は spriteWgsl と同じ 6 頂点。
    // WhyNot: 標本を discard の分岐の中で取らない — WGSL は値で分かれる分岐の中で textureSample を呼べない（式の値は GLSL と同じ）。
    pub def tileWgsl(): String =
        "struct Frame { projection: mat4x4f };\n" +
        "@group(0) @binding(0) var<uniform> frame: Frame;\n" +
        "@group(1) @binding(0) var image: texture_2d<f32>;\n" +
        "@group(1) @binding(1) var imageSampler: sampler;\n" +
        "struct VsOut {\n" +
        "    @builtin(position) position: vec4f,\n" +
        "    @location(0) texCoords: vec2f,\n" +
        "    @location(1) alpha: f32,\n" +
        "    @location(2) tint: vec3f,\n" +
        "    @location(3) layerColor: vec3f,\n" +
        "};\n" +
        "@vertex fn vs_main(@builtin(vertex_index) vi: u32,\n" +
        "                   @location(1) instPos: vec2f, @location(2) instUVO: vec2f, @location(3) instUVS: vec2f,\n" +
        "                   @location(4) instA: f32, @location(5) instTint: vec3f,\n" +
        "                   @location(6) layerPos: vec2f, @location(7) tileSize: f32, @location(8) tileScale: vec2f,\n" +
        "                   @location(9) layerColor: vec3f) -> VsOut {\n" +
        "    var quad = array<vec4f, 6>(vec4f(0.0, 1.0, 0.0, 1.0), vec4f(1.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 0.0),\n" +
        "                               vec4f(0.0, 1.0, 0.0, 1.0), vec4f(1.0, 1.0, 1.0, 1.0), vec4f(1.0, 0.0, 1.0, 0.0));\n" +
        "    let vertex = quad[vi];\n" +
        "    var o: VsOut;\n" +
        "    let screenPos = layerPos + (instPos + vertex.xy * tileSize) * tileScale;\n" +
        "    o.position = frame.projection * vec4f(screenPos, 0.0, 1.0);\n" +
        "    o.texCoords = instUVO + vertex.zw * instUVS;\n" +
        "    o.alpha = instA;\n" +
        "    o.tint = instTint;\n" +
        "    o.layerColor = layerColor;\n" +
        "    return o;\n" +
        "}\n" +
        "@fragment fn fs_main(i: VsOut) -> @location(0) vec4f {\n" +
        "    let t = textureSample(image, imageSampler, i.texCoords);\n" +
        "    let color = vec4f(i.layerColor * i.tint * t.rgb, t.a * i.alpha);\n" +
        "    if (color.a < 0.01) { discard; }\n" +
        "    return color;\n" +
        "}\n"

    /// 組めなかった面の代わりに塗る単色の WGSL（対の GLSL は RenderShader.fallbackFragmentSource と ShaderGen.vertexSource）。
    /// 入口と bind group の並びは ShaderGen.Wgsl.compile の面と同じ（group 0 = 面の値・group 1 = 射影の行列・入口は vs_main・fs_main）で、絵を読まない。
    // WhyNot: ShaderGen.Wgsl で単色の Spec を組んで代わりにしない — 代わりは ShaderGen の出口が壊れた時に塗る物で、同じ出口を通すと一緒に壊れる。
    pub def surfaceFallbackWgsl(): String =
        "struct SgValues { uRectPosX: f32, uRectPosY: f32, uRectSizeX: f32, uRectSizeY: f32, uTime: f32, uAlpha: f32 };\n" +
        "@group(0) @binding(0) var<uniform> sg: SgValues;\n" +
        "struct SgFrame { projection: mat4x4f };\n" +
        "@group(1) @binding(0) var<uniform> sgFrame: SgFrame;\n" +
        ShaderGen.Wgsl.clipFromGlSource() +
        "@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {\n" +
        "    var quad = array<vec2f, 6>(vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(0.0, 0.0), vec2f(0.0, 1.0), vec2f(1.0, 1.0), vec2f(1.0, 0.0));\n" +
        "    let screenPos = vec2f(sg.uRectPosX, sg.uRectPosY) + quad[vi] * vec2f(sg.uRectSizeX, sg.uRectSizeY);\n" +
        "    return sg_clipFromGl(sgFrame.projection * vec4f(screenPos, 0.0, 1.0));\n" +
        "}\n" +
        "@fragment fn fs_main() -> @location(0) vec4f { return vec4f(0.5, 0.2, 0.2, 1.0); }\n"

    /// 中間の texture を画面の texture へ写す WGSL（全面の三角形 1 枚）。入口は vs_present・fs_present。group 0 = 中間の texture。
    // WhyNot: textureSample で読まない — 標本と sampler を通すと filter の差が出うる。整数の座標で 1 画素ずつ写す。
    pub def presentWgsl(): String =
        "@group(0) @binding(0) var frameImage: texture_2d<f32>;\n" +
        "@vertex fn vs_present(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {\n" +
        "    var corners = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));\n" +
        "    return vec4f(corners[vi], 0.0, 1.0);\n" +
        "}\n" +
        "@fragment fn fs_present(@builtin(position) pos: vec4f) -> @location(0) vec4f {\n" +
        "    return textureLoad(frameImage, vec2i(pos.xy), 0);\n" +
        "}\n"
}
