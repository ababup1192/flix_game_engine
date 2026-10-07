// Painter — カメラからの距離で遠→近に並べ、zBase から zStride 刻みの zIndex を振る。
// 疑似 3D は z バッファを持たないので、遠い物から順に上塗りして前後を作る（画家の順）。
// 逆引きの対: 見下ろしの「足元が下ほど手前」は Depth、距離の前後はこれ。
pub mod Painter {

    /// items を距離の遠い順に並べ、(zIndex, item) を返す。zIndex は
    /// zBase + 並び順 * zStride — 1 個が複数の層（面 + 縁取りなど）を使うなら
    /// zStride にその層数を渡す。同距離どうしの並びは入力に対して決定的
    /// （同じ列なら呼ぶたびに同じ — ちらつかない）だが、渡した順の保存までは保証しない。
    pub def zOrdered(distOf: a -> Float64, zBase: Int32, zStride: Int32,
                     items: List[a]): List[(Int32, a)] =
        items
            |> List.map(it -> (-distOf(it), it))
            |> List.sortBy(fst)
            |> List.zipWithIndex
            |> List.map(entry -> {
                let (idx, keyed) = entry;
                (zBase + idx * zStride, snd(keyed))
            })
}
