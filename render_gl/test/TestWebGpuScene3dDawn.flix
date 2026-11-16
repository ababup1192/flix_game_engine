// WebGPU の 3D の描き手の、同じ encoder で同じ描き先の値を 2 回書く所の寿命の決まりを、PC の Dawn で device を開いて固定する（画素は読まない）。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（TestWgslDawn と同じ。`[scene3d-dawn] SKIP:` の行を出す）。
// WhyNot: mod TestWebGpuScene3dDawn にしない — afterSubmit の後の控えを見るのに Render3d.WebGpuRenderer の Host と prepare を、2D の描き手を通さずに呼ぶ。
mod Render3d.WebGpuRenderer.TestWebGpuScene3dDawn {
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureSampleType
    import fge.webgpu.WebGpu
    use Render3d.WebGpuRenderer.{Dest, Host, Prepared, afterSubmit, notePasted, prepare}

    def camera(): Camera3d.Camera3d = { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 }

    /// 目の前（z = 10）に四角 1 枚を置いた 64 × 64 の場面。
    def scene(): Scene3d.RenderCmd =
        let quad = { points = Vec3.v3(-2.0, -2.0, 10.0) :: Vec3.v3(-2.0, 2.0, 10.0) :: Vec3.v3(2.0, 2.0, 10.0) :: Vec3.v3(2.0, -2.0, 10.0) :: Nil,
                     color = Color.rgb(0.8, 0.4, 0.2) };
        let cmd = { instances = Scene3d.meshInstance(Mesh3d.fromPolygons(quad :: Nil), Mat4.identity()) :: Nil | Scene3d.scene(camera(), { x = 64.0, y = 64.0 }) };
        { at = Vec2.zero(), clip = None, scene = cmd }

    def dest(): Dest =
        { key = 0, format = RenderTarget.Format.Rgba8Unorm, samples = 1, height = 64,
          viewport = { x = 0, y = 0, width = 64, height = 64, scaleX = 1.0, scaleY = 1.0 } }

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    /// prepare → submit（2D の Stream を伸ばす時の flushPending と同じ）→ その場面を 2D の pass に貼る → 同じ描き先の prepare、の順で、
    /// 2 回目の prepare が先に submit を 1 回頼む（まだ submit していない貼る pass の値を、先回りして書き換えない）。
    @Test
    def testSecondPrepareAfterPasteFlushesFirst(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let flushes = flushesAround(gpu);
                gpu.destroy();
                Assert.assertEq(expected = 1, flushes)
        }

    def flushesAround(gpu: WebGpu): Int32 \ IO =
        let layoutDesc = new BindGroupLayoutDesc("test paste");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        let layout = gpu.createBindGroupLayout(layoutDesc);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout);
        let encoder = gpu.createCommandEncoder("test");
        let flushes = Ref.fresh(Static, 0);
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> Ref.put(Ref.get(flushes) + 1, flushes), skip = (_, _) -> checked_ecast(()) };
        let first: Prepared = prepare(renderer, host, dest(), scene() :: Nil);
        afterSubmit(renderer);
        Vector.forEach(found -> Option.forEach(notePasted(renderer), found), first);
        discard prepare(renderer, host, dest(), scene() :: Nil);
        let counted = Ref.get(flushes);
        discard encoder.finish();
        Render3d.WebGpuRenderer.release(renderer);
        layout.release();
        counted
}
