// JSON とプログラムの橋渡し(1 Doc につき最大 3 本):
// 壊れたら既定値 / 1 フィールド上書き / rows(増減データ)の長さ追随。
mod TestDocs {

    @Test
    def testMotionBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(MotionDoc.fromJson("{oops")))

    @Test
    def testMotionOverridesOneField(): Unit \ Assert =
        let d = MotionDoc.fromJson("{\"walkSpeed\": 210.5}")
            |> Option.getWithDefault(MotionDoc.defaults()) |> MotionDoc.rec;
        Assert.assertEq(expected = (210.5, MotionDoc.rec(MotionDoc.defaults())#coyoteTime),
            (d#walkSpeed, d#coyoteTime))

    @Test
    def testStagesBrokenFallsBackToBuiltin(): Unit \ Assert =
        // 壊れた JSON でも組み込みの 1 面で必ず遊べる(fail-open)。
        Assert.assertEq(expected = (true, 1),
            (Option.isEmpty(StageDoc.fromJson("not json")),
             List.length(StageDoc.rec(StageDoc.defaults())#stages)))

    @Test
    def testStagesCountFollowsJson(): Unit \ Assert =
        // stages(増減するデータ)の数が JSON に追随する。
        let text = "{\"stages\": ["
            ++ "{\"name\": \"a\", \"kind\": \"outdoor\", \"rows\": [\"..\", \"##\"]},"
            ++ "{\"name\": \"b\", \"kind\": \"cave\", \"rows\": [\"..\"]}]}";
        let d = StageDoc.fromJson(text) |> Option.getWithDefault(StageDoc.defaults()) |> StageDoc.rec;
        let kinds = d#stages |> List.map(s -> s#kind);
        Assert.assertEq(expected = (2, "outdoor" :: "cave" :: Nil),
            (List.length(d#stages), kinds))

    @Test
    def testRulesBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(RulesDoc.fromJson("[1, 2]")))

    @Test
    def testRulesOverridesOneField(): Unit \ Assert =
        let d = RulesDoc.fromJson("{\"coinScore\": 7}")
            |> Option.getWithDefault(RulesDoc.defaults()) |> RulesDoc.rec;
        Assert.assertEq(expected = (7, RulesDoc.rec(RulesDoc.defaults())#maxHearts),
            (d#coinScore, d#maxHearts))

    @Test
    def testUiTextBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(UiText.fromJson("CLEAR!")))

    @Test
    def testUiTextOverridesOneField(): Unit \ Assert =
        let d = UiText.fromJson("{\"clear\": \"YATTA\"}")
            |> Option.getWithDefault(UiText.defaults()) |> UiText.rec;
        Assert.assertEq(expected = ("YATTA", UiText.rec(UiText.defaults())#gameOver),
            (d#clear, d#gameOver))

    @Test
    def testEnemyOverridesOneField(): Unit \ Assert =
        let d = EnemyDoc.fromJson("{\"shotCooldown\": 9.0}")
            |> Option.getWithDefault(EnemyDoc.defaults()) |> EnemyDoc.rec;
        Assert.assertEq(expected = (9.0, EnemyDoc.rec(EnemyDoc.defaults())#walkSpeed),
            (d#shotCooldown, d#walkSpeed))

    @Test
    def testThemeOverridesOneColor(): Unit \ Assert =
        // colors の 1 色だけ上書き(他は既定のまま)。Color は record なので成分で比べる。
        let d = Theme.fromJson("{\"colors\": {\"coin\": \"#FF0000\"}}")
            |> Option.getWithDefault(Theme.defaults());
        let coin = Theme.resolve(d, "coin");
        let ink = Theme.resolve(d, "ink");
        let ink0 = Theme.resolve(Theme.defaults(), "ink");
        Assert.assertEq(
            expected = (1.0, 0.0, 0.0, (ink0#r, ink0#g, ink0#b)),
            (coin#r, coin#g, coin#b, (ink#r, ink#g, ink#b)))

    /// 色票(assets/px.palette.json)は生成物 — Theme や legend を変えて
    /// `make palette` を忘れると、Studio の編集画面だけ古い色になり、
    /// 実機と食い違ったまま**見ただけでは気付けない**。焼き忘れをここで落とす。
    @Test
    def testPaletteFileIsFresh(): Unit \ {Assert, IO} =
        let (sprites, theme, onDisk) = run {
            (PxSpriteDoc.load(World.spritePath()),
             Theme.load(Theme.path()),
             Fs.FileRead.read(Palette.path()))
        } with Fs.FileRead.runWithIO;
        let fresh = Palette.toJson(Palette.entriesOf(sprites, theme));
        Assert.assertEq(expected = Ok(fresh), onDisk)

    /// legend の意味色キーが 1 つ残らず色票で解けること。解けない名前は
    /// Studio が並び順から作った仮色で塗るので、絵は出るのに配色だけ狂う。
    @Test
    def testEveryLegendColorResolves(): Unit \ {Assert, IO} =
        let (sprites, theme) = run {
            (PxSpriteDoc.load(World.spritePath()), Theme.load(Theme.path()))
        } with Fs.FileRead.runWithIO;
        let names = sprites#legend |> Map.valuesOf |> List.distinct;
        let entries = Palette.entriesOf(sprites, theme);
        let missing: List[String] = names |> List.filter(n ->
            not List.exists(e -> fst(e) == n, entries));
        Assert.assertEq(expected = (Nil, List.length(names)),
            (missing, List.length(entries)))

    // ── keys(キー割り当て)──

    @Test
    def testKeysBrokenFallsBack(): Unit \ Assert =
        Assert.assertEq(expected = true, Option.isEmpty(KeysDoc.fromJson("{oops")))

    @Test
    def testKeysDropsUnknownNameOnly(): Unit \ Assert =
        // 書き間違い("Sinistra")はその 1 個だけ落ち、残りは書いた順で生きる。
        let d = KeysDoc.fromJson("{\"left\": [\"Left\", \"Sinistra\", \"A\"]}")
            |> Option.getWithDefault(KeysDoc.defaults()) |> KeysDoc.rec;
        Assert.assertEq(expected = GameEngine.Key.Left :: GameEngine.Key.A :: Nil, d#left)

    @Test
    def testKeysEmptyActionFallsBackToDefaults(): Unit \ Assert =
        // 全部知らない名前で操作が空になったら、その操作だけ既定へ落とす(操作不能を
        // 作らない)。書いた操作(dash)と触っていない操作(left)は影響を受けない。
        let d = KeysDoc.fromJson("{\"jump\": [\"Hop\"], \"dash\": [\"Q\"]}")
            |> Option.getWithDefault(KeysDoc.defaults()) |> KeysDoc.rec;
        Assert.assertEq(
            expected = (KeysDoc.rec(KeysDoc.defaults())#jump, GameEngine.Key.Q :: Nil, KeysDoc.rec(KeysDoc.defaults())#left),
            (d#jump, d#dash, d#left))
}
