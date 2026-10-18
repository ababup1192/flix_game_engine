// 性質テスト: 種で決まる乱数のキー操作を App.trace（画面なし）に流し、返事の音の決まりを見る。
// 台本は小さな fixture（分岐 1 つ・結末 2 つ）。灯りの演出（LampFx）の音は決まった手順で数える。
mod TestTrace {

    use fge::{App, Clock, PropTrace, PxSpriteDoc, Timeline, UiStore}
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq, ToString {
        case Confirm, Prev, Next, Menu
    }

    def keyOf(role: Role): Key = match role {
        case Role.Confirm => Key.Z
        case Role.Prev    => Key.Up
        case Role.Next    => Key.Down
        case Role.Menu    => Key.Escape
    }

    def setup(): PropTrace.Setup[Role] =
        { keyOf = keyOf, viewport = { x = World.width(), y = World.height() }, dt = 1.0 / 60.0 }

    def spec(): PropTrace.Spec[Role] =
        { taps = Role.Confirm :: Role.Prev :: Role.Next :: Nil, holds = Nil, idle = 3,
          dts = 1.0 / 60.0 :: 0.5 :: Nil }

    def beat(speaker: String, text: String): StoryDoc.Beat = { speaker = speaker, text = text }

    def fixture(): StoryDoc.Doc =
        StoryDoc.Doc.Doc({
          version = 1, title = "test", subtitle = "", hint = "", menuLabel = "", start = "hall", lamps = 2,
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

    def start(): World.World =
        World.initial({ story = fixture(), kind = KindDoc.defaults(),
                        theme = ThemeDoc.defaults(), sprites = PxSpriteDoc.empty() },
                      UiStore.empty())

    /// 実機（Main）と同じ更新（step → interact）と音の部品だけを繋いだ App。
    def app(): App.App[World.World, {}] =
        App.make(start())
            |> App.addSystem((f, w) -> Controls.step(f, w) |> (w1 -> Controls.interact(f, w1)))
            |> App.withAudio(Controls.sounds)

    def replies(step: PropTrace.Step[World.World]): Int32 =
        List.count(name -> Set.memberOf(name, Controls.replyNames()), step#sounds)

    def count(name: String, steps: List[PropTrace.Step[World.World]]): Int32 =
        steps |> List.map(s -> List.count(n -> n == name, s#sounds)) |> List.sum

    @Test
    def testOnePressOneReply(): Unit \ Assert =
        // 押したフレームの返事の音は 1 回まで・押していないフレームは返事が鳴らない。
        let rule = (step: PropTrace.Step[World.World]) -> {
            let pressed = not Set.isEmpty(step#frame#justPressed);
            let got = replies(step);
            if (not pressed and got > 0) Some("押していないのに返事が ${Int32.toString(got)} 回")
            else if (got > 1) Some("1 回の押しに返事が ${Int32.toString(got)} 回")
            else None
        };
        let broken = PropTrace.firstFailingSeed(20, seed ->
            PropTrace.firstBroken(app(), setup(), PropTrace.plan(seed, 300, spec()), start(), rule)
                |> Option.map(found -> { let (frame, why, _) = found; "${Int32.toString(frame)} フレーム目: ${why}" }));
        Assert.assertEq(expected = None, broken)

    @Test
    def testRepliesAreHeard(): Unit \ Assert =
        // 上の決まりが空振りでないこと: でたらめに押せば返事は鳴っている。
        let heard = PropTrace.traceOf(app(), setup(), PropTrace.plan(1i64, 300, spec()), start())
            |> List.map(replies) |> List.sum;
        Assert.assertEq(expected = true, heard > 0)

    @Test
    def testDoubtPlaysLampFxOnce(): Unit \ Assert =
        // 疑う選択をすると、演出の 2 つの音（揺らぐ・消える）がその後の 1 秒でちょうど 1 回ずつ鳴る。
        let settle = PropTrace.Act.Idle(1000.0);
        let toAsk = PropTrace.Act.Tap(Role.Confirm) :: settle :: PropTrace.Act.Tap(Role.Confirm) :: settle
            :: PropTrace.Act.Tap(Role.Confirm) :: settle :: Nil;
        let afterDoubt = PropTrace.Act.Tap(Role.Confirm) :: List.repeat(60, PropTrace.Act.Idle(1.0 / 60.0));
        let steps = PropTrace.traceOf(app(), setup(), List.append(toAsk, afterDoubt), start());
        Assert.assertEq(expected = (1, 1, 1), (count("doubt", steps), count("lamp_flicker", steps), count("lamp_out", steps)))

    @Test
    def testMenuDuringLampFxRingsEachOnce(): Unit \ Assert =
        // 灯りの演出の途中（揺らぐ音の後・消える音の前）でメニューを開いて 2 秒置き、閉じても、
        // 2 つの音はちょうど 1 回ずつ（止めている間は鳴らず、戻っても鳴り直さない）。
        let settle = PropTrace.Act.Idle(1000.0);
        let toAsk = PropTrace.Act.Tap(Role.Confirm) :: settle :: PropTrace.Act.Tap(Role.Confirm) :: settle
            :: PropTrace.Act.Tap(Role.Confirm) :: settle :: Nil;
        let frames = n -> List.repeat(n, PropTrace.Act.Idle(1.0 / 60.0));
        let doubt = PropTrace.Act.Tap(Role.Confirm) :: frames(15);
        let menu = PropTrace.Act.Tap(Role.Menu) :: frames(120) ::: PropTrace.Act.Tap(Role.Menu) :: frames(60);
        let steps = PropTrace.traceOf(app(), setup(), toAsk ::: doubt ::: menu, start());
        let inMenu = steps |> List.filter(s -> s#before#menu == World.Menu.Open and s#after#menu == World.Menu.Open);
        Assert.assertEq(expected = (1, 1, 0),
            (count("lamp_flicker", steps), count("lamp_out", steps), count("lamp_out", inMenu)))

    @Test
    def testMenuStopsLampFx(): Unit \ Assert =
        // メニューを開いている間は、炎の細りが進まない（物語の時計が止まる）。
        let settle = PropTrace.Act.Idle(1000.0);
        let toAsk = PropTrace.Act.Tap(Role.Confirm) :: settle :: PropTrace.Act.Tap(Role.Confirm) :: settle
            :: PropTrace.Act.Tap(Role.Confirm) :: settle :: Nil;
        let frames = n -> List.repeat(n, PropTrace.Act.Idle(1.0 / 60.0));
        let steps = PropTrace.traceOf(app(), setup(), toAsk ::: PropTrace.Act.Tap(Role.Confirm) :: frames(6)
            ::: PropTrace.Act.Tap(Role.Menu) :: frames(60), start());
        let flickers = steps |> List.map(s -> LampFx.flickerOf(s#after)) |> List.reverse |> List.take(30);
        Assert.assertEq(expected = 1, flickers |> List.distinct |> List.length)

    @Test
    def testFlickerFollowsTimeline(): Unit \ Assert =
        // 炎の細り具合は、消えた時刻から測った Flicker の進み（長さは時刻表から導く）。
        let tl = LampFx.timeline();
        let half = Timeline.clipOf(LampFx.Beat.Flicker, tl) |> Option.map(c -> c#dur / 2.0) |> Option.getWithDefault(0.0);
        let story = Clock.startAt(10.0);
        let w = { lampOutAt = Some(Clock.nowOf(story)), storyClock = Clock.advance(Clock.Run.Running, half, story) | start() };
        Assert.assertEq(expected = 0.5, LampFx.flickerOf(w))
}
