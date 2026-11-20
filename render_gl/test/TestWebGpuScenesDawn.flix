// 塗りのコア（WebGpuPaint）が場面を貼る時に、その描き先を 3D の描き手へ「使い中」と知らせる配線を、PC の Dawn で device を開いて固定する（画素は読まない）。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（TestWgslDawn と同じ。`[scenes-dawn] SKIP:` の行を出す）。
// WhyNot: WebGpuPaint の外の mod にしない — prepare と貼る間に submit を挟むのに、WebGpuPaint の pass を開く所と submit する所を直に呼ぶ。
mod RenderPaint.Internal.WebGpuPaint.Scenes.TestScenesDawn {
    import fge.webgpu.Texture
    import fge.webgpu.WebGpu
    use RenderFrame.Internal.RenderList
    use RenderFrame.Internal.RenderList.{DepthStencil, PassSpec}
    use RenderPaint.Internal.WebGpuPaint.{Paint, PaintData, flushPending, openPass}
    use RenderPaint.Internal.WebGpuPaint.Scenes.{paste, prepare}

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0, lensShift = Vec2.zero() }

    /// 目の前（z = 10）に四角 1 枚を置いた 64 × 64 の場面。
    def scene(): Scene3d.RenderCmd =
        let quad = { points = Vec3.v3(-2.0, -2.0, 10.0) :: Vec3.v3(-2.0, 2.0, 10.0) :: Vec3.v3(2.0, 2.0, 10.0) :: Vec3.v3(2.0, -2.0, 10.0) :: Nil,
                     color = Color.rgb(0.8, 0.4, 0.2) };
        let cmd = { instances = Scene3d.meshInstance(Mesh3d.fromPolygons(quad :: Nil), Mat4.identity()) :: Nil | Scene3d.scene(camera(), { x = 64.0, y = 64.0 }) };
        { at = Vec2.zero(), clip = None, scene = cmd }

    def screen(): PassSpec = RenderList.screenPass((64, 64), (64.0, 64.0), Color.rgb(0.0, 0.0, 0.0), DepthStencil.NoDepthStencil)

    def target(): (RenderTarget.Format, Int32) = (RenderTarget.Format.Rgba8Unorm, 1)

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    /// 場面を描く → submit → 2D の pass に Scenes.paste で貼る → 同じ描き先の場面をもう一度描く、の順で、2 回目が先に submit を 1 回頼む
    /// （貼った描き先を使い中と知らせていなければ、まだ submit していない貼る pass の値を先回りして書き換え、submit は増えない）。
    @Test
    def testPasteMarksTargetInUse(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scenes-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let submits = submitsAroundPaste(gpu);
                gpu.destroy();
                Assert.assertEq(expected = 1, submits)
        }

    def submitsAroundPaste(gpu: WebGpu): Int32 \ IO =
        let paint = RenderPaint.Internal.WebGpuPaint.create(gpu, { designWidth = 64, designHeight = 64, clearColor = Color.rgb(0.0, 0.0, 0.0), width = 64, height = 64,
                                                                    scene3d = Render3d.WebGpuRenderer.makeScenes });
        let first = prepare(paint, 0, target(), screen(), scene() :: Nil);
        flushPending(paint);
        let before = submitsOf(paint);
        let pass = openPass(paint, frameTextureOf(paint), None, 0, screen());
        paste(paint, target(), Vector.get(0, first), pass, 0);
        pass.end();
        discard prepare(paint, 0, target(), screen(), scene() :: Nil);
        let counted = submitsOf(paint) - before;
        flushPending(paint);
        RenderPaint.Internal.WebGpuPaint.release(paint);
        counted

    /// このコマの submit の数。
    def submitsOf(paint: Paint): Int32 \ IO =
        let PaintData.PaintData(p) = paint;
        Array.get(1, p#frameCounters)

    def frameTextureOf(paint: Paint): Texture \ IO =
        let PaintData.PaintData(p) = paint;
        Array.get(0, p#frameTexture)
}
