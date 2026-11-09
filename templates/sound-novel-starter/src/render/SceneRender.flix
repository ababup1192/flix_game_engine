// SceneRender — ゲーム画面を画面なしで PNG に描き出す（スナップショット比較用）。
// 実行: make render-all → gallery/*.png と gallery/<場面>.json（場面と World は Shots）
//       make render SHOT=nvl → debug/nvl.png（1 枚だけ）。small-<場面> は同じ場面を小さい画面（スマホ）の並べ方で描く。
//       portrait-<場面> は縦に持ったスマホ（390×844 → 縦の design 540×1169）、portrait-short-<場面> は太い縦の画面（360×640 → 540×960）で描く
// 背景のぼかしは宣言シェーダーの面なので、draw には渡さず ShaderEval が画素ごとに塗る（Render.shaderSurfaces）。
// 写真は project.json の textures をそのまま読む（実機と同じ名前 → 同じファイル）。
mod SceneRender {
    use fge::{App, DocJson, Display, HeadlessFont, HeadlessRender, JsonCodec, ProjectLoader, Render, Vec2}

    import java.io.File
    import java.lang.ProcessHandle

    pub def design(): Vec2.Vec2 = Layout.size(Layout.Fit.Regular)

    /// 描き出す画面の形: 横（区分 Large か Small）か、画面の大きさ view の縦のスマホ。
    enum Look {
        case Landscape(Display.SizeClass)
        case Portrait(Vec2.Vec2)
    }

    /// 縦の画面の design（project.json の web.portraitDesign と画面の大きさ view から。実機のブラウザと同じ決め方）。
    /// 縦の指定が読めなければ 540×960。
    def portraitDesignOf(view: Vec2.Vec2): Vec2.Vec2 \ IO =
        let loaded = run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO;
        loaded |> Result.toOption |> Option.flatMap(proj -> ProjectLoader.portraitConfigOf(proj, view))
               |> Option.map(c -> { x = Int32.toFloat64(c#designWidth), y = Int32.toFloat64(c#designHeight) })
               |> Option.getWithDefault({ x = 540.0, y = 960.0 })

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
        let known = List.toSet(allNames());
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            println("[render] 描けない名前です: ${List.join(" ", unknown)}");
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", allNames())}");
            1
        } else {
            let picked = List.toSet(wanted);
            discard shotsInto("debug", n -> Set.memberOf(n, picked));
            0
        }

    /// 小さい画面（スマホ）の並べ方で描く場面: (描き出しの名前, Shots の場面の名前)。World は同じ場面の物をそのまま使う。
    /// WhyNot: Shots.names に入れない — Shots.names は実機の START=shot: の口でもあり、デスクトップ版の実機はいつも Large で描く。
    def smallShots(): List[(String, String)] =
        ("small-title", "title") :: ("small-nvl", "nvl") :: ("small-adv", "adv") :: ("small-choice", "choice")
            :: ("small-save", "save") :: ("small-settings", "settings") :: ("small-ask", "ask") :: Nil

    /// 描く元を替えて描く横の場面: (描き出しの名前, Shots の場面の名前)。どう替えるかは resFor。
    /// WhyNot: Shots.names に入れない — 実機の START=shot: は World だけを替える口で、Doc（描く元）は替えられない。
    def variantShots(): List[(String, String)] =
        ("hold-ring", "hold") :: ("hold-none", "hold") :: ("cast-sample", "cast") :: Nil

    /// 描き出しの名前 → その場面で使う描く元。hold-ring / hold-none = 待ちの印を輪 / 無しにした描く元、
    /// cast-sample = テスト用の立ち絵の人物を足した描く元（CastDoc.sample）、portrait-cast-veil = それに縦の頁の覆いを人物が出ている間だけ薄くする倍率を入れた描く元。ほかはそのまま。
    def resFor(name: String, res: Res.Res): Res.Res = match name {
        case "cast-sample"          => Res.withCast(CastDoc.sample(), res)
        case "portrait-cast-sample" => Res.withCast(CastDoc.sample(), res)
        case "portrait-cast-veil"   => Res.withCast(CastDoc.Doc.Doc({ portraitVeilWithCast = 0.5 | CastDoc.rec(CastDoc.sample()) }), res)
        case "hold-ring"          => withWaitMark(ThemeDoc.WaitMark.Ring, res)
        case "portrait-hold-ring" => withWaitMark(ThemeDoc.WaitMark.Ring, res)
        case "hold-none"          => withWaitMark(ThemeDoc.WaitMark.Off, res)
        case _                    => res
    }

    def withWaitMark(mark: ThemeDoc.WaitMark, res: Res.Res): Res.Res =
        Res.withTheme(ThemeDoc.Doc.Doc({ waitMark = mark | ThemeDoc.rec(res#theme) }), res)

    /// 縦の画面で描く場面: (描き出しの名前, 場面の名前, 画面の大きさ)。World は Shots の同じ場面の物をそのまま使う（menu・saveload・tooltip だけは worldOf）。
    /// 太い縦の画面（360×640）は縦の design の下限の高さで、並べ方がいちばん窮屈になる所を見る。
    def portraitShots(): List[(String, String, Vec2.Vec2)] =
        let tall = Display.defaultPortraitView();
        let short = { x = 360.0, y = 640.0 };
        ("portrait-title", "title", tall) :: ("portrait-nvl", "nvl", tall) :: ("portrait-adv", "adv", tall)
            :: ("portrait-choice", "choice", tall) :: ("portrait-log", "log", tall) :: ("portrait-save", "save", tall)
            :: ("portrait-settings", "settings", tall) :: ("portrait-ask", "ask", tall)
            :: ("portrait-lane", "lane", tall) :: ("portrait-menu", "menu", tall)
            :: ("portrait-saveload", "saveload", tall) :: ("portrait-tooltip", "tooltip", tall)
            :: ("portrait-hold-ring", "hold", tall) :: ("portrait-cast-sample", "cast", tall) :: ("portrait-cast-veil", "cast", tall)
            :: ("portrait-short-nvl", "nvl", short) :: ("portrait-short-save", "save", short)
            :: ("portrait-short-settings", "settings", short) :: Nil

    /// 場面の名前 → World。縦の画面だけの場面（どれも ADV の台詞の上）: menu = オートを点けて右上の … のメニューを開いた所、
    /// saveload = しおりから [セーブ｜ロード] の選びを開いた所、tooltip = 指の長押しで右の列のログの名前を出した所、
    /// cast = テスト用の立ち絵の人物を出した所（横と縦の両方で描く）。
    // WhyNot: 縦の画面だけの場面を Shots.names に入れない — 右の列と … は縦の画面にしか無く、Shots.names は横の描き出しと実機の START=shot: の口でもある。
    def worldOf(scene: String, res: Res.Res): Option[World.World] = match scene {
        case "menu"     =>
            Shots.worldOf("adv", res) |> Option.map(w ->
                World.mapRead(r -> { playback = World.Playback.Auto | r }, { panel = World.Panel.Menu(0) | w }))
        case "saveload" => Shots.worldOf("adv", res) |> Option.map(w -> { panel = World.Panel.SaveLoadPick(0) | w })
        case "tooltip"  => Shots.worldOf("adv", res) |> Option.map(w -> World.mapRead(r -> { tip = Some((logIndex(), w#realNow)) | r }, w))
        case "cast"     => Shots.worldOf("adv", res) |> Option.map(World.mapRead(r -> { stage = { cast = sampleLayer() | r#stage } | r }))
        case _          => Shots.worldOf(scene, res)
    }

    /// テスト用の立ち絵の人物を、既定の位置と表情で出し終えた層。
    def sampleLayer(): Cast.Layer =
        let entry = CastDoc.entryOf(CastDoc.Lane.Character, CastDoc.sampleName(), CastDoc.sample());
        let figures = entry |> Option.map(e -> { name = CastDoc.sampleName(), face = e#face, slot = e#slot }) |> Option.toList;
        Cast.layerOf({ cast = figures, prop = None })

    /// 縦の画面の右の列のログの番号。
    def logIndex(): Int32 =
        WorldMenu.buttonsOf(Layout.Fit.Portrait(PortraitDoc.rec(PortraitDoc.defaults()), Display.defaultPortraitView()))
            |> List.zipWithIndex |> List.find(match (_, b) -> b == World.Button.Log) |> Option.map(fst) |> Option.getWithDefault(0)

    /// 描き出せる名前の全部（Shots の場面と、小さい画面と縦の画面の場面）。
    def allNames(): List[String] =
        List.flatten(Shots.names() :: (variantShots() |> List.map(fst)) :: (smallShots() |> List.map(fst))
                     :: (portraitShots() |> List.map(match (name, _, _) -> name)) :: Nil)

    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let cfg = cfgOf(outDir, texturesOf());
        let loaded = loadRes();
        let regular = Shots.names() |> List.map(name -> (name, name, Look.Landscape(Display.SizeClass.Large)));
        let variant = variantShots() |> List.map(match (name, scene) -> (name, scene, Look.Landscape(Display.SizeClass.Large)));
        let small = smallShots() |> List.map(match (name, scene) -> (name, scene, Look.Landscape(Display.SizeClass.Small)));
        let portrait = portraitShots() |> List.map(match (name, scene, view) -> (name, scene, Look.Portrait(view)));
        List.flatten(regular :: variant :: small :: portrait :: Nil) |> List.filter(match (name, _, _) -> keep(name)) |> List.filterMap(match (name, scene, look) ->
            let res = resFor(name, loaded);
            worldOf(scene, res) |> Option.map(w -> {
                let path = shootAs(look, res, cfg, w, name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(res, w)));
                path
            }))

    def shoot(res: Res.Res, cfg: HeadlessRender.RenderConfig, w: World.World, name: String): String \ IO =
        shootAs(Look.Landscape(Display.SizeClass.Large), res, cfg, w, name)

    /// 1 場面を look の画面として PNG に描き出し、そのファイルパスを返す。hud の合流は実機と同じ App.composeScene を通し、
    /// 背景の面は surfaces として別に取り出して画素ごとに評価させる（draw に渡すと代表色のベタ塗りになる）。
    /// 縦の画面は design と描き出しの大きさを縦の design にし、画面の情報を Display.phonePortrait にする（実機のブラウザの縦と同じ組）。
    def shootAs(look: Look, res: Res.Res, landscape: HeadlessRender.RenderConfig, w: World.World, name: String): String \ IO =
        let (cfg, display) = match look {
            case Look.Landscape(sizeClass) => (landscape, { sizeClass = sizeClass | Display.desktop(design()) })
            case Look.Portrait(view) =>
                let d = portraitDesignOf(view);
                ({ design = d, frameW = Float64.round(d#x) |> Float64.tryToInt32 |> Option.getWithDefault(540),
                   frameH = Float64.round(d#y) |> Float64.tryToInt32 |> Option.getWithDefault(960) | landscape },
                 Display.phonePortrait(view, d))
        };
        let ctx = { display = display | App.viewCtxOf(cfg#fontAtlas, cfg#design) };
        let items = App.composeScene(None, 1.0, cfg#design, { world = View.frame(ctx, res, w), hud = View.hud(ctx, res, w) });
        let (drawables, polygons) = Render.draw(Render.withoutShaders(items));
        HeadlessRender.renderPngWith(cfg, drawables, polygons, Render.shaderSurfaces(items), name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
