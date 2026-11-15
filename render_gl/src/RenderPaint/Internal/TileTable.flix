// RenderPaint.Internal.TileTable — タイルの層の instance の buffer の表（GL と WebGPU が同じ決まりで使う）。
// 作った buffer の番号（ゲームへ返す GpuHandle.TileVao の中身・backend の表の番号）の集まりと、タイル 1 枚の float の並びを持つ。
// 入れ直すか作るかはここだけで決め、backend は作る・入れ直す 2 つ（TileAllocator）だけを渡す。
// 1 枚 tileFloats() 個: 0-1=px 2-3=uvOff 4-5=uvSc 6=alpha 7-9=tint（GL の tile シェーダーの location 1〜5 と同じ並び）。
pub mod RenderPaint.Internal.TileTable {

    /// backend が instance の buffer を作る・入れ直す関数の組。create(floats, 枚数) は buffer の番号を返す。
    /// write(番号, floats, 枚数) は前より多い枚数でも受ける（足りない buffer は backend が作り直す）。
    pub type alias TileAllocator = {
        create = (Array[Float32, Static], Int32) -> Int32 \ IO,
        write = (Int32, Array[Float32, Static], Int32) -> Unit \ IO
    }

    /// 作った buffer の番号の集まり。
    pub type alias Table = Ref[Set[Int32], Static]

    pub def fresh(): Table \ IO = Ref.fresh(Static, Set.empty())

    /// タイル 1 枚の float の数。
    pub def tileFloats(): Int32 = 10

    /// Game.initTileBuffer の中身: buffer を作って (番号, 枚数) を返す。
    pub def init(alloc: TileAllocator, table: Table, instances: List[RenderType.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        let count = List.length(instances);
        let id = (alloc#create)(instanceFloats(instances), count);
        Ref.put(Set.insert(id, Ref.get(table)), table);
        (GpuHandle.wrapTileVao(id), count)

    /// Game.updateTileBuffer の中身: 作った buffer なら入れ直し、知らない番号なら作って返す。
    pub def update(alloc: TileAllocator, table: Table, handle: GpuHandle.TileVao,
                   instances: List[RenderType.TileInstance]): (GpuHandle.TileVao, Int32) \ IO =
        let id = GpuHandle.tileVaoInt(handle);
        if (Set.memberOf(id, Ref.get(table))) {
            let count = List.length(instances);
            (alloc#write)(id, instanceFloats(instances), count);
            (handle, count)
        } else init(alloc, table, instances)

    /// タイルの列を 1 枚 tileFloats() 個の float に並べる。
    pub def instanceFloats(instances: List[RenderType.TileInstance]): Array[Float32, Static] \ IO =
        let f32 = RenderUtil.f32;
        let data = Array.empty(Static, Int32.max(1, List.length(instances)) * tileFloats());
        discard List.foldLeft((i, inst) -> {
            let base = i * tileFloats();
            let px = inst#px;
            Array.put(f32(px#x),       base + 0, data);
            Array.put(f32(px#y),       base + 1, data);
            let uvOff = inst#uvOff;
            Array.put(f32(uvOff#x),    base + 2, data);
            Array.put(f32(uvOff#y),    base + 3, data);
            let uvSc = inst#uvSc;
            Array.put(f32(uvSc#x),     base + 4, data);
            Array.put(f32(uvSc#y),     base + 5, data);
            Array.put(f32(inst#alpha), base + 6, data);
            let tint = inst#tint;
            Array.put(f32(tint#r),     base + 7, data);
            Array.put(f32(tint#g),     base + 8, data);
            Array.put(f32(tint#b),     base + 9, data);
            i + 1
        }, 0, instances);
        data
}
