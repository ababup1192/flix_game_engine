// assets の面（tidepool.levels.json）が解き方どおりに解けること。最少であることは make solve が確かめ、
// ここはその時の面の中身の指紋が今の面と同じかを見る（面を直して make solve を回し忘れると止まる）。
mod TestLevels {

    def docs(): (RulesDoc.Doc, LevelsDoc.Doc) \ Fs.FileRead =
        (RulesDoc.load(RulesDoc.path()), LevelsDoc.load(LevelsDoc.path()))

    /// どの面も solution を流すとクリアし、手数は par。
    @Test
    def testEverySolutionClearsInPar(): Unit \ Assert + Fs.FileRead =
        let (rules, levels) = docs();
        Assert.assertEq(expected = Nil, Solve.replayProblems(rules, levels))

    /// どの面も、今の中身の指紋が make solve の書いた solvedHash と同じ。
    @Test
    def testEveryLevelWasSolvedAsItIsNow(): Unit \ Assert + Fs.FileRead =
        let (rules, levels) = docs();
        Assert.assertEq(expected = Nil, Solve.staleLevels(rules, levels))

    /// 深さを区切った幅優先は最少手数を返す: 面 1 の盤は par 手で解け、par − 1 手までには解けない。
    @Test
    def testShortestFindsTheFewestMoves(): Unit \ Assert =
        let b = Fixtures.crossing();
        Assert.assertEq(expected = (Some("WWWWRRRRR"), None),
            (Solve.shortest(9, b) |> Option.map(World.textOf), Solve.shortest(8, b) |> Option.map(World.textOf)))
}
