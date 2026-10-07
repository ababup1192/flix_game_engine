// ShaderEval — Spec 木を CPU（Float64）で評価する検証用の純関数。描画経路ではない。
// テスト（代表点 (u,v,t) の値を釘打ち）と、将来のプレビューのために使う。
// GPU と byte 一致させる義務はない（Hash は近似で可）が、式の構造は ShaderGen と同じにして
// 「数式の正気」を確かめる（網目が目地で立つ・スクロールで動く・パレットが回る、など）。

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

    /// 色とアルファを一度に返す版。bindings の先行評価（画素ごとに 1 回）を色と α で共有する —
    /// 画素ループが色と α を別々に呼ぶと bindings を 2 回払うことになるため、生成する側はこれを使う。
    pub def evalPixelAlphaTex(spec: ShaderDoc.Spec, uv: Vec2.Vec2, t: Float64,
                              texEnv: Map[String, TexData]): (Color, Float64) =
        let env = envOf(spec#bindings, uv, t, texEnv);
        match spec#out {
            case ShaderDoc.Out.Fill(f) =>
                (evalShade(spec#cycleRate, f#shade, uv, t, env, texEnv),
                 evalFieldEnv(f#alpha, uv, t, env, texEnv))
        }

    /// bindings（前から順）を「面の基準 uv で 1 回評価した値」の env にまとめる。前の binding の値だけが
    /// 後の binding から Ref できる（GL が main 先頭に sg_b_ 宣言を並べるのと同じ意味論）。
    /// out から参照されない binding もここで必ず評価する — 使わない shared は合法だが、その分は
    /// 黙って画素ごとの計算に乗る。
    def envOf(bindings: List[(String, ShaderDoc.Field)], uv: Vec2.Vec2, t: Float64,
              texEnv: Map[String, TexData]): Map[String, Float64] =
        List.foldLeft((env, nf) -> {
            let (name, field) = nf;
            Map.insert(name, evalFieldEnv(field, uv, t, env, texEnv), env)
        }, Map.empty(), bindings)

    def evalShade(cycleRate: Float64, shade: ShaderDoc.Shade, uv: Vec2.Vec2, t: Float64,
                  env: Map[String, Float64], texEnv: Map[String, TexData]): Color =
        match shade {
            case ShaderDoc.Shade.Solid(c) => c
            case ShaderDoc.Shade.Ramp(r)  =>
                // cycleRate = 0 は素直な補間。cycleRate>0 だけ三角波で往復（パレット循環）。
                let field = evalFieldEnv(r#field, uv, t, env, texEnv);
                let phase = if (cycleRate == 0.0) Num.clamp01(field)
                            else Num.clamp01(triWave(field + cycleRate * t));
                mixColor(r#lo, r#hi, phase)
            case ShaderDoc.Shade.Gradient(g) =>
                // GLSL と同じ数式でなぞる: 係数 f を Ramp と同じ規約で作り、
                // 先頭色から隣の区切りごとに smoothstep 重みで次の色へ近づける。
                let field = evalFieldEnv(g#field, uv, t, env, texEnv);
                let f = if (cycleRate == 0.0) Num.clamp01(field)
                        else Num.clamp01(triWave(field + cycleRate * t));
                gradientColor(f, g#stops)
            case ShaderDoc.Shade.Cosine(cs) =>
                let field = evalFieldEnv(cs#field, uv, t, env, texEnv);
                let tt = if (cycleRate == 0.0) field else field + cycleRate * t;
                cosColor(cs#a, cs#b, cs#c, cs#d, tt)
            case ShaderDoc.Shade.Rgb(c) =>
                // cycleRate は読まない（Shade.Rgb の doc の決まり）。
                { r = colorF32(evalFieldEnv(c#r, uv, t, env, texEnv)),
                  g = colorF32(evalFieldEnv(c#g, uv, t, env, texEnv)),
                  b = colorF32(evalFieldEnv(c#b, uv, t, env, texEnv)) }
        }

    /// コサインパレット col = a + b·cos(2π(c·t + d)) を各チャンネルで（ShaderGen の sg_cospal と同じ数式）。
    def cosColor(pa: Color, pb: Color, pc: Color, pd: Color, t: Float64): Color =
        let ch = (av, bv, cv, dv) ->
            colorF32(av + bv * Vec2.cos(6.2831853 * (cv * t + dv)));
        { r = ch(colorF64(pa#r), colorF64(pb#r), colorF64(pc#r), colorF64(pd#r)),
          g = ch(colorF64(pa#g), colorF64(pb#g), colorF64(pc#g), colorF64(pd#g)),
          b = ch(colorF64(pa#b), colorF64(pb#b), colorF64(pc#b), colorF64(pd#b)) }

    def colorF64(x: Float64): Float64 = Float32.toFloat64(RenderUtil.f32(x))
    def colorF32(x: Float64): Float64 = Float32.toFloat64(Float64.clampToFloat32(min = 0.0f32, max = 1.0f32, x))

    /// 係数 f（0..1）で stops を混ぜた色。ShaderGen の gradientExpr と同じ入れ子 mix を辿る。
    def gradientColor(f: Float64, stops: List[(Float64, Color)]): Color =
        match stops {
            case Nil => { r = 0.0, g = 0.0, b = 0.0 }
            case (_, c0) :: rest =>
                let (col, _) = List.foldLeft((acc, sc) -> {
                    let (curCol, prevPos) = acc;
                    let (pos, col) = sc;
                    let w = smoothstep(prevPos, pos, f);
                    (mixColor(curCol, col, w), pos)
                }, (c0, gradientFirstPos(stops)), rest);
                col
        }

    def gradientFirstPos(stops: List[(Float64, Color)]): Float64 =
        match stops {
            case (p, _) :: _ => p
            case Nil         => 0.0
        }

    /// 場を Float64 へ。uv は「今読むべき座標」（Scaled/Warp が差し替える）。
    /// public はシグネチャ不変（呼び元を割らない）で、内部の env 版に空 env で委譲する。
    pub def evalField(field: ShaderDoc.Field, uv: Vec2.Vec2, t: Float64): Float64 =
        evalFieldEnv(field, uv, t, Map.empty(), Map.empty())

    /// env（先行評価済みの shared 値）付きの場評価。Ref は env の値を引くだけ・Tex は texEnv を
    /// 標本する。他 case は受けて再帰へ渡すだけ。
    def evalFieldEnv(field: ShaderDoc.Field, uv: Vec2.Vec2, t: Float64,
                     env: Map[String, Float64], texEnv: Map[String, TexData]): Float64 =
        match field {
            case ShaderDoc.Field.Const(v) => v
            case ShaderDoc.Field.Uv(u)    =>
                match u#axis {
                    case ShaderDoc.Axis.U => uv#x
                    case ShaderDoc.Axis.V => uv#y
                }
            case ShaderDoc.Field.Worley(w) =>
                let (f1, f2) = worleyF1F2(Vec2.mul(uv, w#scale), Int32.toFloat64(w#seed));
                match w#out {
                    case ShaderDoc.WorleyOut.F1    => f1
                    case ShaderDoc.WorleyOut.F2    => f2
                    case ShaderDoc.WorleyOut.F2mF1 => f2 - f1
                }
            case ShaderDoc.Field.Fbm(b) =>
                fbm(Vec2.mul(uv, b#scale), b#octaves, Int32.toFloat64(b#seed))
            case ShaderDoc.Field.FbmTile(b) =>
                fbmTile(Vec2.mul(uv, b#scale), b#period, b#octaves, Int32.toFloat64(b#seed))
            case ShaderDoc.Field.Smoothstep(s) =>
                smoothstep(s#lo, s#hi, evalFieldEnv(s#of, uv, t, env, texEnv))
            case ShaderDoc.Field.Scaled(s) =>
                let uv2 = Vec2.add(Vec2.mul(uv, s#factor), Vec2.mul(s#scroll, t));
                evalFieldEnv(s#of, uv2, t, env, texEnv)
            case ShaderDoc.Field.Warp(wp) =>
                let ox = fbm(Vec2.mul(uv, wp#scale), 3, Int32.toFloat64(wp#seed)) - 0.5;
                let oy = fbm(Vec2.mul(uv, wp#scale), 3, Int32.toFloat64(wp#seed) + 91.0) - 0.5;
                let uv2 = Vec2.add(uv, Vec2.mul({ x = ox, y = oy }, wp#amount));
                evalFieldEnv(wp#of, uv2, t, env, texEnv)
            case ShaderDoc.Field.Swirl(sw) =>
                let c = { x = sw#cx, y = sw#cy };
                let p = Vec2.sub(uv, c);
                let r = Vec2.length(p);
                let a = sw#strength / (r + 0.08) + sw#rate * t;
                let co = Vec2.cos(a);
                let s = Vec2.sin(a);
                let uv2 = { x = c#x + p#x * co - p#y * s, y = c#y + p#x * s + p#y * co };
                evalFieldEnv(sw#of, uv2, t, env, texEnv)
            case ShaderDoc.Field.Angle(an) =>
                Vec2.atan2(uv#y - an#cy, uv#x - an#cx) * 0.15915494 + 0.5
            case ShaderDoc.Field.Rotate(rt) =>
                let c = { x = rt#cx, y = rt#cy };
                let p = Vec2.sub(uv, c);
                let a = 6.2831853 * (rt#turns + rt#rate * t);
                let co = Vec2.cos(a);
                let s = Vec2.sin(a);
                let uv2 = { x = c#x + p#x * co - p#y * s, y = c#y + p#x * s + p#y * co };
                evalFieldEnv(rt#of, uv2, t, env, texEnv)
            case ShaderDoc.Field.Mix(m) =>
                Num.lerp(evalFieldEnv(m#a, uv, t, env, texEnv), evalFieldEnv(m#b, uv, t, env, texEnv), m#t)
            case ShaderDoc.Field.Blend(bl) =>
                Num.lerp(evalFieldEnv(bl#a, uv, t, env, texEnv), evalFieldEnv(bl#b, uv, t, env, texEnv),
                         Num.clamp01(evalFieldEnv(bl#by, uv, t, env, texEnv)))
            case ShaderDoc.Field.Disk(d) =>
                let dist = Vec2.length(Vec2.sub(uv, { x = d#cx, y = d#cy }));
                1.0 - smoothstep(d#radius, d#radius + d#feather, dist)
            case ShaderDoc.Field.Radial(rd) =>
                Vec2.length(Vec2.sub(uv, { x = rd#cx, y = rd#cy }))
            case ShaderDoc.Field.RadialAspect(ra) =>
                Vec2.length({ x = (uv#x - ra#cx) * ra#aspect, y = uv#y - ra#cy })
            case ShaderDoc.Field.Quantize(q) =>
                let n = Int32.toFloat64(Int32.max(1, q#steps));
                Float64.floor(evalFieldEnv(q#of, uv, t, env, texEnv) * n) / n
            case ShaderDoc.Field.Scales(sc) =>
                let p = Vec2.mul(uv, sc#scale);
                let ip = { x = Float64.floor(p#x), y = Float64.floor(p#y) };
                let best = List.foldLeft((acc, cell) -> {
                    let (i, j) = cell;
                    let cy = ip#y + Int32.toFloat64(j);
                    let stag = (cy - Float64.floor(cy / 2.0) * 2.0) * sc#stagger;
                    let center = { x = ip#x + Int32.toFloat64(i) + 0.5 + stag, y = cy + 0.5 };
                    Float64.min(acc, Vec2.length(Vec2.sub(p, center)))
                }, 8.0, neighborCells());
                Num.clamp01(best)
            case ShaderDoc.Field.Glints(g) =>
                let p = Vec2.mul(uv, g#scale);
                let ip = { x = Float64.floor(p#x), y = Float64.floor(p#y) };
                let fpx = Num.fract(p#x);
                let fpy = Num.fract(p#y);
                let sd = Int32.toFloat64(g#seed);
                let on = if (hash1(ip, sd) >= 1.0 - g#density) 1.0 else 0.0;
                let phase = hash1(ip, sd + 7.0) * 6.2831853;
                let tw = Float64.max(0.0, Vec2.sin(t * g#rate + phase));
                let dash = (1.0 - smoothstep(0.04, 0.10, Float64.abs(fpy - 0.5))) *
                           (1.0 - smoothstep(0.28, 0.46, Float64.abs(fpx - 0.5)));
                on * tw * dash
            case ShaderDoc.Field.Ripples(rp) =>
                let sd = Int32.toFloat64(rp#seed);
                let wob = Vec2.sin(uv#x * 6.2831853 * rp#freq * 0.5 + sd) * rp#amp
                        + Vec2.sin(uv#x * 6.2831853 * rp#freq * 1.3 + sd * 2.7) * rp#amp * 0.4;
                let band = uv#y * rp#freq + wob + t * rp#speed;
                0.5 + 0.5 * Vec2.sin(band * 6.2831853)
            case ShaderDoc.Field.Sparkle(sp) =>
                let p = Vec2.mul(uv, sp#scale);
                let ip = { x = Float64.floor(p#x), y = Float64.floor(p#y) };
                let fp = { x = Num.fract(p#x), y = Num.fract(p#y) };
                let sd = Int32.toFloat64(sp#seed);
                let tt = t * sp#rate + hash1(ip, sd + 3.0) * 6.2831853;
                let cyc = Float64.floor(tt / 6.2831853);
                let ipc = Vec2.add(ip, { x = cyc, y = cyc });
                let on = if (hash1(ipc, sd) >= 1.0 - sp#density) 1.0 else 0.0;
                let s = Float64.max(0.0, Vec2.sin(tt));
                let s4 = (s * s) * (s * s);
                let tw = (s4 * s4) * s4;
                let h = hash2(ipc, sd + 11.0);
                let pos = { x = 0.15 + 0.7 * h#x, y = 0.15 + 0.7 * h#y };
                let d = Float64.abs(fp#x - pos#x) + Float64.abs(fp#y - pos#y);
                let point = 1.0 - smoothstep(0.04, 0.26, d);
                on * tw * point
            case ShaderDoc.Field.Bin(bn) =>
                let a = evalFieldEnv(bn#a, uv, t, env, texEnv);
                let b = evalFieldEnv(bn#b, uv, t, env, texEnv);
                match bn#op {
                    case ShaderDoc.BinOp.Add  => a + b
                    case ShaderDoc.BinOp.Sub  => a - b
                    case ShaderDoc.BinOp.Mul  => a * b
                    case ShaderDoc.BinOp.Min  => Float64.min(a, b)
                    case ShaderDoc.BinOp.Max  => Float64.max(a, b)
                    case ShaderDoc.BinOp.Step => if (b >= a) 1.0 else 0.0
                }
            case ShaderDoc.Field.Hash1(h) =>
                hash1(hashCoord(h#scale, h#bucket, uv, t, env, texEnv), Int32.toFloat64(h#seed))
            case ShaderDoc.Field.Hash2(h) =>
                let v = hash2(hashCoord(h#scale, h#bucket, uv, t, env, texEnv), Int32.toFloat64(h#seed));
                match h#comp {
                    case ShaderDoc.Axis.U => v#x
                    case ShaderDoc.Axis.V => v#y
                }
            case ShaderDoc.Field.Un(un) =>
                let x = evalFieldEnv(un#of, uv, t, env, texEnv);
                match un#op {
                    case ShaderDoc.UnOp.Neg      => -x
                    case ShaderDoc.UnOp.Abs      => Float64.abs(x)
                    case ShaderDoc.UnOp.Fract    => Num.fract(x)
                    case ShaderDoc.UnOp.Floor    => Float64.floor(x)
                    case ShaderDoc.UnOp.Sin      => Vec2.sin(x)
                    case ShaderDoc.UnOp.Cos      => Vec2.cos(x)
                    case ShaderDoc.UnOp.Sat      => Num.clamp01(x)
                    case ShaderDoc.UnOp.OneMinus => 1.0 - x
                }
            case ShaderDoc.Field.Pow(pw) =>
                powf(evalFieldEnv(pw#of, uv, t, env, texEnv), pw#p)
            case ShaderDoc.Field.Time(tm) =>
                t * tm#scale + evalFieldEnv(tm#offset, uv, t, env, texEnv)
            case ShaderDoc.Field.Tiling(tl) =>
                // 各マス内は fract(uv*tiles)。of をこの座標で読む（GLSL の差し替えと同じ形）。
                let uv2 = { x = Num.fract(uv#x * tl#tiles#x), y = Num.fract(uv#y * tl#tiles#y) };
                evalFieldEnv(tl#of, uv2, t, env, texEnv)
            case ShaderDoc.Field.Snap(sn) =>
                // GLSL の (floor(uv*cells)+0.5)/cells と同じ形（描き出しと実機で塊の位置を割らない）。
                let cx = snapCells(sn#cells#x);
                let cy = snapCells(sn#cells#y);
                let uv2 = { x = (Float64.floor(uv#x * cx) + 0.5) / cx,
                            y = (Float64.floor(uv#y * cy) + 0.5) / cy };
                evalFieldEnv(sn#of, uv2, t, env, texEnv)
            case ShaderDoc.Field.Ref(name) =>
                // parse が定義済みを保証する。未定義は 0.0（保険）。値は基準 uv での先行評価済み —
                // 座標変換の内側でも読み直さない（GL の sg_b_ 変数と同じ意味論）。
                match Map.get(name, env) {
                    case Some(v) => v
                    case None    => 0.0
                }
            case ShaderDoc.Field.Tex(tx) =>
                // 無い名前は 0.0（黒）。警告は IO を持つ生成側（SoftRaster）が出す — ここは純関数。
                match Map.get(tx#name, texEnv) {
                    case Some(td) => sampleTex(td, tx#chan, uv)
                    case None     => 0.0
                }
            case ShaderDoc.Field.Shift(sh) =>
                // dx/dy は外側 uv で評価してから、of をずらした座標で読む（GLSL の式と同じ組み方）。
                let dx = evalFieldEnv(sh#dx, uv, t, env, texEnv);
                let dy = evalFieldEnv(sh#dy, uv, t, env, texEnv);
                evalFieldEnv(sh#of, { x = uv#x + dx, y = uv#y + dy }, t, env, texEnv)
        }

    /// テクスチャ標本（NEAREST + CLAMP の釘打ち式 — GL と同じ量子化になるのが backend-parity の契約）。
    /// ix = clamp(floor(u*w), 0, w−1)・iy 同様。チャンネル値は 8bit を 255 で割った 0..1。
    def sampleTex(td: TexData, chan: ShaderDoc.TexChan, uv: Vec2.Vec2): Float64 =
        if (td#width <= 0 or td#height <= 0) 0.0
        else {
            let ix = clampTexel(Float64.floor(uv#x * Int32.toFloat64(td#width)), td#width);
            let iy = clampTexel(Float64.floor(uv#y * Int32.toFloat64(td#height)), td#height);
            let argb = Vector.get(iy * td#width + ix, td#pixels);
            let shift = match chan {
                case ShaderDoc.TexChan.A => 24
                case ShaderDoc.TexChan.R => 16
                case ShaderDoc.TexChan.G => 8
                case ShaderDoc.TexChan.B => 0
            };
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
        if (k == 0) 1.0
        else List.foldLeft((acc, _) -> acc * base, base, List.range(1, k))

    // ── ノイズの CPU 版（GLSL prelude と同じ構造・byte 一致は狙わない）──

    // hash に渡すセル座標。floor(uv*scale) に、bucket が有ればその値を両成分へ足す（GLSL の
    // vec2+float 自動配りと同じ）。GLSL の hashCoord と同じ形。
    def hashCoord(scale: Float64, bucket: Option[ShaderDoc.Field], uv: Vec2.Vec2, t: Float64,
                  env: Map[String, Float64], texEnv: Map[String, TexData]): Vec2.Vec2 =
        let ip = { x = Float64.floor(uv#x * scale), y = Float64.floor(uv#y * scale) };
        match bucket {
            case None    => ip
            case Some(b) => let bv = evalFieldEnv(b, uv, t, env, texEnv); Vec2.add(ip, { x = bv, y = bv })
        }

    def hash1(p: Vec2.Vec2, seed: Float64): Float64 =
        Num.fract(Vec2.sin(p#x * 127.1 + p#y * 311.7 + seed * 0.017) * 43758.5453123)

    def hash2(p: Vec2.Vec2, seed: Float64): Vec2.Vec2 =
        { x = hash1(p, seed), y = hash1(Vec2.add(p, { x = 19.19, y = 7.31 }), seed) }

    def worleyF1F2(p: Vec2.Vec2, seed: Float64): (Float64, Float64) =
        let ip = { x = Float64.floor(p#x), y = Float64.floor(p#y) };
        let fp = { x = Num.fract(p#x), y = Num.fract(p#y) };
        // 近傍 3x3 セルを走査して最近 F1・次近 F2 を求める。
        List.foldLeft((acc, cell) -> {
            let (f1, f2) = acc;
            let (i, j) = cell;
            let g = { x = Int32.toFloat64(i), y = Int32.toFloat64(j) };
            let o = hash2(Vec2.add(ip, g), seed);
            let r = Vec2.sub(Vec2.add(g, o), fp);
            let d = Vec2.length(r);
            if (d < f1) (d, f1)
            else if (d < f2) (f1, d)
            else (f1, f2)
        }, (8.0, 8.0), neighborCells())

    def neighborCells(): List[(Int32, Int32)] =
        (-1, -1) :: (0, -1) :: (1, -1) ::
        (-1,  0) :: (0,  0) :: (1,  0) ::
        (-1,  1) :: (0,  1) :: (1,  1) :: Nil

    def valueNoise(p: Vec2.Vec2, seed: Float64): Float64 =
        let ip = { x = Float64.floor(p#x), y = Float64.floor(p#y) };
        let fx = Num.fract(p#x);
        let fy = Num.fract(p#y);
        let wx = fx * fx * (3.0 - 2.0 * fx);
        let wy = fy * fy * (3.0 - 2.0 * fy);
        let a = hash1(ip, seed);
        let b = hash1(Vec2.add(ip, { x = 1.0, y = 0.0 }), seed);
        let c = hash1(Vec2.add(ip, { x = 0.0, y = 1.0 }), seed);
        let d = hash1(Vec2.add(ip, { x = 1.0, y = 1.0 }), seed);
        Num.lerp(Num.lerp(a, b, wx), Num.lerp(c, d, wx), wy)

    def fbm(p: Vec2.Vec2, octaves: Int32, seed: Float64): Float64 =
        List.foldLeft((acc, i) -> {
            let (sum, amp, freq) = acc;
            let s = sum + amp * valueNoise(Vec2.mul(p, freq), seed + Int32.toFloat64(i) * 13.0);
            (s, amp * 0.5, freq * 2.0)
        }, (0.0, 0.5, 1.0), List.range(0, Int32.max(0, octaves))) |> fst3

    // GLSL の mod と同じ折り返し（結果の符号は m 側・fract と違い任意周期）。
    def gmod(x: Float64, m: Float64): Float64 = x - m * Float64.floor(x / m)

    // 格子点を period で折り返す value noise（GLSL prelude の sg_valueNoiseTile と同じ構造）。
    def valueNoiseTile(p: Vec2.Vec2, period: Vec2.Vec2, seed: Float64): Float64 =
        let ip = { x = Float64.floor(p#x), y = Float64.floor(p#y) };
        let fx = Num.fract(p#x);
        let fy = Num.fract(p#y);
        let wx = fx * fx * (3.0 - 2.0 * fx);
        let wy = fy * fy * (3.0 - 2.0 * fy);
        let wrap = (dx, dy) ->
            ({ x = gmod(ip#x + dx, period#x), y = gmod(ip#y + dy, period#y) }: Vec2.Vec2);
        let a = hash1(wrap(0.0, 0.0), seed);
        let b = hash1(wrap(1.0, 0.0), seed);
        let c = hash1(wrap(0.0, 1.0), seed);
        let d = hash1(wrap(1.0, 1.0), seed);
        Num.lerp(Num.lerp(a, b, wx), Num.lerp(c, d, wx), wy)

    // 周期つき fbm。オクターブごとに period も freq 倍する（sg_fbmTile と同じ構造）。
    def fbmTile(p: Vec2.Vec2, period: Vec2.Vec2, octaves: Int32, seed: Float64): Float64 =
        List.foldLeft((acc, i) -> {
            let (sum, amp, freq) = acc;
            let s = sum + amp * valueNoiseTile(Vec2.mul(p, freq), Vec2.mul(period, freq),
                                               seed + Int32.toFloat64(i) * 13.0);
            (s, amp * 0.5, freq * 2.0)
        }, (0.0, 0.5, 1.0), List.range(0, Int32.max(0, octaves))) |> fst3

    // ── 小道具 ──

    def fst3(t: (Float64, Float64, Float64)): Float64 = let (a, _, _) = t; a

    /// 0..1 を三角波（0→1→0）に折り返す（GLSL の abs(fract(x)*2-1) と同じ）。
    def triWave(x: Float64): Float64 = Float64.abs(Num.fract(x) * 2.0 - 1.0)

    def smoothstep(lo: Float64, hi: Float64, x: Float64): Float64 =
        if (hi - lo == 0.0) (if (x < lo) 0.0 else 1.0)
        else {
            let tt = Num.clamp01((x - lo) / (hi - lo));
            tt * tt * (3.0 - 2.0 * tt)
        }

    def mixColor(a: Color, b: Color, t: Float64): Color =
        let tf = Float64.clampToFloat32(min = 0.0f32, max = 1.0f32, t);
        let f32 = RenderUtil.f32;
        let wide = Float32.toFloat64;
        { r = wide(f32(a#r) + (f32(b#r) - f32(a#r)) * tf),
          g = wide(f32(a#g) + (f32(b#g) - f32(a#g)) * tf),
          b = wide(f32(a#b) + (f32(b#b) - f32(a#b)) * tf) }
}
