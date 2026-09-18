// Controls — キーを World.Input へ写し、World.step で 1 歩進める（純粋）。
// どのキーがどの操作かは KeysDoc（player.keys.json）が決める — 既定は
// ←→↑↓（矢印キー）と WASD。エディタで割り当てを変えて保存すると即反映。
// Doc の保存即反映（watchFile）と F1 一括リロードの読み直しもここに置く。
mod Controls {

    /// このフレームのキーを World.Input へ。操作ごとのキーの列（keys Doc）の
    /// どれか 1 つでも押されていれば効き、逆向きが同時なら打ち消して 0。
    pub def inputOf(frame: App.Frame, keys: KeysDoc.Doc): World.Input =
        let held = ks -> List.exists(k -> App.isDown(k, frame), ks);
        let axis = (negDown, posDown) ->
            (if (posDown) 1.0 else 0.0) - (if (negDown) 1.0 else 0.0);
        let k = KeysDoc.rec(keys);
        { x = axis(held(k#left), held(k#right)),
          y = axis(held(k#up), held(k#down)) }

    /// 毎フレームのシステム。
    pub def step(frame: App.Frame, w: World.World): World.World =
        World.step(inputOf(frame, w#keys), frame#dt, w)

    // ── Doc の読み直し（watchFile / F1） ──

    pub def reloadDoc(w: World.World): World.World \ Fs.FileRead =
        World.withDoc(SampleDoc.load(SampleDoc.path()), w)

    pub def reloadKeys(w: World.World): World.World \ Fs.FileRead =
        World.withKeys(KeysDoc.load(KeysDoc.path()), w)

    /// テーマは色に加えて「塗りの仕上げ」も持つので、絵も読み直して掛け直す
    /// （仕上げは読み込み時に 1 回だけ掛かる = 絵の側に生成の結果として定着しているため）。
    pub def reloadTheme(w: World.World): World.World \ Fs.FileRead =
        World.withTheme(ThemeDoc.load(ThemeDoc.path()),
            PxSpriteDoc.load(World.spritePath()), w)

    pub def reloadSprites(w: World.World): World.World \ Fs.FileRead =
        World.withSprites(PxSpriteDoc.load(World.spritePath()), w)

    /// 空の塗り。壊れていれば engine の見本の面にする（何も出ないより気付ける）。
    pub def loadShader(): ShaderDoc.Spec \ Fs.FileRead =
        ShaderJson.loadOr(ShaderDoc.demoSurface(), World.shaderPath())

    pub def reloadShader(w: World.World): World.World \ Fs.FileRead =
        World.withShader(loadShader(), w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物。
    /// この骨組みは場面が 1 つで、5 行とも常に絵に効いている。場面（表紙・クリア等）が
    /// 増えたら、出ていない行に activeWhen を被せること
    /// （全部を常時 active にするとバッジの意味が死ぬ）。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("sample", SampleDoc.path(),     reloadDoc)
            :: DocTable.row("keys",   KeysDoc.path(),       reloadKeys)
            :: DocTable.row("theme",  ThemeDoc.path(),      reloadTheme)
            :: DocTable.row("sprite", World.spritePath(),   reloadSprites)
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
