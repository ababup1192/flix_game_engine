// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
// ThemeDoc のふつうのフィールドは KindDoc と同型（フィールドの Or 読み）なので橋渡しは書かない。
// accentLight だけは palette.json の宣言が導出に勝つ固有の規則なので、下で 2 本だけ確かめる。
mod TestDocs {

    // ══════════════════════════════════════════════════════
    // StoryDoc（台本: rows）
    // ══════════════════════════════════════════════════════

    @Test
    def testStoryBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定の台本へ落ちる（ゲームは必ず起動する）。
        let doc = StoryDoc.fromJson("{ broken") |> Option.getWithDefault(StoryDoc.defaults());
        Assert.assertEq(expected = StoryDoc.rec(StoryDoc.defaults())#start, StoryDoc.rec(doc)#start)

    @Test
    def testStoryOverridesOneField(): Unit \ Assert =
        // 1 フィールドだけ書いた JSON はそこだけ効き、残りは既定のまま。
        let doc = StoryDoc.fromJson("{\"version\":1, \"hint\": \"Zではじめる\"}")
            |> Option.getWithDefault(StoryDoc.defaults());
        Assert.assertEq(expected = ("Zではじめる", StoryDoc.rec(StoryDoc.defaults())#start),
            (StoryDoc.rec(doc)#hint, StoryDoc.rec(doc)#start))

    @Test
    def testStoryRowsLengthFollowsJson(): Unit \ Assert =
        // sections の rows を増やせば節が増える（節の中の beats / options の rows も追随する）。
        let text = "{\"version\":1, \"start\":\"a\", \"sections\":["
            + "{\"id\":\"a\", \"beats\":[{\"text\":\"x\"},{\"text\":\"y\"}],"
            + " \"ask\":{\"text\":\"?\", \"options\":[{\"label\":\"l\",\"goto\":\"b\"}]}},"
            + "{\"id\":\"b\", \"beats\":[]}]}";
        let doc = StoryDoc.fromJson(text) |> Option.getWithDefault(StoryDoc.defaults());
        let beatsInA = StoryDoc.sectionOf("a", doc)
            |> Option.map(section -> List.length(section#beats))
            |> Option.getWithDefault(-1);
        let optionsInA = StoryDoc.sectionOf("a", doc)
            |> Option.flatMap(section -> section#ask)
            |> Option.map(ask -> List.length(ask#options))
            |> Option.getWithDefault(-1);
        Assert.assertEq(expected = (2, 2, 1),
            (List.length(StoryDoc.rec(doc)#sections), beatsInA, optionsInA))

    // ══════════════════════════════════════════════════════
    // KindDoc（手触りの数値）
    // ══════════════════════════════════════════════════════

    @Test
    def testKindBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        let doc = KindDoc.fromJson("{ broken") |> Option.getWithDefault(KindDoc.defaults());
        Assert.assertEq(expected = KindDoc.rec(KindDoc.defaults())#cps, KindDoc.rec(doc)#cps)

    @Test
    def testKindOverridesOneField(): Unit \ Assert =
        let doc = KindDoc.fromJson("{\"version\":1, \"cps\": 99.0}")
            |> Option.getWithDefault(KindDoc.defaults());
        Assert.assertEq(expected = (99.0, KindDoc.rec(KindDoc.defaults())#dim),
            (KindDoc.rec(doc)#cps, KindDoc.rec(doc)#dim))

    // ══════════════════════════════════════════════════════
    // ThemeDoc（accentLight だけ橋渡しを書く: palette.json の宣言が導出に勝つ規則。
    // 他のフィールドは KindDoc と同型の Or 読みなので書かない）
    // ══════════════════════════════════════════════════════

    @Test
    def testThemeAccentLightPaletteWins(): Unit \ Assert =
        // palette.json に accentLight が宣言されていればそれが勝つ。
        let doc = ThemeDoc.overlayAccentLight(
            "{\"accentLight\": {\"rgb\": [0.0, 0.5, 1.0]}}", ThemeDoc.defaults());
        Assert.assertEq(expected = (0.0, 0.5, 1.0),
            (ThemeDoc.rec(doc)#accentLight#r, ThemeDoc.rec(doc)#accentLight#g, ThemeDoc.rec(doc)#accentLight#b))

    @Test
    def testThemeAccentLightFallsBackToDerived(): Unit \ Assert =
        // palette が壊れている・宣言が無いときは従来どおり accent からの導出のまま。
        let d = ThemeDoc.defaults();
        let derived = ThemeDoc.lighten(ThemeDoc.rec(d)#accent, 0.5);
        let doc = ThemeDoc.overlayAccentLight("{ broken", d);
        Assert.assertEq(expected = (derived#r, derived#g, derived#b),
            (ThemeDoc.rec(doc)#accentLight#r, ThemeDoc.rec(doc)#accentLight#g, ThemeDoc.rec(doc)#accentLight#b))
}
