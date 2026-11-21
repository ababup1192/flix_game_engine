// TextSplit — 字を決まった区切りで分ける・行に分ける。答えは Flix 標準の String.split・String.lines と同じ。
//
// 標準の 2 つは中で Java の正規表現を使い、1 か所でも呼ぶとブラウザ版の wasm に java.util.regex の一式が入る
// （lint の java-regex が止める）。こちらは字を前から探すだけで書く。
// engine（契約層）にあるので、どのパッケージ・ゲームからでも呼べる。
pub mod TextSplit {

    /// s を区切りの字 sep で分ける。区切りは正規表現でなく字のまま見る。
    /// 答えは Java の String.split と同じ: 区切りが 1 つも無ければ s 1 本（空の s なら [""]）・末尾に続く空の要素は捨てる・先頭の空は残す。
    /// WhyNot: 末尾の空を残す String.splitOn をそのまま使わない — "a\n" を ["a", ""] にし、置き換える前の答えとずれる。
    pub def split(sep: String, s: String): List[String] =
        if (String.isEmpty(sep))
            s :: Nil
        else
            dropTrailingEmptyUnlessOne(String.splitOn(substr = sep, s))

    /// s を行に分ける。改行は \r\n・\n・\r のどれでも 1 つ。空の s は Nil・末尾に続く空の行は捨てる。
    /// WhyNot:   などの Unicode の改行は見ない — 標準の String.lines（\R）もブラウザ版では書き出しの道具が \r\n|[\n\r] に替えている。
    pub def lines(s: String): List[String] =
        if (String.isEmpty(s))
            Nil
        else
            dropTrailingEmptyUnlessOne(linesFrom(s, String.length(s), 0, 0, Nil))

    /// start から i までが今の行。i で改行を見つけたら行を積む。積む順は逆で、最後に返す。
    def linesFrom(s: String, len: Int32, start: Int32, i: Int32, acc: List[String]): List[String] =
        if (i >= len)
            List.reverse(String.slice(start = start, end = len, s) :: acc)
        else {
            let c = String.charAt(i, s);
            if (c == '\n')
                linesFrom(s, len, i + 1, i + 1, String.slice(start = start, end = i, s) :: acc)
            else if (c == '\r') {
                let next = if (i + 1 < len and String.charAt(i + 1, s) == '\n') i + 2 else i + 1;
                linesFrom(s, len, next, next, String.slice(start = start, end = i, s) :: acc)
            }
            else
                linesFrom(s, len, start, i + 1, acc)
        }

    /// 区切りが見つかった時（2 本以上）だけ、末尾に続く空の要素を捨てる。
    def dropTrailingEmptyUnlessOne(parts: List[String]): List[String] = match parts {
        case _ :: Nil => parts
        case _        => parts |> List.reverse |> List.dropWhile(String.isEmpty) |> List.reverse
    }
}
