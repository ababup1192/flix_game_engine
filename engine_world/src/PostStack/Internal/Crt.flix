// PostStack.Internal.Crt — CRT のにじみ（PostStack.Crt）の面の Spec。横の 5 点のぼかし（明るさ）・色だけの広いぼかし・走査線。
// 3 つの描き手は同じ Spec を読む（新しい式は無い）。
mod PostStack.Internal.Crt {
    use ShaderDoc.{Axis, BinOp, Field, Out, Shade, TexChan, UnOp}

    /// source を読み、size（design）の画素で横にぼかした面。明るさは compositeBlur の半径・色（rgb − 明るさ）は compositeBlur + chromaBleed の半径で広げ、
    /// 走査線は design の画素の行の真ん中を 1・境目を 1 − scanlines にする（0.5 + 0.5 cos で行の中をなめらかに）。
    // WhyNot: 縦の隣と混ぜない — コンポジットの帯域の狭さは横（走査の向き）だけで、縦は行ごとに別の信号。
    // WhyNot: 明るさを Rec.709 でなく Rec.601 の重み（0.299・0.587・0.114）で分ける — コンポジット映像（NTSC の YIQ）の明るさの式に合わせる。
    pub def spec(size: Vec2.Vec2, source: String, c: PostStack.Crt): ShaderDoc.Spec =
        let narrow = Float64.max(0.0, c#compositeBlur);
        let wide = narrow + Float64.max(0.0, c#chromaBleed);
        let hasBleed = c#chromaBleed > 0.0;
        let bindings = List.flatten(
            blurBindings("crt_n", size, source, narrow)
                :: (if (hasBleed) blurBindings("crt_w", size, source, wide) else Nil)
                :: (("crt_line", lineFactor(size, c#scanlines)) :: Nil) :: Nil);
        let chan = (ch: String) -> {
            let base = if (hasBleed) add(luma("crt_n"), sub(Field.Ref("crt_w_${ch}"), luma("crt_w"))) else Field.Ref("crt_n_${ch}");
            mul(base, Field.Ref("crt_line"))
        };
        { name = "ps_crt:${Float64.toString(narrow)}:${Float64.toString(wide)}:${Float64.toString(c#scanlines)}", cycleRate = 0.0, bindings = bindings,
          out = Out.Fill({ shade = Shade.Rgb({ r = chan("r"), g = chan("g"), b = chan("b") }), alpha = Field.Const(1.0) }) }

    /// 横の 5 点（−1・−0.5・0・0.5・1 × 半径・重み 1・4・6・4・1 ÷ 16）で source を読んだ r・g・b を <prefix>_r・_g・_b に置く。半径 0 なら 1 点。
    def blurBindings(prefix: String, size: Vec2.Vec2, source: String, radius: Float64): List[(String, Field)] =
        let taps = if (radius <= 0.0) (0.0, 1.0) :: Nil
                   else (-1.0, 1.0 / 16.0) :: (-0.5, 4.0 / 16.0) :: (0.0, 6.0 / 16.0) :: (0.5, 4.0 / 16.0) :: (1.0, 1.0 / 16.0) :: Nil;
        let read = (tc: TexChan) -> taps |> List.map(t -> {
            let (at, w) = t;
            let tex = Field.Sampler({ filter = ShaderDoc.FilterMode.Linear, of = Field.Tex({ name = source, chan = tc }) });
            let shifted = if (at == 0.0) tex else Field.Shift({ dx = Field.Const(at * radius / size#x), dy = Field.Const(0.0), of = tex });
            mul(Field.Const(w), shifted)
        }) |> List.reduceLeft(add) |> Option.getWithDefault(Field.Const(0.0));
        ("${prefix}_r", read(TexChan.R)) :: ("${prefix}_g", read(TexChan.G)) :: ("${prefix}_b", read(TexChan.B)) :: Nil

    /// <prefix>_r・_g・_b の明るさ（Rec.601）。
    def luma(prefix: String): Field =
        add(add(mul(Field.Const(0.299), Field.Ref("${prefix}_r")), mul(Field.Const(0.587), Field.Ref("${prefix}_g"))), mul(Field.Const(0.114), Field.Ref("${prefix}_b")))

    /// 走査線の掛け算（1 − s × (0.5 + 0.5 cos(2π × 行の中の位置))。行の中の位置 = fract(v × 高さ)）。s が 0 なら 1。
    def lineFactor(size: Vec2.Vec2, s: Float64): Field =
        if (s <= 0.0) Field.Const(1.0)
        else {
            let phase = Field.Un({ op = UnOp.Fract, of = mul(Field.Uv({ axis = Axis.V }), Field.Const(size#y)) });
            let wave = add(Field.Const(0.5), mul(Field.Const(0.5), Field.Un({ op = UnOp.Cos, of = mul(phase, Field.Const(2.0 * 3.141592653589793)) })));
            sub(Field.Const(1.0), mul(Field.Const(Float64.min(1.0, s)), wave))
        }

    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })
    def sub(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Sub, a = a, b = b })
    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })
}
