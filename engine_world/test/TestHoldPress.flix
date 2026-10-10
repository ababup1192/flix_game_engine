// HoldPress のテスト。テストするのは「満ちたフレームで 1 回だけ合図」「合図の後は離すまで貯めない」
// 「受け付けない画面では貯めない」「離すと速めに戻る」だけ。

mod TestHoldPress {

    def cfg(): HoldPress.Config = { seconds = 0.5, drain = 2.0 }

    /// 押し続けた秒を貯めて、0.5 秒に届いたフレームで合図を出す（それまでは出さない）。
    def press(n: Int32, s: HoldPress.HoldPress): (HoldPress.HoldPress, List[Bool]) =
        List.range(0, n) |> List.foldLeft((acc, _i) -> {
            let (cur, fired) = acc;
            let (next, f) = HoldPress.step(cfg(), true, true, 0.1, cur);
            (next, f :: fired)
        }, (s, Nil)) |> (r -> (fst(r), List.reverse(snd(r))))

    @Test
    def testFiresOnceWhenFull(): Unit \ Assert =
        let (_, fired) = press(5, HoldPress.empty());
        Assert.assertEq(expected = false :: false :: false :: false :: true :: Nil, fired)

    /// 合図の後に押しっぱなしでも、離すまで貯め直さない。
    @Test
    def testLatchedUntilReleased(): Unit \ Assert =
        let (after, _) = press(5, HoldPress.empty());
        let (held, fired) = press(10, after);
        Assert.assertEq(expected = (0.0, false), (held#charge, List.exists(x -> x, fired)))

    /// 受け付けない画面では貯めない。
    @Test
    def testDisabledDoesNotCharge(): Unit \ Assert =
        let (s, f) = HoldPress.step(cfg(), true, false, 0.1, HoldPress.empty());
        Assert.assertEq(expected = (0.0, false), (s#charge, f))

    /// 離すと drain 倍の速さで戻る（0.3 秒貯めて 0.1 秒離すと 0.1 残る）。
    @Test
    def testReleaseDrainsFaster(): Unit \ Assert =
        let (held, _) = press(3, HoldPress.empty());
        let (released, _) = HoldPress.step(cfg(), false, true, 0.1, held);
        Assert.assertEq(expected = true, Float64.abs(released#charge - 0.1) < 0.000001)
}
