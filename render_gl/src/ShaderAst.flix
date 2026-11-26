// ShaderAst — シェーダーを 1 回だけ書き、GLSL（ShaderAst.Glsl）と WGSL（ShaderAst.Wgsl）へ出す小さな型つきの木。
//
// 式は型を持つ組み立ての関数（add・mulS・dot…）でしか作れない（Expr[t] の t は Float・Vec3 などの型のマーカー）。
// 関数は名前で集める: 呼んだ関数・読んだ大域の値を辿り、使う前に 1 回ずつ並べる。同じ名前で中身の違う物が 2 つ集まったら止める。
// GLSL と WGSL の意味の違いは printer と組み込み（Intrinsic）にだけ書く。
// WhyNot: 演算子 + * を使わない — Flix の trait は同じ型どうしの演算しか書けず、vec3 × f32 や mat4 × vec4 を表せない。
pub mod ShaderAst {

    // ── 型 ──

    /// 値の型（printer が宣言の型の字を選ぶ）。Texture2d は色の絵・DepthTexture2d は奥行きの絵（GLSL はどちらも sampler2D）。
    pub enum Ty with Eq, ToString {
        case F32, I32, U32, Bool, Vec2, Vec3, Vec4, IVec2, IVec4, Mat3, Mat4, Texture2d, DepthTexture2d, Sampler, Void
    }

    /// 式の型のマーカー（Expr[t] の t）。値は持たない。
    pub enum Float { case Float }
    pub enum Int { case Int }
    pub enum UInt { case UInt }
    pub enum Boolean { case Boolean }
    pub enum Vec2 { case Vec2 }
    pub enum Vec3 { case Vec3 }
    pub enum Vec4 { case Vec4 }
    pub enum IVec2 { case IVec2 }
    pub enum IVec4 { case IVec4 }
    pub enum Mat3 { case Mat3 }
    pub enum Mat4 { case Mat4 }
    pub enum Tex { case Tex }
    pub enum DepthTex { case DepthTex }

    /// 出す言語。
    pub enum Lang with Eq { case Glsl, Wgsl }

    // ── 木 ──

    /// 二項の演算。
    pub enum BinOp with Eq {
        case Add, Sub, Mul, Div, Mod, Lt, Le, Gt, Ge, EqOp, Ne, And, Or, BitAnd, Shl
    }

    /// uniform の読み方の字（base に swizzle を付けて読む。swizzle は空でよい）。
    pub type alias Access = { base = String, swizzle = String }

    /// uniform の読み: name = 名前（鍵）・ty = 型・言語ごとの読む字（None はその言語では宣言しない欄）。
    pub type alias UniformRef = { name = String, ty = Ty, glsl = Option[Access], wgsl = Option[Access] }

    /// 木の中の uniform の読み（名前・型・GLSL の (base, swizzle)・WGSL の (base, swizzle)）。
    type alias UniformKey = (String, Ty, Option[(String, String)], Option[(String, String)])

    def keyOf(u: UniformRef): UniformKey =
        let pair = (a: Access) -> (a#base, a#swizzle);
        (u#name, u#ty, Option.map(pair, u#glsl), Option.map(pair, u#wgsl))

    /// 言語ごとに中身の違う組み込みの式（2 節の意味の違い）。
    pub enum Intrinsic with Eq {
        /// 描き先の左上を 0 とする画素の位置（ivec2）。GLSL は gl_FragCoord を描き先の原点 uPsxTarget で直す・WGSL は frag の @builtin(position)。
        case PixelFromTopLeft
    }

    /// 式の節（型を持つ）。
    enum Node with Eq {
        case Lit(String, Ty)
        case Ref(String, Ty)
        case Uniform(UniformKey)
        case Bin(BinOp, Node, Node, Ty)
        case Neg(Node, Ty)
        case Not(Node)
        case Call(Def, List[Node], Ty)
        case Builtin(String, List[Node], Ty)
        case Construct(Ty, List[Node])
        case Swizzle(Node, String, Ty)
        case Index(Node, Node, Ty)
        case Select(Node, Node, Node, Ty)
        case Paren(Node)
        case Intrinsic(Intrinsic, Ty)
        case Global(Def, Ty)
    }

    /// 文の置き方: Inline = 1 行（GLSL は波かっこを付けない）・Block = 波かっこのブロック。
    pub enum Layout with Eq { case Inline, Block }

    /// 文。
    enum Stmt with Eq {
        case Decl(String, Ty, Option[Node], Bool)
        case Assign(Node, Node)
        case Incr(Node)
        case If(Node, List[Stmt], List[Stmt], Layout)
        case For(String, Ty, Node, Node, List[Stmt], Layout)
        case Return(Option[Node])
        case Discard
        case Eval(Node)
    }

    /// 言語ごとの本文の字（extern 関数）。Text = この字を置く・Outside = 周りの字が定義する（置かない）・Missing = この言語には無い（print すると止める）。
    pub enum Body with Eq {
        case Text(String)
        case Outside
        case Missing
    }

    /// 関数の定義。
    pub type alias FnDef = { name = String, ret = Ty, params = List[(String, Ty)], body = List[Stmt] }

    /// extern 関数: 本文は言語ごとの字。deps = 本文が読む定義（先に並べる）・derivative = 微分か暗黙の mip レベルの読みを使うか（2.15 の検査が辿る）。
    pub type alias ExternDef = { name = String, ret = Ty, params = List[Ty], glsl = Body, wgsl = Body, deps = List[Def], derivative = Bool }

    /// 決まった値の配列（GLSL は大域の const・WGSL は使う関数の頭の var）。
    pub type alias ConstArrayDef = { name = String, elem = Ty, values = List[String] }

    /// 大域の変数（GLSL は大域の変数・WGSL は var<private>）。length = 配列の長さ（0 は配列でない）・init = 初めの値の字（言語で同じ字・None なら初めの値なし）・
    /// lang = 片方の言語だけに置く物（None は両方）。
    pub type alias PrivateDef = { name = String, ty = Ty, length = Int32, init = Option[String], lang = Option[Lang] }

    /// 定義（名前で集める単位）。
    enum Def with Eq {
        case Fn(String, Ty, List[(String, Ty)], List[Stmt])
        case Extern(String, Ty, List[Ty], Body, Body, List[Def], Bool)
        case ConstArray(String, Ty, List[String])
        case Private(String, Ty, Int32, Option[String], Option[Lang])
    }

    /// 型つきの式。t は型のマーカー。
    // WhyNot: t を中身で使わずに置かない — Flix は使わない型の引数をコンパイルで止める。いつも None の Option[t] を持たせる。
    enum ExprData[t] { case ExprData(Node, Option[t]) }
    pub type alias Expr[t] = ExprData[t]

    /// 文（外から case を作らせない）。
    pub type alias Statement = Stmt

    /// 定義（外から case を作らせない）。
    pub type alias Definition = Def

    /// 木の組み方の誤り（呼んだプログラマの前提が破れた所）で止める。全部の版を組むテスト（TestShaderDump）が当てる。
    def invalidOrBug(message: String): a = bug!(message)

    // ── 中身の取り出し（printer と検査が使う） ──

    def nodeOf(e: Expr[t]): Node = match e { case ExprData.ExprData(n, _) => n }

    def wrap(n: Node): Expr[t] = ExprData.ExprData(n, None)

    def tyOfNode(n: Node): Ty = match n {
        case Node.Lit(_, t)          => t
        case Node.Ref(_, t)          => t
        case Node.Uniform((_, t, _, _)) => t
        case Node.Bin(_, _, _, t)    => t
        case Node.Neg(_, t)          => t
        case Node.Not(_)             => Ty.Bool
        case Node.Call(_, _, t)      => t
        case Node.Builtin(_, _, t)   => t
        case Node.Construct(t, _)    => t
        case Node.Swizzle(_, _, t)   => t
        case Node.Index(_, _, t)     => t
        case Node.Select(_, _, _, t) => t
        case Node.Paren(x)           => tyOfNode(x)
        case Node.Intrinsic(_, t)    => t
        case Node.Global(_, t)       => t
    }

    /// 式の型。
    pub def tyOf(e: Expr[t]): Ty = tyOfNode(nodeOf(e))

    /// 定義の名前。
    pub def nameOf(d: Definition): String = match d {
        case Def.Fn(name, _, _, _)               => name
        case Def.Extern(name, _, _, _, _, _, _)  => name
        case Def.ConstArray(name, _, _)          => name
        case Def.Private(name, _, _, _, _)       => name
    }

    // ── マーカーごとの型 ──

    /// 型のマーカー t の値の型（引数・局所の変数を作る時に渡す）。
    enum TyWitnessData[t] { case TyWitnessData(Ty, Option[t]) }
    pub type alias TyWitness[t] = TyWitnessData[t]

    def witness(t: Ty): TyWitness[a] = TyWitnessData.TyWitnessData(t, None)

    def tyOfWitness(w: TyWitness[t]): Ty = match w { case TyWitnessData.TyWitnessData(t, _) => t }

    pub def float(): TyWitness[Float] = witness(Ty.F32)
    pub def int(): TyWitness[Int] = witness(Ty.I32)
    pub def boolean(): TyWitness[Boolean] = witness(Ty.Bool)
    pub def vec2(): TyWitness[Vec2] = witness(Ty.Vec2)
    pub def vec3(): TyWitness[Vec3] = witness(Ty.Vec3)
    pub def vec4(): TyWitness[Vec4] = witness(Ty.Vec4)
    pub def ivec2(): TyWitness[IVec2] = witness(Ty.IVec2)
    pub def mat3(): TyWitness[Mat3] = witness(Ty.Mat3)
    pub def mat4(): TyWitness[Mat4] = witness(Ty.Mat4)
    pub def depthTexture(): TyWitness[DepthTex] = witness(Ty.DepthTexture2d)
    pub def texture(): TyWitness[Tex] = witness(Ty.Texture2d)

    // ── 式の組み立て ──

    /// 数のリテラル（字のまま出す。1e-12 などの綴りを保つため字で受ける）。
    pub def f(text: String): Expr[Float] = wrap(Node.Lit(text, Ty.F32))

    /// 整数のリテラル。
    pub def i(x: Int32): Expr[Int] = wrap(Node.Lit(Int32.toString(x), Ty.I32))

    /// 真偽のリテラル。
    pub def bool(b: Bool): Expr[Boolean] = wrap(Node.Lit(if (b) "true" else "false", Ty.Bool))

    /// 名前の読み（引数・局所の変数）。
    pub def ref(w: TyWitness[t], name: String): Expr[t] = wrap(Node.Ref(name, tyOfWitness(w)))

    /// uniform の読み。u#ty はマーカー t と同じ型にする。
    pub def uniform(w: TyWitness[t], u: UniformRef): Expr[t] =
        if (u#ty != tyOfWitness(w)) invalidOrBug("ShaderAst.uniform: ${u#name} の型 ${u#ty} とマーカー ${tyOfWitness(w)} が違う")
        else wrap(Node.Uniform(keyOf(u)))

    /// 言語ごとに中身の違う組み込みの式。
    pub def pixelFromTopLeft(): Expr[IVec2] = wrap(Node.Intrinsic(Intrinsic.PixelFromTopLeft, Ty.IVec2))

    def bin(op: BinOp, a: Expr[x], b: Expr[y], t: Ty): Expr[r] = wrap(Node.Bin(op, nodeOf(a), nodeOf(b), t))

    /// 同じ型どうしの四則。
    pub def add(a: Expr[t], b: Expr[t]): Expr[t] = bin(BinOp.Add, a, b, tyOf(a))
    pub def sub(a: Expr[t], b: Expr[t]): Expr[t] = bin(BinOp.Sub, a, b, tyOf(a))
    pub def mul(a: Expr[t], b: Expr[t]): Expr[t] = bin(BinOp.Mul, a, b, tyOf(a))
    pub def div(a: Expr[t], b: Expr[t]): Expr[t] = bin(BinOp.Div, a, b, tyOf(a))

    /// ベクトルとスカラーの四則（a の型のまま）。
    pub def addS(a: Expr[t], s: Expr[Float]): Expr[t] = bin(BinOp.Add, a, s, tyOf(a))
    pub def subS(a: Expr[t], s: Expr[Float]): Expr[t] = bin(BinOp.Sub, a, s, tyOf(a))
    pub def mulS(a: Expr[t], s: Expr[Float]): Expr[t] = bin(BinOp.Mul, a, s, tyOf(a))
    pub def divS(a: Expr[t], s: Expr[Float]): Expr[t] = bin(BinOp.Div, a, s, tyOf(a))

    /// スカラーとベクトルの積・差（スカラーが左）。
    pub def sMul(s: Expr[Float], a: Expr[t]): Expr[t] = bin(BinOp.Mul, s, a, tyOf(a))
    pub def sSub(s: Expr[Float], a: Expr[t]): Expr[t] = bin(BinOp.Sub, s, a, tyOf(a))

    /// 行列 × ベクトル・行列 × 行列。
    pub def mulMV(m: Expr[Mat4], v: Expr[Vec4]): Expr[Vec4] = bin(BinOp.Mul, m, v, Ty.Vec4)
    pub def mulM3V(m: Expr[Mat3], v: Expr[Vec3]): Expr[Vec3] = bin(BinOp.Mul, m, v, Ty.Vec3)
    pub def mulMM(a: Expr[Mat4], b: Expr[Mat4]): Expr[Mat4] = bin(BinOp.Mul, a, b, Ty.Mat4)

    /// 整数の余り・ビットの積・左シフト。
    pub def modulo(a: Expr[Int], b: Expr[Int]): Expr[Int] = bin(BinOp.Mod, a, b, Ty.I32)
    pub def bitAnd(a: Expr[t], b: Expr[t]): Expr[t] = bin(BinOp.BitAnd, a, b, tyOf(a))

    /// 比べ。
    pub def lt(a: Expr[t], b: Expr[t]): Expr[Boolean] = bin(BinOp.Lt, a, b, Ty.Bool)
    pub def le(a: Expr[t], b: Expr[t]): Expr[Boolean] = bin(BinOp.Le, a, b, Ty.Bool)
    pub def gt(a: Expr[t], b: Expr[t]): Expr[Boolean] = bin(BinOp.Gt, a, b, Ty.Bool)
    pub def ge(a: Expr[t], b: Expr[t]): Expr[Boolean] = bin(BinOp.Ge, a, b, Ty.Bool)
    pub def eq(a: Expr[t], b: Expr[t]): Expr[Boolean] = bin(BinOp.EqOp, a, b, Ty.Bool)
    pub def ne(a: Expr[t], b: Expr[t]): Expr[Boolean] = bin(BinOp.Ne, a, b, Ty.Bool)
    pub def andAlso(a: Expr[Boolean], b: Expr[Boolean]): Expr[Boolean] = bin(BinOp.And, a, b, Ty.Bool)
    pub def orElse(a: Expr[Boolean], b: Expr[Boolean]): Expr[Boolean] = bin(BinOp.Or, a, b, Ty.Bool)

    /// 符号を返す・否定。
    pub def neg(a: Expr[t]): Expr[t] = wrap(Node.Neg(nodeOf(a), tyOf(a)))
    pub def negate(a: Expr[Boolean]): Expr[Boolean] = wrap(Node.Not(nodeOf(a)))

    /// 意味の無い括弧（今の字の括弧を保つ）。
    pub def paren(a: Expr[t]): Expr[t] = wrap(Node.Paren(nodeOf(a)))

    /// cond ? a : b。a と b は両方を計算してよい式だけ（WGSL の select は両側を計算する。危ない側は If の文で書く）。
    pub def ternary(cond: Expr[Boolean], a: Expr[t], b: Expr[t]): Expr[t] = wrap(Node.Select(nodeOf(cond), nodeOf(a), nodeOf(b), tyOf(a)))

    /// 配列の要素。
    pub def index(w: TyWitness[t], array: Expr[a], at: Expr[Int]): Expr[t] = wrap(Node.Index(nodeOf(array), nodeOf(at), tyOfWitness(w)))

    /// 決まった値の配列の要素。
    pub def at(array: Definition, at: Expr[Int]): Expr[Float] = match array {
        case Def.ConstArray(_, elem, _) => wrap(Node.Index(Node.Global(array, elem), nodeOf(at), elem))
        case _                 => invalidOrBug("ShaderAst.at: ${nameOf(array)} は決まった値の配列でない")
    }

    /// 大域の変数の読み。
    pub def readGlobal(w: TyWitness[t], d: Definition): Expr[t] = wrap(Node.Global(d, tyOfWitness(w)))

    // ── swizzle ──

    def swizzle(a: Expr[x], s: String, t: Ty): Expr[r] = wrap(Node.Swizzle(nodeOf(a), s, t))

    pub def x(a: Expr[t]): Expr[Float] = swizzle(a, "x", Ty.F32)
    pub def y(a: Expr[t]): Expr[Float] = swizzle(a, "y", Ty.F32)
    pub def z(a: Expr[t]): Expr[Float] = swizzle(a, "z", Ty.F32)
    pub def w(a: Expr[t]): Expr[Float] = swizzle(a, "w", Ty.F32)
    pub def r(a: Expr[t]): Expr[Float] = swizzle(a, "r", Ty.F32)
    pub def g(a: Expr[t]): Expr[Float] = swizzle(a, "g", Ty.F32)
    pub def b(a: Expr[t]): Expr[Float] = swizzle(a, "b", Ty.F32)
    pub def a(v: Expr[t]): Expr[Float] = swizzle(v, "a", Ty.F32)
    pub def xy(a: Expr[t]): Expr[Vec2] = swizzle(a, "xy", Ty.Vec2)
    pub def zw(a: Expr[t]): Expr[Vec2] = swizzle(a, "zw", Ty.Vec2)
    pub def xz(a: Expr[t]): Expr[Vec2] = swizzle(a, "xz", Ty.Vec2)
    pub def xyz(a: Expr[t]): Expr[Vec3] = swizzle(a, "xyz", Ty.Vec3)
    pub def rgb(a: Expr[t]): Expr[Vec3] = swizzle(a, "rgb", Ty.Vec3)
    pub def ix(a: Expr[IVec2]): Expr[Int] = swizzle(a, "x", Ty.I32)
    pub def iy(a: Expr[IVec2]): Expr[Int] = swizzle(a, "y", Ty.I32)

    // ── 型の作り直し ──

    def construct(t: Ty, args: List[Node]): Expr[r] = wrap(Node.Construct(t, args))

    pub def vec2Of(x1: Expr[Float], y1: Expr[Float]): Expr[Vec2] = construct(Ty.Vec2, nodeOf(x1) :: nodeOf(y1) :: Nil)
    pub def vec3Of(x1: Expr[Float], y1: Expr[Float], z1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(x1) :: nodeOf(y1) :: nodeOf(z1) :: Nil)
    pub def vec3Splat(x1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(x1) :: Nil)
    pub def vec4Of(x1: Expr[Float], y1: Expr[Float], z1: Expr[Float], w1: Expr[Float]): Expr[Vec4] =
        construct(Ty.Vec4, nodeOf(x1) :: nodeOf(y1) :: nodeOf(z1) :: nodeOf(w1) :: Nil)
    pub def vec4FromVec3(v: Expr[Vec3], w1: Expr[Float]): Expr[Vec4] = construct(Ty.Vec4, nodeOf(v) :: nodeOf(w1) :: Nil)
    pub def vec4FromVec2(v: Expr[Vec2], z1: Expr[Float], w1: Expr[Float]): Expr[Vec4] = construct(Ty.Vec4, nodeOf(v) :: nodeOf(z1) :: nodeOf(w1) :: Nil)
    pub def ivec2Of(x1: Expr[Int], y1: Expr[Int]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(x1) :: nodeOf(y1) :: Nil)
    pub def ivec2Splat(x1: Expr[Int]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(x1) :: Nil)
    pub def vec2FromIVec2(v: Expr[IVec2]): Expr[Vec2] = construct(Ty.Vec2, nodeOf(v) :: Nil)
    pub def toFloat(x1: Expr[Int]): Expr[Float] = construct(Ty.F32, nodeOf(x1) :: Nil)
    pub def toInt(x1: Expr[Float]): Expr[Int] = construct(Ty.I32, nodeOf(x1) :: Nil)
    pub def ivec2FromVec2(v: Expr[Vec2]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(v) :: Nil)

    // ── 組み込みの関数（名前は GLSL の物・WGSL の printer が付け替える） ──

    def builtin(name: String, args: List[Node], t: Ty): Expr[r] = wrap(Node.Builtin(name, args, t))

    def same1(name: String, a: Expr[t]): Expr[t] = builtin(name, nodeOf(a) :: Nil, tyOf(a))

    pub def floor(a: Expr[t]): Expr[t] = same1("floor", a)
    pub def abs(a: Expr[t]): Expr[t] = same1("abs", a)
    pub def normalize(a: Expr[t]): Expr[t] = same1("normalize", a)
    pub def asin(a: Expr[Float]): Expr[Float] = same1("asin", a)
    pub def sign(a: Expr[Float]): Expr[Float] = same1("sign", a)
    pub def fwidth(a: Expr[t]): Expr[t] = same1("fwidth", a)
    pub def length(a: Expr[t]): Expr[Float] = builtin("length", nodeOf(a) :: Nil, Ty.F32)
    pub def dot(a: Expr[t], b1: Expr[t]): Expr[Float] = builtin("dot", nodeOf(a) :: nodeOf(b1) :: Nil, Ty.F32)
    pub def distance(a: Expr[t], b1: Expr[t]): Expr[Float] = builtin("distance", nodeOf(a) :: nodeOf(b1) :: Nil, Ty.F32)
    pub def cross(a: Expr[Vec3], b1: Expr[Vec3]): Expr[Vec3] = builtin("cross", nodeOf(a) :: nodeOf(b1) :: Nil, Ty.Vec3)
    pub def atan2(y1: Expr[Float], x1: Expr[Float]): Expr[Float] = builtin("atan", nodeOf(y1) :: nodeOf(x1) :: Nil, Ty.F32)
    pub def max(a: Expr[t], b1: Expr[t]): Expr[t] = builtin("max", nodeOf(a) :: nodeOf(b1) :: Nil, tyOf(a))
    pub def min(a: Expr[t], b1: Expr[t]): Expr[t] = builtin("min", nodeOf(a) :: nodeOf(b1) :: Nil, tyOf(a))
    pub def determinant(m: Expr[Mat3]): Expr[Float] = builtin("determinant", nodeOf(m) :: Nil, Ty.F32)

    /// clamp(a, lo, hi)（同じ型）。
    pub def clamp(a: Expr[t], lo: Expr[t], hi: Expr[t]): Expr[t] = builtin("clamp", nodeOf(a) :: nodeOf(lo) :: nodeOf(hi) :: Nil, tyOf(a))

    /// clamp(ベクトル, スカラー, スカラー)（WGSL の printer がスカラーをベクトルに広げる）。
    pub def clampS(a: Expr[t], lo: Expr[Float], hi: Expr[Float]): Expr[t] = builtin("clamp", nodeOf(a) :: nodeOf(lo) :: nodeOf(hi) :: Nil, tyOf(a))

    /// mix(a, b, スカラー)。
    pub def mixS(a: Expr[t], b1: Expr[t], s: Expr[Float]): Expr[t] = builtin("mix", nodeOf(a) :: nodeOf(b1) :: nodeOf(s) :: Nil, tyOf(a))

    /// 描き先の絵の画素をmip レベル 0 で読む（GPU が描いた描き先。行の数え方は GL のまま）。
    pub def texelFetch(map: Expr[t], at: Expr[IVec2]): Expr[Vec4] = builtin("texelFetch", nodeOf(map) :: nodeOf(at) :: Nil, Ty.Vec4)

    /// 絵のmip レベル 0 の大きさ（画素）。
    pub def textureSize(map: Expr[t]): Expr[IVec2] = builtin("textureSize", nodeOf(map) :: Nil, Ty.IVec2)

    // ── 文の組み立て ──

    /// 変えない局所の値（GLSL は型つきの宣言・WGSL は let）。返り値の式でその名前を読む。
    pub def let_(name: String, e: Expr[t]): (Statement, Expr[t]) =
        (Stmt.Decl(name, tyOf(e), Some(nodeOf(e)), false), wrap(Node.Ref(name, tyOf(e))))

    /// 後で書き替える局所の変数（WGSL は var）。
    pub def var_(name: String, e: Expr[t]): (Statement, Expr[t]) =
        (Stmt.Decl(name, tyOf(e), Some(nodeOf(e)), true), wrap(Node.Ref(name, tyOf(e))))

    /// 初めの値の無い局所の変数。
    pub def varNoInit(w: TyWitness[t], name: String): (Statement, Expr[t]) =
        (Stmt.Decl(name, tyOfWitness(w), None, true), wrap(Node.Ref(name, tyOfWitness(w))))

    /// 代入。
    pub def assign(target: Expr[t], e: Expr[t]): Statement = Stmt.Assign(nodeOf(target), nodeOf(e))

    /// 1 足す（x++）。
    pub def incr(target: Expr[Int]): Statement = Stmt.Incr(nodeOf(target))

    /// 1 行の if（GLSL は波かっこなし）。
    pub def if1(cond: Expr[Boolean], s: Statement): Statement = Stmt.If(nodeOf(cond), s :: Nil, Nil, Layout.Inline)

    /// ブロックの if。
    pub def ifBlock(cond: Expr[Boolean], body: List[Statement]): Statement = Stmt.If(nodeOf(cond), body, Nil, Layout.Block)

    /// ブロックの if と else。
    pub def ifElse(cond: Expr[Boolean], body: List[Statement], otherwise: List[Statement]): Statement = Stmt.If(nodeOf(cond), body, otherwise, Layout.Block)

    /// for (int name = start; name ＜cond＞; name++)。body は数え上げの変数を受けて文を返す。layout は 1 行かブロックか。
    pub def for_(name: String, start: Expr[Int], cond: Expr[Int] -> Expr[Boolean], layout: Layout, body: Expr[Int] -> List[Statement]): Statement =
        let v = wrap(Node.Ref(name, Ty.I32));
        Stmt.For(name, Ty.I32, nodeOf(start), nodeOf(cond(v)), body(v), layout)

    /// 値を返す。
    pub def ret(e: Expr[t]): Statement = Stmt.Return(Some(nodeOf(e)))

    /// 値を返さずに抜ける。
    pub def retVoid(): Statement = Stmt.Return(None)

    /// 画素を捨てる。
    pub def discard_(): Statement = Stmt.Discard

    /// 値を使わない呼び出し。
    pub def eval(e: Expr[t]): Statement = Stmt.Eval(nodeOf(e))

    // ── 定義の組み立て ──

    /// 関数の引数（名前と型）。返り値の式で本文から読む。
    pub def param(w: TyWitness[t], name: String): ((String, Ty), Expr[t]) = ((name, tyOfWitness(w)), wrap(Node.Ref(name, tyOfWitness(w))))

    /// 関数の定義。ret = 返り値の型（Void なら値を返さない）。
    pub def function(name: String, ret: Ty, params: List[(String, Ty)], body: List[Statement]): Definition =
        Def.Fn(name, ret, params, body)

    /// extern 関数の定義。
    pub def externFunction(x: ExternDef): Definition = Def.Extern(x#name, x#ret, x#params, x#glsl, x#wgsl, x#deps, x#derivative)

    /// 決まった値の配列の定義。
    pub def constArray(a: ConstArrayDef): Definition = Def.ConstArray(a#name, a#elem, a#values)

    /// 大域の変数の定義。
    pub def privateVar(p: PrivateDef): Definition = Def.Private(p#name, p#ty, p#length, p#init, p#lang)

    def paramTys(d: Def): List[Ty] = match d {
        case Def.Fn(_, _, params, _)               => params |> List.map(snd)
        case Def.Extern(_, _, params, _, _, _, _)  => params
        case _             => invalidOrBug("ShaderAst.call: ${nameOf(d)} は関数でない")
    }

    def retTy(d: Def): Ty = match d {
        case Def.Fn(_, ret, _, _)               => ret
        case Def.Extern(_, ret, _, _, _, _, _)  => ret
        case _             => invalidOrBug("ShaderAst.call: ${nameOf(d)} は関数でない")
    }

    /// 関数の呼び出しの引数（型を問わずに並べる）。
    pub enum Arg { case Arg(Node) }

    /// 引数 1 つ。
    pub def arg(e: Expr[t]): Arg = Arg.Arg(nodeOf(e))

    /// 関数 d を args で呼ぶ。w = 返り値の型のマーカー（d の返り値の型と同じにする）。引数の型が d の引数と違えば止める。
    pub def call(w: TyWitness[t], d: Definition, args: List[Arg]): Expr[t] =
        let nodes = args |> List.map(a1 -> match a1 { case Arg.Arg(n) => n });
        let got = nodes |> List.map(tyOfNode);
        if (got != paramTys(d)) invalidOrBug("ShaderAst.call: ${nameOf(d)} の引数の型 ${paramTys(d)} に ${got} を渡した")
        else if (retTy(d) != tyOfWitness(w)) invalidOrBug("ShaderAst.call: ${nameOf(d)} の返り値の型 ${retTy(d)} を ${tyOfWitness(w)} で受けた")
        else wrap(Node.Call(d, nodes, tyOfWitness(w)))

    /// 返り値の無い関数 d を呼ぶ文。
    pub def callStmt(d: Definition, args: List[Arg]): Statement =
        let nodes = args |> List.map(a1 -> match a1 { case Arg.Arg(n) => n });
        let got = nodes |> List.map(tyOfNode);
        if (got != paramTys(d)) invalidOrBug("ShaderAst.callStmt: ${nameOf(d)} の引数の型 ${paramTys(d)} に ${got} を渡した")
        else Stmt.Eval(Node.Call(d, nodes, Ty.Void))

    // ── 集める ──

    def depsOfNode(n: Node): List[Def] = match n {
        case Node.Lit(_, _)          => Nil
        case Node.Ref(_, _)          => Nil
        case Node.Uniform(_)         => Nil
        case Node.Bin(_, a1, b1, _)  => depsOfNode(a1) ::: depsOfNode(b1)
        case Node.Neg(a1, _)         => depsOfNode(a1)
        case Node.Not(a1)            => depsOfNode(a1)
        case Node.Call(d, args, _)   => (args |> List.flatMap(depsOfNode)) ::: d :: Nil
        case Node.Builtin(_, args, _) => args |> List.flatMap(depsOfNode)
        case Node.Construct(_, args) => args |> List.flatMap(depsOfNode)
        case Node.Swizzle(a1, _, _)  => depsOfNode(a1)
        case Node.Index(a1, b1, _)   => depsOfNode(a1) ::: depsOfNode(b1)
        case Node.Select(c, a1, b1, _) => depsOfNode(c) ::: depsOfNode(a1) ::: depsOfNode(b1)
        case Node.Paren(a1)          => depsOfNode(a1)
        case Node.Intrinsic(k, _)    => depsOfIntrinsic(k)
        case Node.Global(d, _)       => d :: Nil
    }

    /// 組み込みの式が読む大域の値（WGSL の画素の位置は入口が写す var<private>）。
    def depsOfIntrinsic(k: Intrinsic): List[Def] = match k {
        case Intrinsic.PixelFromTopLeft => fragCoord() :: Nil
    }

    /// frag の画素の位置（WGSL の入口が @builtin(position) を写す。GLSL は gl_FragCoord を直に読むので置かない）。
    pub def fragCoord(): Definition = Def.Private("r3d_fragCoord", Ty.Vec4, 0, None, Some(Lang.Wgsl))

    def depsOfStmt(s: Stmt): List[Def] = match s {
        case Stmt.Decl(_, _, init, _)   => init |> Option.toList |> List.flatMap(depsOfNode)
        case Stmt.Assign(a1, b1)        => depsOfNode(a1) ::: depsOfNode(b1)
        case Stmt.Incr(a1)              => depsOfNode(a1)
        case Stmt.If(c, t, e, _)        => depsOfNode(c) ::: (t |> List.flatMap(depsOfStmt)) ::: (e |> List.flatMap(depsOfStmt))
        case Stmt.For(_, _, a1, c, body, _) => depsOfNode(a1) ::: depsOfNode(c) ::: (body |> List.flatMap(depsOfStmt))
        case Stmt.Return(e)             => e |> Option.toList |> List.flatMap(depsOfNode)
        case Stmt.Discard               => Nil
        case Stmt.Eval(e)               => depsOfNode(e)
    }

    /// 定義 d が直に読む定義（呼んだ関数・読んだ大域の値）。
    def directDeps(d: Def): List[Def] = match d {
        case Def.Fn(_, _, _, body)              => body |> List.flatMap(depsOfStmt)
        case Def.Extern(_, _, _, _, _, deps, _) => deps
        case _                                  => Nil
    }

    /// roots と、それが辿って使う定義を、使う前に 1 回ずつ並べた列（roots の順を保つ）。同じ名前で中身の違う物が 2 つ集まったら止める。
    pub def collect(roots: List[Definition]): List[Definition] =
        let step = (acc: (List[Def], Map[String, Def]), d: Def) -> visit(d, acc);
        let (order, _) = roots |> List.foldLeft(step, (Nil, Map.empty()));
        List.reverse(order)

    def visit(d: Def, acc: (List[Def], Map[String, Def])): (List[Def], Map[String, Def]) =
        let (order, seen) = acc;
        match Map.get(nameOf(d), seen) {
            case Some(prev) =>
                if (prev == d) acc
                else invalidOrBug("ShaderAst.collect: 同じ名前 ${nameOf(d)} で中身の違う定義が 2 つある")
            case None =>
                let (order2, seen2) = directDeps(d) |> List.foldLeft((a1, dep) -> visit(dep, a1), (order, Map.insert(nameOf(d), d, seen)));
                (d :: order2, seen2)
        }

    // ── 一様さの検査（2.15） ──

    /// 定義 d が微分か暗黙の mip レベルの読みを使うか（呼ぶ関係を辿る）。
    def usesDerivative(d: Def): Bool = match d {
        case Def.Fn(_, _, _, body)                       => body |> List.exists(stmtUsesDerivative)
        case Def.Extern(_, _, _, _, _, deps, derivative) => derivative or (deps |> List.exists(usesDerivative))
        case _                                           => false
    }

    def isDerivativeBuiltin(name: String): Bool = name == "fwidth" or name == "dFdx" or name == "dFdy" or name == "texture"

    def nodeUsesDerivative(n: Node): Bool = match n {
        case Node.Bin(_, a1, b1, _)    => nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Node.Neg(a1, _)           => nodeUsesDerivative(a1)
        case Node.Not(a1)              => nodeUsesDerivative(a1)
        case Node.Call(d, args, _)     => usesDerivative(d) or (args |> List.exists(nodeUsesDerivative))
        case Node.Builtin(nm, args, _) => isDerivativeBuiltin(nm) or (args |> List.exists(nodeUsesDerivative))
        case Node.Construct(_, args)   => args |> List.exists(nodeUsesDerivative)
        case Node.Swizzle(a1, _, _)    => nodeUsesDerivative(a1)
        case Node.Index(a1, b1, _)     => nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Node.Select(c, a1, b1, _) => nodeUsesDerivative(c) or nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Node.Paren(a1)            => nodeUsesDerivative(a1)
        case _                         => false
    }

    def stmtUsesDerivative(s: Stmt): Bool = match s {
        case Stmt.Decl(_, _, init, _) => init |> Option.exists(nodeUsesDerivative)
        case Stmt.Assign(a1, b1)      => nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Stmt.Incr(_)             => false
        case Stmt.If(c, t, e, _)      => nodeUsesDerivative(c) or (t |> List.exists(stmtUsesDerivative)) or (e |> List.exists(stmtUsesDerivative))
        case Stmt.For(_, _, a1, c, body, _) => nodeUsesDerivative(a1) or nodeUsesDerivative(c) or (body |> List.exists(stmtUsesDerivative))
        case Stmt.Return(e)           => e |> Option.exists(nodeUsesDerivative)
        case Stmt.Discard             => false
        case Stmt.Eval(e)             => nodeUsesDerivative(e)
    }

    /// 式が一様か（uniform・リテラル・一様な局所の値だけの式。関数の引数と呼び出しは一様でないと見る）。
    def isUniform(uniformLocals: Set[String], n: Node): Bool = match n {
        case Node.Lit(_, _)            => true
        case Node.Uniform(_)           => true
        case Node.Ref(name, _)         => Set.memberOf(name, uniformLocals)
        case Node.Bin(_, a1, b1, _)    => isUniform(uniformLocals, a1) and isUniform(uniformLocals, b1)
        case Node.Neg(a1, _)           => isUniform(uniformLocals, a1)
        case Node.Not(a1)              => isUniform(uniformLocals, a1)
        case Node.Construct(_, args)   => args |> List.forAll(isUniform(uniformLocals))
        case Node.Builtin(_, args, _)  => args |> List.forAll(isUniform(uniformLocals))
        case Node.Swizzle(a1, _, _)    => isUniform(uniformLocals, a1)
        case Node.Paren(a1)            => isUniform(uniformLocals, a1)
        case Node.Select(c, a1, b1, _) => isUniform(uniformLocals, c) and isUniform(uniformLocals, a1) and isUniform(uniformLocals, b1)
        case _                         => false
    }

    /// 検査の途中の状態: 一様な局所の値の名前・一様でない流れの中か（一様でない条件の if・for の中、または一様でない条件の早い return の後）。
    type alias UniformityState = { locals = Set[String], diverged = Bool }

    /// 関数 name の本文 body で、一様でない流れの中に置いた微分・暗黙の mip レベルの読みの誤りの文（無ければ空）。
    /// WhyNot: discard の後を一様でない流れと見ない — WGSL の discard は helper の呼び出しへ落ちるだけで一様さを崩さない。
    def uniformityErrors(name: String, body: List[Stmt]): List[String] =
        snd(checkStmts(name, { locals = Set.empty(), diverged = false }, body))

    def checkStmts(fname: String, st: UniformityState, body: List[Stmt]): (UniformityState, List[String]) =
        body |> List.foldLeft((acc, s) -> {
            let (st1, errs) = acc;
            let (st2, more) = checkStmt(fname, st1, s);
            (st2, errs ::: more)
        }, (st, Nil))

    def checkStmt(fname: String, st: UniformityState, s: Stmt): (UniformityState, List[String]) =
        let here = if (st#diverged and stmtUsesDerivative(s)) "${fname} が一様でない流れの中で微分か暗黙の mip レベルの読みを使う（WGSL のコンパイルが落ちる）" :: Nil else Nil;
        match s {
            case Stmt.Decl(name, _, init, mutable) =>
                let uniform = (not mutable) and (init |> Option.exists(isUniform(st#locals)));
                (if (uniform) { locals = Set.insert(name, st#locals) | st } else st, here)
            case Stmt.If(c, t, e, _) =>
                let inner = { diverged = st#diverged or not isUniform(st#locals, c) | st };
                let inThen = snd(checkStmts(fname, inner, t));
                let inElse = snd(checkStmts(fname, inner, e));
                let returns = (t ::: e) |> List.exists(containsReturn);
                (if (returns and not isUniform(st#locals, c)) { diverged = true | st } else st, here ::: inThen ::: inElse)
            case Stmt.For(_, _, a1, c, body, _) =>
                let inner = { diverged = st#diverged or not (isUniform(st#locals, a1) and isUniform(st#locals, c)) | st };
                (st, here ::: snd(checkStmts(fname, inner, body)))
            case _ => (st, here)
        }

    def containsReturn(s: Stmt): Bool = match s {
        case Stmt.Return(_)          => true
        case Stmt.If(_, t, e, _)     => (t ::: e) |> List.exists(containsReturn)
        case Stmt.For(_, _, _, _, b1, _) => b1 |> List.exists(containsReturn)
        case _                       => false
    }

    /// 定義 d の一様さの誤りの文（関数でなければ空）。print は誤りがあれば止める。
    pub def uniformityErrorsOf(d: Definition): List[String] = match d {
        case Def.Fn(name, _, _, body) => uniformityErrors(name, body)
        case _                        => Nil
    }

    /// defs の関数を全部、一様さの検査に通した defs（誤りがあれば止める）。
    def checked(defs: List[Def]): List[Def] =
        let errors = defs |> List.flatMap(uniformityErrorsOf);
        if (List.isEmpty(errors)) defs else invalidOrBug("ShaderAst: " + String.intercalate("; ", errors))

    // ── printer の共通 ──

    /// 二項の演算の強さ（大きいほど強く結ぶ。C の並び）。
    def precOf(op: BinOp): Int32 = match op {
        case BinOp.Mul    => 12
        case BinOp.Div    => 12
        case BinOp.Mod    => 12
        case BinOp.Add    => 11
        case BinOp.Sub    => 11
        case BinOp.Shl    => 10
        case BinOp.Lt     => 9
        case BinOp.Le     => 9
        case BinOp.Gt     => 9
        case BinOp.Ge     => 9
        case BinOp.EqOp   => 8
        case BinOp.Ne     => 8
        case BinOp.BitAnd => 7
        case BinOp.And    => 4
        case BinOp.Or     => 3
    }

    def opText(op: BinOp): String = match op {
        case BinOp.Add    => "+"
        case BinOp.Sub    => "-"
        case BinOp.Mul    => "*"
        case BinOp.Div    => "/"
        case BinOp.Mod    => "%"
        case BinOp.Lt     => "<"
        case BinOp.Le     => "<="
        case BinOp.Gt     => ">"
        case BinOp.Ge     => ">="
        case BinOp.EqOp   => "=="
        case BinOp.Ne     => "!="
        case BinOp.And    => "&&"
        case BinOp.Or     => "||"
        case BinOp.BitAnd => "&"
        case BinOp.Shl    => "<<"
    }

    /// 節の強さ（括弧が要るかを決める）。
    def precOfNode(n: Node): Int32 = match n {
        case Node.Bin(op, _, _, _)   => precOf(op)
        case Node.Select(_, _, _, _) => 2
        case Node.Neg(_, _)          => 14
        case Node.Not(_)             => 14
        case _                       => 16
    }

    /// uniform の swizzle に、外の swizzle を重ねた swizzle（uPsxTarget.zw の .x は uPsxTarget.z）。
    def composeSwizzle(inner: String, outer: String): String =
        let pick = (ch: Char) -> {
            let k = match ch {
                case 'x' => 0
                case 'r' => 0
                case 'y' => 1
                case 'g' => 1
                case 'z' => 2
                case 'b' => 2
                case _   => 3
            };
            String.charAt(k, inner)
        };
        String.toList(outer) |> List.map(pick) |> List.map(Char.toString) |> String.flatten

    /// uniform を base と swizzle で読む字に、外の swizzle outer を重ねた字。
    def accessText(base: String, swizzle: String, outer: String): String =
        let sw = if (String.isEmpty(swizzle)) outer else if (String.isEmpty(outer)) swizzle else composeSwizzle(swizzle, outer);
        if (String.isEmpty(sw)) base else base + "." + sw

    /// 4 つの空白で字下げした行。
    def indentOf(depth: Int32): String = String.repeat(depth * 4, " ")

    /// 字の部品を 1 つにつなぐ。
    def joinParts(parts: List[String]): String = region rc {
        let sb = StringBuilder.empty(rc);
        List.forEach(s -> StringBuilder.append(s, sb), parts);
        StringBuilder.toString(sb)
    }
}
