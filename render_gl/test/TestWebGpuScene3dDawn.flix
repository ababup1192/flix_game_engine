// WebGPU の 3D の描き手の、同じ encoder で同じ描き先の値を 2 回書く所の寿命の決まりを、PC の Dawn で device を開いて固定する（画素は読まない）。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（TestWgslDawn と同じ。`[scene3d-dawn] SKIP:` の行を出す）。
// WhyNot: mod TestWebGpuScene3dDawn にしない — afterSubmit の後の控えを見るのに Render3d.WebGpuRenderer の Host と prepare を、2D の描き手を通さずに呼ぶ。
mod Render3d.WebGpuRenderer.TestWebGpuScene3dDawn {
    import fge.webgpu.BindGroupLayout
    import fge.webgpu.BindGroupLayoutDesc
    import fge.webgpu.BufferBindingType
    import fge.webgpu.SamplerBindingType
    import fge.webgpu.ShaderStage
    import fge.webgpu.TextureSampleType
    import fge.webgpu.WebGpu
    use Render3d.WebGpuRenderer.{Dest, Host, Prepared, RendererData, afterSubmit, createInstanceBuffer, createPoseBuffer, notePasted, packPoses, prepare, sendPoses}

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

    def imageLayout(gpu: WebGpu): BindGroupLayout \ IO =
        let layoutDesc = new BindGroupLayoutDesc("test image");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).sampler(1, ShaderStage.FRAGMENT, SamplerBindingType.FILTERING);
        gpu.createBindGroupLayout(layoutDesc)

    def pasteLayout(gpu: WebGpu): BindGroupLayout \ IO =
        let layoutDesc = new BindGroupLayoutDesc("test paste");
        discard layoutDesc.texture(0, ShaderStage.FRAGMENT, TextureSampleType.FLOAT).buffer(1, ShaderStage.FRAGMENT, BufferBindingType.UNIFORM);
        gpu.createBindGroupLayout(layoutDesc)

    /// 姿勢は同じ encoder の中では 1 回だけ送って group 2 を使い回し、submit の後は送り直して新しい group 2 を作る
    /// （submit の後に次の prepare が姿勢の buffer の頭から書くので、前の位置を読む group を使い続けない）。
    @Test
    def testPosesAreResentAfterSubmit(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let found = posesAroundSubmit(gpu);
                gpu.destroy();
                Assert.assertEq(expected = (1, true, 1, false), found)
        }

    /// (1 回目に送った後の group 2 の数, 2 回目が同じ group か, submit の後に送り直した後の group 2 の数, 送り直した group が前と同じか)。
    def posesAroundSubmit(gpu: WebGpu): (Int32, Bool, Int32, Bool) \ IO =
        let layout = pasteLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, imageLayout(gpu));
        let RendererData.RendererData(s) = renderer;
        let rows = snd(Render3d.PoseRows.assignRow(Render3d.FakeGl.poseAt(1.0), Render3d.PoseRows.noRows(16)));
        let found = match packPoses(renderer, rows) {
            case None => (0, false, 0, false)
            case Some(poses) =>
                let first = sendPoses(renderer, poses);
                let again = sendPoses(renderer, poses);
                let sentOnce = List.length(Ref.get(s#poseGroups));
                afterSubmit(renderer);
                let resent = sendPoses(renderer, poses);
                (sentOnce, Render3d.PoseRows.isSameValue(first, again), List.length(Ref.get(s#poseGroups)), Render3d.PoseRows.isSameValue(first, resent))
        };
        Render3d.WebGpuRenderer.release(renderer);
        layout.release();
        found

    /// 骨つきの三角 1 枚と骨の無い三角 2 枚の場面（1 体ごとの値 3 体 = 384 バイト・姿勢 1 行 = 頭 16 + 64 バイト）。
    def skinnedScene(): Scene3d.RenderCmd =
        let skinned = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity()) |> Scene3d.withPose(Render3d.FakeGl.poseAt(0.5));
        let plain = (x: Float64) -> Scene3d.meshInstance(Render3d.FakeGl.plainTriangle(), Mat4.translate(Vec3.v3(x, 0.0, 0.0)));
        Render3d.FakeGl.cmdOf(Render3d.FakeGl.sceneOf(skinned :: plain(-1.0) :: plain(1.0) :: Nil))

    /// 骨つきの場面 2 つを 1 回の prepare に渡し、1 つ目の後で 1 体ごとの値の buffer（512 バイト）があふれて submit が 1 回入ると、
    /// 2 つ目の場面は姿勢を送り直して新しい group 2 を作る（submit で前の group 2 は手放してあるので、group 2 は 1 つ）。
    /// あふれない時（buffer 4,096 バイト）は submit せず、2 つ目の場面は 1 つ目の姿勢と group 2 を使い回す（姿勢の buffer は 1 回分ちょうどの 336 バイトで、
    /// 送り直しを見積もると入らずに submit が増える）。
    @Test
    def testSecondSceneResendsPosesAfterSubmitInsidePrepare(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let overflow = posesAcrossScenes(gpu, 512);
                let roomy = posesAcrossScenes(gpu, 4096);
                gpu.destroy();
                Assert.assertEq(expected = ((1, 1), (0, 1)), (overflow, roomy))
        }

    /// 1 体ごとの値の buffer を instanceBytes にした描き手で、骨つきの場面 2 つを 1 回の prepare で描いた時の (submit の数, prepare の後の group 2 の数)。
    def posesAcrossScenes(gpu: WebGpu, instanceBytes: Int32): (Int32, Int32) \ IO =
        let layout = pasteLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, imageLayout(gpu));
        let RendererData.RendererData(s) = renderer;
        Array.get(0, s#instances).destroy();
        Array.put(createInstanceBuffer(gpu, instanceBytes), 0, s#instances);
        Array.get(0, s#poses).destroy();
        Array.put(createPoseBuffer(gpu, 336), 0, s#poses);
        let encoder = gpu.createCommandEncoder("test");
        let flushes = Ref.fresh(Static, 0);
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> Ref.put(Ref.get(flushes) + 1, flushes), skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None), groupById = _ -> checked_ecast(None) };
        discard prepare(renderer, host, dest(), skinnedScene() :: skinnedScene() :: Nil);
        let found = (Ref.get(flushes), List.length(Ref.get(s#poseGroups)));
        discard encoder.finish();
        Render3d.WebGpuRenderer.release(renderer);
        layout.release();
        found

    def flushesAround(gpu: WebGpu): Int32 \ IO =
        let layout = pasteLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, imageLayout(gpu));
        let encoder = gpu.createCommandEncoder("test");
        let flushes = Ref.fresh(Static, 0);
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> Ref.put(Ref.get(flushes) + 1, flushes), skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None), groupById = _ -> checked_ecast(None) };
        let first: Prepared = prepare(renderer, host, dest(), scene() :: Nil);
        afterSubmit(renderer);
        Vector.forEach(found -> Option.forEach(notePasted(renderer), found), first);
        discard prepare(renderer, host, dest(), scene() :: Nil);
        let counted = Ref.get(flushes);
        discard encoder.finish();
        Render3d.WebGpuRenderer.release(renderer);
        layout.release();
        counted

    /// 骨つきの三角 1 枚と骨の無い三角 2 枚を、影を落とすスポットで照らす場面（影の地図 64 × 64 の鍵 (64, 0)）。shadowed が偽ならスポットに影を付けない。
    def spotScene(shadowed: Bool): Scene3d.RenderCmd =
        let base = skinnedScene();
        let spot = if (shadowed) Render3d.FakeGl.shadowSpot() else { shadow = None | Render3d.FakeGl.shadowSpot() };
        { scene = { spotLights = spot :: Nil | base#scene } | base }

    /// 同じ encoder の 2 回目の prepare が、1 回目と同じ鍵の影の地図を描き直す時は、送る前に submit を 1 回頼む
    /// （影の pass の光の目の値は描き先ごとの buffer で、submit せずに書き直すと 1 回目の影の pass も 2 回目の目で描く）。
    /// submit の後に姿勢を送り直し、影の地図を読む group 0 を作り直す（どちらも 1 つ・手放した物を使わない）。影の無い場面では submit しない。
    @Test
    def testSecondPrepareRedrawingAShadowMapFlushesFirst(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let shadowed = shadowMapsAcrossPrepares(gpu, true);
                let plain = shadowMapsAcrossPrepares(gpu, false);
                gpu.destroy();
                Assert.assertEq(expected = ((1, 1, 1, 0), (0, 2, 0, 0)), (shadowed, plain))
        }

    /// 描き先の違う 2 回の prepare（描き先の鍵 0 と 1）を同じ encoder で流した時の (submit の数, prepare の後の group 2 の数, 影の地図を読む group 0 の数, device の誤りの数)。
    def shadowMapsAcrossPrepares(gpu: WebGpu, shadowed: Bool): (Int32, Int32, Int32, Int32) \ IO =
        let layout = pasteLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, imageLayout(gpu));
        let RendererData.RendererData(s) = renderer;
        let encoder = gpu.createCommandEncoder("test");
        let flushes = Ref.fresh(Static, 0);
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> Ref.put(Ref.get(flushes) + 1, flushes), skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None), groupById = _ -> checked_ecast(None) };
        discard prepare(renderer, host, dest(), spotScene(shadowed) :: Nil);
        discard prepare(renderer, host, { key = 1 | dest() }, spotScene(shadowed) :: Nil);
        let found = (Ref.get(flushes), List.length(Ref.get(s#poseGroups)), List.length(Ref.get(s#sceneGroups)));
        discard encoder.finish();
        let errors = gpu.errorCount();
        Render3d.WebGpuRenderer.release(renderer);
        layout.release();
        let (f, p, g) = found;
        (f, p, g, errors)

    // ── 先に上げる物（withPreload3d）──

    /// 先に上げる物の宣言: 絵つきの材質の三角と、頂点の色の三角（key = "k"）。絵は場面の textures に載せる 4 × 4。
    def preloadCmd(key: String): Scene3d.PreloadCmd =
        let tex = match Texture3d.fromArgb(4, 4, Vector.range(0, 16) |> Vector.map(i -> if (Int32.remainder(i, 2) == 0) -1 else -16777216)) {
            case Ok(t)  => t
            case Err(e) => bug!(e)
        };
        let textured = Scene3d.meshInstance(Mesh3d.withBoxUvs(1.0, Render3d.FakeGl.plainTriangle()), Mat4.identity())
            |> Scene3d.withMaterial(Scene3d.texturedMaterial(Texture3d.name(tex), ShaderDoc.FilterMode.Linear));
        let plain = Scene3d.meshInstance(Render3d.FakeGl.skinnedTriangle(), Mat4.identity());
        { key = key, instances = () -> textured :: plain :: Nil, textures = () -> tex :: Nil }

    /// 宣言を上げると、形 2 つ・材質の絵 1 枚（mip のレベル 3 つ）が置き場に載って控えに残り、積んだ pass を先に submit する（1 回）。
    /// 同じ key の 2 回目は何もしない（submit も数えない）。上げた形と絵は、使わないコマが続いても endFrame の上限の内なら残る。
    @Test
    def testPreloadUploadsOnceAndKeepsWhatItUploaded(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let found = preloadedCounts(gpu);
                gpu.destroy();
                Assert.assertEq(expected = (2, 1, 3, 1, 2, 1, 0), found)
        }

    /// (形の数, 控えた絵の鍵の数, 絵の mip のレベルの数, submit の数, 2 回目の後の形の数, 2 回目の後の submit の数, Dawn の誤りの数)。
    /// 2 回目の前に endFrame を 200 回呼ぶ（使わない形と絵が古くなる）。
    def preloadedCounts(gpu: WebGpu): (Int32, Int32, Int32, Int32, Int32, Int32, Int32) \ IO =
        let layout = pasteLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, imageLayout(gpu));
        let RendererData.RendererData(s) = renderer;
        let encoder = gpu.createCommandEncoder("test");
        let flushes = Ref.fresh(Static, 0);
        let host: Host = { encoder = () -> checked_ecast(encoder), notePass = () -> checked_ecast(()), flush = () -> Ref.put(Ref.get(flushes) + 1, flushes), skip = (_, _) -> checked_ecast(()), textureOf = _ -> checked_ecast(None), textureById = _ -> checked_ecast(None), groupById = _ -> checked_ecast(None) };
        Render3d.WebGpuRenderer.preload(renderer, host, preloadCmd("k"));
        let meshes = Map.size(Render3d.MeshTable.createdOf(s#meshes));
        let slots = Ref.get(s#preloaded)#textures |> Set.size;
        let levels = Render3d.TextureTable3d.createdOf(Render3d.WebGpuMaterials.texturesOf(s#materials)) |> Map.toList |> List.map(kv -> { let (_, (_, c, _)) = kv; c#levels }) |> List.sum;
        let firstFlushes = Ref.get(flushes);
        List.range(0, 200) |> List.forEach(_ -> Render3d.WebGpuRenderer.endFrame(renderer));
        Render3d.WebGpuRenderer.preload(renderer, host, preloadCmd("k"));
        let kept = Map.size(Render3d.MeshTable.createdOf(s#meshes));
        discard encoder.finish();
        let errors = gpu.errorCount();
        Render3d.WebGpuRenderer.release(renderer);
        layout.release();
        (meshes, slots, levels, firstFlushes, kept, Ref.get(flushes), errors)

    /// ビルボードの pipeline（stride 0 の頂点の buffer・group 0 の場面と group 1 の 2D の絵の layout）を、画面の形式の標本 1 と 4 で Dawn が誤り無しに作る。
    @Test
    def testBillboardPipelinesBuildOnDawn(): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[scene3d-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                let errors = billboardPipelineErrors(gpu);
                gpu.destroy();
                Assert.assertEq(expected = 0, errors)
        }

    def billboardPipelineErrors(gpu: WebGpu): Int32 \ IO =
        let layout = pasteLayout(gpu);
        let image = imageLayout(gpu);
        let renderer = Render3d.WebGpuRenderer.create(gpu, layout, image);
        let RendererData.RendererData(s) = renderer;
        discard Render3d.WebGpuBillboards.pipelineOf(s#billboards, RenderTarget.Format.Rgba8Unorm, 1);
        discard Render3d.WebGpuBillboards.pipelineOf(s#billboards, RenderTarget.Format.Rgba8Unorm, 4);
        let errors = gpu.errorCount();
        Render3d.WebGpuRenderer.release(renderer);
        image.release();
        layout.release();
        errors
}
