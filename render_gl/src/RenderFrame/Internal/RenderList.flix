// RenderFrame.Internal.RenderList — 1 回の renderCommands で描く行の列（GL と WebGPU が同じ物を流す）と、その行を描く pass の指定。
// 1 行 = 物の集まりを 1 回描く（種類はスプライト・字・箱の run・多角形の run・タイルの層・static layer の範囲・mask つきスプライト 1 体・面 1 枚・3D の場面を貼る所）。
// GL の物（program・VAO・buffer）を持たず、絵と頂点の buffer は backend の表の番号（GL の backend ではテクスチャ・VAO の番号）で持つ。
// rows の頭: 0=行の数 1=次に書く instance の番号 2=次に書く頂点の番号。その後ろに 1 行 rowStride() 個（欄の番号は col* の def・読むのは名前の読み出し口）:
//   0=種類（kindCodeOf） 1=先頭（スプライトは instance・多角形と static は頂点の番号） 2=数（体数・頂点数・タイルの数）
//   3=絵の番号（0 = 絵の無い箱・多角形と static は 0） 4=blend 5=clip有無 6-9=clip矩形（viewport の左上原点の px）
//   10=頂点の buffer の番号（タイルの instance・static の頂点。backend の表の番号。ほかは 0） 11=values の先頭（draw ごとの値。スプライトは 0）
//   mask つきスプライト（ListRowKind.Mask）だけ欄の意味が違う: 1=instance の番号（1 体） 2=mask の頂点の数（三角形にほどいた物・3 未満なら 0） 10=mask の先頭の頂点の番号
//   11=stencil に書いて比べる値（nextMaskRef が決める・0 = mask が 3 頂点未満で stencil を使わずに描く）。mask の頂点は values の頭の identity の view で描く。
//   3D の場面を貼る行（ListRowKind.Scene3d）: 1=場面の番号（Scene3dRenderer.Prepared の番号）。ほかの欄は 0。
//   面の行（ListRowKind.Surface・ShaderDoc の面 1 枚）: 1=program（backend の表の番号） 2=values に書いた値の数（rect 4・time・alpha・params の順） 3=0 4=blend
//   5=0（面は clip を持たない） 6=reads の先頭（絵の組の 1 つ目の番号） 7=絵の数 8=mask の先頭の頂点の番号 9=mask の頂点の数（3 未満なら 0）
//   10=stencil に書いて比べる値（nextMaskRef・0 = mask が無い） 11=values の先頭（surfaceValueAlign() の倍数）。
// reads は面が読む絵の組（1 つ readFields() 個: 0=絵の番号（無い名前は 0） 1=補間（0 = Nearest・1 = Linear） 2=上下逆に格納された描き先なら 1）。
// instances は 1 体 instanceFloats() 個（RenderFrame.writeInstAt の並び）。スプライトの行の値は instances の [先頭 × 38, (先頭 + 体数) × 38)。
// vertices は多角形の頂点（1 頂点 6 個・RenderSprite.writePolyVerts の並び）。instances も vertices も backend が貸す入れ物で、GPU へそのまま送る。
// values は draw ごとの値（front-end の並び。GL は uniform へ差し、WebGPU は詰め直さずに stride 0 の頂点の buffer として読む）。頭の viewValueFloats() 個はいつも identity の view（多角形の行が指す）。
//   多角形と static は view 6 個（viewOffset x・y・viewScale x・y・halfDesign x・y）・タイルは 8 個（position x・y・tileSize・tileScale x・y・color r・g・b）。
// 1 回の renderCommands は (PassSpec, RenderList) の組で描く。2D だけの画面では組は 1 つ。
// WhyNot: 行ごとに record や enum を作らない — 絵が 1 個ごとに替わると行は描く物の数だけでき、その割り当てが 1 コマに乗る。
// WhyNot: タイルと static の値を行の欄へ詰めない — Float32 を Int32 の欄へ入れると読む所でほどく手間が backend 2 つに要る。
// WhyNot: RenderFrame の兄弟のモジュールに出さない — 兄弟の mod からは RenderFrame の pub でない関数（run の状態・数え）を呼べず、pub に開くことになる。
pub mod RenderFrame.Internal.RenderList {
    import java.nio.FloatBuffer

    pub type alias RenderList = {
        instances = FloatBuffer,
        vertices = FloatBuffer,
        rows = Array[Array[Int32, Static], Static],
        values = Array[Array[Float32, Static], Static],
        valueCount = Array[Int32, Static],
        reads = Array[Array[Int32, Static], Static],
        readCount = Array[Int32, Static]
    }

    /// instance の 1 体の float の数。
    pub def instanceFloats(): Int32 = 38

    /// 多角形の 1 頂点の float の数。
    pub def vertexFloats(): Int32 = 6

    /// 行の種類（欄 0）。StaticRange = static layer の範囲・Mask = mask つきスプライト 1 体（draw call は Sprite で数える）・Scene3d = 3D の場面を貼る所・Surface = ShaderDoc の面 1 枚。
    pub enum ListRowKind with Eq, ToString {
        case Sprite
        case Poly
        case Tile
        case StaticRange
        case Surface
        case Scene3d
        case Mask
    }

    /// 行 row の種類。
    pub def kindAt(rows: Array[Int32, Static], row: Int32): ListRowKind \ IO = kindOfCode(rowAt(rows, row, colKind()))

    /// 欄 0 の番号 → 種類（範囲の外は書く側の誤り）。
    pub def kindOfCode(code: Int32): ListRowKind = match code {
        case 1 => ListRowKind.Sprite
        case 2 => ListRowKind.Poly
        case 3 => ListRowKind.Tile
        case 4 => ListRowKind.StaticRange
        case 5 => ListRowKind.Surface
        case 6 => ListRowKind.Scene3d
        case 7 => ListRowKind.Mask
        case _ => bug!("RenderList: 行の種類の番号 ${code} は無い")
    }

    /// 種類 → 欄 0 の番号。
    pub def kindCodeOf(kind: ListRowKind): Int32 = match kind {
        case ListRowKind.Sprite  => 1
        case ListRowKind.Poly    => 2
        case ListRowKind.Tile    => 3
        case ListRowKind.StaticRange  => 4
        case ListRowKind.Surface => 5
        case ListRowKind.Scene3d => 6
        case ListRowKind.Mask    => 7
    }

    /// draw call の数え（RenderFrame の run の状態の「前の種類」）の番号。mask つきスプライトはスプライトと同じ番号で数える。
    pub def drawCountCodeOf(kind: ListRowKind): Int32 = match kind {
        case ListRowKind.Mask => kindCodeOf(ListRowKind.Sprite)
        case _                => kindCodeOf(kind)
    }

    def rowStride(): Int32 = 12

    // 欄の番号（並びはこのファイルの頭のコメント）。書く側（putRow）と読み出し口の両方がここを使う。
    def colKind(): Int32 = 0
    def colFirst(): Int32 = 1
    def colCount(): Int32 = 2
    def colTexture(): Int32 = 3
    def colBlend(): Int32 = 4
    def colClip(): Int32 = 5
    def colClipX0(): Int32 = 6
    def colClipY0(): Int32 = 7
    def colClipX1(): Int32 = 8
    def colClipY1(): Int32 = 9
    def colBuffer(): Int32 = 10
    def colValues(): Int32 = 11

    def rowsHead(): Int32 = 3

    /// values の 1 つの view（多角形と static）の float の数。
    pub def viewValueFloats(): Int32 = 6

    /// values の 1 つのタイルの層の float の数。
    pub def tileValueFloats(): Int32 = 8

    /// 面の値を置く values の位置と、面 1 枚に取る values の数の刻み（float の数）。
    // WhyNot: 面の値を詰めて置かない — WebGPU の backend は面の値を uniform の buffer として読み、bind する位置は 256 バイト
    //   （core の minUniformBufferOffsetAlignment の上限）の倍数でないといけない。dynamic offset で 1 つの bind group を使い回す道は
    //   render_gl/java の WebGpu の口（setBindGroup の offset）が要る。
    pub def surfaceValueAlign(): Int32 = 64

    /// 値を count 個書いた面の行が values に取っている数（surfaceValueAlign の倍数。読む側はこの数まで読んでよい）。
    pub def surfaceValuesTaken(count: Int32): Int32 =
        Int32.max(surfaceValueAlign(), (count + surfaceValueAlign() - 1) / surfaceValueAlign() * surfaceValueAlign())

    /// reads の 1 つの絵の Int32 の数。
    pub def readFields(): Int32 = 3

    /// 空の列。instances と vertices は backend が貸す入れ物（描く物の数ぶん書ける大きさ）。
    pub def newRenderList(instances: FloatBuffer, vertices: FloatBuffer): RenderList \ IO =
        let list = { instances = instances, vertices = vertices, rows = Array#{Array.empty(Static, rowsHead() + 16 * rowStride())} @ Static,
                     values = Array#{Array.empty(Static, 64)} @ Static, valueCount = Array#{0} @ Static,
                     reads = Array#{Array.empty(Static, 4 * readFields())} @ Static, readCount = Array#{0} @ Static };
        clearRenderList(list);
        list

    pub def rowCountOf(list: RenderList): Int32 \ IO = Array.get(0, rowsOf(list))

    pub def nextInstanceOf(list: RenderList): Int32 \ IO = Array.get(1, rowsOf(list))

    pub def nextVertexOf(list: RenderList): Int32 \ IO = Array.get(2, rowsOf(list))

    /// values（広げると差し替わるので、行を足した後は取り直す）。
    pub def valuesOf(list: RenderList): Array[Float32, Static] \ IO = Array.get(0, list#values)

    /// values に書いた float の数（頭の identity の view を含む）。
    pub def valueCountOf(list: RenderList): Int32 \ IO = Array.get(0, list#valueCount)

    /// 面の絵の組の配列（広げると差し替わるので、行を足した後は取り直す）。
    pub def readsOf(list: RenderList): Array[Int32, Static] \ IO = Array.get(0, list#reads)

    /// 頭と行を並べた Int32 の配列（広げると差し替わるので、行を足した後は取り直す）。
    pub def rowsOf(list: RenderList): Array[Int32, Static] \ IO = Array.get(0, list#rows)

    /// 行 row の欄 col（並びはこのファイルの頭のコメント）。外からは名前の読み出し口で読む。
    def rowAt(rows: Array[Int32, Static], row: Int32, col: Int32): Int32 \ IO =
        Array.get(rowsHead() + row * rowStride() + col, rows)

    // ── 読み出し口（スプライト・多角形・タイル・static の行。mask の行も 1〜9 の意味は同じ） ──
    // WhyNot: 違う種類の欄を同じ名前で読ませない — 面の行の欄 6〜11 は reads・mask・stencil・values で、clip ではない。種類ごとの口は頭に種類の名前を付ける。

    /// 行 row の先頭（スプライトは instance・多角形と static は頂点の番号）。
    pub def firstAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colFirst())

    /// 行 row の数（体数・頂点数・タイルの数）。
    pub def countAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colCount())

    /// 行 row の絵の番号（0 = 絵の無い箱・多角形と static は 0）。
    pub def textureAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colTexture())

    /// 行 row の blend（RenderFrame.blendCode の番号。面の行も同じ欄）。
    pub def blendAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colBlend())

    /// 行 row が clip を持つか（1 = 持つ）と、その矩形（viewport の左上原点の px）。clip を持つのはスプライト・多角形・static・mask の行。
    pub def clipFlagAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClip())
    pub def clipX0At(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipX0())
    pub def clipY0At(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipY0())
    pub def clipX1At(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipX1())
    pub def clipY1At(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipY1())

    /// 種類 kind が clip の欄を持つか（持たないタイル・面・3D の場面の行は、描き先の全面に描く）。
    pub def hasClipColumns(kind: ListRowKind): Bool = match kind {
        case ListRowKind.Sprite  => true
        case ListRowKind.Poly    => true
        case ListRowKind.StaticRange  => true
        case ListRowKind.Mask    => true
        case ListRowKind.Tile    => false
        case ListRowKind.Surface => false
        case ListRowKind.Scene3d => false
    }

    /// 種類 kind が欄 3 に絵の番号を持つか（スプライト・タイル・mask の行）。
    pub def hasTextureColumn(kind: ListRowKind): Bool = match kind {
        case ListRowKind.Sprite  => true
        case ListRowKind.Tile    => true
        case ListRowKind.Mask    => true
        case ListRowKind.Poly    => false
        case ListRowKind.StaticRange  => false
        case ListRowKind.Surface => false
        case ListRowKind.Scene3d => false
    }

    /// タイルと static の行の頂点の buffer の番号（backend の表の番号）。
    pub def bufferAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colBuffer())

    /// 行 row の values の先頭（draw ごとの値。スプライトは 0・面の行も同じ欄）。
    pub def valuesAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colValues())

    // ── mask つきスプライトの行 ──

    /// mask の行の 1 体の instance の番号。
    pub def maskInstanceAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colFirst())

    /// mask の行の mask の頂点の数（3 未満なら 0）。
    pub def maskVertexCountAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colCount())

    /// mask の行の mask の先頭の頂点の番号。
    pub def maskFirstVertexAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colBuffer())

    /// mask の行の stencil に書いて比べる値（0 = stencil を使わない）。
    pub def maskStencilRefAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colValues())

    // ── 面の行 ──

    /// 面の行の program（backend の表の番号）。
    pub def surfaceProgramAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colFirst())

    /// 面の行が values に書いた値の数（rect 4・time・alpha・params の順）。
    pub def surfaceValueCountAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colCount())

    /// 面の行の reads の先頭（絵の組の 1 つ目の番号）と絵の数。
    pub def surfaceFirstReadAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipX0())
    pub def surfaceReadCountAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipY0())

    /// 面の行の mask の先頭の頂点の番号と頂点の数（3 未満なら 0）。
    pub def surfaceMaskFirstAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipX1())
    pub def surfaceMaskCountAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colClipY1())

    /// 面の行の stencil に書いて比べる値（0 = mask が無い）。
    pub def surfaceStencilAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colBuffer())

    // ── 3D の場面の行 ──

    /// 3D の場面の行の場面の番号（Scene3dRenderer.Prepared の番号）。
    pub def sceneIndexAt(rows: Array[Int32, Static], row: Int32): Int32 \ IO = rowAt(rows, row, colFirst())

    /// 行を全部捨てる（instances と頂点の書く位置も頭へ戻し、values は頭の identity の view だけにする）。
    pub def clearRenderList(list: RenderList): Unit \ IO =
        let rows = Array.get(0, list#rows);
        Array.put(0, 0, rows);
        Array.put(0, 1, rows);
        Array.put(0, 2, rows);
        let values = Array.get(0, list#values);
        Array.put(0.0f32, 0, values);
        Array.put(0.0f32, 1, values);
        Array.put(1.0f32, 2, values);
        Array.put(1.0f32, 3, values);
        Array.put(0.0f32, 4, values);
        Array.put(0.0f32, 5, values);
        Array.put(viewValueFloats(), 0, list#valueCount);
        Array.put(0, 0, list#readCount)

    /// n 個書ける values と、書き始める位置を返し、書く位置を n 進める（足りなければ倍に広げて写す）。
    def reserveValues(list: RenderList, n: Int32): (Array[Float32, Static], Int32) \ IO =
        let values = Array.get(0, list#values);
        let at = Array.get(0, list#valueCount);
        let need = at + n;
        Array.put(need, 0, list#valueCount);
        if (Array.length(values) >= need) (values, at)
        else {
            let grown = Array.empty(Static, Int32.max(need, 2 * Array.length(values)));
            Array.copyInto(srcPos = 0, dstPos = 0, len = at, src = values, grown);
            Array.put(grown, 0, list#values);
            (grown, at)
        }

    /// 書く位置を surfaceValueAlign の倍数へ進め、値 n 個の面の分（surfaceValuesTaken）を取る。取った所（進めた分を含む）を 0 で埋めて (values, 書き始める位置) を返す。
    def reserveSurfaceValues(list: RenderList, n: Int32): (Array[Float32, Static], Int32) \ IO =
        let align = surfaceValueAlign();
        let start = Array.get(0, list#valueCount);
        let at = (start + align - 1) / align * align;
        let taken = surfaceValuesTaken(n);
        let (values, _) = reserveValues(list, at - start + taken);
        fillZero(values, start, at + taken);
        (values, at)

    def fillZero(values: Array[Float32, Static], i: Int32, stop: Int32): Unit \ IO =
        if (i >= stop) ()
        else {
            Array.put(0.0f32, i, values);
            fillZero(values, i + 1, stop)
        }

    /// count 個の絵を書ける reads と、書き始める番号を返し、書く位置を count 進める（足りなければ倍に広げて写す）。
    def reserveReads(list: RenderList, count: Int32): (Array[Int32, Static], Int32) \ IO =
        let reads = Array.get(0, list#reads);
        let at = Array.get(0, list#readCount);
        let need = (at + count) * readFields();
        Array.put(at + count, 0, list#readCount);
        if (Array.length(reads) >= need) (reads, at)
        else {
            let grown = Array.empty(Static, Int32.max(need, 2 * Array.length(reads)));
            Array.copyInto(srcPos = 0, dstPos = 0, len = at * readFields(), src = reads, grown);
            Array.put(grown, 0, list#reads);
            (grown, at)
        }

    /// 1 行足せる大きさの rows を返す（足りなければ倍に広げて写す）。
    def rowsWithRoom(list: RenderList): Array[Int32, Static] \ IO =
        let rows = Array.get(0, list#rows);
        let need = rowsHead() + (Array.get(0, rows) + 1) * rowStride();
        if (Array.length(rows) >= need) rows
        else {
            let grown = Array.empty(Static, Int32.max(need, 2 * Array.length(rows)));
            Array.copyInto(srcPos = 0, dstPos = 0, len = Array.length(rows), src = rows, grown);
            Array.put(grown, 0, list#rows);
            grown
        }

    /// スプライトの run を 1 行として足す。次の run の instance は、この run の後ろから始まる。
    pub def appendSpriteRow(list: RenderList, first: Int32, count: Int32, texId: Int32, blendC: Int32,
                            clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.Sprite, first, count, texId, blendC, clipFlag, x0, y0, x1, y1, 0, 0);
        Array.put(first + count, 1, rows)

    /// 多角形の run（vertices の [first, first + count)）を 1 行として足す。次の run の頂点は、この run の後ろから始まる。
    /// view は values の頭の identity の view（頂点は画面の座標で書いてある）。
    pub def appendPolyRow(list: RenderList, first: Int32, count: Int32, blendC: Int32,
                          clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.Poly, first, count, 0, blendC, clipFlag, x0, y0, x1, y1, 0, 0);
        Array.put(first + count, 2, rows)

    /// タイルの層を 1 行として足す。buffer = タイルの instance の buffer の番号・count = タイルの数。blend は Normal・clip は無し。
    pub def appendTileRow(list: RenderList, texId: Int32, buffer: Int32, count: Int32,
                          layer: { posX = Float32, posY = Float32, tileSize = Float32, scaleX = Float32, scaleY = Float32,
                                   r = Float32, g = Float32, b = Float32 }): Unit \ IO =
        let (values, at) = reserveValues(list, tileValueFloats());
        Array.put(layer#posX, at + 0, values);
        Array.put(layer#posY, at + 1, values);
        Array.put(layer#tileSize, at + 2, values);
        Array.put(layer#scaleX, at + 3, values);
        Array.put(layer#scaleY, at + 4, values);
        Array.put(layer#r, at + 5, values);
        Array.put(layer#g, at + 6, values);
        Array.put(layer#b, at + 7, values);
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.Tile, 0, count, texId, 0, 0, 0, 0, 0, 0, buffer, at)

    /// static layer の範囲（buffer の頂点 [first, first + count)）を 1 行として足す。view = 世界の座標を画面へ写す値。
    pub def appendStaticRow(list: RenderList, buffer: Int32, first: Int32, count: Int32, blendC: Int32,
                            clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32,
                            view: { offsetX = Float32, offsetY = Float32, scaleX = Float32, scaleY = Float32,
                                    halfX = Float32, halfY = Float32 }): Unit \ IO =
        let (values, at) = reserveValues(list, viewValueFloats());
        Array.put(view#offsetX, at + 0, values);
        Array.put(view#offsetY, at + 1, values);
        Array.put(view#scaleX, at + 2, values);
        Array.put(view#scaleY, at + 3, values);
        Array.put(view#halfX, at + 4, values);
        Array.put(view#halfY, at + 5, values);
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.StaticRange, first, count, 0, blendC, clipFlag, x0, y0, x1, y1, buffer, at)

    /// mask つきスプライト 1 体を 1 行として足す。instanceAt = 書いた 1 体の番号・maskFirst と maskCount = vertices に書いた mask の三角形の頂点・
    /// ref = stencil に書いて比べる値（nextMaskRef。maskCount が 3 未満なら 0）。次の instance と頂点は、この行の後ろから始まる。
    pub def appendMaskRow(list: RenderList, instanceAt: Int32, maskFirst: Int32, maskCount: Int32, texId: Int32, blendC: Int32,
                          clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32, ref: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.Mask, instanceAt, maskCount, texId, blendC, clipFlag, x0, y0, x1, y1, maskFirst, ref);
        Array.put(instanceAt + 1, 1, rows);
        Array.put(maskFirst + maskCount, 2, rows)

    /// stencil の比べる値の上限（stencil は 8 bit）。
    pub def maxMaskRef(): Int32 = 255

    /// 1 つの pass の中で、前の mask の値 last（0 = この pass でまだ無い）の次の mask の値。1 から 1 ずつ進み、上限の次は 1 に戻る。
    /// 値が 1 の行の前で、backend は stencil を全部 0 にする（pass の頭か、上限まで使い切った後）。それ以外の値は前の mask が書いたどの値よりも
    /// 大きいので、stencil を 0 に戻さなくても前の mask の形と取り違えない。
    // WhyNot: mask ごとに stencil を 0 に戻さない — WebGPU は pass の途中で stencil だけを clear する口が無く、戻すたびに design の全面の draw が 1 本増える。
    //   GL でも mask ごとに全面の clear を払う。
    pub def nextMaskRef(last: Int32): Int32 =
        if (last <= 0 or last >= maxMaskRef()) 1 else last + 1

    /// 3D の場面を貼る所を 1 行として足す。scene = Scene3dRenderer.Prepared の番号。
    // WhyNot: 場面の矩形と clip を欄に入れない — 番号で引ける場面の命令が持ち、GL は Render3d.drawItem がそこから出す。行にも写すと 2 か所が食い違いうる。
    pub def appendSceneRow(list: RenderList, scene: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.Scene3d, scene, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// 面 1 枚を 1 行として足す。program = backend の表の番号・surface と params = 面の値（values へ rect・time・alpha・params の順に書く）・
    /// reads = 絵の組（(絵の番号, 補間, 上下逆なら 1)）・maskFirst と maskCount = vertices に書いた mask の三角形の頂点・
    /// ref = stencil に書いて比べる値（maskCount が 3 未満なら 0）。次の頂点は、この行の後ろから始まる。
    pub def appendSurfaceRow(list: RenderList, program: Int32, blendC: Int32,
                             surface: { x = Float32, y = Float32, width = Float32, height = Float32, time = Float32, alpha = Float32 },
                             params: List[Float64], reads: List[(Int32, Int32, Int32)],
                             maskFirst: Int32, maskCount: Int32, ref: Int32): Unit \ IO =
        let count = 6 + List.length(params);
        let (values, at) = reserveSurfaceValues(list, count);
        Array.put(surface#x, at + 0, values);
        Array.put(surface#y, at + 1, values);
        Array.put(surface#width, at + 2, values);
        Array.put(surface#height, at + 3, values);
        Array.put(surface#time, at + 4, values);
        Array.put(surface#alpha, at + 5, values);
        List.forEachWithIndex((k, p) -> Array.put(RenderUtil.f32(p), at + 6 + k, values), params);
        let readCount = List.length(reads);
        let (readArray, readsAt) = reserveReads(list, readCount);
        List.forEachWithIndex((k, read) -> {
            let (texId, filter, flip) = read;
            let base = (readsAt + k) * readFields();
            Array.put(texId, base, readArray);
            Array.put(filter, base + 1, readArray);
            Array.put(flip, base + 2, readArray)
        }, reads);
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), ListRowKind.Surface, program, count, 0, blendC, 0, readsAt, readCount, maskFirst, maskCount, ref, at);
        Array.put(maskFirst + maskCount, 2, rows)

    /// 行 row が stencil に書いて比べる値（mask つきスプライトと面の行。ほかの行と、mask が 3 頂点未満の行は 0）。
    pub def stencilRefOf(rows: Array[Int32, Static], row: Int32): Int32 \ IO = match kindAt(rows, row) {
        case ListRowKind.Mask    => maskStencilRefAt(rows, row)
        case ListRowKind.Surface => surfaceStencilAt(rows, row)
        case _                   => 0
    }

    /// 行の欄を書いて行の数を 1 進める（rows は rowsWithRoom で取った物）。
    def putRow(rows: Array[Int32, Static], n: Int32, kind: ListRowKind, first: Int32, count: Int32, texId: Int32, blendC: Int32,
               clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32, buffer: Int32, valuesFirst: Int32): Unit \ IO =
        let at = rowsHead() + n * rowStride();
        Array.put(kindCodeOf(kind), at + colKind(), rows);
        Array.put(first, at + colFirst(), rows);
        Array.put(count, at + colCount(), rows);
        Array.put(texId, at + colTexture(), rows);
        Array.put(blendC, at + colBlend(), rows);
        Array.put(clipFlag, at + colClip(), rows);
        Array.put(x0, at + colClipX0(), rows);
        Array.put(y0, at + colClipY0(), rows);
        Array.put(x1, at + colClipX1(), rows);
        Array.put(y1, at + colClipY1(), rows);
        Array.put(buffer, at + colBuffer(), rows);
        Array.put(valuesFirst, at + colValues(), rows);
        Array.put(n + 1, 0, rows)

    // ── pass の指定 ──

    /// pass が持つ depth と stencil の attachment。
    pub enum DepthStencil {
        case NoDepthStencil
        case Depth
        case DepthAndStencil
    }

    /// 描き先の色の attachment 1 つ。texture = backend の表の番号（読む側が引く 1 標本の絵）・format = 画素の形式・load = 前の中身の始末・
    /// resolveTo = 標本が 2 以上の時、pass の終わりに標本の平均を写す先の表の番号（描く所は backend が texture ごとに持つ標本つきの描き先）。
    pub type alias ColorAttachment = { texture = Int32, format = RenderTarget.Format, load = RenderTarget.LoadOp, resolveTo = Option[Int32] }

    /// 描き先。Screen = 画面（色の attachment は画面か中間の texture の 1 つで、backend が決める。letterbox = design の外の余りの始末）・
    /// Target = Pass の texture（頭の色の attachment と、その後ろの attachment の列。今は頭の 1 つだけ使う）。
    // WhyNot: 色の attachment を List 1 本で持たない — Pass は必ず 1 つ持つので、空の列を読む枝（既定値か bug!）が要らない形にする。
    pub enum PassTarget {
        case Screen({ clearColor = Color, letterbox = Letterbox })
        case Target(ColorAttachment, List[ColorAttachment])
    }

    /// 画面の pass の design の外（レターボックス・ピラーボックス）の始末。Absent = 余りが無い（viewport が描き先の全面）・
    /// Black = 余りを黒で塗る・Kept = 余りはこのコマに先に塗ってあるので残す（App.withLetterboxView の絵を広げた後の本編の pass）。
    pub enum Letterbox with Eq, ToString {
        case Absent
        case Black
        case Kept
    }

    /// pass を開く前の history（前のコマの描き先の絵）の始末。CopyTo(n) = 描き先の今の中身を表の番号 n へ写す・
    /// ClearTransparent(n) = n を透明で塗る（前のコマを持たない 1 枚撮りと動画）・NoHistory = この pass は history を読まない。
    pub enum PassHistory with Eq, ToString {
        case NoHistory
        case CopyTo(Int32)
        case ClearTransparent(Int32)
    }

    /// 1 つの pass の指定。width × height = 描き先の画素の大きさ・viewport = design の矩形を描き先の画素で（x, 上の端, 幅, 高さ。左上が原点）・
    /// depthStencil = 描き先が持つ depth と stencil（WebGPU は、行に stencil を使う mask があれば前半が DepthAndStencil にする）・samples = 標本の数・
    /// history = pass を開く前の history の始末。
    pub type alias PassSpec = {
        target = PassTarget,
        width = Int32,
        height = Int32,
        viewport = (Int32, Int32, Int32, Int32),
        depthStencil = DepthStencil,
        samples = Int32,
        history = PassHistory
    }

    /// 画面の pass。width × height に design を縦横比を保って収め、余りは黒帯。
    pub def screenPass(size: (Int32, Int32), design: (Float64, Float64), clearColor: Color, depthStencil: DepthStencil): PassSpec =
        let (width, height) = size;
        let (designW, designH) = design;
        let (vpX, vpY, vpW, vpH) = RenderFrame.calcViewport(width, height, designW, designH);
        let viewport = (vpX, height - vpY - vpH, vpW, vpH);
        let letterbox = if (viewport != (0, 0, width, height)) Letterbox.Black else Letterbox.Absent;
        { target = PassTarget.Screen({ clearColor = clearColor, letterbox = letterbox }),
          width = width, height = height, viewport = viewport, depthStencil = depthStencil, samples = 1, history = PassHistory.NoHistory }

    /// 画面の pass の余りを、先に塗った物のまま残す形にする（余りの無い pass と Pass はそのまま）。
    pub def withLetterboxKept(pass: PassSpec): PassSpec =
        match pass#target {
            case PassTarget.Screen(screen) if screen#letterbox == Letterbox.Black =>
                { target = PassTarget.Screen({ letterbox = Letterbox.Kept | screen }) | pass }
            case _ => pass
        }

    /// 描き先の全面を viewport にした画面の pass（design の矩形を描き先の全面へ伸ばして写す。余りは無い）。
    /// App.withLetterboxView の絵を広げて塗る pass で、本編の pass より先に開く。
    pub def fullTargetPass(size: (Int32, Int32), clearColor: Color, depthStencil: DepthStencil): PassSpec =
        let (width, height) = size;
        { target = PassTarget.Screen({ clearColor = clearColor, letterbox = Letterbox.Absent }),
          width = width, height = height, viewport = (0, 0, width, height), depthStencil = depthStencil, samples = 1, history = PassHistory.NoHistory }

    /// Pass の texture 1 枚の pass。design の全面を描き先の全面へ写す（縦横の倍率が少し違ってよい — uv で読む限りずれない）。
    /// samples = backend が実際に描く標本の数。2 以上なら pass の終わりに color の texture へ resolve する（pass ごと）。
    // WhyNot: resolve を endTarget まで待たない — WebGPU は pass の resolveTarget で写すので、endTarget で写すと標本つきの描き先を読み直して
    //   書く空の pass が 1 本増える。開いている描き先は読めない決まりなので、pass の終わりに写しても読む側の絵は同じ。
    pub def targetPass(size: (Int32, Int32), color: TargetColor, depthStencil: DepthStencil, samples: Int32, history: PassHistory): PassSpec =
        let (width, height) = size;
        let attachment = { texture = color#texture, format = color#format, load = color#load,
                           resolveTo = if (samples > 1) Some(color#texture) else None };
        { target = PassTarget.Target(attachment, Nil), width = width, height = height, viewport = (0, 0, width, height),
          depthStencil = depthStencil, samples = samples, history = history }

    /// Pass の描き先の色（targetPass の引数）。texture = backend の表の番号・format = 画素の形式・load = 前の中身の始末。
    pub type alias TargetColor = { texture = Int32, format = RenderTarget.Format, load = RenderTarget.LoadOp }

    /// 頼まれた標本の数 requested で、backend が描ける標本の数 supported のどれを使うか。requested を超えない一番大きい物
    /// （GL は 1・2・4・8 のうち GL_MAX_SAMPLES 以下で、8 を頼まれて上限 4 なら 4）。ただし requested が 2 以上で、それが 1 になる時は
    /// supported の 2 以上の一番小さい物へ上げる（WebGPU は 1 と 4 しか描けないので、2 は 4 で描く）。
    // WhyNot: 2 を 1 へ下げない — 4 が描ける backend で MSAA が消え、backend で絵の縁が大きく変わる。
    pub def drawSamplesOf(requested: Int32, supported: List[Int32]): Int32 =
        let below = List.foldLeft((best, n) -> if (n <= requested and n > best) n else best, 1, supported);
        if (requested <= 1 or below > 1) below
        else List.foldLeft((best, n) -> if (n > 1 and (best == 1 or n < best)) n else best, 1, supported)

    /// pass の終わりに resolve する先の表の番号（標本 1 の pass と画面は None）。
    pub def resolveTargetOf(pass: PassSpec): Option[Int32] =
        match pass#target {
            case PassTarget.Screen(_)        => None
            case PassTarget.Target(color, _) => color#resolveTo
        }

    /// 頭の色の attachment の始末（画面は余りを黒で塗るなら黒・余りを残すなら前の中身のまま・余りが無ければ clearColor）。
    pub def loadOpOf(pass: PassSpec): RenderTarget.LoadOp =
        match pass#target {
            case PassTarget.Screen(screen) => screenLoadOp(screen#letterbox, screen#clearColor)
            case PassTarget.Target(color, _) => color#load
        }

    def screenLoadOp(letterbox: Letterbox, clearColor: Color): RenderTarget.LoadOp = match letterbox {
        case Letterbox.Absent => RenderTarget.LoadOp.Clear(clearColor)
        case Letterbox.Black  => RenderTarget.LoadOp.Clear({ r = 0.0, g = 0.0, b = 0.0 })
        case Letterbox.Kept   => RenderTarget.LoadOp.Keep
    }

    /// 描き先の色の attachment の表の番号（画面は -1）。この番号の絵を読む行は描けない。
    pub def targetTextureOf(pass: PassSpec): Int32 =
        match pass#target {
            case PassTarget.Screen(_)        => -1
            case PassTarget.Target(color, _) => color#texture
        }

    /// Pass の頭の色の attachment の形式（画面は None — 形式は backend が決める）。
    pub def targetFormatOf(pass: PassSpec): Option[RenderTarget.Format] =
        match pass#target {
            case PassTarget.Screen(_)        => None
            case PassTarget.Target(color, _) => Some(color#format)
        }

    /// 画面の pass の design の中の地の色（Pass は地の色を持たないので None）。
    pub def screenClearColorOf(pass: PassSpec): Option[Color] =
        match pass#target {
            case PassTarget.Screen(screen) => Some(screen#clearColor)
            case PassTarget.Target(_, _)   => None
        }

    /// 画面の pass で design の外に余りがあるか（黒で塗るか、先に塗った物を残すか）。
    pub def hasLetterbox(pass: PassSpec): Bool =
        match pass#target {
            case PassTarget.Screen(screen) => screen#letterbox != Letterbox.Absent
            case PassTarget.Target(_, _)   => false
        }

    /// 画面の pass の余りの始末（Pass は Absent）。
    pub def letterboxOf(pass: PassSpec): Letterbox =
        match pass#target {
            case PassTarget.Screen(screen) => screen#letterbox
            case PassTarget.Target(_, _)   => Letterbox.Absent
        }

    /// viewport を GL の左下が原点の (x, y, 幅, 高さ) で。
    pub def glViewportOf(pass: PassSpec): (Int32, Int32, Int32, Int32) =
        let (x, top, w, h) = pass#viewport;
        (x, pass#height - top - h, w, h)
}
