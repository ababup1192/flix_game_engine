// LookDoc — night_school.look.json（光と霧と画角）の宣言ドキュメント層。
// 持つのは「暗さの調整」だけ: 環境光・距離の霧・月明かり・非常口の灯り・懐中電灯・画角・画面の字の色。
// 光をどう置くか（どの窓の月明かりを使うか・懐中電灯を目のどこに持つか）はコード（SchoolScene）。
// fail-open: 読めない・壊れているときは、その欄だけ defaults() へ落とす。
mod LookDoc {
    use fge::{Color, DocJson, JsonCodec, PostStack, Scene3d, UiDoc}
    use Util.Json.Json

    /// 点光源の種類ごとの値。every = 表の何個に 1 つを灯すか（1 で全部）。
    pub type alias Lamp = { color = Color, intensity = Float64, range = Float64, every = Int32 }

    /// 懐中電灯。fovDeg = 円錐の全体の角・innerDeg = 縁で暗くなり始める角・sway = 歩く時の揺れの大きさ（m）。
    pub type alias Flashlight = { color = Color, intensity = Float64, range = Float64, fovDeg = Float64, innerDeg = Float64, sway = Float64 }

    /// 会話の字幕。size = 字の高さ（design px。窓では 2 倍）・shadow = 右下の影の濃さ・outline = 縁取りの濃さ・band = 字の幅の帯の濃さ（0 で敷かない）・
    /// chroma = 赤と青を 1 窓 px ずらした色のにじみの濃さ・scanline = 字に掛ける走査線の濃さ・hintSize・hintAlpha = 「話す」の印の大きさ（design px）と濃さ・
    /// hintBox = 印の後ろの黒い半透明の箱の濃さ（0 で敷かない）・hintPad = 箱の字の周りの余白（design px）・
    /// maxChars = 字幕の 1 行の字数の上限（超えたら 2 行に折り返す）・lineGap = 2 行の間（design px）・bottom = 下の行の下の余白（design px）。
    pub type alias Subtitle = { size = Float64, shadow = Float64, outline = Float64, band = Float64, chroma = Float64, scanline = Float64, hintSize = Float64, hintAlpha = Float64,
                                hintBox = Float64, hintPad = Float64, maxChars = Float64, lineGap = Float64, bottom = Float64 }

    /// PS1 風の描き方（Scene3d.PsxLook）。colorDepth = 色の 1 成分のビット数（0 で切る・5 で 15 ビット）・dither = ディザの表（Doc の字は "psx" / "bayer" / "off"）・
    /// ditherStrength = ディザの強さ・vertexSnap = 頂点を丸める格子（design px・0 で切る）・affine = 床や壁の絵の歪み（0 = 遠近の補正どおり〜1 = アフィン）・
    /// compositeBlur・scanlines・chromaBleed = テレビに映したにじみ（PostStack.Crt。横のぼかし design px・走査線の濃さ・色だけの横のにじみ design px。全部 0 で掛けない）。
    pub type alias Psx = { colorDepth = Int32, dither = Scene3d.DitherPattern, ditherStrength = Float64, vertexSnap = Float64, affine = Float64,
                           compositeBlur = Float64, scanlines = Float64, chromaBleed = Float64 }

    /// 霧。目から near で掛かり始め、far で color に沈み切る。
    pub type alias Fog = { color = Color, near = Float64, far = Float64 }

    pub type alias Rec = {
        version = Int32,
        ambient = Color,
        fog = Fog,
        moon = Lamp,
        exit = Lamp,
        exitGlow = Float64,
        flashlight = Flashlight,
        fovDeg = Float64,
        hudText = Color,
        subtitle = Subtitle,
        psx = Psx
    }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/night_school.look.json"

    /// コード側の既定値（assets/night_school.look.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
                  ambient = Color.rgb(1.0, 1.0, 1.0),
                  fog = { color = Color.rgb(0.012, 0.012, 0.008), near = 5.0, far = 12.0 },
                  moon = { color = Color.rgb(0.62, 0.7, 1.0), intensity = 0.35, range = 4.5, every = 3 },
                  exit = { color = Color.rgb(0.2, 1.0, 0.45), intensity = 0.7, range = 3.5, every = 1 },
                  exitGlow = 2.5,
                  flashlight = { color = Color.rgb(1.0, 0.93, 0.8), intensity = 0.0, range = 11.0, fovDeg = 46.0, innerDeg = 16.0, sway = 0.03 },
                  fovDeg = 50.0,
                  hudText = Color.rgb(0.86, 0.84, 0.76),
                  subtitle = { size = 11.0, shadow = 0.85, outline = 0.7, band = 0.0, chroma = 0.15, scanline = 0.06, hintSize = 8.0, hintAlpha = 0.9, hintBox = 0.55, hintPad = 3.0, maxChars = 24.0, lineGap = 4.0, bottom = 10.0 },
                  psx = { colorDepth = 0, dither = Scene3d.DitherPattern.Psx, ditherStrength = 1.0, vertexSnap = 0.0, affine = 0.0,
                          compositeBlur = 0.0, scanlines = 0.0, chromaBleed = 0.0 } })

    pub def fromJson(text: String): Option[Doc] = DocJson.decodeObject(fromRoot, text)

    pub def load(p: String): Doc \ Fs.FileRead = DocJson.loadOr(fromJson, defaults(), p)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  ambient = colorOr(d#ambient, "ambient", root),
                  fog = withRecord("fog", root, d#fog, o -> { color = colorOr(d#fog#color, "color", o),
                        near = JsonCodec.floatOr("near", d#fog#near, o), far = JsonCodec.floatOr("far", d#fog#far, o) }),
                  moon = withRecord("moon", root, d#moon, lampOf(d#moon)),
                  exit = withRecord("exit", root, d#exit, lampOf(d#exit)),
                  exitGlow = JsonCodec.floatOr("exitGlow", d#exitGlow, root),
                  flashlight = withRecord("flashlight", root, d#flashlight, flashlightOf(d#flashlight)),
                  fovDeg = JsonCodec.floatOr("fovDeg", d#fovDeg, root),
                  hudText = colorOr(d#hudText, "hudText", root),
                  subtitle = withRecord("subtitle", root, d#subtitle, subtitleOf(d#subtitle)),
                  psx = withRecord("psx", root, d#psx, psxOf(d#psx)) })

    def psxOf(d: Psx): Map[String, Json] -> Psx = o ->
        { colorDepth = JsonCodec.intOr("colorDepth", d#colorDepth, o), dither = ditherOf(d#dither, o),
          ditherStrength = JsonCodec.floatOr("ditherStrength", d#ditherStrength, o),
          vertexSnap = JsonCodec.floatOr("vertexSnap", d#vertexSnap, o), affine = JsonCodec.floatOr("affine", d#affine, o),
          compositeBlur = JsonCodec.floatOr("compositeBlur", d#compositeBlur, o), scanlines = JsonCodec.floatOr("scanlines", d#scanlines, o),
          chromaBleed = JsonCodec.floatOr("chromaBleed", d#chromaBleed, o) }

    /// テレビに映したにじみ（全部 0 以下なら None）。
    pub def crtOf(p: Psx): Option[PostStack.Crt] =
        if (p#compositeBlur <= 0.0 and p#scanlines <= 0.0 and p#chromaBleed <= 0.0) None
        else Some({ compositeBlur = p#compositeBlur, scanlines = p#scanlines, chromaBleed = p#chromaBleed })

    def ditherOf(fallback: Scene3d.DitherPattern, o: Map[String, Json]): Scene3d.DitherPattern =
        match Map.get("dither", o) |> Option.flatMap(JsonCodec.expectString) {
            case Some("psx")   => Scene3d.DitherPattern.Psx
            case Some("bayer") => Scene3d.DitherPattern.Bayer4x4
            case Some("off")   => Scene3d.DitherPattern.Off
            case _             => fallback
        }

    /// Doc の値を場面の PS1 風の描き方へ。
    pub def psxLookOf(p: Psx): Scene3d.PsxLook =
        { colorDepth = p#colorDepth, dither = p#dither, ditherStrength = p#ditherStrength, vertexSnap = p#vertexSnap, affineTextureMapping = p#affine | Scene3d.psxOff() }

    def withRecord(key: String, root: Map[String, Json], fallback: a, decode: Map[String, Json] -> a): a =
        Map.get(key, root) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(decode) |> Option.getWithDefault(fallback)

    def lampOf(d: Lamp): Map[String, Json] -> Lamp = o ->
        { color = colorOr(d#color, "color", o), intensity = JsonCodec.floatOr("intensity", d#intensity, o),
          range = JsonCodec.floatOr("range", d#range, o), every = JsonCodec.intOr("every", d#every, o) }

    def flashlightOf(d: Flashlight): Map[String, Json] -> Flashlight = o ->
        { color = colorOr(d#color, "color", o), intensity = JsonCodec.floatOr("intensity", d#intensity, o),
          range = JsonCodec.floatOr("range", d#range, o), fovDeg = JsonCodec.floatOr("fovDeg", d#fovDeg, o),
          innerDeg = JsonCodec.floatOr("innerDeg", d#innerDeg, o), sway = JsonCodec.floatOr("sway", d#sway, o) }

    def subtitleOf(d: Subtitle): Map[String, Json] -> Subtitle = o ->
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, o);
        { size = num("size", d#size), shadow = num("shadow", d#shadow), outline = num("outline", d#outline), band = num("band", d#band),
          chroma = num("chroma", d#chroma), scanline = num("scanline", d#scanline), hintSize = num("hintSize", d#hintSize), hintAlpha = num("hintAlpha", d#hintAlpha),
          hintBox = num("hintBox", d#hintBox), hintPad = num("hintPad", d#hintPad),
          maxChars = num("maxChars", d#maxChars), lineGap = num("lineGap", d#lineGap), bottom = num("bottom", d#bottom) }

    def colorOr(fallbackColor: Color, key: String, obj: Map[String, Json]): Color =
        Map.get(key, obj)
            |> Option.flatMap(json -> UiDoc.colorOf(Map.empty(), key, json) |> Result.toOption)
            |> Option.getWithDefault(fallbackColor)
}
