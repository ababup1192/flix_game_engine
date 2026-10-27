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
    pub def chooseTitle(item: World.TitleItem, w: World.World): World.World \ Emit[World.Event] = match item {
        case World.TitleItem.NewGame  => WorldRead.newGame(w)
        case World.TitleItem.Continue =>
            match Saves.latest(w#saves) {
                case Some((tab, i)) => WorldSaves.loadFrom(tab, i, w)
                case None           => World.notice(StoryDoc.Label.NoSave, w)
            }
        case World.TitleItem.LoadGame => WorldSaves.openLoad(w)
        case World.TitleItem.Settings => WorldSettings.openSettings(w)
        case World.TitleItem.Credits  => World.toCredits(w)
        case World.TitleItem.Quit     => World.askFor(World.Ask.Quit, w)
    }

    /// タイトルのカーソルの項目を選ぶ（選べない項目なら何もしない）。
    pub def chooseTitleHere(w: World.World): World.World \ Emit[World.Event] =
        match World.titleCursorOf(w) {
            case Some(item) if isTitleItemOpen(item, w#saves) => chooseTitle(item, w)
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

    /// クイックメニューを押す（読んでいて、画面も確認のウィンドウも開いていない時だけ）。[遷移: Reading→各 Panel / 確認のウィンドウ]
    pub def press(button: World.Button, w: World.World): World.World \ Emit[World.Event] =
        if (not World.isReading(w) or not World.isFree(w)) w
        else match button {
            case World.Button.Rollback  => WorldLog.rollback(w)
            case World.Button.Log       => WorldLog.openLog(w)
            case World.Button.Auto      => WorldRead.togglePlayback(World.Playback.Auto, w)
            case World.Button.Skip      => WorldRead.togglePlayback(World.Playback.Skip, w)
            case World.Button.QuickSave => WorldSaves.quickSave(w)
            case World.Button.QuickLoad =>
                if (Option.nonEmpty(Saves.slotOf(Saves.Tab.Quick, 0, w#saves))) World.askFor(World.Ask.QuickLoad, w)
                else World.notice(StoryDoc.Label.NoQuickSave, w)
            case World.Button.Save      => WorldSaves.openSave(w)
            case World.Button.Load      => WorldSaves.openLoad(w)
            case World.Button.Settings  => WorldSettings.openSettings(w)
            case World.Button.Hide      => World.mapRead(r -> { playback = World.Playback.Manual | r }, { panel = World.Panel.Hidden | w })
            case World.Button.ToTitle   => World.askFor(World.Ask.ToTitle, w)
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
    pub def answer(given: World.Answer, w: World.World): World.World \ Emit[World.Event] =
        match World.askOf(w) {
            case None => w
            case Some(ask) =>
                let closed = { ask = None | w };
                match given {
                    case World.Answer.No  => Emit.emit(World.Event.Closed); closed
                    case World.Answer.Yes =>
                        match ask {
                            case World.Ask.Overwrite(tab, i) => WorldSaves.writeSlot(tab, i, closed)
                            case World.Ask.Delete(tab, i)    => WorldSaves.removeSlot(tab, i, closed)
                            case World.Ask.Load(tab, i)      => WorldSaves.loadFrom(tab, i, closed)
                            case World.Ask.QuickLoad         => WorldSaves.loadFrom(Saves.Tab.Quick, 0, closed)
                            case World.Ask.Jump(k)           => WorldLog.jumpTo(k, closed)
                            case World.Ask.ToTitle           => Emit.emit(World.Event.Closed); World.toTitle(closed)
                            case World.Ask.Quit              => { quitting = true | closed }
                            case World.Ask.Reset             => WorldSettings.reset(closed)
                        }
                }
        }

    /// 確認のウィンドウのカーソルの答えで答える。
    pub def answerHere(w: World.World): World.World \ Emit[World.Event] =
        match World.answerOf(w) {
            case Some(given) => answer(given, w)
            case None        => w
        }
}
