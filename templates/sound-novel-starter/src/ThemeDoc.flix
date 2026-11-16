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

    /// 縦の画面での字の出し方。Page = 画面いっぱいの頁に行を上から積む、Band(高さ) = 画面の下の帯（下端から高さ px）に今の行だけを出し、
    /// 覆いは帯の上にだけ敷く（帯より上の写真と HUD は沈めない）、Frame(真ん中の高さ) = 画面の真ん中の枠に今の行だけを出す
    /// （枠の真ん中は画面の高さに対する割合。高さは行の数で決まる。Layout.portraitFrame）。
    pub enum PortraitText with Eq, ToString {
        case Page
        case Band(Float64)
        case Frame(Float64)
    }

    /// メッセージ枠の型 1 つ（<<window 型>> の型）。kind = 出し方、place = ADV の枠の置き場、frame = 字の立たせ方、
    /// showName = ADV の枠に話し手の名前を出すか、quotes = 台詞を「」で包むか、portrait = 縦の画面での字の出し方。
    pub type alias Window = { kind = WindowKind, place = WindowPlace, frame = WindowFrame, showName = Bool, quotes = Bool, portrait = PortraitText }

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

    def nvlWindow(): Window = { kind = WindowKind.Nvl, place = WindowPlace.Bottom, frame = WindowFrame.Panel, showName = true, quotes = true, portrait = PortraitText.Page }

    def advWindow(): Window = { kind = WindowKind.Adv, place = WindowPlace.Bottom, frame = WindowFrame.Panel, showName = true, quotes = true, portrait = PortraitText.Page }

    /// Mark v3 の mode が書いていた出し方の名前（Nvl・Adv。legacyModes の鍵。Doc の型の名前には使えない）。
    pub def kindAlias(kind: WindowKind): String = "${kind}"

    /// 型の名前 name の型と、その本当の名前。Nvl / Adv は legacyModes の行き先の型。
    /// legacyModes に無い・行き先が windows に無い時と知らない名前は、windows の中でその出し方（知らない名前は ADV）の最初の型（鍵の順）、
    /// その出し方の型が無ければもう一方の出し方の最初の型。
    // WhyNot: 知らない名前を知らせない — 毎フレーム描く所が引くので、同じ 1 行が流れ続ける。知らない名前は台本からは来ない（<<window>> の apply が Err にする）。
    //   Doc の legacyModes の食い違いは読み込みの時に 1 回知らせる（legacyProblemsOf）。
    pub def windowOf(name: String, doc: Doc): (String, Window) =
        let ws = rec(doc)#windows;
        let legacy = Map.get(name, rec(doc)#legacyModes) |> Option.flatMap(target -> Map.get(target, ws) |> Option.map(w -> (target, w)));
        match (Map.get(name, ws), legacy) {
            case (Some(w), _)    => (name, w)
            case (None, Some(t)) => t
            case _ if name == kindAlias(WindowKind.Nvl) => firstOfKind(WindowKind.Nvl, doc)
            case _               => firstOfKind(WindowKind.Adv, doc)
        }

    /// windows の中で kind の最初の型（鍵の順）。無ければもう一方の出し方の最初の型（それも無ければ既定の型）。
    def firstOfKind(kind: WindowKind, doc: Doc): (String, Window) =
        let ws = rec(doc)#windows |> Map.toList;
        let other = if (kind == WindowKind.Nvl) WindowKind.Adv else WindowKind.Nvl;
        let builtin = if (kind == WindowKind.Nvl) nvlWindow() else advWindow();
        ws |> List.find(match (_, w) -> w#kind == kind)
           |> Option.withDefault(default = ws |> List.find(match (_, w) -> w#kind == other))
           |> Option.getWithDefault((kindAlias(kind), builtin))

    /// 新しいゲームの最初の型の名前: legacyModes の Nvl の行き先が windows の nvl の型ならそれ、無ければ nvl の最初の型、nvl の型が無ければ adv の最初の型。
    pub def startWindowName(doc: Doc): String =
        let ws = rec(doc)#windows;
        Map.get(kindAlias(WindowKind.Nvl), rec(doc)#legacyModes)
            |> Option.filter(t -> Map.get(t, ws) |> Option.exists(w -> w#kind == WindowKind.Nvl))
            |> Option.getWithDefault(fst(firstOfKind(WindowKind.Nvl, doc)))

    /// legacyModes の食い違い（Nvl・Adv の欠け・行き先が windows に無い・行き先の出し方が違う）を 1 行ずつ。
    pub def legacyProblemsOf(windows: Map[String, Window], legacy: Map[String, String]): List[String] =
        (WindowKind.Nvl :: WindowKind.Adv :: Nil) |> List.filterMap(kind -> {
            let oldName = kindAlias(kind);
            match Map.get(oldName, legacy) {
                case None    => Some("legacyModes に ${oldName} が無い（${oldName} の古いセーブは ${oldName} の最初の型で読む）")
                case Some(t) => targetProblemOf(oldName, kind, t, Map.get(t, windows))
            }
        })

    def targetProblemOf(oldName: String, kind: WindowKind, target: String, window: Option[Window]): Option[String] = match window {
        case None                       => Some("legacyModes の ${oldName} の行き先 '${target}' が windows に無い")
        case Some(w) if w#kind != kind  => Some("legacyModes の ${oldName} の行き先 '${target}' は ${w#kind} の型（${oldName} は ${kind} の型にする）")
        case Some(_)                    => None
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
            |> warnLegacy

    /// legacyModes の食い違いを読み込みの時に 1 行ずつ知らせる（Doc はそのまま。windowOf が最初の型へ落とす）。
    def warnLegacy(doc: Doc): Doc =
        legacyProblemsOf(rec(doc)#windows, rec(doc)#legacyModes) |> List.foldLeft((acc, why) -> Log.warnThen("[theme] ${why}", acc), doc)

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
                                      quotes = JsonCodec.boolOr("quotes", base(k)#quotes, obj),
                                      portrait = portraitTextOf(obj) })
        })

    /// band の帯の高さの既定（画面の下端から px）。
    pub def defaultBandHeight(): Float64 = 236.0

    /// 型の portrait（"page"・"band"・"frame"）と bandHeight（帯の高さ px。既定 defaultBandHeight）・frameCenter（枠の真ん中の高さ。
    /// 既定 defaultFrameCenter）。知らない字は page。
    def portraitTextOf(obj: Map[String, Json]): PortraitText = match JsonCodec.stringOr("portrait", "page", obj) {
        case "band"  => PortraitText.Band(JsonCodec.floatOr("bandHeight", defaultBandHeight(), obj))
        case "frame" => PortraitText.Frame(JsonCodec.floatOr("frameCenter", defaultFrameCenter(), obj))
        case _       => PortraitText.Page
    }

    /// 真ん中の枠の真ん中の高さの既定（画面の高さに対する割合。真ん中より少し上）。
    pub def defaultFrameCenter(): Float64 = 0.4

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
