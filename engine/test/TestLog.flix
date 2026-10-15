// 何を守るか: 純粋な関数の中から *Then の口で知らせた行が、本当に stderr へ出ること
// （`let _ = Log.warn(..)` は Flix が呼び出しごと消すので、出た文面まで確かめる）。
mod TestLog {
    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System

    /// body を走らせる間だけ stderr を差し替え、出た文面と body の値を返す。
    /// body には差し替えた後に読んだ数（いつも 0）を渡し、body はそれを文面に混ぜる。
    /// WhyNot: 引数無しの純粋な body を渡さない —— Flix は純粋な式を差し替えより前へ動かせるので、
    /// 知らせが差し替える前の stderr に出る。
    def stderrOf(body: Int32 -> a): (a, String) \ IO =
        let old = System.err;
        let buf = new ByteArrayOutputStream();
        System.setErr(new PrintStream(buf, true));
        let value = body(buf.size());
        System.setErr(old);
        (value, buf.toString())

    def decodeWithWarning(n: Int32, tag: Int32): Int32 =
        if (n < 0) Log.fellBackThen("probe", "n=${n}", "0", "負の数です ${tag}", 0) else n

    @Test
    def warnThenPrintsFromPureCode(): Unit \ {Assert, IO} =
        let (value, err) = stderrOf(n -> Log.warnThen("probe: 1 行 ${n}", 7));
        Assert.assertEq(expected = (7, true), (value, String.contains(substr = "probe: 1 行", err)))

    @Test
    def fellBackThenUsesTheFixedSentence(): Unit \ {Assert, IO} =
        let (value, err) = stderrOf(tag -> decodeWithWarning(-3, tag));
        Assert.assertEq(expected = (0, true),
            (value, String.contains(substr = "probe fail-open: n=-3 を0に替えました — 負の数です 0", err)))

    @Test
    def warnAllThenPrintsEveryLineAndNothingWhenEmpty(): Unit \ {Assert, IO} =
        let (_, err) = stderrOf(n -> Log.warnAllThen("probe-a ${n}" :: "probe-b ${n}" :: Nil, ()));
        let (_, quiet) = stderrOf(n -> Log.warnAllThen(Nil, n));
        Assert.assertEq(expected = (true, true, ""),
            (String.contains(substr = "probe-a 0", err), String.contains(substr = "probe-b 0", err), quiet))
}
