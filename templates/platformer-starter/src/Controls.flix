// Controls — キーを World.Input へ写し、World.step で 1 歩進める(純粋)。
// どのキーがどの操作かは KeysDoc(player.keys.json)が決める — 既定は
// ←→(A・D)で歩き、Space か ↑(W)でジャンプ、↓(S)で一方通行から降りる、
// B(Shift・X)を押しっぱなしで B ダッシュ。エディタで割り当てを変えて保存すると即反映。
// Doc の保存即反映(watchFile)と F1 一括リロードの一覧表もここに 1 枚だけ置く。
mod Controls {

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

    pub def step(frame: App.Frame, w: World.World): World.World =
        World.step(inputOf(frame, w#keys), frame#dt, w)

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
