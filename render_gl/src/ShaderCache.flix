// RenderShaderCache — シェーダープログラムのキャッシュから追い出す (evict) 鍵を選ぶ純関数。
//
// GL を一切呼ばないのは、上限と pin の境目をユニットテストで固定するため。GL を握った
// 場所へ書くと、実機のウィンドウが無いと 1 行も検査できなくなる。

mod RenderShaderCache {

    /// コンパイル済みプログラム 1 本と、その uniform location。
    pub type alias ProgramEntry = { program = Int32, uRectPos = Int32, uRectSize = Int32, uTime = Int32 }

    /// LRU で追い出す鍵を、最後に使った世代の古い順に返す。
    ///   entries … (鍵, program 番号, 最後に使った世代)
    ///   pinned  … 追い出してはいけない program 番号
    ///   cap     … キャッシュに残してよい鍵の数
    ///
    /// pinned を守った結果 cap を超えたままになるなら、超えたままにする — いま描く面の
    /// program を捨てると絵が壊れるので、上限を破る方が安い。
    /// 同じ program 番号を持つ鍵が複数あっても鍵ごとに別々に選ぶ。GL の delete を呼ぶかは
    /// 呼ぶ側の判断で、ここは鍵しか返さない。
    pub def computeEvictions(args: { entries = List[(String, Int32, Int64)],
                                     pinned = Set[Int32],
                                     cap = Int32 }): List[String] =
        let excess = List.length(args#entries) - args#cap;
        if (excess <= 0) Nil
        else
            args#entries
                |> List.filterMap(e -> {
                    let (key, program, usedAt) = e;
                    if (Set.memberOf(program, args#pinned)) None else Some((usedAt, key))
                })
                |> List.sortBy(fst)
                |> List.take(excess)
                |> List.map(snd)

    /// 同じ名前で作り直して鍵から外れた（引退した）program のうち、もう消してよい物と、まだ残す物。
    /// 今と前のコマで使った物（pinned）と、まだ別の鍵が指している物（keyed）は残す —
    /// 面の描画は後回しなので、同じコマの前の面がまだその program で描く。
    pub def retiredToDelete(retired: Set[Int32], pinned: Set[Int32], keyed: Set[Int32]): (Set[Int32], Set[Int32]) =
        Set.partition(program -> not Set.memberOf(program, pinned) and not Set.memberOf(program, keyed), retired)

}
