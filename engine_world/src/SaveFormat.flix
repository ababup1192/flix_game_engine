// SaveFormat — セーブの JSON を「形式の名前・版・中身」で包み、古い版を今の形へ書き換えてから渡す。
// 形を変えた時は版を上げ、版 n → n+1 の書き換え（SaveMigration）を登録すれば、ゲームはいつも最新の形の
// JSON だけを読めばよい。版が上がる前の中身は、初めて書く時に控え（`<道>.v<版>.bak`）へ 1 つ残す。
// 利用例: 版 3 のセーブ形式を作り、v1→v2・v2→v3 の書き換えを登録して load / save する /
//   テストで test/save-samples の見本を全部読めるか確かめる（checkSamples）。
// 注意: 読み書きは Fs.FileRead / Fs.FileWrite の上だけで書く。ブラウザ版は WebFs が saves/ の下を
//   localStorage へ回すので、道は saves/ の下に置く（控えも同じフォルダに並ぶ）。
//   値と JSON の変換は Saveable（Persistence）のまま。ここは包みと版だけを持つ。
pub mod SaveFormat {

    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber}

    /// 版 `fromVersion` の中身を版 `fromVersion + 1` の形へ書き換える。
    pub type alias SaveMigration = { fromVersion = Int32, migrate = Json -> Result[String, Json] }

    /// セーブ形式。`make` で作り `withMigration` / `withUnwrappedVersion` で足す。
    pub type alias Format = FormatData

    // WhyNot: record をそのまま出さない — 版と書き換えの並びの食い違い（今の版より先の書き換え・0 より小さい版）を作れてしまう。
    enum FormatData {
        case FormatData({
            name = String,
            version = Int32,
            migrations = Map[Int32, Json -> Result[String, Json]],
            unwrappedVersion = Option[Json -> Int32]
        })
    }

    def fieldsOf(format: Format): { name = String, version = Int32, migrations = Map[Int32, Json -> Result[String, Json]], unwrappedVersion = Option[Json -> Int32] } =
        match format {
            case FormatData.FormatData(fields) => fields
        }

    /// 名前 `name`・今の版 `version` のセーブ形式。書き換えはまだ無い。版は 1 から（1 より小さければ 1 にして 1 行言う）。
    pub def make(name: String, version: Int32): Format =
        let fields = { name = name, version = Int32.max(1, version), migrations = Map.empty(), unwrappedVersion = None };
        if (version < 1) Log.warnThen("[SaveFormat] ${name} の版 ${version} は 1 にした（版は 1 から）", FormatData.FormatData(fields))
        else FormatData.FormatData(fields)

    /// 版 `fromVersion` → `fromVersion + 1` の書き換えを足す。`fromVersion` は 0 以上・今の版より小さいこと。
    /// 外れた版の書き換えは入れずに 1 行言う（その版を読むと「書き換えが無い」の Err になり、見本のテストで止まる）。
    /// 同じ版を 2 度足すと後の物で置き換え、1 行言う。
    // WhyNot: 外れた版で bug! しない — 形式は起動の時にも組まれ、セーブを読まずに遊べる所まで止めることになる。
    pub def withMigration(fromVersion: Int32, migrate: Json -> Result[String, Json], format: Format): Format =
        let fields = fieldsOf(format);
        let added = FormatData.FormatData({ migrations = Map.insert(fromVersion, migrate, fields#migrations) | fields });
        if (fromVersion < 0 or fromVersion >= fields#version)
            Log.warnThen("[SaveFormat] ${fields#name} の ${fromVersion} 版からの書き換えは入れない（0〜${fields#version - 1} 版から）", format)
        else if (Map.memberOf(fromVersion, fields#migrations))
            Log.warnThen("[SaveFormat] ${fields#name} の ${fromVersion} 版の書き換えを 2 度足した（後の物を使う）", added)
        else added

    /// 包みの無い古いセーブ（中身の JSON だけ）を何版として読むかを決める関数を渡す。
    /// 渡さなければ包みの無いセーブは読めない（Err）。
    pub def withUnwrappedVersion(versionOf: Json -> Int32, format: Format): Format =
        FormatData.FormatData({ unwrappedVersion = Some(versionOf) | fieldsOf(format) })

    /// 形式の名前。
    pub def getName(format: Format): String = fieldsOf(format)#name

    /// 今の版（書く時に付ける版）。
    pub def getVersion(format: Format): Int32 = fieldsOf(format)#version

    /// 中身 `data` を今の版の包み `{"format", "version", "data"}` に入れる。
    pub def wrap(data: Json, format: Format): Json =
        JObject(Map#{
            "format" => JString(getName(format)),
            "version" => JNumber(JsonCodec.intToBd(getVersion(format))),
            "data" => data
        })

    /// 包みなら (版, 中身)。包みでなければ None。名前の違う包みは Err。
    def unwrap(json: Json, format: Format): Result[String, Option[(Int32, Json)]] =
        let header = JsonCodec.expectObject(json) |> Option.flatMap(obj ->
            forM (
                formatName <- Map.get("format", obj) |> Option.flatMap(JsonCodec.expectString);
                version <- Map.get("version", obj) |> Option.flatMap(JsonCodec.expectInt);
                data <- Map.get("data", obj)
            ) yield (formatName, version, data));
        match header {
            case None => Ok(None)
            case Some((formatName, version, data)) =>
                if (formatName == getName(format)) Ok(Some((version, data)))
                else Err("別の形式のセーブ（${formatName}・読もうとしたのは ${getName(format)}）")
        }

    /// 読んだ JSON の (版, 中身)。包みが無ければ `withUnwrappedVersion` の関数で版を決める。
    def openEnvelope(json: Json, format: Format): Result[String, (Int32, Json)] =
        unwrap(json, format) |> Result.flatMap(found -> match found {
            case Some(pair) => Ok(pair)
            case None => match fieldsOf(format)#unwrappedVersion {
                case Some(versionOf) => Ok((versionOf(json), json))
                case None => Err("包みの無いセーブ（${getName(format)} は包みの無い版の読み方を持たない）")
            }
        })

    /// 読んだ JSON の版。包みも読み方も無い・名前の違う包みは None。
    pub def versionOf(json: Json, format: Format): Option[Int32] =
        openEnvelope(json, format) |> Result.toOption |> Option.map(fst)

    /// 読んだ JSON を今の版の中身へ書き換えて返す。今より新しい版・書き換えの抜け・書き換えの失敗は Err。
    pub def decode(json: Json, format: Format): Result[String, Json] =
        openEnvelope(json, format) |> Result.flatMap(match (version, data) -> migrateFrom(version, data, format))

    /// セーブの字を読んで `decode` する。JSON として読めない字は Err。
    pub def decodeText(text: String, format: Format): Result[String, Json] =
        parseText(text) |> Result.flatMap(json -> decode(json, format))

    def parseText(text: String): Result[String, Json] =
        DocJson.parse(text) |> Option.toOk("JSON として読めない")

    def migrateFrom(version: Int32, data: Json, format: Format): Result[String, Json] =
        let fields = fieldsOf(format);
        if (version == fields#version) Ok(data)
        else if (version > fields#version) Err("今より新しい版のセーブ（${version} 版・このゲームは ${fields#version} 版まで）")
        else match Map.get(version, fields#migrations) {
            case None => Err("${version} 版 → ${version + 1} 版の書き換えが無い")
            case Some(migrate) =>
                migrate(data)
                    |> Result.mapErr(reason -> "${version} 版 → ${version + 1} 版の書き換えに失敗: ${reason}")
                    |> Result.flatMap(next -> migrateFrom(version + 1, next, format))
        }

    /// `path` のセーブを今の版の中身にして読む。ファイルが無ければ Ok(None)（初めての時は正常）。
    pub def load(path: String, format: Format): Result[String, Option[Json]] \ Fs.FileRead =
        match Fs.FileRead.read(path) {
            case Err(IoError.IoError(IoError.ErrorKind.NotFound, _)) => Ok(None)
            case Err(error) => Err("${path} を読めない: ${error}")
            case Ok(text) => decodeText(text, format) |> Result.map(Some) |> Result.mapErr(reason -> "${path}: ${reason}")
        }

    /// 版 `version` の控えの道（`<path>.v<version>.bak`）。セーブと同じフォルダに並ぶ。
    pub def backupPath(path: String, version: Int32): String = "${path}.v${version}.bak"

    /// 中身 `data` を今の版で包んで `path` に書く。
    /// 今ある `path` が古い版なら、書く前にその字を `backupPath` へ写す（同じ版の控えが既にあれば写さない）。
    /// 今ある `path` が今より新しい版なら書かずに Err（新しいゲームで作ったセーブを消さない）。
    pub def save(path: String, data: Json, format: Format): Result[String, Unit] \ Fs.FileRead + Fs.FileWrite =
        backupBeforeOverwrite(path, format)
            |> Result.flatMap(_ -> writeText(path, Util.Json.toPrettyString(2, wrap(data, format))))

    // WhyNot: JSON として読めない・形式の名前が違う今のファイルで書くのを止めない — 止めると壊れたセーブから二度と書けなくなる。
    def backupBeforeOverwrite(path: String, format: Format): Result[String, Unit] \ Fs.FileRead + Fs.FileWrite =
        match Fs.FileRead.read(path) {
            case Err(_) => Ok(())
            case Ok(text) =>
                let found = parseText(text) |> Result.toOption |> Option.flatMap(json -> versionOf(json, format));
                match found {
                    case None => Ok(())
                    case Some(version) =>
                        if (version > getVersion(format)) Err("${path} は今より新しい版（${version} 版）なので上書きしない")
                        else if (version == getVersion(format)) Ok(())
                        else writeBackupOnce(backupPath(path, version), text)
                }
        }

    // WhyNot: 控えを上書きしない — 同じ版から 2 度上がることは無く、2 度目の字は既に新しい版で書いた後の物になりうる。
    def writeBackupOnce(backup: String, text: String): Result[String, Unit] \ Fs.FileRead + Fs.FileWrite =
        match Fs.FileRead.read(backup) {
            case Ok(_) => Ok(())
            case Err(_) => writeText(backup, text)
        }

    def writeText(path: String, text: String): Result[String, Unit] \ Fs.FileWrite =
        Fs.FileWrite.write({str = text}, path) |> Result.mapErr(error -> "${path} に書けない: ${error}")

    /// `Saveable` の値を今の版で包んで `path` に書く（控えと上書きの判断は `save` と同じ）。
    pub def saveValue(path: String, value: a, format: Format): Result[String, Unit] \ Fs.FileRead + Fs.FileWrite with Saveable[a] =
        save(path, Saveable.toJson(value), format)

    /// `path` を今の版の中身にしてから `Saveable` の値に戻す。ファイルが無ければ Ok(None)。
    pub def loadValue(path: String, format: Format): Result[String, Option[a]] \ Fs.FileRead with Saveable[a] =
        load(path, format) |> Result.flatMap(found -> match found {
            case None => Ok(None)
            case Some(data) => Saveable.fromJson(data) |> Option.map(Some) |> Option.toOk("${path}: 今の版の中身を値に戻せない")
        })

    /// フォルダ `dir` のセーブの見本（*.json）を全部、書き換えを通してから `read` に渡し、
    /// Ok を返さなかった見本の (ファイル名, 理由) を返す（全部読めれば Nil）。見本が 1 つも無いのも失敗に数える。
    pub def checkSamples(dir: String, read: Json -> Result[String, a], format: Format): List[(String, String)] \ Fs.DirList + Fs.FileRead =
        match Fs.DirList.list(dir) {
            case Err(error) => (dir, "フォルダを読めない: ${error}") :: Nil
            case Ok(names) =>
                let samples = names |> List.filter(String.endsWith({suffix = ".json"})) |> Sort.sortStableBy(name -> name);
                if (List.isEmpty(samples)) (dir, "*.json の見本が 1 つも無い") :: Nil
                else samples |> List.filterMap(name -> checkSample(dir, name, read, format))
        }

    def checkSample(dir: String, name: String, read: Json -> Result[String, a], format: Format): Option[(String, String)] \ Fs.FileRead =
        let outcome = Fs.FileRead.read("${dir}/${name}")
            |> Result.mapErr(error -> "読めない: ${error}")
            |> Result.flatMap(text -> decodeText(text, format))
            |> Result.flatMap(data -> read(data) |> Result.map(_ -> ()));
        match outcome {
            case Ok(_) => None
            case Err(reason) => Some((name, reason))
        }
}
