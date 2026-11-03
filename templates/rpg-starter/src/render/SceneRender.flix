// SceneRender — 場面を画面なしで PNG に描き出す。
// 実行: make render-all → gallery/<場面>.png
//       make render SHOT=village → debug/village.png（1 枚だけ）
mod SceneRender {
    use fge::{App, CameraRig, Color, FontAtlas, HeadlessFont, HeadlessRender, PxSpriteAtlas, Render, TileScene, Vec2}

    import java.io.File

    def design(): Vec2.Vec2 = WindowView.design()

    /// 字のフォント（project.json の font と同じファイル）。
    pub def ttf(): String = "assets/PixelMplus10-Regular.ttf"

    /// 描き出しの設定。ドット絵なので面の縁も字の縁もならさない
    /// （WhyNot: 字をならすと PixelMplus の点が 3 倍の拡大でにじみ、色票の外の中間色が湧く）。
    def cfgOf(outDir: String, atlas: FontAtlas, bg: Color): HeadlessRender.RenderConfig =
        { design = design(), scale = 3, background = bg,
          fontTtf = ttf(), fontAtlas = atlas,
          outDir = outDir, frameW = 768, frameH = 720,
          shapeAntialias = false, textAntialias = false | HeadlessRender.defaults() }

    // ── 入口 ──

    pub def all(): Unit \ IO = App.Headless.exitWith(allJob(App.Headless.requestFromProcess()))

    /// SceneRender.all の中身（常駐の /run からも呼ぶ）。戻り値は終了コード。
    def allJob(_req: App.Headless.Request): Int32 \ IO =
        discard allShots();
        0

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("SceneRender", "one", req -> oneJob(req)) ::
        App.Headless.job("SceneRender", "all", req -> allJob(req)) :: Nil

    /// 実機と同じ絵: タイル層・world（カメラを掛ける）・HUD（動画の VideoRender も同じ物で描く）。
    pub def worldItems(ctx: App.ViewCtx, res: Res.Res, w: World.World): List[Render.PlacedItem] =
        let center = CameraRig.clampCenter(bounds = View.boundsOf(res, w), seen = design(), View.cameraOf(res, w));
        let seen = { visible = CameraRig.visibleRect(center, zoom = 1.0, design = design()) | ctx };
        let tiles = View.tileLayers(res, w) |> List.flatMap(TileScene.toItems);
        App.composeScene(Some(center), 1.0, design(),
            { world = List.append(tiles, View.frame(seen, res, w)), hud = View.hud(seen, res, w) })

    /// 全部の場面を gallery/ へ。描いた PNG のパス列を返す。
    pub def allShots(): List[String] \ IO =
        shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ描き出す。
    pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))

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

    /// keep が真を返す場面だけを outDir へ描き出し、そのパス列を返す。
    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let res = run { Res.load() } with Fs.FileRead.runWithIO;
        let ctx = App.viewCtxOf(atlas, design());
        let images = PxSpriteAtlas.asImages(Res.atlases(res));
        // WhyNot: アトラスの PNG を gallery/ に置かない — 描いた場面の顔ぶれに混ざり、reference-check が「増えた絵」と読む。
        let cfg = { texturePath = HeadlessRender.imagePngs("debug", images)
                    | cfgOf(outDir, atlas, Palette.resolve(res#palette, "ink")) };
        let texInfo = HeadlessRender.imageTextureInfo(images);
        Shots.names() |> List.filter(keep) |> List.filterMap(name ->
            Shots.worldOf(name, res) |> Option.map(w -> {
                let (drawables, polygons) = Render.drawWith(texInfo, worldItems(ctx, res, w));
                HeadlessRender.renderPng(cfg, drawables, polygons, name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(w)));
                let path = "${outDir}/${name}.png";
                println("rendered: ${path}");
                path
            }))
}
