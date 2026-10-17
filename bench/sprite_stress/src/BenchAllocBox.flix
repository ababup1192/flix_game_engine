// BenchAllocBox — 箱（BoxStyle つき）の item 構築 + draw の確保バイトを測る使い捨ての入口。
// BenchAlloc と違い item の組み立ても測定の中に入れる — BoxStyle はゲームの View が
// 毎フレーム item を組み直すときに作られるので、そこを外すと style の確保が数字に出ない。
// 実行: ../../bin/flix run --entrypoint BenchAllocBox.main
mod BenchAllocBox {

    use flix_game_engine::{AllocMeter, RawDraw, Render, Vec2}

    pub def main(): Unit \ IO =
        let n = 1000;
        let bytes = AllocMeter.measureBytes(5, () -> Render.draw(testItems(n)));
        println("N=${n} 構築+draw1回=${bytes}B item1個=${bytes / Int32.toInt64(n)}B")

    /// 全部が箱。1/2 は素の箱（solidStyle だけ）、1/4 は角丸、1/4 は枠線つき —
    /// タイトル画面の UI パネルが通る構築の形。
    def testItems(n: Int32): List[Render.PlacedItem] =
        List.range(0, n) |> List.map(i -> {
            let pos = { x = Int32.toFloat64(Int32.modulo(i * 13, 320)),
                        y = Int32.toFloat64(Int32.modulo(i * 7, 240)) };
            let box = RawDraw.box({ x = 8.0, y = 8.0 }, { r = 0.5, g = 0.5, b = 0.5 }, i);
            let item =
                if (Int32.modulo(i, 4) == 0)
                    box |> Render.rounded(2.0)
                else if (Int32.modulo(i, 4) == 1)
                    box |> Render.outline({ r = 1.0, g = 1.0, b = 1.0 }, 1.0)
                else box;
            ({ at = (pos: Vec2.Vec2), item = item }: Render.PlacedItem)
        })
}
