// Controls — 入力の解釈（純粋）と Doc の読み込み・読み直し。
// 操作: ←→ = ハンドル / ↓ = ブレーキ / X = ドリフト / Z = ニトロ発動 /
// Space・Enter = 場面の「決定」（Title→レース / Win・Lose→Title）。
// 連続入力（ハンドル・ブレーキ・ドリフト）は isDown、単発（ニトロ・決定）は justPressed で拾う。
mod Controls {
    use GameEngine.Key

    /// 毎フレームのシステム: 入力を Inputs に組んで World.step へ渡し、
    /// そのあと押した瞬間の「決定」（場面の切り替え）を反映する。
    pub def step(frame: App.Frame, w: World.World): World.World =
        let inputs = {
            dir = App.axis(negative = Key.Left, positive = Key.Right, frame),
            brake = App.isDown(Key.Down, frame),
            driftHeld = App.isDown(Key.X, frame),
            nitroTap = App.justPressed(Key.Z, frame)
        };
        World.step(inputs, frame#dt, w)
            |> (w1 -> applyConfirm(frame, w1))

    /// 場面の「決定」（Space / Enter を押した瞬間）を反映する。意味は場面依存（World.confirm）。
    /// 走行中の Space/Enter は何もしない。
    def applyConfirm(frame: App.Frame, w: World.World): World.World =
        let tapped = App.justPressed(Key.Space, frame) or App.justPressed(Key.Enter, frame);
        if (tapped) World.confirm(w) else w

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    /// 起動時と描き出しが同じ形で読む Doc の束。fx はテーマの色（"@色"）で解決するので、
    /// テーマを先に読んでから fx を組む。
    pub def loadDocs(): World.Docs \ Fs.FileRead =
        let theme = ThemeDoc.load(ThemeDoc.path());
        { rules = RulesDoc.load(RulesDoc.path()),
          rivalsCfg = RivalsDoc.load(RivalsDoc.path()),
          theme = theme,
          course = CourseDoc.load(CourseDoc.path()),
          props = PropsDoc.load(PropsDoc.path()),
          palette = PaletteDoc.load(PaletteDoc.path()),
          sprites = PxSpriteDoc.load(World.spritePath()),
          fx = loadFx(theme),
          sfxtune = SfxTuneDoc.load(SfxTuneDoc.path()) }

    // ── fx（粒の効果）の読み込み ──

    pub def fxSmokePath(): String = "assets/fx/drift-smoke.fx.json"
    pub def fxSparkPath(): String = "assets/fx/spark.fx.json"
    pub def fxFlamePath(): String = "assets/fx/nitro-flame.fx.json"
    pub def fxShockPath(): String = "assets/fx/nitro-burst.fx.json"
    pub def fxCrashPath(): String = "assets/fx/crash.fx.json"

    /// fx.json 5 本を Spec に読む。fx の "@色" はここでテーマから引いて生成時に埋め込まれる —
    /// テーマの保存だけでは fx の色は変わらない（F1 か fx の保存で反映。reloadTheme は
    /// そのため fx も読み直す）。
    pub def loadFx(theme: ThemeDoc.Doc): World.FxSpecs \ Fs.FileRead =
        let pal = fxPalette(theme);
        { smoke = loadSpec(pal, fxSmokePath()),
          spark = loadSpec(pal, fxSparkPath()),
          flame = loadSpec(pal, fxFlamePath()),
          shock = loadSpec(pal, fxShockPath()),
          crash = loadSpec(pal, fxCrashPath()) }

    /// fx.json 1 本を Spec に読む。読めない・壊れているときは空の効果（fail-open —
    /// 粒が出ないだけでゲームは止まらない）。
    def loadSpec(pal: Map[String, Color], p: String): FxDoc.Spec \ Fs.FileRead =
        DocJson.readJson(p)
            |> Result.flatMap(json -> FxDoc.parseWith(pal, json))
            |> Result.getWithDefault(FxDoc.empty())

    /// fx.json の "@名前" が引けるテーマ色の表。ここに無い名前は fx 側でエラーになり
    /// 空の効果へ落ちる（増やすときはこの表と theme を一緒に増やす）。
    def fxPalette(theme: ThemeDoc.Doc): Map[String, Color] =
        Map#{"smoke" => ThemeDoc.rec(theme)#smoke,
             "ash" => ThemeDoc.ash(theme),
             "flame" => ThemeDoc.rec(theme)#flame,
             "flameCore" => ThemeDoc.flameCore(theme),
             "flameHot" => ThemeDoc.flameHot(theme),
             "flameDeep" => ThemeDoc.flameDeep(theme),
             "spark" => ThemeDoc.spark(theme)}

    // ── reload（保存即反映・F1） ──

    pub def reloadRules(w: World.World): World.World \ Fs.FileRead =
        World.withRules(RulesDoc.load(RulesDoc.path()), w)

    pub def reloadRivals(w: World.World): World.World \ Fs.FileRead =
        World.withRivalsCfg(RivalsDoc.load(RivalsDoc.path()), w)

    /// テーマの読み直し。fx の色はテーマから生成時に埋め込まれているので、fx も一緒に読み直す
    /// （テーマだけ替えると煙や炎が古い色のまま残るため）。
    pub def reloadTheme(w: World.World): World.World \ Fs.FileRead =
        let theme = ThemeDoc.load(ThemeDoc.path());
        World.withFx(loadFx(theme), World.withTheme(theme, w))

    pub def reloadCourse(w: World.World): World.World \ Fs.FileRead =
        World.withCourse(CourseDoc.load(CourseDoc.path()), w)

    pub def reloadProps(w: World.World): World.World \ Fs.FileRead =
        World.withProps(PropsDoc.load(PropsDoc.path()), w)

    pub def reloadPalette(w: World.World): World.World \ Fs.FileRead =
        World.withPalette(PaletteDoc.load(PaletteDoc.path()), w)

    pub def reloadSprites(w: World.World): World.World \ Fs.FileRead =
        World.withSprites(PxSpriteDoc.load(World.spritePath()), w)

    /// fx.json の保存で 5 本まとめて読み直す（いまの World のテーマ色で解決する）。
    pub def reloadFx(w: World.World): World.World \ Fs.FileRead =
        World.withFx(loadFx(w#theme), w)

    /// 効果音のつまみの読み直し。ここで届くのは鳴らす間隔だけ —— 音量・高さ・長さは
    /// 生成した WAV に入っているので、make render-all で生成し直して起動し直すまで変わらない。
    pub def reloadSfxTune(w: World.World): World.World \ Fs.FileRead =
        World.withSfxTune(SfxTuneDoc.load(SfxTuneDoc.path()), w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物。
    ///
    /// fx 5 本はどれを保存しても reloadFx（5 本まとめ読み）— 1 本ずつ差し替えるほど
    /// 数が多くないので、配管を 1 種類に保つ。F1 では reloadTheme が同じ物を
    /// 作り直すので withoutReloadAll（一括で 5 回読み直さない）。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        DocTable.row("rules",   RulesDoc.path(),     reloadRules)
            :: DocTable.row("rivals",  RivalsDoc.path(),    reloadRivals)
            :: DocTable.row("theme",   ThemeDoc.path(),     reloadTheme)
            :: DocTable.row("course",  CourseDoc.path(),    reloadCourse)
            :: DocTable.row("props",   PropsDoc.path(),     reloadProps)
            :: DocTable.row("palette", PaletteDoc.path(),   reloadPalette)
            :: DocTable.row("sprite",  World.spritePath(),  reloadSprites)
            :: DocTable.row("sfxtune", SfxTuneDoc.path(),   reloadSfxTune)
            :: List.map(p -> DocTable.unnamedRow(p, reloadFx) |> DocTable.withoutReloadAll,
                   fxSmokePath() :: fxSparkPath() :: fxFlamePath()
                       :: fxShockPath() :: fxCrashPath() :: Nil)

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
