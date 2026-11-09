// WorldMenu — タイトルのメニュー・クイックメニュー・確認のウィンドウの答え（純粋）。
// ほかの章（WorldRead・WorldLog・WorldSaves・WorldSettings）を呼ぶ一番上の規則で、入力（Controls）が呼ぶ口の多くはここにある。
mod WorldMenu {
    use fge::{Emit}

    // ── タイトル ──

    pub def titleItems(): List[World.TitleItem] =
        World.TitleItem.NewGame :: World.TitleItem.Continue :: World.TitleItem.LoadGame :: World.TitleItem.Settings ::
        World.TitleItem.Credits :: World.TitleItem.Quit :: Nil

    /// タイトルの項目を選べるか（データが無い時の「つづきから」は薄く出して選べない）。
    pub def isTitleItemOpen(item: World.TitleItem, saves: Saves.Saves): Bool = match item {
        case World.TitleItem.Continue => Saves.hasAny(saves)
        case _                        => true
    }

    /// タイトルの項目を選ぶ。[遷移: Title→Reading / LoadSlots / Settings / Credits / 確認のウィンドウ（終了）]
    pub def chooseTitle(res: Res.Res, item: World.TitleItem, w: World.World): World.World \ Emit[World.Event] = match item {
        case World.TitleItem.NewGame  => WorldRead.newGame(res, w)
        case World.TitleItem.Continue =>
            match Saves.latest(w#saves) {
                case Some((tab, i)) => WorldSaves.loadFrom(res, tab, i, w)
                case None           => World.notice(StoryDoc.Label.NoSave, w)
            }
        case World.TitleItem.LoadGame => WorldSaves.openLoad(w)
        case World.TitleItem.Settings => WorldSettings.openSettings(w)
        case World.TitleItem.Credits  => World.toCredits(res, w)
        case World.TitleItem.Quit     => World.askFor(World.Ask.Quit, w)
    }

    /// タイトルのカーソルの項目を選ぶ（選べない項目なら何もしない）。
    pub def chooseTitleHere(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match World.titleCursorOf(w) {
            case Some(item) if isTitleItemOpen(item, w#saves) => chooseTitle(res, item, w)
            case _                                     => w
        }

    /// タイトルのカーソルを item へ（マウスが乗った項目。選べない項目と、同じ項目なら何もしない）。
    pub def pointTitle(item: World.TitleItem, w: World.World): World.World \ Emit[World.Event] =
        match World.titleCursorOf(w) {
            case Some(at) if at != item and isTitleItemOpen(item, w#saves) =>
                Emit.emit(World.Event.Moved);
                { scene = World.Scene.Title(item) | w }
            case _ => w
        }

    /// タイトルのカーソルを選べる項目だけ delta ぶん巡らせる。
    pub def moveTitle(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.titleCursorOf(w) {
            case Some(at) =>
                let items = titleItems();
                let count = List.length(items);
                let index = items |> List.zipWithIndex |> List.find(match (_, item) -> item == at) |> Option.map(fst) |> Option.getWithDefault(0);
                // 選べない項目を飛ばして、次に選べる項目まで進む（count 回で一巡するので必ず止まる）。
                let next = List.range(1, count + 1)
                    |> List.filterMap(n -> List.nth(Int32.modulo(index + delta * n, count), items))
                    |> List.find(item -> isTitleItemOpen(item, w#saves))
                    |> Option.getWithDefault(at);
                pointTitle(next, w)
            case None => w
        }

    // ── クイックメニュー ──

    pub def buttons(): List[World.Button] =
        World.Button.Rollback :: World.Button.Log :: World.Button.Auto :: World.Button.Skip :: World.Button.QuickSave ::
        World.Button.QuickLoad :: World.Button.Save :: World.Button.Load :: World.Button.Settings :: World.Button.Hide ::
        World.Button.ToTitle :: Nil

    /// 並べ方の組で出すボタン（View が描く列と Controls が当てる列は同じこの並び）。
    /// 縦の画面は右端の縦の列に字の無いアイコンの 3 つ（上から しおり・ログ・オート）。右上の … は列の外（Rail.moreButton）。
    /// セーブとロードはしおり（saveLoadItems）、スキップはオートの長押し、設定・タイトル・隠すは …（menuItems）から、
    /// 戻る（Rollback）は払う（swipeLeft）とキー、隠すは指の長押し（touchHold）とキーでも届く。
    // WhyNot: 縦で 11 個を並べない — 540 の幅に 44 CSS px で並べると 1 つが 32 CSS px を割り、字のボタンが並ぶと頁の静けさが崩れる。
    pub def buttonsOf(fit: Layout.Fit): List[World.Button] =
        if (Layout.isPortrait(fit)) World.Button.SaveLoad :: World.Button.Log :: World.Button.Auto :: Nil
        else buttons()

    /// 縦の画面の右上の … から開くメニューの項目（上から）。
    pub def menuItems(): List[World.Button] =
        World.Button.Settings :: World.Button.ToTitle :: World.Button.Hide :: Nil

    /// しおりのボタンから開く選びの項目（左から）。
    pub def saveLoadItems(): List[World.Button] = World.Button.Save :: World.Button.Load :: Nil

    /// 縦の画面の右の列のボタンを長押しした時に起きる事。Tooltip = 名前のツールチップを出す（離しても押さない）、
    /// Press(ボタン) = そのボタンを押したのと同じ。
    pub enum LongPressDoes with Eq, ToString {
        case Tooltip
        case Press(World.Button)
    }

    /// 右の列のボタンの長押し。オートはスキップに入る。
    // WhyNot: オートの長押しでツールチップを出さない — 列にスキップは無く、オートの長押しがスキップの入口なので、名前を待たずにスキップへ入る。
    pub def longPressOf(button: World.Button): LongPressDoes = match button {
        case World.Button.Auto => LongPressDoes.Press(World.Button.Skip)
        case _                 => LongPressDoes.Tooltip
    }

    /// 右の列のボタンを短く押して離した。スキップ中のオートはスキップを止める。
    // WhyNot: スキップ中のオートをオートへ替えない — 列にスキップのボタンは無いので、止める口がオートしか無い。
    pub def tapRail(res: Res.Res, button: World.Button, w: World.World): World.World \ Emit[World.Event] =
        if (button == World.Button.Auto and World.playbackOf(w) == World.Playback.Skip) press(res, World.Button.Skip, w)
        else press(res, button, w)

    /// しおりの選びの項目を選ぶ: 選びを閉じてから、セーブ・ロードの画面を開く。[遷移: SaveLoadPick→SaveSlots / LoadSlots]
    pub def chooseSaveLoad(res: Res.Res, item: World.Button, w: World.World): World.World \ Emit[World.Event] =
        press(res, item, { panel = World.Panel.Closed | w })

    /// しおりの選びのカーソルを i へ（端で止まる）。
    pub def pointSaveLoad(i: Int32, w: World.World): World.World \ Emit[World.Event] = match w#panel {
        case World.Panel.SaveLoadPick(at) =>
            let next = Int32.max(0, Int32.min(List.length(saveLoadItems()) - 1, i));
            if (next == at) w else { Emit.emit(World.Event.Moved); { panel = World.Panel.SaveLoadPick(next) | w } }
        case _ => w
    }

    /// メニューの項目を選ぶ: メニューを閉じてから、その項目のボタンを押したのと同じにする。[遷移: Menu→各 Panel / 確認のウィンドウ / 読む間]
    pub def chooseMenu(res: Res.Res, item: World.Button, w: World.World): World.World \ Emit[World.Event] =
        press(res, item, { panel = World.Panel.Closed | w })

    /// メニューのカーソルを delta だけ動かす（端で止まる）。
    pub def moveMenu(delta: Int32, w: World.World): World.World \ Emit[World.Event] = match w#panel {
        case World.Panel.Menu(i) =>
            let next = Int32.max(0, Int32.min(List.length(menuItems()) - 1, i + delta));
            if (next == i) w else { Emit.emit(World.Event.Moved); { panel = World.Panel.Menu(next) | w } }
        case _ => w
    }

    /// メニューのカーソルを i へ（マウス・指が乗った）。
    pub def pointMenu(i: Int32, w: World.World): World.World \ Emit[World.Event] = match w#panel {
        case World.Panel.Menu(at) if at != i => Emit.emit(World.Event.Moved); { panel = World.Panel.Menu(i) | w }
        case _                               => w
    }

    /// クイックメニューを押す（読んでいて、画面も確認のウィンドウも開いていない時だけ）。[遷移: Reading→各 Panel / 確認のウィンドウ]
    pub def press(res: Res.Res, button: World.Button, w: World.World): World.World \ Emit[World.Event] =
        if (not World.isReading(w) or not World.isFree(w)) w
        else match button {
            case World.Button.Rollback  => WorldLog.rollback(res, w)
            case World.Button.Log       => WorldLog.openLog(w)
            case World.Button.Auto      => WorldRead.togglePlayback(World.Playback.Auto, w)
            case World.Button.Skip      => WorldRead.togglePlayback(World.Playback.Skip, w)
            case World.Button.QuickSave => WorldSaves.quickSave(res, w)
            case World.Button.QuickLoad =>
                if (Option.nonEmpty(Saves.slotOf(Saves.Tab.Quick, 0, w#saves))) World.askFor(World.Ask.QuickLoad, w)
                else World.notice(StoryDoc.Label.NoQuickSave, w)
            case World.Button.Save      => WorldSaves.openSave(w)
            case World.Button.Load      => WorldSaves.openLoad(w)
            case World.Button.Settings  => WorldSettings.openSettings(w)
            case World.Button.Hide      => World.mapRead(r -> { playback = World.Playback.Manual | r }, { panel = World.Panel.Hidden | w })
            case World.Button.ToTitle   => World.askFor(World.Ask.ToTitle, w)
            case World.Button.Menu      => World.openPopup(World.Panel.Menu(0), w)
            case World.Button.SaveLoad  => World.openPopup(World.Panel.SaveLoadPick(0), w)
        }

    // ── 確認のウィンドウ ──

    /// ウィンドウの左右のボタンの答え（左がはい）。
    pub def answerOn(side: Layout.Side): World.Answer = match side {
        case Layout.Side.Left  => World.Answer.Yes
        case Layout.Side.Right => World.Answer.No
    }

    /// 答えのボタンの側。
    pub def sideOf(answer: World.Answer): Layout.Side = match answer {
        case World.Answer.Yes => Layout.Side.Left
        case World.Answer.No  => Layout.Side.Right
    }

    /// 確認のウィンドウに答える。はいなら尋ねていた事を行う。[遷移: 確認のウィンドウ→各行き先]
    pub def answer(res: Res.Res, given: World.Answer, w: World.World): World.World \ Emit[World.Event] =
        match World.askOf(w) {
            case None => w
            case Some(ask) =>
                let closed = { ask = None | w };
                match given {
                    case World.Answer.No  => Emit.emit(World.Event.Closed); closed
                    case World.Answer.Yes =>
                        match ask {
                            case World.Ask.Overwrite(tab, i) => WorldSaves.writeSlot(res, tab, i, closed)
                            case World.Ask.Delete(tab, i)    => WorldSaves.removeSlot(tab, i, closed)
                            case World.Ask.Load(tab, i)      => WorldSaves.loadFrom(res, tab, i, closed)
                            case World.Ask.QuickLoad         => WorldSaves.loadFrom(res, Saves.Tab.Quick, 0, closed)
                            case World.Ask.Jump(k)           => WorldLog.jumpTo(res, k, closed)
                            case World.Ask.ToTitle           => Emit.emit(World.Event.Closed); World.toTitle(closed)
                            case World.Ask.Quit              => { quitting = true | closed }
                            case World.Ask.Reset             => WorldSettings.reset(res, closed)
                        }
                }
        }

    /// 確認のウィンドウのカーソルの答えで答える。
    pub def answerHere(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match World.answerOf(w) {
            case Some(given) => answer(res, given, w)
            case None        => w
        }
}
