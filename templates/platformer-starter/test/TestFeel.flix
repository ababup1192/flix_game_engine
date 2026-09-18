// 手触り(ゆるし)のルール。数値の期待値は MotionDoc.defaults() から導く —
// バランス調整(JSON の書き換え)でこのテストは壊れない。
// 地形は closures で直に与える(Stage を経由しない = Physics/Player 単体の検査)。
mod TestFeel {

    def m(): MotionDoc.Doc = MotionDoc.defaults()

    def mr(): MotionDoc.Rec = MotionDoc.rec(m())

    def dt(): Float64 = 1.0 / 120.0

    /// 平地: 行 5 から下が全部硬い(地面の上面 y = 80px)。
    def flat(): Physics.Terrain =
        { solid = (_x, y) -> y >= 5, oneWay = (_x, _y) -> false }

    /// 一方通行だけの床(行 5)。
    def oneWayFloor(): Physics.Terrain =
        { solid = (_x, _y) -> false, oneWay = (_x, y) -> y == 5 }

    def idle(): Player.Input =
        { dir = 0.0, jumpHeld = false, jumpPressed = false, drop = false, dash = false }

    def jump(): Player.Input =
        { dir = 0.0, jumpHeld = true, jumpPressed = true, drop = false, dash = false }

    /// 地面に立っている状態(足裏 = 80px)。
    def grounded(): Player.State =
        let p0 = Player.initial({ x = 24.0, y = 80.0 - Physics.playerSize()#y * 0.5 });
        Player.step(flat(), m(), dt(), idle(), p0)   // 1 tick で接地を確定させる

    @Test
    def testJumpFiresOnGround(): Unit \ Assert =
        let p = Player.step(flat(), m(), dt(), jump(), grounded());
        Assert.assertEq(expected = true, p#body#vel#y < 0.0)

    @Test
    def testCoyoteAllowsLateJump(): Unit \ Assert =
        // 崖を離れた直後(コヨーテ残あり)は空中でも跳べる。バッファとコヨーテは消費される。
        let airborne = { body = { pos = { x = 24.0, y = 40.0 }, vel = { x = 0.0, y = 30.0 },
                                  onGround = false },
                         coyote = mr()#coyoteTime * 0.5, buffer = 0.0,
                         facing = 1.0, jumping = false, wall = 0.0 };
        let p = Player.step(flat(), m(), dt(), jump(), airborne);
        Assert.assertEq(expected = (true, 0.0, 0.0),
            (p#body#vel#y < 0.0, p#coyote, p#buffer))

    @Test
    def testCoyoteExpiredCannotJump(): Unit \ Assert =
        let airborne = { body = { pos = { x = 24.0, y = 40.0 }, vel = { x = 0.0, y = 30.0 },
                                  onGround = false },
                         coyote = 0.0, buffer = 0.0, facing = 1.0, jumping = false, wall = 0.0 };
        let p = Player.step(flat(), m(), dt(), jump(), airborne);
        Assert.assertEq(expected = false, p#body#vel#y < 0.0)

    @Test
    def testJumpBufferFiresOnLanding(): Unit \ Assert =
        // 着地前に取り置いた入力(buffer 残あり)が、着地の次の tick で自動発火する。
        let falling = { body = { pos = { x = 24.0, y = 80.0 - Physics.playerSize()#y * 0.5 - 1.0 },
                                 vel = { x = 0.0, y = 200.0 }, onGround = false },
                        coyote = 0.0, buffer = mr()#jumpBufferTime, facing = 1.0,
                        jumping = false, wall = 0.0 };
        let landed = Player.step(flat(), m(), dt(), idle(), falling);
        let p = Player.step(flat(), m(), dt(), idle(), landed);
        Assert.assertEq(expected = (true, true),
            (landed#body#onGround, p#body#vel#y < 0.0))

    @Test
    def testVariableJumpCutMatchesDoc(): Unit \ Assert =
        // 離した瞬間の削り = cutFactor(Doc から導出)。その後の重力 1 tick 分まで含めて厳密一致。
        let rising = { body = { pos = { x = 24.0, y = 40.0 }, vel = { x = 0.0, y = -200.0 },
                                onGround = false },
                       coyote = 0.0, buffer = 0.0, facing = 1.0, jumping = true, wall = 0.0 };
        let release = { dir = 0.0, jumpHeld = false, jumpPressed = false, drop = false, dash = false };
        let p = Player.step(flat(), m(), dt(), release, rising);
        let cut = -200.0 * Physics.cutFactor(m());
        let expected = Float64.min(cut + Physics.gravityFor(m(), cut) * dt(),
                                   mr()#maxFallSpeed);
        Assert.assertEq(expected = (expected, false), (p#body#vel#y, p#jumping))

    @Test
    def testFallGravityIsHarder(): Unit \ Assert =
        // 下降中の重力 = 上昇中 × fallGravityMult(Doc から導出)。
        Assert.assertEq(
            expected = (Physics.gravity(m()) * mr()#fallGravityMult, Physics.gravity(m())),
            (Physics.gravityFor(m(), 10.0), Physics.gravityFor(m(), -10.0)))

    @Test
    def testOneWayLandsFromAbove(): Unit \ Assert =
        // 上から落ちれば乗れる(足裏がちょうど床上面 80px で止まる)。
        let size = Physics.playerSize();
        let slid = Physics.slideBox(oneWayFloor(), size, dt(), false, 0.0,
            { x = 24.0, y = 80.0 - size#y * 0.5 - 1.0 }, { x = 0.0, y = 300.0 });
        Assert.assertEq(expected = (true, 80.0 - size#y * 0.5),
            (slid#onGround, slid#pos#y))

    @Test
    def testOneWayPassesFromBelowAndOnDrop(): Unit \ Assert =
        // 下から上がるときは通れる。↓(drop)なら上からもすり抜ける。
        let size = Physics.playerSize();
        let up = Physics.slideBox(oneWayFloor(), size, dt(), false, 0.0,
            { x = 24.0, y = 96.0 + size#y * 0.5 }, { x = 0.0, y = -400.0 });
        let drop = Physics.slideBox(oneWayFloor(), size, dt(), true, 0.0,
            { x = 24.0, y = 80.0 - size#y * 0.5 }, { x = 0.0, y = 60.0 });
        Assert.assertEq(expected = (false, false), (up#hitHead, drop#onGround))

    /// 角の許し用の地形: (2,2) の 1 マスだけ硬い。
    def oneBlock(): Physics.Terrain =
        { solid = (x, y) -> x == 2 and y == 2, oneWay = (_x, _y) -> false }

    @Test
    def testCornerNudgeSlidesPastGrazingHead(): Unit \ Assert =
        // 頭の右端 3px だけが角にかすった上昇 → 横へ逃げて通る(止まらない)。
        let size = Physics.playerSize();
        let pos = { x = 35.0 - size#x * 0.5, y = 50.0 + size#y * 0.5 };
        let vel = { x = 0.0, y = -600.0 };
        let nudged = Physics.slideBox(oneBlock(), size, dt(), false,
                                      mr()#cornerNudgePx, pos, vel);
        let blocked = Physics.slideBox(oneBlock(), size, dt(), false, 0.0, pos, vel);
        Assert.assertEq(expected = (false, true, true),
            (nudged#hitHead, blocked#hitHead, nudged#pos#x < pos#x))

    @Test
    def testWalkSpeedCapsAtDoc(): Unit \ Assert =
        // 歩きの最高速は Doc の walkSpeed で頭打ち。
        let p = List.range(0, 240) |> List.foldLeft((acc, _) ->
            Player.step(flat(), m(), dt(),
                { dir = 1.0, jumpHeld = false, jumpPressed = false, drop = false, dash = false }, acc),
            grounded());
        Assert.assertEq(expected = mr()#walkSpeed, p#body#vel#x)

    @Test
    def testDashRaisesTopSpeedToDoc(): Unit \ Assert =
        // B ダッシュの最高速 = walkSpeed × dashMult(期待値は Doc から導く)。
        let dash = { dir = 1.0, jumpHeld = false, jumpPressed = false, drop = false, dash = true };
        let p = List.range(0, 240) |> List.foldLeft((acc, _) ->
            Player.step(flat(), m(), dt(), dash, acc), grounded());
        Assert.assertEq(expected = Physics.topSpeed(m(), true), p#body#vel#x)

    @Test
    def testDashReleaseKeepsMomentum(): Unit \ Assert =
        // 離した瞬間に walkSpeed へ落ちない — decel でゆるく戻るので勢いが残る。
        // ここが accel で即座に戻ると操作が固く感じる(気持ちよさのルール)。
        let dash = { dir = 1.0, jumpHeld = false, jumpPressed = false, drop = false, dash = true };
        let fast = List.range(0, 240) |> List.foldLeft((acc, _) ->
            Player.step(flat(), m(), dt(), dash, acc), grounded());
        let walk = Player.step(flat(), m(), dt(), { dash = false | dash }, fast);
        Assert.assertEq(expected = true, walk#body#vel#x > mr()#walkSpeed)

    /// 右側(x >= 3)が壁の地形。床は無いので接地ジャンプは出ない。
    def rightWall(): Physics.Terrain =
        { solid = (x, _y) -> x >= 3, oneWay = (_x, _y) -> false }

    @Test
    def testWallJumpOnlyWhenDocEnablesIt(): Unit \ Assert =
        // motion.json の wallJump が唯一の開閉。off なら壁に押し当てても跳べず、
        // on なら跳んで壁と反対へ蹴る。「フラグはあるが何も動かない」を捕まえる。
        let push = { dir = 1.0, jumpHeld = true, jumpPressed = true, drop = false, dash = false };
        let onWall = { body = { pos = { x = 48.0 - Physics.playerSize()#x * 0.5, y = 40.0 },
                                vel = { x = 60.0, y = 30.0 }, onGround = false },
                       coyote = 0.0, buffer = 0.0, facing = 1.0, jumping = false, wall = 1.0 };
        let off = Player.step(rightWall(), MotionDoc.Doc.Doc({ wallJump = false | mr() }), dt(), push, onWall);
        let on  = Player.step(rightWall(), MotionDoc.Doc.Doc({ wallJump = true  | mr() }), dt(), push, onWall);
        Assert.assertEq(expected = (false, true, true),
            (off#body#vel#y < 0.0, on#body#vel#y < 0.0, on#body#vel#x < 0.0))
}
