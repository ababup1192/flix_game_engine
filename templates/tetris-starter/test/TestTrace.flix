// 性質テスト: 種で決まる乱数のキー操作を App.trace（画面なし）に流し、どの種でも決まりが崩れないかを見る。
// 盤は下 4 行を 1 列だけ空けて始める（でたらめに落としても列が消える場面が早く来る）。
mod TestTrace {

    use fge::{App, PropTrace, ShaderDoc}
    use fge::GameEngine.Key

    /// 押す操作の役。
    enum Role with Eq, ToString {
        case Left, Right, Ccw, Cw, Drop, Soft
    }

    def keyOf(role: Role): Key = match role {
        case Role.Left  => Key.Left
        case Role.Right => Key.Right
        case Role.Ccw   => Key.Z
        case Role.Cw    => Key.X
        case Role.Drop  => Key.Space
        case Role.Soft  => Key.Down
    }

    def setup(): PropTrace.Setup[Role] =
        { keyOf = keyOf, viewport = { x = 256.0, y = 352.0 }, dt = 1.0 / 60.0 }

    def spec(): PropTrace.Spec[Role] =
        { taps = Role.Left :: Role.Right :: Role.Ccw :: Role.Cw :: Role.Drop :: Nil,
          holds = Role.Soft :: Nil, idle = 4, dts = Nil }

    /// 実機（Main）と同じ更新と音の部品だけを繋いだ App。
    def app(start: World.World): App.App[World.World, {}] =
        App.make(start) |> App.addSystem(Controls.step) |> App.withAudio(Controls.sounds)

    def start(): World.World =
        let w = World.initial({ doc = RulesDoc.defaults(), theme = ThemeDoc.defaults(),
                                shader = ShaderDoc.demoSurface() });
        let cells = List.range(World.rows() - 4, World.rows()) |> List.flatMap(r ->
            List.range(0, World.cols()) |> List.filter(c -> c != 4) |> List.map(c -> ((c, r), World.Kind.I)));
        { board = List.foldLeft((b, e) -> { let (c, k) = e; Map.insert(c, k, b) }, Map.empty(), cells) | w }

    def seeds(): Int32 = 12

    def length(): Int32 = 600

    def acts(seed: Int64): List[PropTrace.Act[Role]] = PropTrace.plan(seed, length(), spec())

    /// 列を消した音（1〜3 行の 2 種と 4 行）。
    def clearNames(): Set[String] =
        (Controls.Sound.LineA :: Controls.Sound.LineB :: Controls.Sound.Tetris :: Nil)
            |> List.map(Controls.soundName) |> List.toSet

    def clearSoundsIn(step: PropTrace.Step[World.World]): Int32 =
        List.count(name -> Set.memberOf(name, clearNames()), step#sounds)

    @Test
    def testSameSeedSameBoard(): Unit \ Assert =
        // 同じ種（= 同じ入力の列）なら、2 回流しても最後の盤・点・消した行数が同じ。
        let broken = PropTrace.firstFailingSeed(seeds(), seed -> {
            let once = PropTrace.finalOf(app(start()), setup(), acts(seed), start());
            let twice = PropTrace.finalOf(app(start()), setup(), acts(seed), start());
            if ((once#board, once#score, once#lines) == (twice#board, twice#score, twice#lines)) None
            else Some("2 回目の盤が違う")
        });
        Assert.assertEq(expected = None, broken)

    @Test
    def testOneClearOneSound(): Unit \ Assert =
        // 行数が増えたフレームだけ、列を消した音がちょうど 1 回鳴る（増えないフレームは鳴らない）。
        let rule = (step: PropTrace.Step[World.World]) -> {
            let wanted = if (step#after#lines > step#before#lines) 1 else 0;
            let got = clearSoundsIn(step);
            if (got == wanted) None
            else Some("消した音 ${Int32.toString(got)} 回（欲しいのは ${Int32.toString(wanted)} 回）")
        };
        let broken = PropTrace.firstFailingSeed(seeds(), seed ->
            PropTrace.firstBroken(app(start()), setup(), acts(seed), start(), rule)
                |> Option.map(found -> { let (frame, why, _) = found; "${Int32.toString(frame)} フレーム目: ${why}" }));
        Assert.assertEq(expected = None, broken)

    @Test
    def testSomeSeedClearsLines(): Unit \ Assert =
        // 上の決まりが空振りでないこと: どれかの種で列が消えたフレームがある
        // （GAME OVER の後は Space で始め直すので、終わりの盤ではなく途中のフレームで数える）。
        let cleared = List.range(1, seeds() + 1) |> List.map(seed ->
            PropTrace.traceOf(app(start()), setup(), acts(Int32.toInt64(seed)), start())
                |> List.count(step -> step#after#lines > step#before#lines))
            |> List.sum;
        Assert.assertEq(expected = true, cleared > 0)
}
