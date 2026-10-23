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
