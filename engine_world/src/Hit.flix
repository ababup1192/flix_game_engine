// Hit — CollisionShape2D とは別実装。こちらは宣言用の 2 形状（円・箱）に限定し、
// 境界規則を「ちょうど接するのは外」で統一した照会専用。位置の解決（押し出し・反射）は Physics2D の仕事。

pub mod Hit {

    /// 当たりの形 1 個。dx/dy は持ち主の位置からのずれ（px）で、錨（中心か足元か）は絵に従う。
    pub enum HitShape {
        case CircleH({ dx = Float64, dy = Float64, r = Float64 })
        case BoxH({ dx = Float64, dy = Float64, w = Float64, h = Float64 })
    }

    /// 当たり判定に置く物 1 個。tag は当たったとき返してほしい値（敵そのもの等）。
    pub type alias Body[a] = { tag = a, pos = Vec2.Vec2, shapes = List[HitShape] }

    /// 1対1の判定。posA に置いた shapesA と posB に置いた shapesB がどこかで重なるか。
    /// 形の列どうしなので「先端の箱だけ当たる」ような複数形もこの 1 つの関数で聞ける。
    pub def overlaps(posA: Vec2.Vec2, shapesA: List[HitShape],
                     posB: Vec2.Vec2, shapesB: List[HitShape]): Bool =
        List.exists(a -> List.exists(b -> shapeOverlap(posA, a, posB, b), shapesB), shapesA)

    /// pos に置いた shapes に最初に触れている body の tag（無ければ None）。
    /// first はリスト順で最初に触れている物（最も近い物ではない）。判定は O(n) の総当り。
    /// tag は Body を組んだ時点の値 — 列を作ってから World を変えた場合、tag は古い値のまま。
    pub def firstHit(pos: Vec2.Vec2, shapes: List[HitShape], bodies: List[Body[a]]): Option[a] =
        bodies
            |> List.find(b -> overlaps(pos, shapes, b#pos, b#shapes))
            |> Option.map(b -> b#tag)

    /// pos に置いた shapes に触れている全 body の tag。
    pub def hits(pos: Vec2.Vec2, shapes: List[HitShape], bodies: List[Body[a]]): List[a] =
        bodies
            |> List.filter(b -> overlaps(pos, shapes, b#pos, b#shapes))
            |> List.map(b -> b#tag)

    /// pos に置いた shapes がどれかに触れているか。
    pub def anyHit(pos: Vec2.Vec2, shapes: List[HitShape], bodies: List[Body[a]]): Bool =
        List.exists(b -> overlaps(pos, shapes, b#pos, b#shapes), bodies)

    /// 宣言した寸法を Physics2D 系の Store に流すための変換。オフセットは呼び側が位置に足す。
    pub def toCollisionShape(shape: HitShape): (Vec2.Vec2, CollisionShape2D) =
        match shape {
            case HitShape.CircleH(c) =>
                ({ x = c#dx, y = c#dy }, CollisionShape2D.CircleShape2D({ radius = c#r }))
            case HitShape.BoxH(b) =>
                ({ x = b#dx, y = b#dy }, CollisionShape2D.RectShape2D({ width = b#w, height = b#h }))
        }

    // ── 形 1 個どうしの判定（3 通りの純関数） ──

    /// 形 1 個どうしの重なり。組は 3 通りで、箱×円は引数を入れ替えて円×箱に落とす。
    def shapeOverlap(posA: Vec2.Vec2, a: HitShape, posB: Vec2.Vec2, b: HitShape): Bool =
        match (a, b) {
            case (HitShape.CircleH(ca), HitShape.CircleH(cb)) =>
                circleCircle(at(posA, ca#dx, ca#dy), ca#r, at(posB, cb#dx, cb#dy), cb#r)
            case (HitShape.CircleH(ca), HitShape.BoxH(bb)) =>
                circleBox(at(posA, ca#dx, ca#dy), ca#r, at(posB, bb#dx, bb#dy), bb#w, bb#h)
            case (HitShape.BoxH(ba), HitShape.CircleH(cb)) =>
                circleBox(at(posB, cb#dx, cb#dy), cb#r, at(posA, ba#dx, ba#dy), ba#w, ba#h)
            case (HitShape.BoxH(ba), HitShape.BoxH(bb)) =>
                boxBox(at(posA, ba#dx, ba#dy), ba#w, ba#h, at(posB, bb#dx, bb#dy), bb#w, bb#h)
        }

    /// 持ち主の位置 pos から dx/dy だけずらした、形自身の中心。
    def at(pos: Vec2.Vec2, dx: Float64, dy: Float64): Vec2.Vec2 =
        { x = pos#x + dx, y = pos#y + dy }

    /// 円×円: 中心間の距離が半径の和より短ければ当たり（ちょうど接するのは外）。
    pub def circleCircle(ca: Vec2.Vec2, ra: Float64, cb: Vec2.Vec2, rb: Float64): Bool =
        Vec2.distanceSquaredTo(ca, cb) < (ra + rb) * (ra + rb)

    /// 円×箱: 箱の中で円の中心に最も近い点（軸ごとのクランプ）までの距離が半径より
    /// 短ければ当たり。中心が箱の中ならその点は中心自身で、距離 0 = 必ず当たる。
    def circleBox(c: Vec2.Vec2, r: Float64, bc: Vec2.Vec2, w: Float64, h: Float64): Bool =
        let nearest = { x = Num.clamp(bc#x - w / 2.0, bc#x + w / 2.0, c#x),
                        y = Num.clamp(bc#y - h / 2.0, bc#y + h / 2.0, c#y) };
        Vec2.distanceSquaredTo(c, nearest) < r * r

    /// 箱×箱: 軸ごとに中心間のずれが半分幅の和より小さければ当たり（AABB）。
    /// HitShape を組まずに素の中心＋幅高で聞ける口 — タイルやプレイヤーの当たり箱など
    /// 「形が 1 個で決まっている」照会はこちらが素直。境界規則は本体と同じ
    /// 「ちょうど接するのは外」（足元のタイルには置ける・触れて初めて被弾する）。
    pub def boxBox(ca: Vec2.Vec2, wa: Float64, ha: Float64,
                   cb: Vec2.Vec2, wb: Float64, hb: Float64): Bool =
        Float64.abs(ca#x - cb#x) < (wa + wb) / 2.0 and
        Float64.abs(ca#y - cb#y) < (ha + hb) / 2.0

    /// 点×箱: 点が中心 c・幅 w・高さ h の箱の中か（縁の上は外 — boxBox の点版）。
    pub def pointBox(p: Vec2.Vec2, c: Vec2.Vec2, w: Float64, h: Float64): Bool =
        boxBox(p, 0.0, 0.0, c, w, h)
}
