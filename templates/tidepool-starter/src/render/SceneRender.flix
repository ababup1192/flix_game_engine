// SceneRender — ゲーム画面を画面なしで PNG に生成する（スナップショット比較用）。
// 実行: make render-all → gallery/main.png
//       make render SHOT=main → debug/main.png（1 枚だけ）
mod SceneRender {
    use fge::{
        App, Color, FontAtlas, GameEngine, HeadlessFont, HeadlessRender, PxSprite, PxSpriteAtlas,
        PxSpriteDoc, Render, Vec2
    }

    import java.io.File

    def design(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    def ttf(): String = "assets/ShipporiMincho-Regular.subset.ttf"

    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        // なめらかな絵なので面の縁もならす（ならさないと岩の塊の輪郭が階段になる）。
        { design = design(), scale = 2, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = outDir, frameW = 1280, frameH = 720,
          shapeAntialias = true | HeadlessRender.defaults() }

    /// 生成するときの時刻（秒）から始めた、題名の画面の World。実時間でなく固定値を使う —
    /// 水の流れも泡の位置もこの t だけで決まるので、何度生成しても同じ PNG が出る（スナップショットのバイト比較が成り立つ）。
    def loadWorld(): World.World = World.tick(3.0, World.initial())

    /// 手の列（U D L R W）を 1 手ずつ World に流し、各手の動きを終わらせる。
    def played(res: Res.Res, moves: String, w: World.World): World.World =
        World.movesOf(moves) |> Option.getWithDefault(Nil)
            |> List.foldLeft((acc, move) -> World.tick(0.5, World.play(res, move, acc)), w)

    /// 面 index（0 から）を Doc の解き方の先頭 n 手まで遊んだ後。
    def partway(res: Res.Res, index: Int32, n: Int32, w: World.World): World.World =
        let solution = LevelsDoc.rec(res#levels)#levels |> List.drop(index) |> List.head
            |> Option.map(level -> String.takeLeft(n, level#solution)) |> Option.getWithDefault("");
        played(res, solution, World.enterLevel(res, index, w))

    /// 面 1 から面 count まで、解き方で解いて決定で次へ進んだ後。
    def solvedUpTo(res: Res.Res, count: Int32, w: World.World): World.World =
        List.range(0, count) |> List.foldLeft((acc, i) -> World.advance(res, partway(res, i, 99, acc)), w)

    // ── 決定的な場面（スナップショット） ──

    pub def all(): Unit \ IO = App.Headless.exitWith(allJob(App.Headless.requestFromProcess()))

    /// SceneRender.all の中身（常駐の /run からも呼ぶ）。戻り値は終了コード。
    def allJob(_req: App.Headless.Request): Int32 \ IO =
        discard allShots();
        0

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("SceneRender", "one", req -> oneJob(req)) ::
        App.Headless.job("SceneRender", "all", req -> allJob(req)) :: Nil

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面の題と一言（Studio のギャラリーに出るラベル）は assets/*.scenes.json 側で、
    /// name をここの名前とそろえる。ラベルを足しても描き出す場面は増えない。
    /// 場面を足したら、ここと sceneOf と Makefile の SHOTS を一緒に足す。
    def shotNames(): List[String] =
        "title" :: "play" :: "flood" :: "dam" :: "clear" :: "washed" :: "ending" :: "quit" :: Nil

    /// 名前 → その場面の World。shotNames と対で保つ。名前で引く形にしてあるので、
    /// SHOT で 1 枚だけ生成するときに残りの場面は組まない。
    def sceneOf(name: String, res: Res.Res, w0: World.World): Option[World.World] =
        let settled = w -> World.tick(2.0, w);
        match name {
            // 面 1〜4 を解いた後に題名へ戻り、面 5 を選んでいる。
            case "title"  => Some(World.backToTitle(solvedUpTo(res, 4, w0)))
            // 面 5 の途中の上げ潮。破線が次の手の水際。
            case "play"   => Some(partway(res, 4, 7, w0))
            // 同じ盤の満ち潮。
            case "flood"  => Some(partway(res, 4, 9, w0))
            // 小石でせき止めた池が、引き潮でも外の潮より高い水を残している。
            case "dam"    => Some(partway(res, 4, 12, w0))
            case "clear"  => Some(settled(partway(res, 0, 99, w0)))
            // 面 1 で満ち潮の低い岩へ下りて流された。
            case "washed" => Some(settled(played(res, "RRD", World.enterLevel(res, 0, w0))))
            case "ending" => Some(settled(solvedUpTo(res, 6, w0)))
            case "quit"   => Some(World.askQuit(partway(res, 4, 7, w0)))   // Esc・閉じるボタンで出る終了の確認（Layer.Prompt）
            case _        => None
        }

    /// SceneRender.all の中身。生成した PNG のパス列を返す — 走行中のゲームへの POST /render
    /// （Main の App.onRenderRequest）もこれを呼ぶ。プレイ状態には触れず Docs から組み立てる。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ生成する（スナップショットを汚さない）。
    /// 実行: make render SHOT=main
    pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))

    /// SceneRender.one の中身（常駐の /run からも呼ぶ）。env は要求の表（App.Headless.envOf）だけを読む。
    def oneJob(req: App.Headless.Request): Int32 \ IO =
        let wanted = Map.getWithDefault("SHOT", "", App.Headless.envOf(req)) |> String.splitOn(substr = " ")
            |> List.map(String.trim) |> List.filter(n -> not String.isEmpty(n));
        let known = List.toSet(shotNames());
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            println("[render] 描けない名前です: ${List.join(" ", unknown)}");
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", shotNames())}");
            1
        } else {
            let picked = List.toSet(wanted);
            discard shotsInto("debug", n -> Set.memberOf(n, picked));
            0
        }

    /// keep が真を返す場面だけを outDir へ生成し、そのファイルパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let res = Res.build(run { Controls.loadDocs() } with Fs.FileRead.runWithIO);
        let w0 = loadWorld();
        let (cfg, texInfo) = withAtlasOf(cfgOf(outDir, atlas, ThemeDoc.rec(res#theme)#bg), res);
        let ctx = App.viewCtxOf(atlas, design());
        shotNames() |> List.filter(keep) |> List.filterMap(name ->
            sceneOf(name, res, w0) |> Option.map(w -> shoot(cfg, texInfo, ctx, res, w, name)))

    /// 実機が GPU へ上げるのと同じアトラスの画素を PNG に落とし、「そこから貼れる cfg」と
    /// texInfo を返す（描き出しは PNG からしか絵を読めない）。View が drawQuad で貼るので、
    /// これを通さないとドット絵が仮色の板になる。
    /// 置き場所は生成先でなく debug/ に固定する — gallery/ に混ぜると、絵の顔ぶれを
    /// 突き合わせる reference-check が「増えた絵」として落とす。
    def withAtlasOf(cfg: HeadlessRender.RenderConfig, res: Res.Res):
            (HeadlessRender.RenderConfig, String -> Option[GameEngine.TextureInfo]) \ IO =
        let images = PxSpriteAtlas.asImages(
            { texture = Res.atlasName(), baked = res#atlas } :: Nil);
        ({ texturePath = HeadlessRender.imagePngs("debug", images) | cfg },
         HeadlessRender.imageTextureInfo(images))

    /// 1 場面を PNG に生成し、生成したファイルパスを返す。
    /// 宣言シェーダーの面は draw に渡さず（渡すと代表色のベタ塗りになる）、
    /// surfaces として別に取り出して画素ごとに評価させる。
    /// アトラスから貼るクアッドがあるので、素の Render.draw ではなく texInfo つきの
    /// drawWith を通す。
    def shoot(cfg: HeadlessRender.RenderConfig, texInfo: String -> Option[GameEngine.TextureInfo],
              ctx: App.ViewCtx, res: Res.Res, w: World.World, name: String): String \ IO =
        // 実機は静的な層（View.frameBorder）を別に敷くので、描き出しでは同じ物を足して並べる。
        let items = List.append(View.frame(ctx, res, w), View.frameBorder(res#theme));
        let surfaces = Render.shaderSurfaces(items);
        let (drawables, polygons) = Render.drawWith(texInfo, Render.withoutShaders(items));
        HeadlessRender.renderPngWith(cfg, drawables, polygons, surfaces, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
