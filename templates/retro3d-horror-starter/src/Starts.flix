// Starts — 始まりの登録簿（App.withStarts。Game が Resources.liftStart で組の行へ持ち上げる）。名前と引数から、新しく作った初期の World を場面へ組む。
// 起動（START="at x=-4.5 z=2 yaw=0"）・リモートの POST /start・flow の `start at`・テストの App.startOrBug が同じ表を引く。
mod Starts {
    use fge::{Num, Resources, Vec3}

    /// 登録簿。先頭が起動の既定。
    pub def all(): List[Resources.Start[Res.Res, World.World]] =
        { name = "play", doc = "1 階の昇降口に立つ所（起動の既定・表の spawn）", args = Map.empty(), build = (_, w, _) -> Ok(w) } ::
        { name = "at", doc = "足元 x・y・z（engine の座標・m）に立ち、yaw（度・0 で +Z・90 で +X）を向いた所（下の床に合わせる）。" +
                             "items=a,b で持ち物（items.kind.json の id）を持たせ、unlocked=library,science でその部屋の戸を開けておく",
          args = atArgs(), build = at } ::
        { name = "perf", doc = "at と同じ所に立ち、重さの表示（F3）を出した所（見える窓で fps を測る）",
          args = atArgs(), build = (res, w, args) -> at(res, w, args) |> Result.map(World.togglePerf) } :: Nil

    def atArgs(): Map[String, String] = Map#{"x" => "0", "y" => "0", "z" => "0", "yaw" => "0", "items" => "", "unlocked" => ""}

    def at(res: Res.Res, w: World.World, args: Map[String, String]): Result[String, World.World] =
        forM (
            x <- numOf("x", args);
            y <- numOf("y", args);
            z <- numOf("z", args);
            yaw <- numOf("yaw", args);
            held <- World.withItems(res, namesOf("items", args), w);
            rooms <- lockedRooms(res, namesOf("unlocked", args))
        ) yield World.withUnlocked(rooms, World.placeAt(res, Vec3.v3(x, y, z), yaw * Num.pi() / 180.0, held))

    /// 開けておく部屋が全部、鍵のかかった部屋か（打ち間違いを黙って通さない）。
    def lockedRooms(res: Res.Res, rooms: List[String]): Result[String, List[String]] =
        match rooms |> List.find(r -> not Items.isLockedRoom(res#items, r)) {
            case Some(r) => Err("unlocked の '${r}' は items.kind.json の locks に無い部屋")
            case None    => Ok(rooms)
        }

    /// a,b の形の引数を名前の並びに（空なら空）。
    def namesOf(name: String, args: Map[String, String]): List[String] =
        Map.getWithDefault(name, "", args) |> String.splitOn(substr = ",") |> List.map(String.trim) |> List.filter(n -> not String.isEmpty(n))

    def numOf(name: String, args: Map[String, String]): Result[String, Float64] =
        let text = Map.getWithDefault(name, "0", args);
        Float64.fromString(text) |> Option.toOk("${name} は数（'${text}'）")
}
