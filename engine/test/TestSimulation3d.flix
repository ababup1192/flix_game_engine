// 見た目の仕事の宣言（Simulation3d）の CPU の道: 群れの規則の性質・格子と総当たりのバイトの一致・seed の決まり方・
// 刻みの数えと作り直しの判定・cache の無い道で続くコマ・構造の値と毎コマの値の分け方・出口の並び。
mod TestSimulation3d {
    use Simulation3d.Internal.{FlockParams, Structure, PresetKind}
    use Simulation3d.Internal.Step.{StepPlan}

    def box(): Mesh3d.Bounds = { min = Vec3.v3(-5.0, -5.0, -5.0), max = Vec3.v3(5.0, 5.0, 5.0) }

    def rules(): Simulation3d.FlockRules = Simulation3d.Internal.defaultFlockRules()

    def flock(count: Int32, time: Float64): Simulation3d.Simulation3d[Simulation3d.Elements] =
        Simulation3d.Internal.make("birds", Simulation3d.Internal.flockPreset(rules()), count, box(), time)

    def paramsFor(r: Simulation3d.FlockRules, count: Int32): FlockParams = Simulation3d.Internal.flockParamsOf(r, box(), count)

    /// 2 個だけの状態（どちらも止まっている）。
    def pair(gap: Float32): Vector[Float32] =
        Vector#{ 0.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32,
                 gap, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32 }

    def gapOf(state: Vector[Float32]): Float32 = Vector.get(8, state) - Vector.get(0, state)

    def at(state: Vector[Float32], i: Int32, k: Int32): Float32 = Vector.get(i * 8 + k, state)

    def steps(p: FlockParams, n: Int32, state: Vector[Float32]): Vector[Float32] = Simulation3d.Internal.Cpu.advance(p, Int32.toInt64(n), state)

    def started(count: Int32, seed: Int32): Vector[Float32] = Simulation3d.Internal.Cpu.initialState(paramsFor(rules(), count), seed)

    // ── 規則の性質 ──

    /// 近所の距離の内・離れる距離の外にいる 2 個は、寄る力で近づく。
    @Test
    def testTwoApartWithinNeighborRadiusMoveCloser(): Unit \ Assert =
        let p = paramsFor({ alignment = 0.0, separation = 0.0, margin = 0.0 | rules() }, 2);
        Assert.assertEq(expected = true, gapOf(steps(p, 5, pair(1.5f32))) < 1.5f32)

    /// 離れる距離の内の 2 個は離れる。
    @Test
    def testTwoTooCloseMoveApart(): Unit \ Assert =
        let p = paramsFor({ cohesion = 0.0, alignment = 0.0, margin = 0.0 | rules() }, 2);
        Assert.assertEq(expected = true, gapOf(steps(p, 5, pair(0.3f32))) > 0.3f32)

    /// 近所の距離の外の 2 個は寄らない（止まったまま）。
    @Test
    def testTwoBeyondNeighborRadiusStayPut(): Unit \ Assert =
        let p = paramsFor({ margin = 0.0 | rules() }, 2);
        Assert.assertEq(expected = 2.5f32, gapOf(steps(p, 5, pair(2.5f32))))

    /// 何刻み進めても速さは maxSpeed（と丸めの 1e-4）を超えない。
    @Test
    def testSpeedStaysWithinMaxSpeed(): Unit \ Assert =
        let p = paramsFor(rules(), 300);
        let s = steps(p, 40, started(300, 3));
        let fastest = List.range(0, 300) |> List.foldLeft((m, i) -> {
            let v = Float32.toFloat64(at(s, i, 4) * at(s, i, 4) + at(s, i, 5) * at(s, i, 5) + at(s, i, 6) * at(s, i, 6));
            Float64.max(m, Num.sqrt(v))
        }, 0.0);
        Assert.assertEq(expected = true, fastest <= 5.0001)

    /// 何刻み進めても箱を出ない。
    @Test
    def testElementsStayInsideTheBox(): Unit \ Assert =
        let s = steps(paramsFor(rules(), 300), 40, started(300, 4));
        let outside = List.range(0, 300) |> List.count(i ->
            List.range(0, 3) |> List.exists(k -> at(s, i, k) < -5.0f32 or at(s, i, k) > 5.0f32));
        Assert.assertEq(expected = 0, outside)

    /// 向かう点（target）があると、群れの真ん中がその点へ近づく。
    @Test
    def testTargetPullsTheFlockTowardIt(): Unit \ Assert =
        let p = paramsFor({ target = Some(Vec3.v3(4.0, 0.0, 0.0)), targetWeight = 6.0 | rules() }, 200);
        let meanX = (s: Vector[Float32]) -> List.range(0, 200) |> List.foldLeft((acc, i) -> acc + Float32.toFloat64(at(s, i, 0)), 0.0);
        let s0 = started(200, 5);
        Assert.assertEq(expected = true, meanX(steps(p, 30, s0)) > meanX(s0))

    // ── 決定性 ──

    /// 格子で引いた 1 刻みと総当たりの 1 刻みは、Float32 のバイトまで同じ。
    @Test
    def testGridStepEqualsBruteStepByteForByte(): Unit \ Assert =
        let p = paramsFor(rules(), 400);
        let s = steps(p, 20, started(400, 6));
        let grid = Simulation3d.Internal.Cpu.stepFlock(p, s);
        let brute = Simulation3d.Internal.Cpu.stepFlockBrute(p, s);
        Assert.assertEq(expected = Vector.map(Float32.toString, brute), Vector.map(Float32.toString, grid))

    /// 同じ seed なら同じ初めの状態・違う seed なら違う。
    @Test
    def testSameSeedSameStateOtherSeedDiffers(): Unit \ Assert =
        Assert.assertEq(expected = (true, false), (started(64, 9) == started(64, 9), started(64, 9) == started(64, 10)))

    /// 全部が 1 点に重なっていても、あふれず有限の値のまま進む。
    @Test
    def testAllAtOnePointStaysFinite(): Unit \ Assert =
        let n = 300;
        let same = Vector.range(0, n * 8) |> Vector.map(i -> if (Int32.remainder(i, 8) == 3 or Int32.remainder(i, 8) == 4) 1.0f32 else 0.0f32);
        let s = steps(paramsFor(rules(), n), 3, same);
        Assert.assertEq(expected = 0, Vector.count(x -> not Float64.isFinite(Float32.toFloat64(x)), s))

    /// 3 軸でセルの数が違う箱（20 × 6 × 10）でも、格子と総当たりはバイトで同じ。
    @Test
    def testGridEqualsBruteInAnUnevenBox(): Unit \ Assert =
        let p = Simulation3d.Internal.flockParamsOf(rules(), { min = Vec3.v3(-10.0, -3.0, -5.0), max = Vec3.v3(10.0, 3.0, 5.0) }, 400);
        let s = Simulation3d.Internal.Cpu.advance(p, 20i64, Simulation3d.Internal.Cpu.initialState(p, 12));
        Assert.assertEq(expected = (true, Vector.map(Float32.toString, Simulation3d.Internal.Cpu.stepFlockBrute(p, s))),
                        (p#gx != p#gy and p#gy != p#gz, Vector.map(Float32.toString, Simulation3d.Internal.Cpu.stepFlock(p, s))))

    // ── 刻みの数えと作り直し ──

    def structure(): Structure = Structure.Structure(PresetKind.Flock, 512, 1)

    def progress(step: Int64): Simulation3d.Internal.Step.Progress = { step = step, structure = structure() }

    @Test
    def testStepIndexToleratesAccumulatedSeconds(): Unit \ Assert =
        let summed = List.range(0, 60) |> List.foldLeft((t, _) -> t + 1.0 / 60.0, 0.0);
        Assert.assertEq(expected = (60i64, 0i64), (Simulation3d.Internal.Step.stepIndexOf(summed), Simulation3d.Internal.Step.stepIndexOf(-3.0)))

    @Test
    def testAdvanceIsCappedAtFourSteps(): Unit \ Assert =
        Assert.assertEq(expected = StepPlan.Advance(4i64), Simulation3d.Internal.Step.planOf(120, Some(progress(100i64)), structure(), 110i64))

    @Test
    def testStructureChangeResets(): Unit \ Assert =
        Assert.assertEq(expected = StepPlan.Reset(0i64, 101i64),
                        Simulation3d.Internal.Step.planOf(120, Some(progress(100i64)), Structure.Structure(PresetKind.Flock, 256, 1), 101i64))

    @Test
    def testJumpOfExactlyOneSecondStillAdvances(): Unit \ Assert =
        Assert.assertEq(expected = StepPlan.Advance(4i64), Simulation3d.Internal.Step.planOf(120, Some(progress(500i64)), structure(), 560i64))

    @Test
    def testTimeGoingBackResets(): Unit \ Assert =
        Assert.assertEq(expected = StepPlan.Reset(0i64, 199i64), Simulation3d.Internal.Step.planOf(120, Some(progress(400i64)), structure(), 199i64))

    @Test
    def testJumpOverOneSecondResets(): Unit \ Assert =
        Assert.assertEq(expected = StepPlan.Reset(180i64, 381i64), Simulation3d.Internal.Step.planOf(120, Some(progress(500i64)), structure(), 561i64))

    @Test
    def testFirstSightResetsFromThePeriodHeadMinusPrewarm(): Unit \ Assert =
        Assert.assertEq(expected = (StepPlan.Reset(0i64, 50i64), StepPlan.Reset(480i64, 270i64)),
                        (Simulation3d.Internal.Step.planOf(120, None, structure(), 50i64), Simulation3d.Internal.Step.planOf(120, None, structure(), 750i64)))

    // ── 構造の値と毎コマの値 ──

    /// 規則の値・向かう点（target）・箱・時刻を毎コマ変えても構造の値は同じ（作り直さない）。
    @Test
    def testPerFrameValuesKeepTheStructure(): Unit \ Assert =
        let a = flock(512, 1.0);
        let b = Simulation3d.Internal.make("birds",
                    Simulation3d.Internal.flockPreset({ cohesion = 3.0, target = Some(Vec3.v3(1.0, 2.0, 3.0)) | rules() }), 512,
                    { min = Vec3.v3(-9.0, -9.0, -9.0), max = Vec3.v3(9.0, 9.0, 9.0) }, 2.0);
        Assert.assertEq(expected = Simulation3d.Internal.structureOf(512, a), Simulation3d.Internal.structureOf(512, b))

    /// 数か seed を変えると構造の値が変わる（作り直す）。
    @Test
    def testCountOrSeedChangesTheStructure(): Unit \ Assert =
        let a = flock(512, 1.0);
        let reseeded = Simulation3d.Internal.mapFields(r -> { seed = 2 | r }, a);
        Assert.assertEq(expected = (false, false),
                        (Simulation3d.Internal.structureOf(512, a) == Simulation3d.Internal.structureOf(256, a),
                         Simulation3d.Internal.structureOf(512, a) == Simulation3d.Internal.structureOf(512, reseeded)))

    /// 毎コマの値を変えた次のコマは、前の状態から 1 刻み進める（作り直さない）。
    @Test
    def testChangingRulesNextFrameAdvancesTheHeldState(): Unit \ Assert =
        let (held, state) = Simulation3d.Internal.Cpu.computeState(64, None, flock(64, 2.0));
        let moved = Simulation3d.Internal.make("birds", Simulation3d.Internal.flockPreset({ cohesion = 2.0 | rules() }), 64, box(), 2.0 + 1.0 / 60.0);
        let (_, next) = Simulation3d.Internal.Cpu.computeState(64, Some((held, state)), moved);
        let expected = Simulation3d.Internal.Cpu.stepFlock(Simulation3d.Internal.Cpu.paramsOf(64, moved), state);
        Assert.assertEq(expected = Vector.map(Float32.toString, expected), Vector.map(Float32.toString, next))

    /// cache の無い道で続く 2 コマを別々に求めても、後のコマは前のコマを 1 刻み進めた物と同じ（同じ区切りの中）。
    @Test
    def testCachelessFramesInOnePeriodAreContinuous(): Unit \ Assert =
        let now = Simulation3d.Internal.Cpu.stateAt(flock(48, 3.0));
        let later = Simulation3d.Internal.Cpu.stateAt(flock(48, 3.0 + 1.0 / 60.0));
        let p = Simulation3d.Internal.Cpu.paramsOf(48, flock(48, 3.0));
        Assert.assertEq(expected = Vector.map(Float32.toString, Simulation3d.Internal.Cpu.stepFlock(p, now)), Vector.map(Float32.toString, later))

    /// CPU で解く数は count と fallbackCount の小さい方。
    @Test
    def testCpuCountIsCappedByFallbackCount(): Unit \ Assert =
        Assert.assertEq(expected = (512, 100), (Simulation3d.Internal.cpuCountOf(flock(8000, 0.0)), Simulation3d.Internal.cpuCountOf(flock(100, 0.0))))

    // ── 1 刻みの値 ──

    /// セルの大きさは近所の距離以上・1 軸のセルは 32 まで。
    @Test
    def testCellsCoverTheNeighborRadiusAndCapAt32(): Unit \ Assert =
        let p = Simulation3d.Internal.flockParamsOf(rules(), { min = Vec3.v3(0.0, 0.0, 0.0), max = Vec3.v3(5.0, 100.0, 1.0) }, 10);
        Assert.assertEq(expected = (2, 32, 1, true), (p#gx, p#gy, p#gz, p#cellSize#x >= 2.0f32 and p#cellSize#y >= 2.0f32))

    // ── 出口 ──

    /// +Z へ進む 1 個は向きが単位行列・平行移動が位置・速さ最大の色は白。
    @Test
    def testForwardAlongZIsIdentityBasis(): Unit \ Assert =
        let state = Vector#{ 1.0f32, 2.0f32, 3.0f32, 1.0f32, 0.0f32, 0.0f32, 5.0f32, 0.0f32 };
        let out = Simulation3d.Internal.Cpu.transformsOf(paramsFor(rules(), 1), state);
        Assert.assertEq(expected = (Vector#{ 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 2.0, 0.0, 0.0, 1.0, 3.0 }, Vector#{ 1.0, 1.0, 1.0 }),
                        (out#transforms, out#colors))
}
