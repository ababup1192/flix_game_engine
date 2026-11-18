// TestStarts — 始まりの登録簿とギャラリーの場面が実機と同じ App から組めること・板の絵が project.json の textures に揃っていること。
// 読むのは assets の本物の Doc と絵（ゲームで Doc を書き換えても守る性質だけを見る）。
mod TestStarts {
    use fge::{App, DocJson, JsonCodec, Resources, Vec2}

    def res(): Res.Res \ IO =
        run { Res.loadOrBug(Images.readImageIo, TownScene.TextureNames.SceneTextures, Map.empty(), Res.loadDocsOrBug()) } with Fs.FileRead.runWithIO

    /// ギャラリーの場面は全部、実機と同じ App から shot:<名前> の始まりで組める。
    @Test
    def testEveryShotBuildsFromTheApp(): Unit \ {Assert, IO, Fs.FileRead} =
        let a = Game.app(res());
        Assert.assertEq(expected = Nil,
            Shots.names() |> List.filter(name -> Result.isErr(App.buildStart(a, Vec2.zero(), App.shotStartName(name), Map.empty()))))

    /// 立ち始めとギャラリーの場面の先頭は、通れるマスに立つ。
    @Test
    def testEveryShotLeaderStandsOnAnOpenCell(): Unit \ {Assert, IO} =
        let r = res();
        let blockedShots = Shots.names() |> List.filter(name -> Shots.worldOf(name, r)
            |> Option.flatMap(w -> World.leaderCell(r, w))
            |> Option.map(cr -> CollisionGrid.isBlockedFrom(r#grid, cr, cr)) |> Option.getWithDefault(true));
        Assert.assertEq(expected = Nil, blockedShots)

    /// at は先頭を col・row に立たせる。
    @Test
    def testAtPlacesTheLeader(): Unit \ {Assert, IO, Fs.FileRead} =
        let r = res();
        let started = App.startOrBug(Game.app(r), "at", Map#{"col" => "13", "row" => "47", "face" => "s"});
        Assert.assertEq(expected = Some((13, 47)), Resources.read((rr, w) -> World.leaderCell(rr, w), started))

    /// 板（木・街灯・町の人・小物・隊列）の絵は全部 project.json の textures にある（GPU の描き手は板の絵をその名前で引き、無ければ描かない）。
    @Test
    def testEveryBoardPictureIsAProjectTexture(): Unit \ {Assert, IO} =
        let docs = run { Res.loadDocsOrBug() } with Fs.FileRead.runWithIO;
        let tiles = TileMap3d.materialTable() |> Map.valuesOf |> List.map(fst) |> List.toSet;
        let boards = Res.picturePathsOf(docs) |> List.filter(p -> not Set.memberOf(p, tiles)) |> List.map(TownScene.projectTextureName);
        let declared = projectTextures();
        Assert.assertEq(expected = Nil, boards |> List.filter(n -> not Set.memberOf(n, declared)))

    def projectTextures(): Set[String] \ IO =
        (run { DocJson.readJson("project.json") } with Fs.FileRead.runWithIO) |> Result.toOption
            |> Option.flatMap(JsonCodec.expectObject) |> Option.flatMap(Map.get("textures"))
            |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.map(o -> JsonCodec.stringOr("name", "", o))))
            |> Option.getWithDefault(Nil) |> List.toSet
}
