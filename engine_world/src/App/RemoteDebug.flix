// App.RemoteDebug — 起動中のゲームを外部プロセス（AI エージェント等）が HTTP で操作・観測する口。
// curl 一発で「キー入力の台本を N フレーム実行して、結果の状態を受け取る」が完結する。
// デバッグ専用: App の debug が有効かつ環境変数 DEBUG_HTTP_PORT があるときだけ立ち上がる。
//
// スレッドの取り決め: HTTP のスレッドは World に一切触れない。リクエストの生文字列をキューへ
// 積んで応答文字列を待つだけで、パース・実行・応答の組み立てはすべてゲームループ側
// （App）が行う。ゲームが応答しなければ 10 秒で 503 を返し、その依頼は取り下げる。
// 例外は /render だけ: 描き出しは World に触れないので、ゲームループには渡さず、描き出し専用の
// スレッドで走らせる（ゲームの窓は描き出しの間も動き続ける）。

pub mod App.RemoteDebug {
    import java.lang.System
    import java.net.InetSocketAddress
    import com.sun.net.httpserver.HttpServer
    import com.sun.net.httpserver.HttpHandler
    import com.sun.net.httpserver.HttpExchange
    import java.util.concurrent.{LinkedBlockingQueue => JQueue}
    import java.util.concurrent.TimeUnit
    import java.util.concurrent.Callable
    import java.util.concurrent.Executors
    import java.util.concurrent.ThreadFactory
    import java.util.concurrent.atomic.AtomicLong
    import java.util.concurrent.atomic.AtomicReference
    import java.lang.{String => JString}
    import java.lang.Runnable
    import java.lang.Thread
    import java.lang.Throwable
    import java.io.OutputStream
    import java.util.concurrent.locks.ReentrantLock

    // ── HTTP スレッドとゲームループを繋ぐ橋 ──

    /// HTTP サーバ本体と、リクエスト / レスポンスを受け渡す 2 本のキュー。
    /// キューの中身は「依頼番号 + タブ + 本文」。番号で依頼と答えを対にする。
    pub type alias Bridge = {
        server = HttpServer,           // 稼働中のサーバ（終了時に stop する）
        requests = JQueue[String],     // HTTP → ゲームループ（"番号\tMETHOD /path?query\n台本"）
        responses = JQueue[String],    // ゲームループ → HTTP（"番号\t応答本文"）
        current = AtomicLong           // ゲームループがいま捌いている依頼の番号
    }

    /// /render の帳簿。HTTP のスレッドと描き出しのスレッドが共有する（どれもスレッド安全な Java の部品）。
    /// 依頼ごとに requested を 1 つ進め、描き出しのスレッドは「頼まれた番号まで」をまとめて 1 回で描く。
    pub type alias RenderJobs = {
        requested = AtomicLong,            // 最後に受け付けた依頼の番号
        done = AtomicLong,                 // 描き終えた（または失敗した）最後の番号
        running = AtomicLong,              // いま描いている回の番号（0 = 描いていない）
        last = AtomicReference[String],    // done の回の応答本文（成功なら ok rendered=…、失敗なら error: …）
        wake = JQueue[String]              // 描き出しのスレッドを起こす印（中身は使わない）
    }

    /// 橋の外で、HTTP の糸の中で答える口（App.Headless の /hello・/run）。path が合う依頼はキューへ積まず、
    /// 200・chunked のヘッダを送ってから serve を呼び、serve が戻ったら本文を閉じる。
    /// serve は終わるまで HTTP の糸を持つ（何十秒でもよい）。
    pub type alias DirectRoute = {
        path = String,                                  // "/run" など（クエリを外したパス）
        serve = (Request, OutputStream) -> Unit \ IO    // 本文を書く（flush は serve が決める）
    }

    /// 環境変数 DEBUG_HTTP_PORT からポート番号を読む。未設定・数値でなければ None。
    pub def portFromEnv(): Option[Int32] \ IO = portOf(ProcessEnv.snapshot())

    /// portFromEnv の中身。env は入口の頭で読んだ環境変数の表。
    pub def portOf(env: Map[String, String]): Option[Int32] =
        Map.get("DEBUG_HTTP_PORT", env) |> Option.flatMap(Int32.fromString)

    /// 命令口を開くポート: DEBUG_HTTP_PORT があればそれ、無ければ 0（OS に空いたポートを選ばせる）。
    /// 0 で開いた時は、開けたポートを ~/.flix_ge_studio/games.json に書き置く（App.GameRegistry・start が書く）。
    /// DEBUG_HTTP_PORT=off なら開かない。
    pub def portToOpen(): Option[Int32] \ IO = portToOpenOf(ProcessEnv.snapshot())

    /// portToOpen の中身。env は入口の頭で読んだ環境変数の表。
    pub def portToOpenOf(env: Map[String, String]): Option[Int32] =
        match Map.getWithDefault("DEBUG_HTTP_PORT", "", env) {
            case ""    => Some(0)
            case "off" => None
            case value => Int32.fromString(value)
        }

    /// 実際に開けたポート（0 で開いた時に OS が選んだ番号を知る）。
    pub def boundPort(bridge: Bridge): Int32 \ IO =
        let server = bridge#server;
        server.getAddress().getPort()

    /// 本文に依頼番号を付ける（キューに積む形）。
    pub def tagged(id: Int64, text: String): String = "${id}\t${text}"

    /// tagged の逆。番号の無い・読めない形は None。
    pub def untagged(raw: String): Option[(Int64, String)] =
        String.indexOfLeft({substr = "\t"}, raw)
            |> Option.flatMap(i -> Int64.fromString(String.takeLeft(i, raw))
                |> Option.map(id -> (id, String.dropLeft(i + 1, raw))))

    /// 127.0.0.1 の port で HTTP サーバを立てて Bridge を返す。
    /// ハンドラはリクエストを 1 つの文字列にまとめてキューへ積み、自分の番号の応答を最大 10 秒待つ。
    /// executor を与えない（null）ので処理は 1 スレッド直列 = 同時リクエストも順番に並ぶ。
    /// `render` はゲームが App.onRenderRequest で登録した描き出し。/render はキューに積まず、
    /// ここで描き出しのスレッドへ回す（serveRender）。
    // WhyNot: 時間切れの依頼をキューに残すと、ゲームは後でそれにも答え、その答えが次の依頼の
    // 答えとして渡ってしまう（以後ずっと 1 つずつずれる）。だから時間切れでは、まだ取られて
    // いない依頼を取り下げ、遅れて届いた他の番号の答えは捨てる。
    pub def start(port: Int32, render: Option[Unit -> List[String] \ IO]): Bridge \ IO =
        open(port, render, true, Nil)

    /// 窓なしのゲーム（App.Headless）の待ち受け: 同じ橋を、名乗らず（listening の行も書き置きも無し）に開く。
    pub def startQuiet(port: Int32): Bridge \ IO = open(port, None, false, Nil)

    /// startQuiet に、橋の外で答える口（DirectRoute）を足して開く。
    // WhyNot: direct の依頼を橋と同じ 1 本の HTTP の糸で受けない — 長い /run の間、/hello も会話の列の
    // /step も待たされ、2 件目の /run に busy と答えることもできない。糸を増やす代わりに、橋へ渡す依頼は
    // 1 件ずつ錠で並べる（awaitAnswer は他の番号の答えを捨てるので、橋を 2 本の糸が同時に待つと答えが消える）。
    pub def startQuietWith(port: Int32, direct: List[DirectRoute]): Bridge \ IO = open(port, None, false, direct)

    /// startQuiet で開いた橋を閉じる（書き置きに触れない）。
    pub def stopQuiet(bridge: Bridge): Unit \ IO =
        let server = bridge#server;
        server.stop(0)

    def open(port: Int32, render: Option[Unit -> List[String] \ IO], announce: Bool,
             direct: List[DirectRoute]): Bridge \ IO =
        let requests: JQueue[String] = new JQueue();
        let responses: JQueue[String] = new JQueue();
        let current = new AtomicLong(0i64);
        let issued = new AtomicLong(0i64);
        let bridgeLock = new ReentrantLock(true);
        let renderJobs = Option.map(startRenderWorker, render);
        let directRoutes = direct |> List.map(route -> (route#path, route#serve));
        let server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        discard server.createContext("/", new HttpHandler {
            def handle(_this: HttpHandler, exchange: HttpExchange): Unit \ IO = {
                let uri = exchange.getRequestURI();
                let rawQuery = uri.getQuery();
                let queryPart = if (Object.isNull(rawQuery)) "" else "?" + rawQuery;
                let requestBody = exchange.getRequestBody();
                let bodyText = new JString(requestBody.readAllBytes(), "UTF-8");
                let methodName = exchange.getRequestMethod();
                let path = uri.getPath();
                let raw = "${methodName} ${path}${queryPart}\n${bodyText}";
                let headers = exchange.getResponseHeaders();
                headers.set("Content-Type", "text/plain; charset=utf-8");
                match findRoute(path, directRoutes) {
                    case Some(serve) =>
                        exchange.sendResponseHeaders(200, 0i64);
                        let out = exchange.getResponseBody();
                        try { serve(parseRequest(raw), out) } catch {
                            case e: Throwable => Log.warn("[remote-debug] ${path} の途中で止まりました — ${e.toString()}")
                        };
                        try { out.close() } catch { case _: Throwable => () }
                    case None =>
                        let (status, text) =
                            if (path == "/render") serveRender(renderJobs, parseRequest(raw))
                            else {
                                bridgeLock.lock();
                                let id = issued.incrementAndGet();
                                let request = tagged(id, raw);
                                discard requests.offer(request);
                                let waitNs = answerWaitSecs(parseRequest(raw)#params) * 1_000_000_000i64;
                                let answer = awaitAnswer(responses, id, System.nanoTime() + waitNs);
                                if (Option.isEmpty(answer)) discard requests.remove(request) else ();
                                bridgeLock.unlock();
                                (if (Option.isEmpty(answer)) 503 else 200,
                                 Option.getWithDefault(busyText(), answer))
                            };
                        let bytes = text.getBytes("UTF-8");
                        exchange.sendResponseHeaders(status, Int32.toInt64(Array.length(bytes)));
                        let out = exchange.getResponseBody();
                        out.write(bytes);
                        out.close()
                }
            }
        });
        if (List.isEmpty(direct)) () else server.setExecutor(Executors.newCachedThreadPool(new ThreadFactory {
            def newThread(_this: ThreadFactory, task: Runnable): Thread \ IO = {
                let thread = new Thread(task, "remote-debug-http");
                thread.setDaemon(true);
                thread
            }
        }));
        server.start();
        let bound = server.getAddress().getPort();
        if (announce) {
            println("[remote-debug] listening on http://127.0.0.1:${bound} (GET /help)");
            // Studio が渡したポートは Studio が書き置く。自分で選んだポートだけ自分で書く（bin/fge talk goto が読む）。
            if (port == 0) App.GameRegistry.register(bound) else ()
        } else ();
        { server = server, requests = requests, responses = responses, current = current }

    /// 番号 id の答えを deadlineNs（System.nanoTime の値）まで待つ。他の番号の答えは捨てる。
    def awaitAnswer(responses: JQueue[String], id: Int64, deadlineNs: Int64): Option[String] \ IO =
        let leftNs = deadlineNs - System.nanoTime();
        if (leftNs <= 0i64) None
        else {
            let raw = responses.poll(leftNs, TimeUnit.NANOSECONDS);
            if (Object.isNull(raw)) None
            else match untagged(raw) {
                case Some((answered, text)) if answered == id => Some(text)
                case _ => awaitAnswer(responses, id, deadlineNs)
            }
        }

    // ── /render: 描き出しのスレッド ──

    /// 描き出しのスレッドを 1 本立てて帳簿を返す。スレッドは daemon（ゲームを閉じたら一緒に終わる）。
    /// 描き出し（SoftRaster / HeadlessFont）は Java2D = AWT を使う。macOS の実機起動は
    /// -XstartOnFirstThread で GLFW が主スレッドを占有しており、AWT が AppKit を起こそうとすると
    /// 永久ハングし得る。このプロセスは AWT のウィンドウを開かないので、どのスレッドが最初に AWT に
    /// 触れても困らないよう、ここで 1 回だけ headless を明示しておく。
    // WhyNot: Flix の region + spawn を使わない — region は出口で中のスレッドの合流を待つので、
    // 描き出しのスレッドを置いたまま start から戻れない。Runnable でなく Callable を渡すのは `run` が
    // Flix の予約語で、匿名クラスの手続き名に書けないため（Thread は ThreadFactory が受け取った
    // Runnable から作るだけ）。
    def startRenderWorker(render: Unit -> List[String] \ IO): RenderJobs \ IO =
        discard System.setProperty("java.awt.headless", "true");
        let jobs = { requested = new AtomicLong(0i64), done = new AtomicLong(0i64),
                     running = new AtomicLong(0i64), last = new AtomicReference(""),
                     wake = new JQueue() };
        let executor = Executors.newSingleThreadExecutor(new ThreadFactory {
            def newThread(_this: ThreadFactory, task: Runnable): Thread \ IO = {
                let thread = new Thread(task, "remote-debug-render");
                thread.setDaemon(true);
                thread
            }
        });
        // WhyNot: 受けずに放さない — submit は Callable から抜けた例外を Future に飲み込むので、
        // renderOnce の外（take の割り込みなど）で落ちると、スレッドだけ黙って消えて以後はずっと 503 になる。
        discard executor.submit(new Callable[String] {
            def call(_this: Callable[String]): String \ IO = {
                try {
                    renderLoop(render, jobs)
                } catch {
                    case e: Throwable =>
                        Log.warn("[remote-debug] 描き出しのスレッドが止まりました（以後の /render は 503） — ${e.toString()}")
                };
                ""
            }
        });
        executor.shutdown();
        jobs

    /// 起こされるたびに、頼まれた番号が描き終えた番号より先なら 1 回描く。ずっと回る。
    /// 描いている間に来た依頼は印を積むので、描き終えた後の周でまとめて 1 回だけ描き直す。
    def renderLoop(render: Unit -> List[String] \ IO, jobs: RenderJobs): Unit \ IO =
        let wake = jobs#wake;
        discard wake.take();
        let requested = jobs#requested;
        let done = jobs#done;
        match nextRenderTarget(requested.get(), done.get()) {
            case Some(target) => renderOnce(render, jobs, target)
            case None         => ()
        };
        renderLoop(render, jobs)

    /// 番号 target までの依頼を 1 回の描き出しで済ませる。描き出しの中の bug!（Error で飛ぶ）も
    /// 受け止めて失敗として記録する — 受けないとスレッドだけ黙って死に、running のまま固まる。
    /// last を先に書いてから done を進める（done を見た側が、その回以降の last を必ず読める）。
    def renderOnce(render: Unit -> List[String] \ IO, jobs: RenderJobs, target: Int64): Unit \ IO =
        let running = jobs#running;
        let last = jobs#last;
        let done = jobs#done;
        running.set(target);
        let startNs = System.nanoTime();
        let text = try {
            let paths = render();
            renderJobDoneText(target, (System.nanoTime() - startNs) / 1000000i64, paths)
        } catch {
            case e: Throwable => renderFailedText(target, e.toString())
        };
        last.set(text);
        done.set(target);
        running.set(0i64)

    /// /render を HTTP のスレッドで捌く（ゲームループには渡さない）。返すのは (HTTP の状態, 本文)。
    /// - GET /render: 帳簿を読むだけ。
    /// - POST /render?async=1: 受け付けて番号をすぐ返す（新しい Studio はこの後 GET で番号の完了を待つ）。
    /// - POST /render（クエリ無し）: 受け付けて、その番号が済むまで最大 9 秒待つ。済めば今までと同じ
    ///   ok rendered=… を、済まなければ今までと同じ 503 の「答えなし」を返す。
    // WhyNot: クエリ無しをすぐ返す形にしない — 古い Studio は 1 行目が "ok " で始まれば描き終えたと
    // 読むので、描きかけの絵を reference へ写してしまう。待つ上限を 9 秒にするのは、古い Studio の
    // 読み取りの待ち（15 秒）より先に、Studio が「描いている途中」と読む 503 を返すため。
    def serveRender(renderJobs: Option[RenderJobs], request: Request): (Int32, String) \ IO =
        match renderJobs {
            case None       => (200, renderUnsupportedText())
            case Some(jobs) =>
                let requested = jobs#requested;
                let done = jobs#done;
                let running = jobs#running;
                let last = jobs#last;
                if (request#method == "GET") {
                    // done を先に読んでから last を読む（renderOnce は last → done の順に書くので、
                    // こう読めば last は必ず読んだ done 以降の回の本文になる）。
                    let doneNow = done.get();
                    let lastNow = last.get();
                    (200, renderStatusText(requested.get(), doneNow, running.get(), lastNow))
                } else {
                    let id = requested.incrementAndGet();
                    let wake = jobs#wake;
                    discard wake.offer("render");
                    if (wantsAsyncRender(request#params)) (200, renderAcceptedText(id))
                    else if (awaitRender(jobs, id, System.nanoTime() + 9_000_000_000i64)) (200, last.get())
                    else (503, busyText())
                }
        }

    /// 番号 id の依頼が済むまで（後の回でまとめて描き終えても済んだ扱い）、deadlineNs まで待つ。
    def awaitRender(jobs: RenderJobs, id: Int64, deadlineNs: Int64): Bool \ IO =
        let done = jobs#done;
        if (isRenderSettled(id, done.get())) true
        else if (System.nanoTime() >= deadlineNs) false
        else {
            Thread.sleep(50i64);
            awaitRender(jobs, id, deadlineNs)
        }

    /// ゲームループが毎フレーム呼ぶ非ブロッキングの受信。届いていなければ None。
    pub def pollRequest(bridge: Bridge): Option[String] \ IO =
        let queue = bridge#requests;
        let raw = queue.poll();
        if (Object.isNull(raw)) None
        else match untagged(raw) {
            case Some((id, text)) =>
                let current = bridge#current;
                current.set(id);
                Some(text)
            case None => Some(raw)
        }

    /// 応答本文を HTTP スレッドへ返す（pollRequest で受けた 1 件に必ず 1 回対で呼ぶ）。
    pub def respond(text: String, bridge: Bridge): Unit \ IO =
        let queue = bridge#responses;
        let current = bridge#current;
        discard queue.offer(tagged(current.get(), text))

    /// サーバを止める（ゲーム終了時）。待機中のリクエストは切断される。
    pub def shutdown(bridge: Bridge): Unit \ IO =
        App.GameRegistry.unregister();
        let server = bridge#server;
        server.stop(0)

    // ── リクエストのパース（ここから下は純関数）──

    /// パース済みリクエスト。1 行目が "METHOD /path?query"、2 行目以降がボディ（台本 DSL）。
    pub type alias Request = {
        method = String,             // "GET" / "POST"
        path = String,               // "/step" など
        params = Map[String, String], // クエリパラメータ（view=status 等）。query は Flix 予約語
        body = String                // ボディ（/step の台本）
    }

    /// Bridge から受けた生文字列をリクエストへ分解する。
    pub def parseRequest(raw: String): Request =
        let (headLine, bodyLines) = match String.lines(raw) {
            case first :: rest => (first, rest)
            case Nil           => ("", Nil)
        };
        let (methodName, url) = match String.words(headLine) {
            case m :: u :: _ => (m, u)
            case _           => ("", "")
        };
        let (path, queryText) = match String.splitOn({substr = "?"}, url) {
            case p :: q :: _ => (p, q)
            case p :: Nil    => (p, "")
            case Nil         => ("", "")
        };
        { method = methodName, path = path, params = parseQuery(queryText),
          body = bodyLines |> String.intercalate("\n") }

    /// "a=1&b=2" を Map へ。値に = を含む形は扱わない（このプロトコルでは不要）。
    def parseQuery(text: String): Map[String, String] =
        if (text == "") Map.empty()
        else String.splitOn({substr = "&"}, text)
             |> List.filterMap(pair -> match String.splitOn({substr = "="}, pair) {
                 case key :: value :: Nil => Some((key, decodeValue(value)))
                 case _                   => None
             })
             |> List.toMap

    /// クエリ値の最小限の URL デコード（"+" と "%20" を空白へ）。値は英数字が基本の
    /// プロトコルなので、全 %XX の復号表は持たない（必要になったら足す）。
    def decodeValue(text: String): String =
        text |> String.replace(src = "+", dst = " ")
             |> String.replace(src = "%20", dst = " ")

    /// ゲーム登録の任意ルート（App.onRequest）から、パスに完全一致する最初の 1 本を選ぶ。
    /// パスは parseRequest がクエリを外した後の物で照合する（"/save?slot=1" は "/save" に合う）。
    pub def findRoute(path: String, routes: List[(String, a)]): Option[a] =
        routes |> List.findMap(entry -> {
            let (route, chosen) = entry;
            if (route == path) Some(chosen) else None
        })

    // ── /step・/state のパラメータ ──

    /// 観測の詳細度。応答のトークン量を必要最小限に抑えるための選択肢。
    pub enum View with Eq, ToString {
        case Status,  // 1 行サマリ（App.withStatusLine）
        case Summary, // 数行サマリ（当面 Status と同じ。ゲームの statusLine が複数行なら差が出る）
        case Full,    // ゲーム定義の worldDump（App.withWorldDump）
        case Scene,   // 描画物の一覧（配線不要のフォールバック観測）
        case Shot,    // 1 枚の PNG に描いてパスを返す（App.onShotRequest。[shot] の行は ok png=… か error: …）
        case Silent   // 本文なし（イベントとヘッダだけ欲しいとき）
    }

    /// /step を台本の途中で止める条件。「意味のある瞬間」で止まることで往復を減らす。
    pub enum Until with Eq, ToString {
        case Always,               // 止めない（台本を最後まで実行）
        case SfxAny,               // 何か音が鳴ったら止まる
        case SfxNamed(Set[String]), // 指定した名前の音が鳴ったら止まる
        case Quiet(Int32)          // N フレーム連続で無音になったら止まる（演出待ちに）
    }

    /// /step・/state のクエリを解釈した実行パラメータ。
    pub type alias StepParams = {
        view = View,                 // 応答に載せる観測の詳細度
        rect = Option[Rect2.Rect2],  // full / scene の関心矩形（デザイン座標。None = 全画面）
        stopWhen = Until,            // 早期停止の条件
        maxFrames = Int32,           // 1 リクエストで実行するフレーム数の上限
        traceEvery = Option[Int32],  // K フレームごとに statusLine を応答へ 1 行足す
        dtSeconds = Float64          // 合成フレーム 1 コマの経過秒（既定 1/60。診断用に変更可）
    }

    /// クエリ Map を StepParams へ。不正な値は理由つきの Err（応答にそのまま載せる）。
    pub def parseParams(queryMap: Map[String, String]): Result[String, StepParams] =
        forM (
            view <- parseView(Map.getWithDefault("view", "status", queryMap));
            rect <- parseRect(Map.get("rect", queryMap));
            stopWhen <- parseUntil(Map.get("until", queryMap));
            maxFrames <- parseMax(Map.get("max", queryMap));
            traceEvery <- parseTrace(Map.get("trace", queryMap));
            dtSeconds <- parseDt(Map.get("dt", queryMap))
        ) yield { view = view, rect = rect, stopWhen = stopWhen,
                  maxFrames = maxFrames, traceEvery = traceEvery, dtSeconds = dtSeconds }

    def parseView(name: String): Result[String, View] =
        match String.toLowerCase(name) {
            case "status"  => Ok(View.Status)
            case "summary" => Ok(View.Summary)
            case "full"    => Ok(View.Full)
            case "scene"   => Ok(View.Scene)
            case "shot"    => Ok(View.Shot)
            case "none"    => Ok(View.Silent)
            case other     => Err("error: unknown view '${other}' (status|summary|full|scene|shot|none)")
        }

    def parseRect(text: Option[String]): Result[String, Option[Rect2.Rect2]] =
        match text {
            case None => Ok(None)
            case Some(spec) =>
                match String.splitOn({substr = ","}, spec) |> List.filterMap(Float64.fromString) {
                    case x :: y :: w :: h :: Nil =>
                        Ok(Some({ position = { x = x, y = y }, size = { x = w, y = h } }))
                    case _ => Err("error: rect must be 'x,y,w,h' (got '${spec}')")
                }
        }

    def parseUntil(text: Option[String]): Result[String, Until] =
        match text |> Option.map(String.splitOn({substr = ":"})) {
            case None                          => Ok(Until.Always)
            case Some("sfx" :: "any" :: Nil)   => Ok(Until.SfxAny)
            case Some("sfx" :: names :: Nil)   =>
                Ok(Until.SfxNamed(String.splitOn({substr = ","}, names) |> List.toSet))
            case Some("quiet" :: count :: Nil) =>
                match Int32.fromString(count) {
                    case Some(n) if n > 0 => Ok(Until.Quiet(n))
                    case _                => Err("error: until=quiet:N needs a positive N (got '${count}')")
                }
            case Some(_) => Err("error: until must be 'sfx:any' / 'sfx:name1,name2' / 'quiet:N'")
        }

    def parseMax(text: Option[String]): Result[String, Int32] =
        match text {
            case None => Ok(1200)
            case Some(spec) => match Int32.fromString(spec) {
                case Some(n) if n >= 1 and n <= frameCap() => Ok(n)
                case _ => Err("error: max must be 1..${frameCap()} (got '${spec}')")
            }
        }

    def parseTrace(text: Option[String]): Result[String, Option[Int32]] =
        match text |> Option.map(String.splitOn({substr = ":"})) {
            case None => Ok(None)
            case Some("status" :: every :: Nil) => match Int32.fromString(every) {
                case Some(k) if k > 0 => Ok(Some(k))
                case _                => Err("error: trace=status:K needs a positive K")
            }
            case Some(_) => Err("error: trace must be 'status:K'")
        }

    def parseDt(text: Option[String]): Result[String, Float64] =
        match text {
            case None => Ok(1.0 / 60.0)
            case Some(spec) => match Float64.fromString(spec) {
                case Some(ms) if ms >= 0.1 and ms <= 100.0 => Ok(ms / 1000.0)
                case _ => Err("error: dt is milliseconds in 0.1..100 (got '${spec}')")
            }
        }

    /// クエリを何も書かなかった時の StepParams（view=status・止めない・max 1200・dt 1/60 秒）。
    pub def defaultParams(): StepParams =
        { view = View.Status, rect = None, stopWhen = Until.Always, maxFrames = 1200,
          traceEvery = None, dtSeconds = 1.0 / 60.0 }

    /// 1 リクエストで実行できる合成フレーム数の天井（60fps で 1 分ぶん）。
    pub def frameCap(): Int32 = 3600

    /// until 条件の 1 フレームぶんの判定。このフレームで鳴った音名と「無音が何フレーム
    /// 続いているか」から、(停止理由, 新しい無音連続数) を返す。停止理由 "" = 続行。
    pub def stopCheck(stopWhen: Until, soundsThisFrame: List[String], quietRun: Int32): (String, Int32) =
        match stopWhen {
            case Until.Always => ("", 0)
            case Until.SfxAny =>
                (if (List.isEmpty(soundsThisFrame)) "" else "until:sfx", 0)
            case Until.SfxNamed(names) =>
                (if (List.exists(name -> Set.memberOf(name, names), soundsThisFrame)) "until:sfx" else "", 0)
            case Until.Quiet(need) =>
                let quietNow = if (List.isEmpty(soundsThisFrame)) quietRun + 1 else 0;
                (if (quietNow >= need) "until:quiet" else "", quietNow)
        }

    // ── 応答の整形 ──

    /// /step 応答の 1 行目。何フレーム進んで何故止まったかを 1 行で伝える。
    pub def stepHeader(info: { stepped = Int32, frame = Int64, stoppedBy = String, quit = Bool }): String =
        "ok stepped=${info#stepped} frame=${info#frame} mode=halted stopped=${info#stoppedBy}"
        + (if (info#quit) " quit=true" else "")
        + "\n"

    /// 実行中に鳴った音のブロック。「f=フレーム番号 sfx=音名」の行を時系列で並べる。
    /// 音はフレーム間に何が起きたか（衝突・ミス・フェーズ遷移）を伝える主要な観測チャンネル。
    pub def eventsBlock(sounds: List[(Int64, String)]): String =
        if (List.isEmpty(sounds)) ""
        else "[events]\n" + (sounds
             |> List.map(pair -> { let (frameNo, name) = pair; "f=${frameNo} sfx=${name}" })
             |> String.intercalate("\n")) + "\n"

    /// trace=status:K で集めた status 行のブロック。
    pub def traceBlock(lines: List[String]): String =
        if (List.isEmpty(lines)) ""
        else "[trace]\n" + String.intercalate("\n", lines) + "\n"

    /// scene ビューの本文。矩形に重なる描画物を z 順に 1 行ずつ（多すぎる場合は打ち切る）。
    /// worldDump が未配線のゲームでも、何がどこに描かれているかはこれで観測できる。
    pub def sceneBlock(rect: Rect2.Rect2, hitList: List[Annotate.Hit]): String =
        let sorted = hitList |> List.sortBy(hit -> hit#zIndex);
        let total = List.length(sorted);
        let capped = List.take(sceneLimit(), sorted);
        let header = "[scene] rect=(${fmt1(rect#position#x)},${fmt1(rect#position#y)},"
                   + "${fmt1(rect#size#x)},${fmt1(rect#size#y)}) items=${total}";
        let lines = capped |> List.map(sceneLine);
        let extra = if (total > sceneLimit()) ("(+${total - sceneLimit()} more)" :: Nil) else Nil;
        (header :: List.append(lines, extra)) |> String.intercalate("\n")

    /// scene 1 行に載せる描画物の上限（トークン量の安全弁）。
    def sceneLimit(): Int32 = 80

    def sceneLine(hit: Annotate.Hit): String =
        let label = if (hit#name == "") hit#kind else "${hit#kind} ${hit#name}";
        "${label} pos=(${fmt1(hit#position#x)},${fmt1(hit#position#y)})"
        + " size=(${fmt1(hit#aabb#size#x)},${fmt1(hit#aabb#size#y)}) z=${hit#zIndex}"

    /// 小数第 1 位までに丸めた表示（座標の長い小数でトークンを浪費しないため）。
    pub def fmt1(value: Float64): String =
        "${Float64.round(value * 10.0) / 10.0}"

    /// view=full の本文の安全弁。矩形無指定の worldDump は数万文字になり得る
    /// （全画面で実測 80KB）ので、超過分を打ち切って rect= の指定を促す。
    pub def capBody(text: String): String =
        let limit = 8192;
        if (String.length(text) <= limit) text
        else String.takeLeft(limit, text)
             + "\n...(truncated ${String.length(text) - limit} chars; pass rect=x,y,w,h to narrow)"

    // ── POST /render の応答 ──

    /// POST /render の成功応答。1 行目に枚数と所要ミリ秒、続く [rendered] ブロックに
    /// 描き出したファイルパスを描き出した順に 1 行 1 枚で載せる（0 枚ならブロックは省く）。
    pub def renderDoneText(ms: Int64, paths: List[String]): String =
        "ok rendered=${List.length(paths)} ms=${ms}\n"
        + (if (List.isEmpty(paths)) ""
           else "[rendered]\n" + String.intercalate("\n", paths) + "\n")

    /// 1 回の描き出しが済んだときの応答。renderDoneText の 1 行目の末尾に、その回の番号を足した形
    /// （古い Studio は 1 行目を "ok " で始まるかだけで読むので、足しても読み方は変わらない）。
    pub def renderJobDoneText(job: Int64, ms: Int64, paths: List[String]): String =
        let text = renderDoneText(ms, paths);
        match String.lines(text) {
            case first :: rest => String.intercalate("\n", "${first} job=${job}" :: rest) + "\n"
            case Nil           => text
        }

    /// 1 回の描き出しが落ちたときの応答（描き出しの中の bug! や例外の文面を 1 行に）。
    pub def renderFailedText(job: Int64, reason: String): String =
        let oneLine = reason |> String.replace(src = "\n", dst = " ");
        "error: render failed job=${job}: ${oneLine}\n"

    /// POST /render?async=1 の応答。番号を受け取った側は GET /render で done がその番号以上になるのを待つ。
    pub def renderAcceptedText(job: Int64): String = "ok accepted job=${job}\n"

    /// GET /render の応答。1 行目に番号 3 つ（受け付けた最後・描き終えた最後・いま描いている回。0 = 無し）、
    /// まだ 1 回も描き終えていなければそれだけ、描き終えた回があれば [last] にその回の応答をそのまま載せる。
    pub def renderStatusText(requested: Int64, done: Int64, running: Int64, last: String): String =
        "ok render requested=${requested} done=${done} running=${running}\n"
        + (if (done == 0i64) "" else "[last]\n" + last)

    /// POST /render のクエリが「すぐ返す」を頼んでいるか（async=1）。
    pub def wantsAsyncRender(params: Map[String, String]): Bool =
        Map.get("async", params) == Some("1")

    /// 描き出しのスレッドが次に描く番号。頼まれた番号が描き終えた番号より先なら、頼まれた番号まで
    /// まとめて 1 回で描く（間に何件来ていても 1 回）。追いついていれば None。
    pub def nextRenderTarget(requested: Int64, done: Int64): Option[Int64] =
        if (requested > done) Some(requested) else None

    /// 番号 id の依頼が済んだか。後の番号の回でまとめて描き終えていても済んだ扱い
    /// （その回は id の依頼より後に Docs を読み直しているので、id の時点の変更を含む）。
    pub def isRenderSettled(id: Int64, done: Int64): Bool = done >= id

    /// 橋が主の糸の答えを待つ秒数。`wait=<秒>`（1〜600）があればそれ、無ければ view=shot は 60 秒、ほかは 10 秒。
    // WhyNot: view=shot も 10 秒にそろえない — 1 枚撮りは場面を組んで塗るまでを主の糸で行うので、重いゲームでは
    // 10 秒を超える（internet_dungeon の会話のプレビューが Studio で「did not answer within 10s」になった）。
    // ほかの要求まで長くしないのは、主の糸が固まった時に 10 秒で気づけるようにするため。
    pub def answerWaitSecs(params: Map[String, String]): Int64 =
        match Map.get("wait", params) |> Option.flatMap(Int64.fromString) {
            case Some(secs) if secs >= 1i64 and secs <= 600i64 => secs
            case _ => if (Map.get("view", params) == Some("shot")) 60i64 else 10i64
        }

    /// 時間内に答えられなかったときの応答。古い Studio はこの 1 行目を「描いている途中」と読む
    /// （make での描き出しに切り替えない）ので、待つ秒数を変えても文面は変えない（answerWaitSecs）。
    pub def busyText(): String = "error: game loop did not answer within 10s\n"

    /// 描き出しの実体（App.onRenderRequest）を登録していないゲームへの応答。
    /// Studio はこの error 行を見て自前の描き出し起動（make render-all 等）へフォールバックする。
    pub def renderUnsupportedText(): String =
        "error: render not supported (game does not wire App.onRenderRequest)\n"

    /// GET /help の本文。プロトコルの自己記述（セッション冒頭に 1 回読む想定）。
    pub def helpText(): String =
        "remote debug protocol (all responses are text/plain)\n"
        + "\n"
        + "GET  /help                    this text\n"
        + "GET  /state?view=&rect=       observe without advancing\n"
        + "POST /halt                    pause the game (lockstep mode)\n"
        + "POST /resume                  resume realtime play\n"
        + "POST /render                  run the game's registered render (App.onRenderRequest)\n"
        + "     on a background thread of the warm JVM (the game keeps running); waits up to 9s\n"
        + "     and answers the rendered file paths, or 503 if still rendering. play state is untouched.\n"
        + "POST /render?async=1          accept and answer \"ok accepted job=N\" at once\n"
        + "GET  /render                  requested= done= running= job numbers, then [last] result.\n"
        + "     job N is finished once done >= N (requests during a render fold into one rerun)\n"
        + "GET  /starts                  the start registry (App.withStarts): name, default args, doc\n"
        + "POST /start?name=N&k=v[&view=shot]  rebuild a fresh world from start N and swap it in (view=shot: also one PNG)\n"
        + "POST /step?view=&rect=&until=&max=&trace=&dt=\n"
        + "     body = flow (same grammar as e2e/<name>.flow); runs it frame by frame, then answers.\n"
        + "     steps before any start run on the current world. auto-halts first if the game is running.\n"
        + "POST /flow?path=&apply=1&repeat=N\n"
        + "     run a flow (body or ?path=) from a fresh world; apply=1 swaps the result in. no rebuild needed.\n"
        + "ANY  /<path>?k=v              game-registered handler (App.onRequest), if wired\n"
        + "\n"
        + "flow (one step per line, # comments; vocabulary in e2e/vocab.json):\n"
        + "  start NAME k=v      rebuild the world from a start (GET /starts)\n"
        + "  tap ROLE|KEY,KEY|X,Y   one frame down (X,Y = click)\n"
        + "  hold ROLE [0.5|30f]  hold (until release if no length)   release ROLE\n"
        + "  wait 0.5|30f        touch nothing\n"
        + "  until PROBE max SECS   wait until the probe holds (PROBE: name, !name, a&b, name>=3, name=Text)\n"
        + "  drive NAME until PROBE max SECS   let a named pilot press\n"
        + "  expect PROBE   mark NAME   fps N   ready on|off\n"
        + "\n"
        + "query params:\n"
        + "  view=status|summary|full|scene|shot|none   response detail (default status; shot = one PNG via App.onShotRequest)\n"
        + "  rect=x,y,w,h   design-space rect for full/scene (default whole screen)\n"
        + "  until=sfx:any | sfx:name1,name2 | quiet:N   stop early on sound events\n"
        + "  max=N          frame cap for this request (default 1200, max ${frameCap()})\n"
        + "  trace=status:K append a status line every K frames\n"
        + "  dt=MS          per-frame delta time in ms (default 16.67; diagnostics only)\n"
        + "\n"
        + "response: header line, then [events] (sounds with frame numbers),\n"
        + "[trace] if requested, and the view block ([status]/[full]/[scene]).\n"

    // ── リモートデバッグ（HTTP）: コマンド処理 ──
    //
    // 外部プロセス（AI エージェント等）が curl で送るコマンドをゲームループ側で処理する。
    // 主役は /step: ゲームを止めたまま「キー入力の台本」を 1 コマ = 1 フレームで実行し、
    // 進んだ結果（鳴った音・状態サマリ）を 1 応答で返す。実時間を追いかけられない相手でも、
    // ゲーム側が待つことでフレーム精度の操作と観測ができる。

    /// リモートコマンド処理が次の実フレームへ持ち回す状態。
    pub type alias RemoteNext[w] = {
        world = w,               // 現在の World（/step で進み得る）
        anno = Annotate.State,   // 停止・スクラブ等の状態（/halt /step で paused になる）
        history = List[w],       // スクラブ用の履歴（/step の合成フレームも積む）
        hold = Bool,             // HTTP 側が停止の主導権を持っているか（真の間 F8 は無効）
        stepState = App.StepState, // 固定刻みの持ち越しと実時間の時計（/step が実機と同じに進める）
        record = List[Flow.Record.Item] // 遊んだ記録に足す物（このリクエストが World を変えた分。App が書く）
    }

    /// リクエスト 1 件を捌き、応答をブリッジへ書いてから次の状態を返す。
    /// どの経路でも必ず 1 回 respond する（しないと HTTP 側が 10 秒待って 503 になる）。
    pub def handleRemote(app: App.App[w, ef], bridge: Bridge, raw: String,
                     ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + Fs.FileRead + IO) =
        let request = parseRequest(raw);
        match (request#method, request#path) {
            case ("GET", "/help")    => answer(helpText(), bridge, ctx)
            case ("POST", "/halt")   => remoteHalt(app, bridge, ctx)
            case ("POST", "/resume") => remoteResume(bridge, ctx)
            case ("GET", "/state")   => remoteState(app, bridge, request, ctx)
            case ("POST", "/step")   => remoteStepCommand(app, bridge, request, ctx)
            case ("GET", "/starts")  => answer(startsText(app), bridge, ctx)
            case ("POST", "/start")  => remoteStart(app, bridge, request, ctx)
            case ("POST", "/flow")   => remoteFlow(app, bridge, request, ctx)
            case (m, p)              =>
                match findRoute(p, app#remoteHandlers) {
                    case Some(chosen) => remoteCustom(chosen, bridge, request, ctx)
                    case None => answer("error: no route for ${m} ${p} (see GET /help)\n", bridge, ctx)
                }
        }

    /// ゲーム登録の任意ルート（App.onRequest）を 1 件適用する。Ok なら world を差し替えて
    /// "ok"、Err なら理由をそのまま応答する。停止状態・履歴・hold には触れない —
    /// 走行中なら差し替わった world で次の実フレームから進み、停止中なら /resume でそこから再開する。
    def remoteCustom(apply: (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead},
                     bridge: Bridge, request: Request,
                     ctx: RemoteNext[w]): RemoteNext[w] \ (Fs.FileRead + IO) =
        let (result, files) = Flow.Record.captureReads(() -> apply(request#params, ctx#world));
        match result {
            case Ok(changed)  =>
                // 止めている間は履歴の先頭にも置く（/resume は履歴の表示中の World から再開するので、置かないと消える）。
                let history = if (ctx#anno#paused) changed :: List.drop(ctx#anno#scrub, ctx#history) else ctx#history;
                answer("ok\n", bridge, { world = changed, history = history, anno = { scrub = 0 | ctx#anno },
                                         record = Flow.Record.Item.Line(Flow.Record.requestLine(request#path, request#params, files)) :: Nil | ctx })
            case Err(message) => answer("error: ${message}\n", bridge, ctx)
        }

    /// GET /starts の本文: 始まりの登録簿（App.withStarts）の名前・既定の引数・説明を 1 行ずつ。
    pub def startsText(app: App.App[w, ef]): String =
        if (List.isEmpty(app#starts)) "(no starts wired; use App.withStarts)\n"
        else app#starts |> List.map(start -> {
            let args = start#args |> Map.toList |> List.map(entry -> { let (k, v) = entry; " ${k}=${v}" }) |> String.intercalate("");
            "${start#name}${args}\t${start#doc}\n"
        }) |> String.intercalate("")

    /// POST /start?name=<名前>&k=v: 新しく作った初期の World から始まりを組み、走っている World と差し替える。
    /// 止めている間ならそこで止まったまま（/resume でその場面から遊べる）。巻き戻しの履歴は捨てる
    /// （差し替える前の World へ巻き戻せると、跳んだ先と前の場面が混ざる）。
    def remoteStart(app: App.App[w, ef], bridge: Bridge, request: Request,
                    ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + Fs.FileRead + IO) =
        match Map.get("name", request#params) {
            case None => answer("error: POST /start needs name= (see GET /starts)\n", bridge, ctx)
            case Some(name) =>
                let args = request#params |> Map.remove("name") |> Map.remove("view");
                let (built, files) = Flow.Record.captureReads(() -> App.buildStart(app, GameEngine.Game.getViewportRect()#size, name, args));
                match built {
                    case Err(why)  => answer("error: ${why}\n", bridge, ctx)
                    case Ok(world) =>
                        let block = if (Map.get("view", request#params) == Some("shot")) shotBlock(app, world)
                                    else "[status]\n${statusText(app, world)}\n";
                        answer("ok start=${name}\n${block}", bridge,
                               { world = world, history = Nil, anno = { scrub = 0 | ctx#anno }, stepState = App.freshStepState(),
                                 record = Flow.Record.Item.Started(Flow.Record.startLine(name, args, files)) :: Nil | ctx })
                }
        }

    /// 応答を書いてから next を返すだけの小さな合流点。
    def answer(text: String, bridge: Bridge, next: RemoteNext[w]): RemoteNext[w] \ IO =
        respond(text, bridge);
        next

    /// 停止に入る見た目（ウィンドウタイトルのバッジと十字カーソル）。F8 と同じ絵柄。
    def enterHaltMarkers(): Unit \ GameEngine.Game =
        GameEngine.Game.setDebugBadge(true);
        GameEngine.Game.setCursor(GameEngine.Cursor.Crosshair)

    /// 停止を抜ける見た目（バッジを外して通常カーソルへ）。
    def exitHaltMarkers(): Unit \ GameEngine.Game =
        GameEngine.Game.setDebugBadge(false);
        GameEngine.Game.setCursor(GameEngine.Cursor.Default)

    /// POST /halt: 時間を止めて lockstep モードへ入る。既に停止中でも安全（冪等）。
    def remoteHalt(app: App.App[w, ef], bridge: Bridge,
                   ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + IO) =
        if (not ctx#anno#paused) enterHaltMarkers() else ();
        let shownFrame = ctx#anno#frame - Int32.toInt64(ctx#anno#scrub);
        let displayed = App.worldAt(ctx#history, ctx#anno#scrub, ctx#world);
        answer("ok mode=halted frame=${shownFrame}\n[status]\n${statusText(app, displayed)}\n",
               bridge, { anno = { paused = true | ctx#anno }, hold = true | ctx })

    /// POST /resume: 実時間の進行へ戻す。スクラブで過去を見ていたらそこから再開する。
    def remoteResume(bridge: Bridge,
                     ctx: RemoteNext[w]): RemoteNext[w] \ (GameEngine.Game + IO) =
        if (not ctx#anno#paused)
            answer("ok mode=running frame=${ctx#anno#frame}\n", bridge, { hold = false | ctx })
        else {
            exitHaltMarkers();
            let resumed = App.resumePoint(ctx#anno, ctx#history, ctx#world);
            answer("ok mode=running frame=${resumed#anno#frame}\n", bridge,
                   { world = resumed#world, anno = resumed#anno, history = resumed#history, hold = false,
                     record = rewound(ctx#anno) | ctx })
        }

    /// GET /state: 進めずに観測だけ返す。停止中はスクラブで表示中の瞬間を見る。
    def remoteState(app: App.App[w, ef], bridge: Bridge, request: Request,
                    ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + IO) =
        match parseParams(request#params) {
            case Err(message) => answer(message + "\n", bridge, ctx)
            case Ok(stepParams) =>
                let displayed = App.worldAt(ctx#history, ctx#anno#scrub, ctx#world);
                let modeName = if (ctx#anno#paused) "halted" else "running";
                let shownFrame = ctx#anno#frame - Int32.toInt64(ctx#anno#scrub);
                answer("ok frame=${shownFrame} mode=${modeName}\n" + viewBlock(app, stepParams, displayed),
                       bridge, ctx)
        }

    /// POST /step: 本文の flow（1 行 1 手。start の無い手はいまの World から）を流し、結果を 1 応答に束ねて返す。
    /// 実行中に来たら自動で停止してから進める。スクラブで過去を見ていたら
    /// 「表示中の瞬間から再開して進める」（F8 解除と同じ意味論。未来側の履歴は捨てる）。
    def remoteStepCommand(app: App.App[w, ef], bridge: Bridge, request: Request,
                          ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + Fs.FileRead + IO) =
        match parseParams(request#params) {
            case Err(message) => answer(message + "\n", bridge, ctx)
            case Ok(stepParams) =>
                let base = App.resumePoint(ctx#anno, ctx#history, ctx#world);
                match stepScriptOf(app, base#world, request, stepParams) {
                    case Err(message) => answer(message + "\n", bridge, ctx)
                    case Ok(script) =>
                        if (not ctx#anno#paused) enterHaltMarkers() else ();
                        let (result, files) = Flow.Record.captureReads(() ->
                            Flow.play(app, { design = GameEngine.Game.getViewportRect()#size, limit = stepParams#maxFrames },
                                      script, { world = base#world, state = ctx#stepState }));
                        let (played, flowEnd) = playedOf(result);
                        let outcome = stepOutcomeOf(app, played, { world = base#world, state = ctx#stepState, frame = base#anno#frame },
                                                    stepParams, flowEnd);
                        let annoAfter = { paused = true,
                                          frame = base#anno#frame + Int32.toInt64(outcome#framesRun) | base#anno };
                        let historyAfter = List.take(App.historyLimit(), List.append(outcome#newHistory, base#history));
                        let text = stepHeader({ stepped = outcome#framesRun, frame = annoAfter#frame,
                                                stoppedBy = outcome#stoppedBy, quit = outcome#quit })
                                 + (if (outcome#failure == "") "" else "[fail]\n${outcome#failure}\n")
                                 + eventsBlock(outcome#sounds)
                                 + traceBlock(outcome#traceLines)
                                 + viewBlock(app, stepParams, outcome#world);
                        let ran = List.take(outcome#framesRun, played);
                        answer(text, bridge,
                               { world = outcome#world, anno = annoAfter, history = historyAfter, hold = true,
                                 stepState = outcome#stepState,
                                 record = List.append(rewound(ctx#anno), itemsOf(app, script, ran, startsOf(result), files)) })
                }
        }

    /// 応答に載せる観測本文（[status] / [full] / [scene] のブロック）。
    def viewBlock(app: App.App[w, ef], stepParams: StepParams, world: w): String \ (ef + GameEngine.Game + IO) =
        match stepParams#view {
            case View.Silent  => ""
            case View.Shot    => shotBlock(app, world)
            case View.Status  => "[status]\n" + statusText(app, world) + "\n"
            case View.Summary => "[status]\n" + statusText(app, world) + "\n"
            case View.Full    =>
                let rect = Option.getWithDefault(GameEngine.Game.getViewportRect(), stepParams#rect);
                match app#worldDump {
                    case Some(dump) => "[full]\n" + capBody(dump(rect, world)) + "\n"
                    case None       => "[full]\n(no worldDump wired; try view=scene)\n"
                }
            case View.Scene   =>
                let rect = Option.getWithDefault(GameEngine.Game.getViewportRect(), stepParams#rect);
                sceneText(app, rect, world) + "\n"
        }

    /// view=shot の本文: [shot] と、撮れたら `ok png=<パス>`（/render と同じ形）・撮れなければ `error: 理由`。
    /// 描き出しは Java2D なので、AWT が窓を起こさないよう先に headless を明示する（/render と同じ理由）。
    pub def shotBlock(app: App.App[w, ef], world: w): String \ IO =
        "[shot]\n" + match app#shot {
            case None => "error: shot not supported (game does not wire App.onShotRequest)\n"
            case Some(f) =>
                discard System.setProperty("java.awt.headless", "true");
                try { "ok png=${f(world)}\n" } catch {
                    case e: Throwable => "error: ${e.toString()}\n"
                }
        }

    /// view=status の本文。ゲームが withStatusLine を繋いでいなければその旨を返す。
    def statusText(app: App.App[w, ef], world: w): String \ ef =
        match app#statusLine {
            case Some(toLine) => toLine(world)
            case None         => "(no statusLine wired; use view=scene or wire App.withStatusLine)"
        }

    /// view=scene の本文。view（PlacedItem 投影）か debugView（生チャンネル投影）から、
    /// 矩形に重なる描画物を列挙する。どちらも無いゲームは観測手段が無い旨を返す。
    def sceneText(app: App.App[w, ef], rect: Rect2.Rect2, world: w): String \ (ef + GameEngine.Game) =
        match (app#view, app#debugView) {
            case (Some(toItems), _) =>
                let atlas = GameEngine.Game.getFontAtlas("default");
                // 画面座標の矩形と突き合わせるので、カメラ適用後（=画面に出ている）items を使う
                let hitList = Annotate.hits(name -> GameEngine.Game.getTextureInfo(name), rect,
                                            App.sceneItems(app, atlas, _ -> (), world, toItems));
                sceneBlock(rect, hitList)
            case (None, Some((_, toChannels))) =>
                let (drawables, _, _) = toChannels(world);
                let hitList = Annotate.hitsFromDrawables(name -> GameEngine.Game.getTextureInfo(name),
                                                         rect, drawables);
                sceneBlock(rect, hitList)
            case (None, None) => "[scene]\n(no view/debugView wired)"
        }

    // ── リモートデバッグ（HTTP）: /step・/flow の実行器（中身は Flow.play = 実機と同じ 1 フレーム）──

    /// /step 1 回ぶんの実行結果。
    pub type alias StepOutcome[w] = {
        world = w,                       // 実行後の World
        stepState = App.StepState,       // 実行後の固定刻みの持ち越しと実時間の時計
        newHistory = List[w],            // 実行中に積んだ World（新しい順・上限つき）
        framesRun = Int32,               // 実際に進んだコマ数
        sounds = List[(Int64, String)],  // (絶対フレーム番号, 音名) の時系列
        stoppedBy = String,              // "script" / "until:sfx" / "until:quiet" / "quit" / "max" / "fail"
        quit = Bool,                     // 終了条件（quitWhen）に触れて止まったか
        failure = String,                // flow が止まった所（"" = 最後まで流れた）
        traceLines = List[String]        // trace=status:K で集めた行（時系列）
    }

    /// flow が流したフレームの列を、/step の止め方（until=sfx|quiet・quitWhen）で切り、応答の材料にする。
    /// quitWhen に触れたフレームはまだ流していない扱い（実機ではそのフレームで閉じる）。
    pub def stepOutcomeOf(app: App.App[w, ef], played: List[Flow.Played[w]],
                          start: { world = w, state = App.StepState, frame = Int64 },
                          stepParams: StepParams, flowEnd: String): StepOutcome[w] \ ef =
        let first = { world = start#world, state = start#state, done = 0, quietRun = 0, acc = Nil, sounds = Nil,
                      stopped = "", quit = false, trace = Nil };
        let final = played |> List.foldLeft((fold, entry) -> {
            if (fold#stopped != "") fold
            else {
                let wantsQuit = app#quit;
                if (wantsQuit(entry#step#frame, fold#world)) { stopped = "quit", quit = true | fold }
                else {
                    let frameNo = start#frame + Int32.toInt64(fold#done) + 1i64;
                    let (stoppedNow, quietNow) = stopCheck(stepParams#stopWhen, entry#step#sounds, fold#quietRun);
                    let traceNow = match stepParams#traceEvery {
                        case Some(every) =>
                            if (Int32.modulo(fold#done + 1, every) == 0)
                                "f=${frameNo} ${statusText(app, entry#step#after)}" :: fold#trace
                            else fold#trace
                        case None => fold#trace
                    };
                    { world = entry#step#after, state = entry#state, done = fold#done + 1, quietRun = quietNow,
                      acc = entry#step#after :: fold#acc,
                      sounds = List.append(List.reverse(entry#step#sounds |> List.map(name -> (frameNo, name))), fold#sounds),
                      stopped = stoppedNow, trace = traceNow | fold }
                }
            }
        }, first);
        { world = final#world, stepState = final#state,
          newHistory = List.take(App.historyLimit(), final#acc),
          framesRun = final#done,
          sounds = List.reverse(final#sounds),
          stoppedBy = if (final#stopped != "") final#stopped
                      else if (flowEnd == "") "script"
                      else if (String.contains(substr = "フレームの上限", flowEnd)) "max"
                      else "fail",
          quit = final#quit,
          failure = if (final#stopped != "") "" else flowEnd,
          traceLines = List.reverse(final#trace) }

    /// flow の結果（流し終えた・止まった）からフレームの列と止まった所の 1 行を取り出す。
    pub def playedOf(result: Result[Flow.Failure[w], Flow.Outcome[w]]): (List[Flow.Played[w]], String) =
        match result {
            case Ok(outcome)  => (outcome#frames, "")
            case Err(failure) => (failure#upTo#frames, failureLine(failure))
        }

    /// 止まった所の 1 行（行番号・理由・何フレーム目・使った問いの値）。
    pub def failureLine(failure: Flow.Failure[w]): String =
        "${failure#at#file}:${Int32.toString(failure#at#number)}: ${failure#why} / ${Int32.toString(failure#frame)} フレーム目"
            + (if (failure#seen == "") "" else " / ${failure#seen}")

    /// /step の本文を flow として読む（語彙はいまの World から）。dt= のクエリは fps より先に効く（診断用）。
    def stepScriptOf(app: App.App[w, ef], world: w, request: Request, stepParams: StepParams): Result[String, Flow.Script] =
        Flow.Parse.parseText(Flow.vocabOf(app, world), "body", request#body)
            |> Result.mapErr(problems -> "error: " + Flow.Parse.problemsText(problems))
            |> Result.map(script -> if (Map.memberOf("dt", request#params)) { fps = 1.0 / stepParams#dtSeconds | script } else script)

    /// POST /flow: flow（本文か ?path=）を新しく作った World（先頭の始まり）から流し、結果の表を返す。
    /// ?apply=1 なら流し終えた World へ差し替える（その場面から遊べる・止めている間は止まったまま）。
    /// ?repeat=N は同じ flow を N 回流す（速さを測る。結果の表は最後の 1 回）。ゲームのループの中で流すので上限は flowFrameCap。
    def remoteFlow(app: App.App[w, ef], bridge: Bridge, request: Request,
                   ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + Fs.FileRead + IO) =
        let design = GameEngine.Game.getViewportRect()#size;
        let fresh = App.freshWorld(app, design);
        let vocab = Flow.vocabOf(app, fresh);
        let parsed = match Map.get("path", request#params) {
            case Some(path) => Flow.Parse.parseFile(vocab, path, Flow.Cli.readText)
            case None       => Flow.Parse.parseText(vocab, "body", request#body)
        };
        match parsed {
            case Err(problems) => answer("error: " + Flow.Parse.problemsText(problems) + "\n", bridge, ctx)
            case Ok(script) =>
                let (start, startFiles) = Flow.Record.captureReads(() -> Flow.Cli.startWorld(app, design, fresh, script));
                let repeat = Map.get("repeat", request#params) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(1);
                let began = GameEngine.Game.getViewportRect();
                let results = List.range(0, Int32.max(1, repeat)) |> List.map(_ ->
                    Flow.Record.captureReads(() -> Flow.play(app, { design = began#size, limit = flowFrameCap() }, script,
                                                        { world = start, state = App.freshStepState() })));
                match List.last(results) {
                    case None => answer("error: nothing ran\n", bridge, ctx)
                    case Some((Err(failure), _)) => answer("FAIL ${failureLine(failure)}\n    ${failure#at#text}\n", bridge, ctx)
                    case Some((Ok(outcome), files)) =>
                        let text = "ok frames=${Int32.toString(List.length(outcome#frames))} repeat=${Int32.toString(repeat)}\n"
                                 + "[places]\n" + placesText(outcome) + "\n"
                                 + "[status]\n" + statusText(app, outcome#last) + "\n";
                        // 記録には、先頭の始まり（書いていなければ登録簿の先頭）から流したフレームを足す。
                        let leading = match (List.head(script#lines) |> Option.map(line -> line#step), List.head(app#starts)) {
                            case (Some(Flow.Step.Start(_, _, _)), _) => Nil
                            case (_, Some(first)) => Flow.Record.Item.Started(Flow.Record.startLine(first#name, Map.empty(), startFiles)) :: Nil
                            case _ => Flow.Record.Item.Line("# /flow?apply（始まりの登録簿が無いので、再生はここから食い違う）") :: Nil
                        };
                        if (Map.get("apply", request#params) == Some("1"))
                            answer(text, bridge, { world = outcome#last, stepState = outcome#state, history = Nil,
                                                   anno = { scrub = 0 | ctx#anno },
                                                   record = List.append(leading, itemsOf(app, script, outcome#frames, outcome#starts, files)) | ctx })
                        else answer(text, bridge, ctx)
                }
        }

    /// 停止中にスクラブで過去を見ていたら、そこから進める前に記録へ rewind を足す。
    def rewound(anno: Annotate.State): List[Flow.Record.Item] =
        if (anno#paused and anno#scrub > 0) Flow.Record.Item.Line("rewind ${Int32.toString(anno#scrub)}") :: Nil else Nil

    /// flow の結果の始まりの場所（流し終えた・止まった）。
    def startsOf(result: Result[Flow.Failure[w], Flow.Outcome[w]]): List[(Int32, String)] =
        match result {
            case Ok(outcome)  => outcome#starts
            case Err(failure) => failure#upTo#starts
        }

    /// 流したフレームを記録の材料にする: 始まりの場所に start の行（引数は flow に書いた物・読んだファイルの中身つき）、
    /// 各フレームはそのまま（後の World の指紋の元つき）。
    def itemsOf(app: App.App[w, ef], script: Flow.Script, played: List[Flow.Played[w]], starts: List[(Int32, String)],
                files: Map[String, Flow.File]): List[Flow.Record.Item] =
        let startLines = script#lines |> List.filterMap(line -> match line#step {
            case Flow.Step.Start(name, args, _) => Some(Flow.Record.startLine(name, args, files))
            case _                              => None
        });
        let at = List.zip(starts, startLines) |> List.map(match ((count, _), text) -> (count, text));
        let linesAt = i -> at |> List.filter(entry -> fst(entry) == i) |> List.map(entry -> Flow.Record.Item.Started(snd(entry)));
        let fp = world -> app#fingerprint |> Option.map(f -> f(world));
        let body = played |> List.zipWithIndex |> List.flatMap(match (i, entry) ->
            List.append(linesAt(i), Flow.Record.Item.Played(entry#step#frame, fp(entry#step#after)) :: Nil));
        List.append(body, linesAt(List.length(played)))

    /// 始まりと mark の場所（何フレーム目か）を 1 行ずつ。
    def placesText(outcome: Flow.Outcome[w]): String =
        let starts = outcome#starts |> List.map(match (at, name) -> "start ${name} @${Int32.toString(at)}");
        let marks = outcome#marks |> Map.toList |> List.map(match (name, at) -> "mark ${name} @${Int32.toString(at)}");
        String.intercalate("\n", List.append(starts, marks))

    /// POST /flow 1 回で流せるフレームの上限（60fps で 10 分ぶん）。ゲームのループの中で流すので、その間は窓が止まる。
    pub def flowFrameCap(): Int32 = 36000
}
