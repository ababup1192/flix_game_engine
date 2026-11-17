// 動かない物の集まりの持ち越し（Render3d.StaticRows）: いつ前のコマの行を使い、いつ作り直すか・持ち越す物と毎コマの物の分け方・持ち越す行の値。
mod Render3d.TestStaticRows {
    use Render3d.FakeGl.{camera, plainTriangle, poseAt, sceneOf, skinnedAt, stderrOf}
    use Render3d.SceneList.{flagSameBinding, hasFlag, rowAt, rowCountOf, valuesAt}
    use Render3d.ScenePlan.{freshPlanner}
    use Render3d.StaticRows.{CarriedRows, build, carriedGroupsOf, ensure, freshCache, isCarriedItem, perFrameOf, setTime, sizeOf, sweep}

    def noRegistered(_name: String): Option[Scene3dRenderer.RegisteredTexture] \ IO = checked_ecast(None)

    def freshTables(): Render3d.SceneList.Tables \ IO =
        { meshes = Render3d.MeshTable.fresh(), textures = Render3d.TextureTable3d.fresh(), layouts = Render3d.MaterialValues.freshLayouts(), gen = 1i64,
          gpuMip = false, textureOf = noRegistered }

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

    /// 集まり g を世代 gens の順に lookup し、作った回数を返す（作るたびに 1 足した数を payload にする）。
    def buildsOver(gens: List[(Int64, Scene3d.StaticGroup)]): Int32 \ IO =
        let cache = freshCache();
        let builds = Ref.fresh(Static, 0);
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        gens |> List.forEach(match (gen, g) -> discard ensure(planner, cache, gen, g, "", () -> { Ref.put(Ref.get(builds) + 1, builds); Ref.get(builds) }, _ -> ()));
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
        List.range(1, 4) |> List.forEach(gen -> (g :: tinted :: Nil) |> List.forEach(x ->
            discard ensure(planner, cache, Int32.toInt64(gen), x, "", () -> { Ref.put(Ref.get(builds) + 1, builds); 0 }, _ -> Ref.put(Ref.get(retired) + 1, retired))));
        Assert.assertEq(expected = (2, 0, 2), (Ref.get(builds), Ref.get(retired), sizeOf(cache)))

    /// 作り直す時は、前の物を destroy に渡す。
    @Test
    def testRebuildDestroysOldPayload(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let destroyed = Ref.fresh(Static, Nil);
        let destroy = (p: Int32) -> Ref.put(p :: Ref.get(destroyed), destroyed);
        discard ensure(planner, cache, 1i64, town(), "", () -> 1, destroy);
        discard ensure(planner, cache, 2i64, town(), "", () -> 2, destroy);
        Assert.assertEq(expected = 1 :: Nil, Ref.get(destroyed))

    /// しばらく描かなかった集まりは sweep が destroy して外し、描いた集まりは残す。
    @Test
    def testSweepDropsIdleGroups(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let destroyed = Ref.fresh(Static, Nil);
        let destroy = (p: Int32) -> Ref.put(p :: Ref.get(destroyed), destroyed);
        let kept = town();
        discard ensure(planner, cache, 1i64, Scene3d.staticGroup("gone", ("x", boxAt(1.0)) :: Nil), "", () -> 7, destroy);
        discard ensure(planner, cache, 1i64, kept, "", () -> 8, destroy);
        discard ensure(planner, cache, 10i64, kept, "", () -> 9, destroy);
        sweep(cache, 10i64, 5i64, destroy);
        Assert.assertEq(expected = (7 :: Nil, 1), (Ref.get(destroyed), sizeOf(cache)))

    /// 同じ名前の集まりを上限のコマ数続けて作り直すと、名前ごとに 1 回知らせる。
    @Test
    def testRebuildStreakWarnsOnce(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let said = stderrOf(() -> List.range(1, 70) |> List.forEach(gen -> discard ensure(planner, cache, Int32.toInt64(gen), town(), "", () -> gen, _ -> ())));
        Assert.assertEq(expected = 2, List.length(String.split(regex = "'town'", said)))

    /// 作り直しが続かなければ知らせない。
    @Test
    def testSteadyGroupDoesNotWarn(): Unit \ {Assert, IO} =
        let cache = freshCache();
        let planner = freshPlanner(Render3d.DrawMode.Instanced);
        let g = town();
        List.range(1, 40) |> List.forEach(gen -> discard ensure(planner, cache, Int32.toInt64(gen), g, "", () -> gen, _ -> ()));
        Assert.assertFalse(Set.memberOf("@staticGroup:town", Ref.get(planner#sceneWarnedRef)))

    // ── 持ち越す物と毎コマの物 ──

    /// 半透明の物と骨つきの物は持ち越さない。
    @Test
    def testBlendedAndSkinnedAreNotCarried(): Unit \ Assert =
        Assert.assertEq(expected = (true, false, false), (isCarriedItem(boxAt(1.0)), isCarriedItem(glass()), isCarriedItem(skinnedAt(poseAt(0.0)))))

    def built(g: Scene3d.StaticGroup): CarriedRows \ IO =
        let answer = (requests: Vector[Render3d.ScenePlan.MaterialRequest]) -> Vector.map(_ -> 3, requests);
        build(freshPlanner(Render3d.DrawMode.Instanced), freshTables(), answer, sceneOf(Nil), g)

    /// 集まりの持ち越さない物は perFrame に入り、色の場面の計画へ instances の後ろに通る。
    @Test
    def testPerFrameOfAddsNotCarriedItemsAfterInstances(): Unit \ {Assert, IO} =
        let g = Scene3d.staticGroup("mix", ("a", boxAt(1.0)) :: ("g", glass() |> Scene3d.withName("glass")) :: Nil);
        let walker = boxAt(5.0) |> Scene3d.withName("walker");
        let scene = { instances = walker :: Nil, groups = g :: Nil | sceneOf(Nil) };
        Assert.assertEq(expected = "walker" :: "glass" :: Nil, perFrameOf(scene, built(g) :: Nil) |> List.map(Scene3d.nameOf))

    /// 奥行きの書き出しの場面は集まりを持ち越さず、全部を計画へ通す。
    @Test
    def testDepthSceneCarriesNothing(): Unit \ Assert =
        let g = town();
        let scene = { groups = g :: Nil, output = Scene3d.Output.Depth({ near = 0.1, range = 10.0 }) | sceneOf(Nil) };
        Assert.assertEq(expected = (0, 3), (List.length(carriedGroupsOf(scene)), List.length(perFrameOf(scene, Nil))))

    /// 持ち越す行は外した鍵の物を描かない。
    @Test
    def testBuildSkipsRemovedItems(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = 2, built(Scene3d.withoutItems(Set#{"a"}, town()))#placed)

    /// 視錐台の外の物も間引かずに持ち越す（目が動いても作り直さない）。
    @Test
    def testBuildDoesNotCullOutsideFrustum(): Unit \ {Assert, IO} =
        let behind = Scene3d.meshInstance(plainTriangle(), Mat4.translate(Vec3.v3(0.0, 0.0, -50.0))) |> Scene3d.withMaterial(materialOf(0.1));
        let rows = built(Scene3d.staticGroup("behind", ("z", behind) :: Nil));
        Assert.assertEq(expected = (1, 1), (rowCountOf(rows#list), rowAt(rows#list, 0, 4)))

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
            let rows = build(freshPlanner(Render3d.DrawMode.Instanced), freshTables(), answer, scene, town());
            Array.toList(rows#list#rows)
        };
        Assert.assertEq(expected = at(Vec3.v3(0.0, 0.0, -5.0)), at(Vec3.v3(40.0, 10.0, 30.0)))
}
