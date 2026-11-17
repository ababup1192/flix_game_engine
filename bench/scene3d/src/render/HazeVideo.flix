// HazeVideo — 陽炎（PostStack.Distortion）の部屋を VideoOut で書き出す（make haze-video）。
// 塗る物は VideoOut の環境変数で選ぶ: FGE_GPU=on は GL（窓を開かずに塗る・frames.mkv）・FGE_GPU=off は SoftRaster（f0000.png …）・
// FGE_PNG_PAINTER=webgpu と FGE_VIDEO_PAINT=frames:0-47 は画面なしの WebGPU（f0000.png …）。3 つの描き手の絵を並べて比べる用。
// HAZE_OUT = 書き出す所・HAZE_OFF=1 で歪みを外す（描き手どうしの元の差を測る）。
mod HazeVideo {
    use fge::{Clock, Color, HeadlessFont, HeadlessRender, PostStack, ProcessEnv, Render, VideoOut}

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    def stackAt(haze: Bool, t: Clock.Time[Clock.Real]): PostStack.Stack =
        PostStack.preset(PostStack.Preset.DuskOutdoor) |> PostStack.withExposure(-0.3)
            |> PostStack.withDistortion(if (haze) Some(SceneBench.hazeOf()) else None) |> PostStack.withTime(t)

    pub def write(): Unit \ IO =
        let env = ProcessEnv.snapshot();
        let settings = VideoOut.settingsOf(env);
        let outDir = Map.getWithDefault("HAZE_OUT", "debug/haze/video", env);
        let haze = Map.get("HAZE_OFF", env) != Some("1");
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let world = Room.items(Room.kitOf(meshes), 0.0);
                let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
                let cfg = { design = Room.design(), scale = 3, outDir = outDir, fontTtf = ttf(), fontAtlas = atlas,
                            frameW = 960, frameH = 540 | HeadlessRender.defaults() };
                let built = (t: Clock.Time[Clock.Real]) ->
                    PostStack.build({ size = Room.design(), clear = Color.rgb(0.0, 0.0, 0.0), world = world }, stackAt(haze, t));
                let video = { outDir = outDir, fps = 24, soft = cfg, softFonts = _ -> atlas, extraFonts = Map.empty(), images = Nil,
                              scene = _ -> t -> built(t)#present :: Nil, wanted = _ -> true, bakeSurfaces = false, encoders = Nil };
                let painter = VideoOut.writeFramesWithPasses(settings, video, _ -> t -> built(t)#plan, HazeMoments.frames());
                println("[scene3d] ${outDir}（${painter}）")
        }
}
