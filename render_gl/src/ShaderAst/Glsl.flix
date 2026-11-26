// ShaderAst.Glsl — ShaderAst の木を GLSL（330 core・GLSL ES 3.00 へ写す前の字）へ出す。
pub mod ShaderAst.Glsl {
    use ShaderAst.{Node, Stmt, Def, Ty, BinOp, Layout, Body, Intrinsic, Lang, Expr, Definition, Statement}

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

    /// 式の字。
    pub def expression(e: Expr[t]): String = exprAt(0, ShaderAst.nodeOf(e))

    def exprAt(ctx: Int32, n: Node): String =
        let s = raw(n);
        if (ShaderAst.precOfNode(n) < ctx) "(" + s + ")" else s

    def args(xs: List[Node]): String = xs |> List.map(exprAt(0)) |> String.intercalate(", ")

    def raw(n: Node): String = match n {
        case Node.Lit(text, _)        => text
        case Node.Ref(name, _)        => name
        case Node.Uniform(u)          => accessOf(u, "")
        case Node.Bin(op, a, b, _)    =>
            let p = ShaderAst.precOf(op);
            exprAt(p, a) + " " + ShaderAst.opText(op) + " " + exprAt(p + 1, b)
        case Node.Neg(a, _)           => "-" + exprAt(14, a)
        case Node.Not(a)              => "!" + exprAt(14, a)
        case Node.Call(d, xs, _)      => ShaderAst.nameOf(d) + "(" + args(xs) + ")"
        case Node.Builtin(name, xs, _) => name + "(" + args(xs) + ")"
        case Node.Construct(t, xs)    => tyName(t) + "(" + args(xs) + ")"
        case Node.Swizzle(inner, s, _) => match inner {
            case Node.Uniform(u) => accessOf(u, s)
            case _               => exprAt(16, inner) + "." + s
        }
        case Node.Index(a, at, _)     => exprAt(16, a) + "[" + exprAt(0, at) + "]"
        case Node.Select(c, a, b, _)  => exprAt(3, c) + " ? " + exprAt(3, a) + " : " + exprAt(2, b)
        case Node.Paren(a)            => "(" + exprAt(0, a) + ")"
        case Node.Intrinsic(k, _)     => intrinsic(k)
        case Node.Global(d, _)        => ShaderAst.nameOf(d)
    }

    /// uniform u を読む字（outer = 外から重ねる swizzle）。
    def accessOf(u: ShaderAst.UniformKey, outer: String): String = match u {
        case (name, _, None, _) => ShaderAst.invalidOrBug("ShaderAst.Glsl: uniform ${name} は GLSL に無い")
        case (_, _, Some((base, swizzle)), _) => ShaderAst.accessText(base, swizzle, outer)
    }

    def intrinsic(k: Intrinsic): String = match k {
        case Intrinsic.PixelFromTopLeft => "ivec2(int(floor(gl_FragCoord.x - uPsxTarget.x)), int(floor(uPsxTarget.y + uPsxTarget.w - gl_FragCoord.y)))"
    }

    // ── 文 ──

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
        case _                              => ShaderAst.invalidOrBug("ShaderAst.Glsl: if・for は 1 行の文の中に置けない")
    }

    def stmts(depth: Int32, body: List[Stmt]): String = body |> List.map(stmt(depth)) |> ShaderAst.joinParts

    def stmt(depth: Int32, s: Stmt): String =
        let ind = ShaderAst.indentOf(depth);
        match s {
            case Stmt.If(c, t, e, layout) =>
                let head = ind + "if (" + exprAt(0, c) + ")";
                match (layout, t, e) {
                    case (Layout.Inline, one :: Nil, Nil) => head + " " + inline(one) + "\n"
                    case (_, _, Nil)                      => head + " {\n" + stmts(depth + 1, t) + ind + "}\n"
                    case _                                => head + " {\n" + stmts(depth + 1, t) + ind + "} else {\n" + stmts(depth + 1, e) + ind + "}\n"
                }
            case Stmt.For(name, t, start, cond, body, layout) =>
                let head = ind + "for (" + tyName(t) + " " + name + " = " + exprAt(0, start) + "; " + exprAt(0, cond) + "; " + name + "++)";
                match (layout, body) {
                    case (Layout.Inline, one :: Nil) => head + " " + inline(one) + "\n"
                    case _                           => head + " {\n" + stmts(depth + 1, body) + ind + "}\n"
                }
            case _ => ind + inline(s) + "\n"
        }

    // ── 定義 ──

    /// 定義 1 つの字（辿った定義は含めない）。
    pub def definition(d: Definition): String = match d {
        case Def.Fn(name, ret, params, body) =>
            let ps = params |> List.map(p -> tyName(snd(p)) + " " + fst(p)) |> String.intercalate(", ");
            tyName(ret) + " " + name + "(" + ps + ") {\n" + stmts(1, body) + "}\n"
        case Def.Extern(name, _, _, glsl, _, _, _) => match glsl {
            case Body.Text(text) => text
            case Body.Outside    => ""
            case Body.Missing    => ShaderAst.invalidOrBug("ShaderAst.Glsl: extern ${name} に GLSL の本文が無い")
        }
        case Def.ConstArray(name, elem, values) =>
            let n = List.length(values);
            "const ${tyName(elem)} ${name}[${n}] = ${tyName(elem)}[${n}](" + String.intercalate(", ", values) + ");\n"
        case Def.Private(name, t, length, init, lang) =>
            if (lang == Some(Lang.Wgsl)) ""
            else {
                let dims = if (length > 0) "[${length}]" else "";
                let start = init |> Option.map(v -> " = " + v) |> Option.getWithDefault("");
                tyName(t) + " " + name + dims + start + ";\n"
            }
    }

    /// roots と、それが辿って使う定義を、使う前に 1 回ずつ並べた字（一様さの検査を通す）。
    pub def print(roots: List[Definition]): String =
        ShaderAst.checked(ShaderAst.collect(roots)) |> List.map(definition) |> ShaderAst.joinParts

    /// defs だけを並べた字（辿った定義は周りの字が置く）。
    pub def printOnly(defs: List[Definition]): String =
        ShaderAst.checked(defs) |> List.map(definition) |> ShaderAst.joinParts
}
