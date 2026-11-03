// TestLwjglEnv — 実機の窓が読む環境変数の読み方と、1 コマの dt の決め方（GL を呼ばない純粋な部分）を具体値で固定する。

mod TestLwjglEnv {

    // ── 環境変数の表を読む ─────────────────────────────────────────

    /// 何も置かなければ全部切れている（デスクトップの本番の起動は変わらない）。
    @Test
    def testEmptyEnvTurnsEverythingOff(): Unit \ Assert =
        let s = LwjglEnv.fromMap(Map.empty());
        Assert.assertEq(expected = (false, false, false, None, None, None),
                        (s#hidden, s#muted, s#frameStats, s#frameShotDir, s#splashShotPath, s#fixedDt))

    /// 旗ごとの値の読み方: HIDDEN は置けば値を問わず入る・MUTE は "0" と空で切れる・FRAME_STATS は空だけで切れる。
    @Test
    def testFlagsReadTheirOwnOffValues(): Unit \ Assert =
        let readFlags = env -> { let s = LwjglEnv.fromMap(env); (s#hidden, s#muted, s#frameStats) };
        Assert.assertEq(expected = ((true, false, true), (true, true, true)),
                        (readFlags(Map#{"FLIX_GE_HIDDEN" => "0", "FLIX_GE_MUTE" => "0", "FLIX_GE_FRAME_STATS" => "0"}),
                         readFlags(Map#{"FLIX_GE_HIDDEN" => "", "FLIX_GE_MUTE" => "1", "FLIX_GE_FRAME_STATS" => "1"})))

    /// 撮る口のパスと dt の秒はそのまま値になる。
    @Test
    def testPathsAndFixedDtAreRead(): Unit \ Assert =
        let s = LwjglEnv.fromMap(Map#{"FLIX_GE_FRAME_SHOT" => "out/gl", "FLIX_GE_SPLASH_SHOT" => "out/splash.png",
                                      "FLIX_GE_FIXED_DT" => "0.5"});
        Assert.assertEq(expected = (Some("out/gl"), Some("out/splash.png"), Some(0.5)),
                        (s#frameShotDir, s#splashShotPath, s#fixedDt))

    /// 読めない FLIX_GE_FIXED_DT は実時間のまま続ける（起動を止めない）。
    @Test
    def testBadFixedDtFallsBackToRealTime(): Unit \ Assert =
        Assert.assertEq(expected = None, LwjglEnv.fromMap(Map#{"FLIX_GE_FIXED_DT" => "fast"})#fixedDt)

    /// 空の値は置いていないのと同じ（撮る口のパスも dt も無し）。
    @Test
    def testEmptyValuesAreUnset(): Unit \ Assert =
        let s = LwjglEnv.fromMap(Map#{"FLIX_GE_FRAME_SHOT" => "", "FLIX_GE_SPLASH_SHOT" => "", "FLIX_GE_FIXED_DT" => ""});
        Assert.assertEq(expected = (None, None, None), (s#frameShotDir, s#splashShotPath, s#fixedDt))

    // ── FLIX_GE_FIXED_DT の字 ─────────────────────────────────────

    /// 小数と分数を受ける。1/60 は割り算の値そのもの（画面なしの描き手の 1.0 / 60.0 と同じ数）。
    @Test
    def testParseFixedDtAcceptsDecimalAndFraction(): Unit \ Assert =
        Assert.assertEq(expected = (Ok(0.25), Ok(1.0 / 60.0), Ok(0.5)),
                        (LwjglEnv.parseFixedDt("0.25"), LwjglEnv.parseFixedDt("1/60"), LwjglEnv.parseFixedDt(" 1 / 2 ")))

    /// 0・負・0 で割った値・字は受けない。
    @Test
    def testParseFixedDtRejectsNonPositiveAndText(): Unit \ Assert =
        Assert.assertEq(expected = (true, true, true, true),
                        (Result.isErr(LwjglEnv.parseFixedDt("0")), Result.isErr(LwjglEnv.parseFixedDt("-0.5")),
                         Result.isErr(LwjglEnv.parseFixedDt("1/0")), Result.isErr(LwjglEnv.parseFixedDt("abc"))))

    // ── 1 コマの dt ─────────────────────────────────────────────

    /// 固定が無ければ実時間（0.5 秒 = 500,000,000 ns）、有ればかかった時間に関わらずその値。
    @Test
    def testFrameDtUsesFixedValueOverElapsed(): Unit \ Assert =
        Assert.assertEq(expected = (0.5, 0.25),
                        (LwjglEnv.frameDt(None, 1.0, 500_000_000i64),
                         LwjglEnv.frameDt(Some(0.25), 1.0, 500_000_000i64)))

    /// 実時間も固定の値も maxDeltaTime（ここでは 0.1 秒）で切る。
    @Test
    def testFrameDtIsCappedByMaxDeltaTime(): Unit \ Assert =
        Assert.assertEq(expected = (0.1, 0.1),
                        (LwjglEnv.frameDt(None, 0.1, 500_000_000i64),
                         LwjglEnv.frameDt(Some(0.5), 0.1, 0i64)))
}
