// SortingLayer — 画面全体の重なりの層を名前で宣言する表と、ZStack の木を z の数へ戻す組み立て（compose）と、同じ前後で押す物を選ぶ口（pick）。
// 使う場面: 根（Main / View の入口）で 1 回 compose する・新しい層（ポーズ・確認）は enum に case を足す・押す物の当たりを描く時と同じ前後で選ぶ。
// Unity の Sorting Layer（名前つきの層）と同じ考え方。ゲームは層を enum で宣言し、instance で各層の
// z の範囲を match で書く（case を足すと網羅で止まる）。層の並び（どれが手前か）は範囲の底の順。
// 表は根（画面全体）にだけ置き、層の中は ZStack の積んだ順、部品の中は葉の中の小さな z で決める。
// 利用例: 場面の絵 → 会話 → 確認の窓 → 指している物 → 切り替え を層にし、
//         `SortingLayer.compose(ctx, (Layer.Scene, scene) :: (Layer.Talk, talk) :: Nil)` で 1 本の絵の列にする。
//         場面の奥から出す説明の窓は `ZStack.topLayer(Layer.Pointer, leaf(tip))` で Pointer の層へ送る。
// 押す物の当たり（pickFrom）: 描く木に積んだ ZStack.hit を、compose と同じ前後で手前から選ぶ（当たりの表を別に書かない）。
//         `let layers = (Layer.Scene, of(leaf(door) :: hit(Press.Door, doorRect) :: Nil)) ::
//                       (Layer.Prompt, modal(Layer.Prompt, Some(Press.No), of(leaf(ask) :: hit(Press.Yes, yesRect) :: Nil))) :: Nil;
//          SortingLayer.compose(ctx, layers)          // 描く
//          SortingLayer.pickFrom(pointer, layers)     // 押した物（窓の間は Door に届かない）`
//         HUD の木は場面より手前なので `pickIn(点, over(hitsOf(HUD の層), hitsOf(場面の層)))`。
//         入力の側で木を組むときの ViewCtx は App.pickCtx（当たりの矩形は字の幅から作らない）。
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

    use ZStack.Tree

    /// 押せる物の当たりの列（手前 → 奥）。hitsOf だけが作る —— 木を通さない当たりの表を書けないように、
    /// 中身の enum は外へ出さない（読むのは pickIn・hitAt・toList）。
    enum HitList[a] {
        case HitList(List[Entry[a]])
    }

    pub type alias Hits[a] = HitList[a]

    /// 当たり 1 つ。target = 押したら何か（None = 奥を塞ぐだけ）・area = 矩形（None = 画面全体）。
    type alias Entry[a] = { target = Option[a], area = Option[Rect2.Rect2] }

    /// 当たりの読み出し（hitAt・toList の結果）。rect = None は画面全体（hitAnywhere・modal の窓の外）。
    pub type alias Picked[a] = { target = a, rect = Option[Rect2.Rect2] }

    /// 層の底の z（順番 0）。
    pub def bottom(layer: t): Int32 with SortingLayer[t] = fst(SortingLayer.zRange(layer))

    /// 層の天井の z。
    pub def top(layer: t): Int32 with SortingLayer[t] = snd(SortingLayer.zRange(layer))

    /// 層ごとの木を 1 本の絵の列にする。各層の木はその層の底から積み、topLayer で送った物は送り先の層の
    /// 木の上に（送った順に）積む。同じ層が 2 回出たら 1 つにまとめる（後の木が手前）。
    /// 区画を越えた・奥の層へ送った・同じ層を 2 回渡した、はどれも続けたうえで ctx#warnOnce で知らせる。
    pub def compose(ctx: App.ViewCtx, entries: List[(t, Tree[t, a])]): List[Render.PlacedItem]
        with SortingLayer[t], ToString[t] =
        laidOut(ctx#warnOnce, true, entries)#items

    /// 木に積んだ当たり（ZStack.hit・hitAnywhere・blocking・modal）の列。前後は compose と同じ道筋で決まる
    /// （層の底の順・積んだ順・zIndex・topLayer の送り先・mapItems の変換）。絵は組まない。
    /// 区画を越えた・奥へ送った、の知らせは compose の側で出るので、ここでは黙る。
    pub def hitsOf(entries: List[(t, Tree[t, a])]): Hits[a] with SortingLayer[t], ToString[t] =
        HitList.HitList(laidOut(_ -> (), false, entries)#hits)

    /// point の下のいちばん手前の押せる物（無い・窓が塞いでいる所は None）。`pickIn(point, hitsOf(entries))`。
    pub def pickFrom(point: Vec2.Vec2, entries: List[(t, Tree[t, a])]): Option[a] with SortingLayer[t], ToString[t] =
        pickIn(point, hitsOf(entries))

    /// point の下のいちばん手前の押せる物。
    pub def pickIn(point: Vec2.Vec2, hits: Hits[a]): Option[a] =
        hitAt(point, hits) |> Option.map(picked -> picked#target)

    /// point の下のいちばん手前の押せる物と、その矩形（押せる物を光らせる絵に使う）。
    pub def hitAt(point: Vec2.Vec2, hits: Hits[a]): Option[Picked[a]] =
        let HitList.HitList(list) = hits;
        List.find(entry -> match entry#area {
            case None       => true
            case Some(rect) => Rect2.hasPoint(point, rect)
        }, list)
            |> Option.flatMap(entry -> entry#target |> Option.map(target -> { target = target, rect = entry#area }))

    /// front（HUD など、いつも手前の木の当たり）を back の手前に重ねる。
    pub def over(front: Hits[a], back: Hits[a]): Hits[a] =
        let HitList.HitList(f) = front;
        let HitList.HitList(b) = back;
        HitList.HitList(List.append(f, b))

    /// 押せる物の一覧（手前 → 奥。塞ぐだけの当たりは出さない）。描き出しでマウスを置く所を探すとき用。
    pub def toList(hits: Hits[a]): List[Picked[a]] =
        let HitList.HitList(list) = hits;
        list |> List.filterMap(entry -> entry#target |> Option.map(target -> { target = target, rect = entry#area }))

    /// compose と hitsOf の共通の道筋。draw = false なら絵を組まず当たりだけ集める。
    def laidOut(note: String -> Unit, draw: Bool, entries: List[(t, Tree[t, a])]): { items = List[Render.PlacedItem], hits = List[Entry[a]] }
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
                    warned(note, "z fail-open: 層 ${layer} の 2 本目の木を 1 本目の手前に積みました — compose に同じ層が 2 回渡されました", mark#next)
                case None       => low
            };
            let done = walk(tree, None, { acc = st#acc, hits = st#hits, next = start, low = low, high = top(layer), sends = Nil, keep = true, draw = draw });
            let sends = List.foldLeft((acc, sent) -> claimed(note, layer, sent, acc), st#sends, List.reverse(done#sends));
            { acc = done#acc, hits = done#hits, sends = sends, ends = Map.insert(low, { name = "${layer}", low = low, high = top(layer), next = done#next }, st#ends) }
        }, { acc = Nil, hits = Nil, sends = Nil, ends = Map.empty() }, ranked);
        // 2 巡目: 送った物を送り先の底の順・送った順に 1 回だけ並べ、送り先の層の続きから積む。
        let sends = List.reverse(first#sends)
            |> List.zipWithIndex
            |> List.map(entry -> { let (i, sent) = entry; ((bottom(sent#target), i), sent) })
            |> List.sortBy(fst)
            |> List.map(snd);
        let second = List.foldLeft((st, sent) -> {
            let low = bottom(sent#target);
            let mark = Map.get(low, st#ends) |> Option.getWithDefault({ name = "${sent#target}", low = low, high = top(sent#target), next = low });
            let done = walkWrapped(sent#child, sent#wrap, { acc = st#acc, hits = st#hits, next = mark#next, low = low, high = mark#high, sends = Nil, keep = false, draw = draw });
            { acc = done#acc, hits = done#hits, ends = Map.insert(low, { next = done#next | mark }, st#ends) }
        }, { acc = first#acc, hits = first#hits, ends = first#ends }, sends);
        let items = Map.foldLeft((placed, mark) ->
            if (mark#next - 1 > mark#high)
                warned(note, "z fail-open: 層 ${mark#name} の z を天井 ${mark#high} に替えました — 積んだ高さが区画 ${mark#low}..${mark#high} を越えました", placed)
            else placed, List.reverse(second#acc), second#ends);
        { items = items, hits = second#hits }

    /// 0.39 で消す —— 当たりは描く木に ZStack.hit で積み、pickFrom で選ぶ（この口は描く木と別の表を書かせる）。
    /// point の下にある物のうち、いちばん手前の物（どれにも当たらなければ None）。
    /// 層の前後は compose と同じ zRange の底の順（同じ層を 2 回渡したら後の列が手前）。同じ層の中は列の後ろほど
    /// 手前（ZStack.of に積む順と同じ）。UiFocusNav.hitTest（列の前ほど先に当たる）とは向きが逆。
    /// 窓の外を押せなくする層は、その層の列の先頭に画面全体の矩形を 1 つ置く（冒頭の例）。
    /// 描いた木は見ない: ZStack.topLayer で送った物は送り先の層の列に置き、葉の中の z や zIndex の付け替えは前後に効かない。
    pub def pick(point: Vec2.Vec2, entries: List[(t, List[(a, Rect2.Rect2)])]): Option[a] with SortingLayer[t] =
        entries
            |> List.zipWithIndex
            |> List.map(entry -> { let (i, (layer, targets)) = entry; ((bottom(layer), i), targets) })
            |> List.sortBy(fst)
            |> List.foldLeft((found, entry) -> List.foldLeft((hit, target) -> {
                   let (value, rect) = target;
                   if (Rect2.hasPoint(point, rect)) Some(value) else hit
               }, found, snd(entry)), None)

    /// 1 つの層だけの compose。
    pub def stack(ctx: App.ViewCtx, layer: t, tree: Tree[t, a]): List[Render.PlacedItem]
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

    /// note（ctx#warnOnce）で line を知らせてから value を返す。
    /// WhyNot: `let _ = note(line); value` と書かない —— 純粋な型の呼び出しの値を捨てると、
    /// コンパイラが呼び出しごと消す（知らせが出ない）。値を match で受けると残る。
    def warned(note: String -> Unit, line: String, value: a): a =
        match note(line) {
            case () => value
        }

    // ── 木をたどる ──

    /// 絵の列に掛ける変換（道中の mapItems を外から内へ合わせた物。None は何も掛けない）。
    type alias Wrap = Option[List[Render.PlacedItem] -> List[Render.PlacedItem]]

    /// 送った物: 送り先の層・道中の変換・中身。
    type alias Sent[t, a] = { target = t, wrap = Wrap, child = Tree[t, a] }

    /// 巡回の途中の状態。acc = 出した絵（逆順）・hits = 出した当たり（逆順 = 手前が先）・next = 次に使う z・
    /// low / high = いまの層の底と天井・sends = topLayer で送った物（逆順）・
    /// keep = 送った物を集めるか（2 巡目は集め終わっているので捨てる）・draw = 絵を組むか（hitsOf は組まない）。
    type alias Walk[t, a] = { acc = List[Render.PlacedItem], hits = List[Entry[a]], next = Int32, low = Int32, high = Int32,
                              sends = List[Sent[t, a]], keep = Bool, draw = Bool }

    /// 送った物 sent（層 source から）を、中の topLayer ごと acc の前へ積む（出会った順）。
    /// 送り元より奥の層への送りは送り元の層へ置き直して知らせる。
    def claimed(note: String -> Unit, source: t, sent: Sent[t, a], acc: List[Sent[t, a]]): List[Sent[t, a]]
        with SortingLayer[t], ToString[t] =
        let target = if (bottom(sent#target) >= bottom(source)) sent#target
                     else warned(note, "z fail-open: 層 ${source} から奥の層 ${sent#target} への topLayer を ${source} の手前に替えました — 奥の層へは送れません", source);
        gather(note, target, sent#child, sent#wrap, { target = target | sent } :: acc)

    /// node の中の topLayer を（出会った順に）acc の前へ積む。葉は見ない（節の数だけ）。
    def gather(note: String -> Unit, source: t, node: Tree[t, a], wrap: Wrap, acc: List[Sent[t, a]]): List[Sent[t, a]]
        with SortingLayer[t], ToString[t] =
        match node {
            case Tree.Leaf(_)                 => acc
            case Tree.Hit(_, _)               => acc
            case Tree.Block(_)                => acc
            case Tree.Stacked(children)       => List.foldLeft((s, child) -> gather(note, source, child, wrap, s), acc, ordered(children))
            case Tree.ZIndexed(_, child)      => gather(note, source, child, wrap, acc)
            case Tree.TopLayer(target, child) => claimed(note, source, { target = target, wrap = wrap, child = child }, acc)
            case Tree.Mapped(f, child)        => gather(note, source, child, wrapped(wrap, f), acc)
        }

    /// 道中の変換 outer の内側に f を足す（f を先に掛け、outer を後に掛ける）。
    def wrapped(outer: Wrap, f: List[Render.PlacedItem] -> List[Render.PlacedItem]): Wrap =
        match outer {
            case None    => Some(f)
            case Some(g) => Some(items -> g(f(items)))
        }

    /// 道中の変換 wrap を掛けながら node を出す（送った物を送り先で積むとき）。
    def walkWrapped(node: Tree[t, a], wrap: Wrap, st: Walk[t, a]): Walk[t, a] =
        match wrap {
            case None    => walk(node, None, st)
            case Some(f) => mapped(f, walk(node, wrap, { acc = Nil, hits = Nil | st }), st)
        }

    /// 木を深さ優先でたどって絵と当たりを出す。wrap は送った物に持たせる道中の変換。
    def walk(node: Tree[t, a], wrap: Wrap, st: Walk[t, a]): Walk[t, a] =
        match node {
            case Tree.Leaf(items)             => if (st#draw) emitLeaf(items, st) else st
            case Tree.Hit(target, rect)       => { hits = { target = Some(target), area = Some(rect) } :: st#hits | st }
            case Tree.Block(target)           => { hits = { target = target, area = None } :: st#hits | st }
            case Tree.Stacked(children)       => List.foldLeft((s, child) -> walk(child, wrap, s), st, ordered(children))
            case Tree.ZIndexed(_, child)      => walk(child, wrap, st)
            case Tree.TopLayer(target, child) =>
                if (st#keep) { sends = { target = target, wrap = wrap, child = child } :: st#sends | st } else st
            case Tree.Mapped(f, child)        => mapped(f, walk(child, wrapped(wrap, f), { acc = Nil, hits = Nil | st }), st)
        }

    /// inner が出した絵（逆順）と当たりに f を掛け、外の蓄積 outer の前へ積む。
    def mapped(f: List[Render.PlacedItem] -> List[Render.PlacedItem], inner: Walk[t, a], outer: Walk[t, a]): Walk[t, a] =
        let items = if (List.isEmpty(inner#acc)) outer#acc
                    else List.foldLeft((acc, placed) -> placed :: acc, outer#acc, f(List.reverse(inner#acc)));
        let hits = List.foldRight((entry, acc) -> match movedHit(f, entry) {
            case Some(moved) => moved :: acc
            case None        => acc
        }, outer#hits, inner#hits);
        { acc = items, hits = hits | inner }

    /// 当たり 1 つに f を掛ける。矩形を切り抜きの枠にした見えない箱を f に通し、出てきた枠（入れ子なら重なり）を読む。
    /// f が箱を消したら None（描かない物は押せない）。画面全体の当たりは動かさない。
    def movedHit(f: List[Render.PlacedItem] -> List[Render.PlacedItem], entry: Entry[a]): Option[Entry[a]] =
        match entry#area {
            case None       => Some(entry)
            case Some(rect) =>
                let probe = { at = rect#position, item = Render.clipped(rect, RawDraw.box(rect#size, Color.rgb(0.0, 0.0, 0.0), 0)) };
                match f(probe :: Nil) {
                    case placed :: _ => Some({ area = Some(clipOf(placed#item, None) |> Option.getWithDefault(rect)) | entry })
                    case Nil         => None
                }
        }

    /// 入れ子の切り抜きの枠の重なり（切り抜きが無ければ None）。
    def clipOf(item: Render.Item, outer: Option[Rect2.Rect2]): Option[Rect2.Rect2] =
        match item {
            case Render.Item.Clipped(c) =>
                let here = match outer {
                    case None       => c#rect
                    case Some(rect) => Rect2.intersect(rect, c#rect)
                };
                clipOf(c#inner, Some(here))
            case _ => outer
        }

    /// zIndex の数で子を並べる（1 つも無ければ積んだ順のまま）。List.sortBy は安定でないので元の位置も鍵に含める。
    def ordered(children: List[Tree[t, a]]): List[Tree[t, a]] =
        if (not hasZIndex(children)) children
        else children
            |> List.zipWithIndex
            |> List.map(entry -> { let (i, child) = entry; ((orderOf(child), i), child) })
            |> List.sortBy(fst)
            |> List.map(snd)

    /// 子のどれかに zIndex が付いているか（of の子を 1 巡するだけ）。
    def hasZIndex(children: List[Tree[t, a]]): Bool =
        match children {
            case Tree.ZIndexed(_, _) :: _ => true
            case _ :: rest                => hasZIndex(rest)
            case Nil                      => false
        }

    def orderOf(node: Tree[t, a]): Int32 = match node {
        case Tree.ZIndexed(order, _) => order
        case _                       => 0
    }

    /// 葉 1 枚を next から出す。z の差を保ったまま最小の z を next へずらすので、同じ z は同じ z のまま。
    /// 中の z がまばらな葉は幅をそのまま使う —— 詰め直すと絵の数に log が掛かるため。天井を越えた分は天井で止める。
    def emitLeaf(items: List[Render.PlacedItem], st: Walk[t, a]): Walk[t, a] =
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
                    { item = zMapped(z -> Int32.min(ceiling, z + delta), placed#item) | placed } :: a, st#acc, items);
                { acc = acc, next = st#next + (high - low + 1) | st }
        }

    // WhyNot: 同じ 10 行を UiRender・SortingLayer・App に 1 つずつ置く。pub にするとゲームから z を書き換えられ、
    //   どの層に入るかが表から読めなくなる（Flix 0.77 にはパッケージの中だけで見える pub が無い）。
    /// 描画物の重なり順（zIndex）を f で写す（Clipped は中身の z）。木を層の区画へ置く所（emitLeaf）だけで使う。
    def zMapped(f: Int32 -> Int32, item: Render.Item): Render.Item =
        match item {
            case Render.Item.Sprite(s)  => Render.Item.Sprite({ zIndex = f(s#zIndex) | s })
            case Render.Item.Text(x)    => Render.Item.Text({ zIndex = f(x#zIndex) | x })
            case Render.Item.Box(b)     => Render.Item.Box({ zIndex = f(b#zIndex) | b })
            case Render.Item.Poly(p)    => Render.Item.Poly({ zIndex = f(p#zIndex) | p })
            case Render.Item.Shader(s)  => Render.Item.Shader({ zIndex = f(s#zIndex) | s })
            case Render.Item.Clipped(c) => Render.Item.Clipped({ inner = zMapped(f, c#inner) | c })
        }
}
