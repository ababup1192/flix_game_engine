// Controls — 入力の解釈・音の宣言・Doc の読み込みと読み直し（純粋。読み込みだけ Fs.FileRead）。
// キーは KeysDoc（novel.keys.json）の割り当て、クリックは Layout の矩形（View が描く所と同じ）で当てる。
// 入力の効き先は「いちばん手前の物」1 つ: 確認のウィンドウ → 開いている画面 → 選択肢 → クイックメニュー → 本文（送る）。
// 本文を送るのはキーの決定と、Gesture が離した時に決めた押し（タップ・ドラッグ・左の外の払い）。押している間と長押しは送らない。
mod Controls {
    use fge::{App, AudioMixer, AudioMixerDoc, Display, DocTable, Emit, LoadProgress, Log, Rect2, Resources}
    use fge::GameEngine.Key

    // ── 毎フレームの系 ──

    /// 実時間の今を World へ写し、文字送り・待ち・オート・スキップ（素材を待っている間は待ちの段）を 1 歩進める。
    pub def step(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let (next, events) = Emit.collectInto(() -> WorldRead.step(res, frame#dt, { realNow = frame#realNow | w }), w#events);
        noteGaveUp(res, w, { events = events | next })

    /// このコマで待ち切れずに諦めた素材があれば 1 行知らせる（諦めた事は World の gaveUp に残る）。
    // WhyNot: WorldRead の中で知らせない — 規則のテストが stderr に出た行で落ちる。
    def noteGaveUp(res: Res.Res, before: World.World, after: World.World): World.World =
        let gaveUpOf = (w: World.World) -> World.readOf(w) |> Option.map(r -> r#gaveUp) |> Option.getWithDefault(Set.empty());
        let fresh = Set.difference(gaveUpOf(after), gaveUpOf(before));
        if (Set.isEmpty(fresh) or not World.isReading(before)) after
        else Log.warnThen("[hold] ${Set.join(", ", fresh)} が ${Float64.toString(KindDoc.rec(res#kind)#holdGiveUpSeconds)} 秒待っても届かないので、無いまま進む", after)

    /// 入力の解釈。規則が出した出来事は events 欄に溜める（音は sounds が前後の差で読む）。
    pub def interact(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let pointed = World.withPointer({ x = frame#cursor#x, y = frame#cursor#y }, w);
        let (next, events) = Emit.collectInto(() -> interpret(res, frame, pointed), pointed#events);
        { events = events | next }

    /// 終了の判定（Game の App.quitWhen）。確認のウィンドウで「はい」を選んだ時だけ。
    pub def isQuit(_frame: App.Frame, w: World.World): Bool = w#quitting

    def tapped(keys: List[Key], frame: App.Frame): Bool = List.exists(key -> App.justPressed(key, frame), keys)

    def clickedOn(r: Rect2.Rect2, frame: App.Frame): Bool = frame#mouseClicked and Layout.contains(r, frame#cursor)

    def keysOf(res: Res.Res): KeysDoc.Rec = KeysDoc.rec(res#keys)

    /// このフレームの並べ方の組（View が ViewCtx#display から引く組と同じ。design の向きは design の形から決まる）。
    def fitOf(res: Res.Res, frame: App.Frame): Layout.Fit =
        Layout.fitOf(frame#sizeClass, Display.orientationOf(frame#viewport), frame#viewport, res#smallScreen, res#portrait)

    def interpret(res: Res.Res, frame: App.Frame, w0: World.World): World.World \ Emit[World.Event] =
        // WhyNot: 他の画面で押し始めた押しを持ち越さない — 画面を閉じた押しを読む画面で離すと、タップと見なされて台詞が進む。
        let w = if (readsText(w0) or Gesture.isIdle(w0#gesture)) w0 else dropGesture(w0);
        if (Option.nonEmpty(w#ask)) askInput(res, frame, dropLongPress(w))
        else if (w#panel != World.Panel.Closed) panelInput(res, frame, dropLongPress(w))
        else match w#scene {
            case World.Scene.Title(_)      => titleInput(res, frame, w)
            // WhyNot: 素材を待つ間にメニューやセーブを開かせない — 画面は黒で押せる物が見えず、待ちは長くても数十秒で明ける。
            case World.Scene.Reading(_)    => if (World.isHolding(w)) dropLongPress(w) else readingInput(res, frame, w)
            case World.Scene.Credits(_, _) =>
                let k = keysOf(res);
                if (World.creditsOver(res, Layout.height(fitOf(res, frame)), w) or frame#mouseClicked or tapped(k#confirm, frame) or tapped(k#back, frame)) World.toTitle(w)
                else w
        }

    def dropGesture(w: World.World): World.World = { gesture = Gesture.idle() | w }

    /// 列の長押しの途中で画面や確認のウィンドウが開いた・素材を待つ黒に入ったら、長押しを捨てる。
    // WhyNot: 残したまま読む間へ戻さない — 戻った最初のフレームで「離した」と読み、開いた覚えの無いボタンを押してしまう。
    def dropLongPress(w: World.World): World.World = match w#grab {
        case World.Grab.LongPress(_, _) => { grab = World.Grab.Free | w }
        case _                          => w
    }

    /// 入力が本文へ届く時か（確認のウィンドウも画面も開いていない・読んでいる・素材を待っていない）。
    def readsText(w: World.World): Bool =
        Option.isEmpty(w#ask) and w#panel == World.Panel.Closed and World.isReading(w) and not World.isHolding(w)

    // ── 確認のウィンドウ ──

    /// はい / いいえ: ←→↑↓ でカーソル、決定で答える、戻るは「いいえ」。マウスは乗った方へカーソルを寄せ、押した方で答える。
    def askInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let hovered = Layout.sideAt(Layout.askButton(fitOf(res, frame)), frame#cursor) |> Option.map(WorldMenu.answerOn);
        match hovered {
            case Some(a) if frame#mouseClicked => WorldMenu.answer(res, a, w)
            case Some(a) if frame#mouseMoved   => World.moveAsk(a, w)
            case _ =>
                if (tapped(k#back, frame)) WorldMenu.answer(res, World.Answer.No, w)
                else if (tapped(k#confirm, frame)) WorldMenu.answerHere(res, w)
                else if (tapped(k#left, frame) or tapped(k#prev, frame)) World.moveAsk(World.Answer.Yes, w)
                else if (tapped(k#right, frame) or tapped(k#next, frame)) World.moveAsk(World.Answer.No, w)
                else w
        }

    // ── タイトル ──

    def titleInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let items = WorldMenu.titleItems();
        let hovered = Layout.hitOf(List.length(items), i -> Layout.titleItem(fitOf(res, frame), i, List.length(items)), frame#cursor)
            |> Option.flatMap(i -> List.nth(i, items)) |> Option.filter(item -> WorldMenu.isTitleItemOpen(item, w#saves));
        match hovered {
            case Some(item) if frame#mouseClicked => WorldMenu.chooseTitle(res, item, w)
            case Some(item) if frame#mouseMoved   => WorldMenu.pointTitle(item, w)
            case _ =>
                if (tapped(k#quit, frame)) World.askFor(World.Ask.Quit, w)
                else if (tapped(k#prev, frame)) WorldMenu.moveTitle(-1, w)
                else if (tapped(k#next, frame)) WorldMenu.moveTitle(1, w)
                else if (tapped(k#confirm, frame)) WorldMenu.chooseTitleHere(res, w)
                else w
        }

    // ── 読んでいる間 ──

    /// 読む間の入口。縦の画面は右の列（Rail.judge）と右上の …、横の画面は下の帯。
    /// 押した 1 回は Gesture で記録し、離した時に advancesOnRelease の種類なら本文を 1 行送る（releasedText）。
    def readingInput(res: Res.Res, frame: App.Frame, w0: World.World): World.World \ Emit[World.Event] =
        let fit = fitOf(res, frame);
        let (gesture, track) = Gesture.step(KindDoc.gestureLimits(res#kind), frame, w0#gesture);
        let w = { gesture = track | w0 };
        let releasedText = Option.exists(advancesOnRelease, gesture);
        if (Layout.isPortrait(fit)) railInput(res, frame, fit, releasedText, w)
        else {
            let buttons = WorldMenu.buttonsOf(fit);
            let pressed = Layout.hitOf(List.length(buttons), i -> Layout.button(fit, i, List.length(buttons)), frame#cursor)
                |> Option.filter(_ -> frame#mouseClicked) |> Option.flatMap(i -> List.nth(i, buttons));
            readingRest(res, frame, pressed, releasedText, w)
        }

    /// 縦の画面: 右の列のボタンは押し始めで掴み、離した時に押したことにする。長押しは WorldMenu.longPressOf のとおり。… は押した時に開く。
    /// 列か … が受けた押しは Gesture の記録を捨てる（列を押して離した時に、本文のタップとして台詞まで進めない）。
    def railInput(res: Res.Res, frame: App.Frame, fit: Layout.Fit, releasedText: Bool, w: World.World): World.World \ Emit[World.Event] =
        let buttons = WorldMenu.buttonsOf(fit);
        let input = Rail.inputOf(frame, tapped(keysOf(res)#touchHold, frame));
        let dropped = dropGesture(w);
        let freed = { grab = World.Grab.Free | dropped };
        let buttonAt = (i, f) -> List.nth(i, buttons) |> Option.map(f) |> Option.getWithDefault(freed);
        match Rail.judge(fit, input, w#grab, frame#realNow) {
            case Rail.Outcome.Begin(i)     => { grab = World.Grab.LongPress(i, frame#realNow) | dropped }
            case Rail.Outcome.Held(_)      => dropped
            case Rail.Outcome.Tap(i)       => buttonAt(i, b -> WorldMenu.tapRail(res, b, freed))
            case Rail.Outcome.Long(i)      => buttonAt(i, b -> longPress(res, b, dropped))
            case Rail.Outcome.Released     => freed
            case Rail.Outcome.TouchLong(i) => buttonAt(i, b -> touchLongPress(res, frame, b, i, dropped))
            case Rail.Outcome.MoreOpen     => WorldMenu.press(res, World.Button.Menu, dropped)
            case Rail.Outcome.Swallow      => dropped
            case Rail.Outcome.Pass         => readingRest(res, frame, None, releasedText, w)
        }

    /// 押したまま長押しの秒を越えている列のボタン: ツールチップの物は離すまで掴んだまま（離しても押さない）、
    /// 別のボタンになる物（オート → スキップ）はそのボタンを押して掴みを Other にする（離しても押さない・続けて押さない）。
    def longPress(res: Res.Res, button: World.Button, w: World.World): World.World \ Emit[World.Event] =
        match WorldMenu.longPressOf(button) {
            case WorldMenu.LongPressAction.Press(other) => WorldMenu.press(res, other, { grab = World.Grab.Other | w })
            case WorldMenu.LongPressAction.Tooltip      => w
        }

    /// ブラウザ版の指の長押し（離した時に touchGestures の longPress = touchHold のキーが、押した所のまま届く）が右の列の上だった:
    /// マウスの長押しと同じく、オートはスキップ、ほかは名前のツールチップ（離した後に出す）。
    def touchLongPress(res: Res.Res, frame: App.Frame, button: World.Button, i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match WorldMenu.longPressOf(button) {
            case WorldMenu.LongPressAction.Press(other) => WorldMenu.press(res, other, w)
            case WorldMenu.LongPressAction.Tooltip      => World.mapRead(r -> { tip = Some((i, frame#realNow)) | r }, w)
        }

    /// 押したボタン（無ければキー・選択肢・送り）。送るのは離した押し（releasedText）とキーの決定だけで、
    /// ボタン・キー・選択肢が受けた押しは Gesture の記録を捨てる。指の長押し（touchHold）は列の外なら隠す。
    def readingRest(res: Res.Res, frame: App.Frame, pressed: Option[World.Button], releasedText: Bool, w0: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let w = if (w0#grab != World.Grab.Free and not frame#mouseDown) { grab = World.Grab.Free | w0 } else w0;
        let dropped = dropGesture(w);
        match pressed {
            case Some(button) => WorldMenu.press(res, button, dropped)
            case None =>
                // WhyNot: 上へのホイールでバックログを開かない — ブラウザ版で指を下へ払って送ると、動かしている間に上へのホイールも出る。
                if (tapped(k#log, frame)) WorldMenu.press(res, World.Button.Log, dropped)
                else if (tapped(k#rollback, frame)) WorldMenu.press(res, World.Button.Rollback, dropped)
                else if (tapped(k#auto, frame)) WorldMenu.press(res, World.Button.Auto, dropped)
                else if (tapped(k#skip, frame)) WorldMenu.press(res, World.Button.Skip, dropped)
                else if (tapped(k#quickSave, frame)) WorldMenu.press(res, World.Button.QuickSave, dropped)
                else if (tapped(k#quickLoad, frame)) WorldMenu.press(res, World.Button.QuickLoad, dropped)
                else if (tapped(k#hide, frame) or tapped(k#back, frame) or tapped(k#touchHold, frame)) WorldMenu.press(res, World.Button.Hide, dropped)
                else if (World.isChoosing(w)) choiceInput(res, frame, dropped)
                else if (releasedText or tapped(k#confirm, frame) or tapped(k#advance, frame)) WorldRead.advance(res, w)
                else w
        }

    /// 離した押しのうち本文を 1 行送る種類: タップ・ドラッグ・左の外の払い。
    // WhyNot: 左の払いで送らない — 左へ払うのは 1 行戻る（touchGestures の swipeLeft）で、送ると戻した行へすぐ進む。
    // WhyNot: 長押しで送らない — 長押しはウィンドウを隠す（touchGestures の longPress = touchHold）。
    def advancesOnRelease(kind: Gesture.Kind): Bool = match kind {
        case Gesture.Kind.Tap(_)    => true
        case Gesture.Kind.Drag      => true
        case Gesture.Kind.Swipe(d)  => d != Gesture.Direction.Left
        case Gesture.Kind.LongPress => false
    }

    /// 選択肢: マウスは動いたフレームだけカーソルを吸い寄せ、クリックした選択肢を選ぶ。キーは ↑↓ と決定。
    def choiceInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let count = List.length(World.choicesOf(w));
        let hovered = Layout.hitOf(count, i -> Layout.choice(fitOf(res, frame), i, count), frame#cursor);
        match hovered {
            case Some(i) if frame#mouseClicked => WorldRead.pick(res, i, w)
            case Some(i) if frame#mouseMoved   => WorldRead.pointChoice(i, w)
            case _ =>
                if (tapped(k#prev, frame)) WorldRead.moveChoice(-1, w)
                else if (tapped(k#next, frame)) WorldRead.moveChoice(1, w)
                else if (tapped(k#confirm, frame)) WorldRead.pickHere(res, w)
                else w
        }

    // ── 画面 ──

    def panelInput(res: Res.Res, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let back = tapped(k#back, frame) or clickedOn(Layout.back(fitOf(res, frame)), frame);
        match w#panel {
            case World.Panel.Closed => w
            case World.Panel.Hidden =>
                if (frame#mouseClicked or tapped(k#confirm, frame) or back or tapped(k#hide, frame)) World.closePanel(w)
                else w
            case World.Panel.Log(offset)     => logInput(res, frame, back, offset, w)
            case World.Panel.SaveSlots(_, _) => slotsInput(res, frame, back, w)
            case World.Panel.LoadSlots(_, _) => slotsInput(res, frame, back, w)
            case World.Panel.Settings(at)    => settingsInput(res, frame, back, at, w)
            case World.Panel.Menu(at)        => menuInput(res, frame, back, at, w)
            case World.Panel.SaveLoadPick(at) => saveLoadInput(res, frame, back, at, w)
        }

    /// … のメニュー: 項目を押すとその項目へ、メニューの外を押すか戻るで閉じる。キーは ↑↓ と決定。
    def menuInput(res: Res.Res, frame: App.Frame, back: Bool, cursor: Int32, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let fit = fitOf(res, frame);
        let items = WorldMenu.menuItems();
        let count = List.length(items);
        let hovered = Layout.hitOf(count, Rail.menuItem(fit), frame#cursor);
        let outside = frame#mouseClicked and not Layout.contains(Rail.menuBox(fit, count), frame#cursor);
        let pickItem = i -> List.nth(i, items) |> Option.map(item -> WorldMenu.chooseMenu(res, item, w)) |> Option.getWithDefault(w);
        match hovered {
            case Some(i) if frame#mouseClicked => pickItem(i)
            case Some(i) if frame#mouseMoved   => WorldMenu.pointMenu(i, w)
            case _ =>
                if (back or outside or tapped(k#hide, frame)) World.closePanel(w)
                else if (tapped(k#prev, frame)) WorldMenu.moveMenu(-1, w)
                else if (tapped(k#next, frame)) WorldMenu.moveMenu(1, w)
                else if (tapped(k#confirm, frame)) pickItem(cursor)
                else w
        }

    /// しおりの選び: セーブ・ロードを押すとその画面へ、外を押すか戻るで閉じる。キーは ←→（↑↓ も）と決定。
    def saveLoadInput(res: Res.Res, frame: App.Frame, back: Bool, cursor: Int32, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let fit = fitOf(res, frame);
        let items = WorldMenu.saveLoadItems();
        let count = List.length(items);
        let hovered = Layout.hitOf(count, i -> Rail.saveLoadItem(fit, i, count), frame#cursor);
        let outside = frame#mouseClicked and not Layout.contains(Rail.saveLoadBox(fit, count), frame#cursor);
        let pickItem = i -> List.nth(i, items) |> Option.map(item -> WorldMenu.chooseSaveLoad(res, item, w)) |> Option.getWithDefault(w);
        match hovered {
            case Some(i) if frame#mouseClicked => pickItem(i)
            case Some(i) if frame#mouseMoved   => WorldMenu.pointSaveLoad(i, w)
            case _ =>
                if (back or outside or tapped(k#hide, frame)) World.closePanel(w)
                else if (tapped(k#left, frame) or tapped(k#prev, frame)) WorldMenu.pointSaveLoad(cursor - 1, w)
                else if (tapped(k#right, frame) or tapped(k#next, frame)) WorldMenu.pointSaveLoad(cursor + 1, w)
                else if (tapped(k#confirm, frame)) pickItem(cursor)
                else w
        }

    /// バックログ: ホイールと ↑↓ で遡る（一番下でホイールを下へ回すと閉じる）。戻れる行をクリックすると、その場面へ戻るか尋ねる。
    def logInput(res: Res.Res, frame: App.Frame, back: Bool, offset: Float64, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let fit = fitOf(res, frame);
        let size = View.logScrollSize(fit, res, w);
        let row = View.logRowHeight(fit, res, w);
        let clicked = if (frame#mouseClicked) View.logEntryAt(fit, res, frame#cursor, w) else None;
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
    def slotsInput(res: Res.Res, frame: App.Frame, back: Bool, w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        let fit = fitOf(res, frame);
        let count = Saves.perPage();
        let tabs = WorldSaves.tabsOf(w);
        let tabHit = if (frame#mouseClicked) Layout.hitOf(List.length(tabs), Layout.tab(fit, List.length(tabs)), frame#cursor) |> Option.flatMap(j -> List.nth(j, tabs)) else None;
        let removeHit = if (frame#mouseClicked) Layout.hitOf(count, Layout.remove(fit), frame#cursor) else None;
        let slotHit = Layout.hitOf(count, Layout.slot(fit), frame#cursor);
        match (tabHit, removeHit, slotHit) {
            case (Some(tab), _, _)      => WorldSaves.withTab(tab, w)
            case (None, Some(i), _)     => WorldSaves.deleteSlot(i, w)
            case (None, None, Some(i)) if frame#mouseClicked => WorldSaves.chooseSlot(res, i, w)
            case (None, None, Some(i)) if frame#mouseMoved   => WorldSaves.pointSlot(i, w)
            case _ =>
                if (back) World.closePanel(w)
                else if (tapped(k#tabPrev, frame)) WorldSaves.moveTab(-1, w)
                else if (tapped(k#tabNext, frame)) WorldSaves.moveTab(1, w)
                else if (tapped(k#remove, frame)) WorldSaves.deleteHere(w)
                else if (tapped(k#prev, frame)) WorldSaves.moveSlotCursor(-Layout.slotColumns(fitOf(res, frame)), w)
                else if (tapped(k#next, frame)) WorldSaves.moveSlotCursor(Layout.slotColumns(fitOf(res, frame)), w)
                else if (tapped(k#left, frame)) WorldSaves.moveSlotCursor(-1, w)
                else if (tapped(k#right, frame)) WorldSaves.moveSlotCursor(1, w)
                else if (tapped(k#confirm, frame)) WorldSaves.chooseHere(res, w)
                else w
        }

    /// 設定: ↑↓ で行、←→ で値、決定で 2 つから選ぶ行を反対側へ・「初期設定に戻す」を押す。
    /// スライダーの帯をクリックするとその位置の値、2 つから選ぶ行はクリックした側になる。
    /// スライダーは押したまま（指なら横へなぞったまま）動かすと、帯の上の位置に付いて値が動く。
    /// 離すまでは最初に掴んだスライダーだけが動く（縦にずれて隣の行に入っても、隣は動かさない）。
    // WhyNot: 押しているフレームならいつでも掴む、にしない — 前の画面のボタンを押したまま設定が開くと、
    //   その指の下のスライダーのバーを掴んで値が勝手に動き、押していないのに返事の音が鳴る。掴むのは押し始めたフレームだけ。
    def settingsInput(res: Res.Res, frame: App.Frame, back: Bool, current: World.Setting, w: World.World): World.World \ Emit[World.Event] =
        let rows = WorldSettings.settings();
        let hovered = Layout.hitOf(List.length(rows), Layout.settingRow(fitOf(res, frame)), frame#cursor)
            |> Option.flatMap(i -> List.nth(i, rows) |> Option.map(s -> (i, s)));
        let fit = fitOf(res, frame);
        let grabbed = (i, slider) -> { grab = World.Grab.Slider(i) | dragSlider(res, i, slider, frame, WorldSettings.pointSetting(World.Setting.Slider(slider), w)) };
        match (frame#mouseDown, w#grab, hovered) {
            case (true, World.Grab.Slider(i), _) =>
                match List.nth(i, rows) {
                    case Some(World.Setting.Slider(slider)) => grabbed(i, slider)
                    case _                                  => w
                }
            case (true, World.Grab.Free, Some((i, World.Setting.Slider(slider)))) if frame#mouseClicked and Layout.contains(Layout.settingBarReach(fit, i), frame#cursor) =>
                grabbed(i, slider)
            case _ =>
                let next = if (frame#mouseDown) World.Grab.Other else World.Grab.Free;
                let w1 = if (w#grab == next) w else { grab = next | w };
                settingsRest(res, frame, back, current, hovered, w1)
        }

    /// 掴んでいない時の設定の入力（クリック・ホバー・キー）。
    def settingsRest(res: Res.Res, frame: App.Frame, back: Bool, current: World.Setting, hovered: Option[(Int32, World.Setting)], w: World.World): World.World \ Emit[World.Event] =
        let k = keysOf(res);
        match hovered {
            case Some((i, setting)) if frame#mouseClicked => clickSetting(res, i, setting, frame, WorldSettings.pointSetting(setting, w))
            case Some((_, setting)) if frame#mouseMoved   => WorldSettings.pointSetting(setting, w)
            case _ =>
                if (back) World.closePanel(w)
                else if (tapped(k#prev, frame)) WorldSettings.moveSetting(-1, w)
                else if (tapped(k#next, frame)) WorldSettings.moveSetting(1, w)
                else if (tapped(k#left, frame)) WorldSettings.adjust(res, current, -1, w)
                else if (tapped(k#right, frame)) WorldSettings.adjust(res, current, 1, w)
                else if (tapped(k#confirm, frame)) WorldSettings.activate(current, w)
                else w
        }

    /// 掴んだ i 行目のスライダーを、カーソルの横の位置の値にする（縦の位置は見ない）。
    def dragSlider(res: Res.Res, i: Int32, slider: World.Slider, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let range = WorldSettings.rangeOf(slider, res#kind);
        let bar = Layout.settingBar(fitOf(res, frame), i);
        let t = Float64.max(0.0, Float64.min(1.0, (frame#cursor#x - bar#position#x) / bar#size#x));
        WorldSettings.withLevel(res, slider, range#min + Float64.round((t * (range#max - range#min)) / range#step) * range#step, w)

    /// 設定の行 i をクリックした: スライダーは帯の位置の値、2 つから選ぶ行は押した側、押す行はボタンの上なら確認のウィンドウ。
    def clickSetting(res: Res.Res, i: Int32, setting: World.Setting, frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        match setting {
            case World.Setting.Slider(slider) =>
                let range = WorldSettings.rangeOf(slider, res#kind);
                let fit = fitOf(res, frame);
                let bar = Layout.settingBar(fit, i);
                let reach = Layout.settingBarReach(fit, i);
                if (not Layout.contains(reach, frame#cursor)) w
                else {
                    let t = Float64.max(0.0, Float64.min(1.0, (frame#cursor#x - bar#position#x) / bar#size#x));
                    WorldSettings.withLevel(res, slider, range#min + Float64.round((t * (range#max - range#min)) / range#step) * range#step, w)
                }
            case World.Setting.Pair(pair) =>
                match Layout.sideAt(side -> Layout.settingSide(fitOf(res, frame), i, side), frame#cursor) {
                    case Some(side) => WorldSettings.withSide(pair, side, w)
                    case None       => w
                }
            case World.Setting.Reset =>
                if (Layout.contains(Layout.settingAction(fitOf(res, frame), i), frame#cursor)) WorldSettings.activate(setting, w) else w
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

    /// 1 フレームの一発の音（このフレームに溜まった出来事から）。missing = まだ届いていない音の名前。
    pub def sounds(missing: Set[String], ws: { before = World.World, after = World.World }): List[String] =
        soundsOf(missing, Emit.since(ws#before#events, ws#after#events))

    /// 出来事の列から鳴らす一発の音。まだ届いていない音（missing）は待たず、鳴らさずに進む。
    pub def soundsOf(missing: Set[String], events: List[World.Event]): List[String] =
        events |> List.filterMap(soundOf) |> List.filter(name -> not Set.memberOf(name, missing))

    /// 鳴り続ける環境音（舞台の ambience。amb_<名前>）。音量はミキサーのバスが決める。
    pub def ambience(res: Res.Res, w: World.World): List[App.Sustain] =
        World.stageOf(res, w)#ambience |> Option.map(name -> { name = Stage.ambienceSound(name), volume = 1.0, pitch = 1.0 } :: Nil)
            |> Option.getWithDefault(Nil)

    /// 音の通り道: novel.mixer.json のバスに、設定の音量（全体 × 環境音 / 効果音）を掛ける。
    /// 画面や確認のウィンドウを開いている間は snapshot「panel」（環境音を籠もらせる）。
    pub def mixerOf(res: Res.Res, w: World.World): AudioMixer.Mixer =
        let c = Saves.configOf(w#saves);
        let base = res#mixer |> AudioMixer.withBusVolume("ambience", c#masterVolume * c#ambienceVolume)
                           |> AudioMixer.withBusVolume("se", c#masterVolume * c#seVolume);
        if (World.isFree(w)) base else AudioMixer.withSnapshot("panel", base)

    // ── 後回しの素材を解く量（ブラウザ版。App.withDecodeBudget） ──

    /// このコマに、届いた後回しの絵を登録してよい量。素材を待っている間（黒へ重ねる・黒のまま・黒から戻す）は Covered(50)、
    /// 文字送りの途中とクレジット（流れている）は Paused、タップ待ち・選択肢・タイトル・画面を開いている間は Idle(4)。
    // WhyNot: 背景の写真の重ねの途中を Covered にしない — 見えている写真の重なりが登録の止まりで引っかかる。
    pub def decodeBudget(h: Resources.With[Res.Res, World.World]): LoadProgress.DecodeBudget =
        let w = h#world;
        match w#scene {
            case World.Scene.Title(_)      => LoadProgress.DecodeBudget.Idle(idleMs())
            case World.Scene.Credits(_, _) => LoadProgress.DecodeBudget.Paused
            case World.Scene.Reading(r)    =>
                if (Option.nonEmpty(r#hold)) LoadProgress.DecodeBudget.Covered(coveredMs())
                else if (World.isFree(w) and not Page.isDone(r#page)) LoadProgress.DecodeBudget.Paused
                else LoadProgress.DecodeBudget.Idle(idleMs())
        }

    /// 画面が動いて見えている間に、1 コマで登録に使ってよい ms（1 本の道は必ず通る）。
    def idleMs(): Float64 = 4.0

    /// 画面が黒い間に、1 コマで登録に使ってよい ms。
    def coveredMs(): Float64 = 50.0

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    pub def mixerPath(): String = "assets/novel.mixer.json"

    /// 起動時と描き出しとテストが同じ形で読む描く元（Doc とシナリオ）。
    pub def loadRes(): Res.Res \ Fs.FileRead =
        { story = StoryDoc.load(StoryDoc.path()),
          kind = KindDoc.load(KindDoc.path()),
          theme = ThemeDoc.load(ThemeDoc.path()),
          backdrops = BackdropDoc.load(BackdropDoc.path()),
          credits = CreditsDoc.load(CreditsDoc.path()),
          keys = KeysDoc.load(KeysDoc.path()),
          smallScreen = SmallScreenDoc.load(SmallScreenDoc.path()),
          portrait = loadPortrait(),
          cast = CastDoc.load(CastDoc.path()),
          mixer = AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()),
          dialogue = Talk.load(),
          missing = Set.empty(),
          scriptEdits = ScriptEdits.none() }

    /// 縦の画面の Doc（novel.portrait.json に novel.rail.json を rail 欄として組んだ物）。
    def loadPortrait(): PortraitDoc.Doc \ Fs.FileRead =
        PortraitDoc.withRail(RailDoc.load(RailDoc.path()), PortraitDoc.load(PortraitDoc.path()))

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る「表示中」の 3 つは、
    /// どれもこの 1 枚から導出する。docId は project.json の editor.resources[] の id と同じ物。
    /// 読み直すのは描く元（Res）で、World を収め直すのはシナリオの行だけ（WorldRead.settleDialogue）。
    pub def docTable(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] =
        let unchanged = (_, w) -> w;
        Resources.reloadRow("story", StoryDoc.path(), res -> Res.withStory(StoryDoc.load(StoryDoc.path()), res), unchanged)
            :: Resources.reloadUnnamedRow(Talk.dialoguePath(), res -> Res.withDialogue(Talk.load(), res), WorldRead.settleDialogue)
            :: (Resources.reloadRow("kind", KindDoc.path(), res -> Res.withKind(KindDoc.load(KindDoc.path()), res), unchanged)
                |> DocTable.withActiveWhen(Resources.read((_, w) -> World.isReading(w))))
            :: Resources.reloadRow("theme", ThemeDoc.path(), res -> Res.withTheme(ThemeDoc.load(ThemeDoc.path()), res), unchanged)
            :: Resources.reloadRow("backdrops", BackdropDoc.path(), res -> Res.withBackdrops(BackdropDoc.load(BackdropDoc.path()), res), unchanged)
            :: (Resources.reloadRow("credits", CreditsDoc.path(), res -> Res.withCredits(CreditsDoc.load(CreditsDoc.path()), res), unchanged)
                |> DocTable.withActiveWhen(Resources.read((_, w) -> World.isCredits(w))))
            :: Resources.reloadRow("keys", KeysDoc.path(), res -> Res.withKeys(KeysDoc.load(KeysDoc.path()), res), unchanged)
            :: Resources.reloadRow("small", SmallScreenDoc.path(), res -> Res.withSmallScreen(SmallScreenDoc.load(SmallScreenDoc.path()), res), unchanged)
            :: Resources.reloadRow("portrait", PortraitDoc.path(), res -> Res.withPortrait(loadPortrait(), res), unchanged)
            :: Resources.reloadRow("rail", RailDoc.path(), res -> Res.withPortrait(loadPortrait(), res), unchanged)
            :: Resources.reloadRow("cast", CastDoc.path(), res -> Res.withCast(CastDoc.load(CastDoc.path()), res), unchanged)
            :: Resources.reloadRow("mixer", mixerPath(), res -> Res.withMixer(AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()), res), unchanged)
            :: Nil
}
