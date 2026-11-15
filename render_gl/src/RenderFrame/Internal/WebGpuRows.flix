// RenderFrame.Internal.WebGpuRows — 1 回の renderCommands を、GL と同じ前半（mergedByZ → emitSprite が RenderList を作る）で行にし、
// 行を WebGPU の render pass へ流す。device・pipeline・絵の表・instance buffer は呼ぶ側（WebGpuPaint）が持ち、関数の record で渡す。
// 描くのはスプライト・字・箱（mask 無し）だけ。ほかの種類は名前ごとに呼ぶ側へ知らせて飛ばす。
pub mod RenderFrame.Internal.WebGpuRows {
    import fge.webgpu.RenderPass
    import java.nio.FloatBuffer
    use RenderFrame.{Merged, RenderList, addCountsTo, calcViewport, closeSpriteRun, countSpriteDraw, emitSprite,
                     mergedByZ, newRenderList, nextInstanceOf, rowAt, rowCountOf, rowsOf, stateSize, writeInstAt}

    /// 1 回の renderCommands を描き先の render pass 1 つへ流す。
    /// cfg の欄:
    ///   sprites・registry = 描き物と絵の表（GL の FrameArgs と同じ物）・designW/H = 射影の寸・fbW/H = 描き先の画素の大きさ
    ///   targetClear = None なら画面（黒帯と clearColor）・Some(op) なら Pass（全面に写す。op で前の中身を始末する）
    ///   readsForbidden = 描き先と同じ絵の番号（画面なら -1）。その絵を読む行は描かずに知らせる
    ///   instancesFor(n) = n 体ぶん書ける instance の入れ物（呼ぶ側の LITTLE_ENDIAN の ByteBuffer の float の見方）
    ///   openPass(n, op) = 入れ物の頭 n 体を GPU へ送り、op で始末した render pass を開く。返すのは (pass, 送った位置の instance の番号)
    ///   setPipeline(blend の番号)・setTexture(絵の番号) = 行の鍵を pass に積む（0 の絵は呼ばない）
    ///   skip(名前) = 描かない種類を知らせる（名前ごとに 1 回にまとめるのは呼ぶ側）
    pub def renderFrame(cfg: {
        sprites = List[RenderType.Drawable],
        registry = RenderAsset.TextureRegistry,
        clearColor = Color,
        designW = Float64,
        designH = Float64,
        fbW = Int32,
        fbH = Int32,
        targetClear = Option[RenderTarget.LoadOp],
        readsForbidden = Int32,
        texWarnLog = Ref[Set[String], Static],
        drawCounts = RenderDrawCounts.Holder,
        instancesFor = Int32 -> FloatBuffer \ IO,
        openPass = (Int32, RenderTarget.LoadOp) -> (RenderPass, Int32) \ IO,
        setPipeline = (RenderPass, Int32) -> Unit \ IO,
        setTexture = (RenderPass, Int32) -> Unit \ IO,
        skip = String -> Unit \ IO
    }): Unit \ IO =
        let (fbW, fbH) = (cfg#fbW, cfg#fbH);
        if (fbW <= 0 or fbH <= 0) ()
        else {
            let vp = match cfg#targetClear {
                case None    => calcViewport(fbW, fbH, cfg#designW, cfg#designH)
                case Some(_) => (0, 0, fbW, fbH)
            };
            let (_, _, vpW, vpH) = vp;
            let scaleX = Int32.toFloat64(vpW) / cfg#designW;
            let scaleY = Int32.toFloat64(vpH) / cfg#designH;
            let letterboxed = Option.isEmpty(cfg#targetClear) and needsLetterbox(fbW, fbH, vp);
            let instances = cfg#instancesFor(List.length(cfg#sprites) + 1);
            let st: Array[Int32, Static] = Array.empty(Static, stateSize());
            Array.put(1, 28, st);
            Array.put(if (Array.get(RenderDrawCounts.drawCallsSlot(), cfg#drawCounts) > 0) 1 else 0, 30, st);
            let list = newRenderList(instances);
            mergedByZ(Nil, cfg#sprites, Nil, Nil, Nil, Vector.empty())
                |> List.forEach(item -> emitItem(st, list, scaleX, scaleY, cfg#registry, cfg#texWarnLog, cfg#skip, item));
            closeSpriteRun(st, list);
            let used = nextInstanceOf(list);
            if (letterboxed) writeInstAt(instances, used, 0.0, 0.0, cfg#designW, cfg#designH,
                                         clearBox(cfg#clearColor), false, false) else ();
            let sent = if (letterboxed) used + 1 else used;
            let (pass, base) = cfg#openPass(sent, loadOpOf(cfg#targetClear, letterboxed, cfg#clearColor));
            let (vpX, vpY, _, _) = vp;
            pass.setViewport(Int32.toFloat64(vpX), Int32.toFloat64(viewportTop(fbH, vpY, vpH)),
                             Int32.toFloat64(vpW), Int32.toFloat64(vpH), 0.0, 1.0);
            // 0 = 今の pipeline の blend・1 = 今の絵（-1 = まだ積んでいない）
            let bound: Array[Int32, Static] = Array#{-1, -1} @ Static;
            if (letterboxed) {
                bindPipeline(pass, bound, cfg#setPipeline, 0);
                pass.setScissorRect(0, 0, fbW, fbH);
                pass.draw(6, 1, 0, base + used)
            } else ();
            let rows = rowsOf(list);
            drawRowsFrom(pass, st, rows, { fb = (fbW, fbH), vp = vp, base = base, readsForbidden = cfg#readsForbidden,
                                           setPipeline = cfg#setPipeline, setTexture = cfg#setTexture, skip = cfg#skip,
                                           bound = bound }, 0, rowCountOf(list));
            pass.end();
            addCountsTo(cfg#drawCounts, st)
        }

    /// 行を流す間ずっと同じ物（描き先と viewport の大きさ・送った位置・鍵を積む口・今積んである鍵）。
    type alias RowSink = {
        fb = (Int32, Int32),
        vp = (Int32, Int32, Int32, Int32),
        base = Int32,
        readsForbidden = Int32,
        setPipeline = (RenderPass, Int32) -> Unit \ IO,
        setTexture = (RenderPass, Int32) -> Unit \ IO,
        skip = String -> Unit \ IO,
        bound = Array[Int32, Static]
    }

    /// 並べた 1 個を行へ積む（mask の無いスプライトだけ。ほかは知らせて飛ばす）。
    def emitItem(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                 registry: RenderAsset.TextureRegistry, warnLog: Ref[Set[String], Static],
                 skip: String -> Unit \ IO, item: Merged): Unit \ IO =
        match item {
            case Merged.MSprite(d) =>
                if (List.isEmpty(DrawCmd.maskOf(d))) emitSprite(st, list, scaleX, scaleY, registry, Set.empty(), warnLog, d)
                else skip("mask つきスプライト")
            case Merged.MTile(_)    => skip("タイルの層")
            case Merged.MPoly(_)    => skip("多角形")
            case Merged.MStatic(_)  => skip("static layer")
            case Merged.MSurface(_) => skip("面（ShaderDoc）")
            case Merged.MScene3d(_) => skip("3D の場面")
        }

    def drawRowsFrom(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], sink: RowSink,
                     row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, st, rows, sink, row);
            drawRowsFrom(pass, st, rows, sink, row + 1, n)
        }

    /// 行 1 つを draw 1 本にし、draw call を GL と同じ物差しで数える（幅か高さが 0 の scissor は draw を出さずに 1 と数える）。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], sink: RowSink, row: Int32): Unit \ IO =
        let (blendC, texId, firstInstance, count) = drawArgsAt(rows, row, sink#base);
        let clipFlag = rowAt(rows, row, 5);
        let x0 = rowAt(rows, row, 6);
        let y0 = rowAt(rows, row, 7);
        let x1 = rowAt(rows, row, 8);
        let y1 = rowAt(rows, row, 9);
        if (texId != 0 and texId == sink#readsForbidden) sink#skip("描き先と同じ絵を読むスプライト")
        else {
            let (sx, sy, sw, sh) = scissorOf(sink#fb, sink#vp, clipFlag, x0, y0, x1, y1);
            bindPipeline(pass, sink#bound, sink#setPipeline, blendC);
            if (texId == 0 or Array.get(1, sink#bound) == texId) ()
            else {
                sink#setTexture(pass, texId);
                Array.put(texId, 1, sink#bound)
            };
            if (sw > 0 and sh > 0) {
                pass.setScissorRect(sx, sy, sw, sh);
                pass.draw(6, count, 0, firstInstance)
            } else ();
            countSpriteDraw(st, texId, clipFlag, x0, y0, x1, y1, blendC, false, 1)
        };
        ()

    /// blend の番号の pipeline を積む（前と同じなら積まない）。
    def bindPipeline(pass: RenderPass, bound: Array[Int32, Static], setPipeline: (RenderPass, Int32) -> Unit \ IO,
                     blendC: Int32): Unit \ IO =
        if (Array.get(0, bound) == blendC) ()
        else {
            setPipeline(pass, blendC);
            Array.put(blendC, 0, bound)
        }

    /// 行 row の draw の引数: (blend の番号, 絵の番号, firstInstance, 体数)。base = 行の instance を送った位置の instance の番号。
    def drawArgsAt(rows: Array[Int32, Static], row: Int32, base: Int32): (Int32, Int32, Int32, Int32) \ IO =
        (rowAt(rows, row, 4), rowAt(rows, row, 3), base + rowAt(rows, row, 1), rowAt(rows, row, 2))

    /// 行の clip 矩形（viewport の左上が原点の px）を、描き先の左上が原点の scissor (x, y, 幅, 高さ) にする。
    /// viewport と交わし、描き先の外へ出た分を切る（WebGPU は描き先の外へ出た scissor で pass ごと誤りになる）。clip が無ければ描き先の全面。
    def scissorOf(fb: (Int32, Int32), vp: (Int32, Int32, Int32, Int32), clipFlag: Int32,
                  x0: Int32, y0: Int32, x1: Int32, y1: Int32): (Int32, Int32, Int32, Int32) =
        let (fbW, fbH) = fb;
        if (clipFlag == 0) (0, 0, fbW, fbH)
        else {
            let (vpX, vpY, vpW, vpH) = vp;
            let cx0 = Int32.max(0, x0);
            let cx1 = Int32.min(vpW, x1);
            let cy0 = Int32.max(0, y0);
            let cy1 = Int32.min(vpH, y1);
            let left = vpX + cx0;
            let top = viewportTop(fbH, vpY, vpH) + cy0;
            let x = within(fbW, left);
            let y = within(fbH, top);
            let right = within(fbW, left + Int32.max(0, cx1 - cx0));
            let bottom = within(fbH, top + Int32.max(0, cy1 - cy0));
            (x, y, Int32.max(0, right - x), Int32.max(0, bottom - y))
        }

    /// v を [0, limit] に収める。
    def within(limit: Int32, v: Int32): Int32 = Int32.max(0, Int32.min(limit, v))

    /// viewport の上の端（描き先の左上が原点）。calcViewport の vpY は GL の左下が原点。
    def viewportTop(fbH: Int32, vpY: Int32, vpH: Int32): Int32 = fbH - vpY - vpH

    /// 画面のコマで黒帯があるか（design の矩形が描き先の全面でない）。
    def needsLetterbox(fbW: Int32, fbH: Int32, vp: (Int32, Int32, Int32, Int32)): Bool =
        vp != (0, 0, fbW, fbH)

    /// 黒帯のある画面で design の矩形を塗る箱（Normal・alpha 1 なので結果は色そのもの）。置くのは (0, 0)・大きさは design。
    def clearBox(color: Color): RenderType.Drawable =
        DrawCmd.make({
            texture = "", position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
            rotation = 0.0, color = color, alpha = 1.0, centered = false,
            uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
            zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })

    /// render pass の頭の始末。画面は黒帯があれば黒（design の矩形は clearBox が塗る）・無ければ clearColor。Pass は頼まれた op。
    def loadOpOf(targetClear: Option[RenderTarget.LoadOp], letterboxed: Bool, clearColor: Color): RenderTarget.LoadOp =
        match targetClear {
            case Some(op) => op
            case None     => RenderTarget.LoadOp.Clear(if (letterboxed) { r = 0.0, g = 0.0, b = 0.0 } else clearColor)
        }
}
