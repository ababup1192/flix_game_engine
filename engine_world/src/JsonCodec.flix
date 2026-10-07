// JsonCodec — JSON の読み書きでよく使う小さなヘルパを 1 箇所に集める。
// 各 Codec がめいめいに書いていた変換を共有でき、`Saveable` の toJson / fromJson を短く書ける。
// 利用例: JSON object から値を取り出す / Map や List を JSON と相互変換する / Vec2 を読み書きする。
// 注意: decode 系は純粋 (`Json -> Option[T]`)。encode 用の数値変換 (`floatToBd` / `intToBd`) は
//   内部の `unsafe IO` で副作用を隠すので、呼び出し側は純粋関数として扱える。
pub mod JsonCodec {
    import java.math.{BigDecimal => JBigDecimal}

    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber, JBool, JArray}

    // ════════════════════════════════════════════════════════
    // 値の取り出し: 期待型ならその中身を、そうでなければ None を返す
    // ════════════════════════════════════════════════════════

    /// JSON object なら中身の Map を、そうでなければ None を返す。
    pub def expectObject(element: Json): Option[Map[String, Json]] =
        match element {
            case JObject(map) => Some(map)
            case _               => None
        }

    /// JSON 文字列なら中身を返す。
    pub def expectString(element: Json): Option[String] =
        match element {
            case JString(text) => Some(text)
            case _                => None
        }

    /// JSON 数値を Int32 として取り出す。`BigDecimal -> Float64 -> Int32` の 2 段階の変換。
    /// 範囲外 / 小数 / 数値以外は None。
    pub def expectInt(element: Json): Option[Int32] =
        match element {
            case JNumber(bd) =>
                BigDecimal.tryToFloat64(bd) |> Option.flatMap(Float64.tryToInt32)
            case _              => None
        }

    /// JSON 数値を Float64 として取り出す。数値以外は None。
    pub def expectFloat(element: Json): Option[Float64] =
        match element {
            case JNumber(bd) => BigDecimal.tryToFloat64(bd)
            case _              => None
        }

    /// JSON 真偽値を取り出す。真偽値以外は None。
    pub def expectBool(element: Json): Option[Bool] =
        match element {
            case JBool(value) => Some(value)
            case _               => None
        }

    // ════════════════════════════════════════════════════════
    // 数値変換: 内部 unsafe IO で副作用を隠蔽し pure シグネチャで提供
    // ════════════════════════════════════════════════════════

    /// `Float64` を `BigDecimal` に。trailing zero 除去で「100」(「100.0」ではなく) として書き出す。
    /// scale が負になった場合 (= 「1E+2」のような指数表記になるケース) は 0 に補正して
    /// 通常表記「100」を維持する。内部 `unsafe IO` で隠蔽するため呼び出し側は pure として扱える。
    pub def floatToBd(value: Float64): BigDecimal =
        unsafe IO {
            let stripped = JBigDecimal.valueOf(value).stripTrailingZeros();
            if (stripped.scale() < 0) stripped.setScale(0) else stripped
        }

    /// `Int32` を `BigDecimal` に。trailing zero 除去で「100」として書き出す。
    /// scale が負になる場合は 0 に補正して「100」表記を維持する。
    pub def intToBd(value: Int32): BigDecimal =
        unsafe IO {
            let stripped = JBigDecimal.valueOf(Int32.toFloat64(value)).stripTrailingZeros();
            if (stripped.scale() < 0) stripped.setScale(0) else stripped
        }

    // ════════════════════════════════════════════════════════
    // Map[String, T] の round-trip
    // ════════════════════════════════════════════════════════

    /// `Map[String, T]` を JSON object として encode する。`encodeEntry` は 1 要素 encoder。
    pub def encodeStringMap(encodeEntry: t -> Json, entries: Map[String, t]): Json =
        let inner = entries |> Map.foldLeftWithKey(
            (acc, key, entry) -> Map.insert(key, encodeEntry(entry), acc),
            Map.empty()
        );
        JObject(inner)

    /// JSON object を `Map[String, T]` として decode する。要素のいずれかが None なら全体 None。
    /// schema 不整合の検出は全体 None で受けるため、部分成功を許さない設計。
    pub def decodeStringMap(decodeEntry: Json -> Option[t], element: Json):
            Option[Map[String, t]] =
        match element {
            case JObject(map) =>
                Map.foldLeftWithKey(
                    (acc, key, entryJson) ->
                        Option.flatMap(soFar ->
                            decodeEntry(entryJson)
                                |> Option.map(decoded -> Map.insert(key, decoded, soFar)),
                            acc),
                    Some(Map.empty()),
                    map)
            case _ => None
        }

    // ════════════════════════════════════════════════════════
    // List[T] の round-trip
    // ════════════════════════════════════════════════════════

    /// `List[T]` を JSON array として encode する。
    pub def encodeList(encodeEntry: t -> Json, entries: List[t]): Json =
        JArray(List.map(encodeEntry, entries) |> List.toVector)

    /// JSON array を `List[T]` として decode する。要素のいずれかが None なら全体 None。
    pub def decodeList(decodeEntry: Json -> Option[t], element: Json):
            Option[List[t]] =
        match element {
            case JArray(items) =>
                List.foldRight(item -> acc ->
                    Option.flatMap(soFar ->
                        decodeEntry(item) |> Option.map(decoded -> decoded :: soFar),
                        acc),
                    Some(Nil),
                    Vector.toList(items))
            case _ => None
        }

    // ════════════════════════════════════════════════════════
    // Vec2 の round-trip (offset / scale の defensive default を含む)
    // ════════════════════════════════════════════════════════

    /// `{x: Float, y: Float}` の Vec2 を JSON object に encode する。
    pub def encodeVec2(vec: Vec2.Vec2): Json =
        JObject(Map#{
            "x" => JNumber(floatToBd(vec#x)),
            "y" => JNumber(floatToBd(vec#y))
        })

    /// JSON object を Vec2 に decode する。x/y どちらか欠落でも 0.0 で補完。
    pub def decodeVec2(element: Json): Option[Vec2.Vec2] =
        match element {
            case JObject(obj) =>
                let x = Map.get("x", obj) |> Option.flatMap(expectFloat)
                          |> Option.getWithDefault(0.0);
                let y = Map.get("y", obj) |> Option.flatMap(expectFloat)
                          |> Option.getWithDefault(0.0);
                Some({x = x, y = y})
            case _ => None
        }

    /// `Option[Json]` を Vec2 に。欠落 / 不正なら `(defaultValue, defaultValue)`。
    /// `offset` (default 0.0) / `scale` (default 1.0) の defensive default で使う。
    pub def decodeVec2OrDefault(optElement: Option[Json], defaultValue: Float64):
            Vec2.Vec2 =
        match optElement {
            case None          => {x = defaultValue, y = defaultValue}
            case Some(element) => match decodeVec2(element) {
                case Some(value) => value
                case None        => {x = defaultValue, y = defaultValue}
            }
        }

    // ════════════════════════════════════════════════════════
    // fail-open ヘルパ: キーが無い・型が違うときは黙って fallback
    // 設定ファイルの読み込みで、書き手のミスがゲームを止めないようにする
    // ════════════════════════════════════════════════════════

    /// object から `key` を Float64 として読む。無い・数値でなければ `fallback`。
    pub def floatOr(key: String, fallback: Float64, obj: Map[String, Json]): Float64 =
        Map.get(key, obj) |> Option.flatMap(expectFloat) |> Option.getWithDefault(fallback)

    /// object から `key` を Int32 として読む。無い・整数でなければ `fallback`。
    pub def intOr(key: String, fallback: Int32, obj: Map[String, Json]): Int32 =
        Map.get(key, obj) |> Option.flatMap(expectInt) |> Option.getWithDefault(fallback)

    /// object から `key` を String として読む。無い・文字列でなければ `fallback`。
    pub def stringOr(key: String, fallback: String, obj: Map[String, Json]): String =
        Map.get(key, obj) |> Option.flatMap(expectString) |> Option.getWithDefault(fallback)

    /// object から `key` を Bool として読む。無い・真偽値でなければ `fallback`。
    pub def boolOr(key: String, fallback: Bool, obj: Map[String, Json]): Bool =
        Map.get(key, obj) |> Option.flatMap(expectBool) |> Option.getWithDefault(fallback)
}
