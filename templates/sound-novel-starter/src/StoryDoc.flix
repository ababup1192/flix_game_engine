// StoryDoc — novel.story.json（画面に出す言葉: 表紙・ボタン・設定・セーブの文言と、話し手の呼び名）の宣言ドキュメント層。
// 文章・分岐・結末はシナリオ assets/talk/natsukusa.yarn（Talk）にあり、ここはシナリオの外で画面に出す言葉だけを持つ。
// 言葉は Label の enum を鍵に引く（鍵の綴りの正は labelKey。Doc に無い鍵は既定の言葉で出す = fail-open）。
mod StoryDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// シナリオの外で画面に出す言葉の鍵。
    pub enum Label with Eq, Order, ToString {
        // 表紙のメニュー
        case NewGame case Continue case Settings case Credits case Quit
        // 読んでいる間のボタン
        case Log case Auto case Skip case Save case Load case Hide case ToTitle
        // 設定の行
        case TextSpeed case AutoWait case AmbienceVolume case SeVolume
        // セーブの窓・ログ・知らせ
        case SaveTitle case LoadTitle case EmptySlot case Back case LogTitle case Saved case Loaded case NoSave
    }

    pub def labels(): List[Label] =
        Label.NewGame :: Label.Continue :: Label.Settings :: Label.Credits :: Label.Quit ::
        Label.Log :: Label.Auto :: Label.Skip :: Label.Save :: Label.Load :: Label.Hide :: Label.ToTitle ::
        Label.TextSpeed :: Label.AutoWait :: Label.AmbienceVolume :: Label.SeVolume ::
        Label.SaveTitle :: Label.LoadTitle :: Label.EmptySlot :: Label.Back :: Label.LogTitle ::
        Label.Saved :: Label.Loaded :: Label.NoSave :: Nil

    /// novel.story.json の labels の鍵。
    pub def labelKey(label: Label): String = match label {
        case Label.NewGame        => "newGame"
        case Label.Continue       => "continue"
        case Label.Settings       => "settings"
        case Label.Credits        => "credits"
        case Label.Quit           => "quit"
        case Label.Log            => "log"
        case Label.Auto           => "auto"
        case Label.Skip           => "skip"
        case Label.Save           => "save"
        case Label.Load           => "load"
        case Label.Hide           => "hide"
        case Label.ToTitle        => "toTitle"
        case Label.TextSpeed      => "textSpeed"
        case Label.AutoWait       => "autoWait"
        case Label.AmbienceVolume => "ambienceVolume"
        case Label.SeVolume       => "seVolume"
        case Label.SaveTitle      => "saveTitle"
        case Label.LoadTitle      => "loadTitle"
        case Label.EmptySlot      => "emptySlot"
        case Label.Back           => "back"
        case Label.LogTitle       => "logTitle"
        case Label.Saved          => "saved"
        case Label.Loaded         => "loaded"
        case Label.NoSave         => "noSave"
    }

    /// Doc に鍵が無い時に出す言葉（assets/novel.story.json と同じ値から出発する）。
    def fallbackOf(label: Label): String = match label {
        case Label.NewGame        => "はじめから"
        case Label.Continue       => "つづきから"
        case Label.Settings       => "設定"
        case Label.Credits        => "クレジット"
        case Label.Quit           => "おわる"
        case Label.Log            => "ログ"
        case Label.Auto           => "オート"
        case Label.Skip           => "スキップ"
        case Label.Save           => "セーブ"
        case Label.Load           => "ロード"
        case Label.Hide           => "隠す"
        case Label.ToTitle        => "表紙へ"
        case Label.TextSpeed      => "文字の速さ"
        case Label.AutoWait       => "オートの待ち"
        case Label.AmbienceVolume => "環境音"
        case Label.SeVolume       => "効果音"
        case Label.SaveTitle      => "どこに栞を挟みますか"
        case Label.LoadTitle      => "どの栞から読みますか"
        case Label.EmptySlot      => "―― 空き ――"
        case Label.Back           => "戻る"
        case Label.LogTitle       => "これまでの頁"
        case Label.Saved          => "栞を挟みました"
        case Label.Loaded         => "栞のところから読みます"
        case Label.NoSave         => "まだ栞がありません"
    }

    /// title / subtitle / hint = 表紙の文言、titlePhoto / titleGrade / titleAmbience = 表紙の背景（写真・時間帯は
    /// novel.backdrops.json の鍵）と環境音、names = 話し手の id → 呼び名、labels = Label の鍵 → 言葉。
    pub type alias Rec = {
        version = Int32,
        title = String,
        subtitle = String,
        hint = String,
        titlePhoto = String,
        titleGrade = String,
        titleAmbience = String,
        names = Map[String, String],
        labels = Map[String, String]
    }

    /// 型検査が record を展開しないため、World が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.story.json"

    pub def defaults(): Doc =
        Doc.Doc({ version = 1, title = "夏草の駅", subtitle = "十年ぶりに、祖母の町へ帰る。",
                  hint = "クリックか Enter で選ぶ", titlePhoto = "station", titleGrade = "dusk", titleAmbience = "evening",
                  names = Map.empty(), labels = Map.empty() })

    /// 鍵の言葉（Doc に無ければ既定の言葉）。
    pub def labelOf(label: Label, doc: Doc): String =
        Map.get(labelKey(label), rec(doc)#labels) |> Option.getWithDefault(fallbackOf(label))

    /// 話し手の id の呼び名（地の文の空の id は空・Doc に無い id はそのまま）。
    pub def nameOf(id: String, doc: Doc): String =
        Map.getWithDefault(id, id, rec(doc)#names)

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let strings = key -> Map.get(key, root)
            |> Option.flatMap(JsonCodec.decodeStringMap(JsonCodec.expectString))
            |> Option.getWithDefault(Map.empty());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  title = JsonCodec.stringOr("title", d#title, root),
                  subtitle = JsonCodec.stringOr("subtitle", d#subtitle, root),
                  hint = JsonCodec.stringOr("hint", d#hint, root),
                  titlePhoto = JsonCodec.stringOr("titlePhoto", d#titlePhoto, root),
                  titleGrade = JsonCodec.stringOr("titleGrade", d#titleGrade, root),
                  titleAmbience = JsonCodec.stringOr("titleAmbience", d#titleAmbience, root),
                  names = strings("names"),
                  labels = strings("labels") })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
