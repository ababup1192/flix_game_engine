// 窓なしの GPU の session（GpuOffscreen）を WebGPU で開き、塗った箱を readImage で読み戻せる事を PC の Dawn で固定する。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（GL へ落ちた時。`[gpu-offscreen-dawn] SKIP:` の行を出す）。
// WhyNot: mod TestGpuOffscreenDawn にしない — どちらの描き手で開いたかを、GpuOffscreen の中の pub でない enum で見る。
mod GpuOffscreen.TestGpuOffscreenDawn {
    use GpuOffscreen.SessionData

    /// 16 × 8 の design・絵もフォントも無い設定。
    def config(): GameEngine.EngineConfig =
        { rootDir = ".", glyphs = "auto", designWidth = 16, designHeight = 8, windowWidth = 16, windowHeight = 8, title = "gpu-offscreen",
          textureManifest = Nil, fontManifest = Nil, soundManifest = Nil, clearColor = Color.rgb(0.0, 0.0, 0.0), maxDeltaTime = 0.1,
          scene3dTextureBudgetMB = GameEngine.defaultScene3dTextureBudgetMB(),
          scene3dTextureBudgetCount = GameEngine.defaultScene3dTextureBudgetCount() }

    /// 左の 8 × 8 に赤い箱を置いたコマを scale 2 で塗り、箱の中・箱の外・大きさを読む。WebGPU で開けなければ None。
    def paintedBox(): Option[(Int32, Int32, (Int32, Int32))] \ IO =
        match GpuOffscreen.open(LwjglEnv.Backend.WebGpu, { config = config(), scale = 2 }) {
            case Ok(SessionData.WebGpu(w)) =>
                let session = SessionData.WebGpu(w);
                let red = Rect.toDrawable(Rect.make({ x = 8.0, y = 8.0 }, Color.rgb(1.0, 0.0, 0.0)), Vec2.zero());
                GpuOffscreen.handle(session, () -> Platform.Draw2d.renderCommands(red :: Nil, Nil, Nil, Nil));
                let image = GpuOffscreen.readImage(session);
                let read = (image.getRGB(4, 4), image.getRGB(24, 4), GpuOffscreen.sizeOf(session));
                GpuOffscreen.close(session);
                Some(read)
            case Ok(other) =>
                GpuOffscreen.close(other);
                None
            case Err(_) => None
        }

    @Test
    def testWebGpuSessionPaintsAndReadsBack(): Unit \ {Assert, IO} =
        match paintedBox() {
            case None =>
                println("[gpu-offscreen-dawn] SKIP: WebGPU で開かない（GL へ落ちたか、どちらも開かない）");
                Assert.assertEq(expected = 0, 0)
            case Some((inside, outside, size)) =>
                // TYPE_INT_RGB は α を 0xFF で返す: 赤 0xFFFF0000 = -65536・黒 0xFF000000 = -16777216。
                Assert.assertEq(expected = (-65536, -16777216, (32, 16)), (inside, outside, size))
        }
}
