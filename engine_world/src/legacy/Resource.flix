// Resource — 旧世代のスキーマ方言。新しく作るゲームは Schema を使う。
// ゲーム独自データ型に「どんなフィールドがあり、どう編集するか」という編集 UI の
// 規格（schema）を JSON（`_schema.json`）で与える。IDE はデータの中身を知らなくても、
// 各フィールドに合った入力欄を出せる。
// 注意: schema が記述するのはフィールド定義だけで、ファイル全体の形（catalog / single 等）は
// data 側の構造で決まる。Flix 型と schema のズレは `checkConsistency` が起動時に検出する（ゲーム側の責任）。
pub mod Resource {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber, JBool, JArray, JNull}

    /// `KindedRefListT` で使う 1 種別ぶんの記述。
    ///   kindId : JSON 上で kind 判別子として書かれる文字列（例: "itemA"）
    ///   label  : IDE の kind ComboBox 表示用ラベル（例: "種別 A"）
    ///   target : 参照先 catalog の containerKey（例: "catalogA"）
    /// schema JSON では `{"kindId": "...", "label": "...", "to": "..."}` の object として表す。
    pub type alias KindSpec = {
        kindId = String,
        label  = String,
        target = String
    }

    /// フィールドの値型。IDE はこれと `FieldHint` の組から widget を選ぶ。
    ///   RefT(target) : 値が別 catalog の sub-entry id を指す。IDE は
    ///                  `target` 配下の sub-entries を ComboBox 候補に並べる。
    ///                  schema JSON では `{"type": "ref", "to": target}` で表す。
    ///   RefPercentListT(target) : 値が `[{id, percent}]` の object 配列。各要素は
    ///                  `target` catalog の sub-entry id への ref と 0-100 整数のペア。
    ///                  抽選テーブル等の「重み付き ref リスト」を表現する。
    ///                  schema JSON では `{"type": "refPercentList", "to": target}` で表す。
    ///   KindedRefListT(kinds) : 値が `[{kind, id}]` の object 配列。各要素は `kinds`
    ///                  のいずれかの種別を選び、その種別に紐づく catalog の sub-entry id を指す。
    ///                  複数種別の catalog にまたがる ref を 1 つのリストで編集したいときに使う。
    ///                  schema JSON では `{"type": "kindedRefList", "kinds": [{kindId,label,to}, ...]}` で表す。
    pub enum FieldType {
        case TextT
        case IntT
        case FloatT
        case BoolT
        case TexturePathT      // プロジェクト登録済みテクスチャから選択
        case RefT(String)      // 別 catalog (containerKey = target) の sub-entry id
        case RefPercentListT(String)  // [{id: ref, percent: 0-100}] の動的長配列
        case KindedRefListT(List[KindSpec])  // [{kind, id}] の動的長配列。複数 catalog から ref を選ぶ
        case EnumT(List[String])      // 有限の文字列選択肢。
                                       // IDE は 2 値なら ToggleGroup、3 値以上なら ComboBox を出す。
                                       // schema JSON では `{"type": "enum", "values": ["A", "B"]}` で表す。
        case SpriteFramesT     // スプライトのアニメ集合 (Map[anim_name, Animation])。
                                // IDE は アニメ選択 + region (pos/size) spinner + アトラスプレビューの
                                // 専用 widget を出して spriteFrames の region 編集を視覚化する。
                                // schema JSON では `"spriteFrames"` 文字列で表す。
        case WeaponProfT       // 武器タイプ習熟（得意/苦手）。値は WeaponType 文字列の配列
                                // (例 ["Sword","Axe"])。IDE は 5 タイプの正方形アイコンを並べた
                                // 複数トグルを出す。schema JSON では `"weaponProf"` 文字列で表す。
    }

    /// 編集 UI のヒント。`Plain` は型相応の素直な入力欄（数値スピナー / テキスト等）。
    /// `Multiline` は TextT に対して使うと複数行 TextArea で編集できる。
    /// 各 payload は anonymous record なので Eq / ToString 自動 derive はせず、
    /// 必要なら手動 instance を定義する方針。
    pub enum FieldHint {
        case Plain
        case Multiline
        case Slider({min = Float64, max = Float64, step = Float64})
        case Spinner({min = Int32, max = Int32})
        case FrameGrid({hframesField = String, vframesField = String})
    }

    /// 1 フィールドぶんの完全記述。
    /// `order` は IDE での表示順を明示するための補助フィールド（小さい値が先頭）。
    /// 指定なし（`None`）なら IDE 側のデフォルト並び（priority + alphabetical）が使われる。
    /// デザイナの意図する自然な並びを schema 側で宣言できるようにするための拡張。
    pub type alias FieldSchema = {
        ftype = FieldType,
        hint  = FieldHint,
        label = String,
        order = Option[Int32]
    }

    /// レコード 1 件のフィールド木。`Field` は葉、`Nested` はサブレコード。
    pub enum FieldEntry {
        case Field(FieldSchema)
        case Nested(Map[String, FieldEntry])
    }

    /// catalog 外のトップレベル array (例: `players: ["knight", ...]`) の編集 UI を決めるヒント。
    ///   Ref(target)  : 要素が `target` という catalog コンテナの sub-entry id を指す。
    ///                  IDE は data の `target` 配下の sub-entries を dropdown 候補に並べる。
    ///                  例: `Ref("units")` なら units 配下の knight/archer/... が候補。
    ///   Text         : 要素が任意の文字列 (catalog id ではない)。IDE は JTextField で自由入力。
    /// schema 表記:
    ///   {"type": "ref", "to": "units"}  → Ref("units")
    ///   {"type": "text"}                → Text
    pub enum MetaHint with Eq, ToString {
        case Ref(String)
        case Text
    }

    /// ファイル単位の schema。fields は catalog 子レコードのフィールド構造、metaHints は data top の
    /// catalog 外フィールド (= メタ array) の編集 UI ヒント。
    /// metaHints は省略可能 (デコード時に欠落していれば空 Map になる) → 後方互換。
    pub enum ResourceSchema {
        case ResourceSchema({
            fields    = Map[String, FieldEntry],
            metaHints = Map[String, MetaHint]
        })
    }

    /// `ResourceSchema` の中身（フィールド集合）を取り出す。
    pub def fieldsOf(schema: ResourceSchema): Map[String, FieldEntry] =
        let ResourceSchema.ResourceSchema(payload) = schema;
        payload#fields

    /// メタフィールドの編集ヒントを取り出す。指定されていなければ空 Map。
    pub def metaHintsOf(schema: ResourceSchema): Map[String, MetaHint] =
        let ResourceSchema.ResourceSchema(payload) = schema;
        payload#metaHints

    /// `Map[String, FieldEntry]` から `ResourceSchema` を作るコンストラクタ。
    /// metaHints は空 Map で初期化する。
    pub def mkSchema(fields: Map[String, FieldEntry]): ResourceSchema =
        ResourceSchema.ResourceSchema({fields = fields, metaHints = Map.empty()})

    /// fields と metaHints を両方指定するコンストラクタ。
    pub def mkSchemaWithMeta(fields: Map[String, FieldEntry], metaHints: Map[String, MetaHint]):
            ResourceSchema =
        ResourceSchema.ResourceSchema({fields = fields, metaHints = metaHints})

    /// `_schema.json` をパースして `ResourceSchema` を返す。形式不一致は `None`。
    /// 失敗ハンドリングは呼び出し側に任せる（panic にしたい場合は `Option.getWithDefault(?bug(...))`）。
    pub def loadSchema(path: String): Option[ResourceSchema] \ Fs.FileRead =
        Persistence.load(path)

    /// `loadSchema` の診断つきバリアント。失敗の段階を文字列で返す。
    /// `Game.start` から呼んで起動時に panic させるとファイル不在 / JSON parse / decode の
    /// どこで失敗したかが一目でわかる。
    pub def loadSchemaDiagnostic(path: String): Result[String, ResourceSchema] \ Fs.FileRead =
        let readResult = run {
            Fs.ReadFile.read(path)
        } with Fs.ReadFile.runWithFileRead;
        match readResult {
            case Err(e) => Err("file read failed (${path}): ${e}")
            case Ok(content) =>
                match DocJson.parse(content) {
                    case None => Err("JSON parse failed (${path})")
                    case Some(json) =>
                        let decoded: Option[ResourceSchema] = Saveable.fromJson(json);
                        match decoded {
                            case None    => Err("ResourceSchema decode failed (${path}) — schema JSON does not match engine spec")
                            case Some(s) => Ok(s)
                        }
                }
        }

    /// 整合性検査。schema の **トップレベルフィールド集合** が `expected` の部分集合か検証する。
    /// 過剰フィールド（schema にあるが Flix 型にない）は `Err` を返す。
    /// 不足フィールド（Flix 型にあるが schema にない）は警告として `Err` に含める。
    ///
    /// IDE が schema に頼って widget を出すため、両者がズレるとデザイナが「触れないフィールド」を
    /// 編集できないなどの不整合が起きる。CI / 起動時に必ず通すこと。
    pub def checkConsistency(expected: Set[String], schema: ResourceSchema):
            Result[String, Unit] =
        let actual  = Map.keysOf(fieldsOf(schema));
        let extras  = Set.difference(actual, expected);
        let missing = Set.difference(expected, actual);
        if (Set.isEmpty(extras) and Set.isEmpty(missing)) Ok(())
        else
            let extrasMsg  = if (Set.isEmpty(extras))  "" else "extra fields in schema: ${extras}; ";
            let missingMsg = if (Set.isEmpty(missing)) "" else "missing fields in schema: ${missing}";
            Err("${extrasMsg}${missingMsg}")
}

// ════════════════════════════════════════════════════════════════════════
// Saveable[Resource.ResourceSchema] — `_schema.json` の round-trip 実装
// ════════════════════════════════════════════════════════════════════════
//
// JSON 形状（例）:
//   {
//     "fields": {
//       "hp":  { "field":  { "ftype": "int", "hint": { "slider": { "min": 1, "max": 100, "step": 5 } }, "label": "HP" } },
//       "sprite": { "nested": { "frame": { "field": {...} }, ... } }
//     }
//   }
//
// FieldEntry は `{"field": ...}` か `{"nested": {...}}` の単一キー判別。
// FieldHint は `"plain"`（文字列）または `{"slider": {...}}` 等の単一キー判別。

instance Saveable[Resource.ResourceSchema] {
    pub def toJson(value: Resource.ResourceSchema): Util.Json.Json =
        ResourceCodec.encodeSchema(value)

    pub def fromJson(element: Util.Json.Json): Option[Resource.ResourceSchema] =
        ResourceCodec.decodeSchema(element)
}

/// `ResourceSchema` の JSON エンコード／デコード本体。
/// 外部からは `Saveable[Resource.ResourceSchema]` 経由でしか触らない想定。
mod ResourceCodec {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber, JBool, JArray}
    use JsonCodec.{expectObject, expectString, expectInt, expectFloat, floatToBd, intToBd}
    use Resource.{ResourceSchema, FieldEntry, FieldSchema, FieldType, FieldHint, MetaHint}

    // ── エンコード ──

    pub def encodeSchema(s: ResourceSchema): Json =
        let meta = Resource.metaHintsOf(s);
        let base = Map#{"fields" => encodeEntries(Resource.fieldsOf(s))};
        if (Map.isEmpty(meta))
            JObject(base)
        else
            JObject(Map.insert("metaHints", encodeMetaHints(meta), base))

    def encodeMetaHints(meta: Map[String, MetaHint]): Json =
        let inner = meta
            |> Map.foldLeftWithKey((acc, name, hint) ->
                Map.insert(name, encodeMetaHint(hint), acc),
                Map.empty());
        JObject(inner)

    def encodeMetaHint(h: MetaHint): Json = match h {
        case MetaHint.Ref(target) =>
            JObject(Map#{
                "type" => JString("ref"),
                "to"   => JString(target)
            })
        case MetaHint.Text =>
            JObject(Map#{"type" => JString("text")})
    }

    def encodeEntries(entries: Map[String, FieldEntry]): Json =
        let inner = entries
            |> Map.foldLeftWithKey((acc, name, entry) ->
                Map.insert(name, encodeEntry(entry), acc),
                Map.empty());
        JObject(inner)

    def encodeEntry(entry: FieldEntry): Json = match entry {
        case FieldEntry.Field(fs) =>
            JObject(Map#{"field" => encodeFieldSchema(fs)})
        case FieldEntry.Nested(m) =>
            JObject(Map#{"nested" => encodeEntries(m)})
    }

    def encodeFieldSchema(fs: FieldSchema): Json =
        let base = Map#{
            "ftype" => encodeFieldType(fs#ftype),
            "hint"  => encodeFieldHint(fs#hint),
            "label" => JString(fs#label)
        };
        let withOrder = match fs#order {
            case Some(n) => Map.insert("order", JNumber(intToBd(n)), base)
            case None    => base
        };
        JObject(withOrder)

    def encodeFieldType(t: FieldType): Json = match t {
        case FieldType.TextT         => JString("text")
        case FieldType.IntT          => JString("int")
        case FieldType.FloatT        => JString("float")
        case FieldType.BoolT         => JString("bool")
        case FieldType.TexturePathT  => JString("texturePath")
        case FieldType.SpriteFramesT => JString("spriteFrames")
        case FieldType.WeaponProfT   => JString("weaponProf")
        case FieldType.RefT(target)  =>
            JObject(Map#{
                "type" => JString("ref"),
                "to"   => JString(target)
            })
        case FieldType.RefPercentListT(target) =>
            JObject(Map#{
                "type" => JString("refPercentList"),
                "to"   => JString(target)
            })
        case FieldType.KindedRefListT(kinds) =>
            JObject(Map#{
                "type"  => JString("kindedRefList"),
                "kinds" => JArray(List.map(encodeKindSpec, kinds) |> List.toVector)
            })
        case FieldType.EnumT(values) =>
            JObject(Map#{
                "type"   => JString("enum"),
                "values" => JArray(List.map(JString, values) |> List.toVector)
            })
    }

    /// 1 つの KindSpec を `{"kindId": "...", "label": "...", "to": "..."}` に encode する。
    def encodeKindSpec(k: Resource.KindSpec): Json =
        JObject(Map#{
            "kindId" => JString(k#kindId),
            "label"  => JString(k#label),
            "to"     => JString(k#target)
        })

    def encodeFieldHint(h: FieldHint): Json = match h {
        case FieldHint.Plain         => JString("plain")
        case FieldHint.Multiline     => JString("multiline")
        case FieldHint.Slider(s)     =>
            JObject(Map#{"slider" => JObject(Map#{
                "min"  => JNumber(floatToBd(s#min)),
                "max"  => JNumber(floatToBd(s#max)),
                "step" => JNumber(floatToBd(s#step))
            })})
        case FieldHint.Spinner(s)    =>
            JObject(Map#{"spinner" => JObject(Map#{
                "min" => JNumber(intToBd(s#min)),
                "max" => JNumber(intToBd(s#max))
            })})
        case FieldHint.FrameGrid(g)  =>
            JObject(Map#{"frameGrid" => JObject(Map#{
                "hframesField" => JString(g#hframesField),
                "vframesField" => JString(g#vframesField)
            })})
    }

    // ── デコード ──

    pub def decodeSchema(element: Json): Option[ResourceSchema] =
        forM (
            top         <- expectObject(element);
            fieldsJson  <- Map.get("fields", top);
            fieldsMap   <- expectObject(fieldsJson);
            fields      <- decodeEntries(fieldsMap);
            metaHints   <- decodeMetaHintsOpt(top)
        ) yield Resource.mkSchemaWithMeta(fields, metaHints)

    /// `metaHints` セクションは省略可能。欠落していれば空 Map を返す (後方互換)。
    def decodeMetaHintsOpt(top: Map[String, Json]): Option[Map[String, MetaHint]] =
        match Map.get("metaHints", top) {
            case None         => Some(Map.empty())
            case Some(metaJ)  =>
                expectObject(metaJ) |> Option.flatMap(decodeMetaHints)
        }

    def decodeMetaHints(map: Map[String, Json]): Option[Map[String, MetaHint]] =
        Map.foldLeftWithKey((acc, name, json) ->
            Option.flatMap(soFar ->
                decodeMetaHint(json) |> Option.map(h -> Map.insert(name, h, soFar)),
                acc),
            Some(Map.empty()),
            map)

    def decodeMetaHint(element: Json): Option[MetaHint] =
        forM (
            obj    <- expectObject(element);
            typeJ  <- Map.get("type", obj);
            tName  <- expectString(typeJ);
            hint   <- match tName {
                case "ref"  =>
                    Map.get("to", obj)
                        |> Option.flatMap(expectString)
                        |> Option.map(MetaHint.Ref)
                case "text" => Some(MetaHint.Text)
                case _      => None
            }
        ) yield hint

    def decodeEntries(map: Map[String, Json]): Option[Map[String, FieldEntry]] =
        Map.foldLeftWithKey((acc, name, json) ->
            Option.flatMap(soFar ->
                decodeEntry(json) |> Option.map(e -> Map.insert(name, e, soFar)),
                acc),
            Some(Map.empty()),
            map)

    def decodeEntry(element: Json): Option[FieldEntry] =
        expectObject(element)
            |> Option.flatMap(singleEntry)
            |> Option.flatMap(matchEntryKind)

    def matchEntryKind(pair: (String, Json)): Option[FieldEntry] =
        match pair {
            case ("field", payload) =>
                decodeFieldSchema(payload) |> Option.map(FieldEntry.Field)
            case ("nested", payload) =>
                expectObject(payload)
                    |> Option.flatMap(decodeEntries)
                    |> Option.map(FieldEntry.Nested)
            case _ => None
        }

    def decodeFieldSchema(element: Json): Option[FieldSchema] =
        forM (
            obj      <- expectObject(element);
            ftypeJ   <- Map.get("ftype", obj);
            hintJ    <- Map.get("hint",  obj);
            labelJ   <- Map.get("label", obj);
            ftype    <- decodeFieldType(ftypeJ);
            hint     <- decodeFieldHint(hintJ);
            label    <- expectString(labelJ);
            order    <- decodeOrderOpt(obj)
        ) yield ({ftype = ftype, hint = hint, label = label, order = order}: FieldSchema)

    /// `order` フィールドは省略可能。欠落時は `None`、値あり時は `Some(n)`。
    def decodeOrderOpt(obj: Map[String, Json]): Option[Option[Int32]] =
        match Map.get("order", obj) {
            case None      => Some(None)
            case Some(orderJ) => expectInt(orderJ) |> Option.map(Some)
        }

    def decodeFieldType(element: Json): Option[FieldType] = match element {
        case JString("text")          => Some(FieldType.TextT)
        case JString("int")           => Some(FieldType.IntT)
        case JString("float")         => Some(FieldType.FloatT)
        case JString("bool")          => Some(FieldType.BoolT)
        case JString("texturePath")   => Some(FieldType.TexturePathT)
        case JString("spriteFrames")  => Some(FieldType.SpriteFramesT)
        case JString("weaponProf")    => Some(FieldType.WeaponProfT)
        case JObject(obj)            =>
            forM (
                typeJ <- Map.get("type", obj);
                tName <- expectString(typeJ);
                ftype <- match tName {
                    case "ref" =>
                        Map.get("to", obj)
                            |> Option.flatMap(expectString)
                            |> Option.map(FieldType.RefT)
                    case "refPercentList" =>
                        Map.get("to", obj)
                            |> Option.flatMap(expectString)
                            |> Option.map(FieldType.RefPercentListT)
                    case "kindedRefList" =>
                        Map.get("kinds", obj)
                            |> Option.flatMap(decodeKindSpecList)
                            |> Option.map(FieldType.KindedRefListT)
                    case "enum" =>
                        Map.get("values", obj)
                            |> Option.flatMap(decodeStringList)
                            |> Option.map(FieldType.EnumT)
                    case _     => None
                }
            ) yield ftype
        case _                          => None
    }

    /// `["A", "B", ...]` の JArray を List[String] に。
    /// EnumT.values の decoding に使う。
    def decodeStringList(element: Json): Option[List[String]] = match element {
        case JArray(items) =>
            List.foldRight(item -> acc ->
                Option.flatMap(soFar ->
                    expectString(item) |> Option.map(s -> s :: soFar),
                    acc),
                Some(Nil), Vector.toList(items))
        case _ => None
    }

    /// `[{kindId, label, to}, ...]` の JArray を `List[KindSpec]` に decode する。
    /// 要素のいずれかが不正なら全体を None にする（schema 不整合は起動時 panic に上げる）。
    def decodeKindSpecList(element: Json): Option[List[Resource.KindSpec]] = match element {
        case JArray(items) =>
            List.foldRight(item -> acc ->
                Option.flatMap(soFar ->
                    decodeKindSpec(item) |> Option.map(k -> k :: soFar),
                    acc),
                Some(Nil), Vector.toList(items))
        case _ => None
    }

    def decodeKindSpec(element: Json): Option[Resource.KindSpec] =
        forM (
            obj      <- expectObject(element);
            kindIdJ  <- Map.get("kindId", obj);
            labelJ   <- Map.get("label", obj);
            toJ      <- Map.get("to", obj);
            kindId   <- expectString(kindIdJ);
            label    <- expectString(labelJ);
            target   <- expectString(toJ)
        ) yield ({kindId = kindId, label = label, target = target}: Resource.KindSpec)

    def decodeFieldHint(element: Json): Option[FieldHint] = match element {
        case JString("plain")     => Some(FieldHint.Plain)
        case JString("multiline") => Some(FieldHint.Multiline)
        case JObject(_)           =>
            expectObject(element)
                |> Option.flatMap(singleEntry)
                |> Option.flatMap(matchHintKind)
        case _                       => None
    }

    def matchHintKind(pair: (String, Json)): Option[FieldHint] =
        match pair {
            case ("slider", payload)    => decodeSliderHint(payload)
            case ("spinner", payload)   => decodeSpinnerHint(payload)
            case ("frameGrid", payload) => decodeFrameGridHint(payload)
            case _                      => None
        }

    def decodeSliderHint(element: Json): Option[FieldHint] =
        forM (
            obj   <- expectObject(element);
            minJ  <- Map.get("min",  obj);
            maxJ  <- Map.get("max",  obj);
            stepJ <- Map.get("step", obj);
            mn    <- expectFloat(minJ);
            mx    <- expectFloat(maxJ);
            st    <- expectFloat(stepJ)
        ) yield FieldHint.Slider({min = mn, max = mx, step = st})

    def decodeSpinnerHint(element: Json): Option[FieldHint] =
        forM (
            obj  <- expectObject(element);
            minJ <- Map.get("min", obj);
            maxJ <- Map.get("max", obj);
            mn   <- expectInt(minJ);
            mx   <- expectInt(maxJ)
        ) yield FieldHint.Spinner({min = mn, max = mx})

    def decodeFrameGridHint(element: Json): Option[FieldHint] =
        forM (
            obj  <- expectObject(element);
            hfJ  <- Map.get("hframesField", obj);
            vfJ  <- Map.get("vframesField", obj);
            hf   <- expectString(hfJ);
            vf   <- expectString(vfJ)
        ) yield FieldHint.FrameGrid({hframesField = hf, vframesField = vf})

    // ── ヘルパー ──
    //
    // expectObject / expectString / expectInt / expectFloat / floatToBd / intToBd は
    // `engine/src/JsonCodec.flix` に集約されている。本 mod の `use JsonCodec.{...}` で
    // 参照を引き込んでいるため、ローカル定義は持たない。

    def singleEntry(map: Map[String, Json]): Option[(String, Json)] =
        match Map.toList(map) {
            case head :: Nil => Some(head)
            case _           => None
        }
}
