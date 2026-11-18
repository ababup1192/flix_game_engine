// Starts — 始まりの登録簿（App.withStarts。Game が Resources.liftStart で組の行へ持ち上げる）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="at col=13 row=47 face=s"）・リモートの POST /start・flow の `start at`・テストの App.startOrBug が同じ表を引く。
mod Starts {
    use fge::Resources

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[Resources.Start[Res.Res, World.World]] =
        { name = "walk", doc = "explore.json の立ち始めのマスに立つ所（起動の既定）", args = Map.empty(), build = (_, w, _) -> Ok(w) } ::
        { name = "at", doc = "先頭をマス col・row に、face（n・e・s・w）を向けて立たせた所",
          args = Map#{"col" => "13", "row" => "54", "face" => "n"}, build = at } :: Nil

    def at(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        forM (
            c <- intOf("col", args);
            r <- intOf("row", args)
        ) yield World.placeLeader(res, c, r, Facing.ofLetter(Map.getWithDefault("face", "n", args)), w)

    def intOf(name: String, args: Map[String, String]): Result[String, Int32] =
        let text = Map.getWithDefault(name, "0", args);
        Int32.fromString(text) |> Option.toOk("${name} は整数（'${text}'）")
}
