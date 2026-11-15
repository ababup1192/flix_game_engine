// RenderFrame.Internal.WebGpuRows — 1 回の renderCommands を、GL と同じ前半（mergedByZ → emitSprite が RenderList を作る）で行にし、
// 行を WebGPU の render pass へ流す。device・pipeline・絵の表・instance buffer は呼ぶ側（WebGpuPaint）が持ち、関数の record で渡す。
// 描くのはスプライト・字・箱（mask 無し）だけ。ほかの種類は名前ごとに呼ぶ側へ知らせて飛ばす。
pub mod RenderFrame.Internal.WebGpuRows {
    import fge.webgpu.RenderPass
    import java.nio.FloatBuffer
    use RenderFrame.{Merged, addCountsTo, calcViewport, closeSpriteRun, countSpriteDraw, emitSprite,
                     mergedByZ, stateSize, writeInstAt}
    use RenderFrame.Internal.RenderList.{RenderList, newRenderList, nextInstanceOf, rowAt, rowCountOf, rowsOf}

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
            // WhyNot: 並べた 1 個ごとに cfg の欄を読まない — 開いた record の欄は読むたびに欄の列を辿り、2 万個の画面ではそれだけで 1 コマに出る。
            let registry = cfg#registry;
            let warnLog = cfg#texWarnLog;
            let skip = cfg#skip;
            emitAll(st, list, scaleX, scaleY, registry, warnLog, skip, mergedByZ(Nil, cfg#sprites, Nil, Nil, Nil, Vector.empty()));
            closeSpriteRun(st, list);
            let used = nextInstanceOf(list);
            if (letterboxed) writeInstAt(instances, used, 0.0, 0.0, cfg#designW, cfg#designH,
                                         clearBox(cfg#clearColor), false, false) else ();
            let sent = if (letterboxed) used + 1 else used;
            let (pass, base) = cfg#openPass(sent, loadOpOf(cfg#targetClear, letterboxed, cfg#clearColor));
            let (vpX, vpY, _, _) = vp;
            pass.setViewport(Int32.toFloat64(vpX), Int32.toFloat64(viewportTop(fbH, vpY, vpH)),
                             Int32.toFloat64(vpW), Int32.toFloat64(vpH), 0.0, 1.0);
            let setPipeline = cfg#setPipeline;
            let geom = geometryOf(fbW, fbH, vp, base, cfg#readsForbidden);
            if (letterboxed) {
                bindPipeline(pass, geom, setPipeline, 0);
                pass.setScissorRect(0, 0, fbW, fbH);
                pass.draw(6, 1, 0, base + used)
            } else ();
            drawRowsFrom(pass, st, rowsOf(list), geom, setPipeline, cfg#setTexture, skip, 0, rowCountOf(list));
            pass.end();
            addCountsTo(cfg#drawCounts, st)
        }

    // ── 行を流す間ずっと同じ値の入れ物（Int32 の配列 1 本）──
    // 0=描き先の幅 1=描き先の高さ 2-5=viewport (x, y, 幅, 高さ・GL の左下原点) 6=行の instance を送った位置 7=描き先と同じ絵の番号
    // 8=今積んである pipeline の blend 9=今積んである絵（どちらも -1 = まだ積んでいない） 10-13=今の行の scissor (x, y, 幅, 高さ)
    // WhyNot: record や組で持ち回らない — 行が描く物の数だけある画面で、行ごとに record の欄を辿る代金と組の割り当てが 1 コマに出る（RenderFrame の st と同じ形）。
    def geometryOf(fbW: Int32, fbH: Int32, vp: (Int32, Int32, Int32, Int32), base: Int32, readsForbidden: Int32): Array[Int32, Static] \ IO =
        let (vpX, vpY, vpW, vpH) = vp;
        Array#{fbW, fbH, vpX, vpY, vpW, vpH, base, readsForbidden, -1, -1, 0, 0, 0, 0} @ Static

    def emitAll(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                registry: RenderAsset.TextureRegistry, warnLog: Ref[Set[String], Static],
                skip: String -> Unit \ IO, items: List[Merged]): Unit \ IO =
        match items {
            case Nil => ()
            case item :: rest =>
                emitItem(st, list, scaleX, scaleY, registry, warnLog, skip, item);
                emitAll(st, list, scaleX, scaleY, registry, warnLog, skip, rest)
        }

    /// 並べた 1 個を行へ積む（mask の無いスプライトだけ。ほかは知らせて飛ばす）。
    // WhyNot: 末尾を呼び出しで終えない・emitAll のループの中へ書き下さない — ループが JIT から外れる（docs/performance.md の 13 節。RenderFrame.emitOne と同じ形）。
    @DontInline
    def emitItem(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                 registry: RenderAsset.TextureRegistry, warnLog: Ref[Set[String], Static],
                 skip: String -> Unit \ IO, item: Merged): Unit \ IO =
        match item {
            case Merged.MSprite(d) => emitPlainSprite(st, list, scaleX, scaleY, registry, warnLog, skip, d)
            case Merged.MTile(_)    => skip("タイルの層")
            case Merged.MPoly(_)    => skip("多角形")
            case Merged.MStatic(_)  => skip("static layer")
            case Merged.MSurface(_) => skip("面（ShaderDoc）")
            case Merged.MScene3d(_) => skip("3D の場面")
        };
        ()

    /// mask の無い・Pass の history でないスプライトを行へ積む（ほかは知らせて飛ばす）。
    def emitPlainSprite(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                        registry: RenderAsset.TextureRegistry, warnLog: Ref[Set[String], Static],
                        skip: String -> Unit \ IO, d: RenderType.Drawable): Unit \ IO =
        if (not List.isEmpty(DrawCmd.maskOf(d))) skip("mask つきスプライト")
        else if (isHistoryName(DrawCmd.textureOf(d))) skip("Pass の history")
        else emitSprite(st, list, scaleX, scaleY, registry, Set.empty(), warnLog, d)

    /// Pass の前のコマの写しの名前か（RenderTarget.historyName で作る名前）。
    def isHistoryName(name: String): Bool = String.endsWith({suffix = RenderTarget.historyName("")}, name)

    def drawRowsFrom(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                     setPipeline: (RenderPass, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                     skip: String -> Unit \ IO, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, st, rows, geom, setPipeline, setTexture, skip, row);
            drawRowsFrom(pass, st, rows, geom, setPipeline, setTexture, skip, row + 1, n)
        }

    /// 行 1 つを draw 1 本にし、draw call を GL と同じ物差しで数える（幅か高さが 0 の scissor は draw を出さずに 1 と数える）。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                setPipeline: (RenderPass, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                skip: String -> Unit \ IO, row: Int32): Unit \ IO =
        let blendC = rowAt(rows, row, 4);
        let texId = rowAt(rows, row, 3);
        let clipFlag = rowAt(rows, row, 5);
        let x0 = rowAt(rows, row, 6);
        let y0 = rowAt(rows, row, 7);
        let x1 = rowAt(rows, row, 8);
        let y1 = rowAt(rows, row, 9);
        if (texId != 0 and texId == Array.get(7, geom)) skip("描き先と同じ絵を読むスプライト")
        else {
            scissorInto(geom, clipFlag, x0, y0, x1, y1);
            bindPipeline(pass, geom, setPipeline, blendC);
            if (texId == 0 or Array.get(9, geom) == texId) ()
            else {
                setTexture(pass, texId);
                Array.put(texId, 9, geom)
            };
            let sw = Array.get(12, geom);
            let sh = Array.get(13, geom);
            if (sw > 0 and sh > 0) {
                pass.setScissorRect(Array.get(10, geom), Array.get(11, geom), sw, sh);
                pass.draw(6, rowAt(rows, row, 2), 0, firstInstanceAt(rows, row, Array.get(6, geom)))
            } else ();
            countSpriteDraw(st, texId, clipFlag, x0, y0, x1, y1, blendC, false, 1)
        };
        ()

    /// blend の番号の pipeline を積む（前と同じなら積まない）。
    def bindPipeline(pass: RenderPass, geom: Array[Int32, Static], setPipeline: (RenderPass, Int32) -> Unit \ IO,
                     blendC: Int32): Unit \ IO =
        if (Array.get(8, geom) == blendC) ()
        else {
            setPipeline(pass, blendC);
            Array.put(blendC, 8, geom)
        }

    /// 行 row の draw の firstInstance。base = 行の instance を送った位置の instance の番号。
    def firstInstanceAt(rows: Array[Int32, Static], row: Int32, base: Int32): Int32 \ IO = base + rowAt(rows, row, 1)

    /// 行の clip 矩形（viewport の左上が原点の px）を、描き先の左上が原点の scissor (x, y, 幅, 高さ) にして geom の 10〜13 へ置く。
    /// viewport と交わし、描き先の外へ出た分を切る（WebGPU は描き先の外へ出た scissor で pass ごと誤りになる）。clip が無ければ描き先の全面。
    def scissorInto(geom: Array[Int32, Static], clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        let fbW = Array.get(0, geom);
        let fbH = Array.get(1, geom);
        if (clipFlag == 0) putScissor(geom, 0, 0, fbW, fbH)
        else {
            let vpX = Array.get(2, geom);
            let vpY = Array.get(3, geom);
            let vpW = Array.get(4, geom);
            let vpH = Array.get(5, geom);
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
            putScissor(geom, x, y, Int32.max(0, right - x), Int32.max(0, bottom - y))
        }

    def putScissor(geom: Array[Int32, Static], x: Int32, y: Int32, w: Int32, h: Int32): Unit \ IO =
        Array.put(x, 10, geom);
        Array.put(y, 11, geom);
        Array.put(w, 12, geom);
        Array.put(h, 13, geom)

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
