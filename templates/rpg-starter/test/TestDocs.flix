// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで）と、Doc どうし・会話の語彙の食い違い。
mod TestDocs {
    use fge::{Yarn}

    // ══════════════════════════════════════════════════════
    // MapDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None（MapDoc.load はそこで既定の 1 マスの草地へ落ちる）。
    @Test
    def testMapBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, MapDoc.fromJson(ItemsDoc.defaults(), "village", "{ broken") |> Option.map(doc -> MapDoc.rec(doc)#rows))

    /// rows だけ書いた JSON は、組の既定（village）と、出入口・人・小物の無いマップになる。
    @Test
    def testMapWithOnlyRows(): Unit \ Assert =
        Assert.assertEq(expected = Some((Tileset.TilesetId.Village, 3, 2, 0)),
            MapDoc.fromJson(ItemsDoc.defaults(), "x", "{\"version\":1, \"rows\":[\"...\", \"...\"]}")
                |> Option.map(doc -> { let m = MapDoc.rec(doc); (m#tileset, m#cols, m#height, Map.size(m#npcAt)) }))

    /// 人の一覧は JSON の行に追随し、読めない行（x が無い 2 行目）だけ飛ばして、その行を問題に挙げる。
    @Test
    def testMapNpcsFollowTheRows(): Unit \ Assert =
        let text = "{\"version\":1, \"rows\":[\"...\"], \"npcs\":[" +
            "{\"id\":\"a\", \"sprite\":\"woman\", \"x\":0, \"y\":0}," +
            "{\"id\":\"b\", \"sprite\":\"child\", \"y\":0}," +
            "{\"id\":\"c\", \"sprite\":\"child\", \"x\":2, \"y\":0, \"node\":\"Child\"}]}";
        Assert.assertEq(expected = Some((2, "[map] x の npcs の 2 行目を読めないので飛ばす" :: Nil)),
            MapDoc.fromJson(ItemsDoc.defaults(), "x", text) |> Option.map(doc -> (Map.size(MapDoc.rec(doc)#npcAt), MapDoc.rec(doc)#problems)))

    // ══════════════════════════════════════════════════════
    // RulesDoc・KeysDoc・TextDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None。
    @Test
    def testRulesBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, RulesDoc.fromJson("{ broken") |> Option.map(doc -> RulesDoc.rec(doc)#cps))

    /// 1 欄だけ書いた JSON はそこだけ効き、残りは既定のまま。
    @Test
    def testRulesOverridesOneField(): Unit \ Assert =
        Assert.assertEq(expected = Some((0.5, RulesDoc.rec(RulesDoc.defaults())#cps)),
            RulesDoc.fromJson("{\"version\":1, \"secondsPerTile\": 0.5}") |> Option.map(doc -> (RulesDoc.rec(doc)#secondsPerTile, RulesDoc.rec(doc)#cps)))

    /// 知らない向きの名前の startFacing は既定の向きへ落ちる。
    @Test
    def testRulesUnknownFacingFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = Some(RulesDoc.rec(RulesDoc.defaults())#startFacing),
            RulesDoc.fromJson("{\"version\":1, \"startFacing\": \"sideways\"}") |> Option.map(doc -> RulesDoc.rec(doc)#startFacing))

    /// 知らないキーの名前だけの操作は既定のキーへ落ちる（書き間違いで操作できなくしない）。
    @Test
    def testKeysWithOnlyUnknownNamesFallBack(): Unit \ Assert =
        Assert.assertEq(expected = Some(KeysDoc.rec(KeysDoc.defaults())#confirm),
            KeysDoc.fromJson("{\"version\":1, \"confirm\": [\"NoSuchKey\"]}") |> Option.map(doc -> KeysDoc.rec(doc)#confirm))

    /// 呼び名の無い話し手は id のまま・書いていないメニューの言葉はコードの既定。
    @Test
    def testTextFallsBackPerEntry(): Unit \ Assert =
        Assert.assertEq(expected = Some(("むらおさ", "woman", "はい")),
            TextDoc.fromJson("{\"version\":1, \"speakers\": {\"chief\": {\"name\": \"むらおさ\"}}}")
                |> Option.map(doc -> (TextDoc.speakerName("chief", doc), TextDoc.speakerName("woman", doc), TextDoc.menuText(TextDoc.MenuText.Yes, doc))))

    // ══════════════════════════════════════════════════════
    // PartyDoc・ItemsDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None（PartyDoc.load はそこで既定へ落ちる）。
    @Test
    def testPartyBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, PartyDoc.fromJson("{ broken") |> Option.map(doc -> PartyDoc.memberOf(Member.Member.Luka, doc)#sprite))

    /// 1 人の sprite だけ書いた JSON はその人だけに効き、行の無い人はコードの既定の絵（ルカは hero）。
    @Test
    def testPartyOverridesOneMember(): Unit \ Assert =
        Assert.assertEq(expected = Some(("hero", "child")),
            PartyDoc.fromJson("{\"version\":1, \"members\": {\"mina\": {\"sprite\": \"child\"}}}")
                |> Option.map(doc -> (PartyDoc.memberOf(Member.Member.Luka, doc)#sprite, PartyDoc.memberOf(Member.Member.Mina, doc)#sprite)))

    /// 読めない行（sprite が無い mina）はその人だけ既定へ落ち、読める行（luka）は効く。
    @Test
    def testPartyRowsFallBackOneByOne(): Unit \ Assert =
        Assert.assertEq(expected = Some(("woman", "mina")),
            PartyDoc.fromJson("{\"version\":1, \"members\": {\"luka\": {\"sprite\": \"woman\"}, \"mina\": {\"name\": \"ミナ\"}}}")
                |> Option.map(doc -> (PartyDoc.memberOf(Member.Member.Luka, doc)#sprite, PartyDoc.memberOf(Member.Member.Mina, doc)#sprite)))

    /// 道具の catalog は行に追随し、name の無い行だけ飛ばしてその行を問題に挙げる。
    @Test
    def testItemsFollowTheRows(): Unit \ Assert =
        let text = "{\"version\":1, \"items\": {\"a\": {\"name\": \"A\"}, \"b\": {}, \"c\": {\"name\": \"C\"}}}";
        Assert.assertEq(expected = Some(("a" :: "c" :: Nil, "[items] 'b' の行を読めない（name が無いか kind が use / weapon / armor / key でない）ので飛ばす" :: Nil)),
            ItemsDoc.fromJson(text) |> Option.map(doc -> (ItemsDoc.keysOf(doc), ItemsDoc.rec(doc)#problems)))

    /// kind と数の欄を省いた道具は、使う物・値段 0・誰も装備できない。kind を読めない行は飛ばす。
    @Test
    def testItemsDefaultTheOmittedFields(): Unit \ Assert =
        let text = "{\"version\":1, \"items\": {\"a\": {\"name\": \"A\"}, \"b\": {\"name\": \"B\", \"kind\": \"food\"}}}";
        Assert.assertEq(expected = Some((Some((ItemsDoc.Kind.Use, 0, Set.empty())), ("a" :: Nil))),
            ItemsDoc.fromJson(text) |> Option.map(doc ->
                (ItemsDoc.idOf(doc, "a") |> Option.flatMap(ItemsDoc.itemOf(doc)) |> Option.map(item -> (item#kind, item#price, item#equip)), ItemsDoc.keysOf(doc))))

    // ══════════════════════════════════════════════════════
    // ShopsDoc
    // ══════════════════════════════════════════════════════

    /// 読めない JSON は None（ShopsDoc.load はそこで品の無い店へ落ちる）。
    @Test
    def testShopsBrokenJsonIsNone(): Unit \ Assert =
        Assert.assertEq(expected = None, ShopsDoc.fromJson("{ broken") |> Option.map(doc -> ShopsDoc.rec(doc)#innPrice))

    /// innPrice だけ書いた JSON はそこだけ反映され、品は無い。
    @Test
    def testShopsOverridesTheInnPrice(): Unit \ Assert =
        Assert.assertEq(expected = Some((10, Nil)),
            ShopsDoc.fromJson("{\"version\":1, \"innPrice\": 10}") |> Option.map(doc -> (ShopsDoc.rec(doc)#innPrice, ShopsDoc.goodsOf("", doc))))

    /// 品の一覧は JSON の行に追随し、item の無い 2 行目だけ飛ばしてその行を問題に挙げる。shop を書かない行は村の道具屋（空の名前）。
    @Test
    def testShopsGoodsFollowTheRows(): Unit \ Assert =
        let text = "{\"version\":1, \"goods\": [{\"item\": \"a\"}, {}, {\"item\": \"c\", \"shop\": \"mine\"}]}";
        Assert.assertEq(expected = Some(("a" :: Nil, "c" :: Nil, "[shops] goods の 2 行目に item が無いので飛ばす" :: Nil)),
            ShopsDoc.fromJson(text) |> Option.map(doc -> (ShopsDoc.goodsOf("", doc), ShopsDoc.goodsOf("mine", doc), ShopsDoc.rec(doc)#problems)))

    // ══════════════════════════════════════════════════════
    // Doc どうし
    // ══════════════════════════════════════════════════════

    /// assets の Doc に食い違いが無い（出入口の行き先・人と gate の会話のノード・始まりのマップ・
    /// 会話のコマンドの引数が Doc で引ける・World から写す変数を <<set>> で書いていない）。
    @Test
    def testAssetsHaveNoProblems(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Nil, Res.problemsOf(Res.load()))

    /// 全部の台詞が、出し切った時に会話のウィンドウ 1 枚に収まる（収まらない台詞は yarn で 2 行に分ける）。
    @Test
    def testEveryLineFitsTheTalkWindow(): Unit \ Assert + Fs.FileRead + IO =
        let res = Res.load();
        Assert.assertEq(expected = Nil, FieldScreen.overflowingLines(Fixtures.windowEnv(res), Talk.linesOf(res#dialogue)))

    /// assets/maps の *.map.json は全部 MapDoc.names に載っている（載せ忘れたマップは読まれず、出入口の行き先が無いと言われる）。
    @Test
    def testEveryMapFileIsListed(): Unit \ Assert + Fs.DirList =
        Assert.assertEq(expected = Ok(Nil), Fs.DirList.list("assets/maps") |> Result.map(MapDoc.unlistedIn))

    /// マップのスキーマの gate に書ける名前は、空（gate 無し）と仲間の名前（Member.ids）だけ。
    @Test
    def testGateNamesInTheSchemaAreTheMembers(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some("" :: Member.ids()), Fixtures.schemaGateNames())

    /// Doc で引けないコマンドの引数（無い道具・居ない仲間・どのマップにも無い物の id）は 1 つずつ問題に挙がり、引ける物（accept）は挙がらない。
    @Test
    def testUnknownCommandArgsAreProblems(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let tree = Fixtures.command("give", "nosuch") + "," + Fixtures.command("join", "nobody") + "," + Fixtures.command("open", "nosuch") + "," +
                   Fixtures.command("quest", "accept");
        Assert.assertEq(expected = Some(3), Talk.fromJson(Fixtures.treeOf(tree)) |> Option.map(program -> List.length(Talk.problemsOf(res#items, res#foes, Set#{"cave_mole"}, program))))

    /// World から写す変数（$gold）への <<set>> は問題に挙がる（書いても次の写しで消える）。
    @Test
    def testSetOnACopiedVarIsAProblem(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let set = "{\"kind\":\"set\",\"line\":2,\"name\":\"$gold\",\"expr\":{\"kind\":\"value\",\"value\":5}}";
        Assert.assertEq(expected = Some(1), Talk.fromJson(Fixtures.treeOf(set)) |> Option.map(program -> List.length(Talk.problemsOf(res#items, res#foes, Set.empty(), program))))

    /// 会話の語彙 assets/talk/vocab.json が、コードの語彙（Talk.vocabOf）と同じ（ずれたら make talk-vocab）。
    @Test
    def testTalkVocabMatchesTheCode(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Ok(String.trim(Yarn.vocabJson(Talk.vocabOf(MapDoc.loadTable(ItemsDoc.load(ItemsDoc.path())), TextDoc.load(TextDoc.path()))))),
            Fs.FileRead.read(Talk.vocabPath()) |> Result.map(String.trim))
}
