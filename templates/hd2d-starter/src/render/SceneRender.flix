// SceneRender — ゲーム画面を画面なしで CPU（SoftRaster）の PNG に生成する（スナップショット比較用）。
// 実行: make render-all → gallery/<場面>.png
//       make render SHOT=title → debug/title.png（1 枚だけ）
// 描くのは実機と同じ View.frame（3D の場面）に View.postOf（ポストプロセス）を掛け、View.hud（終了の確認の窓）を重ねた物。
mod SceneRender {
    use fge::{App, Color, HeadlessFont, HeadlessRender, PostStack, Render}

    import java.io.File

    def ttf(): String = "assets/PixelMplus10-Regular.ttf"

    /// 描き出しの描き方の重さ（影の地図を 2048 に落とす。つまみは実機の SHADOW_MAP と同じ口）。
    // WhyNot: 実機と同じ 4096 で描かない — CPU の描き出しは影の地図の画素の数に比例して重く、4 枚で 1 分を超える。
    def knobs(): Knobs.Knobs = Map#{ "shadow" => "2048" }

    def loadRes(): Res.Res \ IO =
        Res.loadOrBugIo(knobs())

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
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let res = loadRes();
        let cfg = { design = View.size(), scale = 1, background = Color.rgb(0.0, 0.0, 0.0), fontTtf = ttf(), fontAtlas = atlas,
                    outDir = outDir, frameW = Float64.round(View.size()#x) |> Float64.tryToInt32 |> Option.getWithDefault(1280),
                    frameH = Float64.round(View.size()#y) |> Float64.tryToInt32 |> Option.getWithDefault(720) | HeadlessRender.defaults() };
        let ctx = App.viewCtxOf(atlas, View.size());
        Shots.names() |> List.filter(keep) |> List.filterMap(name ->
            Shots.worldOf(name, res) |> Option.map(w -> {
                HeadlessRender.renderPngFull(cfg, sceneOf(ctx, res, w), name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(res, w)));
                let path = "${outDir}/${name}.png";
                println("rendered: ${path}");
                path
            }))

    /// 1 枚の中身: View.frame にポストプロセス（explore.json の post が偽なら掛けない）を掛け、View.hud を重ねる。
    def sceneOf(ctx: App.ViewCtx, res: Res.Res, w: World.World): HeadlessRender.Scene =
        let world = View.frame(ctx, res, w);
        let hud = View.hud(ctx, res, w);
        if (res#quality#post) {
            let built = PostStack.build({ size = View.size(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, View.postOf(res, w));
            let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
                |> List.map(s -> { name = s#name, clear = s#clear, drawables = s#drawables, polygons = s#polygons, surfaces = s#surfaces, scenes = s#scenes, target = s#target });
            let soft = Render.softSceneOf(_ -> None, built#present :: hud);
            { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
              scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }
        } else {
            let soft = Render.softSceneOf(_ -> None, List.append(world, hud));
            { passes = Nil, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
              scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }
        }
}
