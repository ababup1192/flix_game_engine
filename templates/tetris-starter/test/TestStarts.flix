// 始まりの登録簿（Starts.all を App.startOrBug / App.buildStart で引く）と、JSON・引数との橋渡し。
// startOrBug は新しく作った初期の World（assets の Doc を読み直した物）から組む。
mod TestStarts {
    use fge::{App, Vec2}

    def app(): App.App[World.World, {}] \ Fs.FileRead = Game.app(Controls.loadDocs())

    /// stack の既定（gap=4）: 下 4 行に 9 升ずつ・空いているのは 4 列目だけ。
    @Test
    def testStackLeavesTheGapColumnOpen(): Unit \ Assert + Fs.FileRead =
        let w = App.startOrBug(app(), "stack", Map.empty());
        Assert.assertEq(expected = (4 * (World.cols() - 1), false),
            (Map.size(w#board), Map.memberOf((4, World.rows() - 1), w#board)))

    /// 引数は既定を上書きする: gap=0 なら 0 列目が空き、4 列目は埋まる。
    @Test
    def testStackGapArgumentOverridesTheDefault(): Unit \ Assert + Fs.FileRead =
        let w = App.startOrBug(app(), "stack", Map#{"gap" => "0"});
        Assert.assertEq(expected = (false, true),
            (Map.memberOf((0, World.rows() - 1), w#board), Map.memberOf((4, World.rows() - 1), w#board)))

    /// 盤の外の列は組まずに理由を返す。
    @Test
    def testStackRefusesAColumnOffTheBoard(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("始まり 'stack': gap は 0..9 の列（'10'）"),
            App.buildStart(app(), Vec2.zero(), "stack", Map#{"gap" => "10"}) |> Result.map(w -> w#phase))
}
