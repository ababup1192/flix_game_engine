// ブラウザ版で後から届く鍵の解き方（Controls.withBackgroundLoads・Controls.decodeBudget）を、偽の downloads と App.stepBackgroundLoad で確かめる。
// 偽の downloads はどの道も届いている（Downloaded）と答える。人物の鍵は assets/characters の glb を本当に読んで解く。
// 校舎はテストの中に書いた 1 階だけの表で組み、少女（girl_student）を 1 階に置く。
mod TestBackgroundLoads {

    use fge::{App, BackgroundLoad, HeadlessLoad, LoadProgress, Model3d, Resources, Yarn}

    def layout(): Layout.Layout =
        Layout.fromJson("{\"floors\":[{\"index\":1,\"y\":0,\"colliders\":[{\"min\":[-10,-0.2,-10],\"max\":[10,0,10]}]}],\"spawn\":{\"pos\":[0,0,5],\"yaw\":0}}")
            |> Result.getWithDefault(Layout.empty())

    def cast(): CastDoc.Doc =
        CastDoc.fromJson("{\"characters\":[{\"id\":\"g\",\"model\":\"girl_student\",\"node\":\"girl\",\"pos\":[0,0,4],\"yaw\":180}]}")
            |> Option.getWithDefault(CastDoc.defaults())

    /// 1 階の建物の束（道は本物の束。偽の downloads が届いたと答えるだけで、このテストでは解かれない）。
    def bundles(): List[Bundles.Entry] =
        { key = "floor1", path = "assets/school/bundle/floor1.glb", floors = 1 :: Nil, buildings = 1 :: Nil } :: Nil

    def personKey(): String = Bundles.personKey("girl_student")

    /// どの道も Downloaded と答え、頼みと捨てと予算は聞き流す偽の downloads。
    def downloads(): LoadProgress.AssetDownloads =
        { stateOf = _ -> checked_ecast(LoadProgress.LoadState.Downloaded),
          request = _ -> checked_ecast(()),
          release = _ -> checked_ecast(()),
          setBudget = _ -> checked_ecast(()),
          spentMs = () -> checked_ecast(0.0) | LoadProgress.localDownloads() }

    def pendingOf(group: Bundles.Group, keys: List[String], costMs: Float64): BackgroundLoad.Pending =
        { group = group#name, states = keys |> List.map(k -> (k, LoadProgress.LoadState.Downloaded)) |> List.toMap,
          sentPriority = Nil, costMs = costMs, idleSinceMs = -1.0 }

    /// 束の見込みを bundleCostMs にした待ちの表と、届いた人物の鍵を持つ描く元。
    def resOf(bundleGroup: Bundles.Group, modelGroup: Bundles.Group, bundleCostMs: Float64, bundleKeys: List[String]): Res.Res =
        Res.build({ walk = WalkDoc.defaults(), keys = KeysDoc.defaults(), look = LookDoc.defaults(), sound = SoundDoc.defaults(), layout = layout(),
                    assets = { floors = Map.empty(), props = Map.empty(), surfaces = Map.empty() }, items = ItemsDoc.defaults(),
                    cast = cast(), people = Map.empty(), dialogue = Yarn.empty(), bundles = bundles(),
                    bundlePending = pendingOf(bundleGroup, bundleKeys, bundleCostMs),
                    modelPending = pendingOf(modelGroup, personKey() :: Nil, modelGroup#costMs) })

    def groups(): (Bundles.Group, Bundles.Group) \ {IO, Fs.FileRead} =
        let loader = HeadlessLoad.handle(() -> Model3d.loader());
        (Bundles.schoolGroup(bundles(), loader), Bundles.modelGroup("girl_student" :: Nil, Nil, loader))

    def appOf(res: Res.Res, bundleGroup: Bundles.Group, modelGroup: Bundles.Group): App.App[Resources.With[Res.Res, World.World], {}] =
        App.make(Resources.of(res, World.initial(res)))
            |> App.withDecodeBudget(Resources.read(Controls.decodeBudget))
            |> Controls.withBackgroundLoads({ bundleGroup = bundleGroup, modelGroup = modelGroup, downloads = downloads() })

    /// スマホで束を 1 本解いた後のように束の見込みが 180 ms へ上がっていても、届いた人物の鍵はそのコマで解かれ、少女の形が置かれる（束は始まらない）
    @Test
    def testPersonIsDecodedWhileBundleEstimateIsHigh(): Unit \ {Assert, IO} = run {
        let (bundleGroup, modelGroup) = groups();
        let res = resOf(bundleGroup, modelGroup, 180.0, "floor1" :: Nil);
        let stepped = App.stepBackgroundLoad(appOf(res, bundleGroup, modelGroup), Resources.of(res, World.initial(res)))#resources;
        Assert.assertEq(expected = (true, true, false),
                        (BackgroundLoad.isLoaded(personKey(), stepped#modelPending), Map.memberOf("girl_student", stepped#people),
                         BackgroundLoad.isLoaded("floor1", stepped#bundlePending)))
    } with Fs.FileRead.runWithIO

    /// 束が全部解けていても、描く階の人物が届いて待っていれば、遊んでいる最中の予算は Idle(45)
    @Test
    def testWaitingPersonRaisesTheBudget(): Unit \ {Assert, IO} = run {
        let (bundleGroup, modelGroup) = groups();
        let res = resOf(bundleGroup, modelGroup, bundleGroup#costMs, Nil);
        Assert.assertEq(expected = LoadProgress.DecodeBudget.Idle(45.0), Controls.decodeBudget(res, World.initial(res)))
    } with Fs.FileRead.runWithIO
}
