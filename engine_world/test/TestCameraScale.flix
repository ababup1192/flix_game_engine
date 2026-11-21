// Render.applyCameraScale のテスト。camera の zoom は scale だけでなく mask（型抜きの
// 多角形）の頂点にも掛かる — リポジトリの中に呼び手が無い pub API のため、
// 取り違えはここでしか捕まらない（描き出しのバイト一致はこの経路を通らない）。
mod TestCameraScale {

    // zoom (2, 3) を通すと scale は軸ごとに 2 倍・3 倍、mask の頂点も同じ倍率で伸びる。
    @Test
    def testApplyCameraScaleScalesScaleAndMask(): Unit \ Assert =
        let d = DrawCmd.make({
            texture = "tex",
            position = { x = 0.0, y = 0.0 },
            scale = { x = 4.0, y = 5.0 },
            rotation = 0.0,
            color = { r = 1.0, g = 1.0, b = 1.0 },
            alpha = 1.0,
            centered = true,
            uvOffset = { x = 0.0, y = 0.0 },
            uvScale = { x = 1.0, y = 1.0 },
            zIndex = 0,
            style = None,
            clip = None,
            blend = DrawCmd.BlendMode.Normal,
            mask = (({ x = 1.0, y = 2.0 }: Vec2.Vec2) :: Nil) :: Nil, squashY = 1.0 });
        let transform: Projection.ViewTransform =
            { offset = { x = 0.0, y = 0.0 }, scale = { x = 2.0, y = 3.0 } };
        let got = Render.applyCameraScale(transform, d :: Nil)
            |> List.head
            |> Option.map(out -> {
                let spec = DrawCmd.toSpec(out);
                (spec#scale#x, spec#scale#y,
                 spec#mask |> List.map(poly -> poly |> List.map(v -> (v#x, v#y))))
            });
        Assert.assertEq(expected = Some((8.0, 15.0, ((2.0, 6.0) :: Nil) :: Nil)), got)
}
