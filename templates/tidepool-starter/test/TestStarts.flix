// 始まりの登録簿（Starts.all を App.startOrBug / App.buildStart で引く）と、引数との橋渡し。
mod TestStarts {
    use fge::{App, Resources, Vec2}

    def app(): App.App[Resources.With[Res.Res, World.World], {}] \ Fs.FileRead = Game.app(Controls.loadDocs())

    /// level n=2 は面 2（index 1）の初めで、遊びの画面。
    @Test
    def testLevelStartsTheNthLevel(): Unit \ Assert + Fs.FileRead =
        let started = App.startOrBug(app(), "level", Map#{"n" => "2"});
        Assert.assertEq(expected = (1, World.ScreenKind.Play, 0),
            Resources.read((res, w) -> (World.levelOf(w), World.screenKindOf(w), World.state(res, w)#t), started))

    /// 無い面は組まずに理由を返す。
    @Test
    def testLevelRefusesAMissingLevel(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("始まり 'level': n は 1..6 の面（'9'）"),
            App.buildStart(app(), Vec2.zero(), "level", Map#{"n" => "9"}) |> Result.map(Resources.read((_, w) -> World.levelOf(w))))
}
