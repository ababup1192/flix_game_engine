// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
mod TestDocs {

    @Test
    def testSampleBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        let doc = SampleDoc.fromJson("{ broken") |> Option.getWithDefault(SampleDoc.defaults());
        Assert.assertEq(expected = SampleDoc.rec(SampleDoc.defaults())#speed, SampleDoc.rec(doc)#speed)

    @Test
    def testSampleOverridesOneField(): Unit \ Assert =
        let doc = SampleDoc.fromJson("{\"version\":1, \"speed\": 99.0}")
            |> Option.getWithDefault(SampleDoc.defaults());
        Assert.assertEq(expected = 99.0, SampleDoc.rec(doc)#speed)

    @Test
    def testKeysBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(KeysDoc.fromJson("{oops")))

    @Test
    def testKeysDropsUnknownNameAndEmptyActionFallsBack(): Unit \ Assert =
        // 書き間違い("Sinistra")はその 1 個だけ落ちる。全部知らない名前で空になった
        // 操作(up)だけ既定へ落ち、触っていない操作(down)は既定のまま。
        let d = KeysDoc.fromJson("{\"left\": [\"Left\", \"Sinistra\"], \"up\": [\"Hop\"]}")
            |> Option.getWithDefault(KeysDoc.defaults());
        Assert.assertEq(
            expected = (GameEngine.Key.Left :: Nil, KeysDoc.rec(KeysDoc.defaults())#up, KeysDoc.rec(KeysDoc.defaults())#down),
            (KeysDoc.rec(d)#left, KeysDoc.rec(d)#up, KeysDoc.rec(d)#down))
}
