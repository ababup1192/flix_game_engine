// 始まりの登録簿（Starts.all を App.startOrBug / App.buildStart で引く）と、引数との橋渡し。
mod TestStarts {
    use fge::{App, Resources, Vec2}

    def heroOf(w: World.World): Option[(Float64, Float64)] = World.heroAt(w) |> Option.map(p -> (p#x, p#y))

    def app(): App.App[Resources.With[Res.Res, World.World], {}] \ Fs.FileRead = Game.app(Controls.loadDocs())

    /// at は主人公を x・y に置く。
    @Test
    def testAtPlacesTheHero(): Unit \ Assert + Fs.FileRead =
        let started = App.startOrBug(app(), "at", Map#{"x" => "60", "y" => "50"});
        Assert.assertEq(expected = Some((60.0, 50.0)), Resources.read((_, w) -> heroOf(w), started))

    /// 数でない座標は組まずに理由を返す。
    @Test
    def testAtRefusesANonNumber(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("始まり 'at': x は数（'left'）"),
            App.buildStart(app(), Vec2.zero(), "at", Map#{"x" => "left"}) |> Result.map(Resources.read((_, w) -> heroOf(w))))
}
