// 動かない物の集まりの持ち越し（Render3d.StaticRows）: いつ前のコマの行を使い、いつ作り直すか・持ち越す物と毎コマの物の分け方・持ち越す行の値。
mod Render3d.TestStaticRows {
    use Render3d.FakeGl.{camera, cmdOf, freshRecorded, freshState, paint, plainTriangle, poseAt, recordingGl, sceneOf, skinnedAt, stderrOf, timesCalled}
    use Render3d.SceneList.{countAt, flagSameBinding, hasFlag, rowCountOf, valuesAt}
    use Render3d.ScenePlan.{freshPlanner}
    use Render3d.StaticRows.{BuildSteps, CarriedRows, build, buildingCountOf, carriedKeyOf, ensure, freshCache, isCarriedItem, perFrameOf, setTime, sizeOf,
                             startBuild, stepBuild, sweep}

    import java.lang.Thread

    def noRegistered(_name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO = checked_ecast(None)

    def freshTables(): Render3d.SceneList.Tables \ IO =
        { meshes = Render3d.MeshTable.fresh(), textures = Render3d.TextureTable3d.fresh(), layouts = Render3d.MaterialValues.freshLayouts(), gen = 1i64,
          gpuMip = false, textureOf = noRegistered, flipsTargetV = false }

    def materialOf(red: Float64): Scene3d.Material3d =
        Scene3d.material({ name = "m${red}", cycleRate = 0.0, bindings = Nil,
                           out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = red, g = 0.5, b = 0.5 }), alpha = ShaderDoc.Field.Const(1.0) }) })

    /// 幅 side の三角形に材質（赤の量 0.1）を付けた物。
    def boxAt(side: Float64): Scene3d.Instance3d =
        let mesh = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(side, 0.0, 0.0) :: Vec3.v3(0.0, side, 0.0) :: Nil,
                                         color = { r = 1.0, g = 1.0, b = 1.0 } } :: Nil);
        Scene3d.meshInstance(mesh, Mat4.translate(Vec3.v3(side, 0.0, 0.0))) |> Scene3d.withMaterial(materialOf(0.1))

    def glass(): Scene3d.Instance3d =
        Scene3d.meshInstance(plainTriangle(), Mat4.identity()) |> Scene3d.withMaterial(materialOf(0.2) |> Scene3d.withAlphaBlend(true))

    def town(): Scene3d.StaticGroup =
        Scene3d.staticGroup("town", ("a", boxAt(1.0)) :: ("b", boxAt(2.0)) :: ("c", boxAt(3.0)) :: Nil)

    /// GPU を呼ばない作る仕事: 置くたびに builds へ 1 足し、その数を置いた物にする。手放した物は retire へ。pause = 形 1 つごとに待つ ms（0 で待たない）。
    def countingSteps(builds: Ref[Int32, Static], retire: Int32 -> Unit \ IO, pause: Int64): BuildSteps[Int32] \ IO =
        { tables = freshTables(), resolve = requests -> Vector.map(_ -> 0, requests),
          prepareMesh = _ -> if (pause > 0i64) Thread.sleep(pause) else (), prepareMaterial = _ -> (),
          place = _ -> { Ref.put(Ref.get(builds) + 1, builds); Ref.get(builds) }, uploadCount = _ -> 0, uploadAt = (_, _) -> (), retire = retire }

    /// 集まり g の持ち越した物（色の場面・GPU を呼ばない仕事）。
    def ensureWith(planner: Render3d.ScenePlan.Planner, cache: Render3d.StaticRows.Cache[Int32], gen: Int64, g: Scene3d.StaticGroup,
                   steps: BuildSteps[Int32]): Int32 \ IO =
        ensure(planner, cache, gen, g, "", false, sceneOf(Nil), steps)

    /// 集まり g を世代 gens の順に lookup し、作った回数を返す。
    def buildsOver(gens: List[(Int64, Scene3d.StaticGroup)]): Int32 \ IO =
        let cache = freshCache();
        let builds = Ref.fresh(Static, 0);
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let steps = countingSteps(builds, _ -> (), 0i64);
        gens |> List.forEach(match (gen, g) -> discard ensureWith(planner, cache, gen, g, steps));
        Ref.get(builds)

    // ── 前のコマの行を使うか ──

    /// 同じ集まりの値を毎コマ渡すと、作るのは最初の 1 回だけ。
    @Test
    def testSameGroupValueBuildsOnce(): Unit \ {Assert, IO} =
        let g = town();
        Assert.assertEq(expected = 1, buildsOver((1i64, g) :: (2i64, g) :: (3i64, g) :: Nil))

    /// 同じ中身でも staticGroup を作り直した値は、別の集まりとして作り直す（中身は比べない）。
    @Test
    def testRemadeGroupValueRebuilds(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, buildsOver((1i64, town()) :: (2i64, town()) :: Nil))

    /// 外す鍵が変わったコマは作り直し、同じ鍵のままのコマは作り直さない。
    @Test
    def testRemovedKeysChangeRebuilds(): Unit \ {Assert, IO} =
        let g = town();
        let without = (keys: Set[String]) -> Scene3d.withoutItems(keys, g);
        Assert.assertEq(expected = 2, buildsOver((1i64, g) :: (2i64, without(Set#{"b"})) :: (3i64, without(Set#{"b"})) :: Nil))

    /// tint が変わったコマは作り直す。
    @Test
    def testTintChangeRebuilds(): Unit \ {Assert, IO} =
        let g = town();
        let tinted = Scene3d.withGroupTint(Color.rgb(1.0, 0.5, 0.5), g);
        Assert.assertEq(expected = 2, buildsOver((1i64, g) :: (2i64, tinted) :: (3i64, tinted) :: Nil))

    /// 同じ名前で中身の違う集まりを 1 コマに 2 つ描くと、両方を控え（今のコマで使った物は手放さない）、次のコマからは作り直さない。
    @Test
    def testSameNameTwoGroupsInOneFrameAreBothKept(): Unit \ {Assert, IO} =
        let g = town();
        let tinted = Scene3d.withGroupTint(Color.rgb(1.0, 0.5, 0.5), g);
        let retired = Ref.fresh(Static, 0);
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let builds = Ref.fresh(Static, 0);
        let steps = countingSteps(builds, _ -> Ref.put(Ref.get(retired) + 1, retired), 0i64);
        List.range(1, 4) |> List.forEach(gen -> (g :: tinted :: Nil) |> List.forEach(x -> discard ensureWith(planner, cache, Int32.toInt64(gen), x, steps)));
        Assert.assertEq(expected = (2, 0, 2), (Ref.get(builds), Ref.get(retired), sizeOf(cache)))

    /// 作り直す時は、前の物を destroy に渡す。
    @Test
    def testRebuildDestroysOldPayload(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let destroyed = Ref.fresh(Static, Nil);
        let steps = countingSteps(Ref.fresh(Static, 0), p -> Ref.put(p :: Ref.get(destroyed), destroyed), 0i64);
        discard ensureWith(planner, cache, 1i64, town(), steps);
        discard ensureWith(planner, cache, 2i64, town(), steps);
        Assert.assertEq(expected = 1 :: Nil, Ref.get(destroyed))

    /// しばらく描かなかった集まりは sweep が destroy して外し、描いた集まりは残す。
    @Test
    def testSweepDropsIdleGroups(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let destroyed = Ref.fresh(Static, Nil);
        let destroy = (p: Int32) -> Ref.put(p :: Ref.get(destroyed), destroyed);
        let steps = countingSteps(Ref.fresh(Static, 0), destroy, 0i64);
        let kept = town();
        discard ensureWith(planner, cache, 1i64, Scene3d.staticGroup("gone", ("x", boxAt(1.0)) :: Nil), steps);
        discard ensureWith(planner, cache, 1i64, kept, steps);
        discard ensureWith(planner, cache, 10i64, kept, steps);
        sweep(cache, 10i64, 5i64, destroy);
        Assert.assertEq(expected = (1 :: Nil, 1), (Ref.get(destroyed), sizeOf(cache)))

    /// 同じ名前の集まりを上限のコマ数続けて作り直すと、名前ごとに 1 回知らせる。
    @Test
    def testRebuildStreakWarnsOnce(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 0i64);
        let said = stderrOf(() -> List.range(1, 70) |> List.forEach(gen -> discard ensureWith(planner, cache, Int32.toInt64(gen), town(), steps)));
        Assert.assertEq(expected = 2, List.length(String.split(regex = "'town'", said)))

    /// 作り直しが続かなければ知らせない。
    @Test
    def testSteadyGroupDoesNotWarn(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let g = town();
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 0i64);
        List.range(1, 40) |> List.forEach(gen -> discard ensureWith(planner, cache, Int32.toInt64(gen), g, steps));
        Assert.assertFalse(Set.memberOf("@staticGroup:town", Ref.get(planner#sceneWarnedRef)))

    // ── 少しずつ作る ──

    /// steps で集まりを世代 gens の順に引いた答えの並び（色の場面）。
    def answersOver(steps: BuildSteps[Int32], cache: Render3d.StaticRows.Cache[Int32], gens: List[(Int64, Scene3d.StaticGroup)]): List[Int32] \ IO =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        gens |> List.map(match (gen, g) -> ensureWith(planner, cache, gen, g, steps))

    /// staticGroup を作り直した集まりは、作り終えるまで前の控えの物を返し、作り終えたコマから新しい物を返す。
    @Test
    def testRemadeGroupShowsPreviousUntilBuilt(): Unit \ {Assert, IO} =
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 4i64);
        let next = town();
        let answers = answersOver(steps, freshCache(), (1i64, town()) :: List.map(gen -> (Int32.toInt64(gen), next), List.range(2, 8)));
        Assert.assertEq(expected = (1, 1, 2), (List.head(answers) |> Option.getWithDefault(0), List.nth(1, answers) |> Option.getWithDefault(0),
                                               List.last(answers) |> Option.getWithDefault(0)))

    /// 作り直しの間も前の控えを手放さず、作り終えたコマで手放す。
    @Test
    def testPreviousIsRetiredWhenRebuildFinishes(): Unit \ {Assert, IO} =
        let retired = Ref.fresh(Static, Nil);
        let steps = countingSteps(Ref.fresh(Static, 0), p -> Ref.put(p :: Ref.get(retired), retired), 4i64);
        let next = town();
        let cache = freshCache();
        let answers = answersOver(steps, cache, (1i64, town()) :: (2i64, next) :: Nil);
        let whileBuilding = Ref.get(retired);
        discard answersOver(steps, cache, List.map(gen -> (Int32.toInt64(gen), next), List.range(3, 8)));
        Assert.assertEq(expected = (1 :: 1 :: Nil, Nil, 1 :: Nil, 0), (answers, whileBuilding, Ref.get(retired), buildingCountOf(cache)))

    /// 同じ items の値で外した鍵だけが替わった集まりは、前の控えを描かずにそのコマで作る。
    @Test
    def testRemovedKeysBuildInOneFrame(): Unit \ {Assert, IO} =
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 4i64);
        let g = town();
        Assert.assertEq(expected = 1 :: 2 :: Nil, answersOver(steps, freshCache(), (1i64, g) :: (2i64, Scene3d.withoutItems(Set#{"b"}, g)) :: Nil))

    /// 作り終える前に毎コマ別の値へ替わり続けると、始め直しの上限の後はそのコマで作る。
    @Test
    def testEndlessRemakesBuildInOneFrame(): Unit \ {Assert, IO} =
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 4i64);
        let answers = answersOver(steps, freshCache(), List.range(1, 7) |> List.map(gen -> (Int32.toInt64(gen), town())));
        Assert.assertEq(expected = 1 :: 1 :: 1 :: 1 :: 2 :: 3 :: Nil, answers)

    /// 作るのが遅くても、毎コマ別の値を渡し続ければ作り直しの知らせが出る。
    @Test
    def testSlowEndlessRemakesStillWarn(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 4i64);
        let cache = freshCache();
        discard stderrOf(() -> List.range(1, 40) |> List.forEach(gen -> discard ensureWith(planner, cache, Int32.toInt64(gen), town(), steps)));
        Assert.assertTrue(Set.memberOf("@staticGroup:town", Ref.get(planner#sceneWarnedRef)))

    /// 同じ集まりの色の場面の行を作り直しても、奥行きの書き出しの場面の前の控えは手放さない（その場面はまだ前の控えを描く）。
    @Test
    def testRebuildKeepsOtherVariantEntry(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let retired = Ref.fresh(Static, Nil);
        let steps = countingSteps(Ref.fresh(Static, 0), p -> Ref.put(p :: Ref.get(retired), retired), 0i64);
        let cache = freshCache();
        let g = town();
        discard ensure(planner, cache, 1i64, g, "color", false, sceneOf(Nil), steps);
        discard ensure(planner, cache, 1i64, g, "depth", false, sceneOf(Nil), steps);
        let next = town();
        discard ensure(planner, cache, 2i64, next, "color", false, sceneOf(Nil), steps);
        Assert.assertEq(expected = (1 :: Nil, 2), (Ref.get(retired), sizeOf(cache)))

    /// 置き終えて絵を上げている途中の作りかけも、clear が置いた物を 1 回だけ手放して外す。
    @Test
    def testClearRetiresPlacedWork(): Unit \ {Assert, IO} =
        let retired = Ref.fresh(Static, Nil);
        let retire = (p: Int32) -> Ref.put(p :: Ref.get(retired), retired);
        let steps = { uploadCount = _ -> 1, uploadAt = (_, _) -> Thread.sleep(20i64) | countingSteps(Ref.fresh(Static, 0), retire, 0i64) };
        let cache = freshCache();
        let shown = answersOver(steps, cache, (1i64, town()) :: (2i64, town()) :: Nil);
        let building = buildingCountOf(cache);
        Render3d.StaticRows.clear(cache, retire);
        Assert.assertEq(expected = (1 :: 1 :: Nil, 1, Set#{1, 2}, 2, 0), (shown, building, List.toSet(Ref.get(retired)), List.length(Ref.get(retired)), buildingCountOf(cache)))

    /// 長く進めなかった作りかけは sweep が外す。
    @Test
    def testSweepDropsIdleWork(): Unit \ {Assert, IO} =
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 4i64);
        let cache = freshCache();
        discard answersOver(steps, cache, (1i64, town()) :: (2i64, town()) :: Nil);
        let before = buildingCountOf(cache);
        sweep(cache, 20i64, 5i64, _ -> ());
        Assert.assertEq(expected = (1, 0), (before, buildingCountOf(cache)))

    /// 作り直しの途中で前の値へ戻ると、作りかけを捨てる。
    @Test
    def testReturningToPreviousDropsWork(): Unit \ {Assert, IO} =
        let steps = countingSteps(Ref.fresh(Static, 0), _ -> (), 4i64);
        let cache = freshCache();
        let g = town();
        let answers = answersOver(steps, cache, (1i64, g) :: (2i64, town()) :: (3i64, g) :: Nil);
        Assert.assertEq(expected = (1 :: 1 :: 1 :: Nil, 0), (answers, buildingCountOf(cache)))

    /// 形の違う箱 20 個の集まり name（呼ぶたびに別の値）。
    def boxes(name: String): Scene3d.StaticGroup =
        Scene3d.staticGroup(name, List.range(1, 21) |> List.map(k -> (Int32.toString(k), boxAt(Int32.toFloat64(k)))))

    /// 予算を使い切ったコマの最低の時間は、そのコマで最初に来た作りかけ 1 つだけが使い、後の作りかけは 1 段だけ進む。
    @Test
    def testMinimumStepGoesToOneWorkPerFrame(): Unit \ {Assert, IO} =
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let cache = freshCache();
        let made = Ref.fresh(Static, 0);
        let counted = (n: Ref[Int32, Static]) -> { prepareMesh = (_: Mesh3d.Mesh3d) -> { Thread.sleep(1i64); Ref.put(Ref.get(n) + 1, n) } | countingSteps(made, _ -> (), 0i64) };
        let (a, b, c) = (Ref.fresh(Static, 0), Ref.fresh(Static, 0), Ref.fresh(Static, 0));
        (("a", a) :: ("b", b) :: ("c", c) :: Nil) |> List.forEach(match (name, _) -> discard ensureWith(planner, cache, 1i64, boxes(name), countingSteps(made, _ -> (), 0i64)));
        (("a", a) :: ("b", b) :: ("c", c) :: Nil) |> List.forEach(match (name, n) -> discard ensureWith(planner, cache, 2i64, boxes(name), counted(n)));
        Assert.assertEq(expected = (true, 1), (Ref.get(a) > 1, Ref.get(c)))

    /// 1 段ずつ何コマもかけて作った行は、1 回で作った行と同じ（行・1 体ごとの値・影の地図の行）。
    @Test
    def testSteppedRowsEqualOneShotRows(): Unit \ {Assert, IO} =
        let answer = (requests: Vector[Render3d.ScenePlan.MaterialRequest]) -> Vector.map(_ -> 3, requests);
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let steps = { tables = freshTables(), resolve = answer, prepareMesh = _ -> (), prepareMaterial = _ -> (), place = (rows: CarriedRows) -> rows,
                      uploadCount = _ -> 0, uploadAt = (_, _) -> (), retire = _ -> () };
        let b = startBuild(planner, false, sceneOf(Nil), city());
        let stepped = stepUntilBuilt(planner, steps, b, 0);
        let once = build(freshPlanner(Render3d.DrawMode.Instanced), freshTables(), answer, false, sceneOf(Nil), city());
        let shape = (r: CarriedRows) -> (Array.toList(r#list#rows), Array.toList(r#shadowList#rows), r#instanceCount, Array.toList(r#list#values), r#timeAt,
                                         Vector.length(r#requests), r#placed, List.map(i -> r#instances.get(i), List.range(0, r#instances.capacity())));
        Assert.assertEq(expected = (shape(once), true), (shape(stepped), Ref.get(b#phase) == Render3d.StaticRows.BuildPhase.Done))

    /// 形 7 種・材質 2 種の物 80 個の集まり（候補分けの区切り groupChunk をまたぐ）。
    def city(): Scene3d.StaticGroup =
        let shapes = List.range(1, 8) |> List.map(k -> boxAt(Int32.toFloat64(k)));
        Scene3d.staticGroup("city", List.range(0, 80) |> List.map(i -> {
            let base = List.nth(Int32.modulo(i, 7), shapes) |> Option.getWithDefault(boxAt(1.0));
            let f = Scene3d.instanceFieldsOf(base);
            let placed = Scene3d.meshInstance(f#mesh, Mat4.translate(Vec3.v3(Int32.toFloat64(i), 0.0, 0.0)))
                |> Scene3d.withMaterial(materialOf(if (Int32.modulo(i, 3) == 0) 0.3 else 0.1));
            (Int32.toString(i), placed)
        }))

    /// b を、毎回時計の限りを過ぎた（1 つずつしか進めない）ことにして作り終えるまで進める（calls = 呼んだ回数・上限 1000 回）。
    def stepUntilBuilt(planner: Render3d.ScenePlan.Planner, steps: BuildSteps[CarriedRows], b: Render3d.StaticRows.Build[CarriedRows], calls: Int32): CarriedRows \ IO =
        match stepBuild(planner, steps, b, 0i64) {
            case Some(rows) => rows
            case None       => if (calls > 1000) bug!("1000 回進めても作り終えない") else stepUntilBuilt(planner, steps, b, calls + 1)
        }

    // ── 持ち越す物と毎コマの物 ──

    /// 半透明の物と骨つきの物は持ち越さない。
    @Test
    def testBlendedAndSkinnedAreNotCarried(): Unit \ Assert =
        Assert.assertEq(expected = (true, false, false), (isCarriedItem(boxAt(1.0)), isCarriedItem(glass()), isCarriedItem(skinnedAt(poseAt(0.0)))))

    def built(g: Scene3d.StaticGroup): CarriedRows \ IO =
        let answer = (requests: Vector[Render3d.ScenePlan.MaterialRequest]) -> Vector.map(_ -> 3, requests);
        build(freshPlanner(Render3d.DrawMode.Instanced), freshTables(), answer, false, sceneOf(Nil), g)

    /// 集まりの持ち越さない物は perFrame に入り、色の場面の計画へ instances の後ろに通る。
    @Test
    def testPerFrameOfAddsNotCarriedItemsAfterInstances(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("mix", ("a", boxAt(1.0)) :: ("g", glass() |> Scene3d.withName("glass")) :: Nil);
        let walker = boxAt(5.0) |> Scene3d.withName("walker");
        let scene = { instances = walker :: Nil, groups = g :: Nil | sceneOf(Nil) };
        Assert.assertEq(expected = "walker" :: "glass" :: Nil, perFrameOf(scene, built(g) :: Nil) |> List.map(Scene3d.nameOf))

    def depthScene(): Scene3d.Scene3dCmd = { output = Scene3d.Output.Depth({ near = 0.1, range = 10.0 }) | sceneOf(Nil) }

    def builtDepth(g: Scene3d.StaticGroup): CarriedRows \ IO =
        let answer = (requests: Vector[Render3d.ScenePlan.MaterialRequest]) -> Vector.map(_ -> 3, requests);
        build(freshPlanner(Render3d.DrawMode.Instanced), freshTables(), answer, false, { groups = g :: Nil | depthScene() }, g)

    /// 奥行きの書き出しの場面も集まりを持ち越し、計画へ通すのは instances と持ち越さない物だけ。
    @Test
    def testDepthScenePerFrameOmitsCarriedItems(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("mix", ("a", boxAt(1.0)) :: ("g", glass() |> Scene3d.withName("glass")) :: Nil);
        let walker = boxAt(5.0) |> Scene3d.withName("walker");
        let scene = { instances = walker :: Nil, groups = g :: Nil | depthScene() };
        Assert.assertEq(expected = "walker" :: "glass" :: Nil, perFrameOf(scene, builtDepth(g) :: Nil) |> List.map(Scene3d.nameOf))

    /// 色の場面と奥行きの書き出しの場面は、持ち越しの控えの鍵が違う（同じ集まりでも別の行）。
    @Test
    def testDepthAndColorScenesUseDifferentKeys(): Unit \ Assert =
        Assert.assertFalse(carriedKeyOf(false, sceneOf(Nil)) == carriedKeyOf(false, depthScene()))

    /// alpha to coverage の版で作る行は、版を聞かない行と控えの鍵が違う。
    @Test
    def testCoverageChangesKey(): Unit \ Assert =
        Assert.assertFalse(carriedKeyOf(false, sceneOf(Nil)) == carriedKeyOf(true, sceneOf(Nil)))

    /// 奥行きの書き出しの場面の行は、cutout でも両面でもない材質の物を頂点の色の行で描く（材質を問い合わせない）。
    @Test
    def testDepthRowsDrawPlainMaterialsAsShapes(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0, Vector.length(builtDepth(town())#requests))

    /// 奥行きの書き出しの場面の行は影の地図の行を持たない（その場面は影の地図を描かない）。
    @Test
    def testDepthRowsHaveNoShadowRows(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 0, rowCountOf(builtDepth(town())#shadowList))

    /// 持ち越す行は外した鍵の物を描かない。
    @Test
    def testBuildSkipsRemovedItems(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, built(Scene3d.withoutItems(Set#{"a"}, town()))#placed)

    /// 視錐台の外の物も間引かずに持ち越す（目が動いても作り直さない）。
    @Test
    def testBuildDoesNotCullOutsideFrustum(): Unit \ {Assert, IO} =
        let behind = Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(0.0, 0.0, -50.0))) |> Scene3d.withMaterial(materialOf(0.1));
        let rows = built(Scene3d.staticGroup("behind", ("z", behind) :: Nil));
        Assert.assertEq(expected = (1, 1), (rowCountOf(rows#list), countAt(rows#list, 0)))

    /// 前の行と同じ付け方の行は、前の行の値を指す（時刻を書き直す区画は 1 つ）。
    @Test
    def testSameBindingRowsShareValues(): Unit \ {Assert, IO} =
        let rows = built(town());
        let list = rows#list;
        let shared = List.range(1, rowCountOf(list)) |> List.forAll(row -> hasFlag(list, row, flagSameBinding()) and valuesAt(list, row) == valuesAt(list, 0));
        Assert.assertEq(expected = (3, true, 1), (rowCountOf(list), shared, Vector.length(rows#timeAt)))

    /// 影の地図の行は持ち越す物の形ごとに 1 行。
    @Test
    def testShadowRowsCoverEveryShape(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 3, rowCountOf(built(town())#shadowList))

    /// 時刻が変わると値の uTime を書き直して真、同じなら偽。
    @Test
    def testSetTimeWritesOnlyWhenTimeChanges(): Unit \ {Assert, IO} =
        let rows = built(town());
        let at = Vector.head(rows#timeAt) |> Option.getWithDefault(0);
        let changed = setTime(rows, 2.5);
        let again = setTime(rows, 2.5);
        Assert.assertEq(expected = (true, false, 2.5f32), (changed, again, Array.get(at, rows#list#values)))

    /// 目の位置が違う場面から作っても、行は同じ（持ち越した行は目に依らない）。
    @Test
    def testRowsDoNotDependOnCamera(): Unit \ {Assert, IO} =
        let answer = (requests: Vector[Render3d.ScenePlan.MaterialRequest]) -> Vector.map(_ -> 3, requests);
        let at = (eye: Vec3.Vec3) -> {
            let scene = Scene3d.scene({ eye = eye | camera() }, { x = 64.0, y = 64.0 });
            let rows = build(freshPlanner(Render3d.DrawMode.Instanced), freshTables(), answer, false, scene, town());
            Array.toList(rows#list#rows)
        };
        Assert.assertEq(expected = at(Vec3.v3(0.0, 0.0, -5.0)), at(Vec3.v3(40.0, 10.0, 30.0)))

    // ── GL の描き手 ──

    /// GL の描き手は同じ集まりを毎コマ描いても、1 体ごとの値のテクスチャを上げるのは最初の 1 回だけ。
    @Test
    def testGlUploadsGroupValuesOnce(): Unit \ {Assert, IO} =
        let log = freshRecorded();
        let gl = recordingGl(log);
        let state = freshState();
        let scene = { groups = town() :: Nil | sceneOf(Nil) };
        List.range(0, 3) |> List.forEach(_ -> paint(gl, state, cmdOf(scene) :: Nil));
        Assert.assertEq(expected = 1, timesCalled("texSubImageRgba32f", log))

    /// GL の描き手で同じ集まりを色の場面と奥行きの書き出しの場面で描くと、控えは 2 つ（行の決め方が違う）。
    @Test
    def testGlKeepsColorAndDepthRowsApart(): Unit \ {Assert, IO} =
        let gl = recordingGl(freshRecorded());
        let state = freshState();
        let g = town();
        let color = { groups = g :: Nil | sceneOf(Nil) };
        let depth = { groups = g :: Nil | depthScene() };
        paint(gl, state, cmdOf(color) :: cmdOf(depth) :: Nil);
        Assert.assertEq(expected = 2, Render3d.GlStatic.sizeOf(state#statics))
}
