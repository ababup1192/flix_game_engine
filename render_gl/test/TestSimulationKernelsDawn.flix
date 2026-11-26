// 群れの kernel（Render3d.Internal.Kernels）と、それを回す Render3d.Internal.SimulationRunner を PC の Dawn で流して固定する:
// kernel が全部組める・GPU の 1 刻み ≈ CPU の 1 刻み（engine の Simulation3d.Internal.Cpu）・GPU の格子 = GPU の総当たり（バイト）・
// 同じ入力を 2 回でバイト同じ・出口の 1 体ごとの値 ≈ Render3d.InstanceValues の詰め方・作り直しと続きと id の扱い。
// WhyNot: mod TestSimulationKernelsDawn にしない — slot を作る・1 刻みを積む関数は SimulationRunner の中の pub でない関数で、子の mod からだけ見える。
// 組まずに通すのは、Dawn のネイティブを配っていない機種と adapter が無い機械だけ（`[simulation-dawn] SKIP:` の行を出す）。
mod Render3d.Internal.SimulationRunner.TestSimulationKernelsDawn {
    import fge.webgpu.Buffer
    import fge.webgpu.BufferUsage
    import fge.webgpu.WebGpu
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.FloatBuffer
    use Render3d.Internal.Kernels.{FlockKernel}
    use Render3d.Internal.SimulationRunner.{allocate, uploadState, kernel, encodeSteps, encodeSlot, releaseSlot, create, encode, instancesOf, release, endFrame, idleSeconds, Request}
    use Simulation3d.Internal.{FlockParams}

    def count(): Int32 = 1000

    def box(): Mesh3d.Bounds = { min = Vec3.v3(-5.0, -5.0, -5.0), max = Vec3.v3(5.0, 5.0, 5.0) }

    /// 許し幅（Dawn の M4 Pro で実測の差は 5e-7。sqrt と FMA の丸めの分だけ見る）。
    def tolerance(): Float64 = 1.0e-5

    def flock(n: Int32, time: Float64): Simulation3d.Simulation3d[Simulation3d.Elements] =
        Simulation3d.Internal.make("birds", Simulation3d.Internal.flockPreset(Simulation3d.Internal.defaultFlockRules()), n, box(), time)

    def params(): FlockParams = Simulation3d.Internal.Cpu.paramsOf(count(), flock(count(), 0.0))

    /// 向かう点のある規則の 1 刻みの値。
    def targetParams(): FlockParams =
        Simulation3d.Internal.flockParamsOf({ target = Some(Vec3.v3(3.0, -1.0, 2.0)), targetWeight = 4.0 | Simulation3d.Internal.defaultFlockRules() }, box(), count())

    /// 初めの状態を CPU で 20 刻み進めた物（近所がばらけた状態から始める）。
    def startState(): Vector[Float32] =
        Simulation3d.Internal.Cpu.advance(params(), 20i64, Simulation3d.Internal.Cpu.initialState(params(), 11))

    def isSkippable(why: String): Bool =
        String.contains({ substr = "WebGPU のネイティブはまだ配っていない" }, why) or
        String.contains({ substr = "adapter が無い" }, why) or String.contains({ substr = "No supported adapters" }, why)

    def withDawn(f: WebGpu -> Unit \ {Assert, IO}): Unit \ {Assert, IO} =
        match WebGpuDevice.runDawn(() -> WebGpuDevice.requestDevice()) {
            case Err(why) =>
                if (isSkippable(why)) {
                    println("[simulation-dawn] SKIP: Dawn で開かない（${why}）");
                    Assert.assertEq(expected = 0, 0)
                } else
                    Assert.assertEq(expected = "Dawn の device が開ける", why)
            case Ok(gpu) =>
                f(gpu);
                gpu.destroy()
        }

    def floatsOf(gpu: WebGpu, buffer: Buffer, floats: Int32): Vector[Float32] \ IO =
        let size = floats * 4;
        let staging = gpu.createBuffer("test read", Int32.toInt64(size), Int32.bitwiseOr(BufferUsage.COPY_DST, BufferUsage.MAP_READ));
        let encoder = gpu.createCommandEncoder("test read");
        encoder.copyBufferToBuffer(buffer, 0i64, staging, 0i64, Int32.toInt64(size));
        gpu.submit(encoder.finish());
        let out = ByteBuffer.allocateDirect(size).order(ByteOrder.LITTLE_ENDIAN);
        gpu.readBuffer(staging, 0i64, size, out);
        staging.destroy();
        Vector.range(0, floats) |> Vector.map(i -> out.getFloat(i * 4))

    def maxGap(a: Vector[Float32], b: Vector[Float32]): Float64 =
        Vector.zip(a, b) |> Vector.foldLeft((m, p) -> Float64.max(m, Float64.abs(Float32.toFloat64(fst(p)) - Float32.toFloat64(snd(p)))), 0.0)

    /// 状態 state を上げた slot を作り、steps 刻み（brute なら総当たりの kernel）進めて、最新の状態を読む。
    def gpuSteps(gpu: WebGpu, state: Vector[Float32], steps: Int32, brute: Bool): Vector[Float32] \ IO = gpuStepsWith(gpu, params(), state, steps, brute)

    def gpuStepsWith(gpu: WebGpu, p: FlockParams, state: Vector[Float32], steps: Int32, brute: Bool): Vector[Float32] \ IO =
        let c = Render3d.Internal.Compute.create(gpu);
        let sim = flock(count(), 0.0);
        let slot = allocate(c, count(), Simulation3d.Internal.structureOf(count(), sim));
        gpu.writeBuffer(slot#buffers#params, 0i64, Render3d.Internal.Kernels.flockParamsBytes(p, 1.0), 0, Render3d.Internal.Kernels.paramsBytes());
        uploadState(gpu, slot#buffers#stateA, state);
        let encoder = gpu.createCommandEncoder("test steps");
        let pass = Render3d.Internal.Compute.beginPass(encoder, "test steps", None);
        if (brute) {
            let ab = Render3d.Internal.Compute.bindGroupOf(c, kernel(FlockKernel.RulesBrute), slot#buffers#params :: slot#buffers#stateA :: slot#buffers#stateB :: Nil);
            let ba = Render3d.Internal.Compute.bindGroupOf(c, kernel(FlockKernel.RulesBrute), slot#buffers#params :: slot#buffers#stateB :: slot#buffers#stateA :: Nil);
            List.range(0, steps) |> List.forEach(s ->
                Render3d.Internal.Compute.dispatch(c, pass, kernel(FlockKernel.RulesBrute), if (Int32.remainder(s, 2) == 0) ab else ba,
                                                   Render3d.Internal.Compute.groupsFor(count())));
            Ref.put(Int32.remainder(steps, 2) == 0, slot#latestInA)
        } else encodeSteps(c, pass, slot, Int32.toInt64(steps));
        pass.end();
        gpu.submit(encoder.finish());
        let out = floatsOf(gpu, if (Ref.get(slot#latestInA)) slot#buffers#stateA else slot#buffers#stateB, count() * 8);
        releaseSlot(slot);
        Render3d.Internal.Compute.release(c);
        out

    @Test
    def testEveryFlockKernelCompilesOnDawn(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let kinds = FlockKernel.Count :: FlockKernel.ScanBlocks :: FlockKernel.ScanSums :: FlockKernel.ScanAdd :: FlockKernel.Scatter ::
                        FlockKernel.RulesGrid :: FlockKernel.RulesBrute :: FlockKernel.Pack :: Nil;
            let errors = kinds |> List.flatMap(k -> {
                let module = gpu.createShaderModule("test", force kernel(k)#source);
                let info = gpu.getCompilationInfo(module);
                module.release();
                String.lines(info) |> List.filter(l -> String.startsWith({ prefix = "Error" }, l)) |> List.map(l -> "${k}: ${l}")
            });
            let c = Render3d.Internal.Compute.create(gpu);
            Render3d.Internal.Compute.buildPipelines(c, kinds |> List.map(kernel));
            Render3d.Internal.Compute.release(c);
            Assert.assertEq(expected = ((Nil: List[String]), 0), (errors, gpu.errorCount()))
        })

    @Test
    def testGpuStepIsWithinToleranceOfCpuStep(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let s = startState();
            let gap = maxGap(Simulation3d.Internal.Cpu.stepFlock(params(), s), gpuSteps(gpu, s, 1, false));
            println("[simulation-dawn] GPU と CPU の 1 刻みの差の最大 ${gap}");
            Assert.assertEq(expected = (true, 0), (gap <= tolerance(), gpu.errorCount()))
        })

    @Test
    def testGpuStepWithTargetIsWithinToleranceOfCpuStep(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let s = startState();
            let gap = maxGap(Simulation3d.Internal.Cpu.stepFlock(targetParams(), s), gpuStepsWith(gpu, targetParams(), s, 1, false));
            println("[simulation-dawn] target つきの 1 刻みの差の最大 ${gap}");
            Assert.assertEq(expected = true, gap <= tolerance())
        })

    /// 3 軸でセルの数が違う箱でも、GPU の格子と総当たりはバイトで同じ。
    @Test
    def testGpuGridEqualsBruteInAnUnevenBox(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let p = Simulation3d.Internal.flockParamsOf(Simulation3d.Internal.defaultFlockRules(), { min = Vec3.v3(-10.0, -3.0, -5.0), max = Vec3.v3(10.0, 3.0, 5.0) }, count());
            let s = Simulation3d.Internal.Cpu.initialState(p, 13);
            Assert.assertEq(expected = Vector.map(Float32.toString, gpuStepsWith(gpu, p, s, 30, true)), Vector.map(Float32.toString, gpuStepsWith(gpu, p, s, 30, false)))
        })

    @Test
    def testGpuGridEqualsGpuBruteByteForByte(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let s = startState();
            Assert.assertEq(expected = Vector.map(Float32.toString, gpuSteps(gpu, s, 30, true)), Vector.map(Float32.toString, gpuSteps(gpu, s, 30, false)))
        })

    @Test
    def testSameInputTwiceGivesTheSameBytes(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let s = startState();
            Assert.assertEq(expected = Vector.map(Float32.toString, gpuSteps(gpu, s, 30, false)), Vector.map(Float32.toString, gpuSteps(gpu, s, 30, false)))
        })

    /// CPU の出口（transformsOf）を MultiMesh にして InstanceValues で詰めた並び。
    def cpuInstances(p: FlockParams, state: Vector[Float32]): Vector[Float32] \ IO =
        let out = Simulation3d.Internal.Cpu.transformsOf(p, state);
        let n = Vector.length(state) / 8;
        let worldOf = (i: Int32) -> {
            let t = (k: Int32) -> Vector.get(i * 12 + k, out#transforms);
            Mat4.ofColumns(Vector#{ t(0), t(4), t(8), 0.0, t(1), t(5), t(9), 0.0, t(2), t(6), t(10), 0.0, t(3), t(7), t(11), 1.0 })
                |> Result.getWithDefault(Mat4.identity())
        };
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil, color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
        let mm = MultiMesh3d.build(mesh, n, worldOf) |> MultiMesh3d.withColors(i -> Color.rgb(Vector.get(i * 3, out#colors), Vector.get(i * 3 + 1, out#colors), Vector.get(i * 3 + 2, out#colors)));
        let floats = n * Render3d.InstanceValues.floatsPerInstance();
        let buf = FloatBuffer.allocate(floats);
        let scratch = Array.repeat(Static, Render3d.InstanceValues.floatsPerInstance(), 0.0f32);
        discard Render3d.InstanceValues.numberMultiMesh(buf, scratch, n, Array#{0} @ Static, Render3d.InstanceValues.freshMultiCarry(), 0i64, mm);
        Vector.range(0, floats) |> Vector.map(i -> buf.get(i))

    @Test
    def testPackMatchesInstanceValuesPacking(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let s = startState();
            let c = Render3d.Internal.Compute.create(gpu);
            let slot = allocate(c, count(), Simulation3d.Internal.structureOf(count(), flock(count(), 0.0)));
            gpu.writeBuffer(slot#buffers#params, 0i64, Render3d.Internal.Kernels.flockParamsBytes(params(), 1.0), 0, Render3d.Internal.Kernels.paramsBytes());
            uploadState(gpu, slot#buffers#stateA, s);
            let encoder = gpu.createCommandEncoder("test pack");
            let pass = Render3d.Internal.Compute.beginPass(encoder, "test pack", None);
            encodeSlot(c, pass, slot, 0i64);
            pass.end();
            gpu.submit(encoder.finish());
            let got = floatsOf(gpu, slot#buffers#instances, count() * Render3d.InstanceValues.floatsPerInstance());
            releaseSlot(slot);
            Render3d.Internal.Compute.release(c);
            Assert.assertEq(expected = true, maxGap(cpuInstances(params(), s), got) <= tolerance())
        })

    // ── Runner ──

    def request(n: Int32, time: Float64): Request = { sim = flock(n, time), emission = 1.0 }

    /// runner で times の各時刻に 1 コマずつ encode し、最後のコマの出口を読む（各コマの宣言の並びは perFrame）。
    def runFrames(gpu: WebGpu, times: List[Float64], perFrame: Float64 -> List[Request]): Vector[Float32] \ IO =
        let runner = create(gpu);
        times |> List.forEach(t -> {
            let encoder = gpu.createCommandEncoder("test frame");
            encode(runner, encoder, t, perFrame(t));
            gpu.submit(encoder.finish())
        });
        let out = match instancesOf(runner, "birds") {
            case Some(inst) => floatsOf(gpu, inst#buffer, inst#count * Render3d.InstanceValues.floatsPerInstance())
            case None       => Vector.empty()
        };
        release(runner);
        out

    /// 作り直した（時刻 3/60 = 3 刻み）出口は、CPU で同じ宣言を解いた出口と許し幅で同じ。
    @Test
    def testRunnerResetMatchesCpuOutput(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let t = 3.0 / 60.0;
            let got = runFrames(gpu, t :: Nil, time -> request(count(), time) :: Nil);
            let state = snd(Simulation3d.Internal.Cpu.computeState(count(), None, flock(count(), t)));
            Assert.assertEq(expected = (count() * 32, true), (Vector.length(got), maxGap(cpuInstances(params(), state), got) <= tolerance()))
        })

    /// 同じ id を 1 コマに 2 回渡しても 1 回だけ進める（1 回ずつ渡した時とバイトで同じ）。
    @Test
    def testSameIdTwiceInOneFrameAdvancesOnce(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let times = 1.0 :: (1.0 + 1.0 / 60.0) :: (1.0 + 2.0 / 60.0) :: Nil;
            let once = runFrames(gpu, times, t -> request(count(), t) :: Nil);
            let twice = runFrames(gpu, times, t -> request(count(), t) :: request(count(), t) :: Nil);
            Assert.assertEq(expected = (count() * 32, Vector.map(Float32.toString, once)), (Vector.length(twice), Vector.map(Float32.toString, twice)))
        })

    /// 毎コマ続けて進めた出口は、同じ時刻へ 1 回で作り直した出口と同じ（同じ区切りの中・同じ GPU でバイト）。
    @Test
    def testContinuedFramesEqualOneReset(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let last = 1.0 + 3.0 / 60.0;
            let continued = runFrames(gpu, 1.0 :: (1.0 + 1.0 / 60.0) :: (1.0 + 2.0 / 60.0) :: last :: Nil, t -> request(count(), t) :: Nil);
            let reset = runFrames(gpu, last :: Nil, t -> request(count(), t) :: Nil);
            Assert.assertEq(expected = (count() * 32, Vector.map(Float32.toString, reset)), (Vector.length(continued), Vector.map(Float32.toString, continued)))
        })

    /// 数が変わると作り直して新しい数の出口になり、idleSeconds より長く渡さなかった id は手放す。
    @Test
    def testCountChangeResizesAndIdleIdIsReleased(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let runner = create(gpu);
            let frame = (t: Float64, n: Int32) -> {
                let encoder = gpu.createCommandEncoder("test frame");
                encode(runner, encoder, t, request(n, t) :: Nil);
                gpu.submit(encoder.finish())
            };
            frame(1.0, 300);
            frame(1.0 + 1.0 / 60.0, 200);
            let resized = instancesOf(runner, "birds") |> Option.map(i -> i#count);
            endFrame(runner, 1.0 + 1.0 / 60.0 + idleSeconds() - 0.5);
            let withinIdle = instancesOf(runner, "birds") |> Option.map(i -> i#count);
            endFrame(runner, 1.0 + 1.0 / 60.0 + idleSeconds() + 0.5);
            let afterIdle = instancesOf(runner, "birds") |> Option.map(i -> i#count);
            release(runner);
            Assert.assertEq(expected = (Some(200), Some(200), None), (resized, withinIdle, afterIdle))
        })

    /// 時刻が戻った（2 秒 → 1 秒）出口は、新しい runner に 1 秒を渡した出口とバイトで同じ（使い回した slot を作り直す）。
    @Test
    def testTimeGoingBackResetsTheHeldSlot(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let back = runFrames(gpu, 2.0 :: (2.0 + 1.0 / 60.0) :: 1.0 :: Nil, t -> request(count(), t) :: Nil);
            let fresh = runFrames(gpu, 1.0 :: Nil, t -> request(count(), t) :: Nil);
            Assert.assertEq(expected = (count() * 32, Vector.map(Float32.toString, fresh)), (Vector.length(back), Vector.map(Float32.toString, back)))
        })

    /// 同じ id で数の違う 2 つの宣言を 2 コマ続けて渡すと、最初に見た方の数で描き、知らせは 1 回だけ。
    @Test
    def testMismatchedSameIdUsesTheFirstDeclarationAndWarnsOnce(): Unit \ {Assert, IO} =
        withDawn(gpu -> {
            let runner = create(gpu);
            let said = Render3d.FakeGl.stderrOf(() -> (1.0 :: (1.0 + 1.0 / 60.0) :: Nil) |> List.forEach(t -> {
                let encoder = gpu.createCommandEncoder("test frame");
                encode(runner, encoder, t, request(300, t) :: request(200, t) :: Nil);
                gpu.submit(encoder.finish())
            }));
            let n = instancesOf(runner, "birds") |> Option.map(i -> i#count);
            release(runner);
            Assert.assertEq(expected = (Some(300), 2), (n, List.length(String.split(regex = "@simulation-id-mismatch", said))))
        })
}
