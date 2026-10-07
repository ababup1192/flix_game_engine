// Depth — 見下ろし画面で「足元が下にある物ほど手前」を、重なり順（zIndex）の数として決める。
// 人・木・柵・家をひとつの z の範囲（ZRange）の中に並べると、すれ違うたびに前後が入れ替わる。
// 利用例: 主人公が木の手前に出たり裏に隠れたりする / 柵の向こうに立つ / 落ちている物をまたぐ。
// 注意: 決めるのは数だけで、並べ替えは描画部の仕事（同じ zIndex 同士は渡した順のまま）。
//
// ZRange の考え方: back..front の整数の幅を、world の top..bottom の高さに割り当てる。
// 範囲の外（もっと奥の地面、もっと手前の HUD）とは重ならない数の範囲を選ぶこと。
// 範囲の幅は「マスの数 + 1」くらいあれば足りる（同じ行に立つ物は同じ数になってよい）。
//
// 1 画面に帯が何本も要るとき（奥・遠景・地面・影・中景・近景・手前）は Bands で名前を付けて
// 並べる。帯の底の数をゲーム側の定数として手で並べると、1 本足すたびに以降を全部書き直す。
pub mod Depth {

    /// 足元の高さ（world の y）を重なり順に写す z の範囲。
    /// back / front = 割り当てる zIndex の範囲（back が奥・front が手前）。
    /// top / bottom = その範囲に対応する world の y（top が奥・bottom が手前）。
    pub type alias ZRange = { back = Int32, front = Int32, top = Float64, bottom = Float64 }

    /// マス目の盤から ZRange を作る近道。1 行に 1 つの zIndex を割り当てる。
    /// back = 範囲の一番奥の zIndex、originY = 盤の上端の world y、rows = 行数、tileSize = 1 マスの辺。
    pub def forRows(spec: { back = Int32, originY = Float64, rows = Int32, tileSize = Float64 }): ZRange =
        { back = spec#back,
          front = spec#back + Int32.max(1, spec#rows),
          top = spec#originY,
          bottom = spec#originY + Int32.toFloat64(Int32.max(1, spec#rows)) * spec#tileSize }

    /// 足元の高さ footY に対する重なり順。範囲の外に出た足元は端で止める
    /// （画面外へ歩いても順序が壊れない）。
    pub def zAt(range: ZRange, footY: Float64): Int32 =
        let span = range#bottom - range#top;
        let t = if (Float64.abs(span) < 0.000001) 0.0
                else Num.clamp01((footY - range#top) / span);
        let steps = Int32.toFloat64(range#front - range#back);
        range#back + (Float64.round(t * steps) |> Float64.tryToInt32 |> Option.getWithDefault(0))

    /// 組み上がった絵の集まりを、足元の高さで決まる層へ持ち上げる。
    /// 部品どうしの相対的な前後（胴 0・頭 1・持ち物 2 のような小さな差）はそのまま保たれるので、
    /// 呼び側は 0 から数えた小さな z で 1 体を組めばよい。
    pub def place(range: ZRange, footY: Float64, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        Render.zShiftedAll(zAt(range, footY), items)

    /// place の 1 個版。置き場所の下端（=足元）を自分で渡す。
    pub def placeOne(range: ZRange, footY: Float64, placed: Render.PlacedItem): Render.PlacedItem =
        { item = Render.zShifted(zAt(range, footY), placed#item) | placed }

    // ════════════════════════════════════════════════════════
    // 帯を何本も並べる（奥・遠景・地面・影・中景・近景・手前 …）
    // ════════════════════════════════════════════════════════

    /// 帯の名前 → その帯の底の zIndex。1 画面を「奥から手前へ」何段かに仕切ったときの地図。
    /// world の範囲（docs/z-bands.md）の中だけで完結する数で、UI・HUD の範囲には触らない。
    pub type alias Bands = Map[String, Int32]

    /// 奥から手前へ並べた名前の列から帯の地図を作る。
    /// base = 一番奥の帯の底、stride = 1 帯に取る zIndex の幅。
    /// stride は「その帯の中で前後を作れる余地」で、Depth.zAt で並べ替える帯なら
    /// 「行の数 + 1」以上、ベタ 1 枚の帯なら小さくてよい。
    ///
    /// 同じ名前が 2 度出たら後の（手前の）方が勝つ。
    pub def bands(spec: { base = Int32, stride = Int32 }, names: List[String]): Bands =
        let step = Int32.max(1, spec#stride);
        names
            |> List.mapWithIndex((i, name) -> (name, spec#base + i * step))
            |> List.toMap

    /// 帯 name の底の zIndex。知らない名前は一番奥（base 側 = 地図の最小値）へ落とす。
    /// 綴り違いは「その絵だけ一番奥へ回る」形で目に見えるので、黙って手前に出るより気づける。
    pub def bandZ(map: Bands, name: String): Int32 =
        match Map.get(name, map) {
            case Some(z) => z
            case None    => Map.valuesOf(map) |> List.minimum |> Option.getWithDefault(0)
        }

    /// 帯 name の中で「足元が下にある物ほど手前」を作る ZRange。
    /// 帯の幅（stride）を超えないので、隣の帯へはみ出して前後が崩れることがない。
    pub def bandRange(map: Bands, name: String,
                      spec: { stride = Int32, top = Float64, bottom = Float64 }): ZRange =
        let back = bandZ(map, name);
        { back = back, front = back + Int32.max(1, spec#stride) - 1,
          top = spec#top, bottom = spec#bottom }
}
