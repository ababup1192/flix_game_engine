// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 文章・分岐・結末はシナリオ assets/talk/natsukusa.yarn（YarnRunner が辿る）、舞台の畳み方は Stage、頁は Page、
// 遊んだ人ごとに残す物（栞・既読・設定）は Saves。ここは「送る・選ぶ・窓を開く・栞を挟む・読み直す」の規則。
//
// 場面の移り変わり（Phase と、Reading の上に開く窓 Panel）:
//
//     Title ──はじめから──▶ Reading（Talk.Node.Opening のノードを開く）──シナリオが終わる──▶ Credits ──流れ切る・決定──▶ Title
//       │                     │  送る(advance) → YarnRunner の Advance / 選ぶ(pick) → Choose
//       ├─つづきから──▶ LoadSlots ──栞を選ぶ(loadSlot)──▶ Reading（ブックマークを当て直す）
//       ├─設定・クレジット・おわる
//                             └─ボタン・キー──▶ Panel: Log / SaveSlots / LoadSlots / Settings / Hidden（物語の時計は止まる）
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// 時計は 2 本（型で分けてあり、取り違えるとコンパイルが止まる）:
//   物語の時計 storyClock（Clock[Story]）… 文字送り・<<wait>>・背景の重ね・揺れ・オートとスキップの間。窓を開くと止まる。
//                                          進めるのは App だけ（Game の App.addClock・進み方は paceOf）。
//   実時間 realNow（Time[Clock.Real]）     … 蛍の光・表紙の字の明滅・クレジットが流れる速さ・知らせの残り時間。止まらない。
//
// オートとスキップは同じ所（autoOrSkip）で決める: 行を出し終えた時刻 doneAt から、オートは「設定の待ち + 字数 × autoPerChar」、
// スキップは「既読の行だけ skipInterval ごと」に送る。スキップは読んでいない行・選択肢で止まる（読み逃しを作らない）。
mod World {
    use fge::{AudioMixer, Clock, Emit, Log, Yarn, YarnRunner, YarnStorage}

    /// 物語の時計の名前（中身は要らない）。
    pub enum Story

    /// いま画面が何をしているか。
    pub enum Phase with Eq, ToString {
        case Title
        case Reading
        case Credits
    }

    /// 読んでいる上に開いている窓（Closed 以外は物語の時計が止まる）。Hidden = 文章の窓を隠して背景だけを見る。
    pub enum Panel with Eq, ToString {
        case Closed
        case Log
        case SaveSlots
        case LoadSlots
        case Settings
        case Hidden
    }

    /// 送り方。Manual = 人が押して送る、Auto = 読み終えて少し待つと送る、Skip = 読んだ行を速く送る（読んでいない行と選択肢で止まる）。
    pub enum Playback with Eq, ToString {
        case Manual
        case Auto
        case Skip
    }

    /// 物語の時計を止める理由。
    pub enum Halt with Eq {
        case PanelOpen
    }

    /// 表紙のメニューの項目。
    pub enum TitleItem with Eq, ToString {
        case NewGame
        case Continue
        case Settings
        case Credits
        case Quit
    }

    /// 読んでいる間のボタン（下の帯）。
    pub enum Button with Eq, ToString {
        case Log
        case Auto
        case Skip
        case Save
        case Load
        case Settings
        case Hide
        case ToTitle
    }

    /// 設定の行。
    pub enum Setting with Eq, ToString {
        case TextSpeed
        case AutoWait
        case AmbienceVolume
        case SeVolume
    }

    /// 規則の中で起きた出来事（返事の音の材料）。Controls.interact が集めて events 欄に溜め、音は前後の差で読む。
    ///   Paged … 次の行へ送った / Revealed … 文字送りの途中で全文を出した / Moved … カーソルや値が動いた /
    ///   Picked … 選択肢を選んだ / Opened・Closed … 窓を開けた・閉じた / Saved・Loaded … 栞を挟んだ・栞から読んだ /
    ///   Cue(名前) … シナリオの <<se>> の効果音。
    pub enum Event with Eq, ToString {
        case Paged
        case Revealed
        case Moved
        case Picked
        case Opened
        case Closed
        case Saved
        case Loaded
        case Cue(String)
    }

    /// 起動時に読む Doc の束（Main・描き出し・テストが同じ形で組む）。
    pub type alias Docs = {
        story = StoryDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        backdrops = BackdropDoc.Doc,
        credits = CreditsDoc.Doc,
        keys = KeysDoc.Doc,
        mixer = AudioMixer.Mixer,
        dialogue = Yarn.Program
    }

    /// ゲームの状態。talk = シナリオの現在地、stage = 舞台、page = 出している文章、choices = 出している選択肢（無ければ空）、
    /// cursor = いま開いている物（表紙・選択肢・栞・設定）のカーソル、log = ログ（新しい順）、logOffset = ログを遡った量（px）、
    /// playback = 送り方（人が押す・オート・スキップ）、doneAt = 今の行を出し終えた物語の時刻、
    /// saves = 栞・既読・設定、saveRev = saves を変えた回数（Saves を書く出力の鍵）、
    /// creditsFrom = クレジットが流れ始めた実時間、toast = 知らせの字と出した実時間、quitting = 表紙で「おわる」を選んだ。
    pub type alias World = {
        phase = Phase,
        panel = Panel,
        story = StoryDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        backdrops = BackdropDoc.Doc,
        credits = CreditsDoc.Doc,
        keys = KeysDoc.Doc,
        mixer = AudioMixer.Mixer,
        dialogue = Yarn.Program,
        talk = YarnRunner.Runner[Story],
        stage = Stage.Stage,
        page = Page.Page,
        choices = List[YarnRunner.DialogueOption],
        cursor = Int32,
        log = List[Page.Line],
        logOffset = Float64,
        playback = Playback,
        doneAt = Option[Clock.Time[Story]],
        saves = Saves.Saves,
        saveRev = Int32,
        storyClock = Clock.Clock[Story],
        realNow = Clock.Time[Clock.Real],
        creditsFrom = Clock.Time[Clock.Real],
        toast = Option[(String, Clock.Time[Clock.Real])],
        quitting = Bool,
        events = Emit.Events[Event]
    }

    // ── 画面の寸法（project.json の designWidth / designHeight と同じ値） ──

    pub def width(): Float64 = 960.0
    pub def height(): Float64 = 540.0

    /// 起動の World。表紙から始まり、背景は表紙の写真（StoryDoc の titlePhoto・titleGrade）。
    pub def initial(docs: Docs, saves: Saves.Saves): World =
        { phase = Phase.Title, panel = Panel.Closed,
          story = docs#story, kind = docs#kind, theme = docs#theme, backdrops = docs#backdrops,
          credits = docs#credits, keys = docs#keys, mixer = docs#mixer, dialogue = docs#dialogue,
          talk = YarnRunner.closed(), stage = titleStage(docs#story), page = Page.empty(),
          choices = Nil, cursor = 0, log = Nil, logOffset = 0.0, playback = Playback.Manual, doneAt = None,
          saves = saves, saveRev = 0, storyClock = Clock.start(), realNow = Clock.zero(),
          creditsFrom = Clock.zero(), toast = None, quitting = false, events = Emit.empty() }

    /// 表紙の舞台（写真は重ね終わっている）。
    def titleStage(story: StoryDoc.Doc): Stage.Stage =
        let r = StoryDoc.rec(story);
        { shot = Some({ photo = r#titlePhoto, grade = r#titleGrade }),
          ambience = if (String.isEmpty(r#titleAmbience)) None else Some(r#titleAmbience) | Stage.empty() }

    def now(w: World): Clock.Time[Story] = Clock.nowOf(w#storyClock)

    def config(w: World): Saves.Config = w#saves#config

    // ── 表紙 ──

    pub def titleItems(): List[TitleItem] =
        TitleItem.NewGame :: TitleItem.Continue :: TitleItem.Settings :: TitleItem.Credits :: TitleItem.Quit :: Nil

    /// 表紙の項目を選ぶ。[遷移: Title→Reading / LoadSlots / Settings / Credits]
    /// 栞が無い時の「つづきから」は知らせを出すだけ（空の窓を開かない）。
    pub def chooseTitle(item: TitleItem, w: World): World \ Emit[Event] = match item {
        case TitleItem.NewGame  => newGame(w)
        case TitleItem.Continue =>
            if (Saves.hasAny(w#saves)) openPanel(Panel.LoadSlots, w)
            else notice(StoryDoc.Label.NoSave, w)
        case TitleItem.Settings => openPanel(Panel.Settings, w)
        case TitleItem.Credits  => toCredits(w)
        case TitleItem.Quit     => { quitting = true | w }
    }

    /// はじめから読む。[遷移: Title→Reading]
    pub def newGame(w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        let fresh = reading(w);
        match Yarn.nodeOf(Talk.nodeName(Talk.Node.Opening), w#dialogue) {
            case Some(_) =>
                let (talk, events) = YarnRunner.start(w#dialogue, Talk.nodeName(Talk.Node.Opening), now(w));
                absorb(false, events, { talk = talk | fresh })
            case None =>
                showLine(false, { speaker = "", text = "（シナリオが読めない。assets/talk/natsukusa.yarn を直して bin/fge yarn build assets/talk を流すと、ここに物語が流れる）",
                                  parts = Nil, tags = Nil, source = { file = "", line = 0 } }, fresh)
        }

    /// 読み始める前の World（舞台・頁・ログを空に）。
    pub def reading(w: World): World =
        { phase = Phase.Reading, panel = Panel.Closed, talk = YarnRunner.closed(), stage = Stage.empty(),
          page = Page.empty(), choices = Nil, cursor = 0, log = Nil, logOffset = 0.0,
          playback = Playback.Manual, doneAt = None | w }

    /// 表紙へ戻る。[遷移: Reading / Credits→Title]
    pub def toTitle(w: World): World =
        { phase = Phase.Title, panel = Panel.Closed, talk = YarnRunner.closed(), stage = titleStage(w#story),
          page = Page.empty(), choices = Nil, cursor = 0, playback = Playback.Manual, doneAt = None | w }

    /// クレジットを流す。[遷移: Reading / Title→Credits]
    pub def toCredits(w: World): World =
        { phase = Phase.Credits, panel = Panel.Closed, talk = YarnRunner.closed(), choices = Nil,
          playback = Playback.Manual, creditsFrom = w#realNow | w }

    /// クレジットが流れ切ったか（行の高さの合計 + 画面の高さを流れたら）。
    pub def creditsOver(w: World): Bool =
        Clock.since(w#creditsFrom, w#realNow) * KindDoc.rec(w#kind)#creditsSpeed >= creditsLength(w) + height()

    /// クレジットの行を並べた長さ（View が置く間隔と同じ決まり）。
    pub def creditsLength(w: World): Float64 =
        CreditsDoc.rec(w#credits)#rows |> List.foldLeft((sum, row) -> sum + creditsRowHeight(row#style), 0.0)

    pub def creditsRowHeight(style: CreditsDoc.Style): Float64 = match style {
        case CreditsDoc.Style.Heading => 52.0
        case CreditsDoc.Style.Body    => 34.0
        case CreditsDoc.Style.Small   => 24.0
        case CreditsDoc.Style.Gap     => 40.0
    }

    // ── シナリオの出来事を畳む ──

    /// 実行器が返した出来事を順に畳む。quiet = 効果音を鳴らさない（栞から読み直す時の当て直し）。
    /// [遷移: シナリオが終わる(Done) → Credits]
    def absorb(quiet: Bool, events: List[YarnRunner.Event], w: World): World \ Emit[Event] =
        List.foldLeft((acc, event) -> match event {
            case YarnRunner.Event.Line(line)       => showLine(quiet, line, acc)
            case YarnRunner.Event.Choices(options) => { choices = options, cursor = firstOpen(options) | acc }
            case YarnRunner.Event.Command(command) => cue(quiet, command, acc)
            case YarnRunner.Event.Done             => toCredits(acc)
        }, w, events)

    /// コマンド 1 つ（wait は実行器が待つので何もしない）。読めないコマンドは 1 行知らせて舞台はそのまま。
    def cue(quiet: Bool, command: Yarn.Command, w: World): World \ Emit[Event] =
        if (command#name == "wait") w
        else match Stage.cueOf(w#backdrops, command) {
            case Ok(Stage.Cue.Clear)       => { page = Page.clear(w#page) | w }
            case Ok(Stage.Cue.Se(name))    => if (quiet) w else { Emit.emit(Event.Cue("se_${name}")); w }
            case Ok(Stage.Cue.ToMode(mode)) =>
                let page = if (mode == w#stage#mode) w#page else Page.clear(w#page);
                { stage = Stage.applyCue(now(w), Stage.Cue.ToMode(mode), w#stage), page = page | w }
            case Ok(c)                     => { stage = Stage.applyCue(now(w), c, w#stage) | w }
            case Err(message)              => Log.warnThen("[stage] ${message}", w)
        }

    /// 台詞 1 行を頁とログへ。NVL で頁に入り切らない時は頁をめくってから積む。
    def showLine(quiet: Bool, line: Yarn.Line, w: World): World =
        let entry = Page.lineOf(StoryDoc.nameOf(line#speaker, w#story), line);
        let page = Page.show(w#stage#mode, fitsNvl(w), entry, w#page);
        let shown = if (quiet) Page.revealAll(page) else page;
        { page = shown, choices = Nil, doneAt = None,
          log = List.take(KindDoc.rec(w#kind)#logMax, entry :: w#log) | w }

    /// NVL の頁に行の列が入り切るか（行の数は novel.kind.json の nvlRows）。
    def fitsNvl(w: World): List[Page.Line] -> Bool = lines ->
        let k = KindDoc.rec(w#kind);
        let rows = lines |> List.foldLeft((sum, line) -> sum + Page.rowsOf(k#bodySize, k#rubySize, Layout.nvlText()#width, line), 0);
        rows <= k#nvlRows

    def firstOpen(options: List[YarnRunner.DialogueOption]): Int32 =
        options |> List.zipWithIndex |> List.find(match (_, option) -> option#available)
                |> Option.map(fst) |> Option.getWithDefault(0)

    // ── 読み進める ──

    /// 決定 1 回分（読んでいる間・窓が閉じている時）。文字送りの途中なら全文へ、出し終えていれば次の行へ。
    /// 選択肢を出している間は動かない（pick だけが進める）。オートとスキップは止める（人が押したら人の速さに戻す）。
    pub def advance(w: World): World \ Emit[Event] =
        if (w#phase != Phase.Reading or w#panel != Panel.Closed or not List.isEmpty(w#choices)) w
        else {
            let manual = { playback = Playback.Manual | w };
            if (not Page.isDone(w#page)) {
                Emit.emit(Event.Revealed);
                { page = Page.revealAll(w#page) | manual }
            } else next(manual)
        }

    /// 今の行を既読にして、次の行へ送る。[遷移: 行→次の行 / 選択肢 / シナリオの終わり(Credits)]
    def next(w: World): World \ Emit[Event] =
        let marked = markSeen(w);
        match YarnRunner.shownOf(marked#talk) {
            case YarnRunner.Shown.Line(_) =>
                Emit.emit(Event.Paged);
                let (talk, events) = YarnRunner.step(YarnRunner.Action.Advance, now(marked), marked#talk);
                absorb(false, events, { talk = talk | marked })
            case YarnRunner.Shown.Closed => toCredits(marked)
            case _                       => marked
        }

    /// 今の行を既読の印へ（初めて読んだ行の時だけ saveRev を進める = 書く）。
    def markSeen(w: World): World =
        match w#page#current {
            case Some(line) if not String.isEmpty(line#source) and not Saves.isSeen(line#source, w#saves) =>
                { saves = Saves.withSeen(line#source, w#saves), saveRev = w#saveRev + 1 | w }
            case _ => w
        }

    /// 今の行を読んだことがあるか（スキップが飛ばしてよい行か・既読の色で描くか）。
    pub def isCurrentSeen(w: World): Bool =
        match w#page#current {
            case Some(line) => Saves.isSeen(line#source, w#saves)
            case None       => false
        }

    /// 選択肢 i を選ぶ。選べない選択肢（行末の <<if>> が偽）の番号なら何もしない。[遷移: 選択肢→選んだ中身]
    pub def pick(i: Int32, w: World): World \ Emit[Event] =
        match List.nth(i, w#choices) {
            case Some(option) if option#available and w#panel == Panel.Closed =>
                Emit.emit(Event.Picked);
                let marked = markSeen(w);
                let logged = { log = List.take(KindDoc.rec(w#kind)#logMax, Page.choiceLine(option#line#text) :: marked#log),
                               choices = Nil | marked };
                let (talk, events) = YarnRunner.step(YarnRunner.Action.Choose(i), now(w), w#talk);
                absorb(false, events, { talk = talk | logged })
            case _ => w
        }

    /// 選択肢のカーソルを delta ぶん動かす（選べない選択肢は飛ばし、端で反対側へ回り込む）。
    pub def moveChoice(delta: Int32, w: World): World \ Emit[Event] =
        let open = w#choices |> List.zipWithIndex |> List.filter(match (_, option) -> option#available) |> List.map(fst);
        let count = List.length(open);
        if (count == 0) w
        else {
            let at = open |> List.zipWithIndex |> List.find(match (_, i) -> i == w#cursor) |> Option.map(fst) |> Option.getWithDefault(0);
            let next = List.nth(Int32.modulo(at + delta, count), open) |> Option.getWithDefault(w#cursor);
            if (next != w#cursor) Emit.emit(Event.Moved) else ();
            { cursor = next | w }
        }

    // ── 毎フレーム ──

    /// 毎フレーム（App が時計を進めた後）: <<wait>> が明けたら続きを流し、文字送りを進め、出し終えた時刻を記し、オートとスキップを決める。
    /// 窓を開いている間は物語の時計が止まるので、待ちも文字送りもオートも止まる。
    pub def step(w: World): World \ Emit[Event] =
        if (w#phase != Phase.Reading) w
        else {
            let waited = match YarnRunner.shownOf(w#talk) {
                case YarnRunner.Shown.Waiting =>
                    // スキップ中は待ちも飛ばす（明ける時刻をそのまま渡す）。
                    let at = if (w#playback == Playback.Skip) YarnRunner.waitUntilOf(w#talk) |> Option.getWithDefault(now(w)) else now(w);
                    let (talk, events) = YarnRunner.step(YarnRunner.Action.Tick, at, w#talk);
                    absorb(false, events, { talk = talk | w })
                case _ => w
            };
            let fast = waited#playback == Playback.Skip and isCurrentSeen(waited);
            let page = if (fast) Page.revealAll(waited#page) else Page.step(config(waited)#cps, Clock.dtOf(waited#storyClock), waited#page);
            let typed = { page = page | waited };
            let stamped = if (Page.isDone(page) and Option.isEmpty(typed#doneAt)) { doneAt = Some(now(typed)) | typed } else typed;
            autoOrSkip(stamped)
        }

    /// オートとスキップ（行を出し終えてから、決めた間が過ぎたら送る）。スキップは読んでいない行・選択肢で止まる。
    def autoOrSkip(w: World): World \ Emit[Event] =
        if (w#panel != Panel.Closed) w
        else if (w#playback == Playback.Skip and (not List.isEmpty(w#choices) or (Option.nonEmpty(w#page#current) and not isCurrentSeen(w))))
            { playback = Playback.Manual | w }
        else match w#doneAt {
            case None     => w
            case Some(at) =>
                let k = KindDoc.rec(w#kind);
                let waited = Clock.since(at, now(w));
                let chars = w#page#current |> Option.map(line -> String.length(line#text)) |> Option.getWithDefault(0);
                let autoWait = config(w)#autoWait + Int32.toFloat64(chars) * k#autoPerChar;
                match w#playback {
                    case Playback.Skip   => if (waited >= k#skipInterval) next(w) else w
                    case Playback.Auto   => if (waited >= autoWait) next(w) else w
                    case Playback.Manual => w
                }
        }

    /// 物語の時計のこのフレームの進み方（Game の App.addClock が読む）。止める理由は窓だけ。
    pub def paceOf(w: World): Clock.Pace[Story, Halt] =
        if (w#panel == Panel.Closed) Clock.paceOf(Clock.Run.Running)
        else Clock.paceOf(Clock.Run.Paused(Halt.PanelOpen))

    // ── ボタンと窓 ──

    pub def buttons(): List[Button] =
        Button.Log :: Button.Auto :: Button.Skip :: Button.Save :: Button.Load :: Button.Settings :: Button.Hide :: Button.ToTitle :: Nil

    /// 読んでいる間のボタンを押す。[遷移: Reading→各 Panel / Title]
    pub def press(button: Button, w: World): World \ Emit[Event] =
        if (w#phase != Phase.Reading or w#panel != Panel.Closed) w
        else match button {
            case Button.Log      => openPanel(Panel.Log, w)
            case Button.Auto     => Emit.emit(Event.Moved); { playback = toggled(Playback.Auto, w#playback) | w }
            case Button.Skip     => Emit.emit(Event.Moved); { playback = toggled(Playback.Skip, w#playback) | w }
            case Button.Save     => openPanel(Panel.SaveSlots, w)
            case Button.Load     => openPanel(Panel.LoadSlots, w)
            case Button.Settings => openPanel(Panel.Settings, w)
            case Button.Hide     => { panel = Panel.Hidden, playback = Playback.Manual | w }
            case Button.ToTitle  => Emit.emit(Event.Closed); toTitle(w)
        }

    /// ボタンを押した送り方: 点いていれば消し（人が押す）、そうでなければそれに替える。
    def toggled(mode: Playback, current: Playback): Playback = if (current == mode) Playback.Manual else mode

    /// 窓を開く（オートとスキップは止める。開いている間は物語の時計も止まる）。
    pub def openPanel(panel: Panel, w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        { panel = panel, cursor = 0, logOffset = 0.0, playback = Playback.Manual | w }

    /// 窓を閉じる。
    pub def closePanel(w: World): World \ Emit[Event] =
        if (w#panel == Panel.Closed) w
        else { Emit.emit(Event.Closed); { panel = Panel.Closed, cursor = 0 | w } }

    /// 窓のカーソル（栞の枠・設定の行）を動かす。数は窓ごと（端で回り込む）。
    pub def movePanelCursor(delta: Int32, count: Int32, w: World): World \ Emit[Event] =
        if (count <= 0) w
        else { Emit.emit(Event.Moved); { cursor = Int32.modulo(w#cursor + delta, count) | w } }

    /// 知らせを出す（実時間で数秒残る。長さは novel.kind.json の toastSeconds）。
    def notice(label: StoryDoc.Label, w: World): World =
        { toast = Some((StoryDoc.labelOf(label, w#story), w#realNow)) | w }

    /// 今の知らせ（消えていれば None）。
    pub def toastOf(w: World): Option[String] = match w#toast {
        case Some((text, at)) if Clock.since(at, w#realNow) < KindDoc.rec(w#kind)#toastSeconds => Some(text)
        case _ => None
    }

    // ── 栞（セーブ・ロード） ──

    /// 枠 i に栞を挟む（読んでいる所が無ければ何もしない）。
    pub def saveSlot(i: Int32, w: World): World \ Emit[Event] =
        match YarnRunner.bookmarkOf(w#talk) {
            case Some(bookmark) =>
                Emit.emit(Event.Saved);
                let place = w#stage#shot |> Option.flatMap(shot -> BackdropDoc.photoOf(shot#photo, w#backdrops))
                    |> Option.map(photo -> photo#label) |> Option.getWithDefault("");
                let excerpt = w#page#current |> Option.map(line -> String.takeLeft(28, line#text)) |> Option.getWithDefault("");
                notice(StoryDoc.Label.Saved,
                    { saves = Saves.withSlot(i, { bookmark = bookmark, place = place, excerpt = excerpt, shot = w#stage#shot,
                                                  ambience = w#stage#ambience, particles = w#stage#particles }, w#saves),
                      saveRev = w#saveRev + 1 | w })
            case None => w
        }

    /// 枠 i の栞から読む: ブックマークを当て直し、通ったコマンドを黙って畳んで舞台と頁とログを作り直す。
    /// 前のノードから持ち越す背景・環境音・粒は栞の値で戻し、背景の重ねや揺れの途中は終わりの形にする。[遷移: Title / Reading→Reading]
    pub def loadSlot(i: Int32, w: World): World \ Emit[Event] =
        match Map.get(i, w#saves#slots) {
            case Some(slot) =>
                Emit.emit(Event.Loaded);
                let fresh = reading(w);
                let (talk, events) = YarnRunner.resume(w#dialogue, slot#bookmark, now(w));
                let replayed = absorb(true, events, { talk = talk | fresh });
                let carried = { shot = slot#shot, ambience = slot#ambience, particles = slot#particles | replayed#stage };
                notice(StoryDoc.Label.Loaded, { stage = Stage.settle(carried), panel = Panel.Closed | replayed })
            case None => w
        }

    // ── 設定 ──

    pub def settings(): List[Setting] =
        Setting.TextSpeed :: Setting.AutoWait :: Setting.AmbienceVolume :: Setting.SeVolume :: Nil

    /// 設定の値の範囲と 1 押しの量（lo, hi, step）。
    pub def rangeOf(setting: Setting): (Float64, Float64, Float64) = match setting {
        case Setting.TextSpeed      => (10.0, 120.0, 10.0)
        case Setting.AutoWait       => (0.2, 4.0, 0.2)
        case Setting.AmbienceVolume => (0.0, 1.0, 0.1)
        case Setting.SeVolume       => (0.0, 1.0, 0.1)
    }

    pub def valueOf(setting: Setting, w: World): Float64 = match setting {
        case Setting.TextSpeed      => config(w)#cps
        case Setting.AutoWait       => config(w)#autoWait
        case Setting.AmbienceVolume => config(w)#ambienceVolume
        case Setting.SeVolume       => config(w)#seVolume
    }

    /// 設定の値を delta 段ぶん動かす（範囲の端で止まる）。
    pub def adjust(setting: Setting, delta: Int32, w: World): World \ Emit[Event] =
        let (lo, hi, by) = rangeOf(setting);
        let v = Float64.max(lo, Float64.min(hi, valueOf(setting, w) + Int32.toFloat64(delta) * by));
        withSetting(setting, v, w)

    /// 設定の値を v にする（つまみの帯をクリックした所の値）。
    pub def withSetting(setting: Setting, v: Float64, w: World): World \ Emit[Event] =
        let c = config(w);
        let changed = v != valueOf(setting, w);
        let next = match setting {
            case Setting.TextSpeed      => { cps = v | c }
            case Setting.AutoWait       => { autoWait = v | c }
            case Setting.AmbienceVolume => { ambienceVolume = v | c }
            case Setting.SeVolume       => { seVolume = v | c }
        };
        if (not changed) w
        else { Emit.emit(Event.Moved); { saves = Saves.withConfig(next, w#saves), saveRev = w#saveRev + 1 | w } }

    // ── ログ ──

    /// ログを delta px 遡る（0 = 一番新しい所。遡れる上限は View が描く高さで決まるので、ここでは 0 未満にしないだけ）。
    pub def scrollLog(delta: Float64, maxOffset: Float64, w: World): World =
        { logOffset = Float64.max(0.0, Float64.min(maxOffset, w#logOffset + delta)) | w }

    // ── 流れの問い・要点 ──

    /// 開いているノードの名前（閉じていれば空）。
    pub def talkNodeOf(w: World): String = YarnRunner.nodeOf(w#talk) |> Option.getWithDefault("")

    /// 今出している行のシナリオの行（ファイル:行。無ければ空）。
    pub def talkLineOf(w: World): String = w#page#current |> Option.map(line -> line#source) |> Option.getWithDefault("")

    /// 選択肢を出していて選べるか。
    pub def isAsking(w: World): Bool = not List.isEmpty(w#choices)

    /// シナリオの変数（栞や結末のテスト・flow の問い）。
    pub def variableOf(name: String, w: World): String =
        YarnRunner.valueOf(name, w#talk) |> Option.map(Yarn.toText) |> Option.getWithDefault("")

    // ── 始まりの場面（Starts・描き出し） ──

    /// node の頭から、.yarn の line 行を出している所まで進めた World（Studio の会話のプレビュー・bin/fge talk goto）。
    /// 通ったコマンドは黙って畳み、演出の途中は終わりの形にする。
    pub def openAt(storage: YarnStorage.Storage, node: String, line: Int32, w: World): World \ Emit[Event] =
        let fresh = reading(w);
        let (talk, events) = YarnRunner.startAtWith(storage, w#dialogue, node, line, now(w));
        let opened = absorb(true, events, { talk = talk | fresh });
        { stage = Stage.settle(opened#stage) | opened }

    /// 今の行を出し終えた形（描き出しが場面を作る時。時計を進めずに 1 行読み終える）。
    pub def revealLine(w: World): World = { page = Page.revealAll(w#page) | w }

    // ── Doc の差し替え（保存即反映） ──

    pub def withStory(story: StoryDoc.Doc, w: World): World =
        let w1 = { story = story | w };
        if (w1#phase == Phase.Title) { stage = titleStage(story) | w1 } else w1

    pub def withKind(kind: KindDoc.Doc, w: World): World = { kind = kind | w }

    pub def withTheme(theme: ThemeDoc.Doc, w: World): World = { theme = theme | w }

    pub def withBackdrops(backdrops: BackdropDoc.Doc, w: World): World = { backdrops = backdrops | w }

    pub def withCredits(credits: CreditsDoc.Doc, w: World): World = { credits = credits | w }

    pub def withKeys(keys: KeysDoc.Doc, w: World): World = { keys = keys | w }

    pub def withMixer(mixer: AudioMixer.Mixer, w: World): World = { mixer = mixer | w }

    /// シナリオの差し替え。読んでいる途中なら、開いているノードの頭から読み直す（編集がその場で画面に出る）。
    /// WhyNot: 読んでいた行から続けない —— 行の並びが変わると「同じ行」が決まらない。
    pub def withDialogue(dialogue: Yarn.Program, w: World): World =
        let w1 = { dialogue = dialogue | w };
        match (w1#phase, YarnRunner.nodeOf(w1#talk)) {
            case (Phase.Reading, Some(node)) if Option.nonEmpty(Yarn.nodeOf(node, dialogue)) =>
                let (talk, events) = YarnRunner.startWith(YarnRunner.storageOf(w1#talk), dialogue, node, now(w1));
                fst(Emit.collect(() -> absorb(true, events, { talk = talk, page = Page.empty(), choices = Nil | w1 })))
            case (Phase.Reading, Some(_)) => toTitle(w1)
            case _ => w1
        }
}
