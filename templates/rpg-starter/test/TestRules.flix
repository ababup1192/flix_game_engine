// タイトル・乱数・始まりの登録簿の決まり。
mod TestRules {
    use fge::{App, Dir4, Emit, Vec2}

    // ══════════════════════════════════════════════════════
    // タイトル
    // ══════════════════════════════════════════════════════

    /// セーブがまだ無いので「つづきから」へはカーソルが動かない（はじめからのまま・音も出ない）。
    @Test
    def testTitleCursorSkipsContinue(): Unit \ Assert =
        let (w, events) = Emit.collect(() -> WorldTitle.move(1, World.initial(None)));
        Assert.assertEq(expected = (Some(World.TitleItem.NewGame), (Nil: List[World.Event])), (World.titleCursorOf(w), events))

    /// 「はじめから」は rules の始まりのマスと向きで、暗転を晴らしながら入る。
    @Test
    def testNewGameEntersTheStartCell(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let rules = RulesDoc.rec(res#rules);
        let (w, _) = Emit.collect(() -> WorldTitle.confirm(res, World.TitleItem.NewGame, World.initial(None)));
        Assert.assertEq(expected = Some((rules#startMap, (rules#startX, rules#startY), rules#startFacing, "Busy")),
            World.fieldRecOf(w) |> Option.map(r -> (MapDoc.nameOf(r#map), (r#hero#x, r#hero#y), r#facing, InputLayer.nameOf(InputLayer.layerOf(w)))))

    // ══════════════════════════════════════════════════════
    // 旗
    // ══════════════════════════════════════════════════════

    /// 名前付きの旗は立てた後に下ろすと、立っていない。
    @Test
    def testNamedFlagCanBeLoweredAgain(): Unit \ Assert =
        let lever = Fixtures.flagId("lever");
        let raised = Progress.withFlag(lever, true, Progress.initial());
        Assert.assertEq(expected = (true, false), (Progress.isFlagSet(lever, raised), Progress.isFlagSet(lever, Progress.withFlag(lever, false, raised))))

    // ══════════════════════════════════════════════════════
    // 乱数
    // ══════════════════════════════════════════════════════

    /// 同じ回数・同じ用途なら同じ値で、引くたびに回数が 1 進む。
    @Test
    def testDiceIsDeterministic(): Unit \ Assert =
        let w = Dice.withSeed(10, World.initial(None));
        let (a, after) = Dice.roll(Dice.Channel.EncounterSteps, w);
        let (b, _) = Dice.roll(Dice.Channel.EncounterSteps, w);
        Assert.assertEq(expected = (true, 11), (a == b, after#dice))

    // ══════════════════════════════════════════════════════
    // 始まりの登録簿
    // ══════════════════════════════════════════════════════

    /// 立てないマス（村の家の壁）には field で立たず、理由を返す。
    @Test
    def testFieldRefusesAWall(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Err("始まり 'field': (1, 3) には立てない"),
            App.buildStart(Fixtures.app(), Vec2.zero(), "field", Map#{"map" => "village", "x" => "1", "y" => "3"}) |> Result.map(_ -> ()))

    /// talk は field の所に立ち、ノードの会話を開いた所。
    @Test
    def testTalkStartsWithTheNodeOpen(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("talk", Map#{"node" => "Child", "map" => "village", "x" => "3", "y" => "11", "facing" => "up"});
        Assert.assertEq(expected = (Some("Child"), Some(((3, 11), Dir4.Dir4.Up))), (Fixtures.talkNodeOf(h), Fixtures.heroOf(h)))
}
