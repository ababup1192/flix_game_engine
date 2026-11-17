// TownLook — 見た目のつまみの Doc（assets/town.json）を読む。無い欄は既定値で続ける。
mod TownLook {
    use fge::{Color, DocJson, JsonCodec, Log}
    use Util.Json.Json
    use TownScene.{Look}

    /// 既定の値（Blender の試作の昼: 15°→50°・太陽 55°/35°・影の奥行き 40 m）。
    pub def defaults(): Look =
        { topDeg = 15.0, bottomDeg = 50.0, far = 60.0, shadowDistance = 40.0, shadowMapSize = 2048,
          sunElevation = 55.0, sunAzimuth = 35.0, sunIntensity = 2.2,
          ambient = Color.rgb(0.55, 0.6, 0.72), hemisphere = 0.3, boardTint = 1.0, snapToTexels = true,
          fogNear = 30.0, fogFar = 80.0, fog = Color.rgb(0.88, 0.92, 0.98), sky = Color.rgb(0.7, 0.8, 0.95),
          exposure = 0.25, bloomStrength = 0.35, fStop = 0.07, saturation = 0.85, gain = Color.rgb(1.05, 1.0, 0.92), vignette = 0.35 }

    /// path の Doc を読む。無ければ黙って既定値・読めなければ 1 行言って既定値。
    pub def loadOr(path: String): Look \ Fs.FileRead =
        match DocJson.readJson(path) {
            case Ok(json) => JsonCodec.expectObject(json) |> Option.map(decode) |> Option.getWithDefault(defaults())
            case Err(e)   => Log.fellBackThen("hd2d_town", path, "TownLook.defaults", DocJson.describe(e), defaults())
        }

    def decode(m: Map[String, Json]): Look =
        let d = defaults();
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, m);
        let color = (key: String, fallback: Color) -> Map.get(key, m) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
            |> Option.flatMap(xs -> match xs {
                case r :: g :: b :: _ => Some(Color.rgb(r, g, b))
                case _                => None
            }) |> Option.getWithDefault(fallback);
        { topDeg = num("topDeg", d#topDeg), bottomDeg = num("bottomDeg", d#bottomDeg), far = num("far", d#far),
          shadowDistance = num("shadowDistance", d#shadowDistance), shadowMapSize = JsonCodec.intOr("shadowMapSize", d#shadowMapSize, m),
          sunElevation = num("sunElevation", d#sunElevation), sunAzimuth = num("sunAzimuth", d#sunAzimuth), sunIntensity = num("sunIntensity", d#sunIntensity),
          ambient = color("ambient", d#ambient), hemisphere = num("hemisphere", d#hemisphere), boardTint = num("boardTint", d#boardTint),
          snapToTexels = JsonCodec.boolOr("snapToTexels", d#snapToTexels, m),
          fogNear = num("fogNear", d#fogNear), fogFar = num("fogFar", d#fogFar), fog = color("fog", d#fog), sky = color("sky", d#sky),
          exposure = num("exposure", d#exposure), bloomStrength = num("bloomStrength", d#bloomStrength), fStop = num("fStop", d#fStop),
          saturation = num("saturation", d#saturation), gain = color("gain", d#gain), vignette = num("vignette", d#vignette) }
}
