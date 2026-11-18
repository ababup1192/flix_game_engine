// TestDocs — Doc の読み方（壊れた JSON は既定値で続ける・1 欄だけ書いた Doc はほかの欄を既定値にする・地図と小物は読めなければ Err）。
mod TestDocs {
    use fge::{DocJson}

    @Test
    def testBrokenExploreJsonIsNotADoc(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(ExploreDoc.fromJson("{ speed: ")))

    @Test
    def testExploreWithOneFieldKeepsTheOtherDefaults(): Unit \ Assert =
        let e = ExploreDoc.fromJson("{\"speed\": 3.0}") |> Option.getWithDefault(ExploreDoc.defaults()) |> ExploreDoc.rec;
        Assert.assertEq(expected = ExploreDoc.rec(ExploreDoc.defaults())#walkFrameSec, e#walkFrameSec)

    @Test
    def testExploreReadsTheSpeed(): Unit \ Assert =
        let e = ExploreDoc.fromJson("{\"speed\": 3.0}") |> Option.getWithDefault(ExploreDoc.defaults()) |> ExploreDoc.rec;
        Assert.assertEq(expected = 3.0, e#speed)

    @Test
    def testEmptyPartyKeepsTheDefaultParty(): Unit \ Assert =
        let e = ExploreDoc.fromJson("{\"party\": []}") |> Option.getWithDefault(ExploreDoc.defaults()) |> ExploreDoc.rec;
        Assert.assertEq(expected = List.length(ExploreDoc.rec(ExploreDoc.defaults())#party), List.length(e#party))

    @Test
    def testPartyStripIsReadUnderSprites(): Unit \ Assert =
        let e = ExploreDoc.fromJson("{\"party\": [{\"strip\": \"a.png\", \"idleStrip\": \"b.png\"}]}") |> Option.getWithDefault(ExploreDoc.defaults()) |> ExploreDoc.rec;
        Assert.assertEq(expected = ("sprites/a.png", "sprites/b.png") :: Nil, e#party |> List.map(w -> (w#strip, w#idleStrip)))

    @Test
    def testShadowKnobReplacesTheShadowMapSize(): Unit \ Assert =
        let q = ExploreDoc.qualityWith(Map#{ "shadow" => "1024" }, ExploreDoc.rec(ExploreDoc.defaults())#quality);
        Assert.assertEq(expected = 1024, q#shadowMapSize)

    @Test
    def testUnknownKnobValueKeepsTheDoc(): Unit \ Assert =
        let d = ExploreDoc.rec(ExploreDoc.defaults())#quality;
        Assert.assertEq(expected = d#depthOfField, ExploreDoc.qualityWith(Map#{ "dof" => "yes" }, d)#depthOfField)

    @Test
    def testQueryPairsBecomeKnobs(): Unit \ Assert =
        Assert.assertEq(expected = Map#{ "shadow" => "2048", "dof" => "0" }, Knobs.ofPairs("shadow" :: "2048" :: "dof" :: "0" :: Nil))

    @Test
    def testBrokenLookJsonIsNotADoc(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(TownLook.fromJson("[1, 2")))

    @Test
    def testLookReadsAHexColor(): Unit \ Assert =
        let l = TownLook.fromJson("{\"sky\": \"#ff0000\"}") |> Option.getWithDefault(TownLook.defaults()) |> TownLook.rec;
        Assert.assertEq(expected = 1.0, l#sky#r)

    @Test
    def testLookWithABrokenColorKeepsTheDefault(): Unit \ Assert =
        let l = TownLook.fromJson("{\"sky\": \"blue\"}") |> Option.getWithDefault(TownLook.defaults()) |> TownLook.rec;
        Assert.assertEq(expected = TownLook.rec(TownLook.defaults())#sky#b, l#sky#b)

    @Test
    def testDecorWithoutPropsIsRefused(): Unit \ Assert =
        Assert.assertTrue(DocJson.parse("{\"version\": 1}") |> Option.map(j -> Result.isErr(TownDecor.decode(j))) |> Option.getWithDefault(false))

    @Test
    def testDecorWithoutSpriteIsSkipped(): Unit \ Assert =
        let ds = DocJson.parse("{\"props\": [{\"col\": 1}, {\"sprite\": \"dog.png\"}]}") |> Option.toOk("JSON") |> Result.flatMap(TownDecor.decode);
        Assert.assertEq(expected = Ok("sprites/dog.png" :: Nil), ds |> Result.map(List.map(d -> d#sprite)))

    @Test
    def testDecorSwayNeedsAnAmplitude(): Unit \ Assert =
        let ds = DocJson.parse("{\"props\": [{\"sprite\": \"balloon.png\", \"swaySec\": 2.0}]}") |> Option.toOk("JSON") |> Result.flatMap(TownDecor.decode);
        Assert.assertEq(expected = Ok(None :: Nil), ds |> Result.map(List.map(d -> d#sway)))
}
