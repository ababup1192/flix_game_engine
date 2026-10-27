// Controls — 入力の解釈・音の宣言・Doc の読み込みと読み直し（純粋。読み込みだけ Fs.FileRead）。
// キーは KeysDoc（novel.keys.json）の割り当て、クリックは Layout の矩形（View が描く所と同じ）で当てる。
// 入力の効き先は「いちばん手前の物」1 つ: 開いている窓 → 選択肢 → 読んでいる間のボタン → 本文（送る）。
mod Controls {
    use fge::{App, AudioMixer, AudioMixerDoc, DocTable, Emit, Rect2}
    use fge::GameEngine.Key

    // ── 毎フレームの系 ──

    /// 実時間の今を World へ写し、文字送り・待ち・オート・スキップを 1 歩進める。
    pub def step(frame: App.Frame, w: World.World): World.World =
        let (next, events) = Emit.collectInto(() -> World.step({ realNow = frame#realNow | w }), w#events);
        { events = events | next }

    /// 入力の解釈。規則が出した出来事は events 欄に溜める（音は sounds が前後の差で読む）。
    pub def interact(frame: App.Frame, w: World.World): World.World =
        let (next, events) = Emit.collectInto(() -> interpret(frame, w), w#events);
        { events = events | next }

    /// 終了の判定（Game の App.quitWhen）。表紙で「おわる」を選んだか、表紙で quit のキーを押した時。
    pub def isQuit(frame: App.Frame, w: World.World): Bool =
        w#quitting or (w#phase == World.Phase.Title and w#panel == World.Panel.Closed and tapped(KeysDoc.rec(w#keys)#quit, frame))

    def tapped(keys: List[Key], frame: App.Frame): Bool = List.exists(key -> App.justPressed(key, frame), keys)

    def interpret(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        if (w#panel != World.Panel.Closed) panelInput(frame, w)
        else match w#phase {
            case World.Phase.Title   => titleInput(frame, w)
            case World.Phase.Reading => readingInput(frame, w)
            case World.Phase.Credits =>
                let k = KeysDoc.rec(w#keys);
                if (World.creditsOver(w) or frame#mouseClicked or tapped(k#confirm, frame) or tapped(k#back, frame)) World.toTitle(w)
                else w
        }

    // ── 表紙 ──

    def titleInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = KeysDoc.rec(w#keys);
        let items = World.titleItems();
        let count = List.length(items);
        let hovered = List.range(0, count) |> List.find(i -> Layout.contains(Layout.titleItem(i), frame#cursor));
        let w1 = match hovered {
            case Some(i) if frame#mouseMoved and i != w#cursor => { cursor = i | w }
            case _ => w
        };
        if (frame#mouseClicked)
            match hovered |> Option.flatMap(i -> List.nth(i, items)) {
                case Some(item) => World.chooseTitle(item, w1)
                case None       => w1
            }
        else if (tapped(k#prev, frame)) World.movePanelCursor(-1, count, w1)
        else if (tapped(k#next, frame)) World.movePanelCursor(1, count, w1)
        else if (tapped(k#confirm, frame))
            match List.nth(w1#cursor, items) {
                case Some(item) => World.chooseTitle(item, w1)
                case None       => w1
            }
        else w1

    // ── 読んでいる間 ──

    def readingInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = KeysDoc.rec(w#keys);
        let buttons = World.buttons();
        let pressed = buttons |> List.zipWithIndex |> List.find(match (i, _) ->
            frame#mouseClicked and Layout.contains(Layout.button(i, List.length(buttons)), frame#cursor)) |> Option.map(snd);
        match pressed {
            case Some(button) => World.press(button, w)
            case None =>
                if (tapped(k#log, frame) or frame#wheel > 0.0) World.press(World.Button.Log, w)
                else if (tapped(k#auto, frame)) World.press(World.Button.Auto, w)
                else if (tapped(k#skip, frame)) World.press(World.Button.Skip, w)
                else if (tapped(k#hide, frame) or tapped(k#back, frame)) World.press(World.Button.Hide, w)
                else if (World.isAsking(w)) choiceInput(frame, w)
                else if (frame#mouseClicked or tapped(k#confirm, frame)) World.advance(w)
                else w
        }

    /// 選択肢: マウスは動いたフレームだけカーソルを吸い寄せ、クリックした選択肢を選ぶ。キーは ↑↓ と決定。
    def choiceInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = KeysDoc.rec(w#keys);
        let count = List.length(w#choices);
        let hovered = List.range(0, count) |> List.find(i -> Layout.contains(Layout.choice(i, count), frame#cursor));
        let w1 = match hovered {
            case Some(i) if frame#mouseMoved and i != w#cursor and isOpenChoice(i, w) => { cursor = i | w }
            case _ => w
        };
        if (frame#mouseClicked)
            match hovered {
                case Some(i) => World.pick(i, w1)
                case None    => w1
            }
        else if (tapped(k#prev, frame)) World.moveChoice(-1, w1)
        else if (tapped(k#next, frame)) World.moveChoice(1, w1)
        else if (tapped(k#confirm, frame)) World.pick(w1#cursor, w1)
        else w1

    def isOpenChoice(i: Int32, w: World.World): Bool =
        List.nth(i, w#choices) |> Option.map(option -> option#available) |> Option.getWithDefault(false)

    // ── 窓 ──

    def panelInput(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = KeysDoc.rec(w#keys);
        let back = tapped(k#back, frame) or (frame#mouseClicked and Layout.contains(Layout.back(), frame#cursor));
        match w#panel {
            case World.Panel.Closed => w
            case World.Panel.Hidden =>
                if (frame#mouseClicked or tapped(k#confirm, frame) or back or tapped(k#hide, frame)) World.closePanel(w)
                else w
            case World.Panel.Log =>
                let row = View.logRowHeight(w);
                let maxOffset = View.logMaxOffset(w);
                if (back or tapped(k#log, frame)) World.closePanel(w)
                else if (frame#wheel != 0.0) World.scrollLog(frame#wheel * row, maxOffset, w)
                else if (tapped(k#prev, frame)) World.scrollLog(row, maxOffset, w)
                else if (tapped(k#next, frame)) World.scrollLog(-row, maxOffset, w)
                else w
            case World.Panel.SaveSlots => slotsInput(frame, back, i -> World.saveSlot(i, w), w)
            case World.Panel.LoadSlots => slotsInput(frame, back, i -> World.loadSlot(i, w), w)
            case World.Panel.Settings  => settingsInput(frame, back, w)
        }

    /// 栞の枠: ↑↓ は 1 行（2 枠）、←→ は 1 枠動く。決定かクリックで挟む・読む。
    def slotsInput(frame: App.Frame, back: Bool, act: Int32 -> World.World \ Emit[World.Event],
                   w: World.World): World.World \ Emit[World.Event] =
        let k = KeysDoc.rec(w#keys);
        let count = Saves.slotCount();
        let clicked = List.range(0, count) |> List.find(i -> frame#mouseClicked and Layout.contains(Layout.slot(i), frame#cursor));
        match clicked {
            case Some(i) => act(i)
            case None =>
                if (back) World.closePanel(w)
                else if (tapped(k#prev, frame)) World.movePanelCursor(-2, count, w)
                else if (tapped(k#next, frame)) World.movePanelCursor(2, count, w)
                else if (tapped(k#left, frame)) World.movePanelCursor(-1, count, w)
                else if (tapped(k#right, frame)) World.movePanelCursor(1, count, w)
                else if (tapped(k#confirm, frame)) act(w#cursor)
                else w
        }

    /// 設定: ↑↓ で行、←→ で値。つまみの帯をクリックすると、その位置の値になる。
    def settingsInput(frame: App.Frame, back: Bool, w: World.World): World.World \ Emit[World.Event] =
        let k = KeysDoc.rec(w#keys);
        let rows = World.settings();
        let count = List.length(rows);
        let current = List.nth(w#cursor, rows);
        let onBar = rows |> List.zipWithIndex |> List.find(match (i, _) ->
            frame#mouseClicked and Layout.contains(grown(Layout.settingBar(i)), frame#cursor));
        match onBar {
            case Some((i, setting)) =>
                let bar = Layout.settingBar(i);
                let t = Float64.max(0.0, Float64.min(1.0, (frame#cursor#x - bar#position#x) / bar#size#x));
                let (lo, hi, by) = World.rangeOf(setting);
                let v = lo + Float64.round((t * (hi - lo)) / by) * by;
                World.withSetting(setting, v, { cursor = i | w })
            case None =>
                if (back) World.closePanel(w)
                else if (tapped(k#prev, frame)) World.movePanelCursor(-1, count, w)
                else if (tapped(k#next, frame)) World.movePanelCursor(1, count, w)
                else match current {
                    case Some(setting) if tapped(k#left, frame)  => World.adjust(setting, -1, w)
                    case Some(setting) if tapped(k#right, frame) => World.adjust(setting, 1, w)
                    case _ => w
                }
        }

    /// つまみの帯は細いので、押せる所は上下に広げる。
    def grown(r: Rect2.Rect2): Rect2.Rect2 =
        { position = { x = r#position#x - 8.0, y = r#position#y - 14.0 }, size = { x = r#size#x + 16.0, y = r#size#y + 28.0 } }

    // ── 音 ──

    /// 返事の音（project.json の sounds の論理名）。ui_ は決定やカーソルへの返事、se_ はシナリオの <<se>>。
    pub def soundOf(event: World.Event): Option[String] = match event {
        case World.Event.Paged    => Some("ui_page")
        case World.Event.Revealed => None
        case World.Event.Moved    => Some("ui_cursor")
        case World.Event.Picked   => Some("ui_choice")
        case World.Event.Opened   => Some("ui_open")
        case World.Event.Closed   => Some("ui_open")
        case World.Event.Saved    => Some("ui_save")
        case World.Event.Loaded   => Some("ui_save")
        case World.Event.Cue(name) => Some(name)
    }

    /// 1 フレームの一発の音（このフレームに溜まった出来事から）。
    pub def sounds(ws: { before = World.World, after = World.World }): List[String] =
        Emit.since(ws#before#events, ws#after#events) |> List.filterMap(soundOf)

    /// 鳴り続ける環境音（舞台の ambience。amb_<名前>）。音量はミキサーのバスが決める。
    pub def ambience(w: World.World): List[App.Sustain] =
        w#stage#ambience |> Option.map(name -> { name = "amb_${name}", volume = 1.0, pitch = 1.0 } :: Nil)
            |> Option.getWithDefault(Nil)

    /// 音の通り道: novel.mixer.json のバスに、設定の音量を掛ける。窓を開いている間は snapshot「panel」（環境音を籠もらせる）。
    pub def mixerOf(w: World.World): AudioMixer.Mixer =
        let c = w#saves#config;
        let base = w#mixer |> AudioMixer.withBusVolume("ambience", c#ambienceVolume) |> AudioMixer.withBusVolume("se", c#seVolume);
        if (w#panel == World.Panel.Closed) base else AudioMixer.withSnapshot("panel", base)

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
            :: DocTable.unnamedRow(Talk.dialoguePath(), w -> World.withDialogue(Talk.load(), w))
            :: (DocTable.row("kind", KindDoc.path(), w -> World.withKind(KindDoc.load(KindDoc.path()), w))
                |> DocTable.withActiveWhen(isReading))
            :: DocTable.row("theme", ThemeDoc.path(), w -> World.withTheme(ThemeDoc.load(ThemeDoc.path()), w))
            :: DocTable.row("backdrops", BackdropDoc.path(), w -> World.withBackdrops(BackdropDoc.load(BackdropDoc.path()), w))
            :: (DocTable.row("credits", CreditsDoc.path(), w -> World.withCredits(CreditsDoc.load(CreditsDoc.path()), w))
                |> DocTable.withActiveWhen(w -> w#phase == World.Phase.Credits))
            :: DocTable.row("keys", KeysDoc.path(), w -> World.withKeys(KeysDoc.load(KeysDoc.path()), w))
            :: DocTable.row("mixer", mixerPath(), w -> World.withMixer(AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()), w))
            :: Nil

    def isReading(w: World.World): Bool = w#phase == World.Phase.Reading
}
