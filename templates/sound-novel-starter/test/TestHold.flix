// 素材の待ち（ブラウザ版で後回しにした背景・環境音が、使う時にまだ届いていない間の暗転）と、届いた絵を登録する予算の決まり。
// 届いていない名前は Res の missing（実機は Game.withAssetLoading が downloads#missing() から写す）を外から決めて流す。
// 写真・音の名前は Doc（novel.backdrops.json の texture・Stage.ambienceSound）から引き、秒は novel.kind.json から引く。
mod TestHold {

    use fge::{App, Clock, LoadProgress, Render, Resources}
    use TestKit.{advance, begun, quiet, readTo, readUntil, stepBy}

    def kind(res: Res.Res): KindDoc.Rec = KindDoc.rec(res#kind)

    /// names がまだ届いていない描く元。
    def missingOf(names: List[String], res: Res.Res): Res.Res = Res.withMissing(List.toSet(names), res)

    /// 写真の名前 → project.json の textures の名前。
    def texture(res: Res.Res, photo: String): String = BackdropDoc.textureOf(photo, res#backdrops) |> Option.getWithDefault("")

    /// 全部届いている描く元で、送れば Paddy のノードへ入る所（Station の最後の行を出し終えた所）。
    def beforePaddy(res: Res.Res): World.World =
        readUntil(res, cur -> World.talkNodeOf(advance(res, cur)) == "Paddy", Nil, begun(res))

    /// 今の背景の写真の名前。
    def photoOf(w: World.World): Option[String] =
        World.readOf(w) |> Option.flatMap(r -> r#stage#shot) |> Option.map(shot -> shot#photo)

    def storyNow(w: World.World): Float64 = Clock.secondsOf(World.now(w))

    def gaveUpOf(w: World.World): Set[String] = World.readOf(w) |> Option.map(r -> r#gaveUp) |> Option.getWithDefault(Set.empty())

    /// Paddy の背景（paddy）が届いていない描く元で送り、黒へ重ね切った所（Waiting）。
    def waitingForPaddy(res: Res.Res): World.World =
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        advance(held, beforePaddy(res)) |> stepBy(held, kind(res)#holdFadeSeconds + 0.01)

    /// dt 秒ずつ系を回し、until が真になった所（fuel で必ず止まる）。
    def stepsUntil(res: Res.Res, dt: Float64, until: World.World -> Bool, w: World.World): World.World =
        def go(fuel: Int32, cur: World.World): World.World =
            if (fuel <= 0 or until(cur)) cur else go(fuel - 1, stepBy(res, dt, cur));
        go(400, w)

    /// 偽の downloads: missing は Ref から引き、受けた予算を Ref に溜める。ほかは全部届いた機種と同じ。
    type alias Fake = {
        downloads = LoadProgress.AssetDownloads,
        missing = Ref[Set[String], Static],
        budgets = Ref[List[LoadProgress.DecodeBudget], Static]
    }

    def fakeOf(missing: Set[String]): Fake \ IO =
        let missingNow = Ref.fresh(Static, missing);
        let budgets = Ref.fresh(Static, Nil);
        let local = LoadProgress.localDownloads();
        { downloads = { missing = () -> Ref.get(missingNow),
                        setBudget = budget -> Ref.put(budget :: Ref.get(budgets), budgets) | local },
          missing = missingNow, budgets = budgets }

    // ══ 全部届いている ══

    @Test
    def testAllArrivedReadsToTheEndWithoutHolding(): Unit \ {Assert, Fs.FileRead} =
        // 全部届いていれば（デスクトップ・描き出し・テストの既定）、どの選択肢を選んでも一度も待たずにクレジットまで読み切る。
        let res = TestKit.res();
        let w = readUntil(res, World.isHolding, 0 :: 0 :: 0 :: 0 :: 0 :: 0 :: Nil, begun(res));
        Assert.assertEq(expected = (true, false), (World.isCredits(w), World.isHolding(w)))

    // ══ 未着の背景へ切り替える ══

    @Test
    def testUnarrivedBackdropHoldsBeforeTheCue(): Unit \ {Assert, Fs.FileRead} =
        // 届いていない写真へ切り替える所で送ると、黒へ重ね始め（FadingOut）、背景も行も前のまま（切り替えは届いてから）。
        let res = TestKit.res();
        let before = beforePaddy(res);
        let w = advance(missingOf(texture(res, "paddy") :: Nil, res), before);
        Assert.assertEq(expected = (Some(World.HoldPhase.FadingOut), photoOf(before), World.talkLineOf(before)),
                        (World.holdPhaseOf(w), photoOf(w), World.talkLineOf(w)))

    @Test
    def testHoldStopsTheStoryClockOnlyOnceDark(): Unit \ {Assert, Fs.FileRead} =
        // 黒へ重ねる間（holdFadeSeconds）は物語の時計が動き、重ね切ったら Waiting で止まる（1 秒回しても進まない）。
        let res = TestKit.res();
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let fading = advance(held, beforePaddy(res));
        let dark = stepBy(held, kind(res)#holdFadeSeconds + 0.01, fading);
        let later = stepBy(held, 1.0, dark);
        Assert.assertEq(expected = (Some(World.HoldPhase.Waiting), true, storyNow(dark)),
                        (World.holdPhaseOf(dark), storyNow(dark) > storyNow(fading), storyNow(later)))

    @Test
    def testHoldIgnoresAdvanceAndAuto(): Unit \ {Assert, Fs.FileRead} =
        // 待つ間は送っても動かず、オートも送らない（物語の時計が止まり、実行器も進めない）。
        let res = TestKit.res();
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let dark = waitingForPaddy(res) |> World.mapRead(r -> { playback = World.Playback.Auto | r });
        let w = advance(held, dark) |> stepBy(held, 5.0);
        Assert.assertEq(expected = (Some(World.HoldPhase.Waiting), World.talkLineOf(dark), World.Playback.Auto),
                        (World.holdPhaseOf(w), World.talkLineOf(w), World.playbackOf(w)))

    @Test
    def testArrivalFromTheDownloadsResumesTheCue(): Unit \ {Assert, Fs.FileRead, IO} =
        // 実機と同じ繋ぎ（Game.withAssetLoading と偽の downloads）: 黒のまま待つ間の予算は Covered、
        // 写真が届くと次のコマで missing が空になり、黒から戻し始め（FadingIn）、預けていた切り替えが当たって Paddy の写真と ADV になる。
        let res = TestKit.res();
        let paddy = texture(res, "paddy");
        let fake = fakeOf(Set#{paddy});
        let app = Game.withAssetLoading(fake#downloads, TestKit.app(res, TestKit.w0(res)));
        let dark = Resources.of(missingOf(paddy :: Nil, res), waitingForPaddy(res)) |> App.stepBackgroundLoad(app);
        let budget = List.head(Ref.get(fake#budgets));
        Ref.put(Set.empty(), fake#missing);
        let arrived = App.stepBackgroundLoad(app, dark);
        let w = stepBy(arrived#resources, 1.0 / 60.0, arrived#world);
        Assert.assertEq(expected = (Some(LoadProgress.DecodeBudget.Covered(50.0)), Set.empty(), Some(World.HoldPhase.FadingIn), Some("paddy"), Stage.Mode.Adv),
                        (budget, arrived#resources#missing, World.holdPhaseOf(w), photoOf(w), World.stageOf(res, w)#mode))

    @Test
    def testFadingInEndsTheHold(): Unit \ {Assert, Fs.FileRead} =
        // 届いた後、黒から戻す間はまだ送れず、戻し切ると（holdFadeSeconds）待ちが消えて、送れば文字送りの途中の行を全部出す。
        let res = TestKit.res();
        let resumed = stepBy(res, 1.0 / 60.0, waitingForPaddy(res));
        let w = stepBy(res, kind(res)#holdFadeSeconds + 0.01, resumed);
        let revealed = (cur: World.World) -> Page.isDone(World.pageOf(advance(res, cur)));
        Assert.assertEq(expected = (Some(World.HoldPhase.FadingIn), false, false, true),
                        (World.holdPhaseOf(resumed), revealed(resumed), World.isHolding(w), revealed(w)))

    @Test
    def testHoldGivesUpAfterTheLimit(): Unit \ {Assert, Fs.FileRead} =
        // 黒のまま holdGiveUpSeconds 待っても届かなければ、その写真を諦めて（gaveUp）無いまま切り替えを当て、黒から戻す。
        // 諦める手前の 1 秒前はまだ待っている。
        let res = TestKit.res();
        let paddy = texture(res, "paddy");
        let held = missingOf(paddy :: Nil, res);
        let almost = stepBy(held, kind(res)#holdGiveUpSeconds - 1.0, waitingForPaddy(res));
        let w = stepBy(held, 1.01, almost);
        Assert.assertEq(expected = (Some(World.HoldPhase.Waiting), Some(World.HoldPhase.FadingIn), Some("paddy"), true),
                        (World.holdPhaseOf(almost), World.holdPhaseOf(w), photoOf(w), Set.memberOf(paddy, gaveUpOf(w))))

    @Test
    def testGaveUpPhotoIsNotWaitedForAgain(): Unit \ {Assert, Fs.FileRead} =
        // 諦めた写真は、黒から戻した後も待ち直さない（届かないまま読み進める）。
        let res = TestKit.res();
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let w = stepBy(held, kind(res)#holdGiveUpSeconds + 0.01, waitingForPaddy(res))
            |> stepBy(held, kind(res)#holdFadeSeconds + 0.01) |> stepBy(held, 1.0 / 60.0);
        Assert.assertEq(expected = false, World.isHolding(w))

    // ══ 環境音と効果音 ══

    @Test
    def testUnarrivedAmbienceHoldsWithTheBackdrop(): Unit \ {Assert, Fs.FileRead} =
        // Engawa の頭は環境音と写真を続けて替える。どちらも届いていなければ、暗転 1 回で両方を待つ。
        let res = TestKit.res();
        let names = Stage.ambienceSound("night") :: texture(res, "engawa") :: Nil;
        let held = missingOf(names, res);
        let lane = readTo(res, "Lane", 0 :: Nil, begun(res));
        let w = readUntil(held, World.isHolding, Nil, lane);
        Assert.assertEq(expected = (Some(List.toSet(names)), "Engawa"),
                        (World.readOf(w) |> Option.flatMap(r -> r#hold) |> Option.map(h -> List.toSet(h#names)), World.talkNodeOf(w)))

    @Test
    def testUnarrivedSeIsSkippedSilently(): Unit \ {Assert, Fs.FileRead} =
        // 一発の効果音（<<se slap>>）は届いていなくても待たずに読み進め、鳴らす音からは外す（届いていれば鳴る）。
        let res = TestKit.res();
        let slap = "se_slap";
        let held = missingOf(slap :: Nil, res);
        let lane = readTo(res, "Lane", 0 :: Nil, begun(res));
        let (w, heard) = TestKit.readHearing(held, cur -> World.talkNodeOf(cur) == "Engawa", Nil, lane);
        Assert.assertEq(expected = ("Engawa", false, true),
                        (World.talkNodeOf(w), List.memberOf(slap, Controls.soundsOf(Set#{slap}, heard)), List.memberOf(slap, Controls.soundsOf(Set.empty(), heard))))

    // ══ スキップ・ロード・タイトル・サムネ ══

    @Test
    def testSkipPassesTheCueAndHoldsWhereItStops(): Unit \ {Assert, Fs.FileRead} =
        // スキップ中（設定で未読も飛ばす）は届いていない写真へ切り替えても待たずに進み、選択肢で止まった所で待ちに入る（続きは無い）。
        let res = TestKit.res();
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let everything = quiet(() -> WorldSettings.withSide(World.Pair.SkipScope, Layout.Side.Right, beforePaddy(res)));
        let skipping = quiet(() -> WorldRead.togglePlayback(World.Playback.Skip, everything));
        let w = stepsUntil(held, 0.1, World.isHolding, skipping);
        Assert.assertEq(expected = (true, World.Playback.Manual, Some("paddy"), Some(0)),
                        (World.isChoosing(w), World.playbackOf(w), photoOf(w),
                         World.readOf(w) |> Option.flatMap(r -> r#hold) |> Option.map(h -> List.length(h#rest))))

    @Test
    def testLoadingIntoAnUnarrivedPlaceHolds(): Unit \ {Assert, Fs.FileRead} =
        // タイトルからロードで戻った所の写真が届いていなければ、次のコマで待ちに入る。
        // 同じ所のサムネ（screenOf）は待ちを持たない（暗い地で描くだけで、パネルの絵は止まらない）。
        let res = TestKit.res();
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let atPaddy = readTo(res, "Paddy", Nil, begun(res));
        let mark = WorldRead.slotHere(res, atPaddy) |> Option.map(slot -> slot#mark);
        let loaded = mark |> Option.map(m -> quiet(() -> WorldRead.restore(held, m, World.toTitle(atPaddy))) |> stepBy(held, 1.0 / 60.0));
        let thumb = mark |> Option.map(m -> World.isHolding(WorldRead.screenOf(held, m, atPaddy)));
        Assert.assertEq(expected = (Some(Some(World.HoldPhase.FadingOut)), Some(false)),
                        (loaded |> Option.map(World.holdPhaseOf), thumb))

    @Test
    def testHoldDropsTheRailLongPress(): Unit \ {Assert, Fs.FileRead} =
        // 列を押したまま素材を待つ黒に入ったら、長押しを捨てる（明けた最初のフレームで「離した」と読まない）。
        let res = TestKit.res();
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let pressing = { grab = World.Grab.LongPress(0, Clock.zero()) | waitingForPaddy(res) };
        let w = Controls.interact({ viewport = Layout.size(Layout.Fit.Regular) | App.emptyFrame() }, held, pressing);
        Assert.assertEq(expected = World.Grab.Free, w#grab)

    @Test
    def testToTitleDropsTheHold(): Unit \ {Assert, Fs.FileRead} =
        // タイトルへ戻ると待ちは消える（タイトルの写真は後回しにしない決まりなので、タイトルでは待たない）。
        let res = TestKit.res();
        Assert.assertEq(expected = false, World.isHolding(World.toTitle(waitingForPaddy(res))))

    // ══ 届いた絵を登録する予算 ══

    @Test
    def testDecodeBudgetFollowsWhatIsOnScreen(): Unit \ {Assert, Fs.FileRead} =
        // タイトルとタップ待ちは Idle(4)（1 コマに 1 本と 4 ms）・文字送りの途中は Paused・待つ間は Covered(50)・クレジットは Paused。
        let res = TestKit.res();
        let budgetOf = (w: World.World) -> Controls.decodeBudget(Resources.of(res, w));
        let tapWait = begun(res);
        let typing = advance(res, tapWait) |> stepBy(res, 0.01);
        Assert.assertEq(expected = LoadProgress.DecodeBudget.Idle(4.0) :: LoadProgress.DecodeBudget.Idle(4.0) :: LoadProgress.DecodeBudget.Paused ::
                                   LoadProgress.DecodeBudget.Covered(50.0) :: LoadProgress.DecodeBudget.Paused :: Nil,
                        budgetOf(TestKit.w0(res)) :: budgetOf(tapWait) :: budgetOf(typing) :: budgetOf(waitingForPaddy(res)) ::
                        budgetOf(World.toCredits(res, tapWait)) :: Nil)


    // ══ 待ちの印（novel.theme.json の loadingMark） ══

    /// 待ちの印の形を mark に替えた描く元。
    def withLoadingMark(mark: ThemeDoc.LoadingMark, res: Res.Res): Res.Res =
        Res.withTheme(ThemeDoc.withLoadingMark(mark, res#theme), res)

    /// Paddy の背景を黒のまま待ち、waited 秒待った所。
    def waitedFor(res: Res.Res, waited: Float64): World.World =
        waitingForPaddy(res) |> World.mapRead(r -> { hold = r#hold |> Option.map(h -> { waited = waited | h }) | r })

    /// 描き出しと同じ字のアトラスで、横の画面の hud を組む。
    def hudOf(res: Res.Res, w: World.World): List[Render.PlacedItem] \ IO =
        let ctx = App.viewCtxOf(SceneRender.cfgOf("debug", Map.empty())#fontAtlas, SceneRender.design());
        View.hud(ctx, res, w)

    def textsOf(items: List[Render.PlacedItem]): List[String] =
        items |> List.filterMap(placed -> match placed#item {
            case Render.Item.Text(t) => Some(t#text)
            case _                   => None
        })

    /// 印が出る前（待ち始め）と、holdMarkSeconds を過ぎた所の hud の描き物の数。
    def markCounts(res: Res.Res): (Int32, Int32) \ IO =
        let marked = kind(res)#holdMarkSeconds + 0.5;
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        (List.length(hudOf(held, waitedFor(res, 0.0))), List.length(hudOf(held, waitedFor(res, marked))))

    @Test
    def testDotsMarkAppearsAfterHoldMarkSeconds(): Unit \ {Assert, Fs.FileRead, IO} =
        // loadingMark = dots: 黒のまま holdMarkSeconds を過ぎると、待ち始めより描き物が増える（点 3 つ）。
        let (before, after) = markCounts(withLoadingMark(ThemeDoc.LoadingMark.Dots, TestKit.res()));
        Assert.assertTrue(after > before)

    @Test
    def testRingMarkShowsTheWaitingLabel(): Unit \ {Assert, Fs.FileRead, IO} =
        // loadingMark = ring: holdMarkSeconds を過ぎた hud の字に、labels の waiting が入る。
        let res = withLoadingMark(ThemeDoc.LoadingMark.Ring, TestKit.res());
        let held = missingOf(texture(res, "paddy") :: Nil, res);
        let word = StoryDoc.labelOf(StoryDoc.Label.Waiting, res#story);
        let texts = textsOf(hudOf(held, waitedFor(res, kind(res)#holdMarkSeconds + 0.5)));
        Assert.assertTrue(List.memberOf(word, texts))

    @Test
    def testNoneMarkDrawsOnlyTheDark(): Unit \ {Assert, Fs.FileRead, IO} =
        // loadingMark = none: holdMarkSeconds を過ぎても描き物は待ち始めと同じ（黒の地だけ）。
        let (before, after) = markCounts(withLoadingMark(ThemeDoc.LoadingMark.Hidden, TestKit.res()));
        Assert.assertEq(expected = before, after)

    @Test
    def testOnlyTheThreeLoadingMarkWordsAreRead(): Unit \ Assert =
        // 読める字は dots / ring / none の 3 つだけ（ほかの字は Doc を読む時に 1 行知らせて dots へ落とす）。
        // WhyNot: 知らない字を fromJson に通して確かめない — 知らせの 1 行が標準エラーに出ると、テストの道具が失敗と数える。
        let read = ("dots" :: "ring" :: "none" :: "spinner" :: Nil) |> List.map(ThemeDoc.loadingMarkOf);
        Assert.assertEq(expected = Some(ThemeDoc.LoadingMark.Dots) :: Some(ThemeDoc.LoadingMark.Ring) :: Some(ThemeDoc.LoadingMark.Hidden) :: None :: Nil, read)
}
