// LightModel3d.Codegen — 3D の場面（Scene3d）の部品。光の式の木（LightModel3d）のコード生成。

/// 光の式の木から、CPU の描き手が回す Flix のソース（engine_tools の gen/SoftRaster3dLight.flix）と GLSL の関数の字を作る。engine の開発用（ゲームは使わない）。
// WhyNot: Flix の出口を engine の外（engine_tools の test の側）へ出さない — 2 つの出口は同じ文の組み立てと使わない文の落とし方を共有し、
//   GL の出口は Render3d が走る時に使う。分けると共有の部分が 2 か所になる。ゲームの組む時間に約 800 行が乗る代わり。
// WhyNot: 木と同じファイルに置かない — 木と式は GL と CPU の約束で、コード生成は engine_tools と Render3d の名前を字で知る。触る人と理由が違う。
pub mod LightModel3d.Codegen {
    use LightModel3d.{ScalarExpr, Vec3Expr, Cond, ScalarInput, Vec3Input, ScalarLightField, Vec3LightField, LightKind}
    use LightModel3d.{lightingModel, lightmapLightingModel, fogModel, skyModel, pbrModel, environmentDirection, strideOf, vec3FieldOffset, scalarFieldOffset}

    // ════════════════════════════════════════════════════════
    // コード生成（2 つの出口が共に使う）
    // ════════════════════════════════════════════════════════

    /// 出口の言葉。
    enum Target {
        case Flix
        case Glsl
    }

    /// 生成した関数が受ける引数（並びの順が引数の順）。
    enum Param with Eq, Order {
        case Steps
        case Points
        case Spots
        case Shadow
        case Vec3Param(Vec3Input)
        case ScalarParam(ScalarInput)
    }

    /// 木を生成した文。
    enum Stmt {
        /// 名前 = 式。
        case Bind(String, String)
        /// 名前 = 条件（GLSL では bool）。
        case BindBool(String, String)
        /// 条件・受ける名前・真の時の文と値・偽の時の文と値。
        case IfElse(String, List[String], List[Stmt], List[String], List[Stmt], List[String])
        /// 光の種類・受ける名前 3 つ・1 本の光の文・足す値 3 つ・1 本の光が読む引数・ループの外で束ねた名前のうち 1 本の光が読む物（Float64 の名前。CPU は引数で渡す）。
        case Loop(LightKind, List[String], List[Stmt], List[String], Set[Param], List[String])
    }

    /// コード生成の途中の名前の表。light = 今いる光のループ・shadowFunction = CPU の影の割合の関数の名前（GLSL では使わない）。
    type alias Env = { scalars = Map[String, String], vecs = Map[String, (String, String, String)], light = Option[LightKind],
                       shadowFunction = String }

    def envFor(shadowFunction: String): Env = { scalars = Map.empty(), vecs = Map.empty(), light = None, shadowFunction = shadowFunction }

    /// 名前 base に数え上げの数をつないだ新しい名前。光のループの中は数の前に l を入れ、外の名前と重ならない。
    def freshName(fresh: Ref[(String, Int32), r], base: String): String \ r =
        let (scope, n) = Ref.get(fresh);
        Ref.put((scope, n + 1), fresh);
        "${base}_${scope}${n}"

    /// Let の名前は英字だけ（生成した名前の区切りの _ と数と重ならない）。
    def checkedLetName(name: String): String =
        let isAsciiLetter = (c: Char) -> (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        if (String.length(name) > 0 and (String.toList(name) |> List.forAll(isAsciiLetter))) name
        else bug!("LightModel3d: Let の名前「${name}」は英字だけにする")

    def numLit(x: Float64): String =
        if (not Float64.isFinite(x)) bug!("LightModel3d: Num に有限でない数（NaN・無限）は置けない")
        else numText(x)

    def numText(x: Float64): String =
        let s = String.map(c -> if (c == 'E') 'e' else c, Float64.toString(x));
        if (x < 0.0) "(${s})" else s

    /// 名前か数だけの式（何度書いても計算が増えない）。
    def isAtomic(code: String): Bool =
        not String.contains(substr = "(", code) and not String.contains(substr = " ", code)

    /// code が名前か数でなければ新しい名前に束ねる。
    def bindIfNotAtomic(fresh: Ref[(String, Int32), r], code: (List[Stmt], String)): (List[Stmt], String) \ r =
        let (stmts, e) = code;
        if (isAtomic(e)) code
        else {
            let name = freshName(fresh, "t");
            (stmts ::: Stmt.Bind(name, e) :: Nil, name)
        }

    def bindIfNotAtomic3(fresh: Ref[(String, Int32), r], code: (List[Stmt], (String, String, String))): (List[Stmt], (String, String, String)) \ r =
        let (stmts, (x, y, z)) = code;
        let (sx, bx) = bindIfNotAtomic(fresh, (stmts, x));
        let (sy, by) = bindIfNotAtomic(fresh, (sx, y));
        let (sz, bz) = bindIfNotAtomic(fresh, (sy, z));
        (sz, (bx, by, bz))

    def scalarInputCode(t: Target, env: Env, input: ScalarInput): String = match (t, input) {
        case (_, ScalarInput.ShadowLit) =>
            if (env#light != Some(LightKind.Spot)) bug!("LightModel3d: ShadowLit は SumSpots の中だけで読める")
            else match t {
                case Target.Flix => "${env#shadowFunction}(shadow, i, ${vec3InputCode(t, Vec3Input.Position, 0)}, ${vec3InputCode(t, Vec3Input.Position, 1)}, ${vec3InputCode(t, Vec3Input.Position, 2)})"
                // GLSL の i はスポットの番号（Flix の i は並びの欄の位置）。spotShadow はその番号で uShadowSpot と比べる。
                case Target.Glsl => "spotShadow(i, ${vec3InputName(Vec3Input.Position)})"
            }
        case (Target.Flix, _) => scalarInputName(input)
        // WhyNot: 太陽の影の割合を関数の引数にしない — toGlsl の引数の並びを変えず、frag の main が先に求めて渡す（地図を引くのは木の外）。
        case (Target.Glsl, ScalarInput.SunLit)            => "r3d_sunLit"
        case (Target.Glsl, ScalarInput.Hemisphere)        => "uHemisphere"
        case (Target.Glsl, ScalarInput.FogNear)           => "uFogRange.x"
        case (Target.Glsl, ScalarInput.FogFar)            => "uFogRange.y"
        case (Target.Glsl, ScalarInput.SkyCurve)          => "uCurve"
        case (Target.Glsl, ScalarInput.LightmapSrgb)      => "float(uLightmapSrgb)"
        case (Target.Glsl, ScalarInput.LightmapIntensity) => "uLightmapIntensity"
        case (Target.Glsl, ScalarInput.EnvironmentOn)     => "float(uEnvOn)"
        case (Target.Glsl, ScalarInput.EnvironmentBoxOn)  => "float(uEnvBoxOn)"
    }

    def scalarInputName(input: ScalarInput): String = match input {
        case ScalarInput.Hemisphere        => "hemisphere"
        case ScalarInput.ShadowLit         => "shadowLit"
        case ScalarInput.SunLit            => "sunLit"
        case ScalarInput.FogNear          => "fogNear"
        case ScalarInput.FogFar            => "fogFar"
        case ScalarInput.SkyCurve          => "skyCurve"
        case ScalarInput.LightmapSrgb      => "lightmapSrgb"
        case ScalarInput.LightmapIntensity => "lightmapIntensity"
        case ScalarInput.EnvironmentOn     => "envOn"
        case ScalarInput.EnvironmentBoxOn  => "envBoxOn"
    }

    def vec3InputName(input: Vec3Input): String = match input {
        case Vec3Input.Position      => "p"
        case Vec3Input.Normal        => "n"
        case Vec3Input.Eye           => "eye"
        case Vec3Input.Ambient       => "ambient"
        case Vec3Input.LightmapColor => "lightmap"
        case Vec3Input.Color         => "color"
        case Vec3Input.FogColor      => "fogColor"
        case Vec3Input.SkyDirection  => "dir"
        case Vec3Input.SkyZenith     => "zenith"
        case Vec3Input.SkyHorizon    => "horizon"
        case Vec3Input.SkyGround     => "ground"
        case Vec3Input.Albedo        => "albedo"
        case Vec3Input.Light         => "light"
        case Vec3Input.MetallicRoughness => "metalRough"
        case Vec3Input.EnvironmentColor     => "envColor"
        case Vec3Input.EnvironmentBoxMin    => "envBoxMin"
        case Vec3Input.EnvironmentBoxMax    => "envBoxMax"
        case Vec3Input.EnvironmentBoxCenter => "envBoxCenter"
        case Vec3Input.SunDirection         => "sunDir"
        case Vec3Input.SunColor             => "sunColor"
    }

    /// GLSL で画素ごとに関数の引数として受ける入力か（ほかは uniform）。
    def isPerPixel(input: Vec3Input): Bool = match input {
        case Vec3Input.Position      => true
        case Vec3Input.Normal        => true
        case Vec3Input.LightmapColor => true
        case Vec3Input.Color         => true
        case Vec3Input.SkyDirection  => true
        case Vec3Input.Eye           => false
        case Vec3Input.Ambient       => false
        case Vec3Input.FogColor      => false
        case Vec3Input.SkyZenith     => false
        case Vec3Input.SkyHorizon    => false
        case Vec3Input.SkyGround     => false
        case Vec3Input.Albedo        => true
        case Vec3Input.Light         => true
        case Vec3Input.MetallicRoughness => true
        case Vec3Input.EnvironmentColor     => true
        case Vec3Input.EnvironmentBoxMin    => false
        case Vec3Input.EnvironmentBoxMax    => false
        case Vec3Input.EnvironmentBoxCenter => false
        case Vec3Input.SunDirection         => false
        case Vec3Input.SunColor             => false
    }

    /// GLSL で入力を読む名前（画素ごとの入力は関数の引数の名前・ほかは uniform）。
    def glslUniformOf(input: Vec3Input): String = match input {
        case Vec3Input.Eye        => "uEye"
        case Vec3Input.Ambient    => "uAmbient"
        case Vec3Input.FogColor   => "uFogColor"
        case Vec3Input.SkyZenith  => "uZenith"
        case Vec3Input.SkyHorizon => "uHorizon"
        case Vec3Input.SkyGround  => "uGround"
        case Vec3Input.Position      => vec3InputName(input)
        case Vec3Input.Normal        => vec3InputName(input)
        case Vec3Input.LightmapColor => vec3InputName(input)
        case Vec3Input.Color         => vec3InputName(input)
        case Vec3Input.SkyDirection  => vec3InputName(input)
        case Vec3Input.Albedo        => vec3InputName(input)
        case Vec3Input.Light         => vec3InputName(input)
        case Vec3Input.MetallicRoughness => vec3InputName(input)
        case Vec3Input.EnvironmentColor     => vec3InputName(input)
        case Vec3Input.EnvironmentBoxMin    => "uEnvBoxMin"
        case Vec3Input.EnvironmentBoxMax    => "uEnvBoxMax"
        case Vec3Input.EnvironmentBoxCenter => "uEnvBoxCenter"
        case Vec3Input.SunDirection         => "uSunDir"
        case Vec3Input.SunColor             => "uSunColor"
    }

    def axisSuffix(t: Target, axis: Int32): String = match (t, axis) {
        case (Target.Flix, 0) => "X"
        case (Target.Flix, 1) => "Y"
        case (Target.Flix, _) => "Z"
        case (Target.Glsl, 0) => ".x"
        case (Target.Glsl, 1) => ".y"
        case (Target.Glsl, _) => ".z"
    }

    def vec3InputCode(t: Target, input: Vec3Input, axis: Int32): String = match t {
        case Target.Flix => vec3InputName(input) + axisSuffix(t, axis)
        case Target.Glsl => glslUniformOf(input) + axisSuffix(t, axis)
    }

    def lightOf(env: Env, what: String): LightKind = match env#light {
        case Some(kind) => kind
        case None       => bug!("LightModel3d: ${what} は SumPoints・SumSpots の中だけで読める")
    }

    def fieldRead(offset: Int32): String =
        if (offset == 0) "Vector.get(i, lights)" else "Vector.get(i + ${offset}, lights)"

    def glslVec3Field(kind: LightKind, field: Vec3LightField): String = match (kind, field) {
        case (LightKind.Point, Vec3LightField.Position) => "uPointPos[i]"
        case (LightKind.Point, Vec3LightField.Color)    => "uPointColor[i]"
        case (LightKind.Spot, Vec3LightField.Position)  => "uSpotPos[i]"
        case (LightKind.Spot, Vec3LightField.Direction) => "uSpotDir[i]"
        case (LightKind.Spot, Vec3LightField.Color)     => "uSpotColor[i]"
        case _                                          => bug!("LightModel3d: 点光源に向きは無い")
    }

    def glslScalarField(kind: LightKind, field: ScalarLightField): String = match (kind, field) {
        case (LightKind.Point, ScalarLightField.RangeSquared) => "(uPointRange[i] * uPointRange[i])"
        case (LightKind.Spot, ScalarLightField.RangeSquared)  => "(uSpotRange[i] * uSpotRange[i])"
        case (LightKind.Spot, ScalarLightField.OuterCos)      => "uSpotCone[i].x"
        case (LightKind.Spot, ScalarLightField.InnerCos)      => "uSpotCone[i].y"
        case _                                                => bug!("LightModel3d: 点光源に円錐の縁は無い")
    }

    def scalarFieldCode(t: Target, env: Env, field: ScalarLightField): String =
        let kind = lightOf(env, "光の欄");
        match t {
            case Target.Glsl => glslScalarField(kind, field)
            case Target.Flix => match scalarFieldOffset(kind, field) {
                case Some(offset) => fieldRead(offset)
                case None         => bug!("LightModel3d: この光に無い欄")
            }
        }

    def vec3FieldCode(t: Target, env: Env, field: Vec3LightField): (String, String, String) =
        let kind = lightOf(env, "光の欄");
        match t {
            case Target.Glsl =>
                let u = glslVec3Field(kind, field);
                ("${u}.x", "${u}.y", "${u}.z")
            case Target.Flix => match vec3FieldOffset(kind, field) {
                case Some(offset) => (fieldRead(offset), fieldRead(offset + 1), fieldRead(offset + 2))
                case None         => bug!("LightModel3d: この光に無い欄")
            }
        }

    def call1(t: Target, flixName: String, glslName: String, a: String): String = match t {
        case Target.Flix => "${flixName}(${a})"
        case Target.Glsl => "${glslName}(${a})"
    }

    def maxCode(t: Target, a: String, b: String): String = match t {
        case Target.Flix => "Float64.max(${a}, ${b})"
        case Target.Glsl => "max(${a}, ${b})"
    }

    def minCode(t: Target, a: String, b: String): String = match t {
        case Target.Flix => "Float64.min(${a}, ${b})"
        case Target.Glsl => "min(${a}, ${b})"
    }

    def srgbCode(t: Target, toLinear: Bool, a: String): String = match (t, toLinear) {
        case (Target.Flix, true)  => "Texture3d.srgbToLinear(${a})"
        case (Target.Flix, false) => "Texture3d.linearToSrgb(${a})"
        case (Target.Glsl, true)  => "r3d_srgbToLinear(${a})"
        case (Target.Glsl, false) => "r3d_linearToSrgb(${a})"
    }

    def selectCode(t: Target, c: String, a: String, b: String): String = match t {
        case Target.Flix => "(if (${c}) ${a} else ${b})"
        case Target.Glsl => "(${c} ? ${a} : ${b})"
    }

    def condCode(t: Target, fresh: Ref[(String, Int32), r], env: Env, c: Cond): (List[Stmt], String) \ r = match c {
        case Cond.Greater(a, b) => binary(t, fresh, env, a, b, (x, y) -> "(${x} > ${y})")
        case Cond.AtLeast(a, b) => binary(t, fresh, env, a, b, (x, y) -> "(${x} >= ${y})")
        case Cond.And(l, r) =>
            let (sl, cl) = condCode(t, fresh, env, l);
            let (sr, cr) = condCode(t, fresh, env, r);
            let op = match t {
                case Target.Flix => "and"
                case Target.Glsl => "&&"
            };
            // WhyNot: 右の文を左より前に流さない — 左が偽の時に右を計算しない約束が崩れる。右は文の要らない形だけを受ける。
            if (not List.isEmpty(sr)) bug!("LightModel3d: Cond.And の右に Let・文の要る Select は置けない")
            else (sl, "(${cl} ${op} ${cr})")
    }

    def binary(t: Target, fresh: Ref[(String, Int32), r], env: Env, a: ScalarExpr, b: ScalarExpr, f: (String, String) -> String): (List[Stmt], String) \ r =
        let (sa, ca) = scalarCode(t, fresh, env, a);
        let (sb, cb) = scalarCode(t, fresh, env, b);
        (sa ::: sb, f(ca, cb))

    def lookupScalar(env: Env, name: String): String = match Map.get(name, env#scalars) {
        case Some(code) => code
        case None       => bug!("LightModel3d: スカラーの名前 ${name} が束ねられていない")
    }

    def lookupVec3(env: Env, name: String): (String, String, String) = match Map.get(name, env#vecs) {
        case Some(code) => code
        case None       => bug!("LightModel3d: vec3 の名前 ${name} が束ねられていない")
    }

    def dotCode(x: (String, String, String), y: (String, String, String)): String =
        let (ax, ay, az) = x;
        let (bx, by, bz) = y;
        "(((${ax} * ${bx}) + (${ay} * ${by})) + (${az} * ${bz}))"

    /// 選ばない側を計算しない Select（どちらかの側に文があれば IfElse の文にする）。
    def chooseScalar(t: Target, fresh: Ref[(String, Int32), r], cond: (List[Stmt], String), yes: (List[Stmt], String), no: (List[Stmt], String)): (List[Stmt], String) \ r =
        let (sc, c) = cond;
        let (sy, y) = yes;
        let (sn, n) = no;
        if (List.isEmpty(sy) and List.isEmpty(sn)) (sc, selectCode(t, c, y, n))
        else {
            let name = freshName(fresh, "t");
            (sc ::: Stmt.IfElse(c, name :: Nil, sy, y :: Nil, sn, n :: Nil) :: Nil, name)
        }

    def scalarCode(t: Target, fresh: Ref[(String, Int32), r], env: Env, e: ScalarExpr): (List[Stmt], String) \ r = match e {
        case ScalarExpr.Num(x)        => (Nil, numLit(x))
        case ScalarExpr.In(input)     => (Nil, scalarInputCode(t, env, input))
        case ScalarExpr.LightField(f) => (Nil, scalarFieldCode(t, env, f))
        case ScalarExpr.Add(a, b)     => binary(t, fresh, env, a, b, (x, y) -> "(${x} + ${y})")
        case ScalarExpr.Sub(a, b)     => binary(t, fresh, env, a, b, (x, y) -> "(${x} - ${y})")
        case ScalarExpr.Mul(a, b)     => binary(t, fresh, env, a, b, (x, y) -> "(${x} * ${y})")
        case ScalarExpr.Div(a, b)     => binary(t, fresh, env, a, b, (x, y) -> "(${x} / ${y})")
        case ScalarExpr.Max(a, b)     => binary(t, fresh, env, a, b, (x, y) -> maxCode(t, x, y))
        case ScalarExpr.Min(a, b)     => binary(t, fresh, env, a, b, (x, y) -> minCode(t, x, y))
        case ScalarExpr.Pow(a, b)     => binary(t, fresh, env, a, b, (x, y) -> match t {
            case Target.Flix => "Float64.pow(base = ${x}, ${y})"
            case Target.Glsl => "pow(${x}, ${y})"
        })
        case ScalarExpr.Sqrt(a) =>
            let (sa, ca) = scalarCode(t, fresh, env, a);
            (sa, call1(t, "Num.sqrt", "sqrt", ca))
        case ScalarExpr.InverseSqrt(a) =>
            let (sa, ca) = scalarCode(t, fresh, env, a);
            (sa, match t {
                case Target.Flix => "(1.0 / Num.sqrt(${ca}))"
                case Target.Glsl => "inversesqrt(${ca})"
            })
        case ScalarExpr.Clamp01(a) =>
            let (sa, ca) = scalarCode(t, fresh, env, a);
            (sa, match t {
                case Target.Flix => "clamp01(${ca})"
                case Target.Glsl => "clamp(${ca}, 0.0, 1.0)"
            })
        case ScalarExpr.Smoothstep(lo, hi, x) =>
            let (sl, cl) = scalarCode(t, fresh, env, lo);
            let (sh, ch) = scalarCode(t, fresh, env, hi);
            let (sx, cx) = scalarCode(t, fresh, env, x);
            (sl ::: sh ::: sx, "smoothstep(${cl}, ${ch}, ${cx})")
        case ScalarExpr.Dot(a, b) =>
            let (sa, ca) = vec3Code(t, fresh, env, a);
            let (sb, cb) = vec3Code(t, fresh, env, b);
            (sa ::: sb, dotCode(ca, cb))
        case ScalarExpr.Length(a) =>
            let (sa, ca) = bindIfNotAtomic3(fresh, vec3Code(t, fresh, env, a));
            (sa, call1(t, "Num.sqrt", "sqrt", dotCode(ca, ca)))
        case ScalarExpr.X(a) => let (sa, (x, _, _)) = vec3Code(t, fresh, env, a); (sa, x)
        case ScalarExpr.Y(a) => let (sa, (_, y, _)) = vec3Code(t, fresh, env, a); (sa, y)
        case ScalarExpr.Z(a) => let (sa, (_, _, z)) = vec3Code(t, fresh, env, a); (sa, z)
        case ScalarExpr.Select(c, a, b) =>
            chooseScalar(t, fresh, condCode(t, fresh, env, c), scalarCode(t, fresh, env, a), scalarCode(t, fresh, env, b))
        case ScalarExpr.Let(name, v, body) =>
            let (sv, bindName) = bindScalar(t, fresh, env, name, v);
            let (sb, cb) = scalarCode(t, fresh, { scalars = Map.insert(name, bindName, env#scalars) | env }, body);
            (sv ::: sb, cb)
        case ScalarExpr.LetVec3(name, v, body) =>
            let (sv, names) = bindVec3(t, fresh, env, name, v);
            let (sb, cb) = scalarCode(t, fresh, { vecs = Map.insert(name, names, env#vecs) | env }, body);
            (sv ::: sb, cb)
        case ScalarExpr.Ref(name) => (Nil, lookupScalar(env, name))
    }

    def bindScalar(t: Target, fresh: Ref[(String, Int32), r], env: Env, name: String, v: ScalarExpr): (List[Stmt], String) \ r =
        let (sv, cv) = scalarCode(t, fresh, env, v);
        let bindName = freshName(fresh, checkedLetName(name));
        (sv ::: Stmt.Bind(bindName, cv) :: Nil, bindName)

    def bindVec3(t: Target, fresh: Ref[(String, Int32), r], env: Env, name: String, v: Vec3Expr): (List[Stmt], (String, String, String)) \ r =
        let (sv, (x, y, z)) = vec3Code(t, fresh, env, v);
        let base = freshName(fresh, checkedLetName(name));
        let (nx, ny, nz) = ("${base}X", "${base}Y", "${base}Z");
        (sv ::: Stmt.Bind(nx, x) :: Stmt.Bind(ny, y) :: Stmt.Bind(nz, z) :: Nil, (nx, ny, nz))

    def map3(f: String -> String, v: (String, String, String)): (String, String, String) =
        let (x, y, z) = v;
        (f(x), f(y), f(z))

    def zip3(f: (String, String) -> String, a: (String, String, String), b: (String, String, String)): (String, String, String) =
        let (ax, ay, az) = a;
        let (bx, by, bz) = b;
        (f(ax, bx), f(ay, by), f(az, bz))

    def pairwise(t: Target, fresh: Ref[(String, Int32), r], env: Env, a: Vec3Expr, b: Vec3Expr, f: (String, String) -> String): (List[Stmt], (String, String, String)) \ r =
        let (sa, ca) = vec3Code(t, fresh, env, a);
        let (sb, cb) = vec3Code(t, fresh, env, b);
        (sa ::: sb, zip3(f, ca, cb))

    def vec3Code(t: Target, fresh: Ref[(String, Int32), r], env: Env, e: Vec3Expr): (List[Stmt], (String, String, String)) \ r = match e {
        // WhyNot: 同じ木の成分を 1 つずつ書き下さない — Make(e, e, e) で e の計算（光のループならループごと）が成分の数だけ走る。
        case Vec3Expr.Make(a, b, c) =>
            let (sa, ca) = if (a == b or a == c) bindIfNotAtomic(fresh, scalarCode(t, fresh, env, a)) else scalarCode(t, fresh, env, a);
            let (sb, cb) = if (b == a) (Nil, ca) else if (b == c) bindIfNotAtomic(fresh, scalarCode(t, fresh, env, b)) else scalarCode(t, fresh, env, b);
            let (sc, cc) = if (c == a) (Nil, ca) else if (c == b) (Nil, cb) else scalarCode(t, fresh, env, c);
            (sa ::: sb ::: sc, (ca, cb, cc))
        case Vec3Expr.In(input) => (Nil, (vec3InputCode(t, input, 0), vec3InputCode(t, input, 1), vec3InputCode(t, input, 2)))
        case Vec3Expr.LightField(f) => (Nil, vec3FieldCode(t, env, f))
        case Vec3Expr.Add(a, b) => pairwise(t, fresh, env, a, b, (x, y) -> "(${x} + ${y})")
        case Vec3Expr.Sub(a, b) => pairwise(t, fresh, env, a, b, (x, y) -> "(${x} - ${y})")
        case Vec3Expr.Mul(a, b) => pairwise(t, fresh, env, a, b, (x, y) -> "(${x} * ${y})")
        case Vec3Expr.Max(a, b) => pairwise(t, fresh, env, a, b, (x, y) -> maxCode(t, x, y))
        case Vec3Expr.Min(a, b) => pairwise(t, fresh, env, a, b, (x, y) -> minCode(t, x, y))
        case Vec3Expr.Scale(v, s) =>
            let (sv, cv) = vec3Code(t, fresh, env, v);
            let (ss, cs) = bindIfNotAtomic(fresh, scalarCode(t, fresh, env, s));
            (sv ::: ss, map3(x -> "(${x} * ${cs})", cv))
        case Vec3Expr.Mix(a, b, s) =>
            let (sa, ca) = bindIfNotAtomic3(fresh, vec3Code(t, fresh, env, a));
            let (sb, cb) = vec3Code(t, fresh, env, b);
            let (ss, cs) = bindIfNotAtomic(fresh, scalarCode(t, fresh, env, s));
            (sa ::: sb ::: ss, zip3((x, y) -> "(${x} + ((${y} - ${x}) * ${cs}))", ca, cb))
        case Vec3Expr.SumPoints(body) => loopCode(t, fresh, env, LightKind.Point, body)
        case Vec3Expr.SumSpots(body)  => loopCode(t, fresh, env, LightKind.Spot, body)
        case Vec3Expr.Toon(v) =>
            match t {
                case Target.Flix =>
                    let (sv, cv) = vec3Code(t, fresh, env, v);
                    (sv, map3(x -> "toon(steps, ${x})", cv))
                case Target.Glsl =>
                    let (sv, cv) = bindIfNotAtomic3(fresh, vec3Code(t, fresh, env, v));
                    (sv, map3(x -> "(uToonSteps > 0 ? floor(${x} * float(uToonSteps) + 0.5) / float(uToonSteps) : ${x})", cv))
            }
        case Vec3Expr.SrgbToLinear(v) => let (sv, cv) = vec3Code(t, fresh, env, v); (sv, map3(x -> srgbCode(t, true, x), cv))
        case Vec3Expr.LinearToSrgb(v) => let (sv, cv) = vec3Code(t, fresh, env, v); (sv, map3(x -> srgbCode(t, false, x), cv))
        case Vec3Expr.Select(c, a, b) =>
            let (sc, cc) = condCode(t, fresh, env, c);
            let (sa, (ax, ay, az)) = vec3Code(t, fresh, env, a);
            let (sb, (bx, by, bz)) = vec3Code(t, fresh, env, b);
            let base = freshName(fresh, "t");
            let names = ("${base}X", "${base}Y", "${base}Z");
            let (nx, ny, nz) = names;
            // WhyNot: 文の無い両側を組（タプル）で選ばない — 画素ごとに組を 1 つ作ることになる。成分ごとに選べば作らない。
            if (List.isEmpty(sa) and List.isEmpty(sb)) {
                let cond = freshName(fresh, "c");
                let pick = (n: String, x: String, y: String) -> Stmt.Bind(n, selectCode(t, cond, x, y));
                (sc ::: Stmt.BindBool(cond, cc) :: pick(nx, ax, bx) :: pick(ny, ay, by) :: pick(nz, az, bz) :: Nil, names)
            }
            else (sc ::: Stmt.IfElse(cc, nx :: ny :: nz :: Nil, sa, ax :: ay :: az :: Nil, sb, bx :: by :: bz :: Nil) :: Nil, names)
        case Vec3Expr.Let(name, v, body) =>
            let (sv, names) = bindVec3(t, fresh, env, name, v);
            let (sb, cb) = vec3Code(t, fresh, { vecs = Map.insert(name, names, env#vecs) | env }, body);
            (sv ::: sb, cb)
        case Vec3Expr.LetScalar(name, v, body) =>
            let (sv, bindName) = bindScalar(t, fresh, env, name, v);
            let (sb, cb) = vec3Code(t, fresh, { scalars = Map.insert(name, bindName, env#scalars) | env }, body);
            (sv ::: sb, cb)
        case Vec3Expr.Ref(name) => (Nil, lookupVec3(env, name))
    }

    /// 光のループ。中の式は、入力と光の欄のほかに、外の Let の名前も読める（ループの外で 1 回だけ計算した値を、光の数だけ計算し直さない）。
    /// 外の名前のうち中の文が読む物は Stmt.Loop の captured に控える（GLSL は同じ関数の中なので名前のまま・CPU は引数で渡す）。
    /// 名前の数え始めは外と分ける。
    // WhyNot: ループの中の名前を外と続けて数えない — 同じ中身のループ（lightingModel と lightmapLightingModel の点光源）が同じ字になり、1 つの関数で済む。
    def loopCode(t: Target, fresh: Ref[(String, Int32), r], env: Env, kind: LightKind, body: Vec3Expr): (List[Stmt], (String, String, String)) \ r =
        if (Option.nonEmpty(env#light)) bug!("LightModel3d: 光のループの中に光のループは置けない")
        else region inner {
            let innerFresh = Ref.fresh(inner, ("l", 0));
            let innerEnv = { light = Some(kind), scalars = env#scalars, vecs = env#vecs | envFor(env#shadowFunction) };
            let (sb, (x, y, z)) = vec3Code(t, innerFresh, innerEnv, body);
            let read = namesReadBy(sb, x :: y :: z :: Nil);
            let captured = outerNamesOf(env) |> List.filter(n -> Set.memberOf(n, read));
            let base = freshName(fresh, match kind {
                case LightKind.Point => "points"
                case LightKind.Spot  => "spots"
            });
            let names = ("${base}X", "${base}Y", "${base}Z");
            let (nx, ny, nz) = names;
            (Stmt.Loop(kind, nx :: ny :: nz :: Nil, sb, x :: y :: z :: Nil, paramsOfVec3(body), captured) :: Nil, names)
        }

    /// 外の Let が生成した名前（スカラーはその名前・vec3 は X・Y・Z の 3 つ）。並びは名前の順。
    def outerNamesOf(env: Env): List[String] =
        let scalars = Map.toList(env#scalars) |> List.map(snd);
        let vecs = Map.toList(env#vecs) |> List.map(snd) |> List.flatMap(v -> { let (x, y, z) = v; x :: y :: z :: Nil });
        List.append(scalars, vecs) |> List.distinct |> List.sort

    // ── 使う引数 ─────────────────────────────────────────

    def paramsOfScalar(e: ScalarExpr): Set[Param] = match e {
        case ScalarExpr.Num(_)                => Set.empty()
        case ScalarExpr.In(ScalarInput.ShadowLit) => Set#{ Param.Shadow, Param.Vec3Param(Vec3Input.Position) }
        case ScalarExpr.In(input)             => Set#{ Param.ScalarParam(input) }
        case ScalarExpr.LightField(_)         => Set.empty()
        case ScalarExpr.Add(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Sub(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Mul(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Div(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Max(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Min(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Pow(a, b)             => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case ScalarExpr.Sqrt(a)               => paramsOfScalar(a)
        case ScalarExpr.InverseSqrt(a)        => paramsOfScalar(a)
        case ScalarExpr.Clamp01(a)            => paramsOfScalar(a)
        case ScalarExpr.Smoothstep(a, b, c)   => Set.union(paramsOfScalar(a), Set.union(paramsOfScalar(b), paramsOfScalar(c)))
        case ScalarExpr.Dot(a, b)             => Set.union(paramsOfVec3(a), paramsOfVec3(b))
        case ScalarExpr.Length(a)             => paramsOfVec3(a)
        case ScalarExpr.X(a)                  => paramsOfVec3(a)
        case ScalarExpr.Y(a)                  => paramsOfVec3(a)
        case ScalarExpr.Z(a)                  => paramsOfVec3(a)
        case ScalarExpr.Select(c, a, b)       => Set.union(paramsOfCond(c), Set.union(paramsOfScalar(a), paramsOfScalar(b)))
        case ScalarExpr.Let(_, v, body)       => Set.union(paramsOfScalar(v), paramsOfScalar(body))
        case ScalarExpr.LetVec3(_, v, body)   => Set.union(paramsOfVec3(v), paramsOfScalar(body))
        case ScalarExpr.Ref(_)                => Set.empty()
    }

    def paramsOfCond(c: Cond): Set[Param] = match c {
        case Cond.Greater(a, b) => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case Cond.AtLeast(a, b) => Set.union(paramsOfScalar(a), paramsOfScalar(b))
        case Cond.And(a, b)    => Set.union(paramsOfCond(a), paramsOfCond(b))
    }

    def paramsOfVec3(e: Vec3Expr): Set[Param] = match e {
        case Vec3Expr.Make(a, b, c)         => Set.union(paramsOfScalar(a), Set.union(paramsOfScalar(b), paramsOfScalar(c)))
        case Vec3Expr.In(input)             => Set#{ Param.Vec3Param(input) }
        case Vec3Expr.LightField(_)         => Set.empty()
        case Vec3Expr.Add(a, b)             => Set.union(paramsOfVec3(a), paramsOfVec3(b))
        case Vec3Expr.Sub(a, b)             => Set.union(paramsOfVec3(a), paramsOfVec3(b))
        case Vec3Expr.Mul(a, b)             => Set.union(paramsOfVec3(a), paramsOfVec3(b))
        case Vec3Expr.Max(a, b)             => Set.union(paramsOfVec3(a), paramsOfVec3(b))
        case Vec3Expr.Min(a, b)             => Set.union(paramsOfVec3(a), paramsOfVec3(b))
        case Vec3Expr.Scale(v, s)           => Set.union(paramsOfVec3(v), paramsOfScalar(s))
        case Vec3Expr.Mix(a, b, s)          => Set.union(paramsOfVec3(a), Set.union(paramsOfVec3(b), paramsOfScalar(s)))
        case Vec3Expr.SumPoints(body)       => Set.insert(Param.Points, paramsOfVec3(body))
        case Vec3Expr.SumSpots(body)        => Set.insert(Param.Spots, paramsOfVec3(body))
        case Vec3Expr.Toon(v)               => Set.insert(Param.Steps, paramsOfVec3(v))
        case Vec3Expr.SrgbToLinear(v)       => paramsOfVec3(v)
        case Vec3Expr.LinearToSrgb(v)       => paramsOfVec3(v)
        case Vec3Expr.Select(c, a, b)       => Set.union(paramsOfCond(c), Set.union(paramsOfVec3(a), paramsOfVec3(b)))
        case Vec3Expr.Let(_, v, body)       => Set.union(paramsOfVec3(v), paramsOfVec3(body))
        case Vec3Expr.LetScalar(_, v, body) => Set.union(paramsOfScalar(v), paramsOfVec3(body))
        case Vec3Expr.Ref(_)                => Set.empty()
    }

    // ════════════════════════════════════════════════════════
    // 使わない文を落とす（2 つの出口が共に使う）
    // ════════════════════════════════════════════════════════

    /// 文の並び stmts のうち、後ろ（と live の名前）で使われない名前だけを束ねる文を落とす。組で受ける名前のうち使わない物は `_` を付ける。
    // WhyNot: 落とさずにそのまま書く — vec3 の Let・Select・光のループはいつも x・y・z の 3 つを束ねるので、1 成分だけ使う木で
    //   使わない局所変数ができ、Flix がそれを止めて生成物が組めなくなる。
    def pruneStmts(stmts: List[Stmt], live: Set[String]): List[Stmt] =
        let (kept, _) = List.foldRight((s, acc) -> {
            let (out, used) = acc;
            match pruneStmt(s, used) {
                case Some((s1, needs)) => (s1 :: out, Set.union(needs, used))
                case None              => acc
            }
        }, (Nil, live), stmts);
        kept

    /// 文 s を残すなら (直した文, その文が読む名前)。
    def pruneStmt(s: Stmt, used: Set[String]): Option[(Stmt, Set[String])] = match s {
        case Stmt.Bind(name, e) =>
            if (Set.memberOf(name, used)) Some((s, identifiersIn(e))) else None
        case Stmt.BindBool(name, e) =>
            if (Set.memberOf(name, used)) Some((s, identifiersIn(e))) else None
        case Stmt.IfElse(c, names, yesStmts, yesVals, noStmts, noVals) =>
            if (not List.exists(n -> Set.memberOf(n, used), names)) None
            else {
                let yes = pruneStmts(yesStmts, identifiersInAll(yesVals));
                let no = pruneStmts(noStmts, identifiersInAll(noVals));
                let needs = Set.union(identifiersIn(c), Set.union(namesReadBy(yes, yesVals), namesReadBy(no, noVals)));
                Some((Stmt.IfElse(c, markUnused(used, names), yes, yesVals, no, noVals), needs))
            }
        case Stmt.Loop(kind, names, bodyStmts, vals, params, captured) =>
            if (not List.exists(n -> Set.memberOf(n, used), names)) None
            else {
                let body = pruneStmts(bodyStmts, identifiersInAll(vals));
                Some((Stmt.Loop(kind, markUnused(used, names), body, vals, params, captured), List.toSet(captured)))
            }
    }

    def markUnused(used: Set[String], names: List[String]): List[String] =
        names |> List.map(n -> if (Set.memberOf(n, used)) n else "_${n}")

    def identifiersInAll(codes: List[String]): Set[String] =
        codes |> List.foldLeft((acc, c) -> Set.union(identifiersIn(c), acc), Set.empty())

    /// 文の並びと値が読む名前（並びの中で束ねた名前も含む。外で束ねた名前を消さないので多めに数える）。
    def namesReadBy(stmts: List[Stmt], vals: List[String]): Set[String] =
        stmts |> List.foldLeft((acc, s) -> Set.union(stmtReads(s), acc), identifiersInAll(vals))

    def stmtReads(s: Stmt): Set[String] = match s {
        case Stmt.Bind(_, e)     => identifiersIn(e)
        case Stmt.BindBool(_, e) => identifiersIn(e)
        case Stmt.IfElse(c, _, yesStmts, yesVals, noStmts, noVals) =>
            Set.union(identifiersIn(c), Set.union(namesReadBy(yesStmts, yesVals), namesReadBy(noStmts, noVals)))
        case Stmt.Loop(_, _, _, _, _, captured) => List.toSet(captured)
    }

    // ════════════════════════════════════════════════════════
    // Flix の出口（CPU の描き手）
    // ════════════════════════════════════════════════════════

    /// 生成する CPU の光の関数が呼ぶ engine_tools の名前（影の地図の型と、地図・スポットの並びの位置・world の点 → 影の割合の関数）。
    // WhyNot: 影の割合を関数の値（クロージャ）で渡さない — Flix の関数の値は Float64 を箱に入れて呼ぶので、画素 × スポットの数だけ重くなる
    //   （影を落とす場面で 1 スレッドの時間が約 1 割増えた）。生成した字は engine_tools の中でだけ組むので、名前で直に呼ぶ。
    /// shadowFunction は (shadow, スポットの並びの欄の位置（スポットの番号 × LightModel3d.spotStride()）, px, py, pz) -> Float64 の関数の名前。
    pub type alias CpuHooks = { shadowType = String, shadowFunction = String }

    /// CPU の描き手が使う関数（生成するファイルの並びの順）。params = 引数の並び（引数の順はこの並びで決まり、enum の宣言の順に頼らない）。
    type alias CpuEntry = { name = String, model = Vec3Expr, doc = String, params = List[Param] }

    def cpuEntries(): List[CpuEntry] =
        let p = Param.Vec3Param(Vec3Input.Position);
        let n = Param.Vec3Param(Vec3Input.Normal);
        let lights = Param.Steps :: Param.Points :: Param.Spots :: Param.Shadow :: p :: n :: Nil;
        let sun = Param.Vec3Param(Vec3Input.SunDirection) :: Param.Vec3Param(Vec3Input.SunColor) :: Param.ScalarParam(ScalarInput.SunLit) :: Nil;
        { name = "lightAt", model = lightingModel(), doc = "lightingModel の光の量（toon の丸めまで済ませた値。sunLit = 太陽の影の割合）。",
          params = lights ::: Param.Vec3Param(Vec3Input.Ambient) :: Param.ScalarParam(ScalarInput.Hemisphere) :: sun } ::
        { name = "lightmapLightAt", model = lightmapLightingModel(), doc = "lightmapLightingModel の光の量（lightmap は段つきで読んだ後の rgb を渡す）。",
          params = lights ::: Param.Vec3Param(Vec3Input.LightmapColor) :: Param.ScalarParam(ScalarInput.LightmapSrgb) ::
                   Param.ScalarParam(ScalarInput.LightmapIntensity) :: Nil } ::
        { name = "fogAt", model = fogModel(), doc = "fogModel の色（fog が無い場面では呼ばない）。",
          params = p :: Param.Vec3Param(Vec3Input.Eye) :: Param.Vec3Param(Vec3Input.Color) :: Param.Vec3Param(Vec3Input.FogColor) ::
                   Param.ScalarParam(ScalarInput.FogNear) :: Param.ScalarParam(ScalarInput.FogFar) :: Nil } ::
        { name = "skyAt", model = skyModel(), doc = "skyModel の空の色。",
          params = Param.Vec3Param(Vec3Input.SkyDirection) :: Param.Vec3Param(Vec3Input.SkyZenith) :: Param.Vec3Param(Vec3Input.SkyHorizon) ::
                   Param.Vec3Param(Vec3Input.SkyGround) :: Param.ScalarParam(ScalarInput.SkyCurve) :: Nil } ::
        { name = "pbrAt", model = pbrModel(), doc = "pbrModel の、かすみの前の色（light = lightAt か lightmapLightAt の値・metalRough の x = metallic・y = roughness・z は使わない）。",
          params = Param.Points :: Param.Spots :: Param.Shadow :: p :: n :: Param.Vec3Param(Vec3Input.Albedo) :: Param.Vec3Param(Vec3Input.Light) ::
                   Param.Vec3Param(Vec3Input.MetallicRoughness) :: Param.Vec3Param(Vec3Input.Eye) :: Param.Vec3Param(Vec3Input.SkyZenith) ::
                   Param.Vec3Param(Vec3Input.SkyHorizon) :: Param.Vec3Param(Vec3Input.SkyGround) :: Param.ScalarParam(ScalarInput.SkyCurve) ::
                   Param.Vec3Param(Vec3Input.EnvironmentColor) :: Param.ScalarParam(ScalarInput.EnvironmentOn) :: sun } ::
        { name = "environmentDirectionAt", model = environmentDirection(),
          doc = "environmentDirection の、環境マップを読む向き（長さ 1。metalRough の x は使わない）。",
          params = p :: n :: Param.Vec3Param(Vec3Input.Albedo) :: Param.Vec3Param(Vec3Input.MetallicRoughness) :: Param.Vec3Param(Vec3Input.Eye) ::
                   Param.Vec3Param(Vec3Input.EnvironmentBoxMin) :: Param.Vec3Param(Vec3Input.EnvironmentBoxMax) ::
                   Param.Vec3Param(Vec3Input.EnvironmentBoxCenter) :: Param.ScalarParam(ScalarInput.EnvironmentBoxOn) :: Nil } :: Nil

    /// 生成した CPU の光の関数（engine_tools の gen/SoftRaster3dLight.flix）のソースの全部（engine の開発用。ゲームは使わない）。
    /// 光の種類ごと（点光源の輪・スポットの輪）に関数を分けて出す。
    // WhyNot: 1 つの関数に全部を書き下さない — 長い 1 本の式は Flix の型推論が崩れる。
    pub def generateFlix(hooks: CpuHooks): String =
        generateFlixOf(hooks, { module = "SoftRaster3dLight", origin = "LightModel3d.Codegen.generateFlix",
                                about = "3D の光の式（LightModel3d の木）を CPU の描き手が画素ごとに回す関数（engine の中で使う。ゲームは使わない）。\n" +
                                        "/// 光の並びは LightModel3d.packPointLights・packSpotLights の形。shadow = 影を落とすスポット（${hooks#shadowType}）。" }, cpuEntries())

    /// 生成器のエッジケース（1 成分だけ使う Let・引数を読まない光のループ・同じエントリの 2 つのループ・文のある枝の Select・エントリに書いた引数の順）を
    /// 集めた確かめ用のソース（engine_tools の test/gen/SoftRaster3dLightCases.flix。engine の開発用）。
    // WhyNot: 字の一部だけをテストで見て済ませない — 組めない字（空の引数の並びなど）は字の一部の比べでは見つからない。テストの作業場で組ませて確かめる。
    pub def generateFlixCases(hooks: CpuHooks): String =
        generateFlixOf(hooks, { module = "SoftRaster3dLightCases", origin = "LightModel3d.Codegen.generateFlixCases",
                                about = "生成器のエッジケースが組める字になることを、テストの作業場で組んで確かめる。" }, caseEntries())

    /// 生成するファイルの mod の名前・作った関数の名前・mod の doc。
    type alias FlixModule = { module = String, origin = String, about = String }

    def generateFlixOf(hooks: CpuHooks, m: FlixModule, entries: List[CpuEntry]): String = region rc {
        let loops: Ref[List[(String, String, String)], rc] = Ref.fresh(rc, Nil);
        let defs = entries |> List.map(entry -> flixEntry(rc, hooks, loops, entry));
        let loopList = Ref.get(loops) |> List.reverse;
        let loopDefs = loopList |> List.map(l -> { let (_, _, text) = l; text });
        let entryNames = entries |> List.map(e -> e#name) |> List.toSet;
        let clash = loopList |> List.map(l -> { let (_, n, _) = l; n }) |> List.find(n -> Set.memberOf(n, entryNames));
        let body = List.join("\n", defs ::: loopDefs);
        match clash {
            case Some(n) => bug!("LightModel3d: ループの関数の名前 ${n} がエントリの名前とぶつかる（エントリの名前を替える）")
            case None    => flixHeader(m) + flixHelpers(identifiersIn(withoutDocLines(body))) + body + "}\n"
        }
    }

    def caseEntries(): List[CpuEntry] =
        let n = Vec3Expr.In(Vec3Input.Normal);
        let y = ScalarExpr.Y(n);
        let splat = (e: ScalarExpr) -> Vec3Expr.Make(e, e, e);
        let normalOnly = Param.Vec3Param(Vec3Input.Normal) :: Nil;
        let color = Vec3Expr.LightField(Vec3LightField.Color);
        { name = "oneComponentLet", doc = "y だけ使う vec3 の Let。", params = normalOnly,
          model = Vec3Expr.Let("v", Vec3Expr.Add(n, n), splat(ScalarExpr.Y(Vec3Expr.Ref("v")))) } ::
        { name = "loopWithoutParams", doc = "引数を読まず x だけ使う光のループ。", params = Param.Points :: Nil,
          model = splat(ScalarExpr.X(Vec3Expr.SumPoints(color))) } ::
        { name = "twoLoops", doc = "同じエントリの中身の違う 2 つのループ。", params = Param.Points :: Nil,
          model = Vec3Expr.Add(Vec3Expr.SumPoints(Vec3Expr.Scale(color, ScalarExpr.Num(2.0))), Vec3Expr.SumPoints(color)) } ::
        { name = "scalarBranchWithLet", doc = "枝に Let のあるスカラーの Select。", params = normalOnly,
          model = splat(ScalarExpr.Select(Cond.Greater(y, ScalarExpr.Num(0.0)),
                                          ScalarExpr.Let("a", ScalarExpr.Mul(y, y), ScalarExpr.Add(ScalarExpr.Ref("a"), ScalarExpr.Ref("a"))),
                                          ScalarExpr.Num(0.0))) } ::
        { name = "vec3BranchWithLet", doc = "枝に Let のある vec3 の Select。", params = normalOnly,
          model = Vec3Expr.Select(Cond.Greater(y, ScalarExpr.Num(0.0)), Vec3Expr.Let("w", Vec3Expr.Add(n, n), Vec3Expr.Ref("w")), n) } ::
        { name = "declaredOrder", doc = "エントリに書いた引数の順（法線が先）。値は 点 − 法線。",
          params = Param.Vec3Param(Vec3Input.Normal) :: Param.Vec3Param(Vec3Input.Position) :: Nil,
          model = Vec3Expr.Sub(Vec3Expr.In(Vec3Input.Position), n) } ::
        { name = "sameComponents", doc = "成分が同じ名前でも数でもない式の Make（1 回だけ計算する）と負の数。", params = normalOnly,
          model = splat(ScalarExpr.Mul(ScalarExpr.Mul(y, y), ScalarExpr.Num(-2.0))) } ::
        { name = "spotFields", doc = "スポットのループで読む欄（外の cos・内の cos・range²・color）と toon。",
          params = Param.Steps :: Param.Spots :: Nil,
          model = Vec3Expr.Toon(Vec3Expr.SumSpots(Vec3Expr.Scale(color, ScalarExpr.Add(ScalarExpr.Add(ScalarExpr.LightField(ScalarLightField.OuterCos),
                                                                                                          ScalarExpr.LightField(ScalarLightField.InnerCos)),
                                                                                           ScalarExpr.LightField(ScalarLightField.RangeSquared))))) } :: Nil

    def flixHeader(m: FlixModule): String =
        "// ${m#module} — 生成した物（${m#origin}）。手で直さない。直すのは LightModel3d の木で、\n" +
        "// `make gen-light3d` で作り直す（入っている物と作り直した物が同じことは engine_tools の TestSoftRaster3dLight が確かめる）。\n" +
        "\n" +
        "/// ${m#about}\n" +
        "pub mod ${m#module} {\n" +
        "\n"

    /// 字から doc の行（///）を除いた物。
    def withoutDocLines(text: String): String =
        String.lines(text) |> List.filter(l -> not String.startsWith(prefix = "///", String.trim(l))) |> List.join("\n")

    /// 生成した関数が呼ぶ小さな関数（使う物だけ。Flix は使わない def を止める）。
    def flixHelpers(used: Set[String]): String =
        let smooth = Set.memberOf("smoothstep", used);
        (if (smooth or Set.memberOf("clamp01", used)) "    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))\n\n" else "") +
        (if (smooth)
            "    def smoothstep(lo: Float64, hi: Float64, x: Float64): Float64 =\n" +
            "        let t = if (hi == lo) (if (x >= hi) 1.0 else 0.0) else clamp01((x - lo) / (hi - lo));\n" +
            "        t * t * (3.0 - 2.0 * t)\n\n"
         else "") +
        (if (Set.memberOf("toon", used))
            "    def toon(steps: Int32, x: Float64): Float64 =\n" +
            "        if (steps <= 0) x\n" +
            "        else {\n" +
            "            let s = Int32.toFloat64(steps);\n" +
            "            Float64.floor(x * s + 0.5) / s\n" +
            "        }\n\n"
         else "")

    /// 引数の型の字。
    def flixParamType(hooks: CpuHooks, p: Param): String = match p {
        case Param.Steps    => "Int32"
        case Param.Points   => "Vector[Float64]"
        case Param.Spots    => "Vector[Float64]"
        case Param.Shadow   => hooks#shadowType
        case Param.Vec3Param(_)   => "Float64"
        case Param.ScalarParam(_) => "Float64"
    }

    def flixParamNames(p: Param): List[String] = match p {
        case Param.Steps    => "steps" :: Nil
        case Param.Points   => "points" :: Nil
        case Param.Spots    => "spots" :: Nil
        case Param.Shadow   => "shadow" :: Nil
        case Param.Vec3Param(input) => let n = vec3InputName(input); "${n}X" :: "${n}Y" :: "${n}Z" :: Nil
        case Param.ScalarParam(input) => scalarInputName(input) :: Nil
    }

    /// 引数の宣言の字。body に出てこない名前は `_` を付ける（Flix は使わない引数を止める）。
    def flixParamList(hooks: CpuHooks, params: List[Param], body: String): String =
        List.join(", ", flixParamDecls(hooks, params, body))

    def flixParamDecls(hooks: CpuHooks, params: List[Param], body: String): List[String] =
        let used = identifiersIn(body);
        params |> List.flatMap(p -> flixParamNames(p) |> List.map(n -> {
            let shown = if (Set.memberOf(n, used)) n else "_${n}";
            "${shown}: ${flixParamType(hooks, p)}"
        }))

    /// 木 e が読む入力が、エントリの引数の並び declared に全部あるか（無ければ止める）。
    def checkedParams(name: String, declared: List[Param], e: Vec3Expr): List[Param] =
        let declaredSet = List.toSet(declared);
        let missing = paramsOfVec3(e) |> Set.toList |> List.filter(p -> not Set.memberOf(p, declaredSet));
        if (List.isEmpty(missing)) declared else bug!("LightModel3d: ${name} の木が引数の並びに無い入力を読む（${List.length(missing)} 個）")

    def flixEntry(rc: Region[r], hooks: CpuHooks, loops: Ref[List[(String, String, String)], r], entry: CpuEntry): String \ r =
        let params = checkedParams(entry#name, entry#params, entry#model);
        let fresh = Ref.fresh(rc, ("", 0));
        let (stmts, (x, y, z)) = vec3Code(Target.Flix, fresh, envFor(hooks#shadowFunction), entry#model);
        let kept = pruneStmts(stmts, identifiersInAll(x :: y :: z :: Nil));
        let body = flixStmts(rc, hooks, loops, entry, 2, kept) + "        (${x}, ${y}, ${z})\n";
        "    /// ${entry#doc}\n" +
        "    pub def ${entry#name}(${flixParamList(hooks, params, body)}): (Float64, Float64, Float64) =\n" + body

    def indent(depth: Int32): String = String.repeat(depth * 4, " ")

    def flixStmts(rc: Region[r], hooks: CpuHooks, loops: Ref[List[(String, String, String)], r], entry: CpuEntry, depth: Int32, stmts: List[Stmt]): String \ r =
        stmts |> List.map(s -> flixStmt(rc, hooks, loops, entry, depth, s)) |> List.join("")

    def flixStmt(rc: Region[r], hooks: CpuHooks, loops: Ref[List[(String, String, String)], r], entry: CpuEntry, depth: Int32, s: Stmt): String \ r =
        let pad = indent(depth);
        match s {
            case Stmt.Bind(name, e) => "${pad}let ${name} = ${e};\n"
            case Stmt.BindBool(name, e) => "${pad}let ${name} = ${e};\n"
            // WhyNot: 文のある枝を成分ごとの if に分けない — 枝の文を成分の数だけ書き写すことになる。組は文のある枝の時だけ作る。
            case Stmt.IfElse(c, names, yesStmts, yesVals, noStmts, noVals) =>
                let branch = (bs: List[Stmt], vals: List[String]) ->
                    "{\n" + flixStmts(rc, hooks, loops, entry, depth + 1, bs) + indent(depth + 1) + tupleOf(vals) + "\n${pad}}";
                "${pad}let ${tupleOf(names)} = if (${c}) ${branch(yesStmts, yesVals)} else ${branch(noStmts, noVals)};\n"
            case Stmt.Loop(kind, names, bodyStmts, vals, used, captured) =>
                let params = entry#params |> List.filter(p -> Set.memberOf(p, used));
                let fname = flixLoopDef(rc, hooks, loops, entry, kind, bodyStmts, vals, params, captured);
                let lightsArg = match kind {
                    case LightKind.Point => "points"
                    case LightKind.Spot  => "spots"
                };
                let args = (lightsArg :: "0" :: List.flatMap(flixParamNames, params)) ::: captured ::: ("0.0" :: "0.0" :: "0.0" :: Nil);
                "${pad}let ${tupleOf(names)} = ${fname}(${List.join(", ", args)});\n"
        }

    def tupleOf(names: List[String]): String = match names {
        case one :: Nil => one
        case _          => "(" + List.join(", ", names) + ")"
    }

    /// 光のループの関数の名前（同じ中身のループが前にあれば、その名前）。
    def flixLoopDef(rc: Region[r], hooks: CpuHooks, loops: Ref[List[(String, String, String)], r], entry: CpuEntry, kind: LightKind,
                    bodyStmts: List[Stmt], vals: List[String], params: List[Param], captured: List[String]): String \ r =
        let suffix = match kind {
            case LightKind.Point => "Points"
            case LightKind.Spot  => "Spots"
        };
        let taken = Ref.get(loops) |> List.map(l -> { let (_, n, _) = l; n }) |> List.toSet;
        let base = entry#name + suffix;
        let proposed = if (not Set.memberOf(base, taken)) base
            else List.range(2, Set.size(taken) + 3) |> List.map(k -> "${base}${k}") |> List.find(c -> not Set.memberOf(c, taken))
                                                    |> Option.getWithDefault(base);
        let render = (fname: String) -> {
            let stride = strideOf(kind);
            let args = List.flatMap(flixParamNames, params);
            let (x, y, z) = match vals {
                case a :: b :: c :: Nil => (a, b, c)
                case _                  => bug!("LightModel3d: ループの値は 3 つ")
            };
            let inner = flixStmts(rc, hooks, loops, entry, 3, bodyStmts) +
                "            ${fname}(${List.join(", ", ("lights" :: "i + ${stride}" :: args) ::: captured ::: ("(accX + ${x})" :: "(accY + ${y})" :: "(accZ + ${z})" :: Nil))})\n";
            let decls = ("lights: Vector[Float64]" :: "i: Int32" :: flixParamDecls(hooks, params, inner)) ::: (captured |> List.map(n -> "${n}: Float64"))
                ::: ("accX: Float64" :: "accY: Float64" :: "accZ: Float64" :: Nil);
            "    def ${fname}(${List.join(", ", decls)}): (Float64, Float64, Float64) =\n" +
            "        if (i + ${stride} > Vector.length(lights)) (accX, accY, accZ)\n" +
            "        else {\n" + inner + "        }\n"
        };
        let key = render("LOOP");
        match List.find(l -> { let (k, _, _) = l; k == key }, Ref.get(loops)) {
            case Some((_, existing, _)) => existing
            case None =>
                Ref.put((key, proposed, render(proposed)) :: Ref.get(loops), loops);
                proposed
        }

    /// 字に出てくる名前（英数字と _ の続き）の集まり。
    def identifiersIn(text: String): Set[String] =
        let isPart = (c: Char) -> Char.isLetter(c) or Char.isDigit(c) or c == '_';
        let (done, current) = String.toList(text) |> List.foldLeft((acc, c) -> {
            let (found, word) = acc;
            if (isPart(c)) (found, c :: word)
            else if (List.isEmpty(word)) acc
            else (Set.insert(List.reverse(word) |> List.join(""), found), Nil)
        }, (Set.empty(), Nil));
        if (List.isEmpty(current)) done else Set.insert(List.reverse(current) |> List.join(""), done)

    // ════════════════════════════════════════════════════════
    // GLSL の出口
    // ════════════════════════════════════════════════════════

    /// 式 e を GLSL の関数 `vec3 name(…)` に生成した字。画素ごとの入力（点・法線・lightmap の色・かすみの前の色・空の向き・albedo・拡散の光・metallic と roughness）は
    /// 引数（p・n・lightmap・color・dir・albedo・light・metalRough）で受け、ほかは Render3dGlsl が宣言する uniform の名前（uAmbient・uPointPos の i 番目など）で読む。
    /// 光のループは Scene3d.maxPointLights()・maxSpotLights() 回の for で、uPointCount・uSpotCount で抜ける。
    /// 影は spotShadow(i, p)、lightmap の色の空間は r3d_srgbToLinear・r3d_linearToSrgb（float → float の関数。Texture3d.srgbToLinearGlsl・linearToSrgbGlsl で作る）を呼ぶ。engine の開発用（ゲームは使わない）。
    /// perPixel = 関数の引数の並び（引数の順はこの並びで決まり、enum の宣言の順に頼らない。木が読む画素ごとの入力が無ければ止める）。
    // WhyNot: 画素ごとの入力の読み方（varying か、確かめ用の絵の texelFetch か）を引数で選ばせない — 画素ごとの入力は関数の引数なので、
    //   呼ぶ側の main が varying でも texelFetch した値でも渡せる。
    pub def toGlsl(name: String, perPixel: List[Vec3Input], e: Vec3Expr): String = region rc {
        let fresh = Ref.fresh(rc, ("", 0));
        let (stmts, (x, y, z)) = vec3Code(Target.Glsl, fresh, envFor(""), e);
        let kept = pruneStmts(stmts, identifiersInAll(x :: y :: z :: Nil));
        let perPixelSet = List.toSet(perPixel);
        let missing = paramsOfVec3(e) |> Set.toList |> List.filter(p -> match p {
            case Param.Vec3Param(input) => isPerPixel(input) and not Set.memberOf(input, perPixelSet)
            case _                      => false
        });
        let params = perPixel |> List.map(input -> "vec3 ${vec3InputName(input)}");
        if (not List.isEmpty(missing)) bug!("LightModel3d: ${name} の木が引数の並びに無い画素ごとの入力を読む")
        else if (List.exists(input -> not isPerPixel(input), perPixel)) bug!("LightModel3d: ${name} の引数の並びに uniform で読む入力がある")
        else "vec3 ${name}(${List.join(", ", params)}) {\n" + glslStmts(1, kept) + "    return vec3(${x}, ${y}, ${z});\n}\n"
    }

    def glslStmts(depth: Int32, stmts: List[Stmt]): String =
        stmts |> List.map(glslStmt(depth)) |> List.join("")

    def glslStmt(depth: Int32, s: Stmt): String =
        let pad = indent(depth);
        match s {
            case Stmt.Bind(name, e) => "${pad}float ${name} = ${e};\n"
            case Stmt.BindBool(name, e) => "${pad}bool ${name} = ${e};\n"
            case Stmt.IfElse(c, names, yesStmts, yesVals, noStmts, noVals) =>
                let assign = (vals: List[String]) -> List.zip(names, vals) |> List.map(pair -> "${indent(depth + 1)}${fst(pair)} = ${snd(pair)};\n") |> List.join("");
                (names |> List.map(n -> "${pad}float ${n};\n") |> List.join("")) +
                "${pad}if (${c}) {\n" + glslStmts(depth + 1, yesStmts) + assign(yesVals) +
                "${pad}} else {\n" + glslStmts(depth + 1, noStmts) + assign(noVals) + "${pad}}\n"
            case Stmt.Loop(kind, names, bodyStmts, vals, _, _) =>
                let (count, limit) = match kind {
                    case LightKind.Point => ("uPointCount", Scene3d.maxPointLights())
                    case LightKind.Spot  => ("uSpotCount", Scene3d.maxSpotLights())
                };
                let accumulate = List.zip(names, vals) |> List.map(pair -> "${indent(depth + 1)}${fst(pair)} = ${fst(pair)} + ${snd(pair)};\n") |> List.join("");
                (names |> List.map(n -> "${pad}float ${n} = 0.0;\n") |> List.join("")) +
                "${pad}for (int i = 0; i < ${limit}; i++) {\n" +
                "${indent(depth + 1)}if (i >= ${count}) break;\n" +
                glslStmts(depth + 1, bodyStmts) + accumulate + "${pad}}\n"
        }
}
