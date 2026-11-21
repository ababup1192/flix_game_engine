// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
mod TestDocs {

    use fge::GameEngine

    @Test
    def testWalkBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 読めない JSON は None（起動の読み込み WalkDoc.load はそこで既定へ落ちる。ゲームは必ず起動する）。
        Assert.assertEq(expected = None, WalkDoc.fromJson("{ broken") |> Option.map(doc -> WalkDoc.rec(doc)#speed))

    @Test
    def testWalkOverridesOneField(): Unit \ Assert =
        Assert.assertEq(expected = Some(0.9), WalkDoc.fromJson("{\"version\":1, \"speed\": 0.9}") |> Option.map(doc -> WalkDoc.rec(doc)#speed))

    @Test
    def testLookKeepsDefaultsOfAMissingRecordField(): Unit \ Assert =
        // 懐中電灯の 1 欄だけ書いた Doc は、書いていない欄（届く距離）を既定のまま持つ。
        Assert.assertEq(expected = Some((3.0, LookDoc.rec(LookDoc.defaults())#flashlight#range)),
            LookDoc.fromJson("{\"flashlight\": {\"intensity\": 3.0}}") |> Option.map(d -> (LookDoc.rec(d)#flashlight#intensity, LookDoc.rec(d)#flashlight#range)))

    @Test
    def testKeysBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(KeysDoc.fromJson("{oops")))

    @Test
    def testKeysDropsUnknownNameAndEmptyActionFallsBack(): Unit \ Assert =
        // 書き間違い("Sinistra")はその 1 個だけ落ちる。全部知らない名前で空になった
        // 操作(forward)だけ既定へ落ち、触っていない操作(back)は既定のまま。
        Assert.assertEq(
            expected = Some((GameEngine.Key.Left :: Nil, KeysDoc.rec(KeysDoc.defaults())#forward, KeysDoc.rec(KeysDoc.defaults())#back)),
            KeysDoc.fromJson("{\"turnLeft\": [\"Left\", \"Sinistra\"], \"forward\": [\"Hop\"]}")
                |> Option.map(d -> (KeysDoc.rec(d)#turnLeft, KeysDoc.rec(d)#forward, KeysDoc.rec(d)#back)))
}
