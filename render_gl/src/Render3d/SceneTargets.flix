// Render3d.SceneTargets — 場面を描く描き先（render target）の寿命の表（前半。GPU を呼ばない）。GL（Design の解像度の FBO・Render3d.designTarget）と
// WebGPU（場面ごとの描き先・Render3d.WebGpuRenderer.targetOf）が同じ関数を使う。
// 鍵ごとに描き先の形（大きさ・形式・標本）と最後に使った世代を持ち、形が変われば作り直し、しばらく使わなかった描き先を捨てる物を決める。
// GPU の描き先を作る・捨てるのは backend の Allocator で、作った物は表が値として預かる（v の中は見ない）。
// WhyNot: 鍵の形を 2 つの backend でそろえない — GL は prepare の中の場面の番号と形式で鍵を作り（画面と HDR の Pass で同じ番号を描いても作り直しが続かない）、
//   WebGPU は描き先の番号と場面の番号で鍵を作る（同じ encoder で同じ鍵に 2 回書く前に submit する決まりがその鍵で控える）。表は鍵の型を問わない。
// WhyNot: 影の地図の寿命の表（Render3d.ShadowMaps）とまとめない — 影の地図の鍵は一辺の画素を含み、形が変われば別の鍵になるので、作り直しの比べが要らない。
mod Render3d.SceneTargets {

    /// 描き先の形。samples = 標本の数（GL の Design の描き先はいつも 1）。
    pub type alias Shape = { width = Int32, height = Int32, format = RenderTarget.Format, samples = Int32 }

    /// backend が描き先を作る・捨てる関数の組。
    pub type alias Allocator[v: Type] = { create = Shape -> v \ IO, destroy = v -> Unit \ IO }

    /// 表の 1 行（作った形・最後に使った世代・backend が作った物）。
    type alias Entry[v: Type] = { shape = Shape, lastUsed = Int64, target = v }

    /// 寿命の表（鍵 → 行）。
    pub enum Table[k: Type, v: Type] {
        case Table(Ref[Map[k, Entry[v]], Static])
    }

    pub def fresh(): Table[k, v] \ IO = Table.Table(Ref.fresh(Static, Map.empty()))

    /// 作ってある描き先の鍵 → 最後に使った世代。
    pub def createdOf(table: Table[k, v]): Map[k, Int64] \ IO with Order[k] =
        let Table.Table(entries) = table;
        Map.map(e -> e#lastUsed, Ref.get(entries))

    /// 鍵 key の形 shape の描き先（無いか形が違えば、前の物を allocator で捨ててから作る）と、作ったかの組。最後に使った世代を gen にする。
    pub def ensure(table: Table[k, v], allocator: Allocator[v], gen: Int64, key: k, shape: Shape): (v, Bool) \ IO with Order[k] =
        let Table.Table(entries) = table;
        let held = Ref.get(entries);
        match Map.get(key, held) {
            case Some(e) if isSameShape(e#shape, shape) =>
                Ref.put(Map.insert(key, { lastUsed = gen | e }, held), entries);
                (e#target, false)
            case old =>
                Option.forEach(e -> allocator#destroy(e#target), old);
                let made = allocator#create(shape);
                Ref.put(Map.insert(key, { shape = shape, lastUsed = gen, target = made }, held), entries);
                (made, true)
        }

    def isSameShape(a: Shape, b: Shape): Bool =
        a#width == b#width and a#height == b#height and a#format == b#format and a#samples == b#samples

    /// Render3d.idleTargetFrames() の数の画面のコマ使わなかった描き先を allocator で捨て、捨てた数を返す（画面のコマの終わりに 1 回）。
    pub def sweep(table: Table[k, v], allocator: Allocator[v], gen: Int64): Int32 \ IO with Order[k] =
        let Table.Table(entries) = table;
        let held = Ref.get(entries);
        let idle = Map.filter(e -> gen - e#lastUsed > Render3d.idleTargetFrames(), held);
        if (Map.isEmpty(idle)) 0
        else {
            Map.forEach((_, e) -> allocator#destroy(e#target), idle);
            Ref.put(Map.difference(held, idle), entries);
            Map.size(idle)
        }

    /// 作ってある描き先を全部 allocator で捨てる。
    pub def release(table: Table[k, v], allocator: Allocator[v]): Unit \ IO =
        let Table.Table(entries) = table;
        Map.forEach((_, e) -> allocator#destroy(e#target), Ref.get(entries));
        Ref.put(Map.empty(), entries)
}
