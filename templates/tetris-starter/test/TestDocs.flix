// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
// 期待値はリテラルでなく defaults() から導く（バランス調整でテストが壊れないように）。
mod TestDocs {

    // ══════════════════════════════════════════════════════
    // RulesDoc（手触りと収支の数値）
    // ══════════════════════════════════════════════════════

    @Test
    def testRulesBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定へ落ちる（ゲームは必ず起動する）。
        let doc = RulesDoc.fromJson("{ broken") |> Option.getWithDefault(RulesDoc.defaults());
        Assert.assertEq(expected = RulesDoc.rec(RulesDoc.defaults())#lockDelay, RulesDoc.rec(doc)#lockDelay)

    @Test
    def testRulesOverridesOneField(): Unit \ Assert =
        // 1 フィールドだけ書いた JSON はそこだけ効き、残りは既定のまま。
        let doc = RulesDoc.fromJson("{\"version\":1, \"lockDelay\": 0.9}")
            |> Option.getWithDefault(RulesDoc.defaults());
        Assert.assertEq(
            expected = (0.9, RulesDoc.rec(RulesDoc.defaults())#gravityInterval),
            (RulesDoc.rec(doc)#lockDelay, RulesDoc.rec(doc)#gravityInterval))

    @Test
    def testRulesScoresLengthFollowsJson(): Unit \ Assert =
        // scores 配列の長さを変えれば Doc も追随する（scoreFor が引く表の長さが変わる）。
        let doc = RulesDoc.fromJson("{\"version\":1, \"scores\":[0, 40, 100]}")
            |> Option.getWithDefault(RulesDoc.defaults());
        Assert.assertEq(expected = 3, List.length(RulesDoc.rec(doc)#scores))

    // ══════════════════════════════════════════════════════
    // ThemeDoc（色。RulesDoc と別型 = 色の Or 読みなので橋渡しを 1 本だけ）
    // ══════════════════════════════════════════════════════

    @Test
    def testThemeOverridesOneColor(): Unit \ Assert =
        // 1 色だけ書いた JSON はその色だけ効き、残りは既定のまま。
        let doc = ThemeDoc.fromJson("{\"version\":1, \"bg\": \"#010203\"}")
            |> Option.getWithDefault(ThemeDoc.defaults());
        let d = ThemeDoc.rec(ThemeDoc.defaults());
        // bg は上書きされ、board は既定のまま（色は r で代表して比べる）。
        Assert.assertEq(
            expected = (true, d#board#r),
            (ThemeDoc.rec(doc)#bg#r != d#bg#r, ThemeDoc.rec(doc)#board#r))
}
