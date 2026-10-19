// Suggest — 知らない名前に「もしかして」の候補を付ける。flow の check・始まりの名前（START・/start）・
// 役やキーの名前の誤りで、行番号と一緒に近い名前を言うために使う。
// 近さは編集距離（1 字の足し・消し・置き換え・隣の 2 字の入れ替えを 1 と数える）と、頭が同じかどうか。
// bin/fge flow check（Go）も同じ決まりで候補を出す（go/internal/flow の nearNames）。
pub mod Suggest {

    /// a と b の編集距離（大文字小文字は区別しない）。隣り合う 2 字の入れ替え（tpa → tap）も 1 と数える。
    pub def distance(a: String, b: String): Int32 =
        let xs = String.toLowerCase(a) |> String.toList |> List.toVector;
        let ys = String.toLowerCase(b) |> String.toList |> List.toVector;
        let n = Vector.length(ys);
        let first = Vector.range(0, n + 1);
        let (_, last) = List.range(1, Vector.length(xs) + 1) |> List.foldLeft((rows, i) -> {
            let (twoBack, prev) = rows;
            let row = List.range(1, n + 1) |> List.foldLeft((cur, j) -> {
                let left = List.head(cur) |> Option.getWithDefault(i);
                let cost = if (Vector.get(i - 1, xs) == Vector.get(j - 1, ys)) 0 else 1;
                let edited = Int32.min(Int32.min(left + 1, Vector.get(j, prev) + 1), Vector.get(j - 1, prev) + cost);
                let swapped = i > 1 and j > 1 and Vector.get(i - 1, xs) == Vector.get(j - 2, ys)
                              and Vector.get(i - 2, xs) == Vector.get(j - 1, ys);
                (if (swapped) Int32.min(edited, Vector.get(j - 2, twoBack) + 1) else edited) :: cur
            }, i :: Nil) |> List.reverse |> List.toVector;
            (prev, row)
        }, (first, first));
        Vector.get(n, last)

    /// known のうち name に近い名前（距離 2 以内（3 字以下の名前は 1 以内）か、2 字以上の頭が同じ物）を近い順に 3 つまで。
    pub def near(name: String, known: List[String]): List[String] =
        let lower = String.toLowerCase(name);
        let limit = if (String.length(name) <= 3) 1 else 2;
        known
            |> List.map(candidate -> (distance(name, candidate), candidate))
            |> List.filter(entry -> {
                let (d, candidate) = entry;
                d <= limit or (String.length(name) >= 2 and String.startsWith(prefix = lower, String.toLowerCase(candidate)))
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
