// ScriptEdits — 付箋の頁の「ここから遊ぶ」が URL に載せた始まりの行とシナリオの直しを、今のシナリオに当てる（純粋）。
// 行は「前の文」の FNV-1a（UTF-8・16 進 8 桁）で確かめる。頁（go/internal/tape/template.html の fnv1a）と同じ字・同じ計算。
// 行の番号が合っていても前の文が違えば当てない（シナリオが書き換わった後に古い直しが別の行へ入らないように）。
mod ScriptEdits {
    use fge::Yarn

    /// ノードの中の 1 行。text = 台詞の文（地の文も）か演出コマンドの字（<<名前 引数…>>）。
    /// say = 台詞の行なら Some（直しを当てられるのは台詞だけ）。
    pub type alias Row = { line = Int32, text = String, say = Option[Yarn.Line] }

    /// 当てた直し。lines = (ファイル, 行) → 後の文、edited = edit.* を受けて開いたか（バナーを出す）、
    /// skipped = 前の文が合わず当てなかった行の数。
    pub type alias Applied = { lines = Map[(String, Int32), String], edited = Bool, skipped = Int32 }

    pub def none(): Applied = { lines = Map.empty(), edited = false, skipped = 0 }

    /// UTF-8 の FNV-1a 32bit を 16 進 8 桁で。
    pub def fnv1a(text: String): String =
        let mask = 0xFFFFFFFFi64;
        let hash = String.toBytes(text) |> Vector.foldLeft((h, b) ->
            Int64.bitwiseAnd(Int64.bitwiseXor(h, Int64.bitwiseAnd(Int8.toInt64(b), 0xFFi64)) * 16777619i64, mask), 2166136261i64);
        List.range(0, 8) |> List.map(i -> {
            let nibble = Int64.bitwiseAnd(Int64.rightShift(hash, 4 * (7 - i)), 0xFi64);
            Char.toString(String.charAt(Int64.tryToInt32(nibble) |> Option.getWithDefault(0), "0123456789abcdef"))
        }) |> String.flatten

    /// ノードの行（選択肢と <<if>> の中も。書いた順）。<<set>> と <<stop>> は字を持たないので載せない。
    pub def rowsOf(node: Yarn.Node): List[Row] = statementRows(node#body)

    def statementRows(body: List[Yarn.Statement]): List[Row] =
        body |> List.flatMap(statement -> match statement {
            case Yarn.Statement.Say(line)        => sayRow(line) :: Nil
            case Yarn.Statement.Command(command) => cmdRow(command#source#line, command#name :: command#args) :: Nil
            case Yarn.Statement.Jump(target, at) => cmdRow(at#line, "jump" :: target :: Nil) :: Nil
            case Yarn.Statement.Choose(choices)  => choices |> List.flatMap(c -> sayRow(c#line) :: statementRows(c#body))
            case Yarn.Statement.If(branches, _)  => branches |> List.flatMap(b -> statementRows(b#body))
            case Yarn.Statement.Stop(_)          => Nil
            case Yarn.Statement.Set(_, _, _)     => Nil
        })

    def sayRow(line: Yarn.Line): Row = { line = line#source#line, text = line#text, say = Some(line) }

    def cmdRow(at: Int32, words: List[String]): Row = { line = at, text = "<<${String.intercalate(" ", words)}>>", say = None }

    /// 始める行。at（前の文のハッシュ）が無ければ line のまま（Studio の会話のプレビュー・bin/fge talk goto）。
    /// at がある時は、line の今の文が合えば line、合わなければ同じ文の行をノードの中で探し、無ければノードの頭（0）。
    pub def startLine(rows: List[Row], line: Option[Int32], at: Option[String]): Int32 = match at {
        case None       => Option.getWithDefault(0, line)
        case Some(hash) =>
            let matches = (r: Row) -> fnv1a(r#text) == hash;
            let here = line |> Option.flatMap(n -> rows |> List.find(r -> r#line == n)) |> Option.filter(matches);
            let found = if (Option.isEmpty(here)) rows |> List.find(matches) else here;
            found |> Option.map(r -> r#line) |> Option.getWithDefault(0)
    }

    /// 引数の edit.<行>=<後の文> を、was.<行> が今の台詞の文のハッシュに合う行にだけ当てる。file = ノードを書いたファイル。
    pub def applyArgs(file: String, rows: List[Row], args: Map[String, String]): Applied =
        let edits = args |> Map.toList |> List.filterMap(match (key, after) ->
            String.stripPrefix({substr = "edit."}, key) |> Option.map(n -> (n, after)));
        let fits = (n: String) -> forM (
            line <- Int32.fromString(n);
            row  <- rows |> List.find(r -> r#line == line);
            _    <- row#say;
            was  <- Map.get("was.${n}", args);
            if fnv1a(row#text) == was
        ) yield line;
        let (applied, skipped) = edits |> List.foldLeft((acc, pair) -> {
            let (done, missed) = acc;
            let (n, after) = pair;
            match fits(n) {
                case Some(line) => (Map.insert((file, line), after, done), missed)
                case None       => (done, missed + 1)
            }
        }, (Map.empty(), 0));
        { lines = applied, edited = not List.isEmpty(edits), skipped = skipped }

    /// 台詞の行に直しを当てる（直しの無い行はそのまま）。
    // WhyNot: parts を元のまま残さない — 画面とバックログは parts のマークアップ・ルビ・{式} から字を組むので、text だけ替えると前の文が出る。
    pub def editLine(applied: Applied, line: Yarn.Line): Yarn.Line =
        match Map.get((line#source#file, line#source#line), applied#lines) {
            case Some(after) => { text = after, parts = Yarn.Part.Literal(after) :: Nil | line }
            case None        => line
        }
}
