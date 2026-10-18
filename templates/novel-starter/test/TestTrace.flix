// 性質テスト: 種で決まるでたらめなキーとクリックを App.trace の道（PropertyTest・画面なし）に流し、
// どう読み進めても崩れない決まりを見る。押さなければ返事は鳴らない・1 回の押しに返事は 1 回まで・
// 灯りは疑う選択でだけ 1 つずつ減り、減ったフレームだけ消える演出の音が鳴る。
// 台本は小さな fixture（分岐 1 つ・結末 2 つ）。
mod TestTrace {

    use fge::{App, Emit, PropertyTest, PxSpriteDoc, Timeline}
    use fge::PropertyTest.Input
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq {
        case Confirm, Prev, Next
    }

    def keyOf(role: Role, _w: World.World): Key = match role {
        case Role.Confirm => Key.Z
        case Role.Prev    => Key.Up
        case Role.Next    => Key.Down
    }

    def setup(): PropertyTest.Setup[Role, World.World] =
        { keyOf = keyOf, viewport = { x = World.width(), y = World.height() }, dt = 1.0 / 60.0 }

    /// 種 20 個 × 300 入力。キー 3 つ・画面の 2 か所のクリック・文字送りを使い切る 0.5 秒の待ち。
    def cases(): PropertyTest.Cases[Role] =
        { seeds = 20, length = 300,
          spec = { taps = List#{Role.Confirm, Role.Prev, Role.Next}, idle = 3, dts = List#{1.0 / 60.0, 0.5},
                   points = List#{{ x = 40.0, y = 40.0 }, { x = World.width() / 2.0, y = World.height() - 30.0 }}
                   | PropertyTest.emptySpec() } }

    def beat(speaker: String, text: String): StoryDoc.Beat = { speaker = speaker, text = text }

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

    /// 実機と同じ UI（会話窓と選択肢のチップ）を読んだ始まりの World。UI が空だと選択肢のカーソルが動かない。
    def start(): World.World \ Fs.FileRead =
        World.initial({ story = fixture(), kind = KindDoc.defaults(),
                        theme = ThemeDoc.defaults(), sprites = PxSpriteDoc.empty() },
                      NovelKit.spawnAssets())

    /// 実機（Main）と同じ更新（step → interact）と音の部品だけを繋いだ App。
    def app(w0: World.World): App.App[World.World, {}] =
        App.make(w0)
            |> App.addSystem((f, w) -> Controls.step(f, w) |> (w1 -> Controls.interact(f, w1)))
            |> App.withAudio(Controls.sounds)

    def replies(step: App.TraceStep[World.World]): Int32 =
        List.count(name -> Set.memberOf(name, Controls.replyNames()), step#sounds)

    def heard(name: String, step: App.TraceStep[World.World]): Int32 =
        List.count(sound -> sound == name, step#sounds)

    def count(name: String, steps: List[App.TraceStep[World.World]]): Int32 =
        steps |> List.map(step -> heard(name, step)) |> List.sum

    /// キーもボタンもマウスの動きも無いフレーム。
    def untouched(frame: App.Frame): Bool =
        Set.isEmpty(frame#justPressed) and not frame#mouseClicked and not frame#mouseMoved

    def opened(step: App.TraceStep[World.World]): Bool =
        List.memberOf(World.Event.Opened, Emit.since(step#before#events, step#after#events))

    /// 押さなければ返事は鳴らない・1 回の押しに返事は 1 回まで。
    @Test
    def testRepliesFollowPresses(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let rule = (step: App.TraceStep[World.World]) -> {
            let got = replies(step);
            if (untouched(step#frame) and got > 0) Some("押していないのに返事が ${got} 回")
            else if (got > 1) Some("1 回の押しに返事が ${got} 回")
            else None
        };
        Assert.assertEq(expected = None, PropertyTest.forAll(app(w0), setup(), cases(), w0, rule))

    /// 灯りの数 = 前の数 − 疑う選択の数（0 より下へは行かない）。物語をはじめたフレームは全部つき直る。
    /// 消える演出の頭の音（lamp_flicker）は、灯りが減ったフレームだけ鳴る。
    @Test
    def testLampsFallOnlyByDoubt(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let rule = (step: App.TraceStep[World.World]) -> {
            let before = World.lampsLit(step#before);
            let wanted = if (opened(step)) StoryDoc.rec(fixture())#lamps
                         else Int32.max(0, before - heard("doubt", step));
            let got = World.lampsLit(step#after);
            let flickers = heard("lamp_flicker", step);
            if (got != wanted) Some("灯り ${got}（欲しいのは ${wanted}）")
            else if (flickers != (if (got < before) 1 else 0)) Some("灯りが ${before} → ${got} で消える音 ${flickers} 回")
            else None
        };
        Assert.assertEq(expected = None, PropertyTest.forAll(app(w0), setup(), cases(), w0, rule))

    /// 上の決まりが空振りでないこと: 種 1 の列で返事が鳴り、どれかの種で灯りが消え、どれかの種で疑わない選択をしている。
    @Test
    def testRepliesAndDoubtsHappen(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let stepsOf = seed -> PropertyTest.traceOf(app(w0), setup(), PropertyTest.generate(seed, cases()#length, cases()#spec), w0);
        let seeds = List.range(1, cases()#seeds + 1) |> List.map(Int32.toInt64);
        Assert.assertEq(expected = (true, true, true),
            (List.exists(step -> replies(step) > 0, stepsOf(1i64)),
             List.exists(seed -> count("lamp_flicker", stepsOf(seed)) > 0, seeds),
             List.exists(seed -> count("pick", stepsOf(seed)) > 0, seeds)))

    /// 疑う選択をすると、演出の 2 つの音（揺らぐ・消える）がその後の 1 秒でちょうど 1 回ずつ鳴る。
    @Test
    def testDoubtPlaysLampFxOnce(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let settle = Input.Idle(1000.0);
        let toAsk = List#{Input.Tap(Role.Confirm), settle, Input.Tap(Role.Confirm), settle, Input.Tap(Role.Confirm), settle};
        let afterDoubt = Input.Tap(Role.Confirm) :: List.repeat(60, Input.Idle(1.0 / 60.0));
        let steps = PropertyTest.traceOf(app(w0), setup(), List.append(toAsk, afterDoubt), w0);
        Assert.assertEq(expected = (1, 1, 1), (count("doubt", steps), count("lamp_flicker", steps), count("lamp_out", steps)))

    /// 炎の細り具合は、消えた時刻から測った Flicker の進み。細りながら残るのは Flicker の間だけで、
    /// 消えた時刻より前（描き出しが時計を置き直した）は残らない（長さは時刻表から導く）。
    @Test
    def testFlickerFollowsTimeline(): Unit \ {Assert, Fs.FileRead} =
        let tl = LampFx.timeline();
        let half = Timeline.clipOf(LampFx.Beat.Flicker, tl) |> Option.map(c -> c#dur / 2.0) |> Option.getWithDefault(0.0);
        let at = t -> { lampOutAt = Some(10.0), t = t | start() };
        Assert.assertEq(expected = (0.5, true, false, false),
            (LampFx.flickerOf(at(10.0 + half)), LampFx.isFlickering(at(10.0 + half)),
             LampFx.isFlickering(at(10.0 + half * 2.0)), LampFx.isFlickering(at(8.4))))
}
