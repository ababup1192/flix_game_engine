// 始まりの登録簿（Starts.all を App.startOrBug / App.buildStart で引く）と、引数との橋渡し。assets の配置の表から組む。
mod TestStarts {
    use fge::{App, HeadlessLoad, Resources, Vec2}

    def app(): App.App[Resources.With[Res.Res, World.World], {}] \ IO = run { Game.app(HeadlessLoad.handle(Controls.loadDocs)) } with Fs.FileRead.runWithIO

    def feetXz(w: World.World): (Float64, Float64) = (World.feetOf(w)#x, World.feetOf(w)#z)

    /// at は足元を x・z に置く（下の床に合わせる）。
    @Test
    def testAtPlacesTheFeet(): Unit \ Assert + Fs.FileRead + IO =
        let started = App.startOrBug(app(), "at", Map#{"x" => "-4.5", "y" => "0", "z" => "5", "yaw" => "0"});
        Assert.assertEq(expected = (-4.5, 5.0), Resources.read((_, w) -> feetXz(w), started))

    /// 数でない座標は組まずに理由を返す。
    @Test
    def testAtRefusesANonNumber(): Unit \ Assert + Fs.FileRead + IO =
        Assert.assertEq(expected = Err("始まり 'at': x は数（'left'）"),
            App.buildStart(app(), Vec2.zero(), "at", Map#{"x" => "left"}) |> Result.map(Resources.read((_, w) -> feetXz(w))))

    /// ギャラリーの場面は全部、実機と同じ App から shot:<名前> の始まりで組める（表に当たる部屋と階段がある）。
    @Test
    def testEveryShotBuildsFromTheApp(): Unit \ Assert + Fs.FileRead + IO =
        let a = app();
        Assert.assertEq(expected = Nil,
            Shots.names() |> List.filter(name -> Result.isErr(App.buildStart(a, Vec2.zero(), App.shotStartName(name), Map.empty()))))

    /// at の items= は持ち物を持たせ、unlocked= はその部屋の戸を開けておく（assets の items.kind.json の id）。
    @Test
    def testAtHoldsItemsAndOpensDoors(): Unit \ Assert + Fs.FileRead + IO =
        let started = App.startOrBug(app(), "at", Map#{"x" => "-4.5", "y" => "0", "z" => "5", "yaw" => "0", "items" => "library_key", "unlocked" => "library"});
        Assert.assertEq(expected = ("library_key" :: Nil, true),
            Resources.read((res, w) -> (World.inventoryIdsOf(res, w), World.isUnlocked("library", w)), started))

    /// 鍵のかかっていない部屋の unlocked= は組まずに理由を返す（打ち間違いを黙って通さない）。
    @Test
    def testAtRefusesAnUnknownRoom(): Unit \ Assert + Fs.FileRead + IO =
        Assert.assertTrue(Result.isErr(App.buildStart(app(), Vec2.zero(), "at", Map#{"unlocked" => "gym"})))

    /// assets の校舎で、鍵のかかった部屋（図書室と理科室）の戸口はどちらも 2 つずつ見つかる。
    @Test
    def testLockedRoomsHaveTwoDoorwaysEach(): Unit \ Assert + Fs.FileRead + IO =
        let started = App.startOrBug(app(), "play", Map.empty());
        Assert.assertEq(expected = (2, 2), Resources.read((res, _) -> (List.length(Items.doorsOfRoom("library", res#doors)), List.length(Items.doorsOfRoom("science", res#doors))), started))
}
