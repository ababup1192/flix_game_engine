// BenchAlloc — Render.draw (item → Drawable 変換) の確保バイトを AllocMeter で測る使い捨ての入口。
// 実行: ../../bin/flix run --entrypoint BenchAlloc.main
// 出力: N と、1 回の draw の確保バイト、item 1 個あたりのバイト。
mod BenchAlloc {

    use fge::{AllocMeter, RawDraw, Render, Vec2}

    pub def main(): Unit \ IO =
        let n = 1000;
        let items = testItems(n);
        // ウォームアップ 5 回で JIT を温めてから測る (AllocMeter の流儀)。
        let bytes = AllocMeter.measureBytes(5, () -> Render.draw(items));
        println("N=${n} draw1回=${bytes}B item1個=${bytes / Int32.toInt64(n)}B")

    /// スプライト半分・箱半分。さらに全体の 1/4 を clipped で包み、
    /// 部分更新 (withClip) の経路も測りに入れる。
    def testItems(n: Int32): List[Render.PlacedItem] =
        List.range(0, n) |> List.map(i -> {
            let pos = { x = Int32.toFloat64(Int32.modulo(i * 13, 320)),
                        y = Int32.toFloat64(Int32.modulo(i * 7, 240)) };
            let item =
                if (Int32.modulo(i, 2) == 0)
                    Render.sprite("flag", i)
                else
                    RawDraw.box({ x = 8.0, y = 8.0 }, { r = 0.5, g = 0.5, b = 0.5 }, i);
            let wrapped =
                if (Int32.modulo(i, 4) == 0)
                    Render.clipped({ position = { x = 0.0, y = 0.0 }, size = { x = 320.0, y = 240.0 } }, item)
                else item;
            ({ at = (pos: Vec2.Vec2), item = wrapped }: Render.PlacedItem)
        })
}
