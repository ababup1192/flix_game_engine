// YarnCommands.Param — コマンドの引数 1 つを表に書く部品と、parse を通った引数を型付きで読む口。
// 部品は Opt（書かなければ値が無い）を作り、at・orWords・orNames・list・oneOf・scopedBy で形を足し、
// required か default で Req（いつも値がある）にする。time と ease は既定の値つきの Req を直に作る。
//
//   let alpha = Param.num("alpha", 0.0, 1.0) |> Param.at(1) |> Param.required;   // Req[Float64]
//   let color = Param.choice("color", "black" :: "white" :: Nil) |> Param.default("black");
//   let from  = Param.num("from", 0.0, 1.0);                                        // Opt[Float64]
//   Param.get(alpha, args)  /  Param.getOpt(from, args)
pub mod YarnCommands.Param {
    use YarnCommands.{Field, Handle, Kind, Need, Shape, DocRef, Args}

    /// Req を見分ける型（書かなくても値がある）。
    pub enum Must

    /// Opt を見分ける型（書かなければ値が無い）。
    pub enum May

    /// 書かなくても値がある引数（required・default・time・ease）。読むのは get。
    pub type alias Req[t] = Handle[Must, t]

    /// 書かなければ値が無い引数。読むのは getOpt。
    pub type alias Opt[t] = Handle[May, t]

    /// 型を消した引数（YarnCommands.spec に並べる）。
    pub type alias Erased = Field

    /// orWords の語か orNames の名前（Word）と、型どおりの値（Value）。
    pub enum Or[t] with Eq {
        case Value(t)
        case Word(String)
    }

    instance ToString[Or[t]] with ToString[t] {
        pub def toString(x: Or[t]): String = match x {
            case Or.Value(v) => ToString.toString(v)
            case Or.Word(w)  => w
        }
    }

    // ── 部品 ──

    /// min 以上 max 以下の数。
    pub def num(name: String, min: Float64, max: Float64): Opt[Float64] =
        optional(name, Kind.Num(min, max), YarnCommands.numberOf, YarnCommands.plainNumber)

    /// time=秒（0 以上）。書かなければ fallback。
    pub def time(fallback: Float64): Req[Float64] =
        optional("time", Kind.Time, YarnCommands.numberOf, YarnCommands.plainNumber) |> default(fallback)

    /// ease=曲線の名前（Curve.easeTable）。書かなければ fallback。
    pub def ease(fallback: Curve.Ease): Req[Curve.Ease] =
        optional("ease", Kind.Ease, YarnCommands.easeOf, ToString.toString) |> default(fallback)

    /// values のどれか。
    pub def choice(name: String, values: List[String]): Opt[String] =
        let known = List.toSet(values);
        optional(name, Kind.Choice(values), v -> if (Set.memberOf(v, known)) Some(v) else None, v -> v)

    /// 名前。refs は build が照らす Doc（Nil なら照らさない）。
    pub def name(name: String, refs: List[DocRef]): Opt[String] =
        optional(name, Kind.Name(refs), v -> if (v == "") None else Some(v), v -> v)

    /// 「名.点」（whale.mouth）を (名, 点) で読む。. がちょうど 1 つで両側が空でない時だけ受ける。refs は build が照らす Doc。
    pub def marker(name: String, refs: List[DocRef]): Opt[(String, String)] =
        optional(name, Kind.Marker(refs), YarnCommands.markerOf, match (n, p) -> "${n}.${p}")

    /// 空でない字（"…" で書けば空白も含む）。
    pub def text(name: String): Opt[String] =
        optional(name, Kind.Text, v -> if (v == "") None else Some(v), v -> v)

    /// true か false。
    pub def flag(name: String): Opt[Bool] =
        optional(name, Kind.Flag, v -> if (v == "true") Some(true) else if (v == "false") Some(false) else None, b -> if (b) "true" else "false")

    /// encode は値を台本に書く字へ戻す（既定の値を vocab.json に書き、型で照らす）。
    def optional(name: String, kind: Kind, decode: String -> Option[t], encode: t -> String): Opt[t] =
        Handle.Handle({
            field    = Field.Field({ name = name, pos = 0, kind = kind, need = Need.Optional, words = Nil, names = Nil, shape = Shape.Single, group = "", scope = "" }),
            decode   = decode,
            encode   = encode,
            fallback = None
        })

    // ── 形を足す ──

    /// 位置 pos（1 か 2）でも書ける。
    pub def at(pos: Int32, h: Opt[t]): Opt[t] = withRow(r -> { pos = pos | r }, h)

    /// 書かなければ誤り。
    pub def required(h: Opt[t]): Req[t] =
        let Handle.Handle(x) = withRow(r -> { need = Need.Required | r }, h);
        Handle.Handle(x)

    /// 書かなければ fallback。
    /// WhyNot: 既定の字を ToString で作らない — Float64 は 0.001 未満と 1e7 以上で 1.0E-4 の形になり、台本の数の形に合わない。
    pub def default(fallback: t, h: Opt[t]): Req[t] =
        let Handle.Handle(y) = h;
        let Handle.Handle(x) = withRow(r -> { need = Need.Defaulted(y#encode(fallback)) | r }, h);
        Handle.Handle({ fallback = Some(fallback) | x })

    /// 型の外に words の語も受ける（off・all など）。
    pub def orWords(words: List[String], h: Opt[t]): Opt[Or[t]] =
        let known = List.toSet(words);
        let Handle.Handle(x) = withRow(r -> { words = List.append(r#words, words) | r }, h);
        Handle.Handle({
            field    = x#field,
            decode   = v -> if (Set.memberOf(v, known)) Some(Or.Word(v)) else x#decode(v) |> Option.map(Or.Value),
            encode   = orText(x#encode),
            fallback = None
        })

    /// 型に合わない値を、refs の Doc の名前として受ける（数か音量の名前、など）。
    pub def orNames(refs: List[DocRef], h: Opt[t]): Opt[Or[t]] =
        let Handle.Handle(x) = withRow(r -> { names = List.append(r#names, refs) | r }, h);
        Handle.Handle({
            field    = x#field,
            decode   = v -> x#decode(v) |> Option.map(Or.Value) |> Option.withDefault(default = if (v == "") None else Some(Or.Word(v))),
            encode   = orText(x#encode),
            fallback = None
        })

    /// , で区切って並べた値（a,b）。
    pub def list(h: Opt[t]): Opt[List[t]] =
        let Handle.Handle(x) = withRow(r -> { shape = Shape.Listed | r }, h);
        Handle.Handle({
            field    = x#field,
            decode   = v -> String.splitOn(substr = ",", v) |> Option.traverse(x#decode),
            encode   = vs -> vs |> List.map(x#encode) |> String.intercalate(","),
            fallback = None
        })

    def orText(inner: t -> String, x: Or[t]): String = match x {
        case Or.Value(v) => inner(v)
        case Or.Word(w)  => w
    }

    /// 同じ group の引数のどれか 1 つは要る（hide の名前か at= など）。
    pub def oneOf(group: String, h: Opt[t]): Opt[t] = withRow(r -> { group = group | r }, h)

    /// build が ref を「同じ行の引数 other の値 + "." + この値」で照らす（other を書いていない・other が orWords の語の時は照らさない）。
    // WhyNot: 実行時の parse では照らさない — Doc を持たないのは ref と同じ。照らすのは名前を引く apply。
    pub def scopedBy(other: String, h: Opt[t]): Opt[t] = withRow(r -> { scope = other | r }, h)

    def withRow(f: YarnCommands.Row -> YarnCommands.Row, h: Handle[m, t]): Handle[m, t] =
        let Handle.Handle(x) = h;
        let Field.Field(r) = x#field;
        Handle.Handle({ field = Field.Field(f(r)) | x })

    /// 表に並べる形にする。
    pub def erase(h: Handle[m, t]): Erased =
        let Handle.Handle(x) = h;
        x#field

    // ── 読む ──

    /// 引数の値（書いてなければ既定の値）。
    pub def get(h: Req[t], args: Args): t =
        let Handle.Handle(x) = h;
        match valueOf(h, args) |> Option.withDefault(default = x#fallback) {
            case Some(v) => v
            case None    => bug!("YarnCommands.Param.get: ${nameOf(h)} に値が無い（parse が必須を見ている）")
        }

    /// 引数の値（書いてなければ None）。
    pub def getOpt(h: Opt[t], args: Args): Option[t] = valueOf(h, args)

    def valueOf(h: Handle[m, t], args: Args): Option[t] =
        let Handle.Handle(x) = h;
        YarnCommands.rawOf(nameOf(h), args) |> Option.map(raw -> match x#decode(raw) {
            case Some(v) => v
            case None    => bug!("YarnCommands.Param: ${nameOf(h)} の ${raw} を読めない（parse の型の検査と decode がずれている）")
        })

    def nameOf(h: Handle[m, t]): String =
        let Handle.Handle(x) = h;
        let Field.Field(r) = x#field;
        r#name
}
