// 性質テスト: 種で決まるでたらめなキーとクリックを App.trace の道（PropertyTest・画面なし）に流し、
// どう読み進めても崩れない決まりを見る。押さなければ返事は鳴らない・1 回の押しに返事は 1 回まで・
// 灯りは疑う選択でだけ 1 つずつ減り、減ったフレームだけ消える演出の音が鳴る。
// メニュー（物語の時計を止める）の決まりは決まった手順で確かめる: 止めて戻しても演出の音は 1 回ずつ・
// 止めている間は炎の細りが進まない・止めている間も実時間は進む。
// シナリオは小さな fixture（test/talk/fixture.yarn・分岐 1 つ・結末 2 つ）。App は実機と同じ繋ぎ（TestKit.app）。
mod TestTrace {

    use fge::{App, Clock, Emit, PropertyTest, PxSpriteDoc, Timeline}
    use fge::PropertyTest.Input
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq {
        case Confirm, Prev, Next, Menu
    }

    /// 役 → いまの割り当ての先頭のキー（KeysDoc から引く）。
    def keyOf(role: Role, w: World.World): Key =
        let keys = KeysDoc.rec(w#keys);
        let list = match role {
            case Role.Confirm => keys#confirm
            case Role.Prev    => keys#prev
            case Role.Next    => keys#next
            case Role.Menu    => keys#menu
        };
        List.head(list) |> Option.getWithDefault(Key.F12)

    def setup(): PropertyTest.Setup[Role, World.World] =
        { keyOf = keyOf, viewport = { x = World.width(), y = World.height() }, dt = 1.0 / 60.0 }

    /// 種 20 個 × 300 入力。キー 4 つ・画面の 2 か所のクリック・文字送りを使い切る 0.5 秒の待ち。
    def cases(): PropertyTest.Cases[Role] =
        { seeds = 20, length = 300,
          spec = { taps = List#{Role.Confirm, Role.Prev, Role.Next, Role.Menu}, idle = 3, dts = List#{1.0 / 60.0, 0.5},
                   points = List#{{ x = 40.0, y = 40.0 }, { x = World.width() / 2.0, y = World.height() - 30.0 }}
                   | PropertyTest.emptySpec() } }

    /// 実機と同じ UI（会話窓と選択肢のチップ）を読んだ始まりの World。UI が空だと選択肢のカーソルが動かない。
    def start(): World.World \ Fs.FileRead =
        World.initial({ story = StoryDoc.defaults(), dialogue = TestKit.fixtureDialogue(), kind = KindDoc.defaults(), keys = KeysDoc.defaults(),
                        theme = ThemeDoc.defaults(), sprites = PxSpriteDoc.empty() },
                      NovelKit.spawnAssets())

    def app(w0: World.World): App.App[World.World, {}] = TestKit.app(w0)

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
            let wanted = if (opened(step)) StoryDoc.rec(StoryDoc.defaults())#lamps
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

    /// 表紙から最初の分岐（選択肢待ち）まで: 決定 → 読み切る待ち を 3 回。
    def toAsk(): List[Input[Role]] =
        let settle = Input.Idle(1000.0);
        List#{Input.Tap(Role.Confirm), settle, Input.Tap(Role.Confirm), settle, Input.Tap(Role.Confirm), settle}

    /// 何も触らない n フレーム（1/60 秒ずつ）。
    def frames(n: Int32): List[Input[Role]] = List.repeat(n, Input.Idle(1.0 / 60.0))

    /// 選択肢待ちで決定（カーソルは先頭 = fixture の疑う選択）し、n フレーム待ってメニューを開く。
    def doubtThenMenu(n: Int32): List[Input[Role]] =
        toAsk() ::: Input.Tap(Role.Confirm) :: frames(n) ::: Input.Tap(Role.Menu) :: Nil

    def lastOf(steps: List[App.TraceStep[World.World]]): Option[App.TraceStep[World.World]] = List.last(steps)

    /// 灯りの演出の途中（揺らぐ音の後・消える音の前 = Flicker の 0.5 秒の内の 0.25 秒）でメニューを開き、
    /// 2 秒置いて閉じ、1 秒待つ: 演出の 2 つの音はちょうど 1 回ずつで、メニューの間は 1 つも鳴らない。
    @Test
    def testMenuDuringLampFxRingsEachOnce(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let inputs = doubtThenMenu(15) ::: frames(120) ::: Input.Tap(Role.Menu) :: frames(60);
        let steps = PropertyTest.traceOf(app(w0), setup(), inputs, w0);
        let inMenu = steps |> List.filter(step -> step#before#menu == World.Menu.Open and step#after#menu == World.Menu.Open);
        Assert.assertEq(expected = (1, 1, 0, 0),
            (count("lamp_flicker", steps), count("lamp_out", steps),
             count("lamp_flicker", inMenu), count("lamp_out", inMenu)))

    /// メニューを開いた次のフレームから 1 秒置いても、炎の細り具合は変わらない（物語の時計が止まる）。
    @Test
    def testMenuHoldsLampFlicker(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let held = PropertyTest.traceOf(app(w0), setup(), doubtThenMenu(6) ::: frames(1), w0) |> lastOf;
        let later = PropertyTest.traceOf(app(w0), setup(), doubtThenMenu(6) ::: frames(61), w0) |> lastOf;
        Assert.assertEq(expected = held |> Option.map(step -> LampFx.flickerOf(step#after)),
                        later |> Option.map(step -> LampFx.flickerOf(step#after)))

    /// メニューの間も実時間は進む（雨は降り続ける）: 開いた次のフレームから 60 フレームで 1 秒。
    @Test
    def testMenuKeepsRealTime(): Unit \ {Assert, Fs.FileRead} =
        let w0 = start();
        let held = PropertyTest.traceOf(app(w0), setup(), doubtThenMenu(6) ::: frames(1), w0) |> lastOf;
        let later = PropertyTest.traceOf(app(w0), setup(), doubtThenMenu(6) ::: frames(61), w0) |> lastOf;
        let elapsed = match (held, later) {
            case (Some(a), Some(b)) => Clock.since(a#after#realNow, b#after#realNow)
            case _                  => bug!("trace が空")
        };
        Assert.assertTrue(Float64.abs(elapsed - 1.0) < 0.000001)

    /// 炎の細り具合は、消えた時刻から物語の時計で測った Flicker の進み。細りながら残るのは Flicker の間だけで、
    /// 消えた時刻より前（描き出しが時計を置き直した）は残らない（長さは時刻表から導く）。
    @Test
    def testFlickerFollowsTimeline(): Unit \ {Assert, Fs.FileRead} =
        let tl = LampFx.timeline();
        let half = Timeline.clipOf(LampFx.Beat.Flicker, tl) |> Option.map(c -> c#dur / 2.0) |> Option.getWithDefault(0.0);
        let at = seconds -> { lampOutAt = Some(Clock.after(10.0, Clock.zero())), storyClock = Clock.startAt(seconds) | start() };
        Assert.assertEq(expected = (0.5, true, false, false),
            (LampFx.flickerOf(at(10.0 + half)), LampFx.isFlickering(at(10.0 + half)),
             LampFx.isFlickering(at(10.0 + half * 2.0)), LampFx.isFlickering(at(8.4))))
}
