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

    /// 向きは design の形から: 縦長だけ Portrait・正方形は Landscape
    @Test
    def testOrientationFollowsDesignShape(): Unit \ Assert =
        Assert.assertEq(expected = (Display.Orientation.Landscape, Display.Orientation.Portrait, Display.Orientation.Landscape),
                        (Display.desktop({ x = 960.0, y = 540.0 })#orientation, Display.desktop({ x = 540.0, y = 1169.0 })#orientation,
                         Display.orientationOf({ x = 600.0, y = 600.0 })))

    /// 縦のスマホの既定は Small・Touch・Portrait で、design の 1px は画面の幅 ÷ design の幅
    @Test
    def testPhonePortraitIsSmallTouchPortrait(): Unit \ Assert =
        let d = Display.phonePortrait(Display.defaultPortraitView(), { x = 540.0, y = 1169.0 });
        Assert.assertEq(expected = (Display.SizeClass.Small, Display.PointerKind.Touch, Display.Orientation.Portrait, 390.0 / 540.0),
                        (d#sizeClass, d#pointer, d#orientation, d#designScale))
}
