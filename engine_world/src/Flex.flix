// Flex — 宣言的なノード木を UiLayout（flexbox 風・純関数）でレイアウトし、
// Render.PlacedItem の列に落とす薄い汎用層。UI ストア（UiSpec/UiStore の entity 木）を
// 介さずに「毎フレーム View が組み立てる」使い方へ UiLayout の語彙を開放する。
// 利用例: ギャラリーの行組み / HUD の横並び / ラベル付きセルの格子。
//
// 木は 2 種類のノードだけ:
//   Leaf = 実寸（size）を持つ描画物。レイアウト確定後、割り当てられた rect を draw が受け取る。
//   Box  = 子を UiLayout.Style（方向・gap・pad・寄せ・サイズ指定）で並べる容器。
//
// 内部は DFS で EntityId（= Int32 の透明 alias）を採番して LayoutInput を組み、
// UiLayout.computeLayout に解決を委譲する。レイアウト計算そのものはここでは持たない。
//
// 注意:
//   - Leaf に style は登録しない（defaultStyle + measures 登録で内在サイズ扱いになる）。
//     Grow させたい葉は box({width = Grow(w) | ...}, leaf :: Nil) で包む。
//   - root ノードのサイズ指定は place の rootRect に上書きされる（computeLayout は root に
//     rootRect をそのまま割り当てる）。root の style は dir / pad / 寄せだけ意味を持つ。
//   - Column の子を親幅いっぱいに広げたいときは親に crossAlign = Stretch（既定 Start では
//     子は自分の内在幅に縮む）。

pub mod Flex {

    /// レイアウトノード。Leaf = 実寸つき描画物、Box = 子を並べる容器、
    /// Keyed = 中身にラベルを付ける透明な包み（場所を取らず、レイアウトにも影響しない）。
    /// Box の draw は「自分の rect を描いてから子を載せる」容器用（ui.json の panel 相当）。
    pub enum Node {
        case Leaf({ size = Vec2.Vec2, draw = Rect2.Rect2 -> List[Render.PlacedItem] })
        case Box({ style = UiLayout.Style,
                   draw = Option[Rect2.Rect2 -> List[Render.PlacedItem]],
                   children = List[Node] })
        case Keyed({ key = String, inner = Node })
    }

    /// 実寸 size の葉。draw はレイアウト確定後の rect（左上原点）を受け取る。
    pub def leaf(size: Vec2.Vec2, draw: Rect2.Rect2 -> List[Render.PlacedItem]): Node =
        Node.Leaf({ size = size, draw = draw })

    /// 「中心座標を受けて描く」既存語彙（Render.*At 系）をそのまま挿せる近道。
    pub def leafAtCenter(size: Vec2.Vec2, make: Vec2.Vec2 -> List[Render.PlacedItem]): Node =
        leaf(size, r -> make(Rect2.center(r)))

    /// style で子を並べる容器。
    pub def box(style: UiLayout.Style, children: List[Node]): Node =
        Node.Box({ style = style, draw = None, children = children })

    /// 自分の rect も描く容器（背景パネル + 子、の形）。draw の出力は子より先に並ぶ
    /// （重なりは zIndex が決める）。
    pub def boxDrawn(style: UiLayout.Style, draw: Rect2.Rect2 -> List[Render.PlacedItem],
                     children: List[Node]): Node =
        Node.Box({ style = style, draw = Some(draw), children = children })

    /// 中身にラベルを付ける（レイアウトには影響しない）。rectsOf / placeWithRects が
    /// 「ラベル → 画面上の矩形」を返すので、描く側と当たりを見る側が同じ宣言を読める。
    /// 同じラベルを 2 つ付けたら後の方が勝つ（呼び側が一意にする責任）。
    pub def keyed(key: String, node: Node): Node =
        Node.Keyed({ key = key, inner = node })

    /// 縦並びの既定 style（= UiLayout.defaultStyle）。`{... | Flex.columnStyle()}` で上書きする。
    pub def columnStyle(): UiLayout.Style =
        UiLayout.defaultStyle()

    /// 横並びの既定 style。
    pub def rowStyle(): UiLayout.Style =
        { dir = UiLayout.Dir.Row | UiLayout.defaultStyle() }

    /// 木を rootRect に敷いてレイアウトを解決し、各 Leaf の draw を rect で呼んで連結する。
    /// 出力順は木の DFS 順（重なりは zIndex が決めるので、順序は再現性のための固定）。
    pub def place(root: Node, rootRect: Rect2.Rect2): List[Render.PlacedItem] =
        fst(placeWithRects(root, rootRect))

    /// place と同じ描画物に加えて「ラベル → 矩形」の表も返す。1 回のレイアウトで
    /// 描画と当たり判定の両方を賄うための関数（2 度敷くと座標が二重管理になる）。
    pub def placeWithRects(root: Node, rootRect: Rect2.Rect2):
            (List[Render.PlacedItem], Map[String, Rect2.Rect2]) =
        let (leaves, rects, keys) = resolveTree(root, rootRect);
        let items = leaves |> List.flatMap(entry -> {
            let (id, draw) = entry;
            match Map.get(id, rects) {
                case Some(r) => draw(r)
                case None    => Nil
            }
        });
        (items, namedRects(keys, rects))

    /// ラベルの付いたノードの矩形だけを引く（描かずに場所だけ知りたいとき）。
    pub def rectsOf(root: Node, rootRect: Rect2.Rect2): Map[String, Rect2.Rect2] =
        let (_, rects, keys) = resolveTree(root, rootRect);
        namedRects(keys, rects)

    def namedRects(keys: Map[String, EntityId], rects: Map[EntityId, Rect2.Rect2]):
            Map[String, Rect2.Rect2] =
        Map.foldLeftWithKey((acc, key, id) -> match Map.get(id, rects) {
            case Some(r) => Map.insert(key, r, acc)
            case None    => acc
        }, Map.empty(), keys)

    /// 各 Leaf に割り当てられた rect を DFS 順で返す（レイアウトだけ検分したいとき・テスト用）。
    pub def leafRects(root: Node, rootRect: Rect2.Rect2): List[Rect2.Rect2] =
        let (leaves, rects, _keys) = resolveTree(root, rootRect);
        leaves |> List.filterMap(entry -> { let (id, _) = entry; Map.get(id, rects) })

    // ── 内部 ──

    /// 木の走査で積む状態。leaves は前置で積むので DFS の逆順（solve が反転して返す）。
    type alias Acc = {
        nextId   = Int32,
        styles   = Map[EntityId, UiLayout.Style],
        parents  = Map[EntityId, EntityId],
        order    = Map[EntityId, Int32],
        measures = Map[EntityId, Vec2.Vec2],
        leaves   = List[(EntityId, Rect2.Rect2 -> List[Render.PlacedItem])],
        keys     = Map[String, EntityId]
    }

    def emptyAcc(): Acc =
        { nextId = 0, styles = Map.empty(), parents = Map.empty(), order = Map.empty(),
          measures = Map.empty(), leaves = Nil, keys = Map.empty() }

    /// 採番済みの木を computeLayout に掛け、(DFS 順の Leaf 列, id → rect) を返す。
    /// （solve は Flix の予約語なので resolveTree）
    def resolveTree(root: Node, rootRect: Rect2.Rect2):
            (List[(EntityId, Rect2.Rect2 -> List[Render.PlacedItem])],
             Map[EntityId, Rect2.Rect2], Map[String, EntityId]) =
        let (rootId, acc) = build(root, emptyAcc());
        let input = { styles = acc#styles, parents = acc#parents, order = acc#order,
                      measures = acc#measures, visible = Map.empty() };
        (List.reverse(acc#leaves), UiLayout.computeLayout(input, rootId, rootRect), acc#keys)

    /// DFS で id を採番しつつ LayoutInput の素材を積む。自分の id と更新後の Acc を返す。
    def build(node: Node, acc: Acc): (EntityId, Acc) =
        let id = acc#nextId;
        match node {
            case Node.Leaf(l) =>
                (id, { nextId   = id + 1,
                       measures = Map.insert(id, l#size, acc#measures),
                       leaves   = (id, l#draw) :: acc#leaves | acc })
            case Node.Keyed(k) =>
                // ラベルは場所を取らない: id を消費せず、中身に付いた id をラベルに結び付ける。
                let (innerId, acc1) = build(k#inner, acc);
                (innerId, { keys = Map.insert(k#key, innerId, acc1#keys) | acc1 })
            case Node.Box(b) =>
                let leaves1 = match b#draw {
                    case Some(d) => (id, d) :: acc#leaves
                    case None    => acc#leaves
                };
                let opened = { nextId = id + 1,
                               styles = Map.insert(id, b#style, acc#styles),
                               leaves = leaves1 | acc };
                let (_, closed) = List.foldLeft((st, child) -> {
                    let (i, a) = st;
                    let (childId, a1) = build(child, a);
                    (i + 1, { parents = Map.insert(childId, id, a1#parents),
                              order   = Map.insert(childId, i, a1#order) | a1 })
                }, (0, opened), b#children);
                (id, closed)
        }
}
