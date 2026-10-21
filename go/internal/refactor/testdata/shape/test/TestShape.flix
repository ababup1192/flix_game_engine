mod TestShape {
    def world(): Shape.World = {
        speed = 5,
        // 使われない欄
        old = false,
        clock = 0.0,
        pointer = { x = 0.0, y = 0.0 }
    }

    @Test
    def speedOfReadsTheSpeed(): Unit \ Assert = Assert.assertEq(expected = 5, Shape.speedOf(world()))

    @Test
    def cursorOfAnOpenPanel(): Unit \ Assert = Assert.assertEq(expected = 0, Shape.cursorOf(Shape.open(1)))
}
