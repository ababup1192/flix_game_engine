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
        let known = List.toSet(Shots.names());
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            println("[render] 描けない名前です: ${List.join(" ", unknown)}");
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", Shots.names())}");
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
        let (cfg, texInfo) = withAtlasOf(cfgOf(outDir, atlas, ThemeDoc.rec(res#theme)#bg), res);
        let ctx = App.viewCtxOf(atlas, design());
        Shots.names() |> List.filter(keep) |> List.filterMap(name ->
            Shots.worldOf(name, res) |> Option.map(w -> shoot(cfg, texInfo, ctx, res, w, name)))

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
        App.Headless.writeShotRecord(cfg#outDir, name, Some(E2e.fingerprint(res, w)));
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
