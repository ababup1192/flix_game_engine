// YarnStorage — 会話の変数の値と、ノードを出た回数の置き場（公式の Yarn Spinner の VariableStorage。純粋）。
// YarnRunner が 1 つ持ち、<<set>> で書き、式と visited で読む。ゲームはセーブに乗せる時に toJson / fromJson を使う。
//
//   let storage = YarnRunner.storageOf(runner)                               会話の外で取り出す
//   let runner = YarnRunner.startWith(storage, program, "station2", now)     次の会話へ持ち越す
//   YarnStorage.toJson(storage)                                              セーブへ（{"variables": {"$tickets": 3}, "visits": {"station1": 1}}）
//
// 名前は .yarn と同じく $ から書く。書いていない変数は、シナリオの <<declare>> の初めの値として読まれる（YarnRunner.valueOf）。
pub mod YarnStorage {
    use Util.Json.Json

    /// values = 変数の名前 → 値、visits = ノードの名前 → 出た回数。外では作らない（empty か fromJson）。
    enum Variables({ values = Map[String, Yarn.Value], visits = Map[String, Int32] })

    /// 変数と訪れた数の置き場。
    pub type alias Storage = Variables

    /// 何も書いていない置き場（変数は全部 <<declare>> の初めの値・どのノードも 0 回）。
    pub def empty(): Storage = Variables.Variables({ values = Map.empty(), visits = Map.empty() })

    /// 書いてある値（書いていなければ None。<<declare>> の初めの値は見ない）。
    pub def get(name: String, storage: Storage): Option[Yarn.Value] =
        let Variables.Variables(s) = storage; Map.get(name, s#values)

    /// 値を書く（型はシナリオの宣言と合わせる。合わない値は読む時に初めの値へ戻る）。
    pub def set(name: String, value: Yarn.Value, storage: Storage): Storage =
        let Variables.Variables(s) = storage; Variables.Variables({ values = Map.insert(name, value, s#values) | s })

    /// node を出た回数。
    pub def visitCountOf(node: String, storage: Storage): Int32 =
        let Variables.Variables(s) = storage; Map.getWithDefault(node, 0, s#visits)

    /// node を出た回数を 1 つ足す。
    pub def addVisit(node: String, storage: Storage): Storage =
        let Variables.Variables(s) = storage;
        Variables.Variables({ visits = Map.insert(node, visitCountOf(node, storage) + 1, s#visits) | s })

    /// 書いてある変数の名前と値（名前の順）。
    pub def valuesOf(storage: Storage): List[(String, Yarn.Value)] =
        let Variables.Variables(s) = storage; Map.toList(s#values)

    /// 始まりの引数（`talk node=… line=… $切符=0`）の $ から始まる物を、宣言の型で読んで書く（他の引数は見ない）。
    /// 宣言の無い名前・型に読めない値は、近い名前の案つきで Err（プレビューが違う場面を黙って出さないため）。
    pub def withArgs(args: Map[String, String], program: Yarn.Program, storage: Storage): Result[String, Storage] =
        let names = Yarn.variablesOf(program) |> List.map(fst);
        args |> Map.toList |> List.filter(match (key, _) -> String.startsWith(prefix = "$", key))
             |> List.foldLeft((acc, pair) -> forM (
                    soFar <- acc;
                    value <- {
                        let (name, text) = pair;
                        match Yarn.declarationOf(name, program) {
                            case None           => Err("変数 ${name} はシナリオで宣言していない${Suggest.hint(name, names)}")
                            case Some(declared) => valueAs(declared#value, text) |> Option.toOk("変数 ${name} の値 '${text}' は ${typeName(declared#value)} に読めない")
                        }
                    }
                ) yield set(fst(pair), value, soFar), Ok(storage))

    /// text を like と同じ型の値に（数は 1.5 の形・真偽は true / false・文字列はそのまま）。
    def valueAs(like: Yarn.Value, text: String): Option[Yarn.Value] = match like {
        case Yarn.Value.Number(_) => Float64.fromString(text) |> Option.map(Yarn.Value.Number)
        case Yarn.Value.Bool(_)   => match text {
            case "true"  => Some(Yarn.Value.Bool(true))
            case "false" => Some(Yarn.Value.Bool(false))
            case _       => None
        }
        case Yarn.Value.Text(_)   => Some(Yarn.Value.Text(text))
    }

    def typeName(value: Yarn.Value): String = match value {
        case Yarn.Value.Number(_) => "Number"
        case Yarn.Value.Bool(_)   => "Bool"
        case Yarn.Value.Text(_)   => "String"
    }

    // ── セーブ ──

    /// {"variables": {名前: 数・真偽・文字列}, "visits": {ノード: 回数}}。
    pub def toJson(storage: Storage): Json =
        let Variables.Variables(s) = storage;
        Json.JObject(Map#{
            "variables" => JsonCodec.encodeStringMap(Yarn.valueToJson, s#values),
            "visits" => JsonCodec.encodeStringMap(count -> Json.JNumber(JsonCodec.intToBd(count)), s#visits)
        })

    /// toJson の形から。欄が無ければ空・形が違えば None。
    pub def fromJson(json: Json): Option[Storage] = forM (
        obj <- JsonCodec.expectObject(json);
        values <- mapOr("variables", obj, Yarn.valueFromJson);
        visits <- mapOr("visits", obj, JsonCodec.expectInt)
    ) yield Variables.Variables({ values = values, visits = visits })

    def mapOr(key: String, obj: Map[String, Json], decode: Json -> Option[t]): Option[Map[String, t]] = match Map.get(key, obj) {
        case None       => Some(Map.empty())
        case Some(json) => JsonCodec.decodeStringMap(decode, json)
    }
}
