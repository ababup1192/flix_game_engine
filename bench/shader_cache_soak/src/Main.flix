// 入口。隠しウィンドウの GL へ「数値だけが違う Spec」を大量に投げ、シェーダープログラムの
// キャッシュが上限で頭打ちになるかを確かめる。頭打ちになっていなければ exit 1。
//
// キャッシュの個数を外から読む口は無い（本番の pub 面を検査のために増やさない）ので、
// 追い出しが 1 行ずつ書く stderr を捕まえて数える。捕まえた行のうち追い出し以外は
// 本物の stderr へ流し直す — 起動時の知らせを握り潰すと、落ちたときに何も残らない。
use fge::GameEngine

mod ShaderCacheSoak {
    use fge::{DrawCmd, GameEngine, GpuHandle, LwjglLayer, ShaderDoc, ShaderEffect}

    import java.io.ByteArrayOutputStream
    import java.io.PrintStream
    import java.lang.System
    import java.nio.charset.StandardCharsets

    /// 投げる Spec の本数。上限（生きている面 1 枚なら 16）をはっきり越える数にする。
    def rounds(): Int32 = 200

    /// 追い出しの行の目印。
    def evictionMark(): String = "プログラムキャッシュから"

    /// 数値を 1 つずつ変えた Spec。ShaderGen.compile は Doc の数値を GLSL のリテラルへ
    /// 焼き込むので、cycleRate を動かすだけで 1 回ごとに別の鍵（別の GLSL ソース）になる。
    def specAt(i: Int32): ShaderDoc.Spec =
        let base = ShaderDoc.demoSurface();
        { cycleRate = 0.5 + Int32.toFloat64(i) / 1000.0 | base }

    def surfaceCmd(prog: GpuHandle.ShaderProgram): ShaderEffect.ShaderRenderCmd =
        { program = prog, texNames = Nil,
          rect = { position = { x = 0.0, y = 0.0 }, size = { x = 32.0, y = 32.0 } },
          mask = Nil, time = 0.0, zIndex = 0, blend = DrawCmd.BlendMode.Normal }

    /// 1 本ごとに「作って・積んで・フレームを 1 つ送る」。フレームを送らないと世代が進まず、
    /// 全ての program が「いま描いている物」に見えて 1 個も追い出されない。
    def soak(): Unit \ GameEngine.Game + ShaderEffect.Shader =
        List.range(0, rounds()) |> List.forEach(i -> {
            let prog = ShaderEffect.Shader.buildProgram(specAt(i));
            ShaderEffect.Shader.drawSurface(surfaceCmd(prog));
            GameEngine.Game.renderCommands(Nil, Nil, Nil, None)
        })

    // ── 行を読む ──

    /// 行に出てくる数字を出た順に取り出す。追い出しの行は
    /// 「N 個追い出した（… program M 個・残り R 個 / 上限 C）」の 4 つ。
    def numbersIn(line: String): List[Int32] =
        let step = (st, c) -> {
            let (acc, cur) = st;
            if (Char.isDigit(c)) (acc, c :: cur)
            else if (List.isEmpty(cur)) (acc, cur)
            else (digitsToInt(cur) :: acc, Nil)
        };
        let (acc0, cur0) = String.toList(line)
            |> List.foldLeft(step, ((Nil: List[Int32]), (Nil: List[Char])));
        let acc1 = if (List.isEmpty(cur0)) acc0 else digitsToInt(cur0) :: acc0;
        List.reverse(acc1)

    /// 逆順に積まれた数字を Int32 へ。
    def digitsToInt(revDigits: List[Char]): Int32 =
        List.reverse(revDigits)
            |> List.foldLeft((n, c) -> n * 10 + (Char.toBmpCodePoint(c) - Char.toBmpCodePoint('0')), 0)

    /// 追い出しの 1 行 → (追い出した鍵の数, 残り, 上限)。形が読めなければ None。
    def readEviction(line: String): Option[(Int32, Int32, Int32)] =
        if (String.contains({ substr = evictionMark() }, line))
            match numbersIn(line) {
                case victims :: _deleted :: left :: cap :: _ => Some((victims, left, cap))
                case _                                       => None
            }
        else None

    // ── 判定 ──

    /// 検査 3 つ。1 つでも破れたら false。
    ///   1. 1 個も追い出されていない = 上限が効いていない
    ///   2. 残りが上限を超えている行がある = 追い出しきれていない
    ///   3. 追い出した鍵の合計が「投げた本数 − 上限」に届かない = 途中で増え続けている
    def verdicts(evictions: List[(Int32, Int32, Int32)]): List[(Bool, String)] =
        let count = List.length(evictions);
        let evicted = evictions |> List.foldLeft((n, e) -> { let (v, _, _) = e; n + v }, 0);
        let overCap = evictions |> List.filter(e -> { let (_, left, cap) = e; left > cap });
        let lastCap = evictions |> List.last |> Option.map(e -> { let (_, _, cap) = e; cap })
            |> Option.getWithDefault(0);
        let needed = rounds() - lastCap;
        (count > 0, "追い出しが ${count} 回起きた")
            :: (List.isEmpty(overCap), "残りが上限を超えた行 ${List.length(overCap)} 本")
            :: (evicted >= needed, "追い出した鍵 ${evicted} 個 (要 ${needed} 個以上・上限 ${lastCap})")
            :: Nil

    def line(ok: Bool, text: String): String =
        "[soak] ${if (ok) "OK  " else "NG  "}${text}"

    pub def go(): Unit \ IO =
        let buf = new ByteArrayOutputStream();
        let capture = new PrintStream(buf, true, StandardCharsets.UTF_8);
        let realErr = System.err;
        System.setErr(capture);
        run {
            soak()
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO;
        capture.flush();
        System.setErr(realErr);
        let captured = buf.toString(StandardCharsets.UTF_8) |> String.lines;
        let (evictLines, otherLines) =
            List.partition(l -> String.contains({ substr = evictionMark() }, l), captured);
        otherLines |> List.forEach(l -> if (String.isEmpty(l)) () else realErr.println(l));
        let evictions = evictLines |> List.filterMap(readEviction);
        println("[soak] Spec を ${rounds()} 本投げた（数値だけが違う = 毎回別の鍵）");
        evictLines |> List.take(2) |> List.forEach(l -> println("[soak] 最初: ${l}"));
        evictLines |> List.reverse |> List.take(2) |> List.reverse
                   |> List.forEach(l -> println("[soak] 最後: ${l}"));
        let results = verdicts(evictions);
        results |> List.forEach(r -> { let (ok, text) = r; println(line(ok, text)) });
        if (List.exists(r -> { let (ok, _) = r; not ok }, results)) System.exit(1) else ()
}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else ShaderCacheSoak.go()
