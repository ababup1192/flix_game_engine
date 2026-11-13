// FlowVideo — e2e/<名前>.flow を実機と同じ 1 フレーム（Flow.play）で流し、動画のコマと音に描き出す。
// 実行: make video FLOW=e2e/showcase.flow → debug/video/showcase.mp4（mp4 に束ねるのは Makefile の ffmpeg）
//
// 書く物（FLOW_OUT。既定は debug/video/<名前>）:
//   f0000.png …（SoftRaster）か frames.mkv（GPU）・drawhash.txt・frames.json … エンジンの VideoOut が書く
//   audio.f64 … 左右 2 本の 44.1kHz の音（64bit 浮動小数・ビッグエンディアン・左右交互）。
//               実機と同じミキサー（Controls.mixerOf）で、そのフレームに鳴った音と鳴り続ける環境音を AudioMixdown が混ぜる。
//   fps.txt   … コマの速さ（flow の fps）
//   tape.json … テープの頁が読むシナリオ・シーン・音・問いの流れ（TapeOut。同じ名前の mark・2 つ以上の .yarn にまたがる flow では書かずに理由を出す）
mod FlowVideo {
    use fge::{App, AudioMixdown, DocJson, Flow, FontAtlas, JsonCodec, Rect2, Render, Resources, VideoOut}

    import java.io.BufferedOutputStream
    import java.io.DataOutputStream
    import java.io.File
    import java.io.FileOutputStream
    import java.io.FileWriter

    /// App の w（描く元と World の組）。
    type alias AppState = Resources.With[Res.Res, World.World]

    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。E2e.serveHeadless が束ねる。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.videoJob("FlowVideo", "play", req -> playJob(req)) :: Nil

    /// 終了コード: 0 = 撮れた・1 = flow が途中で止まった（そこまでは書く）・2 = flow を読めない。
    pub def playJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        // WhyNot: 設定を字の用意より後に作らない —— GPU で塗る回は AWT より先に GL へ繋ぐ必要がある（VideoOut.settingsOf）。
        let settings = VideoOut.settingsOf(env);
        let path = Map.getWithDefault("FLOW", "", env);
        let out = Map.getWithDefault("FLOW_OUT", "debug/video/${nameOf(path)}", env);
        let played = run {
            let app = appOf();
            let design = SceneRender.design();
            let fresh = App.freshWorld(app, design);
            match Flow.Parse.parseFile(Flow.vocabOf(app, fresh), path, Flow.Cli.readText) {
                case Err(problems) => Err(Flow.Parse.problemsText(problems))
                case Ok(script)    =>
                    let start = { world = Flow.Cli.startWorld(app, design, fresh, script), state = App.freshStepState() };
                    Ok((script, Flow.play(app, { design = design, limit = frameCap() }, script, start)))
            }
        } with Fs.FileRead.runWithIO;
        match played {
            case Err(why) => println("FAIL ${path} を読めない\n${why}"); 2
            case Ok((script, Ok(outcome))) =>
                write(settings, script#fps, out, outcome);
                writeTape(path, script, out, outcome);
                println("rendered: ${out} (${Int32.toString(List.length(outcome#frames))} frames)");
                0
            case Ok((script, Err(failure))) =>
                write(settings, script#fps, out, failure#upTo);
                writeTape(path, script, out, failure#upTo);
                println("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: ${failure#why}");
                println("    ${failure#at#text}");
                1
        }

    /// e2e と同じ App で、セーブの日時だけ描き出しと同じ「起動した時刻」に据える（e2e の 0 のままだと 1970/01/01 と出る）。
    def appOf(): App.App[AppState, {}] \ Fs.FileRead =
        let res = Controls.loadRes();
        Game.app(res, Saves.fresh(res#kind), Shots.clockBase())

    /// 撮るコマの上限（30fps で 5 分。flow の until の max が先に当たる）。
    def frameCap(): Int32 = 9000

    def write(settings: VideoOut.Settings, fps: Float64, out: String, outcome: Flow.Outcome[AppState]): Unit \ IO =
        discard (new File(out)).mkdirs();
        let rate = Float64.tryToInt32(Float64.round(fps)) |> Option.getWithDefault(30);
        writeText("${out}/fps.txt", Int32.toString(rate));
        writeAudio("${out}/audio.f64", fps, outcome);
        let cfg = SceneRender.cfgOf(out, SceneRender.texturesOf());
        let video = { outDir = out, fps = rate, soft = cfg, softFonts = _ -> cfg#fontAtlas, extraFonts = Map.empty(),
                      images = Nil, scene = fonts -> h -> sceneOf(fonts, h), wanted = _ -> true, bakeSurfaces = false,
                      encoders = Nil };
        discard VideoOut.writeFrames(settings, video, Flow.worldsOf(outcome))

    /// tape.json（flow が途中で止まった時もそこまで）。書けない理由（同じ名前の mark・2 つ以上の .yarn にまたがる）は 1 行出す。
    def writeTape(path: String, script: Flow.Script, out: String, outcome: Flow.Outcome[AppState]): Unit \ IO =
        let marks = script#lines |> List.filterMap(line -> match line#step {
            case Flow.Step.Mark(name) => Some(name)
            case _                    => None
        });
        let flowRun = { game = (new File(".")).getCanonicalFile().getName(), flow = path, fps = script#fps, design = SceneRender.design(),
                        marks = marks, outcome = outcome };
        match TapeOut.toJson(tapeTable(outcome#last), flowRun) {
            case Ok(text) => writeText("${out}/tape.json", text)
            case Err(why) => println("tape: ${why}（${out}/tape.json は書かない）")
        }

    /// テープに渡すこのゲームの表。題名は project.json、UI の返事の音（ui_）は載せない、メッセージウィンドウは横の ADV のウィンドウ（NVL の間は重ねない）。
    def tapeTable(h: AppState): TapeOut.Table \ IO =
        { title = projectTitle(),
          sceneNames = Map#{ "title" => "タイトル", "station" => "無人の駅", "clear" => "頁をめくる" },
          soundLabels = Map#{ "amb_evening" => "夕方の環境音", "amb_night" => "夜の環境音", "amb_river" => "川の環境音",
                              "amb_morning" => "朝の環境音", "se_slap" => "背中を叩く", "se_furin" => "風鈴" },
          hiddenSounds = soundFiles() |> List.map(match (name, _, _) -> name) |> List.filter(String.startsWith({prefix = "ui_"})) |> List.toSet,
          msg = advMsg(h),
          probes = "phase" :: "mode" :: "photo" :: "logSize" :: Nil,
          probeNames = Map#{ "phase" => "場面", "mode" => "出し方", "photo" => "背景", "logSize" => "ログ" },
          playUrl = "",
          objects = h1 -> objectsOf(Layout.Fit.Regular, h1#resources, h1#world) }

    /// 画面に出ている物（テープの頁の「物を選ぶ」）。タイトルは題字とメニュー、読む間は背景・立ち絵と小物・メッセージウィンドウ・選択肢・クイックメニュー。
    /// 置き場は View と同じ Layout・Cast の関数から引く（描いた所と枠がずれない）。
    pub def objectsOf(fit: Layout.Fit, res: Res.Res, w: World.World): List[TapeOut.ScreenObject] =
        let thing = (id, name, r) -> { id = id, name = name, rect = r };
        match w#scene {
            case World.Scene.Title(_) =>
                let count = List.length(WorldMenu.titleItems());
                let top = Layout.titleHeadingY(fit);
                thing("title_logo", "題字", rectOf(Layout.width(fit) * 0.2, top, Layout.width(fit) * 0.6, Layout.titleSubtitleY(fit) + 22.0 - top)) ::
                thing("title_menu", "タイトルのメニュー", boxOf(List.range(0, count) |> List.map(i -> Layout.titleItem(fit, i, count)))) :: Nil
            case World.Scene.Credits(_, _) => thing("credits", "クレジット", Layout.screen(fit)) :: Nil
            case World.Scene.Reading(r) =>
                let backdrop = r#stage#shot |> Option.map(shot -> {
                    let label = BackdropDoc.photoOf(shot#photo, res#backdrops) |> Option.map(p -> p#label) |> Option.filter(l -> not String.isEmpty(l));
                    thing("backdrop", "背景（${Option.getWithDefault(shot#photo, label)}）", Layout.screen(fit))
                }) |> Option.toList;
                let castEnv = { doc = res#cast, fit = fit, storyNow = World.now(w), realNow = w#realNow, missing = res#missing };
                let cast = Cast.placedOf(castEnv, r#stage#cast) |> List.map(p -> thing(p#figure#name, if (String.isEmpty(p#label)) p#figure#name else p#label, p#rect));
                let hud = if (View.coversScreen(w#panel) or w#panel == World.Panel.Hidden) Nil else readingHud(fit, r);
                List.flatten(backdrop :: cast :: hud :: Nil)
        }

    def readingHud(fit: Layout.Fit, r: World.Read): List[TapeOut.ScreenObject] =
        let choiceCount = List.length(r#choices);
        let buttonCount = List.length(WorldMenu.buttonsOf(fit));
        let message = if (Layout.isPortrait(fit)) Layout.page(fit, choiceCount)
            else match r#stage#mode {
                case Stage.Mode.Adv => Layout.advPanel(fit)
                case Stage.Mode.Nvl =>
                    let area = Layout.nvlText();
                    rectOf(area#x, area#y, area#width, Layout.height(fit) - 2.0 * area#y)
            };
        let buttons = List.range(0, buttonCount) |> List.map(i -> if (Layout.isPortrait(fit)) Rail.button(fit, i) else Layout.button(fit, i, buttonCount));
        let choices = if (choiceCount == 0) Nil
            else { id = "choices", name = "選択肢", rect = boxOf(List.range(0, choiceCount) |> List.map(i -> Layout.choice(fit, i, choiceCount))) } :: Nil;
        List.flatten(({ id = "message", name = "メッセージウィンドウ", rect = message } :: Nil) :: choices ::
                     ({ id = "quick_menu", name = "クイックメニュー", rect = boxOf(buttons) } :: Nil) :: Nil)

    /// 矩形を全部囲む矩形（空なら大きさ 0）。
    def boxOf(rects: List[Rect2.Rect2]): Rect2.Rect2 =
        let xs0 = rects |> List.map(r -> r#position#x);
        let ys0 = rects |> List.map(r -> r#position#y);
        let xs1 = rects |> List.map(r -> r#position#x + r#size#x);
        let ys1 = rects |> List.map(r -> r#position#y + r#size#y);
        let lo = vs -> List.minimum(vs) |> Option.getWithDefault(0.0);
        let hi = vs -> List.maximum(vs) |> Option.getWithDefault(0.0);
        rectOf(lo(xs0), lo(ys0), hi(xs1) - lo(xs0), hi(ys1) - lo(ys0))

    def rectOf(x: Float64, y: Float64, w: Float64, h: Float64): Rect2.Rect2 = { position = { x = x, y = y }, size = { x = w, y = h } }

    /// 横の ADV のウィンドウの寸法を画面の割合に（Layout と novel.kind.json から導く）。
    def advMsg(h: AppState): TapeOut.Msg =
        let fit = Layout.Fit.Regular;
        let size = Layout.size(fit);
        let k = KindDoc.rec(h#resources#kind);
        let panel = Layout.advPanel(fit);
        let text = Layout.advText(fit);
        let body = Layout.advTextSizes(fit, k)#body;
        let firstBase = text#y + body;
        { x0 = text#x / size#x, x1 = (text#x + text#width) / size#x,
          cy = (panel#position#y + panel#size#y * 0.5) / size#y,
          lh = (body + k#lineGap * body / k#bodySize) / size#y,
          padTop = (firstBase - panel#position#y) / size#y,
          padBot = (panel#position#y + panel#size#y - firstBase) / size#y,
          font = body / size#y,
          cps = World.configOf(h#world)#cps,
          when = Map#{ "mode" => "Adv" } }

    /// project.json の title（読めなければ空）。
    def projectTitle(): String \ IO =
        let root = run { DocJson.readJson("project.json") } with Fs.FileRead.runWithIO;
        root |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
             |> Option.map(obj -> JsonCodec.stringOr("title", "", obj)) |> Option.getWithDefault("")

    /// 1 コマの絵（SceneRender.shoot と同じ合流: 背景は frame、文章とウィンドウは hud）。
    def sceneOf(fonts: String -> FontAtlas, h: AppState): List[Render.PlacedItem] =
        let ctx = App.viewCtxOf(fonts(""), SceneRender.design());
        App.composeScene(None, 1.0, SceneRender.design(), { world = Resources.view(View.frame, ctx, h), hud = Resources.view(View.hud, ctx, h) })

    def sampleRate(): Int32 = 44100

    /// 各フレームに鳴った音と鳴り続ける音を、そのフレームの World のミキサーで混ぜて書く。
    def writeAudio(path: String, fps: Float64, outcome: Flow.Outcome[AppState]): Unit \ IO =
        let entries = soundFiles();
        let sounds = loadSounds(entries, Map.empty());
        let loops = loadLoops(entries, Map.empty());
        let frames = outcome#frames |> List.map(played ->
            { plays = played#step#sounds, sustained = played#step#sustained, mixer = Resources.read(Controls.mixerOf, played#step#after) });
        let mixed = AudioMixdown.mixdownStereo(sampleRate(), fps, sounds, loops, frames);
        writeSamples(path, mixed)

    def writeSamples(path: String, mixed: AudioMixdown.Stereo): Unit \ IO =
        let out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(path)));
        let n = Int32.min(Vector.length(mixed#left), Vector.length(mixed#right));
        def go(i: Int32): Unit \ IO =
            if (i >= n) ()
            else {
                out.writeDouble(Vector.get(i, mixed#left));
                out.writeDouble(Vector.get(i, mixed#right));
                go(i + 1)
            };
        go(0);
        out.close()

    def loadSounds(entries: List[(String, String, Bool)], acc: Map[String, AudioMixdown.Stereo]): Map[String, AudioMixdown.Stereo] \ IO =
        match entries {
            case (name, file, _) :: rest => loadSounds(rest, Map.insert(name, AudioMixdown.loadWavStereo(sampleRate(), file), acc))
            case Nil                     => acc
        }

    def loadLoops(entries: List[(String, String, Bool)], acc: Map[String, Int32]): Map[String, Int32] \ IO =
        match entries {
            case (name, file, true) :: rest => match AudioMixdown.loadLoopStart(sampleRate(), file) {
                case Some(at) => loadLoops(rest, Map.insert(name, at, acc))
                case None     => loadLoops(rest, acc)
            }
            case _ :: rest => loadLoops(rest, acc)
            case Nil       => acc
        }

    /// project.json の sounds（名前・ファイル・鳴り続けるか）。
    def soundFiles(): List[(String, String, Bool)] \ IO =
        let rows = run { DocJson.readJson("project.json") } with Fs.FileRead.runWithIO;
        rows |> Result.toOption |> Option.flatMap(JsonCodec.expectObject)
             |> Option.flatMap(root -> Map.get("sounds", root))
             |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(obj ->
                    (JsonCodec.stringOr("name", "", obj), JsonCodec.stringOr("path", "", obj), JsonCodec.boolOr("looping", false, obj)))))
             |> Option.getWithDefault(Nil)

    /// e2e/showcase.flow → showcase。
    def nameOf(path: String): String =
        let base = String.splitOn({substr = "/"}, path) |> List.last |> Option.getWithDefault(path);
        String.stripSuffix({substr = ".flow"}, base) |> Option.getWithDefault(base)

    def writeText(path: String, text: String): Unit \ IO =
        let out = new FileWriter(path);
        out.write(text);
        out.close()
}
