// RenderFrame.Internal.GlRows — RenderList の行を GL へ流す（GL の backend）。pass を開いて閉じ（clear・viewport・後始末）、
// instance と頂点の入れ物を貸し、行 1 つを draw 1 回にする（スプライトの run・多角形の run・タイルの層・static layer の範囲・面。mask つきスプライトと mask つきの面は 2 回）。
// 3D の場面を貼る行は、その場で場面を描き先へ直に描く（Design の解像度の場面は先に描いた texture を貼る。Render3d.drawItem）。
// WhyNot: Native の解像度の場面を中間の texture に描いてから貼らない — 標本つきの描き先で場面の MSAA が消え、中間の 8 bit の丸めで GL の絵が変わる
//   （plans/engine-webgpu.md の 12.21）。
pub mod RenderFrame.Internal.GlRows {
    import fge.gl.GlConst
    import fge.gl.GlContext
    import java.nio.FloatBuffer
    use RenderFrame.{FrameArgs, blendOf, countPolyDraw, countSceneRow, countSingleDraw, countSpriteDraw, emitFrameMixed, polyVertCap, spriteCaps, surfaceMaskCap,
                     upsideDownTargetsOf}
    use RenderFrame.Internal.RenderList.{ColorAttachment, DepthStencil, Letterbox, PassHistory, PassSpec, PassTarget, RenderList, clearRenderList, glViewportOf,
                                         ListRowKind, blendAt, bufferAt, clipFlagAt, clipX0At, clipX1At, clipY0At, clipY1At, countAt, drawCountCodeOf, firstAt,
                                         hasClipColumns, instanceFloats, kindAt, maskFirstVertexAt, maskInstanceAt, maskStencilRefAt, maskVertexCountAt, newRenderList,
                                         readsOf, rowCountOf, sceneIndexAt, surfaceMaskCountAt, surfaceMaskFirstAt, surfaceStencilAt, textureAt, valuesAt,
                                         rowsOf, screenPass, targetPass, valuesOf, vertexFloats}

    /// 面の行の面を塗る口: (gl, rows, 行, reads, values)。行の program と values と reads の絵で塗る（stencil は GlRows が張ってから呼ぶ）。
    pub type alias SurfaceDrawer = (GlContext, Array[Int32, Static], Int32, Array[Int32, Static], Array[Float32, Static]) -> Unit \ IO

    /// 行を流す時に GL の backend の外へ頼む描き物。scene = 3D の場面を貼る行で番号の場面を描く・
    /// surface = 面の行の面を塗る（SurfaceDrawer）。
    pub type alias RowDrawers = {
        scene = Int32 -> Unit \ IO,
        surface = SurfaceDrawer
    }

    /// GL の描き先（FBO）は行 0 が下で、上下逆に格納される。
    pub def targetUpsideDown(): Bool = true

    /// args#targetClear から pass を作る（None = 画面）。Pass の描き先の番号と形式は問わない（GL は bind 済みの framebuffer へ描く）。
    /// GL の描き先はいつも stencil を持つ（窓は GLFW_STENCIL_BITS・Pass は RenderTargetGl の renderbuffer）。
    // WhyNot: Pass の標本の数を描き先から引かない — renderFrameMixed（テストが組む）には描き先の表が無い。resolve と history は RenderPaint.paintTarget が
    //   自分で組んだ pass から読むので、ここの pass は描き先の始末と viewport にだけ使う。
    pub def passOfArgs(args: FrameArgs): PassSpec =
        match args#targetClear {
            case None     => screenPass((args#fbW, args#fbH), (args#designW, args#designH), args#clearColor, DepthStencil.DepthAndStencil)
            case Some(op) => targetPass((args#fbW, args#fbH), { texture = -1, format = RenderTarget.Format.Rgba8Unorm, load = op },
                                        DepthStencil.DepthAndStencil, 1, PassHistory.NoHistory)
        }

    /// pass 1 つを今 bind されている framebuffer へ描く。描き先の始末と viewport は pass で決める（args#targetClear は読まない）。
    pub def renderPass(gl: GlContext, args: FrameArgs, pass: PassSpec): Unit \ IO =
        if (pass#width <= 0 or pass#height <= 0) ()
        else {
            beginPass(gl, pass);
            let list = prepareRenderList(gl, args);
            let upsideDown = upsideDownTargetsOf(targetUpsideDown(), () -> args#targetNames);
            emitFrameMixed(gl, glStateOf(args, pass), list, args, pass, upsideDown);
            endPass(gl)
        }

    /// 描き先の前の中身を始末し、viewport を張る。画面は黒帯を含む全面を黒 → design 領域だけ clearColor の 2 段階の clear
    /// （余りを先に塗ってある pass（Letterbox.Kept）は、全面の黒を飛ばして design 領域だけ塗る）。
    def beginPass(gl: GlContext, pass: PassSpec): Unit \ IO =
        let (vpX, vpY, vpW, vpH) = glViewportOf(pass);
        match pass#target {
            case PassTarget.Screen(screen) =>
                let clearColor = screen#clearColor;
                if (screen#letterbox == Letterbox.Kept) () else clearWhole(gl, pass);
                gl.viewport(vpX, vpY, vpW, vpH);
                gl.enable(GlConst.SCISSOR_TEST);
                gl.scissor(vpX, vpY, vpW, vpH);
                gl.clearColor(RenderUtil.f32(clearColor#r), RenderUtil.f32(clearColor#g),
                              RenderUtil.f32(clearColor#b), 1.0f32);
                gl.clear(GlConst.COLOR_BUFFER_BIT);
                gl.disable(GlConst.SCISSOR_TEST)
            case PassTarget.Target(color, _) =>
                gl.viewport(vpX, vpY, vpW, vpH);
                clearColorAttachment(gl, color)
        }

    /// 画面の全面（余りを含む）を黒で塗る。
    def clearWhole(gl: GlContext, pass: PassSpec): Unit \ IO =
        gl.viewport(0, 0, pass#width, pass#height);
        gl.clearColor(0.0f32, 0.0f32, 0.0f32, 1.0f32);
        gl.clear(GlConst.COLOR_BUFFER_BIT)

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
    /// 行は pass の終わりまで溜まるので、instance はスプライトの数ぶん取る。
    /// 頂点は多角形と mask（スプライトと面）を三角形へほどいた数の上限で先に広げておく（溜めている途中で取り直す＝書きかけを捨てることが起きない）。
    def prepareRenderList(gl: GlContext, args: FrameArgs): RenderList \ IO =
        let instBuf = args#instBuf;
        let polyBuf = args#polyBuf;
        let (spriteCount, maskVerts) = spriteCaps(args#sprites);
        RenderBuf.ensure(gl, instBuf, Int32.max(1, spriteCount) * instanceFloats());
        RenderBuf.ensure(gl, polyBuf, Int32.max(3, polyVertCap(args#polygons) + maskVerts + surfaceMaskCap(args#surfaces)) * vertexFloats());
        newRenderList(RenderBuf.buffer(instBuf), RenderBuf.buffer(polyBuf))

    // ── GL の backend の状態（Int32 の配列 1 本・gs）──
    // 0=instShader 1=instVao 2=instVbo 3=instMultiplyBlend 4=polyBatchShader 5=polyBatchVao 6=polyBatchVbo
    // 7-10=viewport (x, y, 幅, 高さ・GL の左下原点) 11=tileShader
    // 12-15=多角形のシェーダーの uniform location（multiplyBlend・viewOffset・viewScale・halfDesign）
    // 16-19=tile シェーダーの uniform location（layerPos・tileSize・tileScale・layerColor）
    // WhyNot: record で持ち回らない — 1 item ごとに record の欄を辿る代金が物量の画面で 1 コマに出る（RenderFrame の st と同じ形）。
    def glStateOf(args: FrameArgs, pass: PassSpec): Array[Int32, Static] \ IO =
        let (vpX, vpY, vpW, vpH) = glViewportOf(pass);
        let poly = args#polyBatchUniforms;
        let tile = args#tileUniforms;
        Array#{args#instShader, args#instVao, args#instVbo, args#instMultiplyBlend,
               args#polyBatchShader, args#polyBatchVao, args#polyBatchVbo,
               vpX, vpY, vpW, vpH, args#tileShader,
               poly#multiplyBlend, poly#viewOffset, poly#viewScale, poly#halfDesign,
               tile#layerPos, tile#tileSize, tile#tileScale, tile#layerColor} @ Static

    def polyLocsAt(): Int32 = 12

    def tileLocsAt(): Int32 = 16

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

    /// 行を順に GL へ流し、列を空にする。st = front-end の状態（draw call を数える先）・draw = 3D の場面と面を描く口。
    pub def drawRenderList(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], list: RenderList, draw: RowDrawers): Unit \ IO =
        drawRowsFrom(gl, GlCache.GlCache(gs), DrawTally.DrawTally(st), draw#scene, draw#surface, list#instances, list#vertices, rowsOf(list), valuesOf(list),
                     ReadTable.ReadTable(readsOf(list)), 0, rowCountOf(list));
        clearRenderList(list)

    // 行のループの引数で、同じ Array[Int32, Static] が並ぶ物を型で分ける（入口で包み、drawRow の頭で 1 回剥がす）。
    // WhyNot: 葉（RenderSprite・RenderFrame の数え・SurfaceDrawer）まで包んだまま渡さない — 別のモジュールの pub の型を替えることになる。
    /// GL の状態の控え（program・VAO・viewport・uniform の位置）。
    enum GlCache { case GlCache(Array[Int32, Static]) }
    /// front-end の run の状態（draw call を数える先）。
    enum DrawTally { case DrawTally(Array[Int32, Static]) }
    /// 面の行が読む絵の組（RenderList の reads）。
    enum ReadTable { case ReadTable(Array[Int32, Static]) }

    // WhyNot: 行ごとに list と draw の欄を引かない — 行が描く物の数だけある画面で、record の欄を辿る代金が 1 コマに出る。入れ物と配列はここで 1 回取る。
    def drawRowsFrom(gl: GlContext, cache: GlCache, tally: DrawTally, drawScene: Int32 -> Unit \ IO,
                     drawSurface: SurfaceDrawer,
                     instances: FloatBuffer, vertices: FloatBuffer,
                     rows: Array[Int32, Static], values: Array[Float32, Static], readTable: ReadTable, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(gl, cache, tally, drawScene, drawSurface, instances, vertices, rows, values, readTable, row);
            drawRowsFrom(gl, cache, tally, drawScene, drawSurface, instances, vertices, rows, values, readTable, row + 1, n)
        }

    /// 行 1 つを draw 1 回で描き、draw call を数える（種類ごとの描き方は drawPolyRow などへ）。clip の欄を持たない種類（タイル・面・3D の場面）は scissor を切って描く。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(gl: GlContext, cache: GlCache, tally: DrawTally, drawScene: Int32 -> Unit \ IO,
                drawSurface: SurfaceDrawer,
                instances: FloatBuffer, vertices: FloatBuffer,
                rows: Array[Int32, Static], values: Array[Float32, Static], readTable: ReadTable, row: Int32): Unit \ IO =
        let GlCache.GlCache(gs) = cache;
        let DrawTally.DrawTally(st) = tally;
        let ReadTable.ReadTable(reads) = readTable;
        let kind = kindAt(rows, row);
        if (hasClipColumns(kind)) setRowScissor(gl, gs, rows, row) else gl.disable(GlConst.SCISSOR_TEST);
        match kind {
            case ListRowKind.Sprite  => drawSpriteRow(gl, gs, st, instances, rows, row)
            case ListRowKind.Poly    => drawPolyRow(gl, gs, st, vertices, rows, values, row)
            case ListRowKind.Tile    => drawTileRow(gl, gs, st, rows, values, row)
            case ListRowKind.StaticRange  => drawStaticRow(gl, gs, st, rows, values, row)
            case ListRowKind.Mask    => drawMaskRow(gl, gs, st, instances, vertices, rows, values, row)
            case ListRowKind.Scene3d => drawSceneRow(st, drawScene, rows, row)
            case ListRowKind.Surface => drawSurfaceRow(gl, gs, st, drawSurface, vertices, rows, values, reads, row)
        };
        ()

    /// 行 row の clip で scissor を張る（clip の欄を持つ種類の行だけ）。
    def setRowScissor(gl: GlContext, gs: Array[Int32, Static], rows: Array[Int32, Static], row: Int32): Unit \ IO =
        setScissorAt(gl, gs, clipFlagAt(rows, row), clipX0At(rows, row), clipY0At(rows, row), clipX1At(rows, row), clipY1At(rows, row))

    /// スプライトの行（instances の run）を 1 回の instanced draw で描く。
    def drawSpriteRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], instances: FloatBuffer,
                      rows: Array[Int32, Static], row: Int32): Unit \ IO =
        let texId = textureAt(rows, row);
        let blendC = blendAt(rows, row);
        RenderSprite.drawSpriteInstancedBuf(gl, Array.get(0, gs), Array.get(1, gs), Array.get(2, gs), texId,
                                            Array.get(3, gs), blendOf(blendC), instances, firstAt(rows, row), countAt(rows, row));
        countSpriteDraw(st, texId, clipFlagAt(rows, row), clipX0At(rows, row), clipY0At(rows, row), clipX1At(rows, row), clipY1At(rows, row),
                        blendC, false, 1)

    /// mask つきスプライトの行: stencil の値が 1 なら先に stencil を全部 0 にし（RenderList.nextMaskRef）、mask を stencil へ書いて
    /// その内側だけ 1 体を描く（draw 2 回）。値が 0（mask が 3 頂点未満）なら stencil を使わずに 1 体を描く。
    def drawMaskRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], instances: FloatBuffer, vertices: FloatBuffer,
                    rows: Array[Int32, Static], values: Array[Float32, Static], row: Int32): Unit \ IO =
        let texId = textureAt(rows, row);
        let blendC = blendAt(rows, row);
        let ref = maskStencilRefAt(rows, row);
        if (ref == 0)
            RenderSprite.drawSpriteInstancedBuf(gl, Array.get(0, gs), Array.get(1, gs), Array.get(2, gs), texId,
                                                Array.get(3, gs), blendOf(blendC), instances, maskInstanceAt(rows, row), 1)
        else {
            if (ref == 1) {
                RenderSprite.clearStencil(gl);
                setRowScissor(gl, gs, rows, row)
            } else ();
            RenderSprite.writeStencilMask(gl, Array.get(4, gs), Array.get(5, gs), Array.get(6, gs), gs, polyLocsAt(),
                                          values, 0, vertices, maskFirstVertexAt(rows, row), maskVertexCountAt(rows, row), ref);
            RenderSprite.drawSpriteInstancedBuf(gl, Array.get(0, gs), Array.get(1, gs), Array.get(2, gs), texId,
                                                Array.get(3, gs), blendOf(blendC), instances, maskInstanceAt(rows, row), 1);
            RenderSprite.endStencilMask(gl)
        };
        countSpriteDraw(st, texId, clipFlagAt(rows, row), clipX0At(rows, row), clipY0At(rows, row), clipX1At(rows, row), clipY1At(rows, row),
                        blendC, true, if (ref == 0) 1 else 2)

    /// 面の行: stencil の値が 1 なら先に stencil を全部 0 にし、mask を stencil へ書いてその内側だけ面を塗る（draw 2 回）。
    /// 値が 0（mask が無いか 3 頂点未満）なら面をそのまま塗る。塗るのは塗りのコアの drawSurface（program と uniform と絵の bind）。
    def drawSurfaceRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static],
                       drawSurface: SurfaceDrawer,
                       vertices: FloatBuffer, rows: Array[Int32, Static], values: Array[Float32, Static], reads: Array[Int32, Static], row: Int32): Unit \ IO =
        let ref = surfaceStencilAt(rows, row);
        if (ref == 0) drawSurface(gl, rows, row, reads, values)
        else {
            if (ref == 1) RenderSprite.clearStencil(gl) else ();
            RenderSprite.writeStencilMask(gl, Array.get(4, gs), Array.get(5, gs), Array.get(6, gs), gs, polyLocsAt(),
                                          values, 0, vertices, surfaceMaskFirstAt(rows, row), surfaceMaskCountAt(rows, row), ref);
            drawSurface(gl, rows, row, reads, values);
            RenderSprite.endStencilMask(gl)
        };
        countSingleDraw(st, drawCountCodeOf(ListRowKind.Surface), if (ref == 0) 1 else 2)

    /// 3D の場面を貼る行: 番号の場面を描く（描き終えた場面は viewport を design の矩形へ戻し・scissor を切り・blend を Normal へ戻す）。
    def drawSceneRow(st: Array[Int32, Static], drawScene: Int32 -> Unit \ IO, rows: Array[Int32, Static], row: Int32): Unit \ IO =
        drawScene(sceneIndexAt(rows, row));
        countSceneRow(st)

    /// 多角形の行（vertices の run）を 1 回の draw で描く。
    def drawPolyRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static], vertices: FloatBuffer,
                    rows: Array[Int32, Static], values: Array[Float32, Static], row: Int32): Unit \ IO =
        let blendC = blendAt(rows, row);
        RenderSprite.drawPolygonRange(gl, Array.get(4, gs), Array.get(5, gs), Array.get(6, gs), gs, polyLocsAt(), blendOf(blendC),
                                      values, valuesAt(rows, row), vertices, firstAt(rows, row), countAt(rows, row));
        countPolyDraw(st, clipFlagAt(rows, row), clipX0At(rows, row), clipY0At(rows, row), clipX1At(rows, row), clipY1At(rows, row), blendC)

    /// タイルの層の行を 1 回の instanced draw で描く。TileMapRenderCmd は blend を持たない（いつも Normal）ので、前の行の Add / Multiply を戻す。
    def drawTileRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static],
                    rows: Array[Int32, Static], values: Array[Float32, Static], row: Int32): Unit \ IO =
        RenderSprite.applyBlend(gl, DrawCmd.BlendMode.Normal);
        RenderSprite.drawTileMapInstanced(gl, Array.get(11, gs), textureAt(rows, row), bufferAt(rows, row), gs, tileLocsAt(),
                                          values, valuesAt(rows, row), countAt(rows, row));
        countSingleDraw(st, drawCountCodeOf(ListRowKind.Tile), 1)

    /// static layer の範囲の行を、頂点の buffer（VAO）の範囲で 1 回の draw で描く（上げも三角形化もしない）。
    def drawStaticRow(gl: GlContext, gs: Array[Int32, Static], st: Array[Int32, Static],
                      rows: Array[Int32, Static], values: Array[Float32, Static], row: Int32): Unit \ IO =
        let count = countAt(rows, row);
        RenderSprite.drawStaticRange(gl, Array.get(4, gs), bufferAt(rows, row), gs, polyLocsAt(), blendOf(blendAt(rows, row)),
                                     values, valuesAt(rows, row), firstAt(rows, row), count);
        countSingleDraw(st, drawCountCodeOf(ListRowKind.StaticRange), if (count < 3) 0 else 1)
}
