// ShaderEval — Spec 木を CPU（Float64）で評価する純関数。GL の描画経路ではないが、
// SoftRaster（描き出し・動画・スナップショット）はシェーダー面の画素をこれで塗る。
// テスト（代表点 (u,v,t) の値を釘打ち）にも使う。何万画素も評価する側は compile で
// 面ごとに 1 回だけ組み直してから evalCompiled を画素ごとに呼ぶ。
// GPU と byte 一致させる義務はない（Hash は近似で可）が、式の構造は ShaderGen と同じにして
// 「数式の正気」を確かめる（網目が目地で立つ・スクロールで動く・パレットが回る、など）。
//
// 読む順: 公開の入口（evalPixel …）→ compile（Spec → Node の木）→ evalNode（画素 1 つ）→ ノイズ。

pub mod ShaderEval {

    import java.lang.{Float => JFloat}

    /// テクスチャ 1 枚ぶんの画素（ARGB・正立・行優先）。Tex ノードが CPU 側で標本する素材。
    /// GL の pass ターゲットは上下逆格納だが描き出しの pass 画像は正立なので、CPU 側は反転しない
    /// （反転の吸収は GL の uTexFlip だけが持つ既存の非対称と同型）。
    pub type alias TexData = { width = Int32, height = Int32, pixels = Vector[Int32] }

    /// 1 を超える値を持てる画素（Rgba16Float の Pass を CPU で読む形。1 画素に r, g, b, α の 4 つ・行優先・正立）。
    /// 値は half の精度に丸めた物。外から作らせない（hdrTextureOf だけが作る・読むのは hdrWidthOf / hdrHeightOf / hdrChannelOf）。
    enum HdrTextureData {
        case HdrTextureData(Int32, Int32, Vector[Float32])
    }

    /// Rgba16Float の Pass の画素（wgpu の TextureFormat::Rgba16Float の絵を CPU で持つ形）。
    pub type alias HdrTexture = HdrTextureData

    /// x を half（16bit の浮動小数）の精度に丸めた値（GPU の Rgba16Float の描き先が書く値。65504 を超えると無限大）。
    pub def roundToHalf(x: Float64): Float64 =
        Float32.toFloat64(JFloat.float16ToFloat(JFloat.floatToFloat16(RenderUtil.f32(x))))

    /// width × height の画素（rgba = 1 画素に r, g, b, α の 4 つ・行優先）を half に丸めて凍らせる。足りない分は 0。
    pub def hdrTextureOf(width: Int32, height: Int32, rgba: Vector[Float64]): HdrTexture =
        let w = Int32.max(1, width);
        let h = Int32.max(1, height);
        let n = w * h * 4;
        let values = if (Vector.length(rgba) >= n) Vector.take(n, rgba) else Vector.append(rgba, Vector.repeat(n - Vector.length(rgba), 0.0));
        HdrTextureData.HdrTextureData(w, h, Vector.map(x -> RenderUtil.f32(roundToHalf(x)), values))

    /// 幅（テクセルの数）。
    pub def hdrWidthOf(tex: HdrTexture): Int32 = let HdrTextureData.HdrTextureData(w, _, _) = tex; w

    /// 高さ（テクセルの数）。
    pub def hdrHeightOf(tex: HdrTexture): Int32 = let HdrTextureData.HdrTextureData(_, h, _) = tex; h

    /// index 番目の値（index = (y × 幅 + x) × 4 + 成分。成分は r = 0・g = 1・b = 2・α = 3）。外なら 0。
    pub def hdrChannelOf(tex: HdrTexture, index: Int32): Float64 =
        let HdrTextureData.HdrTextureData(_, _, values) = tex;
        if (index < 0 or index >= Vector.length(values)) 0.0 else Float32.toFloat64(Vector.get(index, values))

    /// 面の tex / blur の読み先の 1 枚（case の名前は RenderTarget.Format と同じ）。Rgba8Unorm = 8bit の絵（ファイル・Rgba8Unorm の Pass）・
    /// Rgba16Float = Rgba16Float の Pass（1 を超える値を切らずに読む。α だけ 0..1 に切る）。
    pub enum TexImage {
        case Rgba8Unorm(TexData)
        case Rgba16Float(HdrTexture)
    }

    /// 代表点 uv（0..1 目安）と時刻 t の最終色（Color の rgb。ここでは 0..1 に切らない — 1 を超える色の場や Rgba16Float の Pass を読む面は 1 を超え得る。切るのは書き込む側）。
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
        let (r, g, b, a) = evalCompiled(compile(spec, Map.map(TexImage.Rgba8Unorm, texEnv)), uv#x, uv#y, t);
        ({ r = r, g = g, b = b }, a)

    /// 場を Float64 へ（shared も tex も無い所で 1 点だけ）。
    pub def evalField(field: ShaderDoc.Field, uv: Vec2.Vec2, t: Float64): Float64 = region rc {
        let env: Array[Float64, rc] = Array.repeat(rc, inputSlots(), 0.0);
        let ids = Ref.fresh(rc, 0);
        evalNode(compileField(clampSampling(), ids, Map.empty(), Map.empty(), field), uv#x, uv#y, t, env)
    }

    // ── 組み直し（面ごとに 1 回）──

    /// compile が組み直した面 1 枚（外からは作らせない — compile で作る）。
    /// bindings は前から順の場（Ref は添字で読む）、shade は色、alpha は α の場、cycleRate、
    /// 画素ごとの値の置き場の大きさ、World / Normal / VertexColor の置き場を先頭に取るか（取るなら添字 0..8・bindings はその後ろ）、
    /// emission は 3D の材質の自分で光る色、段つきの絵を読む節（MipTex）の数。
    /// MipTex のある面は、値の置き場の後ろに lod を求めるための区画（節ごとに右隣と下隣の座標の 4 つ・最後に読み方の番号）を取る。
    enum Compiled {
        case Compiled(List[Node], CShade, Node, Float64, Int32, Bool, Option[CShade], Int32)
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
        case Tex(Int32, Int32, Vector[Int32], Int32, Bool, Bool)      // 幅, 高さ, 画素, チャンネルの shift, Linear で読むか, REPEAT か
        case MipTex(Int32, Vector[TexData], Int32, Bool, Bool)        // 節の番号, 段の列, チャンネルの shift, Linear で読むか, REPEAT か
        case Shift(Node, Node, Node)                                  // dx, dy, of
        case TexBlur(Int32, Int32, Vector[Int32], Int32, Float64, Float64, Int32, Node, Bool, Bool) // 幅, 高さ, 画素, shift, 半径 x/y, taps, amount, Linear, REPEAT
        case TexF(Int32, Int32, Vector[Float32], Int32, Bool, Bool)   // Tex の Rgba16Float 版（幅, 高さ, 値, 成分の位置, Linear, REPEAT）
        case TexBlurF(Int32, Int32, Vector[Float32], Int32, Float64, Float64, Int32, Node, Bool, Bool) // TexBlur の Rgba16Float 版
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
    pub def compile(spec: ShaderDoc.Spec, texEnv: Map[String, TexImage]): CompiledSpec =
        compileWith(spec, None, clampSampling(), texEnv)

    /// 3D の材質を組み直す材料。textures = tex / blur の読み先の絵の段の列（名前 → Mip.build の段。段 0 が元の絵。
    /// 段が 1 つなら lod を求めずに段 0 を読む。無い名前は 0）・repeat = 0..1 の外の uv を繰り返すか（偽なら端の色を伸ばす）。
    pub type alias MaterialInput = { spec = ShaderDoc.Spec, emission = Option[ShaderDoc.Shade], params = Map[String, Float64],
                                     textures = Map[String, Vector[TexData]], repeat = Bool }

    /// 3D の材質（Scene3d.Material3d の spec・emission・params）を組み直す。Param は params の値の Const に置き換える
    /// （ShaderDoc.bindParams）。evalCompiled3 / evalMaterial3 に画素ごとに渡す。
    pub def compileMaterial(input: MaterialInput): CompiledSpec =
        let mips = input#textures |> Map.filter(chain -> Vector.length(chain) > 1);
        let level0 = input#textures |> Map.filterMap(Vector.head);
        compileWith(ShaderDoc.bindParams(input#params, input#spec), Option.map(ShaderDoc.bindShadeParams(input#params), input#emission),
                    { linear = false, repeat = input#repeat, mips = mips }, Map.map(TexImage.Rgba8Unorm, level0))

    /// tex / blur の読み方。linear = Linear で読むか（Sampler の内側）・repeat = 0..1 の外の uv を繰り返すか（3D の材質の Wrap）・
    /// mips = 段の列を持つ絵（3D の材質だけ。tex はここにある名前なら lod を求めて段を読む）。
    type alias Sampling = { linear = Bool, repeat = Bool, mips = Map[String, Vector[TexData]] }

    /// 1 枚の読み方（Sampling から段の列を除いた物）。
    type alias Filter = { linear = Bool, repeat = Bool }

    def clampSampling(): Sampling = { linear = false, repeat = false, mips = Map.empty() }

    def compileWith(spec: ShaderDoc.Spec, emission: Option[ShaderDoc.Shade], sampling: Sampling, texEnv: Map[String, TexImage]): CompiledSpec = region rc {
        let ids = Ref.fresh(rc, 0);
        let withInputs = readsSurface(spec) or Option.exists(shade -> readsSurface(specOfShade(shade)), emission);
        let first = if (withInputs) inputSlots() else 0;
        let (revBindings, scope, next) = List.foldLeft((acc, nf) -> {
            let (nodes, sc, i) = acc;
            let (name, field) = nf;
            (compileField(sampling, ids, sc, texEnv, field) :: nodes, Map.insert(name, i, sc), i + 1)
        }, (Nil, Map.empty(), first), spec#bindings);
        match spec#out {
            case ShaderDoc.Out.Fill(f) =>
                let shade = compileShade(sampling, ids, scope, texEnv, f#shade);
                let alpha = compileField(sampling, ids, scope, texEnv, f#alpha);
                let glow = match emission {
                    case Some(e) => Some(compileShade(sampling, ids, scope, texEnv, e))
                    case None    => None
                };
                let mipCount = Ref.get(ids);
                let size = if (mipCount > 0) next + mipCount * 4 + 1 else next;
                Compiled.Compiled(List.reverse(revBindings), shade, alpha, spec#cycleRate, size, withInputs, glow, mipCount)
        }
    }

    /// Spec が World・Normal・VertexColor のどれかを読むか（読むなら置き場の先頭にその値を取る）。
    def readsSurface(spec: ShaderDoc.Spec): Bool =
        ShaderDoc.usesWorld3d(spec) or (ShaderDoc.fieldsOf(spec) |> List.exists(field -> ShaderDoc.foldField((found, f) -> match f {
            case ShaderDoc.Field.VertexColor(_) => true
            case _                              => found
        }, false, field)))

    /// 色だけを持つ Spec（色の場を Spec の走査に掛けるため）。
    def specOfShade(shade: ShaderDoc.Shade): ShaderDoc.Spec =
        { name = "", cycleRate = 0.0, bindings = Nil, out = ShaderDoc.Out.Fill({ shade = shade, alpha = ShaderDoc.Field.Const(1.0) }) }

    /// World（x, y, z）・Normal（x, y, z）・頂点の色（r, g, b）の置き場の数。値の置き場の先頭に取る。
    def inputSlots(): Int32 = 9

    /// World / Normal の axis の値の置き場の添字。
    def inputIndex(normal: Bool, axis: ShaderDoc.Axis3): Int32 =
        let base = if (normal) 3 else 0;
        match axis {
            case ShaderDoc.Axis3.X => base
            case ShaderDoc.Axis3.Y => base + 1
            case ShaderDoc.Axis3.Z => base + 2
        }

    /// 頂点の色の chan の値の場（R・G・B は置き場・A は 1）。
    def vertexColorNode(chan: ShaderDoc.TexChan): Node =
        match chan {
            case ShaderDoc.TexChan.R => Node.Ref(6)
            case ShaderDoc.TexChan.G => Node.Ref(7)
            case ShaderDoc.TexChan.B => Node.Ref(8)
            case ShaderDoc.TexChan.A => Node.Const(1.0)
        }

    /// 画素 1 つ（uv = (u, v)・時刻 t）の (r, g, b, α)。値は evalPixelAlphaTex と同じ。
    /// out から参照されない binding もここで必ず評価する — 使わない shared は合法だが、その分は
    /// 黙って画素ごとの計算に乗る。
    /// World / Normal は 0・VertexColor は 1（2D の面）。
    pub def evalCompiled(compiled: CompiledSpec, u: Float64, v: Float64, t: Float64): (Float64, Float64, Float64, Float64) =
        match compiled {
            case Compiled.Compiled(bindings, shade, alpha, cycleRate, size, withInputs, _, _) => region rc {
                let env: Array[Float64, rc] = Array.empty(rc, size);
                if (withInputs) putInputs(flatPoint(u, v), env) else ();
                fillEnv(bindings, if (withInputs) inputSlots() else 0, u, v, t, env);
                let (r, g, b) = evalShade(shade, cycleRate, u, v, t, env);
                (r, g, b, evalNode(alpha, u, v, t, env))
            }
        }

    /// 3D のメッシュの画素 1 つの入力。world = 画素の world の点・normal = 外向きの法線（長さは問わない）・
    /// uv = 絵の上の位置（uv の無い形は (0, 0)）・color = 頂点の色（置いた物の tint は入れない）。
    pub type alias SurfacePoint = { world = Vec3.Vec3, normal = Vec3.Vec3, uv = Vec2.Vec2, color = Color }

    /// 2D の面の画素の入力（World / Normal は 0・頂点の色は白）。
    def flatPoint(u: Float64, v: Float64): SurfacePoint =
        { world = Vec3.zero(), normal = Vec3.zero(), uv = { x = u, y = v }, color = { r = 1.0, g = 1.0, b = 1.0 } }

    /// 3D のメッシュの画素 1 つ（時刻 t）の (r, g, b, α)。色は光を当てる前の色（albedo）。
    /// 場は point の uv で読む（ShaderGen.compile3d の sg_uv = vUv と同じ）。法線は長さ 1 にそろえてから読む（長さ 0 なら 0 のまま）。
    pub def evalCompiled3(compiled: CompiledSpec, point: SurfacePoint, t: Float64): (Float64, Float64, Float64, Float64) =
        match compiled {
            case Compiled.Compiled(bindings, shade, alpha, cycleRate, size, withInputs, _, _) => region rc {
                let env = env3(bindings, size, withInputs, point, t, rc);
                let (u, v) = (point#uv#x, point#uv#y);
                let (r, g, b) = evalAlbedo(shade, cycleRate, u, v, t, env);
                (r, g, b, evalNode(alpha, u, v, t, env))
            }
        }

    /// 3D の材質の画素 1 つ: 光を当てる前の色（albedo）・α・自分で光る色（emission。無ければ黒）。
    pub type alias MaterialSample = { albedo = Color, alpha = Float64, emission = Color }

    /// evalCompiled3 に emission を足した版（bindings の評価を色・α・emission で共有する）。
    /// 光の計算は呼び手（SoftRaster3d）が albedo に掛け、その後に emission を足す。
    pub def evalMaterial3(compiled: CompiledSpec, point: SurfacePoint, t: Float64): MaterialSample =
        match compiled {
            case Compiled.Compiled(bindings, shade, alpha, cycleRate, size, withInputs, emission, _) => region rc {
                let env = env3(bindings, size, withInputs, point, t, rc);
                sampleMaterial(shade, alpha, emission, cycleRate, point, t, env)
            }
        }

    /// evalMaterial3 の、段つきの絵を lod で読む版。nextX・nextY = 右隣・下隣の画素の入力（隣が三角形の外でも、重みを外へ延ばした値）。
    /// 隣の入力では bindings（shared）から評価し直して、各 tex の節が読む座標を控え、真ん中の画素で座標の差から lod を求める（Mip.lodOf）。
    /// 隣の入力の評価では tex を段 0 で読む（座標の式の中にある入れ子の tex は、隣では lod を求めずに読む）。
    /// 段つきの絵を読まない材質は evalMaterial3 と同じ（隣を評価しない）。
    // WhyNot: 真ん中の bindings の値を隣の評価に使い回さない — atWorld を shared に書く形では座標が bindings で決まり、差が 0 になって段 0 に落ちる。
    pub def evalMaterial3Mip(compiled: CompiledSpec, center: SurfacePoint, nextX: SurfacePoint, nextY: SurfacePoint, t: Float64): MaterialSample =
        match compiled {
            case Compiled.Compiled(bindings, shade, alpha, cycleRate, size, withInputs, emission, mipCount) => region rc {
                let env: Array[Float64, rc] = Array.repeat(rc, size, 0.0);
                let pass = (point: SurfacePoint, mode: Float64) -> {
                    if (mipCount > 0) Array.put(mode, size - 1, env) else ();
                    if (withInputs) putInputs(point, env) else ();
                    fillEnv(bindings, if (withInputs) inputSlots() else 0, point#uv#x, point#uv#y, t, env);
                    sampleMaterial(shade, alpha, emission, cycleRate, point, t, env)
                };
                if (mipCount == 0) pass(center, modeLevel0())
                else {
                    discard pass(nextX, modeRecordX());
                    discard pass(nextY, modeRecordY());
                    pass(center, modeLod())
                }
            }
        }

    def sampleMaterial(shade: CShade, alpha: Node, emission: Option[CShade], cycleRate: Float64, point: SurfacePoint, t: Float64,
                       env: Array[Float64, r]): MaterialSample \ r =
        let (u, v) = (point#uv#x, point#uv#y);
        let (cr, cg, cb) = evalAlbedo(shade, cycleRate, u, v, t, env);
        // emission は 1 を超えて持つ（Rgba16Float の描き先で炎が 1 を超えて残る。8bit の描き先は書く所で 0..1 に切る）。負だけ 0 に切る。
        let (er, eg, eb) = match emission {
            case Some(glow) =>
                let (gr, gg, gb) = evalShade(glow, cycleRate, u, v, t, env);
                (Float64.max(0.0, gr), Float64.max(0.0, gg), Float64.max(0.0, gb))
            case None       => (0.0, 0.0, 0.0)
        };
        { albedo = { r = cr, g = cg, b = cb }, alpha = evalNode(alpha, u, v, t, env), emission = { r = er, g = eg, b = eb } }

    // MipTex の読み方の番号（値の置き場の最後に置く）: 段 0 を読む・右隣の座標を控える・下隣の座標を控える・控えから lod を求めて読む。
    def modeLevel0(): Float64 = 0.0

    def modeRecordX(): Float64 = 1.0

    def modeRecordY(): Float64 = 2.0

    def modeLod(): Float64 = 3.0

    /// 3D の画素の値の置き場（World / Normal / 頂点の色を先頭に置き、bindings を point の uv で評価して後ろに積む）。
    def env3(bindings: List[Node], size: Int32, withInputs: Bool, point: SurfacePoint, t: Float64,
             rc: Region[r]): Array[Float64, r] \ r =
        let env: Array[Float64, r] = Array.repeat(rc, size, 0.0);
        if (withInputs) putInputs(point, env) else ();
        fillEnv(bindings, if (withInputs) inputSlots() else 0, point#uv#x, point#uv#y, t, env);
        env

    def putInputs(point: SurfacePoint, env: Array[Float64, r]): Unit \ r =
        let (world, normal, color) = (point#world, point#normal, point#color);
        let len = Vec2.sqrt(normal#x * normal#x + normal#y * normal#y + normal#z * normal#z);
        let unit = c -> if (len == 0.0) 0.0 else c / len;
        Array.put(world#x, inputIndex(false, ShaderDoc.Axis3.X), env);
        Array.put(world#y, inputIndex(false, ShaderDoc.Axis3.Y), env);
        Array.put(world#z, inputIndex(false, ShaderDoc.Axis3.Z), env);
        Array.put(unit(normal#x), inputIndex(true, ShaderDoc.Axis3.X), env);
        Array.put(unit(normal#y), inputIndex(true, ShaderDoc.Axis3.Y), env);
        Array.put(unit(normal#z), inputIndex(true, ShaderDoc.Axis3.Z), env);
        Array.put(color#r, 6, env);
        Array.put(color#g, 7, env);
        Array.put(color#b, 8, env)

    def fillEnv(bindings: List[Node], i: Int32, u: Float64, v: Float64, t: Float64, env: Array[Float64, r]): Unit \ r =
        match bindings {
            case Nil => ()
            case node :: rest =>
                Array.put(evalNode(node, u, v, t, env), i, env);
                fillEnv(rest, i + 1, u, v, t, env)
        }

    def compileShade(sampling: Sampling, ids: Ref[Int32, r], scope: Map[String, Int32], texEnv: Map[String, TexImage], shade: ShaderDoc.Shade): CShade \ r =
        let rgb = (c: Color) -> (c#r, c#g, c#b);
        match shade {
            case ShaderDoc.Shade.Solid(c)    => CShade.Solid(c#r, c#g, c#b)
            case ShaderDoc.Shade.Ramp(r)     => CShade.Ramp(rgb(r#lo), rgb(r#hi), compileField(sampling, ids, scope, texEnv, r#field))
            case ShaderDoc.Shade.Gradient(g) =>
                CShade.Gradient(List.map(pc -> { let (p, c) = pc; (p, rgb(c)) }, g#stops),
                                compileField(sampling, ids, scope, texEnv, g#field))
            case ShaderDoc.Shade.Cosine(cs)  =>
                let (a, b, c, d) = (cs#a, cs#b, cs#c, cs#d);
                let k = List.map(colorF64, a#r :: b#r :: c#r :: d#r :: a#g :: b#g :: c#g :: d#g :: a#b :: b#b :: c#b :: d#b :: Nil);
                CShade.Cosine(List.toVector(k), compileField(sampling, ids, scope, texEnv, cs#field))
            case ShaderDoc.Shade.Rgb(c)      =>
                CShade.Rgb(compileField(sampling, ids, scope, texEnv, c#r), compileField(sampling, ids, scope, texEnv, c#g),
                           compileField(sampling, ids, scope, texEnv, c#b))
        }

    /// sampling = この節の tex / blur の読み方（Sampler の内側なら linear が真）。
    /// ids = 段つきの絵を読む節に振る次の番号。
    def compileField(sampling: Sampling, ids: Ref[Int32, r], scope: Map[String, Int32], texEnv: Map[String, TexImage],
                     field: ShaderDoc.Field): Node \ r =
        let sub = f -> compileField(sampling, ids, scope, texEnv, f);
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
                match (Map.get(tx#name, sampling#mips), Map.get(tx#name, texEnv)) {
                    case (Some(chain), _) =>
                        let id = Ref.get(ids);
                        Ref.put(id + 1, ids);
                        Node.MipTex(id, chain, texShift(tx#chan), sampling#linear, sampling#repeat)
                    case (None, Some(TexImage.Rgba8Unorm(td))) =>
                        Node.Tex(td#width, td#height, td#pixels, texShift(tx#chan), sampling#linear, sampling#repeat)
                    case (None, Some(TexImage.Rgba16Float(HdrTextureData.HdrTextureData(w, h, values)))) =>
                        Node.TexF(w, h, values, texChanIndex(tx#chan), sampling#linear, sampling#repeat)
                    case (None, None)     => Node.Missing
                }
            // dx/dy は外側 uv で評価してから、of をずらした座標で読む（GLSL の式と同じ組み方）。
            case ShaderDoc.Field.Shift(sh)      => Node.Shift(sub(sh#dx), sub(sh#dy), sub(sh#of))
            case ShaderDoc.Field.TexBlur(bl)    =>
                match Map.get(bl#name, texEnv) {
                    case Some(TexImage.Rgba8Unorm(td)) => Node.TexBlur(td#width, td#height, td#pixels, texShift(bl#chan),
                                                  bl#radius#x, bl#radius#y, ShaderDoc.blurTaps(bl#taps), sub(bl#amount),
                                                  sampling#linear, sampling#repeat)
                    case Some(TexImage.Rgba16Float(HdrTextureData.HdrTextureData(w, h, values))) =>
                        Node.TexBlurF(w, h, values, texChanIndex(bl#chan), bl#radius#x, bl#radius#y, ShaderDoc.blurTaps(bl#taps),
                                      sub(bl#amount), sampling#linear, sampling#repeat)
                    case None     => Node.Missing
                }
            // 3D の材質の texEnv は段 0 の絵なので、寸法も段 0 の数（GL の textureSize(…, 0) と同じ）。
            case ShaderDoc.Field.TexSize(ts)    =>
                let pick = (w: Int32, h: Int32) -> match ts#axis {
                    case ShaderDoc.Axis.U => Int32.toFloat64(w)
                    case ShaderDoc.Axis.V => Int32.toFloat64(h)
                };
                match Map.get(ts#name, texEnv) {
                    case Some(TexImage.Rgba8Unorm(td))                        => Node.Const(pick(td#width, td#height))
                    case Some(TexImage.Rgba16Float(HdrTextureData.HdrTextureData(w, h, _))) => Node.Const(pick(w, h))
                    case None                                            => Node.Const(0.0)
                }
            // 描き出しは Render.shaderSurfaces が値の表で Const に置き換えてから渡す（ShaderDoc.bindParams）。
            // ここへ来るのは表を通さずに評価した時で、渡されなかった名前と同じく 0。
            case ShaderDoc.Field.Param(_)      => Node.Missing
            case ShaderDoc.Field.Sampler(sm)    =>
                compileField({ linear = sm#filter == ShaderDoc.FilterMode.Linear | sampling }, ids, scope, texEnv, sm#of)
            // 置き場は先頭の inputSlots 個（compileWith が取る）。uv の変換を受けないので Ref と同じく置き場を読むだけ。
            case ShaderDoc.Field.World(w)       => Node.Ref(inputIndex(false, w#axis))
            case ShaderDoc.Field.Normal(n)      => Node.Ref(inputIndex(true, n#axis))
            case ShaderDoc.Field.VertexColor(vc) => vertexColorNode(vc#chan)
        }

    /// Rgba16Float の 1 画素の中の成分の位置（r, g, b, α の順）。
    def texChanIndex(chan: ShaderDoc.TexChan): Int32 =
        match chan {
            case ShaderDoc.TexChan.R => 0
            case ShaderDoc.TexChan.G => 1
            case ShaderDoc.TexChan.B => 2
            case ShaderDoc.TexChan.A => 3
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
                // cycleRate は読まない（Shade.Rgb の doc の決まり）。0..1 に切るのは書く所（Rgba16Float の描き先は 1 を超えて持つ）。
                let r = colorF64(evalNode(fr, x, y, t, env));
                let g = colorF64(evalNode(fg, x, y, t, env));
                let b = colorF64(evalNode(fb, x, y, t, env));
                (r, g, b)
        }

    /// 3D の材質の光を当てる前の色（albedo）。Rgb の 3 本は 0..1 に切る（evalShade は切らない）。
    def evalAlbedo(shade: CShade, cycleRate: Float64, x: Float64, y: Float64, t: Float64,
                   env: Array[Float64, r]): (Float64, Float64, Float64) \ r =
        match shade {
            case CShade.Rgb(fr, fg, fb) =>
                (colorF32(evalNode(fr, x, y, t, env)), colorF32(evalNode(fg, x, y, t, env)), colorF32(evalNode(fb, x, y, t, env)))
            case _ => evalShade(shade, cycleRate, x, y, t, env)
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
                    case ShaderDoc.BinOp.Div  => if (b == 0.0) 0.0 else a / b
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
                    case ShaderDoc.UnOp.Sqrt     => Vec2.sqrt(Float64.max(v, 0.0))
                }
            case Node.Pow(of, p) => powf(evalNode(of, x, y, t, env), p)
            case Node.Time(scale, offset) => t * scale + evalNode(offset, x, y, t, env)
            // 各マス内は fract(uv*tiles)。of をこの座標で読む（GLSL の差し替えと同じ形）。
            case Node.Tiling(tilesX, tilesY, of) => evalNode(of, Num.fract(x * tilesX), Num.fract(y * tilesY), t, env)
            case Node.Snap(cx, cy, of) =>
                evalNode(of, (Float64.floor(x * cx) + 0.5) / cx, (Float64.floor(y * cy) + 0.5) / cy, t, env)
            case Node.Ref(i) => Array.get(i, env)
            case Node.Missing => 0.0
            case Node.Tex(w, h, pixels, shift, linear, repeat) => sampleTexAs({ linear = linear, repeat = repeat }, w, h, pixels, shift, x, y)
            case Node.MipTex(id, chain, shift, linear, repeat) => evalMipTex(id, chain, shift, { linear = linear, repeat = repeat }, x, y, env)
            case Node.Shift(fdx, fdy, of) =>
                let dx = evalNode(fdx, x, y, t, env);
                let dy = evalNode(fdy, x, y, t, env);
                evalNode(of, x + dx, y + dy, t, env)
            case Node.TexBlur(w, h, pixels, shift, rx, ry, taps, amount, linear, repeat) =>
                let k = evalNode(amount, x, y, t, env);
                blurTex({ w = w, h = h, pixels = pixels, shift = shift, sampling = { linear = linear, repeat = repeat } }, x, y, rx * k, ry * k, taps)
            case Node.TexF(w, h, values, chan, linear, repeat) => sampleTexFAs({ linear = linear, repeat = repeat }, w, h, values, chan, x, y)
            case Node.TexBlurF(w, h, values, chan, rx, ry, taps, amount, linear, repeat) =>
                let k = evalNode(amount, x, y, t, env);
                blurTexF({ w = w, h = h, values = values, chan = chan, sampling = { linear = linear, repeat = repeat } }, x, y, rx * k, ry * k, taps)
        }

    /// 段つきの絵の節 id を座標 (x, y) で読む（値の置き場の最後の番号で、段 0 を読むか・隣の座標を控えるか・lod を求めて読むか）。
    def evalMipTex(id: Int32, chain: Vector[TexData], shift: Int32, sampling: { linear = Bool, repeat = Bool },
                   x: Float64, y: Float64, env: Array[Float64, r]): Float64 \ r =
        let size = Array.length(env);
        let mode = Array.get(size - 1, env);
        let slot = size - 1 - (id + 1) * 4;
        if (mode == modeRecordX()) { Array.put(x, slot, env); Array.put(y, slot + 1, env) }
        else if (mode == modeRecordY()) { Array.put(x, slot + 2, env); Array.put(y, slot + 3, env) }
        else ();
        let lod = if (mode != modeLod()) 0.0 else match Vector.head(chain) {
            case Some(base) =>
                Mip.lodOf({ dudx = Array.get(slot, env) - x, dvdx = Array.get(slot + 1, env) - y,
                            dudy = Array.get(slot + 2, env) - x, dvdy = Array.get(slot + 3, env) - y },
                          base#width, base#height, Vector.length(chain))
            case None => 0.0
        };
        sampleMip(chain, sampling, shift, lod, x, y)

    /// 段の列 chain を lod で読む（GL の NEAREST_MIPMAP_LINEAR・LINEAR_MIPMAP_LINEAR と同じ）。lod ≤ 0 は段 0 を sampling の補間で、
    /// ほかは隣り合う 2 段をそれぞれ sampling の補間で読み、lod の小数で混ぜる。wrap は各段に掛かる。
    def sampleMip(chain: Vector[TexData], sampling: { linear = Bool, repeat = Bool }, shift: Int32, lod: Float64, u: Float64, v: Float64): Float64 =
        let n = Vector.length(chain);
        let read = (k: Int32) -> {
            let td = Vector.get(Int32.max(0, Int32.min(n - 1, k)), chain);
            sampleTexAs(sampling, td#width, td#height, td#pixels, shift, u, v)
        };
        if (n == 0) 0.0
        else if (lod <= 0.0) read(0)
        else {
            let k = Float64.tryToInt32(Float64.floor(lod)) |> Option.getWithDefault(0);
            // WhyNot: lod の小数をそのまま混ぜる重みにしない — GPU は 1/256 ほどに切り捨てて混ぜ、段の境目の帯の画素が GL とずれる。
            let f = Float64.floor((lod - Float64.floor(lod)) * 256.0) / 256.0;
            let a = read(k);
            if (f == 0.0) a else a + (read(k + 1) - a) * f
        }

    /// 段の列 chain の uv (u, v) の r・g・b を lod で読む（sampleMip と同じ読み方。3D の法線マップが読む）。
    pub def sampleMipRgb(chain: Vector[TexData], sampling: { linear = Bool, repeat = Bool }, lod: Float64, u: Float64, v: Float64): (Float64, Float64, Float64) =
        (sampleMip(chain, sampling, 16, lod, u, v), sampleMip(chain, sampling, 8, lod, u, v), sampleMip(chain, sampling, 0, lod, u, v))

    /// ぼかしの標本（GLSL の sg_blur と同じ点の並び: i 番目は角度 i×黄金角・距離 √((i+0.5)/taps)）。
    /// 半径が 0 なら 1 点だけ読む（sg_blur と同じ分岐）。
    def blurTex(tex: BlurTex, u: Float64, v: Float64, rx: Float64, ry: Float64, taps: Int32): Float64 =
        if (rx == 0.0 and ry == 0.0) sampleTexAs(tex#sampling, tex#w, tex#h, tex#pixels, tex#shift, u, v)
        else blurSum(tex, u, v, rx, ry, taps, 0, 0.0) / Int32.toFloat64(taps)

    /// ぼかしが読む 1 枚（寸法・画素・チャンネルの shift・読み方）。
    type alias BlurTex = { w = Int32, h = Int32, pixels = Vector[Int32], shift = Int32, sampling = Filter }

    def blurSum(tex: BlurTex, u: Float64, v: Float64,
                rx: Float64, ry: Float64, taps: Int32, i: Int32, acc: Float64): Float64 =
        if (i >= taps) acc
        else {
            let fi = Int32.toFloat64(i);
            let r = Vec2.sqrt((fi + 0.5) / Int32.toFloat64(taps));
            let a = fi * 2.39996323;
            let s = sampleTexAs(tex#sampling, tex#w, tex#h, tex#pixels, tex#shift, u + Vec2.cos(a) * r * rx, v + Vec2.sin(a) * r * ry);
            blurSum(tex, u, v, rx, ry, taps, i + 1, acc + s)
        }

    def sampleTexAs(sampling: Filter, w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        match (sampling#linear, sampling#repeat) {
            case (true, false)  => sampleTexLinear(w, h, pixels, shift, u, v)
            case (false, false) => sampleTex(w, h, pixels, shift, u, v)
            case (true, true)   => sampleTexLinearRepeat(w, h, pixels, shift, wrapUnit(u), wrapUnit(v))
            case (false, true)  => sampleTex(w, h, pixels, shift, wrapUnit(u), wrapUnit(v))
        }

    /// 座標を 0..1 へ戻す（GL の REPEAT と同じ fract）。
    def wrapUnit(x: Float64): Float64 = x - Float64.floor(x)

    /// Linear の REPEAT の標本（GL の GL_LINEAR + REPEAT と同じ）。0..1 へ戻した座標で、端をまたぐ 4 テクセルは反対の端から読む。
    def sampleTexLinearRepeat(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else {
            let x = u * Int32.toFloat64(w) - 0.5;
            let y = v * Int32.toFloat64(h) - 0.5;
            let x0 = Float64.floor(x);
            let y0 = Float64.floor(y);
            let fx = x - x0;
            let fy = y - y0;
            let at = (tx, ty) -> {
                let argb = Vector.get(wrapTexel(ty, h) * w + wrapTexel(tx, w), pixels);
                Int32.toFloat64(Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, argb), 255)) / 255.0
            };
            let top = at(x0, y0) + (at(x0 + 1.0, y0) - at(x0, y0)) * fx;
            let bottom = at(x0, y0 + 1.0) + (at(x0 + 1.0, y0 + 1.0) - at(x0, y0 + 1.0)) * fx;
            top + (bottom - top) * fy
        }

    /// texel 添字を [0, n−1] へ回す（REPEAT。−1 は n−1・n は 0）。floor 済みの値を受ける。
    def wrapTexel(x: Float64, n: Int32): Int32 =
        let k = Float64.tryToInt32(x) |> Option.getWithDefault(0);
        Int32.remainder(Int32.remainder(k, n) + n, n)

    /// Linear の標本（GL の GL_LINEAR + CLAMP_TO_EDGE と同じ点・同じ重み）。テクセルの中心が (i+0.5)/w なので
    /// 読む点から 0.5 引いた所の左下の 4 テクセルを、端に張り付けて、はみ出した分の割合で混ぜる。
    /// GPU は重みを固定小数（たいてい 8bit）に丸めるので ±1/255 程度ずれうる（docs/backend-parity.md の近似の行）。
    def sampleTexLinear(w: Int32, h: Int32, pixels: Vector[Int32], shift: Int32, u: Float64, v: Float64): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else {
            let x = u * Int32.toFloat64(w) - 0.5;
            let y = v * Int32.toFloat64(h) - 0.5;
            let x0 = Float64.floor(x);
            let y0 = Float64.floor(y);
            let fx = x - x0;
            let fy = y - y0;
            let at = (tx, ty) -> {
                let argb = Vector.get(clampTexel(ty, h) * w + clampTexel(tx, w), pixels);
                Int32.toFloat64(Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, argb), 255)) / 255.0
            };
            let top = at(x0, y0) + (at(x0 + 1.0, y0) - at(x0, y0)) * fx;
            let bottom = at(x0, y0 + 1.0) + (at(x0 + 1.0, y0 + 1.0) - at(x0, y0 + 1.0)) * fx;
            top + (bottom - top) * fy
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

    // ── Rgba16Float の標本（点・重み・端の扱いは 8bit の同名の関数と同じ。値を 255 で割らず、α だけ 0..1 に切る）──
    // WhyNot: 8bit の関数に値の読み方を関数で渡して 1 本にしない — テクセルごとに閉包を呼ぶ分が、8bit の面の描き出しに乗る。

    /// texel (ix, iy) の chan の値（α は 0..1 に切る — Add が溜めた α を混ぜ式に入れない。GL の sprite も読む所で切る）。
    def texelF(w: Int32, values: Vector[Float32], chan: Int32, ix: Int32, iy: Int32): Float64 =
        let v = Float32.toFloat64(Vector.get((iy * w + ix) * 4 + chan, values));
        if (chan == 3) Num.clamp01(v) else v

    def sampleTexFAs(sampling: Filter, w: Int32, h: Int32, values: Vector[Float32], chan: Int32, u: Float64, v: Float64): Float64 =
        match (sampling#linear, sampling#repeat) {
            case (true, false)  => sampleTexFLinear(w, h, values, chan, u, v, clampTexel)
            case (false, false) => sampleTexF(w, h, values, chan, u, v)
            case (true, true)   => sampleTexFLinear(w, h, values, chan, wrapUnit(u), wrapUnit(v), wrapTexel)
            case (false, true)  => sampleTexF(w, h, values, chan, wrapUnit(u), wrapUnit(v))
        }

    /// NEAREST の標本（sampleTex と同じ添字）。
    def sampleTexF(w: Int32, h: Int32, values: Vector[Float32], chan: Int32, u: Float64, v: Float64): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else texelF(w, values, chan, clampTexel(Float64.floor(u * Int32.toFloat64(w)), w), clampTexel(Float64.floor(v * Int32.toFloat64(h)), h))

    /// Linear の標本（sampleTexLinear・sampleTexLinearRepeat と同じ点と重み）。edge = 端の扱い（clampTexel か wrapTexel）。
    def sampleTexFLinear(w: Int32, h: Int32, values: Vector[Float32], chan: Int32, u: Float64, v: Float64,
                         edge: (Float64, Int32) -> Int32): Float64 =
        if (w <= 0 or h <= 0) 0.0
        else {
            let x = u * Int32.toFloat64(w) - 0.5;
            let y = v * Int32.toFloat64(h) - 0.5;
            let x0 = Float64.floor(x);
            let y0 = Float64.floor(y);
            let fx = x - x0;
            let fy = y - y0;
            let at = (tx, ty) -> texelF(w, values, chan, edge(tx, w), edge(ty, h));
            let top = at(x0, y0) + (at(x0 + 1.0, y0) - at(x0, y0)) * fx;
            let bottom = at(x0, y0 + 1.0) + (at(x0 + 1.0, y0 + 1.0) - at(x0, y0 + 1.0)) * fx;
            top + (bottom - top) * fy
        }

    /// ぼかしが読む Rgba16Float の 1 枚（BlurTex の Rgba16Float 版）。
    type alias BlurTexF = { w = Int32, h = Int32, values = Vector[Float32], chan = Int32, sampling = Filter }

    /// blurTex の Rgba16Float 版（点の並びは同じ）。
    def blurTexF(tex: BlurTexF, u: Float64, v: Float64, rx: Float64, ry: Float64, taps: Int32): Float64 =
        if (rx == 0.0 and ry == 0.0) sampleTexFAs(tex#sampling, tex#w, tex#h, tex#values, tex#chan, u, v)
        else blurSumF(tex, u, v, rx, ry, taps, 0, 0.0) / Int32.toFloat64(taps)

    def blurSumF(tex: BlurTexF, u: Float64, v: Float64,
                 rx: Float64, ry: Float64, taps: Int32, i: Int32, acc: Float64): Float64 =
        if (i >= taps) acc
        else {
            let fi = Int32.toFloat64(i);
            let r = Vec2.sqrt((fi + 0.5) / Int32.toFloat64(taps));
            let a = fi * 2.39996323;
            let s = sampleTexFAs(tex#sampling, tex#w, tex#h, tex#values, tex#chan, u + Vec2.cos(a) * r * rx, v + Vec2.sin(a) * r * ry);
            blurSumF(tex, u, v, rx, ry, taps, i + 1, acc + s)
        }

    // Pow の CPU 評価。整数指数は反復積（GLSL の powProduct と同じ左結合の並び）で、
    // 非整数のみ Float64.pow を呼ぶ（第 1 引数はレコード）。負の底は 0 で下切り。
    def powf(x: Float64, p: Float64): Float64 =
        let base = Float64.max(0.0, x);
        if (p < 0.0) negPow(x, p)
        else if (Float64.floor(p) == p)
            powProduct(base, Float64.floor(p))
        else
            Float64.pow({ base = base }, p)

    // 負の指数の pow（ShaderGen.negPowExpr と同じ下切り・上切り・掛け順）。
    def negPow(x: Float64, p: Float64): Float64 =
        let base = Float64.max(ShaderDoc.negPowFloor(), x);
        let raw = if (Float64.floor(p) == p) 1.0 / powProduct(base, Float64.floor(-p))
                  else Float64.pow({ base = base }, p);
        Float64.min(ShaderDoc.negPowCeil(), raw)

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
