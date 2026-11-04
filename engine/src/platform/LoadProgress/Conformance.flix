// LoadProgress.Conformance — LoadProgress の handler が runTasks の決まり（知らせの並び・50 ms ごとの知らせ・例外で抜ける）を
// 守るかを確かめる、テストを組む関数。handler を持つ層（render_gl・engine_tools・ブラウザ）のテストが自分の handler を渡して呼ぶ
// （engine のテストからはほかの層の handler が見えないので、決まりはここに 1 つだけ置く）。
// 眠る・投げる・時刻を読む・スレッドをまたぐフラグは機種の物なので、テストの側が Harness で渡す。

pub mod LoadProgress.Conformance {
    import java.lang.Throwable

    /// 確かめる handler と、テストの側が用意する道具。
    /// handle = 試す handler で program を流し、結果と、handler が届けた知らせ (phase, done, total) の並びを返す。
    /// sleepMs = 今のスレッドを眠らせる（起こされたら例外で抜けてよい）・fail = 字を message に持つ例外を投げる・
    /// nowMs = ミリ秒の時刻（差だけを使う）・newFlag = どのスレッドから立てても見えるフラグを 1 つ作る（AtomicBoolean など）。
    pub type alias Harness = {
        handle = (Unit -> List[Int32] \ IO + LoadProgress) -> (List[Int32], List[(String, Int32, Int32)]) \ IO,
        sleepMs = Int64 -> Unit \ IO,
        fail = String -> Unit \ IO,
        nowMs = Unit -> Int64 \ IO,
        newFlag = Unit -> Flag \ IO
    }

    /// スレッドをまたいで立てて読むフラグ。
    pub type alias Flag = { raise = Unit -> Unit \ IO, isRaised = Unit -> Bool \ IO }

    /// 知らせの並びと結果の並び: 後ろほど早く終わる 5 つの仕事で、結果は xs の順・最初が (p, 0, 5)・最後が (p, 5, 5)・
    /// done は 0 から 5 まで 1 つずつ増える。守れていない決まりを 1 行ずつ返す（空なら守れている）。
    pub def orderViolations(harness: Harness): List[String] \ IO =
        let slowerFirst = x -> { (harness#sleepMs)(Int32.toInt64((5 - x) * 5)); x * 10 };
        let (ys, seen) = (harness#handle)(() -> LoadProgress.parMapWithProgress("p", slowerFirst, List.range(0, 5)));
        let dones = List.map(s -> { let (_, done, _) = s; done }, seen);
        violation(ys == 0 :: 10 :: 20 :: 30 :: 40 :: Nil, "結果が xs の順でない: ${ys}")
            ++ violation(List.head(seen) == Some(("p", 0, 5)), "最初の知らせが (p, 0, 5) でない: ${List.head(seen)}")
            ++ violation(List.last(seen) == Some(("p", 5, 5)), "最後の知らせが (p, 5, 5) でない: ${List.last(seen)}")
            ++ violation(List.distinct(dones) == List.range(0, 6) and isAscending(dones), "done が 0 から 5 まで 1 つずつ増えていない: ${dones}")

    /// 50 ms ごとの知らせ: 300 ms 眠る 1 つの仕事の間に、done 0 の知らせが 3 回以上届く（並列で回す handler だけが守る）。
    pub def pollingViolations(harness: Harness): List[String] \ IO =
        let (_, seen) = (harness#handle)(() -> LoadProgress.parMapWithProgress("p", x -> { (harness#sleepMs)(300i64); x }, 0 :: Nil));
        let zeros = List.count(s -> { let (_, done, _) = s; done == 0 }, seen);
        violation(zeros >= 3, "300 ms の間に done 0 の知らせが ${Int32.toString(zeros)} 回（50 ms ごとなら 3 回以上）")

    /// 例外で抜ける: 最初の仕事が 20 ms で投げ、残りは 3 秒眠る。同じ message の例外で、残りを待たずに（2 秒より前に）抜け、
    /// 始まっていた残りの仕事は止められる（眠りから起こされる。抜けてから 1 秒まで待つ）。順に回す handler は残りを始めないので通る。
    pub def failureViolations(harness: Harness): List[String] \ IO =
        let marker = "LoadProgress.Conformance: 試しの例外";
        let started = (harness#newFlag)();
        let stopped = (harness#newFlag)();
        let work = x -> if (x == 0) { (harness#sleepMs)(20i64); (harness#fail)(marker); x } else {
            (started#raise)();
            try { (harness#sleepMs)(3000i64) } catch { case _: Throwable => (stopped#raise)() };
            x
        };
        let begun = (harness#nowMs)();
        let caught = try {
            discard (harness#handle)(() -> LoadProgress.parMapWithProgress("p", work, List.range(0, 4)));
            None
        } catch {
            case e: Throwable => Some(e.getMessage())
        };
        let elapsed = (harness#nowMs)() - begun;
        let rest = not (started#isRaised)() or waitFor(harness, stopped, 100);
        violation(caught == Some(marker), "仕事の例外がそのまま抜けていない: ${caught}")
            ++ violation(elapsed < 2000i64, "例外の後も残りの仕事を待った（${Int64.toString(elapsed)} ms）")
            ++ violation(rest, "例外の後も残りの仕事が止められずに眠り続けた")

    /// flag が立つまで 10 ms ずつ最大 left 回待つ。
    def waitFor(harness: Harness, flag: Flag, left: Int32): Bool \ IO =
        if ((flag#isRaised)() or left <= 0) (flag#isRaised)()
        else { (harness#sleepMs)(10i64); waitFor(harness, flag, left - 1) }

    def violation(ok: Bool, line: String): List[String] = if (ok) Nil else line :: Nil

    def isAscending(xs: List[Int32]): Bool =
        List.zip(xs, List.drop(1, xs)) |> List.forAll(p -> { let (a, b) = p; a <= b })
}
