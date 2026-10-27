// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 文章・分岐・結末はシナリオ assets/talk/natsukusa.yarn（YarnRunner が辿る）、舞台の畳み方は Stage、頁は Page、
// 遊んだ人ごとに残す物（セーブデータ・既読・設定）は Saves。ここは「送る・選ぶ・画面を開く・セーブ・ロード・戻る」の規則。
//
// 場面の移り変わり（Phase と、Reading の上に開く画面 Panel と、いちばん手前の確認の窓 Ask）:
//
//     Title ──はじめから──▶ Reading（Talk.Node.Opening のノードを開く）──シナリオが終わる──▶ Credits ──流れ切る・決定──▶ Title
//       │                     │  送る(advance) → YarnRunner の Advance / 選ぶ(pick) → Choose / 戻る(rollback) → 1 つ前の行
//       ├─つづきから（いちばん新しいデータを読む）──▶ Reading
//       ├─ロード──▶ LoadSlots ──データを選ぶ──▶ Reading（ブックマークを当て直す = restore）
//       ├─設定・クレジット・終了（確認の窓）
//                             └─クイックメニュー・キー──▶ Panel: Log / SaveSlots / LoadSlots / Settings / Hidden（物語の時計は止まる）
//     確認の窓（Ask）は Panel の上に開き、はいで中身（上書き・削除・ロード・この場面へ戻る・タイトルへ・終了・初期化）を行う。
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// 時計は 2 本（型で分けてあり、取り違えるとコンパイルが止まる）:
//   物語の時計 storyClock（Clock[Story]）… 文字送り・<<wait>>・背景の重ね・揺れ・オートとスキップの間。画面や確認の窓を開くと止まる。
//                                          進めるのは App だけ（Game の App.addClock・進み方は paceOf）。
//   実時間 realNow（Time[Clock.Real]）     … 蛍の光・タイトルの字の明滅・クレジット・知らせ・設定の文字の速さの見本。止まらない。
//   セーブの日時は clockBase（起動した時のその土地の時刻。Main が読んで渡す）+ realNow の秒。
//
// 戻れる所（Saves.Mark）は 3 か所が同じ物を持つ: セーブデータ・バックログの行・「戻る」。戻し方は restore 1 つで、
// ブックマークを当て直し（通ったコマンドは黙って畳む）、前のノードから持ち越す舞台は Mark の値で戻す。
//
// オートとスキップは同じ所（autoOrSkip）で決める: 行を出し終えた時刻 doneAt から、オートは「設定の待ち + 字数 × autoPerChar」、
// スキップは skipInterval ごとに送る。スキップは設定で「既読のみ」なら読んでいない行で止まり、選択肢で止まるかも設定で選ぶ。
mod World {
    use fge::{AudioMixer, Clock, Emit, Log, UiScroll, Yarn, YarnRunner, YarnStorage}

    /// 物語の時計の名前（中身は要らない）。
    pub enum Story

    /// いま画面が何をしているか。
    pub enum Phase with Eq, ToString {
        case Title
        case Reading
        case Credits
    }

    /// 開いている画面（Closed 以外は物語の時計が止まる）。Hidden = 文章の窓を隠して背景だけを見る。
    pub enum Panel with Eq, ToString {
        case Closed
        case Log
        case SaveSlots
        case LoadSlots
        case Settings
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

    /// 設定の行（左の列: 文章、右の列: 音と画面）。
    pub enum Setting with Eq, ToString {
        case TextSpeed
        case AutoWait
        case SkipScope
        case AfterChoice
        case Display
        case MasterVolume
        case AmbienceVolume
        case SeVolume
        case WindowAlpha
        case Reset
    }

    /// 設定の行の操作の形。Slider(下限, 上限, 1 押しの量)、Pair(左の言葉, 右の言葉) = 2 つから選ぶ、Action = 押すと確認の窓。
    pub enum Control {
        case Slider(Float64, Float64, Float64)
        case Pair(StoryDoc.Label, StoryDoc.Label)
        case Action
    }

    /// 確認の窓で尋ねている事。数は今のページの枠（Overwrite・Delete・Load）かバックログの行（Jump。0 = 一番新しい行）。
    pub enum Ask with Eq, ToString {
        case Overwrite(Int32)
        case Delete(Int32)
        case Load(Int32)
        case QuickLoad
        case Jump(Int32)
        case ToTitle
        case Quit
        case Reset
    }

    /// バックログの 1 行。Said = 台詞か地の文（戻れる所つき）、Chose = 選んだ選択肢。
    pub enum Entry {
        case Said(Page.Line, Option[Saves.Mark])
        case Chose(String)
    }

    /// 規則の中で起きた出来事（返事の音の材料）。Controls.interact が集めて events 欄に溜め、音は前後の差で読む。
    ///   Paged … 次の行へ送った / Revealed … 文字送りの途中で全文を出した / Moved … カーソルや値が動いた /
    ///   Picked … 選択肢を選んだ / Opened・Closed … 画面や確認の窓を開けた・閉じた / Saved・Loaded … セーブした・ロードした /
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
    /// cursor = いま開いている物（タイトル・選択肢・セーブの枠・設定）のカーソル、log = バックログ（新しい順）、
    /// logOffset = バックログを遡った量（px）、playback = 送り方、doneAt = 今の行を出し終えた物語の時刻、
    /// saves = セーブデータ・既読・設定、saveRev = saves を変えた回数（Saves を書く出力の鍵）、slotTab = セーブ・ロードの今のページ、
    /// ask / askCursor = 確認の窓（0 = はい・1 = いいえ）、pointer = マウスの位置（触れている物を明るくする）、
    /// clockBase = 起動した時のその土地の時刻（秒。セーブの日時の元）、autosavedNode = オートセーブを残した最後のノード、
    /// creditsFrom = クレジットが流れ始めた実時間、toast = 知らせの字と出した実時間、quitting = 終了を決めた。
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
        log = List[Entry],
        logOffset = Float64,
        playback = Playback,
        doneAt = Option[Clock.Time[Story]],
        saves = Saves.Saves,
        saveRev = Int32,
        slotTab = Saves.Tab,
        ask = Option[Ask],
        askCursor = Int32,
        pointer = { x = Float64, y = Float64 },
        clockBase = Int64,
        autosavedNode = String,
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

    /// 起動の World。タイトルから始まり、背景はタイトルの写真（StoryDoc の titlePhoto・titleGrade）。
    /// clockBase = 起動した時のその土地の時刻（1970-01-01 からの秒。テストと描き出しは決めた値を渡す）。
    pub def initial(docs: Docs, saves: Saves.Saves, clockBase: Int64): World =
        { phase = Phase.Title, panel = Panel.Closed,
          story = docs#story, kind = docs#kind, theme = docs#theme, backdrops = docs#backdrops,
          credits = docs#credits, keys = docs#keys, mixer = docs#mixer, dialogue = docs#dialogue,
          talk = YarnRunner.closed(), stage = titleStage(docs#story), page = Page.empty(),
          choices = Nil, cursor = 0, log = Nil, logOffset = 0.0, playback = Playback.Manual, doneAt = None,
          saves = saves, saveRev = 0, slotTab = Saves.Tab.Numbered(1), ask = None, askCursor = 1,
          pointer = { x = -1.0, y = -1.0 }, clockBase = clockBase, autosavedNode = "",
          storyClock = Clock.start(), realNow = Clock.zero(),
          creditsFrom = Clock.zero(), toast = None, quitting = false, events = Emit.empty() }

    /// タイトルの舞台（写真は重ね終わっている）。
    def titleStage(story: StoryDoc.Doc): Stage.Stage =
        let r = StoryDoc.rec(story);
        { shot = Some({ photo = r#titlePhoto, grade = r#titleGrade }),
          ambience = if (String.isEmpty(r#titleAmbience)) None else Some(r#titleAmbience) | Stage.empty() }

    def now(w: World): Clock.Time[Story] = Clock.nowOf(w#storyClock)

    def config(w: World): Saves.Config = Saves.configOf(w#saves)

    /// マウスの位置を写す（Controls が毎フレーム。触れている物を明るくする View が読む）。
    pub def withPointer(p: { x = Float64, y = Float64 }, w: World): World = { pointer = p | w }

    // ── タイトル ──

    pub def titleItems(): List[TitleItem] =
        TitleItem.NewGame :: TitleItem.Continue :: TitleItem.LoadGame :: TitleItem.Settings :: TitleItem.Credits :: TitleItem.Quit :: Nil

    /// タイトルの項目を選べるか（データが無い時の「つづきから」は薄く出して選べない）。
    pub def isTitleItemOpen(item: TitleItem, w: World): Bool = match item {
        case TitleItem.Continue => Saves.hasAny(w#saves)
        case _                  => true
    }

    /// タイトルの項目を選ぶ。[遷移: Title→Reading / LoadSlots / Settings / Credits / 確認の窓（終了）]
    pub def chooseTitle(item: TitleItem, w: World): World \ Emit[Event] = match item {
        case TitleItem.NewGame  => newGame(w)
        case TitleItem.Continue =>
            match Saves.latest(w#saves) {
                case Some((tab, i)) => loadFrom(tab, i, w)
                case None           => notice(StoryDoc.Label.NoSave, w)
            }
        case TitleItem.LoadGame => openPanel(Panel.LoadSlots, w)
        case TitleItem.Settings => openPanel(Panel.Settings, w)
        case TitleItem.Credits  => toCredits(w)
        case TitleItem.Quit     => askFor(Ask.Quit, w)
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
                showLine(false, None, { speaker = "", text = "（シナリオが読めない。assets/talk/natsukusa.yarn を直して bin/fge yarn build assets/talk を流すと、ここに物語が流れる）",
                                        parts = Nil, tags = Nil, source = { file = "", line = 0 } }, fresh)
        }

    /// 読み始める前の World（舞台・頁・バックログを空に）。
    pub def reading(w: World): World =
        { phase = Phase.Reading, panel = Panel.Closed, ask = None, talk = YarnRunner.closed(), stage = Stage.empty(),
          page = Page.empty(), choices = Nil, cursor = 0, log = Nil, logOffset = 0.0,
          playback = Playback.Manual, doneAt = None, autosavedNode = "" | w }

    /// タイトルへ戻る。[遷移: Reading / Credits→Title]
    pub def toTitle(w: World): World =
        { phase = Phase.Title, panel = Panel.Closed, ask = None, talk = YarnRunner.closed(), stage = titleStage(w#story),
          page = Page.empty(), choices = Nil, cursor = 0, log = Nil, playback = Playback.Manual, doneAt = None,
          autosavedNode = "" | w }

    /// クレジットを流す。[遷移: Reading / Title→Credits]
    pub def toCredits(w: World): World =
        { phase = Phase.Credits, panel = Panel.Closed, ask = None, talk = YarnRunner.closed(), choices = Nil,
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

    /// 実行器が返した出来事を順に畳む。quiet = 効果音を鳴らさずオートセーブもしない（ロード・戻るの当て直し）。
    /// 台詞ごとの戻れる所は、最後のブックマークから「その台詞より後に受けた入力」の数だけ入力を外した物
    /// （台詞は送る 1 回、選択肢は選ぶ 1 回で次へ進むので、後ろに出た台詞と選択肢の数がそのまま外す数）。
    /// [遷移: シナリオが終わる(Done) → Credits]
    def absorb(quiet: Bool, events: List[YarnRunner.Event], w: World): World \ Emit[Event] =
        let last = YarnRunner.bookmarkOf(w#talk);
        List.zip(events, inputsAfter(events)) |> List.foldLeft((acc, pair) -> {
            let (event, later) = pair;
            match event {
                case YarnRunner.Event.Line(line)       => showLine(quiet, markAt(last, later, acc#stage), line, acc)
                case YarnRunner.Event.Choices(options) => { choices = options, cursor = firstOpen(options) | acc }
                case YarnRunner.Event.Command(command) => cue(quiet, command, acc)
                case YarnRunner.Event.Done             => toCredits(acc)
            }
        }, w)

    /// 出来事ごとに、それより後ろに出た台詞と選択肢の数。
    def inputsAfter(events: List[YarnRunner.Event]): List[Int32] =
        let isInput = event -> match event {
            case YarnRunner.Event.Line(_)    => 1
            case YarnRunner.Event.Choices(_) => 1
            case _                           => 0
        };
        fst(List.foldRight((event, acc) -> {
            let (counts, n) = acc;
            (n :: counts, n + isInput(event))
        }, (Nil, 0), events))

    /// 最後のブックマークから入力を later 個外した所と、その時の舞台。
    def markAt(last: Option[YarnRunner.Bookmark], later: Int32, stage: Stage.Stage): Option[Saves.Mark] =
        last |> Option.map(b -> {
            let kept = Int32.max(0, List.length(b#steps) - later);
            { bookmark = { steps = List.take(kept, b#steps) | b }, shot = stage#shot, ambience = stage#ambience,
              particles = stage#particles, mode = stage#mode }
        })

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

    /// 台詞 1 行を頁とバックログへ。NVL で頁に入り切らない時は頁をめくってから積む。新しいノードの最初の行ならオートセーブ。
    def showLine(quiet: Bool, mark: Option[Saves.Mark], line: Yarn.Line, w: World): World =
        let entry = Page.lineOf(StoryDoc.nameOf(line#speaker, w#story), line);
        let page = Page.show(w#stage#mode, fitsNvl(w), entry, w#page);
        let shown = { page = if (quiet) Page.revealAll(page) else page, choices = Nil, doneAt = None,
                      log = List.take(KindDoc.rec(w#kind)#logMax, Entry.Said(entry, mark) :: w#log) | w };
        if (quiet) shown else autosave(mark, shown)

    /// NVL の頁に行の列が入り切るか（行の数は novel.kind.json の nvlRows）。
    def fitsNvl(w: World): List[Page.Line] -> Bool = lines ->
        let k = KindDoc.rec(w#kind);
        let rows = lines |> List.foldLeft((sum, line) -> sum + Page.rowsOf(k#bodySize, k#rubySize, Layout.nvlText()#width, line), 0);
        rows <= k#nvlRows

    def firstOpen(options: List[YarnRunner.DialogueOption]): Int32 =
        options |> List.zipWithIndex |> List.find(match (_, option) -> option#available)
                |> Option.map(fst) |> Option.getWithDefault(0)

    // ── 読み進める ──

    /// 決定 1 回分（読んでいる間・画面が閉じている時）。文字送りの途中なら全文へ、出し終えていれば次の行へ。
    /// 選択肢を出している間は動かない（pick だけが進める）。オートとスキップは止める（人が押したら人の速さに戻す）。
    pub def advance(w: World): World \ Emit[Event] =
        if (w#phase != Phase.Reading or not isFree(w) or not List.isEmpty(w#choices)) w
        else {
            let manual = { playback = Playback.Manual | w };
            if (not Page.isDone(w#page)) {
                Emit.emit(Event.Revealed);
                { page = Page.revealAll(w#page) | manual }
            } else next(manual)
        }

    /// 画面も確認の窓も開いていないか。
    def isFree(w: World): Bool = w#panel == Panel.Closed and Option.isEmpty(w#ask)

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

    /// 今の行を読んだことがあるか（既読の色で描くか）。
    pub def isCurrentSeen(w: World): Bool =
        match w#page#current {
            case Some(line) => Saves.isSeen(line#source, w#saves)
            case None       => false
        }

    /// スキップが今の行を飛ばしてよいか（既読か、設定が「未読も」）。
    def isSkippable(w: World): Bool = isCurrentSeen(w) or config(w)#skipScope == Saves.SkipScope.Everything

    /// 選択肢 i を選ぶ。選べない選択肢（行末の <<if>> が偽）の番号なら何もしない。[遷移: 選択肢→選んだ中身]
    pub def pick(i: Int32, w: World): World \ Emit[Event] =
        match List.nth(i, w#choices) {
            case Some(option) if option#available and isFree(w) =>
                Emit.emit(Event.Picked);
                let marked = markSeen(w);
                let logged = { log = List.take(KindDoc.rec(w#kind)#logMax, Entry.Chose(option#line#text) :: marked#log),
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
    /// 画面や確認の窓を開いている間は物語の時計が止まるので、待ちも文字送りもオートも止まる。
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
            let fast = waited#playback == Playback.Skip and isSkippable(waited);
            let page = if (fast) Page.revealAll(waited#page) else Page.step(config(waited)#cps, Clock.dtOf(waited#storyClock), waited#page);
            let typed = { page = page | waited };
            let stamped = if (Page.isDone(page) and Option.isEmpty(typed#doneAt)) { doneAt = Some(now(typed)) | typed } else typed;
            autoOrSkip(stamped)
        }

    /// オートとスキップ（行を出し終えてから、決めた間が過ぎたら送る）。
    /// スキップは選択肢で止まるか待つか（設定の「選択肢の後」）、読んでいない行で止まるか（設定の「スキップ」）。
    def autoOrSkip(w: World): World \ Emit[Event] =
        if (not isFree(w)) w
        else if (w#playback == Playback.Skip and isAsking(w))
            if (config(w)#afterChoice == Saves.AfterChoice.StopSkip) { playback = Playback.Manual | w } else w
        else if (w#playback == Playback.Skip and Option.nonEmpty(w#page#current) and not isSkippable(w))
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

    /// 物語の時計のこのフレームの進み方（Game の App.addClock が読む）。止める理由は確認の窓と画面。
    pub def paceOf(w: World): Clock.Pace[Story, Halt] =
        if (Option.nonEmpty(w#ask)) Clock.paceOf(Clock.Run.Paused(Halt.Asking))
        else if (w#panel != Panel.Closed) Clock.paceOf(Clock.Run.Paused(Halt.PanelOpen))
        else Clock.paceOf(Clock.Run.Running)

    // ── クイックメニューと画面 ──

    pub def buttons(): List[Button] =
        Button.Rollback :: Button.Log :: Button.Auto :: Button.Skip :: Button.QuickSave :: Button.QuickLoad ::
        Button.Save :: Button.Load :: Button.Settings :: Button.Hide :: Button.ToTitle :: Nil

    /// クイックメニューを押す。[遷移: Reading→各 Panel / 確認の窓]
    pub def press(button: Button, w: World): World \ Emit[Event] =
        if (w#phase != Phase.Reading or not isFree(w)) w
        else match button {
            case Button.Rollback  => rollback(w)
            case Button.Log       => openPanel(Panel.Log, w)
            case Button.Auto      => Emit.emit(Event.Moved); { playback = toggled(Playback.Auto, w#playback) | w }
            case Button.Skip      => Emit.emit(Event.Moved); { playback = toggled(Playback.Skip, w#playback) | w }
            case Button.QuickSave => quickSave(w)
            case Button.QuickLoad =>
                if (Option.nonEmpty(Saves.slotOf(Saves.Tab.Quick, 0, w#saves))) askFor(Ask.QuickLoad, w)
                else notice(StoryDoc.Label.NoQuickSave, w)
            case Button.Save      => openPanel(Panel.SaveSlots, w)
            case Button.Load      => openPanel(Panel.LoadSlots, w)
            case Button.Settings  => openPanel(Panel.Settings, w)
            case Button.Hide      => { panel = Panel.Hidden, playback = Playback.Manual | w }
            case Button.ToTitle   => askFor(Ask.ToTitle, w)
        }

    /// ボタンを押した送り方: 点いていれば消し（人が押す）、そうでなければそれに替える。
    def toggled(mode: Playback, current: Playback): Playback = if (current == mode) Playback.Manual else mode

    /// 画面を開く（オートとスキップは止める。開いている間は物語の時計も止まる）。
    /// セーブはオートとクイックのページに書かないので、書けるページで開く。ロードはいちばん新しいデータのページで開く。
    pub def openPanel(panel: Panel, w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        let tab = match panel {
            case Panel.SaveSlots => if (Saves.isWritable(w#slotTab)) w#slotTab else Saves.Tab.Numbered(1)
            case Panel.LoadSlots => Saves.latest(w#saves) |> Option.map(fst) |> Option.getWithDefault(w#slotTab)
            case _               => w#slotTab
        };
        { panel = panel, cursor = 0, logOffset = 0.0, playback = Playback.Manual, slotTab = tab | w }

    /// 画面を閉じる。
    pub def closePanel(w: World): World \ Emit[Event] =
        if (w#panel == Panel.Closed) w
        else { Emit.emit(Event.Closed); { panel = Panel.Closed, cursor = 0 | w } }

    /// 画面のカーソル（セーブの枠・設定の行）を動かす。数は画面ごと（端で回り込む）。
    pub def movePanelCursor(delta: Int32, count: Int32, w: World): World \ Emit[Event] =
        if (count <= 0) w
        else { Emit.emit(Event.Moved); { cursor = Int32.modulo(w#cursor + delta, count) | w } }

    /// カーソルを i へ（マウスが乗った物。同じなら音を出さない）。
    pub def pointAt(i: Int32, w: World): World \ Emit[Event] =
        if (i == w#cursor) w else { Emit.emit(Event.Moved); { cursor = i | w } }

    /// 知らせを出す（実時間で数秒残る。長さは novel.kind.json の toastSeconds）。
    def notice(label: StoryDoc.Label, w: World): World =
        { toast = Some((StoryDoc.labelOf(label, w#story), w#realNow)) | w }

    /// 今の知らせ（消えていれば None）。
    pub def toastOf(w: World): Option[String] = match w#toast {
        case Some((text, at)) if Clock.since(at, w#realNow) < KindDoc.rec(w#kind)#toastSeconds => Some(text)
        case _ => None
    }

    // ── 確認の窓 ──

    /// 確認の窓を開く（カーソルは「いいえ」から。決定を押し続けても進まない）。
    pub def askFor(ask: Ask, w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        { ask = Some(ask), askCursor = 1, playback = Playback.Manual | w }

    /// 窓の閉じるボタン（App.withCloseRequest）: 終了を尋ねる。もう尋ねていれば何もしない。
    pub def requestQuit(w: World): World =
        if (w#ask == Some(Ask.Quit)) w else { ask = Some(Ask.Quit), askCursor = 1, playback = Playback.Manual | w }

    /// 確認の窓のカーソル（はい / いいえ）を替える。
    pub def moveAsk(i: Int32, w: World): World \ Emit[Event] =
        let next = Int32.max(0, Int32.min(1, i));
        if (next == w#askCursor) w else { Emit.emit(Event.Moved); { askCursor = next | w } }

    /// 確認の窓に答える。はいなら尋ねていた事を行う。[遷移: 確認の窓→各行き先]
    pub def answer(yes: Bool, w: World): World \ Emit[Event] =
        match w#ask {
            case None => w
            case Some(ask) =>
                let closed = { ask = None | w };
                if (not yes) { Emit.emit(Event.Closed); closed }
                else match ask {
                    case Ask.Overwrite(i) => writeSlot(w#slotTab, i, closed)
                    case Ask.Delete(i)    =>
                        Emit.emit(Event.Closed);
                        notice(StoryDoc.Label.Deleted, { saves = Saves.withoutSlot(w#slotTab, i, w#saves), saveRev = w#saveRev + 1 | closed })
                    case Ask.Load(i)      => loadFrom(w#slotTab, i, closed)
                    case Ask.QuickLoad    => loadFrom(Saves.Tab.Quick, 0, closed)
                    case Ask.Jump(k)      => jumpTo(k, closed)
                    case Ask.ToTitle      => Emit.emit(Event.Closed); toTitle(closed)
                    case Ask.Quit         => { quitting = true | closed }
                    case Ask.Reset        =>
                        Emit.emit(Event.Moved);
                        notice(StoryDoc.Label.ResetDone,
                               { saves = Saves.withConfig(Saves.defaultConfig(w#kind), w#saves), saveRev = w#saveRev + 1 | closed })
                }
        }

    // ── セーブ・ロード ──

    /// 今の所のデータ（読んでいる所が無ければ None）。mark を渡せばその戻れる所で、無ければ今のブックマークで作る。
    def slotHere(mark: Option[Saves.Mark], w: World): Option[Saves.Slot] =
        let here = match mark {
            case Some(m) => Some(m)
            case None    => markAt(YarnRunner.bookmarkOf(w#talk), 0, w#stage)
        };
        here |> Option.map(m -> {
            let place = m#shot |> Option.flatMap(shot -> BackdropDoc.photoOf(shot#photo, w#backdrops))
                |> Option.map(photo -> photo#label) |> Option.getWithDefault("");
            let (speaker, excerpt) = w#page#current |> Option.map(line -> (line#speaker, String.takeLeft(80, line#text)))
                |> Option.getWithDefault(("", ""));
            let page = if (m#mode == Stage.Mode.Adv) w#page#current |> Option.map(line -> line#text) |> Option.toList
                else List.append(w#page#lines, w#page#current |> Option.toList)
                    |> List.map(line -> if (String.isEmpty(line#speaker)) line#text else "${line#speaker}${line#text}");
            { mark = m, place = place, speaker = speaker, excerpt = excerpt, page = page, savedAt = savedAtNow(w),
              serial = Saves.nextSerial(w#saves) }
        })

    /// 今のその土地の時刻（秒）。
    def savedAtNow(w: World): Int64 =
        w#clockBase + (Float64.tryToInt64(Float64.floor(Clock.secondsOf(w#realNow))) |> Option.getWithDefault(0i64))

    /// ページ tab の i 枠目に書く。
    pub def writeSlot(tab: Saves.Tab, i: Int32, w: World): World \ Emit[Event] =
        match slotHere(None, w) {
            case Some(slot) =>
                Emit.emit(Event.Saved);
                notice(StoryDoc.Label.Saved, { saves = Saves.withSlot(tab, i, slot, w#saves), saveRev = w#saveRev + 1 | w })
            case None => w
        }

    /// クイックセーブ（クイックのページの先頭へ。前の物は後ろへ押す）。
    pub def quickSave(w: World): World \ Emit[Event] =
        match slotHere(None, w) {
            case Some(slot) =>
                Emit.emit(Event.Saved);
                notice(StoryDoc.Label.QuickSaved, { saves = Saves.withPushed(Saves.Tab.Quick, slot, w#saves), saveRev = w#saveRev + 1 | w })
            case None => w
        }

    /// 新しいノードの最初の行でオートセーブ（オートのページの先頭へ。音も知らせも出さない）。
    def autosave(mark: Option[Saves.Mark], w: World): World =
        let node = talkNodeOf(w);
        if (String.isEmpty(node) or node == w#autosavedNode) w
        else match slotHere(mark, w) {
            case Some(slot) =>
                { saves = Saves.withPushed(Saves.Tab.Auto, slot, w#saves), saveRev = w#saveRev + 1, autosavedNode = node | w }
            case None => w
        }

    /// 今のページの i 枠目を選ぶ（セーブ: 空なら書き、あれば上書きを尋ねる。ロード: タイトルからはすぐ読み、読んでいる途中なら尋ねる）。
    pub def chooseSlot(i: Int32, w: World): World \ Emit[Event] =
        let filled = Option.nonEmpty(Saves.slotOf(w#slotTab, i, w#saves));
        match w#panel {
            case Panel.SaveSlots =>
                if (not Saves.isWritable(w#slotTab)) w
                else if (filled) askFor(Ask.Overwrite(i), w)
                else writeSlot(w#slotTab, i, w)
            case Panel.LoadSlots =>
                if (not filled) w
                else if (w#phase == Phase.Reading) askFor(Ask.Load(i), w)
                else loadFrom(w#slotTab, i, w)
            case _ => w
        }

    /// 今のページの i 枠目を消すか尋ねる（空なら何もしない）。
    pub def deleteSlot(i: Int32, w: World): World \ Emit[Event] =
        if (Option.isEmpty(Saves.slotOf(w#slotTab, i, w#saves))) w else askFor(Ask.Delete(i), w)

    /// セーブ・ロードのページを替える（セーブ画面は書けるページだけを巡る）。
    pub def withTab(tab: Saves.Tab, w: World): World \ Emit[Event] =
        if (tab == w#slotTab) w else { Emit.emit(Event.Moved); { slotTab = tab, cursor = 0 | w } }

    /// 今の画面のページの並び。
    pub def tabsOf(w: World): List[Saves.Tab] =
        if (w#panel == Panel.SaveSlots) Saves.writableTabs() else Saves.tabs()

    /// ページを delta ぶん替える（端で回り込む）。
    pub def moveTab(delta: Int32, w: World): World \ Emit[Event] =
        let tabs = tabsOf(w);
        let count = List.length(tabs);
        let at = tabs |> List.zipWithIndex |> List.find(match (_, tab) -> tab == w#slotTab) |> Option.map(fst) |> Option.getWithDefault(0);
        match List.nth(Int32.modulo(at + delta, Int32.max(1, count)), tabs) {
            case Some(tab) => withTab(tab, w)
            case None      => w
        }

    /// ページ tab の i 枠目から読む。[遷移: Title / Reading→Reading]
    pub def loadFrom(tab: Saves.Tab, i: Int32, w: World): World \ Emit[Event] =
        match Saves.slotOf(tab, i, w#saves) {
            case Some(slot) =>
                Emit.emit(Event.Loaded);
                notice(StoryDoc.Label.Loaded, restore(slot#mark, w))
            case None => w
        }

    /// 戻れる所へ戻す: ブックマークを当て直し、通ったコマンドを黙って畳んで舞台と頁とバックログを作り直す。
    /// 前のノードから持ち越す背景・環境音・粒・文章の出し方は Mark の値から始め、背景の重ねや揺れの途中は終わりの形にする。
    def restore(mark: Saves.Mark, w: World): World \ Emit[Event] =
        let carried = { shot = mark#shot, ambience = mark#ambience, particles = mark#particles, mode = mark#mode | Stage.empty() };
        let fresh = { stage = carried | reading(w) };
        let (talk, events) = YarnRunner.resume(w#dialogue, mark#bookmark, now(w));
        let replayed = absorb(true, events, { talk = talk | fresh });
        { stage = Stage.settle(replayed#stage), autosavedNode = talkNodeOf(replayed) | replayed }

    // ── 戻る・バックログ ──

    /// 1 つ前の行へ戻る（選択肢を出している間は、問いの行へ戻って選び直せる形に）。
    pub def rollback(w: World): World \ Emit[Event] =
        let first = if (isAsking(w)) 0 else 1;
        let target = w#log |> List.zipWithIndex |> List.find(match (i, entry) -> i >= first and isJumpable(entry)) |> Option.map(fst);
        match target {
            case Some(k) => jumpTo(k, w)
            case None    => notice(StoryDoc.Label.NoRollback, w)
        }

    /// バックログの行が戻れる所を持つか。
    pub def isJumpable(entry: Entry): Bool = match entry {
        case Entry.Said(_, Some(_)) => true
        case Entry.Said(_, None)    => false
        case Entry.Chose(_)         => false
    }

    /// バックログの k 行目（0 = 一番新しい）の場面へ戻るか尋ねる（戻れない行なら何もしない）。
    pub def askJump(k: Int32, w: World): World \ Emit[Event] =
        match List.nth(k, w#log) {
            case Some(entry) if k > 0 and isJumpable(entry) => askFor(Ask.Jump(k), w)
            case _ => w
        }

    /// バックログの k 行目の場面へ戻る。バックログはその行までに切り詰める（その先は読み直す）。
    def jumpTo(k: Int32, w: World): World \ Emit[Event] =
        match List.nth(k, w#log) {
            case Some(Entry.Said(_, Some(mark))) =>
                Emit.emit(Event.Rolled);
                { log = List.drop(k, w#log) | restore(mark, w) }
            case _ => w
        }

    /// バックログを delta px 遡る（0 = 一番新しい所。長さは View が描く高さ）。
    pub def scrollLog(delta: Float64, size: { contentPx = Float64, viewportPx = Float64 }, w: World): World =
        { logOffset = UiScroll.scrollByPx(delta, size, w#logOffset) | w }

    // ── 設定 ──

    pub def settings(): List[Setting] =
        Setting.TextSpeed :: Setting.AutoWait :: Setting.SkipScope :: Setting.AfterChoice :: Setting.Display ::
        Setting.MasterVolume :: Setting.AmbienceVolume :: Setting.SeVolume :: Setting.WindowAlpha :: Setting.Reset :: Nil

    /// 左の列（文章）に並べる行の数。残りは右の列（音と画面）。
    pub def leftColumnRows(): Int32 = 5

    pub def controlOf(setting: Setting): Control = match setting {
        case Setting.TextSpeed      => Control.Slider(10.0, 120.0, 10.0)
        case Setting.AutoWait       => Control.Slider(0.2, 4.0, 0.2)
        case Setting.MasterVolume   => Control.Slider(0.0, 1.0, 0.1)
        case Setting.AmbienceVolume => Control.Slider(0.0, 1.0, 0.1)
        case Setting.SeVolume       => Control.Slider(0.0, 1.0, 0.1)
        case Setting.WindowAlpha    => Control.Slider(0.2, 1.0, 0.1)
        case Setting.SkipScope      => Control.Pair(StoryDoc.Label.SkipReadOnly, StoryDoc.Label.SkipEverything)
        case Setting.AfterChoice    => Control.Pair(StoryDoc.Label.StopSkip, StoryDoc.Label.KeepSkip)
        case Setting.Display        => Control.Pair(StoryDoc.Label.WindowMode, StoryDoc.Label.FullscreenMode)
        case Setting.Reset          => Control.Action
    }

    /// 行の値（つまみは値そのもの、2 つから選ぶ行は 0 = 左・1 = 右、押す行は 0）。
    pub def valueOf(setting: Setting, w: World): Float64 =
        let c = config(w);
        let side = b -> if (b) 1.0 else 0.0;
        match setting {
            case Setting.TextSpeed      => c#cps
            case Setting.AutoWait       => c#autoWait
            case Setting.MasterVolume   => c#masterVolume
            case Setting.AmbienceVolume => c#ambienceVolume
            case Setting.SeVolume       => c#seVolume
            case Setting.WindowAlpha    => c#windowAlpha
            case Setting.SkipScope      => side(c#skipScope == Saves.SkipScope.Everything)
            case Setting.AfterChoice    => side(c#afterChoice == Saves.AfterChoice.KeepSkip)
            case Setting.Display        => side(c#display == Saves.Display.Fullscreen)
            case Setting.Reset          => 0.0
        }

    /// 設定の値を delta 段ぶん動かす（つまみは範囲の端で止まる。2 つから選ぶ行は delta の向きの側へ）。
    pub def adjust(setting: Setting, delta: Int32, w: World): World \ Emit[Event] =
        match controlOf(setting) {
            case Control.Slider(lo, hi, by) =>
                withSetting(setting, Float64.max(lo, Float64.min(hi, valueOf(setting, w) + Int32.toFloat64(delta) * by)), w)
            case Control.Pair(_, _) => withSetting(setting, if (delta > 0) 1.0 else 0.0, w)
            case Control.Action     => w
        }

    /// 決定で行を押す（2 つから選ぶ行は反対側へ、押す行は確認の窓）。
    pub def activate(setting: Setting, w: World): World \ Emit[Event] =
        match controlOf(setting) {
            case Control.Pair(_, _)   => withSetting(setting, 1.0 - valueOf(setting, w), w)
            case Control.Action       => askFor(Ask.Reset, w)
            case Control.Slider(_, _, _) => w
        }

    /// 設定の値を v にする（つまみの帯をクリックした所の値・2 つから選ぶ行の 0 / 1）。
    pub def withSetting(setting: Setting, v: Float64, w: World): World \ Emit[Event] =
        let c = config(w);
        let right = v >= 0.5;
        let next = match setting {
            case Setting.TextSpeed      => { cps = v | c }
            case Setting.AutoWait       => { autoWait = v | c }
            case Setting.MasterVolume   => { masterVolume = v | c }
            case Setting.AmbienceVolume => { ambienceVolume = v | c }
            case Setting.SeVolume       => { seVolume = v | c }
            case Setting.WindowAlpha    => { windowAlpha = v | c }
            case Setting.SkipScope      => { skipScope = if (right) Saves.SkipScope.Everything else Saves.SkipScope.ReadOnly | c }
            case Setting.AfterChoice    => { afterChoice = if (right) Saves.AfterChoice.KeepSkip else Saves.AfterChoice.StopSkip | c }
            case Setting.Display        => { display = if (right) Saves.Display.Fullscreen else Saves.Display.Window | c }
            case Setting.Reset          => c
        };
        let changed = { saves = Saves.withConfig(next, w#saves), saveRev = w#saveRev + 1 | w };
        if (valueOf(setting, changed) == valueOf(setting, w)) w
        else { Emit.emit(Event.Moved); changed }

    /// フルスクリーンにしたいか（Game の App.withFullscreen）。
    pub def isFullscreen(w: World): Bool = config(w)#display == Saves.Display.Fullscreen

    // ── 流れの問い・要点 ──

    /// 開いているノードの名前（閉じていれば空）。
    pub def talkNodeOf(w: World): String = YarnRunner.nodeOf(w#talk) |> Option.getWithDefault("")

    /// 今出している行のシナリオの行（ファイル:行。無ければ空）。
    pub def talkLineOf(w: World): String = w#page#current |> Option.map(line -> line#source) |> Option.getWithDefault("")

    /// 選択肢を出していて選べるか。
    pub def isAsking(w: World): Bool = not List.isEmpty(w#choices)

    /// シナリオの変数（セーブや結末のテスト・flow の問い）。
    pub def variableOf(name: String, w: World): String =
        YarnRunner.valueOf(name, w#talk) |> Option.map(Yarn.toText) |> Option.getWithDefault("")

    // ── 始まりの場面（Starts・描き出し） ──

    /// node の頭から、.yarn の line 行を出している所まで進めた World（Studio の会話のプレビュー・bin/fge talk goto）。
    /// 通ったコマンドは黙って畳み、演出の途中は終わりの形にする。
    pub def openAt(storage: YarnStorage.Storage, node: String, line: Int32, w: World): World \ Emit[Event] =
        let fresh = reading(w);
        let (talk, events) = YarnRunner.startAtWith(storage, w#dialogue, node, line, now(w));
        let opened = absorb(true, events, { talk = talk | fresh });
        { stage = Stage.settle(opened#stage), autosavedNode = talkNodeOf(opened) | opened }

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
