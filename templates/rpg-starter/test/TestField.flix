// マップを歩く決まり（壁・押したままの歩きの時刻・出入口と暗転・話しかける・読み直しで収める）。
// 場面は Starts から組み、キーは実機と同じ道（App.trace）で 1/60 秒ずつ流す。
mod TestField {
    use fge::{Clock, Dir4, Resources}

    // ══════════════════════════════════════════════════════
    // 当たり
    // ══════════════════════════════════════════════════════

    /// 鍛冶屋の前の右の家の扉（11, 4）には出入口が無いので入れず、上を向くだけ。
    @Test
    def testDoorWithoutExitOnlyTurns(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "smithy", "x" => "11", "y" => "5", "facing" => "down"});
        Assert.assertEq(expected = Some(((11, 5), Dir4.Dir4.Up)),
            Fixtures.heroOf(Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(20), h)))

    // ══════════════════════════════════════════════════════
    // 押したままの歩き
    // ══════════════════════════════════════════════════════

    /// 村の大通り（行 9）を右へ押したまま 140 フレーム: 11 マス目の歩き始めは 1 歩目の歩き始めから
    /// ちょうど secondsPerTile × 10 秒後（着いたフレームの今を使うと、はみ出しが 1 マスごとに積もってずれる）。
    @Test
    def testHeldWalkDoesNotDrift(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "0", "y" => "9", "facing" => "right"});
        let first = Fixtures.play(Fixtures.hold(Fixtures.right(), 1), h);
        let later = Fixtures.play(Fixtures.hold(Fixtures.right(), 139), first);
        let tenTiles = RulesDoc.rec(h#resources#rules)#secondsPerTile * 10.0;
        let drift = forM (a <- Fixtures.strideStartOf(first); b <- Fixtures.strideStartOf(later))
                    yield Float64.abs(Clock.since(a, b) - tenTiles);
        Assert.assertEq(expected = (Some((11, 9)), Some(true)),
            (Fixtures.heroOf(later) |> Option.map(fst), drift |> Option.map(d -> d < 0.000001)))

    // ══════════════════════════════════════════════════════
    // 出入口と暗転
    // ══════════════════════════════════════════════════════

    /// 村長の家の扉（20, 3）へ上がると、暗転が晴れた後には出入口の行き先のマスにいて、入力を受ける。
    @Test
    def testDoorWarpsToTheExitSpawn(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "4", "facing" => "up"});
        let exit = Map.get("village", h#resources#maps) |> Option.flatMap(map -> Map.get((20, 3), MapDoc.rec(map)#exitAt));
        let after = Fixtures.play(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(90), h);
        Assert.assertEq(expected = (exit |> Option.map(e -> (Some(e#to), Some(((e#spawnX, e#spawnY), e#facing)))), "Walking"),
            (Some((Fixtures.mapOf(after), Fixtures.heroOf(after))), Fixtures.layerOf(after)))

    /// 「はじめから」の暗転が晴れるまでは、方向キーを押したままでも動かない。
    @Test
    def testDirectionIsIgnoredDuringTheFade(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("title", Map.empty());
        let rules = RulesDoc.rec(h#resources#rules);
        let fading = Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.hold(Fixtures.left(), 10), h);
        Assert.assertEq(expected = ("Busy", Some(((rules#startX, rules#startY), rules#startFacing))), (Fixtures.layerOf(fading), Fixtures.heroOf(fading)))

    // ══════════════════════════════════════════════════════
    // 話しかける
    // ══════════════════════════════════════════════════════

    /// 前の人に決定で話しかけると、その人の Doc の node の会話が開く。
    @Test
    def testTalkOpensTheNodeOfThePersonInFront(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "5", "y" => "8", "facing" => "up"});
        let node = Fixtures.npcAt("village", 5, 7, h) |> Option.map(npc -> npc#node);
        Assert.assertEq(expected = node, Fixtures.talkNodeOf(Fixtures.play(Fixtures.tap(Fixtures.confirm()), h)))

    /// 会話を送り切って閉じると、また歩ける（右へ 1 マス）。
    @Test
    def testTalkClosesThenWalks(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "5", "y" => "8", "facing" => "up"});
        let closed = Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()) ::: Fixtures.tap(Fixtures.confirm()), h);
        let walked = Fixtures.play(Fixtures.hold(Fixtures.right(), 1) ::: Fixtures.idle(20), closed);
        Assert.assertEq(expected = Some((6, 8)), Fixtures.heroOf(walked) |> Option.map(fst))

    /// 方向キーを押したまま会話を閉じても、押したままの間はその向きへ歩かず、会話もまた開かない
    /// （村の南の端（20, 14）で外へ向かって下を押し、端の出口の gate の会話を開いて、押したまま閉じ、そのまま 30 フレーム）。
    @Test
    def testHeldDirectionAfterClosingDoesNotReopen(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "14", "facing" => "up", "quest" => "accepted"});
        let opened = Fixtures.play(Fixtures.hold(Fixtures.down(), 2), h);
        let closed = Fixtures.play(Fixtures.tapWhileHolding(Fixtures.down(), Fixtures.confirm())
                                   ::: Fixtures.tapWhileHolding(Fixtures.down(), Fixtures.confirm()), opened);
        let held = Fixtures.play(Fixtures.hold(Fixtures.down(), 30), closed);
        Assert.assertEq(expected = (None, Some(((20, 14), Dir4.Dir4.Down))), (Fixtures.talkNodeOf(held), Fixtures.heroOf(held)))

    /// 遠くから下を押したまま歩いて村の南の端（20, 14）で止まると、押したままでも端の出口の gate の会話が開く
    /// （閉じた向きの待ちは、着いた直後の歩きを止めない）。(20, 9) から 5 マス = 約 66 フレーム。
    @Test
    def testHeldWalkIntoTheGateOpensItsTalk(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "9", "facing" => "down", "quest" => "accepted"});
        let gateNode = Fixtures.exitOf("village", "to_world", h) |> Option.flatMap(exit -> exit#gate) |> Option.map(gate -> gate#node);
        Assert.assertEq(expected = gateNode, Fixtures.talkNodeOf(Fixtures.play(Fixtures.hold(Fixtures.down(), 90), h)))

    /// 閉じた後に方向キーを 1 度離して押し直すと、また入力を受ける（閉じた端の出口なので、同じ会話がもう 1 度開く）。
    @Test
    def testPressingAgainAfterReleaseIsAccepted(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "20", "y" => "14", "facing" => "up", "quest" => "accepted"});
        let opened = Fixtures.play(Fixtures.hold(Fixtures.down(), 2), h);
        let node = Fixtures.talkNodeOf(opened);
        let closed = Fixtures.play(Fixtures.tapWhileHolding(Fixtures.down(), Fixtures.confirm())
                                   ::: Fixtures.tapWhileHolding(Fixtures.down(), Fixtures.confirm()), opened);
        let again = Fixtures.play(Fixtures.idle(1) ::: Fixtures.hold(Fixtures.down(), 2), closed);
        Assert.assertEq(expected = node, Fixtures.talkNodeOf(again))

    // ══════════════════════════════════════════════════════
    // 会話の音
    // ══════════════════════════════════════════════════════

    /// 村長に話しかけて 0.5 秒待つと、ウィンドウの開く音と、村長の声（rpg.text.json の speakers の voice = low）の文字送りの音が鳴る。
    @Test
    def testTalkingPlaysOpenAndVoiceSounds(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "chief_house", "x" => "7", "y" => "5", "facing" => "up"});
        let after = Fixtures.play(Fixtures.tap(Fixtures.confirm()) ::: Fixtures.idle(30), h);
        let sounds = Controls.sounds({ before = h#world, after = after#world });
        Assert.assertEq(expected = (true, true, false), (List.memberOf("talk_open", sounds), List.memberOf("talk_low", sounds), List.memberOf("talk_high", sounds)))

    // ══════════════════════════════════════════════════════
    // 終了の確認
    // ══════════════════════════════════════════════════════

    /// フィールドで Esc を押すと終了の確認が開き、カーソルは「いいえ」にある。
    @Test
    def testEscapeAsksToQuitWithNo(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8"});
        Assert.assertEq(expected = Some(World.Ask.Quit(World.Answer.No)), Fixtures.askOf(Fixtures.play(Fixtures.tap(Fixtures.escape()), h)))

    /// 終了の確認で「いいえ」のまま決定すると、確認が閉じて歩ける。
    @Test
    def testConfirmOnNoClosesTheAsk(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "7", "y" => "8"});
        let after = Fixtures.play(Fixtures.tap(Fixtures.escape()) ::: Fixtures.tap(Fixtures.confirm()), h);
        Assert.assertEq(expected = "Walking", Fixtures.layerOf(after))

    /// 机（Counter）の向こうの村長にも話しかけられる。
    @Test
    def testTalkAcrossTheCounter(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "chief_house", "x" => "7", "y" => "5", "facing" => "up"});
        Assert.assertEq(expected = Some("ChiefQuest"), Fixtures.talkNodeOf(Fixtures.play(Fixtures.tap(Fixtures.confirm()), h)))

    // ══════════════════════════════════════════════════════
    // 読み直し
    // ══════════════════════════════════════════════════════

    /// 読み直しで立っているマスが木（T）になったら、一番近い立てるマス（同じ近さなら上の行・左の列）へ移る。
    @Test
    def testSettleMovesOffANewWall(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "village", "x" => "1", "y" => "4", "facing" => "down"});
        let walled = MapDoc.fromJson(ItemsDoc.defaults(), "village", "{\"version\":1, \"tileset\":\"village\", \"rows\":[\"...\", \"...\", \"...\", \"...\", \".T.\"]}");
        let res = walled |> Option.map(doc -> Res.withMaps(Map#{"village" => doc}, h#resources));
        Assert.assertEq(expected = Some(Some(((0, 3), Dir4.Dir4.Down))),
            res |> Option.map(r -> Fixtures.heroOf(Resources.of(r, WorldField.settle(r, h#world)))))
}
