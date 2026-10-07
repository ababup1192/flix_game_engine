// Schema — リソース(ゲームデータ JSON)の形を宣言する公式スキーマ方言。
// データの形(type / required / default)はゲームも検証に使うが、見せ方(widget)はエディタ専用でエンジンは中身を開けない封筒として運ぶ。
// World には catalog の id を持たせ能力値は参照時に引く(値のコピーを埋めない) — 再読込がスポーン済みの相手にも自然に効く。
// 未知の type タグ・kind は黙って通さず Err にする(綴りミスが「フォームに出ない」沈黙事故になるのを防ぐ)。custom だけが明示的な逃げ道。
pub mod Schema {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber, JBool, JArray}

    // ════════════════════════════════════════════════════════
    // 型
    // ════════════════════════════════════════════════════════

    /// フィールドの値の形。JSON では文字列タグ("int" 等)か object 形({"ref": ...} 等)で書く。
    pub enum FieldType {
        // 自由テキスト
        case TextT
        // 整数
        case IntT
        // 実数
        case FloatT
        // 真偽値
        case BoolT
        // 色
        case ColorT
        // 2 次元ベクトル
        case Vec2T
        // テクスチャ(画像アセットへのパス)
        case TextureT
        // 決まった選択肢から 1 つ選ぶ
        case EnumT(List[String])
        // 別セクション(catalog)の id を参照する
        case RefT(String)
        // 同じ形の値の並び
        case ListT(FieldType)
        // 入れ子のレコード(フィールド名 → フィールド宣言)
        case RecordT(Map[String, Field])
        // エンジンは解釈しない、エディタ拡張用のタグ
        case CustomT(String)
    }

    /// フィールド 1 個の宣言。
    /// fieldType = 値の形 / label = 表示名 / order = 並び順 /
    /// widget = 見せ方(エンジン非解釈の不透明 Json) / required = 必須か(既定 false) /
    /// default = 既定値(Json のまま保持) / min・max・step = 数値の制約。
    /// 制約(required / default / min / max / step)は保持と提供のみで、検証はまだしない。
    pub type alias Field = {
        fieldType = FieldType,
        label     = Option[String],
        order     = Option[Int32],
        widget    = Option[Json],
        required  = Bool,
        default   = Option[Json],
        min       = Option[Float64],
        max       = Option[Float64],
        step      = Option[Float64]
    }

    /// セクションの入れ物の形。catalog = id → レコードの辞書 / list = レコードの配列 /
    /// record = レコード 1 枚。
    pub enum SectionKind with Eq, ToString {
        case Catalog
        case RecordList
        case Record
    }

    /// セクション 1 個の宣言。kind = 入れ物の形 / fields = フィールド名 → フィールド宣言。
    pub type alias Section = {
        kind   = SectionKind,
        fields = Map[String, Field]
    }

    /// スキーマ全体。version = 方言のバージョン(既定 1) / sections = セクション名 → セクション宣言。
    pub type alias Schema = {
        version  = Int32,
        sections = Map[String, Section]
    }

    // ════════════════════════════════════════════════════════
    // 読み込み (JSON → Schema)
    // ════════════════════════════════════════════════════════

    /// スキーマ JSON を読み取る。形が仕様に合わないときは、どのセクション・どのフィールドで
    /// 何が悪いかを平易な日本語 1 行で返す。
    pub def fromJson(json: Json): Result[String, Schema] =
        forM (
            top      <- asObject("スキーマの最上位", json);
            version  <- versionOf(top);
            sections <- sectionsOf(top)
        ) yield { version = version, sections = sections }

    /// path のスキーマファイルを読んで Schema にする。読めない・崩れている・形が違う、の
    /// どの段階で失敗したかがわかる文で断る。
    pub def load(path: String): Result[String, Schema] \ Fs.FileRead =
        let readResult = run { Fs.ReadFile.read(path) } with Fs.ReadFile.runWithFileRead;
        match readResult {
            case Err(e)      => Err("スキーマファイルが読めません (${path}): ${e}")
            case Ok(content) =>
                DocJson.parse(String.trim(content))
                    |> Option.toOk("スキーマの JSON が崩れています (${path})")
                    |> Result.flatMap(fromJson)
        }

    /// ゲームコードが期待するフィールド名集合と、スキーマのセクションを突き合わせる
    /// (起動時 fail-fast 用)。過不足を「無い: xxx / 余分: yyy」の平易な 1 行で返す。
    pub def checkSection(sectionKey: String, expected: Set[String], schema: Schema):
            Result[String, Unit] =
        match Map.get(sectionKey, schema#sections) {
            case None          => Err("セクション ${sectionKey} がスキーマにありません")
            case Some(section) =>
                let actual  = Map.keysOf(section#fields);
                let missing = Set.difference(expected, actual);
                let extras  = Set.difference(actual, expected);
                if (Set.isEmpty(missing) and Set.isEmpty(extras))
                    Ok(())
                else
                    Err("セクション ${sectionKey} のフィールドが合いません。${describeDiff(missing, extras)}")
        }

    /// version が無ければ 1。整数以外で書かれていたら断る。
    def versionOf(top: Map[String, Json]): Result[String, Int32] =
        match Map.get("version", top) {
            case None       => Ok(1)
            case Some(json) =>
                JsonCodec.expectInt(json) |> Option.toOk("version は整数で書いてください")
        }

    /// sections を読む。"//" で始まるセクション名は注釈として読み飛ばす。
    def sectionsOf(top: Map[String, Json]): Result[String, Map[String, Section]] =
        match Map.get("sections", top) {
            case None       => Err("スキーマの最上位に sections がありません")
            case Some(json) =>
                asObject("sections", json) |> Result.flatMap(entries -> entries
                    |> Map.toList
                    |> List.filter(entry -> { let (name, _) = entry; not isNote(name) })
                    |> Result.traverse(entry -> {
                        let (name, sectionJson) = entry;
                        decodeSection(name, sectionJson) |> Result.map(section -> (name, section))
                    })
                    |> Result.map(List.toMap))
        }

    /// セクション 1 個を読む。kind と fields の両方を必須にする —
    /// 綴りミスで欠けたまま「空のフォーム」が黙って出るのを防ぐため。
    def decodeSection(name: String, json: Json): Result[String, Section] =
        forM (
            obj    <- asObject("セクション ${name}", json);
            kind   <- kindOf(name, obj);
            fields <- match Map.get("fields", obj) {
                case None            => Err("セクション ${name} に fields がありません")
                case Some(fieldsJson) => decodeFields(name, fieldsJson)
            }
        ) yield { kind = kind, fields = fields }

    /// kind の 3 値(catalog / list / record)を読む。それ以外の綴りは断る。
    def kindOf(name: String, obj: Map[String, Json]): Result[String, SectionKind] =
        match Map.get("kind", obj) |> Option.flatMap(JsonCodec.expectString) {
            case Some("catalog") => Ok(SectionKind.Catalog)
            case Some("list")    => Ok(SectionKind.RecordList)
            case Some("record")  => Ok(SectionKind.Record)
            case Some(other)     =>
                Err("セクション ${name} の kind「${other}」は catalog / list / record のどれかにしてください")
            case None            =>
                Err("セクション ${name} に kind (catalog / list / record) がありません")
        }

    /// フィールド宣言の辞書を読む。"//" で始まるキーは注釈として読み飛ばす。
    /// path はエラーに出す位置(例: "spawns" や "spawns.sprite")。
    def decodeFields(path: String, json: Json): Result[String, Map[String, Field]] =
        asObject("${path} の fields", json) |> Result.flatMap(entries -> entries
            |> Map.toList
            |> List.filter(entry -> { let (key, _) = entry; not isNote(key) })
            |> Result.traverse(entry -> {
                let (key, fieldJson) = entry;
                decodeField("${path}.${key}", fieldJson) |> Result.map(field -> (key, field))
            })
            |> Result.map(List.toMap))

    /// フィールド 1 個を読む。widget と default は不透明 Json としてそのまま保持する。
    def decodeField(path: String, json: Json): Result[String, Field] =
        forM (
            obj       <- asObject("フィールド ${path}", json);
            typeJson  <- Map.get("type", obj) |> Option.toOk("フィールド ${path} に type がありません");
            fieldType <- decodeType(path, typeJson);
            label     <- optAt(JsonCodec.expectString, "文字列", path, "label", obj);
            order     <- optAt(JsonCodec.expectInt, "整数", path, "order", obj);
            required  <- optAt(JsonCodec.expectBool, "真偽値", path, "required", obj)
                             |> Result.map(Option.getWithDefault(false));
            minVal    <- optAt(JsonCodec.expectFloat, "数値", path, "min", obj);
            maxVal    <- optAt(JsonCodec.expectFloat, "数値", path, "max", obj);
            stepVal   <- optAt(JsonCodec.expectFloat, "数値", path, "step", obj)
        ) yield {
            fieldType = fieldType,
            label     = label,
            order     = order,
            widget    = Map.get("widget", obj),
            required  = required,
            default   = Map.get("default", obj),
            min       = minVal,
            max       = maxVal,
            step      = stepVal
        }

    /// type を読む。文字列タグと object 形のどちらでもない・知らない綴りは断る。
    def decodeType(path: String, json: Json): Result[String, FieldType] =
        match json {
            case JString(tag) => scalarType(path, tag)
            case JObject(m)   => shapedType(path, m)
            case _            =>
                Err("フィールド ${path} の type は文字列タグか {\"enum\": ...} 等の object で書いてください")
        }

    /// 文字列タグの type。7 種のどれでもなければ断る。
    def scalarType(path: String, tag: String): Result[String, FieldType] =
        match tag {
            case "text"    => Ok(FieldType.TextT)
            case "int"     => Ok(FieldType.IntT)
            case "float"   => Ok(FieldType.FloatT)
            case "bool"    => Ok(FieldType.BoolT)
            case "color"   => Ok(FieldType.ColorT)
            case "vec2"    => Ok(FieldType.Vec2T)
            case "texture" => Ok(FieldType.TextureT)
            case _         =>
                Err("フィールド ${path} の type「${tag}」は知らない型です (text / int / float / bool / color / vec2 / texture のどれか)")
        }

    /// object 形の type。注釈キーを除いてちょうど 1 個のキーで形を決める —
    /// 2 個以上はどの形か決められないので断る。
    def shapedType(path: String, m: Map[String, Json]): Result[String, FieldType] =
        let entries = Map.toList(m)
            |> List.filter(entry -> { let (key, _) = entry; not isNote(key) });
        match entries {
            case ("enum", json) :: Nil   =>
                enumChoices(path, json) |> Result.map(FieldType.EnumT)
            case ("ref", json) :: Nil    =>
                JsonCodec.expectString(json)
                    |> Option.map(FieldType.RefT)
                    |> Option.toOk("フィールド ${path} の ref は参照先セクション名の文字列で書いてください")
            case ("list", json) :: Nil   =>
                decodeType(path, json) |> Result.map(FieldType.ListT)
            case ("record", json) :: Nil =>
                decodeFields(path, json) |> Result.map(FieldType.RecordT)
            case ("custom", json) :: Nil =>
                JsonCodec.expectString(json)
                    |> Option.map(FieldType.CustomT)
                    |> Option.toOk("フィールド ${path} の custom はタグ名の文字列で書いてください")
            case (key, _) :: Nil          =>
                Err("フィールド ${path} の type のキー「${key}」は知らない形です (enum / ref / list / record / custom のどれか)")
            case _                        =>
                Err("フィールド ${path} の type の object はキー 1 個 (enum / ref / list / record / custom) で書いてください")
        }

    /// enum の選択肢(文字列の配列)を読む。
    def enumChoices(path: String, json: Json): Result[String, List[String]] =
        match json {
            case JArray(items) =>
                Vector.toList(items) |> Result.traverse(item ->
                    JsonCodec.expectString(item)
                        |> Option.toOk("フィールド ${path} の enum の選択肢は文字列で書いてください"))
            case _ => Err("フィールド ${path} の enum は文字列の配列で書いてください")
        }

    // ════════════════════════════════════════════════════════
    // 書き出し (Schema → JSON)
    // ════════════════════════════════════════════════════════

    /// Schema を JSON に戻す。fromJson と round-trip する(widget / default は原文どおり)。
    /// 省略可能な項目は None のとき書かない — 手書きファイルとの差分を最小に保つため。
    pub def toJson(schema: Schema): Json =
        JObject(Map#{
            "version"  => JNumber(JsonCodec.intToBd(schema#version)),
            "sections" => JObject(Map.map(encodeSection, schema#sections))
        })

    /// FieldType を JSON 表現に戻す。fromJson が受け取る形とちょうど対になる。
    pub def typeToJson(fieldType: FieldType): Json =
        match fieldType {
            case FieldType.TextT           => JString("text")
            case FieldType.IntT            => JString("int")
            case FieldType.FloatT          => JString("float")
            case FieldType.BoolT           => JString("bool")
            case FieldType.ColorT          => JString("color")
            case FieldType.Vec2T           => JString("vec2")
            case FieldType.TextureT        => JString("texture")
            case FieldType.EnumT(choices)  =>
                JObject(Map#{"enum" => JArray(List.map(JString, choices) |> List.toVector)})
            case FieldType.RefT(target)    => JObject(Map#{"ref" => JString(target)})
            case FieldType.ListT(inner)    => JObject(Map#{"list" => typeToJson(inner)})
            case FieldType.RecordT(fields) =>
                JObject(Map#{"record" => JObject(Map.map(encodeField, fields))})
            case FieldType.CustomT(tag)    => JObject(Map#{"custom" => JString(tag)})
        }

    /// セクション 1 個を JSON に戻す。
    def encodeSection(section: Section): Json =
        JObject(Map#{
            "kind"   => JString(kindTag(section#kind)),
            "fields" => JObject(Map.map(encodeField, section#fields))
        })

    /// SectionKind の JSON タグ。
    def kindTag(kind: SectionKind): String =
        match kind {
            case SectionKind.Catalog    => "catalog"
            case SectionKind.RecordList => "list"
            case SectionKind.Record     => "record"
        }

    /// フィールド 1 個を JSON に戻す。required は true のときだけ書く(既定 false と同義のため)。
    def encodeField(field: Field): Json =
        Map#{"type" => typeToJson(field#fieldType)}
            |> insertOpt("label", Option.map(JString, field#label))
            |> insertOpt("order", Option.map(v -> JNumber(JsonCodec.intToBd(v)), field#order))
            |> insertOpt("widget", field#widget)
            |> insertOpt("required", if (field#required) Some(JBool(true)) else None)
            |> insertOpt("default", field#default)
            |> insertOpt("min", Option.map(v -> JNumber(JsonCodec.floatToBd(v)), field#min))
            |> insertOpt("max", Option.map(v -> JNumber(JsonCodec.floatToBd(v)), field#max))
            |> insertOpt("step", Option.map(v -> JNumber(JsonCodec.floatToBd(v)), field#step))
            |> JObject

    // ════════════════════════════════════════════════════════
    // 小さな共通部品
    // ════════════════════════════════════════════════════════

    /// "//" で始まるキーは注釈(元データの JSON の "//" 注釈と同じ流儀)。
    def isNote(key: String): Bool =
        String.startsWith(prefix = "//", key)

    /// JSON object なら中身を返す。違えば what 入りの文で断る。
    def asObject(what: String, json: Json): Result[String, Map[String, Json]] =
        match json {
            case JObject(m) => Ok(m)
            case _          => Err("${what} は JSON object で書いてください")
        }

    /// 省略可能なキーを読む。無ければ Ok(None)、あるのに期待型でなければ断る —
    /// 書いたつもりの制約が黙って落ちるのを防ぐため。
    def optAt(expect: Json -> Option[a], what: String, path: String, key: String,
              obj: Map[String, Json]): Result[String, Option[a]] =
        match Map.get(key, obj) {
            case None       => Ok(None)
            case Some(json) =>
                expect(json)
                    |> Option.map(value -> Some(value))
                    |> Option.toOk("フィールド ${path} の ${key} は${what}で書いてください")
        }

    /// Some のときだけ Map に入れる(省略項目を JSON に書かないため)。
    def insertOpt(key: String, opt: Option[Json], m: Map[String, Json]): Map[String, Json] =
        match opt {
            case Some(json) => Map.insert(key, json, m)
            case None       => m
        }

    /// checkSection の過不足を「無い: xxx / 余分: yyy」の形にする(片方だけならその側のみ)。
    def describeDiff(missing: Set[String], extras: Set[String]): String =
        let missingPart = if (Set.isEmpty(missing)) Nil
                          else "無い: ${joinNames(missing)}" :: Nil;
        let extraPart   = if (Set.isEmpty(extras)) Nil
                          else "余分: ${joinNames(extras)}" :: Nil;
        String.intercalate(" / ", missingPart ::: extraPart)

    /// 名前集合を読みやすい 1 行に並べる。
    def joinNames(names: Set[String]): String =
        Set.toList(names) |> String.intercalate(", ")
}
