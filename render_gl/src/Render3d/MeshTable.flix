// Render3d.MeshTable — 3D の形の置き場の表（Mesh3d.contentHash → 番号・頂点の数・最後に使ったコマ）を、GL（Render3d）と WebGPU（Render3d.WebGpuRenderer）が同じ関数で育てる。
// 番号を振る・上限で捨てる物を選ぶのはここ。GPU の形を作る・捨てる所だけを backend ごとの関数の record（MeshAllocator）で受け、backend は番号から自分の物を引く。
// 番号は計画の行（Render3d.SceneList の形の番号の欄）に載り、行を流す時に backend が作る（numberOf で振ってから ensure で作る）。
// WhyNot: 表を backend ごとに持たない — 捨てる順・頂点の上限・先に上げた物の守り方が 2 本に分かれ、片方だけ直す事になる（RenderPaint.Internal.TargetTable と同じ）。
mod Render3d.MeshTable {

    /// 形 1 つの控え。handle = 番号・vertexCount = GPU に作った形の頂点の数（要素 1 つ。まだ作っていなければ -1）・lastUsed = 最後に使ったコマの世代（要素 1 つ）。
    // WhyNot: lastUsed を Map の値に持ち直さない — batch ごとに Map の道を作り直すことになり、小物の多い場面の代金が増える。
    pub type alias Slot = { handle = Int32, vertexCount = Array[Int32, Static], lastUsed = Array[Int64, Static] }

    /// backend が形を作る・捨てる関数の組。create(番号, 形) = 形を GPU に作って番号で控え、頂点の数を返す・destroy(番号) = 捨てる。
    pub type alias MeshAllocator = {
        create = (Int32, Mesh3d.Mesh3d) -> Int32 \ IO,
        destroy = Int32 -> Unit \ IO
    }

    /// 表。slots = 鍵 → 控え・free = 捨てた後に使い回す番号・next = まだ使っていない一番小さい番号（要素 1 つ）・vertexTotal = 作った形の頂点の合計（要素 1 つ）。
    pub type alias Table = {
        slots = Ref[Map[String, Slot], Static], free = Ref[List[Int32], Static], next = Array[Int32, Static], vertexTotal = Array[Int32, Static]
    }

    /// 空の表。
    pub def fresh(): Table \ IO =
        { slots = Ref.fresh(Static, Map.empty()), free = Ref.fresh(Static, Nil), next = Array#{0} @ Static, vertexTotal = Array#{0} @ Static }

    /// 形 mesh の番号（無ければ振る。GPU には作らない）。どちらでも lastUsed を gen にする。
    pub def numberOf(table: Table, gen: Int64, mesh: Mesh3d.Mesh3d): Int32 \ IO = (slotOf(table, gen, mesh))#handle

    /// 形 mesh の番号（無ければ振る）。GPU にまだ作っていなければ allocator で作る。どちらでも lastUsed を gen にする。
    pub def ensure(table: Table, allocator: MeshAllocator, gen: Int64, mesh: Mesh3d.Mesh3d): Int32 \ IO =
        let slot = slotOf(table, gen, mesh);
        if (Array.get(0, slot#vertexCount) >= 0) ()
        else {
            let n = allocator#create(slot#handle, mesh);
            Array.put(n, 0, slot#vertexCount);
            Array.put(Array.get(0, table#vertexTotal) + n, 0, table#vertexTotal)
        };
        slot#handle

    /// 形 mesh の控え（無ければ番号を振る。GPU には作らない）。lastUsed を gen にする。
    pub def slotOf(table: Table, gen: Int64, mesh: Mesh3d.Mesh3d): Slot \ IO =
        let key = Mesh3d.contentHash(mesh);
        match Map.get(key, Ref.get(table#slots)) {
            case Some(found) =>
                Array.put(gen, 0, found#lastUsed);
                found
            case None =>
                let made = { handle = takeHandle(table), vertexCount = Array#{-1} @ Static, lastUsed = Array#{gen} @ Static };
                Ref.put(Map.insert(key, made, Ref.get(table#slots)), table#slots);
                made
        }

    /// 控え slots の lastUsed を gen にする（行を持ち越した形を、表を引き直さずに今のコマで使った物にする）。
    pub def touchSlots(slots: Vector[Slot], gen: Int64): Unit \ IO =
        Vector.forEach(s -> Array.put(gen, 0, s#lastUsed), slots)

    def takeHandle(table: Table): Int32 \ IO = match Ref.get(table#free) {
        case h :: rest =>
            Ref.put(rest, table#free);
            h
        case Nil =>
            let h = Array.get(0, table#next);
            Array.put(h + 1, 0, table#next);
            h
    }

    /// 作った形の頂点の合計。
    pub def vertexTotalOf(table: Table): Int32 \ IO = Array.get(0, table#vertexTotal)

    /// GPU に作った形の鍵 → (番号, 頂点の数, 最後に使った世代)。
    pub def createdOf(table: Table): Map[String, (Int32, Int32, Int64)] \ IO =
        Ref.get(table#slots) |> Map.filterMap(s -> {
            let n = Array.get(0, s#vertexCount);
            if (n < 0) None else Some((s#handle, n, Array.get(0, s#lastUsed)))
        })

    /// 頂点の合計が limit を超えていたら、Render3d.meshEvictions の順で GPU の形を捨て（作っていない番号で gen − 1 より前の物も外す）、捨てた形の鍵を返す。
    /// preloaded = 先に上げた形の鍵（後ろへ回す）。画面のコマの終わりに呼ぶ。
    pub def trim(table: Table, allocator: MeshAllocator, gen: Int64, limit: Int32, preloaded: Set[String]): List[String] \ IO =
        if (vertexTotalOf(table) <= limit) Nil
        else {
            let slots = Ref.get(table#slots);
            let created = createdOf(table);
            let victims = Render3d.meshEvictions(limit, gen, preloaded, Map.toList(created) |> List.map(ke -> {
                let (key, (_, n, lastUsed)) = ke;
                (key, n, lastUsed)
            }));
            let stale = slots |> Map.filter(s -> Array.get(0, s#vertexCount) < 0 and Array.get(0, s#lastUsed) < gen - 1i64) |> Map.keysOf;
            let dropped = List.foldLeft((acc, key) -> Set.insert(key, acc), stale, victims);
            dropped |> Set.forEach(key -> Map.get(key, slots) |> Option.forEach(s -> drop(table, allocator, s)));
            Ref.put(Set.foldLeft((acc, key) -> Map.remove(key, acc), slots, dropped), table#slots);
            victims
        }

    /// 控え s の形を GPU から捨て（作っていれば）、番号を使い回す列へ戻す。
    def drop(table: Table, allocator: MeshAllocator, s: Slot): Unit \ IO =
        let n = Array.get(0, s#vertexCount);
        if (n < 0) ()
        else {
            allocator#destroy(s#handle);
            Array.put(Array.get(0, table#vertexTotal) - n, 0, table#vertexTotal)
        };
        Ref.put(s#handle :: Ref.get(table#free), table#free)

    /// 表の形を全部捨てる。
    pub def release(table: Table, allocator: MeshAllocator): Unit \ IO =
        Ref.get(table#slots) |> Map.forEach((_, s) -> if (Array.get(0, s#vertexCount) >= 0) allocator#destroy(s#handle) else ());
        Ref.put(Map.empty(), table#slots);
        Ref.put(Nil, table#free);
        Array.put(0, 0, table#next);
        Array.put(0, 0, table#vertexTotal)
}
