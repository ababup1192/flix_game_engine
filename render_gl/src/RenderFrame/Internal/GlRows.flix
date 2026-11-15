// RenderFrame.Internal.GlRows — RenderList の行を GL へ流す（GL の backend）。pass を開いて閉じ（clear・viewport・後始末）、
// instance と頂点の入れ物を貸し、行 1 つを instanced draw 1 回にする。
pub mod RenderFrame.Internal.GlRows {
    import fge.gl.GlConst
    import fge.gl.GlContext
    use RenderFrame.{FrameArgs, blendOf, countSpriteDraw, emitFrameMixed, polyVertCap, upsideDownTargetsOf}
    use RenderFrame.Internal.RenderList.{ColorAttachment, DepthStencil, PassSpec, PassTarget, RenderList, clearRenderList, glViewportOf,
                                         instanceFloats, newRenderList, rowAt, rowCountOf, rowsOf, screenPass, targetPass, vertexFloats}

    /// GL の描き先（FBO）は行 0 が下で、上下逆に格納される。
    pub def targetUpsideDown(): Bool = true

    /// args#targetClear から pass を作る（None = 画面）。Pass の描き先の番号と形式は問わない（GL は bind 済みの framebuffer へ描く）。
    /// GL の描き先はいつも stencil を持つ（窓は GLFW_STENCIL_BITS・Pass は RenderTargetGl の renderbuffer）。
    pub def passOfArgs(args: FrameArgs): PassSpec =
        match args#targetClear {
            case None     => screenPass((args#fbW, args#fbH), (args#designW, args#designH), args#clearColor, DepthStencil.DepthAndStencil)
            case Some(op) => targetPass((args#fbW, args#fbH), { texture = -1, format = RenderTarget.Format.Rgba8Unorm, load = op, resolveTo = None },
                                        DepthStencil.DepthAndStencil, 1)
        }

    /// pass 1 つを今 bind されている framebuffer へ描く。描き先の始末と viewport は pass で決める（args#targetClear は読まない）。
    pub def renderPass(gl: GlContext, args: FrameArgs, pass: PassSpec): Unit \ IO =
        if (pass#width <= 0 or pass#height <= 0) ()
        else {
            beginPass(gl, pass);
            let list = lendRenderList(gl, args);
            let upsideDown = upsideDownTargetsOf(targetUpsideDown(), () -> args#targetNames);
            emitFrameMixed(gl, glStateOf(args, pass), list, args, pass, upsideDown);
            endPass(gl)
        }

    /// 描き先の前の中身を始末し、viewport を張る。画面は黒帯を含む全面を黒 → design 領域だけ clearColor の 2 段階の clear。
    def beginPass(gl: GlContext, pass: PassSpec): Unit \ IO =
        let (vpX, vpY, vpW, vpH) = glViewportOf(pass);
        match pass#target {
            case PassTarget.Screen(screen) =>
                let clearColor = screen#clearColor;
                gl.viewport(0, 0, pass#width, pass#height);
                gl.clearColor(0.0f32, 0.0f32, 0.0f32, 1.0f32);
                gl.clear(GlConst.COLOR_BUFFER_BIT);
                gl.viewport(vpX, vpY, vpW, vpH);
                gl.enable(GlConst.SCISSOR_TEST);
                gl.scissor(vpX, vpY, vpW, vpH);
                gl.clearColor(RenderUtil.f32(clearColor#r), RenderUtil.f32(clearColor#g),
                              RenderUtil.f32(clearColor#b), 1.0f32);
                gl.clear(GlConst.COLOR_BUFFER_BIT);
                gl.disable(GlConst.SCISSOR_TEST)
            case PassTarget.Target(colors) =>
                gl.viewport(vpX, vpY, vpW, vpH);
                colors |> List.head |> Option.forEach(color -> clearColorAttachment(gl, color))
        }

    /// Pass の色の attachment を load の 3 択で始末する（RenderTarget.LoadOp の doc を参照）。
    def clearColorAttachment(gl: GlContext, color: ColorAttachment): Unit \ IO =
        match color#load {
            case RenderTarget.LoadOp.Clear(c) =>
                gl.clearColor(RenderUtil.f32(c#r), RenderUtil.f32(c#g), RenderUtil.f32(c#b), 1.0f32);
                gl.clear(GlConst.COLOR_BUFFER_BIT)
            case RenderTarget.LoadOp.ClearTransparent =>
                gl.clearColor(0.0f32, 0.0f32, 0.0f32, 0.0f32);
                gl.clear(GlConst.COLOR_BUFFER_BIT)
            case RenderTarget.LoadOp.Keep => ()
        }

    /// pass の後始末。scissor を外し blend を Normal に戻す — 有効なまま・Add / Multiply のまま持ち越すと、次のコマの全画面 clear や
    /// タイルマップ、F8 注釈のスクリーンショットの描き直しが小矩形に切られ、違う重ね方で合成される。
    def endPass(gl: GlContext): Unit \ IO =
        gl.disable(GlConst.SCISSOR_TEST);
        RenderSprite.applyBlend(gl, DrawCmd.BlendMode.Normal)

    /// 描く物の数ぶん書ける instance と頂点の入れ物（1 コマ 1 本の使い回し）を貸した空の列。
    /// 行は GL を直に呼ぶ種類の手前まで溜まるので、instance はスプライトの数ぶん取る（行を流すたびに先頭へ戻る）。
    /// 頂点は多角形を三角形へほどいた数の上限で先に広げておく（溜めている途中で取り直す＝書きかけを捨てることが起きない）。
    def lendRenderList(gl: GlContext, args: FrameArgs): RenderList \ IO =
        let instBuf = args#instBuf;
        let polyBuf = args#polyBuf;
        RenderBuf.ensure(gl, instBuf, Int32.max(1, List.length(args#sprites)) * instanceFloats());
        RenderBuf.ensure(gl, polyBuf, Int32.max(3, polyVertCap(args#polygons)) * vertexFloats());
        newRenderList(RenderBuf.buffer(instBuf), RenderBuf.buffer(polyBuf))

    // ── GL の backend の状態（Int32 の配列 1 本・gs）──
    // 0=instShader 1=instVao 2=instVbo 3=instMultiplyBlend 4=polyBatchShader 5=polyBatchVao 6=polyBatchVbo
    // 7-10=viewport (x, y, 幅, 高さ・GL の左下原点) 11=tileShader
    // WhyNot: record で持ち回らない — 1 item ごとに record の欄を辿る代金が物量の画面で 1 コマに出る（RenderFrame の st と同じ形）。
    def glStateOf(args: FrameArgs, pass: PassSpec): Array[Int32, Static] \ IO =
        let (vpX, vpY, vpW, vpH) = glViewportOf(pass);
        Array#{args#instShader, args#instVao, args#instVbo, args#instMultiplyBlend,
               args#polyBatchShader, args#polyBatchVao, args#polyBatchVbo,
               vpX, vpY, vpW, vpH, args#tileShader} @ Static

    /// scissor を張り替える。y は GL の左下原点へ反転し、viewport と交差する
    /// （clip が画面外へ食み出しても letterbox の黒帯を侵さない）。
    /// 幅か高さが 0 以下の矩形は glScissor(…, 0, 0) になり、その run は何も描かない。
    /// clipFlag = 0 は「clip 矩形なし」（scissor 無効化）。
    pub def setScissorAt(gl: GlContext, gs: Array[Int32, Static], clipFlag: Int32,
                         x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        if (clipFlag == 0) gl.disable(GlConst.SCISSOR_TEST)
        else {
            let vpX = Array.get(7, gs);
            let vpY = Array.get(8, gs);
            let vpW = Array.get(9, gs);
            let vpH = Array.get(10, gs);
            let cx0 = Int32.max(0, x0);
            let cx1 = Int32.min(vpW, x1);
            let cy0 = Int32.max(0, y0);
            let cy1 = Int32.min(vpH, y1);
            gl.enable(GlConst.SCISSOR_TEST);
            gl.scissor(vpX + cx0, vpY + vpH - cy1,
                       Int32.max(0, cx1 - cx0), Int32.max(0, cy1 - cy0))
        }

    /// 行を順に GL へ流し、列を空にする。st = front-end の状態（draw call を数える先）。
    pub def drawRenderList(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList): Unit \ IO =
        drawRowsFrom(gl, gs, st, list, 0, rowCountOf(list));
        clearRenderList(list)

    def drawRowsFrom(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(gl, gs, st, list, row);
            drawRowsFrom(gl, gs, st, list, row + 1, n)
        }

    /// スプライトの行 1 つを 1 回の instanced draw で描き、draw call を数える。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList, row: Int32): Unit \ IO =
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
        setScissorAt(gl, gs, clipFlag, x0, y0, x1, y1);
        RenderSprite.drawSpriteInstancedBuf(gl, Array.get(0, gs), Array.get(1, gs), Array.get(2, gs), texId,
                                            Array.get(3, gs), blendOf(blendC), instances, first, count);
        countSpriteDraw(st, texId, clipFlag, x0, y0, x1, y1, blendC, false, 1);
        ()
}
