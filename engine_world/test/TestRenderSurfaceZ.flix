// Render.surfaceZShared — ShaderDoc の面の後ろに同じ z の描き物を並べた所を見つける（面は同じ z の中で必ず手前に描かれ、
// 後ろに並べたドット絵を覆うので、z を分けるよう知らせる）。
mod TestRenderSurfaceZ {

    def surface(z: Int32): Render.PlacedItem =
        { at = Vec2.zero(), item = Render.Item.Shader({
            rect = { position = Vec2.zero(), size = { x = 8.0, y = 8.0 } },
            spec = { name = "fill", cycleRate = 0.0, bindings = Nil,
                     out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 1.0 }), alpha = ShaderDoc.Field.Const(1.0) }) },
            t = 0.0, mask = Nil, zIndex = z, blend = DrawCmd.BlendMode.Normal, alpha = 1.0 }) }

    def box(z: Int32): Render.PlacedItem = RawDraw.boxAt(Vec2.zero(), { x = 4.0, y = 4.0 }, { r = 1.0, g = 0.0, b = 0.0 }, z)

    /// 面の後ろに同じ z の箱 → その z が出る。
    @Test
    def testBoxAfterASurfaceOnTheSameZ(): Unit \ Assert =
        Assert.assertEq(expected = List#{5}, Render.surfaceZShared(List#{surface(5), box(5)}))

    /// 箱が先（面の下に置く意図どおり）・z が違う・面が無い時は出ない。
    @Test
    def testNoClashWhenOrderOrZAgree(): Unit \ Assert =
        Assert.assertEq(expected = (Nil, Nil, Nil),
            (Render.surfaceZShared(List#{box(5), surface(5)}),
             Render.surfaceZShared(List#{surface(5), box(6)}),
             Render.surfaceZShared(List#{box(5), box(5)})))
}
