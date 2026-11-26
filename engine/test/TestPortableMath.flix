// PortableMath・Rot2・StateHash（機種に依らない数の道具）

/// -360〜360 度の 1 度ごとで、PortableMath.sin は Math.sin と 1e-12 未満しか違わない
@Test
def testPortableSinMatchesMath(): Unit \ Assert =
    let worst = List.range(-360, 361) |> List.foldLeft((acc, d) -> {
        let x = Int32.toFloat64(d) * PortableMath.pi() / 180.0;
        Float64.max(acc, Float64.abs(PortableMath.sin(x) - Num.sin(x)))
    }, 0.0);
    Assert.assertTrue(worst < 1.0e-12)

/// -360〜360 度の 1 度ごとで、PortableMath.cos は Math.cos と 1e-12 未満しか違わない
@Test
def testPortableCosMatchesMath(): Unit \ Assert =
    let worst = List.range(-360, 361) |> List.foldLeft((acc, d) -> {
        let x = Int32.toFloat64(d) * PortableMath.pi() / 180.0;
        Float64.max(acc, Float64.abs(PortableMath.cos(x) - Num.cos(x)))
    }, 0.0);
    Assert.assertTrue(worst < 1.0e-12)

/// 円の周りの 72 方向で、PortableMath.atan2 は Math.atan2 と 1e-12 未満しか違わない
@Test
def testPortableAtan2MatchesMath(): Unit \ Assert =
    let worst = List.range(0, 72) |> List.foldLeft((acc, i) -> {
        let a = Int32.toFloat64(i) * 5.0 * PortableMath.pi() / 180.0 + 0.01;
        let y = 3.0 * Num.sin(a);
        let x = 3.0 * Num.cos(a);
        Float64.max(acc, Float64.abs(PortableMath.atan2(y, x) - Num.atan2(y, x)))
    }, 0.0);
    Assert.assertTrue(worst < 1.0e-12)

/// atan2(0, 0) は 0
@Test
def testPortableAtan2OfOrigin(): Unit \ Assert =
    Assert.assertEq(expected = 0.0, PortableMath.atan2(0.0, 0.0))

/// Rot2.fromDegrees(90) の cos と sin は (0, 1) に近い
@Test
def testRot2FromDegrees90(): Unit \ Assert =
    let r = Rot2.fromDegrees(90.0);
    Assert.assertTrue(Float64.abs(Rot2.cos(r)) < 1.0e-15 and Float64.abs(Rot2.sin(r) - 1.0) < 1.0e-15)

/// Rot2.fromCosSin は組を長さ 1 に戻す
@Test
def testRot2FromCosSinNormalizes(): Unit \ Assert =
    let r = Rot2.fromCosSin(3.0, 4.0);
    Assert.assertEq(expected = (0.6, 0.8), (Rot2.cos(r), Rot2.sin(r)))

/// 長さ 0 の組は identity
@Test
def testRot2FromCosSinZeroIsIdentity(): Unit \ Assert =
    Assert.assertEq(expected = Rot2.identity(), Rot2.fromCosSin(0.0, 0.0))

/// NaN の組は identity
@Test
def testRot2FromCosSinNanIsIdentity(): Unit \ Assert =
    Assert.assertEq(expected = Rot2.identity(), Rot2.fromCosSin(Float64.nan(), 1.0))

/// 30 度と 60 度を重ねると 90 度
@Test
def testRot2MulAddsAngles(): Unit \ Assert =
    let r = Rot2.mul(Rot2.fromDegrees(30.0), Rot2.fromDegrees(60.0));
    Assert.assertTrue(Float64.abs(Rot2.toDegrees(r) - 90.0) < 1.0e-12)

/// 90 度で (1, 0) を回すと (0, 1)
@Test
def testRot2RotatesVector(): Unit \ Assert =
    let v = Rot2.rotate({ x = 1.0, y = 0.0 }, Rot2.fromDegrees(90.0));
    Assert.assertTrue(Float64.abs(v#x) < 1.0e-15 and Float64.abs(v#y - 1.0) < 1.0e-15)

/// 逆の向きを重ねると identity に戻る
@Test
def testRot2InverseCancels(): Unit \ Assert =
    let r = Rot2.fromDegrees(37.0);
    let back = Rot2.mul(r, Rot2.inverse(r));
    Assert.assertTrue(Float64.abs(Rot2.sin(back)) < 1.0e-15)

/// 同じ語の並びは同じ指紋
@Test
def testStateHashSameInputSameHash(): Unit \ Assert =
    let h = () -> StateHash.start() |> StateHash.mixFloat64(1.5) |> StateHash.mixInt32(7) |> StateHash.toInt64;
    Assert.assertEq(expected = h(), h())

/// 並びを入れ替えると指紋が変わる
@Test
def testStateHashOrderMatters(): Unit \ Assert =
    let a = StateHash.start() |> StateHash.mixInt32(1) |> StateHash.mixInt32(2) |> StateHash.toInt64;
    let b = StateHash.start() |> StateHash.mixInt32(2) |> StateHash.mixInt32(1) |> StateHash.toInt64;
    Assert.assertTrue(a != b)

/// 最下位ビットだけ違う数は指紋も違う
@Test
def testStateHashSeesLastBit(): Unit \ Assert =
    let a = StateHash.start() |> StateHash.mixFloat64(1.0) |> StateHash.toInt64;
    let b = StateHash.start() |> StateHash.mixFloat64(1.0000000000000002) |> StateHash.toInt64;
    Assert.assertTrue(a != b)
