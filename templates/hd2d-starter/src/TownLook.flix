// TownLook — 昼の見た目の Doc（assets/town.look.json）。カメラの角度・太陽と影・空と霞・ポストプロセス。無い欄は既定値で続ける。
mod TownLook {
    use fge::{Color, DocJson, JsonCodec, PostStack, Scene3d, Vec2}
    use Util.Json.Json

    /// 見た目のつまみ。
    /// topDeg・bottomDeg = 画面の上の端・下の端で地面を見下ろす角度・far = カメラの奥の端（m）・
    /// shadowDistance・shadowStrength・shadowPcf = 太陽の影を描く奥行き（m）・影の濃さ（0〜1）・縁をならす幅（画素）・
    /// sunElevation・sunAzimuth = 太陽の高さと方位（度。方位は南 = 手前から東へ）・sunIntensity・sunColor = 太陽の強さと色・
    /// lightUnits = 光の量の読み方（Physical は逆二乗・拡散に 1/π）・ambient = どこにでも当たる光（画面の値）・hemisphere = 上を向く面ほど明るくする量・
    /// boardTint = 板（木・街灯・キャラ）の明るさの掛け目・charShadowScale = キャラの影の板の幅と高さの倍率（見えている板は変えない）・
    /// snapToTexels = 板とカメラの位置を 1 テクセルに丸めるか・fogNear・fogFar・fog = 霞（目からの距離と色）・sky = 背景の色・
    /// view・exposure・fStop・saturation・lift・gamma・gain・vignette・fxaa = ポストプロセス（曲線・露出・ピントのぼけ・彩度・暗い所 / 中間 / 明るい所の掛け目・周りを暗く・縁のならし）。
    pub type alias Rec = { topDeg = Float64, bottomDeg = Float64, far = Float64,
                           shadowDistance = Float64, shadowStrength = Float64, shadowPcf = Int32,
                           sunElevation = Float64, sunAzimuth = Float64, sunIntensity = Float64, sunColor = Color, lightUnits = Scene3d.LightUnits,
                           ambient = Color, hemisphere = Float64, boardTint = Float64, charShadowScale = Vec2.Vec2, snapToTexels = Bool,
                           fogNear = Float64, fogFar = Float64, fog = Color, sky = Color,
                           view = PostStack.ViewTransform, exposure = Float64, fStop = Float64, saturation = Float64,
                           lift = Color, gamma = Color, gain = Color, vignette = Float64, fxaa = Bool }

    pub enum Look(Rec)

    pub def rec(l: Look): Rec = match l { case Look.Look(r) => r }

    pub def path(): String = "assets/town.look.json"

    /// 既定の値（晴れた昼: 15°→50°・太陽 40°/35°）。
    pub def defaults(): Look = Look.Look(defaultRec())

    def defaultRec(): Rec =
        { topDeg = 15.0, bottomDeg = 50.0, far = 60.0, shadowDistance = 28.0, shadowStrength = 1.0, shadowPcf = 2,
          sunElevation = 40.0, sunAzimuth = 35.0, sunIntensity = 10.367, sunColor = Color.rgb(1.0, 0.95, 0.86), lightUnits = Scene3d.LightUnits.Physical,
          ambient = Color.rgb(0.15, 0.17, 0.24), hemisphere = 0.15, boardTint = 1.0, charShadowScale = Vec2.v2(0.6, 0.8), snapToTexels = true,
          fogNear = 18.0, fogFar = 70.0, fog = Color.rgb(0.88, 0.92, 0.98), sky = Color.rgb(0.7, 0.8, 0.95),
          view = PostStack.ViewTransform.AgX, exposure = -0.3, fStop = 0.08, saturation = 1.05,
          lift = Color.rgb(1.0, 1.0, 1.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = Color.rgb(1.06, 0.99, 0.88), vignette = 0.35, fxaa = true }

    /// テキストから Look へ。JSON のオブジェクトでなければ None。
    pub def fromJson(text: String): Option[Look] = DocJson.decodeObject(decode, text)

    /// path の Doc を読む。無ければ黙って既定値・読めなければ 1 行言って既定値。
    pub def load(p: String): Look \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)

    def decode(m: Map[String, Json]): Look =
        let d = defaultRec();
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, m);
        let color = (key: String, fallback: Color) -> Map.get(key, m) |> Option.flatMap(JsonCodec.expectString)
            |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback);
        let scale = (key: String, fallback: Color) -> Map.get(key, m) |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(o -> Color.rgb(JsonCodec.floatOr("r", fallback#r, o), JsonCodec.floatOr("g", fallback#g, o), JsonCodec.floatOr("b", fallback#b, o)))
            |> Option.getWithDefault(fallback);
        Look.Look({
            topDeg = num("topDeg", d#topDeg), bottomDeg = num("bottomDeg", d#bottomDeg), far = num("far", d#far),
            shadowDistance = num("shadowDistance", d#shadowDistance), shadowStrength = num("shadowStrength", d#shadowStrength),
            shadowPcf = JsonCodec.intOr("shadowPcf", d#shadowPcf, m),
            sunElevation = num("sunElevation", d#sunElevation), sunAzimuth = num("sunAzimuth", d#sunAzimuth), sunIntensity = num("sunIntensity", d#sunIntensity),
            sunColor = color("sunColor", d#sunColor),
            lightUnits = if (JsonCodec.stringOr("lightUnits", "physical", m) == "legacy") Scene3d.LightUnits.Legacy else Scene3d.LightUnits.Physical,
            ambient = color("ambient", d#ambient), hemisphere = num("hemisphere", d#hemisphere), boardTint = num("boardTint", d#boardTint),
            charShadowScale = Map.get("charShadowScale", m) |> Option.flatMap(JsonCodec.expectObject)
                |> Option.map(o -> Vec2.v2(JsonCodec.floatOr("x", d#charShadowScale#x, o), JsonCodec.floatOr("y", d#charShadowScale#y, o)))
                |> Option.getWithDefault(d#charShadowScale),
            snapToTexels = JsonCodec.boolOr("snapToTexels", d#snapToTexels, m),
            fogNear = num("fogNear", d#fogNear), fogFar = num("fogFar", d#fogFar), fog = color("fog", d#fog), sky = color("sky", d#sky),
            view = if (JsonCodec.stringOr("view", "agx", m) == "standard") PostStack.ViewTransform.Standard else PostStack.ViewTransform.AgX,
            exposure = num("exposure", d#exposure), fStop = num("fStop", d#fStop), saturation = num("saturation", d#saturation),
            lift = scale("lift", d#lift), gamma = scale("gamma", d#gamma), gain = scale("gain", d#gain), vignette = num("vignette", d#vignette),
            fxaa = JsonCodec.boolOr("fxaa", d#fxaa, m) })
}
