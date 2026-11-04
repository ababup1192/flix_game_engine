/// 当たり判定に使う 2D の幾何形状（矩形・円・カプセル・坂・多角形）。
/// 形状の組み合わせを気にせず checkOverlap 1 つで判定できる。
///
/// すべての判定関数は形状の **中心座標** を基準として受け取る
/// （PolygonShape2D だけは「中心」でなく作者が決めたローカル原点）。
pub enum CollisionShape2D {
    /// 軸平行の矩形
    case RectShape2D({width = Float64, height = Float64})
    /// 円
    case CircleShape2D({radius = Float64})
    /// カプセル（両端が半円の細長い形）
    /// radius: 半円の半径
    /// height: カプセル全体の高さ（両端の半円を含む）
    /// vertical: true なら縦長、false なら横長
    case CapsuleShape2D({radius = Float64, height = Float64, vertical = Bool})
    /// 坂（直角三角形の床）。底辺が下・直角も下側にあり、斜辺が上面になる。
    /// width / height: 外接箱の幅と高さ（判定関数に渡す中心座標はこの外接箱の中心）
    /// riseRight: true なら右へ登る坂、false なら左へ登る坂
    case SlopeShape2D({width = Float64, height = Float64, riseRight = Bool})
    /// 単純多角形（自己交差しない・凹あり可・回転なし）。静的地形向け。
    /// points は判定関数に渡す pos を原点とするローカル座標の頂点列（3 点以上・巻き順は不問）。
    case PolygonShape2D({points = List[Vec2.Vec2]})
}

pub mod CollisionShape2D {

    // ========================================================================
    // 汎用オーバーラップ判定
    // ========================================================================

    /// 2 つの形状が重なっているか判定する。
    /// posA / posB は各形状の中心座標。
    pub def checkOverlap(posA: Vec2.Vec2, shapeA: CollisionShape2D,
                          posB: Vec2.Vec2, shapeB: CollisionShape2D): Bool =
        match (shapeA, shapeB) {
            // Rect vs Rect
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.RectShape2D(rb)) =>
                checkRectRect(posA, {x = ra#width, y = ra#height},
                              posB, {x = rb#width, y = rb#height})
            // Circle vs Circle
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.CircleShape2D(cb)) =>
                checkCircleCircle(posA, ca#radius, posB, cb#radius)
            // Circle vs Rect
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.RectShape2D(rb)) =>
                checkCircleRect(posA, ca#radius, posB, {x = rb#width, y = rb#height})
            // Rect vs Circle
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.CircleShape2D(cb)) =>
                checkCircleRect(posB, cb#radius, posA, {x = ra#width, y = ra#height})
            // Capsule vs Circle
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.CircleShape2D(cb)) =>
                checkCapsuleCircle(posA, ca#radius, ca#height, ca#vertical, posB, cb#radius)
            // Circle vs Capsule
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.CapsuleShape2D(cb)) =>
                checkCapsuleCircle(posB, cb#radius, cb#height, cb#vertical, posA, ca#radius)
            // Capsule vs Rect
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.RectShape2D(rb)) =>
                checkCapsuleRect(posA, ca#radius, ca#height, ca#vertical,
                                 posB, {x = rb#width, y = rb#height})
            // Rect vs Capsule
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.CapsuleShape2D(cb)) =>
                checkCapsuleRect(posB, cb#radius, cb#height, cb#vertical,
                                 posA, {x = ra#width, y = ra#height})
            // Capsule vs Capsule
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.CapsuleShape2D(cb)) =>
                checkCapsuleCapsule(posA, ca#radius, ca#height, ca#vertical,
                                    posB, cb#radius, cb#height, cb#vertical)
            // Circle vs Slope
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.SlopeShape2D(sb)) =>
                checkCircleSlope(posA, ca#radius,
                                 posB, {x = sb#width, y = sb#height}, sb#riseRight)
            // Slope vs Circle
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.CircleShape2D(cb)) =>
                checkCircleSlope(posB, cb#radius,
                                 posA, {x = sa#width, y = sa#height}, sa#riseRight)
            // Capsule vs Slope
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.SlopeShape2D(sb)) =>
                checkCapsuleSlope(posA, ca#radius, ca#height, ca#vertical,
                                  posB, {x = sb#width, y = sb#height}, sb#riseRight)
            // Slope vs Capsule
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.CapsuleShape2D(cb)) =>
                checkCapsuleSlope(posB, cb#radius, cb#height, cb#vertical,
                                  posA, {x = sa#width, y = sa#height}, sa#riseRight)
            // Rect vs Slope（外接箱で近似 — 静的地形同士は分離しないため厳密判定は持たない）
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.SlopeShape2D(sb)) =>
                checkRectRect(posA, {x = ra#width, y = ra#height},
                              posB, {x = sb#width, y = sb#height})
            // Slope vs Rect（外接箱で近似）
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.RectShape2D(rb)) =>
                checkRectRect(posA, {x = sa#width, y = sa#height},
                              posB, {x = rb#width, y = rb#height})
            // Slope vs Slope（外接箱で近似）
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.SlopeShape2D(sb)) =>
                checkRectRect(posA, {x = sa#width, y = sa#height},
                              posB, {x = sb#width, y = sb#height})
            // Circle vs Polygon
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.PolygonShape2D(pb)) =>
                checkCirclePolygon(posA, ca#radius, posB, pb#points)
            // Polygon vs Circle
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.CircleShape2D(cb)) =>
                checkCirclePolygon(posB, cb#radius, posA, pa#points)
            // Capsule vs Polygon
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.PolygonShape2D(pb)) =>
                checkCapsulePolygon(posA, ca#radius, ca#height, ca#vertical, posB, pb#points)
            // Polygon vs Capsule
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.CapsuleShape2D(cb)) =>
                checkCapsulePolygon(posB, cb#radius, cb#height, cb#vertical, posA, pa#points)
            // Rect vs Polygon（外接箱で近似 — 静的地形同士は分離しないため厳密判定は持たない）
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.PolygonShape2D(pb)) =>
                let (centerB, sizeB) = polygonBoundsCenterSize(posB, pb#points);
                checkRectRect(posA, {x = ra#width, y = ra#height}, centerB, sizeB)
            // Polygon vs Rect（外接箱で近似）
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.RectShape2D(rb)) =>
                let (centerA, sizeA) = polygonBoundsCenterSize(posA, pa#points);
                checkRectRect(centerA, sizeA, posB, {x = rb#width, y = rb#height})
            // Slope vs Polygon（外接箱で近似）
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.PolygonShape2D(pb)) =>
                let (centerB, sizeB) = polygonBoundsCenterSize(posB, pb#points);
                checkRectRect(posA, {x = sa#width, y = sa#height}, centerB, sizeB)
            // Polygon vs Slope（外接箱で近似）
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.SlopeShape2D(sb)) =>
                let (centerA, sizeA) = polygonBoundsCenterSize(posA, pa#points);
                checkRectRect(centerA, sizeA, posB, {x = sb#width, y = sb#height})
            // Polygon vs Polygon（外接箱で近似）
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.PolygonShape2D(pb)) =>
                let (centerA, sizeA) = polygonBoundsCenterSize(posA, pa#points);
                let (centerB, sizeB) = polygonBoundsCenterSize(posB, pb#points);
                checkRectRect(centerA, sizeA, centerB, sizeB)
        }

    // ========================================================================
    // 個別形状ペアの判定
    // ========================================================================

    /// AABB 矩形同士の重なり判定。
    /// pos は矩形の中心、size は幅と高さ。
    ///
    ///   posA          posB
    ///    +--+          +--+
    ///    |  |   <-->   |  |
    ///    +--+          +--+
    ///
    pub def checkRectRect(posA: Vec2.Vec2, sizeA: Vec2.Vec2,
                           posB: Vec2.Vec2, sizeB: Vec2.Vec2): Bool =
        let halfA = Vec2.div(sizeA, 2.0);
        let halfB = Vec2.div(sizeB, 2.0);
        (posA#x + halfA#x > posB#x - halfB#x) and
        (posB#x + halfB#x > posA#x - halfA#x) and
        (posA#y + halfA#y > posB#y - halfB#y) and
        (posB#y + halfB#y > posA#y - halfA#y)

    /// 円同士の重なり判定。
    /// pos は円の中心。
    ///
    ///    (A)  <-->  (B)
    ///
    pub def checkCircleCircle(posA: Vec2.Vec2, radiusA: Float64,
                               posB: Vec2.Vec2, radiusB: Float64): Bool =
        let distSq = Vec2.distanceSquaredTo(posA, posB);
        let sumR = radiusA + radiusB;
        distSq < sumR * sumR

    /// 円と矩形の重なり判定。
    /// circlePos は円の中心、rectPos は矩形の中心、rectSize は幅と高さ。
    ///
    ///    (C)     +----+
    ///            |    |
    ///            +----+
    ///
    pub def checkCircleRect(circlePos: Vec2.Vec2, radius: Float64,
                             rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Bool =
        let halfW = rectSize#x / 2.0;
        let halfH = rectSize#y / 2.0;
        let dx = Float64.abs(circlePos#x - rectPos#x);
        let dy = Float64.abs(circlePos#y - rectPos#y);
        if (dx >= halfW + radius) false
        else if (dy >= halfH + radius) false
        else if (dx <= halfW or dy <= halfH) true
        else
            let cornerDx = dx - halfW;
            let cornerDy = dy - halfH;
            cornerDx * cornerDx + cornerDy * cornerDy < radius * radius

    // ========================================================================
    // カプセル形状のヘルパー
    // ========================================================================

    /// カプセルの軸線分の両端点を返す。
    /// カプセルの中心座標 pos から、半径を除いた軸方向の両端を計算する。
    ///
    ///   縦向き (vertical=true):
    ///       (A)        segA = pos + (0, -halfSeg)
    ///       | |
    ///       | |  pos
    ///       | |
    ///       (B)        segB = pos + (0, +halfSeg)
    ///
    ///   横向き (vertical=false):
    ///   (A)------(B)   segA = pos + (-halfSeg, 0)
    ///                  segB = pos + (+halfSeg, 0)
    ///
    pub def capsuleSegment(pos: Vec2.Vec2, radius: Float64, height: Float64,
                            vertical: Bool): (Vec2.Vec2, Vec2.Vec2) =
        let halfSeg = Float64.max(0.0, height / 2.0 - radius);
        if (vertical)
            ({x = pos#x, y = pos#y - halfSeg}, {x = pos#x, y = pos#y + halfSeg})
        else
            ({x = pos#x - halfSeg, y = pos#y}, {x = pos#x + halfSeg, y = pos#y})

    /// 点から線分への最短距離の二乗を返す。
    ///
    ///        * point
    ///       /|
    ///      / |
    ///   segA----segB
    ///
    pub def pointToSegmentDistSq(point: Vec2.Vec2,
                                  segA: Vec2.Vec2, segB: Vec2.Vec2): Float64 =
        let ab = Vec2.sub(segB, segA);
        let ap = Vec2.sub(point, segA);
        let abLenSq = Vec2.lengthSquared(ab);
        if (abLenSq < 0.000001)
            Vec2.distanceSquaredTo(point, segA)
        else
            let t = Float64.max(0.0, Float64.min(1.0, Vec2.dot(ap, ab) / abLenSq));
            let closest = Vec2.add(segA, Vec2.mul(ab, t));
            Vec2.distanceSquaredTo(point, closest)

    /// 二つの 2D 線分が交差しているか判定する。
    /// 外積の符号で交差を判定する。
    def segmentsIntersect(a1: Vec2.Vec2, a2: Vec2.Vec2,
                           b1: Vec2.Vec2, b2: Vec2.Vec2): Bool =
        let d1 = Vec2.cross(Vec2.sub(b2, b1), Vec2.sub(a1, b1));
        let d2 = Vec2.cross(Vec2.sub(b2, b1), Vec2.sub(a2, b1));
        let d3 = Vec2.cross(Vec2.sub(a2, a1), Vec2.sub(b1, a1));
        let d4 = Vec2.cross(Vec2.sub(a2, a1), Vec2.sub(b2, a1));
        (d1 * d2 < 0.0) and (d3 * d4 < 0.0)

    /// 二つの線分間の最短距離の二乗を返す。
    /// 2D 線分が交差する場合は 0 を返す。
    /// それ以外は端点-線分距離の最小値を取る。
    pub def segmentToSegmentDistSq(a1: Vec2.Vec2, a2: Vec2.Vec2,
                                    b1: Vec2.Vec2, b2: Vec2.Vec2): Float64 =
        let ab = Vec2.sub(a2, a1);
        let cd = Vec2.sub(b2, b1);
        let abLenSq = Vec2.lengthSquared(ab);
        let cdLenSq = Vec2.lengthSquared(cd);
        // 両方とも点の場合
        if (abLenSq < 0.000001 and cdLenSq < 0.000001)
            Vec2.distanceSquaredTo(a1, b1)
        // 一方が点の場合
        else if (abLenSq < 0.000001)
            pointToSegmentDistSq(a1, b1, b2)
        else if (cdLenSq < 0.000001)
            pointToSegmentDistSq(b1, a1, a2)
        // 線分が交差している場合
        else if (segmentsIntersect(a1, a2, b1, b2))
            0.0
        else
            // 4 通りの端点-線分距離の最小値を取る
            let d1 = pointToSegmentDistSq(a1, b1, b2);
            let d2 = pointToSegmentDistSq(a2, b1, b2);
            let d3 = pointToSegmentDistSq(b1, a1, a2);
            let d4 = pointToSegmentDistSq(b2, a1, a2);
            Float64.min(Float64.min(d1, d2), Float64.min(d3, d4))

    // ========================================================================
    // カプセル形状の衝突判定
    // ========================================================================

    /// カプセルと円の重なり判定。
    /// カプセルの軸線分と円の中心の距離が、両者の半径の和より小さいかで判定する。
    ///
    ///   (cap)      (circle)
    ///    | |          O
    ///    | |
    ///
    pub def checkCapsuleCircle(capsulePos: Vec2.Vec2, capsuleRadius: Float64,
                                capsuleHeight: Float64, capsuleVertical: Bool,
                                circlePos: Vec2.Vec2, circleRadius: Float64): Bool =
        let (segA, segB) = capsuleSegment(capsulePos, capsuleRadius, capsuleHeight, capsuleVertical);
        let distSq = pointToSegmentDistSq(circlePos, segA, segB);
        let sumR = capsuleRadius + circleRadius;
        distSq < sumR * sumR

    /// カプセルと矩形の重なり判定。
    /// カプセルの軸線分を半径分太らせた領域と矩形の重なりを判定する。
    /// 矩形を半径分膨らませて（ミンコフスキー和）、軸線分との交差を判定する。
    ///
    ///   (cap)   +----+
    ///    | |    |    |
    ///    | |    +----+
    ///
    pub def checkCapsuleRect(capsulePos: Vec2.Vec2, capsuleRadius: Float64,
                              capsuleHeight: Float64, capsuleVertical: Bool,
                              rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Bool =
        let (segA, segB) = capsuleSegment(capsulePos, capsuleRadius, capsuleHeight, capsuleVertical);
        let halfW = rectSize#x / 2.0;
        let halfH = rectSize#y / 2.0;
        // 線分上の矩形中心への最近接点を求める
        let ab = Vec2.sub(segB, segA);
        let abLenSq = Vec2.lengthSquared(ab);
        let ap = Vec2.sub(rectPos, segA);
        let t = if (abLenSq < 0.000001) 0.0
                else Float64.max(0.0, Float64.min(1.0, Vec2.dot(ap, ab) / abLenSq));
        let closest = Vec2.add(segA, Vec2.mul(ab, t));
        let dx = Float64.abs(closest#x - rectPos#x);
        let dy = Float64.abs(closest#y - rectPos#y);
        // 膨張矩形の辺領域（十字部分）にあれば重なる
        if (dx >= halfW + capsuleRadius or dy >= halfH + capsuleRadius) false
        else if (dx <= halfW or dy <= halfH) true
        else
            let cornerDx = dx - halfW;
            let cornerDy = dy - halfH;
            cornerDx * cornerDx + cornerDy * cornerDy < capsuleRadius * capsuleRadius

    /// カプセル同士の重なり判定。
    /// 二つの軸線分の最短距離が、両者の半径の和より小さいかで判定する。
    ///
    ///   (A)     (B)
    ///    | |     | |
    ///    | |     | |
    ///
    pub def checkCapsuleCapsule(posA: Vec2.Vec2, radiusA: Float64,
                                 heightA: Float64, verticalA: Bool,
                                 posB: Vec2.Vec2, radiusB: Float64,
                                 heightB: Float64, verticalB: Bool): Bool =
        let (segA1, segA2) = capsuleSegment(posA, radiusA, heightA, verticalA);
        let (segB1, segB2) = capsuleSegment(posB, radiusB, heightB, verticalB);
        let distSq = segmentToSegmentDistSq(segA1, segA2, segB1, segB2);
        let sumR = radiusA + radiusB;
        distSq < sumR * sumR

    // ========================================================================
    // 坂形状のヘルパー
    // ========================================================================

    /// 坂の 3 頂点を返す（pos は外接箱の中心・y は下向き正）。
    /// riseRight=true なら 左下 A・右下 B・右上 C（右へ登る）、false なら頂点 C が左上（左へ登る）。
    ///
    ///   riseRight=true:      riseRight=false:
    ///           (C)          (C)
    ///          / |            | \
    ///         /  |            |  \
    ///      (A)---(B)         (A)---(B)
    ///
    pub def slopeVertices(pos: Vec2.Vec2, size: Vec2.Vec2,
                           riseRight: Bool): (Vec2.Vec2, Vec2.Vec2, Vec2.Vec2) =
        let halfW = size#x / 2.0;
        let halfH = size#y / 2.0;
        let a = {x = pos#x - halfW, y = pos#y + halfH};
        let b = {x = pos#x + halfW, y = pos#y + halfH};
        let c = if (riseRight) {x = pos#x + halfW, y = pos#y - halfH}
                else {x = pos#x - halfW, y = pos#y - halfH};
        (a, b, c)

    /// 線分上で点 p に最も近い点を返す。
    pub def closestPointOnSegment(p: Vec2.Vec2, segA: Vec2.Vec2, segB: Vec2.Vec2): Vec2.Vec2 =
        let ab = Vec2.sub(segB, segA);
        let abLenSq = Vec2.lengthSquared(ab);
        if (abLenSq < 0.000001) segA
        else
            let t = Float64.max(0.0, Float64.min(1.0, Vec2.dot(Vec2.sub(p, segA), ab) / abLenSq));
            Vec2.add(segA, Vec2.mul(ab, t))

    /// 点が三角形の内部（境界含む）にあるか。3 辺の外積符号が揃うかで判定する。
    def pointInTriangle(p: Vec2.Vec2, va: Vec2.Vec2, vb: Vec2.Vec2, vc: Vec2.Vec2): Bool =
        let d1 = Vec2.cross(Vec2.sub(vb, va), Vec2.sub(p, va));
        let d2 = Vec2.cross(Vec2.sub(vc, vb), Vec2.sub(p, vb));
        let d3 = Vec2.cross(Vec2.sub(va, vc), Vec2.sub(p, vc));
        (d1 <= 0.0 and d2 <= 0.0 and d3 <= 0.0) or (d1 >= 0.0 and d2 >= 0.0 and d3 >= 0.0)

    /// 辺 a→b の外向き単位法線を返す。inside（三角形の反対側の頂点）から遠ざかる向きに
    /// 揃えるので、頂点の並び順や坂の向きに関わらず符号を取り違えない。
    def edgeOutwardNormal(a: Vec2.Vec2, b: Vec2.Vec2, inside: Vec2.Vec2): Vec2.Vec2 =
        let d = Vec2.sub(b, a);
        let n = Vec2.normalized({x = d#y, y = -1.0 * d#x});
        if (Vec2.dot(n, Vec2.sub(inside, a)) > 0.0) Vec2.neg(n) else n

    /// 点から辺を通る直線までの距離。
    def distToEdgeLine(p: Vec2.Vec2, a: Vec2.Vec2, b: Vec2.Vec2): Float64 =
        let d = Vec2.sub(b, a);
        let len = Vec2.length(d);
        if (len < 0.000001) Vec2.distanceTo(p, a)
        else Float64.abs(Vec2.cross(d, Vec2.sub(p, a))) / len

    /// 点対の距離の二乗。
    def pairDistSq(pair: (Vec2.Vec2, Vec2.Vec2)): Float64 =
        let (p, q) = pair;
        Vec2.distanceSquaredTo(p, q)

    /// 2 線分の最近接点対（線分 1 上の点, 線分 2 上の点）を返す。交差していれば交点。
    def closestPairSegSeg(a1: Vec2.Vec2, a2: Vec2.Vec2,
                           b1: Vec2.Vec2, b2: Vec2.Vec2): (Vec2.Vec2, Vec2.Vec2) =
        if (segmentsIntersect(a1, a2, b1, b2))
            let d1 = Vec2.sub(a2, a1);
            let d2 = Vec2.sub(b2, b1);
            let t = Vec2.cross(Vec2.sub(b1, a1), d2) / Vec2.cross(d1, d2);
            let p = Vec2.add(a1, Vec2.mul(d1, t));
            (p, p)
        else
            // 端点→相手線分の 4 候補から最短の対を取る
            let c1 = (a1, closestPointOnSegment(a1, b1, b2));
            let c2 = (a2, closestPointOnSegment(a2, b1, b2));
            let c3 = (closestPointOnSegment(b1, a1, a2), b1);
            let c4 = (closestPointOnSegment(b2, a1, a2), b2);
            List.foldLeft((acc, cand) -> if (pairDistSq(cand) < pairDistSq(acc)) cand else acc,
                          c1, c2 :: c3 :: c4 :: Nil)

    // ========================================================================
    // 坂形状の衝突判定
    // ========================================================================

    /// 円と坂の重なり判定。
    /// 円の中心が三角形の中にあるか、3 辺のどれかに半径未満まで近ければ重なる。
    pub def checkCircleSlope(circlePos: Vec2.Vec2, radius: Float64,
                              slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2,
                              riseRight: Bool): Bool =
        let (va, vb, vc) = slopeVertices(slopePos, slopeSize, riseRight);
        if (pointInTriangle(circlePos, va, vb, vc)) true
        else
            let rSq = radius * radius;
            pointToSegmentDistSq(circlePos, va, vb) < rSq or
            pointToSegmentDistSq(circlePos, vb, vc) < rSq or
            pointToSegmentDistSq(circlePos, vc, va) < rSq

    /// カプセルと坂の重なり判定。
    /// 軸線分の端点が三角形の中にあるか、3 辺のどれかに半径未満まで近ければ重なる
    /// （線分が三角形を貫くときは辺と交差するので距離 0 で拾える）。
    pub def checkCapsuleSlope(capsulePos: Vec2.Vec2, radius: Float64,
                               height: Float64, vertical: Bool,
                               slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2,
                               riseRight: Bool): Bool =
        let (segA, segB) = capsuleSegment(capsulePos, radius, height, vertical);
        let (va, vb, vc) = slopeVertices(slopePos, slopeSize, riseRight);
        if (pointInTriangle(segA, va, vb, vc) or pointInTriangle(segB, va, vb, vc)) true
        else
            let rSq = radius * radius;
            segmentToSegmentDistSq(segA, segB, va, vb) < rSq or
            segmentToSegmentDistSq(segA, segB, vb, vc) < rSq or
            segmentToSegmentDistSq(segA, segB, vc, va) < rSq

    // ========================================================================
    // MTV（Minimum Translation Vector）計算 — 衝突分離用
    // ========================================================================
    //
    // resolveOverlap は「形状 A を形状 B から分離するために A に加算すべき変位」を返す。
    // 重なっていない場合は None。
    // PhysicsStep が静的衝突解決（push out）に使う。

    /// 2 つの形状の重なりを解消する変位ベクトルを返す。
    /// posA / posB は各形状の中心座標。返り値は posA に足すと A が B から離れる変位。
    /// 静的地形同士（矩形・坂・多角形の組）は None を返す（静的地形同士は分離しないため）。
    pub def resolveOverlap(posA: Vec2.Vec2, shapeA: CollisionShape2D,
                            posB: Vec2.Vec2, shapeB: CollisionShape2D): Option[Vec2.Vec2] =
        match (shapeA, shapeB) {
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.RectShape2D(rb)) =>
                resolveRectRect(posA, {x = ra#width, y = ra#height},
                                posB, {x = rb#width, y = rb#height})
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.CircleShape2D(cb)) =>
                resolveCircleCircle(posA, ca#radius, posB, cb#radius)
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.RectShape2D(rb)) =>
                resolveCircleRect(posA, ca#radius, posB, {x = rb#width, y = rb#height})
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.CircleShape2D(cb)) =>
                // B (circle) を A (rect) から離す変位を求めて符号反転
                Option.map(v -> Vec2.neg(v),
                    resolveCircleRect(posB, cb#radius, posA, {x = ra#width, y = ra#height}))
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.CircleShape2D(cb)) =>
                resolveCapsuleCircle(posA, ca#radius, ca#height, ca#vertical, posB, cb#radius)
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.CapsuleShape2D(cb)) =>
                Option.map(v -> Vec2.neg(v),
                    resolveCapsuleCircle(posB, cb#radius, cb#height, cb#vertical, posA, ca#radius))
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.RectShape2D(rb)) =>
                resolveCapsuleRect(posA, ca#radius, ca#height, ca#vertical,
                                   posB, {x = rb#width, y = rb#height})
            case (CollisionShape2D.RectShape2D(ra), CollisionShape2D.CapsuleShape2D(cb)) =>
                Option.map(v -> Vec2.neg(v),
                    resolveCapsuleRect(posB, cb#radius, cb#height, cb#vertical,
                                       posA, {x = ra#width, y = ra#height}))
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.CapsuleShape2D(cb)) =>
                resolveCapsuleCapsule(posA, ca#radius, ca#height, ca#vertical,
                                      posB, cb#radius, cb#height, cb#vertical)
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.SlopeShape2D(sb)) =>
                resolveCircleSlope(posA, ca#radius,
                                   posB, {x = sb#width, y = sb#height}, sb#riseRight)
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.CircleShape2D(cb)) =>
                Option.map(v -> Vec2.neg(v),
                    resolveCircleSlope(posB, cb#radius,
                                       posA, {x = sa#width, y = sa#height}, sa#riseRight))
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.SlopeShape2D(sb)) =>
                resolveCapsuleSlope(posA, ca#radius, ca#height, ca#vertical,
                                    posB, {x = sb#width, y = sb#height}, sb#riseRight)
            case (CollisionShape2D.SlopeShape2D(sa), CollisionShape2D.CapsuleShape2D(cb)) =>
                Option.map(v -> Vec2.neg(v),
                    resolveCapsuleSlope(posB, cb#radius, cb#height, cb#vertical,
                                        posA, {x = sa#width, y = sa#height}, sa#riseRight))
            case (CollisionShape2D.CircleShape2D(ca), CollisionShape2D.PolygonShape2D(pb)) =>
                resolveCirclePolygon(posA, ca#radius, posB, pb#points)
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.CircleShape2D(cb)) =>
                Option.map(v -> Vec2.neg(v),
                    resolveCirclePolygon(posB, cb#radius, posA, pa#points))
            case (CollisionShape2D.CapsuleShape2D(ca), CollisionShape2D.PolygonShape2D(pb)) =>
                resolveCapsulePolygon(posA, ca#radius, ca#height, ca#vertical, posB, pb#points)
            case (CollisionShape2D.PolygonShape2D(pa), CollisionShape2D.CapsuleShape2D(cb)) =>
                Option.map(v -> Vec2.neg(v),
                    resolveCapsulePolygon(posB, cb#radius, cb#height, cb#vertical, posA, pa#points))
            // 静的地形同士（矩形・坂・多角形の組）は分離しない。
            // ワイルドカードにせず全て列挙する: 6 番目の形状を足すとき、
            // resolve の追加漏れがコンパイルエラーとして現れるように。
            case (CollisionShape2D.RectShape2D(_), CollisionShape2D.SlopeShape2D(_)) => None
            case (CollisionShape2D.SlopeShape2D(_), CollisionShape2D.RectShape2D(_)) => None
            case (CollisionShape2D.SlopeShape2D(_), CollisionShape2D.SlopeShape2D(_)) => None
            case (CollisionShape2D.RectShape2D(_), CollisionShape2D.PolygonShape2D(_)) => None
            case (CollisionShape2D.PolygonShape2D(_), CollisionShape2D.RectShape2D(_)) => None
            case (CollisionShape2D.SlopeShape2D(_), CollisionShape2D.PolygonShape2D(_)) => None
            case (CollisionShape2D.PolygonShape2D(_), CollisionShape2D.SlopeShape2D(_)) => None
            case (CollisionShape2D.PolygonShape2D(_), CollisionShape2D.PolygonShape2D(_)) => None
        }

    /// AABB 矩形同士の MTV。重なる軸のうち侵入量が小さい方向に押し出す。
    pub def resolveRectRect(posA: Vec2.Vec2, sizeA: Vec2.Vec2,
                             posB: Vec2.Vec2, sizeB: Vec2.Vec2): Option[Vec2.Vec2] =
        let halfA = Vec2.div(sizeA, 2.0);
        let halfB = Vec2.div(sizeB, 2.0);
        let dx = posA#x - posB#x;
        let dy = posA#y - posB#y;
        let overlapX = halfA#x + halfB#x - Float64.abs(dx);
        let overlapY = halfA#y + halfB#y - Float64.abs(dy);
        if (overlapX <= 0.0 or overlapY <= 0.0) None
        else if (overlapX < overlapY)
            Some({x = if (dx >= 0.0) overlapX else (-1.0 * overlapX), y = 0.0})
        else
            Some({x = 0.0, y = if (dy >= 0.0) overlapY else (-1.0 * overlapY)})

    /// 円同士の MTV。中心間ベクトル方向に sumR - distance だけ押し出す。
    pub def resolveCircleCircle(posA: Vec2.Vec2, radiusA: Float64,
                                 posB: Vec2.Vec2, radiusB: Float64): Option[Vec2.Vec2] =
        let diff = Vec2.sub(posA, posB);
        let dist = Vec2.length(diff);
        let sumR = radiusA + radiusB;
        if (dist >= sumR) None
        else if (dist < 0.001)
            // 中心一致 — X 正方向に押し出す（任意）
            Some({x = sumR, y = 0.0})
        else
            let push = (sumR - dist) / dist;
            Some(Vec2.mul(diff, push))

    /// 円と矩形の MTV。
    /// circlePos / rectPos は各中心座標。circle を rect から離す変位を返す。
    pub def resolveCircleRect(circlePos: Vec2.Vec2, radius: Float64,
                               rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Option[Vec2.Vec2] =
        let halfW = rectSize#x / 2.0;
        let halfH = rectSize#y / 2.0;
        // 矩形上の最近接点
        let closestX = Float64.max(rectPos#x - halfW, Float64.min(circlePos#x, rectPos#x + halfW));
        let closestY = Float64.max(rectPos#y - halfH, Float64.min(circlePos#y, rectPos#y + halfH));
        let distX = circlePos#x - closestX;
        let distY = circlePos#y - closestY;
        let dist = Vec2.length({x = distX, y = distY});
        if (dist >= radius) None
        else if (dist < 0.001)
            // 円中心が矩形内部 — 浅い軸方向に押し出す
            let dx = circlePos#x - rectPos#x;
            let dy = circlePos#y - rectPos#y;
            let penX = halfW + radius - Float64.abs(dx);
            let penY = halfH + radius - Float64.abs(dy);
            if (penX < penY)
                Some({x = if (dx >= 0.0) penX else (-1.0 * penX), y = 0.0})
            else
                Some({x = 0.0, y = if (dy >= 0.0) penY else (-1.0 * penY)})
        else
            let push = (radius - dist) / dist;
            Some({x = distX * push, y = distY * push})

    // ========================================================================
    // カプセルの MTV — 軸線分上の最近接点を円とみなして既存の円 MTV に還元する
    // ========================================================================

    /// カプセルと円の MTV。カプセルを円から離す変位を返す。
    /// 軸線分上で円中心に最も近い点を求め、その点を中心とする半径 radius の円として押し出す。
    pub def resolveCapsuleCircle(capsulePos: Vec2.Vec2, capsuleRadius: Float64,
                                  capsuleHeight: Float64, capsuleVertical: Bool,
                                  circlePos: Vec2.Vec2, circleRadius: Float64): Option[Vec2.Vec2] =
        let (segA, segB) = capsuleSegment(capsulePos, capsuleRadius, capsuleHeight, capsuleVertical);
        let p = closestPointOnSegment(circlePos, segA, segB);
        resolveCircleCircle(p, capsuleRadius, circlePos, circleRadius)

    /// カプセルと矩形の MTV。カプセルを矩形から離す変位を返す。
    /// 矩形に最も近い軸線分上の点を求め、その点を中心とする円として押し出す。
    pub def resolveCapsuleRect(capsulePos: Vec2.Vec2, radius: Float64,
                                height: Float64, vertical: Bool,
                                rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Option[Vec2.Vec2] =
        let (segA, segB) = capsuleSegment(capsulePos, radius, height, vertical);
        let s = closestSegPointToRect(segA, segB, rectPos, rectSize);
        resolveCircleRect(s, radius, rectPos, rectSize)

    /// カプセル同士の MTV。A を B から離す変位を返す。
    /// 両軸線分の最近接点対を、それぞれの半径の円同士とみなして押し出す。
    pub def resolveCapsuleCapsule(posA: Vec2.Vec2, radiusA: Float64,
                                   heightA: Float64, verticalA: Bool,
                                   posB: Vec2.Vec2, radiusB: Float64,
                                   heightB: Float64, verticalB: Bool): Option[Vec2.Vec2] =
        let (a1, a2) = capsuleSegment(posA, radiusA, heightA, verticalA);
        let (b1, b2) = capsuleSegment(posB, radiusB, heightB, verticalB);
        let (pa, pb) = closestPairSegSeg(a1, a2, b1, b2);
        resolveCircleCircle(pa, radiusA, pb, radiusB)

    /// カプセルと坂の MTV。カプセルを坂から離す変位を返す。
    /// 三角形に最も近い軸線分上の点を求め、その点を中心とする円として押し出す。
    pub def resolveCapsuleSlope(capsulePos: Vec2.Vec2, radius: Float64,
                                 height: Float64, vertical: Bool,
                                 slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2,
                                 riseRight: Bool): Option[Vec2.Vec2] =
        if (slopeSize#x < 0.000001 or slopeSize#y < 0.000001) None   // 潰れた坂は分離できない
        else
            let (segA, segB) = capsuleSegment(capsulePos, radius, height, vertical);
            let (va, vb, vc) = slopeVertices(slopePos, slopeSize, riseRight);
            let s = closestSegPointToTriangle(segA, segB, va, vb, vc);
            resolveCircleTriangle(s, radius, va, vb, vc)

    /// 矩形（実体）に最も近い、線分上の点。端点が矩形の中ならその端点を返す
    /// （深いめり込みは resolveCircleRect の内部ケースが引き受ける）。
    def closestSegPointToRect(segA: Vec2.Vec2, segB: Vec2.Vec2,
                               rectPos: Vec2.Vec2, rectSize: Vec2.Vec2): Vec2.Vec2 =
        let halfW = rectSize#x / 2.0;
        let halfH = rectSize#y / 2.0;
        let inRect = p -> Float64.abs(p#x - rectPos#x) <= halfW and
                          Float64.abs(p#y - rectPos#y) <= halfH;
        if (inRect(segA)) segA
        else if (inRect(segB)) segB
        else
            let tl = {x = rectPos#x - halfW, y = rectPos#y - halfH};
            let tr = {x = rectPos#x + halfW, y = rectPos#y - halfH};
            let br = {x = rectPos#x + halfW, y = rectPos#y + halfH};
            let bl = {x = rectPos#x - halfW, y = rectPos#y + halfH};
            closestSegPointToEdges(segA, segB, (tl, tr) :: (tr, br) :: (br, bl) :: (bl, tl) :: Nil)

    /// 三角形（実体）に最も近い、線分上の点。端点が三角形の中ならその端点を返す。
    def closestSegPointToTriangle(segA: Vec2.Vec2, segB: Vec2.Vec2,
                                   va: Vec2.Vec2, vb: Vec2.Vec2, vc: Vec2.Vec2): Vec2.Vec2 =
        if (pointInTriangle(segA, va, vb, vc)) segA
        else if (pointInTriangle(segB, va, vb, vc)) segB
        else closestSegPointToEdges(segA, segB, (va, vb) :: (vb, vc) :: (vc, va) :: Nil)

    /// 各辺との最近接点対のうち最短の、線分側の点を返す。
    def closestSegPointToEdges(segA: Vec2.Vec2, segB: Vec2.Vec2,
                                edges: List[(Vec2.Vec2, Vec2.Vec2)]): Vec2.Vec2 =
        let candidates = List.map(edge -> {
            let (e1, e2) = edge;
            closestPairSegSeg(segA, segB, e1, e2)
        }, edges);
        match candidates {
            case Nil => segA
            case first :: rest =>
                let bestPair = List.foldLeft(
                    (acc, cand) -> if (pairDistSq(cand) < pairDistSq(acc)) cand else acc,
                    first, rest);
                let (p, _) = bestPair;
                p
        }

    // ========================================================================
    // 坂の MTV
    // ========================================================================

    /// 円と坂の MTV。円を坂から離す変位を返す。
    /// 中心が三角形の外なら「三角形上の最近接点から中心へ」の向きに不足ぶん押し出し、
    /// 中心が三角形の中なら最も浅い辺の外向き法線へ押し出す。
    pub def resolveCircleSlope(circlePos: Vec2.Vec2, radius: Float64,
                                slopePos: Vec2.Vec2, slopeSize: Vec2.Vec2,
                                riseRight: Bool): Option[Vec2.Vec2] =
        if (slopeSize#x < 0.000001 or slopeSize#y < 0.000001) None   // 潰れた坂は分離できない
        else
            let (va, vb, vc) = slopeVertices(slopePos, slopeSize, riseRight);
            resolveCircleTriangle(circlePos, radius, va, vb, vc)

    /// 円と三角形の MTV（円を三角形から離す変位）。
    def resolveCircleTriangle(circlePos: Vec2.Vec2, radius: Float64,
                               va: Vec2.Vec2, vb: Vec2.Vec2, vc: Vec2.Vec2): Option[Vec2.Vec2] =
        if (pointInTriangle(circlePos, va, vb, vc))
            Some(pushOutFromInside(circlePos, radius, va, vb, vc))
        else
            let closest = closestTrianglePoint(circlePos, va, vb, vc);
            let diff = Vec2.sub(circlePos, closest);
            let dist = Vec2.length(diff);
            if (dist >= radius) None
            else if (dist < 0.001)
                // 境界すれすれ — 向きの数値誤差を避けるため内側扱いで押し出す
                Some(pushOutFromInside(circlePos, radius, va, vb, vc))
            else
                Some(Vec2.mul(diff, (radius - dist) / dist))

    /// 三角形の境界上で点 p に最も近い点。
    def closestTrianglePoint(p: Vec2.Vec2, va: Vec2.Vec2, vb: Vec2.Vec2, vc: Vec2.Vec2): Vec2.Vec2 =
        let cAB = closestPointOnSegment(p, va, vb);
        let cBC = closestPointOnSegment(p, vb, vc);
        let cCA = closestPointOnSegment(p, vc, va);
        let best = if (Vec2.distanceSquaredTo(p, cBC) < Vec2.distanceSquaredTo(p, cAB)) cBC else cAB;
        if (Vec2.distanceSquaredTo(p, cCA) < Vec2.distanceSquaredTo(p, best)) cCA else best

    /// 中心が三角形の中にある円の押し出し。
    /// 最も浅い辺（中心から直線までの距離が最小の辺）の外向き法線へ、距離＋半径ぶん動かす。
    def pushOutFromInside(p: Vec2.Vec2, radius: Float64,
                           va: Vec2.Vec2, vb: Vec2.Vec2, vc: Vec2.Vec2): Vec2.Vec2 =
        let dAB = distToEdgeLine(p, va, vb);
        let dBC = distToEdgeLine(p, vb, vc);
        let dCA = distToEdgeLine(p, vc, va);
        if (dAB <= dBC and dAB <= dCA)
            Vec2.mul(edgeOutwardNormal(va, vb, vc), dAB + radius)
        else if (dBC <= dCA)
            Vec2.mul(edgeOutwardNormal(vb, vc, va), dBC + radius)
        else
            Vec2.mul(edgeOutwardNormal(vc, va, vb), dCA + radius)

    // ========================================================================
    // 多角形形状のヘルパー
    // ========================================================================

    /// ローカル頂点列をワールド座標の辺の列にする（最後の頂点→先頭で閉じる）。
    def worldEdges(polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): List[(Vec2.Vec2, Vec2.Vec2)] =
        let world = List.map(p -> Vec2.add(polyPos, p), points);
        match world {
            case Nil => Nil
            case first :: _ =>
                List.zip(world, List.append(List.drop(1, world), first :: Nil))
        }

    /// 点が辺の列で囲まれた領域の内部にあるか（水平線との交差数の偶奇）。
    def insideEdges(p: Vec2.Vec2, edges: List[(Vec2.Vec2, Vec2.Vec2)]): Bool =
        // 偶奇判定は境界上の点で辺の拾い方が揺れるため、先に境界上を弾いて外扱いに固定する
        // （「接触ちょうどは重ならない」政策の strict < と揃える）。
        let onBoundary = List.exists(edge -> {
            let (a, b) = edge;
            pointToSegmentDistSq(p, a, b) < 0.000000001
        }, edges);
        if (onBoundary) false
        else
            List.foldLeft((inside, edge) -> {
                let (a, b) = edge;
                let crosses = ((a#y > p#y) != (b#y > p#y)) and
                              (p#x < a#x + (b#x - a#x) * (p#y - a#y) / (b#y - a#y));
                if (crosses) not inside else inside
            }, false, edges)

    /// 点が多角形の内部にあるか。交差数の偶奇で判定するので凹んだ形でも正しい。
    /// 境界上は外扱い・巻き順は不問。
    pub def pointInPolygon(p: Vec2.Vec2, polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Bool =
        insideEdges(p, worldEdges(polyPos, points))

    /// ローカル頂点列の外接箱。外接箱近似のペアと事前の足切りに使う。
    pub def polygonBounds(points: List[Vec2.Vec2]): Rect2.Rect2 =
        match points {
            case Nil => {position = Vec2.zero(), size = Vec2.zero()}
            case first :: rest =>
                let (low, high) = List.foldLeft((acc, p) -> {
                    let (lo, hi) = acc;
                    ({x = Float64.min(lo#x, p#x), y = Float64.min(lo#y, p#y)},
                     {x = Float64.max(hi#x, p#x), y = Float64.max(hi#y, p#y)})
                }, (first, first), rest);
                {position = low, size = Vec2.sub(high, low)}
        }

    /// 多角形のワールド外接箱を「中心とサイズ」で返す（checkRectRect にそのまま渡せる形）。
    def polygonBoundsCenterSize(polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): (Vec2.Vec2, Vec2.Vec2) =
        let bounds = polygonBounds(points);
        (Vec2.add(polyPos, Rect2.center(bounds)), bounds#size)

    /// 辺 a→b の外向き単位法線。頂点列が signedArea 正の向きに揃っている前提
    /// （揃っていないと符号が反転するので、呼び手が先に向きを正規化する）。
    def polygonEdgeOutwardNormal(edge: (Vec2.Vec2, Vec2.Vec2)): Vec2.Vec2 =
        let (a, b) = edge;
        let d = Vec2.sub(b, a);
        Vec2.normalized({x = d#y, y = -1.0 * d#x})

    /// 多角形の境界上で点に最も近い点と、その点が乗っている辺を返す。
    def closestBoundaryPair(p: Vec2.Vec2, edges: List[(Vec2.Vec2, Vec2.Vec2)]):
            Option[(Vec2.Vec2, (Vec2.Vec2, Vec2.Vec2))] =
        match edges {
            case Nil => None
            case first :: rest =>
                let candidateOf = edge -> {
                    let (a, b) = edge;
                    (closestPointOnSegment(p, a, b), edge)
                };
                Some(List.foldLeft((best, edge) -> {
                    let cand = candidateOf(edge);
                    let (bestPoint, _) = best;
                    let (candPoint, _) = cand;
                    if (Vec2.distanceSquaredTo(p, candPoint) < Vec2.distanceSquaredTo(p, bestPoint))
                        cand
                    else best
                }, candidateOf(first), rest))
        }

    // ========================================================================
    // 多角形形状の衝突判定
    // ========================================================================

    /// 円と多角形の重なり判定（checkCircleSlope の n 辺版）。
    /// 中心が内部にあるか、どれかの辺に半径未満まで近ければ重なる。
    pub def checkCirclePolygon(circlePos: Vec2.Vec2, radius: Float64,
                                polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Bool =
        // 辺の総当りの前に外接箱で足切りする（多角形は辺数が多く、離れている相手が大半のため）。
        let localBounds = polygonBounds(points);
        let worldBounds = {position = Vec2.add(localBounds#position, polyPos), size = localBounds#size};
        if (not Rect2.hasPoint(circlePos, Rect2.grow(radius, worldBounds))) false
        else
            let edges = worldEdges(polyPos, points);
            if (insideEdges(circlePos, edges)) true
            else
                let radiusSq = radius * radius;
                List.exists(edge -> {
                    let (a, b) = edge;
                    pointToSegmentDistSq(circlePos, a, b) < radiusSq
                }, edges)

    /// カプセルと多角形の重なり判定（checkCapsuleSlope の n 辺版）。
    /// 軸線分の端点が内部にあるか、どれかの辺に半径未満まで近ければ重なる
    /// （線分が多角形を貫くときは辺と交差するので距離 0 で拾える）。
    pub def checkCapsulePolygon(capsulePos: Vec2.Vec2, radius: Float64,
                                 height: Float64, vertical: Bool,
                                 polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Bool =
        let (segA, segB) = capsuleSegment(capsulePos, radius, height, vertical);
        let edges = worldEdges(polyPos, points);
        if (insideEdges(segA, edges) or insideEdges(segB, edges)) true
        else
            let radiusSq = radius * radius;
            List.exists(edge -> {
                let (e1, e2) = edge;
                segmentToSegmentDistSq(segA, segB, e1, e2) < radiusSq
            }, edges)

    // ========================================================================
    // 多角形の MTV
    // ========================================================================

    /// 円と多角形の MTV。円を多角形から離す変位を返す。
    /// 押し出しの距離は必ず「辺（線分）への最近接点」から取る。坂の pushOutFromInside のような
    /// 「辺を通る直線への距離」は、凹んだ角の近くで辺の延長線を拾い誤った向きに押すため使わない。
    /// 3 頂点未満は None（潰れた坂と同じ政策）。
    pub def resolveCirclePolygon(circlePos: Vec2.Vec2, radius: Float64,
                                  polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Option[Vec2.Vec2] =
        if (List.length(points) < 3) None
        else
            // 外向き法線の符号は巻き順で反転するため、どちら回りで渡されても
            // 同じ押し出しになるようにここで正の向きへ揃える。
            let oriented = if (Triangulate.signedArea(points) < 0.0) List.reverse(points) else points;
            let edges = worldEdges(polyPos, oriented);
            match closestBoundaryPair(circlePos, edges) {
                case None => None
                case Some((closest, edge)) =>
                    let diff = Vec2.sub(circlePos, closest);
                    let dist = Vec2.length(diff);
                    if (insideEdges(circlePos, edges))
                        // 中心が内部 — 境界最近接点の方向へ dist + radius
                        if (dist < 0.001)
                            Some(Vec2.mul(polygonEdgeOutwardNormal(edge), dist + radius))
                        else
                            Some(Vec2.mul(diff, -1.0 * (dist + radius) / dist))
                    else if (dist >= radius) None
                    else if (dist < 0.001)
                        // 境界すれすれ — 向きの数値誤差を避けるため辺の外向き法線で押す
                        Some(Vec2.mul(polygonEdgeOutwardNormal(edge), radius - dist))
                    else
                        // 外から浅くめり込み — 境界最近接点→中心方向へ不足ぶん
                        Some(Vec2.mul(diff, (radius - dist) / dist))
            }

    /// カプセルと多角形の MTV。カプセルを多角形から離す変位を返す。
    /// 多角形に最も近い軸線分上の点を求め、その点を円とみなして円の MTV に還元する
    /// （既存のカプセル系と同じ還元）。
    pub def resolveCapsulePolygon(capsulePos: Vec2.Vec2, radius: Float64,
                                   height: Float64, vertical: Bool,
                                   polyPos: Vec2.Vec2, points: List[Vec2.Vec2]): Option[Vec2.Vec2] =
        let (segA, segB) = capsuleSegment(capsulePos, radius, height, vertical);
        let edges = worldEdges(polyPos, points);
        let s = if (insideEdges(segA, edges)) segA
                else if (insideEdges(segB, edges)) segB
                else closestSegPointToEdges(segA, segB, edges);
        resolveCirclePolygon(s, radius, polyPos, points)

    // ========================================================================
    // 多角形の検証 — 外部データ（level.json 等）の読み込み時に使う
    // ========================================================================

    /// 頂点列が多角形として成立するか検証する。壊れていれば平易な日本語の理由を返す。
    /// 判定関数からは呼ばない（自己交差の総当りは重く、毎フレームの経路に置けない）。
    pub def validatePolygonPoints(points: List[Vec2.Vec2]): Result[String, Unit] =
        if (List.length(points) < 3)
            Err("頂点が ${List.length(points)} 個しかありません。多角形には 3 個以上の頂点が必要です")
        else if (Float64.abs(Triangulate.signedArea(points)) < 0.000001)
            Err("面積がほぼゼロです。頂点が一直線に並んでいないか確かめてください")
        else if (hasSelfIntersection(points))
            Err("辺同士が交差しています。自己交差しない形に直してください")
        else Ok(())

    /// 隣り合わない辺のペアに交差があるか（O(n²) の総当り）。
    def hasSelfIntersection(points: List[Vec2.Vec2]): Bool =
        let edges = worldEdges(Vec2.zero(), points);
        let count = List.length(edges);
        let indexed = List.zip(List.range(0, count), edges);
        List.exists(left -> {
            let (i, edgeI) = left;
            List.exists(right -> {
                let (j, edgeJ) = right;
                // 隣の辺は頂点を共有していて必ず触れるので除外（先頭と末尾の辺も隣同士）
                let adjacent = (j == i + 1) or (i == 0 and j == count - 1);
                if (j <= i or adjacent) false
                else {
                    let (a1, a2) = edgeI;
                    let (b1, b2) = edgeJ;
                    segmentsIntersect(a1, a2, b1, b2)
                }
            }, indexed)
        }, indexed)
}
