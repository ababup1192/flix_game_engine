// RenderFrame.Internal.WebGpuRows — 1 回の renderCommands を、GL と同じ前半（mergedByZ → emitMerged が RenderList を作る）で行にし、
// 行を WebGPU の render pass へ流す。device・pipeline・絵と頂点の buffer の表・instance と頂点と values の buffer は呼ぶ側（WebGpuPaint）が持ち、関数の record で渡す。
// 描くのはスプライト・字・箱（mask つきを含む）・多角形・タイルの層・static layer・面（mask つきを含む）。3D の場面を貼る行は z の位置まで並べ、描かずに知らせる（skip）。
pub mod RenderFrame.Internal.WebGpuRows {
    import fge.webgpu.RenderPass
    import java.nio.FloatBuffer
    use RenderFrame.{addCountsTo, closeRuns, countPolyDraw, countSceneRow, countSingleDraw, countSpriteDraw, emitMerged, mergedByZ, newRunState,
                     polyVertCap, spriteCaps, surfaceMaskCap, upsideDownTargetsOf, usesStencil, writeInstAt}
    use RenderFrame.Internal.RenderList.{DepthStencil, PassSpec, glViewportOf, hasLetterbox, kindMask, kindPoly, kindScene3d, kindSprite, kindStatic, kindSurface,
                                         kindTile, newRenderList, nextInstanceOf, nextVertexOf, readFields, readsOf, rowAt, rowCountOf, rowsOf, screenClearColorOf,
                                         stencilRefOf, targetTextureOf, valueCountOf, valuesOf}

    /// 描き先（texture）は上下逆に格納しない（行 0 が上）。
    pub def targetUpsideDown(): Bool = false

    /// pipeline の形（setPipeline に渡す番号）。
    pub def shapeSprite(): Int32 = 0
    pub def shapePoly(): Int32 = 1
    pub def shapeTile(): Int32 = 2

    /// pipeline の stencil の使い方（setPipeline に渡す番号）。None = pass が stencil を持たない・Keep = 持つが比べず書かない・
    /// Write = 色を変えず stencil へ比べる値を書く（mask の多角形）・Equal = stencil が比べる値の画素だけ描く（mask の内側のスプライト）。
    pub def stencilNone(): Int32 = 0
    pub def stencilKeep(): Int32 = 1
    pub def stencilWrite(): Int32 = 2
    pub def stencilEqual(): Int32 = 3

    /// 1 回の renderCommands を pass 1 つへ流す。
    /// cfg の欄:
    ///   sprites・tileMaps・polygons・staticRanges・registry = 描き物と絵の表（GL の FrameArgs と同じ物）・designW/H = 射影の寸
    ///   sceneZs = 3D の場面の z（i 番目 = 番号 i の場面。GL の Scene3dRenderer.Prepared#zIndexes と同じ並び）
    ///   pass = 描き先と、その始末・viewport（描き先と同じ絵を読む行は描かずに知らせる）
    ///   instancesFor(n)・verticesFor(n) = n 体・n 頂点ぶん書ける入れ物（呼ぶ側の LITTLE_ENDIAN の ByteBuffer の float の見方）
    ///   upload(体数, 頂点数, values, values の数) = 入れ物の頭と values を GPU へ送る。返すのは送った位置（instance の番号, 頂点の番号, values の bytes）
    ///   openPass(pass) = pass の色の始末と depthStencil で render pass を開く（stencil は 0 で clear。instance の buffer を頂点の buffer の 0 番に付けておく）
    ///   setPipeline(形, blend の番号, stencil の使い方)・setTexture(絵の番号) = 行の鍵を pass に積む（0 の絵は呼ばない）
    ///   setVertices(種類, buffer の番号) = 頂点の buffer の 0 番を、その種類の buffer にする（スプライト = instance・多角形 = 頂点・タイル と static = 表の buffer・
    ///     kindMask = stencil を 0 に戻す design の全面の 6 頂点）。
    ///     返すのはその buffer に入っている要素の数（タイルは枚数・static は頂点の数）。表に無い番号なら 0（その行は描かずに数える）
    ///   setValues(bytes) = 頂点の buffer の 1 番を、values の buffer の bytes の位置にする
    ///   drawSurface(pass, rows, 行, reads, stencil の使い方, 値の bytes) = 面の行の面を塗る（pipeline と group 0・1 を付けて draw 1 本。
    ///     描いた後は group 0 を射影・group 1 を空の絵に戻す）。値の bytes = 行の values の先頭の、values の buffer の中の位置
    ///   skip(名前) = 描かない種類を知らせる（名前ごとに 1 回にまとめるのは呼ぶ側）
    pub def renderFrame(cfg: {
        sprites = List[RenderType.Drawable],
        tileMaps = List[RenderType.TileMapRenderCmd],
        polygons = List[RenderType.PolygonCmd],
        staticRanges = List[RenderStatic.Range],
        surfaces = List[DrawCmd.SurfaceRenderCmd],
        sceneZs = Vector[Int32],
        registry = RenderAsset.TextureRegistry,
        designW = Float64,
        designH = Float64,
        pass = PassSpec,
        texWarnLog = Ref[Set[String], Static],
        drawCounts = RenderDrawCounts.Holder,
        instancesFor = Int32 -> FloatBuffer \ IO,
        verticesFor = Int32 -> FloatBuffer \ IO,
        upload = (Int32, Int32, Array[Float32, Static], Int32) -> (Int32, Int32, Int32) \ IO,
        openPass = PassSpec -> RenderPass \ IO,
        setPipeline = (RenderPass, Int32, Int32, Int32) -> Unit \ IO,
        setTexture = (RenderPass, Int32) -> Unit \ IO,
        setVertices = (RenderPass, Int32, Int32) -> Int32 \ IO,
        setValues = (RenderPass, Int32) -> Unit \ IO,
        drawSurface = (RenderPass, Array[Int32, Static], Int32, Array[Int32, Static], Int32, Int32) -> Unit \ IO,
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
            let (spriteCount, maskVerts) = spriteCaps(cfg#sprites);
            let instances = cfg#instancesFor(spriteCount + 1);
            let st = newRunState(cfg#drawCounts);
            let list = newRenderList(instances, cfg#verticesFor(Int32.max(3, polyVertCap(cfg#polygons) + maskVerts + surfaceMaskCap(cfg#surfaces))));
            // WhyNot: 並べた 1 個ごとに cfg の欄を読まない — 開いた record の欄は読むたびに欄の列を辿り、2 万個の画面ではそれだけで 1 コマに出る。
            let registry = cfg#registry;
            let warnLog = cfg#texWarnLog;
            let skip = cfg#skip;
            // WhyNot: 描き先の表の名前を渡さない — targetUpsideDown が偽なので upsideDownTargetsOf は表を引かない。
            let upsideDown = upsideDownTargetsOf(targetUpsideDown(), () -> Set.empty());
            emitMerged(st, list, scaleX, scaleY, registry, upsideDown, warnLog,
                       mergedByZ(cfg#tileMaps, cfg#sprites, cfg#polygons, cfg#staticRanges, cfg#surfaces, cfg#sceneZs));
            closeRuns(st, list);
            let used = nextInstanceOf(list);
            if (letterboxed) writeInstAt(instances, used, 0.0, 0.0, cfg#designW, cfg#designH,
                                         clearBox(screenClearColorOf(spec) |> Option.getWithDefault({ r = 0.0, g = 0.0, b = 0.0 })), false, false) else ();
            let sent = if (letterboxed) used + 1 else used;
            let (base, vertexBase, valuesBase) = cfg#upload(sent, nextVertexOf(list), valuesOf(list), valueCountOf(list));
            // WhyNot: いつも stencil つきの pass にしない — mask を使わない画面まで stencil の attachment のメモリと clear・書き出しを払う。
            let stencil = usesStencil(st);
            let pass = cfg#openPass(if (stencil) { depthStencil = DepthStencil.DepthAndStencil | spec } else spec);
            let (vpX, vpY, _, _) = vp;
            pass.setViewport(Int32.toFloat64(vpX), Int32.toFloat64(viewportTop(fbH, vpY, vpH)),
                             Int32.toFloat64(vpW), Int32.toFloat64(vpH), 0.0, 1.0);
            let setPipeline = cfg#setPipeline;
            let geom = geometryOf(fbW, fbH, vp, (base, vertexBase, valuesBase), targetTextureOf(spec),
                                  if (stencil) stencilKeep() else stencilNone());
            if (letterboxed) {
                bindPipeline(pass, geom, setPipeline, shapeSprite(), 0);
                putScissor(geom, 0, 0, fbW, fbH);
                applyScissor(pass, geom);
                pass.draw(6, 1, 0, base + used)
            } else ();
            drawRowsFrom(pass, st, rowsOf(list), readsOf(list), geom, setPipeline, cfg#setTexture, cfg#setVertices, cfg#setValues, cfg#drawSurface, skip, warnLog,
                         0, rowCountOf(list));
            pass.end();
            addCountsTo(cfg#drawCounts, st)
        }

    // ── 行を流す間ずっと同じ値の入れ物（Int32 の配列 1 本）──
    // 0=描き先の幅 1=描き先の高さ 2-5=viewport (x, y, 幅, 高さ・GL の左下原点) 6=行の instance を送った位置 7=描き先と同じ絵の番号
    // 8=今積んである pipeline（(形 × 4 + blend) × 4 + stencil の使い方） 9=今積んである絵（どちらも -1 = まだ積んでいない） 10-13=今の行の scissor (x, y, 幅, 高さ)
    // 14-17=今積んである scissor (x, y, 幅, 高さ・幅 -1 = まだ積んでいない) 18=頂点の buffer の 0 番の種類（kind*） 19=その buffer の番号
    // 20=頂点の buffer の 1 番の values の bytes（-1 = まだ積んでいない） 21=行の頂点を送った位置 22=values を送った位置（bytes）
    // 23=頂点の buffer の 0 番に入っている要素の数 24=mask でない行の stencil の使い方（stencilNone か stencilKeep）
    // 25=pass を開いた後に stencil へ書いたか（1 = 書いた） 26=pass に積んである stencil の比べる値
    // WhyNot: record や組で持ち回らない — 行が描く物の数だけある画面で、行ごとに record の欄を辿る代金と組の割り当てが 1 コマに出る（RenderFrame の st と同じ形）。
    /// sent = 送った位置（instance の番号, 頂点の番号, values の bytes）・readsForbidden = 描き先と同じ絵の番号・stencil = mask でない行の stencil の使い方。
    def geometryOf(fbW: Int32, fbH: Int32, vp: (Int32, Int32, Int32, Int32), sent: (Int32, Int32, Int32), readsForbidden: Int32,
                   stencil: Int32): Array[Int32, Static] \ IO =
        let (vpX, vpY, vpW, vpH) = vp;
        let (base, vertexBase, valuesBase) = sent;
        Array#{fbW, fbH, vpX, vpY, vpW, vpH, base, readsForbidden, -1, -1, 0, 0, 0, 0, 0, 0, -1, 0, kindSprite(), 0, -1,
               vertexBase, valuesBase, Int32.maxValue(), stencil, 0, 0} @ Static

    // WhyNot: 積む関数を record 1 つで渡さない — 行が描く物の数だけある画面で、行ごとに record の欄を辿る代金が 1 コマに出る。
    def drawRowsFrom(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], reads: Array[Int32, Static], geom: Array[Int32, Static],
                     setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                     setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                     drawSurface: (RenderPass, Array[Int32, Static], Int32, Array[Int32, Static], Int32, Int32) -> Unit \ IO,
                     skip: String -> Unit \ IO, warnLog: Ref[Set[String], Static], row: Int32, n: Int32): Unit \ IO =
        if (row >= n) ()
        else {
            drawRow(pass, st, rows, reads, geom, setPipeline, setTexture, setVertices, setValues, drawSurface, skip, warnLog, row);
            drawRowsFrom(pass, st, rows, reads, geom, setPipeline, setTexture, setVertices, setValues, drawSurface, skip, warnLog, row + 1, n)
        }

    /// 行 1 つを draw 1 本にし、draw call を GL と同じ物差しで数える（幅か高さが 0 の scissor は draw を出さずに数える）。
    // WhyNot: 末尾を呼び出しで終えない — 行が描く物の数だけある画面で drawRowsFrom のループが JIT から外れる（docs/performance.md の 13 節）。
    @DontInline
    def drawRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], reads: Array[Int32, Static], geom: Array[Int32, Static],
                setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                drawSurface: (RenderPass, Array[Int32, Static], Int32, Array[Int32, Static], Int32, Int32) -> Unit \ IO,
                skip: String -> Unit \ IO, warnLog: Ref[Set[String], Static], row: Int32): Unit \ IO =
        let kind = rowAt(rows, row, 0);
        let texId = rowAt(rows, row, 3);
        // 描かずに飛ばす行でも戻す — 戻さずに飛ばすと、次の値の mask が前に書いた同じ値と重なる。
        if (stencilRefOf(rows, row) == 1 and Array.get(25, geom) == 1) resetStencil(pass, geom, setPipeline, setVertices, setValues) else ();
        if (texId != 0 and texId == Array.get(7, geom)) skip("描き先と同じ絵を読む行")
        else {
            scissorInto(geom, rowAt(rows, row, 5), rowAt(rows, row, 6), rowAt(rows, row, 7), rowAt(rows, row, 8), rowAt(rows, row, 9));
            let visible = Array.get(12, geom) > 0 and Array.get(13, geom) > 0;
            if (kind == kindPoly()) drawPolyRow(pass, st, rows, geom, setPipeline, setVertices, setValues, row, visible)
            else if (kind == kindTile()) drawTileRow(pass, st, rows, geom, setPipeline, setTexture, setVertices, setValues, warnLog, row, visible)
            else if (kind == kindStatic()) drawStaticRow(pass, st, rows, geom, setPipeline, setVertices, setValues, row, visible)
            else if (kind == kindMask()) drawMaskRow(pass, st, rows, geom, setPipeline, setTexture, setVertices, setValues, row, visible)
            else if (kind == kindScene3d()) drawSceneRow(st, skip)
            else if (kind == kindSurface()) drawSurfaceRow(pass, st, rows, reads, geom, setPipeline, setVertices, setValues, drawSurface, skip, row)
            else drawSpriteRow(pass, st, rows, geom, setPipeline, setTexture, setVertices, row, visible)
        };
        ()

    /// スプライトの行: instance の run を draw 1 本（6 頂点 × 体数・firstInstance で行の頭を引く）。
    def drawSpriteRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                      setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
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

    /// mask つきスプライトの行: mask の三角形を stencil へ比べる値で書き（色は変えない）、stencil がその値の画素だけ 1 体を描く（draw 2 本）。
    /// 値が 1 の行の前で stencil を 0 に戻すのは drawRow（pass を開いた後に stencil へ書いた時だけ。開いた時は 0 で clear 済み）。
    /// 値が 0（mask が 3 頂点未満）なら stencil を使わずに 1 体を描く。
    def drawMaskRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                    setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                    setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                    row: Int32, visible: Bool): Unit \ IO =
        let texId = rowAt(rows, row, 3);
        let blendC = rowAt(rows, row, 4);
        let ref = rowAt(rows, row, 11);
        if (visible and ref > 0) {
            bindStencilRef(pass, geom, ref);
            bindStencilPipeline(pass, geom, setPipeline, shapePoly(), 0, stencilWrite());
            discard bindVertices(pass, geom, setVertices, kindPoly(), 0);
            bindValues(pass, geom, setValues, 0);
            applyScissor(pass, geom);
            pass.draw(rowAt(rows, row, 2), 1, Array.get(21, geom) + rowAt(rows, row, 10), 0);
            Array.put(1, 25, geom)
        } else ();
        if (visible) {
            bindStencilPipeline(pass, geom, setPipeline, shapeSprite(), blendC, if (ref > 0) stencilEqual() else Array.get(24, geom));
            discard bindVertices(pass, geom, setVertices, kindSprite(), 0);
            bindTexture(pass, geom, setTexture, texId);
            applyScissor(pass, geom);
            pass.draw(6, 1, 0, firstInstanceAt(rows, row, Array.get(6, geom)))
        } else ();
        countSpriteDraw(st, texId, rowAt(rows, row, 5), rowAt(rows, row, 6), rowAt(rows, row, 7), rowAt(rows, row, 8), rowAt(rows, row, 9),
                        blendC, true, if (ref > 0) 2 else 1)

    /// 面の行: 値が 0 でなければ mask の三角形を stencil へ比べる値で書き（色は変えない）、stencil がその値の画素だけ面を塗る（draw 2 本）。
    /// 値が 1 の行の前で stencil を 0 に戻すのは drawRow。読む絵に描き先と同じ絵があれば描かずに知らせる（WebGPU は描き先を読む draw で pass ごと誤りにする）。
    /// 面の pipeline と group 0・1 を積むのは drawSurface なので、描いた後は積んである pipeline と絵の控えを捨てる。
    def drawSurfaceRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], reads: Array[Int32, Static], geom: Array[Int32, Static],
                       setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO,
                       setValues: (RenderPass, Int32) -> Unit \ IO,
                       drawSurface: (RenderPass, Array[Int32, Static], Int32, Array[Int32, Static], Int32, Int32) -> Unit \ IO,
                       skip: String -> Unit \ IO, row: Int32): Unit \ IO =
        let ref = rowAt(rows, row, 10);
        if (readsTexture(reads, rowAt(rows, row, 6), rowAt(rows, row, 7), Array.get(7, geom))) skip("描き先と同じ絵を読む行")
        else {
            if (ref > 0) {
                bindStencilRef(pass, geom, ref);
                bindStencilPipeline(pass, geom, setPipeline, shapePoly(), 0, stencilWrite());
                discard bindVertices(pass, geom, setVertices, kindPoly(), 0);
                bindValues(pass, geom, setValues, 0);
                applyScissor(pass, geom);
                pass.draw(rowAt(rows, row, 9), 1, Array.get(21, geom) + rowAt(rows, row, 8), 0);
                Array.put(1, 25, geom)
            } else ();
            applyScissor(pass, geom);
            drawSurface(pass, rows, row, reads, if (ref > 0) stencilEqual() else Array.get(24, geom), Array.get(22, geom) + 4 * rowAt(rows, row, 11));
            Array.put(-1, 8, geom);
            Array.put(-1, 9, geom)
        };
        countSingleDraw(st, kindSurface(), if (ref > 0) 2 else 1)

    /// reads の [first, first + count) の絵に texId（0 でない）があるか。
    def readsTexture(reads: Array[Int32, Static], first: Int32, count: Int32, texId: Int32): Bool \ IO =
        if (count <= 0 or texId == 0) false
        else if (Array.get(first * readFields(), reads) == texId) true
        else readsTexture(reads, first + 1, count - 1, texId)

    /// 3D の場面を貼る行: まだ描かない（知らせるだけ）。数えは GL と同じく、次の 2D の draw call を kind で切る。
    // WhyNot: 2D の pass の途中で閉じて場面の pass を開かない — 2D の pass を閉じて開き直すと、viewport・積んだ pipeline と buffer の控え・黒帯の箱と
    //   stencil を張り直す道が要り、標本つきの描き先は閉じるたびに resolve する。V2 では場面を 2D の pass の前に自分の texture へ描き、この行で貼る（plans/engine-webgpu.md の 5.4）。
    def drawSceneRow(st: Array[Int32, Static], skip: String -> Unit \ IO): Unit \ IO =
        skip("3D の場面");
        countSceneRow(st)

    /// stencil を全部 0 に戻す: design の全面の 6 頂点を、stencil へ値 0 を書く pipeline で描く。scissor は描き先の全面にし、行の scissor は次の applyScissor が戻す。
    // WhyNot: pass を閉じて stencil を clear して開き直さない — 開き直すと viewport・積んだ pipeline と buffer の控え・黒帯の箱を全部張り直す道が要り、
    //   標本つきの描き先は閉じるたびに resolve する。
    def resetStencil(pass: RenderPass, geom: Array[Int32, Static], setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO,
                     setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO): Unit \ IO =
        let rowScissor = (Array.get(10, geom), Array.get(11, geom), Array.get(12, geom), Array.get(13, geom));
        putScissor(geom, 0, 0, Array.get(0, geom), Array.get(1, geom));
        applyScissor(pass, geom);
        bindStencilRef(pass, geom, 0);
        bindStencilPipeline(pass, geom, setPipeline, shapePoly(), 0, stencilWrite());
        let count = bindVertices(pass, geom, setVertices, kindMask(), 0);
        bindValues(pass, geom, setValues, 0);
        pass.draw(count, 1, 0, 0);
        Array.put(0, 25, geom);
        let (x, y, w, h) = rowScissor;
        putScissor(geom, x, y, w, h)

    /// 多角形の行: 送った頂点の run を draw 1 本（view は values の頭の identity の view）。
    def drawPolyRow(pass: RenderPass, st: Array[Int32, Static], rows: Array[Int32, Static], geom: Array[Int32, Static],
                    setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO,
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
                    setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setTexture: (RenderPass, Int32) -> Unit \ IO,
                     setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO, setValues: (RenderPass, Int32) -> Unit \ IO,
                    warnLog: Ref[Set[String], Static], row: Int32, visible: Bool): Unit \ IO =
        let held = if (visible) bindVertices(pass, geom, setVertices, kindTile(), rowAt(rows, row, 10)) else 0;
        let count = Int32.min(rowAt(rows, row, 2), held);
        if (held > 0 and held < rowAt(rows, row, 2)) warnTilesOverBuffer(warnLog) else ();
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
                      setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO, setVertices: (RenderPass, Int32, Int32) -> Int32 \ IO,
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

    /// タイルの数が buffer に入っている枚数より多かった事を、初めの 1 回だけ知らせる（毎コマ通る所なので、控えは texWarnLog に置く）。
    def warnTilesOverBuffer(warnLog: Ref[Set[String], Static]): Unit \ IO =
        let key = "webgpu: tiles over buffer";
        if (Set.memberOf(key, Ref.get(warnLog))) ()
        else {
            Ref.put(Set.insert(key, Ref.get(warnLog)), warnLog);
            Log.fellBack("webgpu", "タイルの層", "buffer に入っている枚数", "TileMapRenderCmd の tileCount が buffer に入っている枚数より多い")
        }

    /// 形と blend の番号の pipeline を、mask でない行の stencil の使い方で積む（前と同じなら積まない）。
    def bindPipeline(pass: RenderPass, geom: Array[Int32, Static], setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO,
                     shape: Int32, blendC: Int32): Unit \ IO =
        bindStencilPipeline(pass, geom, setPipeline, shape, blendC, Array.get(24, geom))

    /// 形と blend の番号と stencil の使い方の pipeline を積む（前と同じなら積まない）。
    def bindStencilPipeline(pass: RenderPass, geom: Array[Int32, Static], setPipeline: (RenderPass, Int32, Int32, Int32) -> Unit \ IO,
                         shape: Int32, blendC: Int32, stencil: Int32): Unit \ IO =
        let key = (shape * 4 + blendC) * 4 + stencil;
        if (Array.get(8, geom) == key) ()
        else {
            setPipeline(pass, shape, blendC, stencil);
            Array.put(key, 8, geom)
        }

    /// pass の stencil の比べる値を ref にする（前と同じなら積まない）。
    def bindStencilRef(pass: RenderPass, geom: Array[Int32, Static], ref: Int32): Unit \ IO =
        if (Array.get(26, geom) == ref) ()
        else {
            pass.setStencilReference(ref);
            Array.put(ref, 26, geom)
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
