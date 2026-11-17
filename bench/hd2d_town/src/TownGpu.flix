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

    /// frame = 次に描くコマ・scene・focus = そのコマの場面とピントの距離・grouping = 出来た物の集まりの持ち越し・
    /// progress = 重さを測る区間・finished = 閉じてよいか。
    pub type alias World = { frame = Int32, scene = Option[Scene3d.Scene3dCmd], focus = Float64, grouping = BuildVideo.Grouping,
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
        { frame = w#frame + 1, scene = Some(scene), focus = focus, grouping = grouping, progress = progress,
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
            |> App.withPostStack(w -> checked_ecast(TownScene.postAt(look0, w#focus, w#scene |> Option.map(sc -> sc#time) |> Option.getWithDefault(0.0))));
        run { App.launchForBench(app0) }
            with LwjglLayer.withProject(".")
            with Fs.FileRead.runWithIO
            with Fs.FileWrite.runWithIO
            with Fs.Glob.runWithIO
            with Fs.ModificationTime.runWithFileTime
            with Fs.FileTime.runWithIO

    /// HD2D_MODE=walk の毎コマの状態。
    pub type alias WalkWorld = { frame = Int32, scene = Option[Scene3d.Scene3dCmd], focus = Float64, finished = Bool }

    def envOr(name: String, fallback: String): String \ IO =
        let v = System.getenv(name);
        if (Object.isNull(v) or v == "") fallback else v

    pub def go(): Unit \ IO =
        let mode = envOr("HD2D_MODE", "build");
        let bench = mode == "bench";
        let post = envOr("POST", "1") == "1";
        let shadow = envOr("SHADOW", "1") == "1";
        let look0 = run { TownLook.loadOr(Video.lookPath()) } with Fs.FileRead.runWithIO;
        let look = if (shadow) look0 else { shadowMapSize = 0 | look0 };
        let first = Int32.fromString(envOr("HD2D_FRAME_FROM", "0")) |> Option.getWithDefault(0);
        let extra = Int32.fromString(envOr("EXTRA_LAMPS", "-1")) |> Option.getWithDefault(-1);
        let fog = envOr("FOG", "");
        let charShadow = envOr("CHAR_SHADOW", "");
        let mapSize = Int32.fromString(envOr("SHADOW_MAP", "0")) |> Option.getWithDefault(0);
        let pcf = Int32.fromString(envOr("SHADOW_PCF", "-1")) |> Option.getWithDefault(-1);
        let look1 = { billboardTextures = TownScene.BillboardTextures.ProjectTextures, extraLamps = if (extra >= 0) extra else look#extraLamps,
                      groundFog = if (fog == "0") 0.0 else look#groundFog,
                      charShadow = if (charShadow == "") look#charShadow else TownLook.charShadowOf(charShadow),
                      shadowMapSize = if (mapSize > 0) mapSize else look#shadowMapSize, shadowPcf = if (pcf >= 0) pcf else look#shadowPcf,
                      fogFar = if (fog == "0") 400.0 else look#fogFar, fogNear = if (fog == "0") 300.0 else look#fogNear | look };
        if (mode == "walk") goWalk(look1, first) else
        match BuildVideo.setup(look1) {
            case Err(why) =>
                println("[hd2d_town] 町を組めない: ${why}");
                System.exit(1)
            case Ok(st0) =>
                let st = { show = { dustTexture = "dust" | st0#show } | st0 };
                let knobs = ("bench", BenchRun.quoted("hd2d_town")) :: ("post", if (post) "1" else "0") :: ("shadow", if (shadow) "1" else "0") ::
                            ("look", BenchRun.quoted(Video.lookPath())) :: ("lights", Int32.toString(List.length(TownScene.lampLights(st#res)))) ::
                            ("ground_fog", Float64.toString(look1#groundFog)) :: Nil;
                println("[hd2d_town] GPU ${mode}: コマ ${Int32.toString(st#track#frames)}・後がけ ${if (post) "あり" else "なし"}・太陽の影 ${if (shadow) "あり" else "なし"}");
                let app0 = App.make({ frame = first, scene = None, focus = 10.0, grouping = BuildVideo.startGrouping(st), progress = BenchRun.start(), finished = false })
                    |> App.addSystem(step(st, bench, first, knobs))
                    |> BenchRun.withDiagnostics(plan())
                    |> App.withView((_ctx, w) -> checked_ecast(w#scene |> Option.map(sc -> Render.scene3d(Vec2.zero(), sc)) |> Option.toList))
                    |> App.quitWhen((_frame, w) -> checked_ecast(w#finished));
                let app1 = if (post) app0 |> App.withPostStack(w -> checked_ecast(TownScene.postAt(look, w#focus, w#scene |> Option.map(sc -> sc#time) |> Option.getWithDefault(0.0)))) else app0;
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
