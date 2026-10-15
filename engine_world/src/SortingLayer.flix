// SortingLayer — 画面全体の重なりの層を名前で宣言する表と、ZStack の木を z の数へ戻す組み立て（compose）。
// Unity の Sorting Layer（名前つきの層）と同じ考え方。ゲームは層を enum で宣言し、instance で各層の
// z の範囲を match で書く（case を足すと網羅で止まる）。層の並び（どれが手前か）は範囲の底の順。
// 表は根（画面全体）にだけ置き、層の中は ZStack の積んだ順、部品の中は葉の中の小さな z で決める。
// 利用例: 場面の絵 → 会話 → 確認の窓 → 指している物 → 切り替え を層にし、
//         `SortingLayer.compose(ctx, (Layer.Scene, scene) :: (Layer.Talk, talk) :: Nil)` で 1 本の絵の列にする。
//         場面の奥から出す説明の窓は `ZStack.topLayer(Layer.Pointer, leaf(tip))` で Pointer の層へ送る。
// 注意: 区画を越えた分は天井で止めて続け、ViewCtx#warnOnce で層の名前ごとに知らせる（毎フレーム通るので
//   止めない。描き出しはこの口に集まった名前で止める）。範囲の地図（world / UI / Transition / HUD /
//   デバッグ）は docs/z-bands.md。
//
// 費用: 絵の数 N・節の数 M・送った物の数 P に対して O(N + M log M + P log P)（M log M は zIndex の付いた子を持つ
// of の子の並べ替え）。どの絵も z を 1 回だけ写す（入れ子の深さで z を写し直さない）。mapItems は今の
// Render.*All と同じく、入れ子 1 段ごとに中の絵を 1 回ずつ写す。層の数を掛ける処理（層ごとの filter・append）と
// 使い回し（キャッシュ）は持たない。

/// 層の z の範囲を返す取り決め。t はゲームが宣言した層の enum。
pub trait SortingLayer[t] {

    /// 層の z の範囲（底, 天井）。天井も層に含む。層どうしの前後は底の順。
    pub def zRange(layer: t): (Int32, Int32)
}

pub mod SortingLayer {

    use ZStack.Node

    /// 層の中の順番 order（0 = 層の底）の z（移行の間だけ: 場面を木にするまで、表から z の数を引く View 用）。
    /// 範囲の確かめはしない —— 描いた絵が層の天井を越えたかは compose が一手に見る。
    pub def z(layer: t, order: Int32): Int32 with SortingLayer[t] =
        bottom(layer) + order

    /// 層の底の z（順番 0）。
    pub def bottom(layer: t): Int32 with SortingLayer[t] = fst(SortingLayer.zRange(layer))

    /// 層の天井の z。
    pub def top(layer: t): Int32 with SortingLayer[t] = snd(SortingLayer.zRange(layer))

    /// 層ごとの木を 1 本の絵の列にする。各層の木はその層の底から積み、topLayer で送った物は送り先の層の
    /// 木の上に（送った順に）積む。同じ層が 2 回出たら 1 つにまとめる（後の木が手前）。
    /// 区画を越えた・奥の層へ送った・同じ層を 2 回渡した、はどれも続けたうえで ctx#warnOnce で知らせる。
    pub def compose(ctx: App.ViewCtx, entries: List[(t, Node[t])]): List[Render.PlacedItem]
        with SortingLayer[t], ToString[t] =
        let ranked = entries
            |> List.zipWithIndex
            |> List.map(entry -> { let (i, (layer, tree)) = entry; ((bottom(layer), i), (layer, tree)) })
            |> List.sortBy(fst)
            |> List.map(snd);
        // 1 巡目: 層ごとに自分の木を積む。送った物は描かずに集める。
        let first = List.foldLeft((st, entry) -> {
            let (layer, tree) = entry;
            let low = bottom(layer);
            let start = match Map.get(low, st#ends) {
                case Some(mark) =>
                    warned(ctx, "z fail-open: 層 ${layer} の 2 本目の木を 1 本目の手前に積みました — compose に同じ層が 2 回渡されました", mark#next)
                case None       => low
            };
            let done = walk(ctx, tree, None, { acc = st#acc, next = start, low = low, high = top(layer), sends = Nil, keep = true });
            let sends = List.foldLeft((acc, sent) -> claimed(ctx, layer, sent, acc), st#sends, List.reverse(done#sends));
            { acc = done#acc, sends = sends, ends = Map.insert(low, { name = "${layer}", low = low, high = top(layer), next = done#next }, st#ends) }
        }, { acc = Nil, sends = Nil, ends = Map.empty() }, ranked);
        // 2 巡目: 送った物を送り先の底の順・送った順に 1 回だけ並べ、送り先の層の続きから積む。
        let sends = List.reverse(first#sends)
            |> List.zipWithIndex
            |> List.map(entry -> { let (i, sent) = entry; ((bottom(sent#target), i), sent) })
            |> List.sortBy(fst)
            |> List.map(snd);
        let second = List.foldLeft((st, sent) -> {
            let low = bottom(sent#target);
            let mark = Map.get(low, st#ends) |> Option.getWithDefault({ name = "${sent#target}", low = low, high = top(sent#target), next = low });
            let done = walkWrapped(ctx, sent#child, sent#wrap, { acc = st#acc, next = mark#next, low = low, high = mark#high, sends = Nil, keep = false });
            { acc = done#acc, ends = Map.insert(low, { next = done#next | mark }, st#ends) }
        }, { acc = first#acc, ends = first#ends }, sends);
        Map.foldLeft((items, mark) ->
            if (mark#next - 1 > mark#high)
                warned(ctx, "z fail-open: 層 ${mark#name} の z を天井 ${mark#high} に替えました — 積んだ高さが区画 ${mark#low}..${mark#high} を越えました", items)
            else items, List.reverse(second#acc), second#ends)

    /// 1 つの層だけの compose。
    pub def stack(ctx: App.ViewCtx, layer: t, tree: Node[t]): List[Render.PlacedItem]
        with SortingLayer[t], ToString[t] =
        compose(ctx, (layer, tree) :: Nil)

    /// 表の決まりをテストで確かめる用: 奥から手前へ並べた層が、どれも底 <= 天井で、隣どうし交ざらずに上がっていくか。
    pub def isStacked(layers: List[t]): Bool with SortingLayer[t] =
        let wellFormed = layers |> List.forAll(layer -> bottom(layer) <= top(layer));
        let apart = List.zip(layers, List.drop(1, layers))
            |> List.forAll(pair -> { let (back, front) = pair; top(back) < bottom(front) });
        wellFormed and apart

    /// 表の決まりをテストで確かめる用: どの層も outer（底, 天井）の中に収まるか。
    /// HUD の層をエンジンの HUD の範囲（0..ZBand.innerMax）に収めるときに使う。
    pub def isWithin(outer: (Int32, Int32), layers: List[t]): Bool with SortingLayer[t] =
        let (outerLow, outerHigh) = outer;
        layers |> List.forAll(layer -> outerLow <= bottom(layer) and top(layer) <= outerHigh)

    /// ctx#warnOnce で line を知らせてから value を返す。
    /// WhyNot: `let _ = ctx#warnOnce(line); value` と書かない —— 純粋な型の呼び出しの値を捨てると、
    /// コンパイラが呼び出しごと消す（知らせが出ない）。値を match で受けると残る。
    def warned(ctx: App.ViewCtx, line: String, value: a): a =
        match ctx#warnOnce(line) {
            case () => value
        }

    // ── 木をたどる ──

    /// 絵の列に掛ける変換（道中の mapItems を外から内へ合わせた物。None は何も掛けない）。
    type alias Wrap = Option[List[Render.PlacedItem] -> List[Render.PlacedItem]]

    /// 送った物: 送り先の層・道中の変換・中身。
    type alias Sent[t] = { target = t, wrap = Wrap, child = Node[t] }

    /// 巡回の途中の状態。acc = 出した絵（逆順）・next = 次に使う z・low / high = いまの層の底と天井・
    /// sends = topLayer で送った物（逆順）・keep = 送った物を集めるか（2 巡目は集め終わっているので捨てる）。
    type alias Walk[t] = { acc = List[Render.PlacedItem], next = Int32, low = Int32, high = Int32, sends = List[Sent[t]], keep = Bool }

    /// 送った物 sent（層 source から）を、中の topLayer ごと acc の前へ積む（出会った順）。
    /// 送り元より奥の層への送りは送り元の層へ置き直して知らせる。
    def claimed(ctx: App.ViewCtx, source: t, sent: Sent[t], acc: List[Sent[t]]): List[Sent[t]]
        with SortingLayer[t], ToString[t] =
        let target = if (bottom(sent#target) >= bottom(source)) sent#target
                     else warned(ctx, "z fail-open: 層 ${source} から奥の層 ${sent#target} への topLayer を ${source} の手前に替えました — 奥の層へは送れません", source);
        gather(ctx, target, sent#child, sent#wrap, { target = target | sent } :: acc)

    /// node の中の topLayer を（出会った順に）acc の前へ積む。葉は見ない（節の数だけ）。
    def gather(ctx: App.ViewCtx, source: t, node: Node[t], wrap: Wrap, acc: List[Sent[t]]): List[Sent[t]]
        with SortingLayer[t], ToString[t] =
        match node {
            case Node.Leaf(_)                 => acc
            case Node.Absolute(_)             => acc
            case Node.Stacked(children)       => List.foldLeft((a, child) -> gather(ctx, source, child, wrap, a), acc, ordered(children))
            case Node.ZIndexed(_, child)      => gather(ctx, source, child, wrap, acc)
            case Node.TopLayer(target, child) => claimed(ctx, source, { target = target, wrap = wrap, child = child }, acc)
            case Node.Mapped(f, child)        => gather(ctx, source, child, wrapped(wrap, f), acc)
        }

    /// 道中の変換 outer の内側に f を足す（f を先に掛け、outer を後に掛ける）。
    def wrapped(outer: Wrap, f: List[Render.PlacedItem] -> List[Render.PlacedItem]): Wrap =
        match outer {
            case None    => Some(f)
            case Some(g) => Some(items -> g(f(items)))
        }

    /// 道中の変換 wrap を掛けながら node を出す（送った物を送り先で積むとき）。
    def walkWrapped(ctx: App.ViewCtx, node: Node[t], wrap: Wrap, st: Walk[t]): Walk[t] =
        match wrap {
            case None    => walk(ctx, node, None, st)
            case Some(f) => mapped(f, walk(ctx, node, wrap, { acc = Nil | st }), st#acc)
        }

    /// 木を深さ優先でたどって絵を出す。wrap は送った物に持たせる道中の変換。
    def walk(ctx: App.ViewCtx, node: Node[t], wrap: Wrap, st: Walk[t]): Walk[t] =
        match node {
            case Node.Leaf(items)             => emitLeaf(items, st)
            case Node.Absolute(items)         => emitAbsolute(ctx, items, st)
            case Node.Stacked(children)       => List.foldLeft((s, child) -> walk(ctx, child, wrap, s), st, ordered(children))
            case Node.ZIndexed(_, child)      => walk(ctx, child, wrap, st)
            case Node.TopLayer(target, child) =>
                if (st#keep) { sends = { target = target, wrap = wrap, child = child } :: st#sends | st } else st
            case Node.Mapped(f, child)        => mapped(f, walk(ctx, child, wrapped(wrap, f), { acc = Nil | st }), st#acc)
        }

    /// inner が出した絵（逆順）に f を掛け、外の蓄積 outer の前へ積む。
    def mapped(f: List[Render.PlacedItem] -> List[Render.PlacedItem], inner: Walk[t], outer: List[Render.PlacedItem]): Walk[t] =
        { acc = List.foldLeft((a, placed) -> placed :: a, outer, f(List.reverse(inner#acc))) | inner }

    /// zIndex の数で子を並べる（1 つも無ければ積んだ順のまま）。List.sortBy は安定でないので元の位置も鍵に含める。
    def ordered(children: List[Node[t]]): List[Node[t]] =
        if (not hasZIndex(children)) children
        else children
            |> List.zipWithIndex
            |> List.map(entry -> { let (i, child) = entry; ((orderOf(child), i), child) })
            |> List.sortBy(fst)
            |> List.map(snd)

    /// 子のどれかに zIndex が付いているか（of の子を 1 巡するだけ）。
    def hasZIndex(children: List[Node[t]]): Bool =
        match children {
            case Node.ZIndexed(_, _) :: _ => true
            case _ :: rest                => hasZIndex(rest)
            case Nil                      => false
        }

    def orderOf(node: Node[t]): Int32 = match node {
        case Node.ZIndexed(order, _) => order
        case _                       => 0
    }

    /// 葉 1 枚を next から出す。z の差を保ったまま最小の z を next へずらすので、同じ z は同じ z のまま。
    /// 中の z がまばらな葉は幅をそのまま使う —— 詰め直すと絵の数に log が掛かるため。天井を越えた分は天井で止める。
    def emitLeaf(items: List[Render.PlacedItem], st: Walk[t]): Walk[t] =
        match items {
            case Nil         => st
            case first :: _ =>
                let z0 = Render.zOf(first#item);
                let (low, high) = List.foldLeft((acc, placed) -> {
                    let (lo, hi) = acc;
                    let z = Render.zOf(placed#item);
                    (Int32.min(lo, z), Int32.max(hi, z))
                }, (z0, z0), items);
                let delta = st#next - low;
                let ceiling = st#high;
                let acc = List.foldLeft((a, placed) ->
                    { item = Render.zMapped(z -> Int32.min(ceiling, z + delta), placed#item) | placed } :: a, st#acc, items);
                { acc = acc, next = st#next + (high - low + 1) | st }
        }

    /// 絶対値の葉を z のまま出す（天井を越えた分は天井で止める）。層の続きは葉のいちばん手前の上から。
    /// 層の底より奥の z はそのまま出して知らせる（止めると移行前の絵が変わるため。描き出しはその知らせで止まる）。
    def emitAbsolute(ctx: App.ViewCtx, items: List[Render.PlacedItem], st: Walk[t]): Walk[t] =
        let ceiling = st#high;
        let (acc, lowest, highest) = List.foldLeft((triple, placed) -> {
            let (a, lo, hi) = triple;
            let z = Render.zOf(placed#item);
            let item = if (z > ceiling) Render.zMapped(_ -> ceiling, placed#item) else placed#item;
            ({ item = item | placed } :: a, Int32.min(lo, z), Int32.max(hi, z))
        }, (st#acc, st#low, st#next - 1), items);
        let done = { acc = acc, next = highest + 1 | st };
        if (lowest < st#low)
            warned(ctx, "z fail-open: 底 ${st#low} より奥の z ${lowest} を絶対値の葉のまま出しました — leafAbsolute の絵が層の区画の外にあります", done)
        else done
}
