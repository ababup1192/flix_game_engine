// LightDoc — light.json（光源の質感）の宣言ドキュメント層。
// 「暗さ・照り返しフチ・ハロの大きさ・光源の並び」を JSON に書き、Spec（pure data）へ読み取る。
// occluders（壁の遮蔽ポリゴン）は含めない — 壁はゲームの World が持つ形であって、
// json は光の質感パラメータだけを持つ、という分業のため（items へ渡す SceneLightConfig の
// occluders/viewport/glow/z はゲーム側が Spec.toConfig で自分の値を足して組み立てる）。
// light#at も json の値は初期値の扱いで、実行時は World（プレイヤー位置等）が上書きしてよい。
//
// 語彙（version 1）: トップレベルの darkness / rim / haloDiameterFactor / ambient /
// shadowStrength / lights は全て
// optional（省略時は Light.defaultXxx 相当の既定値）。色表記は ui.json と同じ
// （UiDoc.colorOf に一本化。#rrggbb / {"hsv":...} / {"rgb":...}）。
// "version" / "$schema" / "note" / "//" キーは fx.json / ui.json と同じ扱い。
//
// エラーはノードのパス付き（例: `at lights[0]: 'radius' is required`）— fx/ui と同じ流儀で
// 手書きドキュメントの編集箇所へ誘導する。
pub mod LightDoc {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JNumber}
    use Util.Json.JsonError
    use DocJson.PathTag.Root

    // ========================================================================
    // 型（pure data）
    // ========================================================================

    /// 1 光源ぶんの宣言。at は初期位置（実行時に World の値で上書きしてよい）。
    pub type alias LightSpec = { at = Vec2.Vec2, radius = Float64, color = Color, halo = Float64 }

    /// ドキュメント全体。darkness/rim/haloDiameterFactor は Light.SceneLightConfig の
    /// 同名フィールドへそのまま流し込む値。ambient/shadowStrength は光マップ方式
    /// （Light.LightMapConfig）でだけ使う値 — オーバーレイ方式の toConfig はどちらも読まない。
    pub type alias Spec = {
        darkness = Float64,
        rimWidth = Float64, rimStrength = Float64,
        haloDiameterFactor = Float64,
        ambient = Color,
        shadowStrength = Float64,
        lights = List[LightSpec],
        note = Option[String]
    }

    /// 全フィールド省略時の既定値（lights=Nil の「今は光源なし」ドキュメントも許す —
    /// FxDoc/UiDoc と違い「空文書を弾く」検査はしない。暗闇だけの演出も正当なため）。
    pub def empty(): Spec =
        { darkness = defaultDarkness(),
          rimWidth = Shadow.defaultRimWidth(), rimStrength = Shadow.defaultRimStrength(),
          haloDiameterFactor = Light.defaultHaloDiameterFactor(),
          ambient = Light.defaultAmbient(), shadowStrength = Light.defaultShadowStrength(),
          lights = Nil, note = None }

    // ========================================================================
    // parse（純粋）
    // ========================================================================

    /// ドキュメントを Spec へ読み取る。
    pub def parse(json: Json): Result[JsonError, Spec] =
        match json {
            case JObject(top) => forM (
                _v         <- DocJson.checkVersion("light document", top);
                darkness   <- DocJson.atNode("(root)", DocJson.numOr("darkness", defaultDarkness(), top));
                rim        <- parseRim(top);
                factorOpt  <- DocJson.atNode("(root)", (DocJson.getAtKeyOpt(Root, "haloDiameterFactor", top): Result[JsonError, Option[Float64]]));
                ambient    <- parseAmbient(top);
                shadowStrength <- DocJson.atNode("(root)", DocJson.numOr("shadowStrength", Light.defaultShadowStrength(), top));
                _s         <- require(shadowStrength >= 0.0 and shadowStrength <= 1.0,
                                      "shadowStrength must be within 0..1 (got: ${shadowStrength})");
                note       <- (DocJson.getAtKeyOpt(Root, "note", top): Result[JsonError, Option[String]]);
                lights     <- parseLights(top)
            ) yield ({
                darkness = darkness,
                rimWidth = rim#width, rimStrength = rim#strength,
                haloDiameterFactor = Option.getWithDefault(Light.defaultHaloDiameterFactor(), factorOpt),
                ambient = ambient, shadowStrength = shadowStrength,
                lights = lights, note = note
            }: Spec)
            case _ => Err(DocJson.jsonError(Root, Set#{"LightDoc must be a JSON object"}))
        }

    /// mask 全体の暗さの既定値（Light.SingleLightConfig の doc と同じ既定 0.95 に揃える）。
    def defaultDarkness(): Float64 = 0.95

    /// "rim": {"width": px, "strength": alpha}（省略時は Shadow.defaultRimWidth/Strength）。
    def parseRim(top: Map[String, Json]): Result[JsonError, { width = Float64, strength = Float64 }] =
        match (DocJson.getAtKeyOpt(Root, "rim", top): Result[JsonError, Option[Map[String, Json]]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok({ width = Shadow.defaultRimWidth(), strength = Shadow.defaultRimStrength() })
            case Ok(Some(m)) => DocJson.atNode("rim", forM (
                width    <- DocJson.numOr("width", Shadow.defaultRimWidth(), m);
                strength <- DocJson.numOr("strength", Shadow.defaultRimStrength(), m)
            ) yield { width = width, strength = strength })
        }

    /// "ambient": 色（省略時 Light.defaultAmbient()。光マップ方式でだけ使う環境光の色 —
    /// ambient/shadowStrength は 0.19 系で足した語彙。古いエンジンは読み飛ばして既定になる）。
    def parseAmbient(top: Map[String, Json]): Result[JsonError, Color] =
        match Map.get("ambient", top) {
            case None       => Ok(Light.defaultAmbient())
            case Some(json) => UiDoc.colorOf(Map.empty(), "ambient", json)
        }

    /// "lights": [...]（省略時は空 = 光源なし）。
    def parseLights(top: Map[String, Json]): Result[JsonError, List[LightSpec]] =
        match Map.get("lights", top) {
            case None              => Ok(Nil)
            case Some(JArray(arr)) =>
                Result.traverse(entry -> {
                    let (i, json) = entry;
                    forM (
                        m     <- DocJson.atNode("lights[${i}]", DocJson.asObject("light", json));
                        light <- parseLight("lights[${i}]", m)
                    ) yield light
                }, List.zipWithIndex(Vector.toList(arr)))
            case Some(_) => Err(DocJson.jsonError(Root, Set#{"'lights' must be an array"}))
        }

    /// 1 光源: at（必須 [x,y]）/ radius（必須）/ color（必須）/ halo（省略時 Shadow 系と
    /// 同じ「既定の目安」ではなく、光の演出値なので 0.35 を素朴な既定にする）。
    def parseLight(path: String, m: Map[String, Json]): Result[JsonError, LightSpec] =
        DocJson.atNode(path, forM (
            at      <- parseVec2("at", m);
            radius  <- DocJson.numAt("radius", m);
            _r      <- require(radius > 0.0, "radius must be > 0 (got: ${radius})");
            color   <- parseColorRequired("color", m);
            halo    <- DocJson.numOr("halo", defaultHalo(), m);
            _h      <- require(halo >= 0.0 and halo <= 1.0, "halo must be within 0..1 (got: ${halo})")
        ) yield ({ at = at, radius = radius, color = color, halo = halo }: LightSpec))

    /// halo 省略時の既定値（View.lanternLight 等の実運用値に合わせた素朴な目安）。
    def defaultHalo(): Float64 = 0.35

    def require(ok: Bool, msg: String): Result[JsonError, Unit] =
        if (ok) Ok(()) else Err(DocJson.jsonError(Root, Set#{msg}))

    /// "key": [x, y] を Vec2 へ（必須）。
    def parseVec2(key: String, m: Map[String, Json]): Result[JsonError, Vec2.Vec2] =
        match (DocJson.getAtKey(Root, key, m): Result[JsonError, List[Float64]]) {
            case Err(e)            => Err(e)
            case Ok(x :: y :: Nil) => Ok({x = x, y = y})
            case Ok(_)             => Err(DocJson.jsonError(Root, Set#{"${key} must be [x, y]"}))
        }

    /// 色（必須）。色表記は ui.json と同一 — UiDoc.colorOf に一本化（palette 参照 "@name" は
    /// light.json には無いので空パレットで呼ぶ）。
    def parseColorRequired(key: String, m: Map[String, Json]): Result[JsonError, Color] =
        match Map.get(key, m) {
            case None       => Err(DocJson.jsonError(Root, Set#{"'${key}' is required"}))
            case Some(json) => UiDoc.colorOf(Map.empty(), key, json)
        }

    // ========================================================================
    // Spec → Light.SceneLightConfig
    // ========================================================================

    /// Spec の質感パラメータに、ゲーム側が持つ occluders/viewport/glow/z を足して
    /// Light.SceneLightConfig を組む。at はゲーム側の runtimeLights で丸ごと差し替え可能
    /// （json の lights はエディタ確認用の初期値、実行中は World の光源位置が正）。
    pub def toConfig(spec: Spec, ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2,
                                        glow = Light.GlowAssets, z = Int32 }): Light.SceneLightConfig =
        { lights = List.map(lightOf, spec#lights), occluders = ctx#occluders,
          viewport = ctx#viewport, glow = ctx#glow,
          darkness = spec#darkness, z = ctx#z,
          rimWidth = spec#rimWidth, rimStrength = spec#rimStrength,
          haloDiameterFactor = spec#haloDiameterFactor }

    /// toConfig と同じだが、lights を丸ごと runtimeLights に差し替える
    /// （「json は質感、位置はゲーム」の分業口 — World が持つ光源位置をここへ渡す）。
    pub def toConfigWithLights(spec: Spec, runtimeLights: List[Light.Light],
                               ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2,
                                     glow = Light.GlowAssets, z = Int32 }): Light.SceneLightConfig =
        let base = toConfig(spec, ctx);
        { lights = runtimeLights | base }

    def lightOf(l: LightSpec): Light.Light =
        { at = l#at, radius = l#radius, color = l#color, halo = l#halo }

    // ========================================================================
    // Spec → Light.LightMapConfig（光マップ方式）
    // ========================================================================

    /// Spec の質感（ambient/shadowStrength/lights）に、ゲームが持つ occluders/viewport/
    /// passName/z を足して光マップ設定を組む。extrudeLength は Shadow.infiniteExtrude() —
    /// 影の伸ばし長さは絵の調整値ではないので Doc には出さない。
    pub def toLightMapConfig(spec: Spec,
        ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2,
               passName = String, z = Int32 }): Light.LightMapConfig =
        { lights = List.map(lightOf, spec#lights), occluders = ctx#occluders,
          viewport = ctx#viewport,
          ambient = spec#ambient, shadowStrength = spec#shadowStrength,
          extrudeLength = Shadow.infiniteExtrude(),
          passName = ctx#passName, z = ctx#z }

    /// toLightMapConfig と同じだが、lights を丸ごと runtimeLights に差し替える
    /// （toConfigWithLights と同じ「json は質感、位置はゲーム」の分業口）。
    pub def toLightMapConfigWithLights(spec: Spec, runtimeLights: List[Light.Light],
        ctx: { occluders = List[List[Vec2.Vec2]], viewport = Vec2.Vec2,
               passName = String, z = Int32 }): Light.LightMapConfig =
        let base = toLightMapConfig(spec, ctx);
        { lights = runtimeLights | base }

    // ========================================================================
    // load（ファイル読み — parse は純粋なまま、IO はここだけ）
    // ========================================================================

    /// path を読んで Spec にする。DocJson.readJson と同じ fail 経路
    /// （読めない・崩れているときは Err）。
    pub def load(path: String): Result[JsonError, Spec] \ Fs.FileRead =
        DocJson.readJson(path) |> Result.flatMap(parse)
}
