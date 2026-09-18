// JSON 橋渡しのテスト(1 Doc につき最大 3 本まで。同型の重複は書かない)。
// ThemeDoc は KindDoc と同型(フィールドの Or 読み)なので橋渡しは書かない。
mod TestDocs {

    // ══════════════════════════════════════════════════════
    // MapDoc(里の間取り: rows と配置)
    // ══════════════════════════════════════════════════════

    @Test
    def testMapBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定の間取りへ落ちる(ゲームは必ず起動する)。
        let doc = MapDoc.fromJson("{ broken") |> Option.getWithDefault(MapDoc.defaults());
        Assert.assertEq(
            expected = (MapDoc.rec(MapDoc.defaults())#start#x, MapDoc.rec(MapDoc.defaults())#start#y, MapDoc.rec(MapDoc.defaults())#goal),
            (MapDoc.rec(doc)#start#x, MapDoc.rec(doc)#start#y, MapDoc.rec(doc)#goal))

    @Test
    def testMapOverridesOneField(): Unit \ Assert =
        // 1 フィールドだけ書いた JSON はそこだけ効き、残りは既定のまま。
        let doc = MapDoc.fromJson("{\"version\":1, \"hint\": \"Xではじめる\"}")
            |> Option.getWithDefault(MapDoc.defaults());
        Assert.assertEq(expected = ("Xではじめる", MapDoc.rec(MapDoc.defaults())#goal), (MapDoc.rec(doc)#hint, MapDoc.rec(doc)#goal))

    @Test
    def testMapRowsLengthFollowsJson(): Unit \ Assert =
        // rows・villagers・herbs の行数を増減すれば Doc も追随する。
        let text = "{\"version\":1,"
            + " \"rows\":[\"###\",\"#.#\",\"###\"],"
            + " \"villagers\":[{\"id\":\"a\",\"x\":1,\"y\":1},{\"id\":\"b\",\"x\":1,\"y\":1}],"
            + " \"herbs\":[{\"x\":1,\"y\":1}]}";
        let doc = MapDoc.fromJson(text) |> Option.getWithDefault(MapDoc.defaults());
        Assert.assertEq(expected = (3, 2, 1),
            (List.length(MapDoc.rec(doc)#rows), List.length(MapDoc.rec(doc)#villagers), List.length(MapDoc.rec(doc)#herbs)))

    // ══════════════════════════════════════════════════════
    // KindDoc(手触りの数値)
    // ══════════════════════════════════════════════════════

    @Test
    def testKindBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        let doc = KindDoc.fromJson("{ broken") |> Option.getWithDefault(KindDoc.defaults());
        Assert.assertEq(expected = KindDoc.rec(KindDoc.defaults())#walk, KindDoc.rec(doc)#walk)

    @Test
    def testKindOverridesOneField(): Unit \ Assert =
        let doc = KindDoc.fromJson("{\"version\":1, \"walk\": 9.0}")
            |> Option.getWithDefault(KindDoc.defaults());
        Assert.assertEq(expected = (9.0, KindDoc.rec(KindDoc.defaults())#cps), (KindDoc.rec(doc)#walk, KindDoc.rec(doc)#cps))

    // ══════════════════════════════════════════════════════
    // TownMapDoc(街のタイル盤: rows と legend)
    // ══════════════════════════════════════════════════════

    @Test
    def testTownMapBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定の盤へ落ちる(街の絵は必ず出る)。
        let doc = TownMapDoc.fromJson("{ broken") |> Option.getWithDefault(TownMapDoc.defaults());
        Assert.assertEq(
            expected = (TownMapDoc.rowCount(TownMapDoc.defaults()),
                        Map.size(TownMapDoc.rec(TownMapDoc.defaults())#legend)),
            (TownMapDoc.rowCount(doc), Map.size(TownMapDoc.rec(doc)#legend)))

    @Test
    def testTownMapOverridesLegendOnly(): Unit \ Assert =
        // legend だけ書いた JSON はそこだけ効き、rows は既定のまま。
        // 2 文字以上のキーは黙って捨てられ、legend に無い文字は None(敷かれないだけ)。
        let doc = TownMapDoc.fromJson("{\"version\":1, \"legend\": {\"g\": \"tile_pave\", \"ng\": \"x\"}}")
            |> Option.getWithDefault(TownMapDoc.defaults());
        Assert.assertEq(
            expected = (Some("tile_pave"), None, TownMapDoc.rowCount(TownMapDoc.defaults())),
            (TownMapDoc.tileNameOf(doc, 'g'), TownMapDoc.tileNameOf(doc, 'n'),
             TownMapDoc.rowCount(doc)))

    @Test
    def testTownMapRowsLengthFollowsJson(): Unit \ Assert =
        // rows の行数・列数を増減すれば Doc も追随する(列数は一番長い行に合わせる)。
        let doc = TownMapDoc.fromJson("{\"version\":1, \"rows\":[\"gg\",\"gggg\",\"g\"]}")
            |> Option.getWithDefault(TownMapDoc.defaults());
        Assert.assertEq(expected = (3, 4), (TownMapDoc.rowCount(doc), TownMapDoc.cols(doc)))

    @Test
    def testGrassEdgeSelectionFollowsNeighbors(): Unit \ Assert =
        // 縁選定の代表ケース: 中央 1 マスの石畳の周囲 8 マスで、
        // 四方は縁、斜めは内角になる（rows は素材の文字のまま、縁はコードが選ぶ）。
        let doc = TownMapDoc.Doc.Doc({ rows = "ggg" :: "gpg" :: "ggg" :: Nil | TownMapDoc.rec(TownMapDoc.defaults()) });
        Assert.assertEq(
            expected = ("tile_grass_edge_s", "tile_grass_edge_n",
                        "tile_grass_edge_e", "tile_grass_edge_w",
                        "tile_grass_incorner_se", "tile_grass_incorner_nw",
                        Some("tile_pave")),
            (TownMap.grassTileAt(doc, 1, 0), TownMap.grassTileAt(doc, 1, 2),
             TownMap.grassTileAt(doc, 0, 1), TownMap.grassTileAt(doc, 2, 1),
             TownMap.grassTileAt(doc, 0, 0), TownMap.grassTileAt(doc, 2, 2),
             TownMap.groundTileAt(doc, 1, 1)))

    @Test
    def testFenceCellsAreSolid(): Unit \ {Assert, IO} =
        // 柵のマス(門の並びの隙間)は歩けない。絵(TownMap.fences)と当たり(rpg.map の '#')の
        // 対応が崩れると「見えない壁/すり抜ける柵」になるので、Doc と突き合わせて縛る。
        let map = run { MapDoc.load(MapDoc.path()) } with Fs.FileRead.runWithIO;
        Assert.assertEq(
            expected = TownMap.fences() |> List.map(_ -> true),
            TownMap.fences() |> List.map(cell -> MapDoc.solidAt(cell, map)))

    @Test
    def testPatrolRoutesStayOnWalkableCells(): Unit \ {Assert, IO} =
        // 住人の巡回路は「歩けるマスしか通らない」— これはルール。角の間も展開して、
        // 実際の間取り Doc の '#'（建物・水路・柵）と突き合わせる。
        let map = run { MapDoc.load(MapDoc.path()) } with Fs.FileRead.runWithIO;
        let cells = MapDoc.rec(map)#villagers |> List.flatMap(v -> World.routeCells(v#id));
        Assert.assertEq(
            expected = (false, cells |> List.map(_ -> true)),
            (List.isEmpty(cells),
             cells |> List.map(c ->
                 Grid.inRectOf(c, MapDoc.cols(map), MapDoc.rowCount(map))
                     and not MapDoc.solidAt(c, map))))

    // ══════════════════════════════════════════════════════
    // ThemeDoc resolver（意味色キー → 実色の派生）
    // ══════════════════════════════════════════════════════

    @Test
    def testThemeResolverDerivesWallTop(): Unit \ Assert =
        // 派生色はテーマの基準色から導かれる（導出できる値は Doc に置かない）。
        let d = ThemeDoc.defaults();
        let expectedColor = ThemeDoc.lighten(ThemeDoc.rec(d)#wall, 0.18);
        let got = ThemeDoc.resolver(d, "wallTop");
        Assert.assertEq(
            expected = (expectedColor#r, expectedColor#g, expectedColor#b),
            (got#r, got#g, got#b))
}
