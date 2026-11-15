// ThemeDoc — novel.theme.json（字・ウィンドウの色と待ちの印・メッセージ枠の型）の宣言ドキュメント層。写真の色は BackdropDoc の時間帯が持つ。
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

    /// メッセージ枠の出し方。Nvl = 画面いっぱいに積む（小説の頁）、Adv = 枠に今の 1 行。
    pub enum WindowKind with Eq, ToString {
        case Nvl
        case Adv
    }

    /// ADV の枠の置き場。Bottom = 画面の下、Center = 画面の真ん中。
    pub enum WindowPlace with Eq, ToString {
        case Bottom
        case Center
    }

    /// 字を写真から立たせる仕方。Panel = 字の下に枠の地を敷く、Outline = 地を敷かず字を暗い縁取りで囲む（字幕の形）。
    pub enum WindowFrame with Eq, ToString {
        case Panel
        case Outline
    }

    /// メッセージ枠の型 1 つ（<<window 型>> の型）。kind = 出し方、place = ADV の枠の置き場、frame = 字の立たせ方、
    /// showName = ADV の枠に話し手の名前を出すか、quotes = 台詞を「」で包むか。
    pub type alias Window = { kind = WindowKind, place = WindowPlace, frame = WindowFrame, showName = Bool, quotes = Bool }

    /// 話し手 1 人の色。id = シナリオの話し手の id（地の文は空）、name = 人に見せる名前（空なら novel.story.json の names）、
    /// color = 名前の字（テープの頁でシナリオの行を塗る色も同じ）、ink = 本文の字。
    pub type alias Speaker = { id = String, name = String, color = Color, ink = Color }

    /// ink = 本文の字、inkSeen = 既読の行の字（スキップで飛ばせる行だと分かる色）、name = 話し手の名前、
    /// accent = 選んでいる物・オートやスキップの点灯、panel = ADV のウィンドウ・選択肢・画面の地（濃さは設定の「ウィンドウの濃さ」）、
    /// veil = NVL の頁の下に敷く幕の濃さを、ウィンドウの濃さに掛ける割合（頁は画面いっぱいなのでウィンドウより薄くしてよい）、firefly = 蛍の光、
    /// loadingMark = 素材を待つ間の印、speakers = 話し手の id → 色（無い id は name と ink の色）、windows = メッセージ枠の型の名前 → 型、
    /// legacyModes = セーブの Mark v3 の mode の古い値（Nvl・Adv）→ 読み替える型の名前（空の舞台の Nvl もここで引く）。
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
        speakers = Map[String, Speaker],
        windows = Map[String, Window],
        legacyModes = Map[String, String]
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
                  speakers = Map#{ "" => { id = "", name = "地の文", color = hex("#e9c873"), ink = hex("#f3eee4") } },
                  windows = Map#{ "nvl" => nvlWindow(), "bottom" => advWindow() },
                  legacyModes = Map#{ "Nvl" => "nvl", "Adv" => "bottom" } })

    def nvlWindow(): Window = { kind = WindowKind.Nvl, place = WindowPlace.Bottom, frame = WindowFrame.Panel, showName = true, quotes = true }

    def advWindow(): Window = { kind = WindowKind.Adv, place = WindowPlace.Bottom, frame = WindowFrame.Panel, showName = true, quotes = true }

    /// Mark v3 の mode が書いていた出し方の名前（Nvl・Adv。legacyModes の鍵。Doc の型の名前には使えない）。
    pub def kindAlias(kind: WindowKind): String = "${kind}"

    /// 型の名前 name の型と、その本当の名前。Nvl / Adv は legacyModes の行き先の型。
    /// legacyModes に無い・行き先が windows に無い時と知らない名前は、windows の中でその出し方（知らない名前は ADV）の最初の型（鍵の順。無ければ既定の型）。
    // WhyNot: 知らない名前を知らせない — 毎フレーム描く所が引くので、同じ 1 行が流れ続ける。知らない名前は台本からは来ない（<<window>> の apply が Err にする）。
    pub def windowOf(name: String, doc: Doc): (String, Window) =
        let ws = rec(doc)#windows;
        let firstOf = kind -> ws |> Map.toList |> List.find(match (_, w) -> w#kind == kind);
        let fallback = (kind, builtin) -> firstOf(kind) |> Option.getWithDefault((kindAlias(kind), builtin));
        let legacy = Map.get(name, rec(doc)#legacyModes) |> Option.flatMap(target -> Map.get(target, ws) |> Option.map(w -> (target, w)));
        match (Map.get(name, ws), legacy) {
            case (Some(w), _)    => (name, w)
            case (None, Some(t)) => t
            case _ if name == kindAlias(WindowKind.Nvl) => fallback(WindowKind.Nvl, nvlWindow())
            case _               => fallback(WindowKind.Adv, advWindow())
        }

    /// 型の名前が windows にあるか。
    pub def hasWindow(name: String, doc: Doc): Bool = Map.memberOf(name, rec(doc)#windows)

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
                                 |> Option.getWithDefault(d#speakers),
                  windows = Map.get("windows", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(windowsOf)
                                |> Option.filter(ws -> not Map.isEmpty(ws)) |> Option.getWithDefault(d#windows),
                  legacyModes = Map.get("legacyModes", root) |> Option.flatMap(JsonCodec.decodeStringMap(JsonCodec.expectString)) |> Option.getWithDefault(d#legacyModes) })

    /// windows の表（名前 → { kind, place, frame, showName, quotes }）を読む。Nvl・Adv の名前と読めない行は落とし、落とした理由を 1 行ずつ返す。
    // WhyNot: 型の名前に Nvl・Adv を許さない — セーブの Mark v3 の mode の古い値と同じ字になり、どちらの意味か読み分けられない。
    pub def windowsFrom(rows: Map[String, Json]): (Map[String, Window], List[String]) =
        let read = (name, json) ->
            if (name == kindAlias(WindowKind.Nvl) or name == kindAlias(WindowKind.Adv)) Err("windows の型の名前 '${name}' は使えない（セーブの古い値と同じ字）")
            else windowFrom(json) |> Option.toOk("windows の '${name}' が読めない（kind = nvl・adv が要る）");
        let results = rows |> Map.toList |> List.map(match (name, json) -> read(name, json) |> Result.map(w -> (name, w)));
        (results |> List.filterMap(Result.toOption) |> List.toMap, results |> List.filterMap(errorOf))

    def errorOf(r: Result[String, a]): Option[String] = match r {
        case Err(why) => Some(why)
        case Ok(_)    => None
    }

    /// windowsFrom で読み、落とした行を 1 行ずつ知らせる。
    def windowsOf(rows: Map[String, Json]): Map[String, Window] =
        let (kept, dropped) = windowsFrom(rows);
        dropped |> List.foldLeft((acc, why) -> Log.warnThen("[theme] ${why} — 落とす", acc), kept)

    def windowFrom(json: Json): Option[Window] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj -> {
            let kind = match JsonCodec.stringOr("kind", "", obj) {
                case "nvl" => Some(WindowKind.Nvl)
                case "adv" => Some(WindowKind.Adv)
                case _     => None
            };
            let base = (k: WindowKind) -> if (k == WindowKind.Nvl) nvlWindow() else advWindow();
            kind |> Option.map(k -> { kind = k,
                                      place = if (JsonCodec.stringOr("place", "bottom", obj) == "center") WindowPlace.Center else WindowPlace.Bottom,
                                      frame = if (JsonCodec.stringOr("frame", "panel", obj) == "outline") WindowFrame.Outline else WindowFrame.Panel,
                                      showName = JsonCodec.boolOr("showName", base(k)#showName, obj),
                                      quotes = JsonCodec.boolOr("quotes", base(k)#quotes, obj) })
        })

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
