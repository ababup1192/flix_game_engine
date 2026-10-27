// 性質テスト: 種で決まるでたらめなキーとクリックを App.trace の道（PropertyTest・画面なし）に流し、
// どう読み進めても崩れない決まりを見る。App は実機と同じ繋ぎ（Game.app。栞のファイルは書かない）。
mod TestTrace {

    use fge::{App, Clock, PropertyTest}
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq {
        case Confirm, Back, Prev, Next, Log, Auto, Skip, Hide
    }

    /// 役 → いまの割り当ての先頭のキー（KeysDoc から引く）。
    def keyOf(role: Role, w: World.World): Key =
        let k = KeysDoc.rec(w#keys);
        let keys = match role {
            case Role.Confirm => k#confirm
            case Role.Back    => k#back
            case Role.Prev    => k#prev
            case Role.Next    => k#next
            case Role.Log     => k#log
            case Role.Auto    => k#auto
            case Role.Skip    => k#skip
            case Role.Hide    => k#hide
        };
        List.head(keys) |> Option.getWithDefault(Key.F12)

    def setup(): PropertyTest.Setup[Role, World.World] =
        { keyOf = keyOf, viewport = { x = World.width(), y = World.height() }, dt = 1.0 / 60.0 }

    /// 種 16 個 × 400 入力。キー 8 つ・画面のあちこちのクリック（本文・選択肢・ボタンの帯・戻る）・待ちを明かす長めの間。
    def cases(): PropertyTest.Cases[Role] =
        { seeds = 16, length = 400,
          spec = { taps = List#{Role.Confirm, Role.Confirm, Role.Confirm, Role.Back, Role.Prev, Role.Next, Role.Log, Role.Auto, Role.Skip, Role.Hide},
                   idle = 3, dts = List#{1.0 / 60.0, 0.5, 2.0},
                   points = List#{{ x = World.width() / 2.0, y = 200.0 }, { x = World.width() / 2.0, y = 150.0 },
                                  { x = 700.0, y = World.height() - 14.0 }, { x = 470.0, y = 330.0 }, { x = 480.0, y = 488.0 }}
                   | PropertyTest.emptySpec() } }

    def check(rule: App.TraceStep[World.World] -> Option[String]): Option[String] \ Fs.FileRead =
        let w0 = TestKit.w0();
        PropertyTest.forAll(TestKit.app(w0), setup(), cases(), w0, rule)

    def storyNow(w: World.World): Float64 = Clock.secondsOf(Clock.nowOf(w#storyClock))

    @Test
    def testStoryClockStandsStillWhilePanelIsOpen(): Unit \ {Assert, Fs.FileRead} =
        // 窓（ログ・栞・設定・隠す）を開いている間は物語の時計が進まない（待ち・文字送り・オートも止まる）。
        let rule = (step: App.TraceStep[World.World]) ->
            if (step#before#panel != World.Panel.Closed and storyNow(step#after) != storyNow(step#before))
                Some("窓を開いているのに物語の時計が進んだ")
            else None;
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testChoiceCursorRestsOnAnOpenChoice(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出している間、カーソルは選べる選択肢の上にある。
        let rule = (step: App.TraceStep[World.World]) -> {
            let w = step#after;
            let onOpen = List.nth(w#cursor, w#choices) |> Option.map(option -> option#available) |> Option.getWithDefault(false);
            if (World.isAsking(w) and w#panel == World.Panel.Closed and not onOpen) Some("カーソルが選べない選択肢の上にある")
            else None
        };
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testLogNeverOutgrowsLogMax(): Unit \ {Assert, Fs.FileRead} =
        // ログは logMax を超えない。
        let rule = (step: App.TraceStep[World.World]) ->
            if (List.length(step#after#log) > KindDoc.rec(step#after#kind)#logMax) Some("ログが logMax を超えた") else None;
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testRepliesFollowPresses(): Unit \ {Assert, Fs.FileRead} =
        // 返事の音（ui_）は 1 フレームに 1 つまで。押していない・オートもスキップも点いていないフレームでは鳴らない。
        let rule = (step: App.TraceStep[World.World]) -> {
            let replies = List.count(name -> String.startsWith(prefix = "ui_", name), step#sounds);
            let untouched = Set.isEmpty(step#frame#justPressed) and not step#frame#mouseClicked;
            let hands = step#before#playback != World.Playback.Manual;
            if (replies > 1) Some("1 フレームに返事が ${replies} 回")
            else if (untouched and not hands and replies > 0) Some("押していないのに返事が鳴った")
            else None
        };
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testAmbienceIsAlwaysARegisteredLoop(): Unit \ {Assert, Fs.FileRead} =
        // 鳴り続ける環境音は、どのフレームでも 1 本まで。
        let rule = (step: App.TraceStep[World.World]) ->
            if (List.length(step#sustained) > 1) Some("環境音が ${List.length(step#sustained)} 本重なった") else None;
        Assert.assertEq(expected = None, check(rule))
}
