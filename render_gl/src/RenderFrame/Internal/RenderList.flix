// RenderFrame.Internal.RenderList — 1 回の renderCommands で描く行の列（GL と WebGPU が同じ物を流す）と、その行を描く pass の指定。
// 1 行 = 物の集まりを 1 回描く（種類はスプライト・字・箱の run だけ。ほかの種類は GL を直に呼ぶ）。GL の物（program・VAO・buffer）を持たず、
// 絵は backend の表の番号（GL の backend ではテクスチャの番号）で持つ。行は Int32 の配列、1 体ぶんの値は instances の Float32 に置く。
// rows の頭: 0=行の数 1=次に書く instance の番号。その後ろに 1 行 rowStride() 個:
//   0=種類（kind*） 1=先頭の instance の番号 2=体数 3=絵の番号（0 = 絵の無い箱） 4=blend 5=clip有無 6-9=clip矩形（viewport の左上原点の px）
// instances は 1 体 instanceFloats() 個（RenderFrame.writeInstAt の並び）。行の値は instances の [先頭 × 38, (先頭 + 体数) × 38)。
// vertices は多角形の頂点（1 頂点 6 個・RenderSprite.writePolyVerts の並び）。instances も vertices も backend が貸す入れ物で、GPU へそのまま送る。
// 1 回の renderCommands は (PassSpec, RenderList) の組で描く。2D だけの画面では組は 1 つ。
// WhyNot: 行ごとに record や enum を作らない — 絵が 1 個ごとに替わると行は描く物の数だけでき、その割り当てが 1 コマに乗る。
// WhyNot: RenderFrame の兄弟のモジュールに出さない — 兄弟の mod からは RenderFrame の pub でない関数（run の状態・数え）を呼べず、pub に開くことになる。
pub mod RenderFrame.Internal.RenderList {
    import java.nio.FloatBuffer

    pub type alias RenderList = { instances = FloatBuffer, vertices = FloatBuffer, rows = Array[Array[Int32, Static], Static] }

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

    def rowStride(): Int32 = 10

    def rowsHead(): Int32 = 2

    /// 空の列。instances と vertices は backend が貸す入れ物（描く物の数ぶん書ける大きさ）。
    pub def newRenderList(instances: FloatBuffer, vertices: FloatBuffer): RenderList \ IO =
        { instances = instances, vertices = vertices, rows = Array#{Array.empty(Static, rowsHead() + 16 * rowStride())} @ Static }

    pub def rowCountOf(list: RenderList): Int32 \ IO = Array.get(0, rowsOf(list))

    pub def nextInstanceOf(list: RenderList): Int32 \ IO = Array.get(1, rowsOf(list))

    /// 頭と行を並べた Int32 の配列（広げると差し替わるので、行を足した後は取り直す）。
    pub def rowsOf(list: RenderList): Array[Int32, Static] \ IO = Array.get(0, list#rows)

    /// 行 row の欄 col（並びはこのファイルの頭のコメント）。
    pub def rowAt(rows: Array[Int32, Static], row: Int32, col: Int32): Int32 \ IO =
        Array.get(rowsHead() + row * rowStride() + col, rows)

    /// 行を全部捨てる（instances の書く位置も頭へ戻す）。
    pub def clearRenderList(list: RenderList): Unit \ IO =
        let rows = Array.get(0, list#rows);
        Array.put(0, 0, rows);
        Array.put(0, 1, rows)

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
        let n = Array.get(0, rows);
        let at = rowsHead() + n * rowStride();
        Array.put(kindSprite(), at + 0, rows);
        Array.put(first, at + 1, rows);
        Array.put(count, at + 2, rows);
        Array.put(texId, at + 3, rows);
        Array.put(blendC, at + 4, rows);
        Array.put(clipFlag, at + 5, rows);
        Array.put(x0, at + 6, rows);
        Array.put(y0, at + 7, rows);
        Array.put(x1, at + 8, rows);
        Array.put(y1, at + 9, rows);
        Array.put(n + 1, 0, rows);
        Array.put(first + count, 1, rows)

    // ── pass の指定 ──

    /// pass が持つ depth と stencil の attachment。
    pub enum DepthStencil {
        case NoDepthStencil
        case Depth
        case DepthAndStencil
    }

    /// 描き先の色の attachment 1 つ。texture = backend の表の番号・format = 画素の形式・load = 前の中身の始末・
    /// resolveTo = 標本が 2 以上の時に写す先の表の番号。
    pub type alias ColorAttachment = { texture = Int32, format = RenderTarget.Format, load = RenderTarget.LoadOp, resolveTo = Option[Int32] }

    /// 描き先。Screen = 画面（色の attachment は画面か中間の texture の 1 つで、backend が決める。letterbox = 黒帯があるか）・
    /// Target = Pass の texture（頭の色の attachment と、その後ろの attachment の列。今は頭の 1 つだけ使う）。
    // WhyNot: 色の attachment を List 1 本で持たない — Pass は必ず 1 つ持つので、空の列を読む枝（既定値か bug!）が要らない形にする。
    pub enum PassTarget {
        case Screen({ clearColor = Color, letterbox = Bool })
        case Target(ColorAttachment, List[ColorAttachment])
    }

    /// 1 つの pass の指定。width × height = 描き先の画素の大きさ・viewport = design の矩形を描き先の画素で（x, 上の端, 幅, 高さ。左上が原点）・
    /// depthStencil = 描き先が持つ depth と stencil・samples = 標本の数・copyHistory = 描く前に今の中身を写す先の表の番号。
    // WhyNot: copyHistory を読む backend はまだ無い — GL は RenderPaint.prepareHistory が描く前に写し、WebGPU は history を描かない。
    // WhyNot: depthStencil で stencil つきと無しの pipeline を分けない — WebGPU の行に mask がまだ無く、stencil を持つ pass を作らない。
    //   mask の行が入る時は、両方の pipeline を読み込みの間に作っておく（初めて mask が出たコマで作ると、できるまでそのコマの絵が崩れる）。
    pub type alias PassSpec = {
        target = PassTarget,
        width = Int32,
        height = Int32,
        viewport = (Int32, Int32, Int32, Int32),
        depthStencil = DepthStencil,
        samples = Int32,
        copyHistory = Option[Int32]
    }

    /// 画面の pass。width × height に design を縦横比を保って収め、余りは黒帯。
    pub def screenPass(size: (Int32, Int32), design: (Float64, Float64), clearColor: Color, depthStencil: DepthStencil): PassSpec =
        let (width, height) = size;
        let (designW, designH) = design;
        let (vpX, vpY, vpW, vpH) = RenderFrame.calcViewport(width, height, designW, designH);
        let viewport = (vpX, height - vpY - vpH, vpW, vpH);
        { target = PassTarget.Screen({ clearColor = clearColor, letterbox = viewport != (0, 0, width, height) }),
          width = width, height = height, viewport = viewport, depthStencil = depthStencil, samples = 1, copyHistory = None }

    /// Pass の texture 1 枚の pass。design の全面を描き先の全面へ写す（縦横の倍率が少し違ってよい — uv で読む限りずれない）。
    pub def targetPass(size: (Int32, Int32), color: ColorAttachment, depthStencil: DepthStencil, samples: Int32): PassSpec =
        let (width, height) = size;
        { target = PassTarget.Target(color, Nil), width = width, height = height, viewport = (0, 0, width, height),
          depthStencil = depthStencil, samples = samples, copyHistory = None }

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
