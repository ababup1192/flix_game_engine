// 名前付きの絵（立ち絵と小物）を何人・何個でも出す決まり: 1 つしか立てない位置（exclusive）・端から滑る from= / to=・
// actor.<名>.* の鍵を書く <<move>>・出し直しで鍵を既定へ戻す・背景に付く絵のずれ・重ね順・傾き・残す形。
// コマンドが出す待ち（Out.Wait）を World が預かって明かす決まりもここで見る。
// 人物・位置・滑る距離・ずれはテスト用の Doc（test/fixtures/novel.cast.json）から引き、期待値は Doc から導く。
mod TestActors {

    use fge::{Clock, Render, Yarn, YarnRunner}
    use Util.Json.Json
    use CastDoc.Kind
    use TestKit.{advance, begun, quiet, stepBy}

    def doc(): CastDoc.Doc \ Fs.FileRead = CastDoc.load("test/fixtures/novel.cast.json")

    def d(): CastDoc.Rec \ Fs.FileRead = CastDoc.rec(doc())

    def res(): Res.Res \ Fs.FileRead = TestKit.fixtureRes("test/fixtures/talk", "Station") |> Res.withCast(doc())

    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    /// コマンド 1 つを時刻 at に舞台 st へ表で当てた結果。
    def tried(at: Float64, name: String, args: List[String], st: Stage.Stage): Result[String, Stage.Stage] \ Fs.FileRead =
        Commands.execute(Commands.Replay.Silent, { now = t(at), node = "", res = res(), instant = false }, command(name, args), st) |> Result.map(fst)

    /// コマンドの列を 0 秒・1 秒・2 秒…の時刻で空の舞台へ順に当てる（読めないコマンドは飛ばす）。
    def played(cues: List[(String, List[String])]): Stage.Stage \ Fs.FileRead =
        cues |> List.zipWithIndex |> List.foldLeft((st, pair) -> {
            let (i, (name, args)) = pair;
            tried(Int32.toFloat64(i), name, args, st) |> Result.getWithDefault(st)
        }, Stage.empty())

    def namesOf(st: Stage.Stage, kind: Kind): List[String] =
        st#cast#shown |> List.filter(s -> s#kind == kind) |> List.map(s -> s#now#name)

    def xEnd(name: String, st: Stage.Stage): Float64 = Stage.actorEnd(name, Stage.ActorField.X, st)

    def xAt(at: Float64, name: String, st: Stage.Stage): Float64 =
        PropertyTween.numAt(t(at), Stage.actorKey(name, Stage.ActorField.X), Stage.actorDefaultOf(Stage.ActorField.X), st#props)

    def envOf(st: Stage.Stage, photo: Option[String]): Cast.Env \ Fs.FileRead =
        { doc = doc(), fit = Layout.Fit.Regular, storyNow = t(100.0), realNow = Clock.zero(), missing = Set.empty(),
          light = Cast.steadyLight(Cast.plainTone()), props = st#props, photo = photo, backdropShift = 0.0 }

    /// 描いた面のシェーダーの名前（描く順）。
    def drawnNames(env: Cast.Env, st: Stage.Stage): List[String] =
        Cast.items(env, st#cast, 5) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) => Some(s#spec#name)
            case _                     => None
        })

    // ══ 何人・何個でも出す ══

    @Test
    def testNonExclusiveSlotLetsTwoStand(): Unit \ {Assert, Fs.FileRead} =
        // exclusive でない位置には、2 人目を出しても 1 人目は残る。
        let st = played(("show", "a" :: "at=crowd" :: Nil) :: ("show", "b" :: "at=crowd" :: Nil) :: Nil);
        Assert.assertEq(expected = "a" :: "b" :: Nil, namesOf(st, Kind.Character))

    @Test
    def testPropsAtDifferentSlotsStandTogether(): Unit \ {Assert, Fs.FileRead} =
        // 小物も、別の位置なら同時に出せる（cup は item・book は desk）。
        let st = played(("show", "cup" :: Nil) :: ("show", "book" :: Nil) :: Nil);
        Assert.assertEq(expected = "cup" :: "book" :: Nil, namesOf(st, Kind.Prop))

    @Test
    def testLayerOrdersTheDrawing(): Unit \ {Assert, Fs.FileRead} =
        // 描く順は出した順でなく Doc の layer（book は 450 なので、後から出しても人物 a の 500 より奥）。
        let st = Stage.settle(played(("show", "a" :: Nil) :: ("show", "book" :: Nil) :: Nil));
        Assert.assertEq(expected = "picture_cast_book_plain" :: "picture_cast_a_plain" :: Nil, drawnNames(envOf(st, None), st))

    @Test
    def testSlotWithoutExclusiveHoldsOne(): Unit \ Assert =
        // exclusive を書かない位置は 1 つしか立てない（2 人目を出すと 1 人目は消えていく）。
        let doc = CastDoc.fromJson("{ \"slots\": { \"mid\": { \"x\": 0.5, \"bottom\": 1.0, \"height\": 0.9 } }, \"cast\": { \"p\": { \"slot\": \"mid\", \"faces\": [\"plain\"] }, \"q\": { \"slot\": \"mid\", \"faces\": [\"plain\"] } } }")
            |> Option.getWithDefault(CastDoc.defaults());
        let showOf = name -> Cast.showCue(doc, name, None, None, Some(0.0));
        let layer = List.foldLeft((acc, name) -> showOf(name) |> Result.map(cue -> Cast.apply(t(0.0), cue, acc)) |> Result.getWithDefault(acc),
                                  Cast.empty(), "p" :: "q" :: Nil);
        Assert.assertEq(expected = "q" :: Nil, Cast.shownNames(layer))

    @Test
    def testMoveFromOnAShownActorIsAnError(): Unit \ {Assert, Fs.FileRead} =
        // from= は出ていない絵を端の外から出す時だけ（出ている絵を端へ飛ばさない）。
        let shown = played(("show", "a" :: Nil) :: Nil);
        Assert.assertTrue(Result.isErr(tried(1.0, "move", "a" :: "from=left" :: Nil, shown)))

    // ══ 端から滑る ══

    @Test
    def testShowFromLeftStartsOneSlideAway(): Unit \ {Assert, Fs.FileRead} =
        // <<show 名 from=left>> は、置き場所から slideDistance だけ左から動き出す。
        let st = played(("show", "a" :: "from=left" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(0.0 - d()#slideDistance, xAt(0.0, "a", st)))

    @Test
    def testShowFromLeftEndsAtTheSlot(): Unit \ {Assert, Fs.FileRead} =
        // 滑り終えると置き場所（ずれ 0）に着く。
        let st = played(("show", "a" :: "from=left" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(0.0, xEnd("a", st)))

    @Test
    def testHideToRightEndsOneSlideAway(): Unit \ {Assert, Fs.FileRead} =
        // <<hide 名 to=right>> は、今の位置から slideDistance だけ右へ滑りながら消える。
        let st = played(("show", "a" :: Nil) :: ("hide", "a" :: "to=right" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(d()#slideDistance, xEnd("a", st)))

    @Test
    def testShowingAgainResetsTheMoves(): Unit \ {Assert, Fs.FileRead} =
        // 消した絵を出し直すと、前に出した時の <<move>> は持ち越さない（ずれは既定の 0）。
        let st = played(("show", "a" :: Nil) :: ("move", "a" :: "x=0.3" :: Nil) :: ("hide", "a" :: Nil) :: ("show", "a" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(0.0, xEnd("a", st)))

    // ══ <<move>> ══

    @Test
    def testMoveWritesTheTarget(): Unit \ {Assert, Fs.FileRead} =
        // <<move 名 scale=>> は actor.<名>.scale の終わりの値を書く。
        let st = played(("show", "a" :: Nil) :: ("move", "a" :: "scale=1.5" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(1.5, Stage.actorEnd("a", Stage.ActorField.Scale, st)))

    @Test
    def testMoveDxAddsToTheEnd(): Unit \ {Assert, Fs.FileRead} =
        // dx= は今の終わりの値に足した値を書く（相対の値は残さない）。
        let st = played(("show", "a" :: Nil) :: ("move", "a" :: "x=0.2" :: Nil) :: ("move", "a" :: "dx=0.1" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(0.3, xEnd("a", st)))

    @Test
    def testMoveStartsFromTheValueNow(): Unit \ {Assert, Fs.FileRead} =
        // 動いている途中で次の <<move>> を当てると、その時の値から動き出す（終わりの値へ飛ばない）。
        let shown = played(("show", "a" :: Nil) :: Nil);
        let first = tried(1.0, "move", "a" :: "x=0.4" :: "time=1" :: Nil, shown) |> Result.getWithDefault(shown);
        let second = tried(1.5, "move", "a" :: "x=0.0" :: "time=1" :: Nil, first) |> Result.getWithDefault(first);
        Assert.assertTrue(TestKit.near(xAt(1.5, "a", first), xAt(1.5, "a", second)))

    @Test
    def testMoveXAndDxTogetherIsAnError(): Unit \ {Assert, Fs.FileRead} =
        let shown = played(("show", "a" :: Nil) :: Nil);
        Assert.assertTrue(Result.isErr(tried(1.0, "move", "a" :: "x=0.1" :: "dx=0.1" :: Nil, shown)))

    @Test
    def testMoveOfAnUnshownActorIsAnError(): Unit \ {Assert, Fs.FileRead} =
        // 出ていない絵は from= が無ければ動かせない（書き損じを黙って通さない）。
        Assert.assertTrue(Result.isErr(tried(0.0, "move", "a" :: "x=0.1" :: Nil, Stage.empty())))

    @Test
    def testMoveAcrossLeavesNothingShown(): Unit \ {Assert, Fs.FileRead} =
        // <<move 名 from=left to=right>> は端の外から出して端の外で消すので、残す形には何も残らない。
        let st = played(("move", "a" :: "from=left" :: "to=right" :: Nil) :: Nil);
        Assert.assertEq(expected = Nil, Cast.markOf(st#cast)#cast |> List.map(f -> f#name))

    @Test
    def testMoveAcrossKeepsDrawingUntilItArrives(): Unit \ {Assert, Fs.FileRead} =
        // 消すのは着いた時なので、動いている途中は消えていく物として濃さ 1 のまま描く。
        let st = played(("move", "a" :: "from=left" :: "to=right" :: "time=2" :: Nil) :: Nil);
        let env = { storyNow = t(1.0) | envOf(st, None) };
        let alphas = Cast.items(env, st#cast, 5) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) => Some(s#alpha)
            case _                     => None
        });
        Assert.assertEq(expected = 1.0 :: Nil, alphas)

    @Test
    def testMoveAcrossEndsOneSlideBeyond(): Unit \ {Assert, Fs.FileRead} =
        // from=left to=right は、置き場所から slideDistance だけ左から右へ動く。
        let st = played(("move", "a" :: "from=left" :: "to=right" :: Nil) :: Nil);
        Assert.assertTrue(TestKit.near(d()#slideDistance, xEnd("a", st)))

    @Test
    def testRotatedActorDrawsTheTurnedPicture(): Unit \ {Assert, Fs.FileRead} =
        // 傾けた絵は、傾きを Param で受ける面で描く。
        let st = Stage.settle(played(("show", "a" :: Nil) :: ("move", "a" :: "rotate=30" :: Nil) :: Nil));
        Assert.assertEq(expected = "picture_cast_a_plain_turned" :: Nil, drawnNames(envOf(st, None), st))

    @Test
    def testQuarterTurnSwapsTheSidesOfTheBox(): Unit \ Assert =
        // 90 度傾けた絵の外接する矩形は、幅と高さが入れ替わる。
        let (box, _) = Cast.tiltOf(90.0, { position = { x = 0.0, y = 0.0 }, size = { x = 10.0, y = 20.0 } });
        Assert.assertEq(expected = (20, 10), (Float64.round(box#size#x) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                              Float64.round(box#size#y) |> Float64.tryToInt32 |> Option.getWithDefault(0)))

    // ══ 背景に付く絵 ══

    @Test
    def testAttachedActorShiftsWithThePhoto(): Unit \ {Assert, Fs.FileRead} =
        // 背景に付く絵は、今の写真の名前の横のずれ（画面の幅に対する割合）だけずれて置かれる。
        let st = Stage.settle(played(("show", "shade" :: Nil) :: Nil));
        let xOf = photo -> Cast.placedOf(envOf(st, photo), st#cast) |> List.head |> Option.map(p -> p#rect#position#x) |> Option.getWithDefault(0.0);
        let shift = Cast.entryOf(doc(), "shade") |> Option.map(e -> CastDoc.attachShiftOf(Some("p"), e#attach)) |> Option.getWithDefault(0.0);
        Assert.assertTrue(TestKit.near(shift * Layout.width(Layout.Fit.Regular), xOf(Some("p")) - xOf(None)))

    // ══ 残す形 ══

    @Test
    def testMarkKeepsEveryProp(): Unit \ {Assert, Fs.FileRead} =
        // 小物を 2 つ出した形も、JSON に書いて読み直すと 2 つとも戻る。
        let mark = Cast.markOf(played(("show", "cup" :: Nil) :: ("show", "book" :: Nil) :: Nil)#cast);
        Assert.assertEq(expected = "cup" :: "book" :: Nil, Cast.markFromJson(Some(Cast.markToJson(mark)))#props |> List.map(f -> f#name))

    @Test
    def testSinglePropFrameStillReads(): Unit \ Assert =
        // 小物が 1 つだけの "prop" の枠（前の形）も小物として読む。
        let json = Json.JObject(Map#{ "characters" => Json.JArray(Vector.empty()),
            "prop" => Json.JObject(Map#{ "name" => Json.JString("cup"), "face" => Json.JString("plain"), "slot" => Json.JString("item") }) });
        Assert.assertEq(expected = "cup" :: Nil, Cast.markFromJson(Some(json))#props |> List.map(f -> f#name))

    // ══ コマンドが出す待ち（Out.Wait） ══

    /// 読み始めた所に、seconds 秒の待ちと、明けたら出す台詞 1 行（.yarn の 99 行目）を預けた World。
    def paused(seconds: Float64): World.World \ Fs.FileRead =
        let w = begun(res());
        let line = { speaker = "", text = "待ちの後の行。", parts = Nil, tags = Nil, source = { file = "test", line = 99 } };
        World.mapRead(r -> { pause = Some({ until = Clock.after(seconds, World.now(w)), rest = (YarnRunner.Event.Line(line), 0) :: Nil, last = None, tappable = false }) | r }, w)

    def currentText(w: World.World): String = World.pageOf(w)#current |> Option.map(l -> l#text) |> Option.getWithDefault("")

    @Test
    def testPauseHoldsTheNextLine(): Unit \ {Assert, Fs.FileRead} =
        // 待ちが明ける前は、預けた台詞を出さない。
        let w = stepBy(res(), 0.5, paused(1.0));
        Assert.assertTrue(currentText(w) != "待ちの後の行。")

    @Test
    def testPauseShowsTheNextLineWhenItEnds(): Unit \ {Assert, Fs.FileRead} =
        // 待ちが明けると、預けた台詞を出す。
        let w = stepBy(res(), 1.5, paused(1.0));
        Assert.assertEq(expected = "待ちの後の行。", currentText(w))

    @Test
    def testAdvanceDoesNothingDuringAPause(): Unit \ {Assert, Fs.FileRead} =
        // 待ちの間に送っても、実行器は進まない（待ちの後ろの台詞を読まずに越えない）。
        let w = paused(1.0);
        let pressed = advance(res(), w);
        Assert.assertEq(expected = TestKit.placeOf(w), TestKit.placeOf(pressed))

    @Test
    def testSkipPassesThePause(): Unit \ {Assert, Fs.FileRead} =
        // スキップ中は待ちも飛ばす。
        let w = World.mapRead(r -> { playback = World.Playback.Skip | r }, paused(10.0));
        Assert.assertTrue(Option.isEmpty(World.readOf(stepBy(res(), 0.01, w)) |> Option.flatMap(r -> r#pause)))

    @Test
    def testReopeningTheNodeDropsThePause(): Unit \ {Assert, Fs.FileRead} =
        // 待ちの間にシナリオを直して開き直すと、前の待ちは残らない（Silent の流しを止めない）。
        let w = WorldRead.settleDialogue(res(), paused(10.0));
        Assert.assertTrue(Option.isEmpty(World.readOf(w) |> Option.flatMap(r -> r#pause)))

    @Test
    def testSaveDuringAPauseReturnsToTheLineBefore(): Unit \ {Assert, Fs.FileRead} =
        // 待ちの間のセーブは、バックログの一番新しい台詞の戻れる所（<<wait>> の間と同じ）。
        let w = paused(1.0);
        let head = World.readOf(w) |> Option.flatMap(r -> WorldRead.headMarkOf(r#log)) |> Option.map(m -> YarnRunner.bookmarkToJson(m#bookmark));
        Assert.assertEq(expected = head, WorldRead.slotHere(res(), w) |> Option.map(s -> YarnRunner.bookmarkToJson(s#mark#bookmark)))
}
