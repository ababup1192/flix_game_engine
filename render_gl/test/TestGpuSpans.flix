// TestGpuSpans — 3D の描き手が GPU の時間を測る区間の名前と、draw を積まない試しの旗の読み方。
mod Render3d.TestGpuSpans {

    // 光の種類ごとに区間の名前が分かれる（太陽・スポット・点光源）。
    @Test
    def testShadowSpanNamesByLight(): Unit \ Assert =
        let sun = Render3d.ShadowMaps.ShadowSampling.Sun({ matrix = Mat4.identity(), bias = 0.0, normalShift = 0.0, pcfRadius = 0, strength = 1.0,
                                                           forward = Vec3.zero(), distance = 1.0, fadeWidth = 0.0 });
        let spot = Render3d.ShadowMaps.ShadowSampling.Spot({ matrix = Mat4.identity(), bias = 0.0, pcfRadius = 0, strength = 1.0, spotIndex = 0 });
        Assert.assertEq(expected = ("shadow:sun", "shadow:spot"), (Render3d.GpuSpans.shadowSpanOf(sun), Render3d.GpuSpans.shadowSpanOf(spot)))

    // 場面の pass は色と奥行きの書き出しで名前が分かれる。
    @Test
    def testPassSpanNamesByOutput(): Unit \ Assert =
        Assert.assertEq(expected = ("scene3d", "scene3d:depth"),
                        (Render3d.GpuSpans.passSpanOf(Render3d.ScenePlan.ScenePassSpec.Color),
                         Render3d.GpuSpans.passSpanOf(Render3d.ScenePlan.ScenePassSpec.DepthOut({ near = 0.1, range = 100.0 }))))

    // shadow は影だけ・color は場面だけ・all は両方を飛ばす。無い時はどちらも飛ばさない。
    @Test
    def testSkipFlagsByText(): Unit \ Assert =
        let both = (t: Option[String]) -> (Render3d.GpuSpans.isShadowSkippedBy(t), Render3d.GpuSpans.isColorSkippedBy(t));
        Assert.assertEq(expected = ((true, false), (false, true), (true, true), (false, false)),
                        (both(Some("shadow")), both(Some("color")), both(Some("all")), both(None)))
}
