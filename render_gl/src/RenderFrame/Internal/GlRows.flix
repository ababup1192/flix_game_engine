// RenderFrame.Internal.GlRows — RenderList の行を GL へ流す（GL の backend）。行 1 つを instanced draw 1 回にする。
pub mod RenderFrame.Internal.GlRows {
    import fge.gl.GlContext
    use RenderFrame.{blendOf, countSpriteDraw, setScissorAt}
    use RenderFrame.Internal.RenderList.{RenderList, clearRenderList, rowAt, rowCountOf, rowsOf}

    /// 行を順に GL へ流し、列を空にする。
    pub def drawRenderList(gl: GlContext, st: Array[Int32, Static], list: RenderList): Unit \ IO =
        drawRowsFrom(gl, st, list, 0, rowCountOf(list));
        clearRenderList(list)

    def drawRowsFrom(gl: GlContext, st: Array[Int32, Static], list: RenderList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(gl, st, list, row);
            drawRowsFrom(gl, st, list, row + 1, n)
        }

    /// スプライトの行 1 つを 1 回の instanced draw で描き、draw call を数える。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(gl: GlContext, st: Array[Int32, Static], list: RenderList, row: Int32): Unit \ IO =
        let rows = rowsOf(list);
        let first = rowAt(rows, row, 1);
        let count = rowAt(rows, row, 2);
        let texId = rowAt(rows, row, 3);
        let blendC = rowAt(rows, row, 4);
        let clipFlag = rowAt(rows, row, 5);
        let x0 = rowAt(rows, row, 6);
        let y0 = rowAt(rows, row, 7);
        let x1 = rowAt(rows, row, 8);
        let y1 = rowAt(rows, row, 9);
        let instances = list#instances;
        setScissorAt(gl, st, clipFlag, x0, y0, x1, y1);
        RenderSprite.drawSpriteInstancedBuf(gl, Array.get(0, st), Array.get(1, st), Array.get(2, st), texId,
                                            Array.get(3, st), blendOf(blendC), instances, first, count);
        countSpriteDraw(st, texId, clipFlag, x0, y0, x1, y1, blendC, false, 1);
        ()
}
