// PostStack.Internal.Doc — post.json（schema は engine の docs/post.schema.json）を PostStack.Stack に読む。
// ゲームからは呼ばない（PostStack の中身。入口は PostStack.load / loadOr / parse）。
//
// preset が出発点で、書いた欄だけが上書き。効果の欄（bloom・vignette・colorGrade）は欄ごとに混ぜ、kind を持つ欄（viewTransform・depthOfField）は
// kind が出発点と同じ時だけ欄ごとに混ぜ、違えば丸ごと替える（書いていない欄は新しい kind の既定）。null はその効果を外す。
// kind を書かない欄は出発点の kind として混ぜる。知らない名前（preset・quality・msaa・kind）は出発点へ落として 1 行言う。数の欄に数でない物があれば Err。
pub mod PostStack.Internal.Doc {

    use IoError.IoError
    use IoError.ErrorKind
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JNull}
    use Util.Json.JsonError
    use PostStack.{Fields, Stack, StackData, Bloom, Vignette, ColorGrade, ViewTransform, DepthOfField, Quality, Msaa, Preset, Distortion, DistortionMask, HeightFog, FogNoise}

    pub def load(path: String): Result[JsonError, Stack] \ Fs.FileRead =
        DocJson.readJson(path) |> Result.flatMap(fromJson)

    pub def loadOr(fallback: Stack, path: String): Stack \ Fs.FileRead =
        let readResult = run { Fs.ReadFile.read(path) } with Fs.ReadFile.runWithFileRead;
        match readResult {
            case Err(IoError(ErrorKind.NotFound, _)) => fallback
            case Err(error) => Log.fellBackThen("post", path, "渡された Stack", "ファイルを読めません（${error}）", fallback)
            case Ok(text) => match parse(text) {
                case Ok(s)  => s
                case Err(e) => Log.fellBackThen("post", path, "渡された Stack", "${e}", fallback)
            }
        }

    pub def parse(text: String): Result[JsonError, Stack] =
        DocJson.parse(String.trim(text))
            |> Option.toOk(err("JSON として読めません"))
            |> Result.flatMap(fromJson)

    def fromJson(json: Json): Result[JsonError, Stack] =
        forM (top <- DocJson.asObject("post.json", json);
              _ <- DocJson.checkVersion("post", top);
              f <- fieldsFrom(top))
        yield StackData.StackData(f)

    def err(why: String): JsonError = DocJson.jsonError(DocJson.PathTag.Root, Set#{ "post.json: " + why })

    def fieldsFrom(top: Map[String, Json]): Result[JsonError, Fields] =
        let start = presetFrom(top);
        forM (exposure <- numOr("exposure", start#exposure, top);
              vt <- viewTransformFrom(Map.get("viewTransform", top), start#viewTransform);
              bloom <- effectFrom("bloom", bloomFrom, PostStack.bloom(), top, start#bloom);
              vignette <- effectFrom("vignette", vignetteFrom, PostStack.vignette(), top, start#vignette);
              grade <- effectFrom("colorGrade", gradeFrom, PostStack.colorGrade(), top, start#colorGrade);
              dof <- dofFrom(Map.get("depthOfField", top), start#depthOfField);
              fxaa <- boolOr("fxaa", start#fxaa, top);
              distortion <- effectFrom("distortion", distortionFrom, PostStack.distortion(), top, start#distortion);
              heightFog <- effectFrom("heightFog", heightFogFrom, PostStack.heightFog(), top, start#heightFog);
              crt <- effectFrom("crt", crtFrom, PostStack.crt(), top, start#crt))
        yield { exposure = exposure, viewTransform = vt, bloom = bloom, vignette = vignette, colorGrade = grade, depthOfField = dof, fxaa = fxaa, distortion = distortion,
                heightFog = heightFog, crt = crt,
                quality = qualityFrom(top, start#quality), msaa = msaaFrom(top, start#msaa) | start }

    // ── 名前の欄 ──

    def presetFrom(top: Map[String, Json]): Fields =
        let name = match Map.get("preset", top) {
            case None    => "Neutral"
            case Some(j) => JsonCodec.expectString(j) |> Option.getWithDefault("（字でない値）")
        };
        let found = PostStack.presets() |> List.find(pr -> "${pr}" == name);
        let chosen = match found {
            case Some(pr) => pr
            case None     => Log.fellBackThen("post", "preset ${name}", "Neutral", "知らない preset", Preset.Neutral)
        };
        PostStack.fieldsOf(PostStack.preset(chosen))

    def qualityFrom(top: Map[String, Json], start: Quality): Quality =
        match Map.get("quality", top) |> Option.flatMap(JsonCodec.expectString) {
            case None           => start
            case Some("Auto")   => Quality.Auto
            case Some("Low")    => Quality.Low
            case Some("Medium") => Quality.Medium
            case Some("High")   => Quality.High
            case Some(other)    => Log.fellBackThen("post", "quality ${other}", "出発点の quality", "知らない quality", start)
        }

    def msaaFrom(top: Map[String, Json], start: Msaa): Msaa =
        match Map.get("msaa", top) |> Option.flatMap(JsonCodec.expectString) {
            case None        => start
            case Some("Off") => Msaa.Off
            case Some("X4")  => Msaa.X4
            case Some(other) => Log.fellBackThen("post", "msaa ${other}", "${start}", "知らない msaa", start)
        }

    // ── 数の欄 ──

    def numOr(key: String, fallback: Float64, m: Map[String, Json]): Result[JsonError, Float64] = match Map.get(key, m) {
        case None    => Ok(fallback)
        case Some(j) => JsonCodec.expectFloat(j) |> Option.toOk(err("${key} は数で書く"))
    }

    def boolOr(key: String, fallback: Bool, m: Map[String, Json]): Result[JsonError, Bool] = match Map.get(key, m) {
        case None    => Ok(fallback)
        case Some(j) => JsonCodec.expectBool(j) |> Option.toOk(err("${key} は true か false で書く"))
    }

    def rgbOr(key: String, fallback: Color, m: Map[String, Json]): Result[JsonError, Color] = match Map.get(key, m) {
        case None             => Ok(fallback)
        case Some(JArray(v))  => match Vector.toList(v) |> List.map(JsonCodec.expectFloat) {
            case Some(r) :: Some(g) :: Some(b) :: Nil => Ok({ r = r, g = g, b = b })
            case _                                    => Err(err("${key} は [r, g, b] の数 3 つで書く"))
        }
        case Some(_)          => Err(err("${key} は [r, g, b] の数 3 つで書く"))
    }

    // ── 効果の欄 ──

    /// key の効果: 書いていなければ start・null なら外す・object なら start（無ければ既定）に欄ごとに混ぜる。
    def effectFrom(key: String, decode: (Map[String, Json], a) -> Result[JsonError, a], fresh: a, top: Map[String, Json], start: Option[a]): Result[JsonError, Option[a]] =
        match Map.get(key, top) {
            case None             => Ok(start)
            case Some(JNull)      => Ok(None)
            case Some(JObject(m)) => decode(m, Option.getWithDefault(fresh, start)) |> Result.map(Some)
            case Some(_)          => Err(err("${key} は object か null で書く"))
        }

    def bloomFrom(m: Map[String, Json], b: Bloom): Result[JsonError, Bloom] =
        forM (threshold <- numOr("threshold", b#threshold, m); smoothness <- numOr("smoothness", b#smoothness, m);
              size <- numOr("size", b#size, m); strength <- numOr("strength", b#strength, m))
        yield { threshold = threshold, smoothness = smoothness, size = size, strength = strength }

    def crtFrom(m: Map[String, Json], c: PostStack.Crt): Result[JsonError, PostStack.Crt] =
        forM (blur <- numOr("compositeBlur", c#compositeBlur, m); lines <- numOr("scanlines", c#scanlines, m); bleed <- numOr("chromaBleed", c#chromaBleed, m))
        yield { compositeBlur = blur, scanlines = lines, chromaBleed = bleed }

    def vignetteFrom(m: Map[String, Json], v: Vignette): Result[JsonError, Vignette] =
        forM (strength <- numOr("strength", v#strength, m); inner <- numOr("inner", v#inner, m); outer <- numOr("outer", v#outer, m);
              cx <- centerOr(0, v#center#x, m); cy <- centerOr(1, v#center#y, m))
        yield { strength = strength, inner = inner, outer = outer, center = { x = cx, y = cy } }

    def centerOr(index: Int32, fallback: Float64, m: Map[String, Json]): Result[JsonError, Float64] = match Map.get("center", m) {
        case None            => Ok(fallback)
        case Some(JArray(v)) => Vector.nth(index, v) |> Option.flatMap(JsonCodec.expectFloat) |> Option.toOk(err("vignette.center は [x, y] の数 2 つで書く"))
        case Some(_)         => Err(err("vignette.center は [x, y] の数 2 つで書く"))
    }

    def gradeFrom(m: Map[String, Json], c: ColorGrade): Result[JsonError, ColorGrade] =
        forM (lift <- rgbOr("lift", c#lift, m); gamma <- rgbOr("gamma", c#gamma, m); gain <- rgbOr("gain", c#gain, m);
              saturation <- numOr("saturation", c#saturation, m))
        yield { lift = lift, gamma = gamma, gain = gain, saturation = saturation }

    def distortionFrom(m: Map[String, Json], d: Distortion): Result[JsonError, Distortion] =
        forM (sx <- pairOr("distortion.strength", 0, d#strength#x, Map.get("strength", m));
              sy <- pairOr("distortion.strength", 1, d#strength#y, Map.get("strength", m));
              size <- numOr("noiseSize", d#noiseSize, m);
              vx <- pairOr("distortion.speed", 0, d#speed#x, Map.get("speed", m));
              vy <- pairOr("distortion.speed", 1, d#speed#y, Map.get("speed", m));
              mask <- maskFrom(Map.get("mask", m), d#mask))
        yield { strength = { x = sx, y = sy }, noiseSize = size, speed = { x = vx, y = vy }, mask = mask }

    def heightFogFrom(m: Map[String, Json], h: HeightFog): Result[JsonError, HeightFog] =
        forM (color <- rgbOr("color", h#color, m); density <- numOr("density", h#density, m); base <- numOr("baseHeight", h#baseHeight, m);
              falloff <- numOr("heightFalloff", h#heightFalloff, m); start <- numOr("startDistance", h#startDistance, m);
              maxOpacity <- numOr("maxOpacity", h#maxOpacity, m); glow <- numOr("lightGlow", h#lightGlow, m);
              noise <- effectFrom("noise", fogNoiseFrom, PostStack.fogNoise(), m, h#noise))
        yield { color = color, density = density, baseHeight = base, heightFalloff = falloff, startDistance = start, maxOpacity = maxOpacity,
                noise = noise, lightGlow = glow }

    def fogNoiseFrom(m: Map[String, Json], n: FogNoise): Result[JsonError, FogNoise] =
        forM (size <- numOr("size", n#size, m); amount <- numOr("amount", n#amount, m);
              sx <- pairOr("heightFog.noise.speed", 0, n#speed#x, Map.get("speed", m));
              sz <- pairOr("heightFog.noise.speed", 1, n#speed#y, Map.get("speed", m)))
        yield { size = size, amount = amount, speed = { x = sx, y = sz } }

    def pairOr(key: String, index: Int32, fallback: Float64, json: Option[Json]): Result[JsonError, Float64] = match json {
        case None            => Ok(fallback)
        case Some(JArray(v)) => Vector.nth(index, v) |> Option.flatMap(JsonCodec.expectFloat) |> Option.toOk(err("${key} は [x, y] の数 2 つで書く"))
        case Some(_)         => Err(err("${key} は [x, y] の数 2 つで書く"))
    }

    /// mask は kind で丸ごと決める（BottomBand は kind が出発点と同じ時だけ欄ごとに混ぜる）。
    def maskFrom(json: Option[Json], start: DistortionMask): Result[JsonError, DistortionMask] = match json {
        case None             => Ok(start)
        case Some(JObject(m)) => maskOfObject(m, start)
        case Some(_)          => Err(err("distortion.mask は object で書く"))
    }

    def maskOfObject(m: Map[String, Json], start: DistortionMask): Result[JsonError, DistortionMask] =
        let band = bandOf(start);
        match kindOf(m) {
            case Some("Full")       => Ok(DistortionMask.Full)
            case Some("BottomBand") =>
                forM (top <- numOr("top", band#top, m); soft <- numOr("soft", band#soft, m))
                yield DistortionMask.BottomBand({ top = top, soft = soft })
            case Some("Texture")    =>
                Map.get("name", m) |> Option.flatMap(JsonCodec.expectString) |> Option.map(DistortionMask.Texture)
                    |> Option.toOk(err("distortion.mask の Texture は name（絵の名前）を書く"))
            case Some(other)        => Ok(Log.fellBackThen("post", "distortion.mask ${other}", "出発点の mask", "知らない kind", start))
            case None               => Err(err("distortion.mask は kind を書く"))
        }

    def bandOf(start: DistortionMask): { top = Float64, soft = Float64 } = match start {
        case DistortionMask.BottomBand(b) => b
        case _                            => { top = 0.5, soft = 0.3 }
    }

    // ── kind を持つ欄 ──

    def kindOf(m: Map[String, Json]): Option[String] = Map.get("kind", m) |> Option.flatMap(JsonCodec.expectString)

    def viewTransformFrom(json: Option[Json], start: ViewTransform): Result[JsonError, ViewTransform] = match json {
        case None             => Ok(start)
        case Some(JObject(m)) =>
            let acesStart = match start {
                case ViewTransform.AcesNarkowicz(a) => a
                case _                              => { whitePoint = 4.0, saturationAfter = 0.0 }
            };
            match kindOf(m) {
                case Some("Standard")      => Ok(ViewTransform.Standard)
                case Some("KhronosNeutral") => Ok(ViewTransform.KhronosNeutral)
                case Some("AgX")            => Ok(ViewTransform.AgX)
                case Some("AcesNarkowicz") =>
                    forM (wp <- numOr("whitePoint", acesStart#whitePoint, m); sat <- numOr("saturationAfter", acesStart#saturationAfter, m))
                    yield ViewTransform.AcesNarkowicz({ whitePoint = wp, saturationAfter = sat })
                case Some(other)           => Ok(Log.fellBackThen("post", "viewTransform ${other}", "出発点の viewTransform", "知らない kind", start))
                case None                  => match start {
                    case ViewTransform.AcesNarkowicz(_) =>
                        forM (wp <- numOr("whitePoint", acesStart#whitePoint, m); sat <- numOr("saturationAfter", acesStart#saturationAfter, m))
                        yield ViewTransform.AcesNarkowicz({ whitePoint = wp, saturationAfter = sat })
                    case _ => Ok(start)
                }
            }
        case Some(_)          => Err(err("viewTransform は object で書く"))
    }

    def dofFrom(json: Option[Json], start: Option[DepthOfField]): Result[JsonError, Option[DepthOfField]] = match json {
        case None             => Ok(start)
        case Some(JNull)      => Ok(None)
        case Some(JObject(m)) =>
            let physical = match start {
                case Some(DepthOfField.Physical(p)) => p
                case _                              => { focusDistance = 8.0, fStop = 2.8 }
            };
            let band = match start {
                case Some(DepthOfField.DepthBand(b)) => b
                case _                               => { focusDistance = 8.0, range = 16.0, band = 0.25, soft = 0.5, blur = 0.004 }
            };
            match kindOf(m) {
                case Some("Physical")  =>
                    forM (fd <- numOr("focusDistance", physical#focusDistance, m); fs <- numOr("fStop", physical#fStop, m))
                    yield Some(DepthOfField.Physical({ focusDistance = fd, fStop = fs }))
                case Some("DepthBand") =>
                    forM (fd <- numOr("focusDistance", band#focusDistance, m); range <- numOr("range", band#range, m);
                          b <- numOr("band", band#band, m); soft <- numOr("soft", band#soft, m); blur <- numOr("blur", band#blur, m))
                    yield Some(DepthOfField.DepthBand({ focusDistance = fd, range = range, band = b, soft = soft, blur = blur }))
                case Some(other)       => Ok(Log.fellBackThen("post", "depthOfField ${other}", "出発点の depthOfField", "知らない kind", start))
                case None              => match start {
                    case Some(DepthOfField.Physical(_))  => dofFrom(Some(JObject(Map.insert("kind", Json.JString("Physical"), m))), start)
                    case Some(DepthOfField.DepthBand(_)) => dofFrom(Some(JObject(Map.insert("kind", Json.JString("DepthBand"), m))), start)
                    case None                            => Err(err("depthOfField は kind を書く（出発点に奥行きのぼかしが無い）"))
                }
            }
        case Some(_)          => Err(err("depthOfField は object か null で書く"))
    }
}
