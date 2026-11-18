// TestFinalCut — 通しのコマ番号から場面と場面のコマを引く所と、白い四角の α の式を具体値で固定する。
mod TestFinalCut {
    use fge::{DocJson, JsonCodec}
    use BuildVideo.{Source}
    use FinalCut.{Cut}

    /// 町 100 コマ（頭から）・炎 80 コマ（場面の 12 コマ目から）・氷 40 コマ（18 コマ目から）・白くなる 24 コマ・消える 36 コマ。
    def cut3(): Cut =
        { shots = Vector#{ { name = "town", source = Source.Plan("t.json"), look = "a.json", start = 0, frames = 100 },
                           { name = "fire", source = Source.MapWalk("f.json"), look = "b.json", start = 12, frames = 80 },
                           { name = "ice", source = Source.MapWalk("i.json"), look = "c.json", start = 18, frames = 40 } },
          fadeIn = 24, fadeOut = 36, fadeOutPower = 2.5 }

    def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 0.0001

    @Test
    def testTotalIsTheSumOfTheCuts(): Unit \ Assert =
        Assert.assertEq(expected = 220, FinalCut.totalFrames(cut3()))

    @Test
    def testFirstFrameIsTheTownHead(): Unit \ Assert =
        Assert.assertEq(expected = Some((0, 0)), FinalCut.locate(cut3(), 0))

    @Test
    def testLastTownFrame(): Unit \ Assert =
        Assert.assertEq(expected = Some((0, 99)), FinalCut.locate(cut3(), 99))

    @Test
    def testFireStartsAtItsFromFrame(): Unit \ Assert =
        Assert.assertEq(expected = Some((1, 12)), FinalCut.locate(cut3(), 100))

    @Test
    def testIceFrameIsOffsetByItsFrom(): Unit \ Assert =
        Assert.assertEq(expected = Some((2, 23)), FinalCut.locate(cut3(), 185))

    @Test
    def testPastTheEndIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, FinalCut.locate(cut3(), 220))

    @Test
    def testBatchAcrossTheSeamNeedsTwoShots(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: 1 :: Nil, FinalCut.shotsIn(cut3(), 64, 64))

    @Test
    def testBatchInsideTheTownNeedsOnlyTheTown(): Unit \ Assert =
        Assert.assertEq(expected = 0 :: Nil, FinalCut.shotsIn(cut3(), 0, 64))

    @Test
    def testNoWhiteFarFromTheSeam(): Unit \ Assert =
        Assert.assertTrue(near(0.0, FinalCut.whiteAlpha(cut3(), 50)))

    @Test
    def testWhiteStartsFadeInFramesBeforeTheSeam(): Unit \ Assert =
        Assert.assertTrue(near(1.0 / 24.0, FinalCut.whiteAlpha(cut3(), 76)))

    @Test
    def testFrameBeforeTheSeamIsFullWhite(): Unit \ Assert =
        Assert.assertTrue(near(1.0, FinalCut.whiteAlpha(cut3(), 99)))

    @Test
    def testFirstFrameOfTheNextShotIsFullWhite(): Unit \ Assert =
        Assert.assertTrue(near(1.0, FinalCut.whiteAlpha(cut3(), 100)))

    @Test
    def testWhiteFadesOutWithThePower(): Unit \ Assert =
        Assert.assertTrue(near(Float64.pow(base = 0.5, 2.5), FinalCut.whiteAlpha(cut3(), 118)))

    @Test
    def testWhiteIsGoneAfterFadeOut(): Unit \ Assert =
        Assert.assertTrue(near(0.0, FinalCut.whiteAlpha(cut3(), 136)))

    @Test
    def testSecondSeamAlsoWhitens(): Unit \ Assert =
        Assert.assertTrue(near(1.0, FinalCut.whiteAlpha(cut3(), 180)))

    @Test
    def testNoCoverWithoutWhite(): Unit \ Assert =
        Assert.assertTrue(List.isEmpty(FinalCut.whiteCover({ x = 1280.0, y = 720.0 }, 0.0)))

    @Test
    def testSceneWithoutSourceIsRejected(): Unit \ Assert =
        let json = "{\"scenes\": [{\"name\": \"x\", \"frames\": 10}]}";
        let read = DocJson.parse(json) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("x") |> Result.flatMap(FinalCut.cutOf("x"));
        Assert.assertTrue(Result.isErr(read))

    @Test
    def testFadeSecondsBecomeFrames(): Unit \ Assert =
        let json = "{\"fadeInSec\": 0.8, \"fadeOutSec\": 1.2, \"scenes\": [{\"walkMap\": \"m.json\", \"frames\": 10}]}";
        let read = DocJson.parse(json) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("x") |> Result.flatMap(FinalCut.cutOf("x"));
        Assert.assertEq(expected = Ok((24, 36)), read |> Result.map(c -> (c#fadeIn, c#fadeOut)))

    @Test
    def testFinalDocReads(): Unit \ {Assert, IO} =
        let read = run { FinalCut.load("assets/final.json") } with Fs.FileRead.runWithIO;
        Assert.assertEq(expected = Ok(3), read |> Result.map(c -> Vector.length(c#shots)))
}
