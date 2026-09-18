// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
// 期待値はリテラルでなく defaults() から導く（バランス調整でテストが壊れないように）。
// デコーダの網羅は共通層（JsonCodec）の仕事 — ここは「この Doc の橋が架かっているか」だけ見る。
mod TestDocs {

    // ══════════════════════════════════════════════════════
    // RulesDoc（手触りと収支の数値）
    // ══════════════════════════════════════════════════════

    @Test
    def testRulesBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定へ落ちる（ゲームは必ず起動する）。
        let doc = RulesDoc.fromJson("{ broken") |> Option.getWithDefault(RulesDoc.defaults());
        Assert.assertEq(expected = RulesDoc.rec(RulesDoc.defaults())#forwardSpeed, RulesDoc.rec(doc)#forwardSpeed)

    @Test
    def testRulesOverridesOneField(): Unit \ Assert =
        // 1 フィールド（nitroBoost）だけ書いた JSON はそこだけ効き、残りは既定のまま。
        let doc = RulesDoc.fromJson("{\"version\":1, \"nitroBoost\": 2.5}")
            |> Option.getWithDefault(RulesDoc.defaults());
        Assert.assertEq(
            expected = (2.5, RulesDoc.rec(RulesDoc.defaults())#forwardSpeed),
            (RulesDoc.rec(doc)#nitroBoost, RulesDoc.rec(doc)#forwardSpeed))

    // ══════════════════════════════════════════════════════
    // RivalsDoc（敵の性格と追いかけ方。rows = 台数）
    // ══════════════════════════════════════════════════════

    @Test
    def testRivalsBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定の 3 台へ落ちる。
        let doc = RivalsDoc.fromJson("{ broken") |> Option.getWithDefault(RivalsDoc.defaults());
        Assert.assertEq(
            expected = List.length(RivalsDoc.rec(RivalsDoc.defaults())#rows),
            List.length(RivalsDoc.rec(doc)#rows))

    @Test
    def testRivalsRowCountFollowsJson(): Unit \ Assert =
        // rows 配列の長さを変えれば台数も追随する（2 台の JSON なら 2 台）。
        let doc = RivalsDoc.fromJson("{\"version\":1, \"rows\":[{\"speed\":100}, {\"speed\":90}]}")
            |> Option.getWithDefault(RivalsDoc.defaults());
        Assert.assertEq(expected = 2, List.length(RivalsDoc.rec(doc)#rows))

    @Test
    def testRivalsOverridesOneField(): Unit \ Assert =
        // 1 フィールド（rubberCatchUp）だけ書いた JSON はそこだけ効き、残りは既定のまま。
        let doc = RivalsDoc.fromJson("{\"version\":1, \"rubberCatchUp\": 0.5}")
            |> Option.getWithDefault(RivalsDoc.defaults());
        Assert.assertEq(
            expected = (0.5, RivalsDoc.rec(RivalsDoc.defaults())#rubberRange),
            (RivalsDoc.rec(doc)#rubberCatchUp, RivalsDoc.rec(doc)#rubberRange))

    // ══════════════════════════════════════════════════════
    // ThemeDoc（色。別型 = 色の Or 読みなので橋渡しを 1 本だけ）
    // ══════════════════════════════════════════════════════

    @Test
    def testThemeOverridesOneColor(): Unit \ Assert =
        // 1 色（player）だけ書いた JSON はその色だけ効き、残りは既定のまま。
        let doc = ThemeDoc.fromJson("{\"version\":1, \"player\": \"#010203\"}")
            |> Option.getWithDefault(ThemeDoc.defaults());
        let d = ThemeDoc.rec(ThemeDoc.defaults());
        let t = ThemeDoc.rec(doc);
        Assert.assertEq(
            expected = (true, d#road#r),
            (t#player#r != d#player#r, t#road#r))

    // ══════════════════════════════════════════════════════
    // CourseDoc（区間の表。行数は len の合計 + 行 → 区間の割り当て）
    // ══════════════════════════════════════════════════════

    @Test
    def testCourseRowCountAndSectionLookup(): Unit \ Assert =
        // len の合計が行数（2 + 3 = 5 行）。通し行 0 は 1 区間目、通し行 2 は 2 区間目の頭で、
        // 曲がりも坂も道幅もその区間の値になる（width 50% → 半幅は基準の半分）。
        let doc = CourseDoc.fromJson(
                "{\"version\":1, \"sections\":[{\"len\":2}, "
                    + "{\"len\":3, \"curve\":9, \"hill\":2, \"width\":50}]}")
            |> Option.getWithDefault(CourseDoc.defaults());
        Assert.assertEq(
            expected = (5, 0.0, 9.0, 2.0, CourseDoc.baseHalfWidth() / 2.0),
            (CourseDoc.rowCount(doc), CourseDoc.curveAt(0, doc), CourseDoc.curveAt(2, doc),
             CourseDoc.hillAt(2, doc), CourseDoc.halfWidthAt(2, doc)))

    @Test
    def testCourseWrapsAndResolvesOutsideRail(): Unit \ Assert =
        // 行は先頭へ巻き戻して周回する（5 行のコースの通し行 5 は 0 と同じ区間）。
        // "out" は曲がりの向きの反対側に壁を立て、直線の区間では立たない。
        let doc = CourseDoc.fromJson(
                "{\"version\":1, \"sections\":[{\"len\":2, \"rail\":\"out\"}, "
                    + "{\"len\":3, \"curve\":9, \"rail\":\"out\"}]}")
            |> Option.getWithDefault(CourseDoc.defaults());
        Assert.assertEq(
            expected = (0, 0.0, -1.0, 0.0),
            (CourseDoc.wrapRow(5, doc), CourseDoc.railSideAt(0, doc),
             CourseDoc.railSideAt(2, doc), CourseDoc.railSideAt(5, doc)))

    // ══════════════════════════════════════════════════════
    // PropsDoc（置き場の表。rows の 1 行 = コースの 1 行・1 文字 = 1 レーン）
    // ══════════════════════════════════════════════════════

    @Test
    def testPropsRowsMapCharsToLanes(): Unit \ Assert =
        // 行の文字がそのままレーンの物になる。書いていない行は何も無い（fail-open）。
        let doc = PropsDoc.fromJson("{\"version\":1, \"rows\":[\"..X......\", \".........\"]}")
            |> Option.getWithDefault(PropsDoc.defaults());
        let kinds = m -> PropsDoc.cellsAt(m, doc) |> List.map(c -> (c#lane, c#kind));
        Assert.assertEq(
            expected = ((2, PropsDoc.Kind.Cone) :: Nil, (Nil: List[(Int32, PropsDoc.Kind)]),
                        (Nil: List[(Int32, PropsDoc.Kind)])),
            (kinds(0), kinds(1), kinds(9)))

    @Test
    def testPropsLaneOffSpansTheRoadWidth(): Unit \ Assert =
        // 左端の列は道の左端寄り、真ん中の列は道の中心、右端の列は道の右端寄り。
        // 列は画面の位置ではなく道の中のレーンなので、道幅を渡すと px になる。
        let half = 90.0;
        let mid = PropsDoc.lanes() / 2;
        Assert.assertEq(
            expected = (0.0, true, true),
            (PropsDoc.laneOff(mid, half),
             PropsDoc.laneOff(0, half) < 0.0 - half * 0.8,
             PropsDoc.laneOff(PropsDoc.lanes() - 1, half) > half * 0.8))

    // ══════════════════════════════════════════════════════
    // PaletteDoc（ドット絵の意味色。上書きが resolve で読める + 欠けキーは既定で埋まる）
    // ══════════════════════════════════════════════════════

    @Test
    def testPaletteOverrideAndFillMissing(): Unit \ Assert =
        // colors に 1 色（ink）だけ書いた JSON: ink はその色に変わり、
        // 書かなかったキー（tire）は既定で埋まる（欠けた色で絵に穴を開けない）。
        let doc = PaletteDoc.fromJson("{\"version\":1, \"colors\": {\"ink\": \"#112233\"}}")
            |> Option.getWithDefault(PaletteDoc.defaults());
        let d = PaletteDoc.defaults();
        Assert.assertEq(
            expected = (true, PaletteDoc.resolve(d, "tire")#r),
            (PaletteDoc.resolve(doc, "ink")#r != PaletteDoc.resolve(d, "ink")#r,
             PaletteDoc.resolve(doc, "tire")#r))

    // ══════════════════════════════════════════════════════
    // SfxTuneDoc（効果音のつまみ。入れ子の節を 1 つずつ読む）
    // ══════════════════════════════════════════════════════

    @Test
    def testSfxTuneOverridesOneKnob(): Unit \ Assert =
        // 1 つの音（nitro）の音量だけ書いた JSON: そこだけ効き、同じ節の高さも他の音も既定のまま。
        let doc = SfxTuneDoc.fromJson("{\"version\":1, \"nitro\": {\"volume\": 0.25}}")
            |> Option.getWithDefault(SfxTuneDoc.defaults());
        let d = SfxTuneDoc.rec(SfxTuneDoc.defaults());
        let t = SfxTuneDoc.rec(doc);
        Assert.assertEq(
            expected = (0.25, d#nitro#pitch, d#crash#volume),
            (t#nitro#volume, t#nitro#pitch, t#crash#volume))

    @Test
    def testSfxTuneRejectsZeroSpeed(): Unit \ Assert =
        // 速さ 0 は長さ 0 の無音になるので下限で受け止める（つまみで音を消させない）。
        let doc = SfxTuneDoc.fromJson("{\"version\":1, \"skid\": {\"speed\": 0.0}}")
            |> Option.getWithDefault(SfxTuneDoc.defaults());
        Assert.assertEq(expected = true, SfxTuneDoc.rec(doc)#skid#speed > 0.0)
}
