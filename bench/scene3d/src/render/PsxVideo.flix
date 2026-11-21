// PsxVideo — 部屋を PS1 風の描き方（Scene3d.PsxLook・場面は PsxRoom）で VideoOut に書き出す（make psx-video）。カメラは 2 秒で左右へ首を振る（頂点の揺れが見える）。
// 塗る物は VideoOut の環境変数で選ぶ: FGE_GPU=on は GL（frames.mkv）・FGE_GPU=off は SoftRaster（f0000.png …）・FGE_PNG_PAINTER=webgpu は画面なしの WebGPU。
// PSX_OUT = 書き出す所（既定 debug/psx/<LOOK>）・LOOK = off（既定）・dither・full（PsxRoom.lookOf）・crt（full に PostStack の CRT のにじみ）。
mod PsxVideo {
    use fge::{Color, HeadlessFont, HeadlessRender, PostStack, ProcessEnv, Render, VideoOut}

    def ttf(): String = "assets/Xolonium-Regular.ttf"

    /// コマ i（48 コマ）のカメラの向き（2 秒で −0.35 → +0.35 → −0.35 の首振り）。
    def yawAt(i: Int32): Float64 =
        let t = Int32.toFloat64(i) / 48.0;
        -0.35 + 0.7 * (if (t < 0.5) t * 2.0 else 2.0 - t * 2.0)

    /// LOOK = crt の後がけ（横のぼかし 1.5 px・色だけのにじみ 2 px・走査線 0.35）。ほかの LOOK は掛けない。
    def stackOf(lookName: String): Option[PostStack.Stack] =
        if (lookName == "crt") Some(PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withCrt(Some({ compositeBlur = 1.5, scanlines = 0.35, chromaBleed = 2.0 })))
        else None

    pub def write(): Unit \ IO =
        let env = ProcessEnv.snapshot();
        let settings = VideoOut.settingsOf(env);
        let lookName = Map.getWithDefault("LOOK", "off", env);
        let outDir = Map.getWithDefault("PSX_OUT", "debug/psx/${lookName}", env);
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let kit = PsxRoom.kitOf(Room.kitOf(meshes));
                let look = PsxRoom.lookOf(if (lookName == "crt") "full" else lookName);
                let world = (i: Int32) -> PsxRoom.items(kit, look, yawAt(i));
                let built = (s: PostStack.Stack, i: Int32) -> PostStack.build({ size = Room.design(), clear = Color.rgb(0.0, 0.0, 0.0), world = world(i) }, s);
                let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
                let cfg = { design = Room.design(), scale = 3, outDir = outDir, fontTtf = ttf(), fontAtlas = atlas,
                            frameW = 960, frameH = 540 | HeadlessRender.defaults() };
                let scene = (i: Int32) -> match stackOf(lookName) {
                    case Some(s) => built(s, i)#present :: Nil
                    case None    => world(i)
                };
                let plan = (i: Int32) -> match stackOf(lookName) {
                    case Some(s) => built(s, i)#plan
                    case None    => Render.passPlan(Nil)
                };
                let video = { outDir = outDir, fps = 24, soft = cfg, softFonts = _ -> atlas, extraFonts = Map.empty(), images = Nil,
                              scene = _ -> scene, wanted = _ -> true, bakeSurfaces = false, encoders = Nil };
                let painter = VideoOut.writeFramesWithPasses(settings, video, _ -> plan, List.range(0, 48));
                println("[scene3d] ${outDir}（${painter}）")
        }
}
