// Video — 窓を開かずに CPU（SoftRaster）で町を描き出す入口。
//   compare … Blender の試作と同じ止めたカメラ（地図の camera.frame）・同じ物の置き方で 1 枚（debug/compare_engine.png・1920×1080）
//   frames  … 地図の walk の台本で歩いて止まる 30 fps のコマ（debug/frames/f0001.png …）。FRAME_FROM・FRAME_TO で範囲・書いたコマは飛ばす
//   time    … 歩く場面の 1 コマを温めてから何回か描き、1 枚の時間の中央値を出す
mod Video {
    use fge::{Color, CpuTiming, HeadlessFont, HeadlessRender, Num, PostStack, Render, Scene3d, Vec2}
    use TownMap.{TownMap}
    use TownScene.{Look, Res}

    import java.io.File
    import java.lang.System

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def mapPath(): String = "assets/town_avenue.map.json"

    /// 見た目のつまみの Doc（環境変数 LOOK で替える: assets/town_night.json など）。
    pub def lookPath(): String \ IO =
        let v = System.getenv("LOOK");
        if (Object.isNull(v) or v == "") "assets/town.json" else v

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
    pub def loadAll(skipNpcColumn: Bool): (TownMap, Res) \ IO =
        loadWith(run { TownLook.loadOr(lookPath()) } with Fs.FileRead.runWithIO, skipNpcColumn)

    /// loadAll の見た目のつまみを渡す形（GPU の窓は板の絵を project.json の名前で引くつまみで組む）。
    pub def loadWith(look: Look, skipNpcColumn: Bool): (TownMap, Res) \ IO =
        let loaded = (run { TownMap.load(variant(), mapPath()) } with Fs.FileRead.runWithIO)
            |> Result.flatMap(m -> TownScene.load(m, look, if (skipNpcColumn) Some(m#walk#col) else None) |> Result.map(res -> (m, res)));
        match loaded {
            case Err(why)     => bug!("[hd2d_town] 町を組めない: ${why}")
            case Ok((m, res)) =>
                println("[hd2d_town] ${TownMap.describe(m)}");
                (m, res)
        }

    /// 場面に後がけを掛けた、CPU で描く 1 枚の中身。
    def fullSceneOf(look: Look, focus: Float64, scene: Scene3d.Scene3dCmd): HeadlessRender.Scene =
        let built = PostStack.build({ size = design(), clear = Color.rgb(0.0, 0.0, 0.0), world = TownScene.items(scene) }, TownScene.postOf(look, focus));
        let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
            |> List.map(s -> { name = s#name, clear = s#clear, drawables = s#drawables, polygons = s#polygons, surfaces = s#surfaces, scenes = s#scenes, target = s#target });
        let soft = Render.softSceneOf(_ -> None, built#present :: Nil);
        { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
          scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }

    /// 目から地面の点（北の座標 groundY・高さ groundZ）までの距離。奥行きのぼかしは目からの距離で測る。
    // WhyNot: 水平の奥行きをピントに渡さない — 見下ろしのカメラでは目からの距離と 3〜4 m 違い、ピントが画面の下の端の地面へずれる。
    def focusOf(eye: TownCamera.Eye, groundY: Float64, groundZ: Float64): Float64 =
        let dz = groundY - eye#z;
        let dy = eye#height - groundZ;
        Num.sqrt(dz * dz + dy * dy)

    /// Blender の試作（out/blender_tilemap_avenue_15_50_day.png）と同じ止めたカメラの 1 枚。
    pub def compare(): Unit \ IO =
        let (m, res) = loadAll(false);
        let look = res#look;
        let lens = TownCamera.lensOf(look#topDeg, look#bottomDeg);
        let eye = TownCamera.frameEye(m, lens);
        let camera = TownCamera.cameraAt(lens, look#far, eye);
        let focus = focusOf(eye, Int32.toFloat64(m#height) - m#frame#targetRow, m#frame#targetZ);
        let scale = envInt("SCALE", 6);
        let name = { let v = System.getenv("SHOT"); if (Object.isNull(v) or v == "") "compare_engine" else v };
        HeadlessRender.renderPngFull(configOf(scale, "debug"), fullSceneOf(look, focus, { time = 4.0 | TownScene.sceneOf(res, camera, design(), Nil, Nil) }), name);
        println("[hd2d_town] debug/${name}.png（${Int32.toString(320 * scale)}×${Int32.toString(180 * scale)}・目の高さ ${Float64.toString(eye#height)} m・lensShift ${Float64.toString(lens#shiftY)}）")

    /// 歩く台本の 1 コマの場面と、ピントの距離（目から先頭の足元まで）。
    pub type alias Shot = { scene = Scene3d.Scene3dCmd, focus = Float64 }

    /// 歩く台本の決まり。timeline = 時刻の決まり（速さは画面の真ん中の行で地面が groundFlowH /秒 流れる値）・
    /// feetDepth = 先頭の足元が画面の高さ feetV に来る水平の奥行き（丸めた値）・groundZ = 歩く地面の高さ。
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
    pub def shotAt(m: TownMap, res: Res, wk: Walking, t: Float64): Shot = shotSized(m, res, wk, design(), t)

    /// shotAt の描き物の大きさを渡す形（GPU の窓は 1280×720）。
    pub def shotSized(m: TownMap, res: Res, wk: Walking, size: Vec2.Vec2, t: Float64): Shot =
        let look = res#look;
        let snap = (v: Float64) -> if (look#snapToTexels) TownCamera.snapToTexel(v) else v;
        let tl = wk#timeline;
        let members = m#walk#party |> List.mapWithIndex((i, member) -> {
            let (x, y) = Party.memberAt(m, tl, t, i);
            TownScene.memberBoard(res, member, Party.frameOf(m#walk, tl, t, i), snap(x), snap(y), wk#groundZ)
        }) |> List.filterMap(identity);
        let eye = { z = snap(Party.cameraTargetY(m, tl, t) - wk#feetDepth) | wk#eye };
        let camera = TownCamera.cameraAt(wk#lens, look#far, eye);
        let leaderY = snap(snd(Party.memberAt(m, tl, t, 0)));
        { scene = { time = t | TownScene.sceneOf(res, camera, size, List.map(fst, members), List.map(snd, members)) },
          focus = focusOf(eye, leaderY, wk#groundZ) }

    def pad4(i: Int32): String = String.padLeft(4, '0', Int32.toString(i))

    /// 歩く台本のコマを書く。FRAME_FROM・FRAME_TO（1 から数える）で範囲を選び、もう書いたコマは飛ばす（途中で止めても続きから描ける）。
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
                HeadlessRender.renderPngFull(cfg, fullSceneOf(res#look, shot#focus, shot#scene), name);
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
        let full = fullSceneOf(res#look, shot#focus, shot#scene);
        let (summary, _) = CpuTiming.measure(plan, () -> HeadlessRender.renderImageFull(cfg, full));
        let plain = CpuTiming.measure(plan, () -> HeadlessRender.renderImageSoft(cfg, Render.softSceneOf(_ -> None, TownScene.items(shot#scene))));
        println("[hd2d_town] CPU 1 コマ（${Int32.toString(cfg#frameW)}×${Int32.toString(cfg#frameH)}）: 後がけつき 中央値 ${Float64.toString(summary#median)} ms・" +
                "後がけなし ${Float64.toString(fst(plain)#median)} ms")
}
