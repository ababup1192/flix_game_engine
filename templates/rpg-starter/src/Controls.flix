// Controls — 入力の解釈（純粋）。キーは InputMap の表で「操作の意図」に写してから解釈する。
// 操作は「歩く」（←→↑↓ / WASD。押しっぱなしで歩き続ける）と
// 「話す・進める」（Z / Enter / Space。押した瞬間だけ）の 2 つだけ。
// Doc の保存即反映（watchFile）と F1 一括リロードの読み直しもここに置く。
mod Controls {
    use flix_game_engine::{App, Dir4, DocJson, DocTable, FxDoc, InputMap, ShaderDoc, ShaderJson}
    use flix_game_engine::GameEngine.Key

    /// 歩く向きの表（押している間ずっと効く）。矢印と WASD は同じ意図。
    /// 同時押しは表の順で先勝ち — 斜めは無い（Dir4 の世界）。
    def moveTable(): InputMap.Table[Dir4.Dir4] =
           (Key.Left,  Dir4.Left)  :: (Key.A, Dir4.Left)
        :: (Key.Right, Dir4.Right) :: (Key.D, Dir4.Right)
        :: (Key.Up,    Dir4.Up)    :: (Key.W, Dir4.Up)
        :: (Key.Down,  Dir4.Down)  :: (Key.S, Dir4.Down)
        :: Nil

    /// 決定（話す・進める）の表（押した瞬間だけ効く）。
    def confirmTable(): InputMap.Table[Unit] =
        (Key.Z, ()) :: (Key.Enter, ()) :: (Key.Space, ()) :: Nil

    /// 毎フレームのシステム: 歩みと文字送りを 1 歩進める。
    pub def step(frame: App.Frame, w: World.World): World.World =
        World.step(List.head(InputMap.held(moveTable(), frame)), frame#dt, w)

    /// 毎フレームのシステム: 決定キーの解釈（表紙では歩き出す・里では話す/送る・
    /// 戦いでは選んだコマンドを実行する）。戦いのカーソル移動（↑↓）も押した瞬間だけ拾う
    /// — 歩きと違って押しっぱなしで滑ってほしくないため。
    pub def interact(frame: App.Frame, w: World.World): World.World =
        let moved = match InputMap.firstTap(moveTable(), frame) {
            case Some(Dir4.Up)   => World.moveCursor(-1, w)
            case Some(Dir4.Down) => World.moveCursor(1, w)
            case _               => w
        };
        match InputMap.firstTap(confirmTable(), frame) {
            case Some(_) => World.confirm(moved)
            case None    => moved
        }

    // ── Doc の読み込み・読み直し（watchFile / F1） ──

    /// 起動時と描き出しが同じ形で読む Doc の束。
    pub def loadDocs(): World.Docs \ Fs.FileRead =
        { map = MapDoc.load(MapDoc.path()),
          kind = KindDoc.load(KindDoc.path()),
          theme = ThemeDoc.load(ThemeDoc.path()),
          battle = BattleDoc.load(BattleDoc.path()),
          sprites = World.loadCharSprites(),
          townSprites = World.loadTownSprites(),
          townMap = TownMapDoc.load(TownMapDoc.path()),
          waterShader = loadWaterShader(),
          smokeFx = loadSmokeFx() }

    pub def waterShaderPath(): String = "assets/town.shader.json"

    pub def smokeFxPath(): String = "assets/town.fx.json"

    /// 水面のシェーダー Doc。読めない・知らない語彙は既製の水面（waterVeins）へ落とす
    /// — 知らない kind が 1 つあるだけで丸ごと既定値になるので、絵が別物なら語彙を疑う。
    def loadWaterShader(): ShaderDoc.Spec \ Fs.FileRead =
        ShaderJson.loadOr(ShaderDoc.waterVeins(), waterShaderPath())

    /// 窯の煙の FxDoc。読めなければ粒なし（empty = 煙が出ないだけで落ちない）。
    /// 読み込みは DocJson.loadOr — 壊れた JSON で粒が消えた事実は標準エラーへ 1 行出る。
    def loadSmokeFx(): FxDoc.Spec \ Fs.FileRead =
        DocJson.loadOr(
            text -> DocJson.parse(String.trim(text)) |> Option.flatMap(j -> FxDoc.parse(j) |> Result.toOption),
            FxDoc.empty(), smokeFxPath())

    pub def reloadMap(w: World.World): World.World \ Fs.FileRead =
        World.withMap(MapDoc.load(MapDoc.path()), w)

    pub def reloadKind(w: World.World): World.World \ Fs.FileRead =
        World.withKind(KindDoc.load(KindDoc.path()), w)

    pub def reloadTheme(w: World.World): World.World \ Fs.FileRead =
        World.withTheme(ThemeDoc.load(ThemeDoc.path()), w)

    pub def reloadBattle(w: World.World): World.World \ Fs.FileRead =
        World.withBattleDoc(BattleDoc.load(BattleDoc.path()), w)

    /// 人と物の絵もファイルが分かれている。どれを保存しても束ね直して 1 枚にする。
    pub def reloadSprites(w: World.World): World.World \ Fs.FileRead =
        World.withSprites(World.loadCharSprites(), w)

    /// 街の絵はファイルが分かれているが、どれを保存しても束ね直して 1 枚にする。
    pub def reloadTownSprites(w: World.World): World.World \ Fs.FileRead =
        World.withTownSprites(World.loadTownSprites(), w)

    pub def reloadTownMap(w: World.World): World.World \ Fs.FileRead =
        World.withTownMap(TownMapDoc.load(TownMapDoc.path()), w)

    pub def reloadWaterShader(w: World.World): World.World \ Fs.FileRead =
        World.withWaterShader(loadWaterShader(), w)

    pub def reloadSmokeFx(w: World.World): World.World \ Fs.FileRead =
        World.withSmokeFx(loadSmokeFx(), w)

    /// Doc の一覧表(DocTable)。watchFile(保存即反映)・F1 の一括リロード・Studio へ名乗る
    /// 「表示中」の 3 つは、どれもこの 1 枚から導出する — 足し忘れで
    /// 「保存しても効かない」「印が付かない」を作らないため。
    /// docId は project.json の editor.resources[] の id と同じ物。
    ///
    /// activeWhen は「その場面で画面に出ているか」。表紙とクリアの幕でも盤は霧の下に
    /// 見えているので map / theme / sprite は出しっぱなし。手触り（kind: 歩く速さ・
    /// 文字送り）は里を歩いている間だけ。戦いの最中は盤が隠れ、出ているのは魔物の絵と
    /// 戦いの数・文言だけ。全部を常時 active にしない（バッジの意味が死ぬ）。
    pub def docTable(): List[DocTable.Entry[World.World]] =
        (DocTable.row("map", MapDoc.path(), reloadMap)
                |> DocTable.withActiveWhen(w -> w#phase != World.Phase.Battle))
            :: (DocTable.row("kind", KindDoc.path(), reloadKind)
                |> DocTable.withActiveWhen(w -> w#phase == World.Phase.Play))
            :: DocTable.row("theme", ThemeDoc.path(), reloadTheme)
            :: (DocTable.row("battle", BattleDoc.path(), reloadBattle)
                |> DocTable.withActiveWhen(w -> w#phase == World.Phase.Battle))
            // 名乗るのは 1 本だけ(Studio の「表示中」は Doc の種類で出る)
            :: DocTable.row("sprite", "assets/rpg_people.sprite.json", reloadSprites)
            :: DocTable.unnamedRow("assets/rpg_item.sprite.json", reloadSprites)
            :: DocTable.unnamedRow("assets/rpg_foe.sprite.json", reloadSprites)
            :: DocTable.unnamedRow(TownMapDoc.path(), reloadTownMap)
            :: DocTable.unnamedRow(waterShaderPath(), reloadWaterShader)
            :: DocTable.unnamedRow(smokeFxPath(), reloadSmokeFx)
            // 街の絵は 6 ファイル。どれを保存しても束ね直す(行は 1 本ずつ要る —
            // 保存即反映は「どのファイルが変わったか」で引くため)
            :: (World.townSpritePaths() |> List.map(path -> DocTable.unnamedRow(path, reloadTownSprites)))

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
