// App.Headless — 窓を開かないゲーム。Studio の会話のプレビューと bin/fge talk shot が、ゲームの本物の描き方で
// 好きな場面を 1 枚撮るのに使う（ゲームを起動していなくても撮れる・起動中のゲームを動かさない）。
//
// ゲームに置く入口は 1 つ（新しい make の口は作らない。bin/headless-run が jar を作って流す）:
//
//   // src/E2e.flix
//   pub def serveHeadless(): Unit \ IO =
//       run { App.Headless.serve(Game.app(Controls.loadDocs())) } with Fs.FileRead.runWithIO
//
//   bin/headless-run E2e.serveHeadless                         待ち受ける（Studio が起こす）
//   FGE_SHOT="talk node=clock line=40" bin/headless-run E2e.serveHeadless   1 枚撮って終わる（bin/fge talk shot）
//
// 待ち受ける口（127.0.0.1・リモートデバッグと同じ書き方の部分集合）:
//   GET  /help・GET /starts
//   POST /step?view=shot|status  本文 = flow。`start talk node=… line=…` から始めれば、場面を組んで撮るまで 1 往復
//   POST /start?name=N&k=v&view=shot・GET /state?view=shot
//   POST /quit
// 撮った答えは /render と同じ形の `ok png=<パス>`（[shot] の下の行）。
//
// 実機でない扱い: 系を流すだけで、出力（App.addOutput のセーブ・表示中の Doc の名乗り）は書かず、
// 遊んだ記録（debug/flow-record/）も書かない。Doc は始まりを組むたびに読み直す（App.freshWorld）ので、
// 保存した台本がそのまま次の 1 枚に効く。
//
// 環境変数:
//   HEADLESS_PORT       待ち受けるポート（無い・0 なら OS に選ばせる）。開けたら `[headless] ready port=N pid=P` を 1 行
//   HEADLESS_IDLE_SECS  頼まれない時間がこれを超えたら自分で終わる（既定 600 秒。放っておかれた JVM を残さない）
//   FGE_SHOT            始まりの行（`名前 k=v…`）。あれば 1 枚撮って `ok png=…` を出して終わる（撮れなければ 1）
// 使うメモリの上限は java の旗で渡す（HEADLESS_JAVA_OPTS=-Xmx1g。bin/headless-run が足す）。
pub mod App.Headless {
    import java.lang.System
    import java.lang.Throwable
    import java.util.concurrent.TimeUnit

    /// 待ち受けている間に持つ物: 今の World と固定刻みの持ち越し・最後に頼まれた時刻（ナノ秒）。
    type alias Served[w] = { world = w, state = App.StepState, lastAt = Int64 }

    /// 入口の中身。FGE_SHOT があれば 1 枚撮って終わり、無ければ待ち受ける。
    pub def serve(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + IO =
        discard System.setProperty("java.awt.headless", "true");
        let design = App.loadProjectDesign(".");
        match Flow.Cli.envOr("FGE_SHOT", "") {
            case ""   => listen(app, design)
            case line => shootOnce(app, design, line)
        }

    /// 始まりの行から組んで 1 枚撮り、`ok png=…` を出す。組めない・撮れない時は理由を出して 1 で終わる。
    def shootOnce(app: App.App[w, ef], design: Vec2.Vec2, line: String): Unit \ ef + Fs.FileRead + IO =
        let built = App.parseStartLine(line) |> Result.flatMap(match (name, args) -> App.buildStart(app, design, name, args));
        match built {
            case Err(why) => println("error: ${why}"); System.exit(1)
            case Ok(world) =>
                let block = App.RemoteDebug.shotBlock(app, world);
                println(String.trim(String.dropLeft(String.length("[shot]\n"), block)));
                if (String.contains(substr = "ok png=", block)) () else System.exit(1)
        }

    /// 待ち受ける。開けたら ready の 1 行を出し、頼まれるたびに 1 件ずつ答える。
    // WhyNot: RemoteDebug.start の橋（HTTP のスレッドは World に触れず、キューで渡す）をそのまま使う —
    // 答えを作るのはここ（主スレッド）だけなので、World を共有する可変のコンテナが要らない。
    def listen(app: App.App[w, ef], design: Vec2.Vec2): Unit \ ef + Fs.FileRead + IO =
        let port = Flow.Cli.envOr("HEADLESS_PORT", "0") |> Int32.fromString |> Option.getWithDefault(0);
        let idle = Flow.Cli.envOr("HEADLESS_IDLE_SECS", "600") |> Int64.fromString |> Option.getWithDefault(600i64);
        // 待ち受け始めの World は登録簿の先頭の始まり（無ければ新しく作った初期の World）。
        let fresh = App.freshWorld(app, design);
        let world0 = match List.head(app#starts) {
            case Some(first) => App.buildStart(app, design, first#name, Map.empty()) |> Result.getWithDefault(fresh)
            case None        => fresh
        };
        // 最初の 1 枚は字のアトラスや描き出しの JIT で遅いので、ready を出す前に 1 回撮って温める。
        discard App.RemoteDebug.shotBlock(app, world0);
        let bridge = App.RemoteDebug.startQuiet(port);
        println("[headless] ready port=${App.RemoteDebug.boundPort(bridge)} pid=${App.GameRegistry.pidText()}");
        loop(app, design, bridge, idle * 1_000_000_000i64,
             { world = world0, state = App.freshStepState(), lastAt = System.nanoTime() });
        App.RemoteDebug.stopQuiet(bridge)

    def loop(app: App.App[w, ef], design: Vec2.Vec2, bridge: App.RemoteDebug.Bridge, idleNs: Int64, served: Served[w]): Unit \ ef + Fs.FileRead + IO =
        let requests = bridge#requests;
        let raw = requests.poll(1i64, TimeUnit.SECONDS);
        if (Object.isNull(raw)) {
            if (System.nanoTime() - served#lastAt > idleNs) println("[headless] 頼まれないまま時間が過ぎたので終わります")
            else loop(app, design, bridge, idleNs, served)
        } else match App.RemoteDebug.untagged(raw) {
            case None => loop(app, design, bridge, idleNs, served)
            case Some((id, text)) =>
                let current = bridge#current;
                current.set(id);
                let request = App.RemoteDebug.parseRequest(text);
                let (answer, next, quit) =
                    try { handle(app, design, request, served) } catch {
                        case e: Throwable => ("error: ${e.toString()}\n", served, false)
                    };
                App.RemoteDebug.respond(answer, bridge);
                if (quit) () else loop(app, design, bridge, idleNs, { lastAt = System.nanoTime() | next })
        }

    /// 頼み 1 件への答え・次に持つ物・終わるか。
    def handle(app: App.App[w, ef], design: Vec2.Vec2, request: App.RemoteDebug.Request,
               served: Served[w]): (String, Served[w], Bool) \ ef + Fs.FileRead + IO =
        let view = Map.getWithDefault("view", "status", request#params);
        let block = world -> if (view == "shot") App.RemoteDebug.shotBlock(app, world)
                             else "[status]\n${statusOf(app, world)}\n";
        match (request#method, request#path) {
            case ("GET", "/help")   => (helpText(), served, false)
            case ("GET", "/starts") => (App.RemoteDebug.startsText(app), served, false)
            case ("GET", "/state")  => ("ok\n" + block(served#world), served, false)
            case ("POST", "/quit")  => ("ok quit\n", served, true)
            case ("POST", "/start") => match Map.get("name", request#params) {
                case None => ("error: POST /start needs name= (see GET /starts)\n", served, false)
                case Some(name) =>
                    let args = request#params |> Map.remove("name") |> Map.remove("view");
                    match App.buildStart(app, design, name, args) {
                        case Err(why)  => ("error: ${why}\n", served, false)
                        case Ok(world) => ("ok start=${name}\n" + block(world),
                                           { world = world, state = App.freshStepState() | served }, false)
                    }
            }
            case ("POST", "/step") =>
                match Flow.Parse.parseText(Flow.vocabOf(app, served#world), "body", request#body) {
                    case Err(problems) => ("error: " + Flow.Parse.problemsText(problems) + "\n", served, false)
                    case Ok(script) =>
                        let limit = Map.get("max", request#params) |> Option.flatMap(Int32.fromString)
                                        |> Option.getWithDefault(App.RemoteDebug.flowFrameCap());
                        match Flow.play(app, { design = design, limit = limit }, script, { world = served#world, state = served#state }) {
                            case Ok(outcome) =>
                                ("ok stepped=${Int32.toString(List.length(outcome#frames))}\n" + block(outcome#last),
                                 { world = outcome#last, state = outcome#state | served }, false)
                            case Err(failure) =>
                                ("FAIL ${App.RemoteDebug.failureLine(failure)}\n    ${failure#at#text}\n" + block(failure#upTo#last),
                                 { world = failure#upTo#last, state = failure#upTo#state | served }, false)
                        }
                }
            case (m, p) => ("error: no route for ${m} ${p} (see GET /help)\n", served, false)
        }

    def statusOf(app: App.App[w, ef], world: w): String \ ef =
        match app#statusLine {
            case Some(line) => line(world)
            case None       => "(no statusLine wired)"
        }

    pub def helpText(): String =
        "headless game (no window; App.Headless). one request at a time.\n"
        + "GET  /starts                    the start registry (App.withStarts)\n"
        + "POST /step?view=shot|status     body = flow (start NAME k=v first to build a scene); view=shot answers [shot] ok png=PATH\n"
        + "POST /start?name=N&k=v&view=shot  rebuild from start N\n"
        + "GET  /state?view=shot           the current world\n"
        + "POST /quit                      end this process\n"
}
