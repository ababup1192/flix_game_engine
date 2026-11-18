// 入口（窓あり・GPU の描き手）。町が出来ていく動画を GPU で描く（HD2D_MODE=build・FLIX_GE_FRAME_SHOT でコマを書く）か、
// 出来た町を歩く場面の 1 コマの重さを測る（HD2D_MODE=bench・POST=0 で後がけなし・SHADOW=0 で太陽の影なし・区間ごとに 1 行の JSON）。
// どちらも決まったコマ数で閉じる（窓を開いたままにしない）。
use fge::LwjglLayer

mod TownGpu {
    use fge::{App, LwjglLayer, Render, Scene3d, Vec2}
    use BuildVideo.{Setup}

    import java.lang.System

    /// 描き物の大きさ（project.json の design と同じ 1280×720）。
    def size(): Vec2.Vec2 = { x = 1280.0, y = 720.0 }

    /// frame = 次に描くコマ・scene・focus・look = そのコマの場面とピントの距離と Look・grouping = 出来た物の集まりの持ち越し・
    /// progress = 重さを測る区間・finished = 閉じてよいか。
    pub type alias World = { frame = Int32, scene = Option[Scene3d.Scene3dCmd], focus = Float64, look = TownScene.Look, grouping = BuildVideo.Grouping,
                             progress = BenchRun.Run, finished = Bool }

    /// 測る段取り（頭の 60 コマを捨て、240 コマを 2 区間）。
    def plan(): BenchRun.Plan = { warmup = 60, measured = 240, segments = 2, diagnostics = true }

    /// HD2D_MODE=bench の時に回すコマ（出来上がった後から歩き終わりまでを繰り返す）。
    def benchFrame(st: Setup, k: Int32): Int32 =
        let first = (Float64.round(st#show#done * 30.0) |> Float64.tryToInt32 |> Option.getWithDefault(0)) + 30;
        let span = Int32.max(1, st#track#frames - first);
        first + Int32.modulo(k, span)

    /// FLIX_GE_FRAME_SHOT が 1 回の起動で書けるコマ数（engine の LwjglLayer.frameShotLimit と同じ）。
    // WhyNot: 1 回の起動で全部のコマを撮らない — 窓の書き出しは 1 回の起動で 64 コマまでで、それ以降は書かれない。
    def shotsPerLaunch(): Int32 = 64

    /// 1 コマ進める（場面を組み、出来た物の集まりは regroupEvery コマごとに作り直す）。
    def step(st: Setup, bench: Bool, first: Int32, knobs: List[(String, String)], frame: App.Frame, w: World): World \ IO =
        let f = if (bench) benchFrame(st, w#frame) else w#frame;
        let (grouping, loose) = BuildVideo.regroup(f, BuildVideo.settledAt(st, f), w#grouping);
        let (scene, focus) = BuildVideo.shotAt(st, _ -> (grouping#group, loose), size(), f);
        let progress = if (bench) BenchRun.advance(plan(), line -> println(line), _ -> knobs, BenchRun.sampleOf(frame, 0.0), w#progress) else w#progress;
        { frame = w#frame + 1, scene = Some(scene), focus = focus, look = BuildVideo.lookAt(st, f), grouping = grouping, progress = progress,
          finished = if (bench) progress#done else w#frame + 1 >= Int32.min(st#track#frames, first + shotsPerLaunch()) }

    /// HD2D_MODE=walk: 地図の walk の台本で歩いて止まる場面（Video.frames と同じ）を GPU で撮る（64 コマずつ）。
    def goWalk(look: TownScene.Look, first: Int32): Unit \ IO =
        let look0 = look;
        let (m, res1) = Video.loadWith(look0, true);
        let wk = Video.walkingOf(m, look0);
        let n = Party.frameCount(wk#timeline, 30);
        let step1 = (_frame: App.Frame, w: WalkWorld) -> {
            let shot = Video.shotSized(m, res1, wk, size(), Int32.toFloat64(w#frame) / 30.0);
            { frame = w#frame + 1, scene = Some(shot#scene), focus = shot#focus, finished = w#frame + 1 >= Int32.min(n, first + shotsPerLaunch()) }
        };
        println("[hd2d_town] GPU walk: コマ ${Int32.toString(n)}");
        let app0 = App.make({ frame = first, scene = None, focus = 10.0, finished = false })
            |> App.addSystem(step1)
            |> App.withView((_ctx, w) -> checked_ecast(w#scene |> Option.map(sc -> Render.scene3d(Vec2.zero(), sc)) |> Option.toList))
            |> App.quitWhen((_frame, w) -> checked_ecast(w#finished))
            |> App.withPostStack(w -> checked_ecast(TownScene.postAt(look0, w#focus, w#scene |> Option.map(sc -> sc#time) |> Option.getWithDefault(0.0), size()#x)));
        run { App.launchForBench(app0) }
            with LwjglLayer.withProject(".")
            with Fs.FileRead.runWithIO
            with Fs.FileWrite.runWithIO
            with Fs.Glob.runWithIO
            with Fs.ModificationTime.runWithFileTime
            with Fs.FileTime.runWithIO

    /// HD2D_MODE=walk の毎コマの状態。
    pub type alias WalkWorld = { frame = Int32, scene = Option[Scene3d.Scene3dCmd], focus = Float64, finished = Bool }

    /// HD2D_MODE=final の毎コマの状態。frame = 次に描く通しのコマ・shot = 直前に描いた場面の番号・flash = 着地の光（露出に足す段）・
    /// white = 白い四角の α。
    pub type alias FinalWorld = { frame = Int32, shot = Int32, scene = Option[Scene3d.Scene3dCmd], focus = Float64, look = TownScene.Look,
                                  flash = Float64, white = Float64, grouping = BuildVideo.Grouping, finished = Bool }

    /// HD2D_MODE=final の 1 コマ（場面が替わったら出来た物の集まりを捨てる）。
    def finalStep(cut: FinalCut.Cut, setups: Map[Int32, Setup], last: Int32, w: FinalWorld): FinalWorld =
        let g = w#frame;
        FinalCut.placeOf(cut, setups, g) |> Option.map(p -> {
            let (i, f, st) = p;
            let g0 = if (i == w#shot) w#grouping else BuildVideo.startGrouping(st);
            let (grouping, loose) = BuildVideo.regroup(f, BuildVideo.settledAt(st, f), g0);
            let (scene, focus) = BuildVideo.shotAt(st, _ -> (grouping#group, loose), size(), f);
            { frame = g + 1, shot = i, scene = Some(scene), focus = focus, look = BuildVideo.lookAt(st, f),
              flash = Buildup.flashAt(st#show, Int32.toFloat64(f) / Int32.toFloat64(BuildVideo.fps())), white = FinalCut.whiteAlpha(cut, g),
              grouping = grouping, finished = g + 1 >= last }
        }) |> Option.getWithDefault({ finished = true | w })

    /// HD2D_MODE=final: 通しの台本（FINAL・既定 assets/final.json）のコマ first から 64 コマを撮る（その 64 コマに要る場面だけを読む）。
    /// 白い四角は hudView に置く（後がけの外）。
    def goFinal(tweak: TownScene.Look -> TownScene.Look, first: Int32): Unit \ IO =
        let loaded = (run { FinalCut.load(FinalCut.cutPath()) } with Fs.FileRead.runWithIO)
            |> Result.flatMap(cut -> {
                let last = Int32.min(FinalCut.totalFrames(cut), first + shotsPerLaunch());
                let indices = FinalCut.shotsIn(cut, first, last - first);
                FinalCut.loadShots(cut, tweak, indices) |> Result.map(setups -> (cut, last, indices, setups))
            });
        match loaded {
            case Err(why) =>
                println("[hd2d_town] 通しの台本の場面を組めない: ${why}");
                System.exit(1)
            case Ok((cut, last, indices, setups0)) =>
                let setups = setups0 |> Map.map(st -> { show = { dustTexture = "dust" | st#show } | st });
                launchFinal(cut, last, setups, indices, first)
        }

    def launchFinal(cut: FinalCut.Cut, last: Int32, setups: Map[Int32, Setup], indices: List[Int32], first: Int32): Unit \ IO =
        let any = Map.toList(setups) |> List.head |> Option.map(snd);
        println("[hd2d_town] GPU final: 通しのコマ ${Int32.toString(first)}〜${Int32.toString(last - 1)}・読んだ場面 ${List.toString(indices)}");
        match any {
            case None     => println("[hd2d_town] 撮るコマが無い")
            case Some(st) =>
                let app0 = App.make({ frame = first, shot = -1, scene = None, focus = 10.0, look = st#res#look, flash = 0.0, white = 0.0,
                                      grouping = BuildVideo.startGrouping(st), finished = false })
                    |> App.addSystem((_frame: App.Frame, w: FinalWorld) -> finalStep(cut, setups, last, w))
                    |> App.withView((_ctx, w) -> checked_ecast(w#scene |> Option.map(sc -> Render.scene3d(Vec2.zero(), sc)) |> Option.toList))
                    |> App.withHudView((_ctx, w) -> checked_ecast(FinalCut.whiteCover(size(), w#white)))
                    |> App.quitWhen((_frame, w) -> checked_ecast(w#finished))
                    |> App.withPostStack(w -> checked_ecast(TownScene.postFlashAt(w#look, w#focus, w#scene |> Option.map(sc -> sc#time) |> Option.getWithDefault(0.0), w#flash, size()#x)));
                run { App.launchForBench(app0) }
                    with LwjglLayer.withProject(".")
                    with Fs.FileRead.runWithIO
                    with Fs.FileWrite.runWithIO
                    with Fs.Glob.runWithIO
                    with Fs.ModificationTime.runWithFileTime
                    with Fs.FileTime.runWithIO
        }

    def envOr(name: String, fallback: String): String \ IO =
        let v = System.getenv(name);
        if (Object.isNull(v) or v == "") fallback else v

    pub def go(): Unit \ IO =
        let mode = envOr("HD2D_MODE", "build");
        let bench = mode == "bench";
        let post = envOr("POST", "1") == "1";
        let shadow = envOr("SHADOW", "1") == "1";
        let look0 = run { TownLook.loadOr(Video.lookPath()) } with Fs.FileRead.runWithIO;
        let first = Int32.fromString(envOr("HD2D_FRAME_FROM", "0")) |> Option.getWithDefault(0);
        let extra = Int32.fromString(envOr("EXTRA_LAMPS", "-1")) |> Option.getWithDefault(-1);
        let fog = envOr("FOG", "");
        let charShadow = envOr("CHAR_SHADOW", "");
        let mapSize = Int32.fromString(envOr("SHADOW_MAP", "0")) |> Option.getWithDefault(0);
        let pcf = Int32.fromString(envOr("SHADOW_PCF", "-1")) |> Option.getWithDefault(-1);
        let pointShadows = Int32.fromString(envOr("POINT_SHADOWS", "-1")) |> Option.getWithDefault(-1);
        let tweak = (look2: TownScene.Look) -> {
            let look = if (shadow) look2 else { shadowMapSize = 0 | look2 };
            { billboardTextures = TownScene.BillboardTextures.ProjectTextures, extraLamps = if (extra >= 0) extra else look#extraLamps,
                      groundFog = if (fog == "0") 0.0 else look#groundFog,
                      charShadow = if (charShadow == "") look#charShadow else TownLook.charShadowOf(charShadow),
                      shadowMapSize = if (mapSize > 0) mapSize else look#shadowMapSize, shadowPcf = if (pcf >= 0) pcf else look#shadowPcf,
                      fogFar = if (fog == "0") 400.0 else look#fogFar, fogNear = if (fog == "0") 300.0 else look#fogNear,
                      pointShadows = if (pointShadows < 0) look#pointShadows
                                     else if (pointShadows == 0) None
                                     else Some({ maxShadowedLights = pointShadows | look#pointShadows |> Option.getWithDefault(Scene3d.pointShadowMap()) }) | look }
        };
        let look1 = tweak(look0);
        if (mode == "walk") goWalk(look1, first) else
        if (mode == "final") goFinal(tweak, first) else
        match BuildVideo.setup(look1, tweak) {
            case Err(why) =>
                println("[hd2d_town] 町を組めない: ${why}");
                System.exit(1)
            case Ok(st0) =>
                let st = { show = { dustTexture = "dust" | st0#show } | st0 };
                let knobs = ("bench", BenchRun.quoted("hd2d_town")) :: ("post", if (post) "1" else "0") :: ("shadow", if (shadow) "1" else "0") ::
                            ("look", BenchRun.quoted(Video.lookPath())) :: ("lights", Int32.toString(List.length(TownScene.lampLights(st#res)))) ::
                            ("ground_fog", Float64.toString(look1#groundFog)) ::
                            ("point_shadows", Int32.toString(look1#pointShadows |> Option.map(m -> m#maxShadowedLights) |> Option.getWithDefault(0))) :: Nil;
                println("[hd2d_town] GPU ${mode}: コマ ${Int32.toString(st#track#frames)}・後がけ ${if (post) "あり" else "なし"}・太陽の影 ${if (shadow) "あり" else "なし"}");
                let app0 = App.make({ frame = first, scene = None, focus = 10.0, look = look1, grouping = BuildVideo.startGrouping(st), progress = BenchRun.start(), finished = false })
                    |> App.addSystem(step(st, bench, first, knobs))
                    |> BenchRun.withDiagnostics(plan())
                    |> App.withView((_ctx, w) -> checked_ecast(w#scene |> Option.map(sc -> Render.scene3d(Vec2.zero(), sc)) |> Option.toList))
                    |> App.quitWhen((_frame, w) -> checked_ecast(w#finished));
                let flashOf = (w: World) -> Buildup.flashAt(st#show, Int32.toFloat64(w#frame - 1) / Int32.toFloat64(BuildVideo.fps()));
                let app1 = if (post) app0 |> App.withPostStack(w -> checked_ecast(TownScene.postFlashAt(w#look, w#focus, w#scene |> Option.map(sc -> sc#time) |> Option.getWithDefault(0.0), flashOf(w), size()#x))) else app0;
                run { App.launchForBench(app1) }
                    with LwjglLayer.withProject(".")
                    with Fs.FileRead.runWithIO
                    with Fs.FileWrite.runWithIO
                    with Fs.Glob.runWithIO
                    with Fs.ModificationTime.runWithFileTime
                    with Fs.FileTime.runWithIO
        }
}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else TownGpu.go()
