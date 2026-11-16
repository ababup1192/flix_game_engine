// FlowVideo — e2e/<名前>.flow を実機と同じ 1 フレーム（Flow.play）で流し、動画のコマと音に描き出す。
// 実行: make video FLOW=e2e/showcase.flow → debug/video/showcase.mp4（mp4 に束ねるのは Makefile の ffmpeg）
//
// 書く物（FLOW_OUT。既定は debug/video/<名前>）:
//   f0000.png …（SoftRaster）か frames.mkv（GPU）・drawhash.txt・frames.json … エンジンの VideoOut が書く
//   audio.f64 … 左右 2 本の 44.1kHz の音（64bit 浮動小数・ビッグエンディアン・左右交互）。
//               実機と同じミキサー（Controls.mixerOf）で、そのフレームに鳴った音と鳴り続ける環境音を AudioMixdown が混ぜる。
//   fps.txt   … コマの速さ（flow の fps）
//   tape.json … テープの頁が読むシナリオ・シーン・音・問いの流れ（TapeOut。同じ名前の mark・2 つ以上の .yarn にまたがる flow では書かずに理由を出す）
//
// MIGRATE_OUT=<フォルダ> の時は、移行の突き合わせ（bin/fge migrate diff）の記録もそこへ書く（MigrateOut）:
//   tape.json   … 上の tape.json に events・buses（ミキサーにバスがある時）・frames・ranLines・screen を足した物
//   frames/world/f0000.png … world の層だけのコマ（台詞を出し終えた所と時間を取る命令の途中）、frames/all/ … 全部の層のコマ（台詞を出し終えた所）
//   saves.json  … flow の終わりのセーブデータ（枠が 1 つでもあれば。restore が読み戻す古いセーブ）
// restore（make migrate-baseline が呼ぶ）は MIGRATE_SAVE の saves.json の枠を 1 つずつ読み戻し、MIGRATE_OUT/<MIGRATE_NAME>-<枠>/restore.json に書く。
mod FlowVideo {
    use fge::{App, AudioMixdown, DocJson, Emit, Flow, FontAtlas, GpuShot, HeadlessLoad, JsonCodec, Rect2, Render, Resources, Vec2, VideoOut}

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
        App.Headless.videoJob("FlowVideo", "play", req -> playJob(req)) ::
        App.Headless.videoJob("FlowVideo", "restore", req -> restoreJob(req)) :: Nil

    /// 終了コード: 0 = 撮れた・1 = flow が途中で止まった（そこまでは書く）・2 = flow を読めない・移行の記録を書けない（MIGRATE_OUT の時）。
    pub def playJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        // WhyNot: 設定を字の用意より後に作らない —— GPU で塗る回は AWT より先に GL へ繋ぐ必要がある（VideoOut.settingsOf）。
        let settings = VideoOut.settingsOf(env);
        let path = Map.getWithDefault("FLOW", "", env);
        let out = Map.getWithDefault("FLOW_OUT", "debug/video/${nameOf(path)}", env);
        let migrate = Map.get("MIGRATE_OUT", env) |> Option.filter(dir -> not String.isEmpty(dir));
        let design = SceneRender.design();
        let played = run {
            let app = appOf();
            let fresh = App.freshWorld(app, design);
            match Flow.Parse.parseFile(Flow.vocabOf(app, fresh), path, Flow.Cli.readText) {
                case Err(problems) => Err(Flow.Parse.problemsText(problems))
                case Ok(script)    =>
                    let start = { world = Flow.Cli.startWorld(app, design, fresh, script), state = App.freshStepState() };
                    Ok((script, Flow.play(app, { design = design, limit = frameCapOf(env, script) }, script, start)))
            }
        } with Fs.FileRead.runWithIO;
        match played {
            case Err(why) => println("FAIL ${path} を読めない\n${why}"); 2
            case Ok((script, Ok(outcome))) =>
                write(settings, design, script#fps, out, outcome);
                writeTape(design, path, script, out, outcome);
                let recorded = migrate |> Option.forAll(dir -> writeMigrate(settings, design, path, script, dir, outcome));
                println("rendered: ${out} (${Int32.toString(List.length(outcome#frames))} frames)");
                if (recorded) 0 else 2
            case Ok((script, Err(failure))) =>
                write(settings, design, script#fps, out, failure#upTo);
                writeTape(design, path, script, out, failure#upTo);
                discard (migrate |> Option.forAll(dir -> writeMigrate(settings, design, path, script, dir, failure#upTo)));
                println("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: ${failure#why}");
                println("    ${failure#at#text}");
                1
        }

    /// e2e と同じ App で、セーブの日時だけ描き出しと同じ「起動した時刻」に据える（e2e の 0 のままだと 1970/01/01 と出る）。
    /// ゲームの後から届く素材（GameBoot.loadAssets）も全部読んでから流す（動画とテープに 3D の背景も写す）。
    def appOf(): App.App[AppState, {}] \ {Fs.FileRead, IO} =
        let res = loadRes();
        Game.app(res, Saves.fresh(res#kind), Shots.clockBase())

    def loadRes(): Res.Res \ {Fs.FileRead, IO} =
        let loaded = Controls.loadRes();
        Res.withGame(HeadlessLoad.handle(() -> GameBoot.loadAssets(loaded#game)), loaded)

    /// 撮るコマの上限。環境変数 FLOW_FRAME_CAP（正の整数）があればその数、無ければ flow の手から決めた数（frameBudgetOf）。
    def frameCapOf(env: Map[String, String], script: Flow.Script): Int32 =
        Map.get("FLOW_FRAME_CAP", env) |> Option.flatMap(Int32.fromString) |> Option.filter(n -> n > 0)
            |> Option.getWithDefault(frameBudgetOf(script))

    /// flow を最後まで流すのに要るフレームの数の上限: 手ごとに取りうる秒（wait と hold の長さ・until と drive の max・
    /// tap と hold の前に入力を受けられるまで待つ秒）を足して fps を掛け、手の数だけフレームを足す。
    // WhyNot: 決めた数にしない — flow の長さは flow ごとに違い、長い flow では上限が先に当たって途中で止まる。
    pub def frameBudgetOf(script: Flow.Script): Int32 =
        let seconds = script#lines |> List.foldLeft((sum, line) -> sum + stepSeconds(script#fps, line#step), 0.0);
        let frames = Float64.ceil(seconds * script#fps) |> Float64.tryToInt32 |> Option.getWithDefault(Int32.maxValue() / 2);
        frames + List.length(script#lines) + 1

    /// 手 1 つが取りうる一番長い秒（フレームを使わない手は 0）。
    def stepSeconds(fps: Float64, step: Flow.Step): Float64 = match step {
        case Flow.Step.Wait(span, _)          => spanSeconds(fps, span)
        case Flow.Step.Tap(_, _)              => readyWaitSeconds()
        case Flow.Step.Hold(_, Some(span), _) => readyWaitSeconds() + spanSeconds(fps, span)
        case Flow.Step.Hold(_, None, _)       => readyWaitSeconds()
        case Flow.Step.Until(_, max)          => max
        case Flow.Step.Drive(_, _, max)       => max
        case _                                => 0.0
    }

    def spanSeconds(fps: Float64, span: Flow.Span): Float64 = match span {
        case Flow.Span.Secs(s)   => s
        case Flow.Span.Frames(n) => if (fps > 0.0) Int32.toFloat64(n) / fps else 0.0
    }

    /// tap と hold の前に、入力を受けられるまで Flow.play が待つ秒の上限。
    def readyWaitSeconds(): Float64 = 10.0

    def write(settings: VideoOut.Settings, design: Vec2.Vec2, fps: Float64, out: String, outcome: Flow.Outcome[AppState]): Unit \ IO =
        discard (new File(out)).mkdirs();
        let rate = Float64.tryToInt32(Float64.round(fps)) |> Option.getWithDefault(30);
        writeText("${out}/fps.txt", Int32.toString(rate));
        writeAudio("${out}/audio.f64", fps, outcome);
        let cfg = SceneRender.cfgOf(design, out, SceneRender.texturesOf());
        let video = { outDir = out, fps = rate, soft = cfg, softFonts = _ -> cfg#fontAtlas, extraFonts = Map.empty(),
                      images = Nil, scene = fonts -> h -> sceneOf(design, fonts, h), wanted = _ -> true, bakeSurfaces = false,
                      encoders = Nil };
        discard VideoOut.writeFrames(settings, video, Flow.worldsOf(outcome))

    /// tape.json（flow が途中で止まった時もそこまで）。書けない理由（同じ名前の mark・2 つ以上の .yarn にまたがる）は 1 行出す。
    def writeTape(design: Vec2.Vec2, path: String, script: Flow.Script, out: String, outcome: Flow.Outcome[AppState]): Unit \ IO =
        writeTapeWith(design, Map.empty(), path, script, out, outcome)

    def writeTapeWith(design: Vec2.Vec2, extra: Map[String, Util.Json.Json], path: String, script: Flow.Script, out: String, outcome: Flow.Outcome[AppState]): Unit \ IO =
        let marks = script#lines |> List.filterMap(line -> match line#step {
            case Flow.Step.Mark(name) => Some(name)
            case _                    => None
        });
        let flowRun = { game = (new File(".")).getCanonicalFile().getName(), flow = path, fps = script#fps, design = design,
                        marks = marks, outcome = outcome };
        match TapeOut.toJsonWith(extra, tapeTable(design, outcome#last), flowRun) {
            case Ok(text) => writeText("${out}/tape.json", text)
            case Err(why) => println("tape: ${why}（${out}/tape.json は書かない）")
        }

    // ── 移行の突き合わせの記録（MIGRATE_OUT） ──

    /// 台詞ごとと読み戻した直後に載せる決まった問い（物語の動きに効く物。行の番号・カーソル・出し終えたかは版で替わるか、いつも同じなので載せない）。
    /// ゲームの問い（GameE2e.probes）は全部載せる。シナリオの変数は MigrateOut.probeRowsOf が全部足す。
    def migrateProbes(): List[String] =
        ("phase" :: "panel" :: "talk" :: "mode" :: "photo" :: "logSize" :: "gate" :: "choice" :: Nil) ::: (GameE2e.probes() |> List.map(row -> row#name))

    /// 移行の記録を dir に書く（tape.json・コマの PNG・セーブデータ）。問いが組めずに書かなかった時は false。
    def writeMigrate(settings: VideoOut.Settings, design: Vec2.Vec2, path: String, script: Flow.Script, dir: String, outcome: Flow.Outcome[AppState]): Bool \ IO =
        match MigrateOut.probeRowsOf(migrateProbes(), outcome#last#resources#dialogue) {
            case Err(why)   => println("migrate: ${why}（${dir} は書かない）"); false
            case Ok(probes) => writeMigrateWith(settings, design, probes, path, script, dir, outcome); true
        }

    def writeMigrateWith(settings: VideoOut.Settings, design: Vec2.Vec2, probes: List[MigrateOut.ProbeRow], path: String, script: Flow.Script, dir: String,
                         outcome: Flow.Outcome[AppState]): Unit \ IO =
        discard (new File(dir)).mkdirs();
        let fps = script#fps;
        let record = MigrateOut.recordOf(fps, probes, outcome#frames);
        let sounds = loadSounds(soundFiles(), Map.empty());
        let lengthOf = name -> Map.get(name, sounds) |> Option.map(st -> Int32.toFloat64(Vector.length(st#left)) / Int32.toFloat64(sampleRate())) |> Option.getWithDefault(0.0);
        shootFrames(settings, design, fps, dir, record#shots, Flow.worldsOf(outcome));
        let fields = Map#{ "events" => Util.Json.Json.JArray(List.toVector(record#events)),
                           "frames" => MigrateOut.framesJson(fps, record#shots),
                           "ranLines" => MigrateOut.ranLinesJson(MigrateOut.ranLinesOf(outcome#frames)),
                           "screen" => MigrateOut.screenJson(design) };
        let extra = MigrateOut.busesJson(fps, lengthOf, outcome#frames) |> Option.map(b -> Map.insert("buses", b, fields)) |> Option.getWithDefault(fields);
        writeTapeWith(design, extra, path, script, dir, outcome);
        let saves = outcome#last#world#saves;
        if (Saves.hasAny(saves)) writeText("${dir}/saves.json", Util.Json.toPrettyString(2, Saves.toJson(saves)) + "\n") else ()

    /// 予定のコマを層ごとのフォルダ（dir/frames/<層>）に SoftRaster で塗る（f<フレームの番号>.png）。
    // WhyNot: GPU で塗らない — 全部のフレームを選んだ時の GPU の道は PNG でなく frames.mkv を書き、tape.json の file が指す絵が無くなる。
    def shootFrames(settings: VideoOut.Settings, design: Vec2.Vec2, fps: Float64, dir: String, shots: List[MigrateOut.Shot], worlds: List[AppState]): Unit \ IO =
        let soft = { gpu = GpuShot.Mode.Off, gl = None | settings };
        let rate = Float64.tryToInt32(Float64.round(fps)) |> Option.getWithDefault(30);
        (MigrateOut.Layer.WorldLayer :: MigrateOut.Layer.AllLayers :: Nil) |> List.forEach(layer -> {
            let wanted = shots |> List.filter(shot -> shot#layer == layer) |> List.map(shot -> shot#frame) |> List.toSet;
            if (Set.isEmpty(wanted)) ()
            else {
                let out = "${dir}/frames/${MigrateOut.layerName(layer)}";
                let cfg = SceneRender.cfgOf(design, out, SceneRender.texturesOf());
                let video = { outDir = out, fps = rate, soft = cfg, softFonts = _ -> cfg#fontAtlas, extraFonts = Map.empty(),
                              images = Nil, scene = fonts -> h -> layerSceneOf(design, layer, fonts, h), wanted = i -> Set.memberOf(i, wanted),
                              bakeSurfaces = false, encoders = Nil };
                discard VideoOut.writeFrames(soft, video, worlds)
            }
        })

    def layerSceneOf(design: Vec2.Vec2, layer: MigrateOut.Layer, fonts: String -> FontAtlas, h: AppState): List[Render.PlacedItem] = match layer {
        case MigrateOut.Layer.AllLayers  => sceneOf(design, fonts, h)
        case MigrateOut.Layer.WorldLayer =>
            let ctx = App.viewCtxOf(fonts(""), design);
            App.composeScene(None, 1.0, design, { world = Resources.view(View.worldLayer, ctx, h), hud = Nil })
    }

    /// 古いセーブ（MIGRATE_SAVE の saves.json）の枠を 1 つずつ読み戻し、MIGRATE_OUT/<MIGRATE_NAME>-<枠>/ に restore.json とコマを書く。
    /// 終了コード: 0 = 書けた・2 = セーブを読めない。
    pub def restore(): Unit \ IO = App.Headless.exitWith(restoreJob(App.Headless.requestFromProcess()))

    pub def restoreJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        let settings = VideoOut.settingsOf(Map.insert("FGE_GPU", "off", env));
        let file = Map.getWithDefault("MIGRATE_SAVE", "", env);
        let out = Map.getWithDefault("MIGRATE_OUT", "debug/migrate/saves", env);
        let prefix = Map.getWithDefault("MIGRATE_NAME", nameOf(file), env);
        let design = SceneRender.design();
        let (fresh, parsed) = run { (App.freshWorld(appOf(), design), DocJson.readJson(file)) } with Fs.FileRead.runWithIO;
        match (parsed, MigrateOut.probeRowsOf(migrateProbes(), fresh#resources#dialogue)) {
            case (Err(_), _)       => println("FAIL ${file} を読めない"); 2
            case (_, Err(why))     => println("FAIL ${why}"); 2
            case (Ok(json), Ok(probes)) =>
                let saves = Saves.fromJson(fresh#world#saves, json);
                let loaded = Resources.of(fresh#resources, { saves = saves | fresh#world });
                Saves.tabs() |> List.forEach(tab -> List.range(0, Saves.perPage()) |> List.forEach(i ->
                    if (Option.isEmpty(Saves.slotOf(tab, i, saves))) ()
                    else restoreSlot(settings, design, probes, "${out}/${prefix}-${slotName(tab, i)}", "${prefix}-${slotName(tab, i)}", tab, i, loaded)));
                0
        }

    /// 枠の名前（auto0・quick0・n1-0）。
    def slotName(tab: Saves.Tab, i: Int32): String = match tab {
        case Saves.Tab.Auto        => "auto${i}"
        case Saves.Tab.Quick       => "quick${i}"
        case Saves.Tab.Numbered(n) => "n${n}-${i}"
    }

    def restoreSlot(settings: VideoOut.Settings, design: Vec2.Vec2, probes: List[MigrateOut.ProbeRow], dir: String, name: String, tab: Saves.Tab, i: Int32,
                    loaded: AppState): Unit \ IO =
        let res = loaded#resources;
        let (w, _) = Emit.collect(() -> WorldSaves.loadFrom(res, tab, i, loaded#world));
        let h = Resources.of(res, w);
        let node = World.talkNodeOf(w);
        let seq = MigrateOut.restoredSeqOf(w);
        let shots = { frame = 0, node = node, seq = seq, mid = None, layer = MigrateOut.Layer.WorldLayer } ::
                    { frame = 0, node = node, seq = seq, mid = None, layer = MigrateOut.Layer.AllLayers } :: Nil;
        discard (new File(dir)).mkdirs();
        shootFrames(settings, design, 30.0, dir, shots, h :: Nil);
        let objects = TapeOut.spansOf(30.0, design, objectsOf(SceneRender.fitOf(design, res), res, w) :: Nil);
        writeText("${dir}/restore.json", MigrateOut.restoreJson(name, probes, design, node, seq, h, shots, objects));
        println("restored: ${dir}")

    /// テープに渡すこのゲームの表。題名は project.json、UI の返事の音（ui_）は載せない、メッセージウィンドウは design の画面の ADV のウィンドウ（NVL の間は重ねない）。
    def tapeTable(design: Vec2.Vec2, h: AppState): TapeOut.Table \ IO =
        let fit = SceneRender.fitOf(design, h#resources);
        { title = projectTitle(),
          sceneNames = Map#{ "title" => "タイトル", "station" => "無人の駅", "clear" => "頁をめくる" },
          soundLabels = Map#{ "amb_evening" => "夕方の環境音", "amb_night" => "夜の環境音", "amb_river" => "川の環境音",
                              "amb_morning" => "朝の環境音", "se_slap" => "背中を叩く", "se_furin" => "風鈴" },
          hiddenSounds = soundFiles() |> List.map(match (name, _, _) -> name) |> List.filter(String.startsWith({prefix = "ui_"})) |> List.toSet,
          msg = advMsg(fit, h),
          probes = "phase" :: "mode" :: "photo" :: "logSize" :: Nil,
          probeNames = Map#{ "phase" => "場面", "mode" => "出し方", "photo" => "背景", "logSize" => "ログ" },
          playUrl = "",
          objects = h1 -> objectsOf(SceneRender.fitOf(design, h1#resources), h1#resources, h1#world) }

    /// 画面に出ている物（テープの頁の「物を選ぶ」）。タイトルは題字とメニュー、読む間は背景・立ち絵と小物・メッセージウィンドウ・選択肢・クイックメニュー。
    /// 置き場は View と同じ Layout・Cast の関数から引く（描いた所と枠がずれない）。
    pub def objectsOf(fit: Layout.Fit, res: Res.Res, w: World.World): List[TapeOut.ScreenObject] = objectsUsing(GameView.objects, fit, res, w)

    /// objectsOf の、ゲームの物を game から引く形（テストが差し替える）。ゲームの物は読んでいる間の背景・立ち絵の後ろに並べる。
    pub def objectsUsing(game: (View.Env, World.Read) -> List[TapeOut.ScreenObject], fit: Layout.Fit, res: Res.Res, w: World.World): List[TapeOut.ScreenObject] =
        let thing = (id, name, r) -> { id = id, name = name, rect = r };
        match w#scene {
            case World.Scene.Title(_) =>
                let count = List.length(WorldMenu.titleItems());
                let top = Layout.titleHeadingY(fit);
                thing("title_logo", "題字", rectOf(Layout.width(fit) * 0.2, top, Layout.width(fit) * 0.6, Layout.titleSubtitleY(fit) + 22.0 - top)) ::
                thing("title_menu", "タイトルのメニュー", boxOf(List.range(0, count) |> List.map(i -> Layout.titleItem(fit, i, count)))) :: Nil
            case World.Scene.Credits(_, _) => thing("credits", "クレジット", Layout.screen(fit)) :: Nil
            case World.Scene.Reading(r) =>
                let backdrop = Stage.shownShot(res#backdrops, r#stage) |> Option.map(shot -> {
                    let label = BackdropDoc.photoOf(shot#photo, res#backdrops) |> Option.map(p -> p#label) |> Option.filter(l -> not String.isEmpty(l));
                    thing("backdrop", "背景（${Option.getWithDefault(shot#photo, label)}）", Layout.screen(fit))
                }) |> Option.toList;
                let castEnv = { doc = res#cast, fit = fit, storyNow = World.now(w), realNow = w#realNow, missing = res#missing, light = Cast.steadyLight(Cast.plainTone()),
                               props = r#stage#props, photo = Stage.shownShot(res#backdrops, r#stage) |> Option.map(s -> s#photo), backdropShift = 0.0 };
                let cast = Cast.placedOf(castEnv, r#stage#cast) |> List.map(p -> thing(p#figure#name, if (String.isEmpty(p#label)) p#figure#name else p#label, p#rect));
                let hud = if (View.coversScreen(w#panel) or w#panel == World.Panel.Hidden) Nil else readingHud(fit, res, r);
                List.flatten(backdrop :: cast :: game(View.envOf(fit, res, w), r) :: hud :: Nil)
        }

    def readingHud(fit: Layout.Fit, res: Res.Res, r: World.Read): List[TapeOut.ScreenObject] =
        let choiceCount = List.length(r#choices);
        let buttonCount = List.length(WorldMenu.buttonsOf(fit));
        let message = if (Layout.isPortrait(fit)) Layout.page(fit, choiceCount)
            else match snd(Stage.windowOf(res#theme, r#stage)) {
                case w if w#kind == ThemeDoc.WindowKind.Adv => Layout.advPanelAt(fit, w#place)
                case _ =>
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

    /// 並べ方の組 fit の ADV のウィンドウの寸法を画面の割合に（Layout と novel.kind.json から導く。縦の画面は頁）。
    def advMsg(fit: Layout.Fit, h: AppState): TapeOut.Msg =
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
    def sceneOf(design: Vec2.Vec2, fonts: String -> FontAtlas, h: AppState): List[Render.PlacedItem] =
        let ctx = App.viewCtxOf(fonts(""), design);
        App.composeScene(None, 1.0, design, { world = Resources.view(View.frame, ctx, h), hud = Resources.view(View.hud, ctx, h) })

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
