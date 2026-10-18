// Controls — キーを World.Input へ写し、World.step で 1 歩進める(純粋)。
// どのキーがどの操作かは KeysDoc(player.keys.json)が決める — 既定は
// ←→(A・D)で歩き、Space か ↑(W)でジャンプ、↓(S)で一方通行から降りる、
// B(Shift・X)を押しっぱなしで B ダッシュ、P(Enter)でポーズ。エディタで割り当てを変えて保存すると即反映。
// 遊びの時計(World#play)を進めるのは App — ここは addPlayClock で宣言するだけ。
// Doc の保存即反映(watchFile)と F1 一括リロードの一覧表もここに 1 枚だけ置く。
mod Controls {

    use fge::{App, DocTable, Vec2}

    /// このフレームのキーを World.Input へ。操作ごとのキーの列(keys Doc)の
    /// どれか 1 つでも押されていれば効く。ジャンプは「押しっぱなし」(可変ジャンプの
    /// 維持)と「押した瞬間」(先行入力のバッファ)を別に読む — ゆるしの実装は
    /// World/Player 側にある。
    pub def inputOf(frame: App.Frame, keysDoc: KeysDoc.Doc): World.Input =
        let keys = KeysDoc.rec(keysDoc);
        let held = ks -> List.exists(k -> App.isDown(k, frame), ks);
        let pressed = ks -> List.exists(k -> App.justPressed(k, frame), ks);
        { dir = (if (held(keys#right)) 1.0 else 0.0) - (if (held(keys#left)) 1.0 else 0.0),
          jumpHeld = held(keys#jump),
          jumpPressed = pressed(keys#jump),
          drop = held(keys#drop),
          dash = held(keys#dash) }

    /// 1 フレームの系。ポーズのキーは進めた後で見る —— 閉じたフレームは時計がまだ止まっているので、
    /// 先に閉じても遊びはそのフレームには進まない(進むのは次のフレームから・App.addClock の doc)。
    pub def step(frame: App.Frame, w: World.World): World.World =
        let stepped = World.step(inputOf(frame, w#keys), { realNow = frame#realNow | w });
        if (List.exists(k -> App.justPressed(k, frame), KeysDoc.rec(w#keys)#pause)) World.togglePause(stepped)
        else stepped

    /// 遊びの時計を App に宣言する(止め方とヒットストップは World.paceOf)。
    /// Main・描き出し・bot・系を直に呼ぶテストが同じ 1 本を使う。
    pub def addPlayClock(app: App.App[World.World, ef]): App.App[World.World, ef] =
        App.addClock({ clockOf = w -> w#play, withClock = (c, w) -> { play = c | w },
                       paceOf = World.paceOf }, app)

    /// 画面なしで dt 秒の 1 フレームを進める(bot・計測・描き出し)。入力はキーでなく Input で渡し、
    /// 時計は実機と同じ App.advanceFrame が進める。state は前のフレームの戻り値を渡す(頭は App.freshStepState)。
    pub def stepHeadless(input: World.Input, dt: Float64, state: App.StepState,
                         w: World.World): (World.World, App.StepState) =
        let app = App.make(w) |> addPlayClock
            |> App.addSystem((frame, x) -> World.step(input, { realNow = frame#realNow | x }));
        let frame = App.frameOf(prev = Set.empty(), current = Set.empty(), dt, View.design(),
            { prevCursor = None, cursor = Vec2.zero() }, { prevDown = false, down = false, wheel = 0.0 });
        App.advanceFrame(app, frame, state, w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)と F1 の一括リロードは
    /// どちらもこの 1 枚から導出する — 足し忘れで「保存しても効かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物 — これで
    /// 「いま画面に出ているファイル」を Studio に名乗れる(ActiveDocs)。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("motion",  MotionDoc.path(),     World.reloadMotion)
            :: DocTable.row("keys",    KeysDoc.path(),       World.reloadKeys)
            :: DocTable.row("rules",   RulesDoc.path(),      World.reloadRules)
            :: DocTable.row("enemies", EnemyDoc.path(),      World.reloadEnemies)
            :: DocTable.row("stages",  StageDoc.path(),      World.reloadStages)
            :: DocTable.row("theme",   Theme.path(),         World.reloadTheme)
            :: DocTable.row("text",    UiText.path(),        World.reloadUiText)
            :: DocTable.row("sprite",  World.spritePath(),   World.reloadSprites)
            :: Nil

    /// App.game の reloads(保存即反映の watchFile)へ渡す形。
    pub def reloads(): List[(String, World.World -> World.World \ Fs.FileRead)] =
        DocTable.reloads(docTable())

    /// F1: 一覧表の順に全 Doc を読み直す(絵と数値の一括リロード)。
    pub def reloadAll(w: World.World): World.World \ Fs.FileRead =
        DocTable.reloadAll(docTable(), w)
}
