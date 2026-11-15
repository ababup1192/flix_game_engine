// RenderFrame.Internal.WebGpuRows — 1 回の renderCommands を、GL と同じ前半（mergedByZ → emitRowItem が RenderList を作る）で行にし、
// 行を WebGPU の render pass へ流す。device・pipeline・絵と頂点の buffer の表・instance と頂点と values の buffer は呼ぶ側（WebGpuPaint）が持ち、関数の record で渡す。
// 描くのはスプライト・字・箱（mask 無し）・多角形・タイルの層・static layer。ほかの種類は名前ごとに呼ぶ側へ知らせて飛ばす。
pub mod RenderFrame.Internal.WebGpuRows {
    import fge.webgpu.RenderPass
    import java.nio.FloatBuffer
    use RenderFrame.{Merged, addCountsTo, closeRuns, countPolyDraw, countSingleDraw, countSpriteDraw, emitRowItem, mergedByZ, newRunState,
                     polyVertCap, upsideDownTargetsOf, writeInstAt}
    use RenderFrame.Internal.RenderList.{PassSpec, RenderList, glViewportOf, hasLetterbox, kindPoly, kindSprite, kindStatic, kindTile, loadOpOf,
                                         newRenderList, nextInstanceOf, nextVertexOf, rowAt, rowCountOf, rowsOf, screenClearColorOf,
                                         targetTextureOf, valueCountOf, valuesOf}

    /// 描き先（texture）は上下逆に格納しない（行 0 が上）。
    pub def targetUpsideDown(): Bool = false

    /// pipeline の形（setPipeline に渡す番号）。
    pub def shapeSprite(): Int32 = 0
    pub def shapePoly(): Int32 = 1
    pub def shapeTile(): Int32 = 2

    /// 1 回の renderCommands を pass 1 つへ流す。
    /// cfg の欄:
    ///   sprites・tileMaps・polygons・staticRanges・registry = 描き物と絵の表（GL の FrameArgs と同じ物）・designW/H = 射影の寸
    ///   pass = 描き先と、その始末・viewport（描き先と同じ絵を読む行は描かずに知らせる）
    ///   instancesFor(n)・verticesFor(n) = n 体・n 頂点ぶん書ける入れ物（呼ぶ側の LITTLE_ENDIAN の ByteBuffer の float の見方）
    ///   upload(体数, 頂点数, values, values の数) = 入れ物の頭と values を GPU へ送る。返すのは送った位置（instance の番号, 頂点の番号, values の bytes）
    ///   openPass(op) = op で始末した render pass を開く（instance の buffer を頂点の buffer の 0 番に付けておく）
    ///   setPipeline(形, blend の番号)・setTexture(絵の番号) = 行の鍵を pass に積む（0 の絵は呼ばない）
    ///   setVertices(種類, buffer の番号) = 頂点の buffer の 0 番を、その種類の buffer にする（スプライト = instance・多角形 = 頂点・タイル と static = 表の buffer）。
    ///     返すのはその buffer に入っている要素の数（タイルは枚数・static は頂点の数）。表に無い番号なら 0（その行は描かずに数える）
    ///   setValues(bytes) = 頂点の buffer の 1 番を、values の buffer の bytes の位置にする
    ///   skip(名前) = 描かない種類を知らせる（名前ごとに 1 回にまとめるのは呼ぶ側）
    pub def renderFrame(cfg: {
        sprites = List[RenderType.Drawable],
        tileMaps = List[RenderType.TileMapRenderCmd],
        polygons = List[RenderType.PolygonCmd],
        staticRanges = List[RenderStatic.Range],
        registry = RenderAsset.TextureRegistry,
        designW = Float64,
        designH = Float64,
        pass = PassSpec,
        texWarnLog = Ref[Set[String], Static],
        drawCounts = RenderDrawCounts.Holder,
        instancesFor = Int32 -> FloatBuffer \ IO,
        verticesFor = Int32 -> FloatBuffer \ IO,
        upload = (Int32, Int32, Array[Float32, Static], Int32) -> (Int32, Int32, Int32) \ IO,
        openPass = RenderTarget.LoadOp -> RenderPass \ IO,
        setPipeline = (RenderPass, Int32, Int32) -> Unit \ IO,
        setTexture = (RenderPass, Int32) -> Unit \ IO,
        setVertices = (RenderPass, Int32, Int32) -> Int32 \ IO,
        setValues = (RenderPass, Int32) -> Unit \ IO,
        skip = String -> Unit \ IO
    }): Unit \ IO =
        let spec = cfg#pass;
        let (fbW, fbH) = (spec#width, spec#height);
        if (fbW <= 0 or fbH <= 0) ()
        else {
            let vp = glViewportOf(spec);
            let (_, _, vpW, vpH) = vp;
            let scaleX = Int32.toFloat64(vpW) / cfg#designW;
            let scaleY = Int32.toFloat64(vpH) / cfg#designH;
            let letterboxed = hasLetterbox(spec);
            let instances = cfg#instancesFor(List.length(cfg#sprites) + 1);
            let st = newRunState(cfg#drawCounts);
            let list = newRenderList(instances, cfg#verticesFor(Int32.max(3, polyVertCap(cfg#polygons))));
            // WhyNot: 並べた 1 個ごとに cfg の欄を読まない — 開いた record の欄は読むたびに欄の列を辿り、2 万個の画面ではそれだけで 1 コマに出る。
            let registry = cfg#registry;
            let warnLog = cfg#texWarnLog;
            let skip = cfg#skip;
            // WhyNot: 描き先の表の名前を渡さない — targetUpsideDown が偽なので upsideDownTargetsOf は表を引かない。
            let upsideDown = upsideDownTargetsOf(targetUpsideDown(), () -> Set.empty());
            emitAll(st, list, scaleX, scaleY, registry, upsideDown, warnLog, skip,
                    mergedByZ(cfg#tileMaps, cfg#sprites, cfg#polygons, cfg#staticRanges, Nil, Vector.empty()));
            closeRuns(st, list);
            let used = nextInstanceOf(list);
            if (letterboxed) writeInstAt(instances, used, 0.0, 0.0, cfg#designW, cfg#designH,
                                         clearBox(screenClearColorOf(spec) |> Option.getWithDefault({ r = 0.0, g = 0.0, b = 0.0 })), false, false) else ();
            let sent = if (letterboxed) used + 1 else used;
            let (base, vertexBase, valuesBase) = cfg#upload(sent, nextVertexOf(list), valuesOf(list), valueCountOf(list));
            let pass = cfg#openPass(loadOpOf(spec));
            let (vpX, vpY, _, _) = vp;
            pass.setViewport(Int32.toFloat64(vpX), Int32.toFloat64(viewportTop(fbH, vpY, vpH)),
                             Int32.toFloat64(vpW), Int32.toFloat64(vpH), 0.0, 1.0);
            let setPipeline = cfg#setPipeline;
            let geom = geometryOf(fbW, fbH, vp, (base, vertexBase, valuesBase), targetTextureOf(spec));
            if (letterboxed) {
                bindPipeline(pass, geom, setPipeline, shapeSprite(), 0);
                putScissor(geom, 0, 0, fbW, fbH);
                applyScissor(pass, geom);
                pass.draw(6, 1, 0, base + used)
            } else ();
            drawRowsFrom(pass, st, rowsOf(list), geom, setPipeline, cfg#setTexture, cfg#setVertices, cfg#setValues, skip, 0, rowCountOf(list));
            pass.end();
            addCountsTo(cfg#drawCounts, st)
        }

    // ── 行を流す間ずっと同じ値の入れ物（Int32 の配列 1 本）──
    // 0=描き先の幅 1=描き先の高さ 2-5=viewport (x, y, 幅, 高さ・GL の左下原点) 6=行の instance を送った位置 7=描き先と同じ絵の番号
    // 8=今積んである pipeline（形 × 4 + blend） 9=今積んである絵（どちらも -1 = まだ積んでいない） 10-13=今の行の scissor (x, y, 幅, 高さ)
    // 14-17=今積んである scissor (x, y, 幅, 高さ・幅 -1 = まだ積んでいない) 18=頂点の buffer の 0 番の種類（kind*） 19=その buffer の番号
    // 20=頂点の buffer の 1 番の values の bytes（-1 = まだ積んでいない） 21=行の頂点を送った位置 22=values を送った位置（bytes）
    // 23=頂点の buffer の 0 番に入っている要素の数
    // WhyNot: record や組で持ち回らない — 行が描く物の数だけある画面で、行ごとに record の欄を辿る代金と組の割り当てが 1 コマに出る（RenderFrame の st と同じ形）。
    /// sent = 送った位置（instance の番号, 頂点の番号, values の bytes）・readsForbidden = 描き先と同じ絵の番号。
    def geometryOf(fbW: Int32, fbH: Int32, vp: (Int32, Int32, Int32, Int32), sent: (Int32, Int32, Int32), readsForbidden: Int32): Array[Int32, Static] \ IO =
        let (vpX, vpY, vpW, vpH) = vp;
        let (base, vertexBase, valuesBase) = sent;
        Array#{fbW, fbH, vpX, vpY, vpW, vpH, base, readsForbidden, -1, -1, 0, 0, 0, 0, 0, 0, -1, 0, kindSprite(), 0, -1,
               vertexBase, valuesBase, Int32.maxValue()} @ Static

    def emitAll(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                registry: RenderAsset.TextureRegistry, upsideDown: Set[String], warnLog: Ref[Set[String], Static],
                skip: String -> Unit \ IO, items: List[Merged]): Unit \ IO =
        match items {
            case Nil => ()
            case item :: rest =>
                emitItem(st, list, scaleX, scaleY, registry, upsideDown, warnLog, skip, item);
                emitAll(st, list, scaleX, scaleY, registry, upsideDown, warnLog, skip, rest)
        }

    /// 並べた 1 個を行へ積む（行になる種類だけ。Pass の history を読むスプライトと、GL を直に呼ぶ種類は知らせて飛ばす）。
    // WhyNot: 末尾を呼び出しで終えない・emitAll のループの中へ書き下さない — ループが JIT から外れる（docs/performance.md の 13 節。RenderFrame.emitOne と同じ形）。
    @DontInline
    def emitItem(st: Array[Int32, Static], list: RenderList, scaleX: Float64, scaleY: Float64,
                 registry: RenderAsset.TextureRegistry, upsideDown: Set[String], warnLog: Ref[Set[String], Static],
                 skip: String -> Unit \ IO, item: Merged): Unit \ IO =
        if (readsHistory(item)) skip("Pass の history")
        else if (emitRowItem(st, list, scaleX, scaleY, registry, upsideDown, warnLog, item)) ()
        else {
            // WhyNot: 飛ばした所で run を続けない — GL は GL を直に呼ぶ種類の前で run を閉じるので、続けると draw の数え方が GL とずれる。
            closeRuns(st, list);
            skip(skippedName(item))
        };
        ()

    /// Pass の前のコマの写しを読むスプライトか。
    def readsHistory(item: Merged): Bool = match item {
        case Merged.MSprite(d)  => isHistoryName(DrawCmd.textureOf(d))
        case Merged.MTile(_)    => false
        case Merged.MPoly(_)    => false
        case Merged.MStatic(_)  => false
        case Merged.MSurface(_) => false
        case Merged.MScene3d(_) => false
    }

    /// 行にならなかった物の知らせの名前（スプライトは mask つきの時だけ行にならない）。
    def skippedName(item: Merged): String = match item {
        case Merged.MSprite(_)  => "mask つきスプライト"
        case Merged.MSurface(_) => "面（ShaderDoc）"
        case Merged.MScene3d(_) => "3D の場面"
        case Merged.MTile(_)    => "タイルの層"
        case Merged.MPoly(_)    => "多角形"
        case Merged.MStatic(_)  => "static layer"
    }

    /// Pass の前のコマの写しの名前か（RenderTarget.historyName で作る名前）。
    def isHistoryName(name: String): Bool = String.endsWith({suffix = RenderTarget.historyName("")}, name)

    // WhyNot: 積む関数を record 1 つで渡さない — 行が描く物の数だけある画面で、行ごとに record の欄を辿る代金が 1 コマに出る。
    def drawRowsFrom(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                     setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                     setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                     skip: String -> Unit \ IO, row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, st, rows, geom, setPipeline, setTexture, setVertices, setValues, skip, row);
            drawRowsFrom(pass, st, rows, geom, setPipeline, setTexture, setVertices, setValues, skip, row + 1, n)
        }

    /// 行 1 つを draw 1 本にし、draw call を GL と同じ物差しで数える（幅か高さが 0 の scissor は draw を出さずに数える）。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                     setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                skip: String -> Unit \ IO, row: Int32): Unit \ IO =
        let kind = rowAt(rows, row, 0);
        let texId = rowAt(rows, row, 3);
        if (texId != 0 and texId == Array.get(7, geom)) skip("描き先と同じ絵を読む行")
        else {
            scissorInto(geom, rowAt(rows, row, 5), rowAt(rows, row, 6), rowAt(rows, row, 7), rowAt(rows, row, 8), rowAt(rows, row, 9));
            let visible = Array.get(12, geom) > 0 and Array.get(13, geom) > 0;
            if (kind == kindPoly()) drawPolyRow(pass, st, rows, geom, setPipeline, setVertices, setValues, row, visible)
            else if (kind == kindTile()) drawTileRow(pass, st, rows, geom, setPipeline, setTexture, setVertices, setValues, skip, row, visible)
            else if (kind == kindStatic()) drawStaticRow(pass, st, rows, geom, setPipeline, setVertices, setValues, row, visible)
            else drawSpriteRow(pass, st, rows, geom, setPipeline, setTexture, setVertices, row, visible)
        };
        ()

    /// スプライトの行: instance の run を draw 1 本（6 頂点 × 体数・firstInstance で行の頭を引く）。
    def drawSpriteRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                      setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                      setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, row: Int32, visible: Bool): Unit \ IO =
        let texId = rowAt(rows, row, 3);
        let blendC = rowAt(rows, row, 4);
        if (visible) {
            bindPipeline(pass, geom, setPipeline, shapeSprite(), blendC);
            discard bindVertices(pass, geom, setVertices, kindSprite(), 0);
            bindTexture(pass, geom, setTexture, texId);
            applyScissor(pass, geom);
            pass.draw(6, rowAt(rows, row, 2), 0, firstInstanceAt(rows, row, Array.get(6, geom)))
        } else ();
        countSpriteDraw(st, texId, rowAt(rows, row, 5), rowAt(rows, row, 6), rowAt(rows, row, 7), rowAt(rows, row, 8), rowAt(rows, row, 9),
                        blendC, false, 1)

    /// 多角形の行: 送った頂点の run を draw 1 本（view は values の頭の identity の view）。
    def drawPolyRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                    setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO, setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO,
                    setValues: (RenderPass, Int32) -> Unit \ IO, row: Int32, visible: Bool): Unit \ IO =
        let blendC = rowAt(rows, row, 4);
        if (visible) {
            bindPipeline(pass, geom, setPipeline, shapePoly(), blendC);
            discard bindVertices(pass, geom, setVertices, kindPoly(), 0);
            bindValues(pass, geom, setValues, rowAt(rows, row, 11));
            applyScissor(pass, geom);
            pass.draw(rowAt(rows, row, 2), 1, Array.get(21, geom) + rowAt(rows, row, 1), 0)
        } else ();
        countPolyDraw(st, rowAt(rows, row, 5), rowAt(rows, row, 6), rowAt(rows, row, 7), rowAt(rows, row, 8), rowAt(rows, row, 9), blendC)

    /// タイルの層の行: 表の instance の buffer を draw 1 本（6 頂点 × タイルの数）。blend はいつも Normal。
    /// タイルの数が buffer に入っている枚数より多ければ、入っている枚数で描く（buffer の外を読む draw は pass ごと誤りになり、コマ全体が消える）。
    def drawTileRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                    setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                     setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                    skip: String -> Unit \ IO, row: Int32, visible: Bool): Unit \ IO =
        let held = if (visible) bindVertices(pass, geom, setVertices, kindTile(), rowAt(rows, row, 10)) else 0;
        let count = Int32.min(rowAt(rows, row, 2), held);
        if (held > 0 and held < rowAt(rows, row, 2)) skip("buffer に入っている枚数より多い分のタイル（入っている枚数だけ描く）") else ();
        if (count > 0) {
            bindPipeline(pass, geom, setPipeline, shapeTile(), 0);
            bindTexture(pass, geom, setTexture, rowAt(rows, row, 3));
            bindValues(pass, geom, setValues, rowAt(rows, row, 11));
            applyScissor(pass, geom);
            pass.draw(6, count, 0, 0)
        } else ();
        countSingleDraw(st, kindTile(), 1)

    /// static layer の範囲の行: 表の頂点の buffer の範囲を draw 1 本（3 頂点未満は描かず数えない）。範囲が buffer の外へ出る分は描かない。
    def drawStaticRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                      setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO, setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO,
                      setValues: (RenderPass, Int32) -> Unit \ IO, row: Int32, visible: Bool): Unit \ IO =
        let count = rowAt(rows, row, 2);
        let first = rowAt(rows, row, 1);
        let held = if (visible and count >= 3) bindVertices(pass, geom, setVertices, kindStatic(), rowAt(rows, row, 10)) else 0;
        let drawn = Int32.min(count, held - first);
        if (drawn >= 3) {
            bindPipeline(pass, geom, setPipeline, shapePoly(), rowAt(rows, row, 4));
            bindValues(pass, geom, setValues, rowAt(rows, row, 11));
            applyScissor(pass, geom);
            pass.draw(drawn, 1, first, 0)
        } else ();
        countSingleDraw(st, kindStatic(), if (count < 3) 0 else 1)

    /// 形と blend の番号の pipeline を積む（前と同じなら積まない）。
    def bindPipeline(pass: RenderPass, geom: Array[Int32, Static], setPipeline: (RenderPass, Int32, Int32) -> Unit \ IO,
                     shape: Int32, blendC: Int32): Unit \ IO =
        let key = shape * 4 + blendC;
        if (Array.get(8, geom) == key) ()
        else {
            setPipeline(pass, shape, blendC);
            Array.put(key, 8, geom)
        }

    /// 絵の番号 texId を group 1 に積む（0 の絵と、前と同じ絵は積まない）。
    def bindTexture(pass: RenderPass, geom: Array[Int32, Static], setTexture: (RenderPass, Int32) -> Unit \ IO, texId: Int32): Unit \ IO =
        if (texId == 0 or Array.get(9, geom) == texId) ()
        else {
            setTexture(pass, texId);
            Array.put(texId, 9, geom)
        }

    /// 頂点の buffer の 0 番を、種類 kind の buffer（番号 buffer）にする（前と同じなら積まない）。返すのは入っている要素の数（表に無い番号なら 0）。
    def bindVertices(pass: RenderPass, geom: Array[Int32, Static], setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO,
                     kind: Int32, buffer: Int32): Int32 \ IO =
        if (Array.get(18, geom) == kind and Array.get(19, geom) == buffer) Array.get(23, geom)
        else {
            let held = setVertices(pass, kind, buffer);
            if (held > 0) {
                Array.put(kind, 18, geom);
                Array.put(buffer, 19, geom);
                Array.put(held, 23, geom)
            } else ();
            held
        }

    /// 頂点の buffer の 1 番を、行の values の先頭（float の番号）の位置にする（前と同じなら積まない）。
    def bindValues(pass: RenderPass, geom: Array[Int32, Static], setValues: (RenderPass, Int32) -> Unit \ IO, at: Int32): Unit \ IO =
        let bytes = Array.get(22, geom) + 4 * at;
        if (Array.get(20, geom) == bytes) ()
        else {
            setValues(pass, bytes);
            Array.put(bytes, 20, geom)
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

    /// geom の 10〜13 の scissor を pass に積む（前に積んだ物と同じなら積まない）。
    def applyScissor(pass: RenderPass, geom: Array[Int32, Static]): Unit \ IO =
        if (isSameScissor(geom)) ()
        else {
            pass.setScissorRect(Array.get(10, geom), Array.get(11, geom), Array.get(12, geom), Array.get(13, geom));
            noteScissor(geom)
        }

    /// geom の 10〜13 の scissor が、前に積んだ物（14〜17）と同じか。
    def isSameScissor(geom: Array[Int32, Static]): Bool \ IO =
        Array.get(10, geom) == Array.get(14, geom) and Array.get(11, geom) == Array.get(15, geom)
            and Array.get(12, geom) == Array.get(16, geom) and Array.get(13, geom) == Array.get(17, geom)

    /// geom の 10〜13 の scissor を、積んだ物として 14〜17 へ写す。
    def noteScissor(geom: Array[Int32, Static]): Unit \ IO =
        Array.put(Array.get(10, geom), 14, geom);
        Array.put(Array.get(11, geom), 15, geom);
        Array.put(Array.get(12, geom), 16, geom);
        Array.put(Array.get(13, geom), 17, geom)

    def putScissor(geom: Array[Int32, Static], x: Int32, y: Int32, w: Int32, h: Int32): Unit \ IO =
        Array.put(x, 10, geom);
        Array.put(y, 11, geom);
        Array.put(w, 12, geom);
        Array.put(h, 13, geom)

    /// v を [0, limit] に収める。
    def within(limit: Int32, v: Int32): Int32 = Int32.max(0, Int32.min(limit, v))

    /// viewport の上の端（描き先の左上が原点）。calcViewport の vpY は GL の左下が原点。
    def viewportTop(fbH: Int32, vpY: Int32, vpH: Int32): Int32 = fbH - vpY - vpH

    /// 黒帯のある画面で design の矩形を塗る箱（Normal・alpha 1 なので結果は色そのもの）。置くのは (0, 0)・大きさは design。
    def clearBox(color: Color): RenderType.Drawable =
        DrawCmd.make({
            texture = "", position = { x = 0.0, y = 0.0 }, scale = { x = 1.0, y = 1.0 },
            rotation = 0.0, color = color, alpha = 1.0, centered = false,
            uvOffset = { x = 0.0, y = 0.0 }, uvScale = { x = 1.0, y = 1.0 },
            zIndex = 0, style = None, clip = None, blend = DrawCmd.BlendMode.Normal, mask = Nil })
}
