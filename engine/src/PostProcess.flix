// PostProcess — 画面の仕上げの面（Unity URP / Unreal の Post Process と同じ並び）を ShaderDoc の Spec で組む部品。
// トーンマッピング（1 を超える明るさを 0..1 へなめらかに収める）と FXAA（縁のギザギザをならす）を持つ。
// どれも ShaderDoc の今の場と bindings で組むので、GPU（ShaderGen）と CPU（ShaderEval）が同じ木を評価する。
// 利用例: 本編を Rgba16Float の Pass に描き、`tonemapped(AcesFitted, defaultExposure(), defaultWhitePoint(), 本編の面)` を
// Rgba8Unorm の Pass へ書き、`fxaaSpec(その Pass の名前)` の面を画面へ。HUD と UI は包まない。

pub mod PostProcess {

    use ShaderDoc.{Field, Shade, BinOp, UnOp, Axis, TexChan, FilterMode}

    /// トーンマップの曲線（Unity の Tonemapping Mode・Unreal の Filmic と同じ役目）。
    pub enum Tonemap with Eq, ToString {
        /// Narkowicz 2015 の ACES の近似 `x(2.51x + 0.03) / (x(2.43x + 0.59) + 0.14)` を whitePoint の値で割る。肩がやわらかく暗部が締まる。
        case AcesFitted
        /// 拡張 Reinhard `x(1 + x / W²) / (1 + x)`。W でちょうど 1 になり、折れ目ができない。
        case Reinhard
    }

    /// 既定の露出（stop の数。2^stops 倍してから曲線に掛ける）。曲線の正規化で落ちる白を持ち上げる値で、
    /// 既定の白の点と合わせると 8bit の 1.0 は AcesFitted でおよそ 0.83〜0.9・Reinhard でおよそ 0.62 になる。
    /// 色をガンマのまま扱う所では中間の明るさも持ち上がる（0.3 → 0.55）。中間を保つなら −0.6 前後（docs/shader-doc.md の後処理の節）。
    pub def defaultExposure(): Float64 = 0.4

    /// 既定の白の点（この明るさで 1 になる）。
    pub def defaultWhitePoint(): Float64 = 4.0

    /// ITU-R BT.709 の明るさ（0.2126 r + 0.7152 g + 0.0722 b）。
    pub def luma709(r: Field, g: Field, b: Field): Field =
        add(add(mul(Field.Const(0.2126), r), mul(Field.Const(0.7152), g)), mul(Field.Const(0.0722), b))

    /// spec の色を、露出 2^exposureStops を掛けてから op でトーンマップした色にした Spec（α はそのまま）。
    /// 色の場は bindings の pp_r / pp_g / pp_b に 1 回だけ置く（Ramp・Gradient・Cosine は係数の場を pp_f に置き、cycleRate の往復も写す）。
    /// 名前は "tonemap:曲線:露出:白の点:元の名前"（GPU の program の控えは名前を鍵にするので、元の面と包んだ面・包み方の違う面を別の名前にする）。
    /// cycleRate は 0 にする（往復はもう pp_f に写してあり、残すと after が返す Ramp などにもう 1 回掛かる）。
    /// 白の点が 0 以下なら曲線を白の点でそろえない（AcesFitted は Narkowicz の式のまま・Reinhard は x / (1 + x)）。
    /// spec の bindings に pp_ の名前があれば、トーンマップせず spec をそのまま返して 1 行知らせる。
    /// WhyNot: Field → Field の関数にしない — 曲線の式に x が 4 回出てきて、x の木を GLSL も CPU も 4 回評価する。
    pub def tonemapped(op: Tonemap, exposureStops: Float64, whitePoint: Float64, spec: ShaderDoc.Spec): ShaderDoc.Spec =
        tonemappedWith(op, exposureStops, whitePoint, (r, g, b) -> Shade.Rgb({ r = r, g = g, b = b }), spec)

    /// tonemapped の、トーンマップの後の色に after を掛ける形（色調・かすみなど 0..1 を前提にした仕上げを同じ面の中で）。
    /// after が受ける 3 本は bindings の pp_tr / pp_tg / pp_tb の Ref（0..1）。
    /// 名前に after は入らない（関数は名前にできない）。同じ曲線・露出・白の点で after だけ違う面を同じコマに並べるなら、元の spec の名前を変えて渡す。
    pub def tonemappedWith(op: Tonemap, exposureStops: Float64, whitePoint: Float64,
                           after: (Field, Field, Field) -> Shade, spec: ShaderDoc.Spec): ShaderDoc.Spec =
        let clashes = spec#bindings |> List.map(fst) |> List.filter(name -> List.memberOf(name, reservedNames()));
        if (not List.isEmpty(clashes))
            Log.warnThen("PostProcess fail-open: ${spec#name} をトーンマップせずそのまま描きます — bindings の名前 "
                + String.intercalate(", ", clashes) + " が tonemapped の使う名前と重なる", spec)
        else {
            let ShaderDoc.Out.Fill(fill) = spec#out;
            let (factor, (r, g, b)) = channelsOf(spec#cycleRate, fill#shade);
            let exposure = Float64.pow(base = 2.0, exposureStops);
            let curve = x -> curveField(op, whitePoint, Field.Bin({ op = BinOp.Max, a = mul(x, Field.Const(exposure)), b = Field.Const(0.0) }));
            let mapped = ("pp_tr", curve(Field.Ref("pp_r"))) :: ("pp_tg", curve(Field.Ref("pp_g"))) :: ("pp_tb", curve(Field.Ref("pp_b"))) :: Nil;
            let factorBinding = factor |> Option.map(f -> ("pp_f", f) :: Nil) |> Option.getWithDefault(Nil);
            { name = "tonemap:${op}:${exposureStops}:${whitePoint}:${spec#name}",
              cycleRate = 0.0,
              bindings = List.flatten(spec#bindings :: factorBinding :: (("pp_r", r) :: ("pp_g", g) :: ("pp_b", b) :: Nil) :: mapped :: Nil),
              out = ShaderDoc.Out.Fill({ shade = after(Field.Ref("pp_tr"), Field.Ref("pp_tg"), Field.Ref("pp_tb")), alpha = fill#alpha }) | spec }
        }

    /// tonemapped が bindings に足す名前。
    def reservedNames(): List[String] = "pp_f" :: "pp_r" :: "pp_g" :: "pp_b" :: "pp_tr" :: "pp_tg" :: "pp_tb" :: Nil

    /// 色を 3 本の場にする（係数の場を使う色は、その場を Some で返し、3 本は Ref("pp_f") を読む）。
    /// 係数の作り方は ShaderGen.shadeExpr と同じ（cycleRate が 0 なら 0..1 に切る・正なら時刻で往復する三角波）。
    def channelsOf(cycleRate: Float64, shade: Shade): (Option[Field], (Field, Field, Field)) =
        let f = Field.Ref("pp_f");
        match shade {
            case Shade.Solid(c)     => (None, (Field.Const(c#r), Field.Const(c#g), Field.Const(c#b)))
            case Shade.Rgb(c)       => (None, (c#r, c#g, c#b))
            case Shade.Ramp(rp)     =>
                let ch = (lo, hi) -> Field.Blend({ a = Field.Const(lo), b = Field.Const(hi), by = f });
                (Some(cycledFactor(cycleRate, rp#field)), (ch(rp#lo#r, rp#hi#r), ch(rp#lo#g, rp#hi#g), ch(rp#lo#b, rp#hi#b)))
            case Shade.Gradient(gr) =>
                (Some(cycledFactor(cycleRate, gr#field)), gradientChannels(gr#stops, f))
            case Shade.Cosine(cs)   =>
                let phase = if (cycleRate == 0.0) cs#field else add(cs#field, Field.Time({ scale = cycleRate, offset = Field.Const(0.0) }));
                let ch = (a, b, c, d) -> sat(add(Field.Const(a), mul(Field.Const(b),
                    Field.Un({ op = UnOp.Cos, of = mul(Field.Const(6.2831853), add(mul(Field.Const(c), f), Field.Const(d))) }))));
                (Some(phase), (ch(cs#a#r, cs#b#r, cs#c#r, cs#d#r), ch(cs#a#g, cs#b#g, cs#c#g, cs#d#g), ch(cs#a#b, cs#b#b, cs#c#b, cs#d#b)))
        }

    /// Ramp・Gradient の係数（cycleRate が 0 なら 0..1 に切る・正なら field + cycleRate × 時刻 の三角波）。
    def cycledFactor(cycleRate: Float64, field: Field): Field =
        if (cycleRate == 0.0) sat(field)
        else {
            let moved = add(field, Field.Time({ scale = cycleRate, offset = Field.Const(0.0) }));
            sat(Field.Un({ op = UnOp.Abs, of = sub(mul(Field.Un({ op = UnOp.Fract, of = moved }), Field.Const(2.0)), Field.Const(1.0)) }))
        }

    /// Gradient の 3 本（先頭の色から、隣り合う区切りごとに smoothstep(前の位置, 次の位置, f) の重みで次の色へ。ShaderGen.gradientExpr と同じ）。
    def gradientChannels(stops: List[(Float64, Color)], f: Field): (Field, Field, Field) =
        match stops {
            case Nil             => (Field.Const(0.0), Field.Const(0.0), Field.Const(0.0))
            case (p0, c0) :: rest =>
                let start = (Field.Const(c0#r), Field.Const(c0#g), Field.Const(c0#b));
                let (out, _) = List.foldLeft((acc, stop) -> {
                    let ((r, g, b), prevPos) = acc;
                    let (pos, col) = stop;
                    let w = Field.Smoothstep({ lo = prevPos, hi = pos, of = f });
                    let step = (cur, next) -> Field.Blend({ a = cur, b = Field.Const(next), by = w });
                    ((step(r, col#r), step(g, col#g), step(b, col#b)), pos)
                }, (start, p0), rest);
                out
        }

    /// 曲線を whitePoint で 1 になるようにそろえ、0..1 に切った場（x は露出を掛けて 0 で下切りした値）。whitePoint が 0 以下ならそろえない。
    def curveField(op: Tonemap, whitePoint: Float64, x: Field): Field =
        match op {
            case Tonemap.AcesFitted =>
                let aces = (v: Field) -> Field.Bin({ op = BinOp.Div,
                    a = mul(v, add(mul(Field.Const(2.51), v), Field.Const(0.03))),
                    b = add(mul(v, add(mul(Field.Const(2.43), v), Field.Const(0.59))), Field.Const(0.14)) });
                let scale = if (whitePoint <= 0.0) 1.0 else 1.0 / acesAt(whitePoint);
                sat(mul(aces(x), Field.Const(scale)))
            case Tonemap.Reinhard =>
                let invW2 = if (whitePoint <= 0.0) 0.0 else 1.0 / (whitePoint * whitePoint);
                let num = mul(x, add(Field.Const(1.0), mul(x, Field.Const(invW2))));
                sat(Field.Bin({ op = BinOp.Div, a = num, b = add(Field.Const(1.0), x) }))
        }

    /// AcesFitted の曲線の値（正の whitePoint での値で割るための数。x は正。値が 0 以下に潰れたら 1 を返し、割らない）。
    def acesAt(x: Float64): Float64 =
        let y = x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14);
        if (y <= 0.0) 1.0 else y

    // ── FXAA ──

    /// source の Pass を FXAA 3.11（PC の簡単な版）でならした面。斜めの 4 点（NW・NE・SW・SE）と真ん中の明るさから縁の向きを出し、
    /// 向きに沿った 4 点を Linear で読んで混ぜる（REDUCE_MIN 1/128・REDUCE_MUL 1/8・SPAN_MAX 8 テクセル）。α は 1。
    /// source はトーンマップ済みの Rgba8Unorm・窓の画素（Window・scale 1）の Pass を前提にする（縮んだ Pass では 1 テクセルが 1 画素にならない）。
    /// 隣の明るさは 1 点ずつ bindings に置く（Ref は Shift の中で読み直されないので、ずらして読む式をそれぞれに書く）。
    pub def fxaaSpec(source: String): ShaderDoc.Spec =
        let ref = Field.Ref;
        let texel = (dx: Field, dy: Field, chan: TexChan) -> Field.Shift({ dx = dx, dy = dy, of = Field.Tex({ name = source, chan = chan }) });
        let lumaAt = (sx: Float64, sy: Float64) -> {
            let dx = mul(Field.Const(sx), ref("fx_rx"));
            let dy = mul(Field.Const(sy), ref("fx_ry"));
            luma709(texel(dx, dy, TexChan.R), texel(dx, dy, TexChan.G), texel(dx, dy, TexChan.B))
        };
        let along = (k: Float64, chan: TexChan) ->
            Field.Sampler({ filter = FilterMode.Linear, of = texel(mul(Field.Const(k), ref("fx_ox")), mul(Field.Const(k), ref("fx_oy")), chan) });
        let pairA = (chan: TexChan) -> mul(Field.Const(0.5), add(along(1.0 / 3.0 - 0.5, chan), along(2.0 / 3.0 - 0.5, chan)));
        let pairB = (a: String, chan: TexChan) ->
            add(mul(Field.Const(0.5), ref(a)), mul(Field.Const(0.25), add(along(-0.5, chan), along(0.5, chan))));
        let nw = ref("fx_nw");
        let ne = ref("fx_ne");
        let sw = ref("fx_sw");
        let se = ref("fx_se");
        let lumaMin = minF(ref("fx_m"), minF(minF(nw, ne), minF(sw, se)));
        let lumaMax = maxF(ref("fx_m"), maxF(maxF(nw, ne), maxF(sw, se)));
        let reduce = maxF(mul(add(add(nw, ne), add(sw, se)), Field.Const(0.25 / 8.0)), Field.Const(1.0 / 128.0));
        let span = (d: String, texelSize: String) ->
            mul(minF(Field.Const(8.0), maxF(Field.Const(-8.0), mul(ref(d), ref("fx_rcp")))), ref(texelSize));
        // 混ぜた明るさが 4 点と真ん中の幅の外なら、遠くの 2 点まで混ぜすぎたので近い 2 点の平均（A）に戻す。
        let below = Field.Un({ op = UnOp.OneMinus, of = Field.Bin({ op = BinOp.Step, a = ref("fx_min"), b = ref("fx_lb") }) });
        let above = Field.Un({ op = UnOp.OneMinus, of = Field.Bin({ op = BinOp.Step, a = ref("fx_lb"), b = ref("fx_max") }) });
        let pick = (b: String, a: String) -> Field.Blend({ a = ref(b), b = ref(a), by = ref("fx_out") });
        { name = "fxaa:" + source,
          cycleRate = 0.0,
          bindings =
              ("fx_rx", Field.Bin({ op = BinOp.Div, a = Field.Const(1.0), b = Field.TexSize({ name = source, axis = Axis.U }) })) ::
              ("fx_ry", Field.Bin({ op = BinOp.Div, a = Field.Const(1.0), b = Field.TexSize({ name = source, axis = Axis.V }) })) ::
              ("fx_nw", lumaAt(-1.0, -1.0)) ::
              ("fx_ne", lumaAt(1.0, -1.0)) ::
              ("fx_sw", lumaAt(-1.0, 1.0)) ::
              ("fx_se", lumaAt(1.0, 1.0)) ::
              ("fx_m", lumaAt(0.0, 0.0)) ::
              ("fx_min", lumaMin) ::
              ("fx_max", lumaMax) ::
              ("fx_dx", sub(add(sw, se), add(nw, ne))) ::
              ("fx_dy", sub(add(nw, sw), add(ne, se))) ::
              ("fx_rcp", Field.Bin({ op = BinOp.Div, a = Field.Const(1.0),
                  b = add(minF(Field.Un({ op = UnOp.Abs, of = ref("fx_dx") }), Field.Un({ op = UnOp.Abs, of = ref("fx_dy") })), reduce) })) ::
              ("fx_ox", span("fx_dx", "fx_rx")) ::
              ("fx_oy", span("fx_dy", "fx_ry")) ::
              ("fx_ar", pairA(TexChan.R)) ::
              ("fx_ag", pairA(TexChan.G)) ::
              ("fx_ab", pairA(TexChan.B)) ::
              ("fx_br", pairB("fx_ar", TexChan.R)) ::
              ("fx_bg", pairB("fx_ag", TexChan.G)) ::
              ("fx_bb", pairB("fx_ab", TexChan.B)) ::
              ("fx_lb", luma709(ref("fx_br"), ref("fx_bg"), ref("fx_bb"))) ::
              ("fx_out", maxF(below, above)) :: Nil,
          out = ShaderDoc.Out.Fill({ shade = Shade.Rgb({ r = pick("fx_br", "fx_ar"), g = pick("fx_bg", "fx_ag"), b = pick("fx_bb", "fx_ab") }),
                                     alpha = Field.Const(1.0) }) }

    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })

    def sub(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Sub, a = a, b = b })

    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })

    def minF(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Min, a = a, b = b })

    def maxF(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Max, a = a, b = b })

    def sat(a: Field): Field = Field.Un({ op = UnOp.Sat, of = a })
}
