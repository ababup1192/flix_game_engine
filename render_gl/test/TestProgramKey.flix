// 変種のフラグの表が engine の先に組む宣言（Scene3d.PreloadVariant）とそろうか。
mod TestProgramKey {
    use Render3d.ProgramKey.{ShaderVariant, flagsOf, variantOf, variantKeyOf, billboardVariantOf}

    def allVariants(): List[ShaderVariant] =
        let flags = false :: true :: Nil;
        flags |> List.flatMap(ps -> flags |> List.flatMap(pu -> flags |> List.flatMap(px -> flags |> List.map(sh ->
            { pointShadows = ps, physicalUnits = pu, psx = px, skyIrradiance = sh, ambientOcclusion = false }))))

    @Test
    def testTableKeysMatchEnginePreloadKeys(): Unit \ Assert =
        Assert.assertEq(expected = allVariants() |> List.map(Scene3d.preloadVariantKey), allVariants() |> List.map(variantKeyOf))

    @Test
    def testFlagsRoundTrip(): Unit \ Assert =
        Assert.assertEq(expected = allVariants() |> List.map(Scene3d.preloadVariantKey),
                        allVariants() |> List.map(v -> Scene3d.preloadVariantKey(variantOf(flagsOf(v)))))

    @Test
    def testBillboardDropsOnlyPointShadows(): Unit \ Assert =
        Assert.assertEq(expected = "+pu+psx+sh", variantKeyOf(billboardVariantOf({ pointShadows = true, physicalUnits = true, psx = true, skyIrradiance = true, ambientOcclusion = false })))
}
