// Controls — 入力の解釈・音の宣言・Doc の読み込みと読み直し（純粋。読み込みだけ Fs.FileRead）。
// キーは KeysDoc（novel.keys.json）の割り当て、クリックは Layout の矩形（View が描く所と同じ）で当てる。
// 入力の効き先は「いちばん手前の物」1 つ: 確認のウィンドウ → 開いている画面 → 選択肢 → クイックメニュー → 本文（送る）。
mod Controls {
    use fge::{App, AudioMixer, AudioMixerDoc, DocTable, Emit, Rect2}
    use fge::GameEngine.Key

    // ── 毎フレームの系 ──

    /// 実時間の今を World へ写し、文字送り・待ち・オート・スキップを 1 歩進める。
    pub def step(frame: App.Frame, w: World.World): World.World =
        let (next, events) = Emit.collectInto(() -> WorldRead.step({ realNow = frame#realNow | w }), w#events);
        { events = events | next }

    /// 入力の解釈。規則が出した出来事は events 欄に溜める（音は sounds が前後の差で読む）。
    pub def interact(frame: App.Frame, w: World.World): World.World =
        let pointed = World.withPointer({ x = frame#cursor#x, y = frame#cursor#y }, w);
        let (next, events) = Emit.collectInto(() -> interpret(frame, pointed), pointed#events);
        { events = events | next }

    /// 終了の判定（Game の App.quitWhen）。確認のウィンドウで「はい」を選んだ時だけ。
    pub def isQuit(_frame: App.Frame, w: World.World): Bool = w#quitting

    def tapped(keys: List[Key], frame: App.Frame): Bool = List.exists(key -> App.justPressed(key, frame), keys)

    def clickedOn(r: Rect2.Rect2, frame: App.Frame): Bool = frame#mouseClicked and Layout.contains(r, frame#cursor)

    def keysOf(w: World.World): KeysDoc.Rec = KeysDoc.rec(w#docs#keys)

    def interpret(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        if (Option.nonEmpty(w#ask)) askInput(frame, w)
        else if (w#panel != World.Panel.Closed) panelInput(frame, w)
        else match w#scene {
            case World.Scene.Title(_)      => titleInput(frame, w)
            case World.Scene.Reading(_)    => readingInput(frame, w)
            case World.Scene.Credits(_, _) =>
                let k = keysOf(w);
                if (World.creditsOver(w) or frame#mouseClicked or tapped(k#confirm, frame) or tapped(k#back, frame)) World.toTitle(w)
                else w
        }

    // ── 確認のウィンドウ ──

    /// はい / いいえ: ←→↑↓ でカーソル、決定で答える、戻るは「いいえ」。マウスは乗った方へカーソルを寄せ、押した方で答える。
    def askInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let hovered = Layout.sideAt(Layout.askButton, frame#cursor) |> Option.map(WorldMenu.answerOn);
        match hovered {
            case Some(a) if frame#mouseClicked => WorldMenu.answer(a, w)
            case Some(a) if frame#mouseMoved   => World.moveAsk(a, w)
            case _ =>
                if (tapped(k#back, frame)) WorldMenu.answer(World.Answer.No, w)
                else if (tapped(k#confirm, frame)) WorldMenu.answerHere(w)
                else if (tapped(k#left, frame) or tapped(k#prev, frame)) World.moveAsk(World.Answer.Yes, w)
                else if (tapped(k#right, frame) or tapped(k#next, frame)) World.moveAsk(World.Answer.No, w)
                else w
        }

    // ── タイトル ──

    def titleInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let items = WorldMenu.titleItems();
        let hovered = Layout.hitOf(List.length(items), Layout.titleItem, frame#cursor)
            |> Option.flatMap(i -> List.nth(i, items)) |> Option.filter(item -> WorldMenu.isTitleItemOpen(item, w#saves));
        match hovered {
            case Some(item) if frame#mouseClicked => WorldMenu.chooseTitle(item, w)
            case Some(item) if frame#mouseMoved   => WorldMenu.pointTitle(item, w)
            case _ =>
                if (tapped(k#quit, frame)) World.askFor(World.Ask.Quit, w)
                else if (tapped(k#prev, frame)) WorldMenu.moveTitle(-1, w)
                else if (tapped(k#next, frame)) WorldMenu.moveTitle(1, w)
                else if (tapped(k#confirm, frame)) WorldMenu.chooseTitleHere(w)
                else w
        }

    // ── 読んでいる間 ──

    def readingInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let buttons = WorldMenu.buttons();
        let pressed = Layout.hitOf(List.length(buttons), i -> Layout.button(i, List.length(buttons)), frame#cursor)
            |> Option.filter(_ -> frame#mouseClicked) |> Option.flatMap(i -> List.nth(i, buttons));
        match pressed {
            case Some(button) => WorldMenu.press(button, w)
            case None =>
                if (tapped(k#log, frame) or frame#wheel > 0.0) WorldMenu.press(World.Button.Log, w)
                else if (tapped(k#rollback, frame)) WorldMenu.press(World.Button.Rollback, w)
                else if (tapped(k#auto, frame)) WorldMenu.press(World.Button.Auto, w)
                else if (tapped(k#skip, frame)) WorldMenu.press(World.Button.Skip, w)
                else if (tapped(k#quickSave, frame)) WorldMenu.press(World.Button.QuickSave, w)
                else if (tapped(k#quickLoad, frame)) WorldMenu.press(World.Button.QuickLoad, w)
                else if (tapped(k#hide, frame) or tapped(k#back, frame)) WorldMenu.press(World.Button.Hide, w)
                else if (World.isChoosing(w)) choiceInput(frame, w)
                else if (frame#mouseClicked or tapped(k#confirm, frame)) WorldRead.advance(w)
                else w
        }

    /// 選択肢: マウスは動いたフレームだけカーソルを吸い寄せ、クリックした選択肢を選ぶ。キーは ↑↓ と決定。
    def choiceInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let count = List.length(World.choicesOf(w));
        let hovered = Layout.hitOf(count, i -> Layout.choice(i, count), frame#cursor);
        match hovered {
            case Some(i) if frame#mouseClicked => WorldRead.pick(i, w)
            case Some(i) if frame#mouseMoved   => WorldRead.pointChoice(i, w)
            case _ =>
                if (tapped(k#prev, frame)) WorldRead.moveChoice(-1, w)
                else if (tapped(k#next, frame)) WorldRead.moveChoice(1, w)
                else if (tapped(k#confirm, frame)) WorldRead.pickHere(w)
                else w
        }

    // ── 画面 ──

    def panelInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let back = tapped(k#back, frame) or clickedOn(Layout.back(), frame);
        match w#panel {
            case World.Panel.Closed => w
            case World.Panel.Hidden =>
                if (frame#mouseClicked or tapped(k#confirm, frame) or back or tapped(k#hide, frame)) World.closePanel(w)
                else w
            case World.Panel.Log(offset)     => logInput(frame, back, offset, w)
            case World.Panel.SaveSlots(_, _) => slotsInput(frame, back, w)
            case World.Panel.LoadSlots(_, _) => slotsInput(frame, back, w)
            case World.Panel.Settings(at)    => settingsInput(frame, back, at, w)
        }

    /// バックログ: ホイールと ↑↓ で遡る（一番下でホイールを下へ回すと閉じる）。戻れる行をクリックすると、その場面へ戻るか尋ねる。
    def logInput(frame: App.Frame, back: Bool, offset: Float64, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let size = View.logScrollSize(w);
        let row = View.logRowHeight(w);
        let clicked = if (frame#mouseClicked) View.logEntryAt(frame#cursor, w) else None;
        match clicked {
            case Some(i) => WorldLog.askJump(i, w)
            case None =>
                if (back or tapped(k#log, frame)) World.closePanel(w)
                else if (frame#wheel < 0.0 and offset <= 0.0) World.closePanel(w)
                else if (frame#wheel != 0.0) WorldLog.scrollLog(frame#wheel * row * 2.0, size, w)
                else if (tapped(k#prev, frame)) WorldLog.scrollLog(row, size, w)
                else if (tapped(k#next, frame)) WorldLog.scrollLog(-row, size, w)
                else w
        }

    /// セーブ・ロード: タブでページ、枠のクリックか決定で選ぶ、右上の × か Delete で削除。
    /// ↑↓ は 1 行（2 枠）、←→ は 1 枠動く。Q / E（tabPrev / tabNext）でページを替える。
    def slotsInput(frame: App.Frame, back: Bool, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let count = Saves.perPage();
        let tabs = WorldSaves.tabsOf(w);
        let tabHit = if (frame#mouseClicked) Layout.hitOf(List.length(tabs), Layout.tab, frame#cursor) |> Option.flatMap(j -> List.nth(j, tabs)) else None;
        let removeHit = if (frame#mouseClicked) Layout.hitOf(count, Layout.remove, frame#cursor) else None;
        let slotHit = Layout.hitOf(count, Layout.slot, frame#cursor);
        match (tabHit, removeHit, slotHit) {
            case (Some(tab), _, _)      => WorldSaves.withTab(tab, w)
            case (None, Some(i), _)     => WorldSaves.deleteSlot(i, w)
            case (None, None, Some(i)) if frame#mouseClicked => WorldSaves.chooseSlot(i, w)
            case (None, None, Some(i)) if frame#mouseMoved   => WorldSaves.pointSlot(i, w)
            case _ =>
                if (back) World.closePanel(w)
                else if (tapped(k#tabPrev, frame)) WorldSaves.moveTab(-1, w)
                else if (tapped(k#tabNext, frame)) WorldSaves.moveTab(1, w)
                else if (tapped(k#remove, frame)) WorldSaves.deleteHere(w)
                else if (tapped(k#prev, frame)) WorldSaves.moveSlotCursor(-2, w)
                else if (tapped(k#next, frame)) WorldSaves.moveSlotCursor(2, w)
                else if (tapped(k#left, frame)) WorldSaves.moveSlotCursor(-1, w)
                else if (tapped(k#right, frame)) WorldSaves.moveSlotCursor(1, w)
                else if (tapped(k#confirm, frame)) WorldSaves.chooseHere(w)
                else w
        }

    /// 設定: ↑↓ で行、←→ で値、決定で 2 つから選ぶ行を反対側へ・「初期設定に戻す」を押す。
    /// スライダーの帯をクリックするとその位置の値、2 つから選ぶ行はクリックした側になる。
    def settingsInput(frame: App.Frame, back: Bool, current: World.Setting, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(w);
        let rows = WorldSettings.settings();
        let hovered = Layout.hitOf(List.length(rows), Layout.settingRow, frame#cursor)
            |> Option.flatMap(i -> List.nth(i, rows) |> Option.map(s -> (i, s)));
        match hovered {
            case Some((i, setting)) if frame#mouseClicked => clickSetting(i, setting, frame, WorldSettings.pointSetting(setting, w))
            case Some((_, setting)) if frame#mouseMoved   => WorldSettings.pointSetting(setting, w)
            case _ =>
                if (back) World.closePanel(w)
                else if (tapped(k#prev, frame)) WorldSettings.moveSetting(-1, w)
                else if (tapped(k#next, frame)) WorldSettings.moveSetting(1, w)
                else if (tapped(k#left, frame)) WorldSettings.adjust(current, -1, w)
                else if (tapped(k#right, frame)) WorldSettings.adjust(current, 1, w)
                else if (tapped(k#confirm, frame)) WorldSettings.activate(current, w)
                else w
        }

    /// 設定の行 i をクリックした: スライダーは帯の位置の値、2 つから選ぶ行は押した側、押す行はボタンの上なら確認のウィンドウ。
    def clickSetting(i: Int32, setting: World.Setting, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        match setting {
            case World.Setting.Slider(slider) =>
                let range = WorldSettings.rangeOf(slider, w#docs#kind);
                let bar = Layout.settingBar(i);
                let reach = { position = { x = bar#position#x - 10.0, y = bar#position#y - 16.0 }, size = { x = bar#size#x + 20.0, y = bar#size#y + 32.0 } };
                if (not Layout.contains(reach, frame#cursor)) w
                else {
                    let t = Float64.max(0.0, Float64.min(1.0, (frame#cursor#x - bar#position#x) / bar#size#x));
                    WorldSettings.withLevel(slider, range#min + Float64.round((t * (range#max - range#min)) / range#step) * range#step, w)
                }
            case World.Setting.Pair(pair) =>
                match Layout.sideAt(side -> Layout.settingSide(i, side), frame#cursor) {
                    case Some(side) => WorldSettings.withSide(pair, side, w)
                    case None       => w
                }
            case World.Setting.Reset =>
                if (Layout.contains(Layout.settingAction(i), frame#cursor)) WorldSettings.activate(setting, w) else w
        }

    // ── 音 ──

    /// 返事の音（project.json の sounds の論理名）。ui_ は決定やカーソルへの返事、se_ はシナリオの <<se>>。
    /// 文を読み進めるたびに鳴らすと、環境音と台詞の間を音が刻んで読む邪魔になるので、送りは鳴らさない。
    pub def soundOf(event: World.Event): Option[String] = match event {
        case World.Event.Paged    => None
        case World.Event.Revealed => None
        case World.Event.Moved    => Some("ui_cursor")
        case World.Event.Picked   => Some("ui_choice")
        case World.Event.Opened   => Some("ui_open")
        case World.Event.Closed   => Some("ui_open")
        case World.Event.Saved    => Some("ui_save")
        case World.Event.Loaded   => Some("ui_save")
        case World.Event.Rolled   => Some("ui_page")
        case World.Event.Cue(name) => Some(name)
    }

    /// 1 フレームの一発の音（このフレームに溜まった出来事から）。
    pub def sounds(ws: { before = World.World, after = World.World }): List[String] =
        Emit.since(ws#before#events, ws#after#events) |> List.filterMap(soundOf)

    /// 鳴り続ける環境音（舞台の ambience。amb_<名前>）。音量はミキサーのバスが決める。
    pub def ambience(w: World.World): List[App.Sustain] =
        World.stageOf(w)#ambience |> Option.map(name -> { name = "amb_${name}", volume = 1.0, pitch = 1.0 } :: Nil)
            |> Option.getWithDefault(Nil)

    /// 音の通り道: novel.mixer.json のバスに、設定の音量（全体 × 環境音 / 効果音）を掛ける。
    /// 画面や確認のウィンドウを開いている間は snapshot「panel」（環境音を籠もらせる）。
    pub def mixerOf(w: World.World): AudioMixer.Mixer =
        let c = Saves.configOf(w#saves);
        let base = w#docs#mixer |> AudioMixer.withBusVolume("ambience", c#masterVolume * c#ambienceVolume)
                           |> AudioMixer.withBusVolume("se", c#masterVolume * c#seVolume);
        if (World.isFree(w)) base else AudioMixer.withSnapshot("panel", base)

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    pub def mixerPath(): String = "assets/novel.mixer.json"

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub def loadDocs(): World.Docs \ Fs.FileRead =
        { story = StoryDoc.load(StoryDoc.path()),
          kind = KindDoc.load(KindDoc.path()),
          theme = ThemeDoc.load(ThemeDoc.path()),
          backdrops = BackdropDoc.load(BackdropDoc.path()),
          credits = CreditsDoc.load(CreditsDoc.path()),
          keys = KeysDoc.load(KeysDoc.path()),
          mixer = AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()),
          dialogue = Talk.load() }

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る「表示中」の 3 つは、
    /// どれもこの 1 枚から導出する。docId は project.json の editor.resources[] の id と同じ物。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("story", StoryDoc.path(), w -> World.withStory(StoryDoc.load(StoryDoc.path()), w))
            :: DocTable.unnamedRow(Talk.dialoguePath(), w -> WorldRead.withDialogue(Talk.load(), w))
            :: (DocTable.row("kind", KindDoc.path(), w -> World.withKind(KindDoc.load(KindDoc.path()), w))
                |> DocTable.withActiveWhen(World.isReading))
            :: DocTable.row("theme", ThemeDoc.path(), w -> World.withTheme(ThemeDoc.load(ThemeDoc.path()), w))
            :: DocTable.row("backdrops", BackdropDoc.path(), w -> World.withBackdrops(BackdropDoc.load(BackdropDoc.path()), w))
            :: (DocTable.row("credits", CreditsDoc.path(), w -> World.withCredits(CreditsDoc.load(CreditsDoc.path()), w))
                |> DocTable.withActiveWhen(World.isCredits))
            :: DocTable.row("keys", KeysDoc.path(), w -> World.withKeys(KeysDoc.load(KeysDoc.path()), w))
            :: DocTable.row("mixer", mixerPath(), w -> World.withMixer(AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()), w))
            :: Nil
}
