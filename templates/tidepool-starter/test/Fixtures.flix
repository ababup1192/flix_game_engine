// テストが共有する組み立てと取り出し（盤を格子から組む・水位の行を取り出す・Doc の既定で World を組む）。
mod Fixtures {

    use fge::{AudioMixer, PxSpriteDoc, ShaderDoc}

    /// 格子から盤を組む（満ち引きの表は cycle）。組めない格子はテストの書き誤りなので止める。
    pub def board(cycle: List[Int32], heights: List[String], props: List[String]): Board.Board =
        match Board.fromRows(List.toVector(cycle), heights, props) {
            case Ok(b)    => b
            case Err(why) => bug!("テストの盤が組めない: ${why}")
        }

    /// 面 1 と同じ盤: 左の高さ 3 からの 3 2 1 1 2 3 の 1 本道。上下は外海につながる高さ 0。満ち引きは rules の既定。
    pub def crossing(): Board.Board =
        board(RulesDoc.rec(RulesDoc.defaults())#cycle, "000000" :: "321123" :: "000000" :: Nil,
              "......" :: "@....*" :: "......" :: Nil)

    /// 水位の y 行目（左から）。
    pub def rowOf(y: Int32, water: Tide.Water, b: Board.Board): List[Int32] =
        List.range(0, b#cols) |> List.map(x -> Map.getWithDefault((x, y), -1, water))

    /// 既定の Doc（面は LevelsDoc の既定の 1 面）で組んだ描く元。
    pub def res(): Res.Res =
        let demo = ShaderDoc.demoSurface();
        Res.build({ rules = RulesDoc.defaults(), levels = LevelsDoc.defaults(), keys = KeysDoc.defaults(),
                 theme = ThemeDoc.defaults(), sprites = PxSpriteDoc.empty(),
                 surfaces = { rock = demo, water = demo, caustics = demo }, mixer = AudioMixer.defaults() })

    /// res() で、面 1 を遊び始めた World。
    pub def world(): World.World =
        World.initial() |> World.enterLevel(res(), 0)

    /// 手を当てた後のヤドカリと小石と流木（動けなかったら None）。
    pub def placesAfter(b: Board.Board, move: World.Move, s: World.State): Option[(Board.Cell, Set[Board.Cell], Set[Board.Cell])] =
        World.act(b, move, s) |> Option.map(next -> (next#crab, next#pebbles, next#driftwood))
}
