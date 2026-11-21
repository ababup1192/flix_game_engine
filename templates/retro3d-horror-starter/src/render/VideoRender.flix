// VideoRender — 校舎を歩く所の動画のコマを、画面なしで書く。
// 実行: make video FLOW=e2e/video/corridor.flow OUT=corridor → debug/video/corridor.mp4
//       （GPU で塗れた時は ffmpeg へ直に流して mp4 を書く。SoftRaster に落ちた時は debug/video/<名前>/f0000.png … を書き、make が mp4 へ束ねる）
//
// 手順は flow（e2e と同じ実行器）で、キーを実機と同じ 1 フレームずつ World に流す。撮るのは mark in_<名前> から
// out_<名前> までの区間だけ。手順は 60 fps で流し、VIDEO_FPS ごとに間引いて描く。コマは 3 倍の 960×720 で描く:
// 3D は 320×240 のまま補間なしで拡げ、字（HUD）は 3 倍の画素でなめらかに描く（ffmpeg で拡げると字まで粗くなる）。
//
// 環境変数: VIDEO_FPS（既定 30。60 を割り切る数）・VIDEO_FLOW（手順）・VIDEO_OUT（debug/video/<名前>）・
//           VIDEO_X264（mp4 を書く ffmpeg の旗）・FGE_GPU / FGE_VIDEO_PAINT / FFMPEG（VideoOut.settingsOf）
mod VideoRender {
    use fge::{App, Color, Flow, FontAtlas, HeadlessFont, HeadlessLoad, HeadlessRender, PostStack, Render, Resources, Sort, VideoOut}

    import java.io.File
    import java.nio.file.{Files, Paths}

    /// App の w（描く元と World の組）。
    type alias AppState = Resources.With[Res.Res, World.World]

    /// 撮る手順と、コマを書く所（debug/video/<名前>）。
    type alias Take = { flow = String, outDir = String }

    def takeOf(env: Map[String, String]): Take =
        let pick = (key, fallback) -> Map.get(key, env) |> Option.map(String.trim) |> Option.filter(v -> not String.isEmpty(v)) |> Option.getWithDefault(fallback);
        { flow = pick("VIDEO_FLOW", "e2e/video/corridor.flow"), outDir = "debug/video/${pick("VIDEO_OUT", "corridor")}" }

    /// 手順を流す速さ（flow の fps と同じ）。
    def playFps(): Int32 = 60

    pub def frames(): Unit \ IO = App.Headless.exitWith(framesJob(App.Headless.requestFromProcess()))

    /// 常駐（App.Headless.serveJobs）が /run で流す入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("VideoRender", "frames", req -> framesJob(req)) :: Nil

    def framesJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        // GL の文脈は AWT（字のアトラス）より先に繋ぐ（VideoOut.settingsOf の doc）。
        let settings = VideoOut.settingsOf(env);
        let fps = Map.get("VIDEO_FPS", env) |> Option.flatMap(Int32.fromString)
            |> Option.filter(n -> n > 0 and Int32.modulo(playFps(), n) == 0) |> Option.getWithDefault(30);
        let design = { x = World.width(), y = World.height() };
        let app = run { Game.app(HeadlessLoad.handle(Controls.loadDocs)) } with Fs.FileRead.runWithIO;
        let fresh = run { App.freshWorld(app, design) } with Fs.FileRead.runWithIO;
        let take = takeOf(env);
        discard (new File(take#outDir)).mkdirs();
        match playFlow(app, fresh, take#flow, Files.readString(Paths.get(take#flow))) {
            case Err(why) =>
                println("[video] ${why}");
                1
            case Ok(outcome) => writeOutcome(settings, env, fps, take, outcome)
        }

    /// 手順（flow の文）を読んで、まっさらな World から流す。読めない・途中で止まった時は、その訳の 1 行。
    def playFlow(app: App.App[AppState, {}], fresh: AppState, flowPath: String, text: String): Result[String, Flow.Outcome[AppState]] \ IO =
        Flow.Parse.parseText(Flow.vocabOf(app, fresh), flowPath, text)
            |> Result.mapErr(problems -> "手順を読めない\n" + Flow.Parse.problemsText(problems))
            |> Result.flatMap(script -> {
                let played = run {
                    Flow.play(app, { design = { x = World.width(), y = World.height() }, limit = 100000 }, script, { world = fresh, state = App.freshStepState() })
                } with Fs.FileRead.runWithIO;
                played |> Result.mapErr(failure -> "手順が ${failure#at#number} 行目で止まった: ${failure#why}（${failure#at#text}）/ ${failure#seen}")
            })

    def writeOutcome(settings: VideoOut.Settings, env: Map[String, String], fps: Int32, take: Take, outcome: Flow.Outcome[AppState]): Int32 \ IO =
        match segmentsOf(outcome#marks) {
            case Err(why) =>
                println("[video] ${take#flow} の mark: ${why}");
                1
            case Ok(segments) =>
                let shown = segments |> List.flatMap(seg -> outcome#frames |> List.drop(fst(seg)) |> List.take(snd(seg) - fst(seg)));
                let stride = playFps() / fps;
                let painted = shown |> List.zipWithIndex |> List.filter(p -> Int32.modulo(fst(p), stride) == 0)
                    |> List.map(p -> snd(p)#step#after);
                println("[video] ${Int32.toString(List.length(segments))} 区間・${Int32.toString(List.length(painted))} コマを撮る（${Int32.toString(List.length(painted) / fps)} 秒・${Int32.toString(fps)} fps）");
                writeVideo(settings, encoderOf(env, fps, take), fps, take#outDir, painted);
                0
        }

    /// mark の in_<名前> / out_<名前> の組を、始まりのフレームの順に (始まり, 終わり) で並べる。対の無い印・逆向きの組は Err。
    def segmentsOf(marks: Map[String, Int32]): Result[String, List[(Int32, Int32)]] =
        let names = Map.keysOf(marks) |> Set.toList;
        let ins = names |> List.filterMap(n -> String.stripPrefix(substr = "in_", n));
        let outs = List.toSet(names |> List.filterMap(n -> String.stripPrefix(substr = "out_", n)));
        let lonely = ins |> List.filter(n -> not Set.memberOf(n, outs));
        let pairs = ins |> List.map(n -> (Map.getWithDefault("in_${n}", 0, marks), Map.getWithDefault("out_${n}", 0, marks)));
        if (not List.isEmpty(lonely)) Err("out_ の無い in_ ${List.join(", ", lonely)}")
        else if (List.isEmpty(pairs)) Err("in_<名前> と out_<名前> の組が 1 つも無い")
        else if (List.exists(p -> snd(p) <= fst(p), pairs)) Err("終わりが始まりより前の組がある")
        else Ok(Sort.sortStableBy(fst, pairs))

    /// GPU の道で debug/video/<名前>.mp4 を直に書く ffmpeg の旗（VIDEO_X264 は Makefile と同じ字を受ける）。
    def encoderOf(env: Map[String, String], fps: Int32, take: Take): VideoOut.Encoder =
        let x264 = Map.getWithDefault("VIDEO_X264", "-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p", env);
        let split = String.splitOn({ substr = " " }, x264) |> List.filter(part -> not String.isEmpty(part));
        // WhyNot: 拡大の -vf をそのまま渡さない — VideoOut は GL の上下を直す -vf vflip を先に置くが、ffmpeg は後の -vf だけを使うので
        //   拡大を足すと上下が逆さのまま書かれる。GL の道の旗だけ、拡大の前に vflip を足す（SoftRaster の PNG は上下が正しい）。
        let flags = split |> List.zip(List.append("" :: Nil, split)) |> List.map(e -> { let (before, part) = e; if (before == "-vf") "vflip,${part}" else part });
        { rate = Int32.toString(fps), inputs = Nil,
          outputs = List.append(flags, "-movflags" :: "+faststart" :: "${take#outDir}.mp4" :: Nil) }

    def writeVideo(settings: VideoOut.Settings, encoder: VideoOut.Encoder, fps: Int32, outDir: String, worlds: List[AppState]): Unit \ IO =
        let font = SceneRender.ttf();
        let atlas = HeadlessFont.buildUiAtlas(font, font);
        let cfg = { design = { x = World.width(), y = World.height() }, scale = 3, background = Color.rgb(0.0, 0.0, 0.0), fontTtf = font, fontAtlas = atlas,
                    outDir = outDir, frameW = 960, frameH = 720 | HeadlessRender.defaults() };
        let painter = VideoOut.writeFramesWithPasses(settings,
            { outDir = outDir, fps = fps, soft = cfg, softFonts = _ -> atlas, extraFonts = Map.empty(),
              images = Nil, scene = sceneOf, wanted = _ -> true, bakeSurfaces = false, encoders = encoder :: Nil }, planOf, worlds);
        println("[video] コマ: ${outDir}（${painter}）")

    /// 1 コマ: 3D の場面（テレビのにじみがあれば PostStack を通した面）と HUD（GPU では GL の字のアトラスで組む）。
    def sceneOf(fonts: String -> FontAtlas): AppState -> List[Render.PlacedItem] =
        Resources.read((r, w) -> {
            let ctx = App.viewCtxOf(fonts("default"), { x = World.width(), y = World.height() });
            let frame = match crtBuilt(ctx, r, w) {
                case Some(b) => b#present :: Nil
                case None    => View.frame(ctx, r, w)
            };
            List.append(frame, View.hud(ctx, r, w))
        })

    /// 先に描く Pass の計画（テレビのにじみが無ければ空）。
    def planOf(fonts: String -> FontAtlas): AppState -> Render.PassPlan =
        Resources.read((r, w) -> {
            let ctx = App.viewCtxOf(fonts("default"), { x = World.width(), y = World.height() });
            crtBuilt(ctx, r, w) |> Option.map(b -> b#plan) |> Option.getWithDefault(Render.passPlan(Nil))
        })

    def crtBuilt(ctx: App.ViewCtx, r: Res.Res, w: World.World): Option[{ plan = Render.PassPlan, present = Render.PlacedItem, issues = List[PostStack.Issue] }] =
        Game.crtStackOf(r) |> Option.map(s -> PostStack.build({ size = { x = World.width(), y = World.height() }, clear = Color.rgb(0.0, 0.0, 0.0), world = View.frame(ctx, r, w) }, s))
}
