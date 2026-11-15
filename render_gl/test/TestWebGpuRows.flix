// WebGPU の行の流し方の、GPU を呼ばない所（scissor の式・viewport の上下・黒帯の要否・行から draw の引数）を固定する。
// 例の描き先は 320 × 200 に design 320 × 180 を収めた物（calcViewport が上下に 10 px ずつの黒帯を置く: vp = (0, 10, 320, 180)）。
// WhyNot: mod TestWebGpuRows にしない — 固定したい関数は WebGpuRows の中の pub でない関数で、子のモジュールからしか呼べない。
mod RenderFrame.Internal.WebGpuRows.TestWebGpuRows {
    import java.nio.FloatBuffer
    use RenderFrame.{closeSpriteRun, emitSprite, stateSize}
    use RenderFrame.Internal.RenderList.{instanceFloats, newRenderList, rowAt, rowsOf}
    use RenderFrame.Internal.WebGpuRows.{firstInstanceAt, geometryOf, isHistoryName, keepScissor, putScissor, scissorInto, viewportTop}

    def fb(): (Int32, Int32) = (320, 200)

    def vp(): (Int32, Int32, Int32, Int32) = (0, 10, 320, 180)

    /// scissorInto が置いた (x, y, 幅, 高さ) を組で読む。
    def scissorOf(fb: (Int32, Int32), vp: (Int32, Int32, Int32, Int32), clipFlag: Int32,
                  x0: Int32, y0: Int32, x1: Int32, y1: Int32): (Int32, Int32, Int32, Int32) \ IO =
        let geom = geometryOf(fst(fb), snd(fb), vp, 0, -1);
        scissorInto(geom, clipFlag, x0, y0, x1, y1);
        (Array.get(10, geom), Array.get(11, geom), Array.get(12, geom), Array.get(13, geom))

    // ── scissor ──

    /// clip の無い行は描き先の全面。
    @Test
    def testScissorWithoutClipIsWholeTarget(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0, 0, 320, 200), scissorOf(fb(), vp(), 0, 0, 0, 0, 0))

    /// viewport の中の clip は、viewport の上の端（10 px）だけ下へずれる。
    @Test
    def testScissorShiftsByViewportTop(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (10, 30, 40, 40), scissorOf(fb(), vp(), 1, 10, 20, 50, 60))

    /// viewport の右下からはみ出た clip は viewport の端で切れる（黒帯に掛からない）。
    @Test
    def testScissorStopsAtViewportEdge(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (300, 180, 20, 10), scissorOf(fb(), vp(), 1, 300, 170, 400, 250))

    /// 幅 0 の clip は幅 0 の scissor（draw を出さない行）。
    @Test
    def testScissorOfZeroWidthClip(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (50, 30, 0, 40), scissorOf(fb(), vp(), 1, 50, 20, 50, 60))

    /// viewport の左上の外だけにある clip は幅も高さも 0。
    @Test
    def testScissorOutsideViewportIsEmpty(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (0, 10, 0, 0), scissorOf(fb(), vp(), 1, -50, -50, -10, -10))

    /// viewport（100 × 100・上の端 0）が描き先（50 × 50）より大きくても、scissor は描き先の中に収まる（右下の 40〜90 は 40〜50 に切れる）。
    @Test
    def testScissorStaysInsideTarget(): Unit \ {Assert, IO} =
        Assert.assertEq(expected = (40, 40, 10, 10), scissorOf((50, 50), (0, -50, 100, 100), 1, 40, 40, 90, 90))

    /// 同じ scissor を 2 回続けて積もうとすると 2 回目だけ積まない。違う矩形に替えるとまた積む（最初の 1 回も積む）。
    @Test
    def testSameScissorIsNotPushedTwice(): Unit \ {Assert, IO} =
        let geom = geometryOf(320, 200, vp(), 0, -1);
        putScissor(geom, 0, 0, 320, 200);
        let first = keepScissor(geom);
        let second = keepScissor(geom);
        putScissor(geom, 10, 30, 40, 40);
        let changed = keepScissor(geom);
        Assert.assertEq(expected = (false, true, false), (first, second, changed))

    // ── viewport ──

    /// viewport の上の端: 上下の黒帯 10 px の時は 10・下に寄った高さ 100 の viewport（GL の vpY = 0）は 300 − 100 = 200。
    @Test
    def testViewportTopFlipsGlOrigin(): Unit \ Assert =
        Assert.assertEq(expected = (10, 200), (viewportTop(200, 10, 180), viewportTop(300, 0, 100)))

    // ── 行から draw の引数 ──

    /// 絵 a・b の 2 行を位置 100 へ送った時、2 行目の引数は (Normal, b の番号 6, 100 + 1, 1 体)。
    @Test
    def testDrawArgsAddBaseToFirstInstance(): Unit \ {Assert, IO} =
        let registry = Map#{"a" => { id = GpuHandle.wrapTextureId(5), width = 8.0, height = 8.0 },
                            "b" => { id = GpuHandle.wrapTextureId(6), width = 8.0, height = 8.0 }};
        let st: Array[Int32, Static] = Array.empty(Static, stateSize());
        let list = newRenderList(FloatBuffer.allocate(instanceFloats() * 2), FloatBuffer.allocate(0));
        let warnLog = Ref.fresh(Static, Set.empty());
        emitSprite(st, list, 1.0, 1.0, registry, Set.empty(), warnLog, spriteOf("a"));
        emitSprite(st, list, 1.0, 1.0, registry, Set.empty(), warnLog, spriteOf("b"));
        closeSpriteRun(st, list);
        let rows = rowsOf(list);
        Assert.assertEq(expected = (0, 6, 101, 1), (rowAt(rows, 1, 4), rowAt(rows, 1, 3), firstInstanceAt(rows, 1, 100), rowAt(rows, 1, 2)))

    def spriteOf(texture: String): DrawCmd.Drawable =
        DrawCmd.make({
          texture = texture, position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
          rotation = 0.0, color = { r = 1.0, g = 1.0, b = 1.0 }, alpha = 1.0,
          centered = false, uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
          zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    // ── Pass の history ──

    /// Pass の前のコマの写しの名前（RenderTarget.historyName）だけを history と見る。
    @Test
    def testHistoryNameIsRecognized(): Unit \ Assert =
        Assert.assertEq(expected = (true, false), (isHistoryName(RenderTarget.historyName("bloom")), isHistoryName("bloom")))
}
