// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
// 期待値はリテラルでなく defaults() から導く（バランス調整でテストが壊れないように）。
mod TestDocs {

    use fge::Color

    // ══════════════════════════════════════════════════════
    // RulesDoc（手触りと収支の数値）
    // ══════════════════════════════════════════════════════

    @Test
    def testRulesBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 読めない JSON は None（起動の読み込み RulesDoc.load はそこで既定へ落ちる。ゲームは必ず起動する）。
        Assert.assertEq(expected = None, RulesDoc.fromJson("{ broken") |> Option.map(doc -> RulesDoc.rec(doc)#lockDelay))

    @Test
    def testRulesOverridesOneField(): Unit \ Assert =
        // 1 フィールドだけ書いた JSON はそこだけ効き、残りは既定のまま。
        Assert.assertEq(
            expected = Some((0.9, RulesDoc.rec(RulesDoc.defaults())#gravityInterval)),
            RulesDoc.fromJson("{\"version\":1, \"lockDelay\": 0.9}")
                |> Option.map(doc -> (RulesDoc.rec(doc)#lockDelay, RulesDoc.rec(doc)#gravityInterval)))

    @Test
    def testRulesScoresLengthFollowsJson(): Unit \ Assert =
        // scores 配列の長さを変えれば Doc も追随する（scoreFor が引く表の長さが変わる）。
        Assert.assertEq(expected = Some(0 :: 40 :: 100 :: Nil),
            RulesDoc.fromJson("{\"version\":1, \"scores\":[0, 40, 100]}") |> Option.map(doc -> RulesDoc.rec(doc)#scores))

    // ══════════════════════════════════════════════════════
    // ThemeDoc（色。RulesDoc と別型 = 色の Or 読みなので橋渡しを 1 本だけ）
    // ══════════════════════════════════════════════════════

    @Test
    def testThemeOverridesOneColor(): Unit \ Assert =
        // 1 色だけ書いた JSON はその色だけ効き（bg）、残りは既定のまま（board）。
        Assert.assertEq(
            expected = Some((Color.hex("#010203") |> Option.map(rgb), rgb(ThemeDoc.rec(ThemeDoc.defaults())#board))),
            ThemeDoc.fromJson("{\"version\":1, \"bg\": \"#010203\"}")
                |> Option.map(doc -> (Some(rgb(ThemeDoc.rec(doc)#bg)), rgb(ThemeDoc.rec(doc)#board))))

    /// 色の 3 つの値（Color の record は Eq を持たないので組にして比べる）。
    def rgb(c: Color): (Float64, Float64, Float64) = (c#r, c#g, c#b)
}
