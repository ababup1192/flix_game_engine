// LightModel3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 3D の光の式を 1 回だけ書く小さな式の木と、その出口（GL のシェーダーの字・CPU の描き手が使う Flix のソース）。
///
/// 式（木は下を足す順まで写す。CPU の描き手は生成した SoftRaster3dLight でこの木をそのまま回す）:
///
///   light  = toon(ambient + hemisphere × max(0, n.y) + Σ 点光源 + Σ スポット)
///   点光源 = color × intensity × att × facing
///   スポット = color × intensity × att × facing × cone × shadowLit
///   att    = (max(0, 1 − d² / max(range², 1e−12)))²            d = 光の位置 − 点・range² = max(range, 1e−6)²
///   facing = clamp01(wrap + n·l)                               l = d / |d|（|d| < 1e−12 なら 0）
///   cone   = smoothstep(outerCos, innerCos, −(l·spotDir))        縁の cos は Scene3d.spotConeOf
///   shadowLit = att × facing と cone が共に正の時だけ地図を引く（ほかは 1）
///   toon   = toonSteps > 0 なら各成分を floor(x × steps + 0.5) / steps
///   lightmap つき: toon(baked + Σ 点光源 + Σ スポット)・baked = linearToSrgb(max(0, toLinear(s) × intensity))
///   fog    = c + (fogColor − c) × clamp01((|点 − 目| − near) / max(far − near, 1e−6))（fog が無い時は呼ぶ側が c のまま返す）
///   空     = horizon + (toward − horizon) × min(1, |dir.y|^curve)・toward = dir.y ≥ 0 なら zenith、ほかは ground
///
/// 木の外に置く物（2 つの描き手がそれぞれ書く）: 絵を読む所（lightmap の段つきの読み・法線マップの絵）・法線マップの TBN・
/// 影の地図の PCF・裏の面の法線の反転。木はその結果を入力（Vec3Input.Normal・LightmapColor・ScalarInput.ShadowLit）として受ける。
/// 光を色に掛ける所（色 = 頂点の色か albedo × tint × light）と、かすみの後に emission を足す所も、今は木の外（呼ぶ側が書く）。
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
        /// 場面の点光源（Scene3d.maxPointLights() まで）ごとに中の式を計算し、並びの順に 0 から足す。中の式は外の Let を読めず、ループを入れ子にできない。
        case SumPoints(Vec3Expr)
        /// 場面のスポット（Scene3d.maxSpotLights() まで）ごとに中の式を計算し、並びの順に 0 から足す。中の式は外の Let を読めず、ループを入れ子にできない。
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
        case FogNear
        case FogFar
        /// Scene3d.skyCurveOf の値。
        case SkyCurve
        /// lightmap を Srgb で読むなら 1、Linear なら 0。
        case LightmapSrgb
        case LightmapIntensity
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
            Vec3Expr.Toon(Vec3Expr.Add(Vec3Expr.Add(Vec3Expr.Add(Vec3Expr.In(Vec3Input.Ambient),
                                                                 Vec3Expr.Make(ScalarExpr.Ref("sky"), ScalarExpr.Ref("sky"), ScalarExpr.Ref("sky"))),
                                                    Vec3Expr.SumPoints(pointLight())),
                                       Vec3Expr.SumSpots(spotLight()))))

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
    pub def skyModel(): Vec3Expr =
        let height = ScalarExpr.Y(Vec3Expr.In(Vec3Input.SkyDirection));
        let curve = ScalarExpr.In(ScalarInput.SkyCurve);
        let up = Cond.AtLeast(height, ScalarExpr.Num(0.0));
        let toward = Vec3Expr.Select(up, Vec3Expr.In(Vec3Input.SkyZenith), Vec3Expr.In(Vec3Input.SkyGround));
        let t = ScalarExpr.Select(up, ScalarExpr.Pow(height, curve), ScalarExpr.Pow(ScalarExpr.Sub(ScalarExpr.Num(0.0), height), curve));
        Vec3Expr.Mix(Vec3Expr.In(Vec3Input.SkyHorizon), toward, ScalarExpr.Min(ScalarExpr.Num(1.0), t))

    /// lightmap から読んだ値を、光の足し算に入れる画面の値へ。
    def bakedLight(): Vec3Expr =
        let s = Vec3Expr.In(Vec3Input.LightmapColor);
        let linear = Vec3Expr.Select(Cond.Greater(ScalarExpr.In(ScalarInput.LightmapSrgb), ScalarExpr.Num(0.0)), Vec3Expr.SrgbToLinear(s), s);
        let zero = Vec3Expr.Make(ScalarExpr.Num(0.0), ScalarExpr.Num(0.0), ScalarExpr.Num(0.0));
        Vec3Expr.LinearToSrgb(Vec3Expr.Max(zero, Vec3Expr.Scale(linear, ScalarExpr.In(ScalarInput.LightmapIntensity))))

    def pointLight(): Vec3Expr =
        bindAttenuationAndFacing(Vec3Expr.Scale(Vec3Expr.LightField(Vec3LightField.Color), ScalarExpr.Ref("k")))

    def spotLight(): Vec3Expr =
        let cone = ScalarExpr.Smoothstep(ScalarExpr.LightField(ScalarLightField.OuterCos), ScalarExpr.LightField(ScalarLightField.InnerCos),
                                         ScalarExpr.Sub(ScalarExpr.Num(0.0), ScalarExpr.Dot(Vec3Expr.Ref("l"), Vec3Expr.LightField(Vec3LightField.Direction))));
        // WhyNot: 地図をいつも引かない — 掛ける先が 0 なので結果は同じで、pcf の (2r+1)² 回が無駄になる。
        let lit = ScalarExpr.Select(Cond.And(Cond.Greater(ScalarExpr.Ref("k"), ScalarExpr.Num(0.0)), Cond.Greater(ScalarExpr.Ref("cone"), ScalarExpr.Num(0.0))),
                                    ScalarExpr.In(ScalarInput.ShadowLit), ScalarExpr.Num(1.0));
        bindAttenuationAndFacing(Vec3Expr.LetScalar("cone", cone, Vec3Expr.LetScalar("lit", lit,
            Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.Scale(Vec3Expr.LightField(Vec3LightField.Color), ScalarExpr.Ref("k")), ScalarExpr.Ref("cone")),
                           ScalarExpr.Ref("lit")))))

    /// 今の光から点へ届く量 k = att × facing と、点から光への向き l（長さ 1）を body の中で使えるようにする。
    def bindAttenuationAndFacing(body: Vec3Expr): Vec3Expr =
        let dSq = ScalarExpr.Ref("dSq");
        let falloff = ScalarExpr.Max(ScalarExpr.Num(0.0), ScalarExpr.Sub(ScalarExpr.Num(1.0),
                       ScalarExpr.Div(dSq, ScalarExpr.Max(ScalarExpr.LightField(ScalarLightField.RangeSquared), ScalarExpr.Num(1.0e-12)))));
        let len = ScalarExpr.Ref("len");
        Vec3Expr.Let("d", Vec3Expr.Sub(Vec3Expr.LightField(Vec3LightField.Position), Vec3Expr.In(Vec3Input.Position)),
        Vec3Expr.LetScalar("dSq", ScalarExpr.Dot(Vec3Expr.Ref("d"), Vec3Expr.Ref("d")),
        Vec3Expr.LetScalar("falloff", falloff,
        Vec3Expr.LetScalar("att", ScalarExpr.Mul(ScalarExpr.Ref("falloff"), ScalarExpr.Ref("falloff")),
        Vec3Expr.LetScalar("len", ScalarExpr.Sqrt(dSq),
        Vec3Expr.LetScalar("inv", ScalarExpr.Select(Cond.Greater(ScalarExpr.Num(1.0e-12), len), ScalarExpr.Num(0.0), ScalarExpr.Div(ScalarExpr.Num(1.0), len)),
        Vec3Expr.Let("l", Vec3Expr.Scale(Vec3Expr.Ref("d"), ScalarExpr.Ref("inv")),
        Vec3Expr.LetScalar("facing", ScalarExpr.Clamp01(ScalarExpr.Add(ScalarExpr.Num(wrap()), ScalarExpr.Dot(Vec3Expr.In(Vec3Input.Normal), Vec3Expr.Ref("l")))),
        Vec3Expr.LetScalar("k", ScalarExpr.Mul(ScalarExpr.Ref("att"), ScalarExpr.Ref("facing")), body)))))))))

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
