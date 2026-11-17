// Still — 部屋を CPU（SoftRaster）で描く（窓を開かない）。
// write は 1 枚を debug/room.png に書き、time は温めてから何回か描いて 1 枚の時間の中央値を出す。
// 実機と同じ描き物の列を Render.softSceneOf で分けて渡す。
mod Still {
    use fge::{Clock, Color, CpuTiming, HeadlessFont, HeadlessRender, PostStack, Render}

    import java.lang.System

    // WhyNot: 字を描かない場面でも字の表を空にしない — SoftRaster は塗る前に必ずフォントの表を組む。
    def ttf(): String = "assets/Xolonium-Regular.ttf"

    /// 書き出す倍率（design 320×180 → 960×540）。
    def scale(): Int32 = 3

    /// 速さの測り方。温めの 5 回で JIT を温め、15 回の中央値を取る（外れた 1 回に引かれない。1 回ごとに絵の読み込みも入る。描き出しの 1 枚と同じ仕事）。
    def timingPlan(): CpuTiming.Plan = { warmup = 5, runs = 15 }

    /// 部屋を描く設定と描き物を組む（家具が読めなければ止める）。
    def roomScene(): (HeadlessRender.RenderConfig, HeadlessRender.SoftScene) \ IO =
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why) =>
                bug!("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let kit = Room.kitOf(meshes);
                let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
                let cfg = { design = Room.design(), scale = scale(), outDir = "debug", fontTtf = ttf(), fontAtlas = atlas,
                            frameW = 320 * scale(), frameH = 180 * scale() | HeadlessRender.defaults() };
                (cfg, Render.softSceneOf(_ -> None, Room.items(kit, 0.0)))
        }

    pub def write(): Unit \ IO =
        let (cfg, soft) = roomScene();
        HeadlessRender.renderPngSoft(cfg, soft, "room");
        println("[scene3d] debug/room.png（描く時間は make cpu-time で測る）")

    /// 部屋に PostStack の preset を 1 つずつ掛けて debug/preset_<名前>.png に書く（人が preset の値を目で見る用。make presets）。
    pub def presets(): Unit \ IO =
        let (cfg, _) = roomScene();
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let world = Room.items(Room.kitOf(meshes), 0.0);
                PostStack.presets() |> List.forEach(p -> {
                    let built = PostStack.build({ size = Room.design(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, PostStack.preset(p));
                    let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
                        |> List.map(s -> { name = s#name, clear = s#clear, drawables = s#drawables, polygons = s#polygons, surfaces = s#surfaces, scenes = s#scenes, target = s#target });
                    let soft = Render.softSceneOf(_ -> None, built#present :: Nil);
                    HeadlessRender.renderPngFull(cfg, { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
                                                        scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }, "preset_${p}");
                    println("[scene3d] debug/preset_${p}.png")
                })
        }

    /// 陽炎（PostStack.Distortion を画面の下側の帯に）の見比べ。debug/haze/off.png（歪みなし）と debug/haze/on_<コマ>.png（24 コマ / 秒で 2 秒）を書く（make haze）。
    pub def haze(): Unit \ IO =
        let (cfg0, _) = roomScene();
        let cfg = { outDir = "debug/haze" | cfg0 };
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let world = Room.items(Room.kitOf(meshes), 0.0);
                let base = PostStack.preset(PostStack.Preset.DuskOutdoor) |> PostStack.withExposure(-0.3);
                let draw = (name: String, s: PostStack.Stack) -> {
                    let built = PostStack.build({ size = Room.design(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, s);
                    let specs = Render.passSpecsOf(_ -> None, built#plan)#specs
                        |> List.map(sp -> { name = sp#name, clear = sp#clear, drawables = sp#drawables, polygons = sp#polygons, surfaces = sp#surfaces, scenes = sp#scenes, target = sp#target });
                    let soft = Render.softSceneOf(_ -> None, built#present :: Nil);
                    HeadlessRender.renderPngFull(cfg, { passes = specs, drawables = soft#drawables, polygons = soft#polygons, surfaces = soft#surfaces,
                                                        scenes = soft#scenes, fonts = Map.empty(), fontAntialias = Map.empty() }, name)
                };
                draw("off", base);
                List.zipWithIndex(HazeMoments.frames()) |> List.forEach(e -> {
                    let (i, t) = e;
                    draw("on_${String.padLeft(3, '0', Int32.toString(i))}",
                         base |> PostStack.withDistortion(Some(SceneBench.hazeOf())) |> PostStack.withTime(t))
                });
                println("[scene3d] debug/haze/off.png と debug/haze/on_000〜047.png")
        }

    pub def time(): Unit \ IO =
        let (cfg, soft) = roomScene();
        let plan = timingPlan();
        let (summary, image) = CpuTiming.measure(plan, () -> HeadlessRender.renderImageSoft(cfg, soft));
        // SoftRaster が 1 スレッドで回すのは FGE_SOFT_SERIAL=1 の時だけ（ほかの値は並列のまま）。
        let serialValue = System.getenv("FGE_SOFT_SERIAL");
        let serial = if (not Object.isNull(serialValue) and serialValue == "1") "FGE_SOFT_SERIAL=1（1 スレッド）" else "行を並列";
        println("[scene3d] CPU 1 枚（${Int32.toString(cfg#frameW)}×${Int32.toString(cfg#frameH)}・${serial}）: " +
                "中央値 ${fmt1(summary#median)} ms（最小 ${fmt1(summary#min)}・最大 ${fmt1(summary#max)}・" +
                "${Int32.toString(plan#runs)} 回・温め ${Int32.toString(plan#warmup)} 回・最後の絵 ${Int32.toString(image.getWidth())}×${Int32.toString(image.getHeight())}）")

    /// ミリ秒を小数 1 桁の字にする（そのまま文字列に埋めると桁が長すぎて読めない）。
    def fmt1(ms: Float64): String = Float64.toString(Float64.round(ms * 10.0) / 10.0)
}
