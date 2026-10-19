// Controls — 入力の解釈（純粋）。キーは KeysDoc（novel.keys.json）の割り当てを InputMap の表にして
// 「操作の意図」に写してから解釈し、クリックは UiFocus.hitTestUi で当たりを引いて
// meta（novel/choice/N）を World の操作へ写す。
// 操作は「選ぶだけ」: ↑↓（カーソル）と 決定（クリック / Z / Enter / Space）。ほかはメニュー（物語を止める）と、表紙での終了。
// Doc の保存即反映（watchFile）と F1 一括リロードの読み直しもここに置く。
mod Controls {
    use fge::{App, DocTable, Emit, EntityId, InputMap, PxSpriteDoc, Timeline, UiFocus, UiMenu, UiMeta, UiStore}

    /// このゲームの操作の意図。キーとの対応は KeysDoc が持ち、tapTable が表にする。
    enum Act with Eq {
        case Menu      // メニューを開く・閉じる
        case Confirm   // 進める・選ぶ（クリックは表に関わらず決定）
        case NavPrev   // 選択肢カーソルを前へ
        case NavNext   // 選択肢カーソルを後ろへ
    }

    /// 単発操作の表（KeysDoc の割り当てから組む）。同時押しは firstTap がこの順で先勝ちにする —
    /// メニューを先に置くのは、決定と同時に押しても物語より先に止まるため。
    def tapTable(keys: KeysDoc.Doc): InputMap.Table[Act] =
        let r = KeysDoc.rec(keys);
        let rows = (act, list) -> List.map(key -> (key, act), list);
        rows(Act.Menu, r#menu) ::: rows(Act.Confirm, r#confirm)
            ::: rows(Act.NavPrev, r#prev) ::: rows(Act.NavNext, r#next)

    /// 毎フレームのシステム: 実時間の今を World へ写し、文字送りと UI 投影を 1 歩進める。
    pub def step(frame: App.Frame, w: World.World): World.World =
        World.step({ realNow = frame#realNow | w })

    /// 終了の判定（Main の App.quitWhen）。終われるのは表紙で quit のキーを押した時だけ —
    /// 物語の途中では同じキー（既定は Esc）がメニューの開け閉めになる。
    pub def isQuit(frame: App.Frame, w: World.World): Bool =
        w#phase == World.Phase.Title
            and List.exists(key -> App.justPressed(key, frame), KeysDoc.rec(w#keys)#quit)

    /// 毎フレームのシステム: 入力の解釈。規則が出した出来事は events 欄に溜める（音は sounds が前後の差で読む）。
    pub def interact(frame: App.Frame, w: World.World): World.World =
        let (next, events) = Emit.collectInto(() -> interpret(frame, w), w#events);
        { events = events | next }

    /// 返事の音（決定・カーソルへの応え）と、灯りが消える演出の音の名前（project.json の sounds の論理名）。
    /// 音の案は art/sfx.snd.star を bin/fge snd build で atelier/sfx へ書く（採用して project.json の sounds に
    /// 載せるまでは、鳴らすと名前ごとに 1 回 warn が出るだけ）。
    pub enum Sound with Eq, ToString {
        case Open
        case Reveal
        case Page
        case End
        case Move
        case Pick
        case Doubt
    }

    pub def soundName(sound: Sound): String = match sound {
        case Sound.Open   => "open"
        case Sound.Reveal => "reveal"
        case Sound.Page   => "page"
        case Sound.End    => "end"
        case Sound.Move   => "move"
        case Sound.Pick   => "pick"
        case Sound.Doubt  => "doubt"
    }

    def soundOf(event: World.Event): Sound = match event {
        case World.Event.Opened        => Sound.Open
        case World.Event.Revealed      => Sound.Reveal
        case World.Event.Paged         => Sound.Page
        case World.Event.Ended         => Sound.End
        case World.Event.Moved         => Sound.Move
        case World.Event.Picked(true)  => Sound.Doubt
        case World.Event.Picked(false) => Sound.Pick
    }

    /// 返事の音の名前の全部（性質テストが「返事の音」を数えるのに使う）。
    pub def replyNames(): Set[String] =
        (Sound.Open :: Sound.Reveal :: Sound.Page :: Sound.End :: Sound.Move :: Sound.Pick :: Sound.Doubt :: Nil)
            |> List.map(soundName) |> List.toSet

    /// 1 フレームの音: 返事の音（このフレームに溜まった出来事）と、灯りが消える演出の時刻表の音
    /// （lampOutAt から物語の時計で測る。鳴らす区間は時計が持つので、メニューで止めて戻しても鳴り直さない）。
    pub def sounds(ws: { before = World.World, after = World.World }): List[String] =
        let replies = Emit.since(ws#before#events, ws#after#events) |> List.map(e -> soundName(soundOf(e)));
        let fx = ws#after#lampOutAt
            |> Option.map(at -> Timeline.soundsOnClock(ws#after#storyClock, at, LampFx.timeline()))
            |> Option.getWithDefault(Nil);
        List.append(replies, fx)

    /// 入力の解釈。メニューのキーは開け閉めだけ・メニューの間は物語の入力を受けない。
    /// 選択肢待ちだけ操作が変わる（カーソル移動 + チップのクリック。それ以外は決定 = 進める）。
    def interpret(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let tap = InputMap.firstTap(tapTable(w#keys), frame);
        if (tap == Some(Act.Menu))
            World.toggleMenu(w)
        else if (w#menu == World.Menu.Open)
            w
        else if (NovelKit.isAsking(w#kit))
            askInteract(frame, UiFocus.hitTestUi(w#ui, frame#viewport, frame#cursor), w)
        else if (frame#mouseClicked or tap == Some(Act.Confirm))
            World.advance(w)
        else w

    /// 選択肢待ち: キーボードのカーソルを基準にし、マウスは動いたフレームだけ吸着
    /// （UiMenu.syncCursor）。ホバー強調はカーソル位置のチップへ。
    /// ↑↓ で移動、決定かチップのクリックで選ぶ。
    def askInteract(frame: App.Frame, hit: Option[EntityId], w: World.World): World.World \ Emit[World.Event] =
        let synced = UiMenu.syncCursor(NovelKit.choicesPath(),
                                       { mouseMoved = frame#mouseMoved, hit = hit },
                                       w#cursor, w#ui);
        let hovered = { cursor = synced#cursor,
                        ui = UiStore.setHovered(synced#hoverPath, w#ui) | w };
        if (frame#mouseClicked)
            pickClicked(hit, hovered)
        else
            match InputMap.firstTap(tapTable(w#keys), frame) {
                case Some(Act.NavPrev) => World.moveCursor(-1, hovered)
                case Some(Act.NavNext) => World.moveCursor(1, hovered)
                case Some(Act.Confirm) => World.pick(hovered#cursor, hovered)
                case _                 => hovered
            }

    /// クリックが選択肢チップ（novel/choice/N）なら、その番号を選ぶ。
    def pickClicked(hit: Option[EntityId], w: World.World): World.World \ Emit[World.Event] =
        match hit |> Option.flatMap(id -> Map.get(id, w#ui#metas))
                  |> Option.flatMap(meta -> UiMeta.indexOf(NovelKit.choicePrefix(), meta)) {
            case Some(i) => World.pick(i, w)
            case None    => w
        }

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub def loadDocs(): World.Docs \ Fs.FileRead =
        { story = StoryDoc.load(StoryDoc.path()),
          dialogue = Talk.load(),
          kind = KindDoc.load(KindDoc.path()),
          keys = KeysDoc.load(KeysDoc.path()),
          theme = ThemeDoc.load(ThemeDoc.path()),
          sprites = PxSpriteDoc.load(World.spritePath()) }

    pub def reloadStory(w: World.World): World.World \ Fs.FileRead =
        World.withStory(StoryDoc.load(StoryDoc.path()), w)

    pub def reloadDialogue(w: World.World): World.World \ Fs.FileRead =
        World.withDialogue(Talk.load(), w)

    pub def reloadKind(w: World.World): World.World \ Fs.FileRead =
        World.withKind(KindDoc.load(KindDoc.path()), w)

    pub def reloadKeys(w: World.World): World.World \ Fs.FileRead =
        { keys = KeysDoc.load(KeysDoc.path()) | w }

    pub def reloadTheme(w: World.World): World.World \ Fs.FileRead =
        World.withTheme(ThemeDoc.load(ThemeDoc.path()), w)

    pub def reloadSprites(w: World.World): World.World \ Fs.FileRead =
        World.withSprites(PxSpriteDoc.load(World.spritePath()), w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物。
    ///
    /// ui.json は F1 だけ（withoutWatch）。保存を検知して読み直すと
    /// UiSpec.reloadAllWithReport がホバー・カーソル・文字送りを捨てるので、
    /// 読んでいる最中に表示が飛ぶ。行はパス 1 本につき 1 行で、F1 では
    /// レジストリの読み直しが行の数だけ走る（押した時だけなので数え直しはしない）。
    ///
    /// 表紙も部屋と額縁と台本の題を描くので story / theme / sprite は出しっぱなし。
    /// keys も表紙の決定と終了で効くので出しっぱなし。
    /// ダイアログ（ui）と手触り（kind: 文字送り・暗さ）は本文に入ってから —
    /// 全部を常時 active にしない（バッジの意味が死ぬ）。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("story", StoryDoc.path(), reloadStory)
            // シナリオの木（bin/fge yarn build の書き出し）。Studio の Doc ではないので名乗らない。
            :: DocTable.unnamedRow(Talk.dialoguePath(), reloadDialogue)
            :: (DocTable.row("kind", KindDoc.path(), reloadKind)
                |> DocTable.withActiveWhen(inStory))
            :: DocTable.row("keys", KeysDoc.path(), reloadKeys)
            :: DocTable.row("theme", ThemeDoc.path(), reloadTheme)
            // accentLight の宣言元。theme の行が F1 で同じ物を読むので withoutReloadAll。
            :: (DocTable.unnamedRow(ThemeDoc.palettePath(), reloadTheme)
                |> DocTable.withoutReloadAll)
            :: DocTable.row("sprite", World.spritePath(), reloadSprites)
            :: List.map(p -> DocTable.row("ui", p, World.reloadUi)
                                 |> DocTable.withoutWatch
                                 |> DocTable.withActiveWhen(inStory),
                   NovelKit.uiPaths())

    def inStory(w: World.World): Bool = w#phase == World.Phase.Story

    /// App.game の reloads(保存即反映の watchFile)へ渡す形。
    pub def reloads(): List[(String, World.World -> World.World \ Fs.FileRead)] =
        DocTable.reloads(docTable())

    /// F1: 一覧表の順に Doc も ui.json も全部読み直す。
    pub def reloadAll(w: World.World): World.World \ Fs.FileRead =
        DocTable.reloadAll(docTable(), w)

    /// いま画面に出ている Doc（Studio の「表示中」バッジの材料）。
    pub def activeDocs(w: World.World): List[(String, List[String])] =
        DocTable.activeDocs(docTable(), w)
}
