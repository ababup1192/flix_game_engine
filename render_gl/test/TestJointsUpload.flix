// 骨の行列を UBO へ書き直すかの判断（非 pub の Render3d.needsUpload）。
mod Render3d.TestJoints {
    import java.lang.{Float => JFloat}

    /// 負のゼロ（符号のビットだけが立った Float32）。
    def negativeZero(): Float32 = JFloat.intBitsToFloat(Int32.minValue())

    def upload(before: List[Float32], after: List[Float32]): Bool =
        region rc {
            Render3d.needsUpload(List.toArray(rc, before), List.toArray(rc, after))
        }

    @Test
    def testSameContentIsNotWritten(): Unit \ Assert =
        Assert.assertFalse(upload(1.0f32 :: 2.0f32 :: Nil, 1.0f32 :: 2.0f32 :: Nil))

    @Test
    def testOneDifferentValueIsWritten(): Unit \ Assert =
        Assert.assertTrue(upload(1.0f32 :: 2.0f32 :: Nil, 1.0f32 :: 2.5f32 :: Nil))

    @Test
    def testDifferentLengthIsWritten(): Unit \ Assert =
        Assert.assertTrue(upload(1.0f32 :: Nil, 1.0f32 :: 0.0f32 :: Nil))

    @Test
    def testNegativeZeroIsWritten(): Unit \ Assert =
        Assert.assertTrue(upload(0.0f32 :: Nil, negativeZero() :: Nil))

    @Test
    def testFirstUploadIsWritten(): Unit \ Assert =
        Assert.assertTrue(upload(Nil, 1.0f32 :: Nil))

    @Test
    def testOnlyLastValueDifferentIsWritten(): Unit \ Assert =
        Assert.assertTrue(upload(1.0f32 :: 2.0f32 :: 3.0f32 :: Nil, 1.0f32 :: 2.0f32 :: 3.5f32 :: Nil))
}
