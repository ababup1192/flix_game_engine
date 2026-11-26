// ShaderAst — シェーダーを 1 回だけ書き、GLSL（ShaderAst.Glsl）と WGSL（ShaderAst.Wgsl）へ出す小さな型つきの木。
//
// 式は型を持つ組み立ての関数（add・mulS・dot…）でしか作れない（Expr[t] の t は Float・Vec3 などの型のマーカー。trait が受ける型を絞る）。
// 関数は名前で集める: 呼んだ関数・読んだ大域の値を辿り、使う前に 1 回ずつ並べる。同じ名前で中身の違う物と、呼ぶ関係の輪は止める。
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
    pub enum Mat3 { case Mat3 }
    pub enum Mat4 { case Mat4 }
    pub enum Tex { case Tex }
    pub enum DepthTex { case DepthTex }

    /// 四則と符号を返すのが両方の言語で組める型。
    pub trait Numeric[t] {}
    instance Numeric[Float] {}
    instance Numeric[Int] {}
    instance Numeric[Vec2] {}
    instance Numeric[Vec3] {}
    instance Numeric[Vec4] {}
    instance Numeric[IVec2] {}

    /// float のスカラーかベクトル（floor・abs・clamp・mix・微分・f32 との四則）。
    pub trait FloatLike[t] {}
    instance FloatLike[Float] {}
    instance FloatLike[Vec2] {}
    instance FloatLike[Vec3] {}
    instance FloatLike[Vec4] {}

    /// float のベクトル（normalize・dot・length・distance）。
    pub trait FloatVector[t] {}
    instance FloatVector[Vec2] {}
    instance FloatVector[Vec3] {}
    instance FloatVector[Vec4] {}

    /// 大小を比べられるスカラー。
    pub trait Scalar[t] {}
    instance Scalar[Float] {}
    instance Scalar[Int] {}

    /// x・y を読めるベクトル。Elem = 1 つの要素の型。
    pub trait Swizzle[t] {
        type Elem: Type
    }
    instance Swizzle[Vec2] { type Elem = Float }
    instance Swizzle[Vec3] { type Elem = Float }
    instance Swizzle[Vec4] { type Elem = Float }
    instance Swizzle[IVec2] { type Elem = Int }

    /// z を読める float のベクトル。
    pub trait Has3[t] {}
    instance Has3[Vec3] {}
    instance Has3[Vec4] {}

    /// 出す言語。
    pub enum Lang with Eq { case Glsl, Wgsl }

    // ── 木 ──

    /// 二項の演算。
    pub enum BinOp with Eq {
        case Add, Sub, Mul, Div, Mod, Lt, Le, Gt, Ge, EqOp, Ne, And, Or, BitAnd, Shl
    }

    /// 組み込みの関数（名前は言語ごとに printer が選ぶ）。
    pub enum BuiltinFn with Eq {
        case Floor, Abs, Normalize, Asin, Sign, Fwidth, Length, Dot, Distance, Cross, Atan2, Max, Min, Determinant, Clamp, Mix
        /// 絵の mip レベル 0 の大きさ（画素の ivec2）。
        case TextureSize
        /// GPU が描いた奥行きの描き先を画素で読む（行は GL の数え方: 行 0 が NDC の y = −1。WGSL は読む直前に行を返す）。
        case TargetDepthTexel
    }

    /// uniform の読み方の字（base に swizzle を付けて読む。swizzle は空でよい）。
    pub type alias Access = { base = String, swizzle = String }

    /// uniform の読み: name = 名前（鍵）・ty = 型・言語ごとの読む字（None はその言語では宣言しない欄）。
    pub type alias UniformRef = { name = String, ty = Ty, glsl = Option[Access], wgsl = Option[Access] }

    /// 木の中の uniform の読み（名前・型・GLSL の (base, swizzle)・WGSL の (base, swizzle)）。
    // WhyNot: UniformRef の record のまま持たない — Flix の record は Eq を持たず、同じ名前の定義の中身を比べられない。
    type alias UniformKey = (String, Ty, Option[(String, String)], Option[(String, String)])

    def keyOf(u: UniformRef): UniformKey =
        let pair = (a: Access) -> (a#base, a#swizzle);
        (u#name, u#ty, Option.map(pair, u#glsl), Option.map(pair, u#wgsl))

    /// 言語ごとに中身の違う組み込みの式（計画の 2 節の意味の違い）。
    enum Intrinsic with Eq {
        /// 描き先の左上を 0 とする画素の位置（ivec2）。GLSL は gl_FragCoord を描き先の矩形（x, y, 幅, 高さ）の uniform で直す・
        /// WGSL は入口が @builtin(position) を写す r3d_fragCoord（場面の描き先の左上が 0）。
        case PixelFromTopLeft(UniformKey)
        /// 描き先いっぱいを覆う三角形の頂点の clip の位置（vertex_index の 3 点）。
        case FullscreenPosition
        /// 四角の角（0〜1・y は下向き。6 点で 2 つの三角形）。GLSL は頂点の属性 aCorner・WGSL は vertex_index の表。
        case QuadCorner
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
        case Builtin(BuiltinFn, List[Node], Ty)
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

    /// extern 関数: 本文は言語ごとの字。deps = 本文が読む定義（先に並べる）・derivative = 微分か暗黙の mip レベルの読みを使うか（一様さの検査が辿る）。
    pub type alias ExternDef = { name = String, ret = Ty, params = List[Ty], glsl = Body, wgsl = Body, deps = List[Def], derivative = Bool }

    /// 決まった値の配列（GLSL は大域の const・WGSL は使う関数の頭の var）。
    pub type alias ConstArrayDef = { name = String, elem = Ty, values = List[String] }

    /// 定義（名前で集める単位）。Fn = (名前, 返り値の型, 引数, 本文)・Extern = ExternDef の欄の並び・ConstArray = ConstArrayDef の欄の並び・
    /// Private = (名前, 型, 配列の長さ, 初めの値, 片方の言語だけに置くならその言語)（GLSL は大域の変数・WGSL は var<private>）。
    enum Def with Eq {
        case Fn(String, Ty, List[(String, Ty)], List[Stmt])
        case Extern(String, Ty, List[Ty], Body, Body, List[Def], Bool)
        case ConstArray(String, Ty, List[String])
        case Private(String, Ty, Option[Int32], Option[Node], Option[Lang])
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
        case Node.Lit(_, t)             => t
        case Node.Ref(_, t)             => t
        case Node.Uniform((_, t, _, _)) => t
        case Node.Bin(_, _, _, t)       => t
        case Node.Neg(_, t)             => t
        case Node.Not(_)                => Ty.Bool
        case Node.Call(_, _, t)         => t
        case Node.Builtin(_, _, t)      => t
        case Node.Construct(t, _)       => t
        case Node.Swizzle(_, _, t)      => t
        case Node.Index(_, _, t)        => t
        case Node.Select(_, _, _, t)    => t
        case Node.Paren(x1)             => tyOfNode(x1)
        case Node.Intrinsic(_, t)       => t
        case Node.Global(_, t)          => t
    }

    /// 式の型。
    pub def tyOf(e: Expr[t]): Ty = tyOfNode(nodeOf(e))

    /// 定義の名前。
    pub def nameOf(d: Definition): String = match d {
        case Def.Fn(name, _, _, _)              => name
        case Def.Extern(name, _, _, _, _, _, _) => name
        case Def.ConstArray(name, _, _)         => name
        case Def.Private(name, _, _, _, _)      => name
    }

    // ── マーカーごとの型 ──

    /// 型のマーカー t の値の型（引数・局所の変数を作る時に渡す）。
    enum TyWitnessData[t] { case TyWitnessData(Ty, Option[t]) }
    pub type alias TyWitness[t] = TyWitnessData[t]

    def witness(t: Ty): TyWitness[a] = TyWitnessData.TyWitnessData(t, None)

    def tyOfWitness(w1: TyWitness[t]): Ty = match w1 { case TyWitnessData.TyWitnessData(t, _) => t }

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

    /// float のリテラル（字のまま出す。1e-12 などの綴りを保つため字で受ける）。小数点か指数の無い字は止める（WGSL が i32 と読む）。
    pub def f(text: String): Expr[Float] =
        if (String.contains(substr = ".", text) or String.contains(substr = "e", text)) wrap(Node.Lit(text, Ty.F32))
        else invalidOrBug("ShaderAst.f: ${text} に小数点も指数も無い（i32 と読まれる）")

    /// 整数のリテラル。
    pub def i(x1: Int32): Expr[Int] = wrap(Node.Lit(Int32.toString(x1), Ty.I32))

    /// 真偽のリテラル。
    pub def bool(b1: Bool): Expr[Boolean] = wrap(Node.Lit(if (b1) "true" else "false", Ty.Bool))

    /// 名前の読み（引数・局所の変数）。
    pub def ref(w1: TyWitness[t], name: String): Expr[t] = wrap(Node.Ref(name, tyOfWitness(w1)))

    /// uniform の読み。u#ty はマーカー t と同じ型にする。
    pub def uniform(w1: TyWitness[t], u: UniformRef): Expr[t] =
        if (u#ty != tyOfWitness(w1)) invalidOrBug("ShaderAst.uniform: ${u#name} の型 ${u#ty} とマーカー ${tyOfWitness(w1)} が違う")
        else wrap(Node.Uniform(keyOf(u)))

    /// 描き先の左上を 0 とする画素の位置。targetRect = 描き先の矩形 (左下の x, y, 幅, 高さ) の uniform（GLSL の gl_FragCoord は描き先の左下が原点なので、この矩形で直す。WGSL では読まない）。
    pub def pixelFromTopLeft(targetRect: UniformRef): Expr[IVec2] =
        if (targetRect#ty != Ty.Vec4) invalidOrBug("ShaderAst.pixelFromTopLeft: ${targetRect#name} は vec4 でない")
        else wrap(Node.Intrinsic(Intrinsic.PixelFromTopLeft(keyOf(targetRect)), Ty.IVec2))

    /// 描き先いっぱいを覆う三角形の頂点の clip の位置（vertex の入口で使う）。
    pub def fullscreenPosition(): Expr[Vec4] = wrap(Node.Intrinsic(Intrinsic.FullscreenPosition, Ty.Vec4))

    /// 四角の角（0〜1・y は下向き）。
    pub def quadCorner(): Expr[Vec2] = wrap(Node.Intrinsic(Intrinsic.QuadCorner, Ty.Vec2))

    def bin(op: BinOp, a1: Expr[x], b1: Expr[y], t: Ty): Expr[r] = wrap(Node.Bin(op, nodeOf(a1), nodeOf(b1), t))

    /// 同じ型どうしの四則。
    pub def add(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Add, a1, b1, tyOf(a1))
    pub def sub(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Sub, a1, b1, tyOf(a1))
    pub def mul(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Mul, a1, b1, tyOf(a1))
    pub def div(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Div, a1, b1, tyOf(a1))

    /// float のベクトルと f32 の四則（a1 の型のまま）。
    pub def addS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Add, a1, s, tyOf(a1))
    pub def subS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Sub, a1, s, tyOf(a1))
    pub def mulS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Mul, a1, s, tyOf(a1))
    pub def divS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Div, a1, s, tyOf(a1))

    /// f32 と float のベクトルの積・差（f32 が左）。
    pub def sMul(s: Expr[Float], a1: Expr[t]): Expr[t] with FloatLike[t] = bin(BinOp.Mul, s, a1, tyOf(a1))
    pub def sSub(s: Expr[Float], a1: Expr[t]): Expr[t] with FloatLike[t] = bin(BinOp.Sub, s, a1, tyOf(a1))

    /// 行列 × ベクトル・行列 × 行列。
    pub def mulMV(m: Expr[Mat4], v: Expr[Vec4]): Expr[Vec4] = bin(BinOp.Mul, m, v, Ty.Vec4)
    pub def mulM3V(m: Expr[Mat3], v: Expr[Vec3]): Expr[Vec3] = bin(BinOp.Mul, m, v, Ty.Vec3)
    pub def mulMM(a1: Expr[Mat4], b1: Expr[Mat4]): Expr[Mat4] = bin(BinOp.Mul, a1, b1, Ty.Mat4)

    /// 整数の余り・ビットの積。
    pub def modulo(a1: Expr[Int], b1: Expr[Int]): Expr[Int] = bin(BinOp.Mod, a1, b1, Ty.I32)
    pub def bitAnd(a1: Expr[Int], b1: Expr[Int]): Expr[Int] = bin(BinOp.BitAnd, a1, b1, Ty.I32)

    /// スカラーの比べ。
    pub def lt(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Lt, a1, b1, Ty.Bool)
    pub def le(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Le, a1, b1, Ty.Bool)
    pub def gt(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Gt, a1, b1, Ty.Bool)
    pub def ge(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Ge, a1, b1, Ty.Bool)
    pub def eq(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.EqOp, a1, b1, Ty.Bool)
    pub def ne(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Ne, a1, b1, Ty.Bool)

    /// 論理の積・和・否定。
    pub def and_(a1: Expr[Boolean], b1: Expr[Boolean]): Expr[Boolean] = bin(BinOp.And, a1, b1, Ty.Bool)
    pub def or_(a1: Expr[Boolean], b1: Expr[Boolean]): Expr[Boolean] = bin(BinOp.Or, a1, b1, Ty.Bool)
    pub def not_(a1: Expr[Boolean]): Expr[Boolean] = wrap(Node.Not(nodeOf(a1)))

    /// 符号を返す。
    pub def neg(a1: Expr[t]): Expr[t] with Numeric[t] = wrap(Node.Neg(nodeOf(a1), tyOf(a1)))

    /// 意味の無い括弧（今の字の括弧を保つ）。
    pub def paren(a1: Expr[t]): Expr[t] = wrap(Node.Paren(nodeOf(a1)))

    /// cond ? a1 : b1。a1 と b1 は両方を計算してよい式だけ（WGSL の select は両側を計算する。危ない側は If の文で書く）。
    pub def ternary(cond: Expr[Boolean], a1: Expr[t], b1: Expr[t]): Expr[t] = wrap(Node.Select(nodeOf(cond), nodeOf(a1), nodeOf(b1), tyOf(a1)))

    /// 決まった値の配列 array の index 番目（配列の要素は f32）。
    pub def at(array: Definition, index: Expr[Int]): Expr[Float] = match array {
        case Def.ConstArray(_, Ty.F32, _) => wrap(Node.Index(Node.Global(array, Ty.F32), nodeOf(index), Ty.F32))
        case _                            => invalidOrBug("ShaderAst.at: ${nameOf(array)} は f32 の決まった値の配列でない")
    }

    /// 大域の変数 d の値（配列でない物）。
    pub def readGlobal(w1: TyWitness[t], d: Definition): Expr[t] = match d {
        case Def.Private(_, ty, None, _, _) if ty == tyOfWitness(w1) => wrap(Node.Global(d, ty))
        case _ => invalidOrBug("ShaderAst.readGlobal: ${nameOf(d)} は ${tyOfWitness(w1)} の大域の変数でない")
    }

    /// 大域の配列の変数 d の index 番目。
    pub def readGlobalAt(w1: TyWitness[t], d: Definition, index: Expr[Int]): Expr[t] = match d {
        case Def.Private(_, ty, Some(_), _, _) if ty == tyOfWitness(w1) => wrap(Node.Index(Node.Global(d, ty), nodeOf(index), ty))
        case _ => invalidOrBug("ShaderAst.readGlobalAt: ${nameOf(d)} は ${tyOfWitness(w1)} の大域の配列でない")
    }

    // ── swizzle ──

    def swizzle(a1: Expr[x], s: String, t: Ty): Expr[r] = wrap(Node.Swizzle(nodeOf(a1), s, t))

    def elemTy(v: Expr[t]): Ty = if (tyOf(v) == Ty.IVec2) Ty.I32 else Ty.F32

    pub def x(v: Expr[t]): Expr[Swizzle.Elem[t]] with Swizzle[t] = swizzle(v, "x", elemTy(v))
    pub def y(v: Expr[t]): Expr[Swizzle.Elem[t]] with Swizzle[t] = swizzle(v, "y", elemTy(v))
    pub def z(v: Expr[t]): Expr[Float] with Has3[t] = swizzle(v, "z", Ty.F32)
    pub def w(v: Expr[Vec4]): Expr[Float] = swizzle(v, "w", Ty.F32)
    pub def r(v: Expr[t]): Expr[Float] with FloatVector[t] = swizzle(v, "r", Ty.F32)
    pub def g(v: Expr[t]): Expr[Float] with FloatVector[t] = swizzle(v, "g", Ty.F32)
    pub def b(v: Expr[t]): Expr[Float] with Has3[t] = swizzle(v, "b", Ty.F32)
    pub def a(v: Expr[Vec4]): Expr[Float] = swizzle(v, "a", Ty.F32)
    pub def xy(v: Expr[t]): Expr[Vec2] with Has3[t] = swizzle(v, "xy", Ty.Vec2)
    pub def xz(v: Expr[t]): Expr[Vec2] with Has3[t] = swizzle(v, "xz", Ty.Vec2)
    pub def zw(v: Expr[Vec4]): Expr[Vec2] = swizzle(v, "zw", Ty.Vec2)
    pub def xyz(v: Expr[Vec4]): Expr[Vec3] = swizzle(v, "xyz", Ty.Vec3)
    pub def rgb(v: Expr[Vec4]): Expr[Vec3] = swizzle(v, "rgb", Ty.Vec3)

    // ── 型の作り直し ──

    def construct(t: Ty, args: List[Node]): Expr[r] = wrap(Node.Construct(t, args))

    pub def vec2Of(x1: Expr[Float], y1: Expr[Float]): Expr[Vec2] = construct(Ty.Vec2, nodeOf(x1) :: nodeOf(y1) :: Nil)
    pub def vec3Of(x1: Expr[Float], y1: Expr[Float], z1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(x1) :: nodeOf(y1) :: nodeOf(z1) :: Nil)
    pub def vec3Splat(x1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(x1) :: Nil)
    pub def vec4Of(x1: Expr[Float], y1: Expr[Float], z1: Expr[Float], w1: Expr[Float]): Expr[Vec4] =
        construct(Ty.Vec4, nodeOf(x1) :: nodeOf(y1) :: nodeOf(z1) :: nodeOf(w1) :: Nil)
    pub def vec4FromVec3(v: Expr[Vec3], w1: Expr[Float]): Expr[Vec4] = construct(Ty.Vec4, nodeOf(v) :: nodeOf(w1) :: Nil)
    pub def ivec2Of(x1: Expr[Int], y1: Expr[Int]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(x1) :: nodeOf(y1) :: Nil)
    pub def ivec2Splat(x1: Expr[Int]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(x1) :: Nil)
    pub def ivec2FromVec2(v: Expr[Vec2]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(v) :: Nil)
    pub def vec2FromIVec2(v: Expr[IVec2]): Expr[Vec2] = construct(Ty.Vec2, nodeOf(v) :: Nil)
    pub def toFloat(x1: Expr[Int]): Expr[Float] = construct(Ty.F32, nodeOf(x1) :: Nil)
    pub def toInt(x1: Expr[Float]): Expr[Int] = construct(Ty.I32, nodeOf(x1) :: Nil)

    // ── 組み込みの関数 ──

    def builtin(fun: BuiltinFn, args: List[Node], t: Ty): Expr[r] = wrap(Node.Builtin(fun, args, t))

    def same1(fun: BuiltinFn, a1: Expr[t]): Expr[t] = builtin(fun, nodeOf(a1) :: Nil, tyOf(a1))

    pub def floor(a1: Expr[t]): Expr[t] with FloatLike[t] = same1(BuiltinFn.Floor, a1)
    pub def abs(a1: Expr[t]): Expr[t] with FloatLike[t] = same1(BuiltinFn.Abs, a1)
    pub def normalize(a1: Expr[t]): Expr[t] with FloatVector[t] = same1(BuiltinFn.Normalize, a1)
    pub def asin(a1: Expr[Float]): Expr[Float] = same1(BuiltinFn.Asin, a1)
    pub def sign(a1: Expr[Float]): Expr[Float] = same1(BuiltinFn.Sign, a1)
    pub def fwidth(a1: Expr[t]): Expr[t] with FloatLike[t] = same1(BuiltinFn.Fwidth, a1)
    pub def length(a1: Expr[t]): Expr[Float] with FloatVector[t] = builtin(BuiltinFn.Length, nodeOf(a1) :: Nil, Ty.F32)
    pub def dot(a1: Expr[t], b1: Expr[t]): Expr[Float] with FloatVector[t] = builtin(BuiltinFn.Dot, nodeOf(a1) :: nodeOf(b1) :: Nil, Ty.F32)
    pub def distance(a1: Expr[t], b1: Expr[t]): Expr[Float] with FloatVector[t] = builtin(BuiltinFn.Distance, nodeOf(a1) :: nodeOf(b1) :: Nil, Ty.F32)
    pub def cross(a1: Expr[Vec3], b1: Expr[Vec3]): Expr[Vec3] = builtin(BuiltinFn.Cross, nodeOf(a1) :: nodeOf(b1) :: Nil, Ty.Vec3)
    pub def atan2(y1: Expr[Float], x1: Expr[Float]): Expr[Float] = builtin(BuiltinFn.Atan2, nodeOf(y1) :: nodeOf(x1) :: Nil, Ty.F32)
    pub def max(a1: Expr[t], b1: Expr[t]): Expr[t] with FloatLike[t] = builtin(BuiltinFn.Max, nodeOf(a1) :: nodeOf(b1) :: Nil, tyOf(a1))
    pub def min(a1: Expr[t], b1: Expr[t]): Expr[t] with FloatLike[t] = builtin(BuiltinFn.Min, nodeOf(a1) :: nodeOf(b1) :: Nil, tyOf(a1))
    pub def determinant(m: Expr[Mat3]): Expr[Float] = builtin(BuiltinFn.Determinant, nodeOf(m) :: Nil, Ty.F32)

    /// clamp(a1, lo, hi)（同じ型）。
    pub def clamp(a1: Expr[t], lo: Expr[t], hi: Expr[t]): Expr[t] with FloatLike[t] = builtin(BuiltinFn.Clamp, nodeOf(a1) :: nodeOf(lo) :: nodeOf(hi) :: Nil, tyOf(a1))

    /// clamp(float のベクトル, f32, f32)（WGSL の printer が f32 をベクトルに広げる）。
    pub def clampS(a1: Expr[t], lo: Expr[Float], hi: Expr[Float]): Expr[t] with FloatLike[t] = builtin(BuiltinFn.Clamp, nodeOf(a1) :: nodeOf(lo) :: nodeOf(hi) :: Nil, tyOf(a1))

    /// clamp(ivec2, ivec2, ivec2)。
    pub def clampI(a1: Expr[IVec2], lo: Expr[IVec2], hi: Expr[IVec2]): Expr[IVec2] = builtin(BuiltinFn.Clamp, nodeOf(a1) :: nodeOf(lo) :: nodeOf(hi) :: Nil, Ty.IVec2)

    /// 奥行きの絵 map の mip レベル 0 の大きさ（画素）。
    pub def textureSize(map: Expr[DepthTex]): Expr[IVec2] = builtin(BuiltinFn.TextureSize, nodeOf(map) :: Nil, Ty.IVec2)

    /// GPU が描いた奥行きの描き先 map の画素 texel の奥行き（行は GL の数え方。WGSL で描いた地図は行 0 が上なので、WGSL の字は読む直前に行を返す）。
    pub def targetDepthTexel(map: Expr[DepthTex], texel: Expr[IVec2]): Expr[Float] = builtin(BuiltinFn.TargetDepthTexel, nodeOf(map) :: nodeOf(texel) :: Nil, Ty.F32)

    /// mix(a1, b1, f32)。
    pub def mixS(a1: Expr[t], b1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = builtin(BuiltinFn.Mix, nodeOf(a1) :: nodeOf(b1) :: nodeOf(s) :: Nil, tyOf(a1))

    // ── 文の組み立て ──

    /// 変えない局所の値（GLSL は型つきの宣言・WGSL は let）。返り値の式でその名前を読む。
    pub def let_(name: String, e: Expr[t]): (Statement, Expr[t]) =
        (Stmt.Decl(name, tyOf(e), Some(nodeOf(e)), false), wrap(Node.Ref(name, tyOf(e))))

    /// 後で書き替える局所の変数（WGSL は var）。
    pub def var_(name: String, e: Expr[t]): (Statement, Expr[t]) =
        (Stmt.Decl(name, tyOf(e), Some(nodeOf(e)), true), wrap(Node.Ref(name, tyOf(e))))

    /// 初めの値の無い局所の変数。
    pub def varNoInit(w1: TyWitness[t], name: String): (Statement, Expr[t]) =
        (Stmt.Decl(name, tyOfWitness(w1), None, true), wrap(Node.Ref(name, tyOfWitness(w1))))

    /// 代入（target は var_ の変数か大域の変数。違えば組む時に止める）。
    pub def assign(target: Expr[t], e: Expr[t]): Statement = Stmt.Assign(nodeOf(target), nodeOf(e))

    /// 1 足す（x++）。
    pub def incr(target: Expr[Int]): Statement = Stmt.Incr(nodeOf(target))

    /// 1 行の if（GLSL は波かっこなし）。
    pub def ifInline(cond: Expr[Boolean], s: Statement): Statement = Stmt.If(nodeOf(cond), s :: Nil, Nil, Layout.Inline)

    /// ブロックの if。
    pub def ifBlock(cond: Expr[Boolean], body: List[Statement]): Statement = Stmt.If(nodeOf(cond), body, Nil, Layout.Block)

    /// ブロックの if と else。
    pub def ifElse(cond: Expr[Boolean], body: List[Statement], otherwise: List[Statement]): Statement = Stmt.If(nodeOf(cond), body, otherwise, Layout.Block)

    /// for (int name = start; cond; name++)。body は数え上げの変数を受けて文を返す。layout は 1 行かブロックか。
    pub def for_(name: String, start: Expr[Int], cond: Expr[Int] -> Expr[Boolean], layout: Layout, body: Expr[Int] -> List[Statement]): Statement =
        let v = wrap(Node.Ref(name, Ty.I32));
        Stmt.For(name, Ty.I32, nodeOf(start), nodeOf(cond(v)), body(v), layout)

    /// 値を返す。
    pub def ret(e: Expr[t]): Statement = Stmt.Return(Some(nodeOf(e)))

    /// 値を返さずに抜ける。
    pub def retVoid(): Statement = Stmt.Return(None)

    /// 画素を捨てる。
    pub def discard_(): Statement = Stmt.Discard

    // ── 定義の組み立て ──

    /// 関数の引数（名前と型）。返り値の式で本文から読む。
    pub def param(w1: TyWitness[t], name: String): ((String, Ty), Expr[t]) = ((name, tyOfWitness(w1)), wrap(Node.Ref(name, tyOfWitness(w1))))

    /// 関数の定義。ret = 返り値の型（Void なら値を返さない）。
    pub def function(name: String, ret: Ty, params: List[(String, Ty)], body: List[Statement]): Definition =
        Def.Fn(name, ret, params, body)

    /// extern 関数の定義。
    pub def externFunction(x1: ExternDef): Definition = Def.Extern(x1#name, x1#ret, x1#params, x1#glsl, x1#wgsl, x1#deps, x1#derivative)

    /// 決まった値の配列の定義。
    pub def constArray(c: ConstArrayDef): Definition = Def.ConstArray(c#name, c#elem, c#values)

    /// 大域の変数の定義（name・型・配列の長さ・初めの値・片方の言語だけに置くならその言語）。
    pub def privateVar(name: String, w1: TyWitness[t], length: Option[Int32], init: Option[Expr[t]], lang: Option[Lang]): Definition =
        Def.Private(name, tyOfWitness(w1), length, Option.map(nodeOf, init), lang)

    def paramTys(d: Def): List[Ty] = match d {
        case Def.Fn(_, _, params, _)              => params |> List.map(snd)
        case Def.Extern(_, _, params, _, _, _, _) => params
        case _                                    => invalidOrBug("ShaderAst.call: ${nameOf(d)} は関数でない")
    }

    def retTy(d: Def): Ty = match d {
        case Def.Fn(_, ret, _, _)              => ret
        case Def.Extern(_, ret, _, _, _, _, _) => ret
        case _                                 => invalidOrBug("ShaderAst.call: ${nameOf(d)} は関数でない")
    }

    /// 関数の呼び出しの引数（型を問わずに並べる）。
    enum ArgData { case ArgData(Node) }
    pub type alias Arg = ArgData

    /// 引数 1 つ。
    pub def arg(e: Expr[t]): Arg = ArgData.ArgData(nodeOf(e))

    def argNodes(d: Def, args: List[Arg]): List[Node] =
        let nodes = args |> List.map(a1 -> match a1 { case ArgData.ArgData(n) => n });
        let got = nodes |> List.map(tyOfNode);
        if (got != paramTys(d)) invalidOrBug("ShaderAst.call: ${nameOf(d)} の引数の型 ${paramTys(d)} に ${got} を渡した") else nodes

    /// 関数 d を args で呼ぶ。w1 = 返り値の型のマーカー（d の返り値の型と同じにする）。引数の型が d の引数と違えば止める。
    pub def call(w1: TyWitness[t], d: Definition, args: List[Arg]): Expr[t] =
        if (retTy(d) != tyOfWitness(w1)) invalidOrBug("ShaderAst.call: ${nameOf(d)} の返り値の型 ${retTy(d)} を ${tyOfWitness(w1)} で受けた")
        else wrap(Node.Call(d, argNodes(d, args), tyOfWitness(w1)))

    /// 返り値の無い関数 d を呼ぶ文。
    pub def callStmt(d: Definition, args: List[Arg]): Statement =
        if (retTy(d) != Ty.Void) invalidOrBug("ShaderAst.callStmt: ${nameOf(d)} は値を返す")
        else Stmt.Eval(Node.Call(d, argNodes(d, args), Ty.Void))

    // ── 集める ──

    def depsOfNode(n: Node): List[Def] = match n {
        case Node.Bin(_, a1, b1, _)    => depsOfNode(a1) ::: depsOfNode(b1)
        case Node.Neg(a1, _)           => depsOfNode(a1)
        case Node.Not(a1)              => depsOfNode(a1)
        case Node.Call(d, args, _)     => (args |> List.flatMap(depsOfNode)) ::: d :: Nil
        case Node.Builtin(_, args, _)  => args |> List.flatMap(depsOfNode)
        case Node.Construct(_, args)   => args |> List.flatMap(depsOfNode)
        case Node.Swizzle(a1, _, _)    => depsOfNode(a1)
        case Node.Index(a1, b1, _)     => depsOfNode(a1) ::: depsOfNode(b1)
        case Node.Select(c, a1, b1, _) => depsOfNode(c) ::: depsOfNode(a1) ::: depsOfNode(b1)
        case Node.Paren(a1)            => depsOfNode(a1)
        case Node.Intrinsic(k, _)      => depsOfIntrinsic(k)
        case Node.Global(d, _)         => d :: Nil
        case _                         => Nil
    }

    /// 組み込みの式が読む大域の値（片方の言語だけの物は Private と Extern の本文で分かれる）。
    def depsOfIntrinsic(k: Intrinsic): List[Def] = match k {
        case Intrinsic.PixelFromTopLeft(_) => fragCoord() :: Nil
        case Intrinsic.FullscreenPosition  => vertexIndex() :: Nil
        case Intrinsic.QuadCorner          => vertexIndex() :: quadCornerTable() :: Nil
    }

    /// frag の画素の位置（WGSL の入口が @builtin(position) を写す。GLSL は gl_FragCoord を直に読むので置かない）。
    pub def fragCoord(): Definition = Def.Private("r3d_fragCoord", Ty.Vec4, None, None, Some(Lang.Wgsl))

    /// vertex の頂点の番号（WGSL の入口が @builtin(vertex_index) を写す。GLSL は gl_VertexID を直に読む）。
    pub def vertexIndex(): Definition = Def.Private("r3d_vertexIndex", Ty.U32, None, None, Some(Lang.Wgsl))

    /// 四角の角の表（WGSL だけ。GLSL は頂点の属性 aCorner を読む）。並びは GL の四角の buffer と同じ。
    def quadCornerTable(): Definition =
        Def.Extern("r3d_quadCorner", Ty.Vec2, Ty.U32 :: Nil, Body.Outside,
            Body.Text("fn r3d_quadCorner(i: u32) -> vec2f {\n" +
                      "    var corners = array<vec2f, 6>(vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0));\n" +
                      "    return corners[i];\n" +
                      "}\n"), Nil, false)

    def depsOfStmt(s: Stmt): List[Def] = match s {
        case Stmt.Decl(_, _, init, _)       => init |> Option.toList |> List.flatMap(depsOfNode)
        case Stmt.Assign(a1, b1)            => depsOfNode(a1) ::: depsOfNode(b1)
        case Stmt.Incr(a1)                  => depsOfNode(a1)
        case Stmt.If(c, t, e, _)            => depsOfNode(c) ::: (t |> List.flatMap(depsOfStmt)) ::: (e |> List.flatMap(depsOfStmt))
        case Stmt.For(_, _, a1, c, body, _) => depsOfNode(a1) ::: depsOfNode(c) ::: (body |> List.flatMap(depsOfStmt))
        case Stmt.Return(e)                 => e |> Option.toList |> List.flatMap(depsOfNode)
        case Stmt.Discard                   => Nil
        case Stmt.Eval(e)                   => depsOfNode(e)
    }

    /// 定義 d が直に読む定義（呼んだ関数・読んだ大域の値）。
    def directDeps(d: Def): List[Def] = match d {
        case Def.Fn(_, _, _, body)              => body |> List.flatMap(depsOfStmt)
        case Def.Extern(_, _, _, _, _, deps, _) => deps
        case Def.Private(_, _, _, init, _)      => init |> Option.toList |> List.flatMap(depsOfNode)
        case _                                  => Nil
    }

    /// 集める途中の状態: 並べた列（逆順）・名前 → 定義・辿っている途中の名前（輪を見つける）。
    type alias CollectState = { order = List[Def], seen = Map[String, Def], open = Set[String] }

    /// roots と、それが辿って使う定義を、使う前に 1 回ずつ並べた列（roots の順を保つ）。
    /// 同じ名前で中身の違う定義・呼ぶ関係の輪があれば Err。
    pub def collect(roots: List[Definition]): Result[String, List[Definition]] =
        roots |> List.foldLeft((acc, d) -> Result.flatMap(st -> visit(d, st), acc), Ok({ order = Nil, seen = Map.empty(), open = Set.empty() }))
              |> Result.map(st -> List.reverse(st#order))

    /// collect の Err で止める版。
    pub def collectOrBug(roots: List[Definition]): List[Definition] = match collect(roots) {
        case Ok(defs) => defs
        case Err(msg) => invalidOrBug("ShaderAst.collect: " + msg)
    }

    def visit(d: Def, st: CollectState): Result[String, CollectState] =
        let name = nameOf(d);
        if (Set.memberOf(name, st#open)) Err("呼ぶ関係が ${name} で輪になっている")
        else match Map.get(name, st#seen) {
            case Some(prev) => if (prev == d) Ok(st) else Err("同じ名前 ${name} で中身の違う定義が 2 つある")
            case None =>
                let start = Ok({ open = Set.insert(name, st#open) | st });
                directDeps(d) |> List.foldLeft((acc, dep) -> Result.flatMap(s1 -> visit(dep, s1), acc), start)
                              |> Result.map(s2 -> { order = d :: s2#order, seen = Map.insert(name, d, s2#seen), open = Set.remove(name, s2#open) })
        }

    // ── 組む時の検査（一様さ・代入の先・返り値の型） ──

    /// 定義 d が微分か暗黙の mip レベルの読みを使うか（呼ぶ関係を辿る）。
    def usesDerivative(d: Def): Bool = match d {
        case Def.Fn(_, _, _, body)                       => body |> List.exists(stmtUsesDerivative)
        case Def.Extern(_, _, _, _, _, deps, derivative) => derivative or (deps |> List.exists(usesDerivative))
        case _                                           => false
    }

    def isDerivative(fun: BuiltinFn): Bool = fun == BuiltinFn.Fwidth

    def nodeUsesDerivative(n: Node): Bool = match n {
        case Node.Bin(_, a1, b1, _)     => nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Node.Neg(a1, _)            => nodeUsesDerivative(a1)
        case Node.Not(a1)               => nodeUsesDerivative(a1)
        case Node.Call(d, args, _)      => usesDerivative(d) or (args |> List.exists(nodeUsesDerivative))
        case Node.Builtin(fun, args, _) => isDerivative(fun) or (args |> List.exists(nodeUsesDerivative))
        case Node.Construct(_, args)    => args |> List.exists(nodeUsesDerivative)
        case Node.Swizzle(a1, _, _)     => nodeUsesDerivative(a1)
        case Node.Index(a1, b1, _)      => nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Node.Select(c, a1, b1, _)  => nodeUsesDerivative(c) or nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Node.Paren(a1)             => nodeUsesDerivative(a1)
        case _                          => false
    }

    def stmtUsesDerivative(s: Stmt): Bool = match s {
        case Stmt.Decl(_, _, init, _)       => init |> Option.exists(nodeUsesDerivative)
        case Stmt.Assign(a1, b1)            => nodeUsesDerivative(a1) or nodeUsesDerivative(b1)
        case Stmt.If(c, t, e, _)            => nodeUsesDerivative(c) or (t |> List.exists(stmtUsesDerivative)) or (e |> List.exists(stmtUsesDerivative))
        case Stmt.For(_, _, a1, c, body, _) => nodeUsesDerivative(a1) or nodeUsesDerivative(c) or (body |> List.exists(stmtUsesDerivative))
        case Stmt.Return(e)                 => e |> Option.exists(nodeUsesDerivative)
        case Stmt.Eval(e)                   => nodeUsesDerivative(e)
        case _                              => false
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

    /// 一様さの検査の途中の状態: locals = 一様な局所の値の名前・diverged = 一様でない流れの中か
    /// （一様でない条件の if・for の中、または一様でない流れの中の return の後）・returned = このブロックで一様でない流れの中から return したか。
    type alias UniformityState = { locals = Set[String], diverged = Bool, returned = Bool }

    /// 関数 name の本文 body で、一様でない流れの中に置いた微分・暗黙の mip レベルの読みの誤りの文（無ければ空）。
    /// WhyNot: discard の後を一様でない流れと見ない — WGSL の discard は helper の呼び出しへ落ちるだけで一様さを崩さない。
    def uniformityErrors(name: String, body: List[Stmt]): List[String] =
        snd(checkStmts(name, { locals = Set.empty(), diverged = false, returned = false }, body))

    def checkStmts(fname: String, st: UniformityState, body: List[Stmt]): (UniformityState, List[String]) =
        body |> List.foldLeft((acc, s) -> {
            let (st1, errs) = acc;
            let (st2, more) = checkStmt(fname, st1, s);
            (st2, errs ::: more)
        }, (st, Nil))

    def derivativeError(fname: String): String = "${fname} が一様でない流れの中で微分か暗黙の mip レベルの読みを使う（WGSL のコンパイルが落ちる）"

    /// 中のブロックを検査した後の外の状態（中で一様でない流れから return したら、その後ろは一様でない流れ）。
    def afterBlock(st: UniformityState, inner: List[UniformityState]): UniformityState =
        if (inner |> List.exists(s -> s#returned)) { diverged = true, returned = true | st } else st

    def leafErrors(fname: String, st: UniformityState, s: Stmt): List[String] =
        if (st#diverged and stmtUsesDerivative(s)) derivativeError(fname) :: Nil else Nil

    def checkStmt(fname: String, st: UniformityState, s: Stmt): (UniformityState, List[String]) = match s {
        case Stmt.Decl(name, _, init, mutable) =>
            let uniform = (not mutable) and (init |> Option.exists(isUniform(st#locals)));
            (if (uniform) { locals = Set.insert(name, st#locals) | st } else st, leafErrors(fname, st, s))
        case Stmt.If(c, t, e, _) =>
            let condErr = if (st#diverged and nodeUsesDerivative(c)) derivativeError(fname) :: Nil else Nil;
            let inner = { diverged = st#diverged or not isUniform(st#locals, c), returned = false | st };
            let (stT, errT) = checkStmts(fname, inner, t);
            let (stE, errE) = checkStmts(fname, inner, e);
            (afterBlock(st, stT :: stE :: Nil), condErr ::: errT ::: errE)
        case Stmt.For(_, _, a1, c, body, _) =>
            let inner = { diverged = st#diverged or not (isUniform(st#locals, a1) and isUniform(st#locals, c)), returned = false | st };
            let (stB, errB) = checkStmts(fname, inner, body);
            (afterBlock(st, stB :: Nil), errB)
        case Stmt.Return(_) =>
            ({ returned = st#returned or st#diverged | st }, leafErrors(fname, st, s))
        case _ =>
            (st, leafErrors(fname, st, s))
    }

    /// 関数の本文の、代入の先と返り値の型の誤りの文（var_ でない名前へ代入・返り値の型が関数と違う）。
    def statementErrors(fname: String, ret: Ty, mutable: Set[String], body: List[Stmt]): List[String] =
        let step = (acc: (Set[String], List[String]), s: Stmt) -> {
            let (vars, errs) = acc;
            let vars2 = match s {
                case Stmt.Decl(name, _, _, true) => Set.insert(name, vars)
                case _                           => vars
            };
            (vars2, errs ::: stmtErrors(fname, ret, vars2, s))
        };
        snd(body |> List.foldLeft(step, (mutable, Nil)))

    def isWritable(vars: Set[String], target: Node): Bool = match target {
        case Node.Ref(name, _)                          => Set.memberOf(name, vars)
        case Node.Global(Def.Private(_, _, _, _, _), _) => true
        case Node.Index(inner, _, _)                    => isWritable(vars, inner)
        case _                                          => false
    }

    def stmtErrors(fname: String, ret: Ty, vars: Set[String], s: Stmt): List[String] = match s {
        case Stmt.Assign(target, _)           => if (isWritable(vars, target)) Nil else "${fname} が書き替えられない値へ代入する" :: Nil
        case Stmt.Incr(target)                => if (isWritable(vars, target)) Nil else "${fname} が書き替えられない値を 1 足す" :: Nil
        case Stmt.Return(Some(e))             => if (tyOfNode(e) == ret) Nil else "${fname} の返り値の型は ${ret} なのに ${tyOfNode(e)} を返す" :: Nil
        case Stmt.Return(None)                => if (ret == Ty.Void) Nil else "${fname} は ${ret} を返すのに値なしで抜ける" :: Nil
        case Stmt.If(_, t, e, _)              => statementErrors(fname, ret, vars, t) ::: statementErrors(fname, ret, vars, e)
        case Stmt.For(name, _, _, _, body, _) => statementErrors(fname, ret, Set.insert(name, vars), body)
        case _                                => Nil
    }

    /// 定義 d の、組む時の検査の誤りの文（関数でなければ空）。print は誤りがあれば止める。
    pub def errorsOf(d: Definition): List[String] = match d {
        case Def.Fn(name, ret, _, body) => uniformityErrors(name, body) ::: statementErrors(name, ret, Set.empty(), body)
        case _                          => Nil
    }

    /// defs を全部、組む時の検査に通した defs（誤りがあれば止める）。
    def checkOrBug(defs: List[Def]): List[Def] =
        let errors = defs |> List.flatMap(errorsOf);
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

    /// 単項の演算の強さ・括弧の要らない式の強さ・? : の強さ。
    def unaryPrec(): Int32 = 14
    def atomPrec(): Int32 = 16
    def ternaryPrec(): Int32 = 2

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

    def isRelational(op: BinOp): Bool = precOf(op) == 9 or precOf(op) == 8

    /// 節の強さ（括弧が要るかを決める）。
    def precOfNode(n: Node): Int32 = match n {
        case Node.Bin(op, _, _, _)   => precOf(op)
        case Node.Select(_, _, _, _) => ternaryPrec()
        case Node.Neg(_, _)          => unaryPrec()
        case Node.Not(_)             => unaryPrec()
        case _                       => atomPrec()
    }

    /// 単項の演算子 op を、字 inner（強さで括弧を付けた後）の前に付けた字。inner が - で始まれば括弧で包む（-- と読まれる）。
    def prefixed(op: String, inner: String): String =
        if (String.startsWith(prefix = "-", inner)) op + "(" + inner + ")" else op + inner

    /// uniform の swizzle inner に、外の swizzle outer を重ねた swizzle（uPsxTarget.zw の .x は uPsxTarget.z）。
    def composeSwizzle(inner: String, outer: String): String =
        let pick = (ch: Char) -> {
            let k = match ch {
                case 'x' => 0
                case 'r' => 0
                case 'y' => 1
                case 'g' => 1
                case 'z' => 2
                case 'b' => 2
                case 'w' => 3
                case 'a' => 3
                case _   => invalidOrBug("ShaderAst: swizzle の字 ${ch} は読めない")
            };
            if (k < String.length(inner)) String.charAt(k, inner)
            else invalidOrBug("ShaderAst: swizzle .${inner} に .${outer} は重ねられない")
        };
        String.toList(outer) |> List.map(pick) |> List.map(Char.toString) |> String.flatten

    /// uniform を base と swizzle で読む字に、外の swizzle outer を重ねた字。
    def accessText(base: String, swizzle: String, outer: String): String =
        let sw = if (String.isEmpty(swizzle)) outer else if (String.isEmpty(outer)) swizzle else composeSwizzle(swizzle, outer);
        if (String.isEmpty(sw)) base else base + "." + sw

    /// uniform u を言語 lang で読む字（outer = 外から重ねる swizzle）。その言語に無い欄なら止める。
    def accessFor(lang: Lang, u: UniformKey, outer: String): String =
        let (name, _, glsl, wgsl) = u;
        match (if (lang == Lang.Glsl) glsl else wgsl) {
            case Some((base, swizzle)) => accessText(base, swizzle, outer)
            case None                  => invalidOrBug("ShaderAst: uniform ${name} はこの言語に無い")
        }

    /// 4 つの空白で字下げした行。
    def indentOf(depth: Int32): String = String.repeat(depth * 4, " ")

    /// 字の部品を 1 つにつなぐ。
    def joinParts(parts: List[String]): String = region rc {
        let sb = StringBuilder.empty(rc);
        List.forEach(s -> StringBuilder.append(s, sb), parts);
        StringBuilder.toString(sb)
    }
}
