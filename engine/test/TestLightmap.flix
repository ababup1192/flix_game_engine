// lightmap（3D のベイクした光）: 色空間の変換の式・Scene3d.lightmap の既定・lightmapOf と lightmapWarning の分かれ道・
// 読む絵の名前に入るか・Blender の PNG の chunk を掛けずに生の値で読むか。

/// 2 本目の uv つきの三角（材質は呼ぶ側が付ける）。
def lmTriangle(): Mesh3d.Mesh3d =
    let plain = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil,
                                      color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
    match Mesh3d.withUvs2(Vector#{0.0, 0.0, 1.0, 0.0, 0.0, 1.0}, plain) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    }

def lmName(): String = Texture3d.namePrefix() + "0123456789abcdef"

def lmMaterial(): Scene3d.Material3d = Scene3d.texturedMaterial(lmName(), ShaderDoc.FilterMode.Linear)

/// 使える形の lightmap つきの置いた物。
def lmPlaced(lm: Scene3d.Lightmap): Scene3d.Instance3d =
    Scene3d.meshInstance(lmTriangle(), Mat4.identity()) |> Scene3d.withMaterial(lmMaterial()) |> Scene3d.withLightmap(lm)

def near(a: Float64, b: Float64): Bool = Float64.abs(a - b) < 1.0e-4

// ── 色空間の変換の式 ──

@Test
def testSrgbToLinearZeroAndOne(): Unit \ Assert =
    Assert.assertEq(expected = (0.0, 1.0), (Texture3d.srgbToLinear(0.0), Texture3d.srgbToLinear(1.0)))

@Test
def testSrgbToLinearHalf(): Unit \ Assert =
    Assert.assertTrue(near(0.2140, Texture3d.srgbToLinear(0.5)))

@Test
def testSrgbToLinearAtTheEdgeIsTheLinearPart(): Unit \ Assert =
    Assert.assertTrue(near(0.04045 / 12.92, Texture3d.srgbToLinear(0.04045)))

@Test
def testSrgbToLinearJustAboveTheEdgeIsThePowerPart(): Unit \ Assert =
    Assert.assertTrue(near(Float64.pow({ base = (0.05 + 0.055) / 1.055 }, 2.4), Texture3d.srgbToLinear(0.05)))

@Test
def testRoundTripOf256Levels(): Unit \ Assert =
    let back = List.range(0, 256) |> List.filter(k -> {
        let s = Int32.toFloat64(k) / 255.0;
        not near(s, Texture3d.linearToSrgb(Texture3d.srgbToLinear(s)))
    });
    Assert.assertEq(expected = Nil, back)

@Test
def testLinearToSrgbAboveOneContinues(): Unit \ Assert =
    Assert.assertTrue(near(1.055 * Float64.pow({ base = 2.0 }, 1.0 / 2.4) - 0.055, Texture3d.linearToSrgb(2.0)))

@Test
def testLinearToSrgbNegativeIsZero(): Unit \ Assert =
    Assert.assertEq(expected = 0.0, Texture3d.linearToSrgb(-0.5))

// ── Scene3d.lightmap と lightmapOf ──

@Test
def testLightmapDefaults(): Unit \ Assert =
    let lm = Scene3d.lightmap(lmName());
    Assert.assertEq(expected = (Texture3d.ColorSpace.Srgb, 1.0), (lm#colorSpace, lm#intensity))

@Test
def testUsableLightmapIsUsed(): Unit \ Assert =
    Assert.assertEq(expected = Some(lmName()), Scene3d.lightmapOf(lmPlaced(Scene3d.lightmap(lmName()))) |> Option.map(lm -> lm#texture))

@Test
def testNegativeIntensityBecomesZero(): Unit \ Assert =
    Assert.assertEq(expected = Some(0.0),
        Scene3d.lightmapOf(lmPlaced({ intensity = -2.0 | Scene3d.lightmap(lmName()) })) |> Option.map(lm -> lm#intensity))

@Test
def testNaNIntensityBecomesZero(): Unit \ Assert =
    Assert.assertEq(expected = Some(0.0),
        Scene3d.lightmapOf(lmPlaced({ intensity = Float64.nan() | Scene3d.lightmap(lmName()) })) |> Option.map(lm -> lm#intensity))

@Test
def testInfiniteIntensityBecomesZero(): Unit \ Assert =
    Assert.assertEq(expected = Some(0.0),
        Scene3d.lightmapOf(lmPlaced({ intensity = Float64.positiveInfinity() | Scene3d.lightmap(lmName()) })) |> Option.map(lm -> lm#intensity))

@Test
def testWithoutMaterialIsNotUsed(): Unit \ Assert =
    let i = Scene3d.meshInstance(lmTriangle(), Mat4.identity()) |> Scene3d.withLightmap(Scene3d.lightmap(lmName()));
    Assert.assertTrue(Option.isEmpty(Scene3d.lightmapOf(i)))

@Test
def testWithoutUvs2IsNotUsed(): Unit \ Assert =
    let flat = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil,
                                     color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
    let i = Scene3d.meshInstance(flat, Mat4.identity()) |> Scene3d.withMaterial(lmMaterial()) |> Scene3d.withLightmap(Scene3d.lightmap(lmName()));
    Assert.assertTrue(Option.isEmpty(Scene3d.lightmapOf(i)))

@Test
def testNameOutsideSceneTexturesIsNotUsed(): Unit \ Assert =
    Assert.assertTrue(Option.isEmpty(Scene3d.lightmapOf(lmPlaced(Scene3d.lightmap("lightmap.png")))))

@Test
def testSkinnedIsNotUsed(): Unit \ Assert =
    let skin = twoJointSkin();
    let mesh = match Mesh3d.withUvs2(Vector#{0.0, 0.0, 1.0, 0.0, 0.0, 1.0}, triangleOnJoint(1)) {
        case Ok(m)  => m
        case Err(e) => bug!(e)
    };
    let i = Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(lmMaterial())
        |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin))) |> Scene3d.withLightmap(Scene3d.lightmap(lmName()));
    Assert.assertTrue(Option.isEmpty(Scene3d.lightmapOf(i)))

@Test
def testUsableLightmapHasNoWarning(): Unit \ Assert =
    Assert.assertEq(expected = None, Scene3d.lightmapWarning(lmPlaced(Scene3d.lightmap(lmName()))))

@Test
def testOverlappingProblemsGiveTheMaterialLineOnly(): Unit \ Assert =
    let flat = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil,
                                     color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
    let i = Scene3d.meshInstance(flat, Mat4.identity()) |> Scene3d.withLightmap(Scene3d.lightmap("lightmap.png"));
    Assert.assertEq(expected = Some(true),
        Scene3d.lightmapWarning(i) |> Option.map(line -> String.contains(substr = "材質が無い", line)))

@Test
def testUsableLightmapIsAmongTextureNames(): Unit \ Assert =
    Assert.assertTrue(List.memberOf(lmName() + "", Scene3d.textureNamesOf(lmPlaced(Scene3d.lightmap(lmName() + "")))))

@Test
def testUnusedLightmapIsNotAmongTextureNames(): Unit \ Assert =
    let i = Scene3d.meshInstance(lmTriangle(), Mat4.identity()) |> Scene3d.withLightmap(Scene3d.lightmap("tex3d:ffffffffffffffff"));
    Assert.assertEq(expected = Nil, Scene3d.textureNamesOf(i))

/// 骨つき・2 本目の uv の無い形・材質つき（理由が骨つきと uv2 無しで重なる）。
def skinnedWithoutUvs2(name: String): Scene3d.Instance3d =
    let skin = twoJointSkin();
    Scene3d.meshInstance(triangleOnJoint(1), Mat4.identity()) |> Scene3d.withMaterial(lmMaterial())
        |> Scene3d.withPose(Pose3d.compute(skin, Skin3d.restPose(skin))) |> Scene3d.withLightmap(Scene3d.lightmap(name))

@Test
def testSkinnedComesBeforeMissingUvs2(): Unit \ Assert =
    Assert.assertEq(expected = Some(true),
        Scene3d.lightmapWarning(skinnedWithoutUvs2(lmName())) |> Option.map(line -> String.contains(substr = "骨つき", line)))

@Test
def testMissingUvs2ComesBeforeTheName(): Unit \ Assert =
    let flat = Mesh3d.fromPolygons({ points = Vec3.v3(0.0, 0.0, 0.0) :: Vec3.v3(1.0, 0.0, 0.0) :: Vec3.v3(0.0, 1.0, 0.0) :: Nil,
                                     color = Color.rgb(1.0, 1.0, 1.0) } :: Nil);
    let i = Scene3d.meshInstance(flat, Mat4.identity()) |> Scene3d.withMaterial(lmMaterial()) |> Scene3d.withLightmap(Scene3d.lightmap("lightmap.png"));
    Assert.assertEq(expected = Some(true),
        Scene3d.lightmapWarning(i) |> Option.map(line -> String.contains(substr = "2 本目の uv が無い", line)))

// ── 絵の大きさの上限（Texture3d.limitSize）──

def lmFourByTwo(): Texture3d.Texture3d =
    match Texture3d.fromArgb(4, 2, Vector#{-1, -1, -16777216, -16777216, -1, -1, -16777216, -16777216}) {
        case Ok(t)  => t
        case Err(e) => bug!(e)
    }

@Test
def testLimitSizeHalvesLikeTheMipChain(): Unit \ Assert =
    let t = lmFourByTwo();
    let mip = Mip.build({ width = 4, height = 2, pixels = Texture3d.argb(t) }) |> List.drop(1) |> List.head;
    let small = Texture3d.limitSize(2, t);
    Assert.assertEq(expected = Option.map(m -> (m#width, m#height, m#pixels), mip),
                    Some((Texture3d.width(small), Texture3d.height(small), Texture3d.argb(small))))

@Test
def testLimitSizeKeepsAFittingTexture(): Unit \ Assert =
    Assert.assertEq(expected = Texture3d.contentHash(lmFourByTwo()), Texture3d.contentHash(Texture3d.limitSize(4, lmFourByTwo())))

// ── Blender の PNG（sRGB・gAMA・cHRM の chunk つき）──

/// 資材の画素 (x, y) の ARGB（lightmap_srgb_chunks.py と同じ式）。
def expectedArgb(x: Int32, y: Int32): Int32 =
    let r = Int32.remainder(x * 60 + y * 10, 256);
    Int32.bitwiseOr(Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.leftShift(r, 16)), Int32.bitwiseOr(Int32.leftShift(64, 8), 200))

@Test
def testBlenderPngChunksAreNotApplied(): Unit \ {Assert, Fs.FileRead, IO} =
    let decoded = Fs.FileRead.readBytes("test/data/testdata/lightmap_srgb_chunks.png")
        |> Result.mapErr(e -> "${e}") |> Result.flatMap(bytes -> Texture3d.decode(bytes));
    let expected = Vector.range(0, 16) |> Vector.map(k -> expectedArgb(Int32.remainder(k, 4), k / 4));
    Assert.assertEq(expected = Ok(expected), decoded |> Result.map(Texture3d.argb))

// ── 読む mip のレベルの数の上限（UV の島の間から）──

@Test
def testGapOf16GivesFourLevels(): Unit \ Assert =
    Assert.assertEq(expected = 4, Scene3d.lightmapLevelsForGap(16))

@Test
def testGapOf7GivesTwoLevels(): Unit \ Assert =
    Assert.assertEq(expected = 2, Scene3d.lightmapLevelsForGap(7))

@Test
def testGapBelow4GivesOneLevel(): Unit \ Assert =
    Assert.assertEq(expected = 1, Scene3d.lightmapLevelsForGap(3))

@Test
def testDefaultMaxLevelsIsTheDefaultLimit(): Unit \ Assert =
    Assert.assertEq(expected = Scene3d.lightmapMaxLevels(), Scene3d.lightmap(lmName())#maxLevels)

@Test
def testZeroMaxLevelsBecomesOne(): Unit \ Assert =
    Assert.assertEq(expected = Some(1),
        Scene3d.lightmapOf(lmPlaced({ maxLevels = 0 | Scene3d.lightmap(lmName()) })) |> Option.map(lm -> lm#maxLevels))
