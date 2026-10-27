// Controls — キーを World の手（動く・待つ・取り消し・やり直し・決定）へ写す（純粋）と、Doc の読み直し。
// どのキーがどの操作かは KeysDoc（player.keys.json）が決める。1 フレームに当てる操作は 1 つだけ。
mod Controls {

    use fge::{App, AudioMixer, AudioMixerDoc, DocTable, Emit, GameEngine, PxSpriteDoc, ShaderDoc, ShaderJson, SortingLayer, Vec2}
    use fge::GameEngine.Key

    /// 毎フレームのシステム。終了の確認の窓が出ている間は Enter で終わる・Esc で戻る（マウスは tapAt）。
    /// Esc と Enter は OS の決まりに合わせた固定のキー（割り当ての Doc には載せない）。
    pub def step(frame: App.Frame, w: World.World): World.World =
        let pressed = key -> App.justPressed(key, frame);
        let w1 = World.tick(frame#dt, w);
        if (World.isAskingQuit(w1))
            (if (pressed(Key.Enter)) World.answerQuit(true, w1)
             else if (pressed(Key.Escape)) World.answerQuit(false, w1)
             else w1)
        else if (pressed(Key.Escape)) World.askQuit(w1)
        else if (frame#mouseClicked) tapAt(frame#cursor, w1)
        else commandOf(frame, KeysDoc.rec(w1#keys)) |> Option.map(c -> apply(c, w1)) |> Option.getWithDefault(w1)

    /// キーが表す操作。
    pub enum Command with Eq, ToString {
        case Go(World.Move)
        case Undo
        case Restart
        case Confirm
    }

    /// このフレームに押した操作（上の行ほど先に見る）。
    def commandOf(frame: App.Frame, k: KeysDoc.Rec): Option[Command] =
        let tapped = (keys: List[Key]) -> List.exists(key -> App.justPressed(key, frame), keys);
        ((k#undo, Command.Undo) :: (k#restart, Command.Restart) :: (k#confirm, Command.Confirm)
            :: (k#left, Command.Go(World.Move.Left)) :: (k#right, Command.Go(World.Move.Right))
            :: (k#up, Command.Go(World.Move.Up)) :: (k#down, Command.Go(World.Move.Down))
            :: (k#wait, Command.Go(World.Move.Wait)) :: Nil)
            |> List.find(e -> tapped(fst(e))) |> Option.map(snd)

    /// 操作を画面ごとに当てる。題名は ←→ で開いた面を選んで決定、遊びは手・取り消し・やり直し・クリアの後の決定、終わりは決定で題名。
    def apply(command: Command, w: World.World): World.World =
        match (w#screen, command) {
            case (World.Screen.Title, Command.Confirm)  => World.enterLevel(w#level, w)
            case (World.Screen.Title, Command.Go(World.Move.Left))  => World.selectLevel(-1, w)
            case (World.Screen.Title, Command.Go(World.Move.Right)) => World.selectLevel(1, w)
            case (World.Screen.Play, Command.Go(move))  => World.play(move, w)
            case (World.Screen.Play, Command.Undo)      => World.undo(w)
            case (World.Screen.Play, Command.Restart)   => World.restart(w)
            case (World.Screen.Play, Command.Confirm)   => World.advance(w)
            case (World.Screen.Ending, Command.Confirm) => World.backToTitle(w)
            case _ => w
        }

    /// cursor を押した。押した物は絵と同じ木（View.layers）から描く順の手前で選ぶ —— 窓の奥には届かない。
    def tapAt(cursor: Vec2.Vec2, w: World.World): World.World =
        let ctx = App.pickCtx({ x = World.width(), y = World.height() });
        match SortingLayer.pickFrom(cursor, View.layers(ctx, View.inputOf(w))) {
            case Some(World.Press.QuitYes) => World.answerQuit(true, w)
            case Some(World.Press.QuitNo)  => World.answerQuit(false, w)
            case None                      => w
        }

    // ── 音（project.json の sounds の論理名。素材は art/sfx.snd.star → assets/sfx） ──

    /// 一発の音。
    pub enum Sound with Eq, ToString {
        case StepSand
        case StepRock
        case Push
        case Driftwood
        case TideHigh
        case TideLow
        case Washed
        case Clear
        case Undo
        case Select
    }

    def soundName(sound: Sound): String = match sound {
        case Sound.StepSand  => "step_sand"
        case Sound.StepRock  => "step_rock"
        case Sound.Push      => "push"
        case Sound.Driftwood => "driftwood"
        case Sound.TideHigh  => "tide_high"
        case Sound.TideLow   => "tide_low"
        case Sound.Washed    => "washed"
        case Sound.Clear     => "clear"
        case Sound.Undo      => "undo"
        case Sound.Select    => "select"
    }

    /// 1 フレームの音: このフレームに溜まった出来事（Emit.since）を音へ写す（App.withAudio に渡す形）。
    pub def sounds(ws: { before = World.World, after = World.World }): List[String] =
        Emit.since(ws#before#events, ws#after#events) |> List.map(e -> soundName(soundOf(e)))

    def soundOf(event: World.Event): Sound = match event {
        case World.Event.WalkedOnSand   => Sound.StepSand
        case World.Event.WalkedOnRock   => Sound.StepRock
        case World.Event.PushedPebble   => Sound.Push
        case World.Event.MovedDriftwood => Sound.Driftwood
        case World.Event.TideFull       => Sound.TideHigh
        case World.Event.TideLow        => Sound.TideLow
        case World.Event.Washed         => Sound.Washed
        case World.Event.Cleared        => Sound.Clear
        case World.Event.Undone         => Sound.Undo
        case World.Event.Restarted      => Sound.Undo
        case World.Event.Cancelled      => Sound.Undo
        case World.Event.Selected       => Sound.Select
    }

    /// 鳴り続ける波の環境音（どの画面でも）。大きさはミキサーの ambience のバスが決める。
    pub def ambience(_w: World.World): List[App.Sustain] = { name = "amb_waves", volume = 1.0, pitch = 1.0 } :: Nil

    def mixerPath(): String = "assets/tidepool.mixer.json"

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    /// 起動時・描き出し・テストが同じ形で読む Doc の束。
    pub def loadDocs(): World.Docs \ Fs.FileRead =
        { rules = RulesDoc.load(RulesDoc.path()), levels = LevelsDoc.load(LevelsDoc.path()),
          keys = KeysDoc.load(KeysDoc.path()), theme = ThemeDoc.load(ThemeDoc.path()),
          sprites = PxSpriteDoc.load(World.spritePath()), surfaces = loadSurfaces(),
          mixer = AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()) }

    /// 面の塗り一式。壊れた Doc は engine の見本の面にする（何も出ないより気付ける）。
    def loadSurfaces(): World.Surfaces \ Fs.FileRead =
        let load = name -> ShaderJson.loadOr(ShaderDoc.waterVeins(), World.surfacePath(name));
        { rock = load("rock"), water = load("water"), caustics = load("caustics") }

    def reloadRules(w: World.World): World.World \ Fs.FileRead =
        World.withRules(RulesDoc.load(RulesDoc.path()), w)

    def reloadLevels(w: World.World): World.World \ Fs.FileRead =
        World.withLevels(LevelsDoc.load(LevelsDoc.path()), w)

    def reloadKeys(w: World.World): World.World \ Fs.FileRead =
        World.withKeys(KeysDoc.load(KeysDoc.path()), w)

    /// テーマは色に加えて「塗りの仕上げ」も持つので、絵も読み直して掛け直す。
    def reloadTheme(w: World.World): World.World \ Fs.FileRead =
        World.withTheme(ThemeDoc.load(ThemeDoc.path()), PxSpriteDoc.load(World.spritePath()), w)

    def reloadSprites(w: World.World): World.World \ Fs.FileRead =
        World.withSprites(PxSpriteDoc.load(World.spritePath()), w)

    def reloadSurfaces(w: World.World): World.World \ Fs.FileRead =
        World.withSurfaces(loadSurfaces(), w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る「表示中」は、
    /// どれもこの 1 枚から導出する。docId は project.json の editor.resources[] の id と同じ物。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("rules",  RulesDoc.path(),   reloadRules)
            :: DocTable.row("levels", LevelsDoc.path(), reloadLevels)
            :: DocTable.row("keys",   KeysDoc.path(),   reloadKeys)
            :: DocTable.row("theme",  ThemeDoc.path(),  reloadTheme)
            :: DocTable.row("sprite", World.spritePath(), reloadSprites)
            :: DocTable.row("mixer",  mixerPath(), w -> World.withMixer(AudioMixerDoc.load(AudioMixer.defaults(), mixerPath()), w))
            :: (("rock" :: "water" :: "caustics" :: Nil)
                |> List.map(name -> DocTable.row("shader", World.surfacePath(name), reloadSurfaces)))
}
