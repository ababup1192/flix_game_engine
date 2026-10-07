// TileState — マス目の「いま」を持つ表。遊んでいる最中に変わり、セーブに乗る側のデータ。
// マップの形（どこが地面か・どこが壁か）は Doc に書いて読むだけの設計図だが、
// 耕した・水をやった・何かを置いた といった状態は日ごとに変わるので置き場所を分ける。
// 利用例: 畑（耕した/濡れた/植えた/育ち具合）/ 罠を仕掛けたマス / 掘り返した床 / 積んだ荷。
// 注意: 持つのは「値のあるマス」だけ（疎な表）。広い盤でも植えたマスの数しか場所を取らない。
//
// 日が変わったときの一斉更新は mapValues で 1 回なめるだけ。毎フレーム全マスを見る必要はない。
pub mod TileState {

    /// マス → 値 の表。値の型はゲームが決める（畑なら「耕した・濡れ・作物・日数」の record）。
    pub type alias Table[v] = Map[(Int32, Int32), v]

    /// 何も無い表。
    pub def empty(): Table[v] = Map.empty()

    /// そのマスの値。無ければ None。
    pub def get(cell: Grid.Cell, table: Table[v]): Option[v] =
        Map.get((cell#x, cell#y), table)

    /// そのマスに値があるか。
    pub def has(cell: Grid.Cell, table: Table[v]): Bool =
        Map.memberOf((cell#x, cell#y), table)

    /// そのマスに値を置く（すでにあれば置き換える）。
    pub def put(cell: Grid.Cell, value: v, table: Table[v]): Table[v] =
        Map.insert((cell#x, cell#y), value, table)

    /// そのマスの値を消す。
    pub def remove(cell: Grid.Cell, table: Table[v]): Table[v] =
        Map.remove((cell#x, cell#y), table)

    /// そのマスの値を作り替える。None を返せば消える、Some を返せば置き換わる。
    /// 「無ければ作る・あれば更新する」を 1 つの式で書くための入口。
    pub def update(cell: Grid.Cell, f: Option[v] -> Option[v] \ ef, table: Table[v]): Table[v] \ ef =
        match f(get(cell, table)) {
            case None        => remove(cell, table)
            case Some(value) => put(cell, value, table)
        }

    /// 値のあるマスの数。
    pub def size(table: Table[v]): Int32 = Map.size(table)

    /// 値のあるマスの列。
    pub def cells(table: Table[v]): List[Grid.Cell] =
        Map.keysOf(table) |> Set.toList |> List.map(key -> { x = fst(key), y = snd(key) })

    /// (マス, 値) の列。描画やセーブで全部をなめるときの入口。
    pub def entries(table: Table[v]): List[(Grid.Cell, v)] =
        Map.toList(table) |> List.map(entry -> {
            let (key, value) = entry;
            ({ x = fst(key), y = snd(key) }, value)
        })

    /// すべての値を一度に作り替える（日が変わったときの一斉更新）。
    pub def mapValues(f: v -> v \ ef, table: Table[v]): Table[v] \ ef =
        Map.map(f, table)

    /// マスの位置も見ながら一度に作り替える（季節や地形で結果が変わるとき）。
    pub def mapAt(f: (Grid.Cell, v) -> v \ ef, table: Table[v]): Table[v] \ ef =
        Map.mapWithKey(key -> value -> f({ x = fst(key), y = snd(key) }, value), table)

    /// 残す値だけを選ぶ（枯れた物を片付ける）。
    pub def filterValues(pred: v -> Bool \ ef, table: Table[v]): Table[v] \ ef =
        Map.filter(pred, table)

    /// 条件に合うマスの数を数える（水をやった数・実った数）。
    pub def countValues(pred: v -> Bool, table: Table[v]): Int32 =
        Map.count((_ -> pred), table)

    // ── セーブとの往復 ──
    //
    // 形は [{"x":3,"y":5,"v":<値>}, ...] の並び。値の中身はゲームが決めるので、
    // その 1 個ぶんの読み書きだけを関数で受け取る。
    // 読めない要素は黙って捨てる（fail-open — セーブが少し古くても遊びは続く）。

    /// 表を JSON の並びにする。encode = 値 1 個を JSON にする関数。
    pub def toJson(encode: v -> Util.Json.Json, table: Table[v]): Util.Json.Json =
        entries(table)
            |> List.map(entry -> {
                let (cell, value) = entry;
                Util.Json.Json.JObject(Map#{
                    "x" => Util.Json.Json.JNumber(JsonCodec.intToBd(cell#x)),
                    "y" => Util.Json.Json.JNumber(JsonCodec.intToBd(cell#y)),
                    "v" => encode(value)
                })
            })
            |> List.toVector
            |> Util.Json.Json.JArray

    /// JSON の並びを表に戻す。decode = JSON 1 個を値にする関数（読めなければ None）。
    pub def fromJson(decode: Util.Json.Json -> Option[v], element: Util.Json.Json): Table[v] =
        match element {
            case Util.Json.Json.JArray(items) =>
                List.foldLeft((acc, item) -> match decodeEntry(decode, item) {
                    case None              => acc
                    case Some((cell, value)) => put(cell, value, acc)
                }, empty(), Vector.toList(items))
            case _ => empty()
        }

    def decodeEntry(decode: Util.Json.Json -> Option[v],
                    element: Util.Json.Json): Option[(Grid.Cell, v)] =
        JsonCodec.expectObject(element) |> Option.flatMap(fields ->
            Map.get("x", fields) |> Option.flatMap(JsonCodec.expectInt) |> Option.flatMap(x ->
            Map.get("y", fields) |> Option.flatMap(JsonCodec.expectInt) |> Option.flatMap(y ->
            Map.get("v", fields) |> Option.flatMap(decode) |> Option.map(value ->
                ({ x = x, y = y }, value)))))
}
