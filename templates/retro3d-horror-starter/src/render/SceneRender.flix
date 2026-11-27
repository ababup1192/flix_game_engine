// SceneRender — ゲーム画面を画面なしで CPU（SoftRaster）の PNG に生成する（スナップショット比較用）。
// 実行: make render-all → gallery/<場面>.png
//       make render SHOT=corridor → debug/corridor.png（1 枚だけ）
// 描くのは実機と同じ View.frame（3D の場面・320×240）に View.hud（部屋の名前・紙のマップ・終了の確認の窓）を重ねた物。
// マップの絵は project.json の textures と同じ物を MapView.textures のパスで読む。
mod SceneRender {
    use fge::{App, Color, DocJson, HeadlessFont, HeadlessLoad, HeadlessRender, JsonCodec, PostStack, Render, Scene3d, Vec2, Vec3}

    import java.io.File

    /// 字のフォント（project.json の fonts の default の path）。フォントを替える所は project.json の 1 か所だけにする。
    /// 読めない時は Kaisei Tokumin（今の既定）。
    pub def ttf(): String \ IO = run { fontPathOr("assets/fonts/KaiseiTokumin-Regular.ttf") } with Fs.FileRead.runWithIO

    def fontPathOr(fallback: String): String \ Fs.FileRead =
        DocJson.readJson("project.json") |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(root -> Map.get("fonts", root)) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectObject))
            |> Option.flatMap(fonts -> fonts |> List.find(f -> JsonCodec.stringOr("name", "", f) == "default"))
            |> Option.map(f -> JsonCodec.stringOr("path", fallback, f)) |> Option.getWithDefault(fallback)

    def design(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    /// 描く元（実機の起動と同じ Controls.loadDocs から組む。絵は javax.imageio で解く）。
    def loadRes(): Res.Res \ IO =
        Res.build(run { HeadlessLoad.handle(Controls.loadDocs) } with Fs.FileRead.runWithIO)

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

    /// 全部の場面を gallery/ へ生成し、PNG のパス列を返す — 走行中のゲームへの POST /render（Main の App.onRenderRequest）もこれを呼ぶ。
    pub def allShots(): List[String] \ IO = shotsInto("gallery", _ -> true)

    /// SHOT で指した場面だけを debug/ へ生成する（スナップショットを汚さない）。
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
        let font = ttf();
        let atlas = HeadlessFont.buildUiAtlas(font, font);
        let res = loadRes();
        // 窓と同じ 2 倍（640×480）で描く: 3D は 320×240 のまま補間なしで拡げ、字（HUD）は 2 倍の画素でなめらかに描く。
        let cfg = { design = design(), scale = 2, background = Color.rgb(0.0, 0.0, 0.0), fontTtf = font, fontAtlas = atlas,
                    outDir = outDir, frameW = 640, frameH = 480,
                    texturePath = MapView.textures() |> List.map(e -> { let (n, path, _, _) = e; (n, path) }) |> List.toMap | HeadlessRender.defaults() };
        let ctx = App.viewCtxOf(atlas, design());
        Shots.names() |> List.filter(keep) |> List.filterMap(name ->
            Shots.worldOf(name, res) |> Option.map(w -> {
                HeadlessRender.renderPngFull(cfg, sceneOf(ctx, res, w), name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(res, w)));
                let path = "${outDir}/${name}.png";
                println("rendered: ${path}");
                path
            }))

    /// ブラウザ版のシェーダーの記録（web/shader-variants.json）が覆うべき 3D の場面: 全部の場面と、各階の全部の部屋の真ん中に立った時の、
    /// 描き出しと同じ道で組んだ面と Pass の中の 3D の場面（test/TestShaderVariants が読む）。
    pub def shaderScenes(): List[Scene3d.Scene3dCmd] \ IO =
        let font = ttf();
        let res = loadRes();
        let ctx = App.viewCtxOf(HeadlessFont.buildUiAtlas(font, font), design());
        let w0 = World.initial(res);
        let shots = Shots.names() |> List.filterMap(name -> Shots.worldOf(name, res));
        let floors = res#layout#floors |> List.flatMap(f -> f#rooms |> List.map(r ->
            World.placeAt(res, Vec3.v3((r#min#x + r#max#x) / 2.0, f#y, (r#min#y + r#max#y) / 2.0), 0.0, w0)));
        (shots ::: floors) |> List.flatMap(w -> {
            let s = sceneOf(ctx, res, w);
            (s#scenes ::: List.flatMap(p -> p#scenes, s#passes)) |> List.map(cmd -> cmd#scene)
        })

    /// 1 枚の中身: View.frame（テレビのにじみがあれば PostStack を通した面）に View.hud を重ねる（実機の App.withPostStack と同じ）。
    def sceneOf(ctx: App.ViewCtx, res: Res.Res, w: World.World): HeadlessRender.Scene =
        let (passes, frame) = match Game.crtStackOf(res) {
            case None    => (Nil, View.frame(ctx, res, w))
            case Some(s) =>
                let built = PostStack.build({ size = design(), clear = Color.rgb(0.0, 0.0, 0.0), world = View.frame(ctx, res, w) }, s);
                let specs = Render.passSpecsOf(MapView.textureInfoOf, built#plan)#specs
                    |> List.map(p -> { name = p#name, clear = p#clear, drawables = p#drawables, polygons = p#polygons, surfaces = p#surfaces, scenes = p#scenes, target = p#target });
                (specs, built#present :: Nil)
        };
        let soft = Render.softSceneOf(MapView.textureInfoOf, List.append(frame, View.hud(ctx, res, w)));
        { passes = passes, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
          scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }
}
