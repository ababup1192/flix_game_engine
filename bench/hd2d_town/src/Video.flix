// Video — 窓を開かずに CPU（SoftRaster）で町を描き出す入口。
//   compare … Blender の試作と同じ止めたカメラ（地図の camera.frame）・同じ物の置き方で 1 枚（debug/compare_engine.png・1920×1080）
//   frames  … 地図の walk の台本で歩いて止まる 30 fps のコマ（debug/frames/f0001.png …）。FRAMES="a,b" で範囲・書いたコマは飛ばす
//   time    … 歩く場面の 1 コマを温めてから何回か描き、1 枚の時間の中央値を出す
mod Video {
    use fge::{Color, CpuTiming, HeadlessFont, HeadlessRender, PostStack, Render, Scene3d, Vec2}
    use TownMap.{TownMap}
    use TownScene.{Look, Res}

    import java.io.File
    import java.lang.System

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def mapPath(): String = "assets/town_avenue.map.json"

    def lookPath(): String = "assets/town.json"

    /// 使う地図の差分（草を 0.25 m 上げて縁石と笠石を立てる版）。
    def variant(): String = "step"

    def fps(): Int32 = 30

    /// 描き物の大きさ（design px・16:9）。書き出す画素は scale 倍。
    def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def envInt(name: String, fallback: Int32): Int32 \ IO =
        let v = System.getenv(name);
        if (Object.isNull(v)) fallback else Int32.fromString(v) |> Option.getWithDefault(fallback)

    def configOf(scale: Int32, outDir: String): HeadlessRender.RenderConfig \ IO =
        let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
        { design = design(), scale = scale, outDir = outDir, fontTtf = ttf(), fontAtlas = atlas,
          frameW = 320 * scale, frameH = 180 * scale | HeadlessRender.defaults() }

    /// 地図とつまみを読み、町を組む（読めなければ止める: 描き出しの入口で、続ける当てが無い）。
    def loadAll(skipNpcColumn: Bool): (TownMap, Res) \ IO =
        let look = run { TownLook.loadOr(lookPath()) } with Fs.FileRead.runWithIO;
        match (run { TownMap.load(variant(), mapPath()) } with Fs.FileRead.runWithIO) {
            case Err(why) => bug!("[hd2d_town] 地図を読めない: ${why}")
            case Ok(m)    =>
                println("[hd2d_town] ${TownMap.describe(m)}");
                match TownScene.load(m, look, if (skipNpcColumn) Some(m#walk#col) else None) {
                    case Err(why) => bug!("[hd2d_town] 町を組めない: ${why}")
                    case Ok(res)  => (m, res)
                }
        }

    /// 場面に後がけを掛けて 1 枚の PNG に書く。
    def writeShot(cfg: HeadlessRender.RenderConfig, look: Look, focus: Float64, scene: Scene3d.Scene3dCmd, name: String): Unit \ IO =
        let built = PostStack.build({ size = design(), clear = Color.rgb(0.0, 0.0, 0.0), world = TownScene.items(scene) }, TownScene.postOf(look, focus));
        let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
            |> List.map(s -> { name = s#name, clear = s#clear, drawables = s#drawables, polygons = s#polygons, surfaces = s#surfaces, scenes = s#scenes, target = s#target });
        let soft = Render.softSceneOf(_ -> None, built#present :: Nil);
        HeadlessRender.renderPngFull(cfg, { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
                                            scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }, name)

    /// Blender の試作（out/blender_tilemap_avenue_15_50_day.png）と同じ止めたカメラの 1 枚。
    pub def compare(): Unit \ IO =
        let (m, res) = loadAll(false);
        let look = res#look;
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let eye = TownCamera.frameEye(m, lens);
        let camera = TownCamera.cameraAt(lens, look#far, eye);
        let focus = Int32.toFloat64(m#height) - m#frame#targetRow - eye#z;
        let scale = envInt("SCALE", 6);
        writeShot(configOf(scale, "debug"), look, focus, TownScene.sceneOf(res, camera, design(), Nil, Nil), "compare_engine");
        println("[hd2d_town] debug/compare_engine.png（${Int32.toString(320 * scale)}×${Int32.toString(180 * scale)}・目の高さ ${Float64.toString(eye#height)} m・lensShift ${Float64.toString(lens#shiftY)}）")

    /// 歩く台本の 1 コマの場面と、ピントの奥行き。
    pub type alias Shot = { scene = Scene3d.Scene3dCmd, focus = Float64 }

    /// 歩く台本の決まり（速さは画面の真ん中の行で地面が groundFlowH /秒 流れる値・足元は画面の高さ feetV）。
    pub type alias Walking = { timeline = Party.Timeline, eye = TownCamera.Eye, lens = TownCamera.Lens, feetDepth = Float64, groundZ = Float64 }

    pub def walkingOf(m: TownMap, look: Look): Walking =
        let w = m#walk;
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let eye = TownCamera.frameEye(m, lens);
        let groundZ = TownMap.topAt(m, w#col, w#toRow);
        let speed = w#groundFlowH / TownCamera.screenPerMeterAt(lens, eye, groundZ, 0.5);
        let depth = TownCamera.depthAt(lens, eye, groundZ, w#feetV);
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        { timeline = Party.timelineOf(w, speed), eye = eye, lens = lens, feetDepth = snap(depth), groundZ = groundZ }

    /// 時刻 t の場面（隊列の板と足元の影・追従カメラ）。位置とカメラは snapToTexels の時 1 テクセルに丸める
    /// （先頭とカメラの間の距離も丸めた値にそろえ、2 つを別々に丸めた差でキャラが画面で震えないようにする）。
    pub def shotAt(m: TownMap, res: Res, wk: Walking, t: Float64): Shot =
        let look = res#look;
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        let tl = wk#timeline;
        let members = m#walk#party |> List.mapWithIndex((i, member) -> {
            let (x, y) = Party.memberAt(m, tl, t, i);
            TownScene.memberBoard(res, member, Party.frameOf(m#walk, tl, t, i), snap(x), snap(y), wk#groundZ)
        }) |> List.filterMap(identity);
        let eye = { z = snap(Party.cameraTargetY(m, tl, t) - wk#feetDepth) | wk#eye };
        let camera = TownCamera.cameraAt(wk#lens, look#far, eye);
        { scene = TownScene.sceneOf(res, camera, design(), List.map(fst, members), List.map(snd, members)), focus = wk#feetDepth }

    def pad4(i: Int32): String = String.padLeft(4, '0', Int32.toString(i))

    /// 歩く台本のコマを書く。FRAMES="a,b"（1 から数える）で範囲を選び、もう書いたコマは飛ばす（途中で止めても続きから描ける）。
    pub def frames(): Unit \ IO =
        let (m, res) = loadAll(true);
        let wk = walkingOf(m, res#look);
        let n = Party.frameCount(wk#timeline, fps());
        let scale = envInt("SCALE", 4);
        let first = envInt("FRAME_FROM", 1);
        let last = Int32.min(n, envInt("FRAME_TO", n));
        let cfg = configOf(scale, "debug/frames");
        println("[hd2d_town] 歩く速さ ${Float64.toString(wk#timeline#speed)} m/s・足元の奥行き ${Float64.toString(wk#feetDepth)} m・コマ ${Int32.toString(n)}（${Int32.toString(first)}〜${Int32.toString(last)} を描く）");
        List.range(first, last + 1) |> List.forEach(f -> {
            let name = "f${pad4(f)}";
            if (new File("debug/frames/${name}.png").exists()) ()
            else {
                let shot = shotAt(m, res, wk, Int32.toFloat64(f - 1) / Int32.toFloat64(fps()));
                writeShot(cfg, res#look, shot#focus, shot#scene, name);
                println("[hd2d_town] debug/frames/${name}.png")
            }
        })

    /// 歩く場面の 1 コマ（歩いている最中）の CPU の時間を測る。
    pub def time(): Unit \ IO =
        let (m, res) = loadAll(true);
        let wk = walkingOf(m, res#look);
        let scale = envInt("SCALE", 4);
        let cfg = configOf(scale, "debug");
        let shot = shotAt(m, res, wk, wk#timeline#startAt + 1.0);
        let plan = { warmup = 1, runs = 3 };
        let built = PostStack.build({ size = design(), clear = Color.rgb(0.0, 0.0, 0.0), world = TownScene.items(shot#scene) }, TownScene.postOf(res#look, shot#focus));
        let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
            |> List.map(s -> { name = s#name, clear = s#clear, drawables = s#drawables, polygons = s#polygons, surfaces = s#surfaces, scenes = s#scenes, target = s#target });
        let soft = Render.softSceneOf(_ -> None, built#present :: Nil);
        let full = { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces, scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() };
        let (summary, _) = CpuTiming.measure(plan, () -> HeadlessRender.renderImageFull(cfg, full));
        let plain = CpuTiming.measure(plan, () -> HeadlessRender.renderImageSoft(cfg, Render.softSceneOf(_ -> None, TownScene.items(shot#scene))));
        println("[hd2d_town] CPU 1 コマ（${Int32.toString(cfg#frameW)}×${Int32.toString(cfg#frameH)}）: 後がけつき 中央値 ${Float64.toString(summary#median)} ms・" +
                "後がけなし ${Float64.toString(fst(plain)#median)} ms")
}
