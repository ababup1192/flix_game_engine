// ShaderAst.Wgsl — ShaderAst の木を WGSL へ出す。
// WGSL の違い: 暗黙の型の変換が無い（clamp の f32 の端はベクトルに広げる）・? : は select（両側を計算する）・
// ビットの演算は単項の式しか取らない（中の二項は括弧で包む）・&& と || を括弧なしで混ぜられない・比べは続けて書けない・
// 決まった値の配列は使う関数の頭の var（実行時の添字で const の配列を引けない実装がある）。
pub mod ShaderAst.Wgsl {
    use ShaderAst.{Node, Stmt, Def, Ty, BinOp, BuiltinFn, Layout, Intrinsic, Lang, Expr, Definition}

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

    /// 組み込みの関数の名前（言語ごとに引数の違う Clamp・TextureSize・TargetDepthTexel の形は builtin が書く）。
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
        case BuiltinFn.Atan2       => "atan2"
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
        case _                     => ShaderAst.invalidOrBug("ShaderAst.Wgsl: 組み込みの関数の名前が無い")
    }

    /// 式の字。
    pub def expression(e: Expr[t]): String = exprAt(0, ShaderAst.nodeOf(e))

    def exprAt(ctx: Int32, n: Node): String =
        let s = raw(n);
        if (ShaderAst.precOfNode(Lang.Wgsl, n) < ctx) "(" + s + ")" else s

    def args(xs: List[Node]): String = xs |> List.map(exprAt(0)) |> String.intercalate(", ")

    def isLogical(op: BinOp): Bool = op == BinOp.And or op == BinOp.Or

    def isBitwise(op: BinOp): Bool = op == BinOp.BitAnd or op == BinOp.Shl

    /// 二項の演算の子を置く強さ（WGSL の文法が括弧を求める所は強くする）。
    def childCtx(op: BinOp, child: Node, base: Int32): Int32 = match child {
        case Node.Bin(cop, _, _, _) =>
            if (isBitwise(op) or isBitwise(cop) and isLogical(op)) ShaderAst.atomPrec()
            else if (isLogical(op) and isLogical(cop) and cop != op) ShaderAst.atomPrec()
            else if (ShaderAst.isRelational(op) and ShaderAst.isRelational(cop)) ShaderAst.atomPrec()
            else base
        case _ => base
    }

    def isVector(t: Ty): Bool = t == Ty.Vec2 or t == Ty.Vec3 or t == Ty.Vec4 or t == Ty.IVec2 or t == Ty.IVec4

    /// f32 の n をベクトルの型 t へ広げた字（t がスカラーならそのまま）。
    def splatTo(t: Ty, n: Node): String =
        if (isVector(t) and not isVector(ShaderAst.tyOfNode(n))) tyName(t) + "(" + exprAt(0, n) + ")" else exprAt(0, n)

    def builtin(fun: BuiltinFn, xs: List[Node], t: Ty): String = match fun {
        case BuiltinFn.Clamp            => clampText(xs, t)
        case BuiltinFn.TextureSize      => "vec2i(textureDimensions(" + args(xs) + ", 0))"
        case BuiltinFn.TargetDepthTexel => depthTexelLoad(xs)
        case BuiltinFn.TargetTexel      => depthTexelLoad(xs) + ".r"
        case _                          => builtinName(fun) + "(" + args(xs) + ")"
    }

    /// clamp の f32 の端を、値の型 t のベクトルに広げた字。
    def clampText(xs: List[Node], t: Ty): String = match xs {
        case v :: lo :: hi :: Nil => "clamp(" + exprAt(0, v) + ", " + splatTo(t, lo) + ", " + splatTo(t, hi) + ")"
        case _                    => "clamp(" + args(xs) + ")"
    }

    /// GL の行の数え方の画素で、WGSL で描いた奥行きの地図（行 0 が上）を読む字（xs = 地図・画素）。
    def depthTexelLoad(xs: List[Node]): String = match xs {
        case map :: texel :: Nil =>
            let m = exprAt(0, map);
            let at = exprAt(ShaderAst.atomPrec(), texel);
            "textureLoad(${m}, vec2i(${at}.x, i32(textureDimensions(${m}, 0).y) - 1 - ${at}.y), 0)"
        case _ => ShaderAst.invalidOrBug("ShaderAst.Wgsl: targetDepthTexel の引数が 2 つでない")
    }

    def raw(n: Node): String = match n {
        case Node.Lit(text, _)         => text
        case Node.Ref(name, _)         => name
        case Node.Uniform(u)           => ShaderAst.accessFor(Lang.Wgsl, u, "")
        case Node.Bin(op, a, b, _)     =>
            let p = ShaderAst.precOf(op);
            exprAt(childCtx(op, a, p), a) + " " + ShaderAst.opText(op) + " " + exprAt(childCtx(op, b, p + 1), b)
        case Node.Neg(a, _)            => ShaderAst.prefixed("-", exprAt(ShaderAst.unaryPrec(), a))
        case Node.Not(a)               => ShaderAst.prefixed("!", exprAt(ShaderAst.unaryPrec(), a))
        case Node.Call(d, xs, _)       => ShaderAst.nameOf(d) + "(" + args(xs) + ")"
        case Node.Builtin(fun, xs, t)  => builtin(fun, xs, t)
        case Node.Construct(t, xs)     => tyName(t) + "(" + args(xs) + ")"
        case Node.Swizzle(inner, s, _) => match inner {
            case Node.Uniform(u) => ShaderAst.accessFor(Lang.Wgsl, u, s)
            case _               => exprAt(ShaderAst.atomPrec(), inner) + "." + s
        }
        case Node.Index(a, at, _)      => exprAt(ShaderAst.atomPrec(), a) + "[" + exprAt(0, at) + "]"
        case Node.Select(c, a, b, _)   => "select(" + exprAt(0, b) + ", " + exprAt(0, a) + ", " + exprAt(0, c) + ")"
        case Node.Paren(a)             => "(" + exprAt(0, a) + ")"
        case Node.Intrinsic(k, _)      => intrinsic(k)
        case Node.Global(d, _)         => ShaderAst.nameOf(d)
        case Node.Raw(_, text, _, _, _) => ShaderAst.rawTextOrBug(Lang.Wgsl, text)
        case Node.CallIn(_, _, name, xs, _, _, _) => name + "(" + args(xs) + ")"
        case Node.Varying(name, _, _)  => "i." + name
        case Node.Attribute(name, _)   => "v." + name
    }

    def intrinsic(k: Intrinsic): String =
        let frag = ShaderAst.nameOf(ShaderAst.fragCoord());
        let index = ShaderAst.nameOf(ShaderAst.vertexIndex());
        match k {
            case Intrinsic.PixelFromTopLeft(_) => "vec2i(i32(floor(${frag}.x)), i32(floor(${frag}.y)))"
            case Intrinsic.PixelNdc(_, w, h)   =>
                let size = (n: Node) -> exprAt(ShaderAst.precOf(BinOp.Div) + 1, n);
                "vec2f(${frag}.x / ${size(w)} * 2.0 - 1.0, 1.0 - ${frag}.y / ${size(h)} * 2.0)"
            case Intrinsic.FullscreenPosition  => "vec4f(f32((${index} << 1u) & 2u) * 2.0 - 1.0, f32(${index} & 2u) * 2.0 - 1.0, 0.0, 1.0)"
            case Intrinsic.QuadCorner          => "r3d_quadCorner(${index})"
            case Intrinsic.FrontFacing         => "i.frontFacing"
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
        case Stmt.Emit(e, _)                    => "return " + exprAt(0, e) + ";"
        case Stmt.Headed(_, head, e)            => head + exprAt(0, e) + ";"
        case Stmt.Output(name, _, _, e)         => "o." + name + " = " + exprAt(0, e) + ";"
        case Stmt.ClipOut(e)                    => "o.position = sg_clipFromGl(" + exprAt(0, e) + ");"
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
            case Stmt.RawStmt(_, text) => TextSplit.lines(text) |> List.map(l -> ind + l + "\n") |> ShaderAst.joinParts
            case _ => ind + inline(s) + "\n"
        }

    // ── 定義 ──

    /// 関数の本文が直に読む決まった値の配列の (名前, 型, 値)（関数の頭に var で置く）。
    def localArrays(d: Def): List[(String, Ty, List[String])] =
        ShaderAst.directDeps(Lang.Wgsl, d) |> List.filterMap(dep -> match dep {
            case Def.ConstArray(name, elem, values) => Some((name, elem, values))
            case _                                  => None
        }) |> List.distinct

    /// 定義 1 つの字（辿った定義は含めない）。
    pub def definition(d: Definition): String = match d {
        case Def.Fn(name, ret, params, body) =>
            let ps = params |> List.map(p -> fst(p) + ": " + tyName(snd(p))) |> String.intercalate(", ");
            let result = if (ret == Ty.Void) "" else " -> " + tyName(ret);
            let arrays = localArrays(d) |> List.map(c -> {
                let (an, elem, values) = c;
                "    var ${an} = array<${tyName(elem)}, ${List.length(values)}>(" + String.intercalate(", ", values) + ");\n"
            });
            "fn " + name + "(" + ps + ")" + result + " {\n" + ShaderAst.joinParts(arrays) + stmts(1, body) + "}\n"
        case Def.Extern(name, _, _, _, wgsl, _, _) => match ShaderAst.bodyText(wgsl) {
            case Some(text) => text
            case None       => ShaderAst.invalidOrBug("ShaderAst.Wgsl: extern ${name} に WGSL の本文が無い")
        }
        case Def.ConstArray(_, _, _) => ""
        case Def.Private(name, t, length, init, lang) =>
            if (lang == Some(Lang.Glsl)) ""
            else {
                let ty = length |> Option.map(n -> "array<${tyName(t)}, ${n}>") |> Option.getWithDefault(tyName(t));
                let start = init |> Option.map(v -> " = " + exprAt(0, v)) |> Option.getWithDefault("");
                "var<private> " + name + ": " + ty + start + ";\n"
            }
    }

    /// roots と、それが辿って使う定義を、使う前に 1 回ずつ並べた字（組む時の検査を通す）。
    pub def print(roots: List[Definition]): String =
        ShaderAst.checkOrBug(ShaderAst.collectOrBug(Lang.Wgsl, roots)) |> List.map(definition) |> ShaderAst.joinParts

    /// varying の欄の字（@location と補間）。
    def varyingField(v: ShaderAst.Varying): String =
        let interp = match v#interp {
            case ShaderAst.Interp.Flat   => "@interpolate(flat) "
            case ShaderAst.Interp.Affine => "@interpolate(linear) "
            case ShaderAst.Interp.Smooth => ""
        };
        "    @location(${v#location}) " + interp + v#name + ": " + tyName(v#ty) + ",\n"

    /// 入口の引数の struct の字と引数の字（欄が無ければ struct を置かず引数も無い）。fields = 欄の行・param = 引数の名前。
    def inputOf(name: String, param: String, fields: List[String]): (String, String) =
        if (List.isEmpty(fields)) ("", "")
        else ("struct ${name} {\n" + ShaderAst.joinParts(fields) + "};\n", param + ": " + name)

    /// frag の入口の字（辿った定義・入口の引数の struct・fs_main）。画素の位置を読む本文は入口の頭で r3d_fragCoord へ写す。
    pub def fragment(e: ShaderAst.FragmentEntry): String =
        let (defs, body) = ShaderAst.Entry.fragmentOrBug(Lang.Wgsl, e);
        let fragPos = ShaderAst.Entry.readsFragCoord(defs);
        let fields = (if (fragPos) "    @builtin(position) fragPos: vec4f,\n" :: Nil else Nil) ::: (e#inputs |> List.map(varyingField)) :::
                     (if (ShaderAst.Entry.readsFrontFacing(body)) "    @builtin(front_facing) frontFacing: bool,\n" :: Nil else Nil);
        let (structText, paramText) = inputOf(e#inputName, "i", fields);
        ShaderAst.joinParts(defs |> List.map(definition)) + structText +
        "@fragment fn fs_main(${paramText})" + (if (e#writesColor) " -> @location(0) vec4f" else "") + " {\n" +
        (if (fragPos) "    " + ShaderAst.nameOf(ShaderAst.fragCoord()) + " = i.fragPos;\n" else "") +
        stmts(1, body) + "}\n"

    /// vertex の入口の字（辿った定義・入口の引数と返り値の struct・vs_main）。頂点の番号を読む本文は入口の頭で r3d_vertexIndex へ写す。
    pub def vertex(e: ShaderAst.VertexEntry): String =
        let (defs, body) = ShaderAst.Entry.vertexOrBug(Lang.Wgsl, e);
        let index = ShaderAst.Entry.readsVertexIndex(defs);
        let attrs = e#attributes |> List.filterMap(a -> a#wgslLocation |> Option.map(at -> "    @location(${at}) ${a#name}: ${tyName(a#ty)},\n"));
        let (structText, paramText) = inputOf(e#inputName, "v", (if (index) "    @builtin(vertex_index) vertexIndex: u32,\n" :: Nil else Nil) ::: attrs);
        ShaderAst.joinParts(defs |> List.map(definition)) + structText +
        "struct ${e#outputName} {\n    @builtin(position) position: vec4f,\n" + ShaderAst.joinParts(e#outputs |> List.map(varyingField)) + "};\n" +
        "@vertex fn vs_main(${paramText}) -> ${e#outputName} {\n" +
        (if (index) "    " + ShaderAst.nameOf(ShaderAst.vertexIndex()) + " = v.vertexIndex;\n" else "") +
        "    var o: ${e#outputName};\n" + stmts(1, body) + "    return o;\n}\n"
}
