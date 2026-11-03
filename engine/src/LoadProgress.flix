// LoadProgress — 起動の読み込みの進み具合を、区切りごとにバックエンドへ知らせる。並列の仕事と絵のデコードも handler に任せる。
//
// 最初のコマを描くまでの読み込み（main の中の Doc・形・絵の解読、App の init と startupSystems）の間は
// ゲームのループが回っていないので、誰もウィンドウのイベントを poll しない。数秒続くと OS が応答なしと見なす。
// 知らせを受けたバックエンド（実機は LwjglLayer）が起動画面を進め、イベントを poll する。
// 1 つの区切りの中はエンジンが割り込めないので、本体のスレッドで知らせの間が 0.5 秒を超えないように区切る。
//
// 並列（スレッド）と絵のデコードは機種の物なので engine は持たない。handler の組:
//   デスクトップ = LwjglLayer（スレッドの pool・javax.imageio）・画面なしとテスト = HeadlessLoad.handle（同じ）・
//   runNoop = 順に回す（知らせは捨てる）。並列の handler が守る決まりは LoadProgress.Conformance で確かめる。

/// 起動の読み込みの進み具合（区切りごとに 1 回）と、読み込みの仕事を回す口。
pub eff LoadProgress {
    /// phase = 今やっていること（起動画面の字）・done / total = その中の何本目 / 全何本（total 0 以下は本数不明）。
    /// handler は必ず k を呼んで返す。RenderTarget を開いたまま（Pass に描いている途中で）呼ばない。
    def report(phase: String, done: Int32, total: Int32): Unit

    /// tasks を全部回してから戻る（並列にするかは handler が決める・ゲームは parMapWithProgress から使う）。
    /// handler の決まり: 最初に (phase, 0, n)・1 つ終わるたびに (phase, 終わった数, n) を知らせ、並列で回すなら
    /// 何も終わらない間も 50 ms ごとに知らせる。仕事が例外を投げたら残りを止め、同じ例外で抜ける。空の並びは何もしない。
    def runTasks(phase: String, tasks: List[Unit -> Unit \ IO]): Unit

    /// PNG / JPEG を画素に戻すデコーダー。読み込みの関数の頭（本体のスレッド）で受け取り、並列の仕事へ引数で渡す
    /// （仕事の中から op は呼べない — effect の handler はスレッドをまたがない）。
    def imageDecoder(): ImageData.ImageDecoder
}

pub mod LoadProgress {

    /// 知らせを捨て、仕事を順に回す handler（headless の描き出し・動画・テスト・flow の再生）。
    /// imageDecoder を受け取ると止まる（絵を解くなら HeadlessLoad.handle）。
    // WhyNot: runNoop のデコーダーを Err にしない — ゲームの読み込みは絵が読めないと既定値で続けるので、
    // コンパイルは通ったまま e2e・動画・gallery から部品が黙って消える。
    pub def runNoop(f: Unit -> a \ ef): a \ (ef - LoadProgress) + IO =
        run f() with handler LoadProgress {
            def report(_phase, _done, _total, k) = k(())
            def runTasks(phase, tasks, k) = { runTasksInOrder((_, _, _) -> (), phase, tasks); k(()) }
            def imageDecoder(_k) = bug!("[LoadProgress] runNoop の下で imageDecoder を受け取った。画面なしで絵を解くなら HeadlessLoad.handle で包む（docs/migrations/0.81.0.md）")
        }

    /// tasks を 1 つずつ回し、最初に (phase, 0, n)・1 つ終わるたびに (phase, 終わった数, n) を report へ渡す（空なら何も渡さない）。
    /// 仕事の例外はそのまま抜ける（残りは回さない）。並列にしない handler の runTasks の中身。
    pub def runTasksInOrder(report: (String, Int32, Int32) -> Unit \ ef, phase: String, tasks: List[Unit -> Unit \ IO]): Unit \ ef + IO =
        let n = List.length(tasks);
        if (n == 0) ()
        else {
            report(phase, 0, n);
            tasks |> List.zipWithIndex |> List.forEach(e -> {
                let (i, task) = e;
                task();
                report(phase, i + 1, n)
            })
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

    /// xs を f で作る（handler が並列に回す・結果の並びは xs のまま）。知らせと例外の決まりは runTasks のとおり
    /// （1 つの要素が長くてもウィンドウが応答し続ける）。f は IO だけ — effect の handler はスレッドをまたがないので、
    /// Fs.FileRead で読む物は先に読んでおき、絵を解くなら先に imageDecoder() で受け取って f へ渡す。空の並びは空を返す。
    pub def parMapWithProgress(phase: String, f: a -> b \ IO, xs: List[a]): List[b] \ IO + LoadProgress =
        let n = List.length(xs);
        if (n == 0) Nil
        else {
            let out: Array[Option[b], Static] = Array.repeat(Static, n, None);
            let tasks = xs |> List.zipWithIndex |> List.map(e -> { let (i, x) = e; () -> Array.put(Some(f(x)), i, out) });
            LoadProgress.runTasks(phase, tasks);
            Array.toList(out) |> List.map(y -> match y {
                case Some(v) => v
                case None    => bug!("LoadProgress.parMapWithProgress: handler の runTasks が全部の仕事を回さずに戻った")
            })
        }
}
