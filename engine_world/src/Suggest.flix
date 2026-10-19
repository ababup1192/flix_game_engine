// Suggest — 知らない名前に「もしかして」の候補を付ける。flow の check・始まりの名前（START・/start）・
// 役やキーの名前の誤りで、行番号と一緒に近い名前を言うために使う。
// 近さは編集距離（1 字の足し・消し・置き換えを 1 と数える）と、頭が同じかどうか。
// bin/fge flow check（Go）も同じ決まりで候補を出す（go/internal/flow の nearNames）。
pub mod Suggest {

    /// a と b の編集距離（大文字小文字は区別しない）。
    pub def distance(a: String, b: String): Int32 =
        let xs = String.toList(String.toLowerCase(a));
        let ys = String.toList(String.toLowerCase(b));
        let first = List.range(0, List.length(ys) + 1);
        let last = xs |> List.zipWithIndex |> List.foldLeft((prev, entry) -> {
            let (i, x) = entry;
            let row = List.zip(ys, List.zip(prev, List.drop(1, prev))) |> List.foldLeft((acc, step) -> {
                let (y, (diagonal, up)) = step;
                let left = List.head(acc) |> Option.getWithDefault(0);
                let cost = if (x == y) 0 else 1;
                Int32.min(Int32.min(left + 1, up + 1), diagonal + cost) :: acc
            }, (i + 1) :: Nil);
            List.reverse(row)
        }, first);
        List.last(last) |> Option.getWithDefault(0)

    /// known のうち name に近い名前（距離 2 以内か、2 字以上の頭が同じ物）を近い順に 3 つまで。
    pub def near(name: String, known: List[String]): List[String] =
        let lower = String.toLowerCase(name);
        known
            |> List.map(candidate -> (distance(name, candidate), candidate))
            |> List.filter(entry -> {
                let (d, candidate) = entry;
                d <= 2 or (String.length(name) >= 2 and String.startsWith(prefix = lower, String.toLowerCase(candidate)))
            })
            |> List.zipWithIndex
            |> List.sortBy(entry -> { let (index, (d, _)) = entry; d * 10000 + index })
            |> List.take(3)
            |> List.map(entry -> { let (_, (_, candidate)) = entry; candidate })

    /// 知らせの後ろに付ける 1 句: 近い名前があれば「（もしかして: a / b）」、無ければ使える名前を 12 個まで。
    pub def hint(name: String, known: List[String]): String =
        match near(name, known) {
            case Nil =>
                let shown = known |> List.take(12) |> String.intercalate(" ");
                let more = if (List.length(known) > 12) " …" else "";
                if (List.isEmpty(known)) "（使える名前はまだ無い）" else "（使える名前: ${shown}${more}）"
            case some => "（もしかして: ${String.intercalate(" / ", some)}）"
        }
}
