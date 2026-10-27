// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
mod TestDocs {

    use fge::GameEngine

    @Test
    def testSampleBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 読めない JSON は None（起動の読み込み SampleDoc.load はそこで既定へ落ちる。ゲームは必ず起動する）。
        Assert.assertEq(expected = None, SampleDoc.fromJson("{ broken") |> Option.map(doc -> SampleDoc.rec(doc)#speed))

    @Test
    def testSampleOverridesOneField(): Unit \ Assert =
        Assert.assertEq(expected = Some(99.0),
            SampleDoc.fromJson("{\"version\":1, \"speed\": 99.0}") |> Option.map(doc -> SampleDoc.rec(doc)#speed))

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
