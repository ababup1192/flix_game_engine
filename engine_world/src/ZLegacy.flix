// ZLegacy — z の数を直に書く古い書き方。ZStack の木で書けない所に、理由をつけて残すときだけ使う。
// 使う場面: 描き上がった 1 フレームを丸ごと加工する演出（裂く・色ずれの影を物ごとに 1 段上へ重ねる）のように、
//   葉の前後では書けない物。ゲームから呼ぶと bin/fge forbid（zlegacy）が止めるので、forbid.local.json の
//   exempt に "パス::zlegacy" と「なぜ木で書けないか」を 1 行書いて残す。
// 使わない: ふつうの重なり（ZStack.of に奥 → 手前で積む・必ず手前は ZStack.topLayer・見下ろしは
//   ZStack.zIndex(Depth.orderAt(足元の y), …)・画面ごと動かすのは ZStack.mapItems）。docs/z-bands.md。
// 置き換えの表は docs/migrations/0.35.24.md（Render.zShiftedAll → ZLegacy.zShiftedAll・SortingLayer.z → ZLegacy.rawZ）。
// 注意: Flix 0.77.0 の @Deprecated は呼んでも警告を出さない。印として付け、古い書き方であることは名前で表す。
pub mod ZLegacy {

    /// 層の中の順番 order（0 = 層の底）の z の数。前の名前は SortingLayer.z。
    /// 範囲の確かめはしない —— 描いた絵が層の天井を越えたかは SortingLayer.compose が見る。
    @Deprecated
    pub def rawZ(layer: t, order: Int32): Int32 with SortingLayer[t] =
        SortingLayer.bottom(layer) + order

    /// 置き場所つきの列の重なり順を丸ごと delta だけずらす。前の名前は Render.zShiftedAll。
    @Deprecated
    pub def zShiftedAll(delta: Int32, items: List[Render.PlacedItem]): List[Render.PlacedItem] =
        items |> List.map(placed -> { item = EngineInternal.zMapped(z -> z + delta, placed#item) | placed })
}
