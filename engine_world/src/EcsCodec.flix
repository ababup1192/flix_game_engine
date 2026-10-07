// EcsCodec — 「番号ごとの値の表」を JSON と相互変換する共通ヘルパ。
// 値ごとの変換だけ渡せば表全体を JSON に落とせるので、セーブ・ロードやデータからの組み立てが楽になる。
// 利用例: プレイ状況をファイルに保存する / 保存データから World を復元する / 盤面をデータで用意する。
// 注意: 値1つ分の変換方法はゲーム側が渡す。ここは表全体の往復だけを引き受ける。

pub mod EcsCodec {

    use Util.Json.Json
    use Util.Json.Json.{JObject, JNumber, JArray, JBool}

    /// component store を JSON 配列 [{id, v}, ...] に encode する。
    pub def encodeStore(encodeC: c -> Json, store: Map[EntityId, c]): Json =
        Map.toList(store)
            |> JsonCodec.encodeList(pair ->
                let (id, v) = pair;
                JObject(Map#{ "id" => JNumber(JsonCodec.intToBd(id)), "v" => encodeC(v) }))

    /// JSON 配列 [{id, v}, ...] を component store に decode する。1 要素でも失敗なら全体 None。
    pub def decodeStore(decodeC: Json -> Option[c], json: Json): Option[Map[EntityId, c]] =
        JsonCodec.decodeList(entry -> decodeStoreEntry(decodeC, entry), json)
            |> Option.map(List.toMap)

    def decodeStoreEntry(decodeC: Json -> Option[c], entry: Json): Option[(EntityId, c)] =
        forM (
            obj <- JsonCodec.expectObject(entry);
            idJ <- Map.get("id", obj);
            vJ  <- Map.get("v", obj);
            id  <- JsonCodec.expectInt(idJ);
            v   <- decodeC(vJ)
        ) yield (id, v)

    /// タグ集合 Set[EntityId] を JSON int 配列に往復する。
    pub def encodeIdSet(s: Set[EntityId]): Json =
        JArray(Set.toList(s) |> List.map(id -> JNumber(JsonCodec.intToBd(id))) |> List.toVector)

    pub def decodeIdSet(json: Json): Option[Set[EntityId]] =
        JsonCodec.decodeList(JsonCodec.expectInt, json) |> Option.map(List.toSet)

    /// Option[EntityId]（player 等）を JSON へ。None は false、Some(id) は数値。
    pub def encodeIdOption(o: Option[EntityId]): Json =
        match o {
            case Some(id) => JNumber(JsonCodec.intToBd(id))
            case None     => JBool(false)
        }

    /// 上の対。数値なら Some(id)、それ以外（false 等）なら None。
    pub def decodeIdOption(json: Json): Option[EntityId] =
        JsonCodec.expectInt(json)
}
