// SubtitleWrap — 会話の字幕を最大 2 行に折り返す決まり（純粋）。
// 折り返す所は、句読点（、。？！）と「……」と』の後・『の前・空白の所だけ（言葉の途中で切らない）。
// 句読点の後を一番に、『の前を次に選び、どちらの行も maxChars 字に収まる所のうち一番後ろで切る。
// 収まる所が無ければ、切れる所のうち長い方の行が一番短くなる所（数字が少しはみ出してもよい）。切れる所が 1 つも無い時だけ maxChars 字で切る
// （台詞を 2 行に収まる長さに分けるのは .yarn の側）。
// WhyNot: 』の後ろが平仮名なら切らない — 『影の落とし物』／として、のように助詞が行の頭に来て不自然に読めた。
mod SubtitleWrap {

    /// 全文 text を行に分ける（maxChars 字までなら 1 行）。行の頭と尻の空白は落とす。
    pub def linesOf(maxChars: Int32, text: String): List[String] =
        let chars = String.toList(text) |> List.toVector;
        let n = Vector.length(chars);
        if (n <= maxChars) text :: Nil
        else {
            let cut = bestBreak(maxChars, chars) |> Option.getWithDefault(maxChars);
            let slice = (a: Int32, b: Int32) -> Vector.slice(start = a, end = b, chars) |> Vector.toList |> List.map(Char.toString) |> List.join("") |> String.trim;
            slice(0, cut) :: slice(cut, n) :: Nil
        }

    /// 切れる所 i（i 字目の前で切る）と、その点数（大きいほど良い）。
    def scoreAt(chars: Vector[Char], i: Int32): Int32 =
        let before = Vector.nth(i - 1, chars) |> Option.getWithDefault(' ');
        let here = Vector.nth(i, chars) |> Option.getWithDefault(' ');
        let hiragana = (c: Char) -> Char.toBmpCodePoint(c) >= 0x3041 and Char.toBmpCodePoint(c) <= 0x3096;
        if (List.memberOf(before, '、' :: '。' :: '？' :: '！' :: Nil) and here != '…' and here != '』') 3
        else if (before == '』' and not hiragana(here) and here != '…') 3
        else if (before == '…' and here != '…') 3
        else if (here == ' ' or before == ' ') 3
        else if (here == '『') 2
        else 0

    /// どちらの行も maxChars 字に収まる切れ目のうち、点数の高い物の一番後ろ。収まる物が無ければ、長い方の行が一番短くなる切れ目。
    def bestBreak(maxChars: Int32, chars: Vector[Char]): Option[Int32] =
        let n = Vector.length(chars);
        let all = List.range(1, n) |> List.map(i -> (scoreAt(chars, i), i)) |> List.filter(e -> fst(e) > 0);
        let fitting = all |> List.filter(e -> snd(e) <= maxChars and n - snd(e) <= maxChars);
        let longer = (i: Int32) -> Int32.max(i, n - i);
        match fitting |> List.maximumBy((a, b) -> if (fst(a) == fst(b)) snd(a) <=> snd(b) else fst(a) <=> fst(b)) {
            case Some(e) => Some(snd(e))
            case None    => all |> List.minimumBy((a, b) -> if (longer(snd(a)) == longer(snd(b))) fst(b) <=> fst(a) else longer(snd(a)) <=> longer(snd(b))) |> Option.map(snd)
        }

    /// 文字送りで見えている字数 shown に合わせて、行ごとに見えている所を返す（折り返す所は全文で決めた所のまま）。
    pub def revealed(lines: List[String], shown: Int32): List[String] =
        let (_, out) = lines |> List.foldLeft((acc, line) -> {
            let (left, done) = acc;
            let len = String.length(line);
            let take = Int32.max(0, Int32.min(len, left));
            (left - len, String.takeLeft(take, line) :: done)
        }, (shown, Nil));
        List.reverse(out) |> List.filter(l -> not String.isEmpty(l))
}
