// SaveFormat — セーブの JSON を「形式の名前・版・中身」で包み、古い版を今の形へ書き換えてから渡す。
// 形を変えた時は版を上げ、版 n → n+1 の書き換え（SaveMigration）を登録すれば、ゲームはいつも最新の形の
// JSON だけを読めばよい。版が上がる前の中身は、初めて書く時に控え（`<道>.v<版>.bak`）へ 1 つ残す。
// 包みには書いたゲームの版（`withGameVersion` の字）も `gameVersion` として残せる。
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

    /// セーブ形式。`make` で作り `withMigration` / `withUnwrappedVersion` / `withGameVersion` で足す。
    pub type alias Format = FormatData

    // WhyNot: record をそのまま出さない — 版と書き換えの並びの食い違い（今の版より先の書き換え・0 より小さい版）を作れてしまう。
    enum FormatData {
        case FormatData({
            name = String,
            version = Int32,
            migrations = Map[Int32, Json -> Result[String, Json]],
            unwrappedVersion = Option[Json -> Int32],
            gameVersion = Option[String]
        })
    }

    def fieldsOf(format: Format): { name = String, version = Int32, migrations = Map[Int32, Json -> Result[String, Json]], unwrappedVersion = Option[Json -> Int32], gameVersion = Option[String] } =
        match format {
            case FormatData.FormatData(fields) => fields
        }

    /// 名前 `name`・今の版 `version` のセーブ形式。書き換えはまだ無い。版は 1 から（1 より小さければ 1 にして 1 行言う）。
    pub def make(name: String, version: Int32): Format =
        let fields = { name = name, version = Int32.max(1, version), migrations = Map.empty(), unwrappedVersion = None, gameVersion = None };
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

    /// 書くセーブの包みに `gameVersion` として残す、ゲームの版（遊ぶ人が見る "1.4.0" など）。字は `trimGameVersion` で整える。
    /// 字はゲームが持ち、engine は project.json も git も読まない（上げ忘れはゲームのテストで flix.toml と照らす）。
    /// 空の字は入れずに 1 行言う。書き換えの版（`make` の版）とは別物で、セーブの形が変わらない更新でも上げる。
    // WhyNot: engine が project.json や git の sha から自動で入れない — ブラウザの束に flix.toml も git も無く、
    //   sha は make run・書き出し・配布物の 3 か所に焼き込む口が要り、遊ぶ人に見せる字にもならない。
    pub def withGameVersion(gameVersion: String, format: Format): Format =
        match trimGameVersion(gameVersion) {
            case Some(trimmed) => FormatData.FormatData({ gameVersion = Some(trimmed) | fieldsOf(format) })
            case None => Log.warnThen("[SaveFormat] ${getName(format)} のゲームの版が空なので gameVersion は付けない", format)
        }

    /// ゲームの版の字の前後の空白を落とす。空なら None。
    pub def trimGameVersion(gameVersion: String): Option[String] =
        let trimmed = String.trim(gameVersion);
        if (String.isEmpty(trimmed)) None else Some(trimmed)

    /// `withGameVersion` で渡したゲームの版。渡していなければ None。
    pub def getGameVersion(format: Format): Option[String] = fieldsOf(format)#gameVersion

    /// 形式の名前。
    pub def getName(format: Format): String = fieldsOf(format)#name

    /// 今の版（書く時に付ける版）。
    pub def getVersion(format: Format): Int32 = fieldsOf(format)#version

    /// 中身 `data` を今の版の包み `{"format", "version", "data"}` に入れる。`withGameVersion` があれば `"gameVersion"` も足す。
    // WhyNot: ゲームの版が無い時に "gameVersion": null や "" を書かない — 版の分からないセーブを欄の無い古いセーブと同じ扱いにして、読む側の場合分けを 1 つにする。
    pub def wrap(data: Json, format: Format): Json =
        let base = Map#{
            "format" => JString(getName(format)),
            "version" => JNumber(JsonCodec.intToBd(getVersion(format))),
            "data" => data
        };
        match getGameVersion(format) {
            case Some(gameVersion) => JObject(Map.insert("gameVersion", JString(gameVersion), base))
            case None => JObject(base)
        }

    /// 包みの欄。`gameVersion` は無くても包みとして読む。
    type alias Envelope = { formatName = String, version = Int32, data = Json, gameVersion = Option[String] }

    def envelopeOf(json: Json): Option[Envelope] =
        JsonCodec.expectObject(json) |> Option.flatMap(obj ->
            forM (
                formatName <- Map.get("format", obj) |> Option.flatMap(JsonCodec.expectString);
                version <- Map.get("version", obj) |> Option.flatMap(JsonCodec.expectInt);
                data <- Map.get("data", obj)
            ) yield { formatName = formatName, version = version, data = data,
                      gameVersion = Map.get("gameVersion", obj) |> Option.flatMap(JsonCodec.expectString) })

    /// 読んだセーブの包みにある、書いたゲームの版（最後に書いた版）。包みでない・`gameVersion` の無い古い包み・字でない時は None。
    /// 形式の名前は照らさない（別の形式の包みでも版を返す。報告に出すだけなので、どの形式かは問わない）。
    /// 不具合の報告・見本の出どころ・未来の版を断る時の文言に出すための物。
    // WhyNot: この字で読み方を分けない — 形の違いは包みの版と書き換えが持つ。ゲームの版で分けると、
    //   形の変わらない更新ごとに分岐が増え、gameVersion の無い古いセーブを読めない道ができる。
    pub def gameVersionOf(json: Json): Option[String] =
        envelopeOf(json) |> Option.flatMap(envelope -> envelope#gameVersion)

    /// 包みなら (版, 中身)。包みでなければ None。名前の違う包みは Err。
    def unwrap(json: Json, format: Format): Result[String, Option[(Int32, Json)]] =
        match envelopeOf(json) {
            case None => Ok(None)
            case Some(envelope) =>
                if (envelope#formatName == getName(format)) Ok(Some((envelope#version, envelope#data)))
                else Err("別の形式のセーブ（${envelope#formatName}・読もうとしたのは ${getName(format)}）")
        }

    /// `gameVersion` があれば「・<版> で書いた」、無ければ空。
    def gameVersionNote(json: Json): String =
        gameVersionOf(json) |> Option.map(gameVersion -> "・${gameVersion} で書いた") |> Option.getWithDefault("")

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
        openEnvelope(json, format) |> Result.flatMap(match (version, data) -> migrateFrom(version, data, gameVersionNote(json), format))

    /// セーブの字を読んで `decode` する。JSON として読めない字は Err。
    pub def decodeText(text: String, format: Format): Result[String, Json] =
        parseText(text) |> Result.flatMap(json -> decode(json, format))

    def parseText(text: String): Result[String, Json] =
        DocJson.parse(text) |> Option.toOk("JSON として読めない")

    def migrateFrom(version: Int32, data: Json, note: String, format: Format): Result[String, Json] =
        let fields = fieldsOf(format);
        if (version == fields#version) Ok(data)
        else if (version > fields#version) Err("今より新しい版のセーブ（${version} 版${note}・このゲームは ${fields#version} 版まで）")
        else match Map.get(version, fields#migrations) {
            case None => Err("${version} 版 → ${version + 1} 版の書き換えが無い")
            case Some(migrate) =>
                migrate(data)
                    |> Result.mapErr(reason -> "${version} 版 → ${version + 1} 版の書き換えに失敗: ${reason}")
                    |> Result.flatMap(next -> migrateFrom(version + 1, next, note, format))
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
                let parsed = parseText(text) |> Result.toOption;
                let found = parsed |> Option.flatMap(json -> versionOf(json, format));
                let note = parsed |> Option.map(gameVersionNote) |> Option.getWithDefault("");
                match found {
                    case None => Ok(())
                    case Some(version) =>
                        if (version > getVersion(format)) Err("${path} は今より新しい版（${version} 版${note}）なので上書きしない")
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
