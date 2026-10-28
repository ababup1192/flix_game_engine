// Starts — 始まりの登録簿（App.withStarts。Game が Resources.liftStart で組の行へ持ち上げる）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="level n=2"）・リモートの POST /start・flow の `start level`・テストの App.startOrBug が同じ表を引く。
mod Starts {
    use fge::Resources

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[Resources.Start[Res.Res, World.World]] =
        { name = "title", doc = "題名の画面（起動の既定）", args = Map.empty(), build = (_, w, _) -> Ok(w) } ::
        { name = "level", doc = "面 n（1 から数える）の初め", args = Map#{"n" => "1"}, build = level } :: Nil

    def level(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        let text = Map.getWithDefault("n", "1", args);
        match Int32.fromString(text) {
            case Some(n) if n >= 1 and n <= Vector.length(res#stages) => Ok(World.enterLevel(res, n - 1, w))
            case _ => Err("n は 1..${Vector.length(res#stages)} の面（'${text}'）")
        }
}
