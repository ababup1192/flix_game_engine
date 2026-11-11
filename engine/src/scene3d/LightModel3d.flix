// LightModel3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 3D の光の式を 1 回だけ書く小さな式の木と、その出口（GL のシェーダーの字・CPU の描き手が使う Flix のソース）。
///
/// 式（木は下を足す順まで写す。CPU の描き手は生成した SoftRaster3dLight でこの木をそのまま回す）:
///
///   light  = toon(ambient + hemisphere × max(0, n.y) + Σ 点光源 + Σ スポット + 太陽)
///   太陽   = SunColor × facing × sunLit                        SunColor = color × intensity・facing = clamp01(wrap + n·l)・l = 点から太陽への向き（SunDirection）
///   sunLit = n·l > 0 かつ影の地図がある時だけ 1 − strength × fade × (1 − 照らされる割合)（ほかは 1。木の外で画素ごとに 1 回。Scene3d.directionalShadowOf）
///   点光源 = color × intensity × att × facing
///   スポット = color × intensity × att × facing × cone × shadowLit
///   att    = (max(0, 1 − d² / max(range², 1e−12)))²            d = 光の位置 − 点・range² = max(range, 1e−6)²
///   facing = clamp01(wrap + n·l)                               l = d / |d|（|d|² < 1e−24 なら 0）
///   cone   = smoothstep(outerCos, innerCos, −(l·spotDir))        縁の cos は Scene3d.spotConeOf
///   shadowLit = att × facing と cone が共に正の時だけ地図を引く（ほかは 1）
///   toon   = toonSteps > 0 なら各成分を floor(x × steps + 0.5) / steps
///   lightmap つき: toon(baked + Σ 点光源 + Σ スポット)・baked = linearToSrgb(max(0, toLinear(s) × intensity))
///   fog    = c + (fogColor − c) × clamp01((|点 − 目| − near) / max(far − near, 1e−6))（fog が無い時は呼ぶ側が c のまま返す）
///   空     = horizon + (toward − horizon) × min(1, |dir.y|^curve)・toward = dir.y ≥ 0 なら zenith、ほかは ground
///
/// metallic と roughness を持つ材質（pbrModel）の色は、上の light を入力にして次の順で足す（かすみと emission はこの後に今までどおり）:
///   色     = albedo × (1 − metallic) × light + Σ 鏡面（点光源・スポット）+ 太陽の鏡面 + 映り込み        albedo = 材質の色 × tint（線形の量）
///   鏡面   = color × intensity × att × cone × shadowLit × F × D × G / (4 × n·v)           n·l は D × G × F / (4 × n·l × n·v) の n·l と相殺して消す
///   太陽の鏡面 = SunColor × sunLit × F × D × G / (4 × n·v)（facing が正の時だけ。lightmap の面にも足す）
///   α      = max(roughness², 0.002)・D = α² / (π × ((n·h)² × (α² − 1) + 1)²)・G = G1(n·l) × G1(n·v)・G1(x) = x / (x × (1 − α / 2) + α / 2)
///   F      = F0 + (1 − F0) × (1 − v·h)^5・F0 = mix(0.04, albedo, metallic)             h = normalize(l + v)・v = 目への向き
///   映り込み = 空(normalize(mix(r, n, roughness²))) × (F0 + (max(1 − roughness, F0) − F0) × (1 − n·v)^5)    r = reflect(−v, n)
///            （粗いほど向きを法線へ寄せる。空の全体の平均へ寄せると、粗い金属が明るく平たく見える）
///   環境マップがあれば（ScalarInput.EnvironmentOn = 1）、映り込みの「空(…)」は環境マップの色 EnvironmentColor に替わる:
///     EnvironmentColor = toLinear(絵(environmentUvOf(d), 段 = roughness × (段の数 − 1))) × 強さ・d = environmentDirection
///     d = 箱が無ければ normalize(mix(r, n, roughness²))・箱があれば p + t × (その向き) の box.center からの向き（t = 向かう側の面までの距離を軸ごとに測った最小・0 以上）
///   toon は light だけに掛かり、鏡面と映り込みは段付けしない。lightmap の面も鏡面と映り込みは同じに足す（ベイクした光は拡散の側）。
///
/// 木の外に置く物（2 つの描き手がそれぞれ書く）: 絵を読む所（lightmap の段つきの読み・法線マップの絵・環境マップの絵）・法線マップの TBN・
/// 影の地図の PCF（スポットの ShadowLit・太陽の SunLit）・裏の面の法線の反転。木はその結果を入力（Vec3Input.Normal・LightmapColor・ScalarInput.ShadowLit・SunLit）として受ける。
/// 光を色に掛ける所（色 = 頂点の色か albedo × tint × light）と、かすみの後に emission を足す所は、metallic と roughness を持たない面では木の外（呼ぶ側が書く）。
/// 持つ面は光を掛ける所まで pbrModel（木の中）が決め、かすみと emission は呼ぶ側が同じに続ける。
// WhyNot: enum を `Vec3`・`Scalar` と名付けない — mod の中で上の `Vec3` モジュールを隠し、Vec3.v3 などが引けなくなる。
// WhyNot: 1 本の enum に vec3 とスカラーを混ぜない — Flix に GADT が無く、スカラーと vec3 を取り違えた木を型で止められない。
pub mod LightModel3d {

    /// スカラーの値の式。
    pub enum ScalarExpr with Eq {
        case Num(Float64)
        case In(ScalarInput)
        /// 光のループ（Vec3Expr.SumPoints・SumSpots）の中の、今の光の欄。
        case LightField(ScalarLightField)
        case Add(ScalarExpr, ScalarExpr)
        case Sub(ScalarExpr, ScalarExpr)
        case Mul(ScalarExpr, ScalarExpr)
        case Div(ScalarExpr, ScalarExpr)
        case Max(ScalarExpr, ScalarExpr)
        case Min(ScalarExpr, ScalarExpr)
        /// 底・指数。
        case Pow(ScalarExpr, ScalarExpr)
        case Sqrt(ScalarExpr)
        /// 1 / sqrt(x)。
        case InverseSqrt(ScalarExpr)
        case Clamp01(ScalarExpr)
        /// 下の端・上の端・x。両端が同じなら x ≥ 上の端で 1、ほかは 0（GLSL の smoothstep は値が決まらないので、端は Scene3d.spotConeOf が離す）。
        case Smoothstep(ScalarExpr, ScalarExpr, ScalarExpr)
        /// x × x + y × y + z × z の順に足す。
        case Dot(Vec3Expr, Vec3Expr)
        case Length(Vec3Expr)
        case X(Vec3Expr)
        case Y(Vec3Expr)
        case Z(Vec3Expr)
        /// 条件が真なら左、偽なら右（選ばない側は計算しない）。
        case Select(Cond, ScalarExpr, ScalarExpr)
        /// 名前・値・その名前を使える式。
        case Let(String, ScalarExpr, ScalarExpr)
        case LetVec3(String, Vec3Expr, ScalarExpr)
        case Ref(String)
    }

    /// vec3 の値の式（色・位置・向き）。成分ごとの計算は x・y・z を同じ式で回す。
    pub enum Vec3Expr with Eq {
        case Make(ScalarExpr, ScalarExpr, ScalarExpr)
        case In(Vec3Input)
        /// 光のループの中の、今の光の欄。
        case LightField(Vec3LightField)
        case Add(Vec3Expr, Vec3Expr)
        case Sub(Vec3Expr, Vec3Expr)
        case Mul(Vec3Expr, Vec3Expr)
        case Max(Vec3Expr, Vec3Expr)
        case Min(Vec3Expr, Vec3Expr)
        /// 成分ごとに × スカラー。
        case Scale(Vec3Expr, ScalarExpr)
        /// a + (b − a) × t。
        case Mix(Vec3Expr, Vec3Expr, ScalarExpr)
        /// 場面の点光源（Scene3d.maxPointLights() まで）ごとに中の式を計算し、並びの順に 0 から足す。中の式は外の Let の名前も読める（ループの外で 1 回だけ計算した値）。ループは入れ子にできない。
        case SumPoints(Vec3Expr)
        /// 場面のスポット（Scene3d.maxSpotLights() まで）ごとに中の式を計算し、並びの順に 0 から足す。中の式は外の Let の名前も読める（ループの外で 1 回だけ計算した値）。ループは入れ子にできない。
        case SumSpots(Vec3Expr)
        /// 場面の toonSteps の段に丸める（0 以下なら丸めない）。
        case Toon(Vec3Expr)
        case SrgbToLinear(Vec3Expr)
        case LinearToSrgb(Vec3Expr)
        case Select(Cond, Vec3Expr, Vec3Expr)
        case Let(String, Vec3Expr, Vec3Expr)
        case LetScalar(String, ScalarExpr, Vec3Expr)
        case Ref(String)
    }

    /// Select の条件。
    pub enum Cond with Eq {
        /// 左 > 右。
        case Greater(ScalarExpr, ScalarExpr)
        /// 左 ≥ 右。
        case AtLeast(ScalarExpr, ScalarExpr)
        /// 両方が真（左が偽なら右を見ない）。右には文の要らない式（名前・数・入力・四則と max などの組み合わせ）だけを置ける（Let・文の要る Select・Length は不可）。
        case And(Cond, Cond)
    }

    /// 画素ごと・場面ごとのスカラーの入力。
    pub enum ScalarInput with Eq, Order {
        case Hemisphere
        /// 今のスポットの光に掛ける影の割合（SumSpots の中だけ・影を落とさないスポットは 1）。
        case ShadowLit
        /// 太陽の光に掛ける影の割合（太陽の拡散と鏡面の両方が読む。影を落とさない・届く光が無い・ビルボードは 1。木の外で画素ごとに 1 回だけ求める）。
        case SunLit
        case FogNear
        case FogFar
        /// Scene3d.skyCurveOf の値。
        case SkyCurve
        /// lightmap を Srgb で読むなら 1、Linear なら 0。
        case LightmapSrgb
        case LightmapIntensity
        /// 環境マップがあれば 1、無ければ 0（pbrModel の映り込みの選び）。
        case EnvironmentOn
        /// 環境マップの箱の補正があれば 1、無ければ 0（environmentDirection の選び）。
        case EnvironmentBoxOn
    }

    /// 画素ごと・場面ごとの vec3 の入力。
    pub enum Vec3Input with Eq, Order {
        /// world の点。
        case Position
        /// 光の計算に使う法線（法線マップと裏の面の反転を当てた後・長さ 1）。
        case Normal
        case Eye
        case Ambient
        /// lightmap の絵から読んだ rgb（段つきの読みの後・0..1）。
        case LightmapColor
        /// かすみを掛ける前の色。
        case Color
        case FogColor
        /// 目から見た向き（長さ 1）。
        case SkyDirection
        case SkyZenith
        case SkyHorizon
        case SkyGround
        /// 材質の色 × tint（線形の量。pbrModel の入力）。
        case Albedo
        /// 拡散の光（lightingModel か lightmapLightingModel の値。pbrModel の入力）。
        case Light
        /// x = metallic・y = roughness（0..1。z は使わない。pbrModel の入力）。
        case MetallicRoughness
        /// 環境マップを跳ね返りの向きで読んだ色（線形の量・強さを掛けた後。pbrModel の入力。絵を読むのは木の外）。
        case EnvironmentColor
        /// 環境マップの箱（world。environmentDirection の入力）。
        case EnvironmentBoxMin
        case EnvironmentBoxMax
        case EnvironmentBoxCenter
        /// 点から太陽へ向かう向き（長さ 1。太陽が無い時は 0 — 拡散も鏡面も 0 になる）。
        case SunDirection
        /// 太陽の color × intensity（線形の量。太陽が無い時は 0）。
        case SunColor
    }

    /// 光のループの中で読めるスカラーの欄。
    pub enum ScalarLightField with Eq {
        /// max(range, 1e−6)²。
        case RangeSquared
        /// スポットの外の縁の cos。
        case OuterCos
        /// スポットの内の縁の cos。
        case InnerCos
    }

    /// 光のループの中で読める vec3 の欄。
    pub enum Vec3LightField with Eq {
        case Position
        /// color × intensity。
        case Color
        /// スポットの向き（長さ 1）。
        case Direction
    }

    // ════════════════════════════════════════════════════════
    // 式
    // ════════════════════════════════════════════════════════

    /// 光が面を回り込む量（facing の wrap）。Environment3d に欄が無いので固定。
    def wrap(): Float64 = 0.0

    /// lightmap の無い面に当たる光（ファイルの頭の light）。
    pub def lightingModel(): Vec3Expr =
        Vec3Expr.LetScalar("sky", ScalarExpr.Mul(ScalarExpr.In(ScalarInput.Hemisphere),
                                                 ScalarExpr.Max(ScalarExpr.Num(0.0), ScalarExpr.Y(Vec3Expr.In(Vec3Input.Normal)))),
            Vec3Expr.Toon(Vec3Expr.Add(Vec3Expr.Add(Vec3Expr.Add(Vec3Expr.Add(Vec3Expr.In(Vec3Input.Ambient),
                                                                 Vec3Expr.Make(ScalarExpr.Ref("sky"), ScalarExpr.Ref("sky"), ScalarExpr.Ref("sky"))),
                                                    Vec3Expr.SumPoints(pointLight())),
                                       Vec3Expr.SumSpots(spotLight())), sunLight())))

    /// lightmap のある面に当たる光（ambient と hemisphere の代わりにベイクした光を足す）。
    pub def lightmapLightingModel(): Vec3Expr =
        Vec3Expr.Toon(Vec3Expr.Add(Vec3Expr.Add(bakedLight(), Vec3Expr.SumPoints(pointLight())), Vec3Expr.SumSpots(spotLight())))

    /// 色 Color に距離のかすみを掛けた色。
    pub def fogModel(): Vec3Expr =
        let distance = ScalarExpr.Length(Vec3Expr.Sub(Vec3Expr.In(Vec3Input.Position), Vec3Expr.In(Vec3Input.Eye)));
        let near = ScalarExpr.In(ScalarInput.FogNear);
        let span = ScalarExpr.Max(ScalarExpr.Sub(ScalarExpr.In(ScalarInput.FogFar), near), ScalarExpr.Num(1.0e-6));
        Vec3Expr.Mix(Vec3Expr.In(Vec3Input.Color), Vec3Expr.In(Vec3Input.FogColor),
                     ScalarExpr.Clamp01(ScalarExpr.Div(ScalarExpr.Sub(distance, near), span)))

    /// 向き SkyDirection の空の色。
    pub def skyModel(): Vec3Expr = skyColorToward(Vec3Expr.In(Vec3Input.SkyDirection))

    /// 向き dir（長さ 1）の空の色。
    def skyColorToward(dir: Vec3Expr): Vec3Expr =
        let height = ScalarExpr.Y(dir);
        let curve = ScalarExpr.In(ScalarInput.SkyCurve);
        let up = Cond.AtLeast(height, ScalarExpr.Num(0.0));
        let toward = Vec3Expr.Select(up, Vec3Expr.In(Vec3Input.SkyZenith), Vec3Expr.In(Vec3Input.SkyGround));
        // WhyNot: 上下で別の Pow を Select で選ばない — 条件の比べが up と t で 2 回になる（生成した字に同じ比べが 2 つ出る）。
        let t = ScalarExpr.Pow(ScalarExpr.Max(height, ScalarExpr.Sub(ScalarExpr.Num(0.0), height)), curve);
        Vec3Expr.Mix(Vec3Expr.In(Vec3Input.SkyHorizon), toward, ScalarExpr.Min(ScalarExpr.Num(1.0), t))

    // ════════════════════════════════════════════════════════
    // metallic と roughness を持つ材質の色
    // ════════════════════════════════════════════════════════

    /// metallic と roughness を持つ材質の、かすみの前の色（式は頭の説明）。入力は Albedo・Light・MetallicRoughness（画素ごと）と、
    /// Position・Normal・Eye・空の 3 色と SkyCurve。空の 3 色は場面に空が無ければ ambient + hemisphere の色（reflectionSkyOf）。
    pub def pbrModel(): Vec3Expr =
        let light = Vec3Expr.In(Vec3Input.Light);
        let diffuse = Vec3Expr.Scale(Vec3Expr.Mul(Vec3Expr.In(Vec3Input.Albedo), light), ScalarExpr.Sub(ScalarExpr.Num(1.0), ScalarExpr.Ref("metallic")));
        withSurface(Vec3Expr.Add(Vec3Expr.Add(diffuse, Vec3Expr.Add(Vec3Expr.Add(Vec3Expr.SumPoints(pointSpecular()), Vec3Expr.SumSpots(spotSpecular())), sunSpecular())),
                                 skyReflection()))

    /// 面の値（metallic・roughness・α・α²・F0・目への向き v・n·v・見る側の項 viewTerm・分布の係数 dScale）を body の中で使えるようにする。
    /// 光のループの中の式は、これらをループの外で 1 回だけ計算した値として読む（光 1 本ごとに計算し直さない）。
    // WhyNot: 目への向きと n·v を画素ごとの入力にしない — 呼ぶ側（GL と CPU）が式を 2 か所に書くことになる。
    def withSurface(body: Vec3Expr): Vec3Expr =
        let n = Vec3Expr.In(Vec3Input.Normal);
        let metallicRoughness = Vec3Expr.In(Vec3Input.MetallicRoughness);
        let roughness = ScalarExpr.Ref("roughness");
        let alpha = ScalarExpr.Ref("alpha");
        let nv = ScalarExpr.Ref("nv");
        let toEye = Vec3Expr.Ref("toEye");
        let alphaSq = ScalarExpr.Ref("alphaSq");
        Vec3Expr.LetScalar("metallic", ScalarExpr.X(metallicRoughness),
        Vec3Expr.LetScalar("roughness", ScalarExpr.Y(metallicRoughness),
        Vec3Expr.LetScalar("alpha", ScalarExpr.Max(ScalarExpr.Num(minAlpha()), ScalarExpr.Mul(roughness, roughness)),
        Vec3Expr.LetScalar("alphaSq", ScalarExpr.Mul(alpha, alpha),
        Vec3Expr.Let("fZero", Vec3Expr.Mix(Vec3Expr.Make(ScalarExpr.Num(dielectricF0()), ScalarExpr.Num(dielectricF0()), ScalarExpr.Num(dielectricF0())),
                                           Vec3Expr.In(Vec3Input.Albedo), ScalarExpr.Ref("metallic")),
        Vec3Expr.Let("toEye", Vec3Expr.Sub(Vec3Expr.In(Vec3Input.Eye), Vec3Expr.In(Vec3Input.Position)),
        Vec3Expr.LetScalar("toEyeSq", ScalarExpr.Dot(toEye, toEye),
        Vec3Expr.LetScalar("invToEye", ScalarExpr.Select(Cond.Greater(ScalarExpr.Num(1.0e-24), ScalarExpr.Ref("toEyeSq")), ScalarExpr.Num(0.0),
                                                         ScalarExpr.InverseSqrt(ScalarExpr.Ref("toEyeSq"))),
        Vec3Expr.Let("v", Vec3Expr.Scale(toEye, ScalarExpr.Ref("invToEye")),
        Vec3Expr.LetScalar("nv", ScalarExpr.Max(ScalarExpr.Num(minNormalView()), ScalarExpr.Dot(n, Vec3Expr.Ref("v"))),
        Vec3Expr.LetScalar("viewTerm", ScalarExpr.Div(smithOne(nv, alpha), ScalarExpr.Mul(ScalarExpr.Num(4.0), nv)),
        Vec3Expr.LetScalar("dScale", ScalarExpr.Div(alphaSq, ScalarExpr.Num(pi())), body))))))))))))

    /// Schlick-GGX の G1(x) = x / (x × (1 − α / 2) + α / 2)。
    def smithOne(x: ScalarExpr, alpha: ScalarExpr): ScalarExpr =
        let half = ScalarExpr.Mul(ScalarExpr.Num(0.5), alpha);
        ScalarExpr.Div(x, ScalarExpr.Add(ScalarExpr.Mul(x, ScalarExpr.Sub(ScalarExpr.Num(1.0), half)), half))

    /// 映り込み（式は頭の説明）。withSurface の中で使う。環境マップがあれば絵から読んだ色（EnvironmentColor）・無ければ空の色。
    def skyReflection(): Vec3Expr =
        let nv = ScalarExpr.Ref("nv");
        let roughness = ScalarExpr.Ref("roughness");
        let fZero = Vec3Expr.Ref("fZero");
        let smooth = ScalarExpr.Sub(ScalarExpr.Num(1.0), roughness);
        let ceiling = Vec3Expr.Max(Vec3Expr.Make(smooth, smooth, smooth), fZero);
        let fresnel = Vec3Expr.Add(fZero, Vec3Expr.Scale(Vec3Expr.Sub(ceiling, fZero), fifthPower(ScalarExpr.Sub(ScalarExpr.Num(1.0), nv))));
        let sky = Vec3Expr.Let("r", reflectionDirection(), skyColorToward(Vec3Expr.Ref("r")));
        let seen = Vec3Expr.Select(Cond.Greater(ScalarExpr.In(ScalarInput.EnvironmentOn), ScalarExpr.Num(0.0)), Vec3Expr.In(Vec3Input.EnvironmentColor), sky);
        Vec3Expr.Mul(seen, fresnel)

    /// 跳ね返りの向き（長さ 1）。粗いほど向きを法線の側へ寄せる（r と n の間を roughness² でつなぎ、長さ 1 にそろえる）。withSurface の中で使う。
    def reflectionDirection(): Vec3Expr =
        let n = Vec3Expr.In(Vec3Input.Normal);
        let reflected = Vec3Expr.Sub(Vec3Expr.Scale(n, ScalarExpr.Mul(ScalarExpr.Num(2.0), ScalarExpr.Ref("nv"))), Vec3Expr.Ref("v"));
        let bent = Vec3Expr.Mix(reflected, n, ScalarExpr.Mul(ScalarExpr.Ref("roughness"), ScalarExpr.Ref("roughness")));
        normalized("q", bent)

    /// 長さ 1 にそろえた v（長さがほぼ 0 の時は 0 のまま。名前 name は一時の Let の名前）。
    def normalized(name: String, v: Vec3Expr): Vec3Expr =
        Vec3Expr.Let(name, v, Vec3Expr.Scale(Vec3Expr.Ref(name),
            ScalarExpr.InverseSqrt(ScalarExpr.Max(ScalarExpr.Dot(Vec3Expr.Ref(name), Vec3Expr.Ref(name)), ScalarExpr.Num(1.0e-12)))))

    /// 環境マップを読む向き（長さ 1・world）。入力は Position・Normal・Albedo・Eye・MetallicRoughness（pbrModel と同じ）と箱の 4 つ（EnvironmentBox…・EnvironmentBoxOn）。
    /// 箱が無ければ跳ね返りの向き。箱があれば、点から跳ね返りの向きへ伸ばした線が箱の内側の面と交わる点の、箱の center からの向き（Unity の Box Projection と同じ）。
    pub def environmentDirection(): Vec3Expr =
        withSurface(Vec3Expr.Select(Cond.Greater(ScalarExpr.In(ScalarInput.EnvironmentBoxOn), ScalarExpr.Num(0.0)),
                                    boxProjected(), reflectionDirection()))

    /// 点から跳ね返りの向きへ出る線が箱の面（向かう側の面）と交わる所までの距離 t で、箱の中の点 p + r × t の center からの向き（長さ 1）。
    /// 点が箱の外にあって t が負になる時は 0 にする（点そのものから見る）。軸に平行な線（成分が 1e−9 以下）はその軸の面に当たらない。
    def boxProjected(): Vec3Expr =
        let r = Vec3Expr.Ref("reflected");
        let hit = Vec3Expr.Add(Vec3Expr.In(Vec3Input.Position), Vec3Expr.Scale(r, ScalarExpr.Ref("reach")));
        let reach = ScalarExpr.Max(ScalarExpr.Num(0.0), ScalarExpr.Min(slabDistance(ScalarExpr.X), ScalarExpr.Min(slabDistance(ScalarExpr.Y), slabDistance(ScalarExpr.Z))));
        Vec3Expr.Let("reflected", reflectionDirection(),
        Vec3Expr.LetScalar("reach", reach,
            normalized("offset", Vec3Expr.Sub(hit, Vec3Expr.In(Vec3Input.EnvironmentBoxCenter)))))

    /// 1 軸の、点から跳ね返りの向きへ出る線が箱の面に当たるまでの距離（pick = その軸の成分を取る）。向かう側の面（成分が正なら max・負なら min）で測る。
    def slabDistance(pick: Vec3Expr -> ScalarExpr): ScalarExpr =
        let r = pick(Vec3Expr.Ref("reflected"));
        let plane = ScalarExpr.Select(Cond.Greater(r, ScalarExpr.Num(0.0)), pick(Vec3Expr.In(Vec3Input.EnvironmentBoxMax)), pick(Vec3Expr.In(Vec3Input.EnvironmentBoxMin)));
        let parallel = Cond.Greater(ScalarExpr.Num(1.0e-9), ScalarExpr.Max(r, ScalarExpr.Sub(ScalarExpr.Num(0.0), r)));
        ScalarExpr.Select(parallel, ScalarExpr.Num(1.0e30), ScalarExpr.Div(ScalarExpr.Sub(plane, pick(Vec3Expr.In(Vec3Input.Position))), r))

    /// 向き d（長さ 1）で環境マップ（正距円筒）を読む座標。u = 0.5 + atan2(d.x, −d.z) / 2π・v = 0.5 − asin(d.y) / π（v = 0 が絵の上 = 真上）。
    /// 向きは座標の約束（Scene3d の頭）のまま: 絵の真ん中（u = 0.5）が −Z・u = 0.75 が +X・u = 0 と 1 の継ぎ目が +Z。
    pub def environmentUvOf(d: Vec3.Vec3): (Float64, Float64) =
        (0.5 + Num.atan2(d#x, 0.0 - d#z) / (2.0 * pi()), 0.5 - Num.asin(Float64.max(-1.0, Float64.min(1.0, d#y))) / pi())

    /// 環境マップを読む段（roughness × 最後の段。levels = 段の数）。GLSL は Render3dGlsl.environmentSource が同じ式を書く。
    pub def environmentLodOf(roughness: Float64, levels: Int32): Float64 =
        roughness * Int32.toFloat64(Int32.max(1, levels) - 1)

    /// 点光源 1 本の鏡面（withSurface の中の光のループで使う）。
    def pointSpecular(): Vec3Expr =
        bindAttenuationAndFacing(whenReached(Cond.Greater(ScalarExpr.Ref("k"), ScalarExpr.Num(0.0)),
            specularTerm(Vec3Expr.Scale(Vec3Expr.LightField(Vec3LightField.Color), ScalarExpr.Ref("att")))))

    def spotSpecular(): Vec3Expr =
        spotGate(whenReached(Cond.And(Cond.Greater(ScalarExpr.Ref("k"), ScalarExpr.Num(0.0)), Cond.Greater(ScalarExpr.Ref("cone"), ScalarExpr.Num(0.0))),
            specularTerm(
                Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.LightField(Vec3LightField.Color), ScalarExpr.Ref("att")), ScalarExpr.Ref("cone")),
                               ScalarExpr.Ref("lit")))))

    /// 太陽の鏡面（withSurface の中。点光源・スポットと同じ式で、l = 太陽への向き・power = SunColor × SunLit）。太陽が無い時は l = 0 で facing = 0 になり、重い式を飛ばす。
    def sunSpecular(): Vec3Expr =
        Vec3Expr.Let("l", Vec3Expr.In(Vec3Input.SunDirection),
        Vec3Expr.LetScalar("facing", sunFacing(),
            whenReached(Cond.Greater(ScalarExpr.Ref("facing"), ScalarExpr.Num(0.0)),
                        specularTerm(Vec3Expr.Scale(Vec3Expr.In(Vec3Input.SunColor), ScalarExpr.In(ScalarInput.SunLit))))))

    /// 太陽の拡散（lightingModel の足し算の最後・Toon の内側）。color × intensity × facing × sunLit。lightmap の面（lightmapLightingModel）には足さない
    /// （ベイクに含めるのが普通で二重になる。鏡面は足す）。太陽が無い時は SunColor = 0 なので 0 を足すだけ。
    def sunLight(): Vec3Expr =
        Vec3Expr.LetScalar("sunFacing", sunFacing(),
            Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.In(Vec3Input.SunColor), ScalarExpr.Ref("sunFacing")), ScalarExpr.In(ScalarInput.SunLit)))

    /// 太陽の facing = clamp01(wrap + n·l)（点光源・スポットと同じ形）。
    def sunFacing(): ScalarExpr =
        ScalarExpr.Clamp01(ScalarExpr.Add(ScalarExpr.Num(wrap()), ScalarExpr.Dot(Vec3Expr.In(Vec3Input.Normal), Vec3Expr.In(Vec3Input.SunDirection))))

    /// reached が真の時だけ body を計算し、偽なら 0（光が届かない・面が光に背を向けている時に、鏡面の重い式を飛ばす。値は変わらない — facing か att か cone が 0 なら鏡面も 0）。
    def whenReached(reached: Cond, body: Vec3Expr): Vec3Expr =
        Vec3Expr.Select(reached, body, Vec3Expr.Make(ScalarExpr.Num(0.0), ScalarExpr.Num(0.0), ScalarExpr.Num(0.0)))

    /// x の 5 乗（Fresnel の項）。
    // WhyNot: Pow(x, 5) を使わない — GLSL の pow は log2 と exp2 の 2 つの重い命令で、光 1 本ごとに走る。掛け算 3 回で済む。
    def fifthPower(x: ScalarExpr): ScalarExpr =
        let a = ScalarExpr.Ref("base");
        ScalarExpr.Let("base", x, ScalarExpr.Mul(ScalarExpr.Mul(ScalarExpr.Mul(a, a), ScalarExpr.Mul(a, a)), a))

    /// 光 1 本の鏡面。power = color × intensity × att（スポットは × cone × shadowLit）。bindAttenuationAndFacing の中で、withSurface の値を読んで使う。
    def specularTerm(power: Vec3Expr): Vec3Expr =
        let n = Vec3Expr.In(Vec3Input.Normal);
        let one = ScalarExpr.Num(1.0);
        let alpha = ScalarExpr.Ref("alpha");
        let alphaSq = ScalarExpr.Ref("alphaSq");
        let h = Vec3Expr.Ref("h");
        let hSq = ScalarExpr.Ref("hSq");
        let normalized = (e: ScalarExpr) -> ScalarExpr.Max(ScalarExpr.Num(0.0), ScalarExpr.Mul(e, ScalarExpr.Ref("invH")));
        let spread = ScalarExpr.Add(ScalarExpr.Mul(ScalarExpr.Mul(ScalarExpr.Ref("nh"), ScalarExpr.Ref("nh")), ScalarExpr.Sub(alphaSq, one)), one);
        let fZero = Vec3Expr.Ref("fZero");
        let fresnel = Vec3Expr.Add(fZero, Vec3Expr.Scale(Vec3Expr.Sub(Vec3Expr.Make(one, one, one), fZero), fifthPower(ScalarExpr.Sub(one, ScalarExpr.Ref("vh")))));
        let amount = ScalarExpr.Mul(ScalarExpr.Div(ScalarExpr.Ref("dScale"), ScalarExpr.Mul(ScalarExpr.Ref("spread"), ScalarExpr.Ref("spread"))),
                                    ScalarExpr.Mul(smithOne(ScalarExpr.Ref("facing"), alpha), ScalarExpr.Ref("viewTerm")));
        Vec3Expr.Let("h", Vec3Expr.Add(Vec3Expr.Ref("l"), Vec3Expr.Ref("v")),
        Vec3Expr.LetScalar("hSq", ScalarExpr.Dot(h, h),
        Vec3Expr.LetScalar("invH", ScalarExpr.Select(Cond.Greater(ScalarExpr.Num(1.0e-24), hSq), ScalarExpr.Num(0.0), ScalarExpr.InverseSqrt(hSq)),
        Vec3Expr.LetScalar("nh", normalized(ScalarExpr.Dot(n, h)),
        Vec3Expr.LetScalar("vh", normalized(ScalarExpr.Dot(Vec3Expr.Ref("v"), h)),
        Vec3Expr.LetScalar("spread", spread,
            Vec3Expr.Scale(Vec3Expr.Mul(power, fresnel), amount)))))))

    /// α の下限（roughness 0 の鏡で D が無限にならないように）。
    def minAlpha(): Float64 = 0.002

    /// 絶縁体の F0（水・ガラス・樹脂の標準の 4%）。
    def dielectricF0(): Float64 = 0.04

    /// n·v の下限（縁で 0 割りにならないように）。
    def minNormalView(): Float64 = 1.0e-4

    def pi(): Float64 = 3.141592653589793

    /// 映り込みに使う空の 3 色（線形の量）と curve。場面に空があればその空・無ければ ambient + hemisphere の色（真っ黒にしない）。
    /// GL の uniform と CPU の描き手の引数は、この値を同じに入れる。
    pub def reflectionSkyOf(scene: Scene3d.Scene3dCmd): { zenith = Color, horizon = Color, ground = Color, curve = Float64 } =
        match scene#sky {
            case Some(sky) =>
                let f = Scene3d.skyFieldsOf(sky);
                { zenith = Texture3d.srgbToLinearColor(f#zenith), horizon = Texture3d.srgbToLinearColor(f#horizon),
                  ground = Texture3d.srgbToLinearColor(f#ground), curve = Scene3d.skyCurveOf(sky) }
            case None =>
                let a = Texture3d.srgbToLinearColor(scene#environment#ambient);
                let h = scene#environment#hemisphere;
                let c = { r = a#r + h, g = a#g + h, b = a#b + h };
                { zenith = c, horizon = c, ground = c, curve = 1.0 }
        }

    /// lightmap から読んだ値を、光の足し算に入れる線形の量へ。
    def bakedLight(): Vec3Expr =
        let s = Vec3Expr.In(Vec3Input.LightmapColor);
        let linear = Vec3Expr.Select(Cond.Greater(ScalarExpr.In(ScalarInput.LightmapSrgb), ScalarExpr.Num(0.0)), Vec3Expr.SrgbToLinear(s), s);
        let zero = Vec3Expr.Make(ScalarExpr.Num(0.0), ScalarExpr.Num(0.0), ScalarExpr.Num(0.0));
        Vec3Expr.Max(zero, Vec3Expr.Scale(linear, ScalarExpr.In(ScalarInput.LightmapIntensity)))

    def pointLight(): Vec3Expr =
        bindAttenuationAndFacing(Vec3Expr.Scale(Vec3Expr.LightField(Vec3LightField.Color), ScalarExpr.Ref("k")))

    def spotLight(): Vec3Expr =
        spotGate(Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.LightField(Vec3LightField.Color), ScalarExpr.Ref("k")), ScalarExpr.Ref("cone")),
                                ScalarExpr.Ref("lit")))

    /// スポット 1 本の cone と shadowLit を、bindAttenuationAndFacing の名前に足して body の中で使えるようにする。
    def spotGate(body: Vec3Expr): Vec3Expr =
        let cone = ScalarExpr.Smoothstep(ScalarExpr.LightField(ScalarLightField.OuterCos), ScalarExpr.LightField(ScalarLightField.InnerCos),
                                         ScalarExpr.Sub(ScalarExpr.Num(0.0), ScalarExpr.Dot(Vec3Expr.Ref("l"), Vec3Expr.LightField(Vec3LightField.Direction))));
        // WhyNot: 地図をいつも引かない — 掛ける先が 0 なので結果は同じで、pcf の (2r+1)² 回が無駄になる。
        let lit = ScalarExpr.Select(Cond.And(Cond.Greater(ScalarExpr.Ref("k"), ScalarExpr.Num(0.0)), Cond.Greater(ScalarExpr.Ref("cone"), ScalarExpr.Num(0.0))),
                                    ScalarExpr.In(ScalarInput.ShadowLit), ScalarExpr.Num(1.0));
        bindAttenuationAndFacing(Vec3Expr.LetScalar("cone", cone, Vec3Expr.LetScalar("lit", lit, body)))

    /// 今の光から点へ届く量 k = att × facing と、点から光への向き l（長さ 1）を body の中で使えるようにする。
    // WhyNot: 向きを Sqrt で長さを出してから 1 / 長さ で求めない — GL で sqrt と割り算の 2 つになり、光 1 本ごとに重い演算が 1 つ増える
    //   （fragment の重い部屋の窓で 1 コマの時間が約 7% 増えた）。InverseSqrt は GL の inversesqrt 1 つ。
    def bindAttenuationAndFacing(body: Vec3Expr): Vec3Expr =
        let dSq = ScalarExpr.Ref("dSq");
        let falloff = ScalarExpr.Max(ScalarExpr.Num(0.0), ScalarExpr.Sub(ScalarExpr.Num(1.0),
                       ScalarExpr.Div(dSq, ScalarExpr.Max(ScalarExpr.LightField(ScalarLightField.RangeSquared), ScalarExpr.Num(1.0e-12)))));
        Vec3Expr.Let("d", Vec3Expr.Sub(Vec3Expr.LightField(Vec3LightField.Position), Vec3Expr.In(Vec3Input.Position)),
        Vec3Expr.LetScalar("dSq", ScalarExpr.Dot(Vec3Expr.Ref("d"), Vec3Expr.Ref("d")),
        Vec3Expr.LetScalar("falloff", falloff,
        Vec3Expr.LetScalar("att", ScalarExpr.Mul(ScalarExpr.Ref("falloff"), ScalarExpr.Ref("falloff")),
        Vec3Expr.LetScalar("inv", ScalarExpr.Select(Cond.Greater(ScalarExpr.Num(1.0e-24), dSq), ScalarExpr.Num(0.0), ScalarExpr.InverseSqrt(dSq)),
        Vec3Expr.Let("l", Vec3Expr.Scale(Vec3Expr.Ref("d"), ScalarExpr.Ref("inv")),
        Vec3Expr.LetScalar("facing", ScalarExpr.Clamp01(ScalarExpr.Add(ScalarExpr.Num(wrap()), ScalarExpr.Dot(Vec3Expr.In(Vec3Input.Normal), Vec3Expr.Ref("l")))),
        Vec3Expr.LetScalar("k", ScalarExpr.Mul(ScalarExpr.Ref("att"), ScalarExpr.Ref("facing")), body))))))))

    // ════════════════════════════════════════════════════════
    // CPU の描き手へ渡す光の並び
    // ════════════════════════════════════════════════════════

    /// 点光源 1 本の欄の数（位置 3・color × intensity 3・range²）。
    pub def pointStride(): Int32 = 7

    /// スポット 1 本の欄の数（位置 3・向き 3・外の cos・内の cos・color × intensity 3・range²）。
    pub def spotStride(): Int32 = 12

    /// 点光源を 1 本の Vector に並べた物（1 本 = pointStride() 個）。生成した SoftRaster3dLight の点光源の輪が読む。
    // WhyNot: 光をレコードの列のまま画素ごとに読ませない — レコードの欄は名前で引くので、画素 × 光の数だけ重くなる。
    pub def packPointLights(lights: List[Scene3d.PointLight]): Vector[Float64] =
        lights |> List.flatMap(l ->
            l#position#x :: l#position#y :: l#position#z ::
            l#color#r * l#intensity :: l#color#g * l#intensity :: l#color#b * l#intensity ::
            rangeSquared(l#range) :: Nil) |> List.toVector

    /// スポットを 1 本の Vector に並べた物（1 本 = spotStride() 個）。
    pub def packSpotLights(lights: List[Scene3d.SpotLight]): Vector[Float64] =
        lights |> List.flatMap(l -> {
            let dir = Vec3.normalized(Vec3.sub(l#target, l#position));
            let edge = Scene3d.spotConeOf(l);
            l#position#x :: l#position#y :: l#position#z :: dir#x :: dir#y :: dir#z ::
            edge#outerCos :: edge#innerCos ::
            l#color#r * l#intensity :: l#color#g * l#intensity :: l#color#b * l#intensity ::
            rangeSquared(l#range) :: Nil
        }) |> List.toVector

    def rangeSquared(range: Float64): Float64 =
        let r = Float64.max(range, 1.0e-6);
        r * r

    /// 光の種類。
    enum LightKind with Eq, Order {
        case Point
        case Spot
    }

    def strideOf(kind: LightKind): Int32 = match kind {
        case LightKind.Point => pointStride()
        case LightKind.Spot  => spotStride()
    }

    /// 欄の並びの中の位置（その種類の光に無い欄は None）。
    def vec3FieldOffset(kind: LightKind, field: Vec3LightField): Option[Int32] = match (kind, field) {
        case (LightKind.Point, Vec3LightField.Position)  => Some(0)
        case (LightKind.Point, Vec3LightField.Color)     => Some(3)
        case (LightKind.Point, Vec3LightField.Direction) => None
        case (LightKind.Spot, Vec3LightField.Position)   => Some(0)
        case (LightKind.Spot, Vec3LightField.Direction)  => Some(3)
        case (LightKind.Spot, Vec3LightField.Color)      => Some(8)
    }

    def scalarFieldOffset(kind: LightKind, field: ScalarLightField): Option[Int32] = match (kind, field) {
        case (LightKind.Point, ScalarLightField.RangeSquared) => Some(6)
        case (LightKind.Point, ScalarLightField.OuterCos)     => None
        case (LightKind.Point, ScalarLightField.InnerCos)     => None
        case (LightKind.Spot, ScalarLightField.OuterCos)      => Some(6)
        case (LightKind.Spot, ScalarLightField.InnerCos)      => Some(7)
        case (LightKind.Spot, ScalarLightField.RangeSquared)  => Some(11)
    }
}
