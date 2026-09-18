// 出来事 → 鳴る音の名前だけをテストする（音の中身＝波形は目と耳の仕事なのでテストしない）。
// 前後の World は「1 つの値だけ変えた 2 つ」で作り、その差分が音の名前になることを見る。
mod TestSfx {

    /// 既定の Doc の束（World.initial が読むのと同じ形）。
    def docs(): World.Docs =
        { rules = RulesDoc.defaults(), rivalsCfg = RivalsDoc.defaults(), theme = ThemeDoc.defaults(),
          course = CourseDoc.defaults(), props = PropsDoc.defaults(), palette = PaletteDoc.defaults(), sprites = PxSpriteDoc.empty(),
          fx = { smoke = FxDoc.empty(), spark = FxDoc.empty(), flame = FxDoc.empty(),
                 shock = FxDoc.empty(), crash = FxDoc.empty() },
          sfxtune = SfxTuneDoc.defaults() }

    /// 走っている World（時計は目盛りをまたがない値で止めておく）。
    def racing(): World.World =
        { phase = World.Phase.Racing, t = 1.0 | World.initial(docs()) }

    @Test
    def testNothingHappensIsSilent(): Unit \ Assert =
        // 何も変わらなかったフレームは無音（毎フレーム鳴り続けない）。
        let w = racing();
        Assert.assertEq(expected = (Nil: List[String]), Sfx.events({ before = w, after = w }))

    @Test
    def testDriftStartIsNotAOneShot(): Unit \ Assert =
        // 滑り出しは一発の音を鳴らさない（擦れは鳴り続ける音の側が受け持つ）。
        let w = racing();
        Assert.assertEq(
            expected = (Nil: List[String]),
            Sfx.events({ before = w, after = { drifting = true | w } }))

    @Test
    def testDriftEndGrips(): Unit \ Assert =
        // 滑りが終わったフレームは食いつきの音（擦れとは別の音で終わりが分かる）。
        let w = racing();
        Assert.assertEq(
            expected = "grip" :: Nil,
            Sfx.events({ before = { drifting = true | w }, after = w }))

    @Test
    def testCrashSilencesGrip(): Unit \ Assert =
        // ドリフトのままクラッシュしたフレームはクラッシュの音だけ（食いつきを重ねない）。
        let w = racing();
        Assert.assertEq(
            expected = "crash" :: Nil,
            Sfx.events({ before = { drifting = true | w },
                         after = { spinLeft = RulesDoc.rec(w#rules)#spinDuration | w } }))

    @Test
    def testNitroFires(): Unit \ Assert =
        // ニトロは残り時間が 0 から立ち上がったフレームに鳴る（発動中ずっとではない）。
        let w = racing();
        let fired = { nitroLeft = RulesDoc.rec(w#rules)#nitroDuration | w };
        Assert.assertEq(
            expected = ("nitro" :: Nil, (Nil: List[String])),
            (Sfx.events({ before = w, after = fired }),
             Sfx.events({ before = fired, after = fired })))

    @Test
    def testOvertakeAndItemAndLap(): Unit \ Assert =
        // 抜いた・拾った・1 周した は、それぞれ別の音（同じフレームに重なっても取り違えない）。
        let w = racing();
        let after = { lap = w#lap + 1, taken = Set.insert(0, w#taken),
                      rivals = w#rivals |> List.map(r -> { passed = true | r }) | w };
        Assert.assertEq(
            expected = "item" :: "overtake" :: "lap" :: Nil,
            Sfx.events({ before = w, after = after }))

    @Test
    def testPhaseChangesSound(): Unit \ Assert =
        // 決定（Title → 走行）とゴール（走行 → 勝ち）で違う音が鳴る。
        let w = World.initial(docs());
        Assert.assertEq(
            expected = ("start" :: Nil, "win" :: Nil),
            (Sfx.events({ before = w, after = { phase = World.Phase.Racing | w } }),
             Sfx.events({ before = { phase = World.Phase.Racing | w },
                          after = { phase = World.Phase.Win | w } })))

    // ── 鳴り続ける音 ──

    def humNames(w: World.World): List[String] =
        Sfx.hums(w) |> List.map(h -> h#name)

    @Test
    def testEngineHumsOnlyWhileRacing(): Unit \ Assert =
        // タイトルとゴールの画面は静か。走っている間だけ唸りが続く。
        let w = World.initial(docs());
        Assert.assertEq(
            expected = ((Nil: List[String]), "engine" :: Nil, (Nil: List[String])),
            (humNames(w), humNames(racing()),
             humNames({ phase = World.Phase.Win | racing() })))

    @Test
    def testEngineHumRisesWithSpeed(): Unit \ Assert =
        // 速いほど唸りが高い（数字を読まなくても伸びているのが耳で分かる）。
        let w = racing();
        let pitchAt = sp -> Sfx.hums({ speed = sp | w }) |> List.map(h -> h#pitch);
        let slow = pitchAt(0.0);
        let fast = pitchAt(RulesDoc.rec(w#rules)#forwardSpeed * RulesDoc.rec(w#rules)#nitroBoost);
        Assert.assertEq(expected = true, slow < fast)

    @Test
    def testEngineHumStaysWithinTheDeclaredRange(): Unit \ Assert =
        // 高さは Doc の下限・上限を出ない（速度がどこまで伸びても甲高くなり切らない）。
        let w = racing();
        let pitchAt = sp -> Sfx.hums({ speed = sp | w })
            |> List.map(h -> h#pitch) |> List.head |> Option.getWithDefault(0.0);
        let lo = SfxTuneDoc.rec(w#sfxtune)#enginePitchLow;
        let hi = SfxTuneDoc.rec(w#sfxtune)#enginePitchHigh;
        Assert.assertEq(expected = (lo, hi), (pitchAt(0.0), pitchAt(99999.0)))

    @Test
    def testSkidHumsOnlyWhileDrifting(): Unit \ Assert =
        // 滑っている間だけ擦れが続く（離したフレームで宣言が消えるので音も止まる）。
        let w = racing();
        Assert.assertEq(
            expected = ("engine" :: Nil, "engine" :: "skid" :: Nil),
            (humNames(w), humNames({ drifting = true | w })))
}
