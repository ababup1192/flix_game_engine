// ThemeDoc — novel.theme.json（字・ウィンドウの色と待ちの印）の宣言ドキュメント層。写真の色は BackdropDoc の時間帯が持つ。
// fail-open — 読めない綴りの色は既定の色のまま、知らない待ちの印は dots。
mod ThemeDoc {
    use fge::{Color, DocJson, JsonCodec, Log}
    use Util.Json.Json

    /// 素材を待つ間（ブラウザ版で背景・環境音がまだ届いていない黒の間）に出す印。Dots = 右下の金の点 3 つの明滅、
    /// Ring = 画面の真ん中に回る点の輪と字のラベル（字は novel.story.json の labels の waiting）、Hidden（JSON は "none"）= 黒の地だけ。
    pub enum LoadingMark with Eq, ToString {
        case Dots
        case Ring
        // WhyNot: JSON の "none" を None と名付けない — Option の None とぶつかり、match の腕で取り違える。
        case Hidden
    }

    /// 話し手 1 人の色。id = シナリオの話し手の id（地の文は空）、name = 人に見せる名前（空なら novel.story.json の names）、
    /// color = 名前の字（テープの頁でシナリオの行を塗る色も同じ）、ink = 本文の字。
    pub type alias Speaker = { id = String, name = String, color = Color, ink = Color }

    /// ink = 本文の字、inkSeen = 既読の行の字（スキップで飛ばせる行だと分かる色）、name = 話し手の名前、
    /// accent = 選んでいる物・オートやスキップの点灯、panel = ADV のウィンドウ・選択肢・画面の地（濃さは設定の「ウィンドウの濃さ」）、
    /// veil = NVL の頁の下に敷く幕の濃さを、ウィンドウの濃さに掛ける割合（頁は画面いっぱいなのでウィンドウより薄くしてよい）、firefly = 蛍の光、
    /// loadingMark = 素材を待つ間の印、speakers = 話し手の id → 色（無い id は name と ink の色）。
    pub type alias Rec = {
        version = Int32,
        ink = Color,
        inkSeen = Color,
        name = Color,
        accent = Color,
        panel = Color,
        veil = Float64,
        firefly = Color,
        loadingMark = LoadingMark,
        speakers = Map[String, Speaker]
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.theme.json"

    def hex(code: String): Color = Color.hex(code) |> Option.getWithDefault({ r = 1.0, g = 0.0, b = 1.0 })

    pub def defaults(): Doc =
        Doc.Doc({ version = 1, ink = hex("#f3eee4"), inkSeen = hex("#c7d3e8"), name = hex("#e9c873"),
                  accent = hex("#e9c873"), panel = hex("#0a0e16"), veil = 0.8,
                  firefly = hex("#d9ff8c"), loadingMark = LoadingMark.Dots,
                  speakers = Map#{ "" => { id = "", name = "地の文", color = hex("#e9c873"), ink = hex("#f3eee4") } } })

    /// 話し手の色（Doc に無い id は名前の色と本文の色）。
    pub def speakerOf(id: String, doc: Doc): Speaker =
        let r = rec(doc);
        Map.get(id, r#speakers) |> Option.getWithDefault({ id = id, name = "", color = r#name, ink = r#ink })

    /// "dots" / "ring" / "none" → 待ちの印（知らない字は None）。
    pub def loadingMarkOf(name: String): Option[LoadingMark] = match name {
        case "dots" => Some(LoadingMark.Dots)
        case "ring" => Some(LoadingMark.Ring)
        case "none" => Some(LoadingMark.Hidden)
        case _      => None
    }

    /// Doc の字の待ちの印。知らない字は 1 行知らせて dots（fail-open）。
    def loadingMarkOr(name: String): LoadingMark = match loadingMarkOf(name) {
        case Some(mark) => mark
        case None       => Log.warnThen("[theme] loadingMark '${name}' は知らない — dots で描く（dots / ring / none）", LoadingMark.Dots)
    }

    /// 待ちの印だけを替えた Doc。
    pub def withLoadingMark(mark: LoadingMark, doc: Doc): Doc = Doc.Doc({ loadingMark = mark | rec(doc) })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let color = (key, fallback) -> Map.get(key, root) |> Option.flatMap(JsonCodec.expectString)
            |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  ink = color("ink", d#ink), inkSeen = color("inkSeen", d#inkSeen), name = color("name", d#name),
                  accent = color("accent", d#accent), panel = color("panel", d#panel),
                  veil = JsonCodec.floatOr("veil", d#veil, root),
                  firefly = color("firefly", d#firefly),
                  loadingMark = loadingMarkOr(JsonCodec.stringOr("loadingMark", "dots", root)),
                  speakers = Map.get("speakers", root) |> Option.map(speakersOf(color("name", d#name), color("ink", d#ink)))
                                 |> Option.getWithDefault(d#speakers) })

    /// speakers の列（{id, name, color, ink}）。色の無い行は名前の色と本文の色。
    def speakersOf(name: Color, ink: Color, json: Json): Map[String, Speaker] =
        JsonCodec.decodeList(JsonCodec.expectObject, json) |> Option.getWithDefault(Nil)
            |> List.map(row -> {
                let color = (key, fallback) -> Map.get(key, row) |> Option.flatMap(JsonCodec.expectString)
                    |> Option.flatMap(Color.hex) |> Option.getWithDefault(fallback);
                let id = JsonCodec.stringOr("id", "", row);
                (id, { id = id, name = JsonCodec.stringOr("name", "", row), color = color("color", name), ink = color("ink", ink) })
            })
            |> List.toMap

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
