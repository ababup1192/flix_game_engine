// 2D の draw call の数と、前の draw call に続けられなかった理由の数え方（FrameDiagnostics.Draw2dBatchBreaks の決まり）を固定する。
// 何も描かない GL で塗りのコアを作り、RenderFrame.renderFrameMixed へ描き物を渡して、溜まった数を読む。

mod TestDrawCounts {
    import fge.gl.GlContext

    // ── 組み立て ──

    /// 絵 texture（"" は絵の無い箱）のスプライト。z の順に描く。
    def sprite(texture: String, z: Int32): DrawCmd.Drawable =
        spriteWith({ texture = texture, z = z, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    def spriteWith(spec: { texture = String, z = Int32, blend = DrawCmd.BlendMode, mask = List[List[Vec2.Vec2]] }): DrawCmd.Drawable =
        DrawCmd.make({
          texture = spec#texture, position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
          rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = spec#z, style = None, clip = None, blend = spec#blend, mask = spec#mask })

    def added(texture: String, z: Int32): DrawCmd.Drawable =
        spriteWith({ texture = texture, z = z, blend = DrawCmd.BlendMode.Add, mask = Nil })

    def tenSquare(): Rect2.Rect2 = { position = { x = 0.0, y = 0.0 }, size = { x = 10.0, y = 10.0 } }

    def triangle(): List[Vec2.Vec2] = { x = 0.0, y = 0.0 } :: { x = 10.0, y = 0.0 } :: { x = 0.0, y = 10.0 } :: Nil

    def polygon(z: Int32): DrawCmd.PolygonRenderCmd =
        { vertices = triangle(), color = { r = 1.0, g = 1.0, b = 1.0 },
          alpha = 1.0, zIndex = z, clip = None, blend = DrawCmd.BlendMode.Normal, grad = None, triangles = None }

    def surface(z: Int32): DrawCmd.SurfaceRenderCmd =
        { program = GpuHandle.wrapShaderProgram(1), texReads = Nil, rect = tenSquare(), mask = Nil,
          time = 0.0, zIndex = z, blend = DrawCmd.BlendMode.Normal, alpha = 1.0, params = Nil }

    /// 絵 "a" と "b"（GL の番号は 5 と 6）を登録した表。
    def registry(): RenderAsset.TextureRegistry =
        Map#{"a" => { id = GpuHandle.wrapTextureId(5), width = 8.0, height = 8.0 },
             "b" => { id = GpuHandle.wrapTextureId(6), width = 8.0, height = 8.0 }}

    /// 何も描かない GL と、その GL で作った塗りのコアの引数（数の入れ物は 0 から）。
    def fresh(): (GlContext, RenderFrame.FrameArgs) \ IO =
        let gl = FakeGl.silent();
        let paint = RenderPaint.create(gl, { designWidth = 320, designHeight = 240, clearColor = { r = 0.0, g = 0.0, b = 0.0 },
                                             screenFramebuffer = 0, scene3d = Scene3dRenderer.none(), gpuTimer = RenderPaint.noFrameTimer() });
        (gl, { registry = registry(), fbW = 320, fbH = 240 | paint#frameArgsBase })

    /// 画面へ 1 コマ塗って、溜まった数を (drawCalls, target, kind, texture, blend, clip, mask) で返す。
    def countsOf(change: RenderFrame.FrameArgs -> RenderFrame.FrameArgs): (Int32, Int32, Int32, Int32, Int32, Int32, Int32) \ IO =
        let (gl, args) = fresh();
        RenderFrame.renderFrameMixed(gl, change(args));
        tupleOf(RenderDrawCounts.take(args#drawCounts))

    def tupleOf(c: FrameDiagnostics.Draw2dCounts): (Int32, Int32, Int32, Int32, Int32, Int32, Int32) =
        let b = c#batchBreaks;
        (c#drawCalls, b#target, b#kind, b#texture, b#blend, b#clip, b#mask)

    // ── スプライトの run ──

    /// 同じ絵のスプライト 4 個は 1 つの draw call にまとまり、切れ目は無い。
    @Test
    def testSameTextureIsOneDrawCall(): Unit \ {Assert, IO} =
        let sprites = sprite("a", 0) :: sprite("a", 1) :: sprite("a", 2) :: sprite("a", 3) :: Nil;
        Assert.assertEq(expected = (1, 0, 0, 0, 0, 0, 0), countsOf(args -> { sprites = sprites | args }))

    /// 絵が交互のスプライト 4 個は draw call 4 つで、texture の切れ目が 3（N − 1）。
    @Test
    def testAlternatingTexturesBreakByTexture(): Unit \ {Assert, IO} =
        let sprites = sprite("a", 0) :: sprite("b", 1) :: sprite("a", 2) :: sprite("b", 3) :: Nil;
        Assert.assertEq(expected = (4, 0, 0, 3, 0, 0, 0), countsOf(args -> { sprites = sprites | args }))

    /// 同じ絵で blend が Normal → Add → Normal と替わると、blend の切れ目が 2。
    @Test
    def testAlternatingBlendBreaksByBlend(): Unit \ {Assert, IO} =
        let sprites = sprite("a", 0) :: added("a", 1) :: sprite("a", 2) :: Nil;
        Assert.assertEq(expected = (3, 0, 0, 0, 2, 0, 0), countsOf(args -> { sprites = sprites | args }))

    /// 同じ絵・同じ blend で切り抜きの矩形だけ違うと、clip の切れ目が 1。
    @Test
    def testDifferentClipBreaksByClip(): Unit \ {Assert, IO} =
        let clipped = DrawCmd.withClip(Some(tenSquare()), sprite("a", 1));
        Assert.assertEq(expected = (2, 0, 0, 0, 0, 1, 0), countsOf(args -> { sprites = sprite("a", 0) :: clipped :: Nil | args }))

    /// 絵も blend も違う切れ目は、先に当てはまる texture だけに数える。
    @Test
    def testTextureWinsOverBlend(): Unit \ {Assert, IO} =
        let sprites = sprite("a", 0) :: added("b", 1) :: Nil;
        Assert.assertEq(expected = (2, 0, 0, 1, 0, 0, 0), countsOf(args -> { sprites = sprites | args }))

    // ── 種類が替わる ──

    /// スプライトと多角形が z の順で交互（s・p・s・p）なら draw call 4 つで、kind の切れ目が 3。
    @Test
    def testAlternatingSpriteAndPolygonBreakByKind(): Unit \ {Assert, IO} =
        let change = (args: RenderFrame.FrameArgs) -> { sprites = sprite("a", 0) :: sprite("a", 2) :: Nil, polygons = polygon(1) :: polygon(3) :: Nil | args };
        Assert.assertEq(expected = (4, 0, 3, 0, 0, 0, 0), countsOf(change))

    /// Shader の面は 1 枚で 1 draw call。2 枚続くと kind の切れ目が 1。
    @Test
    def testSurfacesBreakByKind(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (2, 0, 1, 0, 0, 0, 0), countsOf(args -> { surfaces = surface(0) :: surface(1) :: Nil | args }))

    /// 3D の場面は 2D の draw call に数えないが、同じ絵のスプライトの間に入ると次の draw call が kind で切れる。
    @Test
    def testScene3dBetweenSpritesBreaksByKind(): Unit \ {Assert, IO} =
        let scenes = { zIndexes = Vector#{1}, draw = (_, _) -> checked_ecast(()) };
        let change = (args: RenderFrame.FrameArgs) -> { sprites = sprite("a", 0) :: sprite("a", 2) :: Nil, scenes = scenes | args };
        Assert.assertEq(expected = (2, 0, 1, 0, 0, 0, 0), countsOf(change))

    // ── mask ──

    /// 同じ絵のスプライトの間に mask つきが 1 個入ると、draw call は 4（前の run・stencil・本体・後の run）で、mask の切れ目が 3。
    @Test
    def testMaskedSpriteBreaksByMask(): Unit \ {Assert, IO} =
        let masked = spriteWith({ texture = "a", z = 1, blend = DrawCmd.BlendMode.Normal, mask = triangle() :: Nil });
        let sprites = sprite("a", 0) :: masked :: sprite("a", 2) :: Nil;
        Assert.assertEq(expected = (4, 0, 0, 0, 0, 0, 3), countsOf(args -> { sprites = sprites | args }))

    /// mask つきの Shader の面は draw call 2 つ（stencil と本体）。スプライトの後なら本体が kind・stencil の分が mask。
    @Test
    def testMaskedSurfaceCountsStencilDraw(): Unit \ {Assert, IO} =
        let masked = { mask = triangle() :: Nil | surface(1) };
        let change = (args: RenderFrame.FrameArgs) -> { sprites = sprite("a", 0) :: Nil, surfaces = masked :: Nil | args };
        Assert.assertEq(expected = (3, 0, 1, 0, 0, 0, 1), countsOf(change))

    // ── 描き先 ──

    /// Pass へ 1 つ、画面へ 1 つ描くと draw call 2 つで、画面の最初の draw call が target の切れ目。
    @Test
    def testSecondTargetBreaksByTarget(): Unit \ {Assert, IO} =
        let (gl, args) = fresh();
        let drawn = { sprites = sprite("a", 0) :: Nil | args };
        RenderFrame.renderFrameMixed(gl, { targetClear = Some(RenderTarget.LoadOp.ClearTransparent) | drawn });
        RenderFrame.renderFrameMixed(gl, drawn);
        Assert.assertEq(expected = (2, 1, 0, 0, 0, 0, 0), tupleOf(RenderDrawCounts.take(args#drawCounts)))

    // ── 取り出し ──

    /// 取り出した後は 0 に戻る。
    @Test
    def testTakeResetsCounts(): Unit \ {Assert, IO} =
        let (gl, args) = fresh();
        RenderFrame.renderFrameMixed(gl, { sprites = sprite("a", 0) :: sprite("b", 1) :: Nil | args });
        discard RenderDrawCounts.take(args#drawCounts);
        Assert.assertEq(expected = (0, 0, 0, 0, 0, 0, 0), tupleOf(RenderDrawCounts.take(args#drawCounts)))

    /// 画面へ塗り終えた時の写しは、取り出した後も読める。
    @Test
    def testLastScreenFrameSurvivesTake(): Unit \ {Assert, IO} =
        let (gl, args) = fresh();
        RenderFrame.renderFrameMixed(gl, { sprites = sprite("a", 0) :: sprite("b", 1) :: Nil | args });
        RenderDrawCounts.markScreenFrame(args#drawCounts);
        discard RenderDrawCounts.take(args#drawCounts);
        Assert.assertEq(expected = (2, 0, 0, 1, 0, 0, 0), tupleOf(RenderDrawCounts.lastScreenFrame(args#drawCounts)))
}
