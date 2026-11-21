// ItemsDoc — items.kind.json（拾える物・置き場所・鍵のかかった部屋・拾う演出の値・決まり文句）の宣言ドキュメント層。
// 置き場所は配置の表（layout.json）と同じ glTF の座標で書く（読む時に X を反転する）。向きも表と同じく glTF の +Y まわりの度。
// 拾える距離と角は人物に話しかける時と同じ（characters.kind.json の talkReach・talkAngleDeg）。
// 振る舞い（どれを向いているか・鍵の照合・閉まった戸の当たり）はコード（Items と World）。
// 読めない JSON は defaults() へ落とす（fail-open）。置き場所と鍵が items に無い id を指していたら読み込みを Err にする
// （届かない鍵の部屋は二度と開かないので、黙って続けない）。
mod ItemsDoc {
    use fge::{DocJson, JsonCodec, Log, Num, Vec3}
    use Util.Json.Json

    /// 持ち物 1 つ。glb = assets/items/<glb>.glb の名前（根のノードの名前と同じ）・name = 一覧と字幕に出す名前・
    /// text = アイテム画面の説明文・viewScale = 目の前で見せる時の大きさの倍率・viewTiltDeg = 目の前で見せる時に手前へ起こす角（度）。
    pub type alias Item = { id = String, name = String, text = String, glb = String, viewScale = Float64, viewTiltDeg = Float64 }

    /// 床（机・台の上）に置いた物 1 つ。item = 持ち物の id・floor = 階の番号・pos = 置き場所（engine の座標）・yaw = 向き（ラジアン・engine の回り）。
    pub type alias Pickup = { id = String, item = String, floor = Int32, pos = Vec3.Vec3, yaw = Float64 }

    /// 鍵のかかった部屋 1 つ。room = 配置の表の rooms[].id・key = 開ける持ち物の id。
    pub type alias Lock = { room = String, key = String }

    /// 拾う演出の値。flySec = 置き場所から目の前まで飛ぶ秒・showSec = 目の前で回して見せる秒（字幕もこの間）・
    /// holdDistance = 目の前の距離（m）・holdDrop = 目の高さから下げる長さ（m）・bob = 目の前で浮き沈みする幅（m）・
    /// glowSpeed = 床の物がゆっくり明るくなる・暗くなる速さ（1 秒の回数）・glowAmount = その明るさの揺れ幅（0..1）。
    pub type alias Pickups = { flySec = Float64, showSec = Float64, holdDistance = Float64, holdDrop = Float64, bob = Float64, glowSpeed = Float64, glowAmount = Float64 }

    /// アイテム画面と戸の値。viewDistance = アイテム画面で回す物の目からの距離（m）・spinDegPerSec = 回る速さ・
    /// curtain = 場面を暗く落とす黒の濃さ（0..1）・noticeSec = 「鍵がかかっている。」などを出す秒・doorOpenSec = 戸が開き切るまでの秒。
    pub type alias Screens = { viewDistance = Float64, spinDegPerSec = Float64, curtain = Float64, noticeSec = Float64, doorOpenSec = Float64 }

    /// 決まり文句。{name} を持ち物の名前に置き換える。
    pub type alias Texts = { got = String, locked = String, opened = String, pickHint = String, doorHint = String, listTitle = String, empty = String }

    pub type alias Rec = { version = Int32, items = List[Item], pickups = List[Pickup], locks = List[Lock], pickup = Pickups, screens = Screens, texts = Texts }
    pub enum Doc(Rec)
    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/items.kind.json"

    /// コード側の既定（物も鍵も置かない。演出の値と決まり文句は assets/items.kind.json と同じ）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, items = Nil, pickups = Nil, locks = Nil,
                  pickup = { flySec = 0.5, showSec = 1.6, holdDistance = 0.45, holdDrop = 0.08, bob = 0.01, glowSpeed = 0.35, glowAmount = 0.35 },
                  screens = { viewDistance = 0.45, spinDegPerSec = 40.0, curtain = 0.7, noticeSec = 2.0, doorOpenSec = 0.6 },
                  texts = { got = "{name}を手に入れた。", locked = "鍵がかかっている。", opened = "{name}で開けた。",
                            pickHint = "Space: 拾う", doorHint = "Space: 調べる", listTitle = "持ち物", empty = "何も持っていない。" } })

    /// テキストから Doc へ。JSON の object でなければ Err、置き場所か鍵が知らない持ち物を指していれば Err。
    pub def fromJson(text: String): Result[String, Doc] =
        DocJson.parse(text) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("items.kind.json を JSON の object として読めない")
            |> Result.flatMap(root -> checked(fromRoot(root)))

    /// path の Doc を読む。読めなければ既定（物の無い校舎）、id の食い違いは 1 行言って既定。
    pub def load(p: String): Doc \ Fs.FileRead =
        match DocJson.readJson(p) {
            case Err(_)   => defaults()
            case Ok(json) => match JsonCodec.expectObject(json) |> Option.toOk("${p} の一番外が object でない") |> Result.flatMap(root -> checked(fromRoot(root))) {
                case Ok(d)    => d
                case Err(why) => Log.warnThen("[items] ${why}（物と鍵なしで続ける）", defaults())
            }
        }

    /// 置き場所と鍵が指す持ち物が items にあるか。
    def checked(d: Doc): Result[String, Doc] =
        let r = rec(d);
        let known = r#items |> List.map(i -> i#id) |> List.toSet;
        let missing = List.append(r#pickups |> List.map(p -> p#item), r#locks |> List.map(l -> l#key)) |> List.filter(id -> not Set.memberOf(id, known));
        match missing {
            case Nil     => Ok(d)
            case id :: _ => Err("items.kind.json の置き場所か鍵が、items に無い持ち物 '${id}' を指している")
        }

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        let txt = (key, fallback) -> JsonCodec.stringOr(key, fallback, root);
        let p = d#pickup;
        let s = d#screens;
        let t = d#texts;
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  items = rowsOf("items", itemOf, root), pickups = rowsOf("pickups", pickupOf, root), locks = rowsOf("locks", lockOf, root),
                  pickup = { flySec = num("flySec", p#flySec), showSec = num("showSec", p#showSec), holdDistance = num("holdDistance", p#holdDistance),
                             holdDrop = num("holdDrop", p#holdDrop), bob = num("bob", p#bob), glowSpeed = num("glowSpeed", p#glowSpeed), glowAmount = num("glowAmount", p#glowAmount) },
                  screens = { viewDistance = num("viewDistance", s#viewDistance), spinDegPerSec = num("spinDegPerSec", s#spinDegPerSec),
                              curtain = num("curtain", s#curtain), noticeSec = num("noticeSec", s#noticeSec), doorOpenSec = num("doorOpenSec", s#doorOpenSec) },
                  texts = { got = txt("gotText", t#got), locked = txt("lockedText", t#locked), opened = txt("openedText", t#opened),
                            pickHint = txt("pickHint", t#pickHint), doorHint = txt("doorHint", t#doorHint), listTitle = txt("listTitle", t#listTitle), empty = txt("emptyText", t#empty) } })

    /// 配列の欄を 1 行ずつ読む（欄の欠けた行はその行だけ捨てる）。
    def rowsOf(key: String, rowOf: Map[String, Json] -> Option[a], root: Map[String, Json]): List[a] =
        Map.get(key, root) |> Option.flatMap(JsonCodec.decodeList(Some)) |> Option.getWithDefault(Nil)
            |> List.filterMap(j -> JsonCodec.expectObject(j) |> Option.flatMap(rowOf))

    def itemOf(obj: Map[String, Json]): Option[Item] =
        Map.get("id", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.map(id ->
            { id = id, name = JsonCodec.stringOr("name", id, obj), text = JsonCodec.stringOr("text", "", obj), glb = JsonCodec.stringOr("glb", "prop_item_${id}", obj),
              viewScale = JsonCodec.floatOr("viewScale", 1.0, obj), viewTiltDeg = JsonCodec.floatOr("viewTiltDeg", 0.0, obj) })

    /// 表と同じ約束で読む: [x, y, z] は X を反転・yaw は小物と同じく glTF の度をそのままラジアンに（School.propMatrix の回り）。
    def pickupOf(obj: Map[String, Json]): Option[Pickup] =
        let pos = Map.get("pos", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.flatMap(xs -> match xs {
            case x :: y :: z :: Nil => Some(Vec3.v3(0.0 - x, y, z))
            case _                  => None
        });
        forM (
            id <- Map.get("id", obj) |> Option.flatMap(JsonCodec.expectString);
            item <- Map.get("item", obj) |> Option.flatMap(JsonCodec.expectString);
            floor <- Map.get("floor", obj) |> Option.flatMap(JsonCodec.expectInt);
            at <- pos
        ) yield { id = id, item = item, floor = floor, pos = at, yaw = JsonCodec.floatOr("yaw", 0.0, obj) * Num.pi() / 180.0 }

    def lockOf(obj: Map[String, Json]): Option[Lock] =
        forM (
            room <- Map.get("room", obj) |> Option.flatMap(JsonCodec.expectString);
            key <- Map.get("key", obj) |> Option.flatMap(JsonCodec.expectString)
        ) yield { room = room, key = key }

    /// 決まり文句の {name} を置き換える。
    pub def fill(template: String, name: String): String = String.replace(src = "{name}", dst = name, template)
}
