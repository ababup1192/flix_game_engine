// TestLoadWait — App.Internal.LoadWait（ブラウザ版で届いていない後回しの物を App のループが待つ判断）の表のテスト。
// World は Int32（戻した先が分かるように、コマごとに違う数を渡す）。時刻は秒の数で渡す。
mod TestLoadWait {
    use App.Internal.LoadWait
    use App.Internal.LoadWait.{Show, Step, Input, Mode}
    use GameEngine.Key
    import java.lang.RuntimeException

    def settings(): LoadWait.Settings = LoadWait.defaultSettings()

    def live(): App.Frame = { dt = 0.016 | App.emptyFrame() }

    def pressOf(key: Key): App.Frame = { down = Set#{key}, justPressed = Set#{key} | live() }

    def press(): App.Frame = pressOf(Key.Enter)

    def keepRunning(): Int32 -> App.LoadWaitStyle = _ -> App.LoadWaitStyle.KeepRunning

    /// 照らす時の物（扱いの表は policies・押す前の World は loaded・store の記録は stored）。
    def ctxOf(missing: Set[String], policies: Map[String, LoadProgress.MissingPolicy], nowSec: Float64, frame: App.Frame,
              loaded: Int32, stored: List[Int32 -> Int32]): LoadWait.Context[Int32] =
        { missing = missing, policies = policies, nowSec = nowSec, frame = frame, loaded = loaded,
          stepState = App.freshStepState(), real = App.freshStepState()#real, stored = stored, styleOf = keepRunning() }

    def ctx(missing: Set[String], nowSec: Float64, frame: App.Frame, loaded: Int32): LoadWait.Context[Int32] =
        ctxOf(missing, Map.empty(), nowSec, frame, loaded, Nil)

    def candidate(names: Set[String], pressed: Bool): LoadWait.Candidate =
        { names = names, sounds = Nil, loops = Nil, failed = false, pressed = pressed, outputsChanged = false }

    def watch(missing: Set[String], nowSec: Float64): LoadWait.Watch =
        { missing = missing, failed = Set.empty(), codeReady = true, splash = false, nowSec = nowSec }

    def policy(onMissing: Option[LoadProgress.OnMissing], group: Option[String]): LoadProgress.MissingPolicy =
        { onMissing = onMissing, group = group }

    /// 答えの種類を字にする（Show は比べられないので）。
    def showText(show: Show[Int32]): String = match show {
        case Show.Candidate(sounds)      => "candidate ${sounds}"
        case Show.Loaded(sounds)         => "loaded ${sounds}"
        case Show.Restored(w, _, sounds) => "restored ${w} ${sounds}"
    }

    def stepText(step: Step): String = match step {
        case Step.Splash                    => "splash"
        case Step.Hold                      => "hold"
        case Step.Advance(Input.Live)       => "live"
        case Step.Advance(Input.Idle)       => "idle"
        case Step.Advance(Input.Replay(f))  => "replay ${Set.toList(f#justPressed)}"
    }

    def modeText(state: LoadWait.State[Int32]): String = match state#mode {
        case Mode.Idle         => "idle"
        case Mode.Waiting(wt)  => if (wt#pressed) "pressed-wait" else "stopped-wait"
        case Mode.Replaying(frames) => "replaying ${List.length(frames)}"
    }

    /// 押したコマで bg に当たって押した時の待ちに入った状態（押す前の World は 5・時刻 0）。
    def pressedWait(missing: Set[String]): LoadWait.State[Int32] =
        snd(LoadWait.decide(candidate(Set#{"bg"}, true), ctx(missing, 0.0, press(), 5), LoadWait.initial()))

    // ========================================================================
    // 押した時の待ち（押した所まで戻して待つ）
    // ========================================================================

    /// 押したコマの候補が届いていない絵を使うと、候補を捨てて押す前の World へ戻す
    @Test
    def testPressFrameHittingAPictureRestores(): Unit \ Assert =
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, true), ctx(Set#{"bg"}, 0.0, press(), 5), LoadWait.initial());
        Assert.assertEq(expected = "restored 5 Nil", showText(show))

    /// 押したコマの候補が当たると、押した時の待ちに入る
    @Test
    def testPressFrameHittingAPictureStartsAPressedWait(): Unit \ Assert =
        Assert.assertEq(expected = "pressed-wait", modeText(pressedWait(Set#{"bg"})))

    /// 押したコマを出した後、控えの中の数コマ後に当たっても、押す前の World（控え）へ戻す
    @Test
    def testHitInsideTheWindowRestoresTheSnapshot(): Unit \ Assert =
        let (_, pressed) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, press(), 1), LoadWait.initial());
        let (_, later) = LoadWait.decide(candidate(Set.empty(), false), ctx(Set#{"bg"}, 0.2, live(), 2), pressed);
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, false), ctx(Set#{"bg"}, 0.4, live(), 3), later);
        Assert.assertEq(expected = "restored 1 Nil", showText(show))

    /// 控えの間に押し直しても控えは取り直さない（暗転の途中で押し直しても、最初に押す前の World へ戻す）
    @Test
    def testPressAgainKeepsTheFirstSnapshot(): Unit \ Assert =
        let (_, pressed) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, press(), 1), LoadWait.initial());
        let (_, again) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.3, press(), 2), pressed);
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, true), ctx(Set#{"bg"}, 0.6, press(), 3), again);
        Assert.assertEq(expected = "restored 1 Nil", showText(show))

    /// 控えの間の押した入力は全部、押した順に渡し直す（下を押してすぐ決定を押しても、決定が消えない）
    @Test
    def testEveryPressInTheWindowIsReplayed(): Unit \ Assert =
        let (_, down) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, pressOf(Key.Down), 1), LoadWait.initial());
        let (_, planned2) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 2, App.freshStepState(), down);
        let (_, after2) = LoadWait.decide(candidate(Set.empty(), false), ctx(Set#{"bg"}, 0.1, live(), 2), planned2);
        let (_, planned3) = LoadWait.plan(settings(), press(), watch(Set#{"bg"}, 0.2), 3, App.freshStepState(), after2);
        let (_, waiting) = LoadWait.decide(candidate(Set#{"bg"}, true), ctx(Set#{"bg"}, 0.2, press(), 3), planned3);
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.3), 1, App.freshStepState(), waiting);
        let pressedKeys = captured#snapshot |> Option.map(s -> List.map(f -> Set.toList(f#justPressed), s#frames));
        Assert.assertEq(expected = Some((Key.Down :: Nil) :: Nil :: (Key.Enter :: Nil) :: Nil :: Nil), pressedKeys)

    /// 押したすぐ次のコマでまた押しても、そのコマは組の 2 コマ目として 1 回だけ並ぶ（同じ入力を 2 回渡し直さない）
    @Test
    def testBackToBackPressesAreNotDoubled(): Unit \ Assert =
        let (_, first) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, pressOf(Key.Down), 1), LoadWait.initial());
        let (_, planned) = LoadWait.plan(settings(), press(), watch(Set#{"bg"}, 0.016), 2, App.freshStepState(), first);
        let (_, second) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.016, press(), 2), planned);
        Assert.assertEq(expected = Some(2), second#snapshot |> Option.map(s -> List.length(s#frames)))

    /// 押したコマでそのまま当たった時は、そのコマの store を 2 回当てない（loaded は当てた後の World）
    @Test
    def testPressFrameHitAppliesTheStoreOnce(): Unit \ Assert =
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, true), ctxOf(Set#{"bg"}, Map.empty(), 0.0, press(), 15, (w -> w + 10) :: Nil), LoadWait.initial());
        Assert.assertEq(expected = "restored 15 Nil", showText(show))

    /// 渡し直しの途中で出力の鍵が変わって控えを捨てても、残りの入力は渡し直す
    @Test
    def testReplayContinuesAfterAnOutputChange(): Unit \ Assert =
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        let (_, replaying) = LoadWait.plan(settings(), live(), watch(Set.empty(), 0.2), 6, App.freshStepState(), captured);
        let (_, saved) = LoadWait.decide({ outputsChanged = true | candidate(Set.empty(), true) }, ctx(Set.empty(), 0.2, press(), 6), replaying);
        let (step, _) = LoadWait.plan(settings(), live(), watch(Set.empty(), 0.3), 7, App.freshStepState(), saved);
        Assert.assertEq(expected = "replay Nil", stepText(step))

    /// 待ちの最中に待つ名前が増えたら分母も増やす（届いた割合が負にならない）
    @Test
    def testProgressCountsNamesAddedDuringTheWait(): Unit \ Assert =
        let (_, more) = LoadWait.decide(candidate(Set#{"room"}, false), ctx(Set#{"bg", "room"}, 0.5, live(), 5), pressedWait(Set#{"bg", "room"}));
        Assert.assertEq(expected = Some(0.5), LoadWait.published(more, Set#{"room"}, 1.0) |> Option.map(lw -> lw#progress))

    /// 外への出力の鍵が変わる候補を出したら控えを捨てる（その後に当たっても戻さず止まる）
    @Test
    def testOutputChangeDropsTheSnapshot(): Unit \ Assert =
        let (_, pressed) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, press(), 1), LoadWait.initial());
        let (_, saved) = LoadWait.decide({ outputsChanged = true | candidate(Set.empty(), false) }, ctx(Set#{"bg"}, 0.1, live(), 2), pressed);
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, false), ctx(Set#{"bg"}, 0.2, live(), 3), saved);
        Assert.assertEq(expected = "loaded Nil", showText(show))

    /// 控えの秒（1.5 秒）が過ぎたら控えを捨てる
    @Test
    def testSnapshotExpiresAfterTheWindow(): Unit \ Assert =
        let (_, pressed) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, press(), 1), LoadWait.initial());
        let (_, planned) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 2.0), 2, App.freshStepState(), pressed);
        Assert.assertEq(expected = true, Option.isEmpty(planned#snapshot))

    /// 控えの間に積んだ store の記録は、戻す時に控えた World へもう一度当てる
    @Test
    def testStoreMarksReplayOnRestore(): Unit \ Assert =
        let (_, pressed) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set#{"bg"}, 0.0, press(), 1), LoadWait.initial());
        let (_, stored) = LoadWait.decide(candidate(Set.empty(), false), ctxOf(Set#{"bg"}, Map.empty(), 0.1, live(), 2, (w -> w + 100) :: Nil), pressed);
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, false), ctxOf(Set#{"bg"}, Map.empty(), 0.2, live(), 3, (w -> w + 10) :: Nil), stored);
        Assert.assertEq(expected = "restored 111 Nil", showText(show))

    /// 戻した時の StepState は控えの物で、実時間の時計だけをこのコマの物にする
    @Test
    def testRestoredStepStateKeepsOnlyTheRealClock(): Unit \ Assert =
        let real = Clock.advance(Clock.paceOf(Clock.Run.Running), 3.0, App.freshStepState()#real);
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, true), { real = real | ctx(Set#{"bg"}, 0.0, press(), 5) }, LoadWait.initial());
        let kept = match show {
            case Show.Restored(_, s, _) => Some((s#carry, Clock.nowOf(s#real) == Clock.nowOf(real)))
            case _                      => None
        };
        Assert.assertEq(expected = Some((0.0, true)), kept)

    /// 押した瞬間が固定の刻みの持ち越し（StepState#pending）にだけあっても、押したコマと数える
    @Test
    def testPendingEdgesCountAsAPress(): Unit \ Assert =
        let stepState = { pending = { justPressed = Set#{Key.Enter} | App.freshStepState()#pending } | App.freshStepState() };
        Assert.assertEq(expected = true, LoadWait.isPressFrame(live(), stepState))

    // ========================================================================
    // 控えの外の待ち（前の World で止まる）と、待たない物
    // ========================================================================

    /// 控えが無い所で当たったら、進める前の World を描き直して止まる
    @Test
    def testHitOutsideTheWindowStops(): Unit \ Assert =
        let (show, next) = LoadWait.decide(candidate(Set#{"bg"}, false), ctx(Set#{"bg"}, 0.0, live(), 4), LoadWait.initial());
        Assert.assertEq(expected = ("loaded Nil", "stopped-wait"), (showText(show), modeText(next)))

    /// onMissing が placeholder の絵は待たずに出す
    @Test
    def testPlaceholderPictureIsShown(): Unit \ Assert =
        let policies = Map#{"bg" => policy(Some(LoadProgress.OnMissing.Placeholder), None)};
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, true), ctxOf(Set#{"bg"}, policies, 0.0, press(), 5, Nil), LoadWait.initial());
        Assert.assertEq(expected = "candidate Nil", showText(show))

    /// 届いていない一発の音は既定で待たない（鳴らさず進む）
    @Test
    def testOneShotSkipsByDefault(): Unit \ Assert =
        let (show, _) = LoadWait.decide({ sounds = "se" :: Nil | candidate(Set.empty(), true) }, ctx(Set#{"se"}, 0.0, press(), 5), LoadWait.initial());
        Assert.assertEq(expected = "candidate se :: Nil", showText(show))

    /// onMissing が wait の一発の音は待つ
    @Test
    def testOneShotWithWaitPolicyWaits(): Unit \ Assert =
        let policies = Map#{"se" => policy(Some(LoadProgress.OnMissing.Wait), None)};
        let (show, _) = LoadWait.decide({ sounds = "se" :: Nil | candidate(Set.empty(), true) }, ctxOf(Set#{"se"}, policies, 0.0, press(), 5, Nil), LoadWait.initial());
        Assert.assertEq(expected = "restored 5 Nil", showText(show))

    /// 届いていないループの音は、それだけでは待ちを起こさない
    @Test
    def testLoopAloneDoesNotWait(): Unit \ Assert =
        let (show, _) = LoadWait.decide({ loops = "bgm" :: Nil | candidate(Set.empty(), true) }, ctx(Set#{"bgm"}, 0.0, press(), 5), LoadWait.initial());
        Assert.assertEq(expected = "candidate Nil", showText(show))

    /// 押した時の待ちが起きても、届いていないループの音は既定では一緒に待たない（届いたら鳴る）
    @Test
    def testLoopDoesNotJoinAPressedWaitByDefault(): Unit \ Assert =
        let (_, next) = LoadWait.decide({ loops = "bgm" :: Nil | candidate(Set#{"bg"}, true) }, ctx(Set#{"bg", "bgm"}, 0.0, press(), 5), LoadWait.initial());
        Assert.assertEq(expected = Set#{"bg"}, LoadWait.waitingNames(next))

    /// ループの音も当たった名前と同じ group に入れれば一緒に待つ
    @Test
    def testLoopInTheSameGroupJoinsAPressedWait(): Unit \ Assert =
        let policies = Map#{"bg" => policy(None, Some("start")), "bgm" => policy(None, Some("start"))};
        let (_, next) = LoadWait.decide({ loops = "bgm" :: Nil | candidate(Set#{"bg"}, true) }, ctxOf(Set#{"bg", "bgm"}, policies, 0.0, press(), 5, Nil), LoadWait.initial());
        Assert.assertEq(expected = Set#{"bg", "bgm"}, LoadWait.waitingNames(next))

    /// 押した時の待ちは、当たった名前と同じ group の届いていない名前も一緒に待つ
    @Test
    def testGroupRestJoinsAPressedWait(): Unit \ Assert =
        let policies = Map#{"bg" => policy(None, Some("start")), "op2" => policy(None, Some("start")), "card" => policy(None, Some("cards"))};
        let (_, next) = LoadWait.decide(candidate(Set#{"bg"}, true), ctxOf(Set#{"bg", "op2", "card"}, policies, 0.0, press(), 5, Nil), LoadWait.initial());
        Assert.assertEq(expected = Set#{"bg", "op2"}, LoadWait.waitingNames(next))

    /// group の残りでも skip・placeholder の物は一緒に待たない
    @Test
    def testGroupRestSkipsNoWaitNames(): Unit \ Assert =
        let policies = Map#{"bg" => policy(None, Some("start")), "se" => policy(Some(LoadProgress.OnMissing.Skip), Some("start")),
                            "font_x" => policy(Some(LoadProgress.OnMissing.Placeholder), Some("start"))};
        let (_, next) = LoadWait.decide(candidate(Set#{"bg"}, true), ctxOf(Set#{"bg", "se", "font_x"}, policies, 0.0, press(), 5, Nil), LoadWait.initial());
        Assert.assertEq(expected = Set#{"bg"}, LoadWait.waitingNames(next))

    /// 控えの外の待ちには group の残りを足さない
    @Test
    def testGroupRestDoesNotJoinAStoppedWait(): Unit \ Assert =
        let policies = Map#{"bg" => policy(None, Some("start")), "op2" => policy(None, Some("start"))};
        let (_, next) = LoadWait.decide(candidate(Set#{"bg"}, false), ctxOf(Set#{"bg", "op2"}, policies, 0.0, live(), 5, Nil), LoadWait.initial());
        Assert.assertEq(expected = Set#{"bg"}, LoadWait.waitingNames(next))

    // ========================================================================
    // 待つ間・届いた時・諦め・取り消し
    // ========================================================================

    /// 押した時の待ちの間は、既定（KeepRunning）で入力なしで進める
    @Test
    def testKeepRunningAdvancesWithoutInput(): Unit \ Assert =
        let (step, _) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.5), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        Assert.assertEq(expected = "idle", stepText(step))

    /// 戻した World が Freeze を選んでいれば、進めずに描き直す
    @Test
    def testFreezeHolds(): Unit \ Assert =
        let frozen = { styleOf = _ -> App.LoadWaitStyle.Freeze | ctx(Set#{"bg"}, 0.0, press(), 5) };
        let (_, waiting) = LoadWait.decide(candidate(Set#{"bg"}, true), frozen, LoadWait.initial());
        let (step, _) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.5), 5, App.freshStepState(), waiting);
        Assert.assertEq(expected = "hold", stepText(step))

    /// 控えの外の待ちは、届くまで描き直す
    @Test
    def testStoppedWaitHolds(): Unit \ Assert =
        let (_, stopped) = LoadWait.decide(candidate(Set#{"bg"}, false), ctx(Set#{"bg"}, 0.0, live(), 4), LoadWait.initial());
        let (step, _) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.5), 4, App.freshStepState(), stopped);
        Assert.assertEq(expected = "hold", stepText(step))

    /// 全部届いたら、押したコマの入力から渡し直す
    @Test
    def testArrivalReplaysThePress(): Unit \ Assert =
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        let (step, _) = LoadWait.plan(settings(), live(), watch(Set.empty(), 0.2), 6, App.freshStepState(), captured);
        Assert.assertEq(expected = "replay Enter :: Nil", stepText(step))

    /// 渡し直しは 2 コマ（押したコマとその次のコマ）で、2 コマ目の後は待っていない時へ戻る
    @Test
    def testReplayTakesTwoFrames(): Unit \ Assert =
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        let (_, first) = LoadWait.plan(settings(), live(), watch(Set.empty(), 0.2), 6, App.freshStepState(), captured);
        let (_, afterFirst) = LoadWait.decide(candidate(Set.empty(), true), ctx(Set.empty(), 0.2, press(), 6), first);
        let (second, secondState) = LoadWait.plan(settings(), live(), watch(Set.empty(), 0.3), 7, App.freshStepState(), afterFirst);
        let (_, afterSecond) = LoadWait.decide(candidate(Set.empty(), false), ctx(Set.empty(), 0.3, live(), 7), secondState);
        Assert.assertEq(expected = ("replay Nil", "idle"), (stepText(second), modeText(afterSecond)))

    /// 渡し直した候補がまた届いていない物に当たれば、同じ控え（渡し直す前の World）へ戻って待ちを続ける
    @Test
    def testReplayHittingAgainKeepsWaiting(): Unit \ Assert =
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        let (_, replaying) = LoadWait.plan(settings(), live(), watch(Set#{"room"}, 0.2), 6, App.freshStepState(), captured);
        let (show, next) = LoadWait.decide(candidate(Set#{"room"}, true), ctx(Set#{"room"}, 0.2, press(), 6), replaying);
        Assert.assertEq(expected = ("restored 6 Nil", "pressed-wait"), (showText(show), modeText(next)))

    /// 上限（20 秒）を超えたら残りの名前を諦め、渡し直す
    @Test
    def testGivesUpAtTheLimit(): Unit \ Assert =
        let (step, next) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 20.0), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        Assert.assertEq(expected = ("replay Enter :: Nil", Set#{"bg"}), (stepText(step), next#gaveUp))

    /// 待つ名前が全部取れずに終わったら（4xx）、上限を待たずに諦める
    @Test
    def testGivesUpWhenAllNamesFailed(): Unit \ Assert =
        let (_, next) = LoadWait.plan(settings(), live(), { failed = Set#{"bg"} | watch(Set#{"bg"}, 1.0) }, 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        Assert.assertEq(expected = Set#{"bg"}, next#gaveUp)

    /// 諦めた名前は、その後のコマでは待たない
    @Test
    def testGivenUpNameNoLongerWaits(): Unit \ Assert =
        let (_, gaveUp) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 20.0), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        let (show, _) = LoadWait.decide(candidate(Set#{"bg"}, false), ctx(Set#{"bg"}, 21.0, live(), 6), { mode = Mode.Idle, snapshot = None | gaveUp });
        Assert.assertEq(expected = "candidate Nil", showText(show))

    /// 取り消しのキー（Backspace）で、控えた入力を捨てて待ちをやめる
    @Test
    def testCancelKeyDropsTheWait(): Unit \ Assert =
        let (step, next) = LoadWait.plan(settings(), pressOf(Key.Backspace), watch(Set#{"bg"}, 0.5), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        Assert.assertEq(expected = ("idle", "idle", true), (stepText(step), modeText(next), Option.isEmpty(next#snapshot)))

    /// ほかのキーは待ちを取り消さない
    @Test
    def testOtherKeysDoNotCancel(): Unit \ Assert =
        let (_, next) = LoadWait.plan(settings(), pressOf(Key.Down), watch(Set#{"bg"}, 0.5), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        Assert.assertEq(expected = "pressed-wait", modeText(next))

    // ========================================================================
    // コードの待ち・ロゴ・知らせ
    // ========================================================================

    /// 作る途中で後から取るコードがそろっていなかった候補は捨てて、押した時の待ち（理由は Code）に入る
    @Test
    def testCodeFailureStartsACodeWait(): Unit \ Assert =
        let (show, next) = LoadWait.decide({ failed = true | candidate(Set.empty(), true) }, ctx(Set.empty(), 0.0, press(), 5), LoadWait.initial());
        let reason = LoadWait.published(next, Set.empty(), 0.0) |> Option.map(lw -> lw#reason);
        Assert.assertEq(expected = ("restored 5 Nil", Some(LoadProgress.LoadWaitReason.Code)), (showText(show), reason))

    /// コードの待ちは上限を過ぎても諦めない
    @Test
    def testCodeWaitNeverGivesUp(): Unit \ Assert =
        let (_, waiting) = LoadWait.decide({ failed = true | candidate(Set.empty(), true) }, ctx(Set.empty(), 0.0, press(), 5), LoadWait.initial());
        let (_, next) = LoadWait.plan(settings(), live(), { codeReady = false | watch(Set.empty(), 100.0) }, 5, App.freshStepState(), waiting);
        Assert.assertEq(expected = "pressed-wait", modeText(next))

    /// 頁がロゴを出している間は進めない
    @Test
    def testSplashDoesNotAdvance(): Unit \ Assert =
        let (step, _) = LoadWait.plan(settings(), press(), { splash = true | watch(Set.empty(), 0.0) }, 5, App.freshStepState(), LoadWait.initial());
        Assert.assertEq(expected = "splash", stepText(step))

    /// 知らせる待ちは、残りの名前・届いた割合・押した時の待ちか を持つ
    @Test
    def testPublishedWaitCountsProgress(): Unit \ Assert =
        let policies = Map#{"bg" => policy(None, Some("start")), "op2" => policy(None, Some("start"))};
        let (_, next) = LoadWait.decide(candidate(Set#{"bg"}, true), ctxOf(Set#{"bg", "op2"}, policies, 0.0, press(), 5, Nil), LoadWait.initial());
        let lw = LoadWait.published(next, Set#{"op2"}, 1.5);
        Assert.assertEq(expected = Some(("op2" :: Nil, 0.5, 1.5, true)), Option.map(w -> (w#names, w#progress, w#waited, w#pressed), lw))

    /// デスクトップの組（localDownloads）では、いつも待ちを見ない今までの道を通る
    @Test
    def testLocalDownloadsAlwaysTakeThePlainPath(): Unit \ {Assert, IO} =
        let d = LoadProgress.localDownloads();
        let plain = LoadWait.isFastFrame(d#missing(), d#getCodeLoadState() == LoadProgress.LoadState.Loaded, d#isSplashShowing(),
                                          (LoadWait.initial(): LoadWait.State[Int32]));
        Assert.assertEq(expected = true, plain)

    /// 待ちも控えも無い起動の状態は、今までと同じ道を通れる
    @Test
    def testInitialStateIsIdle(): Unit \ Assert =
        Assert.assertEq(expected = true, LoadWait.isIdle((LoadWait.initial(): LoadWait.State[Int32])))

    // ========================================================================
    // 押した時の決定の音
    // ========================================================================

    /// 待ちに入る時、捨てた候補の一発の音のうち届いている物を鳴らす
    @Test
    def testEnteringAWaitChimesArrivedSounds(): Unit \ Assert =
        let (show, _) = LoadWait.decide({ sounds = "decide" :: "door" :: Nil | candidate(Set#{"bg"}, true) }, ctx(Set#{"bg", "door"}, 0.0, press(), 5), LoadWait.initial());
        Assert.assertEq(expected = "restored 5 decide :: Nil", showText(show))

    /// 渡し直した候補の音から、待ちに入った時に鳴らした数だけ引く（それより多くは引かない）
    @Test
    def testReplaySubtractsTheChimedSounds(): Unit \ Assert =
        let (_, waiting) = LoadWait.decide({ sounds = "decide" :: Nil | candidate(Set#{"bg"}, true) }, ctx(Set#{"bg"}, 0.0, press(), 5), LoadWait.initial());
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 5, App.freshStepState(), waiting);
        let (_, replaying) = LoadWait.plan(settings(), live(), watch(Set.empty(), 0.2), 6, App.freshStepState(), captured);
        let (show, _) = LoadWait.decide({ sounds = "decide" :: "decide" :: Nil | candidate(Set.empty(), true) }, ctx(Set.empty(), 0.2, press(), 6), replaying);
        Assert.assertEq(expected = "candidate decide :: Nil", showText(show))

    /// 引く数より多くは抜かない
    @Test
    def testWithoutOwedKeepsTheExtra(): Unit \ Assert =
        Assert.assertEq(expected = ("a" :: "b" :: Nil, Map.empty()), LoadWait.withoutOwed("a" :: "a" :: "b" :: Nil, Map#{"a" => 1}))

    // ========================================================================
    // 後から取るコードの例外を受け取る所
    // ========================================================================

    def throwNotReady(): Int32 \ IO = throw new RuntimeException("(JavaScript) Error: fge-code-not-ready: placeholder.deferred")

    def throwOther(): Int32 \ IO = throw new RuntimeException("boom")

    /// 目印を含む例外は None で受ける
    @Test
    def testCodeNotReadyIsCaught(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = None, LoadWait.catchCodeNotReady(() -> throwNotReady()))

    /// 例外が無ければ値をそのまま返す
    @Test
    def testValueIsReturned(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = Some(3), LoadWait.catchCodeNotReady(() -> checked_ecast(3)))

    /// 目印の無い例外は飲み込まずに投げ直す
    @Test
    def testOtherExceptionsAreRethrown(): Unit \ {Assert, IO} =
        let message = try { discard LoadWait.catchCodeNotReady(() -> throwOther()); "none" } catch {
            case e: RuntimeException => e.getMessage()
        };
        Assert.assertEq(expected = "boom", message)

    // ========================================================================
    // 組んだ 1 コマの名前（Paint.assetNamesOf）
    // ========================================================================

    /// 画面・Pass の中・余りの絵・タイル層のアトラスの名前を全部数える
    @Test
    def testAssetNamesOfCountsEveryPart(): Unit \ Assert =
        let placed = name -> { at = Vec2.zero(), item = Render.sprite(name, 0) };
        let atlas = { marginX = 0.0, marginY = 0.0, spacingX = 0.0, spacingY = 0.0, texHeight = 16.0, texWidth = 16.0, textureName = "tiles", tileSize = 8.0 };
        let tile = { key = "floor", tileSet = { atlasSource = atlas }, tiles = () -> Nil, origin = Vec2.zero(), zIndex = 0 };
        let built = { items = placed("hero") :: Nil,
                      plan = Render.passPlan({ name = "fx", clear = RenderTarget.LoadOp.Clear({ r = 0.0, g = 0.0, b = 0.0 }), items = placed("smoke") :: Nil } :: Nil),
                      letterbox = Some(placed("blur") :: Nil), tiles = tile :: Nil, retained = true };
        Assert.assertEq(expected = Set#{"hero", "smoke", "blur", "tiles"}, App.Internal.Paint.assetNamesOf(built))

    // ========================================================================
    // 待ちの表示（押した点・波紋・輪）
    // ========================================================================

    def waitOf(waited: Float64, pressed: Bool): LoadProgress.LoadWait =
        { reason = LoadProgress.LoadWaitReason.Assets, names = "bg" :: Nil, waited = waited, progress = 0.5, pressed = pressed }

    def design(): Vec2.Vec2 = { x = 320.0, y = 180.0 }

    def originText(origin: Option[Vec2.Vec2]): String = origin |> Option.map(p -> "${p#x},${p#y}") |> Option.getWithDefault("none")

    /// マウスかタッチで押して待ちに入ると、波紋はその時のカーソルの位置から
    @Test
    def testRippleStartsAtTheClickedCursor(): Unit \ Assert =
        let click = { mouseClicked = true, mouseDown = true, cursor = { x = 40.0, y = 30.0 } | live() };
        let (_, waiting) = LoadWait.decide(candidate(Set#{"bg"}, true), ctx(Set#{"bg"}, 0.0, click, 5), LoadWait.initial());
        Assert.assertEq(expected = "40.0,30.0", originText(LoadWait.rippleOriginOf(waiting, design())))

    /// キーで押して待ちに入ると、波紋は画面の真ん中から
    @Test
    def testRippleStartsAtTheCenterForAKey(): Unit \ Assert =
        Assert.assertEq(expected = "160.0,90.0", originText(LoadWait.rippleOriginOf(pressedWait(Set#{"bg"}), design())))

    /// 渡し直しの途中で別の物に当たって待ちに入り直しても、波紋はもう出さない
    @Test
    def testReenteringDuringTheReplayHasNoRipple(): Unit \ Assert =
        let (_, captured) = LoadWait.plan(settings(), live(), watch(Set#{"bg"}, 0.1), 5, App.freshStepState(), pressedWait(Set#{"bg"}));
        let (_, replaying) = LoadWait.plan(settings(), live(), watch(Set#{"room"}, 0.2), 6, App.freshStepState(), captured);
        let (_, next) = LoadWait.decide(candidate(Set#{"room"}, true), ctx(Set#{"room"}, 0.2, press(), 6), replaying);
        Assert.assertEq(expected = "none", originText(LoadWait.rippleOriginOf(next, design())))

    /// 押した時の待ちの頭は、輪の出る秒の前でも波紋を出す
    @Test
    def testRippleShowsRightAfterThePress(): Unit \ Assert =
        Assert.assertFalse(List.isEmpty(App.Internal.LoadingView.itemsOf(design(), waitOf(0.1, true), Some({ x = 40.0, y = 30.0 }))))

    /// 波紋の無い待ちは、輪の出る秒までは何も出さない
    @Test
    def testNothingBeforeTheIndicatorSeconds(): Unit \ Assert =
        Assert.assertTrue(List.isEmpty(App.Internal.LoadingView.itemsOf(design(), waitOf(0.3, false), None)))

    /// 輪の出る秒を超えた待ちは輪を出す
    @Test
    def testIndicatorShowsAfterTheIndicatorSeconds(): Unit \ Assert =
        Assert.assertFalse(List.isEmpty(App.Internal.LoadingView.itemsOf(design(), waitOf(0.7, false), None)))

    def inLoadingBand(items: List[Render.PlacedItem]): Bool =
        items |> List.map(p -> Render.zOf(p#item)) |> List.forAll(z -> z >= ZBand.loadingBase() and z <= ZBand.loadingBase() + 10)

    /// 波紋は読み込み中の表示の範囲の z（base から +10 まで）
    @Test
    def testRippleStaysInTheLoadingBand(): Unit \ Assert =
        Assert.assertTrue(inLoadingBand(App.Internal.LoadingView.itemsOf(design(), waitOf(0.2, true), Some({ x = 40.0, y = 30.0 }))))

    /// 輪は読み込み中の表示の範囲の z（base から +10 まで）
    @Test
    def testIndicatorStaysInTheLoadingBand(): Unit \ Assert =
        Assert.assertTrue(inLoadingBand(App.Internal.LoadingView.itemsOf(design(), waitOf(0.7, false), None)))

    /// 20 秒を超えた輪も読み込み中の表示の範囲の z
    @Test
    def testSlowIndicatorStaysInTheLoadingBand(): Unit \ Assert =
        Assert.assertTrue(inLoadingBand(App.Internal.LoadingView.itemsOf(design(), waitOf(25.0, false), None)))
}
