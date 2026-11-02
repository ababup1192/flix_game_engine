// LoadProgress — 起動の読み込みの進み具合を、区切りごとにバックエンドへ知らせる。
//
// 最初のコマを描くまでの読み込み（main の中の Doc・形・絵の解読、App の init と startupSystems）の間は
// ゲームのループが回っていないので、誰もウィンドウのイベントを poll しない。数秒続くと OS が応答なしと見なす。
// 知らせを受けたバックエンド（実機は LwjglLayer）が起動画面を進め、イベントを poll する。
// 1 つの区切りの中はエンジンが割り込めないので、本体のスレッドで知らせの間が 0.5 秒を超えないように区切る。

/// 起動の読み込みの進み具合（区切りごとに 1 回）。
pub eff LoadProgress {
    /// phase = 今やっていること（起動画面の字）・done / total = その中の何本目 / 全何本（total 0 以下は本数不明）。
    /// handler は必ず k を呼んで返す（呼ばない・投げると parMapWithProgress のスレッドが止まらずに残る）。
    /// RenderTarget を開いたまま（Pass に描いている途中で）呼ばない。
    def report(phase: String, done: Int32, total: Int32): Unit
}

pub mod LoadProgress {
    import java.lang.{Object => JObject, Runnable, Runtime, Thread, Throwable}
    import java.util.concurrent.{Callable, ExecutionException, ExecutorCompletionService, Executors, Future, ThreadFactory, TimeUnit}

    /// 知らせを捨てる handler（headless の描き出し・動画・テスト・flow の再生）。
    pub def runNoop(f: Unit -> a \ ef + LoadProgress): a \ ef =
        run f() with handler LoadProgress {
            def report(_phase, _done, _total, k) = k(())
        }

    /// xs を f で 1 つずつ作り、作るたびに (phase, 作った数, 全部の数) を知らせる（最初に (phase, 0, n)）。
    /// 空の並びは何も知らせない — (phase, 0, 0) は本数不明の知らせと見分けがつかない。
    pub def mapWithProgress(phase: String, f: a -> b \ ef, xs: List[a]): List[b] \ ef + LoadProgress =
        let n = List.length(xs);
        if (n == 0) Nil
        else {
            LoadProgress.report(phase, 0, n);
            xs |> List.zipWithIndex |> List.map(e -> {
                let (i, x) = e;
                let y = f(x);
                LoadProgress.report(phase, i + 1, n);
                y
            })
        }

    /// xs を f で並列に作り、1 つ届くたびと 50 ms ごとに進み具合を知らせる（スレッドは CPU の数まで・結果の並びは xs のまま）。
    /// 何も届かない間も知らせるので、1 つの要素が長くてもウィンドウが応答し続ける。
    /// f は IO だけ — effect の handler はスレッドをまたがないので、Fs.FileRead で読む物は先に読んでおく。
    /// f が例外を投げたら、残りを止めて同じ例外で抜ける。空の並びはスレッドを立てずに空を返す。
    pub def parMapWithProgress(phase: String, f: a -> b \ IO, xs: List[a]): List[b] \ IO + LoadProgress =
        match parMapPolling(50i64, Int32.maxValue(), phase, f, xs) {
            case Some(ys) => ys
            case None     => bug!("LoadProgress.parMapWithProgress: 待つ回数の上限に届いた")
        }

    /// parMapWithProgress の本体。waitMs ごとに出来上がりを見て、何も届かないまま maxWaits 回待ったら残りを止めて None。
    /// 上限はテストが止まらないことを回数で押さえるための物で、parMapWithProgress（約 3 年）は届かない。
    // WhyNot: 要素ごとに 1 本のスレッドを立てない — N はゲームが決めるので、数百の並びで数百本立つ。
    // WhyNot: region の中で spawn しない — region を閉じる所で全部を待つので、待つ間に知らせを出せない。
    // WhyNot: Channel.timeout で待たない — 呼ぶたびにスレッドを 1 本立てて眠らせるので、50 ms ごとに使うと眠るスレッドが増える。
    def parMapPolling(waitMs: Int64, maxWaits: Int32, phase: String, f: a -> b \ IO, xs: List[a]): Option[List[b]] \ IO + LoadProgress =
        let n = List.length(xs);
        if (n == 0) Some(Nil)
        else {
            let pool = Executors.newFixedThreadPool(Int32.min(n, Runtime.getRuntime().availableProcessors()), daemonThreads());
            let completion = new ExecutorCompletionService(pool);
            xs |> List.zipWithIndex |> List.forEach(e -> {
                let (i, x) = e;
                discard completion.submit(new Callable[JObject] {
                    def call(_this: Callable[JObject]): JObject \ IO = unchecked_cast((i, f(x)) as JObject)
                })
            });
            LoadProgress.report(phase, 0, n);
            let outcome = collect(waitMs, maxWaits, phase, n, completion, Map.empty(), 0);
            discard pool.shutdownNow();
            match outcome {
                case Ok(done)  => done
                case Err(cause) => throw cause
            }
        }

    /// 出来上がりを 1 つずつ受け取り、番号の表に入れる。全部そろったら番号の順に並べる。仕事の例外は Err で返す。
    // WhyNot: 例外を try/catch で受けてプールを止めない — LoadProgress.report から戻った後の例外は、その外の try が受けない。
    def collect(waitMs: Int64, maxWaits: Int32, phase: String, n: Int32, completion: ExecutorCompletionService[JObject],
                got: Map[Int32, b], waits: Int32): Result[Throwable, Option[List[b]]] \ IO + LoadProgress =
        if (Map.size(got) == n) Ok(Some(Map.valuesOf(got)))
        else if (waits >= maxWaits) Ok(None)
        else {
            let future = completion.poll(waitMs, TimeUnit.MILLISECONDS);
            if (Object.isNull(future)) {
                LoadProgress.report(phase, Map.size(got), n);
                collect(waitMs, maxWaits, phase, n, completion, got, waits + 1)
            } else match resultOf(future) {
                case Err(cause) => Err(cause)
                case Ok(value) =>
                    let (i, y): (Int32, b) = unchecked_cast(value as (Int32, b));
                    let got1 = Map.insert(i, y, got);
                    LoadProgress.report(phase, Map.size(got1), n);
                    collect(waitMs, maxWaits, phase, n, completion, got1, waits)
            }
        }

    /// 終わった仕事の値。仕事が例外で終わっていたら、包みを外した元の例外を Err で返す。
    def resultOf(future: Future[JObject]): Result[Throwable, JObject] \ IO =
        try { Ok(future.get()) } catch {
            case e: ExecutionException => Err(e.getCause())
        }

    /// daemon のスレッドを作る factory（読み込みの途中でウィンドウが閉じられても、プロセスの終わりを止めない）。
    def daemonThreads(): ThreadFactory \ IO =
        new ThreadFactory {
            def newThread(_this: ThreadFactory, task: Runnable): Thread \ IO =
                let thread = new Thread(task);
                thread.setDaemon(true);
                thread
        }
}
