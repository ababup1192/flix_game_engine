// Controls — 入力の解釈（純粋）と Doc の読み直し。
// 操作は「左右に動かす」(←→、押した瞬間ごとに 1 マス)・「そっと落とす」(↓ 押しっぱなしで加速)・
// 「回す」(Z=反時計 / X=時計、押した瞬間)・「叩きつける」(↑ または Space=ハードドロップ)・
// GAME OVER からの「仕切り直し」(Space/Enter)。
// 押した瞬間だけ効く操作（回転・叩きつけ・決定）は justPressed、押しっぱなしで効く操作
// （左右の移動・そっと落とす）は isDown を使う。
mod Controls {
    use fge::{App, DocTable, Emit, Hash01, ShaderDoc, ShaderJson}
    use fge::GameEngine.Key

    /// 毎フレームのシステム: まず状態を dt 進め、そのあと押した瞬間の操作を反映する。
    /// softDrop（↓ 押しっぱなし）だけは step の落下加速に渡す。
    /// 規則が出した出来事は events 欄に溜める（音は Controls.sounds が前後の差で読む）。
    pub def step(frame: App.Frame, w: World.World): World.World =
        let (next, events) = Emit.collectInto(() -> rules(frame, w), w#events);
        { events = events | next }

    def rules(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        World.step(App.isDown(Key.Down, frame), frame#dt, w)
            |> (w1 -> applyTaps(frame, w1))

    /// 一発の音の名前（project.json の sounds の論理名）。音の案は art/sfx.snd.star を bin/fge snd build で
    /// atelier/sfx へ書く（採用して project.json の sounds に載せるまでは、鳴らすと名前ごとに 1 回 warn が出るだけ）。
    pub enum Sound with Eq, ToString {
        case Lock
        case LineA
        case LineB
        case Tetris
        case Over
    }

    pub def soundName(sound: Sound): String = match sound {
        case Sound.Lock   => "lock"
        case Sound.LineA  => "line_a"
        case Sound.LineB  => "line_b"
        case Sound.Tetris => "tetris"
        case Sound.Over   => "over"
    }

    /// 1 フレームの音: このフレームに溜まった出来事（Emit.since）を音へ写す（App.withAudio に渡す形）。
    /// 1〜3 行消しの音は 2 つから選ぶ。選びは消した通算の行数で決まる（同じ遊び方なら同じ音）。
    pub def sounds(ws: { before = World.World, after = World.World }): List[String] =
        Emit.since(ws#before#events, ws#after#events) |> List.filterMap(e -> soundOf(ws#after, e)) |> List.map(soundName)

    def soundOf(w: World.World, event: World.Event): Option[Sound] = match event {
        case World.Event.Locked      => Some(Sound.Lock)
        case World.Event.Cleared(4)  => Some(Sound.Tetris)
        case World.Event.Cleared(_)  => Hash01.pickBy({ index = w#lines, channel = 0 }, Sound.LineA :: Sound.LineB :: Nil)
        case World.Event.ToppedOut   => Some(Sound.Over)
        case World.Event.LinesFull(_) => None
    }

    /// 押した瞬間だけ効く操作（左右の 1 マス寄せ・回転・叩きつけ・決定）を反映する。
    /// 左右も justPressed にして「1 押し = 1 マス」にする（押しっぱなしで滑らない素直な操作）。
    def applyTaps(frame: App.Frame, w: World.World): World.World \ Emit[World.Event] =
        let tap = key -> App.justPressed(key, frame);
        w
            |> (w1 -> if (tap(Key.Left))  World.moveLeft(w1)  else w1)
            |> (w1 -> if (tap(Key.Right)) World.moveRight(w1) else w1)
            |> (w1 -> if (tap(Key.Z))     World.rotateCCW(w1) else w1)
            |> (w1 -> if (tap(Key.X))     World.rotateCW(w1)  else w1)
            |> (w1 -> if (tap(Key.Up))    World.hardDrop(w1)  else w1)
            |> (w1 -> if (tap(Key.Space)) confirm(w1)         else w1)
            |> (w1 -> if (tap(Key.Enter)) confirm(w1)         else w1)

    /// Space / Enter の意味は場面で変わる: GAME OVER なら仕切り直し、遊び中なら叩きつけ。
    /// （Enter 中の叩きつけは Space と同じ扱い — どちらでも落とせる。）
    def confirm(w: World.World): World.World \ Emit[World.Event] =
        match w#phase {
            case World.Phase.GameOver => World.restart(w)
            case _                    => World.hardDrop(w)
        }

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub def loadDocs(): World.Docs \ Fs.FileRead =
        { doc = RulesDoc.load(RulesDoc.path()), theme = ThemeDoc.load(ThemeDoc.path()),
          shader = loadShader() }

    /// 盤の下に敷く紙の面。読めない・語彙が違うときはエンジンの見本の面へ落とす（fail-open）。
    pub def loadShader(): ShaderDoc.Spec \ Fs.FileRead =
        ShaderJson.loadOr(ShaderDoc.demoSurface(), World.shaderPath())

    pub def reloadRules(w: World.World): World.World \ Fs.FileRead =
        World.withRules(RulesDoc.load(RulesDoc.path()), w)

    pub def reloadTheme(w: World.World): World.World \ Fs.FileRead =
        World.withTheme(ThemeDoc.load(ThemeDoc.path()), w)

    pub def reloadShader(w: World.World): World.World \ Fs.FileRead =
        World.withShader(loadShader(), w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物。
    /// 盤・ミノは常に色（theme）と数値（rules）で描かれるので、3 行とも常時表示中。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("rules",  RulesDoc.path(),      reloadRules)
            :: DocTable.row("theme",  ThemeDoc.path(),      reloadTheme)
            :: DocTable.row("shader", World.shaderPath(),   reloadShader)
            :: Nil

    /// App.game の reloads(保存即反映の watchFile)へ渡す形。
    pub def reloads(): List[(String, World.World -> World.World \ Fs.FileRead)] =
        DocTable.reloads(docTable())

    /// F1: 一覧表の順に Doc を全部読み直す。
    pub def reloadAll(w: World.World): World.World \ Fs.FileRead =
        DocTable.reloadAll(docTable(), w)

    /// いま画面に出ている Doc（Studio の「表示中」バッジの材料）。
    pub def activeDocs(w: World.World): List[(String, List[String])] =
        DocTable.activeDocs(docTable(), w)
}
