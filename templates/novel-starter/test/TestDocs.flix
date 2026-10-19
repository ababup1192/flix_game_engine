// JSON 橋渡しのテスト（1 Doc につき最大 3 本まで。同型の重複は書かない）。
// ThemeDoc のふつうのフィールドは KindDoc と同型（フィールドの Or 読み）なので橋渡しは書かない。
// accentLight だけは palette.json の宣言が導出に勝つ固有の規則なので、下で 2 本だけ確かめる。
mod TestDocs {

    use fge::{GameEngine, Yarn}

    // ══════════════════════════════════════════════════════
    // StoryDoc（表紙の文言・灯りの数・話し手の呼び名）
    // ══════════════════════════════════════════════════════

    @Test
    def testStoryBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定へ落ちる（ゲームは必ず起動する）。
        let doc = StoryDoc.fromJson("{ broken") |> Option.getWithDefault(StoryDoc.defaults());
        Assert.assertEq(expected = StoryDoc.rec(StoryDoc.defaults())#lamps, StoryDoc.rec(doc)#lamps)

    @Test
    def testStoryOverridesOneField(): Unit \ Assert =
        // 1 フィールドだけ書いた JSON はそこだけ効き、残りは既定のまま。
        let doc = StoryDoc.fromJson("{\"version\":1, \"hint\": \"Zではじめる\"}")
            |> Option.getWithDefault(StoryDoc.defaults());
        Assert.assertEq(expected = ("Zではじめる", StoryDoc.rec(StoryDoc.defaults())#lamps),
            (StoryDoc.rec(doc)#hint, StoryDoc.rec(doc)#lamps))

    @Test
    def testStorySpeakerRowsGiveNames(): Unit \ Assert =
        // speakers の rows の数だけ呼び名が引け、rows に無い話し手は id のまま出る。
        let text = "{\"version\":1, \"speakers\":[{\"id\":\"me\",\"name\":\"私\"},{\"id\":\"master\",\"name\":\"主\"}]}";
        let doc = StoryDoc.fromJson(text) |> Option.getWithDefault(StoryDoc.defaults());
        Assert.assertEq(expected = (2, "私", "butler"),
            (List.length(StoryDoc.rec(doc)#speakers), StoryDoc.nameOf("me", doc), StoryDoc.nameOf("butler", doc)))

    // ══════════════════════════════════════════════════════
    // Talk（シナリオの語彙。正はコードの enum）
    // ══════════════════════════════════════════════════════

    /// build の check が読む assets/talk/vocab.json は、コードの enum から作り直した物と同じ（ずれたら make talk-vocab）。
    @Test
    def testVocabFileMatchesTheCode(): Unit \ {Assert, Fs.FileRead} =
        Assert.assertEq(expected = Ok(Yarn.vocabJson(Talk.vocabOf())), Fs.FileRead.read(Talk.vocabPath()) |> Result.mapErr(e -> "${e}"))

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
    // KeysDoc（キー割り当て）
    // ══════════════════════════════════════════════════════

    @Test
    def testKeysBrokenJsonFallsBackToDefaults(): Unit \ Assert =
        // 壊れた JSON は既定の割り当てへ落ちる（操作不能にしない）。
        let doc = KeysDoc.fromJson("{ broken") |> Option.getWithDefault(KeysDoc.defaults());
        Assert.assertEq(expected = KeysDoc.rec(KeysDoc.defaults())#menu, KeysDoc.rec(doc)#menu)

    @Test
    def testKeysOverridesOneFieldAndDropsUnknownNames(): Unit \ Assert =
        // 書いた欄だけ効き（知らない名前はその 1 個だけ捨てる）、全部知らない名前の欄と書かない欄は既定のまま。
        let doc = KeysDoc.fromJson("{\"version\":1, \"menu\": [\"P\", \"Pause\"], \"quit\": [\"Bye\"]}")
            |> Option.getWithDefault(KeysDoc.defaults());
        let d = KeysDoc.rec(KeysDoc.defaults());
        Assert.assertEq(expected = (GameEngine.Key.P :: Nil, d#quit, d#confirm),
            (KeysDoc.rec(doc)#menu, KeysDoc.rec(doc)#quit, KeysDoc.rec(doc)#confirm))

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
