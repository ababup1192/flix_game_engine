// RenderTarget の MSAA の口（withMsaa・samplesOf）: 既定は 1・1/2/4/8 へ下へ丸める・1 未満は 1。

/// 既定の作り方は MSAA なし（標本 1）。
@Test
def testDefaultDescriptorHasOneSample(): Unit \ Assert =
    Assert.assertEq(expected = (1, 1), (RenderTarget.samplesOf(RenderTarget.defaultDescriptor()), RenderTarget.samplesOf(RenderTarget.windowDescriptor())))

/// 1・2・4・8 はそのまま、ほかは近い下の値（3 → 2・6 → 4・16 → 8）、1 未満は 1。
@Test
def testSamplesRoundDownToSupportedCounts(): Unit \ Assert =
    let of = (n: Int32) -> RenderTarget.samplesOf(RenderTarget.withMsaa(n, RenderTarget.windowDescriptor()));
    Assert.assertEq(expected = 1 :: 1 :: 1 :: 2 :: 2 :: 4 :: 4 :: 8 :: 8 :: Nil,
                    of(-3) :: of(0) :: of(1) :: of(2) :: of(3) :: of(4) :: of(6) :: of(8) :: of(16) :: Nil)

/// withMsaa は標本の数だけを替え、形式と倍率はそのまま。
@Test
def testWithMsaaKeepsOtherFields(): Unit \ Assert =
    let d = RenderTarget.withMsaa(4, RenderTarget.withHdr({ scale = 0.5 | RenderTarget.windowDescriptor() }));
    Assert.assertEq(expected = (0.5, RenderTarget.Format.Rgba16Float, 4), (d#scale, d#format, d#samples))
