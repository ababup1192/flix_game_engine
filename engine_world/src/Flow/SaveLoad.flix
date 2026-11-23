// Flow.SaveLoad — flow の saveload の行（セーブ → 読み直し）を入れた流れと入れない流れを両方流して比べる門。
// ゲームが渡すのは flow の表（App.withFlow）の saveRoundTrip = 書く関数と読む関数だけ（欄の一覧は書かない）。
// 比べるのは毎フレームの問いの値（probes と指紋）と最後のセーブの字。どちらもセーブに出ない一時的な状態（アニメの途中・カメラ）を含まない。
// 書いたのに読む時に落とした値・書く時に何も知らせずに落とした値は、読み直した直後の問いか、その後の遊びが変わった所のセーブの違いとして出る。
pub mod Flow.SaveLoad {
    use Util.Json.Json
    use Util.Json.Json.{JObject}

    /// saveload の行があるか（make flow が 2 本流すかを決める）。
    pub def hasSaveLoad(script: Flow.Script): Bool =
        script#lines |> List.exists(line -> match line#step {
            case Flow.Step.SaveLoad(_) => true
            case _                     => false
        })

    /// 読み直さない側の流れ: saveload の行を残したまま World を替えない形にする（返事を確かめるフレームの挟み方を両方でそろえる）。
    pub def withoutReload(script: Flow.Script): Flow.Script =
        let skip = (line: Flow.Line) -> match line#step {
            case Flow.Step.SaveLoad(_) => { step = Flow.Step.SaveLoad(false) | line }
            case _                     => line
        };
        { lines = script#lines |> List.map(skip) | script }

    /// 2 本の流れを流す（plain = 読み直さない流れ・reloaded = saveload で読み直した流れ）。どちらも同じ始まりから。
    pub def playBoth(app: App.App[w, ef], setup: Flow.Setup, script: Flow.Script, start: { world = w, state = App.StepState }):
            { plain = Result[Flow.Failure[w], Flow.Outcome[w]], reloaded = Result[Flow.Failure[w], Flow.Outcome[w]] } \ ef + Fs.FileRead =
        { plain = Flow.play(app, setup, withoutReload(script), start), reloaded = Flow.play(app, setup, script, start) }

    /// 2 本の結果の判定: 両方通って最後のセーブが同じなら Ok(1 行の知らせ)、違えば Err(FAIL から始まる行の列)。
    /// path は FAIL の行に載せる flow の名前。
    pub def judge(app: App.App[w, ef], path: String,
                  plain: Result[Flow.Failure[w], Flow.Outcome[w]], reloaded: Result[Flow.Failure[w], Flow.Outcome[w]]): Result[List[String], String] =
        match (plain, reloaded, App.rec(app)#flow#saveRoundTrip) {
            case (_, _, None) => Err("FAIL ${path}: saveload の行があるが flow の表（App.withFlow）に saveRoundTrip が無い" :: Nil)
            case (Err(failure), _, _) =>
                Err("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: 読み直さない流れが止まった: ${failure#why}" :: Nil)
            case (_, Err(failure), _) =>
                Err(("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: saveload で読み直した流れが止まった: ${failure#why}") ::
                    "    ${failure#at#text}" ::
                    ("    ${Int32.toString(failure#frame)} フレーム目" + (if (failure#seen == "") "" else " / ${failure#seen}")) :: Nil)
            case (Ok(a), Ok(b), Some(trip)) =>
                let probeLines = match firstProbeDiff(app, a, b) {
                    case Some(text) => ("FAIL ${path}: saveload で読み直した流れと読み直さない流れで、問いの値が分かれた（App.withFlow の probes）") :: "    ${text}" :: Nil
                    case None       => Nil
                };
                match (probeLines, compareLast(trip, a#last, b#last)) {
                    case (Nil, Ok(note)) => Ok("読み直した流れも通り、問いの値が毎フレーム同じで、${note}")
                    case (lines, Ok(_))  => Err(lines)
                    case (lines, Err(diff)) =>
                        Err(lines ::: ("FAIL ${path}: saveload で読み直した流れと読み直さない流れで、最後のセーブが違う") :: "    ${diff}" :: Nil)
                }
        }

    /// 2 本の流れを同じフレームどうしで並べ、問いの値（probes と指紋）が最初に分かれたフレームと、分かれた問い。フレームの数が違えばそれも言う。
    /// WhyNot: World 全体（WorldHash）を比べない — 読み直しで 0 に戻るアニメの時計やカメラ、読んだセーブの写しのような
    /// セーブに出ない欄が必ず違い、どのゲームでも赤になる。問いはゲームが flow のために選んだ「遊びに影響する値」。
    def firstProbeDiff(app: App.App[w, ef], plain: Flow.Outcome[w], reloaded: Flow.Outcome[w]): Option[String] =
        let left = Flow.worldsOf(plain);
        let right = Flow.worldsOf(reloaded);
        let split = List.zip(left, right) |> List.zipWithIndex |> List.findMap(match (i, (a, b)) -> {
            let differing = List.zip(probesOf(app, a), probesOf(app, b)) |> List.filter(match ((_, x), (_, y)) -> x != y)
                |> List.map(match ((name, x), (_, y)) -> "${name}: ${showValue(x)} → ${showValue(y)}");
            if (List.isEmpty(differing)) None
            else Some("${Int32.toString(i + 1)} フレーム目（読み直さない → 読み直した）: " + String.intercalate(" / ", List.take(8, differing)))
        });
        let (n, m) = (List.length(left), List.length(right));
        match split {
            case Some(text) => Some(text)
            case None if n != m => Some("フレームの数が違う: 読み直さない流れ ${Int32.toString(n)}・読み直した流れ ${Int32.toString(m)}")
            case None => None
        }

    /// 問いの名前と値（ゲームの probes の順・指紋を繋いだゲームは最後に fp）。
    def probesOf(app: App.App[w, ef], world: w): List[(String, Option[Flow.Value])] =
        let names = App.rec(app)#flow#probes |> List.map(row -> row#name);
        let withFp = if (Option.nonEmpty(App.rec(app)#fingerprint)) List.append(names, Flow.fingerprintProbe() :: Nil) else names;
        withFp |> List.map(name -> (name, Flow.valueOf(app, name, world)))

    def showValue(v: Option[Flow.Value]): String = match v {
        case Some(Flow.Value.Num(x))  => Float64.toString(x)
        case Some(Flow.Value.Text(s)) => "\"${s}\""
        case Some(Flow.Value.Flag(b)) => if (b) "true" else "false"
        case None                     => "(無い)"
    }

    /// 2 本の流れの最後の World のセーブを比べる。同じなら Ok(そのセーブの字の長さの説明)、違えば Err(違うキー)。
    pub def compareLast(trip: Flow.SaveRoundTrip[w], plain: w, reloaded: w): Result[String, String] =
        match ((trip#save)(plain), (trip#save)(reloaded)) {
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
