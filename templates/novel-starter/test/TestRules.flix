// ルールと進行だけをテストする（方針どおり）。座標の写経や描画・文字送りの見た目はテストしない。
// 期待値はリテラルでなく Doc（台本の rows・既定値）から導く。
// 台本は小さな fixture（分岐 1 つ・結末 2 つ）で、規則を両側（疑う / 疑わない）から確かめる。
mod TestRules {

    // ══════════════════════════════════════════════════════
    // fixture: hall で 1 分岐 → endA（疑う）/ endB（疑わない）
    //
    //   hall: beat a → beat b → ask ──[疑う]──→ endA (1 ビートで結末)
    //                              └─[疑わない]→ endB (1 ビートで結末)
    // ══════════════════════════════════════════════════════

    def beat(speaker: String, text: String): StoryDoc.Beat =
        { speaker = speaker, text = text }

    def fixture(): StoryDoc.Doc =
        StoryDoc.Doc.Doc({
          version = 1, title = "test", subtitle = "", hint = "", start = "hall", lamps = 2,
          sections =
              { id = "hall", beats = beat("", "雨の音。") :: beat("私", "壁の色が違う。") :: Nil,
                ask = Some({ speaker = "私", text = "誰を疑う?",
                             options =
                                 { label = "疑う", goto = "endA", suspect = true }
                              :: { label = "疑わない", goto = "endB", suspect = false } :: Nil }),
                next = "" }
           :: { id = "endA", beats = beat("", "結末A。") :: Nil, ask = None, next = "" }
           :: { id = "endB", beats = beat("", "結末B。") :: Nil, ask = None, next = "" }
           :: Nil })

    def fixtureRec(): StoryDoc.Rec = StoryDoc.rec(fixture())

    def w0(): World.World =
        World.initial({ story = fixture(), kind = KindDoc.defaults(),
                        theme = ThemeDoc.defaults(), sprites = PxSpriteDoc.empty() },
                      UiStore.empty())

    /// 文字送りを使い切って 1 ビート読み終えた状態にする（テストは速さを検査しない）。
    def settle(w: World.World): World.World = World.step(1000.0, w)

    /// 表紙から最初の分岐（選択肢待ち）まで進めた状態。
    def atAsk(): World.World =
        w0() |> World.advance |> settle |> World.advance |> settle |> World.advance |> settle

    // ══════════════════════════════════════════════════════
    // 進行の規則
    // ══════════════════════════════════════════════════════

    @Test
    def testTitleConfirmBeginsStory(): Unit \ Assert =
        // 表紙で決定すると、台本の start の節から物語がはじまる。
        let w = World.advance(w0());
        Assert.assertEq(expected = (World.Phase.Story, fixtureRec()#start, 0),
            (w#phase, w#section, w#idx))

    @Test
    def testAdvanceReadsBeatsInOrder(): Unit \ Assert =
        // 読み終えたビートを送ると、同じ節の次のビートがダイアログに乗る（本文は台本の rows から導く）。
        let w = w0() |> World.advance |> settle |> World.advance;
        let shown = UiDialog.currentLine(w#kit#dialog)
            |> Option.map(line -> RichText.plainText(line#body))
            |> Option.getWithDefault("");
        let wanted = StoryDoc.sectionOf(fixtureRec()#start, fixture())
            |> Option.flatMap(section -> List.nth(1, section#beats))
            |> Option.map(b -> b#text)
            |> Option.getWithDefault("(fixture が壊れている)");
        Assert.assertEq(expected = wanted, shown)

    @Test
    def testAskBlocksAdvance(): Unit \ Assert =
        // 選択肢待ちでは決定で先へ進めない（pick だけが進める）。
        let asking = atAsk();
        let w = asking |> World.advance |> settle;
        Assert.assertEq(expected = (true, asking#section, asking#idx),
            (NovelKit.isAsking(w#kit), w#section, w#idx))

    @Test
    def testPickFollowsGoto(): Unit \ Assert =
        // 選んだ選択肢の goto の節の先頭へ移る（行き先は台本の rows から導く）。
        let firstGoto = fixtureOption(0)#goto;
        let w = World.pick(0, atAsk());
        Assert.assertEq(expected = (firstGoto, 0), (w#section, w#idx))

    @Test
    def testEndingReturnsToTitle(): Unit \ Assert =
        // 結末の節（ask も next も無い）の最後のビートを送ると表紙へ戻る。死なない・詰まない。
        let w = World.pick(0, atAsk()) |> settle |> World.advance;
        Assert.assertEq(expected = World.Phase.Title, w#phase)

    // ══════════════════════════════════════════════════════
    // 灯りの規則（疑うと消える・収支）
    // ══════════════════════════════════════════════════════

    @Test
    def testSuspectPickPutsOutOneLamp(): Unit \ Assert =
        // suspect の選択肢を選ぶと灯りがひとつ消える（選択肢が suspect なことも fixture から確かめる）。
        let w = World.pick(0, atAsk());
        Assert.assertEq(expected = (true, 1, fixtureRec()#lamps - 1),
            (fixtureSuspect(0), w#lightsOut, World.lampsLit(w)))

    @Test
    def testCalmPickKeepsLamps(): Unit \ Assert =
        // suspect でない選択肢では灯りは消えない。
        let w = World.pick(1, atAsk());
        Assert.assertEq(expected = (false, 0), (fixtureSuspect(1), w#lightsOut))

    @Test
    def testLightsNeverExceedLamps(): Unit \ Assert =
        // 灯りは台本の lamps より多くは消えない（残りが負にならない）。
        let dark = { lightsOut = fixtureRec()#lamps | atAsk() };
        let w = World.pick(0, dark);
        Assert.assertEq(expected = (fixtureRec()#lamps, 0), (w#lightsOut, World.lampsLit(w)))

    @Test
    def testRestartRelightsLamps(): Unit \ Assert =
        // 結末から表紙へ戻り、もう一度はじめると灯りは全部つき直る（新しい夜）。
        let ended = World.pick(0, atAsk()) |> settle |> World.advance;
        let w = World.advance(ended);
        Assert.assertEq(expected = (World.Phase.Story, 0), (w#phase, w#lightsOut))

    // ══════════════════════════════════════════════════════
    // 表示中の Doc の名乗り（Studio のバッジの材料。どの id を名乗るかはルール）
    // ══════════════════════════════════════════════════════

    @Test
    def testActiveDocsFollowPhase(): Unit \ Assert =
        // 表紙ではダイアログ（ui）と手触り（kind）を名乗らない — 本文に入ってから加わる。
        // id は project.json の editor 宣言と対（Studio が突き合わせに使う）。
        // 並びは Controls.docTable() の行の順。
        Assert.assertEq(
            expected = ("story" :: "theme" :: "sprite" :: Nil,
                        "story" :: "kind" :: "theme" :: "sprite" :: "ui" :: Nil),
            (Controls.activeDocs(w0()) |> List.map(fst),
             Controls.activeDocs(World.advance(w0())) |> List.map(fst)))

    /// ui は 1 つの id に 2 本のパスが束なる（ダイアログと選択肢）。
    @Test
    def testActiveDocsGroupsBothUiPaths(): Unit \ Assert =
        Assert.assertEq(
            expected = Some(NovelKit.uiPaths()),
            Controls.activeDocs(World.advance(w0()))
                |> List.filter(e -> fst(e) == "ui") |> List.map(snd) |> List.head)

    // ── fixture の分岐から期待値を引く小物 ──

    def fixtureOption(i: Int32): StoryDoc.Choice =
        StoryDoc.sectionOf(fixtureRec()#start, fixture())
            |> Option.flatMap(section -> section#ask)
            |> Option.flatMap(ask -> List.nth(i, ask#options))
            |> Option.getWithDefault({ label = "", goto = "(fixture が壊れている)", suspect = false })

    def fixtureSuspect(i: Int32): Bool = fixtureOption(i)#suspect
}
