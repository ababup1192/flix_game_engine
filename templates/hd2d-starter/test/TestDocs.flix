// TestDocs — Doc の読み方（壊れた JSON は既定値で続ける・1 欄だけ書いた Doc はほかの欄を既定値にする・地図と小物は読めなければ Err）。
mod TestDocs {
    use fge::{DocJson}

    @Test
    def testBrokenExploreJsonIsNotADoc(): Unit \ Assert =
        Assert.assertTrue(Option.isEmpty(ExploreDoc.fromJson("{ speed: ")))

    @Test
    def testExploreWithOneFieldKeepsTheOtherDefaults(): Unit \ Assert =
        Assert.assertEq(expected = Some(ExploreDoc.rec(ExploreDoc.defaults())#walkFrameSec),
            ExploreDoc.fromJson("{\"speed\": 3.0}") |> Option.map(e -> ExploreDoc.rec(e)#walkFrameSec))

    @Test
    def testExploreReadsTheSpeed(): Unit \ Assert =
        Assert.assertEq(expected = Some(3.0), ExploreDoc.fromJson("{\"speed\": 3.0}") |> Option.map(e -> ExploreDoc.rec(e)#speed))

    @Test
    def testEmptyPartyKeepsTheDefaultParty(): Unit \ Assert =
        Assert.assertEq(expected = Some(List.length(ExploreDoc.rec(ExploreDoc.defaults())#party)),
            ExploreDoc.fromJson("{\"party\": []}") |> Option.map(e -> List.length(ExploreDoc.rec(e)#party)))

    @Test
    def testPartyStripIsReadUnderSprites(): Unit \ Assert =
        let e = ExploreDoc.fromJson("{\"party\": [{\"strip\": \"a.png\", \"idleStrip\": \"b.png\"}]}");
        Assert.assertEq(expected = Some(("sprites/a.png", "sprites/b.png")),
            e |> Option.flatMap(d -> List.head(ExploreDoc.rec(d)#party)) |> Option.map(w -> (w#strip, w#idleStrip)))

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
        Assert.assertEq(expected = Some(1.0), TownLook.fromJson("{\"sky\": \"#ff0000\"}") |> Option.map(l -> TownLook.rec(l)#sky#r))

    @Test
    def testLookWithABrokenColorKeepsTheDefault(): Unit \ Assert =
        Assert.assertEq(expected = Some(TownLook.rec(TownLook.defaults())#sky#b),
            TownLook.fromJson("{\"sky\": \"blue\"}") |> Option.map(l -> TownLook.rec(l)#sky#b))

    @Test
    def testDecorWithoutPropsIsRefused(): Unit \ Assert =
        Assert.assertEq(expected = Some(true), DocJson.parse("{\"version\": 1}") |> Option.map(j -> Result.isErr(TownDecor.decode(j))))

    @Test
    def testDecorWithoutSpriteIsSkipped(): Unit \ Assert =
        let ds = DocJson.parse("{\"props\": [{\"col\": 1}, {\"sprite\": \"dog.png\"}]}") |> Option.toOk("JSON") |> Result.flatMap(TownDecor.decode);
        Assert.assertEq(expected = Ok(Some("sprites/dog.png")), ds |> Result.map(xs -> List.head(xs) |> Option.map(d -> d#sprite)))

    @Test
    def testDecorSwayNeedsAnAmplitude(): Unit \ Assert =
        let ds = DocJson.parse("{\"props\": [{\"sprite\": \"balloon.png\", \"swaySec\": 2.0}]}") |> Option.toOk("JSON") |> Result.flatMap(TownDecor.decode);
        Assert.assertEq(expected = Ok(Some(None)), ds |> Result.map(xs -> List.head(xs) |> Option.map(d -> d#sway)))
}
