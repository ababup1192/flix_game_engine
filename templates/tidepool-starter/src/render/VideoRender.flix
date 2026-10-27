// VideoRender — 遊ぶ所を音つきの動画にする（依頼主に見せる 1 本）。
// 実行: make video → debug/video/tidepool.mp4（コマ・音・鳴った時刻の表・流した手順は debug/video/tidepool/）
//
// 手順は flow（Flow.play）で、キーを実機と同じ 1 フレームずつ World に流す。解き方は levels の Doc の solution から組む。
// 題名の ←→ は開いた面が要るので、全面を 1 度解いて題名へ戻った所から撮る。撮るのは題名・面 1・面 3・面 5・全面クリアの区間だけで、
// 間の面（2・4・6）も同じ手順で遊ぶが動画には入れない。
//
// 環境変数: VIDEO_FPS（既定 30）・VIDEO_SCALE（design 640×360 の何倍で描くか。既定 2 = 1280×720）・FGE_GPU / FGE_VIDEO_PAINT / FFMPEG（VideoOut.settingsOf）
mod VideoRender {
    use fge::{App, AudioMixdown, AudioMixer, Flow, FontAtlas, HeadlessFont, HeadlessRender, ProjectLoader,
              PxSpriteAtlas, Render, SfxSynth, Vec2, VideoOut}

    import java.io.File

    def outDir(): String = "debug/video/tidepool"

    def ttf(): String = "assets/ShipporiMincho-Regular.subset.ttf"

    def design(): Vec2.Vec2 = { x = World.width(), y = World.height() }

    def sampleRate(): Int32 = 22050

    /// 動画に入れる区間（mark の名前の組。始まりを含み終わりを含まない）。
    def segments(): List[(String, String)] =
        ("title", "level1_end") :: ("level3", "level3_end") :: ("level5", "level5_end") :: ("ending", "ending_end") :: Nil

    pub def frames(): Unit \ IO = App.Headless.exitWith(framesJob(App.Headless.requestFromProcess()))

    def framesJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        let settings = VideoOut.settingsOf(env);
        let fps = Map.get("VIDEO_FPS", env) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(30);
        let app = run { Game.app(Controls.loadDocs()) } with Fs.FileRead.runWithIO;
        let fresh = run { App.freshWorld(app, design()) } with Fs.FileRead.runWithIO;
        let text = scriptText(fps, LevelsDoc.rec(fresh#levels)#levels |> List.map(level -> level#solution));
        discard (new File(outDir())).mkdirs();
        discard writeText("${outDir()}/video.flow", text);
        match Flow.Parse.parseText(Flow.vocabOf(app, fresh), "video.flow", text) {
            case Err(problems) =>
                println("[video] 手順を読めない\n" + Flow.Parse.problemsText(problems));
                1
            case Ok(script) =>
                let played = run {
                    Flow.play(app, { design = design(), limit = 100000 }, script, { world = fresh, state = App.freshStepState() })
                } with Fs.FileRead.runWithIO;
                match played {
                    case Err(failure) =>
                        println("[video] 手順が ${failure#at#number} 行目で止まった: ${failure#why}（${failure#at#text}）/ ${failure#seen}");
                        1
                    case Ok(outcome) =>
                        let shown = segments() |> List.flatMap(seg -> sliceOf(outcome, seg));
                        println("[video] ${List.length(outcome#frames)} フレームを流し、${List.length(shown)} コマを撮る（${Int32.toString(List.length(shown) / fps)} 秒）");
                        writeAudio(app, fps, shown);
                        let scale = Map.get("VIDEO_SCALE", env) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(2);
                        writeVideo(settings, { fps = fps, scale = scale }, shown |> List.map(p -> p#step#after));
                        0
                }
        }

    /// 区間の mark の間のフレーム。
    def sliceOf(outcome: Flow.Outcome[World.World], seg: (String, String)): List[Flow.Played[World.World]] =
        let (startMark, endMark) = seg;
        match (Map.get(startMark, outcome#marks), Map.get(endMark, outcome#marks)) {
            case (Some(a), Some(b)) => outcome#frames |> List.drop(a) |> List.take(b - a)
            case _                  => bug!("[video] mark ${startMark} / ${endMark} が手順に無い")
        }

    // ── 手順（flow の字）──

    /// 解き方の 1 字 → 役の名前。
    def roleOf(move: Char): String = match move {
        case 'U' => "up"
        case 'D' => "down"
        case 'L' => "left"
        case 'R' => "right"
        case _   => "wait"
    }

    /// 人が考えて押す程度の間（水の動き tweenSeconds より長く、少しずつ揺らす）。
    def thinkSeconds(index: Int32): Float64 =
        Vector.get(Int32.modulo(index, 5), Vector#{0.6, 0.72, 0.55, 0.66, 0.62})

    /// 解き方を 1 手ずつ押す。holdAfter = その手の後に足す間（見せ場で止まる）。
    def solveLines(solution: String, holdAfter: Int32 -> Float64): List[String] =
        String.toList(solution) |> List.zipWithIndex |> List.flatMap(p -> {
            let (index, move) = p;
            let pause = if (move == 'W') 0.9 else thinkSeconds(index);
            "tap ${roleOf(move)}" :: "wait ${Float64.toString(pause + holdAfter(index))}" :: Nil
        })

    /// 撮らない面: 解き方を続けて押す。
    def rushLines(solution: String): List[String] =
        String.toList(solution) |> List.map(move -> "tap ${roleOf(move)}")

    /// 動画の手順の全文。solutions は面の順の解き方。
    def scriptText(fps: Int32, solutions: List[String]): String =
        let solutionOf = index -> List.drop(index, solutions) |> List.head |> Option.getWithDefault("");
        let noHold = _ -> 0.0;
        let clearHold = "expect phase=Cleared" :: "wait 3.0" :: Nil;
        let firstRun = List.range(0, List.length(solutions)) |> List.flatMap(index ->
            rushLines(solutionOf(index)) ::: "expect phase=Cleared" :: "tap confirm" :: Nil);
        let lines =
            "fps ${Int32.toString(fps)}" :: "expect screen=Title" :: "tap confirm" ::
            firstRun :::
            "expect screen=Ending" :: "tap confirm" :: "expect screen=Title" ::
            "tap left" :: "tap left" :: "tap left" :: "wait 0.4" ::
            // 題名: 面 3 から ← で面 1 を選んで始める。
            "mark title" :: "wait 1.1" :: "tap left" :: "wait 0.8" :: "tap left" :: "wait 1.0" :: "tap confirm" ::
            "expect screen=Play&level=1" :: "wait 2.0" ::
            // 面 1: 満ち潮の低い岩へ下りて流される → 取り消し → 初めから → 解き方どおり。
            "tap right" :: "wait 0.62" :: "tap right" :: "wait 0.75" :: "tap down" :: "expect phase=Washed" :: "wait 1.9" ::
            "tap undo" :: "expect phase=Playing&moves=2&col=2" :: "wait 0.9" ::
            "tap restart" :: "expect moves=0&col=0" :: "wait 1.4" ::
            solveLines(solutionOf(0), noHold) ::: clearHold ::: "mark level1_end" ::
            "tap confirm" :: rushLines(solutionOf(1)) ::: "expect phase=Cleared" :: "tap confirm" ::
            // 面 3: 流木に乗って潮を待つと、流木ごと崖の上へ上がる（乗る前の 3 手目の後で止まって見せる）。
            "expect level=3" :: "mark level3" :: "wait 2.0" ::
            solveLines(solutionOf(2), index -> if (index == 2) 1.0 else 0.0) ::: clearHold ::: "mark level3_end" ::
            "tap confirm" :: rushLines(solutionOf(3)) ::: "expect phase=Cleared" :: "tap confirm" ::
            // 面 5: 小石でせき止めた池が、引き潮でも水を残す（3 手目と 12 手目の後で止まって見せる）。
            "expect level=5" :: "mark level5" :: "wait 2.0" ::
            solveLines(solutionOf(4), index -> if (index == 2) 0.8 else if (index == 11) 1.4 else 0.0) ::: clearHold ::: "mark level5_end" ::
            "tap confirm" :: rushLines(solutionOf(5)) ::: "expect phase=Cleared" :: "wait 0.8" ::
            // 最後の面のクリアの重ねから全面クリアへ。
            "mark ending" :: "wait 1.0" :: "tap confirm" :: "expect screen=Ending" :: "wait 6.0" :: "mark ending_end" :: Nil;
        String.unlines(lines)

    // ── 音 ──

    /// 撮るコマの音（一発の音・波の環境音・ミキサーのバス）を 1 本の WAV に混ぜ、鳴った時刻の表を添える。
    def writeAudio(app: App.App[World.World, {}], fps: Int32, shown: List[Flow.Played[World.World]]): Unit \ IO =
        let rate = sampleRate();
        let loaded = run { ProjectLoader.loadProject(".") } with Fs.FileRead.runWithIO;
        let sounds = match loaded {
            case Ok(found) => found#config#soundManifest |> List.map(s -> (s#name, AudioMixdown.loadWav(rate, s#path))) |> List.toMap
            case Err(why)    => bug!("[video] project.json を読めない: ${why}")
        };
        let mixerOf = App.rec(app)#mixer;
        let mixFrames = shown |> List.map(p -> {
            let step = p#step;
            { plays = step#sounds, sustained = step#sustained,
              mixer = mixerOf |> Option.map(f -> f(step#after)) |> Option.getWithDefault(AudioMixer.defaults()) }
        });
        let samples = AudioMixdown.mixdown(rate, Int32.toFloat64(fps), sounds, mixFrames);
        SfxSynth.writeBytes("${outDir()}/audio.wav", SfxSynth.wavBytes({ sampleRate = rate }, Vector.toList(samples)));
        let table = shown |> List.zipWithIndex |> List.flatMap(p -> {
            let (index, played) = p;
            let at = Float64.round(Int32.toFloat64(index) / Int32.toFloat64(fps) * 1000.0) / 1000.0;
            played#step#sounds |> List.map(name -> "${Float64.toString(at)}\t${Int32.toString(index)}\t${name}")
        });
        discard writeText("${outDir()}/sfx.txt", String.unlines("# 秒\tコマ\t音" :: table));
        println("[video] 音: ${outDir()}/audio.wav（一発の音 ${List.length(table)} 回）・時刻の表 ${outDir()}/sfx.txt")

    // ── 絵 ──

    def writeVideo(settings: VideoOut.Settings, size: { fps = Int32, scale = Int32 }, worlds: List[World.World]): Unit \ IO =
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        let first = match List.head(worlds) {
            case Some(w) => w
            case None    => bug!("[video] 撮るコマが無い")
        };
        let images = PxSpriteAtlas.asImages({ texture = World.atlasName(), baked = first#atlas } :: Nil);
        // なめらかな絵なので面の縁もならす（SceneRender と同じ設定）。
        let soft = { design = design(), scale = size#scale, background = ThemeDoc.rec(first#theme)#bg,
                     fontTtf = ttf(), fontAtlas = atlas, outDir = outDir(),
                     frameW = 640 * size#scale, frameH = 360 * size#scale,
                     texturePath = HeadlessRender.imagePngs("debug", images),
                     shapeAntialias = true | HeadlessRender.defaults() };
        let painter = VideoOut.writeFrames(settings,
            { outDir = outDir(), fps = size#fps, soft = soft, softFonts = _ -> atlas, extraFonts = Map.empty(),
              images = images, scene = sceneOf, wanted = _ -> true, bakeSurfaces = false, encoders = Nil },
            worlds);
        println("[video] コマ: ${outDir()}（${painter}）")

    /// 1 コマの絵。実機は静的な層（View.frameBorder）を別に敷くので、同じ物を足して並べる。
    def sceneOf(fonts: String -> FontAtlas): World.World -> List[Render.PlacedItem] =
        w -> List.append(View.frame(App.viewCtxOf(fonts("default"), design()), w), View.frameBorder(w#theme))

    def writeText(path: String, text: String): Bool \ IO =
        run { Fs.WriteFile.write({str = text}, path) |> Result.isOk } with Fs.WriteFile.runWithFileWrite with Fs.FileWrite.runWithIO
}
