// ルールと進行だけをテストする(方針どおり)。座標の写経や描画・歩きコマ・文字送りの
// 見た目はテストしない。期待値はリテラルでなく Doc(間取りの rows・既定値)から導く。
// 間取りは小さな fixture で、約束の両側(薬草が足りない / 足りる)から確かめる。
mod TestRules {

    // ══════════════════════════════════════════════════════
    // fixture: 上の通りと下の畑を、約束で開く木戸がへだてる小さな里
    //
    //   #########
    //   #*..@..G#    @ = 主人公のはじまり  G = 門番(約束の相手)
    //   ####D####    * = 薬草(左が通り・右が畑の奥)
    //   #......*#    D = 木戸(薬草 1 つの約束で開く)
    //   #########
    // ══════════════════════════════════════════════════════

    def fixture(): MapDoc.Doc =
        MapDoc.Doc.Doc({ version = 1, title = "test", subtitle = "", clear = "",
          hint = "", clearHint = "",
          start = { x = 3, y = 1 },
          rows =
                 "#########"
              :: "#.......#"
              :: "####.####"
              :: "#.......#"
              :: "#########"
              :: Nil,
          villagers =
              { id = "gate", cell = { x = 7, y = 1 }, line = "ようこそ、霧の里へ" } :: Nil,
          door = { cell = { x = 4, y = 2 }, promise = "gate", need = 1,
                   ask = "薬草を 1つ たのむよ", opened = "約束どおりだ。通っていいよ" },
          herbs = { x = 1, y = 1 } :: { x = 7, y = 3 } :: Nil,
          lamps = { x = 4, y = 0 } :: Nil,
          goal = 2 })

    def w0(): World.World =
        World.initial({ map = fixture(), kind = KindDoc.defaults(),
                        theme = ThemeDoc.defaults(), battle = BattleDoc.defaults(),
                        sprites = PxSpriteDoc.empty(), townSprites = PxSpriteDoc.empty(),
                        townMap = TownMapDoc.defaults(), waterShader = ShaderDoc.waterVeins(),
                        smokeFx = FxDoc.empty() })

    /// 表紙から歩き出した直後の状態。
    def atStart(): World.World = World.confirm(w0())

    /// 1 歩の規則を direction の列で順に適用する(テストの脚本)。
    def go(directions: List[Dir4.Dir4], w: World.World): World.World =
        directions |> List.foldLeft((acc, d) -> World.stepOnce(d, acc), w)

    /// マスを (x, y) に写す(レコードは == で比べられないので、assert は tuple で比べる)。
    def at(cell: Grid.Cell): (Int32, Int32) = (cell#x, cell#y)

    /// いま ふきだしに乗っている 1 行(閉じていれば空文字)。
    def shownLine(w: World.World): String =
        UiDialog.currentLine(w#dialog)
            |> Option.map(line -> RichText.plainText(line#body))
            |> Option.getWithDefault("")

    /// 門番の目の前(左隣)に立って門番のほうを向いた状態。
    /// 通り(y=1)に薬草は無い経路なので、拾わずに着く。
    def atGate(): World.World =
        atStart() |> go(Dir4.Right :: Dir4.Right :: Dir4.Right :: Dir4.Right :: Nil)

    // ══════════════════════════════════════════════════════
    // 進行(表紙 → 里 → クリア → 表紙)
    // ══════════════════════════════════════════════════════

    @Test
    def testTitleConfirmStartsWalk(): Unit \ Assert =
        // 表紙で決定すると、間取りの start のマスから歩き出す。
        let w = atStart();
        Assert.assertEq(expected = (World.Phase.Play, at(MapDoc.rec(fixture())#start)), (w#phase, at(w#hero)))

    @Test
    def testTitleIgnoresWalk(): Unit \ Assert =
        // 表紙では矢印を押しても歩かない(歩けるのは里の中だけ)。
        let w = World.step(Some(Dir4.Right), 10.0, w0());
        Assert.assertEq(expected = at(MapDoc.rec(fixture())#start), at(w#hero))

    @Test
    def testClearConfirmRestartsFresh(): Unit \ Assert =
        // クリアで決定すると表紙へ、もう一度決定すると仕切り直し:
        // 薬草は全部戻り、木戸は閉じ、拾った数は 0 から(死なない・詰まない)。
        let restarted = clearedWorld() |> World.confirm |> World.confirm;
        Assert.assertEq(
            expected = (World.Phase.Play, 0, false, List.length(MapDoc.rec(fixture())#herbs)),
            (restarted#phase, restarted#picked, restarted#doorOpen, List.length(restarted#herbs)))

    // ══════════════════════════════════════════════════════
    // 歩ける・ぶつかる(壁・住人・木戸)
    // ══════════════════════════════════════════════════════

    @Test
    def testWallBlocksButFloorPasses(): Unit \ Assert =
        // 石垣へは進めない(向きだけ変わる)。道へは 1 マス進む。
        let blocked = World.stepOnce(Dir4.Up, atStart());
        let moved = World.stepOnce(Dir4.Right, atStart());
        Assert.assertEq(
            expected = (at(MapDoc.rec(fixture())#start), Dir4.Up, at(Grid.neighborOf(MapDoc.rec(fixture())#start, Dir4.Right))),
            (at(blocked#hero), blocked#facing, at(moved#hero)))

    @Test
    def testVillagerBlocksStep(): Unit \ Assert =
        // 住人の立つマスへは進めない(すり抜けたり重なったりしない)。
        let w = World.stepOnce(Dir4.Right, atGate());
        Assert.assertEq(expected = at(Grid.neighborOf(gateCell(), Dir4.Left)), at(w#hero))

    @Test
    def testClosedDoorBlocks(): Unit \ Assert =
        // 閉じた木戸のマスへは進めない。開いていれば通れる(鍵は約束だけ)。
        let beforeDoor = atStart() |> go(Dir4.Right :: Nil);
        let closed = World.stepOnce(Dir4.Down, beforeDoor);
        let opened = World.stepOnce(Dir4.Down, { doorOpen = true | beforeDoor });
        Assert.assertEq(
            expected = (at(beforeDoor#hero), at(MapDoc.rec(fixture())#door#cell)),
            (at(closed#hero), at(opened#hero)))

    // ══════════════════════════════════════════════════════
    // 話す(ふきだし)と約束の規則
    // ══════════════════════════════════════════════════════

    @Test
    def testConfirmFacingNobodyDoesNothing(): Unit \ Assert =
        // 目の前に住人がいなければ、決定を押しても何も起きない。
        let w = World.confirm(atStart());
        Assert.assertEq(expected = false, UiDialog.isOpen(w#dialog))

    @Test
    def testPromiseUnmetShowsAskAndKeepsClosed(): Unit \ Assert =
        // 薬草が足りないうちは、約束の相手は頼まれごと(ask)を話し、木戸は閉じたまま。
        let w = World.confirm(atGate());
        Assert.assertEq(
            expected = (MapDoc.rec(fixture())#door#ask, false),
            (shownLine(w), w#doorOpen))

    @Test
    def testPromiseMetOpensDoor(): Unit \ Assert =
        // 頼まれた数の薬草を持って話すと、その場で木戸が開き、opened の 1 行が出る。
        let w = World.confirm(herbInHandAtGate());
        Assert.assertEq(
            expected = (MapDoc.rec(fixture())#door#opened, true),
            (shownLine(w), w#doorOpen))

    @Test
    def testOpenedGateSpeaksUsualLine(): Unit \ Assert =
        // 木戸が開いた後は、約束の相手もいつもの 1 行に戻る。
        let opened = World.confirm(herbInHandAtGate()) |> World.confirm |> World.confirm;
        let w = World.confirm(opened);
        Assert.assertEq(expected = gateLine(), shownLine(w))

    @Test
    def testDialogBlocksMovement(): Unit \ Assert =
        // ふきだしが開いている間は歩けない(会話中に動かないのはルール)。
        let talking = World.confirm(atGate());
        let w = World.step(Some(Dir4.Left), 10.0, talking);
        Assert.assertEq(expected = at(talking#hero), at(w#hero))

    // ══════════════════════════════════════════════════════
    // 収支(薬草の拾いとクリア)
    // ══════════════════════════════════════════════════════

    @Test
    def testHerbPickedOnlyOnce(): Unit \ Assert =
        // 薬草のマスを踏むと 1 つ拾い、盤から消える。同じマスを踏み直しても増えない。
        let picked = atStart() |> go(Dir4.Left :: Dir4.Left :: Nil);
        let revisited = picked |> go(Dir4.Right :: Dir4.Left :: Nil);
        Assert.assertEq(
            expected = (1, List.length(MapDoc.rec(fixture())#herbs) - 1),
            (revisited#picked, List.length(revisited#herbs)))

    @Test
    def testGoalReachedClears(): Unit \ Assert =
        // 通しの脚本: 薬草を拾い、約束を果たして木戸を開け、奥の薬草で goal に届くとクリア。
        let w = clearedWorld();
        Assert.assertEq(
            expected = (World.Phase.Clear, World.goalOf(w)),
            (w#phase, w#picked))

    @Test
    def testGoalClampedToPlacedHerbs(): Unit \ Assert =
        // goal が置いてある薬草より多くても、クリアに要る数は置いた数まで(詰みを作らない)。
        let greedy = World.initial({ map = MapDoc.Doc.Doc({ goal = 99 | MapDoc.rec(fixture()) }), kind = KindDoc.defaults(),
                                     theme = ThemeDoc.defaults(), battle = BattleDoc.defaults(),
                                     sprites = PxSpriteDoc.empty(), townSprites = PxSpriteDoc.empty(),
                                     townMap = TownMapDoc.defaults(), waterShader = ShaderDoc.waterVeins(),
                                     smokeFx = FxDoc.empty() });
        Assert.assertEq(expected = List.length(MapDoc.rec(fixture())#herbs), World.goalOf(greedy))

    // ══════════════════════════════════════════════════════
    // 表示中の Doc の名乗り(Studio のバッジの材料。どの id を名乗るかはルール)
    // ══════════════════════════════════════════════════════

    @Test
    def testActiveDocsFollowPhase(): Unit \ Assert =
        // 表紙とクリアでは手触り(kind)を名乗らない — 里を歩いている間だけ加わる。
        // 戦いの最中は盤(map)が隠れ、代わりに戦いの数・文言(battle)が出る。
        // id は project.json の editor 宣言と対(Studio が突き合わせに使う)。
        // 並びは Controls.docTable() の行の順。
        Assert.assertEq(
            expected = ("map" :: "theme" :: "sprite" :: Nil,
                        "map" :: "kind" :: "theme" :: "sprite" :: Nil,
                        "map" :: "theme" :: "sprite" :: Nil,
                        "theme" :: "battle" :: "sprite" :: Nil),
            (Controls.activeDocs(w0()) |> List.map(fst),
             Controls.activeDocs(atStart()) |> List.map(fst),
             Controls.activeDocs(clearedWorld()) |> List.map(fst),
             Controls.activeDocs(met()) |> List.map(fst)))

    // ── 脚本の小物(期待値はぜんぶ fixture から引く) ──

    def gateCell(): Grid.Cell =
        List.head(MapDoc.rec(fixture())#villagers)
            |> Option.map(villager -> villager#cell)
            |> Option.getWithDefault({ x = -1, y = -1 })

    def gateLine(): String =
        List.head(MapDoc.rec(fixture())#villagers)
            |> Option.map(villager -> villager#line)
            |> Option.getWithDefault("(fixture が壊れている)")

    /// 左の通りの薬草を 1 つ拾ってから門番の前へ戻った状態(往復 = 実際の遊びと同じ経路)。
    def herbInHandAtGate(): World.World =
        atStart()
            |> go(Dir4.Left :: Dir4.Left :: Nil)
            |> go(Dir4.Right :: Dir4.Right :: Dir4.Right :: Dir4.Right :: Dir4.Right :: Dir4.Right :: Nil)

    /// 表紙からクリアまで規則だけで通した状態。
    /// 薬草を拾う → 門番と約束を果たす → ふきだしを閉じる → 木戸を抜けて奥の薬草へ。
    def clearedWorld(): World.World =
        herbInHandAtGate()
            |> World.confirm                     // 門番: 約束が果たされ木戸が開く
            |> World.confirm |> World.confirm    // ふきだしを送って閉じる
            |> go(Dir4.Left :: Dir4.Left :: Nil)
            |> go(Dir4.Down :: Dir4.Down :: Nil)
            |> go(Dir4.Right :: Dir4.Right :: Dir4.Right :: Nil)

    // ══════════════════════════════════════════════════════
    // 戦い（歩数で出会う・殴り合う・逃げる・倒れても詰まない）
    // ══════════════════════════════════════════════════════

    /// 魔物と出会った直後の状態（出会いの 1 行を読んでいるところ）。
    def met(): World.World =
        let d = BattleDoc.rec(BattleDoc.defaults());
        { phase = World.Phase.Battle, steps = d#encounterSteps,
          battle = { step = World.BattleStep.Report, cursor = 0, foeHp = d#foeMaxHp,
                     lines = Nil, foeHurt = false, outcome = None } | atStart() }

    /// コマンドを選べる段まで進めた状態。
    def choosing(): World.World = World.confirm(met())

    @Test
    def testFoeAppearsEveryEncounterSteps(): Unit \ Assert =
        // encounterSteps 歩ちょうどで出会い、その手前では出会わない。
        let d = BattleDoc.defaults();
        Assert.assertEq(
            expected = (false, true, false, true),
            (World.meetsFoeAt(0, d),
             World.meetsFoeAt(BattleDoc.rec(d)#encounterSteps, d),
             World.meetsFoeAt(BattleDoc.rec(d)#encounterSteps + 1, d),
             World.meetsFoeAt(BattleDoc.rec(d)#encounterSteps * 2, d)))

    @Test
    def testFoeNeverAppearsWhenStepsIsZero(): Unit \ Assert =
        // encounterSteps を 0 にすると魔物は出ない（戦いを外した遊びも作れる）。
        let quiet = BattleDoc.Doc.Doc({ encounterSteps = 0 | BattleDoc.rec(BattleDoc.defaults()) });
        Assert.assertEq(expected = false, World.meetsFoeAt(40, quiet))

    @Test
    def testStrikeHurtsBothSides(): Unit \ Assert =
        // 「たたかう」1 回で、魔物は heroAttack ぶん減り、こちらは foeAttack ぶん減る。
        let d = BattleDoc.rec(BattleDoc.defaults());
        let after = World.confirm(choosing());
        Assert.assertEq(
            expected = (d#foeMaxHp - d#heroAttack, d#heroMaxHp - d#foeAttack),
            (after#battle#foeHp, after#heroHp))

    @Test
    def testKillingFoeEndsBattleWithWin(): Unit \ Assert =
        // 魔物の体力が一撃ぶんしか無ければ、その 1 回で決着（勝ち）になり反撃も受けない。
        let d = BattleDoc.rec(BattleDoc.defaults());
        let weak = { battle = { foeHp = d#heroAttack | choosing()#battle } | choosing() };
        let after = World.confirm(weak);
        Assert.assertEq(
            expected = (Some(World.Outcome.Win), d#heroMaxHp),
            (after#battle#outcome, after#heroHp))

    @Test
    def testFleeAlwaysReturnsToVillage(): Unit \ Assert =
        // 「にげる」を選ぶと必ず逃げられ、決定をもう 1 回で里へ戻る（詰ませない）。
        let fleeing = World.confirm(World.moveCursor(1, choosing()));
        let back = World.confirm(fleeing);
        Assert.assertEq(
            expected = (Some(World.Outcome.Flee), World.Phase.Play),
            (fleeing#battle#outcome, back#phase))

    @Test
    def testLosingSendsHeroBackAliveToStart(): Unit \ Assert =
        // 倒れても終わりではない: 入口へ戻り、体力は満タンに戻る（やり直せる）。
        let d = BattleDoc.rec(BattleDoc.defaults());
        let dying = { heroHp = d#foeAttack | choosing() };
        let lost = World.confirm(dying);
        let back = World.confirm(lost);
        Assert.assertEq(
            expected = (Some(World.Outcome.Lose), World.Phase.Play, d#heroMaxHp, true),
            (lost#battle#outcome, back#phase, back#heroHp,
             MapDoc.sameCell(back#hero, MapDoc.rec(back#map)#start)))

    @Test
    def testCursorStaysInsideCommandList(): Unit \ Assert =
        // カーソルはコマンドの外へ出ない（端で止まる）。
        let last = List.length(World.battleCommands()) - 1;
        let up = World.moveCursor(-1, choosing());
        let down = World.moveCursor(1, World.moveCursor(1, choosing()));
        Assert.assertEq(expected = (0, last), (up#battle#cursor, down#battle#cursor))
}
