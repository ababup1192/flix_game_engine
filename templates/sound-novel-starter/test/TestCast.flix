// 立ち絵と小物（Cast）: シナリオの <<char>> / <<item>> の読み方、出し入れと重ね方、セーブ・ロード・バックログから戻る時の持ち越し、
// 素材の待ちとのつなぎ、置き場所。人物と位置の名前はテスト用の Doc（test/fixtures/novel.cast.json）、
// シナリオはテスト用の木（test/fixtures/talk/cast.yarn を build した物）から引き、期待値は Doc から導く。
mod TestCast {

    use fge::{Clock, Display, Render, Yarn, YarnRunner}
    use Util.Json.Json
    use CastDoc.Kind
    use TestKit.{advance, begun, quiet, settle, stepBy}

    /// テスト用の Doc。
    def doc(): CastDoc.Doc \ Fs.FileRead = CastDoc.load("test/fixtures/novel.cast.json")

    def d(): CastDoc.Rec \ Fs.FileRead = CastDoc.rec(doc())

    /// テスト用の Doc とシナリオに差し替えた描く元。
    def res(): Res.Res \ Fs.FileRead =
        TestKit.res() |> Res.withCast(doc()) |> Res.withDialogue(Yarn.loadOr(Yarn.empty(), "test/fixtures/talk/dialogue.json"))

    /// 項目の既定の表情と位置。
    def entry(kind: Kind, name: String): CastDoc.Entry \ Fs.FileRead =
        CastDoc.entryOf(kind, name, doc()) |> Option.getWithDefault({ label = "", aspect = 0.0, scale = 0.0, face = "", slot = "", faces = Nil })

    /// コマンド 1 つ（<<name args…>>）。
    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def cueOf(name: String, args: List[String]): Result[String, Cast.Cue] \ Fs.FileRead = Cast.cueOf(doc(), command(name, args))

    /// 物語の時計の seconds 秒の時刻。
    def t(seconds: Float64): Clock.Time[Stage.Story] = Clock.startAt(seconds) |> Clock.nowOf

    /// コマンドの列を、0 秒・1 秒・2 秒…の時刻で空の層へ順に当てる（読めないコマンドは飛ばす）。
    def played(cues: List[(String, List[String])]): Cast.Layer \ Fs.FileRead =
        cues |> List.zipWithIndex |> List.foldLeft((layer, pair) -> {
            let (i, (name, args)) = pair;
            cueOf(name, args) |> Result.map(c -> Cast.apply(t(Int32.toFloat64(i)), c, layer)) |> Result.getWithDefault(layer)
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
        { doc = doc(), fit = Layout.Fit.Regular, storyNow = t(now), realNow = Clock.zero(), missing = missing }

    // ══ シナリオのコマンドを読む ══

    @Test
    def testCueWordsReadInAnyOrder(): Unit \ {Assert, Fs.FileRead} =
        // 名前の後ろの語（表情・位置・秒）は、順が違っても同じ意味になる。
        let a = cueOf("char", "a" :: "smile" :: "left" :: "1.5" :: Nil) |> Result.map(cueTuple);
        let b = cueOf("char", "a" :: "1.5" :: "left" :: "smile" :: Nil) |> Result.map(cueTuple);
        let want: Result[String, (String, String, String, String, Bool, Bool, Float64)] = Ok(("Character", "a", "smile", "left", false, false, 1.5));
        Assert.assertEq(expected = (want, want), (a, b))

    @Test
    def testOmittedWordsComeFromTheDoc(): Unit \ {Assert, Fs.FileRead} =
        // 省いた表情・位置・秒は Doc の face・slot・fadeSeconds で埋め、表情と位置は「出ていれば今のまま」の印を付ける。
        let b = entry(Kind.Character, "b");
        Assert.assertEq(expected = Ok(("Character", "b", b#face, b#slot, true, true, d()#fadeSeconds)),
                        cueOf("char", "b" :: Nil) |> Result.map(cueTuple))

    @Test
    def testUnknownWordsAreErrors(): Unit \ {Assert, Fs.FileRead} =
        // 知らない人物・表情・位置、off の後ろの数でない秒、小物の欄に無い名前は Err（舞台はそのまま）。
        let errs = (cueOf("char", "zz" :: Nil) :: cueOf("char", "a" :: "angry" :: Nil) :: cueOf("char", "a" :: "top" :: Nil)
                    :: cueOf("char", "a" :: "off" :: "soon" :: Nil) :: cueOf("item", "a" :: Nil) :: Nil) |> List.map(Result.isErr);
        Assert.assertEq(expected = true :: true :: true :: true :: true :: Nil, errs)

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
        let layer = played(("char", "a" :: "center" :: Nil) :: ("char", "b" :: "center" :: Nil) :: Nil);
        Assert.assertEq(expected = ((("b", entry(Kind.Character, "b")#face, "center") :: Nil), "a" :: Nil), (castOf(layer), leavingOf(layer)))

    @Test
    def testReshowWithoutSlotKeepsTheSlotAndChangesTheFace(): Unit \ {Assert, Fs.FileRead} =
        // 位置を省いて出し直すと、位置はそのままで表情だけが替わり、前の表情を下に残す。
        let layer = played(("char", "a" :: "left" :: Nil) :: ("char", "a" :: "smile" :: Nil) :: Nil);
        Assert.assertEq(expected = (("a", "smile", "left") :: Nil, Some(entry(Kind.Character, "a")#face)),
                        (castOf(layer), List.head(layer#cast) |> Option.flatMap(s -> s#before) |> Option.map(u -> u#figure#face)))

    @Test
    def testMovingToAnotherSlotFadesOutTheOldSlot(): Unit \ {Assert, Fs.FileRead} =
        // 位置を替えると、前の位置の形は消えていく物になり、新しい位置に出し直す（すべらせない）。
        let layer = played(("char", "a" :: "left" :: Nil) :: ("char", "a" :: "right" :: Nil) :: Nil);
        Assert.assertEq(expected = (("a", entry(Kind.Character, "a")#face, "right") :: Nil, "a" :: Nil), (castOf(layer), leavingOf(layer)))

    @Test
    def testOffHidesOneAndCharOffHidesAll(): Unit \ {Assert, Fs.FileRead} =
        // <<char 名前 off>> はその人だけ、<<char off>> は全員を消す。
        let two = ("char", "a" :: Nil) :: ("char", "b" :: Nil) :: Nil;
        let one = played(List.append(two, ("char", "a" :: "off" :: Nil) :: Nil));
        let none = played(List.append(two, ("char", "off" :: Nil) :: Nil));
        Assert.assertEq(expected = ("b" :: Nil, 0), (castOf(one) |> List.map(match (n, _, _) -> n), List.length(none#cast)))

    @Test
    def testItemReplacesThePreviousProp(): Unit \ {Assert, Fs.FileRead} =
        // <<item>> は前の小物と入れ替わり（前の小物は消えていく）、<<item off>> で消える。人物の列には入らない。
        let swapped = played(("item", "cup" :: Nil) :: ("item", "fan" :: Nil) :: Nil);
        let gone = played(("item", "cup" :: Nil) :: ("item", "off" :: Nil) :: Nil);
        Assert.assertEq(expected = (Some("fan"), "cup" :: Nil, 0, None),
                        (swapped#prop |> Option.map(s -> s#now#name), leavingOf(swapped), List.length(swapped#cast), gone#prop |> Option.map(s -> s#now#name)))

    // ══ 重ね方 ══

    @Test
    def testFaceChangeKeepsTheOldFaceOpaqueUnderneath(): Unit \ {Assert, Fs.FileRead} =
        // 同じ位置で表情を替える途中は、前の表情を濃さ 1 で下に敷き、今の表情は 0 と 1 の間（透けない）。
        // 表情は 1 秒の時刻に替えたので、fadeSeconds の半分だけ後を見る。
        let layer = played(("char", "a" :: Nil) :: ("char", "a" :: "smile" :: Nil) :: Nil);
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
        let shown = played(("char", "a" :: Nil) :: Nil);
        let changed = cueOf("char", "a" :: "smile" :: Nil) |> Result.map(c -> Cast.apply(t(at), c, shown)) |> Result.getWithDefault(shown);
        let before = visibleAt(at, shown);
        Assert.assertEq(expected = (true, true, true),
                        (before > 0.0, visibleAt(at, changed) <= before + 0.000001, visibleAt(at + fade / 2.0, changed) > before))

    @Test
    def testOffWhileFadingInNeverBrightens(): Unit \ {Assert, Fs.FileRead} =
        // 出てくる途中（fadeSeconds の 3 割の所）で消すと、消えていく形はその時の濃さから薄くなる（一度濃くならない）。
        let fade = d()#fadeSeconds;
        let at = fade * 0.3;
        let shown = played(("char", "a" :: Nil) :: Nil);
        let off = cueOf("char", "a" :: "off" :: Nil) |> Result.map(c -> Cast.apply(t(at), c, shown)) |> Result.getWithDefault(shown);
        let before = visibleAt(at, shown);
        Assert.assertEq(expected = (true, true, 0.0),
                        (visibleAt(at, off) <= before + 0.000001, visibleAt(at + fade / 2.0, off) < before, visibleAt(at + fade, off)))

    @Test
    def testMovingDuringAFaceChangeFadesBothShapes(): Unit \ {Assert, Fs.FileRead} =
        // 表情を替えている途中で位置を替えると、前の位置の今の形も下に敷いた形も、消えていく物になる（下の形が急に消えない）。
        let fade = d()#fadeSeconds;
        let changing = played(("char", "a" :: Nil) :: ("char", "a" :: "smile" :: Nil) :: Nil);
        let moved = cueOf("char", "a" :: "left" :: Nil) |> Result.map(c -> Cast.apply(t(1.0 + fade * 0.3), c, changing)) |> Result.getWithDefault(changing);
        Assert.assertEq(expected = ("cast_a_plain" :: "cast_a_smile" :: Nil),
                        moved#leaving |> List.map(l -> Cast.textureOf(l#figure)))

    @Test
    def testSettleEndsCrossfadesAndLeaving(): Unit \ {Assert, Fs.FileRead} =
        // settle は重ねの途中を終わりの形にする: 前の表情を捨て、消えていく物を空にする。
        let layer = Cast.settle(played(("char", "a" :: Nil) :: ("char", "b" :: "center" :: Nil) :: ("char", "b" :: "left" :: Nil) :: Nil));
        Assert.assertEq(expected = (Nil, 0), (layer#cast |> List.filterMap(s -> s#before) |> List.map(u -> figureTuple(u#figure)), List.length(layer#leaving)))

    @Test
    def testPresenceFollowsTheFade(): Unit \ {Assert, Fs.FileRead} =
        // 人物がどれだけ出ているか（縦の頁の覆いを薄くする量）は、出始めが 0・途中が 0 と 1 の間・出切ると 1・消し切ると 0。
        let shown = played(("char", "a" :: Nil) :: Nil);
        let hidden = played(("char", "a" :: Nil) :: ("char", "a" :: "off" :: Nil) :: Nil);
        let fade = d()#fadeSeconds;
        let mid = Cast.presenceOf(t(fade / 2.0), shown);
        Assert.assertEq(expected = (0.0, true, 1.0, 0.0),
                        (Cast.presenceOf(t(0.0), shown), mid > 0.0 and mid < 1.0, Cast.presenceOf(t(fade), shown), Cast.presenceOf(t(1.0 + fade), hidden)))

    // ══ セーブに残す形 ══

    @Test
    def testMarkSurvivesJson(): Unit \ {Assert, Fs.FileRead} =
        // 残した形を JSON に書いて読み直すと同じ形に戻る。
        let mark = Cast.markOf(played(("char", "a" :: "smile" :: Nil) :: ("char", "b" :: "right" :: Nil) :: ("item", "cup" :: Nil) :: Nil));
        Assert.assertEq(expected = markTuple(mark), markTuple(Cast.markFromJson(Some(Cast.markToJson(mark)))))

    @Test
    def testOldSaveWithoutCastReadsEmpty(): Unit \ {Assert, Fs.FileRead} =
        // cast の欄が無い古いセーブの枠は、立ち絵の無い形として読む（Saves.fromJson が渡す欄が None）。
        let r = res();
        let fresh = Saves.fresh(r#kind);
        let bookmark = WorldRead.slotHere(r, begun(r)) |> Option.map(s -> YarnRunner.bookmarkToJson(s#mark#bookmark));
        let old = bookmark |> Option.map(bm -> Json.JObject(Map#{ "slots" => Json.JObject(Map#{ "0" => Json.JObject(Map#{ "bookmark" => bm, "mode" => Json.JString("Adv") }) }) }));
        let read = old |> Option.map(Saves.fromJson(fresh))
            |> Option.flatMap(s -> Map.get(0, Saves.rec(s)#slots)) |> Option.map(s -> markTuple(s#mark#cast));
        Assert.assertEq(expected = Some((Nil, None)), read)

    // ══ ロード・バックログから戻る時の持ち越し（テスト用のシナリオ） ══

    /// 台詞を出し終えた所から送って、次の台詞を出し終えた所。
    def next(r: Res.Res, w: World.World): World.World = settle(r, advance(r, w))

    /// 送るたびの、読み進めた舞台と、その行の戻れる所（バックログの一番新しい行）から戻した舞台の (立ち絵の形, 戻した立ち絵の形)。
    def liveAndRestored(r: Res.Res, w: World.World): (List[(String, String, String)], Option[(String, String, String)], List[(String, String, String)], Option[(String, String, String)]) =
        let mark = World.logOf(w) |> List.head |> Option.flatMap(e -> match e {
            case World.Entry.Said(_, m) => m
            case _                      => None
        });
        let live = markTuple(Cast.markOf(Cast.settle(World.stageOf(r, w)#cast)));
        let back = mark |> Option.map(m -> settle(r, quiet(() -> WorldRead.restore(r, m, w))))
            |> Option.map(b -> markTuple(Cast.markOf(Cast.settle(World.stageOf(r, b)#cast)))) |> Option.getWithDefault((Nil, None));
        (fst(live), snd(live), fst(back), snd(back))

    @Test
    def testLiveStageMatchesTheRestoredStageOnEveryLine(): Unit \ {Assert, Fs.FileRead} =
        // テスト用のシナリオの全部の台詞で、読み進めた立ち絵と、その行の戻れる所から戻した立ち絵が同じ（前のノードで出した人も戻る）。
        let r = res();
        let l1 = begun(r);
        let l2 = next(r, l1);
        let l3 = next(r, l2);
        let l4 = next(r, l3);
        let l5 = next(r, l4);
        let l6 = next(r, l5);
        let l7 = next(r, l6);
        let l8 = next(r, l7);
        let pairs = (l1 :: l2 :: l3 :: l4 :: l5 :: l6 :: l7 :: l8 :: Nil) |> List.map(liveAndRestored(r));
        // 4 行目（Station の最後）は 2 人と小物が出ている所（空どうしの一致で通らないことの確かめ）。
        Assert.assertEq(expected = (pairs |> List.map(match (c, p, _, _) -> (c, p, c, p)), (shownAtL4(), Some(("cup", "plain", "item")))),
                        (pairs, stageMark(l4)))

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
        let layer = played(("char", "a" :: Nil) :: ("char", "b" :: "right" :: Nil) :: Nil);
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
