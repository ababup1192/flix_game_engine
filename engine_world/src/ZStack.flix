// ZStack — 描く順（z）を「積んだ順」で決める木（SwiftUI の ZStack・CSS の stacking context の形）。
// View は z の数を選ぶ代わりに、部品の列を奥 → 手前の順に of へ並べて返す。z の数を書くのは
// 葉（leaf）の中の小さな前後（胴 0・頭 1・持ち物 2）だけ。木を z の数へ戻すのは SortingLayer.compose
// （画面全体の層の表の、その層の底から詰める）。
// 利用例: ページ送りの画面を 幕 → 立ち絵 → 枠 → 映した画面 → 赤ペン → 会話の欄 → 確認 の順に積む /
//         見下ろし画面で 1 人ずつを足元の高さ（Depth.orderAt）で並べる / 場面の奥のカードから説明の窓だけ
//         手前の層へ送る（topLayer）/ 鼓動で画面ごと膨らませる（mapItems）。
// 注意: 葉の中の z は、その葉の中の前後にだけ効く。葉どうしの前後は積んだ順。
//   別の葉に分けた物どうしは、元が同じ z でも積んだ順になる（描画部は同じ z の中を種類順
//   tiles → sprites → polygons → static → surfaces で描くので、同じ z を分け合う物は 1 枚の葉に入れる）。
//   決まりは「1 部品 = 1 葉」から始め、葉を割るのは前の葉の最大 z < 次の葉の最小 z を確かめてから。
//   状態も使い回し（キャッシュ）も持たない。毎フレーム組んで捨てる。範囲の地図は docs/z-bands.md。
pub mod ZStack {

    /// 積み木の木。p は topLayer の行き先（ゲームの SortingLayer の層の enum）。
    pub enum Node[p] {
        /// 葉。中の z はこの葉の中の前後だけを決める（数の大きさは意味を持たない）。
        case Leaf(List[Render.PlacedItem])
        /// 絶対値の z の葉（場面を木にするまでの移行の間だけ）。z をそのまま使い、層の続きをその上から始める。
        case Absolute(List[Render.PlacedItem])
        /// 子を奥 → 手前に積む。子どうしの z の範囲は交ざらない。
        case Stacked(List[Node[p]])
        /// すぐ外の Stacked の中で並べ替える数（CSS の z-index。付けない子は 0）。
        case ZIndexed(Int32, Node[p])
        /// 中身をその場から抜き、表の層 p の手前へ積む。
        case TopLayer(p, Node[p])
        /// 中身の絵の列に掛ける変換（移動・縮め・薄め・切り抜き）。z は変えない物に限る。
        case Mapped(List[Render.PlacedItem] -> List[Render.PlacedItem], Node[p])
    }

    /// 葉: 組み上がった絵の列を 1 つの子にする（中の前後は z のまま保つ）。
    pub def leaf(items: List[Render.PlacedItem]): Node[p] = Node.Leaf(items)

    /// 絶対値の z の葉: 今までどおり表から z の数を引いて描いた絵を、そのまま木に載せる（移行の間だけ）。
    /// 載せた z が層の続きより奥なら前の兄弟と交ざり、層の底より奥なら層の外に出る（どちらも描いて続け、層の外は
    /// ViewCtx#warnOnce で知らせる）。天井を越えた分は天井で止める。表を持つパッケージでは、表の外で呼ぶと z-table の lint が止める。
    pub def leafAbsolute(items: List[Render.PlacedItem]): Node[p] = Node.Absolute(items)

    /// 子を奥 → 手前の順に積む。
    pub def of(children: List[Node[p]]): Node[p] = Node.Stacked(children)

    /// すぐ外の of の中で child を前後へずらす（小さいほど奥・付けない兄弟は 0・同じ数は積んだ順）。
    /// 見下ろしの足元の順は `of(people |> List.map(p -> zIndex(Depth.orderAt(p.footY), leaf(p.parts))))`
    /// （1 人が 1 つの子なので、隣の人と部品が交互に重ならない）。
    /// of の直下でない所（根・topLayer の直下）に付けた数は使われない。
    pub def zIndex(order: Int32, child: Node[p]): Node[p] = Node.ZIndexed(order, child)

    /// child を、表の層 target の手前（その層の木と、先に送られた物の上）へ送る。
    /// 木のどの深さからでも送れて、topLayer の中の topLayer も同じように送られる。道中の mapItems の変換は
    /// 送った物にも掛かる（縮めて映した画面から送った物は、縮んだ位置に出る）。
    /// 送り元より奥の層へは送れない（送り元の層の手前に置き、ViewCtx#warnOnce で知らせる）。
    pub def topLayer(target: p, child: Node[p]): Node[p] = Node.TopLayer(target, child)

    /// child の絵の列に f を掛ける（`Render.movedAll(d)`・`Render.scaledAllAround(k, pivot)`・
    /// `Render.fadeAll(a)`・`Render.clippedAll(rect)` など）。f で z を変えない（前後は木が決める）。
    pub def mapItems(f: List[Render.PlacedItem] -> List[Render.PlacedItem], child: Node[p]): Node[p] =
        Node.Mapped(f, child)
}
