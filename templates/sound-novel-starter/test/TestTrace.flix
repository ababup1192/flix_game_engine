// 性質テスト: 種で決まるでたらめなキーとクリックを App.trace の道（PropertyTest・画面なし）に流し、
// どう読み進めても崩れない決まりを見る。App は実機と同じ繋ぎ（Game.app。セーブのファイルは書かない）。
mod TestTrace {

    use fge::{App, Clock, PropertyTest, Resources}
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq {
        case Confirm, Back, Prev, Next, Left, Right, Log, Auto, Skip, Hide, Rollback, QuickSave, QuickLoad, TabNext, Remove
    }

    /// App の w（描く元と World の組）。
    type alias Run = Resources.With[Res.Res, World.World]

    /// 役 → いまの割り当ての先頭のキー（KeysDoc から引く）。
    def keyOf(role: Role, res: Res.Res): Key =
        let k = KeysDoc.rec(res#keys);
        let keys = match role {
            case Role.Confirm => k#confirm
            case Role.Back    => k#back
            case Role.Prev    => k#prev
            case Role.Next    => k#next
            case Role.Left    => k#left
            case Role.Right   => k#right
            case Role.Log     => k#log
            case Role.Auto    => k#auto
            case Role.Skip    => k#skip
            case Role.Hide    => k#hide
            case Role.Rollback  => k#rollback
            case Role.QuickSave => k#quickSave
            case Role.QuickLoad => k#quickLoad
            case Role.TabNext   => k#tabNext
            case Role.Remove    => k#remove
        };
        List.head(keys) |> Option.getWithDefault(Key.F12)

    def setup(): PropertyTest.Setup[Role, Run] =
        { keyOf = (role, h) -> keyOf(role, h#resources), viewport = { x = Layout.width(), y = Layout.height() }, dt = 1.0 / 60.0 }

    /// 種 16 個 × 400 入力。キー 15 個・画面のあちこちのクリック（本文・選択肢・クイックメニュー・確認のウィンドウのはい / いいえ・
    /// セーブの枠とタブと削除・設定の行・バックログの行・戻る）・待ちを明かす長めの間。
    def cases(): PropertyTest.Cases[Role] =
        let button = i -> { x = Layout.button(i, List.length(WorldMenu.buttons()))#position#x + 30.0, y = 524.0 };
        let center = r -> { x = r#position#x + r#size#x / 2.0, y = r#position#y + r#size#y / 2.0 };
        { seeds = 16, length = 400,
          spec = { taps = List#{Role.Confirm, Role.Confirm, Role.Confirm, Role.Back, Role.Prev, Role.Next, Role.Left, Role.Right,
                                Role.Log, Role.Auto, Role.Skip, Role.Hide, Role.Rollback, Role.QuickSave, Role.QuickLoad, Role.TabNext, Role.Remove},
                   idle = 3, dts = List#{1.0 / 60.0, 0.5, 2.0},
                   points = List#{{ x = Layout.width() / 2.0, y = 200.0 }, { x = Layout.width() / 2.0, y = 150.0 },
                                  { x = 470.0, y = 330.0 }, { x = 480.0, y = 488.0 },
                                  button(0), button(4), button(5), button(6), button(7), button(10),
                                  center(Layout.askButton(Layout.Side.Left)), center(Layout.askButton(Layout.Side.Right)),
                                  center(Layout.slot(0)), center(Layout.slot(3)), center(Layout.remove(0)), center(Layout.tab(1)),
                                  center(Layout.settingSide(2, Layout.Side.Right)), center(Layout.settingBar(5)), center(Layout.back()), { x = 500.0, y = 300.0 }}
                   | PropertyTest.emptySpec() } }

    /// rule は World の前後で決まりを見る（描く元は遊んでいる間は替わらない）。
    def check(rule: App.TraceStep[World.World] -> Option[String]): Option[String] \ Fs.FileRead =
        let res = TestKit.res();
        let w0 = TestKit.w0(res);
        let onWorld = (step: App.TraceStep[Run]) ->
            rule({ frame = step#frame, before = step#before#world, after = step#after#world, sounds = step#sounds, sustained = step#sustained });
        PropertyTest.forAll(TestKit.app(res, w0), setup(), cases(), Resources.of(res, w0), onWorld)

    def storyNow(w: World.World): Float64 = Clock.secondsOf(Clock.nowOf(w#storyClock))

    @Test
    def testStoryClockStandsStillWhilePanelIsOpen(): Unit \ {Assert, Fs.FileRead} =
        // 画面（バックログ・セーブ・設定・隠す）や確認のウィンドウを開いている間は物語の時計が進まない（待ち・文字送り・オートも止まる）。
        let rule = (step: App.TraceStep[World.World]) ->
            if ((step#before#panel != World.Panel.Closed or Option.nonEmpty(step#before#ask)) and storyNow(step#after) != storyNow(step#before))
                Some("画面か確認のウィンドウを開いているのに物語の時計が進んだ")
            else None;
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testChoiceCursorRestsOnAnOpenChoice(): Unit \ {Assert, Fs.FileRead} =
        // 選択肢を出している間、カーソルは選べる選択肢の上にある。
        let rule = (step: App.TraceStep[World.World]) -> {
            let w = step#after;
            let onOpen = World.readOf(w) |> Option.flatMap(r -> List.nth(r#choiceCursor, r#choices))
                |> Option.map(option -> option#available) |> Option.getWithDefault(false);
            if (World.isChoosing(w) and w#panel == World.Panel.Closed and not onOpen) Some("カーソルが選べない選択肢の上にある")
            else None
        };
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testLogNeverOutgrowsLogMax(): Unit \ {Assert, Fs.FileRead} =
        // ログは logMax を超えない。
        let logMax = KindDoc.rec(TestKit.res()#kind)#logMax;
        let rule = (step: App.TraceStep[World.World]) ->
            if (List.length(World.logOf(step#after)) > logMax) Some("ログが logMax を超えた") else None;
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testRepliesFollowPresses(): Unit \ {Assert, Fs.FileRead} =
        // 返事の音（ui_）は 1 フレームに 1 つまで。押していない・マウスも動かしていない・オートもスキップも点いていないフレームでは鳴らない
        // （マウスが新しい項目に乗った時のカーソルの音は、動かしたことへの返事）。
        let rule = (step: App.TraceStep[World.World]) -> {
            let replies = List.count(name -> String.startsWith(prefix = "ui_", name), step#sounds);
            let untouched = Set.isEmpty(step#frame#justPressed) and not step#frame#mouseClicked and not step#frame#mouseMoved;
            let hands = World.playbackOf(step#before) != World.Playback.Manual;
            if (replies > 1) Some("1 フレームに返事が ${replies} 回")
            else if (untouched and not hands and replies > 0) Some("押していないのに返事が鳴った")
            else None
        };
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testAskingHoldsTheStory(): Unit \ {Assert, Fs.FileRead} =
        // 確認のウィンドウを開いたまま（答えていない）フレームでは、読んでいる行もノードも動かない。
        let rule = (step: App.TraceStep[World.World]) -> {
            let placeOf = (w: World.World) -> (World.talkNodeOf(w), World.talkLineOf(w));
            if (Option.nonEmpty(step#before#ask) and Option.nonEmpty(step#after#ask) and placeOf(step#before) != placeOf(step#after))
                Some("確認のウィンドウを開いているのに読む所が動いた")
            else None
        };
        Assert.assertEq(expected = None, check(rule))

    @Test
    def testSavesStayOnTheirPages(): Unit \ {Assert, Fs.FileRead} =
        // セーブデータはどれも 5 ページ × 6 枠のどこかにあり、通し番号は最後に振った番号を超えない。
        let rule = (step: App.TraceStep[World.World]) -> {
            let saves = Saves.rec(step#after#saves);
            let limit = List.length(Saves.tabs()) * Saves.perPage();
            if (Map.keysOf(saves#slots) |> Set.exists(k -> k < 0 or k >= limit)) Some("ページの外の枠にデータがある")
            else if (Map.valuesOf(saves#slots) |> List.exists(slot -> slot#serial > saves#serial)) Some("通し番号が最後の番号を超えた")
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
