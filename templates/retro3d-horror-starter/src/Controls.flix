// Controls — キーとマウスを World.Input へ写し、World.step で 1 歩進める（純粋）。
// どのキーがどの操作かは KeysDoc（player.keys.json）が決める — 既定は W S（↑ ↓）で前後・A D で横歩き・← →（Q E）で向き・R F で見上げ見下ろし・Shift を押している間は走る。
// クリックでマウスを視点に取り込み（frame#mouseDelta で見回す）、取り込んでいる間の Esc は放すだけ・放している間の Esc で終了の確認。
// Doc と校舎の形の読み込み（loadDocs）と、保存即反映（watchFile）・F1 一括リロードの読み直しもここに置く。
mod Controls {

    use fge::{App, BackgroundLoad, DocTable, GameEngine, LoadProgress, Log, Resources, SortingLayer, Vec2, Yarn}

    /// このフレームのキーとマウスを World.Input へ（逆向きが同時なら打ち消して 0）。
    def inputOf(frame: App.Frame, keys: KeysDoc.Doc, captured: Bool): World.Input =
        let held = ks -> List.exists(k -> App.isDown(k, frame), ks);
        let axis = (negDown, posDown) ->
            (if (posDown) 1.0 else 0.0) - (if (negDown) 1.0 else 0.0);
        let k = KeysDoc.rec(keys);
        { forward = axis(held(k#back), held(k#forward)),
          strafe = axis(held(k#strafeLeft), held(k#strafeRight)),
          turn = axis(held(k#turnLeft), held(k#turnRight)),
          pitch = axis(held(k#lookUp), held(k#lookDown)),
          look = if (captured) frame#mouseDelta else Vec2.zero(),
          dash = held(k#dash),
          active = isActive(frame) }

    /// このコマに何かを操作したか: キー（仮想パッドのボタンと十字キー・ゲームパッドのボタンもキーとして届く）・マウスの押しと動きとホイール・
    /// 画面の指（タップとドラッグはマウスとして届く）・ゲームパッドのスティック。
    def isActive(frame: App.Frame): Bool =
        not Set.isEmpty(frame#down) or frame#mouseDown or not Set.isEmpty(frame#mouseButtons) or frame#mouseMoved or frame#wheel != 0.0
            or isOffCenter(frame#mouseDelta) or frame#padTouched or isOffCenter(frame#leftStick) or isOffCenter(frame#rightStick)

    def isOffCenter(v: Vec2.Vec2): Bool = v#x != 0.0 or v#y != 0.0

    /// 毎フレームのシステム。終了の確認の窓が出ている間は Enter で終わる・Esc で戻る（マウスは tapAt）。
    /// 決定（話すキー 既定 Space・Enter・Z かクリック）は目の前の物の順に効く: 人物に話しかける > 物を拾う > 鍵の戸を調べる。
    /// 話している間は同じキーかクリックで文字送り・Esc で会話をやめる。拾う演出の間は決定で早めに閉じる。
    /// 持ち物のキー（既定 I・Tab・C）でアイテム画面を開く。
    /// Esc と Enter は OS の決まりに合わせた固定のキー（割り当ての Doc には載せない）。F3 で重さの表示（fps・CPU と GPU の ms・3D の数）を出す・消す。
    pub def step(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let pressed = key -> App.justPressed(key, frame);
        let k = KeysDoc.rec(res#keys);
        let talkPressed = List.exists(pressed, k#talk) or frame#mouseClicked;
        let w1 =
            if (World.isAskingQuit(w))
                (if (pressed(GameEngine.Key.Enter)) World.answerQuit(true, w)
                 else if (pressed(GameEngine.Key.Escape)) World.answerQuit(false, w)
                 else w)
            else if (World.isMapOpen(w)) onMap(frame, res, w)
            else if (World.isTalking(w)) (if (pressed(GameEngine.Key.Escape)) World.endTalk(w) else if (talkPressed) World.advanceTalk(frame#realNow, w) else w)
            else if (World.isPickingUp(w)) (if (talkPressed or pressed(GameEngine.Key.Escape)) World.endPickup(res, w) else w)
            else if (World.isItemsOpen(w)) onItems(frame, res, w)
            else if (talkPressed and Option.nonEmpty(World.talkTargetOf(res, w))) World.startTalk(res, frame#realNow, w)
            else if (talkPressed and Option.nonEmpty(World.pickupTargetOf(res, w))) World.startPickup(res, w)
            else if (talkPressed and Option.nonEmpty(World.doorTargetOf(res, w))) World.tryDoor(res, w)
            else if (List.exists(pressed, k#items)) World.openItems(w)
            else if (List.exists(pressed, k#map)) World.openMap(res, World.releaseMouse(w))
            else if (pressed(GameEngine.Key.Escape) and World.isMouseCaptured(w)) World.releaseMouse(w)
            else if (pressed(GameEngine.Key.Escape)) World.askQuit(w)
            else w;
        let w2a = if (frame#mouseClicked and World.isAskingQuit(w1)) tapAt(res, frame#cursor, w1) else w1;
        let w2b = if (pressed(GameEngine.Key.F3)) World.togglePerf(w2a) else w2a;
        let w2 = World.notePerf(frame#dt, w2b);
        let next = World.step(res, inputOf(frame, res#keys, World.wantsMouseCapture(w2)), frame#dt, w2);
        // WhyNot: 取り込みを World.step の前に始めない — クリックしたコマの mouseDelta は取り込む前に自由に動いた量で、視点が跳ねる。
        let busy = World.isAskingQuit(w1) or World.isMapOpen(w1) or World.isTalking(w) or World.isTalking(w1)
            or World.isPickingUp(w) or World.isPickingUp(w1) or World.isItemsOpen(w) or World.isItemsOpen(w1);
        if (frame#mouseClicked and not busy) World.captureMouse(next) else next

    /// 紙のマップを開いている間のキー: マップのキー・Esc・X（ゲームパッドの B）で閉じる・左右（と向きのキー）で階を替える・1〜3 でその階。
    def onMap(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let pressed = key -> App.justPressed(key, frame);
        let k = KeysDoc.rec(res#keys);
        let digit = ((GameEngine.Key.Digit1, 1) :: (GameEngine.Key.Digit2, 2) :: (GameEngine.Key.Digit3, 3) :: Nil)
            |> List.find(e -> pressed(fst(e))) |> Option.map(snd);
        if (List.exists(pressed, k#map) or pressed(GameEngine.Key.Escape) or pressed(GameEngine.Key.X)) World.closeMap(w)
        else if (List.exists(pressed, k#turnLeft) or List.exists(pressed, k#strafeLeft)) World.shiftFloor(res, -1, w)
        else if (List.exists(pressed, k#turnRight) or List.exists(pressed, k#strafeRight)) World.shiftFloor(res, 1, w)
        else digit |> Option.map(n -> World.showFloor(res, n, w)) |> Option.getWithDefault(w)

    /// アイテム画面を開いている間のキー: 持ち物のキー・Esc・X（ゲームパッドの B）で閉じる・前後のキー（と ↑ ↓）で選ぶ物を替える。
    def onItems(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let pressed = key -> App.justPressed(key, frame);
        let k = KeysDoc.rec(res#keys);
        if (List.exists(pressed, k#items) or pressed(GameEngine.Key.Escape) or pressed(GameEngine.Key.X)) World.closeItems(w)
        else if (List.exists(pressed, k#forward)) World.moveItemCursor(res, -1, w)
        else if (List.exists(pressed, k#back)) World.moveItemCursor(res, 1, w)
        else w

    /// cursor を押した。押した物は絵と同じ木（View.promptLayers）から描く順の手前で選ぶ —— 窓の奥には届かない。
    pub def tapAt(res: Res.Res, cursor: Vec2.Vec2, w: World.World): World.World =
        let ctx = App.pickCtx({ x = World.width(), y = World.height() });
        match SortingLayer.pickFrom(cursor, View.promptLayers(ctx, View.promptOf(res, w))) {
            case Some(World.Press.QuitYes) => World.answerQuit(true, w)
            case Some(World.Press.QuitNo)  => World.answerQuit(false, w)
            case None                      => w
        }

    // ── Doc と形の読み込み・読み直し（watchFile / F1） ──

    /// 起動時と描き出しが同じ形で読む物の束。配置の表が読めなければ止める（校舎が組めない: 起動時の必須入力）。
    /// 校舎の束と人物の glb は BackgroundLoad で読む: デスクトップと描き出しは全部をここで読み、ブラウザ版は起動の素材の鍵だけを読んで
    /// 残りを待ちの表（pending）に載せる（届いたら Game.app の withBackgroundLoad が解く）。読めない鍵はその物なしで続ける（理由を 1 行）。
    pub def loadDocs(): Res.Docs \ Fs.FileRead + IO + LoadProgress =
        LoadProgress.report("reading docs...", 0, 0);
        let layout = match Layout.load(Layout.path()) {
            case Ok(l)    => l
            case Err(why) => bug!("[night_school] 校舎の配置の表を読めない: ${why}")
        };
        let cast = CastDoc.load(CastDoc.path());
        let bundles = Bundles.load(layout#placeholder, Bundles.path());
        let models = CastDoc.rec(cast)#members |> List.map(m -> m#model) |> List.distinct;
        let items = ItemsDoc.load(ItemsDoc.path());
        let group = Bundles.group(bundles, models, itemGlbs(items), LoadProgress.imageDecoder());
        let (loaded, pending) = BackgroundLoad.start(group);
        let empty = ({ floors = Map.empty(), props = Map.empty(), surfaces = Res.surfaces() }, Map.empty());
        let (assets, people) = loaded |> Map.foldLeftWithKey((acc, key, result) -> match result {
            case Ok(model) => Res.placeModel(layout, key, model, acc)
            case Err(why)  => Log.warnThen("[school] ${key} を読めない（その物なしで続ける）: ${why}", acc)
        }, empty);
        { walk = WalkDoc.load(WalkDoc.path()), keys = KeysDoc.load(KeysDoc.path()), look = LookDoc.load(LookDoc.path()),
          sound = SoundDoc.load(SoundDoc.path()), layout = layout, assets = assets, items = items, cast = cast, people = people, dialogue = loadDialogue(),
          bundles = bundles, pending = pending, group = group, downloads = LoadProgress.downloads() }

    // ── ブラウザ版で後から届く束と人物（デスクトップは全部 Loaded なので、どれも何もしない） ──

    /// 持ち物の glb の名前（重ならない物）。
    def itemGlbs(items: ItemsDoc.Doc): List[String] = ItemsDoc.rec(items)#items |> List.map(i -> i#glb) |> List.distinct

    /// 今要る鍵: 描く階（School.visibleFloors）に物を置く束と、描く階にいる人物と、持ち物（小さいので全部）。解く順の頭へ回し、届いていれば待たずに解く。
    pub def wantedKeys(res: Res.Res, w: World.World): List[String] =
        let floors = School.visibleFloors(res#layout, World.feetOf(w));
        let bundleKeys = floors |> List.flatMap(Bundles.keysOnFloor(res#bundles));
        let personKeys = CastDoc.rec(res#cast)#members
            |> List.filter(m -> List.memberOf(Layout.floorIndexAt(m#feet#y, res#layout), floors))
            |> List.map(m -> Bundles.personKey(m#model));
        List.flatten(bundleKeys :: personKeys :: (itemGlbs(res#items) |> List.map(Bundles.itemKey)) :: Nil) |> List.distinct

    /// 解く予算: 今要る鍵が届いて解く順番を待っている時と、紙のマップを開いている間は、見込みを問わず 1 本解く（Covered）。
    /// ほかは Idle（束 1 本の見込みは収まらないので始めない）。
    // WhyNot: 届いた鍵を全部すぐ解かない — 束 1 本はスマホで数百 ms 止まる。2・3 階の束は階段の近くかマップの間まで解かない。
    pub def decodeBudget(res: Res.Res, w: World.World): LoadProgress.DecodeBudget =
        let downloaded = key -> BackgroundLoad.stateOf(key, res#pending) == LoadProgress.LoadState.Downloaded;
        if (World.isMapOpen(w) or List.exists(downloaded, wantedKeys(res, w))) LoadProgress.DecodeBudget.Covered(40.0)
        else LoadProgress.DecodeBudget.Idle(4.0)

    /// engine の待ち（App.withLoadGate）へ渡す道: 今いる階の建物の束。届くまで前の場面のまま待つ（階段を上り切る前に止まる）。
    /// 小物の束は待たない（建物だけで歩けて、届いたら足される）。人物は届くまで話しかけられない（World.talkTargetOf）。
    pub def loadGate(res: Res.Res, w: World.World): List[String] =
        Bundles.buildingPathsOf(res#bundles, Layout.floorIndexAt(World.feetOf(w)#y, res#layout))

    /// 会話の台詞（bin/fge yarn build assets/talk が書いた木）。読めなければ台詞の無い木（話しかけても何も出ない）。
    def loadDialogue(): Yarn.Program \ Fs.FileRead = Yarn.loadOr(Yarn.empty(), dialoguePath())

    pub def dialoguePath(): String = "assets/talk/dialogue.json"

    def reloadWalk(res: Res.Res): Res.Res \ Fs.FileRead = Res.withWalk(WalkDoc.load(WalkDoc.path()), res)

    def reloadKeys(res: Res.Res): Res.Res \ Fs.FileRead = Res.withKeys(KeysDoc.load(KeysDoc.path()), res)

    def reloadSound(res: Res.Res): Res.Res \ Fs.FileRead = Res.withSound(SoundDoc.load(SoundDoc.path()), res)

    def reloadLook(res: Res.Res): Res.Res \ Fs.FileRead = Res.withLook(LookDoc.load(LookDoc.path()), res)

    // WhyNot: 人物の glb は読み直さない — 画像を戻すのは IO で、watchFile の読み直しは Fs.FileRead だけの口。置き場所と決まりだけ替わる。
    def reloadCast(res: Res.Res): Res.Res \ Fs.FileRead = Res.withCast(CastDoc.load(CastDoc.path()), res)

    def reloadDialogue(res: Res.Res): Res.Res \ Fs.FileRead = Res.withDialogue(loadDialogue(), res)

    // WhyNot: 持ち物の glb は読み直さない — 人物と同じく、画像を戻すのは IO で watchFile の口に無い。置き場所・鍵・文言だけ替わる。
    def reloadItems(res: Res.Res): Res.Res \ Fs.FileRead = Res.withItems(ItemsDoc.load(ItemsDoc.path()), res)

    /// 配置の表を読み直す（壊れていれば今の表のまま）。
    def reloadLayout(res: Res.Res): Res.Res \ Fs.FileRead = match Layout.load(Layout.path()) {
        case Ok(l)    => Res.withLayout(l, res)
        case Err(why) => Log.warnThen("[school] 配置の表を読み直せない（今の表のまま）: ${why}", res)
    }

    /// 表が替わって今の足元に床が無くなっていたら、始まりへ立たせ直す（歩いている途中の表の直しで奈落へ落ちない）。
    def settleLayout(res: Res.Res, w: World.World): World.World =
        let stayed = World.placeAt(res, World.feetOf(w), World.yawOf(w), w);
        if (World.isOnFloor(stayed)) stayed else World.placeAt(res, res#layout#start#pos, res#layout#start#yaw, w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。docId は project.json の editor.resources[] の id と同じ物。
    pub def docTable(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] =
        let unchanged = (_, w) -> w;
        Resources.reloadRow("walk", WalkDoc.path(), reloadWalk, unchanged)
            :: Resources.reloadRow("keys", KeysDoc.path(), reloadKeys, unchanged)
            :: Resources.reloadRow("look", LookDoc.path(), reloadLook, unchanged)
            :: Resources.reloadRow("sound", SoundDoc.path(), reloadSound, unchanged)
            :: Resources.reloadRow("layout", Layout.path(), reloadLayout, settleLayout)
            :: Resources.reloadRow("characters", CastDoc.path(), reloadCast, unchanged)
            :: Resources.reloadRow("items", ItemsDoc.path(), reloadItems, unchanged)
            :: Resources.reloadRow("talk", dialoguePath(), reloadDialogue, unchanged)
            :: Nil
}
