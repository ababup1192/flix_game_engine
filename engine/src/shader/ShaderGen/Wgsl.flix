// ShaderGen.Wgsl — Spec を WebGPU の WGSL にする出口。式の組み立ては ShaderGen と同じ物を、表に wgslModeKey() を入れて呼ぶ。
// ここに置くのは文の形が GLSL と違う所（ノイズの関数・ぼかし・mip のレベルを選ぶ読み・uniform の struct・入口）だけ。

/// 2D の面と 3D の材質の WGSL。draw ごとの値は 1 つの struct（`SgValues`・`var<uniform> sg`）に、欄を全部 f32 で並べる。
/// 欄の並び（`slots`）の i 番目が uniform buffer の i × 4 バイト目（struct の大きさは WGSL が 16 の倍数に丸める。buffer はその大きさで取る）。
/// 絵の k 番目（texReads の並び）は binding 1 + 2k の texture_2d<f32>（`uTexK`）と 2 + 2k の sampler（`uTexKSampler`）。
/// GL の描き先と違い、WebGPU の描き先の texture は上の行が先なので、読む uv の上下は返さない（GLSL の uTexFlipN は無い）。
pub mod ShaderGen.Wgsl {
    use ShaderGen.{joinParts, wgslModeKey, withParamScope, texScopeFrom, mainStatements, materialStatements}

    /// draw ごとの値の 1 つ（`SgValues` の欄。並びの順が uniform buffer の Float32 の位置）。
    /// RectPos・RectSize = 2D の面の矩形（px）・Time = uTime・Alpha = 面の濃さ（uAlpha）・TexLevels(k) = k 番の絵の mip のレベルの数（3D の材質）・Param(k) = paramNames の k 番。
    pub enum UniformSlot with Eq, ToString {
        case RectPosX
        case RectPosY
        case RectSizeX
        case RectSizeY
        case Time
        case Alpha
        case TexLevels(Int32)
        case Param(Int32)
    }

    /// 2D の面の WGSL。module = 全部（入口は vs_main・fs_main）・functions = 入口を除いた物（`fn sg_surface(vUv: vec2f) -> vec4f` まで）・
    /// slots = `SgValues` の欄の並び・texReads = 絵の並び（ShaderDoc.texReads と同じ）。
    /// group 0 = `sg` と絵・group 1 = 射影の行列（`SgFrame`。頂点シェーダーの値）。
    pub type alias SurfaceWgsl = { module = String, functions = String, slots = List[UniformSlot],
                                   texReads = List[(String, ShaderDoc.FilterMode)] }

    /// Spec → 2D の面の WGSL（式は ShaderGen.compile と同じ木から作る）。
    pub def compile(spec: ShaderDoc.Spec): SurfaceWgsl =
        let reads = ShaderDoc.texReads(spec);
        let params = ShaderDoc.paramNames(spec);
        let tex = Map.insert(wgslModeKey(), 0, withParamScope(params, texScopeFrom(reads)));
        let slots = UniformSlot.RectPosX :: UniformSlot.RectPosY :: UniformSlot.RectSizeX :: UniformSlot.RectSizeY ::
                    UniformSlot.Time :: UniformSlot.Alpha :: paramSlots(params);
        let functions = joinParts(
            valuesDecl(0, slots) ::
            textureDecls(0, reads) ::
            prelude() ::
            (if (ShaderDoc.usesBlur(spec)) blurSource() else "") ::
            (if (ShaderDoc.usesDiv(spec)) divSource() else "") ::
            "fn sg_surface(vUv: vec2f) -> vec4f {\n" ::
            uniformLets(slots) ::
            (mainStatements(spec, "vUv", Map.empty(), tex) |> List.map(st -> "    " + st + "\n") |> joinParts) ::
            writeRuleReturn() ::
            "}\n" :: Nil);
        { module = functions + surfaceEntries(), functions = functions, slots = slots, texReads = reads }

    /// 2D の面の入口（vs_main・fs_main）。quad は頂点の番号から作る（GL の共有 quad と同じ 6 頂点）。
    pub def surfaceEntries(): String =
        "struct SgFrame { projection: mat4x4f };\n" +
        "@group(1) @binding(0) var<uniform> sgFrame: SgFrame;\n" +
        "struct SgVsOut {\n" +
        "    @builtin(position) position: vec4f,\n" +
        "    @location(0) uv: vec2f,\n" +
        "};\n" +
        clipFromGlSource() +
        "@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> SgVsOut {\n" +
        "    var quad = array<vec4f, 6>(vec4f(0.0, 1.0, 0.0, 1.0), vec4f(1.0, 0.0, 1.0, 0.0), vec4f(0.0, 0.0, 0.0, 0.0),\n" +
        "                               vec4f(0.0, 1.0, 0.0, 1.0), vec4f(1.0, 1.0, 1.0, 1.0), vec4f(1.0, 0.0, 1.0, 0.0));\n" +
        "    let vertex = quad[vi];\n" +
        "    let screenPos = vec2f(sg.uRectPosX, sg.uRectPosY) + vertex.xy * vec2f(sg.uRectSizeX, sg.uRectSizeY);\n" +
        "    var o: SgVsOut;\n" +
        "    o.position = sg_clipFromGl(sgFrame.projection * vec4f(screenPos, 0.0, 1.0));\n" +
        "    o.uv = vertex.zw;\n" +
        "    return o;\n" +
        "}\n" +
        "@fragment fn fs_main(i: SgVsOut) -> @location(0) vec4f { return sg_surface(i.uv); }\n"

    /// GL の射影の行列が出した clip の点を WebGPU の clip へ（z を -w..w から 0..w へ。x・y・w はそのまま）。
    /// 奥行きの値は GL の既定（glDepthRange 0..1）のウィンドウの奥行きと同じになるので、影の地図の比べ（ndc.z × 0.5 + 0.5）はそのまま使える。
    // WhyNot: 射影の行列を WebGPU 用に作り直さない — 前半と CPU の描き手が同じ行列を使い続け、影の行列も直さずに済む。
    pub def clipFromGlSource(): String =
        "fn sg_clipFromGl(p: vec4f) -> vec4f { return vec4f(p.x, p.y, (p.z + p.w) * 0.5, p.w); }\n"

    /// 面の出力の書き込みの決まり（ShaderGen.writeRuleStatement と同じ式）。
    def writeRuleReturn(): String =
        "    return vec4f(clamp(outColor.rgb, vec3f(0.0), vec3f(65504.0)), clamp(outColor.a * sg.uAlpha, 0.0, 1.0));\n"

    /// 3D の材質の WGSL の部品。declarations = `SgValues` と絵の宣言（`@group(group)`）・functions = ノイズの関数と
    /// `fn materialEval(vUv: vec2f, vWorld: vec3f, vNormal: vec3f, vColor: vec3f) -> SgMaterial`（albedo・emission・metalRough。metallicRoughness が None なら metalRough は 0）と、
    /// 絵を読む材質だけ `fn materialCutoutAlpha(vUv, vWorld, vNormal, vColor) -> f32`。
    /// cutoutAlpha = cutout の判定に使う α の式（引数の名前は vUv・vWorld・vNormal・vColor・materialEval の albedo を `albedo` で読む）。
    /// 差し込む側の約束: declarations → functions の順に置く（ノイズの関数が sg.uTime を読む）。
    pub type alias MaterialWgsl = { declarations = String, functions = String, slots = List[UniformSlot], paramNames = List[String],
                                    texReads = List[(String, ShaderDoc.FilterMode)], cutoutAlpha = String }

    /// 3D の材質の WGSL（式は ShaderGen.compile3d と同じ木から作る）。group = `sg` と絵を置く bind group の番号。
    pub def compile3d(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], metallicRoughness: Option[ShaderDoc.Shade], group: Int32): MaterialWgsl =
        let reads = ShaderDoc.materialTexReads(spec, emission, metallicRoughness);
        let params = ShaderDoc.materialParamNames(spec, emission, metallicRoughness);
        let readsTextures = not List.isEmpty(reads);
        let tex = Map.insert(wgslModeKey(), 0, withParamScope(params, texScopeFrom(reads)));
        let stmts = materialStatements(spec, emission, metallicRoughness, tex, readsTextures);
        let slots = UniformSlot.Time :: List.append(List.mapWithIndex((k, _) -> UniformSlot.TexLevels(k), reads), paramSlots(params));
        let head = uniformLets(slots) + "    let sg_uv = vUv;\n    let sg_normal = normalize(vNormal);\n";
        let indent = (lines: List[String]) -> lines |> List.map(st -> "    " + st + "\n") |> joinParts;
        let args = "vUv: vec2f, vWorld: vec3f, vNormal: vec3f, vColor: vec3f";
        let cutoutFunction = match stmts#cutout {
            case None        => ""
            case Some(lines) => "fn materialCutoutAlpha(" + args + ") -> f32 {\n" + head + indent(lines) + "}\n"
        };
        { declarations = valuesDecl(group, slots) + textureDecls(group, reads),
          functions = joinParts(
              prelude() ::
              (if (readsTextures) blurSource() + texMipSource() else "") ::
              divSource() ::
              "struct SgMaterial { albedo: vec4f, emission: vec3f, metalRough: vec2f };\n" ::
              "fn materialEval(" + args + ") -> SgMaterial {\n" ::
              head ::
              "    var albedo = vec4f(0.0);\n    var emission = vec3f(0.0);\n    var metalRough = vec2f(0.0);\n" ::
              indent(stmts#eval) ::
              "    return SgMaterial(albedo, emission, metalRough);\n" ::
              "}\n" ::
              cutoutFunction :: Nil),
          slots = slots,
          paramNames = params,
          texReads = reads,
          cutoutAlpha = if (readsTextures) "materialCutoutAlpha(vUv, vWorld, vNormal, vColor)" else "albedo.a" }

    def paramSlots(params: List[String]): List[UniformSlot] = List.mapWithIndex((k, _) -> UniformSlot.Param(k), params)

    /// 欄の WGSL の名前（GLSL の uniform と同じ名前）。
    pub def slotName(slot: UniformSlot): String = match slot {
        case UniformSlot.RectPosX     => "uRectPosX"
        case UniformSlot.RectPosY     => "uRectPosY"
        case UniformSlot.RectSizeX    => "uRectSizeX"
        case UniformSlot.RectSizeY    => "uRectSizeY"
        case UniformSlot.Time         => "uTime"
        case UniformSlot.Alpha        => "uAlpha"
        case UniformSlot.TexLevels(k) => "uTexLevels${k}"
        case UniformSlot.Param(k)     => "uParam${k}"
    }

    def valuesDecl(group: Int32, slots: List[UniformSlot]): String =
        "struct SgValues { " + (slots |> List.map(s -> slotName(s) + ": f32") |> List.join(", ")) + " };\n" +
        "@group(${group}) @binding(0) var<uniform> sg: SgValues;\n"

    def textureDecls(group: Int32, reads: List[a]): String =
        reads |> List.zipWithIndex |> List.map(ir -> {
            let (k, _) = ir;
            "@group(${group}) @binding(${1 + 2 * k}) var uTex${k}: texture_2d<f32>;\n" +
            "@group(${group}) @binding(${2 + 2 * k}) var uTex${k}Sampler: sampler;\n"
        }) |> joinParts

    /// 式が素の名前で読む値（uTime・uParamN・uTexLevelsN）を、関数の頭で sg の欄から受ける。式の字を GLSL と同じに保つため。
    def uniformLets(slots: List[UniformSlot]): String =
        slots |> List.filter(s -> match s {
            case UniformSlot.Time         => true
            case UniformSlot.TexLevels(_) => true
            case UniformSlot.Param(_)     => true
            case _                        => false
        }) |> List.map(s -> "    let ${slotName(s)} = sg.${slotName(s)};\n") |> joinParts

    /// ノイズの関数（ShaderGen.preludeSource と 1 行ずつ同じ式）。sg.uTime を読む。
    // WhyNot: % で割った余りを取らない — WGSL の % は 0 の向きに切り、負の値で GLSL の mod と答えが違う。sg_mod は GLSL の mod の式。
    pub def prelude(): String = joinParts(
        "fn sg_mod(x: f32, y: f32) -> f32 { return x - y * floor(x / y); }\n" ::
        "fn sg_mod2(x: vec2f, y: vec2f) -> vec2f { return x - y * floor(x / y); }\n" ::
        "fn sg_hash1(p: vec2f, seed: f32) -> f32 {\n" ::
        "    return fract(sin(dot(p, vec2f(127.1, 311.7)) + seed * 0.017) * 43758.5453123);\n" ::
        "}\n" ::
        "fn sg_hash2(p: vec2f, seed: f32) -> vec2f {\n" ::
        "    return vec2f(sg_hash1(p, seed), sg_hash1(p + vec2f(19.19, 7.31), seed));\n" ::
        "}\n" ::
        "fn sg_worleyF1F2(p: vec2f, seed: f32) -> vec2f {\n" ::
        "    let ip = floor(p);\n" ::
        "    let fp = fract(p);\n" ::
        "    var f1 = 8.0; var f2 = 8.0;\n" ::
        "    for (var j = -1; j <= 1; j++) {\n" ::
        "        for (var i = -1; i <= 1; i++) {\n" ::
        "            let g = vec2f(f32(i), f32(j));\n" ::
        "            let o = sg_hash2(ip + g, seed);\n" ::
        "            let r = g + o - fp;\n" ::
        "            let d = length(r);\n" ::
        "            if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }\n" ::
        "        }\n" ::
        "    }\n" ::
        "    return vec2f(f1, f2);\n" ::
        "}\n" ::
        "fn sg_valueNoise(p: vec2f, seed: f32) -> f32 {\n" ::
        "    let ip = floor(p);\n" ::
        "    let fp = fract(p);\n" ::
        "    let w = fp * fp * (3.0 - 2.0 * fp);\n" ::
        "    let a = sg_hash1(ip + vec2f(0.0, 0.0), seed);\n" ::
        "    let b = sg_hash1(ip + vec2f(1.0, 0.0), seed);\n" ::
        "    let c = sg_hash1(ip + vec2f(0.0, 1.0), seed);\n" ::
        "    let d = sg_hash1(ip + vec2f(1.0, 1.0), seed);\n" ::
        "    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);\n" ::
        "}\n" ::
        "fn sg_scales(uv: vec2f, scale: f32, stagger: f32) -> f32 {\n" ::
        "    let p = uv * scale;\n" ::
        "    let ip = floor(p);\n" ::
        "    var best = 8.0;\n" ::
        "    for (var j = -1; j <= 1; j++) {\n" ::
        "        for (var i = -1; i <= 1; i++) {\n" ::
        "            let cell = ip + vec2f(f32(i), f32(j));\n" ::
        "            let center = cell + vec2f(0.5 + sg_mod(cell.y, 2.0) * stagger, 0.5);\n" ::
        "            best = min(best, length(p - center));\n" ::
        "        }\n" ::
        "    }\n" ::
        "    return clamp(best, 0.0, 1.0);\n" ::
        "}\n" ::
        "fn sg_glints(uv: vec2f, scale: f32, rate: f32, density: f32, seed: f32) -> f32 {\n" ::
        "    let p = uv * scale;\n" ::
        "    let ip = floor(p);\n" ::
        "    let fp = fract(p);\n" ::
        "    let on = step(1.0 - density, sg_hash1(ip, seed));\n" ::
        "    let phase = sg_hash1(ip, seed + 7.0) * 6.2831853;\n" ::
        "    let tw = max(0.0, sin(sg.uTime * rate + phase));\n" ::
        "    let dash = (1.0 - smoothstep(0.04, 0.10, abs(fp.y - 0.5))) *\n" ::
        "               (1.0 - smoothstep(0.28, 0.46, abs(fp.x - 0.5)));\n" ::
        "    return on * tw * dash;\n" ::
        "}\n" ::
        "fn sg_ripples(uv: vec2f, freq: f32, amp: f32, speed: f32, seed: f32) -> f32 {\n" ::
        "    let wob = sin(uv.x * 6.2831853 * freq * 0.5 + seed) * amp\n" ::
        "            + sin(uv.x * 6.2831853 * freq * 1.3 + seed * 2.7) * amp * 0.4;\n" ::
        "    let band = uv.y * freq + wob + sg.uTime * speed;\n" ::
        "    return 0.5 + 0.5 * sin(band * 6.2831853);\n" ::
        "}\n" ::
        "fn sg_sparkle(uv: vec2f, scale: f32, rate: f32, density: f32, seed: f32) -> f32 {\n" ::
        "    let p = uv * scale;\n" ::
        "    let ip = floor(p);\n" ::
        "    let fp = fract(p);\n" ::
        "    let t = sg.uTime * rate + sg_hash1(ip, seed + 3.0) * 6.2831853;\n" ::
        "    let cyc = floor(t / 6.2831853);\n" ::
        "    let on = step(1.0 - density, sg_hash1(ip + cyc, seed));\n" ::
        "    let tw = pow(max(0.0, sin(t)), 12.0);\n" ::
        "    let pos = 0.15 + 0.7 * sg_hash2(ip + cyc, seed + 11.0);\n" ::
        "    let e = fp - pos;\n" ::
        "    let d = abs(e.x) + abs(e.y);\n" ::
        "    let point = 1.0 - smoothstep(0.04, 0.26, d);\n" ::
        "    return on * tw * point;\n" ::
        "}\n" ::
        "fn sg_fbm(p: vec2f, octaves: i32, seed: f32) -> f32 {\n" ::
        "    var sum = 0.0; var amp = 0.5; var freq = 1.0;\n" ::
        "    for (var i = 0; i < octaves; i++) {\n" ::
        "        sum += amp * sg_valueNoise(p * freq, seed + f32(i) * 13.0);\n" ::
        "        freq *= 2.0; amp *= 0.5;\n" ::
        "    }\n" ::
        "    return sum;\n" ::
        "}\n" ::
        "fn sg_valueNoiseTile(p: vec2f, period: vec2f, seed: f32) -> f32 {\n" ::
        "    let ip = floor(p);\n" ::
        "    let fp = fract(p);\n" ::
        "    let w = fp * fp * (3.0 - 2.0 * fp);\n" ::
        "    let a = sg_hash1(sg_mod2(ip + vec2f(0.0, 0.0), period), seed);\n" ::
        "    let b = sg_hash1(sg_mod2(ip + vec2f(1.0, 0.0), period), seed);\n" ::
        "    let c = sg_hash1(sg_mod2(ip + vec2f(0.0, 1.0), period), seed);\n" ::
        "    let d = sg_hash1(sg_mod2(ip + vec2f(1.0, 1.0), period), seed);\n" ::
        "    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);\n" ::
        "}\n" ::
        "fn sg_fbmTile(p: vec2f, period: vec2f, octaves: i32, seed: f32) -> f32 {\n" ::
        "    var sum = 0.0; var amp = 0.5; var freq = 1.0;\n" ::
        "    for (var i = 0; i < octaves; i++) {\n" ::
        "        sum += amp * sg_valueNoiseTile(p * freq, period * freq, seed + f32(i) * 13.0);\n" ::
        "        freq *= 2.0; amp *= 0.5;\n" ::
        "    }\n" ::
        "    return sum;\n" ::
        "}\n" ::
        "fn sg_swirl(uv: vec2f, cx: f32, cy: f32, strength: f32, rate: f32) -> vec2f {\n" ::
        "    let c = vec2f(cx, cy);\n" ::
        "    let p = uv - c;\n" ::
        "    let r = length(p);\n" ::
        "    let a = strength / (r + 0.08) + rate * sg.uTime;\n" ::
        "    let s = sin(a); let co = cos(a);\n" ::
        "    return c + mat2x2f(co, -s, s, co) * p;\n" ::
        "}\n" ::
        "fn sg_cospal(t: f32, a: vec3f, b: vec3f, c: vec3f, d: vec3f) -> vec3f {\n" ::
        "    return clamp(a + b * cos(6.2831853 * (c * t + d)), vec3f(0.0), vec3f(1.0));\n" ::
        "}\n" ::
        "fn sg_rotate(uv: vec2f, cx: f32, cy: f32, turns: f32, rate: f32) -> vec2f {\n" ::
        "    let c = vec2f(cx, cy);\n" ::
        "    let p = uv - c;\n" ::
        "    let a = 6.2831853 * (turns + rate * sg.uTime);\n" ::
        "    let s = sin(a); let co = cos(a);\n" ::
        "    return c + mat2x2f(co, -s, s, co) * p;\n" ::
        "}\n" :: Nil)

    /// ぼかし（ShaderGen.blurSource と同じ点の並び）。2D の面も 3D の材質も mip のレベル 0 を読む。
    def blurSource(): String =
        "fn sg_blur(tex: texture_2d<f32>, smp: sampler, uv: vec2f, radius: vec2f, taps: i32) -> vec4f {\n" +
        "    if (radius.x == 0.0 && radius.y == 0.0) { return textureSampleLevel(tex, smp, uv, 0.0); }\n" +
        "    var acc = vec4f(0.0);\n" +
        "    for (var i = 0; i < 64; i++) {\n" +
        "        if (i >= taps) { break; }\n" +
        "        let r = sqrt((f32(i) + 0.5) / f32(taps));\n" +
        "        let a = f32(i) * 2.39996323;\n" +
        "        let p = uv + vec2f(cos(a), sin(a)) * r * radius;\n" +
        "        acc += textureSampleLevel(tex, smp, p, 0.0);\n" +
        "    }\n" +
        "    return acc / f32(taps);\n" +
        "}\n"

    /// 3D の材質の mip のレベルを選ぶ読み（ShaderGen.texMipSource と同じ式。上下は返さない）。
    // WhyNot: 三項の代わりの select の偽の側の log2 を避けない — select は両方を計算するが、rho が 1 以下の時の log2 の値は捨てられる。
    pub def texMipSource(): String =
        "fn sg_texMip(tex: texture_2d<f32>, smp: sampler, levels: f32, c: vec2f) -> vec4f {\n" +
        "    var dx = dpdx(c);\n" +
        "    var dy = dpdy(c);\n" +
        "    dx -= floor(dx + 0.5);\n" +
        "    dy -= floor(dy + 0.5);\n" +
        "    let size = vec2f(textureDimensions(tex, 0));\n" +
        "    let rho = max(length(dx * size), length(dy * size));\n" +
        "    let lod = select(min(levels - 1.0, log2(rho)), 0.0, levels <= 1.0 || rho <= 1.0);\n" +
        "    return textureSampleLevel(tex, smp, c, lod);\n" +
        "}\n"

    /// 割り算（ShaderGen.divSource と同じ）。
    def divSource(): String =
        "fn sg_div(a: f32, b: f32) -> f32 {\n" +
        "    return select(a / b, 0.0, b == 0.0);\n" +
        "}\n"
}
