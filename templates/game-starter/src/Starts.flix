// Starts — 始まりの登録簿（App.withStarts。Game が Resources.liftStart で組の行へ持ち上げる）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="at x=40 y=40"）・リモートの POST /start・flow の `start at`・テストの App.startOrBug が同じ表を引く。
// 場面を足したら、その場面へ入る始まりもここに 1 行足す（テストと flow がその場面から始められる）。
mod Starts {
    use fge::Resources

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[Resources.Start[Res.Res, World.World]] =
        { name = "play", doc = "主人公が画面の真ん中に立つ所（起動の既定）", args = Map.empty(), build = (_, w, _) -> Ok(w) } ::
        { name = "at", doc = "主人公を x・y（design の px。画面の外は内へ寄せる）に置いた所", args = Map#{"x" => "0", "y" => "0"}, build = at } :: Nil

    def at(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        forM (
            x <- coordOf("x", args);
            y <- coordOf("y", args)
        ) yield World.placeHero(res, { x = x, y = y }, w)

    def coordOf(name: String, args: Map[String, String]): Result[String, Float64] =
        let text = Map.getWithDefault(name, "0", args);
        Float64.fromString(text) |> Option.toOk("${name} は数（'${text}'）")
}
