// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
mod TestDocs {

    use fge::GameEngine

    // ══════════════════════════════════════════════════════
    // RulesDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None（起動の読み込み RulesDoc.load はそこで既定へ落ちる）。
    @Test
    def testRulesBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        Assert.assertEq(expected = None, RulesDoc.fromJson("{ broken") |> Option.map(doc -> RulesDoc.rec(doc)#undoCap))

    /// 1 欄だけ書いた JSON はそこだけ効き、残りは既定のまま。
    @Test
    def testRulesOverridesOneField(): Unit \ Assert =
        Assert.assertEq(expected = Some((5, RulesDoc.rec(RulesDoc.defaults())#cycle)),
            RulesDoc.fromJson("{\"version\":1, \"shellWidth\": 5}") |> Option.map(doc -> (RulesDoc.rec(doc)#shellWidth, RulesDoc.rec(doc)#cycle)))

    /// 満ち引きの表の長さは JSON に追随する。空の表は既定へ落ちる。
    @Test
    def testRulesCycleFollowsJson(): Unit \ Assert =
        Assert.assertEq(expected = (Some(0 :: 2 :: Nil), Some(RulesDoc.rec(RulesDoc.defaults())#cycle)),
            (RulesDoc.fromJson("{\"version\":1, \"cycle\": [0, 2]}") |> Option.map(doc -> RulesDoc.rec(doc)#cycle),
             RulesDoc.fromJson("{\"version\":1, \"cycle\": []}") |> Option.map(doc -> RulesDoc.rec(doc)#cycle)))

    // ══════════════════════════════════════════════════════
    // LevelsDoc
    // ══════════════════════════════════════════════════════

    /// 面が 1 つも読めない JSON は既定の 1 面で始まる（heights の無い面は読めない）。
    @Test
    def testLevelsWithoutReadableLevelFallBackToDefaults(): Unit \ Assert =
        Assert.assertEq(expected = Some("引き潮の間に渡る" :: Nil),
            LevelsDoc.fromJson("{\"version\":1, \"levels\": [{\"name\": \"heights が無い\"}]}")
                |> Option.map(doc -> LevelsDoc.playableNames(RulesDoc.defaults(), doc)))

    /// 面の cycle は書けば面の物、無ければ rules の既定。
    @Test
    def testLevelCycleOverridesTheRules(): Unit \ Assert =
        let cycleIn = text -> LevelsDoc.fromJson("{\"version\":1, \"levels\": [{\"heights\": [\"00\"], \"props\": [\"@*\"]${text}}]}")
            |> Option.flatMap(doc -> List.head(LevelsDoc.rec(doc)#levels))
            |> Option.map(level -> LevelsDoc.cycleOf(RulesDoc.defaults(), level));
        Assert.assertEq(expected = (Some(Vector#{1}), Some(List.toVector(RulesDoc.rec(RulesDoc.defaults())#cycle))),
            (cycleIn(", \"cycle\": [1]"), cycleIn("")))

    /// 盤の規則に合わない面（ヤドカリが 2 匹）は飛ばし、残りの面で遊べる。
    @Test
    def testLevelThatBreaksTheBoardRulesIsSkipped(): Unit \ Assert =
        let text = "{\"version\":1, \"levels\": [" +
            "{\"name\": \"bad\", \"heights\": [\"000\"], \"props\": [\"@@*\"]}," +
            "{\"name\": \"good\", \"heights\": [\"000\"], \"props\": [\"@.*\"]}]}";
        Assert.assertEq(expected = Some("good" :: Nil),
            LevelsDoc.fromJson(text) |> Option.map(doc -> LevelsDoc.playableNames(RulesDoc.defaults(), doc)))

    // ══════════════════════════════════════════════════════
    // KeysDoc
    // ══════════════════════════════════════════════════════

    @Test
    def testKeysBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(KeysDoc.fromJson("{oops")))

    @Test
    def testKeysDropsUnknownNameAndEmptyActionFallsBack(): Unit \ Assert =
        // 書き間違い("Sinistra")はその 1 個だけ落ちる。全部知らない名前で空になった
        // 操作(up)だけ既定へ落ち、触っていない操作(down)は既定のまま。
        Assert.assertEq(
            expected = Some((GameEngine.Key.Left :: Nil, KeysDoc.rec(KeysDoc.defaults())#up, KeysDoc.rec(KeysDoc.defaults())#down)),
            KeysDoc.fromJson("{\"left\": [\"Left\", \"Sinistra\"], \"up\": [\"Hop\"]}")
                |> Option.map(d -> (KeysDoc.rec(d)#left, KeysDoc.rec(d)#up, KeysDoc.rec(d)#down)))
}
