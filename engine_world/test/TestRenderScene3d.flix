// Render.Item.Scene3d — 3D の場面を 2D の並びに 1 つの描き物として入れる決まり: z と大きさの読み書き・
// 層へ置く時の z の写し・注釈の当たりの矩形・GL へ渡す命令（Clipped の clip を写す）・2D の列から外す・
// CPU の描き出しへ渡す形・面と場面が同じ z に並んだ時の知らせ。
mod TestRenderScene3d {

    /// テスト用の層の表（底の順 = 奥 → 手前）。
    enum Tier with Eq, ToString {
        case Back
        case Front
    }

    instance SortingLayer[Tier] {
        pub def zRange(tier: Tier): (Int32, Int32) = match tier {
            case Tier.Back  => (0, 99)
            case Tier.Front => (100, 199)
        }
    }

    def quiet(): App.ViewCtx =
        let atlas = { textureName = "", fontSize = 1.0, textureSize = 1.0, ascent = 0.0, descent = 0.0,
                      lineGap = 0.0, glyphs = Map.empty() };
        { atlas = atlas, fontOf = _ -> atlas,
          visible = { position = { x = 0.0, y = 0.0 }, size = { x = 1.0, y = 1.0 } },
          warnOnce = _ -> (), diagnostics = None, display = Display.desktop({ x = 1.0, y = 1.0 }) }

    def camera(): Camera3d.Camera3d =
        { eye = Vec3.zero(), yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 1.0, far = 100.0 }

    /// 大きさ 100×50・z の空の場面。
    def sceneCmd(z: Int32): Scene3d.Scene3dCmd =
        { zIndex = z | Scene3d.scene(camera(), { x = 100.0, y = 50.0 }) }

    def sceneAt(x: Float64, y: Float64, z: Int32): Render.PlacedItem =
        Render.scene3d({ x = x, y = y }, sceneCmd(z))

    def surface(z: Int32): Render.PlacedItem =
        Render.shaderFill({ name = "fill", cycleRate = 0.0, bindings = Nil,
                            out = ShaderDoc.Out.Fill({ shade = ShaderDoc.Shade.Solid({ r = 0.0, g = 0.0, b = 1.0 }),
                                                       alpha = ShaderDoc.Field.Const(1.0) }) },
                          { position = Vec2.zero(), size = { x = 8.0, y = 8.0 } }, 0.0, z)

    def box(z: Int32): Render.PlacedItem = RawDraw.boxAt(Vec2.zero(), { x = 4.0, y = 4.0 }, { r = 1.0, g = 0.0, b = 0.0 }, z)

    def sizeOf(item: Render.Item): (Float64, Float64) = match item {
        case Render.Item.Scene3d(sc) => xy(sc#size)
        case _                       => bug!("Scene3d ではない")
    }

    def xy(v: Vec2.Vec2): (Float64, Float64) = (v#x, v#y)

    def rectOf(r: Rect2.Rect2): (Float64, Float64, Float64, Float64) = (r#position#x, r#position#y, r#size#x, r#size#y)

    def kindOf(placed: Render.PlacedItem): String = match placed#item {
        case Render.Item.Scene3d(_) => "scene3d"
        case Render.Item.Clipped(_) => "clipped"
        case Render.Item.Shader(_)  => "shader"
        case Render.Item.Box(_)     => "box"
        case _                      => "other"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // z と大きさ
    // ─────────────────────────────────────────────────────────────────────────

    /// z は cmd#zIndex。scaled(2) で大きさ 100×50 が 200×100 になる。
    @Test
    def testScene3dZAndScaledSize(): Unit \ Assert =
        let item = Render.Item.Scene3d(sceneCmd(7));
        Assert.assertEq(expected = (7, (200.0, 100.0)),
            (Render.zOf(item), sizeOf(Render.scaled(2.0, item))))

    /// 層の木に置くと、場面の z も層の底へ写る（Front の底 = 100）。
    @Test
    def testStackMovesTheSceneIntoTheLayer(): Unit \ Assert =
        let tree = ZStack.leaf(sceneAt(0.0, 0.0, 3) :: Nil);
        Assert.assertEq(expected = 100 :: Nil,
            SortingLayer.stack(quiet(), Tier.Front, tree) |> List.map(placed -> Render.zOf(placed#item)))

    /// 注釈の当たりは at と大きさの矩形で、種類は "scene3d"。
    @Test
    def testAnnotateHitIsTheSceneRect(): Unit \ Assert =
        let rect = { position = Vec2.zero(), size = { x = 320.0, y = 180.0 } };
        Assert.assertEq(expected = ("scene3d", (10.0, 20.0, 100.0, 50.0)) :: Nil,
            Annotate.hits(_ -> None, rect, sceneAt(10.0, 20.0, 0) :: Nil) |> List.map(hit -> (hit#kind, rectOf(hit#aabb))))

    // ─────────────────────────────────────────────────────────────────────────
    // GL へ渡す命令と 2D の列
    // ─────────────────────────────────────────────────────────────────────────

    /// Clipped に包んだ場面は、入れ子の clip の重なり（10,10〜50,50 と 30,0〜80,40 → 30,10〜50,40）を命令の clip に持つ。
    @Test
    def testDrawScenes3dCopiesTheClip(): Unit \ Assert =
        let outer = { position = { x = 10.0, y = 10.0 }, size = { x = 40.0, y = 40.0 } };
        let inner = { position = { x = 30.0, y = 0.0 }, size = { x = 50.0, y = 40.0 } };
        let placed = { at = { x = 5.0, y = 6.0 }, item = Render.clipped(outer, Render.clipped(inner, Render.Item.Scene3d(sceneCmd(0)))) };
        Assert.assertEq(expected = ((5.0, 6.0), Some((30.0, 10.0, 20.0, 30.0))) :: Nil,
            Render.drawScenes3d(placed :: Nil) |> List.map(cmd -> (xy(cmd#at), Option.map(rectOf, cmd#clip))))

    /// withoutScenes3d は場面（Clipped の中の場面も）だけを外し、箱と面は残す。
    @Test
    def testWithoutScenes3dKeepsEverythingElse(): Unit \ Assert =
        let clippedScene = { at = Vec2.zero(), item = Render.clipped({ position = Vec2.zero(), size = { x = 8.0, y = 8.0 } }, Render.Item.Scene3d(sceneCmd(0))) };
        Assert.assertEq(expected = "box" :: "shader" :: Nil,
            Render.withoutScenes3d(box(0) :: sceneAt(0.0, 0.0, 0) :: clippedScene :: surface(0) :: Nil) |> List.map(kindOf))

    /// CPU の描き出しへ渡す形: 場面は scenes に 1 つ、面は surfaces に 1 つ、drawables は箱 1 つだけ（代わりの矩形を入れない）。
    @Test
    def testSoftSceneOfSplitsScenesAndSurfaces(): Unit \ Assert =
        let soft = Render.softSceneOf(_ -> None, box(0) :: sceneAt(0.0, 0.0, 0) :: surface(0) :: Nil);
        Assert.assertEq(expected = (1, 0, 1, 1),
            (List.length(soft#drawables), List.length(soft#polygons), List.length(soft#surfaces), List.length(soft#scenes)))

    /// 3D を知らない道（draw）では、場面は場面の大きさの矩形 1 枚になる。
    @Test
    def testDrawWithoutGlLeavesOneStandInRect(): Unit \ Assert =
        let (drawables, _) = Render.draw(sceneAt(0.0, 0.0, 4) :: Nil);
        Assert.assertEq(expected = ((100.0, 50.0), 4) :: Nil,
            drawables |> List.map(d -> { let spec = DrawCmd.toSpec(d); (xy(spec#scale), spec#zIndex) }))

    // ─────────────────────────────────────────────────────────────────────────
    // 同じ z の知らせ
    // ─────────────────────────────────────────────────────────────────────────

    /// 面と場面が同じ z（どちらの順でも）・場面の後ろに同じ z の箱 → その z が出る。
    @Test
    def testSurfaceZSharedSeesScenes(): Unit \ Assert =
        Assert.assertEq(expected = (5 :: Nil, 5 :: Nil, 5 :: Nil),
            (Render.surfaceZShared(surface(5) :: sceneAt(0.0, 0.0, 5) :: Nil),
             Render.surfaceZShared(sceneAt(0.0, 0.0, 5) :: surface(5) :: Nil),
             Render.surfaceZShared(sceneAt(0.0, 0.0, 5) :: box(5) :: Nil)))

    /// 場面が 2 つ同じ z・箱が場面の前・z が違う時は出ない。
    @Test
    def testSurfaceZSharedQuietForScenesInOrder(): Unit \ Assert =
        Assert.assertEq(expected = (Nil, Nil, Nil),
            (Render.surfaceZShared(sceneAt(0.0, 0.0, 5) :: sceneAt(0.0, 0.0, 5) :: Nil),
             Render.surfaceZShared(box(5) :: sceneAt(0.0, 0.0, 5) :: Nil),
             Render.surfaceZShared(sceneAt(0.0, 0.0, 5) :: box(6) :: Nil)))
}
