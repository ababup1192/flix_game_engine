// ZStack — 描く順（z）を「積んだ順」で決める木（SwiftUI の ZStack・CSS の stacking context の形）。
// 使う場面: View が絵を返すところ全部（重ねる・必ず手前へ送る topLayer・足元の順 zIndex・画面ごと動かす mapItems）と、
//   押せる物の当たり（hit・どこでも hitAnywhere・窓の奥を押させない blocking / modal）。
// 使わない: z の大きな数を書く（積む順で決める）。
// View は z の数を選ぶ代わりに、部品の列を奥 → 手前の順に of へ並べて返す。z の数を書くのは
// 葉（leaf）の中の小さな前後（胴 0・頭 1・持ち物 2）だけ。木を z の数へ戻すのは SortingLayer.compose
// （画面全体の層の表の、その層の底から詰める）。
// 利用例: ページ送りの画面を 幕 → 立ち絵 → 枠 → 映した画面 → 赤ペン → 会話の欄 → 確認 の順に積む /
//         見下ろし画面で 1 人ずつを足元の高さ（Depth.orderAt）で並べる / 場面の奥のカードから説明の窓だけ
//         手前の層へ送る（topLayer）/ 鼓動で画面ごと膨らませる（mapItems）。
// 押せる物: ボタンの葉の隣に `hit(Press.Yes, 矩形)` を積み、確認の窓は `modal(Layer.Prompt, Some(Press.No), 窓の木)`
//         で送る。当たりの列は SortingLayer.hitsOf / pickFrom が同じ木から描く順で出す（別の表を書かない）。
//         手前ほど先に当たり、modal / blocking の窓の奥（奥の層も含む）には届かない。
// 注意: 葉の中の z は、その葉の中の前後にだけ効く。葉どうしの前後は積んだ順。
//   別の葉に分けた物どうしは、元が同じ z でも積んだ順になる（描画部は同じ z の中を種類順
//   tiles → sprites → polygons → static → surfaces で描くので、同じ z を分け合う物は 1 枚の葉に入れる）。
//   決まりは「1 部品 = 1 葉」から始め、葉を割るのは前の葉の最大 z < 次の葉の最小 z を確かめてから。
//   状態も使い回し（キャッシュ）も持たない。毎フレーム組んで捨てる。範囲の地図は docs/z-bands.md。
pub mod ZStack {

    /// 積み木の木。p は topLayer の行き先（ゲームの SortingLayer の層の enum）、a は押せる物の名前
    /// （ゲームの enum。押せる物を持たない木は型変数のままにしておく）。
    pub enum Tree[p, a] {
        /// 葉。中の z はこの葉の中の前後だけを決める（数の大きさは意味を持たない）。
        case Leaf(List[Render.PlacedItem])
        /// 子を奥 → 手前に積む。子どうしの z の範囲は交ざらない。
        case Stacked(List[Tree[p, a]])
        /// すぐ外の Stacked の中で並べ替える数（CSS の z-index。付けない子は 0）。
        case ZIndexed(Int32, Tree[p, a])
        /// 中身をその場から抜き、表の層 p の手前へ積む。
        case TopLayer(p, Tree[p, a])
        /// 中身の絵の列に掛ける変換（移動・縮め・薄め・切り抜き）。z は変えない物に限る。
        case Mapped(List[Render.PlacedItem] -> List[Render.PlacedItem], Tree[p, a])
        /// 押せる物 a の当たり（描かない）。積んだ所の前後で当たる。
        case Hit(a, Rect2.Rect2)
        /// 画面全体の当たり（描かない）。これより奥はどこも押せない。Some(a) なら押すと a・None なら何も起きない。
        case Block(Option[a])
    }

    /// 0.37 までの木の名前（押せる物を持たない木）。0.39 で消す —— 新しく書く所は Tree[p, a]。
    pub type alias Node[p] = Tree[p, Unit]

    /// 葉: 組み上がった絵の列を 1 つの子にする（中の前後は z のまま保つ）。
    pub def leaf(items: List[Render.PlacedItem]): Tree[p, a] = Tree.Leaf(items)

    /// 子を奥 → 手前の順に積む。
    pub def of(children: List[Tree[p, a]]): Tree[p, a] = Tree.Stacked(children)

    /// すぐ外の of の中で child を前後へずらす（小さいほど奥・付けない兄弟は 0・同じ数は積んだ順）。
    /// 見下ろしの足元の順は `of(people |> List.map(p -> zIndex(Depth.orderAt(p.footY), leaf(p.parts))))`
    /// （1 人が 1 つの子なので、隣の人と部品が交互に重ならない）。
    /// of の直下でない所（根・topLayer の直下）に付けた数は使われない。
    pub def zIndex(order: Int32, child: Tree[p, a]): Tree[p, a] = Tree.ZIndexed(order, child)

    /// child を、表の層 target の手前（その層の木と、先に送られた物の上）へ送る。
    /// 木のどの深さからでも送れて、topLayer の中の topLayer も同じように送られる。道中の mapItems の変換は
    /// 送った物にも掛かる（縮めて映した画面から送った物は、縮んだ位置に出る）。
    /// 送り元より奥の層へは送れない（送り元の層の手前に置き、ViewCtx#warnOnce で知らせる）。
    pub def topLayer(target: p, child: Tree[p, a]): Tree[p, a] = Tree.TopLayer(target, child)

    /// child の絵の列に f を掛ける（`Render.movedAll(d)`・`Render.scaledAllAround(k, pivot)`・
    /// `Render.fadeAll(a)`・`Render.clippedAll(rect)` など）。f で z を変えない（前後は木が決める）。
    /// 押せる物の当たりも同じ f で動く（矩形を切り抜きの枠にした見えない絵を f に通して読み戻す。f が絵を消したら当たりも消える）。
    pub def mapItems(f: List[Render.PlacedItem] -> List[Render.PlacedItem], child: Tree[p, a]): Tree[p, a] =
        Tree.Mapped(f, child)

    // ── 押せる物 ──

    /// 押せる物 target の当たりを rect に置く（描かない）。ボタンの絵の葉のすぐ後ろ（手前）に積む。
    /// 同じ点に重なった当たりは、描く順で手前の物が勝つ（SortingLayer.pickFrom）。
    pub def hit(target: a, rect: Rect2.Rect2): Tree[p, a] = Tree.Hit(target, rect)

    /// 画面のどこを押しても target（「どこでも次へ」）。これより奥の当たりには届かない。
    pub def hitAnywhere(target: a): Tree[p, a] = Tree.Block(Some(target))

    /// child より奥を押せなくする（奥の層も含む）。窓の外を押したら outside（None なら何も起きない）。
    /// child の中の当たりは、窓の外の当たりより手前なので先に当たる。
    pub def blocking(outside: Option[a], child: Tree[p, a]): Tree[p, a] =
        Tree.Stacked(Tree.Block(outside) :: child :: Nil)

    /// 確認の窓・ポーズ: child を層 target の手前へ送り（topLayer）、開いている間は奥を押せなくする（blocking）。
    pub def modal(target: p, outside: Option[a], child: Tree[p, a]): Tree[p, a] =
        topLayer(target, blocking(outside, child))
}
