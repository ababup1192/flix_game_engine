// RenderCache.painterKeyOf: SoftRaster でない描き手（画面なしの WebGPU）で塗った絵の置き場の名前は、鍵と描き手の素性から決まり、
// bin/fge migrate（go/internal/migrate の painterKey）と同じ式。
mod TestRenderCachePainter {

    /// Go の TestPainterKeyIsTheSameFormulaAsTheEngine と同じ値になる。
    @Test
    def painterKeyOfMatchesGo(): Unit \ Assert + IO =
        Assert.assertEq(expected = "70f9eafc038469c97ce72e1586c67dbade76b7f3ac2e192cc4a7910e2685dc2a",
                        RenderCache.painterKeyOf("abc", "webgpu X"))

    /// 描き手が違えば同じ鍵でも名前が違う（CPU の絵と GPU の絵が入れ替わらない）。
    @Test
    def otherPainterIsOtherName(): Unit \ Assert + IO =
        Assert.assertFalse(RenderCache.painterKeyOf("abc", "webgpu X") == RenderCache.painterKeyOf("abc", "webgpu Y"))
}
