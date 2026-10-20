// PropertyTest のテスト。入力の列が実機と同じ Frame になること（続けて Tap しても毎回押した瞬間・
// 押しっぱなしは Release まで・マウスの Press と Drag と Up）、keyOf が World を読めること、
// 崩れた最初のフレームと種を指せること、同じ種なら同じ列になることを見る。

mod TestPropertyTest {
    use PropertyTest.Input
    use GameEngine.Key

    enum Role with Eq {
        case Confirm
        case Run
    }

    /// 各フレームで見えた入力の要点を積む World（新しい物が先頭）。
    type alias Seen = {
        presses = List[Set[Key]],     // justPressed
        downs = List[Set[Key]],       // down
        clicks = Int32,               // mouseClicked の回数
        mouse = List[(Bool, Float64, Float64)],  // (mouseDown, cursor の x, y)
        wheels = List[Float64],
        swapped = Bool                // keyOf の割り当てを変えたか（Confirm を 1 回押したら変える）
    }

    def seen(): Seen =
        { presses = Nil, downs = Nil, clicks = 0, mouse = Nil, wheels = Nil, swapped = false }

    def observe(frame: App.Frame, w: Seen): Seen =
        { presses = frame#justPressed :: w#presses, downs = frame#down :: w#downs,
          clicks = w#clicks + (if (frame#mouseClicked) 1 else 0),
          mouse = (frame#mouseDown, frame#cursor#x, frame#cursor#y) :: w#mouse, wheels = frame#wheel :: w#wheels,
          swapped = w#swapped or not Set.isEmpty(frame#justPressed) | w }

    def seenApp(): App.App[Seen, {}] = App.make(seen()) |> App.addSystem(observe)

    def keyOf(role: Role, w: Seen): Key = match role {
        case Role.Confirm => if (w#swapped) Key.X else Key.Z
        case Role.Run     => Key.Left
    }

    def setup(): PropertyTest.Setup[Role, Seen] =
        { keyOf = keyOf, viewport = { x = 320.0, y = 240.0 }, dt = 0.5 }

    def finalOf(inputs: List[Input[Role]]): Seen =
        PropertyTest.finalOf(seenApp(), setup(), inputs, seen())

    def p1(): Vec2.Vec2 = { x = 10.0, y = 20.0 }

    def p2(): Vec2.Vec2 = { x = 50.0, y = 100.0 }

    // ══════════════════════════════════════════════════════
    // 入力 → Frame
    // ══════════════════════════════════════════════════════

    /// 同じ役を 3 回続けて Tap すると、間に離すフレームが挟まり 3 回とも押した瞬間になる（3 + 2 フレーム）。
    @Test
    def testRepeatedTapIsPressedEachTime(): Unit \ Assert =
        let w = finalOf(List#{Input.Tap(Role.Run), Input.Tap(Role.Run), Input.Tap(Role.Run)});
        Assert.assertEq(expected = (3, 5), (List.count(keys -> Set.memberOf(Key.Left, keys), w#presses), List.length(w#presses)))

    /// Hold したキーは Release まで押されたまま、押した瞬間は 1 回だけ。
    @Test
    def testHoldKeepsKeyDownUntilRelease(): Unit \ Assert =
        let w = finalOf(List#{Input.Hold(Role.Run), Input.Idle(0.0), Input.Idle(0.0), Input.Release(Role.Run), Input.Idle(0.0)});
        Assert.assertEq(expected = (List#{false, false, true, true, true}, 1),
            (w#downs |> List.map(keys -> Set.memberOf(Key.Left, keys)), List.count(keys -> not Set.isEmpty(keys), w#presses)))

    /// keyOf はその時の World を読む: 1 回目の Confirm で割り当てが変わると、2 回目は別のキーになる。
    @Test
    def testKeyOfReadsCurrentWorld(): Unit \ Assert =
        let w = finalOf(List#{Input.Tap(Role.Confirm), Input.Tap(Role.Confirm)});
        Assert.assertEq(expected = List#{Set#{Key.X}, Set#{Key.Z}}, w#presses)

    /// 押したまま Press し直すと間に離すフレームが挟まり、クリックは Press の回数だけ数える。
    /// Drag はボタンを押したまま動かし、Up で離す。
    @Test
    def testMousePressDragUp(): Unit \ Assert =
        let w = finalOf(List#{Input.Press(p1()), Input.Drag(p2()), Input.Up, Input.Press(p1()), Input.Press(p2())});
        Assert.assertEq(
            expected = (3, List#{(true, 50.0, 100.0), (false, 50.0, 100.0), (true, 10.0, 20.0), (false, 50.0, 100.0), (true, 50.0, 100.0), (true, 10.0, 20.0)}),
            (w#clicks, w#mouse))

    /// Wheel はそのフレームだけ量が乗る。
    @Test
    def testWheelLastsOneFrame(): Unit \ Assert =
        let w = finalOf(List#{Input.Wheel(1.0), Input.Idle(0.0)});
        Assert.assertEq(expected = List#{0.0, 1.0}, w#wheels)

    // ══════════════════════════════════════════════════════
    // 列を作る
    // ══════════════════════════════════════════════════════

    /// 同じ種なら同じ列（流して見えた入力が全フレームで同じ）。
    @Test
    def testSameSeedSameInputs(): Unit \ Assert =
        let spec = { taps = List#{Role.Confirm}, holds = List#{Role.Run}, points = List#{p1(), p2()},
                     wheels = List#{1.0} | PropertyTest.emptySpec() };
        let once = finalOf(PropertyTest.generate(7i64, 100, spec));
        let twice = finalOf(PropertyTest.generate(7i64, 100, spec));
        Assert.assertEq(expected = (once#presses, once#downs, once#mouse, once#wheels),
            (twice#presses, twice#downs, twice#mouse, twice#wheels))

    /// Tap だけの Spec（idle = 0）で作った 50 個の入力は、50 回とも押した瞬間になる。
    @Test
    def testTapOnlySpecPressesEveryTime(): Unit \ Assert =
        let spec = { taps = List#{Role.Run}, idle = 0 | PropertyTest.emptySpec() };
        let w = finalOf(PropertyTest.generate(3i64, 50, spec));
        Assert.assertEq(expected = 50, List.count(keys -> not Set.isEmpty(keys), w#presses))

    // ══════════════════════════════════════════════════════
    // 崩れを探す
    // ══════════════════════════════════════════════════════

    /// 決まり「押したのは 2 回まで」は 3 回目の Tap のフレーム（0 から数えて 4）で崩れ、入力はそこまでの 5 個。
    @Test
    def testFirstBrokenPointsAtFirstFailingFrame(): Unit \ Assert =
        let rule = (step: App.TraceStep[Seen]) ->
            if (List.count(keys -> Set.memberOf(Key.Left, keys), step#after#presses) <= 2) None else Some("3 回目");
        let inputs = List#{Input.Tap(Role.Run), Input.Idle(0.0), Input.Tap(Role.Run), Input.Idle(0.0),
                           Input.Tap(Role.Run), Input.Idle(0.0)};
        let found = PropertyTest.firstBroken(seenApp(), setup(), inputs, seen(), rule)
            |> Option.map(broken -> (broken#frame, broken#why, List.length(broken#inputs)));
        Assert.assertEq(expected = Some((4, "3 回目", 5)), found)

    /// 種 1..5 のうち、check が最初に崩れを返した種（3）を返す。全部通れば None。
    @Test
    def testFirstFailingSeedReturnsFirstSeed(): Unit \ Assert =
        Assert.assertEq(expected = (Some((3i64, "3")), None),
            (PropertyTest.firstFailingSeed(5, seed -> if (seed >= 3i64) Some(Int64.toString(seed)) else None),
             PropertyTest.firstFailingSeed(5, _seed -> (None: Option[String]))))

    /// forAll は崩れない決まりなら None、崩れる決まりなら最初の種の説明を返す。
    @Test
    def testForAllReportsOnlyBrokenRules(): Unit \ Assert =
        let cases = { seeds = 3, length = 20, spec = { taps = List#{Role.Run}, idle = 0 | PropertyTest.emptySpec() } };
        let never = (_step: App.TraceStep[Seen]) -> None;
        let always = (_step: App.TraceStep[Seen]) -> Some("崩れた");
        Assert.assertEq(expected = (None, Some("seed 1・0 フレーム目（入力 1 個目）: 崩れた")),
            (PropertyTest.forAll(seenApp(), setup(), cases, seen(), never),
             PropertyTest.forAll(seenApp(), setup(), cases, seen(), always)))

    // ══════════════════════════════════════════════════════
    // expect（名前・期待・実際の組で決まりを書く）
    // ══════════════════════════════════════════════════════

    /// mismatchOf は合わなかった最初の 1 件を「名前 期待 … / 実際 …」で返す。
    @Test
    def testMismatchOfNamesTheFirstFailedCheck(): Unit \ Assert =
        Assert.assertEq(expected = Some("押した数 期待 2 / 実際 3"),
            PropertyTest.mismatchOf(PropertyTest.expect("場面", expected = "Play", actual = "Play")
                                    :: PropertyTest.expect("押した数", expected = 2, actual = 3)
                                    :: PropertyTest.expect("音", expected = 1, actual = 0) :: Nil))

    /// 全部合えば None。
    @Test
    def testMismatchOfIsNoneWhenAllHold(): Unit \ Assert =
        Assert.assertEq(expected = None,
            PropertyTest.mismatchOf(PropertyTest.expect("押した数", expected = 2, actual = 2) :: Nil))

    /// forAllExpect は合わなかった最初の種・フレーム・入力の数と、名前・期待・実際を返す。
    @Test
    def testForAllExpectReportsSeedFrameAndValues(): Unit \ Assert =
        let cases = { seeds = 3, length = 20, spec = { taps = List#{Role.Run}, idle = 0 | PropertyTest.emptySpec() } };
        let checks = (step: App.TraceStep[Seen]) ->
            PropertyTest.expect("押したキーの数", expected = 0, actual = List.length(step#after#presses)) :: Nil;
        Assert.assertEq(expected = Some("seed 1・0 フレーム目（入力 1 個目）: 押したキーの数 期待 0 / 実際 1"),
            PropertyTest.forAllExpect(seenApp(), setup(), cases, seen(), checks))

    /// firstFailingSeedExpect は最初に合わなかった種と、名前・期待・実際を返す。
    @Test
    def testFirstFailingSeedExpectReportsSeedAndValues(): Unit \ Assert =
        Assert.assertEq(expected = Some("seed 3: 種が 3 より小さい 期待 true / 実際 false"),
            PropertyTest.firstFailingSeedExpect(5, seed ->
                PropertyTest.expect("種が 3 より小さい", expected = true, actual = seed < 3i64) :: Nil))
}
