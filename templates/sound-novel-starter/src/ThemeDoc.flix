// ThemeDoc — novel.theme.json（色）の宣言ドキュメント層。写真の色は BackdropDoc の時間帯が持ち、ここは字と窓の色だけ。
// fail-open — 読めない綴りの色は既定の色のまま。
mod ThemeDoc {
    use fge::{Color, DocJson, JsonCodec}
    use Util.Json.Json

    /// ink = 本文の字、inkSeen = 既読の行の字（スキップで飛ばせる行だと分かる色）、name = 話し手の名前、
    /// accent = 選んでいる物・オートやスキップの点灯、panel = ADV の窓と選択肢の地、panelAlpha = その濃さ（0〜1）、
    /// veil = NVL の頁の下に敷く暗さ（0〜1。写真の上でも字が読める濃さ）、firefly = 蛍の光。
    pub type alias Rec = {
        version = Int32,
        ink = Color,
        inkSeen = Color,
        name = Color,
        accent = Color,
        panel = Color,
        panelAlpha = Float64,
        veil = Float64,
        firefly = Color
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.theme.json"

    def hex(code: String): Color = Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    pub def defaults(): Doc =
        Doc.Doc({ version = 1, ink = hex("#f3eee4"), inkSeen = hex("#c7d3e8"), name = hex("#e9c873"),
                  accent = hex("#e9c873"), panel = hex("#0a0e16"), panelAlpha = 0.74, veil = 0.6,
                  firefly = hex("#d9ff8c") })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let color = (key, fallback) -> Map.get(key, root) |> Option.flatMap(JsonCodec.expectString)
            |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  ink = color("ink", d#ink), inkSeen = color("inkSeen", d#inkSeen), name = color("name", d#name),
                  accent = color("accent", d#accent), panel = color("panel", d#panel),
                  panelAlpha = JsonCodec.floatOr("panelAlpha", d#panelAlpha, root),
                  veil = JsonCodec.floatOr("veil", d#veil, root),
                  firefly = color("firefly", d#firefly) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
