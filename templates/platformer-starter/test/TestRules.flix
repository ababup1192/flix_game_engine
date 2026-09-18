// ゲームのルール・進行・収支(World 単位)。面は rows をインラインで与える —
// stage.json のバランス調整でこのテストは壊れない。期待値は Doc から導く。
mod TestRules {

    def m(): MotionDoc.Doc = MotionDoc.defaults()

    def mr(): MotionDoc.Rec = MotionDoc.rec(m())

    def r(): RulesDoc.Doc = RulesDoc.defaults()

    def rr(): RulesDoc.Rec = RulesDoc.rec(r())

    def ed(): EnemyDoc.Doc = EnemyDoc.defaults()

    def edr(): EnemyDoc.Rec = EnemyDoc.rec(ed())

    /// 平地に 1 行だけ置く定型の面。空 4 行 + その行 + 床 — 意味のある行だけ書く。
    def flat(row: String): List[String] =
        "........" :: "........" :: "........" :: "........" :: row :: "########" :: Nil

    def doc(rows: List[String]): StageDoc.Doc =
        StageDoc.Doc.Doc({ version = 1, stages = { name = "t", kind = "outdoor", rows = rows } :: Nil })

    def world(rows: List[String]): World.World =
        World.initial(m(), KeysDoc.defaults(), r(), EnemyDoc.defaults(), doc(rows), Theme.defaults(),
                      UiText.defaults(), PxSpriteDoc.empty())

    def idle(): World.Input =
        { dir = 0.0, jumpHeld = false, jumpPressed = false, drop = false, dash = false }

    /// 右へ歩き続ける入力(ゴール・敵・中間ポイントまで bot に歩かせる用)。
    def walkR(): World.Input = { dir = 1.0 | idle() }

    def dt(): Float64 = 1.0 / 60.0

    /// 秒 → tick 数(このテストの dt で数えるときの換算)。
    def ticksFor(sec: Float64): Int32 =
        Float64.floor(sec / dt()) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    def stepN(n: Int32, inp: World.Input, w: World.World): World.World =
        List.range(0, n) |> List.foldLeft((acc, _) -> World.step(inp, dt(), acc), w)

    /// pred を満たす最初の状態(最大 n tick)。満たさなければ最後の状態。
    def stepUntil(n: Int32, pred: World.World -> Bool, inp: World.Input,
                  w: World.World): World.World =
        if (n <= 0 or pred(w)) w
        else stepUntil(n - 1, pred, inp, World.step(inp, dt(), w))

    @Test
    def testCoinCollectAddsScore(): Unit \ Assert =
        // 開始位置に重なるコイン → 1 tick で取得。1 枚ぶんの点は rules Doc。
        let w = world(
               "........"
            :: "........"
            :: "........"
            :: "..o....."
            :: "..P....."
            :: "########" :: Nil);
        let w1 = World.step(idle(), dt(), w);
        Assert.assertEq(expected = (rr()#coinScore, 1), (w1#score, Set.size(w1#got)))

    @Test
    def testCoinCollectsOnlyOnce(): Unit \ Assert =
        let w = world(
               "........"
            :: "........"
            :: "........"
            :: "..o....."
            :: "..P....."
            :: "########" :: Nil);
        let w1 = stepN(30, idle(), w);
        Assert.assertEq(expected = rr()#coinScore, w1#score)

    @Test
    def testSpringLaunchesHigherThanJump(): Unit \ Assert =
        // バネの上に立つと springTiles(Doc)の高さへ — 長押しジャンプでは届かない高さまで上がる。
        let w = world(flat("..P.S..."));
        let startY = w#player#body#pos#y;
        let flew = stepUntil(240, x ->
            startY - x#player#body#pos#y > (mr()#jumpHeightTiles + 1.0) * Physics.tileSize(),
            walkR(), w);
        Assert.assertEq(expected = true,
            startY - flew#player#body#pos#y > (mr()#jumpHeightTiles + 1.0) * Physics.tileSize())

    @Test
    def testStompKillsAndBounces(): Unit \ Assert =
        // 上から踏む: 敵は消え stompScore ぶん加点、hitstop = Doc、バウンドの初速 = stompBounceTiles から導出。
        let w = world(flat("..P..a.."));
        let w1 = World.step(idle(), dt(), { player = stompingFrom(w) | w });
        Assert.assertEq(
            expected = (0, rr()#stompScore, mr()#hitstopSec,
                        Physics.launchVelocity(m(), mr()#stompBounceTiles)),
            (List.length(w1#enemies), w1#score, w1#freeze, w1#player#body#vel#y))

    /// 1 体目の敵の真上から踏みに降りている主役。
    def stompingFrom(w: World.World): Player.State =
        let fallback = Enemies.make(Enemies.Behavior.Walking(0.0), Stage.centerOf({ x = 5, y = 4 }));
        let e = List.head(w#enemies) |> Option.getWithDefault(fallback);
        let etop = e#pos#y - Enemies.sizeOf(e#behavior)#y * 0.5;
        { body = { pos = { x = e#pos#x, y = etop - Physics.playerSize()#y * 0.5 - 2.0 },
                   vel = { x = 0.0, y = 200.0 }, onGround = false }
        | w#player }

    @Test
    def testSideTouchHurts(): Unit \ Assert =
        // 横から触れる: ハート -1・無敵 = Doc の invulnSec。
        let w = world(flat("..P.a..."));
        let hurtW = stepUntil(240, x -> x#hearts < rr()#maxHearts, walkR(), w);
        Assert.assertEq(expected = (rr()#maxHearts - 1, mr()#invulnSec),
            (hurtW#hearts, hurtW#invuln))

    @Test
    def testFlyerBobsWithoutDrifting(): Unit \ Assert =
        // 飛ぶ敵は湧いた高さを中心に上下するだけ: 横へ流れず、1/4 周期で Doc の flyAmpTiles ぶん振れる。
        let posOf = x -> List.head(x#enemies) |> Option.map(e -> e#pos)
            |> Option.getWithDefault({ x = 0.0, y = 0.0 });
        let w = world(flat("..P..b.."));
        let p0 = posOf(w);
        let p1 = posOf(stepN(ticksFor(edr()#flyPeriod / 4.0), idle(), w));
        let amp = edr()#flyAmpTiles * Physics.tileSize();
        // 頂点の手前で止まるぶんの丸めだけ許す(1 tick ぶん = 2px 未満)。
        Assert.assertEq(expected = (p0#x, true),
            (p1#x, Float64.abs((p1#y - p0#y) - amp) < 2.0))

    @Test
    def testShooterFiresWhenInRange(): Unit \ Assert =
        // 射程内(Doc の shotRangeTiles)・同じ高さの範囲 → 弾が出て主役の側へ飛ぶ。
        let w = world(flat("..P..z.."));
        let w1 = World.step(idle(), dt(), w);
        let vx = List.head(w1#shots) |> Option.map(s -> s#vel#x) |> Option.getWithDefault(0.0);
        Assert.assertEq(expected = (1, true), (List.length(w1#shots), vx < 0.0))

    @Test
    def testFallOutRespawnsAtCheckpoint(): Unit \ Assert =
        // 画面の下へ落ちる → ハート -1 で戻り先(開始位置)へ。
        let w = world(
               "........"
            :: "..P....."
            :: "........"
            :: "........"
            :: "........"
            :: "##.#####" :: Nil);
        let back = stepUntil(600, x -> x#hearts < rr()#maxHearts, idle(), w);
        Assert.assertEq(expected = (rr()#maxHearts - 1, true),
            (back#hearts, back#player#body#pos#y < 60.0))

    @Test
    def testCheckpointMovesRespawnPoint(): Unit \ Assert =
        // 中間ポイントに触れる → 戻り先が差し替わり、次に落ちてもそこから再開する。
        // 「点いたのに最初へ戻る」を捕まえるのがこのテストの仕事。
        let w = world(
               "........"
            :: "........"
            :: "........"
            :: "P...c..."
            :: "####.###" :: Nil);
        let onCp = stepUntil(240, x -> not Set.isEmpty(x#cpOn), walkR(), w);
        let moved = onCp#checkpoint#x > w#checkpoint#x;
        // 減っていたハートは 1 つ返る(上限は maxHearts)。
        let hurt = { hearts = rr()#maxHearts - 2 | w };
        let healed = stepUntil(240, x -> not Set.isEmpty(x#cpOn), walkR(), hurt);
        Assert.assertEq(expected = rr()#maxHearts - 1, healed#hearts);
        // そのまま穴へ落ちる → 差し替わった戻り先(最初より右)から再開。
        let back = stepUntil(600, x -> x#hearts < rr()#maxHearts, walkR(), onCp);
        Assert.assertEq(expected = (true, true),
            (moved, back#player#body#pos#x > w#checkpoint#x))

    @Test
    def testGoalClearsAndAdvances(): Unit \ Assert =
        // 旗に触れる → clear(goalScore ぶん加点)。間を置いて次の面(1 面しか無いので同じ面)を読み直す。
        let w = world(
               "........"
            :: "........"
            :: "........"
            :: "...G...."
            :: "..P....."
            :: "########" :: Nil);
        let cleared = stepUntil(240, x -> x#phase == "clear", walkR(), w);
        let advanced = stepN(120, idle(), cleared);
        Assert.assertEq(expected = ("clear", true, "play"),
            (cleared#phase, cleared#score >= rr()#goalScore, advanced#phase))

    @Test
    def testGameOverRestartsFromFirstStage(): Unit \ Assert =
        // 残機が尽きる → over の幕を overWaitSec だけ見せ、そのあと点も残機も
        // まっさらにして 1 面目から。「2 面目で力尽きたのに 2 面目から再開」を捕まえる。
        let two: StageDoc.Doc = StageDoc.Doc.Doc({ version = 1,
            stages = { name = "one", kind = "outdoor", rows = "..P....." :: "########" :: Nil }
                  :: { name = "two", kind = "outdoor", rows = "..P....." :: "##.#####" :: Nil }
                  :: Nil });
        let w0 = World.initial(m(), KeysDoc.defaults(), r(), EnemyDoc.defaults(), two, Theme.defaults(),
                               UiText.defaults(), PxSpriteDoc.empty());
        // 2 面目・残機 1・点あり の状態から穴へ落ちる。
        let onTwo = { score = 1234, hearts = 1 | World.loadStage(1, w0) };
        let over = stepUntil(600, x -> x#phase == "over", idle(), onTwo);
        // 幕が明ける直前はまだ over、明けたら 1 面目の play。
        let early = stepN(ticksFor(rr()#overWaitSec) - 2, idle(), over);
        let again = stepN(4, idle(), early);
        Assert.assertEq(
            expected = ("over", "over", "play", 0, rr()#maxHearts, 0, "one"),
            (over#phase, early#phase, again#phase,
             again#score, again#hearts, again#stageIx, Stage.rec(again#stage)#name))

    @Test
    def testPlatformCarriesRider(): Unit \ Assert =
        // 動く床に乗ると、床の移動量(時刻の純関数の差分)で運ばれる。
        let w = world(
               "........"
            :: "........"
            :: "........"
            :: "..~~...."
            :: "........"
            :: "########" :: Nil);
        let p = List.head(Stage.rec(w#stage)#platforms)
            |> Option.getWithDefault({ cell = { x = 2, y = 3 }, wTiles = 2 });
        let t1 = w#t + dt();
        let deck = World.platformPosAt(m(), p, t1);
        let riding = { body = { pos = { x = deck#x + 16.0,
                                        y = deck#y - Physics.playerSize()#y * 0.5 },
                                vel = Vec2.zero(), onGround = true }
                     | w#player };
        let x0 = riding#body#pos#x;
        let w1 = World.step(idle(), dt(), { player = riding | w });
        let delta = (World.platformPosAt(m(), p, t1)#x - World.platformPosAt(m(), p, w#t)#x);
        let moved = w1#player#body#pos#x - x0;
        Assert.assertEq(expected = true,
            Float64.abs(moved - delta) < 0.75 and w1#player#body#onGround)

    @Test
    def testBlinkPhaseFromClock(): Unit \ Assert =
        // 消える床: 周期の前半だけ硬い(位相 0 のマス)。時刻の純関数なので値で縛れる。
        // 期待値は Doc から導く: 硬い区間の内 / 外 / 次の周期の内。
        Assert.assertEq(expected = (true, false, true),
            (World.blinkOn(m(), 0.1, 0, 0),
             World.blinkOn(m(), mr()#blinkOnSec + 0.1, 0, 0),
             World.blinkOn(m(), mr()#blinkPeriod + 0.1, 0, 0)))

    @Test
    def testHitstopFreezesWorld(): Unit \ Assert =
        // freeze 中は世界の時刻ごと止まる(敵も粒も進まない)。
        let w = world(flat("..P....."));
        let frozen = { freeze = 0.5 | stepN(3, idle(), w) };
        let w1 = World.step(idle(), dt(), frozen);
        Assert.assertEq(expected = (frozen#t, true), (w1#t, w1#freeze < frozen#freeze))

    @Test
    def testCameraLeadComesFromDoc(): Unit \ Assert =
        // カメラの先読みは motion Doc のノブ。先読みを 0 にした世界と既定の世界で
        // カメラの行き先が変わることを固定する — 「JSON にノブはあるが誰も
        // 読んでいない」を捕まえるのがこのテストの仕事(壁ジャンプで一度踏んだ)。
        let w = world(flat("..P....."));
        let still: MotionDoc.Doc = MotionDoc.Doc.Doc({ camLeadPx = 0.0 | mr() });
        let far = stepN(60, walkR(), w);
        let near = stepN(60, walkR(), { motion = still | w });
        Assert.assertEq(expected = true, far#cam#x > near#cam#x)
}
