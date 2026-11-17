// TestScene3dMaterialMip — 材質の絵の mip のレベルの数の上限（withMaxMipLevels・atlasMipLevelsFor・materialMipLevelsOf）の約束。

def mipSpec(): ShaderDoc.Spec =
    { name = "mip", cycleRate = 0.0, bindings = Nil,
      out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid(Color.rgb(1.0, 1.0, 1.0)), alpha = ShaderDoc.Field.Const(1.0) }) }

/// 足したての材質は上限なし（絵の段の数のまま読む）。
@Test
def testNewMaterialReadsAllLevels(): Unit \ Assert =
    Assert.assertEq(expected = 7, Scene3d.materialMipLevelsOf(Scene3d.materialFieldsOf(Scene3d.material(mipSpec())), 7))

/// withMaxMipLevels を付けた材質は、絵の段の数と上限の小さい方を読む。
@Test
def testCappedMaterialReadsUpToTheCap(): Unit \ Assert =
    let m = Scene3d.material(mipSpec()) |> Scene3d.withMaxMipLevels(5);
    Assert.assertEq(expected = (5, 3), (Scene3d.materialMipLevelsOf(Scene3d.materialFieldsOf(m), 7), Scene3d.materialMipLevelsOf(Scene3d.materialFieldsOf(m), 3)))

/// 上限は 1 より小さくならない。
@Test
def testCapIsAtLeastOne(): Unit \ Assert =
    let m = Scene3d.material(mipSpec()) |> Scene3d.withMaxMipLevels(0);
    Assert.assertEq(expected = 1, Scene3d.materialFieldsOf(m)#maxMipLevels)

/// 16 px のタイルはレベル 0〜4（5 つ）・32 px は 6 つ・24 px は 4 つ・48 px は 5 つ・1 px は 1 つ（2^k がタイルの一辺を割り切るレベルまで）。
@Test
def testAtlasLevelsFollowTheTileSize(): Unit \ Assert =
    Assert.assertEq(expected = (5, 6, 4, 5, 1), (Scene3d.atlasMipLevelsFor(16), Scene3d.atlasMipLevelsFor(32), Scene3d.atlasMipLevelsFor(24), Scene3d.atlasMipLevelsFor(48), Scene3d.atlasMipLevelsFor(1)))
