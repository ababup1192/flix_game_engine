// CPU の描き手の材質の AO（SoftRaster3dLight の materialOcclusion）: 環境の光と映り込みに掛かり、直接光（太陽・点光源）と鏡面には掛からない。
mod SoftRaster3d.TestSoftRaster3dMaterialOcclusion {

    def noLights(): Vector[Float64] = Vector.empty()

    /// 原点の上向きの面の光の量（r）。ambient = 環境の光・sun = 真上の太陽の color × intensity・points = 点光源の並び・ao = 材質の AO。
    def lightOf(ambient: Float64, sun: Float64, points: Vector[Float64], ao: Float64): Float64 =
        let (r, _, _) = SoftRaster3dLight.lightAt(0, points, noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                  ambient, ambient, ambient, 0.0, 0.0, 1.0, 0.0, sun, sun, sun, 1.0, 0.0, 1.0,
                                                  Scene3d.Internal.SkyIrradiance.zeros(), 0.0, 1.0, 1.0, ao);
        r

    /// 真上 1 の点光源（白・強さ 1・range 4）。
    def pointAbove(): Vector[Float64] =
        LightModel3d.packPointLights({ position = Vec3.v3(0.0, 1.0, 0.0), color = Color.rgb(1.0, 1.0, 1.0), intensity = 1.0, range = 4.0 } :: Nil)

    /// 環境の光は材質の AO 倍になる。
    @Test
    def testAmbientIsScaledByMaterialAo(): Unit \ Assert =
        Assert.assertEq(expected = 0.25 * 0.5, lightOf(0.25, 0.0, noLights(), 0.5))

    /// 太陽の拡散は材質の AO に関わらない。
    @Test
    def testSunIsNotScaledByMaterialAo(): Unit \ Assert =
        Assert.assertEq(expected = lightOf(0.0, 0.8, noLights(), 1.0), lightOf(0.0, 0.8, noLights(), 0.5))

    /// 点光源の拡散は材質の AO に関わらない。
    @Test
    def testPointLightIsNotScaledByMaterialAo(): Unit \ Assert =
        Assert.assertEq(expected = lightOf(0.0, 0.0, pointAbove(), 1.0), lightOf(0.0, 0.0, pointAbove(), 0.25))

    /// lightmap のベイクした光も材質の AO 倍になる（Linear・強さ 1）。
    @Test
    def testBakedLightIsScaledByMaterialAo(): Unit \ Assert =
        let (r, _, _) = SoftRaster3dLight.lightmapLightAt(0, noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                          0.5, 0.5, 0.5, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.5);
        Assert.assertEq(expected = 0.25, r)

    /// 金属（metallic 1・roughness 0.5・拡散 0）で光の無い面の、白い空の映り込みだけの色（真上から見る）。
    def reflectionOf(ao: Float64): Float64 =
        let (r, _, _) = SoftRaster3dLight.pbrAt(noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.5, 0.0,
                                                0.0, 10.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
                                                0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, ao);
        r

    /// 空の映り込みは光が無くても明るい（下の比べの前提）。
    @Test
    def testReflectionIsLitWithoutLights(): Unit \ Assert =
        Assert.assertTrue(reflectionOf(1.0) > 0.0)

    /// 空の映り込みは材質の AO 倍になる。
    @Test
    def testReflectionIsScaledByMaterialAo(): Unit \ Assert =
        Assert.assertEq(expected = reflectionOf(1.0) * 0.5, reflectionOf(0.5))

    /// 太陽の鏡面ハイライトは材質の AO に関わらない（空と環境は黒・映り込みは 0）。
    @Test
    def testSunSpecularIsNotScaledByMaterialAo(): Unit \ Assert =
        let colorOf = (ao: Float64) -> {
            let (r, _, _) = SoftRaster3dLight.pbrAt(noLights(), noLights(), None, SoftRaster3d.PointShadows.allLit(), 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                                                    1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.3, 0.0,
                                                    0.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0,
                                                    0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 1.0, ao);
            r
        };
        Assert.assertEq(expected = colorOf(1.0), colorOf(0.25))
}
