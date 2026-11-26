// ShaderAst — シェーダーを 1 回だけ書き、GLSL（ShaderAst.Glsl）と WGSL（ShaderAst.Wgsl）へ出す小さな型つきの木。
//
// 式は型を持つ組み立ての関数（add・mulS・dot…）でしか作れない（Expr[t] の t は Float・Vec3 などの型のマーカー。trait が受ける型を絞る）。
// 関数は名前で集める: 呼んだ関数・読んだ大域の値を辿り、使う前に 1 回ずつ並べる。同じ名前で中身の違う物と、呼ぶ関係の輪は止める。
// GLSL の uniform の宣言の行は、集めた定義が読む uniform から printer が出す。
// GLSL と WGSL の意味の違いは printer と組み込み（Intrinsic）にだけ書く。
// WhyNot: 演算子 + * を使わない — Flix の trait は同じ型どうしの演算しか書けず、vec3 × f32 や mat4 × vec4 を表せない。
// WhyNot: 型のマーカーを受ける関数に本文を書かない — Flix は型ごとに関数を複製するので、本文は Node を受ける関数へ出し、マーカーの関数は包むだけにする。
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

    /// uniform の読み: name = 名前（鍵）・ty = 型・言語ごとの読む字（None はその言語では宣言しない欄）・
    /// glslType と length = GLSL の宣言の型の字と配列の長さ（`uniform <glslType> <glsl の base>[length];`）。
    /// ty が Bool の uniform は GLSL は int（== 1 で読む）・WGSL は f32（> 0.5 で読む）で持つ。
    pub type alias UniformRef = { name = String, ty = Ty, glsl = Option[Access], wgsl = Option[Access], glslType = String, length = Option[Int32] }

    /// 木の中の uniform の読み（名前・型・GLSL の (base, swizzle)・WGSL の (base, swizzle)・GLSL の宣言の型・配列の長さ）。
    // WhyNot: UniformRef の record のまま持たない — Flix の record は Eq を持たず、同じ名前の定義の中身を比べられない。
    type alias UniformKey = (String, Ty, Option[(String, String)], Option[(String, String)], String, Option[Int32])

    def keyOf(u: UniformRef): UniformKey =
        let pair = (a: Access) -> (a#base, a#swizzle);
        (u#name, u#ty, Option.map(pair, u#glsl), Option.map(pair, u#wgsl), u#glslType, u#length)

    /// 言語ごとに中身の違う組み込みの式（計画の 2 節の意味の違い）。
    enum Intrinsic with Eq {
        /// 描き先の左上を 0 とする画素の位置（ivec2）。GLSL は gl_FragCoord を描き先の矩形（x, y, 幅, 高さ）の uniform で直す・
        /// WGSL は入口が @builtin(position) を写す r3d_fragCoord（場面の描き先の左上が 0）。
        case PixelFromTopLeft(UniformKey)
        /// 描き先の画素の真ん中の NDC（vec2・−1..1・y は上へ。(描き先の矩形の uniform, 幅, 高さ)）。GLSL は gl_FragCoord（左下が原点）を矩形で直す・
        /// WGSL は r3d_fragCoord（左上が原点）の y を返す。
        case PixelNdc(UniformKey, Node, Node)
        /// 描き先いっぱいを覆う三角形の頂点の clip の位置（vertex_index の 3 点）。
        case FullscreenPosition
        /// 四角の角（0〜1・y は下向き。6 点で 2 つの三角形）。GLSL は頂点の属性 aCorner・WGSL は vertex_index の表。
        case QuadCorner
        /// frag が表の面か。
        case FrontFacing
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
        case Raw(Option[String], Option[String], Ty, List[Def], Bool)
        case CallIn(String, List[Node], String, List[Node], Ty, List[Def], Bool)
        case Varying(String, Ty, Interp)
        case Attribute(String, Ty)
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
        case Emit(Node, Bool)
        case Headed(String, String, Node)
        case RawStmt(String, String)
        case Output(String, Ty, Interp, Node)
        case ClipOut(Node)
        case Only(Lang, List[Stmt])
    }

    /// print する時に初めて作る字（光の式の木の生成のように重い字）と、その字が読む定義（deps）と uniform。
    pub type alias GeneratedText = { text = String, deps = List[Definition], uniforms = List[UniformRef] }

    /// 言語ごとの本文の字（extern 関数）。Text = この字を置く・Outside = 周りの字が定義する（置かない）・Missing = この言語には無い（print すると止める）。
    /// Generated = (鍵, 字) — print する時に初めて作る字。中身の比べは鍵で済ませる。
    pub enum Body {
        case Text(String)
        case Generated(String, Lazy[GeneratedText])
        case Outside
        case Missing
    }

    // WhyNot: Generated の字を比べない — 比べると、print しない言語の字や、集める途中で 2 回出会った定義の字まで作ることになる。
    instance Eq[Body] {
        pub def eq(a1: Body, b1: Body): Bool = match (a1, b1) {
            case (Body.Text(x1), Body.Text(y1))                 => x1 == y1
            case (Body.Generated(k1, _), Body.Generated(k2, _)) => k1 == k2
            case (Body.Outside, Body.Outside)                   => true
            case (Body.Missing, Body.Missing)                   => true
            case _                                              => false
        }
    }

    /// 言語の本文の字（Generated はここで作る）。Outside は空の字・Missing は None。
    def bodyText(b1: Body): Option[String] = match b1 {
        case Body.Text(text)         => Some(text)
        case Body.Generated(_, text) => Some((force text)#text)
        case Body.Outside            => Some("")
        case Body.Missing            => None
    }

    /// 生成した本文が読む定義（Generated だけ）。
    def bodyDeps(b1: Body): List[Def] = match b1 {
        case Body.Generated(_, text) => (force text)#deps
        case _                       => Nil
    }

    /// 生成した本文が読む uniform（Generated だけ）。
    def bodyUniforms(b1: Body): List[UniformKey] = match b1 {
        case Body.Generated(_, text) => (force text)#uniforms |> List.map(keyOf)
        case _                       => Nil
    }

    /// 生成した字 text の GeneratedText。deps = candidates のうち名前が字に名前として出てくる物・uniforms = uniforms のうち GLSL の名前が字に出てくる物。
    pub def generatedText(text: String, candidates: List[Definition], uniforms: List[UniformRef]): GeneratedText =
        let glslName = (u: UniformRef) -> u#glsl |> Option.map(a1 -> a1#base) |> Option.getWithDefault(u#name);
        { text = text, deps = candidates |> List.filter(d -> hasWord(nameOf(d), text)), uniforms = uniforms |> List.filter(u -> hasWord(glslName(u), text)) }

    /// 字 text に word が名前として（前後が英数字と _ でない所に）出てくるか。
    def hasWord(word: String, text: String): Bool =
        let isPart = (c: Char) -> Char.isLetter(c) or Char.isDigit(c) or c == '_';
        let n = String.length(text);
        def searchFrom(start: Int32): Bool = match String.indexOfLeftWithOffset(substr = word, offset = start, text) {
            case None     => false
            case Some(at) =>
                let end = at + String.length(word);
                let alone = (at == 0 or not isPart(String.charAt(at - 1, text))) and (end >= n or not isPart(String.charAt(end, text)));
                alone or searchFrom(at + 1)
        };
        searchFrom(0)

    /// extern 関数: 本文は言語ごとの字。deps = 本文が読む定義（先に並べる。Generated の本文が読む物は本文が持つ）・
    /// derivative = 微分か暗黙の mip レベルの読みを使うか（一様さの検査が辿る）。
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
        case Node.Lit(_, t)                   => t
        case Node.Ref(_, t)                   => t
        case Node.Uniform((_, t, _, _, _, _)) => t
        case Node.Bin(_, _, _, t)             => t
        case Node.Neg(_, t)                   => t
        case Node.Not(_)                      => Ty.Bool
        case Node.Call(_, _, t)               => t
        case Node.Builtin(_, _, t)            => t
        case Node.Construct(t, _)             => t
        case Node.Swizzle(_, _, t)            => t
        case Node.Index(_, _, t)              => t
        case Node.Select(_, _, _, t)          => t
        case Node.Paren(x1)                   => tyOfNode(x1)
        case Node.Intrinsic(_, t)             => t
        case Node.Global(_, t)                => t
        case Node.Raw(_, _, t, _, _)          => t
        case Node.CallIn(_, _, _, _, t, _, _) => t
        case Node.Varying(_, t, _)            => t
        case Node.Attribute(_, t)             => t
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

    // ── 木を辿る ──

    /// 式の節 n の直の子。
    def childNodes(n: Node): List[Node] = match n {
        case Node.Bin(_, a1, b1, _)    => a1 :: b1 :: Nil
        case Node.Neg(a1, _)           => a1 :: Nil
        case Node.Not(a1)              => a1 :: Nil
        case Node.Call(_, args, _)     => args
        case Node.Builtin(_, args, _)  => args
        case Node.Construct(_, args)   => args
        case Node.Swizzle(a1, _, _)    => a1 :: Nil
        case Node.Index(a1, b1, _)     => a1 :: b1 :: Nil
        case Node.Select(c, a1, b1, _) => c :: a1 :: b1 :: Nil
        case Node.Paren(a1)            => a1 :: Nil
        case Node.CallIn(_, ga, _, wa, _, _, _) => ga ::: wa
        case Node.Intrinsic(Intrinsic.PixelNdc(_, w1, h1), _) => w1 :: h1 :: Nil
        case _                         => Nil
    }

    /// 文 s が直に持つ式。
    def stmtNodes(s: Stmt): List[Node] = match s {
        case Stmt.Decl(_, _, init, _)      => Option.toList(init)
        case Stmt.Assign(a1, b1)           => a1 :: b1 :: Nil
        case Stmt.Incr(a1)                 => a1 :: Nil
        case Stmt.If(c, _, _, _)           => c :: Nil
        case Stmt.For(_, _, a1, c, _, _)   => a1 :: c :: Nil
        case Stmt.Return(e)                => Option.toList(e)
        case Stmt.Eval(e)                  => e :: Nil
        case Stmt.Emit(e, _)               => e :: Nil
        case Stmt.Headed(_, _, e)          => e :: Nil
        case Stmt.Output(_, _, _, e)       => e :: Nil
        case Stmt.ClipOut(e)               => e :: Nil
        case _                             => Nil
    }

    /// 文 s の中のブロックの文。
    def stmtChildren(s: Stmt): List[Stmt] = match s {
        case Stmt.If(_, t, e, _)          => t ::: e
        case Stmt.For(_, _, _, _, body, _) => body
        case Stmt.Only(_, body)            => body
        case _                            => Nil
    }

    /// 式 n の中の節（子が先・n が最後）。
    def nodesIn(n: Node): List[Node] = (childNodes(n) |> List.flatMap(nodesIn)) ::: n :: Nil

    /// 文 s の中の節（中のブロックの文の物も）。
    def nodesInStmt(s: Stmt): List[Node] = (stmtNodes(s) |> List.flatMap(nodesIn)) ::: (stmtChildren(s) |> List.flatMap(nodesInStmt))

    /// 式 n の中（n を含む）に p が真の節があるか。
    def anyNode(p: Node -> Bool, n: Node): Bool = List.exists(p, nodesIn(n))

    /// 文 s の中（ブロックの中の文も）の式に p が真の節があるか。
    def anyStmt(p: Node -> Bool, s: Stmt): Bool = List.exists(p, nodesInStmt(s))

    // ── マーカーごとの型 ──

    /// 型のマーカー t の値の型（引数・局所の変数を作る時に、マーカーの値 Float.Float・Vec3.Vec3 などを渡す）。
    // WhyNot: マーカーの値を返す関数（float() など）を通さない — Flix の関数の呼び出しは呼ぶ所ごとに効果の受け渡しのコードを生み、
    //   シェーダーを組む関数の大きさの多くを占める。マーカーの値はコンストラクタで、呼び出しにならない。
    pub type alias TyWitness[t] = t

    /// マーカー t の値の型。
    pub trait Marker[t] {
        pub def tyOfMarker(x: t): Ty
    }
    instance Marker[Float] { pub def tyOfMarker(_x: Float): Ty = Ty.F32 }
    instance Marker[Int] { pub def tyOfMarker(_x: Int): Ty = Ty.I32 }
    instance Marker[Boolean] { pub def tyOfMarker(_x: Boolean): Ty = Ty.Bool }
    instance Marker[Vec2] { pub def tyOfMarker(_x: Vec2): Ty = Ty.Vec2 }
    instance Marker[Vec3] { pub def tyOfMarker(_x: Vec3): Ty = Ty.Vec3 }
    instance Marker[Vec4] { pub def tyOfMarker(_x: Vec4): Ty = Ty.Vec4 }
    instance Marker[IVec2] { pub def tyOfMarker(_x: IVec2): Ty = Ty.IVec2 }
    instance Marker[Mat3] { pub def tyOfMarker(_x: Mat3): Ty = Ty.Mat3 }
    instance Marker[Mat4] { pub def tyOfMarker(_x: Mat4): Ty = Ty.Mat4 }
    instance Marker[Tex] { pub def tyOfMarker(_x: Tex): Ty = Ty.Texture2d }
    instance Marker[DepthTex] { pub def tyOfMarker(_x: DepthTex): Ty = Ty.DepthTexture2d }

    def tyOfWitness(w1: t): Ty with Marker[t] = Marker.tyOfMarker(w1)

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
    pub def ref(w1: TyWitness[t], name: String): Expr[t] with Marker[t] = wrap(Node.Ref(name, tyOfWitness(w1)))

    /// uniform の読み。u#ty はマーカー t と同じ型にする。
    pub def uniform(w1: TyWitness[t], u: UniformRef): Expr[t] with Marker[t] = wrap(uniformNode(tyOfWitness(w1), u))

    def uniformNode(t: Ty, u: UniformRef): Node =
        if (u#ty != t) invalidOrBug("ShaderAst.uniform: ${u#name} の型 ${u#ty} とマーカー ${t} が違う")
        else Node.Uniform(keyOf(u))

    /// 描き先の左上を 0 とする画素の位置。targetRect = 描き先の矩形 (左下の x, y, 幅, 高さ) の uniform（GLSL の gl_FragCoord は描き先の左下が原点なので、この矩形で直す。WGSL では読まない）。
    pub def pixelFromTopLeft(targetRect: UniformRef): Expr[IVec2] =
        if (targetRect#ty != Ty.Vec4) invalidOrBug("ShaderAst.pixelFromTopLeft: ${targetRect#name} は vec4 でない")
        else wrap(Node.Intrinsic(Intrinsic.PixelFromTopLeft(keyOf(targetRect)), Ty.IVec2))

    /// 描き先の画素の真ん中の NDC（−1..1・y は上へ）。targetRect = 描き先の矩形 (左下の x, y, 幅, 高さ) の uniform（GLSL の gl_FragCoord は描き先の左下が原点なので、この矩形で直す。WGSL では読まない）・width と height = 描き先の大きさ（画素）。
    pub def pixelNdc(targetRect: UniformRef, width: Expr[Float], height: Expr[Float]): Expr[Vec2] =
        if (targetRect#ty != Ty.Vec4) invalidOrBug("ShaderAst.pixelNdc: ${targetRect#name} は vec4 でない")
        else wrap(Node.Intrinsic(Intrinsic.PixelNdc(keyOf(targetRect), nodeOf(width), nodeOf(height)), Ty.Vec2))

    /// 描き先いっぱいを覆う三角形の頂点の clip の位置（vertex の入口で使う）。
    pub def fullscreenPosition(): Expr[Vec4] = wrap(Node.Intrinsic(Intrinsic.FullscreenPosition, Ty.Vec4))

    /// 四角の角（0〜1・y は下向き）。
    pub def quadCorner(): Expr[Vec2] = wrap(Node.Intrinsic(Intrinsic.QuadCorner, Ty.Vec2))

    /// frag が表の面か（入口の本文の中だけで読む。GLSL は gl_FrontFacing・WGSL は入口の @builtin(front_facing)）。
    pub def frontFacing(): Expr[Boolean] = wrap(Node.Intrinsic(Intrinsic.FrontFacing, Ty.Bool))

    /// 言語ごとに字の違う式（材質の部品が作った字・言語ごとに引数の違う絵の読み）。字が 1 つの名前・欄の読み・呼び出しでなければ printer が括弧で包む。
    /// deps = 字が呼ぶ定義（先に並べる）・derivative = 微分か暗黙の mip レベルの読みを使うか（一様さの検査が見る）。
    pub def rawExpr(w1: TyWitness[t], glsl: String, wgsl: String, deps: List[Definition], derivative: Bool): Expr[t] with Marker[t] =
        wrap(Node.Raw(Some(glsl), Some(wgsl), tyOfWitness(w1), deps, derivative))

    /// 言語 lang だけの字の式（片方の言語の字しか持たない部品。GL の描き手は GLSL の材質の部品だけを持つ）。ほかの言語で print すると止める。
    pub def rawExprIn(w1: TyWitness[t], lang: Lang, text: String, deps: List[Definition], derivative: Bool): Expr[t] with Marker[t] = wrap(rawInNode(tyOfWitness(w1), lang, text, deps, derivative))

    def rawInNode(t: Ty, lang: Lang, text: String, deps: List[Def], derivative: Bool): Node =
        if (lang == Lang.Glsl) Node.Raw(Some(text), None, t, deps, derivative) else Node.Raw(None, Some(text), t, deps, derivative)

    /// 言語ごとに名前か引数の並びの違う関数の呼び出し（GLSL は glslName(glslArgs)・WGSL は wgslName(wgslArgs)）。deps と derivative は rawExpr と同じ。
    pub def callIn(w1: TyWitness[t], glslName: String, glslArgs: List[Arg], wgslName: String, wgslArgs: List[Arg], deps: List[Definition], derivative: Bool): Expr[t] with Marker[t] =
        wrap(Node.CallIn(glslName, argsOf(glslArgs), wgslName, argsOf(wgslArgs), tyOfWitness(w1), deps, derivative))

    /// WGSL の sampler の名前 name の引数（callIn の WGSL の引数）。
    pub def samplerArg(name: String): Arg = ArgData.ArgData(Node.Ref(name, Ty.Sampler))

    /// raw の式の言語 lang の字（その言語の字が無ければ止める）。
    def rawTextOrBug(lang: Lang, text: Option[String]): String = match text {
        case Some(t) => t
        case None    => invalidOrBug("ShaderAst: ${if (lang == Lang.Glsl) "GLSL" else "WGSL"} の字を持たない式を出した")
    }

    /// 字が括弧なしで演算子の子に置ける形か（名前・数・欄の読み・添字・呼び出しだけで、括弧の外に空白も演算子も無い）。
    def isAtomText(text: String): Bool =
        let step = (acc: (Int32, Bool), ch: Char) -> {
            let (depth, ok) = acc;
            if (not ok) acc
            else if (ch == '(' or ch == '[') (depth + 1, true)
            else if (ch == ')' or ch == ']') (depth - 1, true)
            else if (depth > 0) acc
            else (depth, Char.isLetter(ch) or Char.isDigit(ch) or ch == '_' or ch == '.')
        };
        not String.isEmpty(text) and snd(String.toList(text) |> List.foldLeft(step, (0, true)))

    def bin(op: BinOp, a1: Node, b1: Node, t: Ty): Expr[r] = wrap(Node.Bin(op, a1, b1, t))

    /// 同じ型どうしの四則。
    pub def add(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Add, nodeOf(a1), nodeOf(b1), tyOf(a1))
    pub def sub(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Sub, nodeOf(a1), nodeOf(b1), tyOf(a1))
    pub def mul(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Mul, nodeOf(a1), nodeOf(b1), tyOf(a1))
    pub def div(a1: Expr[t], b1: Expr[t]): Expr[t] with Numeric[t] = bin(BinOp.Div, nodeOf(a1), nodeOf(b1), tyOf(a1))

    /// float のベクトルと f32 の四則（a1 の型のまま）。
    pub def addS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Add, nodeOf(a1), nodeOf(s), tyOf(a1))
    pub def subS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Sub, nodeOf(a1), nodeOf(s), tyOf(a1))
    pub def mulS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Mul, nodeOf(a1), nodeOf(s), tyOf(a1))
    pub def divS(a1: Expr[t], s: Expr[Float]): Expr[t] with FloatLike[t] = bin(BinOp.Div, nodeOf(a1), nodeOf(s), tyOf(a1))

    /// f32 と float のベクトルの積・差（f32 が左）。
    pub def sMul(s: Expr[Float], a1: Expr[t]): Expr[t] with FloatLike[t] = bin(BinOp.Mul, nodeOf(s), nodeOf(a1), tyOf(a1))
    pub def sSub(s: Expr[Float], a1: Expr[t]): Expr[t] with FloatLike[t] = bin(BinOp.Sub, nodeOf(s), nodeOf(a1), tyOf(a1))

    /// 行列 × ベクトル・行列 × 行列。
    pub def mulMV(m: Expr[Mat4], v: Expr[Vec4]): Expr[Vec4] = bin(BinOp.Mul, nodeOf(m), nodeOf(v), Ty.Vec4)
    pub def mulM3V(m: Expr[Mat3], v: Expr[Vec3]): Expr[Vec3] = bin(BinOp.Mul, nodeOf(m), nodeOf(v), Ty.Vec3)
    pub def mulMM(a1: Expr[Mat4], b1: Expr[Mat4]): Expr[Mat4] = bin(BinOp.Mul, nodeOf(a1), nodeOf(b1), Ty.Mat4)

    /// 整数の余り・ビットの積。
    pub def modulo(a1: Expr[Int], b1: Expr[Int]): Expr[Int] = bin(BinOp.Mod, nodeOf(a1), nodeOf(b1), Ty.I32)
    pub def bitAnd(a1: Expr[Int], b1: Expr[Int]): Expr[Int] = bin(BinOp.BitAnd, nodeOf(a1), nodeOf(b1), Ty.I32)

    /// スカラーの比べ。
    pub def lt(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Lt, nodeOf(a1), nodeOf(b1), Ty.Bool)
    pub def le(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Le, nodeOf(a1), nodeOf(b1), Ty.Bool)
    pub def gt(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Gt, nodeOf(a1), nodeOf(b1), Ty.Bool)
    pub def ge(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Ge, nodeOf(a1), nodeOf(b1), Ty.Bool)
    pub def eq(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.EqOp, nodeOf(a1), nodeOf(b1), Ty.Bool)
    pub def ne(a1: Expr[t], b1: Expr[t]): Expr[Boolean] with Scalar[t] = bin(BinOp.Ne, nodeOf(a1), nodeOf(b1), Ty.Bool)

    /// 論理の積・和・否定。
    pub def and_(a1: Expr[Boolean], b1: Expr[Boolean]): Expr[Boolean] = bin(BinOp.And, nodeOf(a1), nodeOf(b1), Ty.Bool)
    pub def or_(a1: Expr[Boolean], b1: Expr[Boolean]): Expr[Boolean] = bin(BinOp.Or, nodeOf(a1), nodeOf(b1), Ty.Bool)
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
    pub def readGlobal(w1: TyWitness[t], d: Definition): Expr[t] with Marker[t] = wrap(globalNode(tyOfWitness(w1), d))

    def globalNode(t: Ty, d: Def): Node = match d {
        case Def.Private(_, ty, None, _, _) if ty == t => Node.Global(d, ty)
        case _ => invalidOrBug("ShaderAst.readGlobal: ${nameOf(d)} は ${t} の大域の変数でない")
    }

    /// 大域の配列の変数 d の index 番目。
    pub def readGlobalAt(w1: TyWitness[t], d: Definition, index: Expr[Int]): Expr[t] with Marker[t] = wrap(globalAtNode(tyOfWitness(w1), d, nodeOf(index)))

    def globalAtNode(t: Ty, d: Def, index: Node): Node = match d {
        case Def.Private(_, ty, Some(_), _, _) if ty == t => Node.Index(Node.Global(d, ty), index, ty)
        case _ => invalidOrBug("ShaderAst.readGlobalAt: ${nameOf(d)} は ${t} の大域の配列でない")
    }

    // ── swizzle ──

    def swizzle(a1: Node, s: String, t: Ty): Expr[r] = wrap(Node.Swizzle(a1, s, t))

    def elemTy(v: Node): Ty = if (tyOfNode(v) == Ty.IVec2) Ty.I32 else Ty.F32

    pub def x(v: Expr[t]): Expr[Swizzle.Elem[t]] with Swizzle[t] = swizzle(nodeOf(v), "x", elemTy(nodeOf(v)))
    pub def y(v: Expr[t]): Expr[Swizzle.Elem[t]] with Swizzle[t] = swizzle(nodeOf(v), "y", elemTy(nodeOf(v)))
    pub def z(v: Expr[t]): Expr[Float] with Has3[t] = swizzle(nodeOf(v), "z", Ty.F32)
    pub def w(v: Expr[Vec4]): Expr[Float] = swizzle(nodeOf(v), "w", Ty.F32)
    pub def r(v: Expr[t]): Expr[Float] with FloatVector[t] = swizzle(nodeOf(v), "r", Ty.F32)
    pub def g(v: Expr[t]): Expr[Float] with FloatVector[t] = swizzle(nodeOf(v), "g", Ty.F32)
    pub def b(v: Expr[t]): Expr[Float] with Has3[t] = swizzle(nodeOf(v), "b", Ty.F32)
    pub def a(v: Expr[Vec4]): Expr[Float] = swizzle(nodeOf(v), "a", Ty.F32)
    pub def xy(v: Expr[t]): Expr[Vec2] with Has3[t] = swizzle(nodeOf(v), "xy", Ty.Vec2)
    pub def xz(v: Expr[t]): Expr[Vec2] with Has3[t] = swizzle(nodeOf(v), "xz", Ty.Vec2)
    pub def zw(v: Expr[Vec4]): Expr[Vec2] = swizzle(nodeOf(v), "zw", Ty.Vec2)
    pub def xyz(v: Expr[Vec4]): Expr[Vec3] = swizzle(nodeOf(v), "xyz", Ty.Vec3)
    pub def rgb(v: Expr[Vec4]): Expr[Vec3] = swizzle(nodeOf(v), "rgb", Ty.Vec3)

    // ── 型の作り直し ──

    def construct(t: Ty, args: List[Node]): Expr[r] = wrap(Node.Construct(t, args))

    pub def vec2Of(x1: Expr[Float], y1: Expr[Float]): Expr[Vec2] = construct(Ty.Vec2, nodeOf(x1) :: nodeOf(y1) :: Nil)
    pub def vec3Of(x1: Expr[Float], y1: Expr[Float], z1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(x1) :: nodeOf(y1) :: nodeOf(z1) :: Nil)
    pub def vec3Splat(x1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(x1) :: Nil)
    pub def vec4Of(x1: Expr[Float], y1: Expr[Float], z1: Expr[Float], w1: Expr[Float]): Expr[Vec4] =
        construct(Ty.Vec4, nodeOf(x1) :: nodeOf(y1) :: nodeOf(z1) :: nodeOf(w1) :: Nil)
    pub def vec3FromVec2(v: Expr[Vec2], z1: Expr[Float]): Expr[Vec3] = construct(Ty.Vec3, nodeOf(v) :: nodeOf(z1) :: Nil)
    pub def vec4FromVec3(v: Expr[Vec3], w1: Expr[Float]): Expr[Vec4] = construct(Ty.Vec4, nodeOf(v) :: nodeOf(w1) :: Nil)
    pub def ivec2Of(x1: Expr[Int], y1: Expr[Int]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(x1) :: nodeOf(y1) :: Nil)
    pub def ivec2Splat(x1: Expr[Int]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(x1) :: Nil)
    pub def ivec2FromVec2(v: Expr[Vec2]): Expr[IVec2] = construct(Ty.IVec2, nodeOf(v) :: Nil)
    pub def vec2FromIVec2(v: Expr[IVec2]): Expr[Vec2] = construct(Ty.Vec2, nodeOf(v) :: Nil)
    pub def toFloat(x1: Expr[Int]): Expr[Float] = construct(Ty.F32, nodeOf(x1) :: Nil)
    pub def toInt(x1: Expr[Float]): Expr[Int] = construct(Ty.I32, nodeOf(x1) :: Nil)

    // ── 組み込みの関数 ──

    def builtin(fun: BuiltinFn, args: List[Node], t: Ty): Expr[r] = wrap(Node.Builtin(fun, args, t))

    def same1(fun: BuiltinFn, a1: Node): Expr[r] = builtin(fun, a1 :: Nil, tyOfNode(a1))

    pub def floor(a1: Expr[t]): Expr[t] with FloatLike[t] = same1(BuiltinFn.Floor, nodeOf(a1))
    pub def abs(a1: Expr[t]): Expr[t] with FloatLike[t] = same1(BuiltinFn.Abs, nodeOf(a1))
    pub def normalize(a1: Expr[t]): Expr[t] with FloatVector[t] = same1(BuiltinFn.Normalize, nodeOf(a1))
    pub def asin(a1: Expr[Float]): Expr[Float] = same1(BuiltinFn.Asin, nodeOf(a1))
    pub def sign(a1: Expr[Float]): Expr[Float] = same1(BuiltinFn.Sign, nodeOf(a1))
    pub def fwidth(a1: Expr[t]): Expr[t] with FloatLike[t] = same1(BuiltinFn.Fwidth, nodeOf(a1))
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

    def declare(name: String, init: Node, mutable: Bool): (Stmt, Node) = (Stmt.Decl(name, tyOfNode(init), Some(init), mutable), Node.Ref(name, tyOfNode(init)))

    /// 変えない局所の値（GLSL は型つきの宣言・WGSL は let）。返り値の式でその名前を読む。
    pub def let_(name: String, e: Expr[t]): (Statement, Expr[t]) = let (s, n) = declare(name, nodeOf(e), false); (s, wrap(n))

    /// 後で書き替える局所の変数（WGSL は var）。
    pub def var_(name: String, e: Expr[t]): (Statement, Expr[t]) = let (s, n) = declare(name, nodeOf(e), true); (s, wrap(n))

    /// 初めの値の無い局所の変数。
    pub def varNoInit(w1: TyWitness[t], name: String): (Statement, Expr[t]) with Marker[t] =
        (Stmt.Decl(name, tyOfWitness(w1), None, true), wrap(Node.Ref(name, tyOfWitness(w1))))

    /// 代入（target は var_ の変数か大域の変数。違えば組む時に止める）。
    pub def assign(target: Expr[t], e: Expr[t]): Statement = Stmt.Assign(nodeOf(target), nodeOf(e))

    /// 1 足す（x++）。
    pub def incr(target: Expr[Int]): Statement = Stmt.Incr(nodeOf(target))

    /// 1 行の if（GLSL は波かっこなし。emitAndReturn のように 1 行に収まらない文はブロックに置く）。
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

    /// frag の色を出す（GLSL は fragColor への代入・WGSL は return）。入口の本文の最後の文にだけ置ける（if・for の中には置けない）。
    pub def emit(e: Expr[Vec4]): Statement = Stmt.Emit(nodeOf(e), false)

    /// frag の色を出して抜ける（GLSL は fragColor への代入と return・WGSL は return）。入口の本文の中だけに置ける。
    pub def emitAndReturn(e: Expr[Vec4]): Statement = Stmt.Emit(nodeOf(e), true)

    /// 言語ごとに頭の字の違う 1 行の文（頭の字 + 式 + ;。GLSL の大域の変数への代入と WGSL の局所の値のように、置き場だけが言語で違う所）。
    pub def headed(glslHead: String, wgslHead: String, e: Expr[t]): Statement = Stmt.Headed(glslHead, wgslHead, nodeOf(e))

    /// 言語ごとに字の違う文（字下げと改行は printer が付ける。複数の行は改行で区切る。空の字はその言語では何も置かない）。
    pub def rawStatement(glsl: String, wgsl: String): Statement = Stmt.RawStmt(glsl, wgsl)

    // ── 入口 ──

    /// varying の補間: Smooth = 遠近で補正・Flat = 1 つの頂点の値・Affine = 画面の上でまっすぐ（PS1 風の uv）。
    pub enum Interp with Eq { case Smooth, Flat, Affine }

    /// varying 1 つ（location は WGSL の @location。GLSL は名前でつなぐ）。
    pub type alias Varying = { name = String, ty = Ty, location = Int32, interp = Interp }

    /// frag の入口: inputName = WGSL の入口の引数の struct の名前・declarations = 本文から辿れない定義（材質の部品・WGSL の binding の宣言）・
    /// inputs = 受ける varying（vertex の varying の表の一部）・body = main の本文・writesColor = 色を出すか（偽なら出口が無く、本文は捨てるか抜けるだけ）。
    /// 本文と declarations が辿って使う定義と GLSL の uniform の行は printer が集める。
    pub type alias FragmentEntry = { inputName = String, declarations = List[Definition], inputs = List[Varying], body = List[Statement], writesColor = Bool }

    /// 頂点の属性 1 つ。glslLocation = GLSL の `layout (location = n) in`・wgslLocation = WGSL の入口の struct の @location（None はその言語では属性で受けない。
    /// データのテクスチャから読む値のように、属性でない所から読む言語の側は None にして extern の関数で読む）。
    pub type alias Attribute = { name = String, ty = Ty, glslLocation = Option[Int32], wgslLocation = Option[Int32] }

    /// vertex の入口: inputName・outputName = WGSL の入口の引数と返り値の struct の名前・declarations = 本文から辿れない定義（WGSL の binding の宣言）・
    /// attributes = 受ける頂点の属性（四角の角 quadCorner の GLSL の属性は printer が足す）・outputs = 書く varying の表（frag の inputs はこの一部）・
    /// body = main の本文（output で varying を書き、clipOut で clip の位置をif・for の外に 1 回だけ出す。Affine の varying は clipOut の後に書く）。
    pub type alias VertexEntry = { inputName = String, outputName = String, declarations = List[Definition], attributes = List[Attribute],
                                   outputs = List[Varying], body = List[Statement] }

    /// varying v の読み（frag の入口の本文の中だけ。GLSL は名前・Affine は w で割り戻す・WGSL は入口の引数の欄）。
    pub def varying(w1: TyWitness[t], v: Varying): Expr[t] with Marker[t] = wrap(varyingNode(tyOfWitness(w1), v))

    def varyingNode(t: Ty, v: Varying): Node =
        if (v#ty != t) invalidOrBug("ShaderAst.varying: ${v#name} の型 ${v#ty} とマーカー ${t} が違う")
        else Node.Varying(v#name, v#ty, v#interp)

    /// varying v を同じ名前の局所の値に置く文（言語ごとの字の部品が varying を名前で読む所。GLSL は in の名前のまま読めるので何も置かない・WGSL は入口の引数の欄を写す）。
    pub def varyingAsLocal(v: Varying): Statement =
        if (v#interp == Interp.Affine) invalidOrBug("ShaderAst.varyingAsLocal: ${v#name} は Affine（GLSL の字が w で割る式で、名前で読めない）")
        else Stmt.RawStmt("", "let ${v#name} = " + ShaderAst.Wgsl.expression((wrap(Node.Varying(v#name, v#ty, v#interp)): Expr[Float])) + ";")

    /// 頂点の属性 a の読み（vertex の入口の本文の中だけ。GLSL は名前・WGSL は入口の引数の欄）。
    pub def attribute(w1: TyWitness[t], a: Attribute): Expr[t] with Marker[t] = wrap(attributeNode(tyOfWitness(w1), a))

    def attributeNode(t: Ty, a: Attribute): Node =
        if (a#ty != t) invalidOrBug("ShaderAst.attribute: ${a#name} の型 ${a#ty} とマーカー ${t} が違う")
        else Node.Attribute(a#name, a#ty)

    /// varying v に値 e を書く文（vertex の入口の本文の中だけ）。
    pub def output(v: Varying, e: Expr[t]): Statement =
        if (v#ty != tyOf(e)) invalidOrBug("ShaderAst.output: ${v#name} の型 ${v#ty} に ${tyOf(e)} を書いた")
        else Stmt.Output(v#name, v#ty, v#interp, nodeOf(e))

    /// clip の位置 e（GL の clip: z は −w..w）を出す文（vertex の入口の本文のif・for の外に 1 回だけ）。WGSL は sg_clipFromGl で z を 0..w へ移す。
    pub def clipOut(e: Expr[Vec4]): Statement = Stmt.ClipOut(nodeOf(e))

    /// 言語 lang でだけ置く文の並び（入口の本文の中だけ。ほかの言語では何も置かない）。
    pub def onlyIn(lang: Lang, body: List[Statement]): Statement = Stmt.Only(lang, body)

    /// GLSL の四角の角の属性 aCorner の location（GL の描き手の四角の buffer）。
    pub def quadCornerLocation(): Int32 = 0

    /// vertex v と frag f の組の誤り（f が受ける varying が v の表に同じ型・location・補間で無い・どちらかの表で location が重なる）。
    pub def linkErrors(v: VertexEntry, f: FragmentEntry): List[String] =
        let written = v#outputs |> List.map(o -> (o#name, (o#ty, o#location, o#interp))) |> List.toMap;
        let missing = f#inputs |> List.filter(i1 -> Map.get(i1#name, written) != Some((i1#ty, i1#location, i1#interp)));
        let overlaps = (vs: List[Varying]) -> List.length(vs |> List.map(x1 -> x1#location) |> List.distinct) != List.length(vs);
        (missing |> List.map(i1 -> "frag の ${i1#name} が vertex の varying の表に同じ形で無い")) :::
        (if (overlaps(v#outputs)) "vertex の varying の location が重なる" :: Nil else Nil) :::
        (if (overlaps(f#inputs)) "frag の varying の location が重なる" :: Nil else Nil)

    // ── 定義の組み立て ──

    /// 関数の引数（名前と型）。返り値の式で本文から読む。
    pub def param(w1: TyWitness[t], name: String): ((String, Ty), Expr[t]) with Marker[t] = ((name, tyOfWitness(w1)), wrap(Node.Ref(name, tyOfWitness(w1))))

    /// 関数の定義。ret = 返り値の型（Void なら値を返さない）。
    pub def function(name: String, ret: Ty, params: List[(String, Ty)], body: List[Statement]): Definition =
        Def.Fn(name, ret, params, body)

    /// extern 関数の定義。
    pub def externFunction(x1: ExternDef): Definition = Def.Extern(x1#name, x1#ret, x1#params, x1#glsl, x1#wgsl, x1#deps, x1#derivative)

    /// 決まった値の配列の定義。
    pub def constArray(c: ConstArrayDef): Definition = Def.ConstArray(c#name, c#elem, c#values)

    /// 大域の変数の定義（name・型・配列の長さ・初めの値・片方の言語だけに置くならその言語）。
    pub def privateVar(name: String, w1: TyWitness[t], length: Option[Int32], init: Option[Expr[t]], lang: Option[Lang]): Definition with Marker[t] =
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

    def argsOf(args: List[Arg]): List[Node] = args |> List.map(a1 -> match a1 { case ArgData.ArgData(n) => n })

    def argNodes(d: Def, args: List[Arg]): List[Node] =
        let nodes = argsOf(args);
        let got = nodes |> List.map(tyOfNode);
        if (got != paramTys(d)) invalidOrBug("ShaderAst.call: ${nameOf(d)} の引数の型 ${paramTys(d)} に ${got} を渡した") else nodes

    /// 関数 d を args で呼ぶ。w1 = 返り値の型のマーカー（d の返り値の型と同じにする）。引数の型が d の引数と違えば止める。
    pub def call(w1: TyWitness[t], d: Definition, args: List[Arg]): Expr[t] with Marker[t] = wrap(callNode(tyOfWitness(w1), d, args))

    def callNode(t: Ty, d: Def, args: List[Arg]): Node =
        if (retTy(d) != t) invalidOrBug("ShaderAst.call: ${nameOf(d)} の返り値の型 ${retTy(d)} を ${t} で受けた")
        else Node.Call(d, argNodes(d, args), t)

    /// 返り値の無い関数 d を呼ぶ文。
    pub def callStmt(d: Definition, args: List[Arg]): Statement =
        if (retTy(d) != Ty.Void) invalidOrBug("ShaderAst.callStmt: ${nameOf(d)} は値を返す")
        else Stmt.Eval(Node.Call(d, argNodes(d, args), Ty.Void))

    // ── 集める ──

    /// 節 n そのものが読む定義（呼んだ関数・大域の値・raw の字が呼ぶ物）。
    def ownDeps(n: Node): List[Def] = match n {
        case Node.Call(d, _, _)                  => d :: Nil
        case Node.Intrinsic(k, _)                => depsOfIntrinsic(k)
        case Node.Global(d, _)                   => d :: Nil
        case Node.Raw(_, _, _, deps, _)          => deps
        case Node.CallIn(_, _, _, _, _, deps, _) => deps
        case _                                   => Nil
    }

    /// 式 n が読む定義（子の物が先）。
    def depsOfNode(n: Node): List[Def] = nodesIn(n) |> List.flatMap(ownDeps)

    /// 組み込みの式が読む大域の値（片方の言語だけの物は Private と Extern の本文で分かれる）。
    def depsOfIntrinsic(k: Intrinsic): List[Def] = match k {
        case Intrinsic.PixelFromTopLeft(_) => fragCoord() :: Nil
        case Intrinsic.PixelNdc(_, _, _)   => fragCoord() :: Nil
        case Intrinsic.FullscreenPosition  => vertexIndex() :: Nil
        case Intrinsic.QuadCorner          => vertexIndex() :: quadCornerTable() :: Nil
        case Intrinsic.FrontFacing         => Nil
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

    def depsOfStmt(s: Stmt): List[Def] = nodesInStmt(s) |> List.flatMap(ownDeps)

    /// 言語 lang の本文（extern の Body の片方）。
    def bodyIn(lang: Lang, glsl: Body, wgsl: Body): Body = if (lang == Lang.Glsl) glsl else wgsl

    /// 定義 d が言語 lang で直に読む定義（呼んだ関数・読んだ大域の値・生成した本文が読む物）。
    def directDeps(lang: Lang, d: Def): List[Def] = match d {
        case Def.Fn(_, _, _, body)                 => body |> List.flatMap(depsOfStmt)
        case Def.Extern(_, _, _, gb, wb, deps, _)  => deps ::: bodyDeps(bodyIn(lang, gb, wb))
        case Def.Private(_, _, _, init, _)         => init |> Option.toList |> List.flatMap(depsOfNode)
        case _                                     => Nil
    }

    /// 集める途中の状態: 並べた列（逆順）・名前 → 定義・辿っている途中の名前（輪を見つける）。
    type alias CollectState = { order = List[Def], seen = Map[String, Def], open = Set[String] }

    /// roots と、それが言語 lang で辿って使う定義を、使う前に 1 回ずつ並べた列（roots の順を保つ）。
    /// 同じ名前で中身の違う定義・呼ぶ関係の輪があれば Err。
    pub def collect(lang: Lang, roots: List[Definition]): Result[String, List[Definition]] =
        roots |> List.foldLeft((acc, d) -> Result.flatMap(st -> visit(lang, d, st), acc), Ok({ order = Nil, seen = Map.empty(), open = Set.empty() }))
              |> Result.map(st -> List.reverse(st#order))

    /// collect の Err で止める版。
    pub def collectOrBug(lang: Lang, roots: List[Definition]): List[Definition] = match collect(lang, roots) {
        case Ok(defs) => defs
        case Err(msg) => invalidOrBug("ShaderAst.collect: " + msg)
    }

    def visit(lang: Lang, d: Def, st: CollectState): Result[String, CollectState] =
        let name = nameOf(d);
        if (Set.memberOf(name, st#open)) Err("呼ぶ関係が ${name} で輪になっている")
        else match Map.get(name, st#seen) {
            case Some(prev) => if (prev == d) Ok(st) else Err("同じ名前 ${name} で中身の違う定義が 2 つある")
            case None =>
                let start = Ok({ open = Set.insert(name, st#open) | st });
                directDeps(lang, d) |> List.foldLeft((acc, dep) -> Result.flatMap(s1 -> visit(lang, dep, s1), acc), start)
                                    |> Result.map(s2 -> { order = d :: s2#order, seen = Map.insert(name, d, s2#seen), open = Set.remove(name, s2#open) })
        }

    // ── GLSL の uniform の宣言 ──

    /// 節 n そのものが読む uniform（GLSL の画素の位置は描き先の矩形の uniform も読む）。
    def ownUniform(n: Node): Option[UniformKey] = match n {
        case Node.Uniform(k)                                  => Some(k)
        case Node.Intrinsic(Intrinsic.PixelFromTopLeft(k), _) => Some(k)
        case Node.Intrinsic(Intrinsic.PixelNdc(k, _, _), _)   => Some(k)
        case _                                                => None
    }

    /// 定義 defs と本文 body が GLSL で読む uniform の宣言 (型, 名前, 配列の長さ)（GLSL の名前ごとに 1 つ・初めて読んだ順）。
    /// 同じ名前で宣言の違う物があれば止める。
    def glslUniformsOrBug(defs: List[Def], body: List[Stmt]): List[(String, String, Option[Int32])] =
        let ofDef = (d: Def) -> match d {
            case Def.Fn(_, _, _, fb)                => fb |> List.flatMap(nodesInStmt) |> List.filterMap(ownUniform)
            case Def.Private(_, _, _, init, _)      => init |> Option.toList |> List.flatMap(nodesIn) |> List.filterMap(ownUniform)
            case Def.Extern(_, _, _, gb, _, _, _)   => bodyUniforms(gb)
            case _                                  => Nil
        };
        let step = (acc: (Map[String, (String, Option[Int32])], List[(String, String, Option[Int32])]), k: UniformKey) -> {
            let (seen, order) = acc;
            let (name, _, glsl, _, glslType, length) = k;
            match glsl {
                case None            => acc
                case Some((base, _)) => match Map.get(base, seen) {
                    case Some(prev) => if (prev == (glslType, length)) acc else invalidOrBug("ShaderAst: uniform ${base} の宣言が 2 通りある（${name}）")
                    case None       => (Map.insert(base, (glslType, length), seen), (glslType, base, length) :: order)
                }
            }
        };
        let keys = (defs |> List.flatMap(ofDef)) ::: (body |> List.flatMap(nodesInStmt) |> List.filterMap(ownUniform));
        List.reverse(snd(keys |> List.foldLeft(step, (Map.empty(), Nil))))

    // ── 組む時の検査（一様さ・代入の先・返り値の型） ──

    /// 定義 d が微分か暗黙の mip レベルの読みを使うか（呼ぶ関係を辿る）。
    def usesDerivative(d: Def): Bool = match d {
        case Def.Fn(_, _, _, body)                       => body |> List.exists(anyStmt(isDerivativeAt))
        case Def.Extern(_, _, _, _, _, deps, derivative) => derivative or (deps |> List.exists(usesDerivative))
        case _                                           => false
    }

    /// 節 n そのものが微分か暗黙の mip レベルの読みか（呼んだ関数は辿る）。
    def isDerivativeAt(n: Node): Bool = match n {
        case Node.Call(d, _, _)                  => usesDerivative(d)
        case Node.Builtin(fun, _, _)             => fun == BuiltinFn.Fwidth
        case Node.Raw(_, _, _, deps, derivative) => derivative or (deps |> List.exists(usesDerivative))
        case Node.CallIn(_, _, _, _, _, deps, derivative) => derivative or (deps |> List.exists(usesDerivative))
        case _                                   => false
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
        if (st#diverged and anyStmt(isDerivativeAt, s)) derivativeError(fname) :: Nil else Nil

    def checkStmt(fname: String, st: UniformityState, s: Stmt): (UniformityState, List[String]) = match s {
        case Stmt.Decl(name, _, init, mutable) =>
            let uniform = (not mutable) and (init |> Option.exists(isUniform(st#locals)));
            (if (uniform) { locals = Set.insert(name, st#locals) | st } else st, leafErrors(fname, st, s))
        case Stmt.If(c, t, e, _) =>
            let condErr = if (st#diverged and anyNode(isDerivativeAt, c)) derivativeError(fname) :: Nil else Nil;
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
        case Stmt.Emit(_, true) =>
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

    /// 節の強さ（括弧が要るかを決める）。言語 lang の raw の字は名前・呼び出しの形でなければ一番弱い。
    /// Bool の uniform は比べの式（GLSL は == 1・WGSL は > 0.5）・GLSL の Affine の varying は割り算の式。
    def precOfNode(lang: Lang, n: Node): Int32 = match n {
        case Node.Bin(op, _, _, _)            => precOf(op)
        case Node.Select(_, _, _, _)          => if (lang == Lang.Wgsl) atomPrec() else ternaryPrec()
        case Node.Neg(_, _)                   => unaryPrec()
        case Node.Not(_)                      => unaryPrec()
        case Node.Uniform((_, Ty.Bool, _, _, _, _)) => if (lang == Lang.Glsl) precOf(BinOp.EqOp) else precOf(BinOp.Gt)
        case Node.Varying(_, _, Interp.Affine) => if (lang == Lang.Glsl) precOf(BinOp.Div) else atomPrec()
        case Node.Intrinsic(Intrinsic.PixelNdc(_, _, _), _) => if (lang == Lang.Glsl) precOf(BinOp.Sub) else atomPrec()
        case Node.Raw(glsl, wgsl, _, _, _)    =>
            let text = if (lang == Lang.Glsl) glsl else wgsl;
            if (text |> Option.forAll(isAtomText)) atomPrec() else 0
        case _                                => atomPrec()
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

    /// uniform u を言語 lang で読む字（outer = 外から重ねる swizzle）。その言語に無い欄なら止める。Bool の uniform は持つ型の値を比べる字。
    def accessFor(lang: Lang, u: UniformKey, outer: String): String =
        let (name, ty, glsl, wgsl, _, _) = u;
        match (if (lang == Lang.Glsl) glsl else wgsl) {
            case Some((base, swizzle)) =>
                let text = accessText(base, swizzle, outer);
                if (ty != Ty.Bool) text else if (lang == Lang.Glsl) text + " == 1" else text + " > 0.5"
            case None => invalidOrBug("ShaderAst: uniform ${name} はこの言語に無い")
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
