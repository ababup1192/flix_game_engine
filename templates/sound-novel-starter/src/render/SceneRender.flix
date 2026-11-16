// SceneRender — ゲーム画面を画面なしで PNG に描き出す（スナップショット比較用）。
// 実行: make render-all → gallery/*.png と gallery/<場面>.json（場面の正は novel.shots.json・World を組むのは Shots）
//       make render SHOT=nvl → debug/nvl.png（1 枚だけ）。small-<場面> は同じ場面を小さい画面（スマホ）の並べ方で描く。
//       portrait-<場面> は縦に持ったスマホ（390×844 → 縦の design 540×1169）、portrait-short-<場面> は太い縦の画面（360×640 → 540×960）で描く
// 背景のぼかしは宣言シェーダーの面なので、draw には渡さず ShaderEval が画素ごとに塗る（Render.shaderSurfaces）。
// 写真は project.json の textures をそのまま読む（実機と同じ名前 → 同じファイル）。
mod SceneRender {
    use fge::{App, DocJson, Display, FontAtlas, HeadlessFont, HeadlessLoad, HeadlessRender, JsonCodec, Log, ProjectLoader, Render, SoftRaster, Suggest, Vec2}

    import java.io.File
    import java.lang.ProcessHandle

    /// 描き出しと flow の画面の大きさ（project.json の designWidth / designHeight。デスクトップ版の実機と同じ design）。
    /// 読めない・大きさが 0 以下なら横の 960×540（1 行言う）。
    pub def design(): Vec2.Vec2 \ IO =
        match designOf(run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO) {
            case Ok(d)    => d
            case Err(why) => Log.fellBackThen("render", "project.json の design", "960×540", why, Layout.size(Layout.Fit.Regular))
        }

    /// 読んだ project.json の design の大きさ（読めない・0 以下は Err）。
    pub def designOf(loaded: Result[String, ProjectLoader.Project]): Result[String, Vec2.Vec2] =
        loaded |> Result.flatMap(proj ->
            if (proj#config#designWidth > 0 and proj#config#designHeight > 0)
                Ok({ x = Int32.toFloat64(proj#config#designWidth), y = Int32.toFloat64(proj#config#designHeight) })
            else Err("designWidth / designHeight が 0 以下"))

    /// design の大きさで描いた時の並べ方の組（デスクトップ版の実機と同じ: 区分 Large・向きは design の形から。縦の design なら Portrait）。
    pub def fitOf(design: Vec2.Vec2, res: Res.Res): Layout.Fit =
        Layout.fitOf(Display.SizeClass.Large, Display.orientationOf(design), design, res#smallScreen, res#portrait)

    /// 描き出す画面の形: design のまま（区分 Large か Small。縦の design なら縦の並べ方）か、画面の大きさ view の縦のスマホ。
    enum Look {
        case Design(Display.SizeClass)
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

    /// 字の縁も面の縁もならす（写真と明朝の画面。格子に乗せる絵は無い）。描き出しの大きさは design と同じ。
    pub def cfgOf(design: Vec2.Vec2, outDir: String, textures: Map[String, String]): HeadlessRender.RenderConfig \ IO =
        { design = design, scale = 1, background = Backdrop.groundColor(),
          fontTtf = ttf(), fontAtlas = HeadlessFont.buildUiAtlas(ttf(), ttf()), texturePath = textures,
          outDir = outDir, frameW = pixelsOf(design#x, 960), frameH = pixelsOf(design#y, 540) | HeadlessRender.defaults() }

    /// 描き出しと flow の画面: design の大きさ・描き出しへ混ぜる本（extraFontsOf）・View に渡す字の本（本文の本と、名前で引く本）。
    pub type alias Screen = { design = Vec2.Vec2, extra = Map[String, SoftRaster.FontEntry], fonts = View.Fonts }

    /// design と、App.withFonts で宣言した名前 declared から、描き出しの画面を 1 回だけ組む（本を作るのは重いので場面ごとに組まない）。
    pub def screenOf(design: Vec2.Vec2, declared: List[String]): Screen \ IO =
        let extra = extraFontsOf(declared);
        let body = HeadlessFont.buildUiAtlas(ttf(), ttf());
        { design = design, extra = extra, fonts = { atlas = body, fontOf = fontOfIn(extra, body) } }

    /// ゲームが App.withFonts で宣言した名前（GameBoot.app を通した App の fonts）。
    pub def declaredFontsOf(res: Res.Res): List[String] = App.rec(Game.app(res, Saves.fresh(res#kind), 0i64))#fonts

    /// 既定の本（明朝）のほかに描き出しへ混ぜる本（project.json の fonts のうち declared に挙げた名前）。鍵は実機と同じテクスチャの名前（"font_" + name）。
    /// project.json が読めなければ空（既定の本だけで描く）。
    pub def extraFontsOf(declared: List[String]): Map[String, SoftRaster.FontEntry] \ IO =
        match run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO {
            case Ok(proj) => fontsIn(proj, declared)
            case Err(_)   => Map.empty()
        }

    /// proj の fonts のうち declared に挙げた名前を、実機と同じ名前で組んだ本の表に。
    // WhyNot: project.json の fonts を全部組まない — 実機の ViewCtx#fontOf は App.withFonts で宣言した名前しか引けず、宣言していない名前は本文の本になる。
    pub def fontsIn(proj: ProjectLoader.Project, declared: List[String]): Map[String, SoftRaster.FontEntry] \ IO =
        let wanted = List.toSet(declared);
        proj#config#fontManifest |> List.filter(f -> Set.memberOf(f#name, wanted))
            |> List.map(f -> ("font_${f#name}", { ttf = f#path, atlas = HeadlessFont.buildAtlas(f#name, f#path) })) |> List.toMap

    /// 名前 → その本（実機の ViewCtx#fontOf と同じ引き方。知らない名前は fallback）。
    pub def fontOfIn(fonts: Map[String, SoftRaster.FontEntry], fallback: FontAtlas): String -> FontAtlas =
        name -> Map.get("font_${name}", fonts) |> Option.map(e -> e#atlas) |> Option.getWithDefault(fallback)

    /// design の長さを描き出しの画素の数に（読めない長さは fallback）。
    def pixelsOf(length: Float64, fallback: Int32): Int32 = Float64.round(length) |> Float64.tryToInt32 |> Option.getWithDefault(fallback)

    /// project.json の textures（名前 → パス）。読めなければ空（背景は代表色ではなく黒になる）。
    pub def texturesOf(): Map[String, String] \ IO =
        let rows = run { DocJson.readJson("project.json") } with Fs.FileRead.runWithIO;
        rows |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
             |> Option.flatMap(root -> Map.get("textures", root))
             |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(obj ->
                    (JsonCodec.stringOr("name", "", obj), JsonCodec.stringOr("path", "", obj)))))
             |> Option.getWithDefault(Nil) |> List.toMap

    /// ゲームの後から届く素材（GameBoot.loadAssets）も全部読んだ描く元（描き出しに 3D の背景も写す）。
    def loadRes(): Res.Res \ IO = run {
        let loaded = Controls.loadRes();
        Res.withGame(HeadlessLoad.handle(() -> GameBoot.loadAssets(loaded#game)), loaded)
    } with Fs.FileRead.runWithIO

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
        let cfg = cfgOf(design(), "debug/shot", texturesOf());
        shootAs(Look.Design(Display.SizeClass.Large), res, cfg, extraFontsOf(declaredFontsOf(res)), w, "shot-${ProcessHandle.current().pid()}")

    pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))

    pub def oneJob(req: App.Headless.Request): Int32 \ IO =
        let wanted = Map.getWithDefault("SHOT", "", App.Headless.envOf(req)) |> String.splitOn(substr = " ")
            |> List.map(String.trim) |> List.filter(n -> not String.isEmpty(n));
        let names = allNames(loadRes());
        let known = List.toSet(names);
        let unknown = wanted |> List.filter(n -> not Set.memberOf(n, known));
        if (List.isEmpty(wanted) or not List.isEmpty(unknown)) {
            unknown |> List.forEach(n -> println("[render] 描けない名前です: ${n}${Suggest.hint(n, names)}"));
            println("[render] SHOT=<場面> に使えるのは: ${List.join(" ", names)}（場面の正は ${ShotsDoc.path()}）");
            1
        } else {
            let picked = List.toSet(wanted);
            discard shotsInto("debug", n -> Set.memberOf(n, picked));
            0
        }

    /// 小さい画面（スマホ）の並べ方で描く場面: (描き出しの名前, novel.shots.json の場面の名前)。World は同じ場面の物をそのまま使う。
    /// WhyNot: novel.shots.json に入れない — Shots.names は実機の START=shot: の口でもあり、デスクトップ版の実機はいつも Large で描く。
    def smallShots(): List[(String, String)] =
        ("small-title", "title") :: ("small-nvl", "nvl") :: ("small-adv", "adv") :: ("small-choice", "choice")
            :: ("small-save", "save") :: ("small-settings", "settings") :: ("small-ask", "ask") :: Nil

    /// 描く元を替えて描く横の場面: (描き出しの名前, novel.shots.json の場面の名前)。どう替えるかは resFor。
    /// WhyNot: novel.shots.json に入れない — 実機の START=shot: は World だけを替える口で、Doc（描く元）は替えられない。
    def variantShots(): List[(String, String)] =
        ("hold-ring", "hold") :: ("hold-none", "hold") :: ("cast-sample", "cast") :: Nil

    /// 描き出しの名前 → その場面で使う描く元。hold-ring / hold-none = 待ちの印を輪 / 無しにした描く元、
    /// cast-sample = テスト用の立ち絵の人物を物語の人物に足した描く元（CastDoc.withSample）、portrait-cast-veil = それに縦の頁の覆いを人物が出ている間だけ薄くする倍率を入れた描く元。ほかはそのまま。
    def resFor(name: String, res: Res.Res): Res.Res = match name {
        case "cast-sample"          => Res.withCast(CastDoc.withSample(res#cast), res)
        case "portrait-cast-sample" => Res.withCast(CastDoc.withSample(res#cast), res)
        case "portrait-cast-veil"   => Res.withCast(CastDoc.Doc.Doc({ portraitVeilWithCast = 0.5 | CastDoc.rec(CastDoc.withSample(res#cast)) }), res)
        case "hold-ring"          => withLoadingMark(ThemeDoc.LoadingMark.Ring, res)
        case "portrait-hold-ring" => withLoadingMark(ThemeDoc.LoadingMark.Ring, res)
        case "hold-none"          => withLoadingMark(ThemeDoc.LoadingMark.Hidden, res)
        case _                    => res
    }

    def withLoadingMark(mark: ThemeDoc.LoadingMark, res: Res.Res): Res.Res = Res.withTheme(ThemeDoc.withLoadingMark(mark, res#theme), res)

    /// 縦の画面で描く場面: (描き出しの名前, 場面の名前, 画面の大きさ)。World は Shots の同じ場面の物をそのまま使う（menu・saveload・tooltip だけは worldOf）。
    /// 太い縦の画面（360×640）は縦の design の下限の高さで、並べ方がいちばん窮屈になる所を見る。
    def portraitShots(): List[(String, String, Vec2.Vec2)] =
        let tall = Display.defaultPortraitView();
        let short = { x = 360.0, y = 640.0 };
        ("portrait-title", "title", tall) :: ("portrait-nvl", "nvl", tall) :: ("portrait-adv", "adv", tall)
            :: ("portrait-choice", "choice", tall) :: ("portrait-log", "log", tall) :: ("portrait-save", "save", tall)
            :: ("portrait-settings", "settings", tall) :: ("portrait-ask", "ask", tall)
            :: ("portrait-eaves", "eaves", tall) :: ("portrait-ending", "ending", tall) :: ("portrait-menu", "menu", tall)
            :: ("portrait-saveload", "saveload", tall) :: ("portrait-tooltip", "tooltip", tall)
            :: ("portrait-hold-ring", "hold", tall) :: ("portrait-cast-sample", "cast", tall) :: ("portrait-cast-veil", "cast", tall)
            :: ("portrait-short-nvl", "nvl", short) :: ("portrait-short-save", "save", short)
            :: ("portrait-short-settings", "settings", short) :: Nil

    /// 場面の名前 → World。縦の画面だけの場面（どれも ADV の台詞の上）: menu = オートを点けて右上の … のメニューを開いた所、
    /// saveload = しおりから [セーブ｜ロード] の選びを開いた所、tooltip = 指の長押しで右の列のログの名前を出した所、
    /// cast = テスト用の立ち絵の人物を出した所（横と縦の両方で描く）。
    // WhyNot: 縦の画面だけの場面を novel.shots.json に入れない — 右の列と … は縦の画面にしか無く、Shots.names は横の描き出しと実機の START=shot: の口でもある。
    def worldOf(scene: String, res: Res.Res): Option[World.World] =
        match List.find(row -> fst(row) == scene, ownScenes()) {
            case Some((_, change)) => Shots.worldOf("adv", res) |> Option.map(change)
            case None              => Shots.worldOf(scene, res)
        }

    /// worldOf だけが組む場面: (名前, adv の場面の World をどう変えるか)。
    def ownScenes(): List[(String, World.World -> World.World)] =
        ("menu", w -> World.mapRead(r -> { playback = World.Playback.Auto | r }, { panel = World.Panel.Menu(0) | w })) ::
        ("saveload", w -> { panel = World.Panel.SaveLoadPick(0) | w }) ::
        ("tooltip", w -> World.mapRead(r -> { tip = Some((logIndex(), w#realNow)) | r }, w)) ::
        ("cast", World.mapRead(r -> { stage = { cast = sampleLayer() | r#stage } | r })) :: Nil

    /// テスト用の立ち絵の人物を、既定の位置と表情で出し終えた層。
    def sampleLayer(): Cast.Layer =
        let entry = CastDoc.entryOf(CastDoc.Kind.Character, CastDoc.sampleName(), CastDoc.sample());
        let figures = entry |> Option.map(e -> { name = CastDoc.sampleName(), face = e#face, slot = e#slot }) |> Option.toList;
        Cast.layerOf({ cast = figures, props = Nil })

    /// 縦の画面の右の列のログの番号。
    def logIndex(): Int32 =
        WorldMenu.buttonIndexOf(Layout.Fit.Portrait(PortraitDoc.rec(PortraitDoc.defaults()), Display.defaultPortraitView()), World.Button.Log)
            |> Option.getWithDefault(0)

    /// 描き出せる名前の全部（Shots の場面と、小さい画面と縦の画面の場面）。
    def allNames(res: Res.Res): List[String] = Shots.names(res) ::: variantNames()

    def variantNames(): List[String] =
        List.flatten((variantShots() |> List.map(fst)) :: (smallShots() |> List.map(fst))
                     :: (portraitShots() |> List.map(match (name, _, _) -> name)) :: Nil)

    /// 描き出しだけの名前（novel.shots.json の場面の名前と重なると、どちらを描くか読み違える）: worldOf だけが組む場面と、
    /// 描く元を替えた場面・小さい画面・縦の画面の描き出しの名前。
    pub def renderOnlyNames(): List[String] = (ownScenes() |> List.map(fst)) ::: variantNames()

    def shotsInto(outDir: String, keep: String -> Bool): List[String] \ IO =
        discard (new File(outDir)).mkdirs();
        let d = design();
        let cfg = cfgOf(d, outDir, texturesOf());
        let loaded = loadRes();
        let fonts = extraFontsOf(declaredFontsOf(loaded));
        let regular = Shots.names(loaded) |> List.map(name -> (name, name, Look.Design(Display.SizeClass.Large)));
        let variant = variantShots() |> List.map(match (name, scene) -> (name, scene, Look.Design(Display.SizeClass.Large)));
        // WhyNot: 縦の design で small-* を撮らない — 縦の design では区分 Small でも縦の並べ方が選ばれ、design の場面と同じ絵になる。
        let small = if (Display.orientationOf(d) == Display.Orientation.Portrait) Nil
                    else smallShots() |> List.map(match (name, scene) -> (name, scene, Look.Design(Display.SizeClass.Small)));
        let portrait = portraitShots() |> List.map(match (name, scene, view) -> (name, scene, Look.Portrait(view)));
        List.flatten(regular :: variant :: small :: portrait :: Nil) |> List.filter(match (name, _, _) -> keep(name)) |> List.filterMap(match (name, scene, look) ->
            shootNamed(outDir, cfg, fonts, loaded, name, scene, look))

    /// 描き出しの名前 name を、場面 scene の World と look の画面で描く。場面を組めなければ 1 行言って飛ばす。
    def shootNamed(outDir: String, cfg: HeadlessRender.RenderConfig, fonts: Map[String, SoftRaster.FontEntry], loaded: Res.Res,
                   name: String, scene: String, look: Look): Option[String] \ IO =
        let res = resFor(name, loaded);
        match worldOf(scene, res) {
            case Some(w) =>
                let path = shootAs(look, res, cfg, fonts, w, name);
                App.Headless.writeShotRecord(outDir, name, Some(E2e.fingerprint(res, w)));
                Some(path)
            case None =>
                println("[render] ${name} を飛ばす: 場面 '${scene}' を組めない（${ShotsDoc.path()} に無いか、読めない）");
                None
        }

    /// 1 場面を look の画面として PNG に描き出し、そのファイルパスを返す。hud の合流は実機と同じ App.composeScene を通し、
    /// 背景の面は surfaces として別に取り出して画素ごとに評価させる（draw に渡すと代表色のベタ塗りになる）。
    /// 縦の画面は design と描き出しの大きさを縦の design にし、画面の情報を Display.phonePortrait にする（実機のブラウザの縦と同じ組）。
    /// fonts = 描き出しへ混ぜる本（extraFontsOf。場面ごとに組み直さない）。
    def shootAs(look: Look, res: Res.Res, base: HeadlessRender.RenderConfig, fonts: Map[String, SoftRaster.FontEntry], w: World.World, name: String): String \ IO =
        let (cfg, display) = match look {
            case Look.Design(sizeClass) => (base, { sizeClass = sizeClass | Display.desktop(base#design) })
            case Look.Portrait(view) =>
                let d = portraitDesignOf(view);
                ({ design = d, frameW = pixelsOf(d#x, 540), frameH = pixelsOf(d#y, 960) | base }, Display.phonePortrait(view, d))
        };
        let ctx = { display = display | App.viewCtxOfFonts(cfg#fontAtlas, fontOfIn(fonts, cfg#fontAtlas), cfg#design) };
        let items = App.composeScene(None, 1.0, cfg#design, { world = View.frame(ctx, res, w), hud = View.hud(ctx, res, w) });
        let (drawables, polygons) = Render.draw(Render.withoutShaders(items));
        HeadlessRender.renderPngFull(cfg, { passes = Nil, drawables = drawables, polygons = polygons, surfaces = Render.shaderSurfaces(items),
                                            scenes = Nil, fonts = fonts, fontAntialias = Map.empty() }, name);
        let path = "${cfg#outDir}/${name}.png";
        println("rendered: ${path}");
        path
}
