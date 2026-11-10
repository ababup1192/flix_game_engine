// Tests for GamepadMap（パッドとキーの対応表・パッドの機種の見分け）

/// 表に同じボタンが 2 回出ない（1 ボタン = 1 キー。1 押しで決定が 2 連発しない）
@Test
def testEachPadInputHasOneKey(): Unit \ Assert =
    let inputs = GamepadMap.table() |> List.map(snd);
    Assert.assertEq(expected = List.length(inputs), Set.size(List.toSet(inputs)))

/// 表に同じキーが 2 回出ない（byKey で片方が消えない）
@Test
def testEachKeyHasOnePadInput(): Unit \ Assert =
    let keys = GamepadMap.table() |> List.map(fst);
    Assert.assertEq(expected = List.length(keys), Set.size(List.toSet(keys)))

/// Start は Menu キーになる
@Test
def testStartIsMenuKey(): Unit \ Assert =
    Assert.assertEq(expected = Some(GamepadMap.PadInput.Start), Map.get(GameEngine.Key.Menu, GamepadMap.byKey()))

/// Select（Back / View）は Backspace キーになる
@Test
def testBackIsBackspaceKey(): Unit \ Assert =
    Assert.assertEq(expected = Some(GamepadMap.PadInput.Back), Map.get(GameEngine.Key.Backspace, GamepadMap.byKey()))

/// Enter はパッドのどのボタンからも押されない（決定と Start を見分けるため）
@Test
def testEnterHasNoPadInput(): Unit \ Assert =
    Assert.assertEq(expected = None, Map.get(GameEngine.Key.Enter, GamepadMap.byKey()))

/// Escape はパッドのどのボタンからも押されない（マップの上で終了を呼ぶため）
@Test
def testEscapeHasNoPadInput(): Unit \ Assert =
    Assert.assertEq(expected = None, Map.get(GameEngine.Key.Escape, GamepadMap.byKey()))

/// A は決定の Z キーになる
@Test
def testAIsZKey(): Unit \ Assert =
    Assert.assertEq(expected = Some(GamepadMap.PadInput.A), Map.get(GameEngine.Key.Z, GamepadMap.byKey()))

/// ベンダーが Valve（28de）の GUID は Steam（Steam Deck の内蔵パッド）
@Test
def testValveVendorIsSteam(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Steam,
        GamepadMap.kindOf("03000000de2800000512000011010000", "Steam Deck"))

/// GUID の 16 進が大文字でもベンダーを読める
@Test
def testUpperCaseGuidIsRead(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Steam,
        GamepadMap.kindOf("03000000DE280000FF11000001000000", "Generic X-Box pad"))

/// Microsoft（045e）の Xbox のパッドは一般
@Test
def testXboxPadIsGeneric(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Generic,
        GamepadMap.kindOf("030000005e0400008e02000014010000", "Xbox 360 Controller"))

/// ベンダーの 2 バイトを逆に読まない（28de と de28 を取り違えない）
@Test
def testVendorBytesAreLittleEndian(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Generic,
        GamepadMap.kindOf("0300000028de00000512000011010000", "Pad"))

/// GUID にベンダーが無くても、名前に Steam があれば Steam
@Test
def testSteamNameIsSteam(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Steam,
        GamepadMap.kindOf("", "Steam Virtual Gamepad"))

/// GUID も名前も無ければ（つないでいない）不明
@Test
def testNothingIsUnknown(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Unknown, GamepadMap.kindOf("", ""))

/// 形の違う GUID は名前だけで決める（読めた名前がふつうなら一般）
@Test
def testShortGuidFallsBackToName(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Generic, GamepadMap.kindOf("de28", "Wireless Controller"))

/// SDL3 で読んだベンダーが Valve（0x28de）なら Steam
@Test
def testSdlValveVendorIsSteam(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Steam, GamepadMap.kindOfVendor(0x28de, "Steam Controller"))

/// SDL3 で読んだベンダーが他社なら一般
@Test
def testSdlOtherVendorIsGeneric(): Unit \ Assert =
    Assert.assertEq(expected = GamepadMap.PadKind.Generic, GamepadMap.kindOfVendor(0x045e, "Xbox Series X Controller"))

/// 遊びの中は (0, 0)（軸ごとでなく長さで見る: (0.1, 0.1) は長さ 0.14 で遊びの中）
@Test
def testStickInsideDeadzoneIsZero(): Unit \ Assert =
    Assert.assertEq(expected = ((0.0, 0.0), (0.0, 0.0)),
                    (pairOf(GamepadMap.stickOf(0.18, 0.1, 0.1)), pairOf(GamepadMap.stickOf(0.18, -0.17, 0.0))))

def pairOf(v: Vec2.Vec2): (Float64, Float64) = (v#x, v#y)

/// 遊びの境目のすぐ外は長さがほぼ 0（そこから 1 まで伸ばし直すので、境目で値が跳ばない）
@Test
def testStickJustOutsideDeadzoneIsNearZero(): Unit \ Assert =
    let v = GamepadMap.stickOf(0.18, 0.19, 0.0);
    Assert.assertTrue(v#x > 0.0 and v#x < 0.02)

/// いっぱいまで倒すと長さ 1、それ以上の生の値（斜めの角で 1 を超える）も 1 で頭打ち
@Test
def testStickFullTiltHasLengthOne(): Unit \ Assert =
    let straight = Vec2.length(GamepadMap.stickOf(0.18, 1.0, 0.0));
    let corner = Vec2.length(GamepadMap.stickOf(0.18, 1.0, 1.0));
    Assert.assertEq(expected = (1.0, true), (straight, Float64.abs(corner - 1.0) < 0.0001))

/// 斜め 45 度は向きが保たれる（x と y の大きさが同じ）
@Test
def testStickKeepsDiagonalDirection(): Unit \ Assert =
    let v = GamepadMap.stickOf(0.18, 0.6, 0.6);
    Assert.assertEq(expected = true, Float64.abs(v#x - Float64.abs(v#y)) < 0.0001 and v#x > 0.0)

/// 生の軸は下が正なので、-1（上いっぱい）は +y になる。右は +x のまま
@Test
def testStickRawUpBecomesPositiveY(): Unit \ Assert =
    Assert.assertEq(expected = ((0.0, 1.0), (1.0, 0.0)),
                    (pairOf(GamepadMap.stickOf(0.18, 0.0, -1.0)), pairOf(GamepadMap.stickOf(0.18, 1.0, 0.0))))

/// 小数 4 桁に丸め、-0 は出さない（遊んだ記録の字と同じ精度）
@Test
def testStickIsRoundedToFourDigits(): Unit \ Assert =
    let v = GamepadMap.stickOf(0.0, 0.123456, 0.0);
    Assert.assertEq(expected = ("0.1235", "0.0"), (Float64.toString(v#x), Float64.toString(v#y)))
