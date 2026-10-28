// Controls — キーを World.Input へ写し、World.step で 1 歩進める（純粋）。
// どのキーがどの操作かは KeysDoc（player.keys.json）が決める — 既定は
// ←→↑↓（矢印キー）と WASD。エディタで割り当てを変えて保存すると即反映。
// Doc の読み込み（loadDocs）と、保存即反映（watchFile）・F1 一括リロードの読み直しもここに置く。
mod Controls {

    use fge::{App, DocTable, GameEngine, PxSpriteDoc, Resources, ShaderDoc, ShaderJson, SortingLayer, Vec2}

    /// このフレームのキーを World.Input へ。操作ごとのキーの列（keys Doc）の
    /// どれか 1 つでも押されていれば効き、逆向きが同時なら打ち消して 0。
    def inputOf(frame: App.Frame, keys: KeysDoc.Doc): World.Input =
        let held = ks -> List.exists(k -> App.isDown(k, frame), ks);
        let axis = (negDown, posDown) ->
            (if (posDown) 1.0 else 0.0) - (if (negDown) 1.0 else 0.0);
        let k = KeysDoc.rec(keys);
        { x = axis(held(k#left), held(k#right)),
          y = axis(held(k#up), held(k#down)) }

    /// 毎フレームのシステム。終了の確認の窓が出ている間は Enter で終わる・Esc で戻る（マウスは tapAt）。
    /// Esc と Enter は OS の決まりに合わせた固定のキー（割り当ての Doc には載せない）。
    pub def step(frame: App.Frame, res: Res.Res, w: World.World): World.World =
        let pressed = key -> App.justPressed(key, frame);
        let w1 =
            if (World.isAskingQuit(w))
                (if (pressed(GameEngine.Key.Enter)) World.answerQuit(true, w)
                 else if (pressed(GameEngine.Key.Escape)) World.answerQuit(false, w)
                 else w)
            else if (pressed(GameEngine.Key.Escape)) World.askQuit(w)
            else w;
        let w2 = if (frame#mouseClicked) tapAt(res, frame#cursor, w1) else w1;
        World.step(res, inputOf(frame, res#keys), frame#dt, w2)

    /// cursor を押した。押した物は絵と同じ木（View.layers）から描く順の手前で選ぶ —— 窓の奥には届かない。
    pub def tapAt(res: Res.Res, cursor: Vec2.Vec2, w: World.World): World.World =
        let ctx = App.pickCtx({ x = World.width(), y = World.height() });
        match SortingLayer.pickFrom(cursor, View.layers(ctx, View.inputOf(res, w))) {
            case Some(World.Press.QuitYes) => World.answerQuit(true, w)
            case Some(World.Press.QuitNo)  => World.answerQuit(false, w)
            case None                      => w
        }

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub def loadDocs(): Res.Docs \ Fs.FileRead =
        { sample = SampleDoc.load(SampleDoc.path()), keys = KeysDoc.load(KeysDoc.path()),
          theme = ThemeDoc.load(ThemeDoc.path()), sprites = PxSpriteDoc.load(World.spritePath()),
          shader = loadShader() }

    /// 空の塗り。壊れていれば engine の見本の面にする（何も出ないより気付ける）。
    def loadShader(): ShaderDoc.Spec \ Fs.FileRead =
        ShaderJson.loadOr(ShaderDoc.demoSurface(), World.shaderPath())

    def reloadSample(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withSample(SampleDoc.load(SampleDoc.path()), res)

    def reloadKeys(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withKeys(KeysDoc.load(KeysDoc.path()), res)

    /// テーマは色に加えて「塗りの仕上げ」も持つので、絵も読み直して掛け直す
    /// （仕上げは読み込み時に 1 回だけ掛かる = 絵の側に生成の結果として定着しているため）。
    def reloadTheme(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withTheme(ThemeDoc.load(ThemeDoc.path()), PxSpriteDoc.load(World.spritePath()), res)

    def reloadSprites(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withSprites(PxSpriteDoc.load(World.spritePath()), res)

    def reloadShader(res: Res.Res): Res.Res \ Fs.FileRead =
        Res.withShader(loadShader(), res)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物。
    /// Doc を足すときは Res に欄と with* を足し、ここに Resources.reloadRow を 1 行足す。
    /// 読み直しで替わるのは Res だけで、World に収め直す物が無いので settle は 5 行とも (_, w) -> w。
    /// 場面（表紙・クリア等）を Screen の case に足したら、出ていない行に DocTable.withActiveWhen を足すこと
    /// （全部を常時 active にすると「表示中」の印が何も区別しなくなる）。
    pub def docTable(): List[DocTable.Entry[Resources.With[Res.Res, World.World]]] =
        let unchanged = (_, w) -> w;
        Resources.reloadRow("sample", SampleDoc.path(),   reloadSample, unchanged)
            :: Resources.reloadRow("keys",   KeysDoc.path(),     reloadKeys, unchanged)
            :: Resources.reloadRow("theme",  ThemeDoc.path(),    reloadTheme, unchanged)
            :: Resources.reloadRow("sprite", World.spritePath(), reloadSprites, unchanged)
            :: Resources.reloadRow("shader", World.shaderPath(), reloadShader, unchanged)
            :: Nil
}
