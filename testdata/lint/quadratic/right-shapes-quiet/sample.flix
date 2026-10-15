mod Sample {
    def rows(lines: List[List[Int32]]): List[Int32] =
        List.flatten(List.reverse(List.foldLeft((acc, line) -> line :: acc, Nil, lines)))

    def total(xs: List[Int32]): Int32 =
        List.foldLeft((acc, x) -> acc + x, 0, xs)
}
