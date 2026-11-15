// YarnCommands — 台本のコマンド（<<名前 引数…>>）の引数の表と、その表で引数を読む口。
// 1 コマンドの表（Spec）から、実行時の読み方（parse → Param.get）と、bin/fge yarn build の検査が読む
// vocab.json の commands（toJson）の両方を出す。表を書くのは YarnCommands.Param の部品。
//
//   def overlay(): YarnCommands.Spec =
//       let alpha = Param.num("alpha", 0.0, 1.0) |> Param.at(1) |> Param.required;
//       YarnCommands.spec("overlay", "画面に被せる色の濃さを変える", Param.erase(alpha) :: Param.erase(Param.time(0.0)) :: Nil)
//   YarnCommands.parse(overlay(), command) |> Result.map(args -> Param.get(alpha, args))
//
// 書き方: 位置の引数は 2 つまで、ほかは key=value。"…" は空白を含む 1 つの値（\" と \\ が使える）。
// 同じ鍵を 2 回・知らない鍵・位置の数の超過・必須の欠けは誤り。受ける行と断る行の見本は
// go/internal/yarn/testdata/command-args.json（go の検査と同じ見本を読む）。
// Doc の名前（ref）は実行時には照らさない（Doc を持たない）。照らすのは build と、名前を引く apply。
pub mod YarnCommands {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString, JNumber, JBool, JArray}

    /// Doc のどこから名前を集めるか（vocab.json の from の 1 行と同じ）。doc は vocab.json のフォルダから数えたパス。
    /// Keys(doc, path) = path の先の object の鍵、Path(doc, path) = path の先の文字列（xs[] は配列の要素を全部）。
    pub enum DocRef with Eq {
        case Keys(String, String)
        case Path(String, String)
    }

    /// 値の型。Num(min, max) は両端を含む。
    enum Kind with Eq {
        case Num(Float64, Float64)
        case Time
        case Name(List[DocRef])
        case Choice(List[String])
        case Flag
        case Ease
    }

    /// 書かなかった時の扱い。Defaulted は既定の値（vocab.json に書く字）。
    enum Need with Eq {
        case Required
        case Optional
        case Defaulted(String)
    }

    /// 値が 1 つか、, で区切った並びか。
    enum Shape with Eq {
        case Single
        case Listed
    }

    /// 引数 1 つの表の行（型を消した物）。pos = 位置で書ける順番（0 は key=value だけ）・words = 型の外に受ける語・
    /// names = 型に合わない値を名前として受ける時に照らす Doc・group = どれか 1 つは要る組の名前（"" は組に入らない）。
    enum Field(Row)

    /// Field の中身。
    type alias Row = { name = String, pos = Int32, kind = Kind, need = Need, words = List[String], names = List[DocRef], shape = Shape, group = String }

    /// 型付きの引数のハンドル。decode は 1 つの値の字を読む（parse を通った字なら Some）。
    enum Handle[_: Type, t: Type]({ field = Field, decode = String -> Option[t], fallback = Option[t] })

    /// コマンド 1 つの引数の表。
    enum CommandSpec({ name = String, summary = String, params = List[Field] })

    /// コマンド 1 つの引数の表（spec か fromJson で作る）。
    pub type alias Spec = CommandSpec

    /// parse を通った引数。known = 表にある引数の名前・values = 書いてあった引数の字（"…" は外した物）。
    enum Parsed({ command = String, known = Set[String], values = Map[String, String] })

    /// parse を通った引数（外からは作れない。読むのは Param.get / Param.getOpt）。
    pub type alias Args = Parsed

    /// 1 つの字の分け方。
    enum Token {
        case Positional(String)
        case Keyed(String, String)
    }

    /// 位置の引数の数の上限。
    def maxPositional(): Int32 = 2

    // ── 表を作る ──

    /// コマンド 1 つの表。名前の重なり・位置の番号の飛びや重なり・3 つ目の位置はプログラマの誤りなので止める。
    pub def spec(name: String, summary: String, params: List[Field]): Spec =
        let s = { name = name, summary = summary, params = params };
        match problemOf(s) {
            case Some(why) => bug!("YarnCommands.spec: ${why}")
            case None      => CommandSpec.CommandSpec(s)
        }

    /// 表のコマンドの名前。
    pub def nameOf(s: Spec): String = specOf(s)#name

    def specOf(s: Spec): { name = String, summary = String, params = List[Field] } =
        let CommandSpec.CommandSpec(r) = s;
        r

    def fieldOf(f: Field): Row =
        let Field.Field(r) = f;
        r

    def problemOf(s: { name = String, summary = String, params = List[Field] }): Option[String] =
        let rows = s#params |> List.map(fieldOf);
        let names = rows |> List.map(r -> r#name);
        let positions = rows |> List.map(r -> r#pos) |> List.filter(p -> p > 0) |> Sort.sortStable;
        let wanted = List.range(1, List.length(positions) + 1);
        if (s#name == "") Some("名前の無いコマンド")
        else if (List.length(List.distinct(names)) != List.length(names)) Some("<<${s#name}>> に同じ名前の引数が 2 つある")
        else if (List.exists(n -> n == "", names)) Some("<<${s#name}>> に名前の無い引数がある")
        else if (positions != wanted or List.length(positions) > maxPositional()) Some("<<${s#name}>> の位置の番号は 1 から順に ${maxPositional()} つまで")
        else rows |> List.filterMap(rowProblemOf(s#name)) |> List.head

    /// 引数 1 つの表の誤り: 値の一覧の無い choice と、型に合わない既定の値。
    def rowProblemOf(command: String, r: Row): Option[String] =
        let badDefault = match r#need {
            case Need.Defaulted(d) => not List.memberOf(d, r#words) and List.isEmpty(r#names) and not fitsKind(r#kind, d)
            case _                 => false
        };
        if (r#kind == Kind.Choice(Nil)) Some("<<${command}>> の ${r#name}（choice）に values が要る")
        else if (badDefault) Some("<<${command}>> の ${r#name} の既定の値が型に合わない（${expectedOf(r)}）")
        else None

    // ── 読む ──

    /// command を表で読む。読めない時は直し方を 1 行で返す（台本の場所つき）。
    pub def parse(s: Spec, command: Yarn.Command): Result[String, Args] =
        let r = specOf(s);
        let at = "（${Yarn.sourceText(command#source)}）";
        argsOf(r, command#args) |> Result.mapErr(why -> why + at)

    def argsOf(r: { name = String, summary = String, params = List[Field] }, raw: List[String]): Result[String, Args] =
        let rows = r#params |> List.map(fieldOf);
        forM (
            tokens <- raw |> Result.traverse(tokenOf(r#name));
            pairs  <- placed(r#name, rows, tokens);
            _      <- { let byName = rows |> List.map(x -> (x#name, x)) |> List.toMap; pairs |> Result.traverse(pair -> checkPair(r#name, byName, pair)) };
            _      <- missingOf(r#name, rows, pairs |> List.map(fst) |> List.toSet)
        ) yield Parsed.Parsed({ command = r#name, known = rows |> List.map(x -> x#name) |> List.toSet, values = List.toMap(pairs) })

    /// 1 つの字を位置の引数か key=value に分け、"…" を外す。
    def tokenOf(command: String, raw: String): Result[String, Token] =
        if (String.startsWith(prefix = "\"", raw)) unquote(command, raw) |> Result.map(Token.Positional)
        else match keyOf(raw) {
            case Some((key, value)) if String.startsWith(prefix = "\"", value) => unquote(command, value) |> Result.map(v -> Token.Keyed(key, v))
            case Some((key, value)) => Ok(Token.Keyed(key, value))
            case None               => Ok(Token.Positional(raw))
        }

    /// key=value の key と value（= の前が英字か _ で始まる英数字と _ の時だけ）。
    def keyOf(raw: String): Option[(String, String)] =
        String.indexOf(substr = "=", raw)
            |> Option.filter(i -> i > 0)
            |> Option.map(i -> (String.slice(start = 0, end = i, raw), String.sliceRight(start = i + 1, raw)))
            |> Option.filter(pair -> isIdentifier(fst(pair)))

    def isIdentifier(s: String): Bool = match String.toList(s) {
        case c :: rest => isIdentStart(c) and List.forAll(x -> isIdentStart(x) or (x >= '0' and x <= '9'), rest)
        case Nil       => false
    }

    def isIdentStart(c: Char): Bool = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'

    /// "…" の中身（\" と \\ を 1 字に戻す）。閉じていない・中に裸の " がある時は誤り。
    def unquote(command: String, raw: String): Result[String, String] =
        let chars = String.toList(raw);
        let n = List.length(chars);
        if (n >= 2 and String.endsWith(suffix = "\"", raw))
            unescape(List.slice(start = 1, end = n - 1, chars), Nil) |> Option.toOk(unclosed(command, raw))
        else Err(unclosed(command, raw))

    def unclosed(command: String, raw: String): String =
        "<<${command}>> の \"…\" が閉じていないか、中に裸の \" がある（中の \" は \\\" と書く）: ${raw}"

    def unescape(chars: List[Char], acc: List[Char]): Option[String] = match chars {
        case Nil              => Some(List.reverse(acc) |> List.join(""))
        case '\\' :: c :: rest => unescape(rest, c :: acc)
        case '\\' :: Nil      => None
        case '"' :: _         => None
        case c :: rest        => unescape(rest, c :: acc)
    }

    /// 書いてあった引数を (引数の名前, 字) の並びにする。
    def placed(command: String, rows: List[Row], tokens: List[Token]): Result[String, List[(String, String)]] =
        let positional = tokens |> List.filterMap(positionalOf);
        let keyed = tokens |> List.filterMap(keyedOf);
        let slots = rows |> List.filter(r -> r#pos > 0) |> Sort.sortStableBy(r -> r#pos) |> List.map(r -> r#name);
        let names = rows |> List.map(r -> r#name);
        let known = List.toSet(names);
        let pairs = List.append(List.zip(slots, positional), keyed);
        let seen = pairs |> List.map(fst);
        let twice = firstRepeat(seen, Set.empty());
        let unknown = keyed |> List.map(fst) |> List.find(k -> not Set.memberOf(k, known));
        if (not List.isEmpty(positional) and List.isEmpty(rows)) Err("<<${command}>> は引数を取らない")
        else if (List.length(positional) > List.length(slots))
            Err("<<${command}>> の位置の引数は ${List.length(slots)} つまで（${List.length(positional)} つ書いてある。ほかは key=value で書く）")
        else match (unknown, twice) {
            case (Some(k), _)    => Err("<<${command}>> に知らない鍵 ${k}${Suggest.hint(k, names)}")
            case (None, Some(n)) => Err("<<${command}>> の ${n} を 2 回書いている")
            case (None, None)    => Ok(pairs)
        }

    def positionalOf(t: Token): Option[String] = match t {
        case Token.Positional(v) => Some(v)
        case Token.Keyed(_, _)   => None
    }

    def keyedOf(t: Token): Option[(String, String)] = match t {
        case Token.Keyed(k, v)   => Some((k, v))
        case Token.Positional(_) => None
    }

    def firstRepeat(names: List[String], seen: Set[String]): Option[String] = match names {
        case Nil                                  => None
        case n :: _ if Set.memberOf(n, seen)      => Some(n)
        case n :: rest                            => firstRepeat(rest, Set.insert(n, seen))
    }

    def checkPair(command: String, byName: Map[String, Row], pair: (String, String)): Result[String, Unit] =
        let (name, value) = pair;
        Map.get(name, byName)
             |> Option.map(r -> checkValue(command, r, value))
             |> Option.getWithDefault(Ok(()))

    /// 値 1 つが型に合うか（words にある語・, で並べた時は要素ごと）。
    def checkValue(command: String, r: Row, value: String): Result[String, Unit] =
        if (value == "") Err("<<${command}>> の ${r#name} に値が無い")
        else if (List.memberOf(value, r#words)) Ok(())
        else match r#shape {
            case Shape.Single => checkOne(command, r, value)
            case Shape.Listed =>
                String.splitOn(substr = ",", value) |> Result.traverse(checkOne(command, r)) |> Result.map(_ -> ())
        }

    def checkOne(command: String, r: Row, value: String): Result[String, Unit] =
        let asName = value != "" and not List.isEmpty(r#names) and not isNumberKindWithNumber(r#kind, value);
        let fits = fitsKind(r#kind, value) or asName;
        if (fits) Ok(())
        else Err("<<${command}>> の ${r#name} に ${value} は書けない（${expectedOf(r)}）")

    /// 数の型に数の字を書いた時（範囲の外でも名前としては受けない）。
    def isNumberKindWithNumber(k: Kind, value: String): Bool = match k {
        case Kind.Num(_, _) => numberOf(value) |> Option.nonEmpty
        case Kind.Time      => numberOf(value) |> Option.nonEmpty
        case _              => false
    }

    def fitsKind(k: Kind, value: String): Bool = match k {
        case Kind.Num(lo, hi)  => numberOf(value) |> Option.exists(x -> x >= lo and x <= hi)
        case Kind.Time         => numberOf(value) |> Option.exists(x -> x >= 0.0)
        case Kind.Name(_)      => value != ""
        case Kind.Choice(vs)   => List.memberOf(value, vs)
        case Kind.Flag         => value == "true" or value == "false"
        case Kind.Ease         => easeOf(value) |> Option.nonEmpty
    }

    /// 知らせに出す、書ける値の言い方。
    def expectedOf(r: Row): String =
        let base = match r#kind {
            case Kind.Num(lo, hi) => "${numText(lo)}〜${numText(hi)} の数"
            case Kind.Time        => "0 以上の秒"
            case Kind.Name(_)     => "名前"
            case Kind.Choice(vs)  => String.intercalate(" / ", vs)
            case Kind.Flag        => "true / false"
            case Kind.Ease        => "ease の名前（linear・smoothstep・inOutCubic など）"
        };
        let more = r#words |> List.map(w -> " / " + w) |> String.intercalate("");
        let listed = if (r#shape == Shape.Listed) "を , で並べる" else "";
        base + listed + more

    def numText(x: Float64): String =
        if (Float64.floor(x) == x and Float64.abs(x) < 1.0e9) Int64.toString(Float64.tryToInt64(x) |> Option.getWithDefault(0i64)) else Float64.toString(x)

    /// 必須の欠けと、どれか 1 つは要る組の欠け。
    def missingOf(command: String, rows: List[Row], given: Set[String]): Result[String, Unit] =
        let lacking = rows |> List.find(r -> r#need == Need.Required and not Set.memberOf(r#name, given));
        let groups = rows |> List.map(r -> r#group) |> List.filter(g -> g != "") |> List.distinct;
        let filled = rows |> List.filter(r -> Set.memberOf(r#name, given)) |> List.map(r -> r#group) |> List.toSet;
        let emptyGroup = groups |> List.find(g -> not Set.memberOf(g, filled));
        match (lacking, emptyGroup) {
            case (Some(r), _)    => Err("<<${command}>> に ${r#name} が要る")
            case (None, Some(g)) =>
                let members = rows |> List.filter(r -> r#group == g) |> List.map(r -> r#name) |> String.intercalate(" か ");
                Err("<<${command}>> は ${members} のどれかを書く")
            case (None, None)    => Ok(())
        }

    // ── 引数の字と値 ──

    /// 数の字（- と数字と、. の後の数字だけ。1e3・.5・+1 は受けない。go の検査と同じ形）。
    def numberOf(value: String): Option[Float64] =
        let body = String.stripPrefix(substr = "-", value) |> Option.getWithDefault(value);
        let parts = String.splitOn(substr = ".", body);
        let digits = s -> s != "" and List.forAll(c -> c >= '0' and c <= '9', String.toList(s));
        let wellFormed = match parts {
            case whole :: Nil            => digits(whole)
            case whole :: frac :: Nil    => digits(whole) and digits(frac)
            case _                       => false
        };
        if (wellFormed) Float64.fromString(value) else None

    def easeOf(value: String): Option[Curve.Ease] =
        Curve.easeTable() |> List.find(row -> fst(row) == value) |> Option.map(snd)

    /// 書いてあった字（無ければ None）。表に無い引数を読むのはプログラマの誤りなので止める。
    def rawOf(name: String, args: Args): Option[String] =
        let Parsed.Parsed(a) = args;
        if (Set.memberOf(name, a#known)) Map.get(name, a#values)
        else bug!("YarnCommands: <<${a#command}>> の表に無い引数 ${name} を読んだ（spec の一覧に Param.erase を足す）")

    // ── vocab.json ──

    /// 表の一覧を vocab.json の commands（名前を鍵にした object）にする。
    pub def toJson(specs: List[Spec]): Json =
        specs |> List.map(s -> { let r = specOf(s); (r#name, commandJson(r)) }) |> List.toMap |> JObject

    def commandJson(r: { name = String, summary = String, params = List[Field] }): Json =
        JObject(Map#{ "summary" => JString(r#summary), "params" => JArray(r#params |> List.map(fieldJson) |> List.toVector) })

    def fieldJson(f: Field): Json =
        let r = fieldOf(f);
        let kindRows = match r#kind {
            case Kind.Num(lo, hi) => ("type", JString("num")) :: ("min", numJson(lo)) :: ("max", numJson(hi)) :: Nil
            case Kind.Time        => ("type", JString("time")) :: Nil
            case Kind.Name(refs)  => ("type", JString("name")) :: (if (List.isEmpty(refs)) Nil else ("ref", refsJson(refs)) :: Nil)
            case Kind.Choice(vs)  => ("type", JString("choice")) :: ("values", stringsJson(vs)) :: Nil
            case Kind.Flag        => ("type", JString("flag")) :: Nil
            case Kind.Ease        => ("type", JString("ease")) :: ("values", stringsJson(Curve.easeTable() |> List.map(fst))) :: Nil
        };
        let needRows = match r#need {
            case Need.Required     => ("req", JBool(true)) :: Nil
            case Need.Optional     => Nil
            case Need.Defaulted(d) => ("default", JString(d)) :: Nil
        };
        let extra =
            (if (r#pos > 0) ("pos", JNumber(JsonCodec.intToBd(r#pos))) :: Nil else Nil) :::
            (if (List.isEmpty(r#words)) Nil else ("orWords", stringsJson(r#words)) :: Nil) :::
            (if (List.isEmpty(r#names)) Nil else ("orNames", refsJson(r#names)) :: Nil) :::
            (if (r#shape == Shape.Listed) ("list", JBool(true)) :: Nil else Nil) :::
            (if (r#group == "") Nil else ("oneOf", JString(r#group)) :: Nil);
        JObject(List.toMap(("name", JString(r#name)) :: kindRows ::: needRows ::: extra))

    def numJson(x: Float64): Json = JNumber(JsonCodec.floatToBd(x))

    def stringsJson(xs: List[String]): Json = JArray(xs |> List.map(JString) |> List.toVector)

    def refsJson(refs: List[DocRef]): Json =
        JObject(Map#{ "from" => JArray(refs |> List.map(refJson) |> List.toVector) })

    def refJson(ref: DocRef): Json = match ref {
        case DocRef.Keys(doc, path) => JObject(Map#{ "doc" => JString(doc), "keys" => JString(path) })
        case DocRef.Path(doc, path) => JObject(Map#{ "doc" => JString(doc), "path" => JString(path) })
    }

    /// vocab.json の commands（toJson の形）を表の一覧に戻す。中身の無い {} のコマンド（引数を見ない）は一覧に入れない。
    pub def fromJson(json: Json): Result[String, List[Spec]] =
        forM (
            top   <- JsonCodec.expectObject(json) |> Option.toOk("commands は名前を鍵にした object で書く");
            specs <- top |> Map.toList |> Result.traverse(match (name, body) -> commandFromJson(name, body))
        ) yield List.flatten(specs)

    def commandFromJson(name: String, body: Json): Result[String, List[Spec]] =
        forM (
            obj    <- JsonCodec.expectObject(body) |> Option.toOk("commands の ${name} が object でない");
            params <- Map.get("params", obj) |> Option.map(p -> paramsFromJson(name, p) |> Result.map(Some)) |> Option.getWithDefault(Ok(None))
        ) yield {
            let summary = Map.get("summary", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.getWithDefault("");
            params |> Option.map(ps -> { name = name, summary = summary, params = ps })
                   |> Option.toList
                   |> List.map(CommandSpec.CommandSpec)
        }

    def paramsFromJson(command: String, json: Json): Result[String, List[Field]] =
        let rows = match json {
            case JArray(xs) => Ok(Vector.toList(xs))
            case _          => Err("commands の ${command} の params が配列でない")
        };
        forM (
            xs     <- rows;
            fields <- xs |> Result.traverse(fieldFromJson(command));
            spec   <- { let s = { name = command, summary = "", params = fields }; problemOf(s) |> Option.map(Err) |> Option.getWithDefault(Ok(s)) }
        ) yield spec#params

    def fieldFromJson(command: String, json: Json): Result[String, Field] =
        let label = "commands の ${command} の引数";
        forM (
            obj   <- JsonCodec.expectObject(json) |> Option.toOk("${label} が object でない");
            name  <- Map.get("name", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.toOk("${label} に name が無い");
            kind  <- kindFromJson(label + " " + name, obj);
            names <- Map.get("orNames", obj) |> Option.map(refsFromJson(label + " " + name)) |> Option.getWithDefault(Ok(Nil))
        ) yield {
            let text = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString);
            let need = match (Map.get("req", obj) |> Option.flatMap(JsonCodec.expectBool), text("default")) {
                case (Some(true), _) => Need.Required
                case (_, Some(d))    => Need.Defaulted(d)
                case _               => Need.Optional
            };
            Field.Field({
                name   = name,
                pos    = Map.get("pos", obj) |> Option.flatMap(JsonCodec.expectInt) |> Option.getWithDefault(0),
                kind   = kind,
                need   = need,
                words  = Map.get("orWords", obj) |> Option.map(stringsOf) |> Option.getWithDefault(Nil),
                names  = names,
                shape  = if (Map.get("list", obj) |> Option.flatMap(JsonCodec.expectBool) |> Option.getWithDefault(false)) Shape.Listed else Shape.Single,
                group  = text("oneOf") |> Option.getWithDefault("")
            })
        }

    def kindFromJson(label: String, obj: Map[String, Json]): Result[String, Kind] =
        let num = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectFloat) |> Option.toOk("${label} に ${key}（数）が無い");
        let typeName = Map.get("type", obj) |> Option.flatMap(JsonCodec.expectString) |> Option.getWithDefault("");
        match typeName {
            case "num"    => forM (lo <- num("min"); hi <- num("max")) yield Kind.Num(lo, hi)
            case "time"   => Ok(Kind.Time)
            case "name"   => Map.get("ref", obj) |> Option.map(refsFromJson(label)) |> Option.getWithDefault(Ok(Nil)) |> Result.map(Kind.Name)
            case "choice" => Ok(Kind.Choice(Map.get("values", obj) |> Option.map(stringsOf) |> Option.getWithDefault(Nil)))
            case "flag"   => Ok(Kind.Flag)
            case "ease"   =>
                // WhyNot: values の無い ease を受けない — go の検査は values で名前を照らすので、受けると build と実行時の答えが割れる
                if (Map.get("values", obj) |> Option.map(stringsOf) |> Option.getWithDefault(Nil) |> List.isEmpty) Err("${label} の ease に values が要る")
                else Ok(Kind.Ease)
            case other    => Err("${label} の type ${other} を知らない（num・time・name・choice・flag・ease）")
        }

    def stringsOf(json: Json): List[String] = match json {
        case JArray(xs) => xs |> Vector.toList |> List.filterMap(JsonCodec.expectString)
        case _          => Nil
    }

    def refsFromJson(label: String, json: Json): Result[String, List[DocRef]] =
        let rows = JsonCodec.expectObject(json) |> Option.flatMap(Map.get("from")) |> Option.map(arrayOf) |> Option.getWithDefault(Nil);
        rows |> Result.traverse(row -> refFromJson(label, row))

    def arrayOf(json: Json): List[Json] = match json {
        case JArray(xs) => Vector.toList(xs)
        case _          => Nil
    }

    def refFromJson(label: String, json: Json): Result[String, DocRef] =
        let obj = JsonCodec.expectObject(json) |> Option.getWithDefault(Map.empty());
        let text = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString);
        match (text("doc"), text("keys"), text("path")) {
            case (Some(doc), Some(keys), None) => Ok(DocRef.Keys(doc, keys))
            case (Some(doc), None, Some(path)) => Ok(DocRef.Path(doc, path))
            case _                             => Err("${label} の ref は doc と、keys か path のどちらか 1 つを書く")
        }
}
