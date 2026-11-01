// 1 フレームの描画物を重なり順の 1 列にまとめる mergedByZ の並びを固定する。
// 同 z の入れ替わりは絵の事故（背景と同 z の文字が消える）に直結するので、
// 「z 昇順」「同 z は種類の順」「同 z・同種は入力順」の 3 つを別々に押さえる。

mod TestFrameOrder {

    def spriteAt(z: Int32, tag: Float64): DrawCmd.Drawable =
        DrawCmd.make({
          texture = "", position = { x = tag, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
          rotation = 0.0, color = { r = 0.0, g = 0.0, b = 0.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = z, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    def polyAt(z: Int32, tag: Float64): DrawCmd.PolygonRenderCmd =
        { vertices = { x = tag, y = 0.0 } :: Nil, color = { r = 0.0, g = 0.0, b = 0.0 },
          alpha = 1.0, zIndex = z, clip = None, blend = DrawCmd.BlendMode.Normal, grad = None }

    /// 並んだ列を「種類の頭文字 + 目印」の文字列にして読む。
    def trace(items: List[RenderFrame.Merged]): String =
        items |> List.map(m -> match m {
            case RenderFrame.Merged.MSprite(d)  => "s${Float64.floor(DrawCmd.positionOf(d)#x)}"
            case RenderFrame.Merged.MPoly(p)    =>
                "p${List.head(p#vertices) |> Option.map(v -> Float64.floor(v#x)) |> Option.getWithDefault(0.0)}"
            case RenderFrame.Merged.MScene3d(x) => "c${x#cmd#at#x}"
            case _                              => "?"
        }) |> List.join(",")

    def sceneAt(z: Int32, tag: Float64): Render3d.SceneItem =
        let camera = { eye = { x = 0.0, y = 0.0, z = 0.0 }, yaw = 0.0, pitch = 0.0, fovY = 1.0, near = 0.1, far = 100.0 };
        { cmd = { at = { x = tag, y = 0.0 }, clip = None,
                  scene = { zIndex = z | Scene3d.scene(camera, { x = 10.0, y = 10.0 }) } },
          designTarget = None, shadow = None }

    /// z の小さい物が先に来る（入力の並びは逆でも）。
    @Test
    def testAscendingByZ(): Unit \ Assert =
        let sprites = spriteAt(5, 1.0) :: spriteAt(1, 2.0) :: spriteAt(3, 3.0) :: Nil;
        Assert.assertEq(expected = "s2.0,s3.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// 同じ z ならスプライトが先・多角形が後（種類の決められた順）。
    @Test
    def testSpritesBeforePolygonsAtSameZ(): Unit \ Assert =
        let sprites = spriteAt(2, 1.0) :: Nil;
        let polys = polyAt(2, 9.0) :: Nil;
        Assert.assertEq(expected = "s1.0,p9.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, polys, Nil, Nil, Nil)))

    /// 同じ z・同じ種類なら入力の順のまま（安定）。
    @Test
    def testStableWithinSameZ(): Unit \ Assert =
        let sprites = spriteAt(2, 1.0) :: spriteAt(2, 2.0) :: spriteAt(2, 3.0) :: Nil;
        Assert.assertEq(expected = "s1.0,s2.0,s3.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// z がまばらに散っていても（スロット方式に倒さない広さでも）並びは同じ。
    @Test
    def testSparseKeysKeepOrder(): Unit \ Assert =
        let sprites = spriteAt(900000, 1.0) :: spriteAt(0, 2.0) :: spriteAt(0, 3.0) :: Nil;
        Assert.assertEq(expected = "s2.0,s3.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// 何も無いフレームは空の列（スロットを 1 本も作らない）。
    @Test
    def testEmptyFrame(): Unit \ Assert =
        Assert.assertEq(expected = "", trace(RenderFrame.mergedByZ(Nil, Nil, Nil, Nil, Nil, Nil)))

    /// 事故の再現形: world の高 z（爆発 1000）より HUD の範囲（ZBand.liftHud）の絵が手前。
    @Test
    def testHudRangeWinsOverHighWorldZ(): Unit \ Assert =
        let sprites = spriteAt(ZBand.liftHud(10), 1.0) :: spriteAt(1000, 2.0) :: Nil;
        Assert.assertEq(expected = "s2.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// 範囲をまたぐフレームでも各範囲の中は z 昇順・同 z は入力順のまま（範囲別 2 段階ソートの安定性）。
    @Test
    def testRangesKeepWithinRangeOrderStable(): Unit \ Assert =
        let sprites =
               spriteAt(ZBand.liftHud(5), 1.0) :: spriteAt(3, 2.0) :: spriteAt(3, 3.0)
            :: spriteAt(ZBand.liftHud(0), 4.0) :: spriteAt(1, 5.0) :: Nil;
        Assert.assertEq(expected = "s5.0,s2.0,s3.0,s4.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// 範囲をまたいでも同 z の種類の順（スプライトが先・多角形が後）は変わらない。
    @Test
    def testRangesKeepChannelOrderAtSameZ(): Unit \ Assert =
        let sprites = spriteAt(ZBand.liftHud(7), 1.0) :: spriteAt(0, 2.0) :: Nil;
        let polys = polyAt(ZBand.liftHud(7), 9.0) :: Nil;
        Assert.assertEq(expected = "s2.0,s1.0,p9.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, polys, Nil, Nil, Nil)))

    /// デバッグの範囲（2e9）と負の z が同居しても Int32 の幅あふれで壊れない。
    @Test
    def testDebugRangeWithNegativeZDoesNotOverflow(): Unit \ Assert =
        let sprites = spriteAt(ZBand.debugBase(), 1.0) :: spriteAt(-200000000, 2.0)
            :: spriteAt(ZBand.liftHud(0), 3.0) :: Nil;
        Assert.assertEq(expected = "s2.0,s3.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// 範囲の中でも z がまばら（スロットが個数に見合わない）なら木で受け、並びは同じ規約のまま。
    @Test
    def testSparseWithinRangeKeepsOrder(): Unit \ Assert =
        let sprites = spriteAt(ZBand.liftHud(0), 1.0)
            :: spriteAt(90000000, 2.0) :: spriteAt(0, 3.0) :: spriteAt(0, 4.0) :: Nil;
        Assert.assertEq(expected = "s3.0,s4.0,s2.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, Nil)))

    /// 3D の場面は同じ z の中で 2D の描き物の後（z の 1 点に入り、前後の z とは z の順のまま）。
    @Test
    def testSceneComesAfter2dAtSameZ(): Unit \ Assert =
        let sprites = spriteAt(1, 1.0) :: spriteAt(3, 3.0) :: Nil;
        let polys = polyAt(1, 2.0) :: Nil;
        Assert.assertEq(expected = "s1.0,p2.0,c7.0,s3.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, polys, Nil, Nil, sceneAt(1, 7.0) :: Nil)))

    /// 範囲をまたぐフレームでも、3D の場面は自分の z の位置に入る（HUD の範囲の絵が手前）。
    @Test
    def testSceneKeepsZAcrossRanges(): Unit \ Assert =
        let sprites = spriteAt(ZBand.liftHud(0), 1.0) :: spriteAt(0, 2.0) :: Nil;
        Assert.assertEq(expected = "s2.0,c7.0,s1.0",
                  trace(RenderFrame.mergedByZ(Nil, sprites, Nil, Nil, Nil, sceneAt(5, 7.0) :: Nil)))

}
