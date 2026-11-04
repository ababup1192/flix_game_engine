// LogCapture — テストの中で Log の知らせを stderr へ出さずに集める道具。
pub mod LogCapture {
    import java.lang.System
    import java.io.{ByteArrayOutputStream, PrintStream}

    /// f を呼ぶ間に知らせた行を stderr へ出さずに集め、f の値と、知らせた行（出た順）を返す。
    /// テストで知らせを出す経路を通す時と、知らせが出たことを確かめる時に使う
    /// （Flix のテストの実行器は stderr に 1 字でも出たテストを FAIL にする）。
    /// `let (box, lines) = LogCapture.capture(() -> CollisionShape3d.boxOfNode(node));`
    // WhyNot: ゲームや描き出しの中で使わない — System.err をまるごと差し替えるので、その間に他のスレッドが出した行も集めてしまう
    // （テストの実行器はテストを 1 本ずつ同じスレッドで回すので、テストの中では混ざらない）。
    pub def capture(f: Unit -> a \ ef): (a, List[String]) \ ef + IO = region rc {
        let saved = System.err;
        let buffer = new ByteArrayOutputStream();
        let result = Ref.fresh(rc, None);
        System.setErr(new PrintStream(buffer, true, "UTF-8"));
        // WhyNot: `let value = f();` と置いて後で使わない — f が純粋に見えると、Flix は値を使う所（stderr を戻した後）まで呼び出しを遅らせうる。
        // Ref へ入れる所は効果があるので、そこで呼び終わる。
        // WhyNot: f() を差し替えた後に読んだ値（buffer.size()）の分かれ道の外に置かない — 純粋に見える f は差し替えより前へ動かされうる。
        Ref.put(if (buffer.size() >= 0) Some(f()) else None, result);
        System.setErr(saved);
        let lines = String.lines(buffer.toString("UTF-8")) |> List.filter(line -> not String.isEmpty(line));
        match Ref.get(result) {
            case Some(value) => (value, lines)
            case None        => bug!("LogCapture.capture: f の値を受け取る前に Ref を読んだ")
        }
    }
}
