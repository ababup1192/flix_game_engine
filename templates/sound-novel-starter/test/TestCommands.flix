// 演出コマンドの表（Commands）をテストする: 表の全部のコマンドが必須の引数だけで当たること・名前が重ならないこと・
// 頁と音の出来事（Out）・当て直し（Silent）で音が落ちること・時間を取るか（timing）・待つ素材の名前。
// 写真・時間帯・音の名前は Doc（novel.backdrops.json・project.json）から引く。
mod TestCommands {

    use fge::{Clock, Yarn, YarnCommands}
    use Commands.Out

    def command(name: String, args: List[String]): Yarn.Command =
        { name = name, args = args, tags = Nil, source = { file = "test", line = 1 } }

    def ctx(res: Res.Res): Commands.Ctx = { now = Clock.zero(), node = "", res = res }

    def photoOf(res: Res.Res): String = BackdropDoc.rec(res#backdrops)#photos |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("")

    def gradeOf(res: Res.Res): String = BackdropDoc.rec(res#backdrops)#grades |> Map.keysOf |> Set.toList |> List.head |> Option.getWithDefault("")

    def ambienceOf(res: Res.Res): String = StoryDoc.rec(res#story)#titleAmbience

    def exec(res: Res.Res, replay: Commands.Replay, name: String, args: List[String], st: Stage.Stage): Result[String, (Stage.Stage, List[Out])] =
        Commands.execute(replay, ctx(res), command(name, args), st)

    def outsOf(res: Res.Res, replay: Commands.Replay, name: String, args: List[String], st: Stage.Stage): Result[String, List[Out]] =
        exec(res, replay, name, args, st) |> Result.map(snd)

    /// 表のコマンドごとに、必須の引数だけを書いた 1 行（人物と小物はテスト用の Doc の名前）。
    def samples(res: Res.Res): List[(String, List[String])] =
        ("bg", photoOf(res) :: "grade=${gradeOf(res)}" :: Nil) :: ("window", "nvl" :: Nil) :: ("audio", "ambience" :: ambienceOf(res) :: Nil)
        :: ("fx", "off" :: Nil) :: ("shake", Nil) :: ("show", "a" :: Nil) :: ("hide", "all" :: Nil) :: Nil

    def castRes(): Res.Res \ Fs.FileRead = TestKit.res() |> Res.withCast(CastDoc.load("test/fixtures/novel.cast.json"))

    def namesOfTable(): List[String] = Commands.specs() |> List.map(YarnCommands.nameOf)

    @Test
    def testEveryCommandInTheTableRunsWithItsRequiredArguments(): Unit \ {Assert, Fs.FileRead} =
        // 表の全部のコマンドを、必須の引数だけで 1 回ずつ当てて Ok になる（表に入れていない引数を読む書き忘れを拾う）。
        let res = castRes();
        let failed = samples(res) |> List.filter(match (name, args) -> Result.isErr(exec(res, Commands.Replay.Live, name, args, Stage.empty())));
        Assert.assertEq(expected = (Nil, List.toSet(namesOfTable())), (failed, samples(res) |> List.map(fst) |> List.toSet))

    @Test
    def testCommandNamesAreUnique(): Unit \ Assert =
        // テンプレートの表とゲームの表を合わせても、同じ名前のコマンドは無い（後の物は引かれない）。
        Assert.assertEq(expected = List.distinct(namesOfTable()), namesOfTable())

    @Test
    def testUnknownCommandIsAnError(): Unit \ {Assert, Fs.FileRead} =
        let res = TestKit.res();
        Assert.assertTrue(Result.isErr(exec(res, Commands.Replay.Live, "nvl", Nil, Stage.empty())))

    @Test
    def testWindowClearsThePageOnlyWhenTheModeChanges(): Unit \ {Assert, Fs.FileRead} =
        // 文章の出し方が替わる時だけ頁をめくる。同じ出し方の <<window>> は何も出さない。clear はいつもめくる。
        let res = TestKit.res();
        let nvl = Stage.empty();
        Assert.assertEq(expected = (Ok(Out.ClearPage :: Nil), Ok(Nil), Ok(Out.ClearPage :: Nil)),
                        (outsOf(res, Commands.Replay.Live, "window", "bottom" :: Nil, nvl), outsOf(res, Commands.Replay.Live, "window", "nvl" :: Nil, nvl),
                         outsOf(res, Commands.Replay.Live, "window", "clear" :: Nil, nvl)))

    @Test
    def testBackdropTurnsThePageOnlyInAdv(): Unit \ {Assert, Fs.FileRead} =
        // ADV の時の <<bg>> は頁を送る。NVL では送らない（NVL の頁の切れ目は <<window clear>> と行の数が決める）。
        let res = TestKit.res();
        let args = photoOf(res) :: "grade=${gradeOf(res)}" :: Nil;
        Assert.assertEq(expected = (Ok(Out.TurnPage :: Nil), Ok(Nil)),
                        (outsOf(res, Commands.Replay.Live, "bg", args, { mode = Stage.Mode.Adv | Stage.empty() }), outsOf(res, Commands.Replay.Live, "bg", args, Stage.empty())))

    @Test
    def testBackdropWithoutGradeKeepsTheCurrentGrade(): Unit \ {Assert, Fs.FileRead} =
        // grade= を省くと今の背景の時間帯のまま。背景がまだ無ければ Err。
        let res = TestKit.res();
        let first = exec(res, Commands.Replay.Live, "bg", photoOf(res) :: "grade=${gradeOf(res)}" :: Nil, Stage.empty()) |> Result.map(fst);
        let next = first |> Result.flatMap(st -> exec(res, Commands.Replay.Live, "bg", photoOf(res) :: Nil, st)) |> Result.map(p -> fst(p)#shot |> Option.map(s -> s#grade));
        Assert.assertEq(expected = (Ok(Some(gradeOf(res))), true),
                        (next, Result.isErr(exec(res, Commands.Replay.Live, "bg", photoOf(res) :: Nil, Stage.empty()))))

    @Test
    def testSilentReplayDropsSounds(): Unit \ {Assert, Fs.FileRead} =
        // 当て直し（Silent）では効果音を出さない。人が読んでいる時（Live）は出す。
        let res = TestKit.res();
        let args = "se" :: "se_slap" :: Nil;
        Assert.assertEq(expected = (Ok(Out.Sound("se_slap") :: Nil), Ok(Nil)),
                        (outsOf(res, Commands.Replay.Live, "audio", args, Stage.empty()), outsOf(res, Commands.Replay.Silent, "audio", args, Stage.empty())))

    @Test
    def testAmbienceIsKeptOnTheStage(): Unit \ {Assert, Fs.FileRead} =
        // <<audio ambience 音>> は舞台に残り、off で止まる。
        let res = TestKit.res();
        let on = exec(res, Commands.Replay.Live, "audio", "ambience" :: ambienceOf(res) :: Nil, Stage.empty()) |> Result.map(fst);
        let off = on |> Result.flatMap(st -> exec(res, Commands.Replay.Live, "audio", "ambience" :: "off" :: Nil, st)) |> Result.map(fst);
        let read = (r: Result[String, Stage.Stage]) -> r |> Result.map(st -> Stage.ambienceOf(Clock.zero(), st));
        Assert.assertEq(expected = (Ok(Some(ambienceOf(res))), Ok(None)), (read(on), read(off)))

    @Test
    def testTimingMarksOnlyCommandsThatTakeTime(): Unit \ {Assert, Fs.FileRead} =
        // 背景・揺れ・立ち絵は時間を取り、音・文章の出し方・パーティクルは取らない。
        let res = TestKit.res();
        let timed = ("bg", photoOf(res) :: "grade=${gradeOf(res)}" :: Nil) :: ("shake", Nil) :: ("show", "a" :: Nil) :: ("hide", "all" :: Nil) :: Nil;
        let instant = ("window", "nvl" :: Nil) :: ("audio", "se" :: "se_slap" :: Nil) :: ("fx", "off" :: Nil) :: Nil;
        let timingOf = (pair: (String, List[String])) -> Commands.timingOf(command(fst(pair), snd(pair)));
        Assert.assertEq(expected = (List.repeat(4, Commands.Timing.Timed), List.repeat(3, Commands.Timing.Instant)),
                        (timed |> List.map(timingOf), instant |> List.map(timingOf)))

    @Test
    def testNeedsNameTheBackdropTextureAndTheAmbience(): Unit \ {Assert, Fs.FileRead} =
        // 待つ素材: <<bg>> は写真の texture、<<audio ambience>> はその音、効果音は待たない。
        let res = TestKit.res();
        let texture = BackdropDoc.textureOf(photoOf(res), res#backdrops) |> Option.toList;
        let needs = (name, args) -> Commands.needsOf(res, command(name, args), Stage.empty());
        Assert.assertEq(expected = (texture, ambienceOf(res) :: Nil, Nil),
                        (needs("bg", photoOf(res) :: "grade=${gradeOf(res)}" :: Nil), needs("audio", "ambience" :: ambienceOf(res) :: Nil),
                         needs("audio", "se" :: "se_slap" :: Nil)))

    @Test
    def testShakeIsSettledAway(): Unit \ {Assert, Fs.FileRead} =
        // 揺れは settle で止まる（セーブから戻った時に揺れの途中を見せない）。
        let res = TestKit.res();
        let k = KindDoc.rec(res#kind);
        let shook = exec(res, Commands.Replay.Live, "shake", Nil, Stage.empty()) |> Result.map(fst) |> Result.getWithDefault(Stage.empty());
        let mid = Clock.after(k#shakeSeconds / 3.0, Clock.zero());
        Assert.assertEq(expected = (true, (0.0, 0.0)),
                        (Stage.shakeOffset(mid, k#shakeSeconds, k#shakePx, shook) != (0.0, 0.0), Stage.shakeOffset(mid, k#shakeSeconds, k#shakePx, Stage.settle(shook))))
}
