// Log — 既定値で続けたことを人へ 1 行知らせる口。文面と出し先を 1 箇所に持つ。
// 出し先の決まりと定型文は docs/error-handling.md の決まり 3 にある。
//
// 純粋な関数の中から知らせるときは *Then の口（warnThen・fellBackThen・warnAllThen）で、
// 知らせた後に返す値を一緒に渡す。
// WhyNot: 純粋な関数の中で `let _ = Log.warn(..); 値` と書かない —— 戻り値が純粋な Unit なので、
// Flix は値を捨てる所で呼び出しごと消す（`let _ =` も、純粋な関数を渡した List.forEach も）。
// *Then の口は返す値が unsafe IO の中を通るので、消すと値が無くなり、消されない。
pub mod Log {
    import java.lang.System
    import java.io.{ByteArrayOutputStream, PrintStream}

    /// stderr へ 1 行。効果は `unsafe IO` で隠す
    /// （知らせるためだけに呼び側の効果行を広げない）。
    /// 効果のある関数（\ IO など）の中で、式の値として使う（末尾に置く・match で受ける）。
    /// 純粋な関数の中で値を捨てると消えるので、そこでは warnThen を使う。
    pub def warn(line: String): Unit =
        unsafe IO {
            System.err.println(line)
        }

    /// 既定値へ替えた事実を定型文で 1 行知らせる。
    /// domain は領域名（shader / doc / terrain など）、subject は替えた対象、
    /// fallback は替えた先の名前、reason は替えた理由。使い所は warn と同じ。
    pub def fellBack(domain: String, subject: String, fallback: String, reason: String): Unit =
        warn(fellBackLine(domain, subject, fallback, reason))

    /// stderr へ 1 行知らせてから value を返す。純粋な関数の中で知らせるときはこれ。
    /// `Log.warnThen("pxsprite fail-open: …", baked)`。value は知らせる前に計算済み。
    pub def warnThen(line: String, value: a): a =
        unsafe IO {
            System.err.println(line);
            value
        }

    /// fellBack の定型文で 1 行知らせてから value を返す。純粋な関数の中で知らせるときはこれ。
    pub def fellBackThen(domain: String, subject: String, fallback: String, reason: String, value: a): a =
        warnThen(fellBackLine(domain, subject, fallback, reason), value)

    /// lines を 1 行ずつ知らせてから value を返す（空なら何も出さない）。
    /// 繰り返しの中で 1 件ずつ知らせる代わりに、行を集めてからこれへ渡す。
    /// WhyNot: `List.forEach(x -> Log.warn(..), xs)` と書かない —— 渡す関数が純粋だと、
    /// forEach の値を match で受けても呼び出しが消える（0.35.16 で確かめた）。
    pub def warnAllThen(lines: List[String], value: a): a =
        unsafe IO {
            List.forEach(line -> System.err.println(line), lines);
            value
        }

    /// f を呼ぶ間に知らせた行を stderr へ出さずに集め、f の値と、知らせた行（出た順）を返す。
    /// テストで知らせを出す経路を通す時と、知らせが出たことを確かめる時に使う
    /// （Flix のテストの実行器は stderr に 1 字でも出たテストを FAIL にする）。
    /// `let (box, lines) = Log.capture(() -> CollisionShape3d.boxOfNode(node));`
    // WhyNot: ゲームや描き出しの中で使わない — System.err をまるごと差し替えるので、その間に他の糸が出した行も集めてしまう
    // （テストの実行器はテストを 1 本ずつ同じ糸で回すので、テストの中では混ざらない）。
    pub def capture(f: Unit -> a \ ef): (a, List[String]) \ ef + IO = region rc {
        let saved = System.err;
        let buffer = new ByteArrayOutputStream();
        let result = Ref.fresh(rc, None);
        System.setErr(new PrintStream(buffer, true, "UTF-8"));
        // WhyNot: `let value = f();` と置いて後で使わない — f が純粋に見えると、Flix は値を使う所（stderr を戻した後）まで呼び出しを遅らせうる。
        // Ref へ入れる所は効果があるので、そこで呼び終わる。
        Ref.put(Some(f()), result);
        System.setErr(saved);
        let lines = String.lines(buffer.toString("UTF-8")) |> List.filter(line -> not String.isEmpty(line));
        match Ref.get(result) {
            case Some(value) => (value, lines)
            case None        => bug!("Log.capture: f の値を受け取る前に Ref を読んだ")
        }
    }

    /// fellBack の定型文の 1 行（出さない）。行を集めて warnAllThen へ渡すときに使う。
    pub def fellBackLine(domain: String, subject: String, fallback: String, reason: String): String =
        "${domain} fail-open: ${subject} を${fallback}に替えました — ${reason}"
}
