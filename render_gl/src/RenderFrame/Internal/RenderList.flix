// RenderFrame.Internal.RenderList — 1 回の renderCommands で描く行の列（GL と WebGPU が同じ物を流す）と、その行を描く pass の指定。
// 1 行 = 物の集まりを 1 回描く（種類はスプライト・字・箱の run・多角形の run・タイルの層・static layer の範囲・mask つきスプライト 1 体・3D の場面を貼る所。面は GL を直に呼ぶ）。
// GL の物（program・VAO・buffer）を持たず、絵と頂点の buffer は backend の表の番号（GL の backend ではテクスチャ・VAO の番号）で持つ。
// rows の頭: 0=行の数 1=次に書く instance の番号 2=次に書く頂点の番号。その後ろに 1 行 rowStride() 個:
//   0=種類（kind*） 1=先頭（スプライトは instance・多角形と static は頂点の番号） 2=数（体数・頂点数・タイルの数）
//   3=絵の番号（0 = 絵の無い箱・多角形と static は 0） 4=blend 5=clip有無 6-9=clip矩形（viewport の左上原点の px）
//   10=頂点の buffer の番号（タイルの instance・static の頂点。backend の表の番号。ほかは 0） 11=values の先頭（draw ごとの値。スプライトは 0）
//   mask つきスプライト（kindMask）だけ欄の意味が違う: 1=instance の番号（1 体） 2=mask の頂点の数（三角形にほどいた物・3 未満なら 0） 10=mask の先頭の頂点の番号
//   11=stencil に書いて比べる値（nextMaskRef が決める・0 = mask が 3 頂点未満で stencil を使わずに描く）。mask の頂点は values の頭の identity の view で描く。
//   3D の場面を貼る行（kindScene3d）: 1=場面の番号（Scene3dRenderer.Prepared の番号）。ほかの欄は 0。
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
        valueCount = Array[Int32, Static]
    }

    /// instance の 1 体の float の数。
    pub def instanceFloats(): Int32 = 38

    /// 多角形の 1 頂点の float の数。
    pub def vertexFloats(): Int32 = 6

    /// 行の種類（draw call の数えの種類と同じ番号）。
    pub def kindSprite(): Int32 = 1
    pub def kindPoly(): Int32 = 2
    pub def kindTile(): Int32 = 3
    pub def kindStatic(): Int32 = 4
    pub def kindSurface(): Int32 = 5
    pub def kindScene3d(): Int32 = 6
    /// mask つきスプライトの行（draw call は kindSprite で数える）。
    pub def kindMask(): Int32 = 7

    def rowStride(): Int32 = 12

    def rowsHead(): Int32 = 3

    /// values の 1 つの view（多角形と static）の float の数。
    pub def viewValueFloats(): Int32 = 6

    /// values の 1 つのタイルの層の float の数。
    pub def tileValueFloats(): Int32 = 8

    /// 空の列。instances と vertices は backend が貸す入れ物（描く物の数ぶん書ける大きさ）。
    pub def newRenderList(instances: FloatBuffer, vertices: FloatBuffer): RenderList \ IO =
        let list = { instances = instances, vertices = vertices, rows = Array#{Array.empty(Static, rowsHead() + 16 * rowStride())} @ Static,
                     values = Array#{Array.empty(Static, 64)} @ Static, valueCount = Array#{0} @ Static };
        clearRenderList(list);
        list

    pub def rowCountOf(list: RenderList): Int32 \ IO = Array.get(0, rowsOf(list))

    pub def nextInstanceOf(list: RenderList): Int32 \ IO = Array.get(1, rowsOf(list))

    pub def nextVertexOf(list: RenderList): Int32 \ IO = Array.get(2, rowsOf(list))

    /// values（広げると差し替わるので、行を足した後は取り直す）。
    pub def valuesOf(list: RenderList): Array[Float32, Static] \ IO = Array.get(0, list#values)

    /// values に書いた float の数（頭の identity の view を含む）。
    pub def valueCountOf(list: RenderList): Int32 \ IO = Array.get(0, list#valueCount)

    /// 頭と行を並べた Int32 の配列（広げると差し替わるので、行を足した後は取り直す）。
    pub def rowsOf(list: RenderList): Array[Int32, Static] \ IO = Array.get(0, list#rows)

    /// 行 row の欄 col（並びはこのファイルの頭のコメント）。
    pub def rowAt(rows: Array[Int32, Static], row: Int32, col: Int32): Int32 \ IO =
        Array.get(rowsHead() + row * rowStride() + col, rows)

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
        Array.put(viewValueFloats(), 0, list#valueCount)

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
        putRow(rows, Array.get(0, rows), kindSprite(), first, count, texId, blendC, clipFlag, x0, y0, x1, y1, 0, 0);
        Array.put(first + count, 1, rows)

    /// 多角形の run（vertices の [first, first + count)）を 1 行として足す。次の run の頂点は、この run の後ろから始まる。
    /// view は values の頭の identity の view（頂点は画面の座標で書いてある）。
    pub def appendPolyRow(list: RenderList, first: Int32, count: Int32, blendC: Int32,
                          clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), kindPoly(), first, count, 0, blendC, clipFlag, x0, y0, x1, y1, 0, 0);
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
        putRow(rows, Array.get(0, rows), kindTile(), 0, count, texId, 0, 0, 0, 0, 0, 0, buffer, at)

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
        putRow(rows, Array.get(0, rows), kindStatic(), first, count, 0, blendC, clipFlag, x0, y0, x1, y1, buffer, at)

    /// mask つきスプライト 1 体を 1 行として足す。instanceAt = 書いた 1 体の番号・maskFirst と maskCount = vertices に書いた mask の三角形の頂点・
    /// ref = stencil に書いて比べる値（nextMaskRef。maskCount が 3 未満なら 0）。次の instance と頂点は、この行の後ろから始まる。
    pub def appendMaskRow(list: RenderList, instanceAt: Int32, maskFirst: Int32, maskCount: Int32, texId: Int32, blendC: Int32,
                          clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32, ref: Int32): Unit \ IO =
        let rows = rowsWithRoom(list);
        putRow(rows, Array.get(0, rows), kindMask(), instanceAt, maskCount, texId, blendC, clipFlag, x0, y0, x1, y1, maskFirst, ref);
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
        putRow(rows, Array.get(0, rows), kindScene3d(), scene, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// 行の欄を書いて行の数を 1 進める（rows は rowsWithRoom で取った物）。
    def putRow(rows: Array[Int32, Static], n: Int32, kind: Int32, first: Int32, count: Int32, texId: Int32, blendC: Int32,
               clipFlag: Int32, x0: Int32, y0: Int32, x1: Int32, y1: Int32, buffer: Int32, valuesAt: Int32): Unit \ IO =
        let at = rowsHead() + n * rowStride();
        Array.put(kind, at + 0, rows);
        Array.put(first, at + 1, rows);
        Array.put(count, at + 2, rows);
        Array.put(texId, at + 3, rows);
        Array.put(blendC, at + 4, rows);
        Array.put(clipFlag, at + 5, rows);
        Array.put(x0, at + 6, rows);
        Array.put(y0, at + 7, rows);
        Array.put(x1, at + 8, rows);
        Array.put(y1, at + 9, rows);
        Array.put(buffer, at + 10, rows);
        Array.put(valuesAt, at + 11, rows);
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

    /// 描き先。Screen = 画面（色の attachment は画面か中間の texture の 1 つで、backend が決める。letterbox = 黒帯があるか）・
    /// Target = Pass の texture（頭の色の attachment と、その後ろの attachment の列。今は頭の 1 つだけ使う）。
    // WhyNot: 色の attachment を List 1 本で持たない — Pass は必ず 1 つ持つので、空の列を読む枝（既定値か bug!）が要らない形にする。
    pub enum PassTarget {
        case Screen({ clearColor = Color, letterbox = Bool })
        case Target(ColorAttachment, List[ColorAttachment])
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
        { target = PassTarget.Screen({ clearColor = clearColor, letterbox = viewport != (0, 0, width, height) }),
          width = width, height = height, viewport = viewport, depthStencil = depthStencil, samples = 1, history = PassHistory.NoHistory }

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

    /// 頭の色の attachment の始末（画面は黒帯があれば黒・無ければ clearColor）。
    pub def loadOpOf(pass: PassSpec): RenderTarget.LoadOp =
        match pass#target {
            case PassTarget.Screen(screen) =>
                RenderTarget.LoadOp.Clear(if (screen#letterbox) { r = 0.0, g = 0.0, b = 0.0 } else screen#clearColor)
            case PassTarget.Target(color, _) => color#load
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

    /// 画面の pass で黒帯があるか。
    pub def hasLetterbox(pass: PassSpec): Bool =
        match pass#target {
            case PassTarget.Screen(screen) => screen#letterbox
            case PassTarget.Target(_, _)   => false
        }

    /// viewport を GL の左下が原点の (x, y, 幅, 高さ) で。
    pub def glViewportOf(pass: PassSpec): (Int32, Int32, Int32, Int32) =
        let (x, top, w, h) = pass#viewport;
        (x, pass#height - top - h, w, h)
}
