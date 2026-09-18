// ThemeDoc — novel.theme.json（色票）の宣言ドキュメント層と、スプライトの意味色キーを
// 実色に解決する resolver。派生色（ハイライト・窓枠）は基準色から導く（導出できる値は
// Doc に置かない）。fail-open: 読めない・壊れているときは defaults() へ落とす。
// 例外は accentLight — スプライト legend が名指しする色は Studio でも解けるよう
// assets/ui/palette.json の宣言色を優先し、無ければ従来どおり accent から導く（fail-open）。
mod ThemeDoc {
    use Util.Json.Json

    /// 場面の色票と雨の空気。bg = 部屋の闇（床・全体）、wall = 書斎の壁、
    /// window = 雨の窓、accent = 灯り・金（差し色）、ink = 本文・表紙の文字色、
    /// rainCount = 窓の雨すじの本数、rainGlow = 雨すじの明るさ（0〜1。窓色を白に近づける度合い）。
    /// accentLight は novel.theme.json ではなく assets/ui/palette.json の宣言色
    /// （スプライト legend の意味色キー。宣言が無ければ accent からの導出になる）。
    pub type alias Rec = {
        version = Int32,
        bg = Color,
        wall = Color,
        window = Color,
        accent = Color,
        accentLight = Color,
        ink = Color,
        rainCount = Int32,
        rainGlow = Float64
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.theme.json"

    /// accentLight の宣言元（Studio の色解決と同じ色票）。
    pub def palettePath(): String = "assets/ui/palette.json"

    /// 色見本の 6 桁 16 進をそのまま書くための近道。読めない綴りはマゼンタ
    /// （書き間違いが画面で目に見える）。
    def hex(code: String): Color =
        Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    /// コード側の既定値（assets/novel.theme.json と同じ色から出発する）。
    /// accentLight の既定は従来どおり accent からの導出（palette.json が上書きする）。
    pub def defaults(): Doc =
        let accent = hex("#ffc95e");
        Doc.Doc({ version = 1,
                  bg     = hex("#10101c"),   // 部屋の闇（床の底）
                  wall   = hex("#2a2438"),   // 書斎の壁
                  window = hex("#1a2333"),   // 雨の窓
                  accent = accent,           // 灯り
                  accentLight = lighten(accent, 0.5),
                  ink    = hex("#ebf0ff"),   // 本文
                  rainCount = 7,
                  rainGlow = 0.22 })

    /// テキストから Doc へ（fail-open）。色の表記（#rrggbb）は UiDoc.colorOf に委ねる。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let accent = colorOr(d#accent, "accent", root);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  bg     = colorOr(d#bg, "bg", root),
                  wall   = colorOr(d#wall, "wall", root),
                  window = colorOr(d#window, "window", root),
                  accent = accent,
                  accentLight = lighten(accent, 0.5),
                  ink    = colorOr(d#ink, "ink", root),
                  rainCount = JsonCodec.intOr("rainCount", d#rainCount, root),
                  rainGlow = JsonCodec.floatOr("rainGlow", d#rainGlow, root) })

    def colorOr(fallbackColor: Color, key: String, obj: Map[String, Json]): Color =
        Map.get(key, obj)
            |> Option.flatMap(json -> UiDoc.colorOf(Map.empty(), key, json) |> Result.toOption)
            |> Option.getWithDefault(fallbackColor)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    /// accentLight は palette.json（palettePath）の宣言があれば重ねる。
    pub def load(p: String): Doc \ Fs.FileRead =
        let doc = DocJson.loadOr(fromJson, defaults(), p);
        DocJson.loadOr(text -> Some(overlayAccentLight(text, doc)), doc, palettePath())

    /// palette.json のテキストの "accentLight" を doc に重ねる。
    /// 読めない・キーが無いときは doc のまま（fail-open = accent からの導出）。
    pub def overlayAccentLight(text: String, doc: Doc): Doc =
        DocJson.parse(String.trim(text))
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(root -> Map.get("accentLight", root))
            |> Option.flatMap(json ->
                UiDoc.colorOf(Map.empty(), "accentLight", json) |> Result.toOption)
            |> Option.map(c -> Doc.Doc({ accentLight = c | rec(doc) }))
            |> Option.getWithDefault(doc)

    // ── 派生色と resolver ──

    /// 白に近づける（ハイライト・絵があった跡・窓枠などの派生色）。
    pub def lighten(c: Color, k: Float64): Color =
        Color.lighten(c, k)

    /// 黒に近づける（床など、同じ面より奥まって見せたい派生色）。
    pub def darken(c: Color, k: Float64): Color =
        Color.darken(c, k)

    /// スプライトの意味色キー → 実色。未知のキーはマゼンタ（描き忘れが目に見える）。
    pub def resolver(doc: Doc, key: String): Color =
        match key {
            case "accent"      => rec(doc)#accent
            case "accentLight" => rec(doc)#accentLight
            case _             => { r = 1.0, g = 0.0, b = 1.0 }
        }
}
