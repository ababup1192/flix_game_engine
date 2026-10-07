// RemoteDebug — 起動中のゲームを外部プロセス（AI エージェント等）が HTTP で操作・観測する口。
// curl 一発で「キー入力の台本を N フレーム実行して、結果の状態を受け取る」が完結する。
// デバッグ専用: App の debug が有効かつ環境変数 DEBUG_HTTP_PORT があるときだけ立ち上がる。
//
// スレッドの取り決め: HTTP のスレッドは World に一切触れない。リクエストの生文字列をキューへ
// 積んで応答文字列を待つだけで、パース・実行・応答の組み立てはすべてゲームループ側
// （App）が行う。ゲームが応答しなければ 10 秒で 503 を返す。

pub mod RemoteDebug {
    import java.lang.System
    import java.net.InetSocketAddress
    import com.sun.net.httpserver.HttpServer
    import com.sun.net.httpserver.HttpHandler
    import com.sun.net.httpserver.HttpExchange
    import java.util.concurrent.{LinkedBlockingQueue => JQueue}
    import java.util.concurrent.TimeUnit
    import java.lang.{String => JString}

    // ── HTTP スレッドとゲームループを繋ぐ橋 ──

    /// HTTP サーバ本体と、リクエスト / レスポンスを受け渡す 2 本のキュー。
    pub type alias Bridge = {
        server = HttpServer,           // 稼働中のサーバ（終了時に stop する）
        requests = JQueue[String],     // HTTP → ゲームループ（"METHOD /path?query\n台本" の生文字列）
        responses = JQueue[String]     // ゲームループ → HTTP（text/plain の応答本文）
    }

    /// 環境変数 DEBUG_HTTP_PORT からポート番号を読む。未設定・数値でなければ None。
    pub def portFromEnv(): Option[Int32] \ IO =
        let value = System.getenv("DEBUG_HTTP_PORT");
        if (Object.isNull(value)) None else Int32.fromString(value)

    /// 127.0.0.1 の port で HTTP サーバを立てて Bridge を返す。
    /// ハンドラはリクエストを 1 つの文字列にまとめてキューへ積み、応答を最大 10 秒待つ。
    /// executor を与えない（null）ので処理は 1 スレッド直列 = 同時リクエストも順番に並ぶ。
    pub def start(port: Int32): Bridge \ IO =
        let requests: JQueue[String] = new JQueue();
        let responses: JQueue[String] = new JQueue();
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
                discard requests.offer("${methodName} ${path}${queryPart}\n${bodyText}");
                let answer = responses.poll(10i64, TimeUnit.SECONDS);
                let timedOut = Object.isNull(answer);
                let text = if (timedOut) "error: game loop did not answer within 10s\n" else answer;
                let headers = exchange.getResponseHeaders();
                headers.set("Content-Type", "text/plain; charset=utf-8");
                let bytes = text.getBytes("UTF-8");
                exchange.sendResponseHeaders(if (timedOut) 503 else 200, Int32.toInt64(Array.length(bytes)));
                let out = exchange.getResponseBody();
                out.write(bytes);
                out.close()
            }
        });
        server.start();
        println("[remote-debug] listening on http://127.0.0.1:${port} (GET /help)");
        { server = server, requests = requests, responses = responses }

    /// ゲームループが毎フレーム呼ぶ非ブロッキングの受信。届いていなければ None。
    pub def pollRequest(bridge: Bridge): Option[String] \ IO =
        let queue = bridge#requests;
        let raw = queue.poll();
        if (Object.isNull(raw)) None else Some(raw)

    /// 応答本文を HTTP スレッドへ返す（pollRequest で受けた 1 件に必ず 1 回対で呼ぶ）。
    pub def respond(text: String, bridge: Bridge): Unit \ IO =
        let queue = bridge#responses;
        discard queue.offer(text)

    /// サーバを止める（ゲーム終了時）。待機中のリクエストは切断される。
    pub def shutdown(bridge: Bridge): Unit \ IO =
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
            case "none"    => Ok(View.Silent)
            case other     => Err("error: unknown view '${other}' (status|summary|full|scene|none)")
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

    // ── 台本 DSL のパース ──

    /// 台本 1 コマ = そのフレームで押しているキーの集合。リストの並びがフレームの並び。
    pub type alias Script = List[Set[GameEngine.Key]]

    /// 台本 DSL を 1 フレーム 1 コマのキー集合列へ展開する。# 以降はコメント。
    ///   idle N          … 何も押さないフレームを N 個
    ///   press K         … K を 1 フレーム押して 1 フレーム離す（1 押下 = 1 発火）
    ///   hold K N        … K を N フレーム押しっぱなし
    ///   hold K1,K2 N    … 同時押しで N フレーム
    pub def parseScript(body: String): Result[String, Script] =
        String.lines(body)
        |> List.map(line -> stripComment(line) |> String.trim)
        |> List.filter(line -> line != "")
        |> parseScriptLines

    def parseScriptLines(lines: List[String]): Result[String, Script] =
        match lines {
            case Nil => Ok(Nil)
            case line :: rest =>
                forM (frames <- parseScriptLine(line); tail <- parseScriptLines(rest))
                    yield List.append(frames, tail)
        }

    def parseScriptLine(line: String): Result[String, Script] =
        match String.words(line) {
            case "idle" :: count :: Nil =>
                forM (n <- parseCount(count)) yield List.repeat(n, Set.empty())
            case "press" :: keys :: Nil =>
                forM (keySet <- parseKeys(keys)) yield keySet :: Set.empty() :: Nil
            case "hold" :: keys :: count :: Nil =>
                forM (keySet <- parseKeys(keys); n <- parseCount(count))
                    yield List.repeat(n, keySet)
            case _ => Err("error: cannot parse script line '${line}' (idle N / press K / hold K N)")
        }

    def parseCount(text: String): Result[String, Int32] =
        match Int32.fromString(text) {
            case Some(n) if n >= 1 and n <= frameCap() => Ok(n)
            case _ => Err("error: frame count must be 1..${frameCap()} (got '${text}')")
        }

    def parseKeys(text: String): Result[String, Set[GameEngine.Key]] =
        String.splitOn({substr = ","}, text)
        |> List.foldLeft((acc, name) -> forM (
               keySet <- acc;
               key <- keyOf(name) |> Option.toOk("error: unknown key '${name}' (${keyNames()})")
           ) yield Set.insert(key, keySet), Ok(Set.empty()))

    /// "z" や "Enter" のようなキー名を Key へ。解決は InputMap と同じ 1 本 —
    /// 台本とキー設定 Doc で通る名前がずれない。
    pub def keyOf(name: String): Option[GameEngine.Key] =
        InputMap.keyOf(name)

    /// 台本で使える全キー名（help と unknown key エラーに載せる）。
    pub def keyNames(): String =
        GameEngine.allKeys() |> List.map(key -> "${key}") |> String.intercalate(",")

    def stripComment(line: String): String =
        match String.indexOfLeft({substr = "#"}, line) {
            case Some(i) => String.takeLeft(i, line)
            case None    => line
        }

    // ── 応答の整形 ──

    /// /step 応答の 1 行目。何フレーム進んで何故止まったかを 1 行で伝える。
    pub def stepHeader(info: { stepped = Int32, total = Int32, frame = Int64,
                               stoppedBy = String, quit = Bool }): String =
        "ok stepped=${info#stepped} frame=${info#frame} mode=halted"
        + " stopped=${info#stoppedBy} consumed=${info#stepped}/${info#total}"
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
        + "     on the warm JVM; answers the rendered file paths. play state is untouched.\n"
        + "POST /step?view=&rect=&until=&max=&trace=&dt=\n"
        + "     body = input script; runs it frame by frame, then answers.\n"
        + "     auto-halts first if the game is running.\n"
        + "ANY  /<path>?k=v              game-registered handler (App.onRequest), if wired\n"
        + "\n"
        + "script DSL (one command per line, # comments):\n"
        + "  idle N        wait N frames\n"
        + "  press K       tap key K (1 frame down + 1 frame up)\n"
        + "  hold K N      hold key K for N frames\n"
        + "  hold K1,K2 N  hold keys together for N frames\n"
        + "keys: " + keyNames() + "\n"
        + "\n"
        + "query params:\n"
        + "  view=status|summary|full|scene|none   response detail (default status)\n"
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
        hold = Bool              // HTTP 側が停止の主導権を持っているか（真の間 F8 は無効）
    }

    /// リクエスト 1 件を捌き、応答をブリッジへ書いてから次の状態を返す。
    /// どの経路でも必ず 1 回 respond する（しないと HTTP 側が 10 秒待って 503 になる）。
    pub def handleRemote(app: App.App[w, ef], bridge: RemoteDebug.Bridge, raw: String,
                     ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + GameEngine.Audio + Fs.FileRead + IO) =
        let request = RemoteDebug.parseRequest(raw);
        match (request#method, request#path) {
            case ("GET", "/help")    => answer(RemoteDebug.helpText(), bridge, ctx)
            case ("POST", "/halt")   => remoteHalt(app, bridge, ctx)
            case ("POST", "/resume") => remoteResume(bridge, ctx)
            case ("GET", "/state")   => remoteState(app, bridge, request, ctx)
            case ("POST", "/step")   => remoteStepCommand(app, bridge, request, ctx)
            case ("POST", "/render") => remoteRenderCommand(app, bridge, ctx)
            case (m, p)              =>
                match RemoteDebug.findRoute(p, app#remoteHandlers) {
                    case Some(chosen) => remoteCustom(chosen, bridge, request, ctx)
                    case None => answer("error: no route for ${m} ${p} (see GET /help)\n", bridge, ctx)
                }
        }

    /// ゲーム登録の任意ルート（App.onRequest）を 1 件適用する。Ok なら world を差し替えて
    /// "ok"、Err なら理由をそのまま応答する。停止状態・履歴・hold には触れない —
    /// 走行中なら差し替わった world で次の実フレームから進み、停止中なら /resume でそこから再開する。
    def remoteCustom(apply: (Map[String, String], w) -> Result[String, w] \ {Fs.FileRead},
                     bridge: RemoteDebug.Bridge, request: RemoteDebug.Request,
                     ctx: RemoteNext[w]): RemoteNext[w] \ (Fs.FileRead + IO) =
        match apply(request#params, ctx#world) {
            case Ok(changed)  => answer("ok\n", bridge, { world = changed | ctx })
            case Err(message) => answer("error: ${message}\n", bridge, ctx)
        }

    /// 応答を書いてから next を返すだけの小さな合流点。
    def answer(text: String, bridge: RemoteDebug.Bridge, next: RemoteNext[w]): RemoteNext[w] \ IO =
        RemoteDebug.respond(text, bridge);
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
    def remoteHalt(app: App.App[w, ef], bridge: RemoteDebug.Bridge,
                   ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + IO) =
        if (not ctx#anno#paused) enterHaltMarkers() else ();
        let shownFrame = ctx#anno#frame - Int32.toInt64(ctx#anno#scrub);
        let displayed = App.worldAt(ctx#history, ctx#anno#scrub, ctx#world);
        answer("ok mode=halted frame=${shownFrame}\n[status]\n${statusText(app, displayed)}\n",
               bridge, { anno = { paused = true | ctx#anno }, hold = true | ctx })

    /// POST /resume: 実時間の進行へ戻す。スクラブで過去を見ていたらそこから再開する。
    def remoteResume(bridge: RemoteDebug.Bridge,
                     ctx: RemoteNext[w]): RemoteNext[w] \ (GameEngine.Game + IO) =
        if (not ctx#anno#paused)
            answer("ok mode=running frame=${ctx#anno#frame}\n", bridge, { hold = false | ctx })
        else {
            exitHaltMarkers();
            let resumed = App.resumePoint(ctx#anno, ctx#history, ctx#world);
            answer("ok mode=running frame=${resumed#anno#frame}\n", bridge,
                   { world = resumed#world, anno = resumed#anno, history = resumed#history, hold = false })
        }

    /// POST /render: 登録された描き出しの実体（App.onRenderRequest）を温まった JVM で実行し、
    /// 描き出したファイルパスの列を返す。描き出しは Docs から決定的な場面を組み立てるだけなので、
    /// 走行中のプレイ状態（world・停止状態・履歴）には一切触れない — ctx をそのまま返す。
    /// 未登録のゲームには「未対応」を返す（Studio はそれを見て自前の描き出し起動へ
    /// フォールバックする）。同時に来た 2 発目は /step と同じ排他の流儀 — HTTP 側は
    /// 1 スレッド直列・ゲームループは 1 フレーム 1 件なので、キュー順に必ず直列で捌かれる。
    def remoteRenderCommand(app: App.App[w, ef], bridge: RemoteDebug.Bridge,
                          ctx: RemoteNext[w]): RemoteNext[w] \ IO =
        match app#remoteRender {
            case None => answer(RemoteDebug.renderUnsupportedText(), bridge, ctx)
            case Some(renderScenes) =>
                // 描き出し（SoftRaster / HeadlessFont）は Java2D = AWT を使う。macOS の実機起動は
                // -XstartOnFirstThread で GLFW が主スレッドを占有しており、ここで AWT が
                // AppKit を起こそうとすると永久ハングし得る。このプロセスは AWT のウィンドウを
                // 開かないので、初回の AWT 初期化前に headless を明示しておく
                // （bin/flix が test / 描き出しの実行に付けるのと同じ理由）。
                discard System.setProperty("java.awt.headless", "true");
                let startNs = System.nanoTime();
                let paths = renderScenes();
                let elapsedMs = (System.nanoTime() - startNs) / 1000000i64;
                answer(RemoteDebug.renderDoneText(elapsedMs, paths), bridge, ctx)
        }

    /// GET /state: 進めずに観測だけ返す。停止中はスクラブで表示中の瞬間を見る。
    def remoteState(app: App.App[w, ef], bridge: RemoteDebug.Bridge, request: RemoteDebug.Request,
                    ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + IO) =
        match RemoteDebug.parseParams(request#params) {
            case Err(message) => answer(message + "\n", bridge, ctx)
            case Ok(stepParams) =>
                let displayed = App.worldAt(ctx#history, ctx#anno#scrub, ctx#world);
                let modeName = if (ctx#anno#paused) "halted" else "running";
                let shownFrame = ctx#anno#frame - Int32.toInt64(ctx#anno#scrub);
                answer("ok frame=${shownFrame} mode=${modeName}\n" + viewBlock(app, stepParams, displayed),
                       bridge, ctx)
        }

    /// POST /step: 台本を 1 コマ = 1 フレームで実行し、結果を 1 応答に束ねて返す。
    /// 実行中に来たら自動で停止してから進める。スクラブで過去を見ていたら
    /// 「表示中の瞬間から再開して進める」（F8 解除と同じ意味論。未来側の履歴は捨てる）。
    def remoteStepCommand(app: App.App[w, ef], bridge: RemoteDebug.Bridge, request: RemoteDebug.Request,
                          ctx: RemoteNext[w]): RemoteNext[w] \ (ef + GameEngine.Game + GameEngine.Audio + Fs.FileRead + IO) =
        match (RemoteDebug.parseParams(request#params), RemoteDebug.parseScript(request#body)) {
            case (Err(message), _) => answer(message + "\n", bridge, ctx)
            case (_, Err(message)) => answer(message + "\n", bridge, ctx)
            case (Ok(stepParams), Ok(script)) =>
                if (List.isEmpty(script))
                    answer("error: empty script (body needs idle/press/hold lines; see GET /help)\n", bridge, ctx)
                else {
                    if (not ctx#anno#paused) enterHaltMarkers() else ();
                    let base = App.resumePoint(ctx#anno, ctx#history, ctx#world);
                    let outcome = remoteStep(app, base#world, base#anno#frame, script, stepParams);
                    let annoAfter = { paused = true,
                                      frame = base#anno#frame + Int32.toInt64(outcome#framesRun) | base#anno };
                    let historyAfter = List.take(App.historyLimit(),
                                                 List.append(outcome#newHistory, base#history));
                    let total = Int32.min(List.length(script), stepParams#maxFrames);
                    let text = RemoteDebug.stepHeader({ stepped = outcome#framesRun, total = total,
                                                        frame = annoAfter#frame,
                                                        stoppedBy = outcome#stoppedBy, quit = outcome#quit })
                             + RemoteDebug.eventsBlock(outcome#sounds)
                             + RemoteDebug.traceBlock(outcome#traceLines)
                             + viewBlock(app, stepParams, outcome#world);
                    answer(text, bridge,
                           { world = outcome#world, anno = annoAfter, history = historyAfter, hold = true })
                }
        }

    /// 応答に載せる観測本文（[status] / [full] / [scene] のブロック）。
    def viewBlock(app: App.App[w, ef], stepParams: RemoteDebug.StepParams, world: w): String \ (ef + GameEngine.Game) =
        match stepParams#view {
            case RemoteDebug.View.Silent  => ""
            case RemoteDebug.View.Status  => "[status]\n" + statusText(app, world) + "\n"
            case RemoteDebug.View.Summary => "[status]\n" + statusText(app, world) + "\n"
            case RemoteDebug.View.Full    =>
                let rect = Option.getWithDefault(GameEngine.Game.getViewportRect(), stepParams#rect);
                match app#worldDump {
                    case Some(dump) => "[full]\n" + RemoteDebug.capBody(dump(rect, world)) + "\n"
                    case None       => "[full]\n(no worldDump wired; try view=scene)\n"
                }
            case RemoteDebug.View.Scene   =>
                let rect = Option.getWithDefault(GameEngine.Game.getViewportRect(), stepParams#rect);
                sceneText(app, rect, world) + "\n"
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
                                            App.sceneItems(app, atlas, world, toItems));
                RemoteDebug.sceneBlock(rect, hitList)
            case (None, Some((_, toChannels))) =>
                let (drawables, _, _) = toChannels(world);
                let hitList = Annotate.hitsFromDrawables(name -> GameEngine.Game.getTextureInfo(name),
                                                         rect, drawables);
                RemoteDebug.sceneBlock(rect, hitList)
            case (None, None) => "[scene]\n(no view/debugView wired)"
        }

    // ── リモートデバッグ（HTTP）: /step の実行器 ──

    /// /step 1 回ぶんの実行結果。
    type alias StepOutcome[w] = {
        world = w,                       // 実行後の World
        newHistory = List[w],            // 実行中に積んだ World（新しい順・上限つき）
        framesRun = Int32,               // 実際に進んだコマ数
        sounds = List[(Int64, String)],  // (絶対フレーム番号, 音名) の時系列
        stoppedBy = String,              // "script" / "until:sfx" / "until:quiet" / "quit" / "max"
        quit = Bool,                     // 終了条件（ウィンドウ閉 / quitWhen）に触れて止まったか
        traceLines = List[String]        // trace=status:K で集めた行（時系列）
    }

    /// /step の台本実行中に持ち回る畳み込みの状態。
    type alias StepFold[w] = {
        world = w,                        // いまの World
        prev = Set[GameEngine.Key],       // 前のコマのキー集合（エッジ判定用）
        done = Int32,                     // 進んだコマ数
        quietRun = Int32,                 // 無音が続いているコマ数（until=quiet 用）
        acc = List[w],                    // 積んだ World（新しい順）
        stopped = String,                 // 停止理由（"" = 続行）
        quit = Bool,                      // 終了条件に触れたか
        trace = List[String]              // trace の行（新しい順）
    }

    /// 台本をコマ送りで実行する芯。TestWorldJourney の headless 駆動と同じ発想で、
    /// Game / Audio をプロキシハンドラで包んで本番のシステム列をそのまま回す:
    ///   - dt は実時計でなく固定値（既定 1/60 秒）→ 何度やっても同じ結果になる
    ///   - キーは台本のコマから返す（Frame 経由でも直読みでも台本に従う）
    ///   - 描画は捨てる（vsync 待ちが無くなるので数百コマが一瞬で回る）
    ///   - 音は鳴らさず (フレーム番号, 音名) で記録して観測データにする
    /// それ以外の操作（GLFW のイベント処理を含む shouldClose 等）は実ハンドラへ素通しする。
    /// withFixedStep は見ない（台本 1 行 = updateSystems 1 回のまま）: 台本の 1 コマはすでに
    /// フレーム精度の操作であり、そこへさらに accumulator のサブステップ化を重ねると
    /// 「台本 N 行 = 何フレーム進んだか」が読めなくなる。fixedStep なゲームで /step を叩くと
    /// 可変 dt 相当の 1 回更新になる。
    def remoteStep(app: App.App[w, ef], world0: w, frame0: Int64, script: RemoteDebug.Script,
                   stepParams: RemoteDebug.StepParams): StepOutcome[w] \ (ef + GameEngine.Game + GameEngine.Audio + Fs.FileRead) =
        region rc {
            let soundsRef: Ref[List[(Int64, String)], rc] = Ref.fresh(rc, Nil);
            let frameNoRef: Ref[Int64, rc] = Ref.fresh(rc, frame0);
            let keysRef: Ref[Set[GameEngine.Key], rc] = Ref.fresh(rc, Set.empty());
            let effective = List.take(stepParams#maxFrames, script);
            let truncated = List.length(script) > List.length(effective);
            let start: StepFold[w] = { world = world0, prev = Set.empty(), done = 0, quietRun = 0,
                                       acc = Nil, stopped = "", quit = false, trace = Nil };
            let final = run {
                List.foldLeft((state, frameKeys) -> {
                    if (state#stopped != "") state
                    else {
                        Ref.put(frameKeys, keysRef);
                        let frameNo = Ref.get(frameNoRef) + 1i64;
                        Ref.put(frameNo, frameNoRef);
                        // 実ハンドラへ素通し = glfwPollEvents が回り、ウィンドウが固まらない・閉じられる
                        let closing = GameEngine.Game.shouldClose();
                        // /step の台本はキーのみ（マウスは台本に無いので常に「押されず・動かず・回さず」）。
                        let frame = App.frameOf(prev = state#prev, current = frameKeys, stepParams#dtSeconds,
                                            GameEngine.Game.getViewportRect()#size,
                                            { prevCursor = None, cursor = Vec2.zero() },
                                            { prevDown = false, down = false, wheel = 0.0 });
                        let wantsQuit = app#quit;
                        if (closing or wantsQuit(frame, state#world))
                            { stopped = "quit", quit = true | state }
                        else {
                            let capturedBefore = List.length(Ref.get(soundsRef));
                            // /step は描画を捨てるので、リロード発火の合図（タイル層の世代）は
                            // ここでは使わない — 台本にリロードキーを混ぜる運用は想定しない。
                            let (reloaded, _reloadFired) = App.applyReload(app, frame, state#world);
                            let advanced = App.applySystems(frame, app#updateSystems, reloaded);
                            // 音の 2 経路: システムが直接鳴らした分はプロキシが記録済み、
                            // withAudio 由来はここで導出して記録する。
                            let derive = app#audio;
                            derive({ before = reloaded, after = advanced })
                                |> List.forEach(name ->
                                       Ref.put((frameNo, name) :: Ref.get(soundsRef), soundsRef));
                            let soundsNow = Ref.get(soundsRef)
                                |> List.take(List.length(Ref.get(soundsRef)) - capturedBefore)
                                |> List.map(snd);
                            let (stoppedNow, quietNow) =
                                RemoteDebug.stopCheck(stepParams#stopWhen, soundsNow, state#quietRun);
                            let traceNow = match stepParams#traceEvery {
                                case Some(every) =>
                                    if (Int32.modulo(state#done + 1, every) == 0)
                                        "f=${frameNo} ${statusText(app, advanced)}" :: state#trace
                                    else state#trace
                                case None => state#trace
                            };
                            { world = advanced, prev = frameKeys, done = state#done + 1,
                              quietRun = quietNow, acc = advanced :: state#acc,
                              stopped = stoppedNow, quit = false, trace = traceNow }
                        }
                    }
                }, start, effective)
            } with handler GameEngine.Game {
                def getDeltaTime(k)             = k(Duration.seconds(stepParams#dtSeconds))
                def isKeyPressed(key, k)        = k(Set.memberOf(key, Ref.get(keysRef)))
                def renderCommands(_s, _t, _p, _st, k) = k(())
                def shouldClose(k)              = k(GameEngine.Game.shouldClose())
                def initTileBuffer(instances, k) = k(GameEngine.Game.initTileBuffer(instances))
                def updateTileBuffer(vaoId, instances, k) = k(GameEngine.Game.updateTileBuffer(vaoId, instances))
                def getMousePosition(k)         = k(GameEngine.Game.getMousePosition())
                def isMouseButtonPressed(b, k)  = k(GameEngine.Game.isMouseButtonPressed(b))
                def consumeScrollDelta(k)       = k(GameEngine.Game.consumeScrollDelta())
                def getFontAtlas(name, k)       = k(GameEngine.Game.getFontAtlas(name))
                def ensureGlyphs(n, cps, k)     = k(GameEngine.Game.ensureGlyphs(n, cps))
                def getViewportRect(k)          = k(GameEngine.Game.getViewportRect())
                def getTextureInfo(name, k)     = k(GameEngine.Game.getTextureInfo(name))
                def ensureTexture(n, key, w0, h0, px, k) =
                    k(GameEngine.Game.ensureTexture(n, key, w0, h0, px))
                def setCursor(cursor, k)        = k(GameEngine.Game.setCursor(cursor))
                def setCursorVisible(v, k)      = k(GameEngine.Game.setCursorVisible(v))
                def setFullscreen(on, k)        = k(GameEngine.Game.setFullscreen(on))
                def isFullscreen(k)             = k(GameEngine.Game.isFullscreen())
                def saveAnnotation(req, k)      = k(GameEngine.Game.saveAnnotation(req))
                def setDebugBadge(enabled, k)   = k(GameEngine.Game.setDebugBadge(enabled))
            } with handler GameEngine.Audio {
                def playAudio(name, k)  = {
                    Ref.put((Ref.get(frameNoRef), name) :: Ref.get(soundsRef), soundsRef);
                    k()
                }
                def stopAudio(name, k)          = k(GameEngine.Audio.stopAudio(name))
                def setVolume(name, volume, k)  = k(GameEngine.Audio.setVolume(name, volume))
                def setPitch(name, pitch, k)    = k(GameEngine.Audio.setPitch(name, pitch))
                def setLooping(name, looping, k) = k(GameEngine.Audio.setLooping(name, looping))
                def setMasterVolume(gain, k)    = k(GameEngine.Audio.setMasterVolume(gain))
                def reloadAudio(name, path, k)  = k(GameEngine.Audio.reloadAudio(name, path))
            };
            { world = final#world,
              newHistory = List.take(App.historyLimit(), final#acc),
              framesRun = final#done,
              sounds = List.reverse(Ref.get(soundsRef)),
              stoppedBy = if (final#stopped != "") final#stopped
                          else if (truncated) "max" else "script",
              quit = final#quit,
              traceLines = List.reverse(final#trace) }
        }
}
