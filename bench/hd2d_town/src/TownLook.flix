// TownLook — 見た目のつまみの Doc（assets/town.json）を読む。無い欄は既定値で続ける。
mod TownLook {
    use fge::{Color, DocJson, JsonCodec, Log, Num, PostStack, Scene3d, Vec2}
    use Util.Json.Json
    use TownScene.{Look}

    /// 既定の値（Blender の試作の昼: 15°→50°・太陽 55°/35°・影の奥行き 40 m）。
    pub def defaults(): Look =
        { topDeg = 15.0, bottomDeg = 50.0, far = 60.0, shadowDistance = 40.0, shadowMapSize = 2048, shadowStrength = 0.8, shadowPcf = 1,
          sunElevation = 55.0, sunAzimuth = 35.0, sunIntensity = 2.2,
          ambient = Color.rgb(0.55, 0.6, 0.72), hemisphere = 0.3, boardTint = 1.0, snapToTexels = true,
          fogNear = 30.0, fogFar = 80.0, fog = Color.rgb(0.88, 0.92, 0.98), sky = Color.rgb(0.7, 0.8, 0.95),
          exposure = 0.25, bloomStrength = 0.35, fStop = 0.07, saturation = 0.85, lift = Color.rgb(1.0, 1.0, 1.0), gamma = Color.rgb(1.0, 1.0, 1.0), gain = Color.rgb(1.05, 1.0, 0.92), vignette = 0.35, fxaa = false, billboardTextures = TownScene.BillboardTextures.SceneTextures,
          sunColor = Color.rgb(1.0, 0.95, 0.86), lampIntensity = 0.0, lampRange = 7.0, lampColor = Color.rgb(1.0, 0.72, 0.42), lampGlow = 0.0,
          extraLamps = 0, groundFog = 0.0, groundFogColor = Color.rgb(0.6, 0.66, 0.8), charShadow = TownScene.CharShadow.Soft,
          heightFog = None, boardLamplight = 0.0, boardNightBase = Color.rgb(0.3, 0.33, 0.5), bloomThreshold = 0.8, bloomSize = 0.6,
          lanternCore = Color.rgb(1.0, 0.96, 0.42), lanternEdge = Color.rgb(1.0, 0.62, 0.06), haloColor = Color.rgb(1.0, 0.6, 0.08), haloSize = 1.9, haloGlow = 0.0, haloFalloff = 2.2,
          charShadowScale = Vec2.v2(1.0, 1.0), charNightBase = Color.rgb(0.3, 0.33, 0.5), charNightFar = 1.0, lightUnits = Scene3d.LightUnits.Legacy, pointShadows = None,
          boardLight = TownScene.BoardLight.Lit, glowAlpha = 1.0 }

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
          shadowStrength = num("shadowStrength", d#shadowStrength), shadowPcf = JsonCodec.intOr("shadowPcf", d#shadowPcf, m),
          sunElevation = num("sunElevation", d#sunElevation), sunAzimuth = num("sunAzimuth", d#sunAzimuth), sunIntensity = num("sunIntensity", d#sunIntensity),
          ambient = color("ambient", d#ambient), hemisphere = num("hemisphere", d#hemisphere), boardTint = num("boardTint", d#boardTint),
          snapToTexels = JsonCodec.boolOr("snapToTexels", d#snapToTexels, m),
          fogNear = num("fogNear", d#fogNear), fogFar = num("fogFar", d#fogFar), fog = color("fog", d#fog), sky = color("sky", d#sky),
          exposure = num("exposure", d#exposure), bloomStrength = num("bloomStrength", d#bloomStrength), fStop = num("fStop", d#fStop),
          saturation = num("saturation", d#saturation), lift = color("lift", d#lift), gamma = color("gamma", d#gamma), gain = color("gain", d#gain), vignette = num("vignette", d#vignette),
          fxaa = JsonCodec.boolOr("fxaa", d#fxaa, m), billboardTextures = d#billboardTextures,
          sunColor = color("sunColor", d#sunColor), lampIntensity = num("lampIntensity", d#lampIntensity), lampRange = num("lampRange", d#lampRange),
          lampColor = color("lampColor", d#lampColor), lampGlow = num("lampGlow", d#lampGlow), extraLamps = JsonCodec.intOr("extraLamps", d#extraLamps, m),
          groundFog = num("groundFog", d#groundFog), groundFogColor = color("groundFogColor", d#groundFogColor),
          charShadow = charShadowOf(JsonCodec.stringOr("charShadow", "soft", m)),
          heightFog = Map.get("heightFog", m) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(heightFogOf),
          boardLamplight = num("boardLamplight", d#boardLamplight), boardNightBase = color("boardNightBase", d#boardNightBase),
          bloomThreshold = num("bloomThreshold", d#bloomThreshold), bloomSize = num("bloomSize", d#bloomSize),
          lanternCore = color("lanternCore", d#lanternCore), lanternEdge = color("lanternEdge", d#lanternEdge), haloColor = color("haloColor", d#haloColor),
          haloSize = num("haloSize", d#haloSize), haloGlow = num("haloGlow", d#haloGlow), haloFalloff = num("haloFalloff", d#haloFalloff),
          charShadowScale = Map.get("charShadowScale", m) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
              |> Option.flatMap(xs -> match xs {
                  case x :: y :: _ => Some(Vec2.v2(x, y))
                  case _           => None
              }) |> Option.getWithDefault(d#charShadowScale),
          charNightBase = color("charNightBase", color("boardNightBase", d#boardNightBase)),
          charNightFar = num("charNightFar", d#charNightFar),
          lightUnits = if (JsonCodec.stringOr("lightUnits", "legacy", m) == "physical") Scene3d.LightUnits.Physical else Scene3d.LightUnits.Legacy,
          pointShadows = Map.get("pointShadows", m) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(pointShadowsOf),
          boardLight = if (num("boardLamplight", d#boardLamplight) > 0.0) TownScene.BoardLight.Unlit else TownScene.BoardLight.Lit,
          glowAlpha = num("glowAlpha", d#glowAlpha) }

    /// 点光源の影の欄（count = 影を落とす灯りの数・mapSize・pcf・strength・bias・normalBias。無い欄は engine の既定）。
    def pointShadowsOf(h: Map[String, Json]): Scene3d.PointShadowMap =
        let d = Scene3d.pointShadowMap();
        { maxShadowedLights = JsonCodec.intOr("count", d#maxShadowedLights, h), mapSize = JsonCodec.intOr("mapSize", d#mapSize, h),
          pcfRadius = JsonCodec.intOr("pcf", d#pcfRadius, h), strength = JsonCodec.floatOr("strength", d#strength, h),
          bias = JsonCodec.floatOr("bias", d#bias, h), normalBias = JsonCodec.floatOr("normalBias", d#normalBias, h) }

    /// 地面を這う高さの霧の欄（長さは m・speed は [x, z] の m/秒）。
    def heightFogOf(h: Map[String, Json]): PostStack.HeightFog =
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, h);
        let pair = (key: String) -> Map.get(key, h) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat));
        let color = pair("color") |> Option.flatMap(xs -> match xs {
            case r :: g :: b :: _ => Some(Color.rgb(r, g, b))
            case _                => None
        }) |> Option.getWithDefault(Color.rgb(0.32, 0.3, 0.52));
        let speed = pair("noiseSpeed") |> Option.flatMap(xs -> match xs {
            case x :: z :: _ => Some({ x = x, y = z })
            case _           => None
        }) |> Option.getWithDefault({ x = 0.6, y = 0.25 });
        { color = color, density = num("density", 0.12), baseHeight = num("baseHeight", 1.0), heightFalloff = num("heightFalloff", 1.6),
          startDistance = num("startDistance", 0.0), maxOpacity = num("maxOpacity", 0.8),
          noise = if (num("noiseSize", 6.0) > 0.0) Some({ size = num("noiseSize", 6.0), amount = num("noiseAmount", 0.7), speed = speed }) else None,
          lightGlow = num("lightGlow", 1.0) }

    /// 隊列のキャラの影の名前（silhouette・soft・dense・denseCast・smallBlob）。
    pub def charShadowOf(name: String): TownScene.CharShadow = match name {
        case "dense"     => TownScene.CharShadow.Dense
        case "denseCast" => TownScene.CharShadow.DenseCast
        case "smallBlob" => TownScene.CharShadow.SmallBlob
        case "silhouette" => TownScene.CharShadow.Silhouette
        case _           => TownScene.CharShadow.Soft
    }

    // ── 歩きながら変わる時刻（昼 → 夕方 → 夜 → 霧） ──

    /// つなぐ境目の行（地図の行・北ほど小さい）。dayToDusk・duskToNight・nightToFog = つなぎ始める行とつなぎ終える行・
    /// moonRow = 夕方 → 夜の中で、太陽が強さ 0 になって月へ替わり、街灯が点き、板が光を当てない板へ切り替わる行。
    pub type alias Rows = { dayToDusk = (Float64, Float64), duskToNight = (Float64, Float64), moonRow = Float64, nightToFog = (Float64, Float64) }

    /// 台本の timeOfDay（4 つの Look の Doc の道と境目の行）。
    pub type alias TimeOfDay = { day = String, dusk = String, night = String, fog = String, rows = Rows }

    /// 読み込んだ 4 つの Look と境目の行。
    pub type alias Schedule = { day = Look, dusk = Look, night = Look, fog = Look, rows = Rows }

    /// 台本の timeOfDay の欄を読む（無い欄は計画の 1 節の境目）。
    pub def timeOfDayOf(m: Map[String, Json]): TimeOfDay =
        let pair = (key: String, fallback: (Float64, Float64)) -> Map.get(key, m) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
            |> Option.flatMap(xs -> match xs {
                case a :: b :: _ => Some((a, b))
                case _           => None
            }) |> Option.getWithDefault(fallback);
        { day = JsonCodec.stringOr("day", "assets/town.json", m), dusk = JsonCodec.stringOr("dusk", "assets/town_dusk.json", m),
          night = JsonCodec.stringOr("night", "assets/town_night.json", m), fog = JsonCodec.stringOr("fog", "assets/town_night_fog_mid.json", m),
          rows = { dayToDusk = pair("dayToDusk", (50.0, 44.0)), duskToNight = pair("duskToNight", (36.0, 24.0)),
                   moonRow = JsonCodec.floatOr("moonRow", 29.0, m), nightToFog = pair("nightToFog", (17.0, 8.0)) } }

    /// 4 つの Look の Doc を読む（読めない Doc は loadOr のとおり既定値で続ける）。tweak = 読んだ Look に毎回掛ける差し替え。
    pub def loadSchedule(t: TimeOfDay, tweak: Look -> Look): Schedule \ Fs.FileRead =
        { day = tweak(loadOr(t#day)), dusk = tweak(loadOr(t#dusk)), night = tweak(loadOr(t#night)), fog = tweak(loadOr(t#fog)), rows = t#rows }

    def smoothstep(u: Float64): Float64 =
        let v = Num.clamp(0.0, 1.0, u);
        v * v * (3.0 - 2.0 * v)

    /// 行 startRow から行 endRow へ歩いた割合（row が startRow より南なら 0・endRow より北なら 1）。
    def progressOf(span: (Float64, Float64), row: Float64): Float64 =
        let (startRow, endRow) = span;
        Num.clamp(0.0, 1.0, (startRow - row) / Float64.max(0.000001, startRow - endRow))

    /// 先頭の行 row の Look。光の量の読み方と点光源の影は場面で 1 つ（夜の Doc の物）にそろえる。
    pub def atRow(s: Schedule, row: Float64): Look =
        let r = s#rows;
        let look =
            if (row >= fst(r#dayToDusk)) s#day
            else if (row > snd(r#dayToDusk)) blend(s#day, s#dusk, smoothstep(progressOf(r#dayToDusk, row)))
            else if (row >= fst(r#duskToNight)) s#dusk
            else if (row > snd(r#duskToNight)) nightfall(s#dusk, s#night, progressOf(r#duskToNight, row), progressOf(r#duskToNight, r#moonRow))
            else if (row >= fst(r#nightToFog)) s#night
            else if (row > snd(r#nightToFog)) blend(s#night, s#fog, smoothstep(progressOf(r#nightToFog, row)))
            else s#fog;
        { lightUnits = s#night#lightUnits, pointShadows = s#night#pointShadows | look }

    /// 2 つの Look の間を u（0 で a・1 で b）でつなぐ。場面で 1 つに決まる欄（角度・影の地図・光の量の読み方・読み込みで作った絵の色）は a の値。
    /// 板の明るさの決め方は u が 1 に届いた時だけ b に替える。
    pub def blend(a: Look, b: Look, u: Float64): Look =
        let n = (x: Float64, y: Float64) -> x + (y - x) * u;
        let c = (x: Color, y: Color) -> mixColor(x, y, u);
        { shadowDistance = n(a#shadowDistance, b#shadowDistance), shadowStrength = n(a#shadowStrength, b#shadowStrength),
          sunElevation = n(a#sunElevation, b#sunElevation), sunAzimuth = n(a#sunAzimuth, b#sunAzimuth), sunIntensity = n(a#sunIntensity, b#sunIntensity),
          sunColor = c(a#sunColor, b#sunColor), ambient = c(a#ambient, b#ambient), hemisphere = n(a#hemisphere, b#hemisphere), boardTint = n(a#boardTint, b#boardTint),
          fogNear = n(a#fogNear, b#fogNear), fogFar = n(a#fogFar, b#fogFar), fog = c(a#fog, b#fog), sky = c(a#sky, b#sky),
          exposure = n(a#exposure, b#exposure), bloomStrength = n(a#bloomStrength, b#bloomStrength), fStop = n(a#fStop, b#fStop),
          saturation = n(a#saturation, b#saturation), lift = c(a#lift, b#lift), gamma = c(a#gamma, b#gamma), gain = c(a#gain, b#gain), vignette = n(a#vignette, b#vignette),
          lampIntensity = n(a#lampIntensity, b#lampIntensity), lampRange = n(a#lampRange, b#lampRange), lampColor = c(a#lampColor, b#lampColor), lampGlow = n(a#lampGlow, b#lampGlow),
          groundFog = n(a#groundFog, b#groundFog), groundFogColor = c(a#groundFogColor, b#groundFogColor), heightFog = blendHeightFog(a#heightFog, b#heightFog, u),
          boardLamplight = n(a#boardLamplight, b#boardLamplight), boardNightBase = c(a#boardNightBase, b#boardNightBase),
          bloomThreshold = n(a#bloomThreshold, b#bloomThreshold), bloomSize = n(a#bloomSize, b#bloomSize),
          haloColor = c(a#haloColor, b#haloColor), haloGlow = n(a#haloGlow, b#haloGlow), glowAlpha = n(a#glowAlpha, b#glowAlpha),
          charShadowScale = Vec2.v2(n(a#charShadowScale#x, b#charShadowScale#x), n(a#charShadowScale#y, b#charShadowScale#y)),
          charNightBase = c(a#charNightBase, b#charNightBase), charNightFar = n(a#charNightFar, b#charNightFar),
          boardLight = if (u >= 1.0) b#boardLight else a#boardLight | a }

    def mixColor(x: Color, y: Color, u: Float64): Color =
        Color.rgb(x#r + (y#r - x#r) * u, x#g + (y#g - x#g) * u, x#b + (y#b - x#b) * u)

    /// 地面を這う霧をつなぐ。片方が None なら、もう片方の霧の濃さ 0 とみなして濃さだけつなぐ（色・落ち方・むらはある方の値）。濃さ 0 は None。
    def blendHeightFog(a: Option[PostStack.HeightFog], b: Option[PostStack.HeightFog], u: Float64): Option[PostStack.HeightFog] =
        let mix = (x: Float64, y: Float64) -> x + (y - x) * u;
        let fog = match (a, b) {
            case (Some(x), Some(y)) => Some({ density = mix(x#density, y#density), maxOpacity = mix(x#maxOpacity, y#maxOpacity), color = mixColor(x#color, y#color, u) | y })
            case (Some(x), None)    => Some({ density = mix(x#density, 0.0) | x })
            case (None, Some(y))    => Some({ density = mix(0.0, y#density) | y })
            case (None, None)       => None
        };
        fog |> Option.filter(f -> f#density > 0.0)

    /// 夕方 a から夜 b へ（x = 区間の中で歩いた割合・moon = 太陽が月へ替わる割合）。
    /// moon の手前は太陽（a の向きと色）の強さを 0 まで落とし、街灯は消したまま・板は光を当てる板。
    /// moon から先は月（b の向きと色）の強さと街灯を上げ、板は光を当てない板にして、掛け目を切り替えの瞬間の明るさから b の値へつなぐ。
    /// 霞の近い端は moon で場面の奥の端（far）まで引き、moon から先で b の値へ戻す。
    // WhyNot: 太陽の高さと向きを月の物へなめらかにつながない — 影が地面を回って見え、低い西日が真上を通って月になる。
    pub def nightfall(a: Look, b: Look, x: Float64, moon: Float64): Look =
        let base = blend(a, b, smoothstep(x));
        let clearNear = Float64.max(a#far, b#fogNear);
        let clearFar = Float64.max(clearNear + 1.0, b#fogFar);
        if (x < moon) {
            let toMoon = smoothstep(x / Float64.max(0.000001, moon));
            let fade = 1.0 - toMoon;
            // WhyNot: 霞の距離を区間全体でつながない — 光を当てない板は霞を受けず、切り替えの瞬間に遠くの森だけ霞が抜けて黒く跳ねる
            { fogNear = a#fogNear + (clearNear - a#fogNear) * toMoon, fogFar = a#fogFar + (clearFar - a#fogFar) * toMoon,
              sunElevation = a#sunElevation, sunAzimuth = a#sunAzimuth, sunColor = a#sunColor, sunIntensity = a#sunIntensity * fade,
              lampIntensity = 0.0, lampGlow = 0.0, haloGlow = 0.0, glowAlpha = 0.0, boardLamplight = 0.0, boardLight = TownScene.BoardLight.Lit | base }
        } else {
            let rise = smoothstep((x - moon) / Float64.max(0.000001, 1.0 - moon));
            let level = litLevel(blend(a, b, smoothstep(moon)));
            // WhyNot: 街灯の点光源を板と同じ立ち上がりで上げない — 街灯の板は火袋の 0.7 m 先の光を逆二乗で受け、切り替えの次のコマで赤く跳ねる
            { lampIntensity = b#lampIntensity * rise * rise,
              fogNear = clearNear + (b#fogNear - clearNear) * rise, fogFar = clearFar + (b#fogFar - clearFar) * rise,
              sunElevation = b#sunElevation, sunAzimuth = b#sunAzimuth, sunColor = b#sunColor, sunIntensity = b#sunIntensity * rise,
              lampRange = b#lampRange, lampColor = b#lampColor, lampGlow = b#lampGlow * rise, haloGlow = b#haloGlow * rise, glowAlpha = b#glowAlpha * rise,
              boardLamplight = b#boardLamplight * rise, boardLight = TownScene.BoardLight.Unlit,
              boardNightBase = mixColor(level, b#boardNightBase, rise), charNightBase = mixColor(level, b#charNightBase, rise),
              charNightFar = 1.0 + (b#charNightFar - 1.0) * rise | base }
        }

    /// 太陽も街灯も 0 の時に、光を当てる板が受ける明るさ（光を当てない板の色の掛け目・画面の値）。
    /// 立った板にはどこにでも当たる光（ambient）だけが届く。
    // WhyNot: 上を向く面の明るさ（hemisphere）を足さない — 足すと切り替えの瞬間に木とキャラが明るく跳ねた（行 29 の前後の 2 コマで測った）
    pub def litLevel(look: Look): Color = look#ambient
}
