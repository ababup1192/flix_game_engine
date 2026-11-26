// ShaderAst.Wgsl — ShaderAst の木を WGSL へ出す。
// WGSL の違い: 暗黙の型の変換が無い（clamp のスカラーの端はベクトルに広げる）・? : は select（両側を計算する）・
// ビットの演算は単項の式しか取らない（中の二項は括弧で包む）・&& と || を括弧なしで混ぜられない・
// 決まった値の配列は使う関数の頭の var（実行時の添字で const の配列を引けない実装がある）。
pub mod ShaderAst.Wgsl {
    use ShaderAst.{Node, Stmt, Def, Ty, BinOp, Layout, Body, Intrinsic, Lang, Expr, Definition, Statement}

    /// 型の字。
    pub def tyName(t: Ty): String = match t {
        case Ty.F32            => "f32"
        case Ty.I32            => "i32"
        case Ty.U32            => "u32"
        case Ty.Bool           => "bool"
        case Ty.Vec2           => "vec2f"
        case Ty.Vec3           => "vec3f"
        case Ty.Vec4           => "vec4f"
        case Ty.IVec2          => "vec2i"
        case Ty.IVec4          => "vec4i"
        case Ty.Mat3           => "mat3x3f"
        case Ty.Mat4           => "mat4x4f"
        case Ty.Texture2d      => "texture_2d<f32>"
        case Ty.DepthTexture2d => "texture_depth_2d"
        case Ty.Sampler        => "sampler"
        case Ty.Void           => ShaderAst.invalidOrBug("ShaderAst.Wgsl: void の値は無い")
    }

    /// 式の字。
    pub def expression(e: Expr[t]): String = exprAt(0, ShaderAst.nodeOf(e))

    def exprAt(ctx: Int32, n: Node): String =
        let s = raw(n);
        if (ShaderAst.precOfNode(n) < ctx) "(" + s + ")" else s

    def args(xs: List[Node]): String = xs |> List.map(exprAt(0)) |> String.intercalate(", ")

    def isLogical(op: BinOp): Bool = op == BinOp.And or op == BinOp.Or

    def isBitwise(op: BinOp): Bool = op == BinOp.BitAnd or op == BinOp.Shl

    /// 二項の演算の子を置く強さ（WGSL の文法が括弧を求める所は強くする）。
    def childCtx(op: BinOp, child: Node, base: Int32): Int32 = match child {
        case Node.Bin(cop, _, _, _) =>
            if (isBitwise(op)) 16
            else if (isLogical(op) and isLogical(cop) and cop != op) 16
            else base
        case _ => base
    }

    def isVector(t: Ty): Bool = t == Ty.Vec2 or t == Ty.Vec3 or t == Ty.Vec4 or t == Ty.IVec2 or t == Ty.IVec4

    /// スカラーの n をベクトルの型 t へ広げた字（t がスカラーならそのまま）。
    def splatTo(t: Ty, n: Node): String =
        if (isVector(t) and not isVector(ShaderAst.tyOfNode(n))) tyName(t) + "(" + exprAt(0, n) + ")" else exprAt(0, n)

    def builtin(name: String, xs: List[Node], t: Ty): String = match (name, xs) {
        case ("atan", _)                  => "atan2(" + args(xs) + ")"
        case ("clamp", v :: lo :: hi :: Nil) => "clamp(" + exprAt(0, v) + ", " + splatTo(t, lo) + ", " + splatTo(t, hi) + ")"
        case ("texelFetch", map :: at :: Nil) => "textureLoad(" + exprAt(0, map) + ", " + exprAt(0, at) + ", 0)"
        case ("textureSize", map :: Nil)  => "vec2i(textureDimensions(" + exprAt(0, map) + ", 0))"
        case ("dFdx", _)                  => "dpdx(" + args(xs) + ")"
        case _                            => name + "(" + args(xs) + ")"
    }

    def raw(n: Node): String = match n {
        case Node.Lit(text, _)        => text
        case Node.Ref(name, _)        => name
        case Node.Uniform(u)          => accessOf(u, "")
        case Node.Bin(op, a, b, _)    =>
            let p = ShaderAst.precOf(op);
            exprAt(childCtx(op, a, p), a) + " " + ShaderAst.opText(op) + " " + exprAt(childCtx(op, b, p + 1), b)
        case Node.Neg(a, _)           => "-" + exprAt(14, a)
        case Node.Not(a)              => "!" + exprAt(14, a)
        case Node.Call(d, xs, _)      => ShaderAst.nameOf(d) + "(" + args(xs) + ")"
        case Node.Builtin(name, xs, t) => builtin(name, xs, t)
        case Node.Construct(t, xs)    => tyName(t) + "(" + args(xs) + ")"
        case Node.Swizzle(inner, s, _) => match inner {
            case Node.Uniform(u) => accessOf(u, s)
            case _               => exprAt(16, inner) + "." + s
        }
        case Node.Index(a, at, _)     => exprAt(16, a) + "[" + exprAt(0, at) + "]"
        case Node.Select(c, a, b, _)  => "select(" + exprAt(0, b) + ", " + exprAt(0, a) + ", " + exprAt(0, c) + ")"
        case Node.Paren(a)            => "(" + exprAt(0, a) + ")"
        case Node.Intrinsic(k, _)     => intrinsic(k)
        case Node.Global(d, _)        => ShaderAst.nameOf(d)
    }

    /// uniform u を読む字（outer = 外から重ねる swizzle）。
    def accessOf(u: ShaderAst.UniformKey, outer: String): String = match u {
        case (name, _, _, None) => ShaderAst.invalidOrBug("ShaderAst.Wgsl: uniform ${name} は WGSL に無い")
        case (_, _, _, Some((base, swizzle))) => ShaderAst.accessText(base, swizzle, outer)
    }

    def intrinsic(k: Intrinsic): String = match k {
        case Intrinsic.PixelFromTopLeft => "vec2i(i32(floor(r3d_fragCoord.x)), i32(floor(r3d_fragCoord.y)))"
    }

    // ── 文 ──

    def inline(s: Stmt): String = match s {
        case Stmt.Decl(name, _, Some(e), true)  => "var " + name + " = " + exprAt(0, e) + ";"
        case Stmt.Decl(name, _, Some(e), false) => "let " + name + " = " + exprAt(0, e) + ";"
        case Stmt.Decl(name, t, None, _)        => "var " + name + ": " + tyName(t) + ";"
        case Stmt.Assign(a, b)                  => exprAt(0, a) + " = " + exprAt(0, b) + ";"
        case Stmt.Incr(a)                       => exprAt(0, a) + "++;"
        case Stmt.Return(Some(e))               => "return " + exprAt(0, e) + ";"
        case Stmt.Return(None)                  => "return;"
        case Stmt.Discard                       => "discard;"
        case Stmt.Eval(e)                       => exprAt(0, e) + ";"
        case _                                  => ShaderAst.invalidOrBug("ShaderAst.Wgsl: if・for は 1 行の文の中に置けない")
    }

    def stmts(depth: Int32, body: List[Stmt]): String = body |> List.map(stmt(depth)) |> ShaderAst.joinParts

    def stmt(depth: Int32, s: Stmt): String =
        let ind = ShaderAst.indentOf(depth);
        match s {
            case Stmt.If(c, t, e, layout) =>
                let head = ind + "if (" + exprAt(0, c) + ")";
                match (layout, t, e) {
                    case (Layout.Inline, one :: Nil, Nil) => head + " { " + inline(one) + " }\n"
                    case (_, _, Nil)                      => head + " {\n" + stmts(depth + 1, t) + ind + "}\n"
                    case _                                => head + " {\n" + stmts(depth + 1, t) + ind + "} else {\n" + stmts(depth + 1, e) + ind + "}\n"
                }
            case Stmt.For(name, _, start, cond, body, layout) =>
                let head = ind + "for (var " + name + " = " + exprAt(0, start) + "; " + exprAt(0, cond) + "; " + name + "++)";
                match (layout, body) {
                    case (Layout.Inline, one :: Nil) => head + " { " + inline(one) + " }\n"
                    case _                           => head + " {\n" + stmts(depth + 1, body) + ind + "}\n"
                }
            case _ => ind + inline(s) + "\n"
        }

    // ── 定義 ──

    /// 関数の本文が直に読む決まった値の配列の (名前, 型, 値)（関数の頭に var で置く）。
    def localArrays(d: Def): List[(String, Ty, List[String])] =
        ShaderAst.directDeps(d) |> List.filterMap(dep -> match dep {
            case Def.ConstArray(name, elem, values) => Some((name, elem, values))
            case _                                  => None
        }) |> List.distinct

    /// 定義 1 つの字（辿った定義は含めない）。
    pub def definition(d: Definition): String = match d {
        case Def.Fn(name, ret, params, body) =>
            let ps = params |> List.map(p -> fst(p) + ": " + tyName(snd(p))) |> String.intercalate(", ");
            let result = if (ret == Ty.Void) "" else " -> " + tyName(ret);
            let arrays = localArrays(d) |> List.map(a -> {
                let (an, elem, values) = a;
                "    var ${an} = array<${tyName(elem)}, ${List.length(values)}>(" + String.intercalate(", ", values) + ");\n"
            });
            "fn " + name + "(" + ps + ")" + result + " {\n" + ShaderAst.joinParts(arrays) + stmts(1, body) + "}\n"
        case Def.Extern(name, _, _, _, wgsl, _, _) => match wgsl {
            case Body.Text(text) => text
            case Body.Outside    => ""
            case Body.Missing    => ShaderAst.invalidOrBug("ShaderAst.Wgsl: extern ${name} に WGSL の本文が無い")
        }
        case Def.ConstArray(_, _, _) => ""
        case Def.Private(name, t, length, init, lang) =>
            if (lang == Some(Lang.Glsl)) ""
            else {
                let ty = if (length > 0) "array<${tyName(t)}, ${length}>" else tyName(t);
                let start = init |> Option.map(v -> " = " + v) |> Option.getWithDefault("");
                "var<private> " + name + ": " + ty + start + ";\n"
            }
    }

    /// roots と、それが辿って使う定義を、使う前に 1 回ずつ並べた字（一様さの検査を通す）。
    pub def print(roots: List[Definition]): String =
        ShaderAst.checked(ShaderAst.collect(roots)) |> List.map(definition) |> ShaderAst.joinParts

    /// defs だけを並べた字（辿った定義は周りの字が置く）。
    pub def printOnly(defs: List[Definition]): String =
        ShaderAst.checked(defs) |> List.map(definition) |> ShaderAst.joinParts
}
