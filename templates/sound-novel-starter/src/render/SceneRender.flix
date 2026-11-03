// SceneRender — ゲーム画面を画面なしで PNG に描き出す（スナップショット比較用）。
// 実行: make render-all → gallery/*.png と gallery/<場面>.json（場面と World は Shots）
//       make render SHOT=nvl → debug/nvl.png（1 枚だけ）
// 背景のぼかしは宣言シェーダーの面なので、draw には渡さず ShaderEval が画素ごとに塗る（Render.shaderSurfaces）。
// 写真は project.json の textures をそのまま読む（実機と同じ名前 → 同じファイル）。
mod SceneRender {
    use fge::{App, DocJson, HeadlessFont, HeadlessRender, JsonCodec, Render, Vec2}

    import java.io.File
    import java.lang.ProcessHandle

    pub def design(): Vec2.Vec2 = { x = Layout.width(), y = Layout.height() }

    def ttf(): String = "assets/ShipporiMincho-Regular.subset.ttf"

    /// 字の縁も面の縁もならす（写真と明朝の画面。格子に乗せる絵は無い）。
    pub def cfgOf(outDir: String, textures: Map[String, String]): HeadlessRender.RenderConfig \ IO =
        { design = design(), scale = 1, background = Backdrop.groundColor(),
          fontTtf = ttf(), fontAtlas = HeadlessFont.buildUiAtlas(ttf(), ttf()), texturePath = textures,
          outDir = outDir, frameW = 960, frameH = 540 | HeadlessRender.defaults() }

    /// project.json の textures（名前 → パス）。読めなければ空（背景は代表色ではなく黒になる）。
    pub def texturesOf(): Map[String, String] \ IO =
        let rows = run { DocJson.readJson("project.json") } with Fs.FileRead.runWithIO;
        rows |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
             |> Option.flatMap(root -> Map.get("textures", root))
             |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(obj ->
                    (JsonCodec.stringOr("name", "", obj), JsonCodec.stringOr("path", "", obj)))))
             |> Option.getWithDefault(Nil) |> List.toMap

    def loadRes(): Res.Res \ IO = run { Controls.loadRes() } with Fs.FileRead.runWithIO

    pub def all(): Unit \ IO = App.Headless.exitWith(allJob(App.Headless.requestFromProcess()))

    pub def allJob(_req: App.Headless.Request): Int32 \ IO =
        discard allShots();
        0

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。E2e.serveHeadless が束ねる。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("SceneRender", "one", req -> oneJob(req)) ::
        App.Headless.job("SceneRender", "all", req -> allJob(req)) :: Nil


    pub def allShots(): List[String] \ IO = shotsInto("gallery", _ -> true)

    /// 渡した World を 1 枚描いて、そのパスを返す（App.onShotRequest。Studio の会話のプレビュー・bin/fge talk shot）。
    pub def shotOf(res: Res.Res, w: World.World): String \ IO =
        discard (new File("debug/shot")).mkdirs();
        let cfg = cfgOf("debug/shot", texturesOf());
        shoot(res, cfg, w, "shot-${ProcessHandle.current().pid()}")

    pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))

    pub def oneJob(req: App.Headless.Request): Int32 \ IO =
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

    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let cfg = cfgOf(outDir, texturesOf());
        let res = loadRes();
        Shots.names() |> List.filter(keep) |> List.filterMap(name ->
            Shots.worldOf(name, res) |> Option.map(w -> {
                let path = shoot(res, cfg, w, name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(res, w)));
                path
            }))

    /// 1 場面を PNG に描き出し、そのファイルパスを返す。hud の合流は実機と同じ App.composeScene を通し、
    /// 背景の面は surfaces として別に取り出して画素ごとに評価させる（draw に渡すと代表色のベタ塗りになる）。
    def shoot(res: Res.Res, cfg: HeadlessRender.RenderConfig, w: World.World, name: String): String \ IO =
        let ctx = App.viewCtxOf(cfg#fontAtlas, design());
        let items = App.composeScene(None, 1.0, cfg#design, { world = View.frame(ctx, res, w), hud = View.hud(ctx, res, w) });
        let (drawables, polygons) = Render.draw(Render.withoutShaders(items));
        HeadlessRender.renderPngWith(cfg, drawables, polygons, Render.shaderSurfaces(items), name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
