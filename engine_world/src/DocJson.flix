// DocJson — Doc（*.kind.json）を読むときの JSON 道具箱。parse / デコード補助（atNode・jsonError・
// getAtKey 系）と、壊れた JSON を既定値へ落とす fail-open 読み込み（loadOr・checkVersion）を持つ。
// 境界: 値 ⇄ Json の純変換は JsonCodec、Doc 1 種ごとの型と読み書きは各 *Doc モジュールの責務。
// 注意: flix-json 互換の呼び出し形（`getAtKey(Root, ...)` 等）を残している。flix-json はエラーに
//   パス接頭辞 (`Root`) を持たせるが、`Util.Json` は decode 時に内部でパスを構築するため、
//   呼び出し側が渡す接頭辞は捨てる。
//
// 対応する呼び出し形:
//   - `getAtKey(Root, key, map)` / `getAtKeyOpt(...)`
//   - `jsonError(Root, Set#{...})`
//   - `parse(text)` (Option 返し)
pub mod DocJson {
    use IoError.IoError
    use IoError.ErrorKind
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray}
    use Util.Json.JsonError
    use Util.Json.JsonError.JsonError.Decode
    use Util.Json.JsonError.DecodeErrorKind.TypeMismatch
    use Util.Json.JsonPath
    use Util.Json.FromJson.FromJson

    /// flix-json `Json.Path.Path.Root` の代替。`Util.Json` ではパス接頭辞を使わないので
    /// 値としては無意味だが、呼び出し形 `(Root, key, map)` を保つためのプレースホルダ。
    pub enum PathTag { case Root }

    /// `Json.FromJson.getAtKey(Root, key, map)` 互換。map を JObject に包んで委譲。
    /// キーが無ければ `Err`（MissingKey）。
    pub def getAtKey(_p: PathTag, key: String, m: Map[String, Json]): Result[JsonError, a] \ {} with FromJson[a] =
        Util.Json.FromJson.decodeAtKey(key, JObject(m))

    /// `Json.FromJson.getAtKeyOpt(Root, key, map)` 互換。
    /// キー欠落で `Ok(None)`・存在&デコード可で `Ok(Some)`・型不一致で `Err`
    /// （flix-json と同セマンティクス）。
    pub def getAtKeyOpt(_p: PathTag, key: String, m: Map[String, Json]): Result[JsonError, Option[a]] \ {} with FromJson[a] =
        Util.Json.FromJson.decodeAtKeyOpt(key, JObject(m))

    /// `JsonError(Root, Set#{...})` 互換。説明文字列群を 1 つの TypeMismatch にまとめる。
    pub def jsonError(_p: PathTag, msgs: Set[String]): JsonError =
        Decode(JsonPath.empty(), TypeMismatch(String.intercalate("; ", Set.toList(msgs))))

    /// flix-json `Json.Parse.parse` 互換（Option 返し）。
    /// `Util.Json.parse` は `Result` 返しなので Option に変換する。
    pub def parse(s: String): Option[Json] =
        Util.Json.parse(s) |> Result.toOption

    /// version が無いか 1 なら OK。それ以外は docName 入りの文で断る。
    pub def checkVersion(docName: String, top: Map[String, Json]): Result[JsonError, Unit] =
        match (getAtKeyOpt(PathTag.Root, "version", top): Result[JsonError, Option[Int32]]) {
            case Err(e)      => Err(e)
            case Ok(None)    => Ok(())
            case Ok(Some(1)) => Ok(())
            case Ok(Some(v)) => Err(jsonError(PathTag.Root, Set#{"unsupported ${docName} version ${v} (supported: 1)"}))
        }

    /// テキストを JSON オブジェクトとして読み、中身の Map から Doc を組む。
    /// JSON でない・オブジェクトでないときは None（各欄の欠けは fromRoot 側が既定へ落とす）。
    /// Doc 層の `fromJson` はこれ 1 行で書ける。
    pub def decodeObject(fromRoot: Map[String, Json] -> a \ ef, text: String): Option[a] \ ef =
        parse(String.trim(text))
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(fromRoot)

    /// path の Doc を読む。読めない・壊れているときは fallback（fail-open）。
    /// 「書き損じで画面が壊れるより、保存し直せる方を選ぶ」という Doc 規約の実体で、
    /// 外の世界に触る手続き（ファイルを開く・効果をハンドラで受ける）をここ 1 箇所に閉じ込める。
    /// ファイルが無いときは何も知らせず既定へ落とす（任意 Doc の正常系）。ファイルが有るのに
    /// 読めないときだけ標準エラーへ 1 行知らせる — 何も知らせないと「保存したのに
    /// 効かない」の原因が追えない。
    pub def loadOr(decode: String -> Option[a] \ ef, fallback: a, path: String): a \ ef + Fs.FileRead =
        let readResult = run { Fs.ReadFile.read(path) } with Fs.ReadFile.runWithFileRead;
        match readResult {
            case Err(IoError(ErrorKind.NotFound, _)) => fallback
            case Err(error) => warnFellBack(fallback, path, "ファイルを読めません（${error}）")
            case Ok(text) => match decode(text) {
                case Some(doc) => doc
                case None      => warnFellBack(fallback, path, "JSON として読めないか形が違います")
            }
        }

    /// 既定値へ替えた事実を 1 行知らせてから fallback を返す。呼ばれるのは読み込み・
    /// リロード時だけで毎フレームは通らない。
    def warnFellBack(fallback: a, path: String, reason: String): a =
        let _ = Log.fellBack("doc", path, "丸ごと既定値", reason);
        fallback

    /// path のファイルを読んで JSON にする。読めない・崩れているときは Err で返す。
    pub def readJson(path: String): Result[JsonError, Json] \ Fs.FileRead =
        let content = run { Fs.ReadFile.read(path) } with Fs.ReadFile.runWithFileRead;
        content
            |> Result.mapErr(readError -> jsonError(PathTag.Root, Set#{"failed to read: ${readError}"}))
            |> Result.flatMap(text -> parse(String.trim(text))
                |> Option.toOk(jsonError(PathTag.Root, Set#{"JSON parse failed: ${path}"})))

    /// JSON オブジェクトなら中身の Map を返す。違えば label 入りの文で断る。
    pub def asObject(label: String, json: Json): Result[JsonError, Map[String, Json]] =
        match json {
            case JObject(m) => Ok(m)
            case _          => Err(jsonError(PathTag.Root, Set#{"${label} must be a JSON object"}))
        }

    /// key の数値（必須）。
    pub def numAt(key: String, m: Map[String, Json]): Result[JsonError, Float64] =
        (getAtKey(PathTag.Root, key, m): Result[JsonError, Float64])

    /// key の数値（無ければ fallback）。
    pub def numOr(key: String, fallback: Float64, m: Map[String, Json]): Result[JsonError, Float64] =
        (getAtKeyOpt(PathTag.Root, key, m): Result[JsonError, Option[Float64]])
            |> Result.map(Option.getWithDefault(fallback))

    /// field のオブジェクト（名前 → 配列）を、要素パーサで名前ごとのリストに読む。
    /// 要素のエラーには "field.名前[i]" の位置が付き、"//" で始まる名前はコメントとして飛ばす。
    pub def sheetAt(field: String, itemAt: Json -> Result[JsonError, a],
                    top: Map[String, Json]): Result[JsonError, Map[String, List[a]]] =
        match Map.get(field, top) {
            case Some(JObject(m)) =>
                m |> Map.toList
                  |> List.filter(entry -> { let (name, _) = entry; not String.startsWith(prefix = "//", name) })
                  |> Result.traverse(entry -> {
                        let (name, json) = entry;
                        sheetItemsAt(field, name, itemAt, json) |> Result.map(items -> (name, items))
                     })
                  |> Result.map(List.toMap)
            case _ => Err(jsonError(PathTag.Root, Set#{"${field} must be an object of name -> lists"}))
        }

    /// 名前 1 個ぶんの配列を要素パーサで読む。要素のエラーに "field.名前[i]" の位置を付ける。
    def sheetItemsAt(field: String, name: String, itemAt: Json -> Result[JsonError, a],
                     json: Json): Result[JsonError, List[a]] =
        match json {
            case JArray(arr) =>
                Result.traverse(entry -> {
                    let (i, j) = entry;
                    atNode("${field}.${name}[${i}]", itemAt(j))
                }, List.zipWithIndex(Vector.toList(arr)))
            case _ => Err(jsonError(PathTag.Root, Set#{"${field} '${name}' must be an array"}))
        }

    /// エラーにノードの名前パス（例: "gallery/row1/box"）を前置する。ドキュメント木のパーサが
    /// 「どのノードで失敗したか」を編集者へ伝える口。子のエラーは子が既にタグ済みなので、
    /// 呼び側はノード自身のフィールド解析だけを包むこと（二重前置を避ける）。
    pub def atNode(path: String, r: Result[JsonError, a]): Result[JsonError, a] =
        Result.mapErr(e -> Decode(JsonPath.empty(), TypeMismatch("at ${path}: ${describe(e)}")), r)

    /// エラーを編集者向けの一文にする。jsonError / atNode が詰めた文章は `TypeMismatch` のコンテナを
    /// 借りているだけなので、コンテナの定型句（"type mismatch: expected"）を剥がして中身だけ返す。
    /// Util.Json 由来の本物の型不一致（メッセージが "Float64" 等の型名 1 語）まで裸にすると
    /// 文脈が消えるので、空白を含む文章のときだけ剥がす。
    pub def describe(e: JsonError): String =
        match e {
            case Decode(_, TypeMismatch(msg)) =>
                if (String.contains(substr = " ", msg)) msg else "${e}"
            case other => "${other}"
        }
}
