// App.Internal.Hitch — 実機のループのヒッチの記録（DEBUG の起動だけ）と POST /perf（flow の World の列をウィンドウへ塗って測る）。判定と報告の中身は App.HitchDetector。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.Hitch {
    import java.lang.System

    /// 見張りの状態: 判定（HitchDetector）・この実行の置き場・前のコマまでの GC の合計。
    /// minors は単発（GC や swap だけの 1 コマ）の種類 → 1 行（新しい順）。
    pub type alias HitchWatch = { config = App.HitchDetector.Config, detector = App.HitchDetector.Detector, runDir = String,
                              gc = Int32, gcMs = Int64, minors = Map[String, List[String]] }

    /// DEBUG の起動で見張りを始める（描く側の診断を入れ、置き場を作る）。
    pub def startHitchWatch(): HitchWatch \ (Platform.Diagnostics + IO) =
        Platform.Diagnostics.setDiagnosticsEnabled(true);
        let config = App.HitchDetector.defaultConfig();
        let (gc, gcMs) = App.HitchDetector.gcNow();
        { config = config, detector = App.HitchDetector.fresh(config), runDir = App.HitchDetector.prepareRunDir(5), gc = gc, gcMs = gcMs,
          minors = Map.empty() }

    /// 1 コマぶんの測った時刻（start は 1 周の始まり、updateNs は World を進めた時間、renderNs は描く所）。
    /// withPipelinedRendering の App では、updateNs は描いた後に World を進め終わるのを待った時間（進める方が描くより重い分）。
    pub type alias FrameTiming = { frame = Int64, start = Int64, updateNs = Int64, renderNs = Int64, pressed = Set[GameEngine.Key], reloaded = Bool }

    def keysText(keys: Set[GameEngine.Key]): String =
        Set.toList(keys) |> List.map(k -> "${k}") |> String.intercalate(",")

    /// 描き終わったコマを 1 行にする。ゲームの状態の 1 行は、手のあるコマと重いコマだけで作る（毎コマ作ると見張り自身が重くなる）。
    /// diag = そのコマの診断（consumeDiagnostics は App が 1 コマに 1 回だけ呼んで配る。2 回呼ぶと片方が空になる）。
    def hitchRow(app: App[w, ef], watch: HitchWatch, timing: FrameTiming, diag: FrameDiagnostics.Diagnostics, world: w): (App.HitchDetector.Row, HitchWatch) \ (ef + IO) =
        let (gc, gcMs) = App.HitchDetector.gcNow();
        let base = { frame = timing#frame, totalNs = System.nanoTime() - timing#start, updateNs = timing#updateNs,
                     renderNs = timing#renderNs, diag = diag,
                     gc = gc - watch#gc, gcMs = gcMs - watch#gcMs, pressed = keysText(timing#pressed), status = "",
                     reloaded = timing#reloaded };
        let row = if (base#pressed != "" or App.HitchDetector.isSlow(watch#config, base))
                      { status = App.rec(app)#statusLine |> Option.map(toLine -> toLine(world)) |> Option.getWithDefault("") | base }
                  else base;
        (row, { gc = gc, gcMs = gcMs | watch })

    /// 実機の 1 コマを見張りへ渡す。ヒッチが閉じたら、遊んだ記録をその最初のコマの手前まで戻す形で写し、報告を書く。
    pub def watchHitches(app: App[w, ef], hitches: Option[HitchWatch], recorder: Option[Flow.Record.Recorder],
                         timing: FrameTiming, diag: Option[FrameDiagnostics.Diagnostics], world: w): Option[HitchWatch] \ (ef + IO) =
        match hitches {
            case None        => None
            case Some(watch) =>
                let (row, counted) = hitchRow(app, watch, timing, Option.getWithDefault(FrameDiagnostics.empty(), diag), world);
                let (detector, closed) = App.HitchDetector.step(row, counted#detector);
                let stepped = { detector = detector | counted };
                Some(closed |> Option.map(hitch -> writeHitch(stepped, recorder, timing#frame, hitch)) |> Option.getWithDefault(stepped))
        }

    /// 閉じた 1 件を書く。単発は置き場の summary.md に数を足すだけ、それ以外は f<コマ>/hitch.md と記録の写し。
    def writeHitch(watch: HitchWatch, recorder: Option[Flow.Record.Recorder], nowFrame: Int64, hitch: App.HitchDetector.Hitch): HitchWatch \ IO =
        if (App.HitchDetector.isMinor(watch#config, hitch)) {
            let (kind, line) = App.HitchDetector.minorOf(hitch);
            let minors = Map.insert(kind, line :: Map.getWithDefault(kind, Nil, watch#minors), watch#minors);
            discard App.HitchDetector.writeFile(watch#runDir, "summary.md", minorSummary(minors));
            { minors = minors | watch }
        } else match List.head(hitch#rows) {
            case None        => watch
            case Some(first) =>
                let dir = "${watch#runDir}/f${Int64.toString(first#frame)}";
                // /perf で塗る最後のコマ数: 前に付けたコマ + ヒッチ + 閉じるまでの落ち着いたコマ。
                let last = nowFrame - first#frame + 1i64 + Int32.toInt64(List.length(hitch#context));
                let replay = if (Option.isEmpty(recorder)) None else Some((dir, last));
                if (App.HitchDetector.write(dir, App.HitchDetector.report(watch#config, replay, hitch))) {
                    Option.forEach(rc -> discard Flow.Record.copyMarked(rc, dir, 0,
                        "# ヒッチ: 起動からヒッチの最後のコマまでの手（POST /perf の last で最後のコマだけ塗る）", "hitch"), recorder);
                    println("[hitch] ${dir}/hitch.md")
                } else ();
                watch
        }

    /// 単発の数の表（種類ごとの件数と、新しい 5 件）。
    def minorSummary(minors: Map[String, List[String]]): String =
        let lines = Map.toList(minors) |> List.flatMap(entry -> {
            let (kind, items) = entry;
            "- ${kind} の単発 ${Int32.toString(List.length(items))} 回（重いコマが 1 つだけで、シェーダー・字・テクスチャは無し）" ::
            (List.take(5, items) |> List.map(item -> "  - ${item}"))
        });
        String.intercalate("\n", "# 単発（1 件にしなかった 1 コマ）" :: "" :: lines) + "\n"

    /// POST /perf?path=<flow>（本文に flow でもよい）&last=N&warmup=N: flow を決まった刻みで流した World の列を、
    /// 実機のウィンドウへ 1 コマずつ塗り、ヒッチの記録と同じ判定・同じ報告を書く。World の列は flow だけで決まるので、
    /// 何度流しても同じ絵を同じ順に塗る（直す前と後を、作ったシェーダーの数で比べられる）。
    /// 測るのは塗る側だけ（更新は前もって流し終えている）。last=N なら最後の N コマだけを塗る（長い記録の手前は流すだけ）。
    /// FLIX_GE_HIDDEN=1 なら vsync を待たない。走っている World は変えない。
    pub def perfRun(app: App[w, ef], warnOnce: String -> Unit, design: Vec2.Vec2, bridge: App.RemoteDebug.Bridge, request: App.RemoteDebug.Request,
                    hitches: Option[HitchWatch], painted: App.Internal.Paint.Painted): App.Internal.Paint.Painted \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + Platform.Diagnostics + Fs.FileRead + IO) =
        let fresh = App.freshWorld(app, design);
        let vocab = Flow.vocabOf(app, fresh);
        let (name, parsed) = match Map.get("path", request#params) {
            case Some(path) => (perfNameOf(path), Flow.Parse.parseFile(vocab, path, Flow.Cli.readText))
            case None       => ("body", Flow.Parse.parseText(vocab, "body", request#body))
        };
        match (hitches, parsed) {
            case (None, _) =>
                App.RemoteDebug.respond("error: /perf は DEBUG の起動で使う（描く側の診断を集めていない）\n", bridge);
                painted
            case (_, Err(problems)) =>
                App.RemoteDebug.respond("error: " + Flow.Parse.problemsText(problems) + "\n", bridge);
                painted
            case (Some(watch), Ok(script)) =>
                let start = Flow.Cli.startWorld(app, design, fresh, script);
                match Flow.play(app, { design = design, limit = 200000 }, script, { world = start, state = App.freshStepState() }) {
                    case Err(failure) =>
                        App.RemoteDebug.respond("error: ${failure#at#file}:${Int32.toString(failure#at#number)} で止まった（${failure#why}）\n", bridge);
                        painted
                    case Ok(outcome) =>
                        let warmup = Map.get("warmup", request#params) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(0);
                        let config = { warmup = Int32.toInt64(warmup), maxHitches = 50 | watch#config };
                        let runDir = "${watch#runDir}/perf-${name}-${Int64.toString(System.currentTimeMillis())}";
                        let total = List.length(outcome#frames);
                        let last = Map.get("last", request#params) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(total);
                        let frames = outcome#frames |> List.zipWithIndex |> List.drop(Int32.max(0, total - last));
                        let (rows, files, after) = perfPaint(app, warnOnce, design, { config = config, runDir = runDir | watch }, frames, painted);
                        App.RemoteDebug.respond(perfSummary(name, config, rows, files), bridge);
                        after
                }
        }

    def perfNameOf(path: String): String =
        let base = path |> String.split(regex = "/") |> List.last |> Option.getWithDefault(path);
        if (String.endsWith(suffix = ".flow", base)) String.dropRight(5, base) else base

    /// World の列を 1 コマずつ塗り、見張りと同じ判定に通す。返すのは全部の行・書いた報告・描き方の覚え。
    def perfPaint(app: App[w, ef], warnOnce: String -> Unit, design: Vec2.Vec2, watch0: HitchWatch, frames: List[(Int32, Flow.Played[w])], painted: App.Internal.Paint.Painted):
            (List[App.HitchDetector.Row], List[String], App.Internal.Paint.Painted) \ (ef + Platform.Window + Platform.Rendering + RenderTarget.Target + Platform.Diagnostics + IO) =
        discard Platform.Diagnostics.consumeDiagnostics();
        let begin = { detector = App.HitchDetector.fresh(watch0#config) | watch0 };
        let (rowsRev, filesRev, watch, last) = frames |> List.foldLeft((acc, entry) -> {
            let (rows, files, w0, p) = acc;
            let (i, played) = entry;
            let startNs = System.nanoTime();
            let (cache1, seen1, warned1) = App.Internal.Paint.renderFrame(app, warnOnce, None, design, Platform.Window.getDisplay(), played#step#after, App.Internal.Paint.plainLook(Nil), p#tileCache, p#glyphSeen, p#budgetWarned);
            Platform.Window.presentFrame();
            let timing = { frame = Int32.toInt64(i), start = startNs, updateNs = 0i64, renderNs = System.nanoTime() - startNs,
                           pressed = played#step#frame#justPressed, reloaded = false };
            let (row, counted) = hitchRow(app, w0, timing, Platform.Diagnostics.consumeDiagnostics(), played#step#after);
            let (detector, closed) = App.HitchDetector.step(row, counted#detector);
            let written = closed |> Option.map(hitch -> perfWriteHitch(counted, hitch)) |> Option.toList |> List.flatten;
            (row :: rows, List.append(written, files), { detector = detector | counted },
             { tileCache = cache1, glyphSeen = seen1, budgetWarned = warned1 })
        }, (Nil, Nil, begin, painted));
        let (_, tail) = App.HitchDetector.finish(watch#detector);
        let lastFiles = tail |> Option.map(hitch -> perfWriteHitch(watch, hitch)) |> Option.toList |> List.flatten;
        (List.reverse(rowsRev), List.reverse(List.append(lastFiles, filesRev)), last)

    def perfWriteHitch(watch: HitchWatch, hitch: App.HitchDetector.Hitch): List[String] \ IO =
        match List.head(hitch#rows) {
            case None        => Nil
            case Some(_) if App.HitchDetector.isMinor(watch#config, hitch) => Nil
            case Some(first) =>
                let dir = "${watch#runDir}/f${Int64.toString(first#frame)}";
                if (App.HitchDetector.write(dir, App.HitchDetector.report(watch#config, None, hitch))) "${dir}/hitch.md" :: Nil else Nil
        }

    def perfMs(ns: Int64): String = Float64.toString(Float64.round(Int64.toFloat64(ns) / 10000.0) / 100.0)

    /// /perf の答え: 分布と数だけ。中身は書いた hitch.md を読む。
    def perfSummary(name: String, config: App.HitchDetector.Config, all: List[App.HitchDetector.Row], files: List[String]): String =
        let rows = List.drop(Int64.tryToInt32(config#warmup) |> Option.getWithDefault(0), all);
        let sorted = rows |> List.map(r -> r#totalNs) |> List.sort |> List.toVector;
        let n = Vector.length(sorted);
        let at = (q: Int32) -> if (n == 0) 0i64 else Vector.get(Int32.min(n - 1, n * q / 100), sorted);
        let builds = rows |> List.foldLeft((acc, r) -> acc + List.length(r#diag#shaderBuilds), 0);
        let live = match (List.head(rows), List.last(rows)) {
            case (Some(x), Some(y)) => "${Int32.toString(x#diag#liveShaders)} → ${Int32.toString(y#diag#liveShaders)}"
            case _                  => "-"
        };
        let submits = rows |> List.map(r -> r#diag#submitNs) |> List.sort |> List.toVector;
        let submitAt = (q: Int32) -> if (n == 0) 0i64 else Vector.get(Int32.min(n - 1, n * q / 100), submits);
        let scene3d = List.foldLeft((acc, r) -> FrameDiagnostics.addScene3dCounts(acc, r#diag#scene3dCounts), FrameDiagnostics.emptyScene3dCounts(), rows);
        let lines =
            "ok perf ${name} frames=${Int32.toString(List.length(all))}（最初の ${Int64.toString(config#warmup)} コマは数えない・測るのは塗る側だけ）" ::
            "1 コマを塗る時間: p50 ${perfMs(at(50))}ms  p95 ${perfMs(at(95))}ms  max ${perfMs(at(100))}ms" ::
            "GL へ送る時間（submit）: p50 ${perfMs(submitAt(50))}ms  p95 ${perfMs(submitAt(95))}ms  max ${perfMs(submitAt(100))}ms" ::
            "3D の上げ直しと捨てた物の合計: ${FrameDiagnostics.uploadsText(scene3d)}" ::
            "3D の CPU の区間の合計: ${FrameDiagnostics.cpuPhasesText(scene3d)}" ::
            "シェーダーを作った ${Int32.toString(builds)} 回・GPU にあるシェーダー ${live}" ::
            "ヒッチ ${Int32.toString(List.length(files))} 件（中身はこれを読む）:" ::
            (files |> List.map(f -> "  ${f}"));
        String.intercalate("\n", lines) + "\n"
}
