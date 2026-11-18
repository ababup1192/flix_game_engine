// StageFx — 炎の洞窟・氷の谷の地図の見た目の欄（emission・layers・heat・rim・flow・gloss・lighting・objectSprites の光・particles）を読み、
// 材質・熱の地図・崖の根元の光る縁・点光源・粒（火の粉・雪）を作る。座標は TileMap3d と同じ（x = 東・y = 北・z = 上）。
// 地図の Doc の材質の鍵は TileMap3d.materialKey で材質の名前へ直してから持つ。
mod StageFx {
    use fge::{Color, DocJson, JsonCodec, Mat4, Mesh3d, Num, Scene3d, Sort, Texture3d, Vec3}
    use fge::ShaderDoc
    use fge::ShaderDoc.{Axis, Axis3, BinOp, Field, FilterMode, Out, Shade, TexChan, UnOp}
    use Util.Json.Json
    use Faces.{Quad, Rgb}
    use TownMap.{Ground, Prop, TownMap}

    /// 自分で光る面の作り。Unlit = 光を受けず絵の色のまま光る（溶岩・強さ）・
    /// Cracks = 赤い画素だけ光る（R − k·G を熱の 2 乗で弱め、決めた色で光らせる）。
    pub enum Glow {
        case Unlit(Float64)
        case Cracks({ strength = Float64, k = Float64, color = Rgb })
    }

    /// 熱で色を移す層。blend = 2 枚目の絵と、world のむらの大きさ・hot = 熱い所で替える 3 枚目の絵と、替え始め・替え終わりの熱・
    /// minSat = 冷えた所でも残す彩度・ramp = 熱 → 色の掛け目（線形の値）の折れ線。
    pub type alias Layer = { blend = Option[(String, Float64)], hot = Option[(String, Float64, Float64)], minSat = Float64, ramp = List[(Float64, Rgb)] }

    /// 熱の地図。grounds = 熱の元の地面（溶岩）・reach = 熱が 0 になる距離（マス）・power = 落ち方の乗数。
    pub type alias Heat = { grounds = Set[Ground], reach = Float64, power = Float64 }

    /// 地面の上の点光源の置き方。ground = 置く地面・every = 間引き（列 + 行がこの数で割り切れるマス）・energy = 強さ（Blender の W）・height = 床からの高さ（m）。
    pub type alias LightRule = { ground = Ground, every = Int32, energy = Float64, color = Rgb, height = Float64 }

    /// 物の板の光。energy = 強さ（Blender の W）・height = 足元からの高さ（m）。
    pub type alias SpriteLight = { energy = Float64, color = Rgb, height = Float64 }

    /// 物の字の板の光り方。emit = 自分で光る強さ（0 で光らない）・light = 板に添える点光源。
    pub type alias SpriteFx = { emit = Float64, light = Option[SpriteLight] }

    /// 粒の出る所。OnGround = その地面のマスから昇って消える（火の粉）・AroundCamera = カメラの前の箱の中で回る（雪）。
    pub enum Spawn with Eq {
        case OnGround(Ground)
        case AroundCamera
    }

    /// 粒。count = 数・emit = 光る強さ・size = 一辺（m）・vel = 速さ（m/秒・x 東・y 北・z 上）・sway = 横の揺れ（m）・
    /// life = 昇る高さ（m・火の粉）・box = 回る箱の大きさ（m・雪）・ahead = 箱をカメラの追う点から北へずらす量（m）。
    pub type alias Particles = { origin = Spawn, count = Int32, color = Rgb, emit = Float64, size = Float64, vel = (Float64, Float64, Float64),
                                 sway = Float64, life = Float64, box = (Float64, Float64, Float64), ahead = Float64 }

    /// 地図の見た目の欄。glows・layers・flow・gloss = 材質の名前ごと（flow = uv の流れ /秒・gloss = 粗さ）・rim = 崖の根元の光る縁の色と強さ・
    /// lightRules・flicker = 地面の上の点光源と揺らぎの割合・sprites = 物の字ごとの光・particles = 粒・reflections = 空を映すか。
    pub type alias Fx = { glows = Map[String, Glow], layers = Map[String, Layer], heat = Option[Heat], rim = Option[(Rgb, Float64)],
                          flow = Map[String, (Float64, Float64)], gloss = Map[String, Float64], lightRules = List[LightRule], flicker = Float64,
                          sprites = Map[Char, SpriteFx], particles = Option[Particles], reflections = Bool }

    /// 見た目の欄が無い地図（町）。
    pub def none(): Fx =
        { glows = Map.empty(), layers = Map.empty(), heat = None, rim = None, flow = Map.empty(), gloss = Map.empty(), lightRules = Nil, flicker = 0.0,
          sprites = Map.empty(), particles = None, reflections = false }

    // ── 読む ──

    /// path の地図の見た目の欄を読む。
    pub def load(path: String): Result[String, Fx] \ Fs.FileRead =
        DocJson.readJson(path)
            |> Result.mapErr(e -> "${path}: ${DocJson.describe(e)}")
            |> Result.flatMap(json -> JsonCodec.expectObject(json) |> Option.toOk("${path} がオブジェクトでない"))
            |> Result.map(decode)

    /// 地図の JSON の上の欄から読む（無い欄は無い物として続ける）。
    pub def decode(top: Map[String, Json]): Fx =
        let obj = (key: String, o: Map[String, Json]) -> Map.get(key, o) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
        let lighting = obj("lighting", top);
        { glows = obj("emission", top) |> Map.toList |> List.filterMap(kv -> JsonCodec.expectObject(snd(kv)) |> Option.flatMap(glowOf)
                      |> Option.map(g -> (TileMap3d.materialKey(fst(kv)), g))) |> List.toMap,
          layers = obj("layers", top) |> Map.toList |> List.filterMap(kv -> JsonCodec.expectObject(snd(kv)) |> Option.map(o -> (TileMap3d.materialKey(fst(kv)), layerOf(o))))
                      |> List.toMap,
          heat = Map.get("heat", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(heatOf),
          rim = Map.get("rim", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(o ->
                    floats("color", o) |> Option.flatMap(rgbOf) |> Option.map(c -> (c, JsonCodec.floatOr("strength", 4.0, o)))),
          flow = obj("flow", top) |> Map.toList |> List.filterMap(kv -> JsonCodec.decodeList(JsonCodec.expectFloat, snd(kv)) |> Option.flatMap(pairOf)
                     |> Option.map(p -> (TileMap3d.materialKey(fst(kv)), p))) |> List.toMap,
          gloss = obj("gloss", top) |> Map.toList |> List.filterMap(kv -> JsonCodec.expectFloat(snd(kv)) |> Option.map(v -> (TileMap3d.materialKey(fst(kv)), v))) |> List.toMap,
          lightRules = Map.get("pointLights", lighting) |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(lightRuleOf)))
                           |> Option.getWithDefault(Nil),
          flicker = JsonCodec.floatOr("flicker", 0.0, lighting),
          sprites = obj("objectSprites", top) |> Map.toList |> List.filterMap(kv -> JsonCodec.expectObject(snd(kv)) |> Option.map(o -> (firstChar(fst(kv)), spriteFxOf(o))))
                        |> List.toMap,
          particles = Map.get("particles", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(particlesOf),
          reflections = JsonCodec.boolOr("reflections", false, lighting) }

    def firstChar(s: String): Char = String.toList(s) |> List.head |> Option.getWithDefault('.')

    def floats(key: String, o: Map[String, Json]): Option[List[Float64]] = Map.get(key, o) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))

    def rgbOf(xs: List[Float64]): Option[Rgb] = match xs {
        case r :: g :: b :: _ => Some({ r = r, g = g, b = b })
        case _                => None
    }

    def pairOf(xs: List[Float64]): Option[(Float64, Float64)] = match xs {
        case a :: b :: _ => Some((a, b))
        case _           => None
    }

    def tripleOf(xs: List[Float64], fallback: (Float64, Float64, Float64)): (Float64, Float64, Float64) = match xs {
        case a :: b :: c :: _ => (a, b, c)
        case _                => fallback
    }

    def glowOf(o: Map[String, Json]): Option[Glow] =
        let strength = JsonCodec.floatOr("strength", 1.0, o);
        match JsonCodec.stringOr("mode", "", o) {
            case "unlit" => Some(Glow.Unlit(strength))
            case "red"   => Some(Glow.Cracks({ strength = strength, k = JsonCodec.floatOr("k", 1.4, o),
                                               color = floats("color", o) |> Option.flatMap(rgbOf) |> Option.getWithDefault(Faces.white()) }))
            case _       => None
        }

    /// layers の 1 件。ramp が無ければ Blender の試作の既定の 4 段。
    def layerOf(o: Map[String, Json]): Layer =
        let stops = Map.get("ramp", o) |> Option.flatMap(JsonCodec.decodeList(stopOf)) |> Option.getWithDefault(Nil);
        let blend = Map.get("blend", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(p -> (p, JsonCodec.floatOr("blendScale", 0.35, o)));
        let hot = Map.get("hot", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(p -> (p, JsonCodec.floatOr("hotFrom", 0.3, o), JsonCodec.floatOr("hotTo", 0.55, o)));
        { blend = blend, hot = hot, minSat = JsonCodec.floatOr("minSat", 0.0, o), ramp = if (List.isEmpty(stops)) defaultRamp() else stops }

    def defaultRamp(): List[(Float64, Rgb)] =
        (0.0, { r = 0.8, g = 0.82, b = 0.88 }) :: (0.25, { r = 0.85, g = 0.6, b = 0.52 }) :: (0.55, { r = 1.1, g = 0.45, b = 0.3 }) :: (1.0, { r = 1.3, g = 0.62, b = 0.3 }) :: Nil

    /// ramp の 1 段 [位置, [r, g, b]]。
    def stopOf(j: Json): Option[(Float64, Rgb)] =
        JsonCodec.decodeList(x -> Some(x), j) |> Option.flatMap(xs -> match xs {
            case pos :: color :: _ => forM (p <- JsonCodec.expectFloat(pos); c <- JsonCodec.decodeList(JsonCodec.expectFloat, color) |> Option.flatMap(rgbOf)) yield (p, c)
            case _                 => None
        })

    def heatOf(o: Map[String, Json]): Heat =
        { grounds = JsonCodec.stringOr("chars", "w", o) |> String.toList |> List.map(TownMap.groundOf) |> List.toSet,
          reach = JsonCodec.floatOr("reach", 4.0, o), power = JsonCodec.floatOr("power", 1.6, o) }

    def lightRuleOf(o: Map[String, Json]): LightRule =
        { ground = TownMap.groundOf(firstChar(JsonCodec.stringOr("char", "w", o))), every = Int32.max(1, JsonCodec.intOr("every", 2, o)),
          energy = JsonCodec.floatOr("energy", 30.0, o), color = floats("color", o) |> Option.flatMap(rgbOf) |> Option.getWithDefault(Faces.white()),
          height = JsonCodec.floatOr("height", 0.6, o) }

    def spriteFxOf(o: Map[String, Json]): SpriteFx =
        { emit = JsonCodec.floatOr("emit", 0.0, o),
          light = Map.get("light", o) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(l ->
              { energy = JsonCodec.floatOr("energy", 25.0, l), color = floats("color", l) |> Option.flatMap(rgbOf) |> Option.getWithDefault(Faces.white()),
                height = JsonCodec.floatOr("height", 0.8, l) }) }

    def particlesOf(o: Map[String, Json]): Particles =
        let origin = Map.get("spawnOn", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(s -> Spawn.OnGround(TownMap.groundOf(firstChar(s))))
            |> Option.getWithDefault(Spawn.AroundCamera);
        { origin = origin, count = JsonCodec.intOr("count", 80, o), color = floats("color", o) |> Option.flatMap(rgbOf) |> Option.getWithDefault(Faces.white()),
          emit = JsonCodec.floatOr("emit", 0.0, o), size = JsonCodec.floatOr("size", 0.06, o),
          vel = tripleOf(floats("vel", o) |> Option.getWithDefault(Nil), (0.0, 0.0, 0.5)), sway = JsonCodec.floatOr("sway", 0.3, o),
          life = JsonCodec.floatOr("life", 1.2, o), box = tripleOf(floats("box", o) |> Option.getWithDefault(Nil), (14.0, 14.0, 5.0)),
          ahead = JsonCodec.floatOr("ahead", 2.0, o) }

    // ── 熱の地図 ──

    /// 熱の地図の 1 マスの画素の数。
    def heatTexels(): Int32 = 8

    /// 熱の地図（地図の大きさ × heatTexels の絵・行 0 が北・r = g = b = 熱 0..1）。溶岩のマスの縁 1 → reach マス離れると 0
    /// （チェビシェフ距離・落ち方は power 乗）・熱の残る所は低い段ほど +0.18。
    pub def heatTexture(m: TownMap, h: Heat): Result[String, Texture3d.Texture3d] =
        let per = heatTexels();
        let (w, hgt) = (m#width * per, m#height * per);
        let mapH = Int32.toFloat64(m#height);
        let sources = cellsOf(m) |> List.filter(cr -> Set.memberOf(TownMap.groundAt(m, fst(cr), snd(cr)), h#grounds))
            |> List.map(cr -> (Int32.toFloat64(fst(cr)) + 0.5, mapH - 1.0 - Int32.toFloat64(snd(cr)) + 0.5)) |> List.toVector;
        let levels = cellsOf(m) |> List.map(cr -> TownMap.levelAt(m, fst(cr), snd(cr)));
        let lo = Int32.toFloat64(List.foldLeft(Int32.min, 9999, levels));
        let hi = Int32.toFloat64(List.foldLeft(Int32.max, -9999, levels));
        let argb = Vector.range(0, hgt) |> Vector.flatMap(row -> Vector.range(0, w) |> Vector.map(col -> {
            let x = (Int32.toFloat64(col) + 0.5) / Int32.toFloat64(per);
            let y = mapH - (Int32.toFloat64(row) + 0.5) / Int32.toFloat64(per);
            let d = Float64.max(0.0, Vector.foldLeft((acc, s) -> Float64.min(acc, Float64.max(Float64.abs(x - fst(s)), Float64.abs(y - snd(s))) - 0.5), 99.0, sources));
            let near = Float64.pow(base = Num.clamp(0.0, 1.0, 1.0 - d / h#reach), h#power);
            let c = Float64.floor(x) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            let r = m#height - 1 - (Float64.floor(y) |> Float64.tryToInt32 |> Option.getWithDefault(0));
            let low = 1.0 - (Int32.toFloat64(TownMap.levelAt(m, c, r)) - lo) / Float64.max(hi - lo, 1.0);
            let v = Num.clamp(0.0, 1.0, near + (if (near > 0.05) 0.18 * low else 0.0));
            grayArgb(v)
        }));
        Texture3d.fromArgb(w, hgt, argb)

    def grayArgb(v: Float64): Int32 =
        let k = Float64.round(Num.clamp(0.0, 1.0, v) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(k, 16), Int32.bitwiseOr(Int32.leftShift(k, 8), k)))

    def cellsOf(m: TownMap): List[(Int32, Int32)] =
        List.range(0, m#height) |> List.flatMap(r -> List.range(0, m#width) |> List.map(c -> (c, r)))

    // ── 材質 ──

    def k(v: Float64): Field = Field.Const(v)

    def bin(op: BinOp, a: Field, b: Field): Field = Field.Bin({ op = op, a = a, b = b })

    def add(a: Field, b: Field): Field = bin(BinOp.Add, a, b)

    def sub(a: Field, b: Field): Field = bin(BinOp.Sub, a, b)

    def mul(a: Field, b: Field): Field = bin(BinOp.Mul, a, b)

    def sat(a: Field): Field = Field.Un({ op = UnOp.Sat, of = a })

    def ref(name: String): Field = Field.Ref(name)

    def read(filter: FilterMode, texture: String, ch: TexChan): Field = Field.Sampler({ filter = filter, of = Field.Tex({ name = texture, chan = ch }) })

    def channels(): List[(String, TexChan)] = ("r", TexChan.R) :: ("g", TexChan.G) :: ("b", TexChan.B) :: Nil

    def pick(c: Rgb, ch: TexChan): Float64 = match ch {
        case TexChan.R => c#r
        case TexChan.G => c#g
        case _         => c#b
    }

    /// 熱の地図を world の点（東 X・北 Z）で引く場（地図の外は 0）。
    // WhyNot: 地図の外を縁の値のまま読ませない — 溶岩に近い西の縁の熱が地図の外の低い地面へ帯になって伸び、赤いまだらが並ぶ。
    def heatField(m: TownMap, texture: String): Field =
        let (w, h) = (Int32.toFloat64(m#width), Int32.toFloat64(m#height));
        let within = (axis: Axis3, size: Float64) -> {
            let p = Field.World({ axis = axis });
            mul(Field.Smoothstep({ lo = -0.05, hi = 0.0, of = p }), sub(k(1.0), Field.Smoothstep({ lo = size, hi = size + 0.05, of = p })))
        };
        mul(mul(within(Axis3.X, w), within(Axis3.Z, h)), Field.Sampler({ filter = FilterMode.Linear,
                        of = Field.Shift({ dx = sub(sat(mul(Field.World({ axis = Axis3.X }), k(1.0 / w))), Field.Uv({ axis = Axis.U })),
                                           dy = sub(sat(sub(k(1.0), mul(Field.World({ axis = Axis3.Z }), k(1.0 / h)))), Field.Uv({ axis = Axis.V })),
                                           of = Field.Tex({ name = texture, chan = TexChan.R }) }) }))

    /// 熱 → 色の掛け目の折れ線の 1 色（前の段から次の段へ、熱が段の間にある割合だけ足していく）。
    /// 掛け目は線形の値なので、画面の値（絵の色）に掛ける前に 1/2.2 乗へ直す。
    // WhyNot: 線形の掛け目を絵の色へそのまま掛けない — 描き手が線形へ戻す時に 2.2 乗され、1.45 倍の赤が 2.3 倍になって崖が橙に飛ぶ。
    def rampField(stops: List[(Float64, Rgb)], ch: TexChan, heat: Field): Field =
        let screen = (c: Rgb) -> Float64.pow(base = Float64.max(0.0, pick(c, ch)), 1.0 / 2.2);
        let first = List.head(stops) |> Option.map(s -> screen(snd(s))) |> Option.getWithDefault(1.0);
        List.zip(stops, List.drop(1, stops)) |> List.foldLeft((acc, pair) -> {
            let ((p0, c0), (p1, c1)) = pair;
            add(acc, mul(k(screen(c1) - screen(c0)), sat(mul(sub(heat, k(p0)), k(1.0 / Float64.max(p1 - p0, 0.0001))))))
        }, k(first))

    /// 熱で色を移す層の材質（2 枚目の絵をむらで混ぜる → 熱い所で 3 枚目へ替える → 冷えた所ほど灰色へ → 熱のランプを掛ける → 頂点の色（AO）を掛ける）。
    /// glow が Cracks なら、赤い画素を熱の 2 乗で光らせる。texOf = assets のパス → 材質の絵の名前。
    def layeredMaterial(m: TownMap, tile: String, layer: Layer, heatTexture: String, texOf: String -> Option[String], glow: Option[Glow]): Scene3d.Material3d =
        let noiseOf = (scale: Float64) -> Field.Smoothstep({ lo = 0.45, hi = 0.55, of = ShaderDoc.atWorld((Axis3.X, Axis3.Z), Field.Fbm({ octaves = 2, scale = scale, seed = 7 })) });
        let base = (ch: TexChan) -> read(FilterMode.Nearest, tile, ch);
        let blended = (ch: TexChan) -> layer#blend |> Option.flatMap(b -> texOf(fst(b)) |> Option.map(t ->
            Field.Blend({ a = base(ch), b = read(FilterMode.Nearest, t, ch), by = noiseOf(snd(b)) }))) |> Option.getWithDefault(base(ch));
        let hotted = (ch: TexChan) -> layer#hot |> Option.flatMap(hs -> {
            let (path, hotFrom, hotTo) = hs;
            texOf(path) |> Option.map(t -> Field.Blend({ a = blended(ch), b = read(FilterMode.Nearest, t, ch), by = Field.Smoothstep({ lo = hotFrom, hi = hotTo, of = ref("heat") }) }))
        }) |> Option.getWithDefault(blended(ch));
        let raw = channels() |> List.map(nc -> ("c" + fst(nc), hotted(snd(nc))));
        let lum = add(add(mul(k(0.2126), ref("cr")), mul(k(0.7152), ref("cg"))), mul(k(0.0722), ref("cb")));
        let layered = channels() |> List.map(nc -> {
            let (n, ch) = nc;
            ("l" + n, mul(Field.Blend({ a = ref("lum"), b = ref("c" + n), by = ref("sat") }), rampField(layer#ramp, ch, ref("heat"))))
        });
        let bindings = List.flatten((("heat", heatField(m, heatTexture)) :: raw) :: (("lum", lum) :: ("sat", bin(BinOp.Max, ref("heat"), k(layer#minSat))) :: Nil) :: layered :: Nil);
        let shade = Shade.Rgb({ r = mul(ref("lr"), Field.VertexColor({ chan = TexChan.R })), g = mul(ref("lg"), Field.VertexColor({ chan = TexChan.G })),
                                b = mul(ref("lb"), Field.VertexColor({ chan = TexChan.B })) });
        let mat = Scene3d.material({ name = "hd2d:heat-layer", cycleRate = 0.0, bindings = bindings, out = Out.Fill({ shade = shade, alpha = k(1.0) }) })
            |> Scene3d.withDoubleSided(true);
        match glow {
            case Some(Glow.Cracks(c)) =>
                let fac = mul(sat(sub(ref("lr"), mul(k(c#k), ref("lg")))), Field.Pow({ of = ref("heat"), p = 2.0 }));
                mat |> Scene3d.withEmission(Shade.Rgb({ r = mul(fac, k(c#color#r)), g = mul(fac, k(c#color#g)), b = mul(fac, k(c#color#b)) }))
                    |> Scene3d.withEmissionIntensity(c#strength)
            case _ => mat
        }

    /// 光を受けず絵の色のまま光る材質（地の色は黒）。flow = uv の流れ（/秒）。
    // WhyNot: 光を受ける材質に発光を足さない — 溶岩の橙の上に溶岩の点光源の橙が乗り、桃色に飛ぶ。
    def unlitMaterial(tile: String, strength: Float64, flow: (Float64, Float64)): Scene3d.Material3d =
        let flowing = (ch: TexChan) -> Field.Sampler({ filter = FilterMode.Nearest,
            of = Field.Scaled({ factor = 1.0, scroll = { x = fst(flow), y = snd(flow) }, of = Field.Tex({ name = tile, chan = ch }) }) });
        Scene3d.material({ name = "hd2d:unlit-glow", cycleRate = 0.0, bindings = Nil,
                           out = Out.Fill({ shade = Shade.Rgb({ r = k(0.0), g = k(0.0), b = k(0.0) }), alpha = k(1.0) }) })
            |> Scene3d.withEmission(Shade.Rgb({ r = flowing(TexChan.R), g = flowing(TexChan.G), b = flowing(TexChan.B) }))
            |> Scene3d.withEmissionIntensity(strength)
            |> Scene3d.withDoubleSided(true)

    /// 決まった色で光る材質（崖の根元の縁・粒）。
    def solidGlow(name: String, c: Rgb, strength: Float64): Scene3d.Material3d =
        let srgb = (v: Float64) -> k(Faces.linearToSrgb(v));
        Scene3d.material({ name = name, cycleRate = 0.0, bindings = Nil,
                           out = Out.Fill({ shade = Shade.Rgb({ r = k(0.0), g = k(0.0), b = k(0.0) }), alpha = k(1.0) }) })
            |> Scene3d.withEmission(Shade.Rgb({ r = srgb(c#r), g = srgb(c#g), b = srgb(c#b) }))
            |> Scene3d.withEmissionIntensity(strength)
            |> Scene3d.withDoubleSided(true)

    /// 崖の根元の光る縁の材質の名前。
    pub def rimMaterialName(): String = "rim"

    /// 材質の名前 → 町の材質の代わりに使う材質（見た目の欄が触る名前だけ）。table = 材質の表・texOf = assets のパス → 材質の絵の名前・
    /// heatTexture = 熱の地図の絵の名前。
    /// glowScale = 自分で光る強さ（emission・rim）に掛ける倍率（Blender の試作の強さを engine の露出へ直す）。
    pub def materialsOf(m: TownMap, fx: Fx, glowScale: Float64, table: Map[String, (String, Rgb)], texOf: String -> Option[String], heatTexture: Option[String]): Map[String, Scene3d.Material3d] =
        let scaled = { glows = fx#glows |> Map.map(g -> scaleGlow(glowScale, g)) | fx };
        let surfaces = table |> Map.toList |> List.filterMap(entry -> {
            let (name, (path, _)) = entry;
            texOf(path) |> Option.flatMap(tile -> surfaceOf(m, scaled, name, tile, texOf, heatTexture)) |> Option.map(mat -> (name, mat))
        });
        let rim = fx#rim |> Option.map(rc -> (rimMaterialName(), solidGlow("hd2d:lava-rim", fst(rc), snd(rc) * glowScale))) |> Option.toList;
        List.append(surfaces, rim) |> List.toMap

    def scaleGlow(k0: Float64, g: Glow): Glow = match g {
        case Glow.Unlit(s)  => Glow.Unlit(s * k0)
        case Glow.Cracks(c) => Glow.Cracks({ strength = c#strength * k0 | c })
    }

    def surfaceOf(m: TownMap, fx: Fx, name: String, tile: String, texOf: String -> Option[String], heatTexture: Option[String]): Option[Scene3d.Material3d] =
        let glow = Map.get(name, fx#glows);
        let layered = forM (hm <- heatTexture; layer <- Map.get(name, fx#layers)) yield layeredMaterial(m, tile, layer, hm, texOf, glow);
        let shaped = match glow {
            case Some(Glow.Unlit(strength)) => Some(unlitMaterial(tile, strength, Map.get(name, fx#flow) |> Option.getWithDefault((0.0, 0.0))))
            case _                          => layered
        };
        let glossy = (mat: Scene3d.Material3d) -> Map.get(name, fx#gloss) |> Option.map(r -> Scene3d.withMetallicRoughness(0.0, r, mat)) |> Option.getWithDefault(mat);
        match shaped {
            case Some(mat) => Some(glossy(mat))
            case None      => Map.get(name, fx#gloss) |> Option.map(_ -> glossy(Scene3d.texturedMaterial(tile, FilterMode.Nearest) |> Scene3d.withDoubleSided(true)))
        }

    /// 見た目の欄が読む、材質の表に無い絵（層の 2 枚目・3 枚目）。
    pub def extraTiles(fx: Fx): List[String] =
        fx#layers |> Map.valuesOf |> List.flatMap(l -> List.append(l#blend |> Option.map(fst) |> Option.toList, l#hot |> Option.map(b -> { let (p, _, _) = b; p }) |> Option.toList))
            |> List.distinct

    // ── 崖の根元の光る縁 ──

    /// 溶岩の水面から立つ崖の下端の細い光る帯（水面の 0.02 m 下から 0.18 m 上・崖から 0.01 m 浮かす）。
    pub def rimQuads(m: TownMap, fx: Fx): List[Quad] =
        if (Option.isEmpty(fx#rim)) Nil
        else {
            let foot = TownMap.footprints(m);
            cellsOf(m) |> List.filter(cr -> not Map.memberOf(cr, foot) and TownMap.groundAt(m, fst(cr), snd(cr)) != Ground.Water)
                |> List.flatMap(cr -> {
                    let (c, r) = cr;
                    sides() |> List.filterMap(side -> rimOf(m, c, r, side))
                })
        }

    def sides(): List[(String, Int32, Int32)] = ("s", 0, 1) :: ("n", 0, -1) :: ("e", 1, 0) :: ("w", -1, 0) :: Nil

    def rimOf(m: TownMap, c: Int32, r: Int32, side: (String, Int32, Int32)): Option[Quad] =
        let (name, dc, dr) = side;
        let (nc, nr) = (c + dc, r + dr);
        let zs = Int32.toFloat64(TownMap.levelAt(m, nc, nr)) * m#heightStep - TownMap.waterSurface();
        if (TownMap.groundAt(m, nc, nr) != Ground.Water or not TownMap.inside(m, nc, nr) or TownMap.topAt(m, c, r) <= zs) None
        else {
            let x0 = Int32.toFloat64(c);
            let y0 = Int32.toFloat64(m#height - 1 - r);
            let (p, q) = match name {
                case "s" => ((x0, y0), (x0 + 1.0, y0))
                case "n" => ((x0 + 1.0, y0 + 1.0), (x0, y0 + 1.0))
                case "e" => ((x0 + 1.0, y0), (x0 + 1.0, y0 + 1.0))
                case _   => ((x0, y0 + 1.0), (x0, y0))
            };
            let (ox, oy) = (Int32.toFloat64(dc) * 0.01, Int32.toFloat64(0 - dr) * 0.01);
            let at = (pt: (Float64, Float64), z: Float64) -> Faces.p3(fst(pt) + ox, snd(pt) + oy, z);
            Some({ owner = Faces.Owner.Cell(c, r) | Faces.quad(rimMaterialName(), at(p, zs - 0.02) :: at(q, zs - 0.02) :: at(q, zs + 0.18) :: at(p, zs + 0.18) :: Nil, Faces.fullUv(), Nil) })
        }

    // ── 点光源 ──

    /// Blender の試作の点光源の W → engine の Physical の強さ（町の街灯の 120 W ↔ 260 に合わせた比）。
    def wattsToIntensity(): Float64 = 260.0 / 120.0

    /// 点光源の届く範囲（m）。
    def lightRange(): Float64 = 7.0

    /// 地面の点光源を間引く塊の一辺（マス）。
    // WhyNot: 地図の every の間引きのまま全部を置かない — engine は画面の真ん中に近い 8 本しか計算せず、溶岩の上に 20 本並べると画面の端の溶岩が選ばれず暗く跳ねる。
    def lightBlock(): Int32 = 5

    /// 地面の点光源の元（位置・強さ・色・揺らぎの位相）。塊ごとに、溶岩のマスの真ん中に一番近いマスの上に 1 本。
    def groundLights(m: TownMap, fx: Fx): List[(Vec3.Vec3, Float64, Rgb, Float64)] =
        let byGround = cellsOf(m) |> List.foldLeft((acc, cr) -> Map.insertWith((fresh, old) -> List.append(fresh, old), TownMap.groundAt(m, fst(cr), snd(cr)), cr :: Nil, acc), Map.empty());
        fx#lightRules |> List.flatMap(rule -> {
            let cells = Map.get(rule#ground, byGround) |> Option.getWithDefault(Nil);
            let blocks = cells |> List.foldLeft((acc, cr) -> Map.insertWith((fresh, old) -> List.append(fresh, old), (fst(cr) / lightBlock(), snd(cr) / lightBlock()), cr :: Nil, acc), Map.empty());
            blocks |> Map.valuesOf |> List.filterMap(group -> {
                let n = Int32.toFloat64(List.length(group));
                let mx = List.foldLeft((a, cr) -> a + Int32.toFloat64(fst(cr)), 0.0, group) / n;
                let my = List.foldLeft((a, cr) -> a + Int32.toFloat64(snd(cr)), 0.0, group) / n;
                let dist = (cr: (Int32, Int32)) -> (Int32.toFloat64(fst(cr)) - mx) * (Int32.toFloat64(fst(cr)) - mx) + (Int32.toFloat64(snd(cr)) - my) * (Int32.toFloat64(snd(cr)) - my);
                List.minimumBy((a, b) -> dist(a) <=> dist(b), group) |> Option.map(cr -> {
                    let (c, r) = cr;
                    let z = Int32.toFloat64(TownMap.levelAt(m, c, r)) * m#heightStep + rule#height;
                    (Vec3.v3(Int32.toFloat64(c) + 0.5, z, Int32.toFloat64(m#height - 1 - r) + 0.5), rule#energy, rule#color, TileMap3d.h01(c, r, 31) * 2.0 * Num.pi())
                })
            })
        })

    /// 物の字の板に添える点光源（板の足元から height の高さ・板の 0.3 m 手前）。
    def spriteLights(m: TownMap, fx: Fx): List[(Vec3.Vec3, Float64, Rgb)] =
        cellsOf(m) |> List.filterMap(cr -> {
            let (c, r) = cr;
            match TownMap.propAt(m, c, r) {
                case Prop.Sprite(ch) => Map.get(ch, fx#sprites) |> Option.flatMap(s -> s#light) |> Option.map(l -> {
                    let x = Int32.toFloat64(c) + 0.5 + (TileMap3d.h01(c, r, 3) - 0.5) * 0.3;
                    let y = Int32.toFloat64(m#height - 1 - r) + 0.5;
                    (Vec3.v3(x, TownMap.topAt(m, c, r) + l#height, y - 0.3), l#energy, l#color)
                })
                case _ => None
            }
        })

    /// 時刻 t の点光源。地面の点光源は周期の違う 3 つの波の和で ±flicker 揺らす（物の板の光は揺らさない）。scale = 強さに掛ける倍率。
    pub def lightsAt(m: TownMap, fx: Fx, scale: Float64, t: Float64): List[Scene3d.PointLight] =
        let colorOf = (c: Rgb) -> Color.rgb(Faces.linearToSrgb(c#r), Faces.linearToSrgb(c#g), Faces.linearToSrgb(c#b));
        let ground = groundLights(m, fx) |> List.map(l -> {
            let (p, e, c, ph) = l;
            let wave = 0.5 * Num.sin(2.1 * t + ph) + 0.3 * Num.sin(5.3 * t + 2.0 * ph) + 0.2 * Num.sin(11.7 * t + 3.0 * ph);
            { position = p, color = colorOf(c), intensity = e * wattsToIntensity() * scale * (1.0 + fx#flicker * wave), range = lightRange() }
        });
        let sprites = spriteLights(m, fx) |> List.map(l -> {
            let (p, e, c) = l;
            { position = p, color = colorOf(c), intensity = e * wattsToIntensity() * scale, range = lightRange() }
        });
        List.append(ground, sprites)

    /// 物の板の絵 → 自分で光る強さ（光る物だけ）。
    pub def spriteGlows(m: TownMap, fx: Fx): Map[String, Float64] =
        fx#sprites |> Map.toList |> List.filterMap(kv -> {
            let (ch, s) = kv;
            if (s#emit <= 0.0) None else Map.get(ch, m#objectSprites) |> Option.map(o -> (o#sprite, s#emit))
        }) |> List.toMap

    // ── 粒 ──

    def wrap(v: Float64, n: Float64): Float64 = if (n <= 0.0) v else v - n * Float64.floor(v / n)

    /// 時刻 t の粒の (位置, 一辺 m)。center = カメラの追う点（地図の座標の x・y と床の高さ z）。乱数を使わず座標のハッシュで決める（毎回同じ）。
    pub def particlesAt(m: TownMap, p: Particles, t: Float64, center: (Float64, Float64, Float64)): List[(Faces.P3, Float64)] =
        let (vx, vy, vz) = p#vel;
        match p#origin {
            case Spawn.OnGround(g) =>
                let spawns = cellsOf(m) |> List.filter(cr -> TownMap.groundAt(m, fst(cr), snd(cr)) == g)
                    |> Sort.sortStableBy(cr -> TileMap3d.h01(fst(cr), snd(cr), 51)) |> List.take(p#count) |> List.toVector;
                let n = Vector.length(spawns);
                if (n == 0) Nil
                else List.range(0, p#count) |> List.map(i -> {
                    let (c, r) = Vector.get(Int32.modulo(i, n), spawns);
                    let speed = 0.6 + 0.8 * TileMap3d.h01(i, 3, 21);
                    let phase = TileMap3d.h01(i, 4, 20) * 2.0 * Num.pi();
                    let bx = Int32.toFloat64(c) + TileMap3d.h01(i, 1, 17);
                    let by = Int32.toFloat64(m#height - 1 - r) + TileMap3d.h01(i, 2, 18);
                    let bz = Int32.toFloat64(TownMap.levelAt(m, c, r)) * m#heightStep - TownMap.waterSurface();
                    let u = wrap(vz * speed * t / p#life + phase / (2.0 * Num.pi()), 1.0);
                    (Faces.p3(bx + p#sway * Num.sin(1.1 * t + phase) * u, by, bz + u * p#life), p#size * (1.0 - u))
                })
            case Spawn.AroundCamera =>
                let (bw, bd, bh) = p#box;
                let (cx, cy, cz) = center;
                List.range(0, p#count) |> List.map(i -> {
                    let speed = 0.6 + 0.8 * TileMap3d.h01(i, 3, 21);
                    let phase = TileMap3d.h01(i, 4, 20) * 2.0 * Num.pi();
                    let rx = wrap(TileMap3d.h01(i, 1, 17) * bw + vx * speed * t + p#sway * Num.sin(1.3 * t + phase), bw);
                    let ry = wrap(TileMap3d.h01(i, 2, 18) * bd + vy * speed * t, bd);
                    let rz = wrap(TileMap3d.h01(i, 3, 19) * bh + vz * speed * t, bh);
                    (Faces.p3(cx + rx - bw / 2.0, cy + p#ahead + ry - bd / 2.0, cz + rz), p#size)
                })
        }

    /// 粒の材質（決まった色で光る・光を当てない）。
    pub def particleMaterial(p: Particles): Scene3d.Material3d = solidGlow("hd2d:particle", p#color, Float64.max(1.0, p#emit))

    /// 時刻 t の粒をカメラへ向けて立てた四角（mesh = 1 × 1 m の上を向く四角）。
    pub def particleInstances(mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d, m: TownMap, p: Particles, t: Float64, center: (Float64, Float64, Float64)): List[Scene3d.Instance3d] =
        particlesAt(m, p, t, center) |> List.filter(ps -> snd(ps) > 0.001) |> List.map(ps -> {
            let (at, s) = ps;
            Scene3d.meshInstance(mesh, Mat4.mul(Mat4.translate(Vec3.v3(at#x, at#z, at#y)), Mat4.mul(Mat4.rotateX(0.0 - Num.pi() / 2.0), Mat4.scale(Vec3.v3(s, 1.0, s)))))
                |> Scene3d.withMaterial(material)
        })

    // ── 空の映り込み ──

    /// 空の映り込みの絵（正距円筒の 64 × 32・上半分は地平 → 真上の色・下半分は地平 → 地面の色）。
    pub def skyPanorama(zenith: Color, horizon: Color, ground: Color): Result[String, Texture3d.Texture3d] =
        let (w, h) = (64, 32);
        let mix = (a: Color, b: Color, u: Float64) -> Color.rgb(a#r + (b#r - a#r) * u, a#g + (b#g - a#g) * u, a#b + (b#b - a#b) * u);
        let byte = (v: Float64) -> Float64.round(Num.clamp(0.0, 1.0, v) * 255.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let argb = Vector.range(0, h) |> Vector.flatMap(row -> {
            let el = 1.0 - 2.0 * (Int32.toFloat64(row) + 0.5) / Int32.toFloat64(h);
            let c = if (el >= 0.0) mix(horizon, zenith, Float64.pow(base = el, 0.6)) else mix(horizon, ground, Float64.pow(base = 0.0 - el, 0.5));
            let px = Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(byte(c#r), 16), Int32.bitwiseOr(Int32.leftShift(byte(c#g), 8), byte(c#b))));
            Vector.range(0, w) |> Vector.map(_ -> px)
        });
        Texture3d.fromArgb(w, h, argb)
}
