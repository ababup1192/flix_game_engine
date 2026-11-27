// SceneRender — ゲーム画面を画面なしで CPU（SoftRaster）の PNG に生成する（スナップショット比較用）。
// 実行: make render-all → gallery/<場面>.png
//       make render SHOT=title → debug/title.png（1 枚だけ）
// 描くのは実機と同じ View.frame（3D の場面）に View.postOf（ポストプロセス）を掛け、View.hud（終了の確認の窓）を重ねた物。
mod SceneRender {
    use fge::{App, Color, Filmstrip, HeadlessFont, HeadlessRender, PostStack, Render, Scene3d}

    import java.awt.image.BufferedImage
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
                writeShot(cfg, sceneOf(ctx, res, w), name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(res, w)));
                let path = "${outDir}/${name}.png";
                println("rendered: ${path}");
                path
            }))

    /// Studio のジャンルカードの顔（reference/title.png・git に入る 1 枚）の大きさ。ほかの場面は View.size() のまま。
    // WhyNot: title も 1280×720 のまま入れない — 石畳と木の細かい絵は PNG で縮まず 1.9 MB になり、git に入れる絵の上限
    // （bin/fge images の 8 MB）を 1 枚で食う。カードは幅数百 px で見るので 960×540 で粗くならない。
    def titleSize(): (Int32, Int32) = (960, 540)

    /// 1 枚を outDir/<name>.png へ書く。title だけ View.size() で描いてから titleSize() へ面積の平均で縮める。
    def writeShot(cfg: HeadlessRender.RenderConfig, scene: HeadlessRender.Scene, name: String): Unit \ IO =
        if (name == "title") {
            let (w, h) = titleSize();
            Filmstrip.renderFrame(shrinkByArea(HeadlessRender.renderImageFull(cfg, scene), w, h), "${cfg#outDir}/${name}.png")
        } else HeadlessRender.renderPngFull(cfg, scene, name)

    /// img を w × h へ縮める。先の 1 画素は元の画像の重なる範囲の画素を、重なる面積で重みを付けて平均した色（ARGB の 4 つとも）。
    def shrinkByArea(img: BufferedImage, w: Int32, h: Int32): BufferedImage \ IO = region rc {
        let sw = img.getWidth();
        let sh = img.getHeight();
        let src: Array[Int32, rc] = Array.empty(rc, sw * sh);
        discard img.getRGB(0i32, 0i32, sw, sh, src, 0i32, sw);
        let cols = Vector.range(0, w) |> Vector.map(o -> coverageOf(o, w, sw));
        let rows = Vector.range(0, h) |> Vector.map(o -> coverageOf(o, h, sh));
        let area = Int32.toFloat64(sw) / Int32.toFloat64(w) * Int32.toFloat64(sh) / Int32.toFloat64(h);
        let out: Array[Int32, rc] = Array.empty(rc, w * h);
        List.range(0, h) |> List.forEach(y -> {
            let row = Vector.get(y, rows);
            List.range(0, w) |> List.forEach(x -> {
                let samples = row |> List.flatMap(ry -> Vector.get(x, cols) |> List.map(cx ->
                    (Array.get(fst(ry) * sw + fst(cx), src), snd(ry) * snd(cx))));
                Array.put(averageArgb(samples, area), y * w + x, out)
            })
        });
        let dest = new BufferedImage(w, h, 2i32);
        dest.setRGB(0i32, 0i32, w, h, out, 0i32, w);
        dest
    }

    /// 先の o 番目（全部で n）が重なる元の画素（全部で srcN）と、重なる長さ。
    def coverageOf(o: Int32, n: Int32, srcN: Int32): List[(Int32, Float64)] =
        let scale = Int32.toFloat64(srcN) / Int32.toFloat64(n);
        let lo = Int32.toFloat64(o) * scale;
        let hi = lo + scale;
        let first = Float64.floor(lo) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let last = Int32.min(srcN - 1, (Float64.ceil(hi) |> Float64.tryToInt32 |> Option.getWithDefault(srcN)) - 1);
        List.range(first, last + 1) |> List.map(i -> (i, Float64.min(hi, Int32.toFloat64(i + 1)) - Float64.max(lo, Int32.toFloat64(i))))
            |> List.filter(p -> snd(p) > 0.0)

    /// (ARGB, 重み) の列の重み付きの平均を area で割った ARGB。
    def averageArgb(samples: List[(Int32, Float64)], area: Float64): Int32 =
        List.foldLeft((acc, shift) -> {
            let sum = samples |> List.foldLeft((s, p) -> s + Int32.toFloat64(Int32.bitwiseAnd(Int32.logicalRightShift(dist = shift, fst(p)), 255)) * snd(p), 0.0);
            let channel = Int32.max(0, Int32.min(255, Float64.round(sum / area) |> Float64.tryToInt32 |> Option.getWithDefault(0)));
            Int32.bitwiseOr(acc, Int32.leftShift(channel, shift))
        }, 0, 24 :: 16 :: 8 :: 0 :: Nil)

    /// ブラウザ版のシェーダーの記録（web/shader-variants.json）が覆うべき 3D の場面: 全部の場面の、描き出しと同じ道で組んだ面と Pass の中の 3D の場面
    /// （test/TestShaderVariants が読む）。
    pub def shaderScenes(): List[Scene3d.Scene3dCmd] \ IO =
        let res = loadRes();
        let ctx = App.viewCtxOf(HeadlessFont.buildUiAtlas(ttf(), ttf()), View.size());
        Shots.names() |> List.filterMap(name -> Shots.worldOf(name, res)) |> List.flatMap(w -> {
            let s = sceneOf(ctx, res, w);
            (s#scenes ::: List.flatMap(p -> p#scenes, s#passes)) |> List.map(cmd -> cmd#scene)
        })

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
