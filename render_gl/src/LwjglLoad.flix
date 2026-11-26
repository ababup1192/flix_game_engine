// LwjglLoad — デスクトップの LoadProgress の handler の本体: 仕事をスレッドの pool で回し、stb_image のデコーダーを返す。
// 知らせ（起動画面を進める・イベントを poll する）は呼ぶ側が onReport で渡す。LwjglLayer が起動画面の関数を渡して使う。
// 決まり（知らせの並び・50 ms ごとの知らせ・例外で抜ける）は LoadProgress.Conformance で確かめる。
// WhyNot: engine_tools の HeadlessLoad と 1 つにしない — 層は engine と自分のソースしか見ないので、render_gl から
// engine_tools は見えない。engine に置くと契約層へ java.util.concurrent と stb が戻る。
mod LwjglLoad {
    import java.lang.{Object => JObject, Runnable, Runtime, Thread, Throwable}
    import java.nio.{ByteBuffer, ByteOrder}
    import java.util.concurrent.{Callable, ExecutionException, ExecutorCompletionService, Executors, Future, ThreadFactory, TimeUnit}
    import org.lwjgl.stb.STBImage
    import org.lwjgl.system.MemoryUtil

    /// 何も届かない間に知らせる間隔（ミリ秒）。
    def pollMillis(): Int64 = 50i64

    /// f を流し、LoadProgress の知らせを onReport へ渡す。runTasks は pool で回し、imageDecoder は stb_image の物。
    pub def handleWith(onReport: (String, Int32, Int32) -> Unit \ ef1, f: Unit -> a \ ef): a \ (ef - LoadProgress) + ef1 + IO =
        run f() with handler LoadProgress {
            def report(phase, done, total, k) = { onReport(phase, done, total); k(()) }
            def runTasks(phase, tasks, k) = { runOnPool(onReport, phase, tasks); k(()) }
            def imageDecoder(k) = k(stbDecoder())
            def downloads(k) = k(LoadProgress.localDownloads())
        }

    /// PNG / JPEG を stb_image で画素に戻すデコーダー（スレッドをまたいで使える）。
    pub def stbDecoder(): ImageData.ImageDecoder = ImageData.decoderOf(decodeStb)

    // WhyNot: javax.imageio で読まない — macOS の native image には AWT（libawt）が無く、絵が 1 枚も読めない。
    // WhyNot: 読めない絵で投げない — 並列の仕事の中で投げると、読み込みの全部が止まる（壊れた 1 枚は Err で既定値へ）。
    def decodeStb(bytes: Vector[Int8]): Result[String, ImageData.ImageData] \ IO =
        let input = MemoryUtil.memAlloc(Vector.length(bytes));
        discard input.put(unchecked_cast(bytes as Array[Int8, Static]));
        discard input.flip();
        let width = MemoryUtil.memAllocInt(1);
        let height = MemoryUtil.memAllocInt(1);
        let channels = MemoryUtil.memAllocInt(1);
        let rgba = STBImage.stbi_load_from_memory(input, width, height, channels, 4);
        let decoded =
            if (Object.isNull(rgba)) Err("PNG / JPEG として読めない（${STBImage.stbi_failure_reason()}）")
            else {
                let image = imageOfRgba(rgba, width.get(0), height.get(0));
                STBImage.stbi_image_free(rgba);
                Ok(image)
            };
        MemoryUtil.memFree(input);
        MemoryUtil.memFree(width);
        MemoryUtil.memFree(height);
        MemoryUtil.memFree(channels);
        decoded

    /// stb の RGBA（1 画素 4 バイト）を ARGB の int の並びにする。
    def imageOfRgba(rgba: ByteBuffer, w: Int32, h: Int32): ImageData.ImageData \ IO = region rc {
        let argb: Array[Int32, rc] = Array.empty(rc, w * h);
        discard rgba.order(ByteOrder.LITTLE_ENDIAN).asIntBuffer().get(argb);
        swapRedBlue(argb, 0, w * h);
        { width = w, height = h, argb = Array.toVector(argb) }
    }

    /// リトルエンディアンで読んだ ABGR を ARGB にする（赤と青を入れ替える）。
    def swapRedBlue(pixels: Array[Int32, r], i: Int32, n: Int32): Unit \ r =
        if (i >= n) ()
        else {
            let abgr = Array.get(i, pixels);
            let red = Int32.bitwiseAnd(abgr, 255);
            let blue = Int32.bitwiseAnd(Int32.rightShift(abgr, 16), 255);
            Array.put(Int32.bitwiseOr(Int32.bitwiseAnd(abgr, -16711936), Int32.bitwiseOr(Int32.leftShift(red, 16), blue)), i, pixels);
            swapRedBlue(pixels, i + 1, n)
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
