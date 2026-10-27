// App.HitchDetector — DEBUG 実行の毎コマを見張り、ヒッチ（予算を超えたコマの並び）を 1 件ずつ切り出して
// 直すのに要る物だけの短い報告にする。判定と報告は純粋で、書き出し（write・GC の読み）だけが IO。
// 1 件 = 最初の重いコマの前の数コマから、落ち着いたコマが続くまで。報告は上から
// 「何コマ重かったか → 直前の手 → 推定原因 → 作り直したシェーダー → 重いコマの表 → 再現」。
// WhyNot: 毎コマの全部を書き続けない。量が多いと読む側が場面を探すことになり、肝心のコマを外す。
pub mod App.HitchDetector {
    import java.io.{File, FileWriter, IOException}
    import java.nio.file.Files
    import java.lang.management.ManagementFactory
    import java.time.LocalDateTime
    import java.time.format.DateTimeFormatter

    /// 1 コマの記録。時間はナノ秒。totalNs はループの 1 周（入力の取り込みから描き終わりの swap まで）、
    /// renderNs はそのうち描く所（View を組む・シェーダーを作る・送る・swap）。
    /// status はゲームの statusLine（手のあるコマと重いコマだけ。ほかは ""）。reloaded = Doc を読み直したコマ。
    pub type alias Row = {
        frame = Int64, totalNs = Int64, updateNs = Int64, renderNs = Int64, diag = FrameDiagnostics.Diagnostics,
        gc = Int32, gcMs = Int64, pressed = String, status = String, reloaded = Bool
    }

    /// 決まり: budgetNs は 1 コマの予算・warmup は数えない起動直後のコマ数・context は前に付けるコマ数・
    /// calm は閉じるまでの落ち着いたコマ数・maxRows は 1 件の上限・maxHitches は 1 実行の上限。
    pub type alias Config = { budgetNs = Int64, warmup = Int64, context = Int32, calm = Int32, maxRows = Int32, maxHitches = Int32 }

    /// 切り出した 1 件。rows は古い順（落ち着いた尾は除く）、context はその前の数コマ（古い順）。
    pub type alias Hitch = { rows = List[Row], context = List[Row] }

    type alias Open = { rows = List[Row], context = List[Row], calm = Int32 }

    /// 見張りの状態（外から作らせない。作る口は fresh）。recent・open#rows は新しい順。
    enum DetectorState({ config = Config, recent = List[Row], open = Option[Open], written = Int32 })

    pub type alias Detector = DetectorState

    /// 60fps の予算で、起動直後の 120 コマは数えず、前 10 コマ・落ち着き 30 コマ・1 件 600 コマ・1 実行 10 件。
    pub def defaultConfig(): Config =
        { budgetNs = 16666667i64, warmup = 120i64, context = 10, calm = 30, maxRows = 600, maxHitches = 10 }

    pub def fresh(config: Config): Detector =
        DetectorState.DetectorState({ config = config, recent = Nil, open = None, written = 0 })

    /// 組み立て: 描く所から送る・swap を引いた残り（View を組む・シェーダーを作る・字を足す）。
    def buildNs(row: Row): Int64 = Int64.max(0i64, row#renderNs - row#diag#submitNs - row#diag#swapNs)

    /// その他: 1 周から更新と描く所を引いた残り（入力の取り込み・音・記録）。
    def otherNs(row: Row): Int64 = Int64.max(0i64, row#totalNs - row#updateNs - row#renderNs)

    /// swap の待ちを除いた仕事の時間（vsync で待つ分は予算に数えない）。
    def workNs(row: Row): Int64 = row#totalNs - row#diag#swapNs

    /// 重いコマか: 仕事が予算を超えた・swap まで含めて予算の 2 倍を超えた（GPU やドライバで止まった）・シェーダーを作った。
    pub def isSlow(config: Config, row: Row): Bool =
        workNs(row) > config#budgetNs or row#totalNs > config#budgetNs * 2i64 or not List.isEmpty(row#diag#shaderBuilds)

    /// 1 コマ進める。1 件が閉じたらそれを返す。
    pub def step(row: Row, detector: Detector): (Detector, Option[Hitch]) =
        let DetectorState.DetectorState(st) = detector;
        let cfg = st#config;
        let recent = List.take(cfg#context, row :: st#recent);
        match st#open {
            case None =>
                let opens = st#written < cfg#maxHitches and row#frame >= cfg#warmup and isSlow(cfg, row);
                let opened = if (opens) Some({ rows = row :: Nil, context = List.reverse(st#recent), calm = 0 }) else None;
                (DetectorState.DetectorState({ recent = recent, open = opened | st }), None)
            case Some(o) =>
                let next = { rows = row :: o#rows, calm = if (isSlow(cfg, row)) 0 else o#calm + 1 | o };
                let full = List.length(next#rows) >= cfg#maxRows;
                if (next#calm < cfg#calm and not full)
                    (DetectorState.DetectorState({ recent = recent, open = Some(next) | st }), None)
                else {
                    let hitch = closed(if (full) 0 else next#calm, next);
                    let counted = if (isMinor(cfg, hitch)) 0 else 1;
                    (DetectorState.DetectorState({ recent = recent, open = None, written = st#written + counted | st }), Some(hitch))
                }
        }

    /// 開いている 1 件があれば今の所で閉じて返す（流し終えた時に使う）。
    pub def finish(detector: Detector): (Detector, Option[Hitch]) =
        let DetectorState.DetectorState(st) = detector;
        match st#open {
            case None    => (detector, None)
            case Some(o) =>
                let hitch = closed(o#calm, o);
                (DetectorState.DetectorState({ open = None, written = st#written + (if (isMinor(st#config, hitch)) 0 else 1) | st }), Some(hitch))
        }

    /// 落ち着いた尾 tail コマを除き、古い順にする。
    def closed(tail: Int32, o: Open): Hitch =
        { rows = List.reverse(List.drop(tail, o#rows)), context = o#context }

    /// 単発か: 重いコマが 1 つだけで、その時間の半分以上が GC か swap（シェーダー・字・テクスチャ・Doc の読み直しは無し）。
    /// 単発は 1 件にせず、種類ごとの数だけを残す（上限にも数えない）。更新や組み立てが重い 1 コマ（面の切り替わりなど）は単発にしない。
    pub def isMinor(config: Config, hitch: Hitch): Bool =
        List.count(isSlow(config), hitch#rows) <= 1
            and List.forAll(r -> List.isEmpty(r#diag#shaderBuilds) and r#diag#glyphsAdded == 0
                                 and List.isEmpty(r#diag#textureUploads) and not r#reloaded, hitch#rows)
            and Option.exists(w -> minorKind(w) != "", worstOf(hitch))

    /// 1 コマの時間の半分以上を占める物（GC か swap）。どちらでもなければ ""。
    def minorKind(row: Row): String =
        if (row#gcMs * 1000000i64 * 2i64 >= row#totalNs) "GC"
        else if (row#diag#swapNs * 2i64 >= row#totalNs) "swap"
        else ""

    /// 単発の種類と 1 行（summary.md に足す）。
    pub def minorOf(hitch: Hitch): (String, String) =
        match worstOf(hitch) {
            case None    => ("その他", "")
            case Some(w) =>
                let kind = if (minorKind(w) == "") "その他" else minorKind(w);
                (kind, "f=${Int64.toString(w#frame)} ${ms(w#totalNs)}ms（GC ${Int32.toString(w#gc)} 回 ${Int64.toString(w#gcMs)}ms・swap ${ms(w#diag#swapNs)}）")
        }

    // ── 報告 ──

    def ms(ns: Int64): String = Float64.toString(Float64.round(Int64.toFloat64(ns) / 10000.0) / 100.0)

    def sumBy(f: Row -> Int64, rows: List[Row]): Int64 = List.foldLeft((acc, r) -> acc + f(r), 0i64, rows)

    /// 一番重いコマ（無ければ最初のコマ）。
    pub def worstOf(hitch: Hitch): Option[Row] =
        hitch#rows |> List.sortBy(r -> 0i64 - r#totalNs) |> List.head

    /// 原因を探す起点のコマ: 最初にシェーダーを作ったコマ、無ければ一番重いコマ。
    def anchorOf(hitch: Hitch): Option[Row] =
        match List.find(r -> not List.isEmpty(r#diag#shaderBuilds), hitch#rows) {
            case Some(r) => Some(r)
            case None    => worstOf(hitch)
        }

    /// 起点のコマか、それより前で一番近い手（前に付けたコマも探す）。
    pub def pressBefore(hitch: Hitch): Option[Row] =
        match anchorOf(hitch) {
            case None    => None
            case Some(a) => List.append(hitch#context, hitch#rows)
                |> List.filter(r -> r#pressed != "" and r#frame <= a#frame) |> List.last
        }

    /// 読む側（人・エージェント）向けの報告。dir は record.flow を置いた所（無ければ None）。
    /// replay は record.flow を置いた所と、/perf で塗る最後のコマ数（無ければ None）。
    pub def report(config: Config, replay: Option[(String, Int64)], hitch: Hitch): String =
        let rows = hitch#rows;
        match (List.head(rows), List.last(rows), worstOf(hitch)) {
            case (Some(first), Some(last), Some(worst)) =>
                let slow = List.filter(isSlow(config), rows);
                let header =
                    "# ヒッチ f=${Int64.toString(first#frame)}〜${Int64.toString(last#frame)}（${Int32.toString(List.length(rows))} コマ・重いコマ ${Int32.toString(List.length(slow))}・予算 ${ms(config#budgetNs)}ms）" ::
                    "" ::
                    "- 一番重いコマ: f=${Int64.toString(worst#frame)} ${ms(worst#totalNs)}ms（更新 ${ms(worst#updateNs)} / 組み立て ${ms(buildNs(worst))} / 送る ${ms(worst#diag#submitNs)} / swap ${ms(worst#diag#swapNs)} / その他 ${ms(otherNs(worst))}）" ::
                    "- ${pressLine(hitch)}" ::
                    "- 数: シェーダーを作った ${Int32.toString(List.length(List.flatMap(r -> r#diag#shaderBuilds, rows)))}・消した ${Int32.toString(List.foldLeft((acc, r) -> acc + r#diag#shaderDeletes, 0, rows))}・GPU にあるシェーダー ${Int32.toString(first#diag#liveShaders)} → ${Int32.toString(last#diag#liveShaders)}・足した字 ${Int32.toString(List.foldLeft((acc, r) -> acc + r#diag#glyphsAdded, 0, rows))}・上げ直したテクスチャ ${Int32.toString(List.length(List.flatMap(r -> r#diag#textureUploads, rows)))}・GC ${Int32.toString(List.foldLeft((acc, r) -> acc + r#gc, 0, rows))} 回 ${ms(sumBy(r -> r#gcMs * 1000000i64, rows))}ms" ::
                    "" :: "## 推定原因" :: "" :: Nil;
                let causes = guesses(config, rows) |> List.map(line -> "- ${line}");
                String.intercalate("\n", header ::: causes ::: ("" :: Nil) ::: shaderSection(rows) ::: table(config, hitch) ::: replaySection(replay)) + "\n"
            case _ => ""
        }

    def pressLine(hitch: Hitch): String = match pressBefore(hitch) {
        case Some(p) =>
            let lag = anchorOf(hitch) |> Option.map(a -> a#frame - p#frame) |> Option.getWithDefault(0i64);
            "直前の手: ${p#pressed} @ f=${Int64.toString(p#frame)}（起点の ${Int64.toString(lag)} コマ前）  手の後の状態: ${p#status}"
        case None => "直前の手: なし（手と関係なく起きた）"
    }

    /// 推定原因（当たる物を全部・強い順）。
    def guesses(config: Config, rows: List[Row]): List[String] =
        let slow = List.filter(isSlow(config), rows);
        let n = List.length(slow);
        let builds = List.flatMap(r -> r#diag#shaderBuilds, rows);
        let changed = builds |> List.count(b -> b#reason != FrameDiagnostics.BuildReason.First);
        let firsts = List.length(builds) - changed;
        let withBuild = slow |> List.count(r -> not List.isEmpty(r#diag#shaderBuilds));
        let leaked = liveGrowth(rows);
        let deletes = List.foldLeft((acc, r) -> acc + r#diag#shaderDeletes, 0, rows);
        let glyphs = List.foldLeft((acc, r) -> acc + r#diag#glyphsAdded, 0, rows);
        let uploads = List.flatMap(r -> r#diag#textureUploads, rows);
        let reloads = List.count(r -> r#reloaded, rows);
        let totalSlow = sumBy(r -> r#totalNs, slow);
        let part = (f: Row -> Int64) -> sumBy(f, slow);
        let gcNs = sumBy(r -> r#gcMs * 1000000i64, slow);
        let maxItems = List.foldLeft((acc, r) -> Int32.max(acc, r#diag#drawItems), 0, rows);
        let gcLed = totalSlow > 0i64 and gcNs * 3i64 > totalSlow;
        let lines =
            (if (changed > 0) Some("シェーダーを同じ名前で中身を変えて ${Int32.toString(changed)} 回作り直した（重いコマ ${Int32.toString(withBuild)}/${Int32.toString(n)}）。毎コマ変わる値（下の抜き書き）が Spec に書き込まれている。その値を Spec の外へ出す") else None) ::
            (if (firsts > 0) Some("初めて使うシェーダーを ${Int32.toString(firsts)} 本作った。場面に入る前に一度描いて作っておくと、このコマは軽くなる") else None) ::
            (if (leaked > 0 and deletes == 0) Some("GPU にあるシェーダーが ${Int32.toString(leaked)} 本増えて 1 本も消えていない。作り直しのたびに古い物が残っている（漏れ）") else None) ::
            (if (glyphs > 0) Some("初めて出る字を ${Int32.toString(glyphs)} 字アトラスへ足した（1 度だけの重さ）") else None) ::
            (if (not List.isEmpty(uploads)) Some("テクスチャの画素を ${Int32.toString(List.length(uploads))} 回上げ直した（${String.intercalate(", ", List.take(3, List.distinct(uploads)))}）。毎コマなら key が毎コマ変わっている") else None) ::
            (if (reloads > 0) Some("Doc を読み直したコマが ${Int32.toString(reloads)} ある（保存した直後の重さ）") else None) ::
            (if (gcLed) Some("重いコマの時間の 1/3 以上が GC で止まっている。毎コマの割り当てを減らす（DEBUG の巻き戻し用の履歴と記録も割り当てるので、DEBUG を切っても出るか確かめる）") else None) ::
            (if (not gcLed and totalSlow > 0i64 and part(r -> r#diag#swapNs) * 2i64 > totalSlow) Some("時間の半分以上が swap。GPU の塗りが重いか、ドライバが後回しにした仕事（シェーダーのリンクなど）がここに出ている") else None) ::
            (if (not gcLed and totalSlow > 0i64 and part(r -> r#updateNs) * 2i64 > totalSlow) Some("時間の半分以上が更新（World を進める系）。系のどれかが重い") else None) ::
            (if (not gcLed and totalSlow > 0i64 and part(r -> r#diag#submitNs) * 2i64 > totalSlow) Some("時間の半分以上が GL へ送る所（描く物は最大 ${Int32.toString(maxItems)}）。描く物の数を減らす・静的層やタイル層へ寄せる") else None) ::
            (if (not gcLed and totalSlow > 0i64 and part(buildNs) * 2i64 > totalSlow and List.isEmpty(builds) and glyphs == 0) Some("時間の半分以上が組み立て（View を組む）。View の部品のどれかが毎コマ重い計算をしている") else None) ::
            Nil;
        match List.filterMap(x -> x, lines) {
            case Nil  => "当てはまる型が無い（更新・組み立て・送る・swap の内訳を表で見る）" :: Nil
            case some => some
        }

    /// 最初のコマから最後のコマまでに増えた、GPU にあるシェーダーの数。
    def liveGrowth(rows: List[Row]): Int32 = match (List.head(rows), List.last(rows)) {
        case (Some(a), Some(b)) => b#diag#liveShaders - a#diag#liveShaders
        case _                  => 0
    }

    /// 作ったシェーダーを名前ごとに数え、理由の例を 2 つまで。
    def shaderSection(rows: List[Row]): List[String] =
        let builds = List.flatMap(r -> r#diag#shaderBuilds, rows);
        if (List.isEmpty(builds)) Nil
        else {
            let names = builds |> List.map(b -> b#name) |> List.distinct;
            ("## 作ったシェーダー" :: "" :: Nil) :::
            (names |> List.flatMap(name -> {
                let reasons = builds |> List.filter(b -> b#name == name) |> List.map(b -> b#reason);
                let kinds = List.distinct(reasons);
                "- `${name}` ×${Int32.toString(List.length(reasons))}（理由 ${Int32.toString(List.length(kinds))} 通り）" ::
                (List.take(2, kinds) |> List.map(reason -> match reason {
                    case FrameDiagnostics.BuildReason.First      => "  - 初めて"
                    case FrameDiagnostics.BuildReason.Changed(d) => "  - 中身が違う: ${d}"
                }))
            })) ::: ("" :: Nil)
        }

    /// 重いコマと手のあるコマの表（40 行まで。省いた数を書く）。
    def table(config: Config, hitch: Hitch): List[String] =
        let shown = List.append(hitch#context, hitch#rows) |> List.filter(r -> isSlow(config, r) or r#pressed != "");
        let limit = 40;
        let rest = List.length(shown) - limit;
        ("## 重いコマと手のあるコマ" :: "" ::
         "| f | 合計 ms | 更新 | 組み立て | 送る | swap | その他 | 作った | GC | 手 |" ::
         "|---|---|---|---|---|---|---|---|---|---|" :: Nil) :::
        (List.take(limit, shown) |> List.map(r ->
            "| ${Int64.toString(r#frame)} | ${ms(r#totalNs)} | ${ms(r#updateNs)} | ${ms(buildNs(r))} | ${ms(r#diag#submitNs)} | ${ms(r#diag#swapNs)} | ${ms(otherNs(r))} | ${Int32.toString(List.length(r#diag#shaderBuilds))} | ${Int32.toString(r#gc)} | ${if (r#pressed == "") "" else r#pressed} |")) :::
        (if (rest > 0) "（残り ${Int32.toString(rest)} 行は省略）" :: Nil else Nil) ::: ("" :: Nil)

    def replaySection(replay: Option[(String, Int64)]): List[String] = match replay {
        case None         => Nil
        case Some((d, n)) =>
            "## 再現" :: "" ::
            "`${d}/record.flow` は起動からこのヒッチの最後のコマまでの手。DEBUG で起動したゲームへ `curl -X POST \"http://127.0.0.1:<port>/perf?path=${d}/record.flow&last=${Int64.toString(n)}\"` で流すと、手前は塗らずに流し、最後の ${Int64.toString(n)} コマ（このヒッチと前後）だけを本物の GL で塗り直して数を比べられる（ms は機械とドライバのキャッシュで変わるので、作った回数で比べる。`make flow` は GL を通らない）。" ::
            "初めての型（初めて作るシェーダー・初めて出る字）は、同じプロセスで一度描いた物は作り直さないので、ゲームを起動し直してから流す。record.flow は長いので読まない。" :: Nil
    }

    // ── 書き出し（IO） ──

    /// この実行のヒッチの置き場 debug/perf/hitches/<起動時刻> を作り、古い実行は新しい keep 個を残して消す。
    pub def prepareRunDir(keep: Int32): String \ IO =
        let root = new File("debug/perf/hitches");
        discard root.mkdirs();
        let stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss"));
        let runs = listNames(root) |> List.sort |> List.reverse;
        runs |> List.drop(Int32.max(0, keep - 1)) |> List.forEach(name -> deleteTree(new File(root, name)));
        // 0 件の実行も置き場を作る（make status が前の実行の件数を出し続けないように）。
        let dir = "debug/perf/hitches/${stamp}";
        discard (new File(dir)).mkdirs();
        dir

    def listNames(dir: File): List[String] \ IO =
        let names = dir.list();
        if (Object.isNull(names)) Nil else Array.toList(names)

    /// file を消す。シンボリックリンクはリンクだけを消し、先はたどらない。
    def deleteTree(file: File): Unit \ IO =
        if (file.isDirectory() and not Files.isSymbolicLink(file.toPath()))
            listNames(file) |> List.forEach(name -> deleteTree(new File(file, name)))
        else ();
        discard file.delete()

    /// 1 件を dir/hitch.md に書く。書けたら true。
    pub def write(dir: String, text: String): Bool \ IO = writeFile(dir, "hitch.md", text)

    /// dir/name に text を書く（dir が無ければ作る）。書けたら true。
    pub def writeFile(dir: String, name: String, text: String): Bool \ IO =
        try {
            discard (new File(dir)).mkdirs();
            let out = new FileWriter("${dir}/${name}");
            out.write(text);
            out.close();
            true
        } catch {
            case _: IOException => false
        }

    /// 起動からの GC の回数と、止まった時間の合計 ms（並行して走る GC は止めないので数えない）。
    pub def gcNow(): (Int32, Int64) \ IO =
        let beans = ManagementFactory.getGarbageCollectorMXBeans();
        List.range(0, beans.size()) |> List.foldLeft((acc, i) -> {
            let (count, ms) = acc;
            let bean = beans.get(i);
            if (String.contains(substr = "Concurrent", bean.getName())) acc
            else (count + (Int64.max(0i64, bean.getCollectionCount()) |> Int64.tryToInt32 |> Option.getWithDefault(0)),
                  ms + Int64.max(0i64, bean.getCollectionTime()))
        }, (0, 0i64))
}
