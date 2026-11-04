// HeadlessLoad — 画面なしの道（e2e・動画・gallery・テスト）で読み込みを流す LoadProgress の handler。
// 仕事をスレッドの pool で回し、javax.imageio のデコーダーを返す（実機の LwjglLayer と同じ決まり。知らせは捨てるか onReport へ）。
// 絵を解く読み込みの関数を画面なしで流すなら LoadProgress.runNoop ではなく HeadlessLoad.handle で包む（runNoop は順に回し、絵を解こうとすると bug! で止まる）。
// 決まり（知らせの並び・50 ms ごとの知らせ・例外で抜ける）は LoadProgress.Conformance で確かめる。
// WhyNot: render_gl の LwjglLoad と 1 つにしない — 層は engine と自分のソースしか見ないので、engine_tools から
// render_gl は見えない。engine に置くと契約層へ java.util.concurrent と javax.imageio が戻る。
pub mod HeadlessLoad {
    import java.awt.image.BufferedImage
    import java.io.{ByteArrayInputStream, IOException}
    import java.lang.{Object => JObject, Runnable, Runtime, Thread, Throwable}
    import java.util.concurrent.{Callable, ExecutionException, ExecutorCompletionService, Executors, Future, ThreadFactory, TimeUnit}
    import javax.imageio.ImageIO

    /// 何も届かない間に知らせる間隔（ミリ秒）。
    def pollMillis(): Int64 = 50i64

    /// f を流す（知らせは捨てる・仕事は並列・絵は javax.imageio で解く）。
    /// `HeadlessLoad.handle(Controls.loadDocs)` のように、LoadProgress.runNoop の代わりに使う。
    pub def handle(f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO = handleWith((_, _, _) -> (), f)

    /// handle の、知らせを onReport へ渡す版（進み具合を見るテスト・自前の進み具合の表示）。
    pub def handleWith(onReport: (String, Int32, Int32) -> Unit \ ef1, f: Unit -> a \ ef): a \ (ef - LoadProgress) + ef1 + IO =
        run f() with handler LoadProgress {
            def report(phase, done, total, k) = { onReport(phase, done, total); k(()) }
            def runTasks(phase, tasks, k) = { runOnPool(onReport, phase, tasks); k(()) }
            def imageDecoder(k) = k(imageIoDecoder())
        }

    /// PNG / JPEG を javax.imageio で画素に戻すデコーダー（スレッドをまたいで使える）。
    pub def imageIoDecoder(): ImageData.ImageDecoder = { decode = decodeImageIo }

    // WhyNot: ImageIO の IOException を投げたままにしない — 並列の仕事の中で投げると、読み込みの全部が止まる（壊れた 1 枚は Err で既定値へ）。
    def decodeImageIo(bytes: Vector[Int8]): Result[String, ImageData.ImageData] \ IO =
        let read = try { Ok(ImageIO.read(new ByteArrayInputStream(unchecked_cast(bytes as Array[Int8, Static])))) } catch {
            case e: IOException => Err("PNG / JPEG として読めない（${e.getMessage()}）")
        };
        Result.flatMap(image ->
            if (Object.isNull(image)) Err("PNG / JPEG として読めない")
            else Ok({ width = image.getWidth(), height = image.getHeight(), argb = argbOf(image) }), read)

    def argbOf(image: BufferedImage): Vector[Int32] \ IO = region rc {
        let w = image.getWidth();
        let h = image.getHeight();
        let buf: Array[Int32, rc] = Array.empty(rc, w * h);
        discard image.getRGB(0, 0, w, h, buf, 0, w);
        Array.toVector(buf)
    }

    /// tasks を CPU の数までのスレッドで回し、最初に (phase, 0, n)・1 つ終わるたびと pollMillis ごとに
    /// (phase, 終わった数, n) を onReport へ渡す（本体のスレッドから）。仕事が例外を投げたら残りを止め、同じ例外で抜ける。
    // WhyNot: 要素ごとに 1 本のスレッドを立てない — N はゲームが決めるので、数百の並びで数百本立つ。
    // WhyNot: Channel.timeout で待たない — 呼ぶたびにスレッドを 1 本立てて眠らせるので、50 ms ごとに使うと眠るスレッドが増える。
    def runOnPool(onReport: (String, Int32, Int32) -> Unit \ ef, phase: String, tasks: List[Unit -> Unit \ IO]): Unit \ ef + IO =
        let n = List.length(tasks);
        if (n == 0) ()
        else {
            let pool = Executors.newFixedThreadPool(Int32.min(n, Runtime.getRuntime().availableProcessors()), daemonThreads());
            let completion = new ExecutorCompletionService(pool);
            tasks |> List.forEach(task -> {
                discard completion.submit(new Callable[JObject] {
                    def call(_this: Callable[JObject]): JObject \ IO = { task(); unchecked_cast(() as JObject) }
                })
            });
            onReport(phase, 0, n);
            let outcome = try { collect(onReport, phase, n, completion, 0) } catch {
                case e: Throwable => { discard pool.shutdownNow(); throw e }
            };
            discard pool.shutdownNow();
            match outcome {
                case Ok(())     => ()
                case Err(cause) => throw cause
            }
        }

    /// 終わった仕事を 1 つずつ数える。全部終わったら Ok・仕事の例外は Err で返す。
    def collect(onReport: (String, Int32, Int32) -> Unit \ ef, phase: String, n: Int32,
                completion: ExecutorCompletionService[JObject], done: Int32): Result[Throwable, Unit] \ ef + IO =
        if (done == n) Ok(())
        else {
            let future = completion.poll(pollMillis(), TimeUnit.MILLISECONDS);
            if (Object.isNull(future)) {
                onReport(phase, done, n);
                collect(onReport, phase, n, completion, done)
            } else match resultOf(future) {
                case Err(cause) => Err(cause)
                case Ok(_) =>
                    onReport(phase, done + 1, n);
                    collect(onReport, phase, n, completion, done + 1)
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
