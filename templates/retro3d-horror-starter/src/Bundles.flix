// Bundles — 校舎の束（tools/glb_bundle.py が作る assets/school/bundle/*.glb）と人物・持ち物の glb を、鍵ごとに読む（BackgroundLoad の Group を 2 つ: 束と、人物・持ち物）。
// デスクトップと画面なしは起動で全部の鍵を読む。ブラウザ版は起動の素材（project.json の web.deferred に無い物）の鍵だけ起動で読み、
// 残りは届いた物から App.withBackgroundLoad がコマの予算の内で解く（Res.withLoaded が校舎を組み直す）。
// 束の中の根のノードの名前は元の glb の名前（school_floor<n>・prop_<名前>）で、根ごとに 1 つの形へ切り分ける。
mod Bundles {
    use fge::{BackgroundLoad, DocJson, JsonCodec, Log, Model3d}
    use Util.Json.Json

    /// 束 1 つ。floors = 束の物を置く階・buildings = 束に建物が入っている階。
    pub type alias Entry = { key = String, path = String, floors = List[Int32], buildings = List[Int32] }

    pub def path(): String = "assets/school/bundle/bundles.json"

    /// 束の表。仮の校舎（glb の無い表）では表が無いのが普通なので、その時は知らせずに空。
    pub def load(placeholder: Bool, p: String): List[Entry] \ Fs.FileRead =
        match DocJson.readJson(p) {
            case Ok(json) =>
                JsonCodec.expectObject(json)
                    |> Option.flatMap(root -> Map.get("bundles", root))
                    |> Option.flatMap(JsonCodec.decodeList(j -> JsonCodec.expectObject(j) |> Option.flatMap(entryOf)))
                    |> Option.getWithDefault(Nil)
            case Err(_) => if (placeholder) Nil else Log.warnThen("[school] ${p} を読めない（make bundles で作る）— 校舎の形なしで続ける", Nil)
        }

    def entryOf(obj: Map[String, Json]): Option[Entry] =
        let ints = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectInt)) |> Option.getWithDefault(Nil);
        forM (
            key <- Map.get("key", obj) |> Option.flatMap(JsonCodec.expectString);
            p <- Map.get("path", obj) |> Option.flatMap(JsonCodec.expectString)
        ) yield { key = key, path = p, floors = ints("floors"), buildings = ints("buildings") }

    /// 人物の鍵（束の鍵と重ならない形）。
    pub def personKey(model: String): String = "person:${model}"

    /// 人物の鍵なら model の名前。
    pub def personOf(key: String): Option[String] =
        if (String.startsWith(prefix = "person:", key)) Some(String.dropLeft(String.length("person:"), key)) else None

    def personPath(model: String): String = "assets/characters/${model}.glb"

    /// 持ち物の鍵（glb の名前・assets/items/<名前>.glb）。根の名前は prop_item_<id> なので、束の小物と同じく Res.placeModel が小物の置き場へ入れる。
    // WhyNot: 持ち物を校舎の束（tools/glb_bundle.py）へ入れない — 束は校舎の glb を書き出し直すたびに make bundles で作り直す物で、持ち物の glb は別の担当が別の時に直す。
    pub def itemKey(glb: String): String = "item:${glb}"

    def itemPath(key: String): Option[String] =
        if (String.startsWith(prefix = "item:", key)) Some("assets/items/${String.dropLeft(String.length("item:"), key)}.glb") else None

    /// 鍵の glb の道（束の表に無い鍵・人物でも持ち物でもない鍵は空）。
    def pathOf(bundles: List[Entry], key: String): Option[String] =
        ((personOf(key) |> Option.map(personPath)) :: itemPath(key) :: (bundles |> List.find(b -> b#key == key) |> Option.map(b -> b#path)) :: Nil)
            |> List.flatMap(Option.toList) |> List.head

    /// 束・人物・持ち物の glb を読む Group の型。read は道とバイトを取るだけ・decode が glb と絵と頂点の色（COLOR_0。Blender でベイクした明るさ・project.json の "gltf"）を解く。
    pub type alias Group = BackgroundLoad.Group[Result[String, (String, Vector[Int8])], Model3d.Model3d]

    /// 校舎の束を読む Group。costMs は 1 束を解く見込み（束 1 つ primitive 200 個前後で、M4 Pro の Chrome で 35 ms 前後・スマホは 3〜5 倍。Controls.decodeBudget の Idle(45) で 1 コマに 1 束）。
    pub def schoolGroup(bundles: List[Entry], loader: Model3d.Loader): Group =
        groupOf("school", bundles, bundles |> List.map(b -> b#key), loader, 35.0)

    /// 人物（personKey）と持ち物（itemKey）の glb を読む Group。
    // WhyNot: 校舎の束と同じ Group に入れない — 見込み（costMs）は Group に 1 つで、スマホで束が 100〜180 ms かかると見込みがそこまで上がり、
    // Idle(45) の間は estimateResetMs（2 秒）待って戻るまで次を始めない。180 KB ほどの人物もその間待たされ、遊び始めてから何秒も出ない。
    // WhyNot: costMs を束の 35 のままにしない — 測ると人物 1 体は束の 1/5 ほど（JVM で 1 階の束 22〜26 ms・人物 5 ms・持ち物 1 ms）で、
    // スマホの束 100〜180 ms から人物は 20〜36 ms。小さい側の 25 なら、Idle(45) で前の仕事が 20 ms までのコマに人物を 1 体始められる
    // （大きい側の 36 で書くと、絵の登録が 9 ms を超えたコマでは始めない）。
    pub def modelGroup(models: List[String], items: List[String], loader: Model3d.Loader): Group =
        groupOf("models", Nil, List.append(models |> List.map(personKey), items |> List.map(itemKey)), loader, 25.0)

    def groupOf(name: String, bundles: List[Entry], keys: List[String], loader: Model3d.Loader, costMs: Float64): Group =
        { name = name, keys = keys, pathsOf = key -> pathOf(bundles, key) |> Option.toList,
          read = key -> match pathOf(bundles, key) {
              case Some(p) => Fs.FileRead.readBytes(p) |> Result.map(b -> (p, b)) |> Result.mapErr(e -> "${p}: 読めない（${e}）")
              case None    => Err("${key}: 束の表に無い鍵")
          },
          decode = raw -> raw |> Result.flatMap(pb -> Model3d.decode(loader, fst(pb), snd(pb))),
          costMs = costMs }

    /// 束を根のノードごとの形に切り分ける（根の名前 → その根の下の parts だけを持つ形）。絵は束の全部を持たせる（場面には名前で重ねずに渡る: School.build）。
    pub def roots(model: Model3d.Model3d): Map[String, Model3d.Model3d] =
        let nodes = List.toVector(model#nodes);
        let rootOf = (i: Int32) -> rootLoop(nodes, i, Vector.length(nodes));
        let byRoot = model#parts |> List.foldRight((p, acc) -> match p#node {
            case Some(k) => Map.insertWith((fresh, old) -> List.append(fresh, old), rootOf(k), p :: Nil, acc)
            case None    => acc
        }, Map.empty());
        model#nodes |> List.mapWithIndex((i, n) -> (i, n))
            |> List.filter(e -> Option.isEmpty(snd(e)#parent))
            |> List.map(e -> (snd(e)#name, { parts = Map.getWithDefault(fst(e), Nil, byRoot) | model }))
            |> List.toMap

    /// ノード i の根（親を辿る。輪になっていたら budget で止めてその場を根とする）。
    def rootLoop(nodes: Vector[Model3d.ModelNode], i: Int32, budget: Int32): Int32 =
        match Vector.nth(i, nodes) |> Option.flatMap(n -> n#parent) {
            case Some(p) if budget > 0 => rootLoop(nodes, p, budget - 1)
            case _                     => i
        }

    /// 階 floor に物を置く鍵（束）。
    pub def keysOnFloor(bundles: List[Entry], floor: Int32): List[String] =
        bundles |> List.filter(b -> List.memberOf(floor, b#floors)) |> List.map(b -> b#key)

    /// 階 floor の建物の入った束の道（ブラウザ版はこの道が届くまでその階へ入らない）。
    pub def buildingPathsOf(bundles: List[Entry], floor: Int32): List[String] =
        bundles |> List.filter(b -> List.memberOf(floor, b#buildings)) |> List.map(b -> b#path)
}
