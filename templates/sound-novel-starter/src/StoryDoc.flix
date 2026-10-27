// StoryDoc — novel.story.json（画面に出す言葉: タイトル・メニュー・設定・セーブ・確認の窓の文言と、話し手の呼び名）の宣言ドキュメント層。
// 文章・分岐・結末はシナリオ assets/talk/natsukusa.yarn（Talk）にあり、ここはシナリオの外で画面に出す言葉だけを持つ。
// 言葉は Label の enum を鍵に引く（鍵の綴りと既定の言葉の正は entryOf。Doc に無い鍵は既定の言葉で出す = fail-open）。
mod StoryDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// シナリオの外で画面に出す言葉の鍵。
    pub enum Label with Eq, Order, ToString {
        // タイトルのメニュー
        case NewGame
        case Continue
        case LoadGame
        case Settings
        case Credits
        case Quit
        // 読んでいる間のクイックメニュー
        case Rollback
        case Log
        case Auto
        case Skip
        case QuickSave
        case QuickLoad
        case Save
        case Load
        case Config
        case Hide
        case ToTitle
        // 画面の見出しと「戻る」
        case SaveTitle
        case LoadTitle
        case LogTitle
        case SettingsTitle
        case Back
        // セーブ・ロードの画面
        case TabAuto
        case TabQuick
        case EmptySlot
        case NewBadge
        case SlotsHint
        // バックログ
        case LogHint
        // 設定の画面
        case GroupText
        case GroupSound
        case TextSpeed
        case AutoWait
        case SkipScope
        case SkipReadOnly
        case SkipEverything
        case AfterChoice
        case StopSkip
        case KeepSkip
        case Display
        case WindowMode
        case FullscreenMode
        case MasterVolume
        case AmbienceVolume
        case SeVolume
        case WindowAlpha
        case Reset
        case Preview
        // 確認の窓
        case Yes
        case No
        case AskOverwrite
        case AskDelete
        case AskLoad
        case AskJump
        case AskToTitle
        case AskQuit
        case AskReset
        case LostNote
        // 知らせ
        case Saved
        case QuickSaved
        case Loaded
        case Deleted
        case ResetDone
        case NoSave
        case NoQuickSave
        case NoRollback
    }

    pub def labels(): List[Label] =
        Label.NewGame :: Label.Continue :: Label.LoadGame :: Label.Settings :: Label.Credits :: Label.Quit ::
        Label.Rollback :: Label.Log :: Label.Auto :: Label.Skip :: Label.QuickSave :: Label.QuickLoad ::
        Label.Save :: Label.Load :: Label.Config :: Label.Hide :: Label.ToTitle :: Label.SaveTitle ::
        Label.LoadTitle :: Label.LogTitle :: Label.SettingsTitle :: Label.Back :: Label.TabAuto :: Label.TabQuick ::
        Label.EmptySlot :: Label.NewBadge :: Label.SlotsHint :: Label.LogHint :: Label.GroupText :: Label.GroupSound ::
        Label.TextSpeed :: Label.AutoWait :: Label.SkipScope :: Label.SkipReadOnly :: Label.SkipEverything :: Label.AfterChoice ::
        Label.StopSkip :: Label.KeepSkip :: Label.Display :: Label.WindowMode :: Label.FullscreenMode :: Label.MasterVolume ::
        Label.AmbienceVolume :: Label.SeVolume :: Label.WindowAlpha :: Label.Reset :: Label.Preview :: Label.Yes ::
        Label.No :: Label.AskOverwrite :: Label.AskDelete :: Label.AskLoad :: Label.AskJump :: Label.AskToTitle ::
        Label.AskQuit :: Label.AskReset :: Label.LostNote :: Label.Saved :: Label.QuickSaved :: Label.Loaded ::
        Label.Deleted :: Label.ResetDone :: Label.NoSave :: Label.NoQuickSave :: Label.NoRollback :: Nil

    /// novel.story.json の labels の鍵。
    pub def labelKey(label: Label): String = fst(entryOf(label))

    /// 鍵の綴りと、Doc に鍵が無い時に出す言葉（assets/novel.story.json と同じ値から出発する）。
    def entryOf(label: Label): (String, String) = match label {
        case Label.NewGame        => ("newGame", "はじめから")
        case Label.Continue       => ("continue", "つづきから")
        case Label.LoadGame       => ("loadGame", "ロード")
        case Label.Settings       => ("settings", "設定")
        case Label.Credits        => ("credits", "クレジット")
        case Label.Quit           => ("quit", "終了")
        case Label.Rollback       => ("rollback", "戻る")
        case Label.Log            => ("log", "ログ")
        case Label.Auto           => ("auto", "オート")
        case Label.Skip           => ("skip", "スキップ")
        case Label.QuickSave      => ("quickSave", "Qセーブ")
        case Label.QuickLoad      => ("quickLoad", "Qロード")
        case Label.Save           => ("save", "セーブ")
        case Label.Load           => ("load", "ロード")
        case Label.Config         => ("config", "設定")
        case Label.Hide           => ("hide", "隠す")
        case Label.ToTitle        => ("toTitle", "タイトル")
        case Label.SaveTitle      => ("saveTitle", "セーブ")
        case Label.LoadTitle      => ("loadTitle", "ロード")
        case Label.LogTitle       => ("logTitle", "バックログ")
        case Label.SettingsTitle  => ("settingsTitle", "設定")
        case Label.Back           => ("back", "戻る")
        case Label.TabAuto        => ("tabAuto", "オート")
        case Label.TabQuick       => ("tabQuick", "クイック")
        case Label.EmptySlot      => ("emptySlot", "NO DATA")
        case Label.NewBadge       => ("newBadge", "NEW")
        case Label.SlotsHint      => ("slotsHint", "Q / E でページを替える ・ Delete で削除")
        case Label.LogHint        => ("logHint", "行をクリックすると、その場面まで戻れます ・ ホイールで遡る")
        case Label.GroupText      => ("groupText", "文章")
        case Label.GroupSound     => ("groupSound", "音と画面")
        case Label.TextSpeed      => ("textSpeed", "文字の速さ")
        case Label.AutoWait       => ("autoWait", "オートの待ち時間")
        case Label.SkipScope      => ("skipScope", "スキップ")
        case Label.SkipReadOnly   => ("skipReadOnly", "既読のみ")
        case Label.SkipEverything => ("skipEverything", "未読も")
        case Label.AfterChoice    => ("afterChoice", "選択肢の後")
        case Label.StopSkip       => ("stopSkip", "止める")
        case Label.KeepSkip       => ("keepSkip", "続ける")
        case Label.Display        => ("display", "画面")
        case Label.WindowMode     => ("windowMode", "ウィンドウ")
        case Label.FullscreenMode => ("fullscreenMode", "フルスクリーン")
        case Label.MasterVolume   => ("masterVolume", "全体の音量")
        case Label.AmbienceVolume => ("ambienceVolume", "環境音")
        case Label.SeVolume       => ("seVolume", "効果音")
        case Label.WindowAlpha    => ("windowAlpha", "ウィンドウの濃さ")
        case Label.Reset          => ("reset", "初期設定に戻す")
        case Label.Preview        => ("preview", "夏草の匂いが、開けた窓から流れこんでくる。遠くで蜩が鳴いた。")
        case Label.Yes            => ("yes", "はい")
        case Label.No             => ("no", "いいえ")
        case Label.AskOverwrite   => ("askOverwrite", "このデータに上書きしますか？")
        case Label.AskDelete      => ("askDelete", "このデータを削除しますか？")
        case Label.AskLoad        => ("askLoad", "このデータをロードしますか？")
        case Label.AskJump        => ("askJump", "この場面まで戻りますか？")
        case Label.AskToTitle     => ("askToTitle", "タイトルに戻りますか？")
        case Label.AskQuit        => ("askQuit", "ゲームを終了しますか？")
        case Label.AskReset       => ("askReset", "設定を初期値に戻しますか？")
        case Label.LostNote       => ("lostNote", "セーブしていない進行は失われます")
        case Label.Saved          => ("saved", "セーブしました")
        case Label.QuickSaved     => ("quickSaved", "クイックセーブしました")
        case Label.Loaded         => ("loaded", "ロードしました")
        case Label.Deleted        => ("deleted", "削除しました")
        case Label.ResetDone      => ("resetDone", "初期設定に戻しました")
        case Label.NoSave         => ("noSave", "セーブデータがありません")
        case Label.NoQuickSave    => ("noQuickSave", "クイックセーブがありません")
        case Label.NoRollback     => ("noRollback", "これ以上は戻れません")
    }

    /// title / subtitle / hint = タイトル画面の文言、titlePhoto / titleGrade / titleAmbience = タイトル画面の背景（写真・時間帯は
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
        Map.get(labelKey(label), rec(doc)#labels) |> Option.getWithDefault(snd(entryOf(label)))

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
