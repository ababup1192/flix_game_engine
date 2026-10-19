// ShaderEval — Spec 木を CPU（Float64）で評価する純関数。GL の描画経路ではないが、
// SoftRaster（描き出し・動画・スナップショット）はシェーダー面の画素をこれで塗る。
// テスト（代表点 (u,v,t) の値を釘打ち）にも使う。何万画素も評価する側は compile で
// 面ごとに 1 回だけ組み直してから evalCompiled を画素ごとに呼ぶ。
// GPU と byte 一致させる義務はない（Hash は近似で可）が、式の構造は ShaderGen と同じにして
// 「数式の正気」を確かめる（網目が目地で立つ・スクロールで動く・パレットが回る、など）。
//
// 読む順: 公開の入口（evalPixel …）→ compile（Spec → Node の木）→ evalNode（画素 1 つ）→ ノイズ。

pub mod ShaderEval {

    /// テクスチャ 1 枚ぶんの画素（ARGB・正立・行優先）。Tex ノードが CPU 側で標本する素材。
    /// GL の pass ターゲットは上下逆格納だが描き出しの pass 画像は正立なので、CPU 側は反転しない
    /// （反転の吸収は GL の uTexFlip だけが持つ既存の非対称と同型）。
    pub type alias TexData = { width = Int32, height = Int32, pixels = Vector[Int32] }

    /// 代表点 uv（0..1 目安）と時刻 t の最終色（Color = 0..1 の rgb）。
    pub def evalPixel(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64): Color =
        evalPixelTex(spec, uv, t, Map.empty())

    /// 代表点のアルファ（Fill#alpha の場を評価）。
    pub def evalAlpha(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64): Float64 =
        evalAlphaTex(spec, uv, t, Map.empty())

    /// evalPixel のテクスチャつき版。texEnv は名前 → 画素（pass の生成結果など）。
    pub def evalPixelTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64,
                         texEnv: Map[String, TexData]): Color =
        fst(evalPixelAlphaTex(spec, uv, t, texEnv))

    /// evalAlpha のテクスチャつき版。
    pub def evalAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64,
                         texEnv: Map[String, TexData]): Float64 =
        snd(evalPixelAlphaTex(spec, uv, t, texEnv))

    /// 色とアルファを一度に返す版（bindings の先行評価を色と α で共有する）。
    /// 1 点だけ評価する入口で、呼ぶたびに組み直す。何万画素も塗るなら compile + evalCompiled。
    pub def evalPixelAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64,
                              texEnv: Map[String, TexData]): (Color, Float64) =
        let (r, g, b, a) = evalCompiled(compile(spec, texEnv), uv#x, uv#y, t);
        ({ r = r, g = g, b = b }, a)

    /// 場を Float64 へ（shared も tex も無い所で 1 点だけ）。
    pub def evalField(field: ShaderDoc.Field, uv: Vec2.Vec2, t: Float64): Float64 = region rc {
        let env: Array[Float64, rc] = Array.empty(rc, 0);
        evalNode(compileField(Map.empty(), Map.empty(), field), uv#x, uv#y, t, env)
    }

    // ── 組み直し（面ごとに 1 回）──

    /// compile が組み直した面 1 枚（外からは作らせない — compile で作る）。
    /// bindings は前から順の場（Ref は添字で読む）、shade は色、alpha は α の場。
    enum Compiled {
        case Compiled(List[Node], CShade, Node, Float64, Int32)
    }

    /// 組み直した面。compile で作り、evalCompiled に画素ごとに渡す。
    pub type alias CompiledSpec = Compiled

    /// 場を位置で持つ木。ShaderDoc.Field の record を組み直しのときに 1 回だけ読み、
    /// 画素ごとに払うのは計算そのものだけにする（record の欄は名前で引くので画素ごとには重い）。
    /// 各 case の式は ShaderDoc.Field の同名 case と同じ（GLSL の ShaderGen とも同じ形）。
    enum Node {
        case Const(Float64)
        case UvU
        case UvV
        case Worley(Float64, Float64, ShaderDoc.WorleyOut)             // scale, seed, out
        case Fbm(Float64, Int32, Float64)                             // scale, octaves, seed
        case FbmTile(Float64, Float64, Float64, Int32, Float64)       // scale, period x/y, octaves, seed
        case Smoothstep(Float64, Float64, Node)                       // lo, hi, of
        case Scaled(Float64, Float64, Float64, Node)                  // factor, scroll x/y, of
        case Warp(Float64, Float64, Float64, Node)                    // scale, amount, seed, of
        case Swirl(Float64, Float64, Float64, Float64, Node)          // cx, cy, strength, rate, of
        case Angle(Float64, Float64)                                  // cx, cy
        case Rotate(Float64, Float64, Float64, Float64, Node)         // cx, cy, turns, rate, of
        case Mix(Node, Node, Float64)                                 // a, b, t
        case Blend(Node, Node, Node)                                  // a, b, by
        case Disk(Float64, Float64, Float64, Float64)                 // cx, cy, radius, feather
        case Radial(Float64, Float64)                                 // cx, cy
        case RadialAspect(Float64, Float64, Float64)                  // cx, cy, aspect
        case Quantize(Float64, Node)                                  // 段の数, of
        case Scales(Float64, Float64)                                 // scale, stagger
        case Glints(Float64, Float64, Float64, Float64)               // scale, rate, density, seed
        case Ripples(Float64, Float64, Float64, Float64)              // freq, amp, speed, seed
        case Sparkle(Float64, Float64, Float64, Float64)              // scale, rate, density, seed
        case Bin(ShaderDoc.BinOp, Node, Node)
        case Hash1(Float64, Float64, Option[Node])                    // scale, seed, bucket
        case Hash2(Float64, Float64, ShaderDoc.Axis, Option[Node])    // scale, seed, comp, bucket
        case Un(ShaderDoc.UnOp, Node)
        case Pow(Node, Float64)
        case Time(Float64, Node)                                      // scale, offset
        case Tiling(Float64, Float64, Node)                           // tiles x/y, of
        case Snap(Float64, Float64, Node)                             // 分割数 x/y（下切り済み）, of
        case Ref(Int32)                                               // bindings の添字
        case Missing                                                  // 未定義の Ref・無い tex（0.0）
        case Tex(Int32, Int32, Vector[Int32], Int32)                  // 幅, 高さ, 画素, チャンネルの shift
        case Shift(Node, Node, Node)                                  // dx, dy, of
    }

    /// 面の色。Color は (r, g, b) の位置で持つ。
    enum CShade {
        case Solid(Float64, Float64, Float64)
        case Ramp((Float64, Float64, Float64), (Float64, Float64, Float64), Node)
        case Gradient(List[(Float64, (Float64, Float64, Float64))], Node)
        case Cosine(Vector[Float64], Node)                            // a,b,c,d の rgb を colorF64 済みで 12 個
        case Rgb(Node, Node, Node)
    }

    /// Spec を面 1 枚ぶん組み直す。texEnv の名前もここで引いておく（画素ごとに Map を引かない）。
    /// shared の名前もここで添字に直す。前の binding だけが後の binding から Ref できる
    /// （GL が main 先頭に sg_b_ 宣言を並べるのと同じ意味論）。同じ名前が 2 度あれば後の方が勝つ。
    /// WhyNot: 「Spec を受けて画素の関数を返す」形（`let f = 組み立て; (uv, t) -> f(..)`）にしない。
    /// Flix 0.78 の最適化は、純粋な let の値がラムダの中で 1 回だけ使われると式をラムダの中へ
    /// 書き写す（@DontInline でも止まらない）ので、組み立てが画素ごとに走る。組み直しはデータ
    /// （CompiledSpec）で返し、呼ぶ側は画素ループの外で受ける（SoftRaster.onceOutsideLoop）。
    pub def compile(spec: ShaderDoc.Spec, texEnv: Map[String, TexData]): CompiledSpec =
        let (revBindings, scope, count) = List.foldLeft((acc, nf) -> {
            let (nodes, sc, i) = acc;
            let (name, field) = nf;
            (compileField(sc, texEnv, field) :: nodes, Map.insert(name, i, sc), i + 1)
        }, (Nil, Map.empty(), 0), spec#bindings);
        match spec#out {
            case ShaderDoc.Out.Fill(f) =>
                Compiled.Compiled(List.reverse(revBindings), compileShade(scope, texEnv, f#shade),
                                  compileField(scope, texEnv, f#alpha), spec#cycleRate, count)
        }

    /// 画素 1 つ（uv = (u, v)・時刻 t）の (r, g, b, α)。値は evalPixelAlphaTex と同じ。
    /// out から参照されない binding もここで必ず評価する — 使わない shared は合法だが、その分は
    /// 黙って画素ごとの計算に乗る。
    pub def evalCompiled(compiled: CompiledSpec, u: Float64, v: Float64, t: Float64): (Float64, Float64, Float64, Float64) =
        match compiled {
            case Compiled.Compiled(bindings, shade, alpha, cycleRate, count) => region rc {
                let env: Array[Float64, rc] = Array.empty(rc, count);
                fillEnv(bindings, 0, u, v, t, env);
                let (r, g, b) = evalShade(shade, cycleRate, u, v, t, env);
                (r, g, b, evalNode(alpha, u, v, t, env))
            }
        }

    def fillEnv(bindings: List[Node], i: Int32, u: Float64, v: Float64, t: Float64, env: Array[Float64, r]): Unit \ r =
        match bindings {
            case Nil => ()
            case node :: rest =>
                Array.put(evalNode(node, u, v, t, env), i, env);
                fillEnv(rest, i + 1, u, v, t, env)
        }

    def compileShade(scope: Map[String, Int32], texEnv: Map[String, TexData], shade: ShaderDoc.Shade): CShade =
        let rgb = (c: Color) -> (c#r, c#g, c#b);
        match shade {
            case ShaderDoc.Shade.Solid(c)    => CShade.Solid(c#r, c#g, c#b)
            case ShaderDoc.Shade.Ramp(r)     => CShade.Ramp(rgb(r#lo), rgb(r#hi), compileField(scope, texEnv, r#field))
            case ShaderDoc.Shade.Gradient(g) =>
                CShade.Gradient(List.map(pc -> { let (p, c) = pc; (p, rgb(c)) }, g#stops),
                                compileField(scope, texEnv, g#field))
            case ShaderDoc.Shade.Cosine(cs)  =>
                let (a, b, c, d) = (cs#a, cs#b, cs#c, cs#d);
                let k = List.map(colorF64, a#r :: b#r :: c#r :: d#r :: a#g :: b#g :: c#g :: d#g :: a#b :: b#b :: c#b :: d#b :: Nil);
                CShade.Cosine(List.toVector(k), compileField(scope, texEnv, cs#field))
            case ShaderDoc.Shade.Rgb(c)      =>
                CShade.Rgb(compileField(scope, texEnv, c#r), compileField(scope, texEnv, c#g),
                           compileField(scope, texEnv, c#b))
        }

    def compileField(scope: Map[String, Int32], texEnv: Map[String, TexData], field: ShaderDoc.Field): Node =
        let sub = f -> compileField(scope, texEnv, f);
        match field {
            case ShaderDoc.Field.Const(v)       => Node.Const(v)
            case ShaderDoc.Field.Uv(u)          =>
                match u#axis {
                    case ShaderDoc.Axis.U => Node.UvU
                    case ShaderDoc.Axis.V => Node.UvV
                }
            case ShaderDoc.Field.Worley(w)      => Node.Worley(w#scale, Int32.toFloat64(w#seed), w#out)
            case ShaderDoc.Field.Fbm(b)         => Node.Fbm(b#scale, b#octaves, Int32.toFloat64(b#seed))
            case ShaderDoc.Field.FbmTile(b)     =>
                Node.FbmTile(b#scale, b#period#x, b#period#y, b#octaves, Int32.toFloat64(b#seed))
            case ShaderDoc.Field.Smoothstep(s)  => Node.Smoothstep(s#lo, s#hi, sub(s#of))
            case ShaderDoc.Field.Scaled(s)      => Node.Scaled(s#factor, s#scroll#x, s#scroll#y, sub(s#of))
            case ShaderDoc.Field.Warp(wp)       => Node.Warp(wp#scale, wp#amount, Int32.toFloat64(wp#seed), sub(wp#of))
            case ShaderDoc.Field.Swirl(sw)      => Node.Swirl(sw#cx, sw#cy, sw#strength, sw#rate, sub(sw#of))
            case ShaderDoc.Field.Angle(an)      => Node.Angle(an#cx, an#cy)
            case ShaderDoc.Field.Rotate(rt)     => Node.Rotate(rt#cx, rt#cy, rt#turns, rt#rate, sub(rt#of))
            case ShaderDoc.Field.Mix(m)         => Node.Mix(sub(m#a), sub(m#b), m#t)
            case ShaderDoc.Field.Blend(bl)      => Node.Blend(sub(bl#a), sub(bl#b), sub(bl#by))
            case ShaderDoc.Field.Disk(d)        => Node.Disk(d#cx, d#cy, d#radius, d#feather)
            case ShaderDoc.Field.Radial(rd)     => Node.Radial(rd#cx, rd#cy)
            case ShaderDoc.Field.RadialAspect(ra) => Node.RadialAspect(ra#cx, ra#cy, ra#aspect)
            case ShaderDoc.Field.Quantize(q)    => Node.Quantize(Int32.toFloat64(Int32.max(1, q#steps)), sub(q#of))
            case ShaderDoc.Field.Scales(sc)     => Node.Scales(sc#scale, sc#stagger)
            case ShaderDoc.Field.Glints(g)      => Node.Glints(g#scale, g#rate, g#density, Int32.toFloat64(g#seed))
            case ShaderDoc.Field.Ripples(rp)    => Node.Ripples(rp#freq, rp#amp, rp#speed, Int32.toFloat64(rp#seed))
            case ShaderDoc.Field.Sparkle(sp)    => Node.Sparkle(sp#scale, sp#rate, sp#density, Int32.toFloat64(sp#seed))
            case ShaderDoc.Field.Bin(bn)        => Node.Bin(bn#op, sub(bn#a), sub(bn#b))
            case ShaderDoc.Field.Hash1(h)       => Node.Hash1(h#scale, Int32.toFloat64(h#seed), Option.map(sub, h#bucket))
            case ShaderDoc.Field.Hash2(h)       => Node.Hash2(h#scale, Int32.toFloat64(h#seed), h#comp, Option.map(sub, h#bucket))
            case ShaderDoc.Field.Un(un)         => Node.Un(un#op, sub(un#of))
            case ShaderDoc.Field.Pow(pw)        => Node.Pow(sub(pw#of), pw#p)
            case ShaderDoc.Field.Time(tm)       => Node.Time(tm#scale, sub(tm#offset))
            case ShaderDoc.Field.Tiling(tl)     => Node.Tiling(tl#tiles#x, tl#tiles#y, sub(tl#of))
            // GLSL の (floor(uv*cells)+0.5)/cells と同じ形（描き出しと実機で塊の位置を割らない）。
            case ShaderDoc.Field.Snap(sn)       => Node.Snap(snapCells(sn#cells#x), snapCells(sn#cells#y), sub(sn#of))
            // parse が定義済みを保証する。未定義は 0.0（保険）。値は基準 uv での先行評価済み —
            // 座標変換の内側でも読み直さない（GL の sg_b_ 変数と同じ意味論）。
            case ShaderDoc.Field.Ref(name)      =>
                match Map.get(name, scope) {
                    case Some(i) => Node.Ref(i)
                    case None    => Node.Missing
                }
            // 無い名前は 0.0（黒）。警告は IO を持つ生成側（SoftRaster）が出す — ここは純関数。
            case ShaderDoc.Field.Tex(tx)        =>
                match Map.get(tx#name, texEnv) {
                    case Some(td) => Node.Tex(td#width, td#height, td#pixels, texShift(tx#chan))
                    case None     => Node.Missing
                }
            // dx/dy は外側 uv で評価してから、of をずらした座標で読む（GLSL の式と同じ組み方）。
            case ShaderDoc.Field.Shift(sh)      => Node.Shift(sub(sh#dx), sub(sh#dy), sub(sh#of))
        }

    def texShift(chan: ShaderDoc.TexChan): Int32 =
        match chan {
            case ShaderDoc.TexChan.A => 24
            case ShaderDoc.TexChan.R => 16
            case ShaderDoc.TexChan.G => 8
            case ShaderDoc.TexChan.B => 0
        }

    // ── 画素ごと ──

    def evalShade(shade: CShade, cycleRate: Float64, x: Float64, y: Float64, t: Float64,
                  env: Array[Float64, r]): (Float64, Float64, Float64) \ r =
        match shade {
            case CShade.Solid(r, g, b) => (r, g, b)
            case CShade.Ramp(lo, hi, field) =>
                // cycleRate = 0 は素直な補間。cycleRate>0 だけ三角波で往復（パレット循環）。
                let v = evalNode(field, x, y, t, env);
                let phase = if (cycleRate == 0.0) Num.clamp01(v)
                            else Num.clamp01(triWave(v + cycleRate * t));
                mixColor(lo, hi, phase)
            case CShade.Gradient(stops, field) =>
                // GLSL と同じ数式でなぞる: 係数 f を Ramp と同じ規約で作り、
                // 先頭色から隣の区切りごとに smoothstep 重みで次の色へ近づける。
                let v = evalNode(field, x, y, t, env);
                let f = if (cycleRate == 0.0) Num.clamp01(v)
                        else Num.clamp01(triWave(v + cycleRate * t));
                gradientColor(f, stops)
            case CShade.Cosine(k, field) =>
                let v = evalNode(field, x, y, t, env);
                let tt = if (cycleRate == 0.0) v else v + cycleRate * t;
                cosColor(k, tt)
            case CShade.Rgb(fr, fg, fb) =>
                // cycleRate は読まない（Shade.Rgb の doc の決まり）。
                let r = colorF32(evalNode(fr, x, y, t, env));
                let g = colorF32(evalNode(fg, x, y, t, env));
                let b = colorF32(evalNode(fb, x, y, t, env));
                (r, g, b)
        }

    /// コサインパレット col = a + b·cos(2π(c·t + d)) を各チャンネルで（ShaderGen の sg_cospal と同じ数式）。
    /// k は (a,b,c,d) の r → g → b の順に 12 個（colorF64 済み）。
    def cosColor(k: Vector[Float64], t: Float64): (Float64, Float64, Float64) =
        let ch = i -> colorF32(Vector.get(i, k) + Vector.get(i + 1, k) *
                               Vec2.cos(6.2831853 * (Vector.get(i + 2, k) * t + Vector.get(i + 3, k))));
        (ch(0), ch(4), ch(8))

    def colorF64(x: Float64): Float64 = Float32.toFloat64(RenderUtil.f32(x))

    // Float64.clampToFloat32(min = 0.0f32, max = 1.0f32, x) と同じ値（NaN は NaN・範囲外は端）。
    // 名前つき引数の record を画素ごとに作らないために書き下す。
    def unitF32(x: Float64): Float32 =
        if (x != x) Float32.nan()
        else RenderUtil.f32(if (x < 0.0) 0.0 else if (x > 1.0) 1.0 else x)

    def colorF32(x: Float64): Float64 = Float32.toFloat64(unitF32(x))

    /// 係数 f（0..1）で stops を混ぜた色。ShaderGen の gradientExpr と同じ入れ子 mix を辿る。
    def gradientColor(f: Float64, stops: List[(Float64, (Float64, Float64, Float64))]): (Float64, Float64, Float64) =
        match stops {
            case Nil => (0.0, 0.0, 0.0)
            case (p0, c0) :: rest => gradientFrom(f, c0, p0, rest)
        }

    def gradientFrom(f: Float64, cur: (Float64, Float64, Float64), prevPos: Float64,
                     stops: List[(Float64, (Float64, Float64, Float64))]): (Float64, Float64, Float64) =
        match stops {
            case Nil => cur
            case (pos, col) :: rest => gradientFrom(f, mixColor(cur, col, smoothstep(prevPos, pos, f)), pos, rest)
        }

    def evalNode(node: Node, x: Float64, y: Float64, t: Float64, env: Array[Float64, r]): Float64 \ r =
        match node {
            case Node.Const(v) => v
            case Node.UvU => x
            case Node.UvV => y
            case Node.Worley(scale, seed, out) =>
                let (f1, f2) = worleyF1F2(x * scale, y * scale, seed);
                match out {
                    case ShaderDoc.WorleyOut.F1    => f1
                    case ShaderDoc.WorleyOut.F2    => f2
                    case ShaderDoc.WorleyOut.F2mF1 => f2 - f1
                }
            case Node.Fbm(scale, octaves, seed) => fbm(x * scale, y * scale, octaves, seed)
            case Node.FbmTile(scale, periodX, periodY, octaves, seed) =>
                fbmTile(x * scale, y * scale, periodX, periodY, octaves, seed)
            case Node.Smoothstep(lo, hi, of) => smoothstep(lo, hi, evalNode(of, x, y, t, env))
            case Node.Scaled(factor, scrollX, scrollY, of) =>
                evalNode(of, x * factor + scrollX * t, y * factor + scrollY * t, t, env)
            case Node.Warp(scale, amount, seed, of) =>
                let ox = fbm(x * scale, y * scale, 3, seed) - 0.5;
                let oy = fbm(x * scale, y * scale, 3, seed + 91.0) - 0.5;
                evalNode(of, x + ox * amount, y + oy * amount, t, env)
            case Node.Swirl(cx, cy, strength, rate, of) =>
                let px = x - cx;
                let py = y - cy;
                let r = Vec2.sqrt(px * px + py * py);
                let a = strength / (r + 0.08) + rate * t;
                let co = Vec2.cos(a);
                let s = Vec2.sin(a);
                evalNode(of, cx + px * co - py * s, cy + px * s + py * co, t, env)
            case Node.Angle(cx, cy) => Vec2.atan2(y - cy, x - cx) * 0.15915494 + 0.5
            case Node.Rotate(cx, cy, turns, rate, of) =>
                let px = x - cx;
                let py = y - cy;
                let a = 6.2831853 * (turns + rate * t);
                let co = Vec2.cos(a);
                let s = Vec2.sin(a);
                evalNode(of, cx + px * co - py * s, cy + px * s + py * co, t, env)
            case Node.Mix(fa, fb, k) => Num.lerp(evalNode(fa, x, y, t, env), evalNode(fb, x, y, t, env), k)
            case Node.Blend(fa, fb, fby) =>
                let a = evalNode(fa, x, y, t, env);
                let b = evalNode(fb, x, y, t, env);
                Num.lerp(a, b, Num.clamp01(evalNode(fby, x, y, t, env)))
            case Node.Disk(cx, cy, radius, feather) =>
                let dx = x - cx;
                let dy = y - cy;
                1.0 - smoothstep(radius, radius + feather, Vec2.sqrt(dx * dx + dy * dy))
            case Node.Radial(cx, cy) =>
                let dx = x - cx;
                let dy = y - cy;
                Vec2.sqrt(dx * dx + dy * dy)
            case Node.RadialAspect(cx, cy, aspect) =>
                let dx = (x - cx) * aspect;
                let dy = y - cy;
                Vec2.sqrt(dx * dx + dy * dy)
            case Node.Quantize(n, of) => Float64.floor(evalNode(of, x, y, t, env) * n) / n
            case Node.Scales(scale, stagger) => scalesAt(x * scale, y * scale, stagger)
            case Node.Glints(scale, rate, density, sd) =>
                let px = x * scale;
                let py = y * scale;
                let ipx = Float64.floor(px);
                let ipy = Float64.floor(py);
                let fpx = Num.fract(px);
                let fpy = Num.fract(py);
                let on = if (hash1(ipx, ipy, sd) >= 1.0 - density) 1.0 else 0.0;
                let phase = hash1(ipx, ipy, sd + 7.0) * 6.2831853;
                let tw = Float64.max(0.0, Vec2.sin(t * rate + phase));
                let dash = (1.0 - smoothstep(0.04, 0.10, Float64.abs(fpy - 0.5))) *
                           (1.0 - smoothstep(0.28, 0.46, Float64.abs(fpx - 0.5)));
                on * tw * dash
            case Node.Ripples(freq, amp, speed, sd) =>
                let wob = Vec2.sin(x * 6.2831853 * freq * 0.5 + sd) * amp
                        + Vec2.sin(x * 6.2831853 * freq * 1.3 + sd * 2.7) * amp * 0.4;
                let band = y * freq + wob + t * speed;
                0.5 + 0.5 * Vec2.sin(band * 6.2831853)
            case Node.Sparkle(scale, rate, density, sd) => sparkleAt(x * scale, y * scale, t, rate, density, sd)
            case Node.Bin(op, fa, fb) =>
                let a = evalNode(fa, x, y, t, env);
                let b = evalNode(fb, x, y, t, env);
                match op {
                    case ShaderDoc.BinOp.Add  => a + b
                    case ShaderDoc.BinOp.Sub  => a - b
                    case ShaderDoc.BinOp.Mul  => a * b
                    case ShaderDoc.BinOp.Min  => Float64.min(a, b)
                    case ShaderDoc.BinOp.Max  => Float64.max(a, b)
                    case ShaderDoc.BinOp.Step => if (b >= a) 1.0 else 0.0
                }
            // hash に渡すセル座標は floor(uv*scale)。bucket が有ればその値を両成分へ足す（GLSL の
            // vec2+float 自動配りと同じ）。
            case Node.Hash1(scale, seed, bucket) =>
                let cx = Float64.floor(x * scale);
                let cy = Float64.floor(y * scale);
                match bucket {
                    case None    => hash1(cx, cy, seed)
                    case Some(b) => let bv = evalNode(b, x, y, t, env); hash1(cx + bv, cy + bv, seed)
                }
            case Node.Hash2(scale, seed, comp, bucket) =>
                let cx = Float64.floor(x * scale);
                let cy = Float64.floor(y * scale);
                let (hx, hy) = match bucket {
                    case None    => (cx, cy)
                    case Some(b) => let bv = evalNode(b, x, y, t, env); (cx + bv, cy + bv)
                };
                match comp {
                    case ShaderDoc.Axis.U => hash1(hx, hy, seed)
                    case ShaderDoc.Axis.V => hash1(hx + 19.19, hy + 7.31, seed)
                }
            case Node.Un(op, of) =>
                let v = evalNode(of, x, y, t, env);
                match op {
                    case ShaderDoc.UnOp.Neg      => -v
                    case ShaderDoc.UnOp.Abs      => Float64.abs(v)
                    case ShaderDoc.UnOp.Fract    => Num.fract(v)
                    case ShaderDoc.UnOp.Floor    => Float64.floor(v)
                    case ShaderDoc.UnOp.Sin      => Vec2.sin(v)
                    case ShaderDoc.UnOp.Cos      => Vec2.cos(v)
                    case ShaderDoc.UnOp.Sat      => Num.clamp01(v)
                    case ShaderDoc.UnOp.OneMinus => 1.0 - v
                }
            case Node.Pow(of, p) => powf(evalNode(of, x, y, t, env), p)
            case Node.Time(scale, offset) => t * scale + evalNode(offset, x, y, t, env)
            // 各マス内は fract(uv*tiles)。of をこの座標で読む（GLSL の差し替えと同じ形）。
            case Node.Tiling(tilesX, tilesY, of) => evalNode(of, Num.fract(x * tilesX), Num.fract(y * tilesY), t, env)
            case Node.Snap(cx, cy, of) =>
                evalNode(of, (Float64.floor(x * cx) + 0.5) / cx, (Float64.floor(y * cy) + 0.5) / cy, t, env)
            case Node.Ref(i) => Array.get(i, env)
            case Node.Missing => 0.0
            case Node.Tex(w, h, pixels, shift) => sampleTex(w, h, pixels, shift, x, y)
            case Node.Shift(fdx, fdy, of) =>
                let dx = evalNode(fdx, x, y, t, env);
                let dy = evalNode(fdy, x, y, t, env);
                evalNode(of, x + dx, y + dy, t, env)
        }

    /// テクスチャ標本（NEAREST + CLAMP の釘打ち式 — GL と同じ量子化になるのが backend-parity の契約）。
    /// ix = clamp(floor(u*w), 0, w−1)・iy 同様。チャンネル値は 8bit を 255 で割った 0..1。
    def sampleTex(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else {
            let ix = clampTexel(Float64.floor(u * Int32.toFloat64(w)), w);
            let iy = clampTexel(Float64.floor(v * Int32.toFloat64(h)), h);
            let argb = Vector.get(iy * w + ix, pixels);
            Int32.toFloat64(Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, argb), 255)) / 255.0
        }

    /// texel 添字を [0, n−1] に張り付ける（CLAMP）。floor 済みの値を受ける。
    def clampTexel(x: Float64, n: Int32): Int32 =
        Int32.max(0, Int32.min(n - 1, Float64.tryToInt32(x) |> Option.getWithDefault(0)))

    // Pow の CPU 評価。整数指数は反復積（GLSL の powProduct と同じ左結合の並び）で、
    // 非整数のみ Float64.pow を呼ぶ（第 1 引数はレコード）。負の底は 0 で下切り。
    def powf(x: Float64, p: Float64): Float64 =
        let base = Float64.max(0.0, x);
        if (Float64.floor(p) == p)
            powProduct(base, Float64.floor(p))
        else
            Float64.pow({ base = base }, p)

    // Snap の分割数（ShaderGen.snapCells と同じ下切り）。
    def snapCells(c: Float64): Float64 = Float64.max(1.0, c)

    // base を n 回掛ける（n=0 は 1.0）。ShaderGen.powProduct と同じ左からの掛け順。
    def powProduct(base: Float64, n: Float64): Float64 =
        let k = Int32.max(0, Float64.tryToInt32(n) |> Option.getWithDefault(0));
        def times(i, acc) = if (i >= k) acc else times(i + 1, acc * base);
        if (k == 0) 1.0 else times(1, base)

    // ── ノイズの CPU 版（GLSL prelude と同じ構造・byte 一致は狙わない）──
    // 近傍 3x3 セルは (-1,-1) (0,-1) (1,-1) (-1,0) … の順（j が外・i が内）に回る。最小を取る順が
    // 変わると同じ距離のときに選ぶ方が変わりうるので、この順を変えない。

    def hash1(px: Float64, py: Float64, seed: Float64): Float64 =
        Num.fract(Vec2.sin(px * 127.1 + py * 311.7 + seed * 0.017) * 43758.5453123)

    def worleyF1F2(px: Float64, py: Float64, seed: Float64): (Float64, Float64) =
        let ipx = Float64.floor(px);
        let ipy = Float64.floor(py);
        let fpx = Num.fract(px);
        let fpy = Num.fract(py);
        // 近傍 3x3 セルを走査して最近 F1・次近 F2 を求める。
        def cell(k, f1, f2) =
            if (k >= 9) (f1, f2)
            else {
                let gx = Int32.toFloat64(Int32.remainder(k, 3) - 1);
                let gy = Int32.toFloat64(k / 3 - 1);
                let cx = ipx + gx;
                let cy = ipy + gy;
                let ox = hash1(cx, cy, seed);
                let oy = hash1(cx + 19.19, cy + 7.31, seed);
                let rx = (gx + ox) - fpx;
                let ry = (gy + oy) - fpy;
                let d = Vec2.sqrt(rx * rx + ry * ry);
                if (d < f1) cell(k + 1, d, f1)
                else if (d < f2) cell(k + 1, f1, d)
                else cell(k + 1, f1, f2)
            };
        cell(0, 8.0, 8.0)

    // 鱗（Scales）: セルの中心までの距離の最小（近傍 3x3・ずらし込み）。
    def scalesAt(px: Float64, py: Float64, stagger: Float64): Float64 =
        let ipx = Float64.floor(px);
        let ipy = Float64.floor(py);
        def cell(k, best) =
            if (k >= 9) best
            else {
                let i = Int32.remainder(k, 3) - 1;
                let j = k / 3 - 1;
                let cy = ipy + Int32.toFloat64(j);
                let stag = (cy - Float64.floor(cy / 2.0) * 2.0) * stagger;
                let centerX = ipx + Int32.toFloat64(i) + 0.5 + stag;
                let centerY = cy + 0.5;
                let dx = px - centerX;
                let dy = py - centerY;
                cell(k + 1, Float64.min(best, Vec2.sqrt(dx * dx + dy * dy)))
            };
        Num.clamp01(cell(0, 8.0))

    def sparkleAt(px: Float64, py: Float64, t: Float64, rate: Float64, density: Float64, sd: Float64): Float64 =
        let ipx = Float64.floor(px);
        let ipy = Float64.floor(py);
        let fpx = Num.fract(px);
        let fpy = Num.fract(py);
        let tt = t * rate + hash1(ipx, ipy, sd + 3.0) * 6.2831853;
        let cyc = Float64.floor(tt / 6.2831853);
        let icx = ipx + cyc;
        let icy = ipy + cyc;
        let on = if (hash1(icx, icy, sd) >= 1.0 - density) 1.0 else 0.0;
        let s = Float64.max(0.0, Vec2.sin(tt));
        let s4 = (s * s) * (s * s);
        let tw = (s4 * s4) * s4;
        let hx = hash1(icx, icy, sd + 11.0);
        let hy = hash1(icx + 19.19, icy + 7.31, sd + 11.0);
        let posX = 0.15 + 0.7 * hx;
        let posY = 0.15 + 0.7 * hy;
        let d = Float64.abs(fpx - posX) + Float64.abs(fpy - posY);
        let point = 1.0 - smoothstep(0.04, 0.26, d);
        on * tw * point

    def valueNoise(px: Float64, py: Float64, seed: Float64): Float64 =
        let ipx = Float64.floor(px);
        let ipy = Float64.floor(py);
        let fx = Num.fract(px);
        let fy = Num.fract(py);
        let wx = fx * fx * (3.0 - 2.0 * fx);
        let wy = fy * fy * (3.0 - 2.0 * fy);
        // `+ 0.0` は消さない（-0.0 を +0.0 に変える足し算で、元の Vec2.add と同じ値にする）。
        let a = hash1(ipx, ipy, seed);
        let b = hash1(ipx + 1.0, ipy + 0.0, seed);
        let c = hash1(ipx + 0.0, ipy + 1.0, seed);
        let d = hash1(ipx + 1.0, ipy + 1.0, seed);
        Num.lerp(Num.lerp(a, b, wx), Num.lerp(c, d, wx), wy)

    // オクターブを 0 から順に足す（画素ごとに呼ばれるので、リストを作らずに回す）。
    def fbm(px: Float64, py: Float64, octaves: Int32, seed: Float64): Float64 =
        def octave(i, sum, amp, freq) =
            if (i >= octaves) sum
            else octave(i + 1, sum + amp * valueNoise(px * freq, py * freq, seed + Int32.toFloat64(i) * 13.0),
                        amp * 0.5, freq * 2.0);
        octave(0, 0.0, 0.5, 1.0)

    // GLSL の mod と同じ折り返し（結果の符号は m 側・fract と違い任意周期）。
    def gmod(x: Float64, m: Float64): Float64 = x - m * Float64.floor(x / m)

    // 格子点を period で折り返す value noise（GLSL prelude の sg_valueNoiseTile と同じ構造）。
    def valueNoiseTile(px: Float64, py: Float64, periodX: Float64, periodY: Float64, seed: Float64): Float64 =
        let ipx = Float64.floor(px);
        let ipy = Float64.floor(py);
        let fx = Num.fract(px);
        let fy = Num.fract(py);
        let wx = fx * fx * (3.0 - 2.0 * fx);
        let wy = fy * fy * (3.0 - 2.0 * fy);
        let a = hash1(gmod(ipx + 0.0, periodX), gmod(ipy + 0.0, periodY), seed);
        let b = hash1(gmod(ipx + 1.0, periodX), gmod(ipy + 0.0, periodY), seed);
        let c = hash1(gmod(ipx + 0.0, periodX), gmod(ipy + 1.0, periodY), seed);
        let d = hash1(gmod(ipx + 1.0, periodX), gmod(ipy + 1.0, periodY), seed);
        Num.lerp(Num.lerp(a, b, wx), Num.lerp(c, d, wx), wy)

    // 周期つき fbm。オクターブごとに period も freq 倍する（sg_fbmTile と同じ構造）。
    def fbmTile(px: Float64, py: Float64, periodX: Float64, periodY: Float64, octaves: Int32, seed: Float64): Float64 =
        def octave(i, sum, amp, freq) =
            if (i >= octaves) sum
            else octave(i + 1, sum + amp * valueNoiseTile(px * freq, py * freq, periodX * freq, periodY * freq,
                                                          seed + Int32.toFloat64(i) * 13.0),
                        amp * 0.5, freq * 2.0);
        octave(0, 0.0, 0.5, 1.0)

    // ── 小道具 ──

    /// 0..1 を三角波（0→1→0）に折り返す（GLSL の abs(fract(x)*2-1) と同じ）。
    def triWave(x: Float64): Float64 = Float64.abs(Num.fract(x) * 2.0 - 1.0)

    def smoothstep(lo: Float64, hi: Float64, x: Float64): Float64 =
        if (hi - lo == 0.0) (if (x < lo) 0.0 else 1.0)
        else {
            let tt = Num.clamp01((x - lo) / (hi - lo));
            tt * tt * (3.0 - 2.0 * tt)
        }

    /// 2 色を t で混ぜる。混ぜる計算は Float32 で（GL と同じ丸めの回数）。
    def mixColor(a: (Float64, Float64, Float64), b: (Float64, Float64, Float64), t: Float64): (Float64, Float64, Float64) =
        let tf = unitF32(t);
        let (ar, ag, ab) = a;
        let (br, bg, bb) = b;
        (mixChannel(ar, br, tf), mixChannel(ag, bg, tf), mixChannel(ab, bb, tf))

    def mixChannel(a: Float64, b: Float64, tf: Float32): Float64 =
        let f32 = RenderUtil.f32;
        Float32.toFloat64(f32(a) + (f32(b) - f32(a)) * tf)
}
