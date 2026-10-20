// Flow.Cli — flow を画面なしで流す headless の入口の中身（ゲームの src/E2e.flix の play がこれを呼ぶ）。
// bin/fge flow run / make flow FLOW=e2e/x.flow がこの入口を描き出しの jar から流す（Flix を組み直さない）。
// 語彙（e2e/vocab.json）は毎回書き直す —— bin/fge flow check（Go・JVM なし）が読む物を、ゲームの今の表にそろえる。
//
// 環境変数:
//   FLOW       = 手順のファイル（無ければ語彙だけ書く）
//   FLOW_MODE  = run（既定・画面なしで最後まで流す）| check（読むだけ）| vocab（語彙だけ書く）
//   FLOW_VOCAB = 語彙の書き先（既定 e2e/vocab.json）
// 失敗（読めない行・待ちの打ち切り・expect）は行番号つきで 1 行目に FAIL と書き、終わりの番号 1 で抜ける。
pub mod Flow.Cli {

    /// プロセスの環境変数で mainOf を流し、失敗ならその終了コードでプロセスを終える。
    pub def main(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + Fs.FileWrite + IO =
        ProcessEnv.exitWith(mainOf(app, ProcessEnv.snapshot()))

    /// main の中身。env は入口の頭で読んだ環境変数の表（常駐なら App.Headless.envOf(req)）。戻り値は終了コード。
    pub def mainOf(app: App.App[w, ef], env: Map[String, String]): Int32 \ ef + Fs.FileRead + Fs.FileWrite + IO =
        let design = App.loadProjectDesign(".");
        let fresh = App.freshWorld(app, design);
        let vocab = Flow.vocabOf(app, fresh);
        let vocabPath = getEnvOr(env, "FLOW_VOCAB", "e2e/vocab.json");
        let wrote = writeText(vocabPath, Flow.vocabJson(vocab));
        let path = getEnvOr(env, "FLOW", "");
        let mode = getEnvOr(env, "FLOW_MODE", "run");
        if (path == "" or mode == "vocab") {
            println(if (wrote) "[flow] 語彙を書いた: ${vocabPath}" else "[flow] 語彙を書けない: ${vocabPath}（フォルダが無い?）");
            0
        } else match Flow.Parse.parseFile(vocab, path, readText) {
            case Err(problems) =>
                println("FAIL ${Int32.toString(List.length(problems))} 行を読めない\n" + Flow.Parse.problemsText(problems));
                1
            case Ok(script) =>
                if (mode == "check") {
                    println("ok ${path}: ${Int32.toString(List.length(script#lines))} 手を読めた");
                    0
                } else report(app, path, Flow.play(app, { design = design, limit = 100000000 }, script,
                                                   { world = startWorld(app, design, fresh, script), state = App.freshStepState() }), script#fps)
        }

    /// 語彙だけを書く（ゲームの E2e.vocab が呼ぶ。bin/headless-run が jar を作った時・make flow-vocab）。
    pub def writeVocabOf(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + Fs.FileWrite + IO =
        discard vocabMainOf(app, ProcessEnv.snapshot())

    /// writeVocabOf の中身。env は入口の頭で読んだ環境変数の表。書けなくても 0 を返す（理由は 1 行出す）。
    pub def vocabMainOf(app: App.App[w, ef], env: Map[String, String]): Int32 \ ef + Fs.FileRead + Fs.FileWrite + IO =
        let vocab = Flow.vocabOf(app, App.freshWorld(app, App.loadProjectDesign(".")));
        let path = getEnvOr(env, "FLOW_VOCAB", "e2e/vocab.json");
        println(if (writeText(path, Flow.vocabJson(vocab))) "[flow] 語彙を書いた: ${path}" else "[flow] 語彙を書けない: ${path}（フォルダが無い?）");
        0

    /// 先頭の手が start でない時に流し始める World: 登録簿の先頭の始まり（無ければ新しく作った初期の World）。
    pub def startWorld(app: App.App[w, ef], design: Vec2.Vec2, fresh: w, script: Flow.Script): w \ ef + Fs.FileRead =
        let startsFirst = match List.head(script#lines) {
            case Some(line) => match line#step {
                case Flow.Step.Start(_, _, _) => true
                case _                        => false
            }
            case None => false
        };
        match (startsFirst, List.head(App.rec(app)#starts)) {
            case (false, Some(first)) => App.buildStart(app, design, first#name, Map.empty()) |> Result.getWithDefault(fresh)
            case _                    => fresh
        }

    def report(app: App.App[w, ef], path: String, result: Result[Flow.Failure[w], Flow.Outcome[w]], fps: Float64): Int32 \ ef + IO =
        let seconds = frames -> Float64.toString(Float64.round(Int32.toFloat64(frames) / fps * 100.0) / 100.0);
        match result {
            case Ok(outcome) =>
                let count = List.length(outcome#frames);
                println("ok ${path}: ${Int32.toString(count)} フレーム（${seconds(count)} 秒）${fingerprintPart(app, outcome#last)}");
                println(placesText(outcome));
                println(statusPart(app, outcome#last));
                0
            case Err(failure) =>
                println("FAIL ${failure#at#file}:${Int32.toString(failure#at#number)}: ${failure#why}");
                println("    ${failure#at#text}");
                println("    ${Int32.toString(failure#frame)} フレーム目（${seconds(failure#frame)} 秒）" +
                        (if (failure#seen == "") "" else " / ${failure#seen}"));
                1
        }

    /// 始まりと mark の場所（何フレーム目か）を 1 行に。
    def placesText(outcome: Flow.Outcome[w]): String =
        let starts = outcome#starts |> List.map(match (at, name) -> "start ${name} @${Int32.toString(at)}");
        let marks = outcome#marks |> Map.toList |> List.sortBy(snd) |> List.map(match (name, at) -> "mark ${name} @${Int32.toString(at)}");
        let all = List.append(starts, marks);
        if (List.isEmpty(all)) "  （start・mark なし）" else "  " + String.intercalate(" / ", all)

    def fingerprintPart(app: App.App[w, ef], world: w): String =
        match App.rec(app)#fingerprint {
            case Some(f) => "・指紋 ${Flow.fingerprintOf(f(world))}"
            case None    => ""
        }

    def statusPart(app: App.App[w, ef], world: w): String \ ef =
        match App.rec(app)#statusLine {
            case Some(line) => "  [status] ${line(world)}"
            case None       => "  [status] (App.withStatusLine を繋ぐと最後の World の要点が出る)"
        }

    /// プロセスの環境変数（無いか空なら fallback）。入口の頭だけで使う。奥では getEnvOr で引数の表を引く。
    pub def envOr(name: String, fallback: String): String \ IO =
        getEnvOr(ProcessEnv.snapshot(), name, fallback)

    /// env の表の値（無いか空なら fallback）。
    pub def getEnvOr(env: Map[String, String], name: String, fallback: String): String =
        match Map.get(name, env) {
            case Some(value) if not String.isEmpty(value) => value
            case _                                        => fallback
        }

    /// ファイルを読む（読めなければ理由）。
    pub def readText(path: String): Result[String, String] \ Fs.FileRead =
        Fs.FileRead.read(path) |> Result.mapErr(e -> "${path} を読めない（${e}）")

    /// ファイルに書く（書けたか）。
    pub def writeText(path: String, text: String): Bool \ Fs.FileWrite =
        run { Fs.WriteFile.write({str = text}, path) |> Result.isOk } with Fs.WriteFile.runWithFileWrite
}
