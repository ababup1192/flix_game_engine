// LightModel3d.PointShadowCodegen — 3D の場面（Scene3d）の部品。点光源の影を引く式のコード生成。

/// 点光源の影を引く式（受ける点 → 影の割合）1 本から、GLSL と WGSL の r3d_pointShadowLit と、CPU の描き手が画素ごとに回す Flix の関数
/// （engine_tools の gen/SoftRaster3dLight.flix の pointShadowLitAt）を作る。engine の開発用（ゲームは使わない）。
/// 式（Scene3d.PointShadows.atlasOf の doc の続き。s = guardScale・S = tileSize・(A, B) = depthTermsOf）:
///   1. |位置 − p|² ≥ range² か dot(n, 位置 − p) ≤ 0 なら 1（光が届かない・面が背を向けた点は引かない）。
///   2. d0 = p − 位置・major = max(|d0.x|, |d0.y|, |d0.z|)・d = d0 + g × normalBias × 2 major / (s × S)。
///   3. 面 = |d.x| ≥ |d.y| かつ |d.x| ≥ |d.z| なら X・ほかに |d.y| ≥ |d.z| なら Y・ほかは Z（成分が 0 以上なら + の面。番号は basisOf）。
///      along = d·F・rx = d·R・uy = d·U（basisOf の向き）。along ≤ near なら 1。
///   4. refDepth = (A − B / max(along − bias, near)) × 0.5 + 0.5・真ん中の画素 = clamp(floor((s × (rx, uy) / along × 0.5 + 0.5) × S), 0, S − 1)。
///   5. PCF は (x + dx, y + dy) を 0..S − 1 に寄せてから面の原点（tileOriginOf）を足し、refDepth ≤ 地図の値 の数を数える。
///      影の割合 = 1 − strength × (1 − 数 / (2 pcf + 1)²)。
// WhyNot: LightModel3d の木（ScalarExpr・Vec3Expr）に足さない — 木は整数・床関数・面の選び・地図を読むループを持たない。
//   足すと光の式の 3 つの出口と使わない文の落とし方が全部それを扱うことになり、木を読む人の範囲が広がる。
// WhyNot: GPU の near を CPU と同じ値（uniform）で渡さない — GPU は B / (A + 1) を f32 で出し、CPU は ShadowedPointLight#near を読む。
//   GPU の値を替えると比べの境の画素が動きうる。式の入力の読み方（Input）だけを出口ごとに替える。
pub mod LightModel3d.PointShadowCodegen {

    /// GPU の出口の言葉（Flix の出口は toFlix の関数の組）。
    enum Dialect {
        case Glsl
        case Wgsl
    }

    /// 式の入力（出口ごとに読み方が違う）。LightPosition・Point・FaceNormal・Normal は vec3・ほかはスカラー。
    enum Input {
        case LightPosition
        case LightRange
        case TileSize
        case GuardScale
        case Bias
        case NormalBias
        case Near
        case DepthA
        case DepthB
        case Strength
        case Point
        case FaceNormal
        case Normal
    }

    enum Axis {
        case X
        case Y
        case Z
    }

    /// 式（スカラーか vec3。vec3 と スカラーの Mul・Add は成分ごと）。
    enum Expr {
        case Local(String)
        case In(Input)
        case Num(String)
        case Comp(Expr, Axis)
        case Add(Expr, Expr)
        case Sub(Expr, Expr)
        case Mul(Expr, Expr)
        case Div(Expr, Expr)
        case Neg(Expr)
        case Max(Expr, Expr)
        case Abs(Expr)
        case Dot(Expr, Expr)
    }

    /// 先へ進む条件（満たさない点は影を引かず 1）。
    enum Proceed {
        case Below(Expr, Expr)
        case Above(Expr, Expr)
        case Both(Proceed, Proceed)
    }

    /// 面の選びの 1 行: 主な軸・+ と − の面の番号・符号の名前・rx と uy（符号の名前と d の成分で書く）。
    type alias FaceRow = { axis = Axis, plus = Int32, minus = Int32, sign = String, right = Expr, up = Expr }

    enum Step {
        case Let(String, Expr)
        case ProceedIf(Proceed)
        /// |d| の名前・d の名前 → face・along・rx・uy。
        case SelectFace(String, String)
    }

    /// 最後の PCF の数え: 画素の位置の ndc (x, y)・比べる値・面の一辺（Float）→ 影の割合を返す。
    type alias CountLit = { x = Expr, y = Expr, refDepth = Expr, tile = Expr }

    /// 式の全部: 順に流す文と、最後の数え。
    type alias Program = { steps = List[Step], count = CountLit }

    // ════════════════════════════════════════════════════════
    // 式
    // ════════════════════════════════════════════════════════

    def local(name: String): Expr = Expr.Local(name)

    def comp(name: String, axis: Axis): Expr = Expr.Comp(Expr.Local(name), axis)

    def program(): Program =
        let toLight = local("toLight");
        let tile = local("tile");
        let scale = local("scale");
        let along = local("along");
        let near = local("near");
        let shift = Expr.Div(Expr.Mul(Expr.Mul(Expr.In(Input.NormalBias), Expr.Num("2.0")), local("major")), Expr.Mul(scale, tile));
        let refDepth = Expr.Add(Expr.Mul(Expr.Sub(Expr.In(Input.DepthA), Expr.Div(Expr.In(Input.DepthB), Expr.Max(Expr.Sub(along, Expr.In(Input.Bias)), near))),
                                         Expr.Num("0.5")), Expr.Num("0.5"));
        let steps =
            Step.Let("toLight", Expr.Sub(Expr.In(Input.LightPosition), Expr.In(Input.Point))) ::
            Step.Let("reach", Expr.In(Input.LightRange)) ::
            Step.ProceedIf(Proceed.Both(Proceed.Below(Expr.Dot(toLight, toLight), Expr.Mul(local("reach"), local("reach"))),
                                        Proceed.Above(Expr.Dot(Expr.In(Input.Normal), toLight), Expr.Num("0.0")))) ::
            Step.Let("tile", Expr.In(Input.TileSize)) ::
            Step.Let("scale", Expr.In(Input.GuardScale)) ::
            Step.Let("d0", Expr.Neg(toLight)) ::
            Step.Let("major", Expr.Max(Expr.Abs(comp("d0", Axis.X)), Expr.Max(Expr.Abs(comp("d0", Axis.Y)), Expr.Abs(comp("d0", Axis.Z))))) ::
            Step.Let("d", Expr.Add(local("d0"), Expr.Mul(Expr.In(Input.FaceNormal), shift))) ::
            Step.Let("a", Expr.Abs(local("d"))) ::
            Step.SelectFace("a", "d") ::
            Step.Let("near", Expr.In(Input.Near)) ::
            Step.ProceedIf(Proceed.Above(along, near)) ::
            Step.Let("refDepth", refDepth) :: Nil;
        { steps = steps,
          count = { x = Expr.Div(Expr.Mul(scale, local("rx")), along), y = Expr.Div(Expr.Mul(scale, local("uy")), along), refDepth = local("refDepth"), tile = tile } }

    def faceRows(d: String): List[FaceRow] =
        { axis = Axis.X, plus = 0, minus = 1, sign = "sx", right = Expr.Mul(Expr.Neg(local("sx")), comp(d, Axis.Z)), up = comp(d, Axis.Y) } ::
        { axis = Axis.Y, plus = 2, minus = 3, sign = "sy", right = Expr.Mul(Expr.Neg(local("sy")), comp(d, Axis.X)), up = comp(d, Axis.Z) } ::
        { axis = Axis.Z, plus = 4, minus = 5, sign = "sz", right = Expr.Mul(local("sz"), comp(d, Axis.X)), up = comp(d, Axis.Y) } :: Nil

    /// 面の選びの行 row を選ぶ条件（左 ≥ 右）の組（最後の行は空 = ほか全部）。
    def rowTests(a: String, row: FaceRow): List[(Expr, Expr)] = match row#axis {
        case Axis.X => (comp(a, Axis.X), comp(a, Axis.Y)) :: (comp(a, Axis.X), comp(a, Axis.Z)) :: Nil
        case Axis.Y => (comp(a, Axis.Y), comp(a, Axis.Z)) :: Nil
        case Axis.Z => Nil
    }

    def isVec3Input(i: Input): Bool = match i {
        case Input.LightPosition => true
        case Input.Point         => true
        case Input.FaceNormal    => true
        case Input.Normal        => true
        case _                   => false
    }

    def isVec3(vecs: Set[String], e: Expr): Bool = match e {
        case Expr.Local(n)  => Set.memberOf(n, vecs)
        case Expr.In(i)     => isVec3Input(i)
        case Expr.Num(_)    => false
        case Expr.Comp(_, _) => false
        case Expr.Add(a, b) => isVec3(vecs, a) or isVec3(vecs, b)
        case Expr.Sub(a, b) => isVec3(vecs, a) or isVec3(vecs, b)
        case Expr.Mul(a, b) => isVec3(vecs, a) or isVec3(vecs, b)
        case Expr.Div(a, b) => isVec3(vecs, a) or isVec3(vecs, b)
        case Expr.Neg(a)    => isVec3(vecs, a)
        case Expr.Max(a, b) => isVec3(vecs, a) or isVec3(vecs, b)
        case Expr.Abs(a)    => isVec3(vecs, a)
        case Expr.Dot(_, _) => false
    }

    /// vec3 の Let の名前（Flix は成分ごとの 3 つの名前に分ける）。
    def vecLocals(steps: List[Step]): Set[String] =
        steps |> List.foldLeft((vecs, s) -> match s {
            case Step.Let(n, e) => if (isVec3(vecs, e)) Set.insert(n, vecs) else vecs
            case _              => vecs
        }, Set.empty())

    // ════════════════════════════════════════════════════════
    // 字（演算子の強さ: 0 = 名前・呼び出し・1 = 単項・2 = 積と商・3 = 和と差）
    // ════════════════════════════════════════════════════════

    def wrap(code: (String, Int32), limit: Int32): String =
        let (text, strength) = code;
        if (strength > limit) "(${text})" else text

    /// 左結合の 2 項。右は同じ強さでも括弧で包む（浮動小数の和と積は結合の順で値が変わる）。
    def binary(op: String, strength: Int32, a: (String, Int32), b: (String, Int32)): (String, Int32) =
        ("${wrap(a, strength)} ${op} ${wrap(b, strength - 1)}", strength)

    def axisName(axis: Axis): String = match axis {
        case Axis.X => "x"
        case Axis.Y => "y"
        case Axis.Z => "z"
    }

    def axisSuffix(axis: Axis): String = match axis {
        case Axis.X => "X"
        case Axis.Y => "Y"
        case Axis.Z => "Z"
    }

    def gpuInput(dialect: Dialect, i: Input): (String, Int32) = match (dialect, i) {
        case (Dialect.Glsl, Input.LightPosition) => ("uPointPos[i]", 0)
        case (Dialect.Glsl, Input.LightRange)    => ("uPointRange[i]", 0)
        case (Dialect.Glsl, Input.TileSize)      => ("uPointShadowAtlas.x", 0)
        case (Dialect.Glsl, Input.GuardScale)    => ("uPointShadowAtlas.z", 0)
        case (Dialect.Glsl, Input.Bias)          => ("uPointShadowBias.x", 0)
        case (Dialect.Glsl, Input.NormalBias)    => ("uPointShadowBias.y", 0)
        case (_, Input.LightPosition)            => ("r3d.uPointPos[i].xyz", 0)
        case (_, Input.LightRange)               => ("r3d.uPointRange[i].x", 0)
        case (_, Input.TileSize)                 => ("r3dLight.uPointShadowAtlas.x", 0)
        case (_, Input.GuardScale)               => ("r3dLight.uPointShadowAtlas.z", 0)
        case (_, Input.Bias)                     => ("r3dLight.uPointShadowBias.x", 0)
        case (_, Input.NormalBias)               => ("r3dLight.uPointShadowBias.y", 0)
        case (_, Input.Near)                     => ("shadowed.z / (shadowed.y + 1.0)", 2)
        case (_, Input.DepthA)                   => ("shadowed.y", 0)
        case (_, Input.DepthB)                   => ("shadowed.z", 0)
        case (_, Input.Strength)                 => ("shadowed.w", 0)
        case (_, Input.Point)                    => ("p", 0)
        case (_, Input.FaceNormal)               => ("g", 0)
        case (_, Input.Normal)                   => ("n", 0)
    }

    def gpuCode(dialect: Dialect, e: Expr): (String, Int32) = match e {
        case Expr.Local(n)     => (n, 0)
        case Expr.In(i)        => gpuInput(dialect, i)
        case Expr.Num(s)       => (s, if (String.startsWith(prefix = "-", s)) 1 else 0)
        case Expr.Comp(v, axis) => ("${wrap(gpuCode(dialect, v), 0)}.${axisName(axis)}", 0)
        case Expr.Add(a, b)    => binary("+", 3, gpuCode(dialect, a), gpuCode(dialect, b))
        case Expr.Sub(a, b)    => binary("-", 3, gpuCode(dialect, a), gpuCode(dialect, b))
        case Expr.Mul(a, b)    => binary("*", 2, gpuCode(dialect, a), gpuCode(dialect, b))
        case Expr.Div(a, b)    => binary("/", 2, gpuCode(dialect, a), gpuCode(dialect, b))
        case Expr.Neg(a)       => ("-${wrap(gpuCode(dialect, a), 0)}", 1)
        case Expr.Max(a, b)    => ("max(${fst(gpuCode(dialect, a))}, ${fst(gpuCode(dialect, b))})", 0)
        case Expr.Abs(a)       => ("abs(${fst(gpuCode(dialect, a))})", 0)
        case Expr.Dot(a, b)    => ("dot(${fst(gpuCode(dialect, a))}, ${fst(gpuCode(dialect, b))})", 0)
    }

    def gpuText(dialect: Dialect, e: Expr): String = fst(gpuCode(dialect, e))

    /// GPU の「進まない」条件（Proceed の否定を比べの向きで書く）。
    def gpuStop(dialect: Dialect, c: Proceed): String = match c {
        case Proceed.Below(a, b) => "${gpuText(dialect, a)} >= ${gpuText(dialect, b)}"
        case Proceed.Above(a, b) => "${gpuText(dialect, a)} <= ${gpuText(dialect, b)}"
        case Proceed.Both(x, y)  => "${gpuStop(dialect, x)} || ${gpuStop(dialect, y)}"
    }

    def flixInput(i: Input): String = match i {
        case Input.LightPosition => "light"
        case Input.LightRange    => "reach"
        case Input.TileSize      => "Int32.toFloat64(tileSize)"
        case Input.GuardScale    => "scale"
        case Input.Bias          => "bias"
        case Input.NormalBias    => "normalBias"
        case Input.Near          => "near"
        case Input.DepthA        => "depthA"
        case Input.DepthB        => "depthB"
        case Input.Strength      => "strength"
        case Input.Point         => "p"
        case Input.FaceNormal    => "g"
        case Input.Normal        => "n"
    }

    /// Flix のスカラーの式（vec3 の Dot は成分の積の和に開く）。
    def flixScalar(vecs: Set[String], e: Expr): (String, Int32) = match e {
        case Expr.Local(n)     => (n, 0)
        case Expr.In(i)        => (flixInput(i), 0)
        case Expr.Num(s)       => (s, if (String.startsWith(prefix = "-", s)) 1 else 0)
        case Expr.Comp(v, axis) => flixComponent(vecs, v, axis)
        case Expr.Add(a, b)    => binary("+", 3, flixScalar(vecs, a), flixScalar(vecs, b))
        case Expr.Sub(a, b)    => binary("-", 3, flixScalar(vecs, a), flixScalar(vecs, b))
        case Expr.Mul(a, b)    => binary("*", 2, flixScalar(vecs, a), flixScalar(vecs, b))
        case Expr.Div(a, b)    => binary("/", 2, flixScalar(vecs, a), flixScalar(vecs, b))
        case Expr.Neg(a)       => ("-${wrap(flixScalar(vecs, a), 0)}", 1)
        case Expr.Max(a, b)    => ("Float64.max(${fst(flixScalar(vecs, a))}, ${fst(flixScalar(vecs, b))})", 0)
        case Expr.Abs(a)       => ("Float64.abs(${fst(flixScalar(vecs, a))})", 0)
        case Expr.Dot(a, b)    =>
            let term = (axis: Axis) -> binary("*", 2, flixComponent(vecs, a, axis), flixComponent(vecs, b, axis));
            binary("+", 3, binary("+", 3, term(Axis.X), term(Axis.Y)), term(Axis.Z))
    }

    /// vec3 の式 e の成分 axis（スカラーの式はそのまま）。
    def flixComponent(vecs: Set[String], e: Expr, axis: Axis): (String, Int32) =
        if (not isVec3(vecs, e)) flixScalar(vecs, e)
        else match e {
            case Expr.Local(n)  => ("${n}${axisSuffix(axis)}", 0)
            case Expr.In(i)     => ("${flixInput(i)}${axisSuffix(axis)}", 0)
            case Expr.Add(a, b) => binary("+", 3, flixComponent(vecs, a, axis), flixComponent(vecs, b, axis))
            case Expr.Sub(a, b) => binary("-", 3, flixComponent(vecs, a, axis), flixComponent(vecs, b, axis))
            case Expr.Mul(a, b) => binary("*", 2, flixComponent(vecs, a, axis), flixComponent(vecs, b, axis))
            case Expr.Div(a, b) => binary("/", 2, flixComponent(vecs, a, axis), flixComponent(vecs, b, axis))
            case Expr.Neg(a)    => ("-${wrap(flixComponent(vecs, a, axis), 0)}", 1)
            case Expr.Max(a, b) => ("Float64.max(${fst(flixComponent(vecs, a, axis))}, ${fst(flixComponent(vecs, b, axis))})", 0)
            case Expr.Abs(a)    => ("Float64.abs(${fst(flixComponent(vecs, a, axis))})", 0)
            case _              => flixScalar(vecs, e)
        }

    def flixText(vecs: Set[String], e: Expr): String = fst(flixScalar(vecs, e))

    /// Flix の「進む」条件。
    def flixGo(vecs: Set[String], c: Proceed): String = match c {
        case Proceed.Below(a, b) => "${flixText(vecs, a)} < ${flixText(vecs, b)}"
        case Proceed.Above(a, b) => "${flixText(vecs, a)} > ${flixText(vecs, b)}"
        case Proceed.Both(x, y)  => "${flixGo(vecs, x)} and ${flixGo(vecs, y)}"
    }

    def indent(depth: Int32): String = String.repeat(depth * 4, " ")

    // ════════════════════════════════════════════════════════
    // GLSL・WGSL の出口
    // ════════════════════════════════════════════════════════

    /// GLSL の float r3d_pointShadowLit(int i, vec3 p, vec3 g, vec3 n)（uniform の宣言は ShaderAst が読んだ handle から出す）。
    pub def toGlsl(): String =
        "float r3d_pointShadowLit(int i, vec3 p, vec3 g, vec3 n) {\n" +
        "    vec4 shadowed = uPointShadow[i];\n" +
        "    if (shadowed.x < 0.0) return 1.0;\n" +
        gpuProgram(Dialect.Glsl, program()) +
        "}\n"

    /// WGSL の fn r3d_pointShadowLit(i, p, g, n) -> f32（場面の値は r3d と r3dLight の欄。atlas の行は読む時だけ高さ − 1 − 行 に返す）。
    pub def toWgsl(): String =
        "fn r3d_pointShadowLit(i: i32, p: vec3f, g: vec3f, n: vec3f) -> f32 {\n" +
        "    let shadowed = r3dLight.uPointShadow[i];\n" +
        "    if (shadowed.x < 0.0) { return 1.0; }\n" +
        gpuProgram(Dialect.Wgsl, program()) +
        "}\n"

    def gpuProgram(dialect: Dialect, prog: Program): String =
        let vecs = vecLocals(prog#steps);
        let c = prog#count;
        (prog#steps |> List.map(gpuStep(dialect, vecs)) |> List.join("")) +
        gpuCountLit(dialect, gpuText(dialect, c#x), gpuText(dialect, c#y), gpuText(dialect, c#refDepth), gpuText(dialect, c#tile))

    def gpuStep(dialect: Dialect, vecs: Set[String], s: Step): String = match s {
        case Step.Let(n, e)              => "    ${gpuDecl(dialect, isVec3(vecs, e))} ${n} = ${gpuText(dialect, e)};\n"
        case Step.ProceedIf(c)           => "    if (${gpuStop(dialect, c)}) ${gpuReturnOne(dialect)}\n"
        case Step.SelectFace(a, d)       => gpuSelectFace(dialect, a, d)
    }

    def gpuDecl(dialect: Dialect, vec: Bool): String = match dialect {
        case Dialect.Glsl => if (vec) "vec3" else "float"
        case _            => "let"
    }

    def gpuReturnOne(dialect: Dialect): String = match dialect {
        case Dialect.Glsl => "return 1.0;"
        case _            => "{ return 1.0; }"
    }

    def gpuSelectFace(dialect: Dialect, a: String, d: String): String =
        let rows = faceRows(d);
        let declare = match dialect {
            case Dialect.Glsl => "    int face;\n    float along;\n    float rx;\n    float uy;\n"
            case _            => "    var face = 0;\n    var along = 0.0;\n    var rx = 0.0;\n    var uy = 0.0;\n"
        };
        let branches = rows |> List.zipWithIndex |> List.map(entry -> {
            let (k, row) = entry;
            let tests = rowTests(a, row) |> List.map(t -> "${gpuText(dialect, fst(t))} >= ${gpuText(dialect, snd(t))}") |> List.join(" && ");
            let head = if (k == 0) "    if (${tests}) {\n" else if (List.isEmpty(rowTests(a, row))) "    } else {\n" else "    } else if (${tests}) {\n";
            head + gpuFaceBody(dialect, d, row)
        }) |> List.join("");
        declare + branches + "    }\n"

    def gpuFaceBody(dialect: Dialect, d: String, row: FaceRow): String =
        let positive = "${gpuText(dialect, comp(d, row#axis))} >= 0.0";
        let along = Expr.Mul(local(row#sign), comp(d, row#axis));
        let (sign, face) = match dialect {
            case Dialect.Glsl => ("float ${row#sign} = ${positive} ? 1.0 : -1.0;", "face = ${positive} ? ${row#plus} : ${row#minus};")
            case _            => ("let ${row#sign} = select(-1.0, 1.0, ${positive});", "face = select(${row#minus}, ${row#plus}, ${positive});")
        };
        "        ${sign}\n" +
        "        ${face}\n" +
        "        along = ${gpuText(dialect, along)};\n" +
        "        rx = ${gpuText(dialect, row#right)};\n" +
        "        uy = ${gpuText(dialect, row#up)};\n"

    // WhyNot: 周りの画素を atlas の画素で端へ寄せない — 面の塊の外へ出ると隣の面の深度を読む。面の中（0..S − 1）で寄せてから原点を足す。
    def gpuCountLit(dialect: Dialect, x: String, y: String, refDepth: String, tile: String): String =
        let strength = gpuText(dialect, Expr.In(Input.Strength));
        match dialect {
            case Dialect.Glsl =>
                "    int size = int(${tile});\n" +
                "    ivec2 last = ivec2(size - 1);\n" +
                "    ivec2 center = clamp(ivec2(floor((vec2(${x}, ${y}) * 0.5 + 0.5) * ${tile})), ivec2(0), last);\n" +
                "    int slot = int(shadowed.x);\n" +
                "    int columns = int(uPointShadowAtlas.y);\n" +
                "    ivec2 origin = ivec2((slot % columns) * 3 * size + (face % 3) * size, (slot / columns) * 2 * size + (face / 3) * size);\n" +
                "    int pcf = int(uPointShadowAtlas.w);\n" +
                "    int lit = 0;\n" +
                "    int total = 0;\n" +
                "    for (int dy = -pcf; dy <= pcf; dy++) {\n" +
                "        for (int dx = -pcf; dx <= pcf; dx++) {\n" +
                "            ivec2 t = origin + clamp(center + ivec2(dx, dy), ivec2(0), last);\n" +
                "            if (${refDepth} <= texelFetch(uPointShadowMap, t, 0).r) lit++;\n" +
                "            total++;\n" +
                "        }\n" +
                "    }\n" +
                "    return 1.0 - ${strength} * (1.0 - float(lit) / float(total));\n"
            // WhyNot: 周りの画素を返した後の行で面の塊へ寄せない — 面の中へ寄せるのを GL の行で済ませてから返せば、CPU の描き手と同じ画素の組を読む。
            case _ =>
                "    let size = i32(${tile});\n" +
                "    let last = vec2i(size - 1);\n" +
                "    let center = clamp(vec2i(floor((vec2f(${x}, ${y}) * 0.5 + 0.5) * ${tile})), vec2i(0), last);\n" +
                "    let slot = i32(shadowed.x);\n" +
                "    let columns = i32(r3dLight.uPointShadowAtlas.y);\n" +
                "    let origin = vec2i((slot % columns) * 3 * size + (face % 3) * size, (slot / columns) * 2 * size + (face / 3) * size);\n" +
                "    let pcf = i32(r3dLight.uPointShadowAtlas.w);\n" +
                "    let top = i32(textureDimensions(uPointShadowMap, 0).y) - 1;\n" +
                "    var lit = 0;\n" +
                "    var total = 0;\n" +
                "    for (var dy = -pcf; dy <= pcf; dy++) {\n" +
                "        for (var dx = -pcf; dx <= pcf; dx++) {\n" +
                "            let t = origin + clamp(center + vec2i(dx, dy), vec2i(0), last);\n" +
                "            if (${refDepth} <= textureLoad(uPointShadowMap, vec2i(t.x, top - t.y), 0)) { lit++; }\n" +
                "            total++;\n" +
                "        }\n" +
                "    }\n" +
                "    return 1.0 - ${strength} * (1.0 - f32(lit) / f32(total));\n"
        }

    // ════════════════════════════════════════════════════════
    // Flix の出口（CPU の描き手）
    // ════════════════════════════════════════════════════════

    /// CPU の描き手の pointShadowLitAt の def の字（生成するファイルの mod の中に置く）。countLit = 面の地図・一辺・左下の画素 (x, y)・幅・比べる値・0・0 → 数 の関数の名前。
    /// 引数は flat（画素ごとにレコードも組も作らない）: faces = 面 0〜5 の地図（tileSize × tileSize・行 0 が ndc.y = −1）・pcf = pcfRadius・
    /// light = 位置・reach = range・near と strength = ShadowedPointLight の物・(depthA, depthB) = depthTermsOf・p・g・n は受ける点と 2 つの法線。
    // WhyNot: 面の選びを if の枝ごとに残りの関数を呼ぶ形にしない — 末尾の呼び出しは画素ごとのループの JIT（OSR）を外す。
    //   枝ごとの値を 1 つずつ if で選び、関数を 1 本に保つ。
    pub def toFlix(countLit: String): String =
        let prog = program();
        let vecs = vecLocals(prog#steps);
        let params = "faces: Vector[Vector[Float64]], tileSize: Int32, pcf: Int32, scale: Float64, bias: Float64, normalBias: Float64, " +
                     "lightX: Float64, lightY: Float64, lightZ: Float64, reach: Float64, near: Float64, depthA: Float64, depthB: Float64, strength: Float64, " +
                     "pX: Float64, pY: Float64, pZ: Float64, gX: Float64, gY: Float64, gZ: Float64, nX: Float64, nY: Float64, nZ: Float64";
        "    /// 点光源 1 本の影の割合（LightModel3d.PointShadowCodegen の式。光が届かない・面が背を向けた・near より手前の点は 1）。\n" +
        "    pub def pointShadowLitAt(${params}): Float64 =\n" +
        flixSteps(countLit, vecs, prog#count, 2, prog#steps)

    def flixSteps(countLit: String, vecs: Set[String], c: CountLit, depth: Int32, steps: List[Step]): String = match steps {
        case s :: rest => flixStep(countLit, vecs, c, depth, s, rest)
        case Nil       => flixCountLit(countLit, indent(depth), flixText(vecs, c#x), flixText(vecs, c#y), flixText(vecs, c#refDepth), flixText(vecs, c#tile))
    }

    def flixStep(countLit: String, vecs: Set[String], c: CountLit, depth: Int32, s: Step, rest: List[Step]): String =
        let pad = indent(depth);
        match s {
            case Step.Let(n, e) => flixLet(vecs, pad, n, e) + flixSteps(countLit, vecs, c, depth, rest)
            case Step.ProceedIf(go) =>
                "${pad}if (not (${flixGo(vecs, go)})) 1.0\n" +
                "${pad}else {\n" + flixSteps(countLit, vecs, c, depth + 1, rest) + "${pad}}\n"
            case Step.SelectFace(a, d) => flixSelectFace(vecs, pad, a, d) + flixSteps(countLit, vecs, c, depth, rest)
        }

    /// Let（vec3 は成分ごとの 3 行。入力をそのまま同じ名前で受ける Let は引数の名前と同じなので書かない）。
    def flixLet(vecs: Set[String], pad: String, n: String, e: Expr): String =
        if (isVec3(vecs, e))
            List.map(axis -> "${pad}let ${n}${axisSuffix(axis)} = ${fst(flixComponent(vecs, e, axis))};\n", Axis.X :: Axis.Y :: Axis.Z :: Nil) |> List.join("")
        else {
            let text = flixText(vecs, e);
            if (text == n) "" else "${pad}let ${n} = ${text};\n"
        }

    def flixSelectFace(vecs: Set[String], pad: String, a: String, d: String): String =
        let rows = faceRows(d);
        let tested = rows |> List.filter(row -> not List.isEmpty(rowTests(a, row)));
        let onName = (row: FaceRow) -> "on${axisSuffix(row#axis)}";
        let positive = (row: FaceRow) -> "${flixText(vecs, comp(d, row#axis))} >= 0.0";
        let signs = rows |> List.map(row -> "${pad}let ${row#sign} = if (${positive(row)}) 1.0 else -1.0;\n") |> List.join("");
        let ons = tested |> List.map(row -> {
            let tests = rowTests(a, row) |> List.map(t -> "${flixText(vecs, fst(t))} >= ${flixText(vecs, snd(t))}") |> List.join(" and ");
            "${pad}let ${onName(row)} = ${tests};\n"
        }) |> List.join("");
        let pickByFace = (name: String, valueOf: FaceRow -> String) -> {
            let chain = List.foldRight((row, acc) -> if (List.isEmpty(rowTests(a, row))) valueOf(row) else "if (${onName(row)}) ${valueOf(row)} else ${acc}", "", rows);
            "${pad}let ${name} = ${chain};\n"
        };
        signs + ons +
        pickByFace("face", row -> "(if (${positive(row)}) ${row#plus} else ${row#minus})") +
        pickByFace("along", row -> flixText(vecs, Expr.Mul(local(row#sign), comp(d, row#axis)))) +
        pickByFace("rx", row -> flixText(vecs, row#right)) +
        pickByFace("uy", row -> flixText(vecs, row#up))

    def flixCountLit(countLit: String, pad: String, x: String, y: String, refDepth: String, tile: String): String =
        let texel = (v: String) -> "Int32.max(0, Int32.min(last, Float64.truncateToInt32(Float64.floor((${v} * 0.5 + 0.5) * ${tile}))))";
        "${pad}let last = tileSize - 1;\n" +
        "${pad}let side = 2 * pcf + 1;\n" +
        "${pad}let lit = ${countLit}(Vector.get(face, faces), tileSize, ${texel(x)} - pcf, ${texel(y)} - pcf, side, ${refDepth}, 0, 0);\n" +
        "${pad}1.0 - ${flixInput(Input.Strength)} * (1.0 - Int32.toFloat64(lit) / Int32.toFloat64(side * side))\n"
}
