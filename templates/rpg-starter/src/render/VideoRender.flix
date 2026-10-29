// VideoRender — 1 周を縮めた紹介の動画を、画面なしで音つきで書く。
// 実行: make video → debug/video/rune.mp4（コマ・音・鳴った時刻の表は debug/video/rune/）
//
// 手順は e2e/video.flow（e2e と同じ flow の実行器）で、キーを実機と同じ 1 フレームずつ World に流す。撮るのは手順の mark in_<名前> から
// out_<名前> までの区間だけで、並んだ順につなぐ（間の手も流すが動画に入れない）。手順は 60 fps で流し、VIDEO_FPS ごとに間引いて描く。
//
// 環境変数: VIDEO_FPS（既定 30。60 を割り切る数）・VIDEO_SCALE（design 256×240 の何倍で描くか。既定 3 = 768×720）・
//           FGE_GPU / FGE_VIDEO_PAINT / FFMPEG（VideoOut.settingsOf）
mod VideoRender {
    use fge::{App, AudioMixdown, AudioMixer, Flow, FontAtlas, HeadlessFont, HeadlessRender, ProjectLoader,
              PxSpriteAtlas, Render, Resources, SfxSynth, VideoOut}

    import java.io.File
    import java.nio.file.{Files, Paths}

    /// App の w（描く元と World の組）。
    type alias AppState = Resources.With[Res.Res, World.World]

    def outDir(): String = "debug/video/rune"

    def flowPath(): String = "e2e/video.flow"

    /// 手順を流す速さ（e2e/video.flow の fps と同じ。音はこの刻みで混ぜる）。
    def playFps(): Int32 = 60

    def sampleRate(): Int32 = 44100

    pub def frames(): Unit \ IO = App.Headless.exitWith(framesJob(App.Headless.requestFromProcess()))

    def framesJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        let settings = VideoOut.settingsOf(env);
        let fps = Map.get("VIDEO_FPS", env) |> Option.flatMap(Int32.fromString)
            |> Option.filter(n -> n > 0 and Int32.modulo(playFps(), n) == 0) |> Option.getWithDefault(30);
        let scale = Map.get("VIDEO_SCALE", env) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(3);
        let app = run { Game.app(Res.loadDocs(), None) } with Fs.FileRead.runWithIO;
        let fresh = run { App.freshWorld(app, WindowView.design()) } with Fs.FileRead.runWithIO;
        discard (new File(outDir())).mkdirs();
        match playFlow(app, fresh, Files.readString(Paths.get(flowPath()))) {
            case Err(why) =>
                println("[video] ${why}");
                1
            case Ok(outcome) => writeOutcome(settings, app, { fps = fps, scale = scale }, outcome)
        }

    /// 手順（flow の文）を読んで、まっさらな World から流す。読めない・途中で止まった時は、その訳の 1 行。
    def playFlow(app: App.App[AppState, {}], fresh: AppState, text: String): Result[String, Flow.Outcome[AppState]] \ IO =
        Flow.Parse.parseText(Flow.vocabOf(app, fresh), flowPath(), text)
            |> Result.mapErr(problems -> "手順を読めない\n" + Flow.Parse.problemsText(problems))
            |> Result.flatMap(script -> {
                let played = run {
                    Flow.play(app, { design = WindowView.design(), limit = 100000 }, script, { world = fresh, state = App.freshStepState() })
                } with Fs.FileRead.runWithIO;
                played |> Result.mapErr(failure -> "手順が ${failure#at#number} 行目で止まった: ${failure#why}（${failure#at#text}）/ ${failure#seen}")
            })

    def writeOutcome(settings: VideoOut.Settings, app: App.App[AppState, {}], size: { fps = Int32, scale = Int32 },
                     outcome: Flow.Outcome[AppState]): Int32 \ IO =
        match segmentsOf(outcome#marks) {
            case Err(why) =>
                println("[video] ${flowPath()} の mark: ${why}");
                1
            case Ok(segments) =>
                let shown = segments |> List.flatMap(seg -> outcome#frames |> List.drop(fst(seg)) |> List.take(snd(seg) - fst(seg)));
                let stride = playFps() / size#fps;
                let painted = shown |> List.zipWithIndex |> List.filter(p -> Int32.modulo(fst(p), stride) == 0)
                    |> List.map(p -> snd(p)#step#after);
                println("[video] ${List.length(outcome#frames)} フレームを流し、${List.length(segments)} 区間・${List.length(painted)} コマを撮る（${Int32.toString(List.length(painted) / size#fps)} 秒）");
                writeAudio(app, shown);
                writeVideo(settings, size, painted);
                0
        }

    /// mark の in_<名前> / out_<名前> の組を、始まりのフレームの順に (始まり, 終わり) で並べる。
    /// 対の無い mark・終わりが始まりより前の組は Err（黙って区間を落とすと動画が短くなったことに気付けない）。
    def segmentsOf(marks: Map[String, Int32]): Result[String, List[(Int32, Int32)]] =
        let names = Map.keysOf(marks) |> Set.toList;
        let ins = names |> List.filterMap(n -> String.stripPrefix(substr = "in_", n));
        let outs = names |> List.filterMap(n -> String.stripPrefix(substr = "out_", n));
        let inSet = List.toSet(ins);
        let outSet = List.toSet(outs);
        let lonely = List.append(ins |> List.filter(n -> not Set.memberOf(n, outSet)) |> List.map(n -> "in_${n}"),
                                 outs |> List.filter(n -> not Set.memberOf(n, inSet)) |> List.map(n -> "out_${n}"));
        let pairs = ins |> List.map(n -> (Map.getWithDefault("in_${n}", 0, marks), Map.getWithDefault("out_${n}", 0, marks)));
        let backwards = pairs |> List.filter(p -> snd(p) <= fst(p));
        if (not List.isEmpty(lonely)) Err("対の無い印 ${List.join(", ", lonely)}")
        else if (List.isEmpty(pairs)) Err("in_<名前> と out_<名前> の組が 1 つも無い")
        else if (not List.isEmpty(backwards)) Err("終わりが始まりより前の組がある")
        else Ok(List.sortBy(fst, pairs))

    // ── 音 ──

    /// 撮る区間の音（一発の音・曲・ミキサーのバス）を 1 本の WAV に混ぜ、鳴った時刻の表を添える。
    def writeAudio(app: App.App[AppState, {}], shown: List[Flow.Played[AppState]]): Unit \ IO =
        let rate = sampleRate();
        let loaded = run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO;
        let manifest = match loaded {
            case Ok(found) => found#config#soundManifest
            case Err(why)  => bug!("[video] project.json を読めない: ${why}")
        };
        let sounds = manifest |> List.map(s -> (s#name, AudioMixdown.loadWav(rate, s#path))) |> List.toMap;
        let loopStarts = manifest |> List.filterMap(s -> AudioMixdown.loadLoopStart(rate, s#path) |> Option.map(at -> (s#name, at))) |> List.toMap;
        let mixerOf = App.rec(app)#mixer;
        let mixFrames = shown |> List.map(p -> {
            let step = p#step;
            { plays = step#sounds, sustained = step#sustained,
              mixer = mixerOf |> Option.map(f -> f(step#after)) |> Option.getWithDefault(AudioMixer.defaults()) }
        });
        let samples = AudioMixdown.mixdownLooped(rate, Int32.toFloat64(playFps()), sounds, loopStarts, mixFrames);
        SfxSynth.writeBytes("${outDir()}/audio.wav", SfxSynth.wavBytes({ sampleRate = rate }, Vector.toList(samples)));
        let table = shown |> List.zipWithIndex |> List.flatMap(p -> {
            let (index, played) = p;
            let at = Float64.round(Int32.toFloat64(index) / Int32.toFloat64(playFps()) * 1000.0) / 1000.0;
            played#step#sounds |> List.map(name -> "${Float64.toString(at)}\t${Int32.toString(index)}\t${name}")
        });
        writeText("${outDir()}/sfx.txt", String.unlines("# 秒\tフレーム\t音" :: table));
        println("[video] 音: ${outDir()}/audio.wav（一発の音 ${List.length(table)} 回）・時刻の表 ${outDir()}/sfx.txt")

    // ── 絵 ──

    def writeVideo(settings: VideoOut.Settings, size: { fps = Int32, scale = Int32 }, worlds: List[AppState]): Unit \ IO =
        let ttf = SceneRender.ttf();
        let atlas = HeadlessFont.buildUiAtlas(ttf, ttf);
        let first = match List.head(worlds) {
            case Some(w) => w
            case None    => bug!("[video] 撮るコマが無い")
        };
        let res = Resources.read((r, _) -> r, first);
        let images = PxSpriteAtlas.asImages(Res.atlases(res));
        let design = WindowView.design();
        // ドット絵なので面の縁も字の縁もならさない（SceneRender と同じ設定）。
        let soft = { design = design, scale = size#scale, background = Palette.resolve(res#palette, "ink"),
                     fontTtf = ttf, fontAtlas = atlas, outDir = outDir(),
                     frameW = pixels(design#x, size#scale), frameH = pixels(design#y, size#scale),
                     texturePath = HeadlessRender.imagePngs("debug", images),
                     shapeAntialias = false, textAntialias = false | HeadlessRender.defaults() };
        let painter = VideoOut.writeFrames(settings,
            { outDir = outDir(), fps = size#fps, soft = soft, softFonts = _ -> atlas, extraFonts = Map.empty(),
              images = images, scene = sceneOf, wanted = _ -> true, bakeSurfaces = false, encoders = Nil },
            worlds);
        println("[video] コマ: ${outDir()}（${painter}）")

    /// design の長さ（Float64）を scale 倍した画素の数。
    def pixels(length: Float64, scale: Int32): Int32 =
        Option.getWithDefault(0, Float64.tryToInt32(length)) * scale

    /// 1 コマの絵（描き出しと同じ: タイル層・カメラを掛けた world・HUD）。
    def sceneOf(fonts: String -> FontAtlas): AppState -> List[Render.PlacedItem] =
        Resources.read((res, w) -> SceneRender.worldItems(App.viewCtxOf(fonts("default"), WindowView.design()), res, w))

    /// 文字を書く。書けなければ 1 行言って続ける（時刻の表は動画の添え物）。
    def writeText(path: String, text: String): Unit \ IO =
        let written = run { Fs.WriteFile.write({str = text}, path) } with Fs.WriteFile.runWithFileWrite with Fs.FileWrite.runWithIO;
        match written {
            case Ok(_)    => ()
            case Err(why) => println("[video] ${path} を書けない: ${why}")
        }
}
