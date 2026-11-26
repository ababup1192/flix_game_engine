// ShaderAst.Glsl — ShaderAst の木を GLSL（330 core・GLSL ES 3.00 へ写す前の字）へ出す。
pub mod ShaderAst.Glsl {
    use ShaderAst.{Node, Stmt, Def, Ty, BuiltinFn, Layout, Intrinsic, Lang, Expr, Definition}

    /// 型の字。
    pub def tyName(t: Ty): String = match t {
        case Ty.F32            => "float"
        case Ty.I32            => "int"
        case Ty.U32            => "uint"
        case Ty.Bool           => "bool"
        case Ty.Vec2           => "vec2"
        case Ty.Vec3           => "vec3"
        case Ty.Vec4           => "vec4"
        case Ty.IVec2          => "ivec2"
        case Ty.IVec4          => "ivec4"
        case Ty.Mat3           => "mat3"
        case Ty.Mat4           => "mat4"
        case Ty.Texture2d      => "sampler2D"
        case Ty.DepthTexture2d => "sampler2D"
        case Ty.Sampler        => ShaderAst.invalidOrBug("ShaderAst.Glsl: sampler は GLSL に無い")
        case Ty.Void           => "void"
    }

    /// 組み込みの関数の名前（言語ごとに引数の違う TextureSize・TargetDepthTexel は builtin が書く）。
    def builtinName(fun: BuiltinFn): String = match fun {
        case BuiltinFn.Floor       => "floor"
        case BuiltinFn.Abs         => "abs"
        case BuiltinFn.Normalize   => "normalize"
        case BuiltinFn.Asin        => "asin"
        case BuiltinFn.Sign        => "sign"
        case BuiltinFn.Fwidth      => "fwidth"
        case BuiltinFn.Length      => "length"
        case BuiltinFn.Dot         => "dot"
        case BuiltinFn.Distance    => "distance"
        case BuiltinFn.Cross       => "cross"
        case BuiltinFn.Atan2       => "atan"
        case BuiltinFn.Max         => "max"
        case BuiltinFn.Min         => "min"
        case BuiltinFn.Determinant => "determinant"
        case BuiltinFn.Clamp       => "clamp"
        case BuiltinFn.Mix         => "mix"
        case BuiltinFn.Fract       => "fract"
        case BuiltinFn.Sqrt        => "sqrt"
        case BuiltinFn.Pow         => "pow"
        case BuiltinFn.Cos         => "cos"
        case BuiltinFn.Sin         => "sin"
        case _                     => ShaderAst.invalidOrBug("ShaderAst.Glsl: 組み込みの関数の名前が無い")
    }

    /// 式の字。
    pub def expression(e: Expr[t]): String = exprAt(0, ShaderAst.nodeOf(e))

    def exprAt(ctx: Int32, n: Node): String =
        let s = raw(n);
        if (ShaderAst.precOfNode(Lang.Glsl, n) < ctx) "(" + s + ")" else s

    def args(xs: List[Node]): String = xs |> List.map(exprAt(0)) |> String.intercalate(", ")

    def raw(n: Node): String = match n {
        case Node.Lit(text, _)         => text
        case Node.Ref(name, _)         => name
        case Node.Uniform(u)           => ShaderAst.accessFor(Lang.Glsl, u, "")
        case Node.Bin(op, a, b, _)     =>
            let p = ShaderAst.precOf(op);
            exprAt(p, a) + " " + ShaderAst.opText(op) + " " + exprAt(p + 1, b)
        case Node.Neg(a, _)            => ShaderAst.prefixed("-", exprAt(ShaderAst.unaryPrec(), a))
        case Node.Not(a)               => ShaderAst.prefixed("!", exprAt(ShaderAst.unaryPrec(), a))
        case Node.Call(d, xs, _)       => ShaderAst.nameOf(d) + "(" + args(xs) + ")"
        case Node.Builtin(fun, xs, _)  => builtin(fun, xs)
        case Node.Construct(t, xs)     => tyName(t) + "(" + args(xs) + ")"
        case Node.Swizzle(inner, s, _) => match inner {
            case Node.Uniform(u) => ShaderAst.accessFor(Lang.Glsl, u, s)
            case _               => exprAt(ShaderAst.atomPrec(), inner) + "." + s
        }
        case Node.Index(a, at, _)      => exprAt(ShaderAst.atomPrec(), a) + "[" + exprAt(0, at) + "]"
        case Node.Select(c, a, b, _)   =>
            let p = ShaderAst.ternaryPrec();
            exprAt(p + 1, c) + " ? " + exprAt(p + 1, a) + " : " + exprAt(p, b)
        case Node.Paren(a)             => "(" + exprAt(0, a) + ")"
        case Node.Intrinsic(k, _)      => intrinsic(k)
        case Node.Global(d, _)         => ShaderAst.nameOf(d)
        case Node.Raw(text, _, _, _, _) => ShaderAst.rawTextOrBug(Lang.Glsl, text)
        case Node.CallIn(name, xs, _, _, _, _, _) => name + "(" + args(xs) + ")"
        case Node.Varying(name, _, ShaderAst.Interp.Affine) => name + ".xy / " + name + ".z"
        case Node.Varying(name, _, _)  => name
        case Node.Attribute(name, _)   => name
    }

    def builtin(fun: BuiltinFn, xs: List[Node]): String = match fun {
        case BuiltinFn.TextureSize      => "textureSize(" + args(xs) + ", 0)"
        case BuiltinFn.TargetDepthTexel => "texelFetch(" + args(xs) + ", 0).r"
        case BuiltinFn.TargetTexel      => "texelFetch(" + args(xs) + ", 0).r"
        case _                          => builtinName(fun) + "(" + args(xs) + ")"
    }

    def intrinsic(k: Intrinsic): String = match k {
        case Intrinsic.PixelFromTopLeft(rect) =>
            let at = (s: String) -> ShaderAst.accessFor(Lang.Glsl, rect, s);
            "ivec2(int(floor(gl_FragCoord.x - ${at("x")})), int(floor(${at("y")} + ${at("w")} - gl_FragCoord.y)))"
        case Intrinsic.PixelNdc(rect, w, h) =>
            "(gl_FragCoord.xy - ${ShaderAst.accessFor(Lang.Glsl, rect, "xy")}) / vec2(${exprAt(0, w)}, ${exprAt(0, h)}) * 2.0 - 1.0"
        case Intrinsic.FullscreenPosition => "vec4(float((gl_VertexID << 1) & 2) * 2.0 - 1.0, float(gl_VertexID & 2) * 2.0 - 1.0, 0.0, 1.0)"
        case Intrinsic.QuadCorner         => "aCorner"
        case Intrinsic.FrontFacing        => "gl_FrontFacing"
    }

    // ── 文 ──

    /// 1 行に置ける文か（GLSL は emit して抜ける文が 2 行になる）。
    def fitsOneLine(s: Stmt): Bool = match s {
        case Stmt.Emit(_, true)          => false
        case Stmt.If(_, _, _, _)         => false
        case Stmt.For(_, _, _, _, _, _)  => false
        case Stmt.RawStmt(_, _)          => false
        case Stmt.Only(_, _)             => false
        case _                           => true
    }

    /// 1 行に置く文の字（字下げと改行なし）。
    def inline(s: Stmt): String = match s {
        case Stmt.Decl(name, t, Some(e), _) => tyName(t) + " " + name + " = " + exprAt(0, e) + ";"
        case Stmt.Decl(name, t, None, _)    => tyName(t) + " " + name + ";"
        case Stmt.Assign(a, b)              => exprAt(0, a) + " = " + exprAt(0, b) + ";"
        case Stmt.Incr(a)                   => exprAt(0, a) + "++;"
        case Stmt.Return(Some(e))           => "return " + exprAt(0, e) + ";"
        case Stmt.Return(None)              => "return;"
        case Stmt.Discard                   => "discard;"
        case Stmt.Eval(e)                   => exprAt(0, e) + ";"
        case Stmt.Emit(e, false)            => "fragColor = " + exprAt(0, e) + ";"
        case Stmt.Headed(head, _, e)        => head + exprAt(0, e) + ";"
        case Stmt.Output(name, _, ShaderAst.Interp.Affine, e) =>
            name + " = vec3(" + exprAt(ShaderAst.precOf(ShaderAst.BinOp.Mul), e) + " * gl_Position.w, gl_Position.w);"
        case Stmt.Output(name, _, _, e)     => name + " = " + exprAt(0, e) + ";"
        case Stmt.ClipOut(e)                => "gl_Position = " + exprAt(0, e) + ";"
        case _                              => ShaderAst.invalidOrBug("ShaderAst.Glsl: 1 行に置けない文")
    }

    def stmts(depth: Int32, body: List[Stmt]): String = body |> List.map(stmt(depth)) |> ShaderAst.joinParts

    def stmt(depth: Int32, s: Stmt): String =
        let ind = ShaderAst.indentOf(depth);
        match s {
            case Stmt.If(c, t, e, layout) =>
                let head = ind + "if (" + exprAt(0, c) + ")";
                match (layout, t, e) {
                    case (Layout.Inline, one :: Nil, Nil) if fitsOneLine(one) => head + " " + inline(one) + "\n"
                    case (_, _, Nil)                      => head + " {\n" + stmts(depth + 1, t) + ind + "}\n"
                    case _                                => head + " {\n" + stmts(depth + 1, t) + ind + "} else {\n" + stmts(depth + 1, e) + ind + "}\n"
                }
            case Stmt.For(name, t, start, cond, body, layout) =>
                let head = ind + "for (" + tyName(t) + " " + name + " = " + exprAt(0, start) + "; " + exprAt(0, cond) + "; " + name + "++)";
                match (layout, body) {
                    case (Layout.Inline, one :: Nil) if fitsOneLine(one) => head + " " + inline(one) + "\n"
                    case _                           => head + " {\n" + stmts(depth + 1, body) + ind + "}\n"
                }
            case Stmt.Emit(e, true) => ind + inline(Stmt.Emit(e, false)) + "\n" + ind + "return;\n"
            case Stmt.RawStmt(text, _) => TextSplit.lines(text) |> List.map(l -> ind + l + "\n") |> ShaderAst.joinParts
            case _ => ind + inline(s) + "\n"
        }

    // ── 定義 ──

    /// 定義 1 つの字（辿った定義は含めない）。
    pub def definition(d: Definition): String = match d {
        case Def.Fn(name, ret, params, body) =>
            let ps = params |> List.map(p -> tyName(snd(p)) + " " + fst(p)) |> String.intercalate(", ");
            tyName(ret) + " " + name + "(" + ps + ") {\n" + stmts(1, body) + "}\n"
        case Def.Extern(name, _, _, glsl, _, _, _) => match ShaderAst.bodyText(glsl) {
            case Some(text) => text
            case None       => ShaderAst.invalidOrBug("ShaderAst.Glsl: extern ${name} に GLSL の本文が無い")
        }
        case Def.ConstArray(name, elem, values) =>
            let n = List.length(values);
            "const ${tyName(elem)} ${name}[${n}] = ${tyName(elem)}[${n}](" + String.intercalate(", ", values) + ");\n"
        case Def.Private(name, t, length, init, lang) =>
            if (lang == Some(Lang.Wgsl)) ""
            else {
                let dims = length |> Option.map(n -> "[${n}]") |> Option.getWithDefault("");
                let start = init |> Option.map(v -> " = " + exprAt(0, v)) |> Option.getWithDefault("");
                tyName(t) + " " + name + dims + start + ";\n"
            }
    }

    /// uniform の宣言の行（`uniform <型> <名前>[長さ];`）。
    def uniformLine(decl: (String, String, Option[Int32])): String =
        let (t, name, length) = decl;
        "uniform ${t} ${name}" + (length |> Option.map(n -> "[${n}]") |> Option.getWithDefault("")) + ";\n"

    /// defs と本文 body の中の uniform の宣言の行と、defs の字。
    def withUniforms(defs: List[Def], body: List[Stmt]): String =
        ShaderAst.joinParts(ShaderAst.glslUniformsOrBug(defs, body) |> List.map(uniformLine)) + ShaderAst.joinParts(defs |> List.map(definition))

    /// roots と、それが辿って使う定義を、使う前に 1 回ずつ並べた字（読む uniform の宣言の行が先。組む時の検査を通す）。
    pub def print(roots: List[Definition]): String =
        withUniforms(ShaderAst.checkOrBug(ShaderAst.collectOrBug(Lang.Glsl, roots)), Nil)

    /// uniform refs の宣言の行（並べた順。GLSL の名前の重なりは 1 行に）。
    pub def uniformDeclarations(refs: List[ShaderAst.UniformRef]): String =
        refs |> List.map(u -> Stmt.Eval(Node.Uniform(ShaderAst.keyOf(u))))
             |> ShaderAst.glslUniformsOrBug(Nil) |> List.map(uniformLine) |> ShaderAst.joinParts

    /// varying の宣言の型（Affine は uv と w を掛けた xy と w を送るので 1 つ多い）。
    def varyingTy(v: ShaderAst.Varying): Ty =
        if (v#interp == ShaderAst.Interp.Affine and v#ty == Ty.Vec2) Ty.Vec3 else v#ty

    /// varying の宣言の行（dir = in か out）。
    def varyingLines(dir: String, vs: List[ShaderAst.Varying]): String =
        vs |> List.map(v -> (if (v#interp == ShaderAst.Interp.Flat) "flat " else "") + dir + " " + tyName(varyingTy(v)) + " " + v#name + ";\n") |> ShaderAst.joinParts

    /// 入口の main の字（uniform の宣言・辿った定義・main）。
    def mainOf(defs: List[Def], body: List[Stmt]): String = withUniforms(defs, body) + "void main() {\n" + stmts(1, body) + "}\n"

    /// frag の入口の字（#version・in の宣言・fragColor・uniform の宣言・辿った定義・main）。
    pub def fragment(e: ShaderAst.FragmentEntry): String =
        let (defs, body) = ShaderAst.Entry.fragmentOrBug(Lang.Glsl, e);
        "#version 330 core\n" + varyingLines("in", e#inputs) + (if (e#writesColor) "out vec4 fragColor;\n" else "") + mainOf(defs, body)

    /// 属性の宣言の行（name・型・location）。
    def attributeLine(name: String, t: Ty, location: Int32): String = "layout (location = ${location}) in ${tyName(t)} ${name};\n"

    /// vertex の入口の字（#version・属性・out の宣言・uniform の宣言・辿った定義・main）。四角の角を読む本文は aCorner の属性を先に置く。
    pub def vertex(e: ShaderAst.VertexEntry): String =
        let (defs, body) = ShaderAst.Entry.vertexOrBug(Lang.Glsl, e);
        let corner = if (ShaderAst.Entry.readsQuadCorner(defs, body)) attributeLine("aCorner", Ty.Vec2, ShaderAst.quadCornerLocation()) else "";
        let attrs = e#attributes |> List.filterMap(a -> a#glslLocation |> Option.map(at -> attributeLine(a#name, a#ty, at)));
        "#version 330 core\n" + corner + ShaderAst.joinParts(attrs) + varyingLines("out", e#outputs) + mainOf(defs, body)
}
