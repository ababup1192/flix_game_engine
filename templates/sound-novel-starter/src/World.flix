// World — ゲームの状態の形と、どの規則も使う小さな口（すべて純粋）。
// 規則は章ごとのファイルに分けてある（読む順）:
//   WorldRead     … 読み進める（送る・選ぶ・文字送り・オートとスキップ・戻れる所へ戻す）
//   WorldLog      … バックログと「戻る」
//   WorldSaves    … セーブ・ロードの画面
//   WorldSettings … 設定の画面
//   WorldMenu     … タイトルのメニュー・クイックメニュー・確認のウィンドウの答え（ほかの章を呼ぶ一番上）
//
// ── 状態の形: 「その場面でしか触れない値は、その場面の enum の中に持つ」──
//   scene（Scene）… Title(カーソルの項目) / Reading(Read = 読んでいる間だけの値) / Credits(流れ始めた時刻, 最後の舞台)
//   panel（Panel）… 場面の上に開く画面。カーソルやページはその画面の case が持つ（閉じると一緒に消える）
//   ask           … 一番手前の確認のウィンドウ（尋ねている事と、はい / いいえのカーソル）
//   残りの欄は場面をまたぐ物だけ: セーブデータ・マウス・2 本の時計・知らせ・終了・出来事。
// 読んでいる間の値（シナリオの位置・舞台・頁・バックログ…）は Read にしか無いので、タイトルの間に頁を触る、
// クレジットの間にバックログを足す、のような取り違えはコンパイルで止まる。場面を移ると前の場面の値は自然に消える。
//
// 場面の移り変わり（Scene と、その上に開く Panel と、いちばん手前の確認のウィンドウ ask）:
//
//     Title ──はじめから──▶ Reading（Talk.Node.Opening のノードを開く）──シナリオが終わる──▶ Credits ──流れ切る・決定──▶ Title
//       │                     │  送る(advance) → YarnRunner の Advance / 選ぶ(pick) → Choose / 戻る(rollback) → 1 つ前の行
//       ├─つづきから（いちばん新しいデータを読む）──▶ Reading
//       ├─ロード──▶ LoadSlots ──データを選ぶ──▶ Reading（ブックマークを当て直す = WorldRead.restore）
//       ├─設定・クレジット・終了（確認のウィンドウ）
//                             └─クイックメニュー・キー──▶ Panel: Log / SaveSlots / LoadSlots / Settings / Hidden（物語の時計は止まる）
//     確認のウィンドウ（ask）は Panel の上に開き、はいで中身（上書き・削除・ロード・この場面へ戻る・タイトルへ・終了・初期化）を行う。
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// ── 出来事（Emit）──
// 規則は音を直に鳴らさない。「セーブした」「カーソルが動いた」のような出来事 Event を Emit.emit で出すだけで、
// 鳴らす音は Controls.soundOf が出来事から選ぶ。こうすると規則は World → World の純粋な関数のままで、
// テストは出来事の列を比べるだけで「音が鳴るか」を確かめられる（音の名前を変えても規則とテストは動かない）。
//
// 時計は 2 本（型で分けてあり、取り違えるとコンパイルが止まる）:
//   物語の時計 storyClock（Clock[Stage.Story]）… 文字送り・<<wait>>・背景の重ね・揺れ・オートとスキップの間。画面や確認のウィンドウを開くと止まる。
//                                                 進めるのは App だけ（Game の App.addClock・進み方は paceOf）。
//   実時間 realNow（Time[Clock.Real]）          … 蛍の光・タイトルの字の明滅・クレジット・知らせ・設定の文字の速さの見本。止まらない。
//   セーブの日時は clockBase（起動した時のその土地の時刻。Main が読んで渡す）+ realNow の秒。
mod World {
    use fge::{Clock, Emit, Yarn, YarnRunner}

    /// いまの場面と、その場面だけが持つ値。
    ///   Title(項目) = タイトルのメニュー（カーソルの項目）、Reading(Read) = 読んでいる間、
    ///   Credits(流れ始めた実時間, 舞台) = クレジット（最後に読んでいた背景と環境音のまま流す）。
    pub enum Scene {
        case Title(TitleItem)
        case Reading(Read)
        case Credits(Clock.Time[Clock.Real], Stage.Stage)
    }

    /// 読んでいる間だけの値。talk = シナリオの現在地、stage = 舞台、page = 出している文章、
    /// choices / choiceCursor = 出している選択肢（無ければ空）とそのカーソル、log = バックログ（新しい順）、
    /// playback = 送り方、doneAt = 今の行を出し終えた物語の時刻、autosavedNode = オートセーブを残した最後のノード。
    pub type alias Read = {
        talk = YarnRunner.Runner[Stage.Story],
        stage = Stage.Stage,
        page = Page.Page,
        choices = List[YarnRunner.DialogueOption],
        choiceCursor = Int32,
        log = List[Entry],
        playback = Playback,
        doneAt = Option[Clock.Time[Stage.Story]],
        autosavedNode = Option[String]
    }

    /// 場面の上に開いている画面と、その画面だけの値（Closed 以外は物語の時計が止まる）。
    ///   Log(遡った量 px) / SaveSlots・LoadSlots(ページ, 枠のカーソル) / Settings(カーソルの行) / Hidden = 文章のウィンドウを隠して背景だけを見る。
    pub enum Panel with Eq {
        case Closed
        case Log(Float64)
        case SaveSlots(Saves.Tab, Int32)
        case LoadSlots(Saves.Tab, Int32)
        case Settings(Setting)
        case Hidden
    }

    /// 送り方。Manual = 人が押して送る、Auto = 読み終えて少し待つと送る、Skip = 速く送る（設定で既読のみ / 未読も）。
    pub enum Playback with Eq, ToString {
        case Manual
        case Auto
        case Skip
    }

    /// 物語の時計を止める理由。
    pub enum Halt with Eq {
        case PanelOpen
        case Asking
    }

    /// タイトルのメニューの項目。
    pub enum TitleItem with Eq, ToString {
        case NewGame
        case Continue
        case LoadGame
        case Settings
        case Credits
        case Quit
    }

    /// 読んでいる間のクイックメニュー（下の帯）。
    pub enum Button with Eq, ToString {
        case Rollback
        case Log
        case Auto
        case Skip
        case QuickSave
        case QuickLoad
        case Save
        case Load
        case Settings
        case Hide
        case ToTitle
    }

    /// 設定の行。操作の形ごとに分けてある: Slider = スライダーで数を選ぶ、Pair = 2 つから選ぶ、Reset = 押すと確認のウィンドウ。
    /// 形が型に入っているので、スライダーの行に 2 択の値を入れる取り違えはコンパイルで止まる。
    pub enum Setting with Eq, ToString {
        case Slider(Slider)
        case Pair(Pair)
        case Reset
    }

    /// スライダーで選ぶ設定（範囲は novel.kind.json の *Slider）。
    pub enum Slider with Eq, ToString {
        case TextSpeed
        case AutoWait
        case MasterVolume
        case AmbienceVolume
        case SeVolume
        case WindowAlpha
    }

    /// 2 つから選ぶ設定（左と右の言葉は WorldSettings.pairLabels）。
    pub enum Pair with Eq, ToString {
        case SkipScope
        case AfterChoice
        case Display
    }

    /// 確認のウィンドウで尋ねている事。セーブの枠はページと枠の番号、バックログの行（Jump）は 0 = 一番新しい行。
    pub enum Ask with Eq, ToString {
        case Overwrite(Saves.Tab, Int32)
        case Delete(Saves.Tab, Int32)
        case Load(Saves.Tab, Int32)
        case QuickLoad
        case Jump(Int32)
        case ToTitle
        case Quit
        case Reset
    }

    /// 確認のウィンドウの答え（カーソルもこれで持つ。ウィンドウの左がはい）。
    pub enum Answer with Eq, ToString {
        case Yes
        case No
    }

    /// バックログの 1 行。Said = 台詞か地の文（戻れる所つき）、Chose = 選んだ選択肢。
    pub enum Entry {
        case Said(Page.Line, Option[Saves.Mark])
        case Chose(String)
    }

    /// 規則の中で起きた出来事（返事の音の材料。冒頭の「出来事」）。Controls.interact が集めて events 欄に溜め、音は前後の差で読む。
    ///   Paged … 次の行へ送った / Revealed … 文字送りの途中で全文を出した / Moved … カーソルや値が動いた /
    ///   Picked … 選択肢を選んだ / Opened・Closed … 画面や確認のウィンドウを開けた・閉じた / Saved・Loaded … セーブした・ロードした /
    ///   Rolled … 前の行へ戻った / Cue(名前) … シナリオの <<se>> の効果音。
    pub enum Event with Eq, ToString {
        case Paged
        case Revealed
        case Moved
        case Picked
        case Opened
        case Closed
        case Saved
        case Loaded
        case Rolled
        case Cue(String)
    }

    /// ゲームの状態（遊びの状態だけ。Doc とシナリオは Res が持つ）。scene / panel / ask = 冒頭の「状態の形」、
    /// saves = セーブデータ・既読・設定、saveRev = saves を変えた回数（Saves を書く出力の鍵）、pointer = マウスの位置（触れている物を明るくする）、
    /// clockBase = 起動した時のその土地の時刻（秒。セーブの日時の元）、toast = 知らせの言葉と出した実時間、quitting = 終了を決めた、
    /// events = 規則が出した出来事（音の材料）。
    pub type alias World = {
        scene = Scene,
        panel = Panel,
        ask = Option[(Ask, Answer)],
        saves = Saves.Saves,
        saveRev = Int32,
        pointer = { x = Float64, y = Float64 },
        clockBase = Int64,
        storyClock = Clock.Clock[Stage.Story],
        realNow = Clock.Time[Clock.Real],
        toast = Option[(StoryDoc.Label, Clock.Time[Clock.Real])],
        quitting = Bool,
        events = Emit.Events[Event]
    }

    /// 起動の World。タイトルから始まる（カーソルは「はじめから」）。
    /// clockBase = 起動した時のその土地の時刻（1970-01-01 からの秒。テストと描き出しは決めた値を渡す）。
    pub def initial(saves: Saves.Saves, clockBase: Int64): World =
        { scene = Scene.Title(TitleItem.NewGame), panel = Panel.Closed, ask = None,
          saves = saves, saveRev = 0, pointer = { x = -1.0, y = -1.0 }, clockBase = clockBase,
          storyClock = Clock.start(), realNow = Clock.zero(), toast = None, quitting = false, events = Emit.empty() }

    /// 読み始める前の Read（舞台・頁・バックログが空）。
    pub def emptyRead(): Read =
        { talk = YarnRunner.closed(), stage = Stage.empty(), page = Page.empty(), choices = Nil, choiceCursor = 0,
          log = Nil, playback = Playback.Manual, doneAt = None, autosavedNode = None }

    // ── 場面を読む口 ──

    /// 読んでいる間の値（読んでいなければ None）。
    pub def readOf(w: World): Option[Read] = match w#scene {
        case Scene.Reading(r) => Some(r)
        case _                => None
    }

    /// 場面を Reading(r) にする（画面と確認のウィンドウはそのまま）。
    pub def withRead(r: Read, w: World): World = { scene = Scene.Reading(r) | w }

    /// 読んでいる間だけ f を掛ける（ほかの場面ではそのまま）。
    pub def mapRead(f: Read -> Read, w: World): World = match w#scene {
        case Scene.Reading(r) => withRead(f(r), w)
        case _                => w
    }

    /// 今の舞台（タイトルはタイトルの写真、クレジットは最後に読んでいた舞台）。背景・環境音・パーティクルの元。
    pub def stageOf(res: Res.Res, w: World): Stage.Stage = match w#scene {
        case Scene.Title(_)       => titleStage(res#story)
        case Scene.Reading(r)     => r#stage
        case Scene.Credits(_, st) => st
    }

    /// 今の頁（読んでいなければ空）。
    pub def pageOf(w: World): Page.Page = readOf(w) |> Option.map(r -> r#page) |> Option.getWithDefault(Page.empty())

    /// バックログ（新しい順。読んでいなければ空）。
    pub def logOf(w: World): List[Entry] = readOf(w) |> Option.map(r -> r#log) |> Option.getWithDefault(Nil)

    /// 送り方（読んでいなければ Manual）。
    pub def playbackOf(w: World): Playback = readOf(w) |> Option.map(r -> r#playback) |> Option.getWithDefault(Playback.Manual)

    /// 出している選択肢（無ければ空）。
    pub def choicesOf(w: World): List[YarnRunner.DialogueOption] = readOf(w) |> Option.map(r -> r#choices) |> Option.getWithDefault(Nil)

    /// 選択肢を出していて選べるか。
    pub def isChoosing(w: World): Bool = not List.isEmpty(choicesOf(w))

    /// 場面の名前（Title・Reading・Credits。flow の問いと状態の 1 行）。
    pub def sceneName(w: World): String = match w#scene {
        case Scene.Title(_)      => "Title"
        case Scene.Reading(_)    => "Reading"
        case Scene.Credits(_, _) => "Credits"
    }

    pub def isReading(w: World): Bool = Option.nonEmpty(readOf(w))

    pub def isCredits(w: World): Bool = match w#scene {
        case Scene.Credits(_, _) => true
        case _                   => false
    }

    /// 開いている画面の名前（Closed・Log・SaveSlots・LoadSlots・Settings・Hidden）。
    pub def panelName(w: World): String = match w#panel {
        case Panel.Closed          => "Closed"
        case Panel.Log(_)          => "Log"
        case Panel.SaveSlots(_, _) => "SaveSlots"
        case Panel.LoadSlots(_, _) => "LoadSlots"
        case Panel.Settings(_)     => "Settings"
        case Panel.Hidden          => "Hidden"
    }

    /// 開いているセーブ・ロードの画面のページと枠のカーソル。
    pub def slotsOf(w: World): Option[(Saves.Tab, Int32)] = match w#panel {
        case Panel.SaveSlots(tab, i) => Some((tab, i))
        case Panel.LoadSlots(tab, i) => Some((tab, i))
        case _                       => None
    }

    /// タイトルのカーソルの項目（タイトルでなければ None）。
    pub def titleCursorOf(w: World): Option[TitleItem] = match w#scene {
        case Scene.Title(item) => Some(item)
        case _                 => None
    }

    /// 尋ねている事（確認のウィンドウが閉じていれば None）。
    pub def askOf(w: World): Option[Ask] = w#ask |> Option.map(fst)

    /// 確認のウィンドウのカーソル（閉じていれば None）。
    pub def answerOf(w: World): Option[Answer] = w#ask |> Option.map(snd)

    /// タイトルの舞台（写真は重ね終わっている）。
    def titleStage(story: StoryDoc.Doc): Stage.Stage =
        let r = StoryDoc.rec(story);
        { shot = Some({ photo = r#titlePhoto, grade = r#titleGrade }),
          ambience = if (String.isEmpty(r#titleAmbience)) None else Some(r#titleAmbience) | Stage.empty() }

    /// 物語の時計の今。
    pub def now(w: World): Clock.Time[Stage.Story] = Clock.nowOf(w#storyClock)

    /// 遊ぶ人が設定の画面で決めた値。
    pub def configOf(w: World): Saves.Config = Saves.configOf(w#saves)

    /// saves を変えて saveRev を進める（= 実機ではセーブのファイルを書く）。
    pub def withSaves(saves: Saves.Saves, w: World): World = { saves = saves, saveRev = w#saveRev + 1 | w }

    /// マウスの位置を写す（Controls が毎フレーム。触れている物を明るくする View が読む）。
    pub def withPointer(p: { x = Float64, y = Float64 }, w: World): World = { pointer = p | w }

    // ── 場面の移り ──

    /// タイトルへ戻る（読んでいた値は Read ごと消える）。[遷移: Reading / Credits→Title]
    pub def toTitle(w: World): World =
        { scene = Scene.Title(TitleItem.NewGame), panel = Panel.Closed, ask = None | w }

    /// クレジットを流す（背景と環境音は今の舞台のまま）。[遷移: Reading / Title→Credits]
    pub def toCredits(res: Res.Res, w: World): World =
        { scene = Scene.Credits(w#realNow, stageOf(res, w)), panel = Panel.Closed, ask = None | w }

    /// クレジットが流れ切ったか（行の高さの合計 + 画面の高さを流れたら）。
    pub def creditsOver(res: Res.Res, w: World): Bool = match w#scene {
        case Scene.Credits(startedAt, _) =>
            Clock.since(startedAt, w#realNow) * KindDoc.rec(res#kind)#creditsSpeed >= creditsLength(res) + Layout.height()
        case _ => false
    }

    /// クレジットの行を並べた長さ（View が置く間隔と同じ決まり）。
    pub def creditsLength(res: Res.Res): Float64 =
        CreditsDoc.rec(res#credits)#rows |> List.foldLeft((sum, row) -> sum + creditsRowHeight(row#style), 0.0)

    pub def creditsRowHeight(style: CreditsDoc.Style): Float64 = match style {
        case CreditsDoc.Style.Heading => 52.0
        case CreditsDoc.Style.Body    => 34.0
        case CreditsDoc.Style.Small   => 24.0
        case CreditsDoc.Style.Gap     => 40.0
    }

    // ── 画面・確認のウィンドウ・知らせ ──

    /// 画面も確認のウィンドウも開いていないか。
    pub def isFree(w: World): Bool = w#panel == Panel.Closed and Option.isEmpty(w#ask)

    /// 物語の時計のこのフレームの進み方（Game の App.addClock が読む）。止める理由は確認のウィンドウと画面。
    pub def paceOf(w: World): Clock.Pace[Stage.Story, Halt] =
        if (Option.nonEmpty(w#ask)) Clock.paceOf(Clock.Run.Paused(Halt.Asking))
        else if (w#panel != Panel.Closed) Clock.paceOf(Clock.Run.Paused(Halt.PanelOpen))
        else Clock.paceOf(Clock.Run.Running)

    /// 確認のウィンドウを開く（カーソルは「いいえ」から。決定を押し続けても進まない）。オートとスキップは止める。
    pub def askFor(ask: Ask, w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        mapRead(r -> { playback = Playback.Manual | r }, { ask = Some((ask, Answer.No)) | w })

    /// 画面を開く（オートとスキップは止める。開いている間は物語の時計も止まる）。
    pub def openPanel(panel: Panel, w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        mapRead(r -> { playback = Playback.Manual | r }, { panel = panel | w })

    /// 画面を閉じる。
    pub def closePanel(w: World): World \ Emit[Event] =
        if (w#panel == Panel.Closed) w
        else { Emit.emit(Event.Closed); { panel = Panel.Closed | w } }

    /// ウィンドウの閉じるボタン（App.withCloseRequest）: 終了を尋ねる。もう尋ねていれば何もしない。
    pub def requestQuit(w: World): World =
        if (askOf(w) == Some(Ask.Quit)) w
        else mapRead(r -> { playback = Playback.Manual | r }, { ask = Some((Ask.Quit, Answer.No)) | w })

    /// 確認のウィンドウのカーソルを answer へ。
    pub def moveAsk(answer: Answer, w: World): World \ Emit[Event] =
        match w#ask {
            case Some((ask, at)) if at != answer => Emit.emit(Event.Moved); { ask = Some((ask, answer)) | w }
            case _                               => w
        }

    /// 知らせを出す（実時間で数秒残る。長さは novel.kind.json の toastSeconds）。
    pub def notice(label: StoryDoc.Label, w: World): World = { toast = Some((label, w#realNow)) | w }

    /// 今の知らせの字（消えていれば None）。
    pub def toastOf(res: Res.Res, w: World): Option[String] = match w#toast {
        case Some((label, at)) if Clock.since(at, w#realNow) < KindDoc.rec(res#kind)#toastSeconds =>
            Some(StoryDoc.labelOf(label, res#story))
        case _ => None
    }

    // ── 流れの問い・要点 ──

    /// 開いているノードの名前（閉じていれば空）。
    pub def talkNodeOf(w: World): String =
        readOf(w) |> Option.flatMap(r -> YarnRunner.nodeOf(r#talk)) |> Option.getWithDefault("")

    /// 今出している行のシナリオの行（ファイル:行。無ければ空）。
    pub def talkLineOf(w: World): String = pageOf(w)#current |> Option.map(line -> line#source) |> Option.getWithDefault("")

    /// 今の行を読んだことがあるか（既読の色で描くか）。
    pub def isCurrentSeen(w: World): Bool =
        match pageOf(w)#current {
            case Some(line) => Saves.isSeen(line#source, w#saves)
            case None       => false
        }

    /// シナリオの変数（セーブや結末のテスト・flow の問い）。
    pub def variableOf(name: String, w: World): String =
        readOf(w) |> Option.flatMap(r -> YarnRunner.valueOf(name, r#talk)) |> Option.map(Yarn.toText) |> Option.getWithDefault("")
}
