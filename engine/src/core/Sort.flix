// Sort — どんな入力でも n log n で安定な並べ替え（マージソート）。
//
// Flix 標準の List.sort / sortBy / sortWith は Array.sortWithin（基準が範囲の最後の単純なクイックソート）を
// 呼ぶ。並んだ入力と鍵が全部同じ入力で比べる回数が数の二乗になり、安定でもないので、
// エンジンの並べ替えはここを通す（bin/lint-rules/forbid.json が標準の物を止める）。

pub mod Sort {

    /// 鍵の小さい順。鍵が同じ物は来た順のまま。鍵は 1 要素につき 1 回だけ作る。
    pub def sortStableBy(keyOf: a -> k, xs: List[a]): List[a] with Order[k] =
        xs
            |> List.map(x -> (keyOf(x), x))
            |> sortStableWith((p, q) -> fst(p) <=> fst(q))
            |> List.map(snd)

    /// 比べる関数で並べる。EqualTo の物は来た順のまま。
    pub def sortStableWith(cmp: (a, a) -> Comparison, xs: List[a]): List[a] =
        mergeRuns(cmp, List.map(x -> x :: Nil, xs))

    /// 要素そのものの小さい順。同じ物は来た順のまま。
    pub def sortStable(xs: List[a]): List[a] with Order[a] =
        sortStableWith((p, q) -> p <=> q, xs)

    // WhyNot: 再帰を数の深さにしない。組を半分ずつにして log n 回の走査で 1 本にする。
    def mergeRuns(cmp: (a, a) -> Comparison, runs: List[List[a]]): List[a] =
        match runs {
            case Nil         => Nil
            case only :: Nil => only
            case _           => mergeRuns(cmp, mergePairs(cmp, runs, Nil))
        }

    def mergePairs(cmp: (a, a) -> Comparison, runs: List[List[a]], done: List[List[a]]): List[List[a]] =
        match runs {
            case left :: right :: rest => mergePairs(cmp, rest, mergeTwo(cmp, left, right, Nil) :: done)
            case last                  => List.reverse(last ::: done)
        }

    // 同じ鍵なら左（先に来た方）を先に出す。これが安定の全部。
    def mergeTwo(cmp: (a, a) -> Comparison, left: List[a], right: List[a], acc: List[a]): List[a] =
        match (left, right) {
            case (Nil, _) => List.reverse(acc) ::: right
            case (_, Nil) => List.reverse(acc) ::: left
            case (l :: ls, r :: rs) => match cmp(l, r) {
                case Comparison.GreaterThan => mergeTwo(cmp, left, rs, r :: acc)
                case _                      => mergeTwo(cmp, ls, right, l :: acc)
            }
        }

}
