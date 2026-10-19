// ルールと進行だけをテストする（方針どおり）。座標の写経や描画・文字送りの見た目はテストしない。
// 期待値はリテラルでなく Doc（シナリオ・既定値）から導く。
// シナリオは小さな fixture（test/talk/fixture.yarn・分岐 1 つ・結末 2 つ）で、規則を両側（疑う / 疑わない）から確かめる。
mod TestRules {

    use fge::{Emit, PxSpriteDoc, RichText, UiDialog, UiStore, Yarn, YarnRunner}

    /// 規則が出す返事の出来事（Emit）を捨てて World だけを見る（ここのテストは進行と灯りを見る）。
    def advance(w: World.World): World.World = fst(Emit.collect(() -> World.advance(w)))

    def pick(i: Int32, w: World.World): World.World = fst(Emit.collect(() -> World.pick(i, w)))

    // ══════════════════════════════════════════════════════
    // fixture: arrival で 1 分岐 → endA（疑う）/ endB（疑わない）
    //
    //   arrival: 行 a → 行 b → 問い + 選択肢 ──[疑う]──→ endA (1 行で結末)
    //                                       └─[疑わない]→ endB (1 行で結末)
    // ══════════════════════════════════════════════════════

    def fixture(): Yarn.Program \ Fs.FileRead = TestKit.fixtureDialogue()

    def fixtureRec(): StoryDoc.Rec = StoryDoc.rec(StoryDoc.defaults())

    def w0(): World.World \ Fs.FileRead =
        World.initial({ story = StoryDoc.defaults(), dialogue = fixture(), kind = KindDoc.defaults(), keys = KeysDoc.defaults(),
                        theme = ThemeDoc.defaults(), sprites = PxSpriteDoc.empty() },
                      UiStore.empty())

    /// 文字送りを使い切って 1 行読み終えた状態にする（テストは速さを検査しない）。
    def settle(w: World.World): World.World = TestKit.stepBy(1000.0, w)

    /// 表紙から最初の分岐（選択肢待ち）まで進めた状態。
    def atAsk(): World.World \ Fs.FileRead =
        w0() |> advance |> settle |> advance |> settle |> advance |> settle

    // ══════════════════════════════════════════════════════
    // 進行の規則
    // ══════════════════════════════════════════════════════

    @Test
    def testTitleConfirmBeginsStory(): Unit \ {Assert, Fs.FileRead} =
        // 表紙で決定すると、コードが開くノード（Talk.Node.Arrival）から物語がはじまる。
        let w = advance(w0());
        Assert.assertEq(expected = (World.Phase.Story, Some(Talk.nodeName(Talk.Node.Arrival))),
            (w#phase, YarnRunner.nodeOf(w#talk)))

    @Test
    def testAdvanceReadsBeatsInOrder(): Unit \ {Assert, Fs.FileRead} =
        // 読み終えた行を送ると、同じノードの次の行がダイアログに乗る（本文はシナリオから導く）。
        let w = w0() |> advance |> settle |> advance;
        let shown = UiDialog.currentLine(w#kit#dialog)
            |> Option.map(line -> RichText.plainText(line#body))
            |> Option.getWithDefault("");
        Assert.assertEq(expected = fixtureLine(1), shown)

    @Test
    def testAskBlocksAdvance(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢待ちでは決定で先へ進めない（pick だけが進める）。
        let asking = atAsk();
        let w = asking |> advance |> settle;
        Assert.assertEq(expected = (true, YarnRunner.nodeOf(asking#talk)),
            (NovelKit.isAsking(w#kit), YarnRunner.nodeOf(w#talk)))

    @Test
    def testPickFollowsJump(): Unit \ {Assert, Fs.FileRead} =
        // 選んだ選択肢の中身の <<jump>> の先のノードへ移る（行き先はシナリオから導く）。
        let w = pick(0, atAsk());
        Assert.assertEq(expected = fixtureJump(0), YarnRunner.nodeOf(w#talk))

    @Test
    def testEndingReturnsToTitle(): Unit \ {Assert, Fs.FileRead} =
        // 結末のノード（<<jump>> の無いノード）の最後の行を送ると表紙へ戻る。死なない・詰まない。
        let w = pick(0, atAsk()) |> settle |> advance;
        Assert.assertEq(expected = World.Phase.Title, w#phase)

    // ══════════════════════════════════════════════════════
    // 灯りの規則（疑うと消える・収支）
    // ══════════════════════════════════════════════════════

    @Test
    def testSuspectPickPutsOutOneLamp(): Unit \ {Assert, Fs.FileRead} =
        // #suspect の選択肢を選ぶと灯りがひとつ消える（選択肢が #suspect なことも fixture から確かめる）。
        let w = pick(0, atAsk());
        Assert.assertEq(expected = (true, 1, fixtureRec()#lamps - 1),
            (fixtureSuspect(0), w#lightsOut, World.lampsLit(w)))

    @Test
    def testCalmPickKeepsLamps(): Unit \ {Assert, Fs.FileRead} =
        // #suspect でない選択肢では灯りは消えない。
        let w = pick(1, atAsk());
        Assert.assertEq(expected = (false, 0), (fixtureSuspect(1), w#lightsOut))

    @Test
    def testLightsNeverExceedLamps(): Unit \ {Assert, Fs.FileRead} =
        // 灯りは novel.story.json の lamps より多くは消えない（残りが負にならない）。
        let dark = { lightsOut = fixtureRec()#lamps | atAsk() };
        let w = pick(0, dark);
        Assert.assertEq(expected = (fixtureRec()#lamps, 0), (w#lightsOut, World.lampsLit(w)))

    @Test
    def testRestartRelightsLamps(): Unit \ {Assert, Fs.FileRead} =
        // 結末から表紙へ戻り、もう一度はじめると灯りは全部つき直る（新しい夜）。
        let ended = pick(0, atAsk()) |> settle |> advance;
        let w = advance(ended);
        Assert.assertEq(expected = (World.Phase.Story, 0), (w#phase, w#lightsOut))

    // ══════════════════════════════════════════════════════
    // メニュー（物語の時計を止める窓）
    // ══════════════════════════════════════════════════════

    @Test
    def testMenuStopsTypewriter(): Unit \ {Assert, Fs.FileRead} =
        // メニューを開いている間は物語の時計が止まり、どれだけ置いても文字送りは進まない。
        let opened = World.toggleMenu(advance(w0()));
        let w = settle(settle(opened));
        Assert.assertEq(expected = (World.Menu.Open, false), (w#menu, UiDialog.lineDone(w#kit#dialog)))

    @Test
    def testMenuNeverOpensOnTitle(): Unit \ {Assert, Fs.FileRead} =
        // 表紙には止める物語が無いのでメニューは開かない（同じキーは終了に回る）。
        Assert.assertEq(expected = World.Menu.Closed, World.toggleMenu(w0())#menu)

    // ══════════════════════════════════════════════════════
    // 表示中の Doc の名乗り（Studio のバッジの材料。どの id を名乗るかはルール）
    // ══════════════════════════════════════════════════════

    @Test
    def testActiveDocsFollowPhase(): Unit \ {Assert, Fs.FileRead} =
        // 表紙ではダイアログ（ui）と手触り（kind）を名乗らない — 本文に入ってから加わる。
        // id は project.json の editor 宣言と対（Studio が突き合わせに使う）。
        // 並びは Controls.docTable() の行の順。
        Assert.assertEq(
            expected = ("story" :: "keys" :: "theme" :: "sprite" :: Nil,
                        "story" :: "kind" :: "keys" :: "theme" :: "sprite" :: "ui" :: Nil),
            (Controls.activeDocs(w0()) |> List.map(fst),
             Controls.activeDocs(advance(w0())) |> List.map(fst)))

    /// ui は 1 つの id に 2 本のパスが束なる（ダイアログと選択肢）。
    @Test
    def testActiveDocsGroupsBothUiPaths(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(
            expected = Some(NovelKit.uiPaths()),
            Controls.activeDocs(advance(w0()))
                |> List.filter(e -> fst(e) == "ui") |> List.map(snd) |> List.head)

    // ── fixture のシナリオから期待値を引く小物 ──

    /// arrival のノードの n 番目（0 始まり）の台詞の字。
    def fixtureLine(n: Int32): String \ Fs.FileRead =
        arrivalBody() |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Say(line) => Some(line#text)
            case _                        => None
        }) |> List.nth(n) |> Option.getWithDefault("(fixture が壊れている)")

    /// arrival の選択肢の i 番目。
    def fixtureOption(i: Int32): Option[Yarn.Choice] \ Fs.FileRead =
        arrivalBody() |> List.filterMap(statement -> match statement {
            case Yarn.Statement.Choose(choices) => Some(choices)
            case _                              => None
        }) |> List.head |> Option.flatMap(List.nth(i))

    /// arrival の選択肢 i の中身の <<jump>> の先。
    def fixtureJump(i: Int32): Option[String] \ Fs.FileRead =
        fixtureOption(i) |> Option.flatMap(choice -> choice#body |> List.head) |> Option.flatMap(statement -> match statement {
            case Yarn.Statement.Jump(node, _) => Some(node)
            case _                            => None
        })

    def fixtureSuspect(i: Int32): Bool \ Fs.FileRead = fixtureOption(i) |> Option.map(choice -> Talk.isSuspect(choice#line)) |> Option.getWithDefault(false)

    def arrivalBody(): List[Yarn.Statement] \ Fs.FileRead =
        Yarn.nodeOf(Talk.nodeName(Talk.Node.Arrival), fixture()) |> Option.map(node -> node#body) |> Option.getWithDefault(Nil)
}
