/// Display.sizeClassOf の境界と、デスクトップの既定（Large・Mouse）を検証する。
mod TestDisplay {

    /// 主な pointer が指でなければ、短い辺が小さくても Large（PC の窓を狭めただけで Small にしない）
    @Test
    def testMouseIsLargeEvenInNarrowWindow(): Unit \ Assert =
        Assert.assertEq(expected = Display.SizeClass.Large, Display.sizeClassOf(false, 360.0))

    /// 指で短い辺が 599.9 なら Small
    @Test
    def testTouchBelowBoundaryIsSmall(): Unit \ Assert =
        Assert.assertEq(expected = Display.SizeClass.Small, Display.sizeClassOf(true, 599.9))

    /// 指で短い辺がちょうど 600 なら Medium
    @Test
    def testTouchAtBoundaryIsMedium(): Unit \ Assert =
        Assert.assertEq(expected = Display.SizeClass.Medium, Display.sizeClassOf(true, 600.0))

    /// デスクトップの既定の区分は Large
    @Test
    def testDesktopIsLarge(): Unit \ Assert =
        Assert.assertEq(expected = Display.SizeClass.Large, Display.desktop({ x = 960.0, y = 540.0 })#sizeClass)

    /// デスクトップの既定の pointer は Mouse
    @Test
    def testDesktopPointerIsMouse(): Unit \ Assert =
        Assert.assertEq(expected = Display.PointerKind.Mouse, Display.desktop({ x = 960.0, y = 540.0 })#pointer)
}
