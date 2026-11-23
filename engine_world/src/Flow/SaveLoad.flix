// Flow.SaveLoad — flow の saveload の行（セーブ → 読み直し）を入れた流れと入れない流れを両方流して比べる門。
// ゲームが渡すのは flow の表（App.withFlow）の saveRoundTrip = 書く関数と読む関数だけ（欄の一覧は書かない）。
// 比べるのは毎フレームの問いの値と最後のセーブの字。どちらもセーブに出ない一時的な状態（アニメの途中・カメラ）を含まない。
// 書いたのに読む時に落とした値・書く時に何も知らせずに落とした値は、読み直した直後の問いか、その後の遊びが変わった所のセーブの違いとして出る。
pub mod Flow.SaveLoad {
    use Util.Json.Json
    use Util.Json.Json.{JObject}

    /// saveload の行があるか（make flow が 2 本流すかを決める）。
    pub def hasSaveLoad(script: Flow.Script): Bool =
        script#lines |> List.exists(line -> match line#step {
            case Flow.Step.SaveLoad => true
            case _                  => false
        })

    /// 2 本の流れを流す（plain = 読み直さない流れ・reloaded = saveload で読み直した流れ）。どちらも同じ始まりから。
    pub def playBoth(app: App.App[w, ef], setup: Flow.Setup, script: Flow.Script, start: { world = w, state = App.StepState }):
            { plain = Result[Flow.Failure[w], Flow.Outcome[w]], reloaded = Result[Flow.Failure[w], Flow.Outcome[w]] } \ ef + Fs.FileRead =
        { plain = Flow.playWith(app, setup, script, start, Flow.SaveLoadPass.Skip),
          reloaded = Flow.playWith(app, setup, script, start, Flow.SaveLoadPass.Reload) }

    /// 2 本の結果を比べる: 両方通り、問いの値が毎フレーム同じで、フレームの数と最後のセーブが同じなら Ok(1 行の知らせ)、違えば Err(出す行の列)。
    /// path は FAIL の行に載せる flow の名前。読み直した流れが止まった時も、そこまでに問いが分かれていればその行を足す。
    pub def compareRuns(app: App.App[w, ef], path: String,
                        plain: Result[Flow.Failure[w], Flow.Outcome[w]], reloaded: Result[Flow.Failure[w], Flow.Outcome[w]]): Result[List[String], String] =
        match (plain, reloaded) {
            case (Err(failure), _) =>
                Err("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: 読み直さない流れが止まった: ${failure#why}" :: Nil)
            case (Ok(a), Err(failure)) =>
                Err(stoppedLines(failure) ::: probeLines(path, firstProbeDiff(app, a, failure#upTo)))
            case (Ok(a), Ok(b)) => sameRuns(app, path, a, b)
        }

    def stoppedLines(failure: Flow.Failure[w]): List[String] =
        ("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: saveload で読み直した流れが止まった: ${failure#why}") ::
        "    ${failure#at#text}" ::
        ("    ${Int32.toString(failure#frame)} フレーム目" + (if (failure#seen == "") "" else " / ${failure#seen}")) :: Nil

    def probeLines(path: String, split: Option[String]): List[String] =
        split |> Option.map(text -> ("FAIL ${path}: saveload で読み直した流れと読み直さない流れで、問いの値が分かれた（App.withFlow の probes）") :: "    ${text}" :: Nil)
              |> Option.getWithDefault(Nil)

    /// 両方通った 2 本: 問いの値・フレームの数・最後のセーブ。
    def sameRuns(app: App.App[w, ef], path: String, a: Flow.Outcome[w], b: Flow.Outcome[w]): Result[List[String], String] =
        let (n, m) = (List.length(a#frames), List.length(b#frames));
        let countLines = if (n == m) Nil else
            ("FAIL ${path}: saveload で読み直した流れと読み直さない流れで、フレームの数が違う: ${Int32.toString(n)} → ${Int32.toString(m)}") :: Nil;
        let last = compareLast(App.rec(app)#flow#saveRoundTrip, a#last, b#last);
        let saveLines = match last {
            case Ok(_)     => Nil
            case Err(diff) => ("FAIL ${path}: saveload で読み直した流れと読み直さない流れで、最後のセーブが違う") :: "    ${diff}" :: Nil
        };
        let lines = probeLines(path, firstProbeDiff(app, a, b)) ::: countLines ::: saveLines;
        if (List.isEmpty(lines)) Ok("読み直した流れも通り、問いの値が毎フレーム同じで、${Result.getWithDefault("", last)}") else Err(lines)

    /// 2 本の流れを同じフレームどうしで並べ、問い（unsaved に挙げた物を除く probes）の値が最初に分かれたフレームと、分かれた問い。
    /// WhyNot: World 全体（WorldHash）を比べない — 読み直しで 0 に戻るアニメの時計やカメラ、読んだセーブの写しのような
    /// セーブに出ない欄が必ず違い、どのゲームでも赤になる。問いはゲームが flow のために選んだ「遊びに影響する値」。
    /// WhyNot: 指紋（fp）を比べない — 指紋はコマ単位の再生の食い違いを指す物で、向き・入力の層・セーブの回数・乱数の回数のような
    /// セーブに書かない値を含むゲームがあり、読み直すと必ず分かれる。
    def firstProbeDiff(app: App.App[w, ef], plain: Flow.Outcome[w], reloaded: Flow.Outcome[w]): Option[String] =
        let names = probeNames(app);
        List.zip(Flow.worldsOf(plain), Flow.worldsOf(reloaded)) |> List.zipWithIndex |> List.findMap(match (i, (a, b)) -> {
            let differing = names |> List.map(name -> (name, Flow.valueOf(app, name, a), Flow.valueOf(app, name, b)))
                |> List.filter(match (_, x, y) -> x != y)
                |> List.map(match (name, x, y) -> "${name}: ${showValue(x)} → ${showValue(y)}");
            if (List.isEmpty(differing)) None
            else Some("${Int32.toString(i + 1)} フレーム目（読み直さない → 読み直した）: " + String.intercalate(" / ", List.take(8, differing)))
        })

    /// 比べる問いの名前（ゲームの probes の順・unsaved に挙げた名前を除く）。
    def probeNames(app: App.App[w, ef]): List[String] =
        let flow = App.rec(app)#flow;
        let unsaved = flow#saveRoundTrip |> Option.map(rt -> List.toSet(rt#unsaved)) |> Option.getWithDefault(Set.empty());
        flow#probes |> List.map(row -> row#name) |> List.filter(name -> not Set.memberOf(name, unsaved))

    def showValue(v: Option[Flow.Value]): String = match v {
        case Some(Flow.Value.Num(x))  => Float64.toString(x)
        case Some(Flow.Value.Text(s)) => "\"${s}\""
        case Some(Flow.Value.Flag(b)) => if (b) "true" else "false"
        case None                     => "(無い)"
    }

    /// 2 本の流れの最後の World のセーブを比べる。同じなら Ok(そのセーブの字の長さの説明)、違えば Err(違うキー)。
    pub def compareLast(trip: Option[Flow.SaveRoundTrip[w]], plain: w, reloaded: w): Result[String, String] =
        let saveOf = world -> trip |> Option.flatMap(rt -> (rt#save)(world));
        match (saveOf(plain), saveOf(reloaded)) {
            case (None, None)       => Ok("どちらもセーブを書かない場面で終わった")
            case (Some(a), Some(b)) => if (a == b) Ok("最後のセーブが同じ（${Int32.toString(String.length(a))} 字）") else Err(diffText(a, b))
            case (Some(_), None)    => Err("読み直した流れの最後はセーブを書かない場面（読み直さない流れは書く）")
            case (None, Some(_))    => Err("読み直さない流れの最後はセーブを書かない場面（読み直した流れは書く）")
        }

    /// 2 つのセーブの字の違うキー（object を "." でつないだ道。先頭の 8 個と残りの数）。JSON でなければ字の長さだけ言う。
    pub def diffText(before: String, after: String): String =
        match (DocJson.parse(before), DocJson.parse(after)) {
            case (Some(a), Some(b)) =>
                let left = leavesOf("", a, Map.empty());
                let right = leavesOf("", b, Map.empty());
                let paths = Set.union(Map.keysOf(left), Map.keysOf(right)) |> Set.toList
                    |> List.filter(path -> Map.get(path, left) != Map.get(path, right));
                let shown = paths |> List.take(8) |> List.map(path -> "${path}: ${valueText(Map.get(path, left))} → ${valueText(Map.get(path, right))}");
                let rest = List.length(paths) - List.length(shown);
                String.intercalate(" / ", shown) + (if (rest > 0) " ほか ${Int32.toString(rest)} 個" else "")
            case _ => "字が違う（${Int32.toString(String.length(before))} 字 → ${Int32.toString(String.length(after))} 字・JSON として読めない）"
        }

    def valueText(v: Option[String]): String = v |> Option.getWithDefault("(無い)")

    /// object を道ごとの葉（object でない値の字）へ開く。
    def leavesOf(prefix: String, json: Json, acc: Map[String, String]): Map[String, String] = match json {
        case JObject(fields) =>
            fields |> Map.foldLeftWithKey((m, key, v) -> leavesOf(if (prefix == "") key else "${prefix}.${key}", v, m), acc)
        case other => Map.insert(prefix, oneLine(Util.Json.toPrettyString(0, other)), acc)
    }

    /// 列の値を 1 行に詰める（字の中の改行は \n に逃がしてあるので、行の境目は値の区切りだけ）。
    def oneLine(text: String): String = TextSplit.lines(text) |> List.map(String.trim) |> String.intercalate("")
}
