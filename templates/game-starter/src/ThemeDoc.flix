// ThemeDoc — __NAME__.theme.json（絵の見え方）の宣言ドキュメント層と、スプライトの
// 意味色キーを実色に解決する resolver。持つのは 2 つ: 基準の色と、ドット絵の塗りの
// 仕上げ方（PxShade）。どちらも「保存して見ながら決める」物なので同じ Doc に置く。
// 派生色（ハイライト・影）は基準色から導く（導出できる値は Doc に置かない）。
// fail-open: 読めない・壊れているときは defaults() へ落とす。
mod ThemeDoc {
    use Util.Json.Json

    // World が持つ record は enum で包む（型検査が record を展開しないため）。
    pub type alias Rec = {
        version = Int32,
        bg = Color,
        accent = Color,
        shade = PxShade.Spec
    }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/__NAME__.theme.json"

    /// コード側の既定値（assets/__NAME__.theme.json と同じ値から出発する）。
    /// 仕上げは「光は左上から・ふち光と接地影は全部・ディザは半分・粒は無し」。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
                  bg     = Color.rgb(0.066667, 0.066667, 0.101961),
                  accent = Color.rgb(0.388235, 0.690196, 1.0),
                  shade  = { rim = 1.0, contact = 1.0, dither = 0.5, grain = 0.0,
                             grainScale = 1, lightX = -1, lightY = -1 } })

    /// テキストから Doc へ（fail-open）。色の表記（#rrggbb）は UiDoc.colorOf に委ねる。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  bg     = colorOr(d#bg, "bg", root),
                  accent = colorOr(d#accent, "accent", root),
                  shade  = shadeOr(d#shade, root) })

    def colorOr(fallbackColor: Color, key: String, obj: Map[String, Json]): Color =
        Map.get(key, obj)
            |> Option.flatMap(json -> UiDoc.colorOf(Map.empty(), key, json) |> Result.toOption)
            |> Option.getWithDefault(fallbackColor)

    /// "shade" の中身を読む。欄が無ければ・壊れていればその欄だけ既定へ落とす。
    def shadeOr(fallback: PxShade.Spec, root: Map[String, Json]): PxShade.Spec =
        match Map.get("shade", root) |> Option.flatMap(JsonCodec.expectObject) {
            case None => fallback
            case Some(o) =>
                { rim        = JsonCodec.floatOr("rim", fallback#rim, o),
                  contact    = JsonCodec.floatOr("contact", fallback#contact, o),
                  dither     = JsonCodec.floatOr("dither", fallback#dither, o),
                  grain      = JsonCodec.floatOr("grain", fallback#grain, o),
                  grainScale = JsonCodec.intOr("grainScale", fallback#grainScale, o),
                  lightX     = JsonCodec.intOr("lightX", fallback#lightX, o),
                  lightY     = JsonCodec.intOr("lightY", fallback#lightY, o) }
        }

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)

    // ── 派生色と resolver ──

    /// 白に近づける（ハイライト）。
    pub def lighten(c: Color, k: Float64): Color =
        Color.lighten(c, k)

    /// スプライトの意味色キー → 実色。未知のキーはマゼンタ（描き忘れが目に見える）。
    /// accentLight / accentDark は PxShade のふち光・接地影が使う 3 段階の明暗
    /// （絵は accent 1 色で平らに塗り、明暗はここから導く）。
    pub def resolver(doc: Doc, key: String): Color =
        let accent = rec(doc)#accent;
        match key {
            case "accent"      => accent
            case "accentLight" => Color.warm(lighten(accent, 0.5), 0.15)
            case "accentDark"  => Color.cool(Color.darken(accent, 0.45), 0.15)
            case _             => { r = 1.0, g = 0.0, b = 1.0 }
        }
}
