// RenderFrame.Internal.RenderList — 1 回の renderCommands で描く行の列（GL と WebGPU が同じ物を流す）。
// 1 行 = 物の集まりを 1 回描く（種類はスプライト・字・箱の run だけ。ほかの種類は GL を直に呼ぶ）。GL の物（program・VAO・buffer）を持たず、
// 絵は backend の表の番号（GL の backend ではテクスチャの番号）で持つ。行は Int32 の配列、1 体ぶんの値は instances の Float32 に置く。
// rows の頭: 0=行の数 1=次に書く instance の番号。その後ろに 1 行 rowStride() 個:
//   0=種類（kind*） 1=先頭の instance の番号 2=体数 3=絵の番号（0 = 絵の無い箱） 4=blend 5=clip有無 6-9=clip矩形（viewport の左上原点の px）
// instances は 1 体 38 個（RenderFrame.writeInstAt の並び）。行の値は instances の [先頭 × 38, (先頭 + 体数) × 38)。
// WhyNot: 行ごとに record や enum を作らない — 絵が 1 個ごとに替わると行は描く物の数だけでき、その割り当てが 1 コマに乗る。
// WhyNot: RenderFrame の兄弟のモジュールに出さない — 兄弟の mod からは RenderFrame の pub でない関数（run の状態・数え）を呼べず、pub に開くことになる。
pub mod RenderFrame.Internal.RenderList {
    import java.nio.FloatBuffer

    pub type alias RenderList = { instances = FloatBuffer, rows = Array[Array[Int32, Static], Static] }

    /// 行の種類（draw call の数えの種類と同じ番号）。
    pub def kindSprite(): Int32 = 1
    pub def kindPoly(): Int32 = 2
    pub def kindTile(): Int32 = 3
    pub def kindStatic(): Int32 = 4
    pub def kindSurface(): Int32 = 5
    pub def kindScene3d(): Int32 = 6

    def rowStride(): Int32 = 10

    def rowsHead(): Int32 = 2

    pub def newRenderList(instances: FloatBuffer): RenderList \ IO =
        { instances = instances, rows = Array#{Array.empty(Static, rowsHead() + 16 * rowStride())} @ Static }

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
}
