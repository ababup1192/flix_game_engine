// Starts — 始まりの登録簿（App.withStarts）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="level n=2"）・リモートの POST /start・flow の `start level`・テストの App.startOrBug が同じ表を引く。
mod Starts {
    use fge::App

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[App.Start[World.World]] =
        { name = "title", doc = "題名の画面（起動の既定）", args = Map.empty(), build = (w, _) -> Ok(w) } ::
        { name = "level", doc = "面 n（1 から数える）の初め", args = Map#{"n" => "1"}, build = level } :: Nil

    def level(w: World.World, args: Map[String, String]): Result[String, World.World] =
        let text = Map.getWithDefault("n", "1", args);
        match Int32.fromString(text) {
            case Some(n) if n >= 1 and n <= Vector.length(w#stages) => Ok(World.enterLevel(n - 1, w))
            case _ => Err("n は 1..${Vector.length(w#stages)} の面（'${text}'）")
        }
}
