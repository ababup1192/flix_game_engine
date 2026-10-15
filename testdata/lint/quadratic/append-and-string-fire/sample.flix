mod Sample {
    def rows(lines: List[List[Int32]]): List[Int32] =
        List.foldLeft((acc, line) -> List.append(acc, line), Nil, lines)

    def joined(cs: List[Char]): String =
        cs |> List.map(Char.toString) |> List.foldLeft(String.concat, "")

    def prelude(bs: List[String]): String =
        let (text, _) = List.foldLeft((acc, b) -> {
            let (out, n) = acc;
            (out + b, n + 1)
        }, ("", 0), bs);
        text
}
