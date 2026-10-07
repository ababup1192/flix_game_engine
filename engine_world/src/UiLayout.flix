// UiLayout — 縦か横に並べる指定から、各 UI 要素の画面上の矩形（位置と大きさ）を自動で決める。
// 注意: 並びは縦か横の 1 方向のみ。折り返し・格子・割合指定は持たない。すべて純粋な計算。

pub mod UiLayout {

    /// 主軸方向。Row=横並び（主軸=X）、Column=縦並び（主軸=Y）。
    pub enum Dir with Eq { case Row, case Column }

    /// 主軸方向の余白配分。
    /// Start=先頭詰め、Center=中央寄せ、End=末尾詰め、SpaceBetween=両端揃えで間を均等。
    pub enum MainAlign with Eq { case Start, case Center, case End, case SpaceBetween }

    /// 交差軸方向の子の寄せ方。Stretch は子を親の交差サイズいっぱいに広げる。
    pub enum CrossAlign with Eq { case Start, case Center, case End, case Stretch }

    /// 軸ごとのサイズ指定。
    /// Auto=内在サイズ（テキスト実寸 / 子のヒュッグ）、Px=固定 px、Grow=余りを配る重み。
    pub enum SizeSpec with Eq {
        case Auto
        case Px(Float64)
        case Grow(Float64)
    }

    /// ノードのレイアウト属性。
    /// `dir`: 子を並べる主軸方向。
    /// `gap`: 子どうしの間隔（主軸方向）。
    /// `padLeft`/`padTop`/`padRight`/`padBottom`: 内側パディング。
    /// `width`/`height`: 自分の幅・高さの決め方。
    /// `mainAlign`/`crossAlign`: 子の主軸・交差軸の寄せ方。
    /// `wrap`: 主軸に収まらない子を次の行へ折り返す（Row のみ。幅と高さは明示が必要）。
    /// `abs`: Some のときフロー外（親コンテンツ原点からの絶対オフセットに置く。HUD の右上ピン等）。
    ///   flex の子でも out-of-flow で効く — 兄弟の並びにも親の自動サイズにも参加しない。
    pub type alias Style = {
        dir = Dir, gap = Float64,
        padLeft = Float64, padTop = Float64, padRight = Float64, padBottom = Float64,
        width = SizeSpec, height = SizeSpec,
        mainAlign = MainAlign, crossAlign = CrossAlign,
        wrap = Bool,
        abs = Option[Vec2.Vec2]
    }

    /// 既定スタイル。縦並び・gap0・pad0・Auto×Auto・Start/Start・折り返しなし・フロー内。
    pub def defaultStyle(): Style =
        {dir = Dir.Column, gap = 0.0,
         padLeft = 0.0, padTop = 0.0, padRight = 0.0, padBottom = 0.0,
         width = SizeSpec.Auto, height = SizeSpec.Auto,
         mainAlign = MainAlign.Start, crossAlign = CrossAlign.Start,
         wrap = false,
         abs = None}

    /// レイアウト解決アルゴリズム全体が引き回す入力の束。パス1・パス2の内部ヘルパーが
    /// すべて同じ 5 つを引きずるため、1 レコードにまとめて名前渡しする。
    /// `styles`: 各 entity のレイアウト属性。
    /// `parents`: 子→親（root は非在）。
    /// `order`: 兄弟内の並び順。
    /// `measures`: テキスト等の実寸（内在サイズ解決の葉値に使う）。
    /// `visible`: 各 entity の設定可視（継承前）。visible=false の entity はその部分木ごと
    /// フローから除外する（CSS の display:none 相当）。未登録の entity は可視扱い。
    pub type alias LayoutInput = {
        styles   = Map[EntityId, Style],
        parents  = Map[EntityId, EntityId],
        order    = Map[EntityId, Int32],
        measures = Map[EntityId, Vec2.Vec2],
        visible  = Map[EntityId, Bool]
    }

    /// パス1・パス2 の内部ヘルパーが引き回す入力。LayoutInput の parents / order は
    /// 入口で `kids`（親 → 子の一覧・order 昇順）に畳んであるので、ここには残さない。
    /// 子を持たない親は kids に載らない（引く側は空リスト扱いにする）。
    type alias IndexedInput = {
        styles   = Map[EntityId, Style],
        measures = Map[EntityId, Vec2.Vec2],
        visible  = Map[EntityId, Bool],
        kids     = Map[EntityId, List[EntityId]]
    }

    // ========================================================================
    // 公開 API
    // ========================================================================

    /// レイアウトを解決し、各 entity の画面絶対矩形を返す。
    /// root には rootRect（viewport 等）をそのまま割り当て、子孫へ再帰配置する。
    pub def computeLayout(input: LayoutInput, root: EntityId, rootRect: Rect2.Rect2): Map[EntityId, Rect2.Rect2] =
        let indexed = ({styles = input#styles, measures = input#measures, visible = input#visible,
                        kids = buildChildIndex(input)}: IndexedInput);
        assignRect(root, rootRect, indexed, Map.empty())

    /// 「親 → 子の一覧（order 昇順）」の索引。
    /// UiHierarchy にも同じ物があるが、あちらは private なのでここでも作る（pub 面を増やさない）。
    def buildChildIndex(input: LayoutInput): Map[EntityId, List[EntityId]] =
        input#parents
            |> Map.foldLeftWithKey((acc, id, p) -> Map.insertWith((_, kids) -> id :: kids, p, id :: Nil, acc), Map.empty())
            |> Map.map(kids -> List.sortBy(id -> Option.getWithDefault(0, Map.get(id, input#order)), kids))

    /// 可視な子だけを order 順に返す（visible=false の子はレイアウトから除外＝display:none 相当）。
    /// visible 未登録の子は可視扱い。フロー内・フロー外（abs）を問わず、隠した子は配置対象から外れる。
    def visibleChildrenOf(id: EntityId, input: IndexedInput): List[EntityId] =
        Option.getWithDefault(Nil, Map.get(id, input#kids))
            |> List.filter(child -> Option.getWithDefault(true, Map.get(child, input#visible)))

    // ========================================================================
    // パス1: 内在サイズ
    // ========================================================================

    /// entity の内在サイズ（幅・高さ）。width/height が Px なら固定値、
    /// それ以外（Auto/Grow）はコンテンツ由来サイズを使う。
    def intrinsicSizeOf(id: EntityId, input: IndexedInput): Vec2.Vec2 =
        let style = styleOf(id, input#styles);
        let content = contentSizeOf(id, style, input);
        {x = axisIntrinsic(style#width, content#x), y = axisIntrinsic(style#height, content#y)}

    /// 軸のサイズ指定から内在サイズを取り出す。Px は固定値、Auto/Grow はコンテンツ値。
    def axisIntrinsic(spec: SizeSpec, content: Float64): Float64 =
        match spec {
            case SizeSpec.Px(v) => v
            case SizeSpec.Auto  => content
            case SizeSpec.Grow(_) => content
        }

    /// entity のコンテンツ由来サイズ（パディング込み）。
    /// 子を持たなければテキスト実寸（無ければ 0）、持てば主軸に沿った子の合計 + gap、交差軸は子の最大。
    /// abs=Some の子はフロー外なのでコンテンツ集計に含めない。
    def contentSizeOf(id: EntityId, style: Style, input: IndexedInput): Vec2.Vec2 =
        let flowChildren = visibleChildrenOf(id, input)
            |> List.filter(child -> Option.isEmpty(styleOf(child, input#styles)#abs));
        let inner = match flowChildren {
            case Nil => Option.getWithDefault({x = 0.0, y = 0.0}, Map.get(id, input#measures))
            case _   =>
                let childSizes = List.map(child -> intrinsicSizeOf(child, input), flowChildren);
                let mains = List.map(sz -> mainOf(style#dir, sz), childSizes);
                let crosses = List.map(sz -> crossOf(style#dir, sz), childSizes);
                let mainTotal = List.foldLeft((acc, m) -> acc + m, 0.0, mains)
                              + style#gap * Int32.toFloat64(Int32.max(0, List.length(flowChildren) - 1));
                let crossMax = List.foldLeft((acc, c) -> Float64.max(acc, c), 0.0, crosses);
                fromMainCross(style#dir, mainTotal, crossMax)
        };
        {x = inner#x + style#padLeft + style#padRight, y = inner#y + style#padTop + style#padBottom}

    // ========================================================================
    // パス2: 実 rect 割当
    // ========================================================================

    /// entity に rect を確定し、子孫へ再帰的に配置していく。
    def assignRect(id: EntityId, rect: Rect2.Rect2, input: IndexedInput,
                   acc: Map[EntityId, Rect2.Rect2]): Map[EntityId, Rect2.Rect2] =
        let acc1 = Map.insert(id, rect, acc);
        let style = styleOf(id, input#styles);
        // 隠した子（visible=false）はその部分木ごと配置しない（display:none）。
        let children = visibleChildrenOf(id, input);
        // コンテンツ領域 = rect からパディングを引いた内側
        let contentPos = {x = rect#position#x + style#padLeft, y = rect#position#y + style#padTop};
        let contentSize = {x = rect#size#x - style#padLeft - style#padRight,
                           y = rect#size#y - style#padTop - style#padBottom};
        // フロー内 / フロー外（abs）に分ける
        let (flowChildren, absChildren) = List.partition(child -> Option.isEmpty(styleOf(child, input#styles)#abs), children);
        let acc2 = if (style#wrap and style#dir == Dir.Row)
                       layoutWrap(style, contentPos, contentSize, flowChildren, input, acc1)
                   else
                       layoutFlow(style, contentPos, contentSize, flowChildren, input, acc1);
        List.foldLeft((a, child) -> layoutAbs(child, contentPos, input, a), acc2, absChildren)

    /// フロー内の子を主軸に沿って配置する。
    def layoutFlow(style: Style, contentPos: Vec2.Vec2, contentSize: Vec2.Vec2, flowChildren: List[EntityId],
                   input: IndexedInput, acc: Map[EntityId, Rect2.Rect2]): Map[EntityId, Rect2.Rect2] =
        let dir = style#dir;
        let contentMain = mainOf(dir, contentSize);
        let contentCross = crossOf(dir, contentSize);
        let count = List.length(flowChildren);
        // 子ごとの主軸ベースサイズと Grow 重みを求める
        let bases = List.map(child -> baseMainOf(child, dir, input), flowChildren);
        let sumBase = List.foldLeft((acc2, entry) -> acc2 + fst(entry), 0.0, bases);
        let totalWeight = List.foldLeft((acc2, entry) -> acc2 + snd(entry), 0.0, bases);
        let gapTotal = style#gap * Int32.toFloat64(Int32.max(0, count - 1));
        let free = contentMain - sumBase - gapTotal;
        // Grow があれば余りを重み配分、無ければ mainAlign で開始位置・間隔を決める
        let (startOffset, effectiveGap) = flowSpacing(style#mainAlign, style#gap, free, totalWeight, count);
        let childList = List.zip(flowChildren, bases);
        let result = List.foldLeft((st, pair) -> {
            let (child, base) = pair;
            let (baseMain, weight) = base;
            let mainSize = if (totalWeight > 0.0) baseMain + growShare(weight, totalWeight, free) else baseMain;
            let crossSize = crossSizeOf(child, dir, style#crossAlign, contentCross, input);
            let crossOffset = crossOffsetFor(style#crossAlign, contentCross, crossSize);
            let childPos = fromMainCross(dir,
                                          mainOf(dir, contentPos) + st#pen,
                                          crossOf(dir, contentPos) + crossOffset);
            let childSize = fromMainCross(dir, mainSize, crossSize);
            let childRect: Rect2.Rect2 = {position = childPos, size = childSize};
            let newAcc = assignRect(child, childRect, input, st#acc);
            {pen = st#pen + mainSize + effectiveGap, acc = newAcc}
        }, {pen = startOffset, acc = acc}, childList);
        result#acc

    /// 折り返し配置（Row + wrap）。子を内在サイズで左から詰め、幅に収まらなくなったら
    /// 次の行へ。行の高さはその行の子の最大。行内は左詰め（mainAlign / crossAlign は効かない）。
    /// Grow も使わない（幅が確定している前提）。
    def layoutWrap(style: Style, contentPos: Vec2.Vec2, contentSize: Vec2.Vec2, flowChildren: List[EntityId],
                   input: IndexedInput, acc: Map[EntityId, Rect2.Rect2]): Map[EntityId, Rect2.Rect2] =
        let sized = List.map(child -> (child, intrinsicSizeOf(child, input)), flowChildren);
        let rows = splitRows(style#gap, contentSize#x, sized);
        let result = List.foldLeft((st, row) -> {
            let rowHeight = row |> List.foldLeft((h, entry) -> {
                let (_, size) = entry;
                Float64.max(h, size#y)
            }, 0.0);
            let rowAcc = List.foldLeft((rs, entry) -> {
                let (child, size) = entry;
                let childRect: Rect2.Rect2 = {
                    position = { x = contentPos#x + rs#pen, y = contentPos#y + st#top },
                    size = size };
                { pen = rs#pen + size#x + style#gap,
                  acc = assignRect(child, childRect, input, rs#acc) }
            }, {pen = 0.0, acc = st#acc}, row);
            { top = st#top + rowHeight + style#gap, acc = rowAcc#acc }
        }, {top = 0.0, acc = acc}, rows);
        result#acc

    /// (子, 内在サイズ) の列を「幅に収まるだけ」の行に切る。
    /// 1 個も入らない幅でも行に 1 個は入れる（無限行を防ぐ）。
    def splitRows(gap: Float64, maxWidth: Float64,
                  sized: List[(EntityId, Vec2.Vec2)]): List[List[(EntityId, Vec2.Vec2)]] =
        let folded = List.foldLeft((st, entry) -> {
            let (_, size) = entry;
            let nextPen = if (List.isEmpty(st#row)) size#x else st#pen + gap + size#x;
            if (nextPen > maxWidth and not List.isEmpty(st#row))
                { rows = List.reverse(st#row) :: st#rows, row = entry :: Nil, pen = size#x }
            else
                { rows = st#rows, row = entry :: st#row, pen = nextPen }
        }, {rows = Nil, row = Nil, pen = 0.0}, sized);
        let lastRows = if (List.isEmpty(folded#row)) folded#rows
                       else List.reverse(folded#row) :: folded#rows;
        List.reverse(lastRows)

    /// フロー外（abs）の子を親コンテンツ原点 + オフセットに内在サイズで配置する。
    def layoutAbs(child: EntityId, contentPos: Vec2.Vec2, input: IndexedInput,
                  acc: Map[EntityId, Rect2.Rect2]): Map[EntityId, Rect2.Rect2] =
        let offset = Option.getWithDefault({x = 0.0, y = 0.0}, styleOf(child, input#styles)#abs);
        let size = intrinsicSizeOf(child, input);
        let rect: Rect2.Rect2 = {position = {x = contentPos#x + offset#x, y = contentPos#y + offset#y}, size = size};
        assignRect(child, rect, input, acc)

    /// mainAlign と余り（free）から、先頭オフセットと実効間隔を決める。
    /// Grow がある（totalWeight>0）ときは詰めて配置し、間隔は宣言 gap のまま。
    def flowSpacing(mainAlign: MainAlign, gap: Float64, free: Float64, totalWeight: Float64, count: Int32): (Float64, Float64) =
        if (totalWeight > 0.0) (0.0, gap)
        else {
            let leftover = Float64.max(0.0, free);
            match mainAlign {
                case MainAlign.Start        => (0.0, gap)
                case MainAlign.Center       => (leftover / 2.0, gap)
                case MainAlign.End          => (leftover, gap)
                case MainAlign.SpaceBetween =>
                    if (count > 1) (0.0, gap + leftover / Int32.toFloat64(count - 1)) else (0.0, gap)
            }
        }

    /// Grow 子が受け取る余りの取り分。
    def growShare(weight: Float64, totalWeight: Float64, free: Float64): Float64 =
        if (totalWeight > 0.0) Float64.max(0.0, free) * (weight / totalWeight) else 0.0

    /// 子の主軸ベースサイズと Grow 重みの組。Px は固定値、Auto は内在サイズ、Grow は base0 + 重み。
    def baseMainOf(child: EntityId, dir: Dir, input: IndexedInput): (Float64, Float64) =
        match mainSpecOf(dir, styleOf(child, input#styles)) {
            case SizeSpec.Px(v)   => (v, 0.0)
            case SizeSpec.Auto    => (mainOf(dir, intrinsicSizeOf(child, input)), 0.0)
            case SizeSpec.Grow(w) => (0.0, w)
        }

    /// 子の交差軸サイズ。Stretch なら親の交差サイズいっぱい、それ以外は子の指定（Px/Auto/Grow）に従う。
    def crossSizeOf(child: EntityId, dir: Dir, crossAlign: CrossAlign, contentCross: Float64,
                    input: IndexedInput): Float64 =
        match crossAlign {
            case CrossAlign.Stretch => contentCross
            case _ => match crossSpecOf(dir, styleOf(child, input#styles)) {
                case SizeSpec.Px(v)   => v
                case SizeSpec.Auto    => crossOf(dir, intrinsicSizeOf(child, input))
                case SizeSpec.Grow(_) => crossOf(dir, intrinsicSizeOf(child, input))
            }
        }

    /// 交差軸方向の寄せオフセット。
    def crossOffsetFor(crossAlign: CrossAlign, contentCross: Float64, crossSize: Float64): Float64 =
        match crossAlign {
            case CrossAlign.Start   => 0.0
            case CrossAlign.Center  => (contentCross - crossSize) / 2.0
            case CrossAlign.End     => contentCross - crossSize
            case CrossAlign.Stretch => 0.0
        }

    // ========================================================================
    // 軸ヘルパ
    // ========================================================================

    /// entity の Style（未登録なら defaultStyle）。
    def styleOf(id: EntityId, styles: Map[EntityId, Style]): Style =
        Option.getWithDefault(defaultStyle(), Map.get(id, styles))

    /// 主軸方向の成分。Row なら X、Column なら Y。
    def mainOf(dir: Dir, v: Vec2.Vec2): Float64 =
        match dir { case Dir.Row => v#x, case Dir.Column => v#y }

    /// 交差軸方向の成分。Row なら Y、Column なら X。
    def crossOf(dir: Dir, v: Vec2.Vec2): Float64 =
        match dir { case Dir.Row => v#y, case Dir.Column => v#x }

    /// 主軸値・交差軸値から Vec2 を組む（mainOf / crossOf の逆）。
    def fromMainCross(dir: Dir, main: Float64, cross: Float64): Vec2.Vec2 =
        match dir { case Dir.Row => {x = main, y = cross}, case Dir.Column => {x = cross, y = main} }

    /// 主軸方向のサイズ指定。
    def mainSpecOf(dir: Dir, style: Style): SizeSpec =
        match dir { case Dir.Row => style#width, case Dir.Column => style#height }

    /// 交差軸方向のサイズ指定。
    def crossSpecOf(dir: Dir, style: Style): SizeSpec =
        match dir { case Dir.Row => style#height, case Dir.Column => style#width }

    def fst(pair: (a, b)): a = let (x, _) = pair; x
    def snd(pair: (a, b)): b = let (_, y) = pair; y
}
