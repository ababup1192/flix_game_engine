// App.Headless — 窓を開かないゲーム。Studio の会話のプレビューと bin/fge talk shot が、ゲームの本物の描き方で
// 好きな場面を 1 枚撮るのに使う（ゲームを起動していなくても撮れる・起動中のゲームを動かさない）。
// 描き出しの入口（SceneRender.one など）を、温まった JVM のまま何度も流す常駐にもなる（/run）。
//
// ゲームに置く入口は 1 つ（新しい make の口は作らない。bin/headless-run が jar を作って流す）:
//
//   // src/E2e.flix
//   pub def serveHeadless(): Unit \ IO =
//       let jobs = SceneRender.jobs();
//       run { App.Headless.serveJobs(Game.app(Controls.loadDocs()), jobs) } with Fs.FileRead.runWithIO
//
//   // src/render/SceneRender.flix
//   pub def jobs(): List[App.Headless.Job] =
//       App.Headless.job("SceneRender", "one", req -> oneJob(req)) :: Nil
//   pub def oneJob(req: App.Headless.Request): Int32 \ IO = …   // App.Headless.envOf(req) だけを読む
//   pub def one(): Unit \ IO = App.Headless.exitWith(oneJob(App.Headless.requestFromProcess()))
//
//   bin/headless-run E2e.serveHeadless                         待ち受ける（Studio が起こす）
//   FGE_SHOT="talk node=clock line=40" bin/headless-run E2e.serveHeadless   1 枚撮って終わる（bin/fge talk shot）
//
// 待ち受ける口（127.0.0.1・リモートデバッグと同じ書き方の部分集合）:
//   GET  /help・GET /starts
//   POST /step?view=shot|status  本文 = flow。`start talk node=… line=…` から始めれば、場面を組んで撮るまで 1 往復
//   POST /start?name=N&k=v&view=shot・GET /state?view=shot
//   POST /quit
//   GET  /hello                  常駐の名乗り（pid・dir・manifest・served・busy・idle・env・job の行）
//   POST /run?entry=M.f          本文 = 呼ぶ側の環境変数（KEY=VALUE の行）。答えは `o `/`e ` の行の流れと最後の `x …`
// 撮った答えは /render と同じ形の `ok png=<パス>`（[shot] の下の行）。
// /hello と /run の字の形は Go の常駐クライアント（bin/fge resident）とそろえてある。変えるなら両方を直す。
//
// 実機でない扱い: 系を流すだけで、出力（App.addOutput のセーブ・表示中の Doc の名乗り）は書かず、
// 遊んだ記録（debug/flow-record/）も書かない。Doc は始まりを組むたびに読み直す（App.freshWorld）ので、
// 保存した台本がそのまま次の 1 枚に効く。
//
// 環境変数:
//   HEADLESS_PORT            待ち受けるポート（無い・0 なら OS に選ばせる）。開けたら `[headless] ready port=N pid=P` を 1 行
//   HEADLESS_IDLE_SECS       頼まれない時間がこれを超えたら自分で終わる（既定 600 秒。常駐では 180 秒で、/run のたびに置き直す）
//   HEADLESS_TALK_IDLE_SECS  常駐で、会話の列の要求（/start /step /state）の後に延ばす寿命（既定 600 秒）
//   HEADLESS_RESIDENT        1 なら常駐: build/headless/resident.json を書き、入口の出力を /run の流れへ回し、
//                            行き先の無い出力は build/headless/resident.log へ書く
//   HEADLESS_ENTRIES         空白区切りの入口の名前。与えられたら、束の名前が全部ここにあることを起動時に確かめる
//   FGE_SHOT                 始まりの行（`名前 k=v…`）。あれば 1 枚撮って `ok png=…` を出して終わる（撮れなければ 1）
// 使うメモリの上限は java の旗で渡す（HEADLESS_JAVA_OPTS=-Xmx1g。bin/headless-run が足す）。
pub mod App.Headless {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JString}

    import java.lang.System
    import java.lang.Throwable
    import java.lang.OutOfMemoryError
    import java.lang.Thread
    import java.lang.ThreadGroup
    import java.lang.InheritableThreadLocal
    import java.lang.Runtime
    import java.lang.{Object => JObject}
    import java.lang.{String => JavaString}
    import java.io.OutputStream
    import java.io.PrintStream
    import java.io.ByteArrayOutputStream
    import java.io.FileOutputStream
    import java.io.FileDescriptor
    import java.io.{File => JFile}
    import java.nio.file.Files
    import java.time.Instant
    import java.util.concurrent.TimeUnit
    import java.util.concurrent.Callable
    import java.util.concurrent.FutureTask
    import java.util.concurrent.atomic.AtomicBoolean
    import java.util.concurrent.atomic.AtomicLong
    import java.util.concurrent.atomic.AtomicReference
    import java.util.concurrent.locks.ReentrantLock

    // ── 入口の束 ──

    /// 常駐が受ける要求 1 件。外から作らせない（常駐と requestFromProcess だけが作る）。
    enum RequestData({
        env = Map[String, String],   // 呼ぶ側のプロセスの環境変数を丸ごと
        out = PrintStream,           // 入口の標準出力の行き先
        err = PrintStream            // 入口の標準エラーの行き先
    })
    pub type alias Request = RequestData

    /// 要求の env（呼ぶ側のプロセスの環境変数を丸ごと）。
    pub def envOf(req: Request): Map[String, String] = match req { case RequestData.RequestData(r) => r#env }

    /// 要求の標準出力（子プロセスの出力をここへ写す時に使う）。
    pub def outOf(req: Request): PrintStream = match req { case RequestData.RequestData(r) => r#out }

    /// 要求の標準エラー。
    pub def errOf(req: Request): PrintStream = match req { case RequestData.RequestData(r) => r#err }

    /// 今のプロセスの env と標準出力・標準エラーで作る要求（素の道の入口が使う）。
    pub def requestFromProcess(): Request \ IO =
        RequestData.RequestData({ env = ProcessEnv.snapshot(), out = System.out, err = System.err })

    /// 静止画（常駐で流す）か、動画（GPU で塗るなら常駐に送らない）か。
    pub enum JobKind with Eq, ToString {
        case Still,
        case Video
    }

    /// 常駐が受ける入口 1 つ。name は bin/headless-run に渡す名前（"SceneRender.one"）。launch の戻り値は終了コード。
    // WhyNot: 欄の名前を run にしない — Flix の予約語で、レコードの欄に置くとパースで止まる。
    pub type alias Job = { name = String, kind = JobKind, launch = Request -> Int32 \ IO }

    /// 素の道の入口の終わり方: 0 ならそのまま戻り、それ以外はその終了コードでプロセスを終える。
    /// 常駐から呼ばれる入口（launch）の中では呼ばない（常駐ごと落ちる）。
    pub def exitWith(code: Int32): Unit \ IO = ProcessEnv.exitWith(code)

    /// 静止画の入口。名前は "<モジュール>.<関数>" に組む。
    pub def job(module: String, fn: String, launch: Request -> Int32 \ IO): Job =
        { name = "${module}.${fn}", kind = JobKind.Still, launch = launch }

    /// 動画の入口。
    pub def videoJob(module: String, fn: String, launch: Request -> Int32 \ IO): Job =
        { name = "${module}.${fn}", kind = JobKind.Video, launch = launch }

    // ── 行を組む・解く（純粋） ──

    /// /run の終わりの印。
    pub enum RunEnd with Eq, ToString {
        case Exited(Int32),   // 入口が返した終了コード
        case Oom,             // OutOfMemoryError（常駐は終わる）
        case Stale,           // jar.manifest が起動時と違う（常駐は終わる）
        case Busy,            // 仕事の列が塞がっている
        case UnknownEntry,    // 束に無い名前
        case NeedsGl          // Still と名乗った入口が GL を開こうとした
    }

    /// 入口の標準出力の 1 行。
    pub def outLine(text: String): String = "o ${text}\n"

    /// 入口の標準エラーの 1 行。
    pub def errLine(text: String): String = "e ${text}\n"

    /// 流れの最後の 1 行。
    pub def endLine(end: RunEnd): String = match end {
        case RunEnd.Exited(code)  => "x ${code}\n"
        case RunEnd.Oom           => "x oom\n"
        case RunEnd.Stale         => "x stale\n"
        case RunEnd.Busy          => "x busy\n"
        case RunEnd.UnknownEntry  => "x unknown-entry\n"
        case RunEnd.NeedsGl       => "x needs-gl\n"
    }

    /// /run の本文（`KEY=VALUE` の行）を env の表へ。`=` の無い行と鍵の空の行は捨てる。値の中の `=` は残す。
    pub def parseEnvLines(body: String): Map[String, String] =
        String.lines(body)
            |> List.filterMap(line -> String.indexOfLeft({substr = "="}, line) |> Option.flatMap(i ->
                if (i == 0) None else Some((String.takeLeft(i, line), String.dropLeft(i + 1, line)))))
            |> List.toMap

    /// /hello に返す env の行: LANG・LC_*・HEADLESS_* の順（同じ組の中は鍵の字の順）。
    pub def passedEnv(env: Map[String, String]): List[(String, String)] =
        let rows = Map.toList(env);
        let keep = keyIs -> rows |> List.filter(match (key, _) -> keyIs(key));
        keep(key -> key == "LANG")
            ::: keep(key -> String.startsWith(prefix = "LC_", key))
            ::: keep(key -> String.startsWith(prefix = "HEADLESS_", key))
            ::: keep(key -> key == "FGE_RENDER_CACHE")

    /// /hello の本文の材料。
    pub type alias Hello = {
        pid = String,
        dir = String,                       // ゲームの根の実パス
        manifest = String,                  // 起動時に読んだ jar.manifest
        served = Int64,                     // 流した /run の数
        busy = String,                      // 走っている入口の名前（空なら空）
        idleLeft = Int64,                   // 寿命の残りの秒
        idleWindow = Int64,                 // 今の寿命の幅の秒
        env = Map[String, String],          // 起動時の env（passedEnv の分だけ出す）
        jobs = List[(String, JobKind)]      // 束の名前と種類
    }

    /// /hello の本文。
    pub def helloText(hello: Hello): String =
        let head = "ok hello" :: "pid=${hello#pid}" :: "dir=${hello#dir}" :: "manifest=${hello#manifest}"
            :: "served=${hello#served}" :: "busy=${hello#busy}"
            :: "idle.left=${hello#idleLeft}" :: "idle.window=${hello#idleWindow}" :: Nil;
        let envRows = passedEnv(hello#env) |> List.map(match (key, value) -> "env.${key}=${value}");
        let jobRows = hello#jobs |> List.map(match (name, kind) -> "job=${name} ${kindText(kind)}");
        String.intercalate("\n", head ::: envRows ::: jobRows) + "\n"

    /// JobKind の字（/hello の job= の行）。
    pub def kindText(kind: JobKind): String = match kind {
        case JobKind.Still => "still"
        case JobKind.Video => "video"
    }

    /// HEADLESS_ENTRIES（空白区切り）に無い束の名前。HEADLESS_ENTRIES が空なら照合しない（空を返す）。
    pub def missingEntries(declared: String, names: List[String]): List[String] =
        let known = String.words(declared) |> List.toSet;
        if (Set.isEmpty(known)) Nil else names |> List.filter(name -> not Set.memberOf(name, known))

    /// 寿命の幅（秒）: /run の後と、会話の列の要求の後。
    pub type alias IdleWindows = { work = Int64, talk = Int64 }

    /// env から寿命の幅を読む。常駐は /run が 180 秒・会話が 600 秒、常駐でなければどちらも HEADLESS_IDLE_SECS（既定 600 秒）。
    pub def idleWindowsOf(resident: Bool, env: Map[String, String]): IdleWindows =
        let secs = (key, fallback) -> Map.get(key, env) |> Option.flatMap(Int64.fromString) |> Option.getWithDefault(fallback);
        if (resident) { work = secs("HEADLESS_IDLE_SECS", 180i64), talk = secs("HEADLESS_TALK_IDLE_SECS", 600i64) }
        else {
            let idle = secs("HEADLESS_IDLE_SECS", 600i64);
            { work = idle, talk = idle }
        }

    /// 会話の列の要求（World を組む・進める・見る）か。
    pub def isTalkPath(path: String): Bool = path == "/start" or path == "/step" or path == "/state"

    /// 会話の列の要求 1 件が寿命をどれだけ延ばすか。常駐では /start・/step・/state だけ、常駐でなければ全部。
    pub def talkWindowOf(resident: Bool, windows: IdleWindows, path: String): Option[Int64] =
        if (not resident or isTalkPath(path)) Some(windows#talk) else None

    /// 寿命: 切れる時刻（System.nanoTime の値）と、それを決めた幅の秒。
    pub type alias Lease = { deadline = Int64, window = Int64 }

    /// nowNs から windowSecs の寿命を取る。今の寿命の方が長く残っていれば今のまま（短い幅で縮めない）。
    pub def extendLease(nowNs: Int64, windowSecs: Int64, lease: Lease): Lease =
        let deadline = nowNs + windowSecs * 1_000_000_000i64;
        if (deadline >= lease#deadline) { deadline = deadline, window = windowSecs } else lease

    /// 寿命の残りの秒（切れていれば 0）。
    pub def idleLeftSecs(nowNs: Int64, lease: Lease): Int64 =
        Int64.max(0i64, (lease#deadline - nowNs) / 1_000_000_000i64)

    /// resident.json の 1 件（値は全部文字列。games.json と同じ流儀）。
    pub type alias ResidentEntry = { pid = String, port = String, dir = String, manifest = String, started = String }

    /// resident.json の中身。
    pub def residentText(entry: ResidentEntry): String =
        Util.Json.toPrettyString(2, JObject(Map#{
            "pid" => JString(entry#pid), "port" => JString(entry#port), "dir" => JString(entry#dir),
            "manifest" => JString(entry#manifest), "started" => JString(entry#started) })) + "\n"

    /// resident.json の pid（読めなければ None）。
    pub def residentPidOf(text: String): Option[String] =
        DocJson.parse(text)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(JsonCodec.stringOr("pid", ""))
            |> Option.filter(pid -> pid != "")

    /// [shot] の答えの `ok png=<パス>` の行のパス（無ければ None）。
    pub def pngPathOf(block: String): Option[String] =
        String.lines(block)
            |> List.findMap(line -> String.stripPrefix(substr = "ok png=", String.trim(line)))
            |> Option.map(String.trim)
            |> Option.filter(path -> not String.isEmpty(path))

    /// [shot] の答えが書いたファイル: PNG と、隣の描き物の表（<名前>.items.tsv）。撮れていなければ空。
    pub def shotFilesOf(block: String): List[String] =
        match pngPathOf(block) {
            case None => Nil
            case Some(png) =>
                let stem = String.stripSuffix(substr = ".png", png) |> Option.getWithDefault(png);
                png :: "${stem}.items.tsv" :: Nil
        }

    // ── 常駐の持ち物 ──

    /// 糸ごとの出力の行き先。行き先の無い糸は log へ。
    type alias Routes = {
        out = InheritableThreadLocal[JObject],   // 入口の糸の標準出力（PrintStream）
        err = InheritableThreadLocal[JObject],   // 入口の糸の標準エラー（PrintStream）
        log = PrintStream                        // build/headless/resident.log
    }

    /// 待ち受けの間、主スレッドと HTTP の糸が共有する物（どれも糸をまたいで安全な Java の部品か、変わらない値）。
    type alias Station = {
        jobs = Map[String, Job],
        names = List[(String, JobKind)],
        startEnv = Map[String, String],     // 起動時の env
        resident = Bool,
        windows = IdleWindows,
        dir = String,
        pid = String,
        manifest = String,                  // 起動時に読んだ jar.manifest
        console = PrintStream,              // 差し替える前の標準出力（ready の行を書く）
        routes = Option[Routes],
        group = ThreadGroup,
        deadline = AtomicLong,
        window = AtomicLong,
        leaseLock = ReentrantLock,
        running = AtomicBoolean,
        busy = AtomicReference[String],
        served = AtomicLong,
        ending = AtomicBoolean              // /run が終わりを頼んだ（stale・oom・200 件）
    }

    /// 1 つの常駐が流す /run の上限。超えたら答えを書き終えてから終わる。
    def servedCap(): Int64 = 200i64

    /// 入口の糸のスタックの大きさ（-Xss32m と同じ）。
    def jobStackBytes(): Int64 = 33_554_432i64

    def manifestPath(): String = "build/headless/jar.manifest"

    def residentPath(): String = "build/headless/resident.json"

    def logPath(): String = "build/headless/resident.log"

    /// path のファイルを消す（無い・消せなくても止めない）。
    def deleteQuietly(path: String): Unit \ IO =
        try { discard (new JFile(path)).delete() } catch { case _: Throwable => () }

    /// jar.manifest の中身（無い・読めなければ空）。
    def readManifest(): String \ IO =
        try {
            let file = new JFile(manifestPath());
            if (file.isFile()) String.trim(new JavaString(Files.readAllBytes(file.toPath()), "UTF-8")) else ""
        } catch { case _: Throwable => "" }

    /// 起動時の持ち物を作る。束の名前が HEADLESS_ENTRIES に無ければ、立たない理由の 1 行を返す。
    /// 常駐なら、ここで System.out / System.err を糸ごとの行き先へ差し替える。
    def openStation(jobs: List[Job], env: Map[String, String]): Result[String, Station] \ IO =
        let names = jobs |> List.map(j -> (j#name, j#kind));
        match missingEntries(Map.getWithDefault("HEADLESS_ENTRIES", "", env), List.map(fst, names)) {
            case Nil => Ok(stationOf(jobs, names, env))
            case missing =>
                Err("[headless] 束の入口が bin/headless-run の入口に見当たらないので立ちません: ${String.intercalate(" ", missing)}")
        }

    def stationOf(jobs: List[Job], names: List[(String, JobKind)], env: Map[String, String]): Station \ IO =
        let resident = Map.get("HEADLESS_RESIDENT", env) == Some("1");
        // WhyNot: 差し替える前の System.out を let で取っておかない — 静的な欄を読むだけの式は、使う所まで
        // 後ろへ動かされて、差し替えた後の行き先を読むことがある。常駐は ready の行を標準出力の fd へ直に書く。
        let console = if (resident) new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8") else System.out;
        let routes = if (resident) Some(installRoutes()) else None;
        let windows = idleWindowsOf(resident, env);
        { jobs = jobs |> List.map(j -> (j#name, j)) |> List.toMap, names = names, startEnv = env,
          resident = resident, windows = windows, dir = App.GameRegistry.gameDir(),
          pid = App.GameRegistry.pidText(), manifest = readManifest(), console = console, routes = routes,
          group = new ThreadGroup("headless-jobs"),
          deadline = new AtomicLong(System.nanoTime() + windows#work * 1_000_000_000i64),
          window = new AtomicLong(windows#work), leaseLock = new ReentrantLock(),
          running = new AtomicBoolean(false), busy = new AtomicReference(""), served = new AtomicLong(0i64),
          ending = new AtomicBoolean(false) }

    /// System.out / System.err を、糸に置いた行き先へ書く PrintStream に差し替える。
    // WhyNot: 要求ごとに System.setOut しない — 会話の列と仕事の列が並んで走るので、互いの出力が混ざる。
    // InheritableThreadLocal にするのは、入口が起こした糸（lanes など）の出力も同じ要求の流れへ行くようにするため。
    def installRoutes(): Routes \ IO =
        discard (new JFile("build/headless")).mkdirs();
        let log = new PrintStream(new FileOutputStream(logPath(), true), true, "UTF-8");
        let routes = { out = new InheritableThreadLocal(), err = new InheritableThreadLocal(), log = log };
        System.setOut(new PrintStream(routedStream(routes#out, log), true, "UTF-8"));
        System.setErr(new PrintStream(routedStream(routes#err, log), true, "UTF-8"));
        routes

    /// 書いた糸の行き先（無ければ fallback）へ 1 バイトずつ渡す OutputStream。
    def routedStream(local: InheritableThreadLocal[JObject], fallback: PrintStream): OutputStream \ IO =
        new OutputStream {
            def write(_this: OutputStream, b: Int32): Unit \ IO = {
                let target = local.get();
                if (Object.isNull(target)) fallback.write(b)
                else {
                    let stream: OutputStream = unchecked_cast(target as OutputStream);
                    stream.write(b)
                }
            }
        }

    /// 寿命を windowSecs だけ取る（今の方が長ければ今のまま）。
    def touch(station: Station, windowSecs: Int64): Unit \ IO =
        let lock = station#leaseLock;
        let deadline = station#deadline;
        let window = station#window;
        lock.lock();
        let next = extendLease(System.nanoTime(), windowSecs, { deadline = deadline.get(), window = window.get() });
        deadline.set(next#deadline);
        window.set(next#window);
        lock.unlock()

    def leaseOf(station: Station): Lease \ IO =
        let deadline = station#deadline;
        let window = station#window;
        { deadline = deadline.get(), window = window.get() }

    /// 寿命が切れていて、/run も走っていない。
    def isExpired(station: Station): Bool \ IO =
        let running = station#running;
        let deadline = station#deadline;
        not running.get() and System.nanoTime() > deadline.get()

    // ── 橋の外の口（/hello・/run） ──

    def directRoutes(station: Station): List[App.RemoteDebug.DirectRoute] =
        { path = "/hello", serve = (_, body) -> serveHello(station, body) } ::
        { path = "/run", serve = (request, body) -> serveRun(station, request, body) } :: Nil

    def serveHello(station: Station, body: OutputStream): Unit \ IO =
        let served = station#served;
        let busy = station#busy;
        let lease = leaseOf(station);
        let text = helloText({ pid = station#pid, dir = station#dir, manifest = station#manifest,
                               served = served.get(), busy = busy.get(),
                               idleLeft = idleLeftSecs(System.nanoTime(), lease), idleWindow = lease#window,
                               env = station#startEnv, jobs = station#names });
        body.write(text.getBytes("UTF-8"));
        body.flush()

    /// 1 件の /run。入口を新しい糸で流し、出力の行を流しながら書き、最後に x の行を書く。
    def serveRun(station: Station, request: App.RemoteDebug.Request, body: OutputStream): Unit \ IO =
        let lock = new ReentrantLock();
        let ending = station#ending;
        let running = station#running;
        let entry = Map.getWithDefault("entry", "", request#params);
        if (readManifest() != station#manifest) {
            discard writeLocked(body, lock, endLine(RunEnd.Stale));
            ending.set(true)
        } else match Map.get(entry, station#jobs) {
            case None => discard writeLocked(body, lock, endLine(RunEnd.UnknownEntry))
            case Some(found) =>
                if (not running.compareAndSet(false, true)) discard writeLocked(body, lock, endLine(RunEnd.Busy))
                else {
                    let busy = station#busy;
                    let served = station#served;
                    busy.set(entry);
                    touch(station, station#windows#work);
                    let end = launchOnThread(station, found, parseEnvLines(request#body), body, lock);
                    discard writeLocked(body, lock, endLine(end));
                    let count = served.incrementAndGet();
                    busy.set("");
                    running.set(false);
                    touch(station, station#windows#work);
                    if (end == RunEnd.Oom or count >= servedCap()) ending.set(true) else ()
                }
        }

    /// 本文へ字を書いて flush する（相手が切れていたら false）。
    def writeLocked(body: OutputStream, lock: ReentrantLock, text: String): Bool \ IO =
        lock.lock();
        let wrote = try { body.write(text.getBytes("UTF-8")); body.flush(); true } catch { case _: Throwable => false };
        lock.unlock();
        wrote

    /// 行に切って prefix を付けて本文へ書く OutputStream と、残りの書きかけの行を書いて閉じる手続き。
    /// 閉じた後（と相手が切れた後）に書かれた物は log へ回す（入口が残した糸が後から書いても、次の要求に混ざらない）。
    def lineSink(line: String -> String, body: OutputStream, lock: ReentrantLock, log: PrintStream):
            (OutputStream, Unit -> Unit \ IO) \ IO =
        let buffer = new ByteArrayOutputStream();
        let open = new AtomicBoolean(true);
        let emit = () -> {
            let text = buffer.toString("UTF-8");
            buffer.reset();
            let trimmed = if (String.endsWith(suffix = "\r", text)) String.dropRight(1, text) else text;
            if (writeLocked(body, lock, line(trimmed))) () else open.set(false)
        };
        let stream = new OutputStream {
            def write(_this: OutputStream, b: Int32): Unit \ IO =
                if (not open.get()) log.write(b)
                else if (b == 10) emit()
                else buffer.write(b)
        };
        let close = () -> {
            if (open.get() and buffer.size() > 0) emit() else ();
            open.set(false)
        };
        (stream, close)

    /// 入口を 32MB のスタックの新しい糸で流して、終わりの印を返す。
    // WhyNot: Runnable を匿名クラスで書かない — 手続き名の run が Flix の予約語。FutureTask は Callable から
    // Runnable を作る（RemoteDebug の描き出しの糸と同じ回り道）。
    def launchOnThread(station: Station, found: Job, env: Map[String, String], body: OutputStream,
                       lock: ReentrantLock): RunEnd \ IO =
        let (req, closeAll) = match station#routes {
            case None =>
                (RequestData.RequestData({ env = env, out = System.out, err = System.err }), () -> checked_ecast(()))
            case Some(routes) =>
                let (outSink, closeOut) = lineSink(outLine, body, lock, routes#log);
                let (errSink, closeErr) = lineSink(errLine, body, lock, routes#log);
                (RequestData.RequestData({ env = env, out = new PrintStream(outSink, true, "UTF-8"),
                                           err = new PrintStream(errSink, true, "UTF-8") }),
                 () -> { closeOut(); closeErr() })
        };
        let result = new AtomicReference(endLine(RunEnd.Exited(1)));
        let task = new FutureTask(new Callable[String] {
            def call(_this: Callable[String]): String \ IO = {
                bindRoutes(station#routes, req);
                let end = try { RunEnd.Exited((found#launch)(req)) } catch {
                    case _: OutOfMemoryError => RunEnd.Oom
                    case e: Throwable =>
                        let err = errOf(req);
                        err.println(e.toString());
                        RunEnd.Exited(1)
                };
                let errStream = errOf(req);
                errStream.flush();
                let outStream = outOf(req);
                outStream.flush();
                result.set(endLine(end));
                ""
            }
        });
        let thread = new Thread(station#group, task, "headless-run ${found#name}", jobStackBytes());
        thread.setDaemon(true);
        thread.start();
        discard task.get();
        closeAll();
        endOfLine(result.get())

    /// 入口の糸の行き先を、この要求の出力に置く。
    def bindRoutes(routes: Option[Routes], req: Request): Unit \ IO = match routes {
        case None => ()
        case Some(r) =>
            let out = r#out;
            let err = r#err;
            let outTarget: JObject = checked_cast(outOf(req));
            let errTarget: JObject = checked_cast(errOf(req));
            out.set(outTarget);
            err.set(errTarget)
    }

    /// endLine の逆（糸から戻すのを字にしたので、ここで戻す）。
    // WhyNot: RunEnd を AtomicReference に直に置かない — Flix の enum を Java の総称型へ渡す道が無い。
    def endOfLine(text: String): RunEnd =
        let ends = RunEnd.Oom :: RunEnd.Stale :: RunEnd.Busy :: RunEnd.UnknownEntry :: RunEnd.NeedsGl :: Nil;
        match List.find(end -> endLine(end) == text, ends) {
            case Some(end) => end
            case None =>
                String.stripPrefix(substr = "x ", text) |> Option.map(String.trim) |> Option.flatMap(Int32.fromString)
                    |> Option.map(RunEnd.Exited) |> Option.getWithDefault(RunEnd.Exited(1))
        }

    // ── resident.json ──

    /// ready の直後に書く（常駐の時だけ）。JVM の終わりにも消す（自分の pid の時だけ）。
    def writeResident(station: Station, port: Int32): Unit \ IO =
        if (not station#resident) ()
        else try {
            discard (new JFile("build/headless")).mkdirs();
            let text = residentText({ pid = station#pid, port = "${port}", dir = station#dir,
                                      manifest = station#manifest, started = Instant.now().toString() });
            let temp = new JFile(residentPath() + ".${station#pid}.tmp");
            let out = new FileOutputStream(temp);
            out.write(text.getBytes("UTF-8"));
            out.close();
            let file = new JFile(residentPath());
            // POSIX の rename は上書きで 1 回に差し替わる（Windows は上書きできないので先に消す）。
            if (not temp.renameTo(file)) { discard file.delete(); discard temp.renameTo(file) } else ();
            let pid = station#pid;
            let hook = new FutureTask(new Callable[String] {
                def call(_this: Callable[String]): String \ IO = { removeResident(pid); "" }
            });
            Runtime.getRuntime().addShutdownHook(new Thread(hook))
        } catch {
            case e: Throwable => println("[headless] ${residentPath()} を書けません — ${e.toString()}")
        }

    /// resident.json が自分の pid の物なら消す（後から同じ根で起こした常駐の物は残す）。
    def removeResident(pid: String): Unit \ IO =
        try {
            let file = new JFile(residentPath());
            if (file.isFile() and residentPidOf(new JavaString(Files.readAllBytes(file.toPath()), "UTF-8")) == Some(pid))
                discard file.delete()
            else ()
        } catch { case _: Throwable => () }

    // ── 入口 ──

    /// 入口の中身。FGE_SHOT があれば 1 枚撮って終わり、無ければ待ち受ける（/run は無し）。
    pub def serve(app: App.App[w, ef]): Unit \ ef + Fs.FileRead + IO = serveJobs(app, Nil)

    /// 窓なしのゲーム（/start・/step・view=shot）+ 入口の束（/run）で待ち受ける。FGE_SHOT があれば 1 枚撮って終わる。
    /// 撮れない・立てない時はその終了コードでプロセスを終える。
    pub def serveJobs(app: App.App[w, ef], jobs: List[Job]): Unit \ ef + Fs.FileRead + IO =
        exitWith(serveJobsOf(app, jobs, ProcessEnv.snapshot()))

    /// serveJobs の中身。env は起動した時の環境変数の表。戻り値は終了コード。
    def serveJobsOf(app: App.App[w, ef], jobs: List[Job], env: Map[String, String]): Int32 \ ef + Fs.FileRead + IO =
        discard System.setProperty("java.awt.headless", "true");
        let design = App.loadProjectDesign(".");
        match Map.getWithDefault("FGE_SHOT", "", env) {
            case ""   => listen(app, design, jobs, env)
            case line => shootOnce(app, design, line)
        }

    /// App を持たないゲームの常駐。/start・/step・/state には「未対応」と答える。立てない時は 1 でプロセスを終える。
    pub def serveJobsOnly(jobs: List[Job]): Unit \ IO =
        exitWith(serveJobsOnlyOf(jobs, ProcessEnv.snapshot()))

    /// serveJobsOnly の中身。env は起動した時の環境変数の表。戻り値は終了コード。
    def serveJobsOnlyOf(jobs: List[Job], env: Map[String, String]): Int32 \ IO =
        discard System.setProperty("java.awt.headless", "true");
        match openStation(jobs, env) {
            case Err(why) => println(why); 1
            case Ok(station) =>
                let bridge = openBridge(station);
                loop(station, bridge, (), (request, _) -> (answerJobsOnly(request), (), request#path == "/quit" and request#method == "POST"));
                closeBridge(station, bridge);
                0
        }

    def answerJobsOnly(request: App.RemoteDebug.Request): String =
        match (request#method, request#path) {
            case ("GET", "/help")  => helpText()
            case ("POST", "/quit") => "ok quit\n"
            case (_, path) if path == "/starts" or isTalkPath(path) =>
                "error: この常駐は App を持たない（App.Headless.serveJobsOnly）ので ${request#path} には答えません（/hello・/run だけ）\n"
            case (m, p) => "error: no route for ${m} ${p} (see GET /help)\n"
        }

    /// 始まりの行から組んで 1 枚撮り、`ok png=…` を出す。組めない・撮れない時は理由を出して 1 を返す。
    def shootOnce(app: App.App[w, ef], design: Vec2.Vec2, line: String): Int32 \ ef + Fs.FileRead + IO =
        let built = App.parseStartLine(line) |> Result.flatMap(match (name, args) -> App.buildStart(app, design, name, args));
        match built {
            case Err(why) => println("error: ${why}"); 1
            case Ok(world) =>
                let block = App.RemoteDebug.shotBlock(app, world);
                println(String.trim(String.dropLeft(String.length("[shot]\n"), block)));
                if (String.contains(substr = "ok png=", block)) 0 else 1
        }

    /// 待ち受ける。開けたら ready の 1 行を出し、頼まれるたびに 1 件ずつ答える。
    // WhyNot: RemoteDebug.start の橋（HTTP のスレッドは World に触れず、キューで渡す）をそのまま使う —
    // 答えを作るのはここ（主スレッド）だけなので、World を共有する可変のコンテナが要らない。
    def listen(app: App.App[w, ef], design: Vec2.Vec2, jobs: List[Job], env: Map[String, String]): Int32 \ ef + Fs.FileRead + IO =
        match openStation(jobs, env) {
            case Err(why) => println(why); 1
            case Ok(station) => listenOn(app, design, station); 0
        }

    def listenOn(app: App.App[w, ef], design: Vec2.Vec2, station: Station): Unit \ ef + Fs.FileRead + IO =
        // 待ち受け始めの World は登録簿の先頭の始まり（無ければ新しく作った初期の World）。
        let fresh = App.freshWorld(app, design);
        let world0 = match List.head(app#starts) {
            case Some(first) => App.buildStart(app, design, first#name, Map.empty()) |> Result.getWithDefault(fresh)
            case None        => fresh
        };
        // 最初の 1 枚は字のアトラスや描き出しの JIT で遅いので、ready を出す前に 1 回撮って温める。
        // WhyNot: 温めの絵を残さない — 常駐を起こした回だけ debug/shot/ のファイルが増え、verify の 1 と 2 が違って見える。
        List.forEach(deleteQuietly, shotFilesOf(App.RemoteDebug.shotBlock(app, world0)));
        let bridge = openBridge(station);
        loop(station, bridge, { world = world0, state = App.freshStepState() },
             (request, served) -> handle(app, design, request, served));
        closeBridge(station, bridge)

    /// 橋を開いて ready の行を出し、常駐なら resident.json を書く。
    def openBridge(station: Station): App.RemoteDebug.Bridge \ IO =
        let port = Map.get("HEADLESS_PORT", station#startEnv) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(0);
        let bridge = App.RemoteDebug.startQuietWith(port, directRoutes(station));
        let bound = App.RemoteDebug.boundPort(bridge);
        touch(station, station#windows#work);
        let console = station#console;
        console.println("[headless] ready port=${bound} pid=${station#pid}");
        console.flush();
        writeResident(station, bound);
        bridge

    def closeBridge(station: Station, bridge: App.RemoteDebug.Bridge): Unit \ IO =
        let ending = station#ending;
        // /run の答えの最後の行が相手へ届き切るのを待ってからサーバを止める。
        if (ending.get()) Thread.sleep(300i64) else ();
        App.RemoteDebug.stopQuiet(bridge);
        if (station#resident) removeResident(station#pid) else ()

    /// 会話の列: 頼まれるたびに answer で 1 件ずつ答える。寿命が切れるか /quit か、/run が終わりを頼んだら戻る。
    def loop(station: Station, bridge: App.RemoteDebug.Bridge, served: s,
             answer: (App.RemoteDebug.Request, s) -> (String, s, Bool) \ ef): Unit \ ef + IO =
        let requests = bridge#requests;
        let ending = station#ending;
        let raw = requests.poll(1i64, TimeUnit.SECONDS);
        if (ending.get()) println("[headless] /run が終わりを頼んだので終わります")
        else if (Object.isNull(raw)) {
            if (isExpired(station)) println("[headless] 頼まれないまま時間が過ぎたので終わります")
            else loop(station, bridge, served, answer)
        } else match App.RemoteDebug.untagged(raw) {
            case None => loop(station, bridge, served, answer)
            case Some((id, text)) =>
                let current = bridge#current;
                current.set(id);
                let request = App.RemoteDebug.parseRequest(text);
                let (reply, next, quit) =
                    try { answer(request, served) } catch {
                        case e: Throwable => ("error: ${e.toString()}\n", served, false)
                    };
                App.RemoteDebug.respond(reply, bridge);
                match talkWindowOf(station#resident, station#windows, request#path) {
                    case Some(secs) => touch(station, secs)
                    case None       => ()
                };
                if (quit) () else loop(station, bridge, next, answer)
        }

    /// 待ち受けている間に持つ物: 今の World と固定刻みの持ち越し。
    type alias Served[w] = { world = w, state = App.StepState }

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
                                           { world = world, state = App.freshStepState() }, false)
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
                                 { world = outcome#last, state = outcome#state }, false)
                            case Err(failure) =>
                                ("FAIL ${App.RemoteDebug.failureLine(failure)}\n    ${failure#at#text}\n" + block(failure#upTo#last),
                                 { world = failure#upTo#last, state = failure#upTo#state }, false)
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
        + "GET  /hello                     pid / dir / manifest / served / busy / idle / env / job lines\n"
        + "POST /run?entry=M.f             body = KEY=VALUE env lines; streams o / e lines, ends with x CODE|oom|stale|busy|unknown-entry\n"
        + "POST /quit                      end this process\n"
}
