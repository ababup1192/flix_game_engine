// 立ち絵と小物（Cast）: シナリオの <<show>> / <<hide>> の読み方、出し入れと重ね方、セーブ・ロード・バックログから戻る時の持ち越し、
// 舞台の全部と頁がどの台詞からも同じに戻ること、ノードに着いた時の舞台、素材の待ちとのつなぎ、置き場所。
// 人物と位置の名前はテスト用の Doc（test/fixtures/novel.cast.json）、シナリオはテスト用の木
// （test/fixtures/talk/cast.yarn と stage.yarn を build した物）から引き、期待値は Doc と台本から導く。
mod TestCast {

    use fge::{Clock, Display, JsonCodec, Render, Yarn, YarnRunner, YarnStorage}
    use Util.Json.Json
    use CastDoc.Kind
    use TestKit.{advance, begun, quiet, settle, stepBy}

    /// テスト用の Doc。
    def doc(): CastDoc.Doc \ Fs.FileRead = CastDoc.load("test/fixtures/novel.cast.json")

    def d(): CastDoc.Rec \ Fs.FileRead = CastDoc.rec(doc())

    /// テスト用の Doc とシナリオに差し替えた描く元。
    def res(): Res.Res \ Fs.FileRead =
        TestKit.fixtureRes("test/fixtures/talk", "Station") |> Res.withCast(doc())

    /// 項目の既定の表情と位置。
    def entry(kind: Kind, name: String): CastDoc.Entry \ Fs.FileRead =
        CastDoc.entryOf(kind, name, doc()) |> Option.getWithDefault({ label = "", aspect = 0.0, scale = 0.0, face = "", slot = "", faces = Nil })

    /// コマンド 1 つ（<<name args…>>）。
    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    /// コマンド 1 つを、時刻 at に、層 layer を持つ舞台へ表で当てた結果の層。
    def tried(at: Float64, name: String, args: List[String], layer: Cast.Layer): Result[String, Cast.Layer] \ Fs.FileRead =
        Commands.execute(Commands.Replay.Silent, { now = t(at), node = "", res = res() }, command(name, args), { cast = layer | Stage.empty() })
            |> Result.map(done -> fst(done)#cast)

    /// tried の結果（読めないコマンドは層をそのまま）。
    def applied(at: Float64, name: String, args: List[String], layer: Cast.Layer): Cast.Layer \ Fs.FileRead =
        tried(at, name, args, layer) |> Result.getWithDefault(layer)

    /// 物語の時計の seconds 秒の時刻。
    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    /// コマンドの列を、0 秒・1 秒・2 秒…の時刻で空の層へ順に当てる（読めないコマンドは飛ばす）。
    def played(cues: List[(String, List[String])]): Cast.Layer \ Fs.FileRead =
        cues |> List.zipWithIndex |> List.foldLeft((layer, pair) -> {
            let (i, (name, args)) = pair;
            applied(Int32.toFloat64(i), name, args, layer)
        }, Cast.empty())

    def figureTuple(f: Cast.Figure): (String, String, String) = (f#name, f#face, f#slot)

    /// 出ている人物の (名前, 表情, 位置)。
    def castOf(layer: Cast.Layer): List[(String, String, String)] = layer#cast |> List.map(s -> figureTuple(s#now))

    def leavingOf(layer: Cast.Layer): List[String] = layer#leaving |> List.map(l -> l#figure#name)

    def cueTuple(c: Cast.Cue): (String, String, String, String, Bool, Bool, Float64) = match c {
        case Cast.Cue.Show(kind, f, keep, s) => ("${kind}", f#name, f#face, f#slot, keep#face, keep#slot, s)
        case Cast.Cue.Hide(kind, name, s)    => ("${kind}", Option.getWithDefault("*", name), "off", "", false, false, s)
    }

    def markTuple(m: Cast.Mark): (List[(String, String, String)], Option[(String, String, String)]) =
        (m#cast |> List.map(figureTuple), m#prop |> Option.map(figureTuple))

    def stageMark(w: World.World): (List[(String, String, String)], Option[(String, String, String)]) \ Fs.FileRead =
        markTuple(Cast.markOf(World.stageOf(res(), w)#cast))

    /// 層を z 5 に描いた面の (シェーダーの名前, 濃さ)。
    def drawn(env: Cast.Env, layer: Cast.Layer): List[(String, Float64)] =
        Cast.items(env, layer, 5) |> List.filterMap(placed -> match placed#item {
            case Render.Item.Shader(s) => Some((s#spec#name, s#alpha))
            case _                     => None
        })

    def envAt(now: Float64, missing: Set[String]): Cast.Env \ Fs.FileRead =
        { doc = doc(), fit = Layout.Fit.Regular, storyNow = t(now), realNow = Clock.zero(), missing = missing, light = Cast.steadyLight(Cast.plainTone()) }

    // ══ シナリオのコマンドを読む ══

    @Test
    def testShowReadsFaceSecondAndPlaceAsAt(): Unit \ {Assert, Fs.FileRead} =
        // <<show 名前 表情 at=位置 time=秒>> は、2 つ目の位置の引数を表情、at= を位置として出す。
        let layer = tried(0.0, "show", "a" :: "smile" :: "at=left" :: "time=1.5" :: Nil, Cast.empty());
        Assert.assertEq(expected = Ok((("a", "smile", "left") :: Nil, 1.5)),
                        layer |> Result.map(l -> (castOf(l), List.head(l#cast) |> Option.map(x -> x#seconds) |> Option.getWithDefault(0.0))))

    @Test
    def testOmittedArgumentsComeFromTheDoc(): Unit \ {Assert, Fs.FileRead} =
        // 省いた表情・位置・秒は Doc の face・slot・fadeSeconds で埋め、表情と位置は「出ていれば今のまま」の印を付ける。
        let b = entry(Kind.Character, "b");
        Assert.assertEq(expected = Ok(("Character", "b", b#face, b#slot, true, true, d()#fadeSeconds)),
                        Cast.showCue(doc(), "b", None, None, None) |> Result.map(cueTuple))

    @Test
    def testPropNamesShowAsProps(): Unit \ {Assert, Fs.FileRead} =
        // props にある名前は小物として出る（人物の列には入らない）。
        let layer = applied(0.0, "show", "cup" :: Nil, Cast.empty());
        Assert.assertEq(expected = (Some("cup"), 0), (layer#prop |> Option.map(x -> x#now#name), List.length(layer#cast)))

    @Test
    def testUnknownArgumentsAreErrors(): Unit \ {Assert, Fs.FileRead} =
        // 知らない人物・表情・位置、数でない秒、知らない鍵、名前も at= も無い hide は Err（舞台はそのまま）。
        let errs = (("show", "zz" :: Nil) :: ("show", "a" :: "angry" :: Nil) :: ("show", "a" :: "at=top" :: Nil)
                    :: ("show", "a" :: "time=soon" :: Nil) :: ("show", "a" :: "where=left" :: Nil) :: ("hide", "zz" :: Nil) :: ("hide", Nil) :: Nil)
            |> List.map(match (name, args) -> Result.isErr(tried(0.0, name, args, Cast.empty())));
        Assert.assertEq(expected = List.repeat(7, true), errs)

    @Test
    def testDocRoundsDefaultsIntoItsLists(): Unit \ Assert =
        // Doc の既定の表情が faces に無ければ faces の頭へ、既定の位置が slots に無ければ slots の鍵へ丸めて読む（書き損じで人が見えなくならない）。
        let read = CastDoc.fromJson("{ \"cast\": { \"x\": { \"face\": \"angry\", \"slot\": \"top\", \"faces\": [\"plain\", \"smile\"] } } }")
            |> Option.flatMap(doc -> CastDoc.entryOf(Kind.Character, "x", doc) |> Option.map(e -> (e#face, Map.memberOf(e#slot, CastDoc.rec(doc)#slots))));
        Assert.assertEq(expected = Some(("plain", true)), read)

    // ══ 層に反映する ══

    @Test
    def testAnotherPersonAtTheSameSlotSendsTheFirstAway(): Unit \ {Assert, Fs.FileRead} =
        // 同じ位置に別の人を出すと、前の人は消えていく物（leaving）に入る。
        let layer = played(("show", "a" :: "at=center" :: Nil) :: ("show", "b" :: "at=center" :: Nil) :: Nil);
        Assert.assertEq(expected = ((("b", entry(Kind.Character, "b")#face, "center") :: Nil), "a" :: Nil), (castOf(layer), leavingOf(layer)))

    @Test
    def testReshowWithoutSlotKeepsTheSlotAndChangesTheFace(): Unit \ {Assert, Fs.FileRead} =
        // 位置を省いて出し直すと、位置はそのままで表情だけが替わり、前の表情を下に残す。
        let layer = played(("show", "a" :: "at=left" :: Nil) :: ("show", "a" :: "smile" :: Nil) :: Nil);
        Assert.assertEq(expected = (("a", "smile", "left") :: Nil, Some(entry(Kind.Character, "a")#face)),
                        (castOf(layer), List.head(layer#cast) |> Option.flatMap(s -> s#before) |> Option.map(u -> u#figure#face)))

    @Test
    def testMovingToAnotherSlotFadesOutTheOldSlot(): Unit \ {Assert, Fs.FileRead} =
        // 位置を替えると、前の位置の形は消えていく物になり、新しい位置に出し直す（すべらせない）。
        let layer = played(("show", "a" :: "at=left" :: Nil) :: ("show", "a" :: "at=right" :: Nil) :: Nil);
        Assert.assertEq(expected = (("a", entry(Kind.Character, "a")#face, "right") :: Nil, "a" :: Nil), (castOf(layer), leavingOf(layer)))

    @Test
    def testHideNameHidesOneAndHideAllHidesAll(): Unit \ {Assert, Fs.FileRead} =
        // <<hide 名前>> はその人だけ、<<hide all>> は全員を消す。
        let two = ("show", "a" :: Nil) :: ("show", "b" :: Nil) :: Nil;
        let one = played(List.append(two, ("hide", "a" :: Nil) :: Nil));
        let none = played(List.append(two, ("hide", "all" :: Nil) :: Nil));
        Assert.assertEq(expected = ("b" :: Nil, 0), (castOf(one) |> List.map(match (n, _, _) -> n), List.length(none#cast)))

    @Test
    def testHideAllAlsoHidesTheProp(): Unit \ {Assert, Fs.FileRead} =
        // <<hide all>> は人物だけでなく小物も消す。
        let gone = played(("show", "a" :: Nil) :: ("show", "cup" :: Nil) :: ("hide", "all" :: Nil) :: Nil);
        Assert.assertEq(expected = None, gone#prop |> Option.map(s -> s#now#name))

    @Test
    def testHideAtASlotHidesWhoStandsThere(): Unit \ {Assert, Fs.FileRead} =
        // <<hide at=位置>> はその位置に出ている人物だけを消し、ほかの位置の人は残す。
        let layer = played(("show", "a" :: "at=left" :: Nil) :: ("show", "b" :: "at=right" :: Nil) :: ("hide", "at=left" :: Nil) :: Nil);
        Assert.assertEq(expected = "b" :: Nil, castOf(layer) |> List.map(match (n, _, _) -> n))

    @Test
    def testItemReplacesThePreviousProp(): Unit \ {Assert, Fs.FileRead} =
        // 小物の <<show>> は前の小物と入れ替わり（前の小物は消えていく）、<<hide at=item>> で消える。人物の列には入らない。
        let swapped = played(("show", "cup" :: Nil) :: ("show", "fan" :: Nil) :: Nil);
        let gone = played(("show", "cup" :: Nil) :: ("hide", "at=item" :: Nil) :: Nil);
        Assert.assertEq(expected = (Some("fan"), "cup" :: Nil, 0, None),
                        (swapped#prop |> Option.map(s -> s#now#name), leavingOf(swapped), List.length(swapped#cast), gone#prop |> Option.map(s -> s#now#name)))

    // ══ 重ね方 ══

    @Test
    def testFaceChangeKeepsTheOldFaceOpaqueUnderneath(): Unit \ {Assert, Fs.FileRead} =
        // 同じ位置で表情を替える途中は、前の表情を濃さ 1 で下に敷き、今の表情は 0 と 1 の間（透けない）。
        // 表情は 1 秒の時刻に替えたので、fadeSeconds の半分だけ後を見る。
        let layer = played(("show", "a" :: Nil) :: ("show", "a" :: "smile" :: Nil) :: Nil);
        let shown = drawn(envAt(1.0 + d()#fadeSeconds / 2.0, Set.empty()), layer);
        let (names, alphas) = List.unzip(shown);
        let under = List.head(alphas) |> Option.getWithDefault(0.0);
        let over = List.nth(1, alphas) |> Option.getWithDefault(0.0);
        Assert.assertEq(expected = ("picture_cast_a_plain" :: "picture_cast_a_smile" :: Nil, 1.0, true),
                        (names, under, over > 0.0 and over < 1.0))

    /// 層を時刻 now に描いた面の濃さの最大（見えている濃さ）。
    def visibleAt(now: Float64, layer: Cast.Layer): Float64 \ Fs.FileRead =
        drawn(envAt(now, Set.empty()), layer) |> List.map(snd) |> List.foldLeft(Float64.max, 0.0)

    @Test
    def testFaceChangeWhileFadingInNeverBrightens(): Unit \ {Assert, Fs.FileRead} =
        // 出してすぐ（fadeSeconds の 2 割の所で）表情を替えても、替えたコマの濃さは前のコマより上がらない（前の形を濃さ 1 で敷かない）。
        // 替えた後は前の濃さから濃くなっていく（替えて fadeSeconds の半分の所は、替えた時より濃い）。
        let fade = d()#fadeSeconds;
        let at = fade * 0.2;
        let shown = played(("show", "a" :: Nil) :: Nil);
        let changed = applied(at, "show", "a" :: "smile" :: Nil, shown);
        let before = visibleAt(at, shown);
        Assert.assertEq(expected = (true, true, true),
                        (before > 0.0, visibleAt(at, changed) <= before + 0.000001, visibleAt(at + fade / 2.0, changed) > before))

    @Test
    def testOffWhileFadingInNeverBrightens(): Unit \ {Assert, Fs.FileRead} =
        // 出てくる途中（fadeSeconds の 3 割の所）で消すと、消えていく形はその時の濃さから薄くなる（一度濃くならない）。
        let fade = d()#fadeSeconds;
        let at = fade * 0.3;
        let shown = played(("show", "a" :: Nil) :: Nil);
        let off = applied(at, "hide", "a" :: Nil, shown);
        let before = visibleAt(at, shown);
        Assert.assertEq(expected = (true, true, 0.0),
                        (visibleAt(at, off) <= before + 0.000001, visibleAt(at + fade / 2.0, off) < before, visibleAt(at + fade, off)))

    @Test
    def testMovingDuringAFaceChangeFadesBothShapes(): Unit \ {Assert, Fs.FileRead} =
        // 表情を替えている途中で位置を替えると、前の位置の今の形も下に敷いた形も、消えていく物になる（下の形が急に消えない）。
        let fade = d()#fadeSeconds;
        let changing = played(("show", "a" :: Nil) :: ("show", "a" :: "smile" :: Nil) :: Nil);
        let moved = applied(1.0 + fade * 0.3, "show", "a" :: "at=left" :: Nil, changing);
        Assert.assertEq(expected = ("cast_a_plain" :: "cast_a_smile" :: Nil),
                        moved#leaving |> List.map(l -> Cast.textureOf(l#figure)))

    @Test
    def testSettleEndsCrossfadesAndLeaving(): Unit \ {Assert, Fs.FileRead} =
        // settle は重ねの途中を終わりの形にする: 前の表情を捨て、消えていく物を空にする。
        let layer = Cast.settle(played(("show", "a" :: Nil) :: ("show", "b" :: "at=center" :: Nil) :: ("show", "b" :: "at=left" :: Nil) :: Nil));
        Assert.assertEq(expected = (Nil, 0), (layer#cast |> List.filterMap(s -> s#before) |> List.map(u -> figureTuple(u#figure)), List.length(layer#leaving)))

    @Test
    def testPresenceFollowsTheFade(): Unit \ {Assert, Fs.FileRead} =
        // 人物がどれだけ出ているか（縦の頁の覆いを薄くする量）は、出始めが 0・途中が 0 と 1 の間・出切ると 1・消し切ると 0。
        let shown = played(("show", "a" :: Nil) :: Nil);
        let hidden = played(("show", "a" :: Nil) :: ("hide", "a" :: Nil) :: Nil);
        let fade = d()#fadeSeconds;
        let mid = Cast.presenceOf(t(fade / 2.0), shown);
        Assert.assertEq(expected = (0.0, true, 1.0, 0.0),
                        (Cast.presenceOf(t(0.0), shown), mid > 0.0 and mid < 1.0, Cast.presenceOf(t(fade), shown), Cast.presenceOf(t(1.0 + fade), hidden)))

    // ══ セーブに残す形 ══

    @Test
    def testMarkSurvivesJson(): Unit \ {Assert, Fs.FileRead} =
        // 残した形を JSON に書いて読み直すと同じ形に戻る。
        let mark = Cast.markOf(played(("show", "a" :: "smile" :: Nil) :: ("show", "b" :: "at=right" :: Nil) :: ("show", "cup" :: Nil) :: Nil));
        Assert.assertEq(expected = markTuple(mark), markTuple(Cast.markFromJson(Some(Cast.markToJson(mark)))))

    @Test
    def testOldSaveWithoutCastReadsEmpty(): Unit \ {Assert, Fs.FileRead} =
        // cast の欄が無い古いセーブの枠は、立ち絵の無い形として読む（Saves.fromJson が渡す欄が None）。
        let r = res();
        let fresh = Saves.fresh(r#kind);
        let bookmark = WorldRead.slotHere(r, begun(r)) |> Option.map(s -> YarnRunner.bookmarkToJson(s#mark#bookmark));
        let old = bookmark |> Option.map(bm -> Json.JObject(Map#{ "slots" => Json.JObject(Map#{ "0" => Json.JObject(Map#{ "bookmark" => bm, "mode" => Json.JString("Adv") }) }) }));
        let read = old |> Option.map(Saves.fromJson(fresh))
            |> Option.flatMap(s -> Map.get(0, Saves.rec(s)#slots)) |> Option.map(s -> markTuple(Cast.markOf(Stage.fromSnapshot(s#mark#stage)#cast)));
        Assert.assertEq(expected = Some((Nil, None)), read)

    @Test
    def testVersion2SaveReadsIntoTheStage(): Unit \ {Assert, Fs.FileRead} =
        // version 2 の枠の欄（photo・grade・mode・cast・ambienceSound・particles）は、戻す舞台に読み替える。頁は無い。
        let r = res();
        let bookmark = WorldRead.slotHere(r, begun(r)) |> Option.map(s -> YarnRunner.bookmarkToJson(s#mark#bookmark));
        let cast = Cast.markToJson({ cast = { name = "a", face = "smile", slot = "left" } :: Nil, prop = None });
        let old = bookmark |> Option.map(bm -> Json.JObject(Map#{ "version" => Json.JNumber(JsonCodec.intToBd(2)), "slots" => Json.JObject(Map#{ "0" => Json.JObject(Map#{
            "bookmark" => bm, "photo" => Json.JString("p"), "grade" => Json.JString("g"), "mode" => Json.JString("Adv"), "cast" => cast,
            "ambienceSound" => Json.JString("amb_x"), "particles" => Json.JString("fireflies") }) }) }));
        let read = old |> Option.map(Saves.fromJson(Saves.fresh(r#kind)))
            |> Option.flatMap(s -> Map.get(0, Saves.rec(s)#slots)) |> Option.map(s -> {
                let st = Stage.fromSnapshot(s#mark#stage);
                (st#shot |> Option.map(shot -> (shot#photo, shot#grade)), st#mode, markTuple(Cast.markOf(st#cast)), Stage.ambienceOf(Clock.zero(), st), Stage.particlesOf(Clock.zero(), st), Option.isEmpty(s#mark#page))
            });
        Assert.assertEq(expected = Some((Some(("p", "g")), Stage.Mode.Adv, (("a", "smile", "left") :: Nil, None), Some("amb_x"), Some("fireflies"), true)), read)

    // ══ ロード・バックログから戻る時の持ち越し（テスト用のシナリオ） ══

    /// 台詞を出し終えた所から送って、次の台詞を出し終えた所。
    def next(r: Res.Res, w: World.World): World.World = settle(r, advance(r, w))

    /// 舞台（settle した物）と頁（出し終えた形）の JSON の字。
    def shapeOf(r: Res.Res, w: World.World): (String, String) =
        (Util.Json.toPrettyString(2, Stage.snapshotToJson(Stage.snapshotOf(World.stageOf(r, w)))),
         Util.Json.toPrettyString(2, Page.toJson(Page.revealAll(World.pageOf(w)))))

    /// 読み進めた舞台と頁と、その台詞の戻れる所（バックログの一番新しい行）から戻した舞台と頁。
    def liveAndRestored(r: Res.Res, w: World.World): ((String, String), (String, String)) =
        let back = WorldRead.headMarkOf(World.logOf(w)) |> Option.map(m -> settle(r, quiet(() -> WorldRead.restore(r, m, w))))
            |> Option.map(shapeOf(r)) |> Option.getWithDefault(("", ""));
        (shapeOf(r, w), back)

    /// はじめから読み、選択肢では picks の頭を選んで、台詞を出し終えた所を全部（古い順。シナリオが終わるか picks が尽きた選択肢まで）。
    def everyLine(r: Res.Res, picks: List[Int32]): List[World.World] =
        def go(fuel: Int32, rest: List[Int32], cur: World.World, acc: List[World.World]): List[World.World] =
            if (fuel <= 0 or not World.isReading(cur)) List.reverse(acc)
            else if (World.isChoosing(cur)) match rest {
                case i :: tail => go(fuel - 1, tail, settle(r, TestKit.pick(r, i, cur)), acc)
                case Nil       => List.reverse(acc)
            }
            else go(fuel - 1, rest, next(r, cur), cur :: acc);
        go(100, picks, begun(r), Nil)

    /// 左の道を読んだ時の、今の行が prefix を含む所。
    def lineWith(r: Res.Res, prefix: String): World.World =
        everyLine(r, 0 :: Nil)
            |> List.find(w -> World.pageOf(w)#current |> Option.exists(line -> String.contains(substr = prefix, line#text)))
            |> Option.getWithDefault(World.toTitle(begun(r)))

    /// 左の道を読んだ時の、今の行が prefix を含む所の頁の数。
    def pagesAt(r: Res.Res, prefix: String): Int32 = World.stageOf(r, lineWith(r, prefix))#pages

    @Test
    def testLiveStageMatchesTheRestoredStageOnEveryLine(): Unit \ {Assert, Fs.FileRead} =
        // テスト用のシナリオの全部の台詞で（選択肢はどの道も。自分へ戻るメニューも通る）、読み進めた舞台の全部と頁が、その行の戻れる所から戻した物と同じ
        // （前のノードで出した人・前のノードの型・頁の数・ノードをまたいで続く NVL の頁も戻る）。
        let r = res();
        let pairs = (everyLine(r, 0 :: Nil) :: everyLine(r, 1 :: 0 :: 1 :: Nil) :: Nil) |> List.flatten |> List.map(liveAndRestored(r));
        // 4 行目（Station の最後）は 2 人と小物が出ている所（空どうしの一致で通らないことの確かめ）。
        let l4 = List.nth(3, everyLine(r, Nil)) |> Option.map(stageMark) |> Option.getWithDefault((Nil, None));
        Assert.assertEq(expected = (pairs |> List.map(match (live, _) -> (live, live)), (shownAtL4(), Some(("cup", "plain", "item")))),
                        (pairs, l4))

    @Test
    def testEveryLineSurvivesTheSaveJson(): Unit \ {Assert, Fs.FileRead} =
        // 全部の台詞で、セーブの道（slotHere）で残し、JSON に書いて読み直してから戻すと、読み進めた舞台の全部と頁に戻る。
        let r = res();
        let throughJson = (w: World.World) -> WorldRead.slotHere(r, w)
            |> Option.map(slot -> Saves.withPushed(Saves.Tab.Quick, slot, Saves.fresh(r#kind)))
            |> Option.map(s -> Saves.fromJson(Saves.fresh(r#kind), Saves.toJson(s)))
            |> Option.flatMap(s -> Saves.slotOf(Saves.Tab.Quick, 0, s))
            |> Option.map(slot -> shapeOf(r, settle(r, quiet(() -> WorldRead.restore(r, slot#mark, World.toTitle(w))))))
            |> Option.getWithDefault(("", ""));
        let lines = everyLine(r, 0 :: Nil);
        Assert.assertEq(expected = lines |> List.map(shapeOf(r)), lines |> List.map(throughJson))

    @Test
    def testLogJumpAfterALoadKeepsWhatTheNodeChangedLater(): Unit \ {Assert, Fs.FileRead} =
        // Next の三行目（b と小物を消した後）でセーブしてロードし、バックログで Next の一行目へ戻ると、b と小物が出ている
        // （当て直しはノードに入った時の舞台から始まるので、ノードの途中で替えた物が前の台詞へ早く入らない）。
        let r = res();
        let third = List.nth(6, everyLine(r, Nil)) |> Option.getWithDefault(begun(r));
        let saved = quiet(() -> WorldSaves.writeSlot(r, Saves.Tab.Numbered(1), 0, third));
        let loaded = settle(r, quiet(() -> WorldSaves.loadFrom(r, Saves.Tab.Numbered(1), 0, World.toTitle(saved))));
        let asked = quiet(() -> WorldLog.askJump(2, quiet(() -> WorldLog.openLog(loaded))));
        let jumped = settle(r, quiet(() -> WorldMenu.answer(r, World.Answer.Yes, asked)));
        Assert.assertEq(expected = (shownAtL4(), Some(("cup", "plain", "item"))), stageMark(jumped))

    @Test
    def testLogJumpAfterALoadKeepsThePageFromTheEarlierNode(): Unit \ {Assert, Fs.FileRead} =
        // PagesNext の「枠は台詞で戻る」でセーブしてロードし、バックログで「前のノードの頁に続く地の文」へ戻ると、
        // 頁には前のノード（Pages）の行が残っている（当て直しはノードに入る直前の頁から始まる）。
        let r = res();
        let saved = quiet(() -> WorldSaves.writeSlot(r, Saves.Tab.Numbered(1), 0, lineWith(r, "枠は台詞で戻る")));
        let loaded = settle(r, quiet(() -> WorldSaves.loadFrom(r, Saves.Tab.Numbered(1), 0, World.toTitle(saved))));
        let asked = quiet(() -> WorldLog.askJump(1, quiet(() -> WorldLog.openLog(loaded))));
        let jumped = settle(r, quiet(() -> WorldMenu.answer(r, World.Answer.Yes, asked)));
        let before = lineWith(r, "前のノードの頁に続く");
        Assert.assertEq(expected = (shapeOf(r, before), false), (shapeOf(r, jumped), List.isEmpty(World.pageOf(before)#lines)))

    @Test
    def testSavingDuringAWaitAfterAChoiceTellsItCannotSave(): Unit \ {Assert, Fs.FileRead} =
        // セーブできない待ちの間にクイックセーブを押すと、クイックのページは空のまま「今はセーブできません」を知らせる。
        let r = res();
        let waiting = TestKit.pick(r, 0, next(r, lineWith(r, "枠は台詞で戻る")));
        let pressed = quiet(() -> WorldSaves.quickSave(r, waiting));
        Assert.assertEq(expected = (Some(StoryDoc.labelOf(StoryDoc.Label.NoSaveNow, r#story)), true),
                        (World.toastOf(r, pressed), Option.isEmpty(Saves.slotOf(Saves.Tab.Quick, 0, pressed#saves))))

    @Test
    def testPagesCountTheTypeChange(): Unit \ {Assert, Fs.FileRead} =
        // 型の切り替え（下のウィンドウ → nvl）で頁の数が 1 増える。
        let r = res();
        Assert.assertEq(expected = pagesAt(r, "前のノードの型のまま") + 1, pagesAt(r, "一つ目"))

    @Test
    def testPagesCountTheOverflow(): Unit \ {Assert, Fs.FileRead} =
        // NVL で 3 つ目の長い行が頁に入り切らない時に頁の数が 1 増える。
        let r = res();
        Assert.assertEq(expected = pagesAt(r, "二つ目") + 1, pagesAt(r, "三つ目"))

    @Test
    def testPagesCountTheClear(): Unit \ {Assert, Fs.FileRead} =
        // <<window clear>> で頁の数が 1 増える。
        let r = res();
        Assert.assertEq(expected = pagesAt(r, "三つ目") + 1, pagesAt(r, "頁を替えた後"))

    @Test
    def testSavingDuringAWaitWithTheWindowOffReturnsToTheLine(): Unit \ {Assert, Fs.FileRead} =
        // <<window off>> の後の <<wait>> の間は文字の枠を消している。そこでセーブして戻すと、待つ前の台詞を枠のある形で出す。
        let r = res();
        let before = lineWith(r, "前のノードの頁に続く");
        let waiting = advance(r, before);
        let hidden = (w: World.World) -> Stage.isWindowHidden(World.now(w), World.stageOf(r, w));
        let back = WorldRead.slotHere(r, waiting) |> Option.map(slot -> settle(r, quiet(() -> WorldRead.restore(r, slot#mark, waiting))));
        Assert.assertEq(expected = (true, Some(false), Some(shapeOf(r, before))),
                        (hidden(waiting), back |> Option.map(hidden), back |> Option.map(shapeOf(r))))

    @Test
    def testNoSaveDuringAWaitBeforeTheFirstLine(): Unit \ {Assert, Fs.FileRead} =
        // バックログが空のまま待っている間（はじめから読んだ頭の <<wait>>）は、今の所のデータが無い（セーブしない）。
        let r = TestKit.res();
        let waiting = quiet(() -> WorldRead.newGame(r, TestKit.w0(r)));
        Assert.assertEq(expected = (true, true), (TestKit.isWaiting(waiting), Option.isEmpty(WorldRead.slotHere(r, waiting))))

    @Test
    def testNoSaveDuringAWaitRightAfterAChoice(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を選んだ直後の <<wait>> の間（バックログの一番新しい行が選んだ選択肢）は、今の所のデータが無い（選ぶ前へ戻さない）。
        let r = res();
        let atChoices = next(r, lineWith(r, "枠は台詞で戻る"));
        let waiting = TestKit.pick(r, 0, atChoices);
        Assert.assertEq(expected = (true, true, true),
                        (World.isChoosing(atChoices), TestKit.isWaiting(waiting), Option.isEmpty(WorldRead.slotHere(r, waiting))))

    // ══ ノードに着いた時の舞台 ══

    @Test
    def testEntryIsTheStageWhereTheNodeIsFirstReached(): Unit \ {Assert, Fs.FileRead} =
        // Next に着いた時の舞台は、Station の最後の台詞の舞台（前のノードで出した人と小物が居る）。
        // どこからも jump しない Island のほかは、選択肢のどの道のノードにも着く。
        let r = res();
        let entries = WorldRead.buildEntriesWithin(WorldRead.entryFuel(), r);
        let atL4 = List.nth(3, everyLine(r, Nil)) |> Option.map(w -> Stage.snapshotToJson(Stage.snapshotOf(World.stageOf(r, w))));
        Assert.assertEq(expected = (atL4, Yarn.nodeNames(r#dialogue) |> List.filter(name -> name != "Island")),
                        (Map.get("Next", entries) |> Option.map(Stage.snapshotToJson), Map.keysOf(entries) |> Set.toList))

    @Test
    def testEntryWalkStopsAtTheFuel(): Unit \ {Assert, Fs.FileRead} =
        // 歩数の上限に当たると、そこまでに着いたノードだけを返す。Station の 4 行を送ると Next に着き、選択肢の先には着かない。
        let r = res();
        let few = WorldRead.buildEntriesWithin(4, r);
        Assert.assertEq(expected = (true, true, false, false),
                        (Map.memberOf("Station", few), Map.memberOf("Next", few), Map.memberOf("Left", few), Map.memberOf("Right", few)))

    @Test
    def testSelfJumpingMenuDoesNotUseUpTheFuel(): Unit \ {Assert, Fs.FileRead} =
        // 自分へ jump して戻るメニュー（Menu の「聞く」）の道はそこで止まり、少ない歩数でも出口の先（Through・Exit）に着く。
        let r = res();
        let entries = WorldRead.buildEntriesWithin(200, r);
        Assert.assertEq(expected = (true, true), (Map.memberOf("Through", entries), Map.memberOf("Exit", entries)))

    @Test
    def testEntryCarriesCommandsInsideIfAndPassThroughNodes(): Unit \ {Assert, Fs.FileRead} =
        // Exit に着いた時の舞台には、コマンドだけで通り過ぎる Through の <<if>> の枝の中の <<window bottom>> と <<show b>> が入っている。
        let r = res();
        let exit = Map.get("Exit", WorldRead.buildEntriesWithin(WorldRead.entryFuel(), r)) |> Option.map(Stage.fromSnapshot);
        Assert.assertEq(expected = Some((Stage.Mode.Adv, "b" :: Nil)),
                        exit |> Option.map(st -> (st#mode, castOf(st#cast) |> List.map(match (n, _, _) -> n))))

    @Test
    def testUnreachedNodeHasNoEntry(): Unit \ {Assert, Fs.FileRead} =
        // どこからも jump しないノード（Island）には着かない（buildEntryStage はそのノードを空の舞台から始め、1 行言う）。
        let r = res();
        Assert.assertEq(expected = (false, true),
                        (Map.memberOf("Island", WorldRead.buildEntriesWithin(WorldRead.entryFuel(), r)), Option.nonEmpty(Yarn.nodeOf("Island", r#dialogue))))

    @Test
    def testOpenAtStartsFromTheEntryStage(): Unit \ {Assert, Fs.FileRead} =
        // ノードの頭から開くと、前のノードから持ち越す人物と小物が出ている（台本の頭で言い直さなくてよい）。
        let r = res();
        let opened = quiet(() -> WorldRead.openAt(r, YarnStorage.empty(), "Next", 0, World.toTitle(begun(r))));
        Assert.assertEq(expected = (shownAtL4(), Some(("cup", "plain", "item"))), stageMark(opened))

    /// テスト用のシナリオの 4 行目（Station の最後）で出ている人物: a は笑顔で真ん中・b は右。
    def shownAtL4(): List[(String, String, String)] = ("a", "smile", "center") :: ("b", "plain", "right") :: Nil

    @Test
    def testCastFromAnEarlierNodeSurvivesALoad(): Unit \ {Assert, Fs.FileRead} =
        // 前のノードで出した人物と小物は、次のノードでセーブしてロードしても残る（ノードの頭からの当て直しでは戻らない分を Mark が持つ）。
        let r = res();
        let atNext = TestKit.readTo(r, "Next", Nil, begun(r));
        let saved = quiet(() -> WorldSaves.writeSlot(r, Saves.Tab.Numbered(1), 0, atNext));
        let loaded = settle(r, quiet(() -> WorldSaves.loadFrom(r, Saves.Tab.Numbered(1), 0, World.toTitle(saved))));
        Assert.assertEq(expected = (shownAtL4(), Some(("cup", "plain", "item"))), stageMark(loaded))

    @Test
    def testCastSurvivesJumpingBackFromTheLog(): Unit \ {Assert, Fs.FileRead} =
        // 次のノードを読み進めてから、前のノードの最後の台詞へバックログから戻ると、その時の人物と小物になる。
        let r = res();
        let atNext = TestKit.readTo(r, "Next", Nil, begun(r));
        let before = TestKit.readUntil(r, w -> World.talkNodeOf(advance(r, w)) == "Next", Nil, begun(r));
        let far = next(r, next(r, atNext));
        let k = List.length(World.logOf(far)) - List.length(World.logOf(before));
        let asked = quiet(() -> WorldLog.askJump(k, quiet(() -> WorldLog.openLog(far))));
        let jumped = settle(r, quiet(() -> WorldMenu.answer(r, World.Answer.Yes, asked)));
        Assert.assertEq(expected = (shownAtL4(), Some(("cup", "plain", "item"))), stageMark(jumped))

    // ══ 素材の待ち ══

    @Test
    def testUnarrivedCastHoldsBeforeTheCue(): Unit \ {Assert, Fs.FileRead} =
        // まだ届いていない立ち絵へ替える所で送ると、黒へ重ね始め（待つ名前はその立ち絵）、立ち絵は前のまま。
        let r = res();
        let b = entry(Kind.Character, "b");
        let texture = CastDoc.textureOf("b", b#face);
        let held = Res.withMissing(Set#{texture}, r);
        let l1 = begun(r);
        let w = advance(held, l1);
        Assert.assertEq(expected = (Some(World.HoldPhase.FadingOut), Some(texture :: Nil), stageMark(l1)),
                        (World.holdPhaseOf(w), World.readOf(w) |> Option.flatMap(rd -> rd#hold) |> Option.map(h -> h#names), stageMark(w)))

    @Test
    def testUnarrivedCastIsNotDrawn(): Unit \ {Assert, Fs.FileRead} =
        // まだ届いていない立ち絵は描かない（届いている人は描く）。frame とサムネは同じ層の関数を引く。
        let layer = played(("show", "a" :: Nil) :: ("show", "b" :: "at=right" :: Nil) :: Nil);
        let hidden = CastDoc.textureOf("a", entry(Kind.Character, "a")#face);
        Assert.assertEq(expected = "picture_cast_b_plain" :: Nil, drawn(envAt(10.0, Set#{hidden}), layer) |> List.map(fst))

    @Test
    def testWaitingSettlesTheCastCrossfade(): Unit \ {Assert, Fs.FileRead} =
        // 黒へ重ね切って Waiting に入ると、立ち絵の重ねの途中は終わりの形になる（重ね始めの時刻を「終わった過去」にする）。
        // b を出した直後（重ねの途中）に、届いていない a の笑顔へ替える所まで送る。
        let r = res();
        let smile = CastDoc.textureOf("a", "smile");
        let held = Res.withMissing(Set#{smile}, r);
        let typing = advance(held, begun(r));
        let fading = advance(held, advance(held, typing));
        let waiting = stepBy(held, KindDoc.rec(r#kind)#holdFadeSeconds + 0.01, fading);
        let starts = (w: World.World) -> World.stageOf(r, w)#cast#cast |> List.map(s -> Clock.secondsOf(s#startedAt));
        let never = Clock.secondsOf(Clock.never());
        Assert.assertEq(expected = (Some(World.HoldPhase.Waiting), never :: never :: Nil), (World.holdPhaseOf(waiting), starts(waiting)))

    // ══ 置き場所 ══

    @Test
    def testEverySlotRectStaysOnScreen(): Unit \ {Assert, Fs.FileRead} =
        // 横でも縦でも、どの位置に、位置の高さを超える倍率（b の scale）の人を置いても、矩形は画面の中に収まる。
        let b = entry(Kind.Character, "b");
        let fits = Layout.Fit.Regular :: Layout.Fit.Portrait(PortraitDoc.rec(PortraitDoc.defaults()), Display.defaultPortraitView()) :: Nil;
        let inside = (fit: Layout.Fit, slot: CastDoc.Slot) -> {
            let rect = Cast.rectOf(fit, slot, b);
            let size = Layout.size(fit);
            rect#position#x >= 0.0 and rect#position#y >= 0.0 and rect#position#x + rect#size#x <= size#x + 0.001 and rect#position#y + rect#size#y <= size#y + 0.001
        };
        let checks = fits |> List.flatMap(fit -> {
            let slots = if (Layout.isPortrait(fit)) d()#portraitSlots else d()#slots;
            Map.valuesOf(slots) |> List.map(slot -> inside(fit, slot))
        });
        Assert.assertEq(expected = List.map(_ -> true, checks), checks)
}
