// 音: 出来事 → 音の名前の表・project.json の sounds に全部ある・曲の宣言（マップの bgm・戦い・ボス戦・勝ち）。
mod TestSounds {

    // ══════════════════════════════════════════════════════
    // 出来事 → 音の名前
    // ══════════════════════════════════════════════════════

    /// どの出来事の音も project.json の sounds に載っている。
    @Test
    def testEveryEventSoundIsInTheProject(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some(Nil), Fixtures.notInProject(Controls.soundOf, Fixtures.allEvents()))

    /// rpg.spells.json のどの呪文の演出（fx）にも、載っている音がある。
    @Test
    def testEverySpellSoundIsInTheProject(): Unit \ Assert + Fs.FileRead =
        let spells = SpellsDoc.rec(Res.load()#spells)#spells |> Map.valuesOf;
        Assert.assertEq(expected = Some(Nil), Fixtures.notInProject(s -> Controls.soundOf(World.Event.Spell(s#fx)), spells))

    /// 炎・氷・回復の呪文は、それぞれ別の音。
    @Test
    def testSpellsHaveTheirOwnSounds(): Unit \ Assert =
        Assert.assertEq(expected = ("spell_fire", "spell_ice", "heal"),
            (Controls.soundOf(World.Event.Spell("fire")), Controls.soundOf(World.Event.Spell("ice")), Controls.soundOf(World.Event.Spell("heal"))))

    /// 床のスイッチはレバーと別の音。
    @Test
    def testPlateIsNotTheLeverSound(): Unit \ Assert =
        Assert.assertEq(expected = ("lever", "plate"), (Controls.soundOf(World.Event.Lever), Controls.soundOf(World.Event.Switch)))

    /// 坑道 B1 の下り階段を通ると階段の音（扉の音ではない）。
    @Test
    def testStairsSoundOnTheMineStairs(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("field", Map#{"map" => "mine_b1", "x" => "26", "y" => "9", "facing" => "up", "steps" => "999"});
        let sounds = Fixtures.playCollecting(Fixtures.tap(Fixtures.up()) ::: Fixtures.idle(30), h)#sounds;
        Assert.assertEq(expected = (true, false),
            (List.memberOf(Controls.soundOf(World.Event.Stairs), sounds), List.memberOf(Controls.soundOf(World.Event.Door), sounds)))

    /// 戦いの 1 手の出来事: 勝ちの伝言の Beat は勝った（ファンファーレ）。
    @Test
    def testVictoryBeatIsTheVictoryEvent(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        let b = Battle.start(res, Fixtures.foeId(res, "kusausa") :: Nil, Party.starting(res#party, res#items), Bag.withGold(0));
        let (_, beats) = Battle.resolveVictory(res, b);
        Assert.assertEq(expected = Some(World.Event.Victory :: Nil), List.head(beats) |> Option.map(WorldBattle.beatEventsOf))

    /// 勝つまで戦うと、攻撃の音と勝ちのファンファーレが鳴る。
    @Test
    def testWinningPlaysAttackAndFanfare(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "kusausa", "party" => "luka", "lv" => "5"});
        let sounds = Fixtures.playCollecting(Fixtures.confirmEach(8), h)#sounds;
        Assert.assertEq(expected = (true, true),
            (List.memberOf(Controls.soundOf(World.Event.Attack), sounds), List.memberOf(Controls.soundOf(World.Event.Victory), sounds)))

    // ══════════════════════════════════════════════════════
    // 曲
    // ══════════════════════════════════════════════════════

    /// どの曲も project.json の sounds に載っている。
    @Test
    def testEveryTrackIsInTheProject(): Unit \ Assert + Fs.FileRead =
        Assert.assertEq(expected = Some(Nil), Fixtures.notInProject(Bgm.soundOf, Bgm.all()))

    /// フィールドでは、どのマップでもそのマップの Doc の bgm を宣言する。
    @Test
    def testFieldPlaysTheMapBgm(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        Assert.assertEq(expected = Fixtures.mapBgmsOf(res), Fixtures.fieldTracksOf(res))

    /// どのマップにも曲がある（Doc に bgm が書いてあり、立つと鳴る。無音の画面を出荷しない）。
    @Test
    def testNoMapIsSilent(): Unit \ Assert + Fs.FileRead =
        let res = Res.load();
        Assert.assertEq(expected = (false, false), (List.memberOf(None, Fixtures.mapBgmsOf(res)), List.memberOf(None, Fixtures.fieldTracksOf(res))))

    /// タイトルではタイトルの曲 1 本を、元の音量と高さで宣言する。
    @Test
    def testTitleDeclaresTheTitleTrack(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("title", Map.empty());
        let music = Controls.musicOf(h#resources, h#world);
        Assert.assertEq(expected = (1, Some((Bgm.soundOf(Bgm.Track.Title), 1.0, 1.0))),
            (List.length(music), List.head(music) |> Option.map(s -> (s#name, s#volume, s#pitch))))

    /// 戦いの間は戦いの曲。
    @Test
    def testBattlePlaysTheBattleTrack(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "koke"});
        Assert.assertEq(expected = Some(Bgm.Track.Battle), Controls.trackOf(h#resources, h#world))

    /// 逃げられない敵（rpg.foes.json の noFlee。ジェムイーター）との戦いはボス戦の曲。
    @Test
    def testNoFleeFoePlaysTheBossTrack(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "gemeater", "party" => "luka,mina,toto", "lv" => "10"});
        Assert.assertEq(expected = (true, Some(Bgm.Track.Boss)),
            (FoesDoc.foeOrBlank(h#resources#foes, Fixtures.foeId(h#resources, "gemeater"))#noFlee, Controls.trackOf(h#resources, h#world)))

    /// 勝つまで: 戦いの曲 → 勝ちの伝言の間は止める（ファンファーレ）→ 戦ったマップの bgm。
    @Test
    def testVictoryStopsTheBattleTrackThenBackToTheMap(): Unit \ Assert + Fs.FileRead =
        let h = Fixtures.started("battle", Map#{"foes" => "kusausa", "party" => "luka", "lv" => "5", "map" => "world"});
        let tracks = Fixtures.playCollecting(Fixtures.confirmEach(8), h)#tracks;
        Assert.assertEq(expected = Some(Bgm.Track.Battle) :: None :: Fixtures.mapBgmOf("world", h) :: Nil, List.distinct(tracks))
}
