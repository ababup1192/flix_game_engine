// ShaderGen — Spec を GLSL の fragment シェーダー文字列へ変換する codegen。
// 各部品が自分の GLSL 片（式）を返し、compile がそれらを 1 枚の main() に繋ぐ。
// 出力は決定論（同じ Spec なら常に同じ文字列）なので、テストは絵でなくこの文字列を
// スナップショットで釘打ちできる（codegen を変えたら差分で検出＝リグレッション網）。
// 任意 GLSL は書けない — 語彙の合成だけが GLSL になる。ノイズ（hash2/worley/fbm）は
// prelude に固定テンプレとして持ち、Spec スナップから分離する（prelude 改訂は 1 か所だけ動く）。
// 座標変換（Scaled/Warp）は「inner が読む uv の式」を差し替えることで表す。

pub mod ShaderGen {
    /// vertex シェーダー（面 quad 1 枚・uv を渡すだけ）。Spec に依存しない固定ソース。
    /// vertex.xy = 0..1 の quad ローカル座標を rect（px）へ写し、vertex.zw を uv として渡す。
    pub def vertexSource(): String =
        "#version 330 core\n" +
        "layout (location = 0) in vec4 vertex;\n" +
        "out vec2 vUv;\n" +
        "uniform mat4 projection;\n" +
        "uniform vec2 uRectPos;\n" +
        "uniform vec2 uRectSize;\n" +
        "void main() {\n" +
        "    vec2 screenPos = uRectPos + vertex.xy * uRectSize;\n" +
        "    gl_Position = projection * vec4(screenPos, 0.0, 1.0);\n" +
        "    vUv = vertex.zw;\n" +
        "}\n"

    /// ノイズ関数の固定テンプレ（hash2 / worley / fbm）。Spec に依存しないので 1 度だけ pin し、
    /// Spec スナップショットからは除外する（テストで preludeSource を別途スナップする）。
    pub def preludeSource(): String = joinParts(
        "float sg_hash1(vec2 p, float seed) {\n" ::
        "    return fract(sin(dot(p, vec2(127.1, 311.7)) + seed * 0.017) * 43758.5453123);\n" ::
        "}\n" ::
        "vec2 sg_hash2(vec2 p, float seed) {\n" ::
        "    return vec2(sg_hash1(p, seed), sg_hash1(p + vec2(19.19, 7.31), seed));\n" ::
        "}\n" ::
        // Worley: 近傍 3x3 セルの特徴点までの距離から F1(最近) と F2(次近) を求める。
        "vec2 sg_worleyF1F2(vec2 p, float seed) {\n" ::
        "    vec2 ip = floor(p);\n" ::
        "    vec2 fp = fract(p);\n" ::
        "    float f1 = 8.0; float f2 = 8.0;\n" ::
        "    for (int j = -1; j <= 1; j++) {\n" ::
        "        for (int i = -1; i <= 1; i++) {\n" ::
        "            vec2 g = vec2(float(i), float(j));\n" ::
        "            vec2 o = sg_hash2(ip + g, seed);\n" ::
        "            vec2 r = g + o - fp;\n" ::
        "            float d = length(r);\n" ::
        "            if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }\n" ::
        "        }\n" ::
        "    }\n" ::
        "    return vec2(f1, f2);\n" ::
        "}\n" ::
        // value noise（格子 4 点の hash を双一次補間）と、その多重和 fbm。
        "float sg_valueNoise(vec2 p, float seed) {\n" ::
        "    vec2 ip = floor(p);\n" ::
        "    vec2 fp = fract(p);\n" ::
        "    vec2 w = fp * fp * (3.0 - 2.0 * fp);\n" ::
        "    float a = sg_hash1(ip + vec2(0.0, 0.0), seed);\n" ::
        "    float b = sg_hash1(ip + vec2(1.0, 0.0), seed);\n" ::
        "    float c = sg_hash1(ip + vec2(0.0, 1.0), seed);\n" ::
        "    float d = sg_hash1(ip + vec2(1.0, 1.0), seed);\n" ::
        "    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);\n" ::
        "}\n" ::
        // 行ごとに stagger だけずらした格子点への最近距離（0→1）。
        // 近傍 3x3 の格子点を見て最短を取るので、隙間なくタイル状に繋がる（孤立した円にならない）。
        "float sg_scales(vec2 uv, float scale, float stagger) {\n" ::
        "    vec2 p = uv * scale;\n" ::
        "    vec2 ip = floor(p);\n" ::
        "    float best = 8.0;\n" ::
        "    for (int j = -1; j <= 1; j++) {\n" ::
        "        for (int i = -1; i <= 1; i++) {\n" ::
        "            vec2 cell = ip + vec2(float(i), float(j));\n" ::
        "            vec2 center = cell + vec2(0.5 + mod(cell.y, 2.0) * stagger, 0.5);\n" ::
        "            best = min(best, length(p - center));\n" ::
        "        }\n" ::
        "    }\n" ::
        "    return clamp(best, 0.0, 1.0);\n" ::
        "}\n" ::
        // まばらに明滅する短い横線のきらめき。セルごとに density で点灯・位相ずれで sin 明滅。
        "float sg_glints(vec2 uv, float scale, float rate, float density, float seed) {\n" ::
        "    vec2 p = uv * scale;\n" ::
        "    vec2 ip = floor(p);\n" ::
        "    vec2 fp = fract(p);\n" ::
        "    float on = step(1.0 - density, sg_hash1(ip, seed));\n" ::
        "    float phase = sg_hash1(ip, seed + 7.0) * 6.2831853;\n" ::
        "    float tw = max(0.0, sin(uTime * rate + phase));\n" ::
        "    float dash = (1.0 - smoothstep(0.04, 0.10, abs(fp.y - 0.5))) *\n" ::
        "                 (1.0 - smoothstep(0.28, 0.46, abs(fp.x - 0.5)));\n" ::
        "    return on * tw * dash;\n" ::
        "}\n" ::
        // 横に波打つ縞: y にサインのゆらぎ(wob)を足した band を、時間で縦に流す。出力 0..1。
        "float sg_ripples(vec2 uv, float freq, float amp, float speed, float seed) {\n" ::
        "    float wob = sin(uv.x * 6.2831853 * freq * 0.5 + seed) * amp\n" ::
        "              + sin(uv.x * 6.2831853 * freq * 1.3 + seed * 2.7) * amp * 0.4;\n" ::
        "    float band = uv.y * freq + wob + uTime * speed;\n" ::
        "    return 0.5 + 0.5 * sin(band * 6.2831853);\n" ::
        "}\n" ::
        // 点滅の回 cyc ごとに「光るセル(on)」と「セル内の位置(pos)」を選び直すので
        // 同じ場所で繰り返さず毎回ランダムな所に出る。pow を大きくして一瞬で光り一瞬で消える鋭いパルス。
        "float sg_sparkle(vec2 uv, float scale, float rate, float density, float seed) {\n" ::
        "    vec2 p = uv * scale;\n" ::
        "    vec2 ip = floor(p);\n" ::
        "    vec2 fp = fract(p);\n" ::
        "    float t = uTime * rate + sg_hash1(ip, seed + 3.0) * 6.2831853;\n" ::
        "    float cyc = floor(t / 6.2831853);\n" ::
        "    float on = step(1.0 - density, sg_hash1(ip + cyc, seed));\n" ::
        "    float tw = pow(max(0.0, sin(t)), 12.0);\n" ::
        "    vec2 pos = 0.15 + 0.7 * sg_hash2(ip + cyc, seed + 11.0);\n" ::
        "    vec2 e = fp - pos;\n" ::
        "    float d = abs(e.x) + abs(e.y);\n" ::
        "    float point = 1.0 - smoothstep(0.04, 0.26, d);\n" ::
        "    return on * tw * point;\n" ::
        "}\n" ::
        "float sg_fbm(vec2 p, int octaves, float seed) {\n" ::
        "    float sum = 0.0; float amp = 0.5; float freq = 1.0;\n" ::
        "    for (int i = 0; i < octaves; i++) {\n" ::
        "        sum += amp * sg_valueNoise(p * freq, seed + float(i) * 13.0);\n" ::
        "        freq *= 2.0; amp *= 0.5;\n" ::
        "    }\n" ::
        "    return sum;\n" ::
        "}\n" ::
        // 周期つき value noise: 格子点を period で折り返してから hash する（period マスで模様が閉じる）。
        "float sg_valueNoiseTile(vec2 p, vec2 period, float seed) {\n" ::
        "    vec2 ip = floor(p);\n" ::
        "    vec2 fp = fract(p);\n" ::
        "    vec2 w = fp * fp * (3.0 - 2.0 * fp);\n" ::
        "    float a = sg_hash1(mod(ip + vec2(0.0, 0.0), period), seed);\n" ::
        "    float b = sg_hash1(mod(ip + vec2(1.0, 0.0), period), seed);\n" ::
        "    float c = sg_hash1(mod(ip + vec2(0.0, 1.0), period), seed);\n" ::
        "    float d = sg_hash1(mod(ip + vec2(1.0, 1.0), period), seed);\n" ::
        "    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);\n" ::
        "}\n" ::
        // 周期つき fbm。オクターブごとに period も freq 倍する（各層とも同じ位置で折り返す）。
        "float sg_fbmTile(vec2 p, vec2 period, int octaves, float seed) {\n" ::
        "    float sum = 0.0; float amp = 0.5; float freq = 1.0;\n" ::
        "    for (int i = 0; i < octaves; i++) {\n" ::
        "        sum += amp * sg_valueNoiseTile(p * freq, period * freq, seed + float(i) * 13.0);\n" ::
        "        freq *= 2.0; amp *= 0.5;\n" ::
        "    }\n" ::
        "    return sum;\n" ::
        "}\n" ::
        // 中心 (cx,cy) のまわりに座標を回す（中心ほど速い差動回転＋rate*uTime の全体回転）。
        "vec2 sg_swirl(vec2 uv, float cx, float cy, float strength, float rate) {\n" ::
        "    vec2 c = vec2(cx, cy);\n" ::
        "    vec2 p = uv - c;\n" ::
        "    float r = length(p);\n" ::
        "    float a = strength / (r + 0.08) + rate * uTime;\n" ::
        "    float s = sin(a); float co = cos(a);\n" ::
        "    return c + mat2(co, -s, s, co) * p;\n" ::
        "}\n" ::
        // コサインパレット col = a + b*cos(2π(c*t + d))（Inigo Quilez 方式）。
        "vec3 sg_cospal(float t, vec3 a, vec3 b, vec3 c, vec3 d) {\n" ::
        "    return clamp(a + b * cos(6.2831853 * (c * t + d)), 0.0, 1.0);\n" ::
        "}\n" ::
        // 中心 (cx,cy) まわりに座標を均一に回す（turns + rate*uTime 周）。
        "vec2 sg_rotate(vec2 uv, float cx, float cy, float turns, float rate) {\n" ::
        "    vec2 c = vec2(cx, cy);\n" ::
        "    vec2 p = uv - c;\n" ::
        "    float a = 6.2831853 * (turns + rate * uTime);\n" ::
        "    float s = sin(a); float co = cos(a);\n" ::
        "    return c + mat2(co, -s, s, co) * p;\n" ::
        "}\n" :: Nil)

    /// 断片を 1 回で 1 本にする。`+` で継ぎ足すと 1 個ごとに全体を作り直すので、
    /// 断片の数が増えるほどコピーが二乗に膨らむ。
    def joinParts(parts: List[String]): String =
        region rc {
            let sb = StringBuilder.empty(rc);
            List.forEach(s -> StringBuilder.append(s, sb), parts);
            StringBuilder.toString(sb)
        }

    /// Spec 2 つの構造比較（program キャッシュの正当性の中核）。真 ⇒ compile は純関数なので GLSL も等しい。
    /// テクスチャの名前は比べず、texNames の正典順での番号を比べる。決まりと WhyNot は ShaderGen.Internal.SpecKey.eqSpec。
    pub def eqSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool = ShaderGen.Internal.SpecKey.eqSpec(a, b)

    /// 2 つの材質（spec・自分で光る色 emission・metallic と roughness の場 metallicRoughness）が同じ GLSL を生むか（render_gl の材質の program キャッシュの鍵）。
    pub def eqMaterial(specA: ShaderDoc.Spec, emissionA: Option[ShaderDoc.Shade], metallicRoughnessA: Option[ShaderDoc.Shade],
                       specB: ShaderDoc.Spec, emissionB: Option[ShaderDoc.Shade], metallicRoughnessB: Option[ShaderDoc.Shade]): Bool =
        ShaderGen.Internal.SpecKey.eqMaterial(specA, emissionA, metallicRoughnessA, specB, emissionB, metallicRoughnessB)

    /// a と b が同じ物か（中身ではなく参照）。
    pub def isSameSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool = ShaderGen.Internal.SpecKey.isSameSpec(a, b)

    /// 2 つの色（emission か metallicRoughness）が同じ物か（両方無いか、参照が同じ）。
    pub def isSameEmission(a: Option[ShaderDoc.Shade], b: Option[ShaderDoc.Shade]): Bool = ShaderGen.Internal.SpecKey.isSameEmission(a, b)

    /// 材質（spec・emission・metallicRoughness）の中身の鍵。eqMaterial が真の 2 つは必ず同じ値になる（違う中身が同じ値になることはありうるので、
    /// 引き当てた後は eqMaterial で確かめる）。
    pub def hashMaterial(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], metallicRoughness: Option[ShaderDoc.Shade]): Int64 =
        ShaderGen.Internal.SpecKey.hashMaterial(spec, emission, metallicRoughness)


    /// Spec → fragment シェーダー全体（prelude + main）。uTime uniform を前提に持つ。
    /// Tex を使う Spec だけ sampler uniform（uTexN / uTexFlipN）が増える — 使わない Spec の
    /// 出力は 1 文字も変えない（headless のスナップショットを無傷に保つ）。
    pub def compile(spec: ShaderDoc.Spec): String =
        // texNames は木を全走査するので、宣言と番号表で使い回す（毎回呼ぶと走査が重複する）。
        let reads = ShaderDoc.texReads(spec);
        let params = ShaderDoc.paramNames(spec);
        let tex = withParamScope(params, texScopeFrom(reads));
        joinParts(
            "#version 330 core\n" ::
            "in vec2 vUv;\n" ::
            "out vec4 outColor;\n" ::
            "uniform float uTime;\n" ::
            "uniform float uAlpha;\n" ::
            texUniformDecls(reads) ::
            paramUniformDecls(params) ::
            preludeSource() ::
            (if (ShaderDoc.usesBlur(spec)) blurSource() else "") ::
            (if (ShaderDoc.usesDiv(spec)) divSource() else "") ::
            "void main() {\n" ::
            (mainStatements(spec, "vUv", Map.empty(), tex) |> List.map(st -> "    " + st + "\n") |> joinParts) ::
            writeRuleStatement() ::
            "}\n" :: Nil)

    /// 面の出力の書き込みの決まり（CPU の SoftRaster も同じ式で切る）: rgb は [0, 65504]（half の最大）・α は uAlpha を掛けて [0, 1]。
    /// Rgba8Unorm の描き先は GL が書く前に 0..1 に切るので、8bit の絵は変わらない。
    /// WhyNot: α を 1 より上に通さない — Rgba16Float の描き先で Normal の (1 − α) が負になり、下の絵を引いてしまう。
    def writeRuleStatement(): String =
        "    outColor = vec4(clamp(outColor.rgb, 0.0, 65504.0), clamp(outColor.a * uAlpha, 0.0, 1.0));\n"

    // ── 3D の材質（Scene3d.Material3d）──

    /// 3D の材質を GLSL にした部品。render_gl の 3D の frag が、自分の光の計算の前に差し込む。
    /// uniforms  = `uniform float uTime;`・tex の `uniform sampler2D uTexN; uniform float uTexFlipN;`（N は texReads の並び）・
    ///             Param の `uniform float uParamN;`（N は paramNames の並び）。
    /// functions = ノイズの関数と `void materialEval(out vec4 albedo, out vec3 emission)` の定義。
    ///             albedo = 光を当てる前の色と α（Out の Fill）・emission = 自分で光る色（無ければ 0）。
    ///             metallicRoughness が Some の材質だけ、引数がもう 1 つ増える: `out vec2 metalRough`（x = metallic・y = roughness・0..1 に丸めた値）。
    /// paramNames = uParamN に渡す値の名前の並び（ShaderDoc.materialParamNames と同じ）。
    /// texReads = uTexN に貼る (テクスチャ名, 補間) の並び（ShaderDoc.materialTexReads と同じ）。
    /// 差し込む側の約束: `in vec3 vWorld;`（画素の world の点）・`in vec3 vNormal;`（外向きの法線・長さは問わない）・
    /// `in vec3 vColor;`（頂点の色）・`vUv`（vec2。uv の無い形は (0, 0) の const）を functions より前に宣言し、
    /// uniforms → functions の順に置く（ノイズの関数が uTime を読む）。
    /// cutoutAlpha = cutout の判定に使う α の GLSL 式（絵を読む材質は段 0 で読み直す materialCutoutAlpha()・ほかは albedo.a）。
    /// 絵を読む材質の uniforms には `uniform float uTexLevelsN;`（N 番の絵の段の数。1 なら段 0 だけを読む）も入る。
    pub type alias MaterialGlsl = { uniforms = String, functions = String, paramNames = List[String],
                                    texReads = List[(String, ShaderDoc.FilterMode)], cutoutAlpha = String }

    /// 3D の材質（spec・自分で光る色 emission・metallic と roughness を RGB の r と g に入れた色 metallicRoughness）の GLSL の部品。World / Normal / VertexColor は varying の vWorld / vNormal / vColor を、
    /// uv は vUv を読む。tex / blur は uTexN を読む（unit の数に収めるのは呼ぶ側 — ShaderDoc.limitMaterialTexReads）。
    /// tex は読む座標の画面の微分から段を選んで読む（sg_texMip。式は Mip.lodOf と同じ）。blur と cutout の α は段 0 で読む。
    /// emission と metallicRoughness の場は spec の bindings を Ref で読める。cycleRate は emission の色には掛かり、metallicRoughness には掛からない。
    /// materialOcclusion = metallicRoughness の色の b が材質の AO（Scene3d.hasMaterialOcclusion）で、真なら materialEval の metalRough は vec3（z = AO）・
    /// 偽なら vec2（b は読まない。metalRoughWidth）。metallicRoughness が None なら materialOcclusion は見ない。
    pub def compile3d(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], metallicRoughness: Option[ShaderDoc.Shade], materialOcclusion: Bool): MaterialGlsl =
        let reads = ShaderDoc.materialTexReads(spec, emission, metallicRoughness);
        let params = ShaderDoc.materialParamNames(spec, emission, metallicRoughness);
        let readsTextures = not List.isEmpty(reads);
        let width = metalRoughWidth(materialOcclusion);
        let stmts = materialStatements(spec, emission, metallicRoughness, width, withParamScope(params, texScopeFrom(reads)), readsTextures);
        let indent = (lines: List[String]) -> lines |> List.map(st -> "    " + st + "\n") |> joinParts;
        let cutoutFunction = match stmts#cutout {
            case None => ""
            case Some(lines) =>
                joinParts(
                    "float materialCutoutAlpha() {\n" ::
                    "    vec2 sg_uv = vUv;\n" ::
                    "    vec3 sg_normal = normalize(vNormal);\n" ::
                    indent(lines) ::
                    "}\n" :: Nil)
        };
        { uniforms = "uniform float uTime;\n" + texUniformDecls(reads) + texLevelDecls(reads) + paramUniformDecls(params),
          functions = joinParts(
              preludeSource() ::
              (if (readsTextures) blurSourceWith(e -> "textureLod(tex, " + e + ", 0.0)") + texMipSource() else "") ::
              divSource() ::
              "void materialEval(out vec4 albedo, out vec3 emission" + (if (Option.nonEmpty(metallicRoughness)) ", out vec${width} metalRough" else "") + ") {\n" ::
              "    vec2 sg_uv = vUv;\n" ::
              "    vec3 sg_normal = normalize(vNormal);\n" ::
              indent(stmts#eval) ::
              "}\n" ::
              cutoutFunction :: Nil),
          paramNames = params,
          texReads = reads,
          cutoutAlpha = if (readsTextures) "materialCutoutAlpha()" else "albedo.a" }

    /// 材質の文: eval = albedo・emission・metalRough へ代入する文（binding の宣言から）・cutout = 絵を読む材質だけ、mip のレベル 0 で読み直した α を返す文。
    /// tex = 絵と Param の番号の表（wgslModeKey() があれば WGSL の字）・readsTextures = 材質が絵を読むか。
    /// width = metalRough の成分の数（metalRoughWidth）。
    def materialStatements(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], metallicRoughness: Option[ShaderDoc.Shade], width: Int32,
                           tex: Map[String, Int32], readsTextures: Bool): { eval = List[String], cutout = Option[List[String]] } =
        let mipTex = Map.insert(mipModeKey(), 0, tex);
        let baseEnv = Map#{ worldKey() => "vWorld", normalKey() => "sg_normal", colorKey() => "vColor" };
        let uv = "sg_uv";
        let env = bindingEnv(spec#bindings, baseEnv);
        let albedo = match spec#out {
            case ShaderDoc.Out.Fill(f) =>
                "albedo = vec4(" + shadeExpr(spec#cycleRate, f#shade, uv, env, mipTex) + ", " + fieldExpr(f#alpha, uv, env, mipTex) + ");"
        };
        let glowStmt = match emission {
            case Some(shade) => "emission = " + shadeExpr(spec#cycleRate, shade, uv, env, mipTex) + ";"
            case None        => "emission = vec3(0.0, 0.0, 0.0);"
        };
        let metalStmts = match metallicRoughness {
            case Some(shade) =>
                let swizzle = if (width == 3) ").xyz" else ").xy";
                ("metalRough = " + clampUnitN(tex, width, "(" + shadeExpr(0.0, shade, uv, env, mipTex) + swizzle) + ";") :: Nil
            case None        => Nil
        };
        let eval = finishReads(vec4BindingHead(tex), List.append(List.reverse(bindingStatements(spec#bindings, uv, baseEnv, mipTex)), albedo :: glowStmt :: metalStmts));
        let cutout = if (not readsTextures) None else {
            let level0 = Map.insert(level0ModeKey(), 0, tex);
            let alphaExpr = match spec#out {
                case ShaderDoc.Out.Fill(f) => "return " + fieldExpr(f#alpha, uv, env, level0) + ";"
            };
            Some(finishReads(vec4BindingHead(tex), List.append(List.reverse(bindingStatements(spec#bindings, uv, baseEnv, level0)), alphaExpr :: Nil)))
        };
        { eval = eval, cutout = cutout }

    /// materialEval の metalRough の成分の数（materialOcclusion なら 3 = metallic・roughness・AO・ほかは 2）。GLSL・WGSL の部品と、それを呼ぶ frag が同じ数を使う。
    pub def metalRoughWidth(materialOcclusion: Bool): Int32 = if (materialOcclusion) 3 else 2

    /// width 成分の式 e を 0..1 に丸める式（WGSL の clamp は端も同じ幅の vec で渡す）。
    def clampUnitN(tex: Map[String, Int32], width: Int32, e: String): String =
        if (isWgsl(tex)) "clamp(" + e + ", vec${width}(0.0), vec${width}(1.0))" else "clamp(" + e + ", 0.0, 1.0)"

    /// fieldExpr の env で World / Normal の変数名を引く鍵（'@' を含む binding の名前は sg_b_ の変数名として GLSL が通さないので、
    /// 動く Spec の binding とは重ならない）。
    def worldKey(): String = "@world"

    def normalKey(): String = "@normal"

    def colorKey(): String = "@color"

    /// ぼかし（TexBlur）の標本。点の並びは ShaderEval.Internal.blurTex と同じ。ぼかしを使う Spec にだけ足す
    /// （使わない Spec の出力を 1 文字も変えない）。半径が 0 なら 1 点だけ読む（ShaderEval.Internal.blurTex と同じ分岐）。
    /// WhyNot: 分岐の中の texture() を textureLod にしない — ターゲットにも面のテクスチャにも mipmap が無く、微分は答えに効かない。
    /// mipmap を入れる時は textureLod(…, 0.0) に替える。
    def blurSource(): String = blurSourceWith(e -> "texture(tex, " + e + ")")

    /// blurSource の、1 点を読む式を read で組む形（3D の材質は段 0 を読む textureLod(…, 0.0)）。
    def blurSourceWith(read: String -> String): String =
        "vec4 sg_blur(sampler2D tex, float flip, vec2 uv, vec2 radius, int taps) {\n" +
        "    if (radius.x == 0.0 && radius.y == 0.0) return " + read("vec2(uv.x, mix(uv.y, 1.0 - uv.y, flip))") + ";\n" +
        "    vec4 acc = vec4(0.0);\n" +
        "    for (int i = 0; i < 64; i++) {\n" +
        "        if (i >= taps) break;\n" +
        "        float r = sqrt((float(i) + 0.5) / float(taps));\n" +
        "        float a = float(i) * 2.39996323;\n" +
        "        vec2 p = uv + vec2(cos(a), sin(a)) * r * radius;\n" +
        "        acc += " + read("vec2(p.x, mix(p.y, 1.0 - p.y, flip))") + ";\n" +
        "    }\n" +
        "    return acc / float(taps);\n" +
        "}\n"

    /// 3D の材質の段つきの読み。c = 読む座標（Spec の変換の後・REPEAT で 0..1 に戻す前）・levels = 段の数（1 なら段 0）。
    /// lod の式は Mip.lodOf と同じ（微分は dFdx / dFdy・各成分から floor(d + 0.5) を引く）。
    // WhyNot: texture() の自動の段選びに任せない — 選び方がドライバ任せで、REPEAT の継ぎ目で段が跳ね、CPU の描き出しとそろわない。
    pub def texMipSource(): String =
        "vec4 sg_texMip(sampler2D tex, float flip, float levels, vec2 c) {\n" +
        "    vec2 dx = dFdx(c);\n" +
        "    vec2 dy = dFdy(c);\n" +
        "    dx -= floor(dx + 0.5);\n" +
        "    dy -= floor(dy + 0.5);\n" +
        "    vec2 size = vec2(textureSize(tex, 0));\n" +
        "    float rho = max(length(dx * size), length(dy * size));\n" +
        "    float lod = (levels <= 1.0 || rho <= 1.0) ? 0.0 : min(levels - 1.0, log2(rho));\n" +
        "    return textureLod(tex, vec2(c.x, mix(c.y, 1.0 - c.y, flip)), lod);\n" +
        "}\n"

    /// 割り算（BinOp.Div）。割る数が 0 なら 0。割り算を使う Spec にだけ足す。
    /// WhyNot: 式に `(b == 0.0 ? 0.0 : a / b)` と直に書かない — b の式を 2 回書くことになり、b に tex や blur が入ると読みが倍になる。
    def divSource(): String =
        "float sg_div(float a, float b) {\n" +
        "    return b == 0.0 ? 0.0 : a / b;\n" +
        "}\n"

    /// texNames の並び（正典順）に uniform 宣言を吐く。空なら空文字（1 文字も足さない）。
    def texUniformDecls(names: List[a]): String =
        names |> List.zipWithIndex |> List.joinWith(iname -> {
            let (i, _) = iname;
            "uniform sampler2D uTex${i};\nuniform float uTexFlip${i};\n"
        }, "")

    /// texReads の並びに、絵の段の数の uniform を吐く（3D の材質だけ）。
    def texLevelDecls(names: List[a]): String =
        names |> List.zipWithIndex |> List.joinWith(iname -> {
            let (i, _) = iname;
            "uniform float uTexLevels${i};\n"
        }, "")

    /// fieldExpr が tex を段つきで読むか（3D の材質の materialEval）・段 0 で読むか（cutout の α）を引く鍵。tex の表に同居させる。
    def mipModeKey(): String = "@mode:mip"

    def level0ModeKey(): String = "@mode:level0"

    /// Param の名前の並び（paramNames の正典順）に uniform 宣言を吐く。空なら空文字（Param を使わない Spec の GLSL を変えない）。
    def paramUniformDecls(names: List[String]): String =
        names |> List.zipWithIndex |> List.joinWith(iname -> {
            let (i, _) = iname;
            "uniform float uParam${i};\n"
        }, "")

    /// fieldExpr が Param の番号（uParamN）を引く鍵。tex の表に同居させる（fieldExpr の引数を増やさない）。
    def paramKey(name: String): String = "@param:" + name

    /// Param の名前 → 正典順の番号を tex の表へ足す。
    def withParamScope(params: List[String], tex: Map[String, Int32]): Map[String, Int32] =
        params |> List.zipWithIndex |> List.foldLeft((acc, iname) -> {
            let (i, name) = iname;
            Map.insert(paramKey(name), i, acc)
        }, tex)

    /// fieldExpr が tex / blur の番号を引く表（texReads の正典順の番号）。素の名前 = 今の補間の番号、
    /// scopedKey(名前, 補間) = その補間の番号。Sampler の節が素の名前を指し直す（rescope）。
    /// sizeKey(名前) = その名前の最初の組の番号（TexSize が寸法を読む sampler。補間に依らない）。
    def texScopeFrom(reads: List[(String, ShaderDoc.FilterMode)]): Map[String, Int32] =
        reads |> List.zipWithIndex |> List.foldLeft((acc, ir) -> {
            let (i, (name, filter)) = ir;
            let withScoped = Map.insert(scopedKey(name, filter), i, acc);
            let withSize = if (Map.memberOf(sizeKey(name), withScoped)) withScoped else Map.insert(sizeKey(name), i, withScoped);
            if (filter == ShaderDoc.FilterMode.Nearest) Map.insert(name, i, withSize) else withSize
        }, Map.empty())

    def sizeKey(name: String): String = "@size:" + name

    def scopedKey(name: String, filter: ShaderDoc.FilterMode): String = name + "@sampler:" + ToString.toString(filter)

    /// Sampler の内側: 素の名前を filter の番号へ指し直す（その組が無い名前は素の名前ごと外す — 内側では読まれない）。
    def rescope(filter: ShaderDoc.FilterMode, tex: Map[String, Int32]): Map[String, Int32] =
        let suffix = "@sampler:" + ToString.toString(filter);
        Map.foldLeftWithKey((acc, key, i) ->
            if (String.endsWith({ suffix = suffix }, key))
                Map.insert(String.dropRight(String.length(suffix), key), i, acc)
            else acc,
        tex |> Map.filterWithKey((key, _) -> String.contains({ substr = "@sampler:" }, key) or String.startsWith({ prefix = "@param:" }, key)
                                             or String.startsWith({ prefix = "@mode:" }, key)
                                             or String.startsWith({ prefix = "@size:" }, key)), tex)

    // ── main 本体（prelude 抜き）のスナップショット用。ノイズテンプレを混ぜず Spec だけ pin する。──
    pub def compileBody(spec: ShaderDoc.Spec): String =
        let tex = withParamScope(ShaderDoc.paramNames(spec), texScopeFrom(ShaderDoc.texReads(spec)));
        let stmts = mainStatements(spec, "vUv", Map.empty(), tex);
        let n = List.length(stmts);
        stmts |> List.zipWithIndex
              |> List.map(ist -> { let (i, st) = ist; if (i == n - 1) st else "    " + st + "\n" })
              |> joinParts

    /// main の文（binding の宣言を前から・最後に outColor）。同じ読みは共通部分式として括り出してある（finishReads）。
    /// uv = 場が読む座標の GLSL 式・baseEnv = binding より前から見える名前（3D の world と法線の変数）。
    def mainStatements(spec: ShaderDoc.Spec, uv: String, baseEnv: Map[String, String], tex: Map[String, Int32]): List[String] =
        let rev = bindingStatements(spec#bindings, uv, baseEnv, tex);
        let out = outStmt(spec#cycleRate, spec#out, uv, bindingEnv(spec#bindings, baseEnv), tex);
        finishReads(vec4BindingHead(tex), List.reverse(out :: rev))

    /// binding の宣言の文（逆順）。
    def bindingStatements(bindings: List[(String, ShaderDoc.Field)], uv: String, baseEnv: Map[String, String],
                          tex: Map[String, Int32]): List[String] =
        let (rev, _) = List.foldLeft((acc, nf) -> {
            let (out, env) = acc;
            let (name, field) = nf;
            let line = floatBindingHead(tex) + "sg_b_" + name + " = " + fieldExpr(field, uv, env, tex) + ";";
            (line :: out, Map.insert(name, "sg_b_" + name, env))
        }, (Nil, baseEnv), bindings);
        rev

    // ── 同じ読みの括り出し（CSE / hoist）──
    // fieldExpr は tex / blur の呼び出しを ⟦ ⟧ で囲んで返す（チャンネルの .r は外）。finishReads が全部の文で
    // 同じ呼び出しの字を数え、2 回以上出る物だけ vec4 の変数に括り出して、最初に使う文の直前に宣言する。
    // 呼び出しの字は vUv・uTime・uniform・前の binding の変数だけで閉じているので、どの文の前に置いても同じ値になる。

    /// 文の中の読みの木（⟦ ⟧ は入れ子になる — blur の amount の中に tex があるなど）。
    enum ReadPiece {
        case Text(String)
        case Read(List[ReadPiece])
    }

    /// 括り出しの途中の状態: 括り出した呼び出しの字 → 変数名・この文の前に置く宣言（逆順）・次の番号。
    type alias HoistState = { declared = Map[String, String], decls = List[String], next = Int32 }

    def markRead(call: String): String = "⟦" + call + "⟧"

    /// 印の付いた文の列を、印の無い GLSL の文の列へ。1 回しか出ない読みはそのまま書き戻す
    /// （同じ読みが 2 回以上無い Spec の GLSL は印を入れる前と 1 文字も変わらない）。
    def finishReads(vecDecl: String, stmts: List[String]): List[String] =
        if (not List.exists(st -> String.contains({ substr = "⟦" }, st), stmts)) stmts
        else {
            let parsed = stmts |> List.map(st -> fst(parseReads(st, 0)));
            let counts = parsed |> List.foldLeft((acc, ps) -> countReads(ps, acc), Map.empty());
            let (out, _) = parsed |> List.foldLeft((acc, ps) -> {
                let (lines, st0) = acc;
                let (text, st1) = renderReads(vecDecl, counts, ps, { decls = Nil | st0 });
                (List.append(text :: st1#decls, lines), st1)
            }, (Nil, { declared = Map.empty(), decls = Nil, next = 0 }));
            List.reverse(out)
        }

    /// s の i 文字目から、閉じの ⟧ か終わりまでを木にする。戻りの Int32 は読み終えた次の位置。
    def parseReads(s: String, i: Int32): (List[ReadPiece], Int32) =
        let n = String.length(s);
        let textOf = (start, end, acc) ->
            if (end > start) ReadPiece.Text(String.slice({ start = start }, { end = end }, s)) :: acc else acc;
        def go(j, start, acc) =
            if (j >= n) (List.reverse(textOf(start, j, acc)), j)
            else {
                let c = String.charAt(j, s);
                if (c == '⟦') {
                    let (inner, next) = parseReads(s, j + 1);
                    go(next, next, ReadPiece.Read(inner) :: textOf(start, j, acc))
                } else if (c == '⟧') (List.reverse(textOf(start, j, acc)), j + 1)
                else go(j + 1, start, acc)
            };
        go(i, i, Nil)

    /// 印を全部外した字（括り出しの鍵）。
    def plainReads(ps: List[ReadPiece]): String =
        ps |> List.map(p -> match p {
            case ReadPiece.Text(t) => t
            case ReadPiece.Read(inner) => plainReads(inner)
        }) |> joinParts

    def countReads(ps: List[ReadPiece], acc: Map[String, Int32]): Map[String, Int32] =
        List.foldLeft((m, p) -> match p {
            case ReadPiece.Text(_) => m
            case ReadPiece.Read(inner) =>
                let key = plainReads(inner);
                countReads(inner, Map.insert(key, 1 + Option.getWithDefault(0, Map.get(key, m)), m))
        }, acc, ps)

    def renderReads(vecDecl: String, counts: Map[String, Int32], ps: List[ReadPiece], st: HoistState): (String, HoistState) =
        let (rev, stOut) = List.foldLeft((acc, p) -> {
            let (parts, st0) = acc;
            match p {
                case ReadPiece.Text(t) => (t :: parts, st0)
                case ReadPiece.Read(inner) =>
                    let (call, st1) = renderReads(vecDecl, counts, inner, st0);
                    let (text, st2) = hoistRead(vecDecl, counts, plainReads(inner), call, st1);
                    (text :: parts, st2)
            }
        }, (Nil, st), ps);
        (joinParts(List.reverse(rev)), stOut)

    /// 2 回以上出る読みは変数へ（初めてならこの文の前に宣言を積む）、1 回きりなら呼び出しのまま。
    def hoistRead(vecDecl: String, counts: Map[String, Int32], key: String, call: String, st: HoistState): (String, HoistState) =
        if (Option.getWithDefault(0, Map.get(key, counts)) < 2) (call, st)
        else match Map.get(key, st#declared) {
            case Some(var) => (var, st)
            case None =>
                let var = "sg_r${st#next}";
                (var, { declared = Map.insert(key, var, st#declared),
                        decls = (vecDecl + var + " = " + call + ";") :: st#decls,
                        next = st#next + 1 })
        }

    /// bindings 名 → GLSL 変数名（sg_b_<name>）の env。out 式（shade/alpha）が Ref を解くのに使う。
    def bindingEnv(bindings: List[(String, ShaderDoc.Field)], baseEnv: Map[String, String]): Map[String, String] =
        List.foldLeft((env, nf) -> {
            let (name, _) = nf;
            Map.insert(name, "sg_b_" + name, env)
        }, baseEnv, bindings)

    def outStmt(cycleRate: Float64, out: ShaderDoc.Out, uv: String, env: Map[String, String],
                tex: Map[String, Int32]): String =
        match out {
            case ShaderDoc.Out.Fill(f) =>
                (if (isWgsl(tex)) "let " else "") + "outColor = vec4(" + shadeExpr(cycleRate, f#shade, uv, env, tex) + ", " +
                fieldExpr(f#alpha, uv, env, tex) + ");"
        }

    def shadeExpr(cycleRate: Float64, shade: ShaderDoc.Shade, uv: String, env: Map[String, String],
                  tex: Map[String, Int32]): String =
        match shade {
            case ShaderDoc.Shade.Solid(c) => vec3Lit(c)
            case ShaderDoc.Shade.Ramp(r)  =>
                // cycleRate = 0 は素直な補間（field 0→lo・1→hi）。cycleRate>0 のときだけ
                // field を cycleRate*uTime で往復させる三角波にして色が呼吸する（パレット循環）。
                let factor =
                    if (cycleRate == 0.0)
                        "clamp(" + fieldExpr(r#field, uv, env, tex) + ", 0.0, 1.0)"
                    else
                        "clamp(abs(fract((" + fieldExpr(r#field, uv, env, tex) + ") + " +
                        f(cycleRate) + " * uTime) * 2.0 - 1.0), 0.0, 1.0)";
                "mix(" + vec3Lit(r#lo) + ", " + vec3Lit(r#hi) + ", " + factor + ")"
            case ShaderDoc.Shade.Gradient(g) =>
                // 係数 f は Ramp と同じ規約（cycleRate=0 は clamp・>0 は三角波で往復）。
                let factor =
                    if (cycleRate == 0.0)
                        "clamp(" + fieldExpr(g#field, uv, env, tex) + ", 0.0, 1.0)"
                    else
                        "clamp(abs(fract((" + fieldExpr(g#field, uv, env, tex) + ") + " +
                        f(cycleRate) + " * uTime) * 2.0 - 1.0), 0.0, 1.0)";
                // 先頭色から始め、隣り合う区切りごとに mix(..., 次の色, smoothstep(前,次,f)) を入れ子で重ねる
                // （sg_gradient は作らず素の mix/smoothstep を直書き＝prelude を増やさない）。
                gradientExpr(smoothstepName(tex), g#stops, factor)
            case ShaderDoc.Shade.Cosine(cs) =>
                // t = field（cycleRate>0 なら uTime を足して位相を回す。clamp しない＝cos の周期で色が巡る）。
                let t =
                    if (cycleRate == 0.0)
                        "(" + fieldExpr(cs#field, uv, env, tex) + ")"
                    else
                        "(" + fieldExpr(cs#field, uv, env, tex) + " + " + f(cycleRate) + " * uTime)";
                "sg_cospal(" + t + ", " + vec3Lit(cs#a) + ", " + vec3Lit(cs#b) + ", " +
                    vec3Lit(cs#c) + ", " + vec3Lit(cs#d) + ")"
            case ShaderDoc.Shade.Rgb(c) =>
                // cycleRate は読まない（Shade.Rgb の doc の決まり — 3 本の場に三角波は掛けない）。
                "vec3(" + fieldExpr(c#r, uv, env, tex) + ", " +
                fieldExpr(c#g, uv, env, tex) + ", " + fieldExpr(c#b, uv, env, tex) + ")"
        }

    /// stops を先頭色から入れ子 mix にする GLSL 式。区切りが 2 つなら
    /// mix(mix(c0, c1, smoothstep(s0,s1,f)), c2, smoothstep(s1,s2,f)) の形。
    def gradientExpr(smooth: String, stops: List[(Float64, Color)], factor: String): String =
        match stops {
            case Nil => "vec3(0.0, 0.0, 0.0)"
            case (_, c0) :: rest =>
                // 1 段ごとに「それまでの式全体」を包み直す形なので、文字列を足しながら組むと
                // 区切りの数の二乗ぶんコピーする。開き括弧をまとめて先に置き、閉じる側だけ積む。
                let (tails, _) = List.foldLeft((acc, sc) -> {
                    let (out, prevPos) = acc;
                    let (pos, col) = sc;
                    let w = smooth + "(" + f(prevPos) + ", " + f(pos) + ", " + factor + ")";
                    ((", " + vec3Lit(col) + ", " + w + ")") :: out, pos)
                }, (Nil, gradientFirstPos(stops)), rest);
                joinParts(List.append(List.map(_ -> "mix(", rest),
                                      vec3Lit(c0) :: List.reverse(tails)))
        }

    def gradientFirstPos(stops: List[(Float64, Color)]): Float64 =
        match stops {
            case (p, _) :: _ => p
            case Nil         => 0.0
        }

    /// 場を GLSL の float 式へ。uv は「今読むべき座標」の GLSL 式（Scaled/Warp/Tiling が差し替える）。
    /// env は bindings 名 → GLSL 変数名で、Ref だけがこれを読む（他の case は受けて再帰へ渡すだけ）。
    /// tex はテクスチャ名 → sampler 番号（texNames の正典順）で、Tex だけがこれを読む。
    def fieldExpr(field: ShaderDoc.Field, uv: String, env: Map[String, String],
                  tex: Map[String, Int32]): String =
        match field {
            case ShaderDoc.Field.Const(v) => f(v)
            case ShaderDoc.Field.Uv(u)    =>
                match u#axis {
                    case ShaderDoc.Axis.U => "(" + uv + ").x"
                    case ShaderDoc.Axis.V => "(" + uv + ").y"
                }
            case ShaderDoc.Field.Worley(w) =>
                let inner = "sg_worleyF1F2((" + uv + ") * " + f(w#scale) + ", " + fSeed(w#seed) + ")";
                match w#out {
                    case ShaderDoc.WorleyOut.F1    => "(" + inner + ".x)"
                    case ShaderDoc.WorleyOut.F2    => "(" + inner + ".y)"
                    case ShaderDoc.WorleyOut.F2mF1 => "(" + inner + ".y - " + inner + ".x)"
                }
            case ShaderDoc.Field.Fbm(b) =>
                "sg_fbm((" + uv + ") * " + f(b#scale) + ", " + iLit(b#octaves) + ", " + fSeed(b#seed) + ")"
            case ShaderDoc.Field.FbmTile(b) =>
                "sg_fbmTile((" + uv + ") * " + f(b#scale) + ", vec2(" + f(b#period#x) + ", " +
                f(b#period#y) + "), " + iLit(b#octaves) + ", " + fSeed(b#seed) + ")"
            case ShaderDoc.Field.Smoothstep(s) =>
                smoothstepName(tex) + "(" + f(s#lo) + ", " + f(s#hi) + ", " + fieldExpr(s#of, uv, env, tex) + ")"
            case ShaderDoc.Field.Scaled(s) =>
                // inner の見る座標を factor 倍 + uTime*scroll で差し替える。
                let uv2 = "((" + uv + ") * " + f(s#factor) + " + vec2(" +
                          f(s#scroll#x) + ", " + f(s#scroll#y) + ") * uTime)";
                fieldExpr(s#of, uv2, env, tex)
            case ShaderDoc.Field.Warp(wp) =>
                // fbm でずらしたオフセットを uv に足して inner を読む（ドメインワープ）。
                let off = "(vec2(sg_fbm((" + uv + ") * " + f(wp#scale) + ", 3, " + fSeed(wp#seed) +
                          "), sg_fbm((" + uv + ") * " + f(wp#scale) + ", 3, " + fSeed(wp#seed) + " + 91.0)) - 0.5)";
                let uv2 = "((" + uv + ") + " + off + " * " + f(wp#amount) + ")";
                fieldExpr(wp#of, uv2, env, tex)
            case ShaderDoc.Field.Swirl(sw) =>
                // 読む座標を中心まわりに回してから of を読む（Warp と同じ「座標差し替え」）。
                let uv2 = "sg_swirl((" + uv + "), " + f(sw#cx) + ", " + f(sw#cy) + ", " +
                          f(sw#strength) + ", " + f(sw#rate) + ")";
                fieldExpr(sw#of, uv2, env, tex)
            case ShaderDoc.Field.Angle(an) =>
                // 中心から見た角度を 0..1 へ（atan2 / 2π + 0.5）。
                "(" + atan2Name(tex) + "((" + uv + ").y - " + f(an#cy) + ", (" + uv + ").x - " + f(an#cx) +
                    ") * 0.15915494 + 0.5)"
            case ShaderDoc.Field.Rotate(rt) =>
                let uv2 = "sg_rotate((" + uv + "), " + f(rt#cx) + ", " + f(rt#cy) + ", " +
                          f(rt#turns) + ", " + f(rt#rate) + ")";
                fieldExpr(rt#of, uv2, env, tex)
            case ShaderDoc.Field.Mix(m) =>
                "mix(" + fieldExpr(m#a, uv, env, tex) + ", " + fieldExpr(m#b, uv, env, tex) + ", " + f(m#t) + ")"
            case ShaderDoc.Field.Blend(bl) =>
                "mix(" + fieldExpr(bl#a, uv, env, tex) + ", " + fieldExpr(bl#b, uv, env, tex) + ", " +
                "clamp(" + fieldExpr(bl#by, uv, env, tex) + ", 0.0, 1.0))"
            case ShaderDoc.Field.Disk(d) =>
                // 中心からの距離が radius 以内で 1、radius→radius+feather で 0 へ soft fade。
                "(1.0 - " + smoothstepName(tex) + "(" + f(d#radius) + ", " + f(d#radius + d#feather) + ", " +
                "length((" + uv + ") - vec2(" + f(d#cx) + ", " + f(d#cy) + "))))"
            case ShaderDoc.Field.Radial(rd) =>
                // 中心からの生の距離（クランプしない — 呼び側の Smoothstep がカーブを決める）。
                "length((" + uv + ") - vec2(" + f(rd#cx) + ", " + f(rd#cy) + "))"
            case ShaderDoc.Field.RadialAspect(ra) =>
                // u 方向だけ aspect 倍してから距離を測る（非正方形 rect でも px で真円）。
                "length(vec2(((" + uv + ").x - " + f(ra#cx) + ") * " + f(ra#aspect) + ", (" +
                uv + ").y - " + f(ra#cy) + "))"
            case ShaderDoc.Field.Quantize(q) =>
                // steps は 1 未満だと 0 除算になるので生成時に 1 で下切りする（CPU 側と同じ扱い）。
                let n = f(Int32.toFloat64(Int32.max(1, q#steps)));
                "(floor((" + fieldExpr(q#of, uv, env, tex) + ") * " + n + ") / " + n + ")"
            case ShaderDoc.Field.Scales(sc) =>
                "sg_scales((" + uv + "), " + f(sc#scale) + ", " + f(sc#stagger) + ")"
            case ShaderDoc.Field.Glints(g) =>
                "sg_glints((" + uv + "), " + f(g#scale) + ", " + f(g#rate) + ", " +
                f(g#density) + ", " + fSeed(g#seed) + ")"
            case ShaderDoc.Field.Ripples(rp) =>
                "sg_ripples((" + uv + "), " + f(rp#freq) + ", " + f(rp#amp) + ", " +
                f(rp#speed) + ", " + fSeed(rp#seed) + ")"
            case ShaderDoc.Field.Sparkle(sp) =>
                "sg_sparkle((" + uv + "), " + f(sp#scale) + ", " + f(sp#rate) + ", " +
                f(sp#density) + ", " + fSeed(sp#seed) + ")"
            case ShaderDoc.Field.Bin(bn) =>
                let ae = fieldExpr(bn#a, uv, env, tex);
                let be = fieldExpr(bn#b, uv, env, tex);
                match bn#op {
                    case ShaderDoc.BinOp.Add  => "(" + ae + " + " + be + ")"
                    case ShaderDoc.BinOp.Sub  => "(" + ae + " - " + be + ")"
                    case ShaderDoc.BinOp.Mul  => "(" + ae + " * " + be + ")"
                    case ShaderDoc.BinOp.Min  => "min(" + ae + ", " + be + ")"
                    case ShaderDoc.BinOp.Max  => "max(" + ae + ", " + be + ")"
                    case ShaderDoc.BinOp.Step => "step(" + ae + ", " + be + ")"
                    case ShaderDoc.BinOp.Div  => "sg_div(" + ae + ", " + be + ")"
                }
            case ShaderDoc.Field.Hash1(h) =>
                // セルの整数座標 floor(uv*scale) を hash に渡す。bucket が有れば座標に足す（GLSL の
                // vec2+float は自動で両成分に配る）。既存 sg_hash1 を呼ぶだけ（prelude は増やさない）。
                "sg_hash1(" + hashCoord(h#scale, h#bucket, uv, env, tex) + ", " + fSeed(h#seed) + ")"
            case ShaderDoc.Field.Hash2(h) =>
                let comp = match h#comp {
                    case ShaderDoc.Axis.U => ".x"
                    case ShaderDoc.Axis.V => ".y"
                };
                "(sg_hash2(" + hashCoord(h#scale, h#bucket, uv, env, tex) + ", " + fSeed(h#seed) + "))" + comp
            case ShaderDoc.Field.Un(un) =>
                let x = fieldExpr(un#of, uv, env, tex);
                match un#op {
                    case ShaderDoc.UnOp.Neg      => "(-(" + x + "))"
                    case ShaderDoc.UnOp.Abs      => "abs(" + x + ")"
                    case ShaderDoc.UnOp.Fract    => "fract(" + x + ")"
                    case ShaderDoc.UnOp.Floor    => "floor(" + x + ")"
                    case ShaderDoc.UnOp.Sin      => "sin(" + x + ")"
                    case ShaderDoc.UnOp.Cos      => "cos(" + x + ")"
                    case ShaderDoc.UnOp.Sat      => "clamp(" + x + ", 0.0, 1.0)"
                    case ShaderDoc.UnOp.OneMinus => "(1.0 - (" + x + "))"
                    case ShaderDoc.UnOp.Sqrt     => "sqrt(max(" + x + ", 0.0))"
                    case ShaderDoc.UnOp.Log2     => "log2(max(" + x + ", " + Float64.toString(ShaderDoc.log2Floor()) + "))"
                }
            case ShaderDoc.Field.Pow(pw) =>
                // 整数指数は pow() でなく反復積の文字列にして CPU 側の反復積と構造を合わせる
                // （GPU/CPU で丸め順が揃いパリティが強くなる）。負の底の非整数乗は NaN なので 0 で下切り。
                if (pw#p < 0.0) negPowExpr(fieldExpr(pw#of, uv, env, tex), pw#p, tex)
                else {
                    let base = "max(0.0, " + fieldExpr(pw#of, uv, env, tex) + ")";
                    if (Float64.floor(pw#p) == pw#p)
                        powProductFor(tex, base, Float64.floor(pw#p))
                    else
                        "pow(max(0.0, (" + fieldExpr(pw#of, uv, env, tex) + ")), " + f(pw#p) + ")"
                }
            case ShaderDoc.Field.Time(tm) =>
                "(uTime * " + f(tm#scale) + " + (" + fieldExpr(tm#offset, uv, env, tex) + "))"
            case ShaderDoc.Field.Tiling(tl) =>
                // 各マス内は fract(uv*tiles)。of が読む座標をこの式に差し替える（sg_tiling は作らない）。
                let uv2 = "fract((" + uv + ") * vec2(" + f(tl#tiles#x) + ", " + f(tl#tiles#y) + "))";
                fieldExpr(tl#of, uv2, env, tex)
            case ShaderDoc.Field.Snap(sn) =>
                // マスの中心（+0.5）を読む — 角を読むと格子ノイズの節点に乗って塊が半マスずれる。
                // cells は 1 未満だと 0 除算になるので生成時に 1 で下切りする（CPU 側と同じ扱い）。
                let cells = "vec2(" + f(snapCells(sn#cells#x)) + ", " + f(snapCells(sn#cells#y)) + ")";
                let uv2 = "((floor((" + uv + ") * " + cells + ") + 0.5) / " + cells + ")";
                fieldExpr(sn#of, uv2, env, tex)
            case ShaderDoc.Field.Ref(name) =>
                // parse が定義済みを保証する。未定義は 0.0（保険）。
                match Map.get(name, env) {
                    case Some(glslVar) => glslVar
                    case None          => "0.0"
                }
            case ShaderDoc.Field.Tex(tx) =>
                // pass ターゲットは上下逆に格納されるので、貼る側の流儀どおり uniform の
                // uTexFlipN（0 か 1）で y を吸収する（テクスチャ側は触らない）。
                // 番号は texNames の正典順なので Map に必ずある。無い場合の 0 は保険。
                let i = Map.get(tx#name, tex) |> Option.getWithDefault(0);
                let chan = match tx#chan {
                    case ShaderDoc.TexChan.R => ".r"
                    case ShaderDoc.TexChan.G => ".g"
                    case ShaderDoc.TexChan.B => ".b"
                    case ShaderDoc.TexChan.A => ".a"
                };
                markRead(texReadCall(i, uv, tex)) + chan
            case ShaderDoc.Field.Shift(sh) =>
                // ずらし量 dx/dy は外側の uv で評価してから、of をずらした座標で読む。
                let uv2 = "((" + uv + ") + vec2(" + fieldExpr(sh#dx, uv, env, tex) + ", " +
                          fieldExpr(sh#dy, uv, env, tex) + "))";
                fieldExpr(sh#of, uv2, env, tex)
            case ShaderDoc.Field.Sampler(sm) =>
                fieldExpr(sm#of, uv, env, rescope(sm#filter, tex))
            case ShaderDoc.Field.Param(pm) =>
                // 番号は paramNames の正典順なので表に必ずある。無い場合の 0.0 は保険。
                match Map.get(paramKey(pm#name), tex) {
                    case Some(i) => "uParam${i}"
                    case None    => "0.0"
                }
            // uv を受けないので uv の式は読まない。2D（compile）の env には変数が無く 0.0。
            case ShaderDoc.Field.World(w)  => scene3dRead(worldKey(), w#axis, env)
            case ShaderDoc.Field.Normal(n) => scene3dRead(normalKey(), n#axis, env)
            case ShaderDoc.Field.VertexColor(vc) => vertexColorRead(vc#chan, env)
            case ShaderDoc.Field.TexBlur(bl) =>
                let i = Map.get(bl#name, tex) |> Option.getWithDefault(0);
                let chan = match bl#chan {
                    case ShaderDoc.TexChan.R => ".r"
                    case ShaderDoc.TexChan.G => ".g"
                    case ShaderDoc.TexChan.B => ".b"
                    case ShaderDoc.TexChan.A => ".a"
                };
                markRead("sg_blur(uTex${i}, " + texSamplerOrFlipArg(i, tex) + ", (" + uv + "), vec2(" + f(bl#radius#x) + ", " + f(bl#radius#y) +
                    ") * (" + fieldExpr(bl#amount, uv, env, tex) + "), " + iLit(ShaderDoc.blurTaps(bl#taps)) + ")") + chan
            // 番号は texReads の正典順なので表に必ずある。無い場合の 0.0 は保険。
            // WhyNot: 寸法を uniform で渡さない — 縮んだ Pass に registry の design の寸法を入れる取り違えが起きうる。
            case ShaderDoc.Field.TexSize(ts) =>
                let axis = match ts#axis {
                    case ShaderDoc.Axis.U => ".x"
                    case ShaderDoc.Axis.V => ".y"
                };
                match Map.get(sizeKey(ts#name), tex) {
                    case Some(i) => texSizeCall(i, tex) + axis + ")"
                    case None    => "0.0"
                }
        }

    /// uTexN を uv で読む GLSL の呼び出し（2D の面は texture・3D の材質は段つきの sg_texMip・cutout の α は段 0 の textureLod）。
    def texReadCall(i: Int32, uv: String, tex: Map[String, Int32]): String =
        let flipped = "vec2((" + uv + ").x, mix((" + uv + ").y, 1.0 - (" + uv + ").y, uTexFlip${i}))";
        if (Map.memberOf(mipModeKey(), tex)) "sg_texMip(uTex${i}, " + texSamplerOrFlipArg(i, tex) + ", uTexLevels${i}, (" + uv + "))"
        else if (isWgsl(tex)) "textureSampleLevel(uTex${i}, uTex${i}Sampler, (" + uv + "), 0.0)"
        else if (Map.memberOf(level0ModeKey(), tex)) "textureLod(uTex${i}, " + flipped + ", 0.0)"
        else "texture(uTex${i}, " + flipped + ")"

    // ── 言葉（GLSL・WGSL）で字が違う所。WGSL は表に wgslModeKey() を入れて組む ──
    // WhyNot: WGSL の読みで uv の上下を返さない — WebGPU の描き先の texture は上の行が先で、ほかの絵と同じ向き（返すのは GL の描き先だけ）。
    // WhyNot: WGSL の 2D の面の読みを textureSample にしない — 値で分かれる分岐（sg_blur の半径 0）の後で呼べない（uniformity）。面の絵に mip は無いのでレベル 0 と同じ値。

    /// 表の鍵: WGSL の字で組む（rescope が @mode: の鍵を残す）。
    def wgslModeKey(): String = "@mode:wgsl"

    def isWgsl(tex: Map[String, Int32]): Bool = Map.memberOf(wgslModeKey(), tex)

    def floatBindingHead(tex: Map[String, Int32]): String = if (isWgsl(tex)) "let " else "float "

    def vec4BindingHead(tex: Map[String, Int32]): String = if (isWgsl(tex)) "let " else "vec4 "

    def atan2Name(tex: Map[String, Int32]): String = if (isWgsl(tex)) "atan2" else "atan"

    /// 端が定数の smoothstep の名前（WGSL は ShaderGen.Wgsl の sg_smoothstep）。
    // WhyNot: WGSL で組み込みの smoothstep を直に書かない — 端が等しい（Disk の feather 0・同じ位置の stop）と、引数が全部定数の時に
    //   シェーダーを作る所で誤りになりうる。sg_smoothstep は CPU（ShaderEval）と同じく端が等しい時に x < lo で 0・ほかは 1 を返す。
    def smoothstepName(tex: Map[String, Int32]): String = if (isWgsl(tex)) "sg_smoothstep" else "smoothstep"

    /// sg_blur・sg_texMip の 2 つ目の引数（GLSL は上下を返す uTexFlipN・WGSL は sampler）。
    def texSamplerOrFlipArg(i: Int32, tex: Map[String, Int32]): String = if (isWgsl(tex)) "uTex${i}Sampler" else "uTexFlip${i}"

    /// 寸法を float で読む式の頭（閉じ括弧は呼ぶ側）。
    def texSizeCall(i: Int32, tex: Map[String, Int32]): String =
        if (isWgsl(tex)) "f32(textureDimensions(uTex${i}, 0)" else "float(textureSize(uTex${i}, 0)"

    /// env の key に置いた 3D の変数（vec3）の axis の成分。無ければ 0.0（2D の面）。
    def scene3dRead(key: String, axis: ShaderDoc.Axis3, env: Map[String, String]): String =
        match Map.get(key, env) {
            case Some(glslVar) => glslVar + axis3Suffix(axis)
            case None          => "0.0"
        }

    /// 頂点の色の chan の成分。A と、3D の変数の無い 2D の面は 1.0。
    def vertexColorRead(chan: ShaderDoc.TexChan, env: Map[String, String]): String =
        match (Map.get(colorKey(), env), chan) {
            case (Some(glslVar), ShaderDoc.TexChan.R) => glslVar + ".r"
            case (Some(glslVar), ShaderDoc.TexChan.G) => glslVar + ".g"
            case (Some(glslVar), ShaderDoc.TexChan.B) => glslVar + ".b"
            case _                                    => "1.0"
        }

    def axis3Suffix(axis: ShaderDoc.Axis3): String =
        match axis {
            case ShaderDoc.Axis3.X => ".x"
            case ShaderDoc.Axis3.Y => ".y"
            case ShaderDoc.Axis3.Z => ".z"
        }

    /// hash に渡すセル座標の GLSL 式。floor((uv)*scale) を作り、bucket が有ればその式を足す。
    def hashCoord(scale: Float64, bucket: Option[ShaderDoc.Field], uv: String,
                  env: Map[String, String], tex: Map[String, Int32]): String =
        let cell = "floor((" + uv + ") * " + f(scale) + ")";
        match bucket {
            case None    => cell
            case Some(b) => "(" + cell + " + (" + fieldExpr(b, uv, env, tex) + "))"
        }

    /// Snap の分割数（ShaderEval.snapCells と同じ下切り）。
    def snapCells(c: Float64): Float64 = Float64.max(1.0, c)

    /// 負の指数の pow（ShaderEval.negPow と同じ下切り・上切り・掛け順）。
    def negPowExpr(x: String, p: Float64, tex: Map[String, Int32]): String =
        let base = "max(" + f(ShaderDoc.negPowFloor()) + ", " + x + ")";
        let raw = if (Float64.floor(p) == p) "(1.0 / " + powProductFor(tex, base, Float64.floor(-p)) + ")"
                  else "pow(" + base + ", " + f(p) + ")";
        "min(" + f(ShaderDoc.negPowCeil()) + ", " + raw + ")"

    /// base を n 回掛けた式（powProduct と同じ値・同じ掛け順）。WGSL の 2 回以上は ShaderGen.Wgsl の sg_powi を呼ぶ。
    // WhyNot: WGSL でも積を入れ子の括弧で書かない — 指数 180 の式は括弧が 179 重になり、Tint の構文解析の深さの上限（maximum parser recursive depth）で組めない。
    //   sg_powi は左から 1 回ずつ掛ける輪で、入れ子の積と同じ順に丸める。
    def powProductFor(tex: Map[String, Int32], base: String, n: Float64): String =
        let k = Int32.max(0, Float64.tryToInt32(n) |> Option.getWithDefault(0));
        if (isWgsl(tex) and k >= 2) "sg_powi(" + base + ", " + iLit(k) + ")"
        else powProduct(base, n)

    /// base を n 回掛けた GLSL 積の文字列（n=0 は 1.0・n=1 は base そのもの）。
    /// CPU 側の反復積と同じ左結合の並びにする。
    def powProduct(base: String, n: Float64): String =
        let k = Int32.max(0, Float64.tryToInt32(n) |> Option.getWithDefault(0));
        if (k == 0) "1.0"
        else {
            // 積も 1 段ごとに全体を包み直す形。開き括弧を先にまとめて置き、閉じる側だけ積む。
            let reps = List.range(1, k);
            joinParts(List.append(List.map(_ -> "(", reps),
                                  base :: List.map(_ -> " * " + base + ")", reps)))
        }

    def vec3Lit(c: Color): String =
        "vec3(" + f(c#r) + ", " + f(c#g) + ", " + f(c#b) + ")"

    /// GLSL と WGSL の float リテラル（決定論のため必ず小数点を含める）。
    def f(x: Float64): String =
        let s = "${x}";
        if (String.contains({ substr = "." }, s) or String.contains({ substr = "E" }, s)) s else s + ".0"

    /// seed（Int32）を GLSL の float リテラルへ（hash 関数は float seed を取る）。
    def fSeed(seed: Int32): String =
        f(Int32.toFloat64(seed))

    def iLit(n: Int32): String = "${n}"
}
