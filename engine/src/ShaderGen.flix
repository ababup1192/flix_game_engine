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

    /// Spec 2 つの構造比較（program キャッシュの正当性の中核）。真 ⇒ compile は純関数なので
    /// GLSL も等しい、が構成的に成り立つ。確保ゼロの純関数。
    /// WhyNot: derive の Eq にしない — Field 等の payload はレコードで、Flix のレコードは
    /// Eq を持てず導出がそこで止まる。GLSL 全文を鍵にしない — 当たったフレームでも
    /// compile（GLSL 全文の組み立て）を毎回払うことになる。ハッシュにしない — 衝突しない
    /// ことを証明できない。1 フィールドでも比べ忘れると、違う Spec を同じと誤答して
    /// 古い program の絵が何も知らせずに出続けるため、全 case・全フィールドをテストで pin する
    /// （engine/test/TestShaderGenEqSpec.flix）。
    pub def eqSpec(a: ShaderDoc.Spec, b: ShaderDoc.Spec): Bool =
        a#name == b#name
            and a#cycleRate == b#cycleRate
            and eqBindings(a#bindings, b#bindings)
            and eqOut(a#out, b#out)

    def eqBindings(a: List[(String, ShaderDoc.Field)], b: List[(String, ShaderDoc.Field)]): Bool =
        match (a, b) {
            case (Nil, Nil)                       => true
            case ((na, fa) :: ra, (nb, fb) :: rb) => na == nb and eqField(fa, fb) and eqBindings(ra, rb)
            case _                                => false
        }

    def eqOut(a: ShaderDoc.Out, b: ShaderDoc.Out): Bool =
        match (a, b) {
            case (ShaderDoc.Out.Fill(fa), ShaderDoc.Out.Fill(fb)) =>
                eqShade(fa#shade, fb#shade) and eqField(fa#alpha, fb#alpha)
        }

    def eqShade(a: ShaderDoc.Shade, b: ShaderDoc.Shade): Bool =
        use ShaderDoc.Shade;
        match (a, b) {
            case (Shade.Solid(ca), Shade.Solid(cb))       => eqColor(ca, cb)
            case (Shade.Ramp(ra), Shade.Ramp(rb))         =>
                eqColor(ra#lo, rb#lo) and eqColor(ra#hi, rb#hi) and eqField(ra#field, rb#field)
            case (Shade.Gradient(ga), Shade.Gradient(gb)) =>
                eqStops(ga#stops, gb#stops) and eqField(ga#field, gb#field)
            case (Shade.Cosine(ca), Shade.Cosine(cb))     =>
                eqColor(ca#a, cb#a) and eqColor(ca#b, cb#b) and eqColor(ca#c, cb#c)
                    and eqColor(ca#d, cb#d) and eqField(ca#field, cb#field)
            case (Shade.Rgb(ra), Shade.Rgb(rb))           =>
                eqField(ra#r, rb#r) and eqField(ra#g, rb#g) and eqField(ra#b, rb#b)
            case _                                        => false
        }

    def eqStops(a: List[(Float64, Color)], b: List[(Float64, Color)]): Bool =
        match (a, b) {
            case (Nil, Nil)                       => true
            case ((pa, ca) :: ra, (pb, cb) :: rb) => pa == pb and eqColor(ca, cb) and eqStops(ra, rb)
            case _                                => false
        }

    def eqColor(a: Color, b: Color): Bool =
        a#r == b#r and a#g == b#g and a#b == b#b

    def eqVec2(a: Vec2.Vec2, b: Vec2.Vec2): Bool =
        a#x == b#x and a#y == b#y

    def eqOptField(a: Option[ShaderDoc.Field], b: Option[ShaderDoc.Field]): Bool =
        match (a, b) {
            case (None, None)         => true
            case (Some(fa), Some(fb)) => eqField(fa, fb)
            case _                    => false
        }

    def eqField(a: ShaderDoc.Field, b: ShaderDoc.Field): Bool =
        use ShaderDoc.Field;
        match (a, b) {
            case (Field.Const(va), Field.Const(vb))               => va == vb
            case (Field.Uv(ra), Field.Uv(rb))                     => ra#axis == rb#axis
            case (Field.Worley(ra), Field.Worley(rb))             =>
                ra#scale == rb#scale and ra#seed == rb#seed and ra#out == rb#out
            case (Field.Fbm(ra), Field.Fbm(rb))                   =>
                ra#octaves == rb#octaves and ra#scale == rb#scale and ra#seed == rb#seed
            case (Field.FbmTile(ra), Field.FbmTile(rb))           =>
                ra#octaves == rb#octaves and ra#scale == rb#scale
                    and eqVec2(ra#period, rb#period) and ra#seed == rb#seed
            case (Field.Smoothstep(ra), Field.Smoothstep(rb))     =>
                ra#lo == rb#lo and ra#hi == rb#hi and eqField(ra#of, rb#of)
            case (Field.Scaled(ra), Field.Scaled(rb))             =>
                ra#factor == rb#factor and eqVec2(ra#scroll, rb#scroll) and eqField(ra#of, rb#of)
            case (Field.Warp(ra), Field.Warp(rb))                 =>
                ra#amount == rb#amount and ra#scale == rb#scale and ra#seed == rb#seed
                    and eqField(ra#of, rb#of)
            case (Field.Mix(ra), Field.Mix(rb))                   =>
                eqField(ra#a, rb#a) and eqField(ra#b, rb#b) and ra#t == rb#t
            case (Field.Blend(ra), Field.Blend(rb))               =>
                eqField(ra#a, rb#a) and eqField(ra#b, rb#b) and eqField(ra#by, rb#by)
            case (Field.Disk(ra), Field.Disk(rb))                 =>
                ra#cx == rb#cx and ra#cy == rb#cy
                    and ra#radius == rb#radius and ra#feather == rb#feather
            case (Field.Radial(ra), Field.Radial(rb))             =>
                ra#cx == rb#cx and ra#cy == rb#cy
            case (Field.RadialAspect(ra), Field.RadialAspect(rb)) =>
                ra#cx == rb#cx and ra#cy == rb#cy and ra#aspect == rb#aspect
            case (Field.Quantize(ra), Field.Quantize(rb))         =>
                eqField(ra#of, rb#of) and ra#steps == rb#steps
            case (Field.Scales(ra), Field.Scales(rb))             =>
                ra#scale == rb#scale and ra#stagger == rb#stagger
            case (Field.Glints(ra), Field.Glints(rb))             =>
                ra#scale == rb#scale and ra#rate == rb#rate
                    and ra#density == rb#density and ra#seed == rb#seed
            case (Field.Ripples(ra), Field.Ripples(rb))           =>
                ra#freq == rb#freq and ra#amp == rb#amp
                    and ra#speed == rb#speed and ra#seed == rb#seed
            case (Field.Sparkle(ra), Field.Sparkle(rb))           =>
                ra#scale == rb#scale and ra#rate == rb#rate
                    and ra#density == rb#density and ra#seed == rb#seed
            case (Field.Bin(ra), Field.Bin(rb))                   =>
                ra#op == rb#op and eqField(ra#a, rb#a) and eqField(ra#b, rb#b)
            case (Field.Hash1(ra), Field.Hash1(rb))               =>
                ra#scale == rb#scale and ra#seed == rb#seed and eqOptField(ra#bucket, rb#bucket)
            case (Field.Hash2(ra), Field.Hash2(rb))               =>
                ra#scale == rb#scale and ra#seed == rb#seed
                    and ra#comp == rb#comp and eqOptField(ra#bucket, rb#bucket)
            case (Field.Un(ra), Field.Un(rb))                     =>
                ra#op == rb#op and eqField(ra#of, rb#of)
            case (Field.Pow(ra), Field.Pow(rb))                   =>
                eqField(ra#of, rb#of) and ra#p == rb#p
            case (Field.Time(ra), Field.Time(rb))                 =>
                ra#scale == rb#scale and eqField(ra#offset, rb#offset)
            case (Field.Tiling(ra), Field.Tiling(rb))             =>
                eqVec2(ra#tiles, rb#tiles) and eqField(ra#of, rb#of)
            case (Field.Snap(ra), Field.Snap(rb))                 =>
                eqVec2(ra#cells, rb#cells) and eqField(ra#of, rb#of)
            case (Field.Swirl(ra), Field.Swirl(rb))               =>
                ra#cx == rb#cx and ra#cy == rb#cy and ra#strength == rb#strength
                    and ra#rate == rb#rate and eqField(ra#of, rb#of)
            case (Field.Angle(ra), Field.Angle(rb))               =>
                ra#cx == rb#cx and ra#cy == rb#cy
            case (Field.Rotate(ra), Field.Rotate(rb))             =>
                ra#cx == rb#cx and ra#cy == rb#cy and ra#turns == rb#turns
                    and ra#rate == rb#rate and eqField(ra#of, rb#of)
            case (Field.Ref(na), Field.Ref(nb))                   => na == nb
            case (Field.Tex(ra), Field.Tex(rb))                   =>
                ra#name == rb#name and ra#chan == rb#chan
            case (Field.Shift(ra), Field.Shift(rb))               =>
                eqField(ra#dx, rb#dx) and eqField(ra#dy, rb#dy) and eqField(ra#of, rb#of)
            case _                                                => false
        }

    /// Spec → fragment シェーダー全体（prelude + main）。uTime uniform を前提に持つ。
    /// Tex を使う Spec だけ sampler uniform（uTexN / uTexFlipN）が増える — 使わない Spec の
    /// 出力は 1 文字も変えない（headless のスナップショットを無傷に保つ）。
    pub def compile(spec: ShaderDoc.Spec): String =
        // texNames は木を全走査するので、宣言と番号表で使い回す（毎回呼ぶと走査が重複する）。
        let names = ShaderDoc.texNames(spec);
        let tex = texIndexFrom(names);
        joinParts(
            "#version 330 core\n" ::
            "in vec2 vUv;\n" ::
            "out vec4 outColor;\n" ::
            "uniform float uTime;\n" ::
            texUniformDecls(names) ::
            preludeSource() ::
            "void main() {\n" ::
            bindingPrelude(spec#bindings, tex) ::
            "    " :: outStmt(spec#cycleRate, spec#out, envOf(spec#bindings), tex) :: "\n" ::
            "}\n" :: Nil)

    /// texNames の並び（正典順）に uniform 宣言を吐く。空なら空文字（1 文字も足さない）。
    def texUniformDecls(names: List[String]): String =
        names |> List.zipWithIndex |> List.joinWith(iname -> {
            let (i, _) = iname;
            "uniform sampler2D uTex${i};\nuniform float uTexFlip${i};\n"
        }, "")

    /// テクスチャ名 → sampler 番号（texNames の正典順）。Tex ノードが uTexN を選ぶのに使う。
    def texIndexFrom(names: List[String]): Map[String, Int32] =
        names |> List.zipWithIndex
            |> List.foldLeft((acc, iname) -> { let (i, name) = iname; Map.insert(name, i, acc) },
                             Map.empty())

    // ── main 本体（prelude 抜き）のスナップショット用。ノイズテンプレを混ぜず Spec だけ pin する。──
    pub def compileBody(spec: ShaderDoc.Spec): String =
        let tex = texIndexFrom(ShaderDoc.texNames(spec));
        bindingPrelude(spec#bindings, tex) +
        outStmt(spec#cycleRate, spec#out, envOf(spec#bindings), tex)

    /// bindings を main 先頭の `float sg_b_<name> = <式>;` 宣言に並べる（前から順）。
    /// 各 binding の式は自分より前の binding だけ Ref できるので、env を前から畳み込みながら組む。
    /// bindings が空（既存 Spec）なら 1 文字も吐かない（main 本体は現行と完全一致）。
    def bindingPrelude(bindings: List[(String, ShaderDoc.Field)], tex: Map[String, Int32]): String =
        if (List.isEmpty(bindings)) ""
        else {
            let (rev, _) = List.foldLeft((acc, nf) -> {
                let (out, env) = acc;
                let (name, field) = nf;
                let line = "    float sg_b_" + name + " = " + fieldExpr(field, "vUv", env, tex) + ";\n";
                (line :: out, Map.insert(name, "sg_b_" + name, env))
            }, (Nil, Map.empty()), bindings);
            joinParts(List.reverse(rev))
        }

    /// bindings 名 → GLSL 変数名（sg_b_<name>）の env。out 式（shade/alpha）が Ref を解くのに使う。
    def envOf(bindings: List[(String, ShaderDoc.Field)]): Map[String, String] =
        List.foldLeft((env, nf) -> {
            let (name, _) = nf;
            Map.insert(name, "sg_b_" + name, env)
        }, Map.empty(), bindings)

    def outStmt(cycleRate: Float64, out: ShaderDoc.Out, env: Map[String, String],
                tex: Map[String, Int32]): String =
        match out {
            case ShaderDoc.Out.Fill(f) =>
                "outColor = vec4(" + shadeExpr(cycleRate, f#shade, env, tex) + ", " +
                fieldExpr(f#alpha, "vUv", env, tex) + ");"
        }

    def shadeExpr(cycleRate: Float64, shade: ShaderDoc.Shade, env: Map[String, String],
                  tex: Map[String, Int32]): String =
        match shade {
            case ShaderDoc.Shade.Solid(c) => vec3Lit(c)
            case ShaderDoc.Shade.Ramp(r)  =>
                // cycleRate = 0 は素直な補間（field 0→lo・1→hi）。cycleRate>0 のときだけ
                // field を cycleRate*uTime で往復させる三角波にして色が呼吸する（パレット循環）。
                let factor =
                    if (cycleRate == 0.0)
                        "clamp(" + fieldExpr(r#field, "vUv", env, tex) + ", 0.0, 1.0)"
                    else
                        "clamp(abs(fract((" + fieldExpr(r#field, "vUv", env, tex) + ") + " +
                        f(cycleRate) + " * uTime) * 2.0 - 1.0), 0.0, 1.0)";
                "mix(" + vec3Lit(r#lo) + ", " + vec3Lit(r#hi) + ", " + factor + ")"
            case ShaderDoc.Shade.Gradient(g) =>
                // 係数 f は Ramp と同じ規約（cycleRate=0 は clamp・>0 は三角波で往復）。
                let factor =
                    if (cycleRate == 0.0)
                        "clamp(" + fieldExpr(g#field, "vUv", env, tex) + ", 0.0, 1.0)"
                    else
                        "clamp(abs(fract((" + fieldExpr(g#field, "vUv", env, tex) + ") + " +
                        f(cycleRate) + " * uTime) * 2.0 - 1.0), 0.0, 1.0)";
                // 先頭色から始め、隣り合う区切りごとに mix(..., 次の色, smoothstep(前,次,f)) を入れ子で重ねる
                // （sg_gradient は作らず素の mix/smoothstep を直書き＝prelude を増やさない）。
                gradientExpr(g#stops, factor)
            case ShaderDoc.Shade.Cosine(cs) =>
                // t = field（cycleRate>0 なら uTime を足して位相を回す。clamp しない＝cos の周期で色が巡る）。
                let t =
                    if (cycleRate == 0.0)
                        "(" + fieldExpr(cs#field, "vUv", env, tex) + ")"
                    else
                        "(" + fieldExpr(cs#field, "vUv", env, tex) + " + " + f(cycleRate) + " * uTime)";
                "sg_cospal(" + t + ", " + vec3Lit(cs#a) + ", " + vec3Lit(cs#b) + ", " +
                    vec3Lit(cs#c) + ", " + vec3Lit(cs#d) + ")"
            case ShaderDoc.Shade.Rgb(c) =>
                // cycleRate は読まない（Shade.Rgb の doc の決まり — 3 本の場に三角波は掛けない）。
                "vec3(" + fieldExpr(c#r, "vUv", env, tex) + ", " +
                fieldExpr(c#g, "vUv", env, tex) + ", " + fieldExpr(c#b, "vUv", env, tex) + ")"
        }

    /// stops を先頭色から入れ子 mix にする GLSL 式。区切りが 2 つなら
    /// mix(mix(c0, c1, smoothstep(s0,s1,f)), c2, smoothstep(s1,s2,f)) の形。
    def gradientExpr(stops: List[(Float64, Color)], factor: String): String =
        match stops {
            case Nil => "vec3(0.0, 0.0, 0.0)"
            case (_, c0) :: rest =>
                // 1 段ごとに「それまでの式全体」を包み直す形なので、文字列を足しながら組むと
                // 区切りの数の二乗ぶんコピーする。開き括弧をまとめて先に置き、閉じる側だけ積む。
                let (tails, _) = List.foldLeft((acc, sc) -> {
                    let (out, prevPos) = acc;
                    let (pos, col) = sc;
                    let w = "smoothstep(" + f(prevPos) + ", " + f(pos) + ", " + factor + ")";
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
                "smoothstep(" + f(s#lo) + ", " + f(s#hi) + ", " + fieldExpr(s#of, uv, env, tex) + ")"
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
                "(atan((" + uv + ").y - " + f(an#cy) + ", (" + uv + ").x - " + f(an#cx) +
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
                "(1.0 - smoothstep(" + f(d#radius) + ", " + f(d#radius + d#feather) + ", " +
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
                }
            case ShaderDoc.Field.Pow(pw) =>
                // 整数指数は pow() でなく反復積の文字列にして CPU 側の反復積と構造を合わせる
                // （GPU/CPU で丸め順が揃いパリティが強くなる）。負の底の非整数乗は NaN なので 0 で下切り。
                let base = "max(0.0, " + fieldExpr(pw#of, uv, env, tex) + ")";
                if (Float64.floor(pw#p) == pw#p)
                    powProduct(base, Float64.floor(pw#p))
                else
                    "pow(max(0.0, (" + fieldExpr(pw#of, uv, env, tex) + ")), " + f(pw#p) + ")"
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
                "texture(uTex${i}, vec2((" + uv + ").x, mix((" + uv +
                    ").y, 1.0 - (" + uv + ").y, uTexFlip${i})))" + chan
            case ShaderDoc.Field.Shift(sh) =>
                // ずらし量 dx/dy は外側の uv で評価してから、of をずらした座標で読む。
                let uv2 = "((" + uv + ") + vec2(" + fieldExpr(sh#dx, uv, env, tex) + ", " +
                          fieldExpr(sh#dy, uv, env, tex) + "))";
                fieldExpr(sh#of, uv2, env, tex)
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

    /// GLSL の float リテラル（決定論のため必ず小数点を含める）。
    def f(x: Float64): String =
        let s = "${x}";
        if (String.contains({ substr = "." }, s) or String.contains({ substr = "E" }, s)) s else s + ".0"

    /// seed（Int32）を GLSL の float リテラルへ（hash 関数は float seed を取る）。
    def fSeed(seed: Int32): String =
        f(Int32.toFloat64(seed))

    def iLit(n: Int32): String = "${n}"
}
