// Starts — 始まりの登録簿（App.withStarts）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="stack gap=0"）・リモートの POST /start・flow の `start stack`・テストの App.startOrBug が同じ表を引く。
// build は純粋: 走っている World は渡らない（渡すと、さっきまで遊んでいた盤に場面が依存する）。
mod Starts {
    use fge::App

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[App.Start[World.World]] =
        { name = "play", doc = "空の盤に最初のミノが涌いた所（起動の既定）", args = Map.empty(),
          build = (w, _) -> Ok(w) } ::
        { name = "stack", doc = "下 4 行が 1 列（gap = 0..9）だけ空いた盤。縦の I を落とすと 4 行消える", args = Map#{"gap" => "4"},
          build = stack } ::
        { name = "over", doc = "天井まで積んで GAME OVER になった所（決定で仕切り直し）", args = Map.empty(),
          build = (w, _) -> Ok({ phase = World.Phase.GameOver, board = bottomRows(World.rows(), -1) | w }) } :: Nil

    /// 下 4 行を gap の列だけ空けて埋めた盤。
    def stack(w: World.World, args: Map[String, String]): Result[String, World.World] =
        let text = Map.getWithDefault("gap", "4", args);
        match Int32.fromString(text) {
            case Some(gap) if gap >= 0 and gap < World.cols() => Ok({ board = bottomRows(4, gap) | w })
            case _ => Err("gap は 0..${World.cols() - 1} の列（'${text}'）")
        }

    /// 下から count 行を、gap の列（-1 なら空けない）を除いて I の升で埋めた盤。
    def bottomRows(count: Int32, gap: Int32): Map[World.Cell, World.Kind] =
        List.range(World.rows() - count, World.rows())
            |> List.flatMap(row -> List.range(0, World.cols()) |> List.filter(col -> col != gap) |> List.map(col -> ((col, row), World.Kind.I)))
            |> List.toMap
}
