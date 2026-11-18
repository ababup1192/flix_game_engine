// TestSample — 作例の町（assets の地図と小物と手触り）そのものの具体値。ゲームは Doc を書き換えるので、テンプレートの中でだけ流す（new-game.exclude）。
mod TestSample {
    def res(): Res.Res \ IO =
        run { Res.loadOrBug(Images.readImageIo, TownScene.TextureNames.SceneTextures, Map.empty(), Res.loadDocsOrBug()) } with Fs.FileRead.runWithIO

    def isBlocked(r: Res.Res, cr: (Int32, Int32)): Bool = Set.memberOf(cr, r#grid#blocked)

    @Test
    def testTownIsTwentySevenBySixtyFour(): Unit \ {Assert, IO} =
        let m = Res.mapOf(res());
        Assert.assertEq(expected = (27, 64), (m#width, m#height))

    @Test
    def testStartCellOnTheSouthAvenueIsOpen(): Unit \ {Assert, IO} = Assert.assertFalse(isBlocked(res(), (13, 54)))

    @Test
    def testPlazaCentreIsOpen(): Unit \ {Assert, IO} = Assert.assertFalse(isBlocked(res(), (13, 47)))

    @Test
    def testMarketStallBlocksItsCell(): Unit \ {Assert, IO} = Assert.assertTrue(isBlocked(res(), (8, 46)))

    @Test
    def testPigeonCellIsOpen(): Unit \ {Assert, IO} = Assert.assertFalse(isBlocked(res(), (10, 50)))

    @Test
    def testPartyOfThreeWalks(): Unit \ {Assert, IO} = Assert.assertEq(expected = 3, List.length(Res.exploreOf(res())#party))

    @Test
    def testWalkSpeedIsFourPointEightFive(): Unit \ {Assert, IO} = Assert.assertEq(expected = 4.85, Res.exploreOf(res())#speed)

    @Test
    def testWalkFrameChangesEveryQuarterSecondOrSo(): Unit \ {Assert, IO} = Assert.assertEq(expected = 0.24, Res.exploreOf(res())#walkFrameSec)
}
