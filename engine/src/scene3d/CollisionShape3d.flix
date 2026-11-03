// CollisionShape3d — 3D の当たり判定の形と、形 1 つに対する問い（純粋）。座標の約束は scene3d/Scene3d.flix の頭。
// 2D の当たり判定は CollisionShape2D（engine/src/render）。歩く体は engine_world の CharacterBody3d、レイは Ray3d。

/// 3D の当たり判定の形。歩く体の壁（CharacterBody3d）と、見ている物を調べるレイの的（Ray3d.RayTarget）が同じ形を使う。
pub enum CollisionShape3d {
    /// 向きのある箱（OBB）
    case BoxShape3d(CollisionShape3d.Box3d)
    /// 球
    case SphereShape3d(CollisionShape3d.Sphere3d)
    /// 縦に立てたカプセル（両端が半球）
    case CapsuleShape3d(CollisionShape3d.Capsule3d)
}

pub mod CollisionShape3d {

    /// 向きのある箱。center = 真ん中・ax / ay / az = 3 本の向き（長さ 1・互いに直角）・half = 各向きの半分の長さ（0 以上）。
    /// 作るのは box3d / boxOfNode / boxOfMesh / boxOfBounds / transformBox（向きを手で組むと直角が崩れうる）。
    pub type alias Box3d = { center = Vec3.Vec3, ax = Vec3.Vec3, ay = Vec3.Vec3, az = Vec3.Vec3, half = Vec3.Vec3 }

    /// 球。center = 真ん中・radius = 半径。
    pub type alias Sphere3d = { center = Vec3.Vec3, radius = Float64 }

    /// 縦に立てたカプセル。feet = 下の端の点・radius = 半径・height = 全体の高さ（両端の半球を含む。2 × radius より低い時は球 1 つ）。
    pub type alias Capsule3d = { feet = Vec3.Vec3, radius = Float64, height = Float64 }

    // ════════════════════════════════════════════════════════════════════
    // 作る
    // ════════════════════════════════════════════════════════════════════

    /// 軸にそろった箱（真ん中 center・各向きの半分の長さ half。負の値は正に直す）。
    pub def box3d(center: Vec3.Vec3, half: Vec3.Vec3): Box3d =
        { center = center, ax = Vec3.v3(1.0, 0.0, 0.0), ay = Vec3.v3(0.0, 1.0, 0.0), az = Vec3.v3(0.0, 0.0, 1.0),
          half = Vec3.v3(Float64.abs(half#x), Float64.abs(half#y), Float64.abs(half#z)) }

    /// 形の座標の箱 bounds を world で写した向きのある箱。軸ごとの倍率は half に入れる。
    /// world にせん断がある（写した 3 本の向きが直角でない）か、1 つの向きを 0 に潰している時は、8 つの角を囲む軸にそろった箱に倒す
    /// （中身を全部含むので、壁が薄くなって抜けることは無い）。
    pub def boxOfBounds(world: Mat4.Mat4, bounds: Mesh3d.Bounds): Box3d =
        let mid = Vec3.mul(Vec3.add(bounds#min, bounds#max), 0.5);
        let half = Vec3.mul(Vec3.sub(bounds#max, bounds#min), 0.5);
        let ex = Mat4.applyDir(world, Vec3.v3(1.0, 0.0, 0.0));
        let ey = Mat4.applyDir(world, Vec3.v3(0.0, 1.0, 0.0));
        let ez = Mat4.applyDir(world, Vec3.v3(0.0, 0.0, 1.0));
        let (lx, ly, lz) = (Vec3.length(ex), Vec3.length(ey), Vec3.length(ez));
        if (isRigidFrame(world))
            { center = Mat4.apply(world, mid), ax = Vec3.mul(ex, 1.0 / lx), ay = Vec3.mul(ey, 1.0 / ly), az = Vec3.mul(ez, 1.0 / lz),
              half = Vec3.v3(Float64.abs(half#x) * lx, Float64.abs(half#y) * ly, Float64.abs(half#z) * lz) }
        else enclosingBox(Mesh3d.cornersOf(bounds) |> List.map(Mat4.apply(world)))

    /// 3 本の長さ 1 の向きが互いに直角か（せん断の無い行列）。
    // WhyNot: しきい値を 1e-6 まで詰めない — glb の TRS は float32 で、親子を重ねた行列の直角のずれが 1e-6 に届き、段板が軸ぞろえの塊に倒れる。
    def isSquare(a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3): Bool =
        let eps = 1.0e-4;
        Float64.abs(Vec3.dot(a, b)) < eps and Float64.abs(Vec3.dot(b, c)) < eps and Float64.abs(Vec3.dot(a, c)) < eps

    /// 点の列を囲む軸にそろった箱（点が無ければ原点の大きさ 0 の箱）。
    def enclosingBox(points: List[Vec3.Vec3]): Box3d =
        let b = Mesh3d.boundsOfPoints(points);
        box3d(Vec3.mul(Vec3.add(b#min, b#max), 0.5), Vec3.mul(Vec3.sub(b#max, b#min), 0.5))

    /// glTF のノード 1 つの当たり判定の箱（node#localBounds を node#world で写す）。
    /// None: mesh の無いノード（empty・ライト・カメラ）と、行列か境界に NaN・無限大がある時。
    /// world にせん断があって外接箱に倒した時は、ノードの名前を 1 行知らせる。読み込みで 1 回作って持つ（毎コマ呼ばない）。
    pub def boxOfNode(node: Model3d.ModelNode): Option[Box3d] =
        node#localBounds |> Option.map(boxOfBounds(node#world)) |> Option.filter(isFinite)
            |> Option.map(b -> if (isRigidFrame(node#world)) b
                               else Log.warnThen("CollisionShape3d.boxOfNode: ノード ${node#name} の行列にせん断か潰れた軸があるので、軸にそろった外接箱にしました", b))

    /// 行列の 3 本の軸が 0 でなく互いに直角か（boxOfBounds が向きのある箱のまま写せるか）。
    def isRigidFrame(world: Mat4.Mat4): Bool =
        let ex = Mat4.applyDir(world, Vec3.v3(1.0, 0.0, 0.0));
        let ey = Mat4.applyDir(world, Vec3.v3(0.0, 1.0, 0.0));
        let ez = Mat4.applyDir(world, Vec3.v3(0.0, 0.0, 1.0));
        let tiny = 1.0e-9;
        Vec3.length(ex) > tiny and Vec3.length(ey) > tiny and Vec3.length(ez) > tiny and isSquare(Vec3.normalized(ex), Vec3.normalized(ey), Vec3.normalized(ez))

    /// ノードの列の箱（mesh の無いノードは飛ばす・並びはノードの順）。
    /// `Model3d.nodesWithPrefix("COL_", model) |> CollisionShape3d.boxesOfNodes` で Blender の当たり判定の箱を全部集める。
    /// 読み込みで 1 回作って持つ（毎コマ呼ばない）。
    pub def boxesOfNodes(nodes: List[Model3d.ModelNode]): List[Box3d] = List.filterMap(boxOfNode, nodes)

    /// 形 mesh（形の座標）の軸にそろった境界を world で写した箱。頂点の無い形と NaN・無限大は None。
    /// glb の parts の形は world を焼き込んであるので world は Mat4.identity()（向きの合った箱が要るなら boxOfNode）。
    pub def boxOfMesh(mesh: Mesh3d.Mesh3d, world: Mat4.Mat4): Option[Box3d] =
        if (Mesh3d.vertexCount(mesh) == 0) None
        else Some(boxOfBounds(world, Mesh3d.bounds(mesh))) |> Option.filter(isFinite)

    /// 箱 b を行列 m で写した箱（蝶番のまわりに回す扉の板）。倍率とせん断の扱いは boxOfBounds と同じ。
    pub def transformBox(m: Mat4.Mat4, b: Box3d): Box3d =
        boxOfBounds(Mat4.mul(m, frameOf(b)), { min = Vec3.mul(b#half, -1.0), max = b#half })

    /// 箱の向きの座標（真ん中が 0・軸は ax / ay / az）→ world の行列。
    def frameOf(b: Box3d): Mat4.Mat4 =
        Mat4.mul(Mat4.translate(b#center),
                 Mat4.ofLinearRows(Vec3.v3(b#ax#x, b#ay#x, b#az#x), Vec3.v3(b#ax#y, b#ay#y, b#az#y), Vec3.v3(b#ax#z, b#ay#z, b#az#z)))

    /// 箱の全部の数が有限か。
    pub def isFinite(b: Box3d): Bool =
        List.forAll(v -> Float64.isFinite(v#x) and Float64.isFinite(v#y) and Float64.isFinite(v#z), b#center :: b#ax :: b#ay :: b#az :: b#half :: Nil)

    /// 箱の 8 つの角（world）。
    pub def cornersOfBox(b: Box3d): List[Vec3.Vec3] =
        let signs = (-1.0, -1.0, -1.0) :: (1.0, -1.0, -1.0) :: (1.0, 1.0, -1.0) :: (-1.0, 1.0, -1.0) ::
                    (-1.0, -1.0, 1.0) :: (1.0, -1.0, 1.0) :: (1.0, 1.0, 1.0) :: (-1.0, 1.0, 1.0) :: Nil;
        signs |> List.map(s -> {
            let (sx, sy, sz) = s;
            toWorldPoint(b, Vec3.v3(sx * b#half#x, sy * b#half#y, sz * b#half#z))
        })

    // ════════════════════════════════════════════════════════════════════
    // 箱の向きの座標
    // ════════════════════════════════════════════════════════════════════

    /// 箱の向きの座標の点（箱の真ん中が 0・軸は ax / ay / az）。world の座標（素の Vec3）と取り違えないよう包む。
    enum Local(Vec3.Vec3)

    def unwrap(l: Local): Vec3.Vec3 = match l { case Local.Local(v) => v }

    /// world の点を箱の向きの座標へ。
    def toLocal(b: Box3d, p: Vec3.Vec3): Local =
        let d = Vec3.sub(p, b#center);
        Local.Local(Vec3.v3(Vec3.dot(d, b#ax), Vec3.dot(d, b#ay), Vec3.dot(d, b#az)))

    /// 箱の向きの座標（素の Vec3）の点を world へ。
    def toWorldPoint(b: Box3d, l: Vec3.Vec3): Vec3.Vec3 =
        Vec3.add(b#center, toWorldDir(b, l))

    /// 箱の向きの座標の向きを world へ（平行移動を受けない）。
    def toWorldDir(b: Box3d, l: Vec3.Vec3): Vec3.Vec3 =
        Vec3.add(Vec3.add(Vec3.mul(b#ax, l#x), Vec3.mul(b#ay, l#y)), Vec3.mul(b#az, l#z))

    /// 箱の中で一番近い点（箱の向きの座標）。
    def clampInside(b: Box3d, local: Local): Vec3.Vec3 =
        let l = unwrap(local);
        Vec3.v3(clampTo(b#half#x, l#x), clampTo(b#half#y, l#y), clampTo(b#half#z, l#z))

    def clampTo(h: Float64, v: Float64): Float64 = Float64.max(0.0 - h, Float64.min(h, v))

    // ════════════════════════════════════════════════════════════════════
    // 問い
    // ════════════════════════════════════════════════════════════════════

    /// 箱 b の中で点 p に一番近い点（p が中なら p）。
    pub def closestPoint(b: Box3d, p: Vec3.Vec3): Vec3.Vec3 = toWorldPoint(b, clampInside(b, toLocal(b, p)))

    /// 球（真ん中 center・半径 radius）が箱 b に食い込んでいる深さ（m。食い込んでいなければ 0）。
    /// 真ん中が箱の中にある時は radius（中のどこでも同じ。深さで押し出す向きは決めない）。
    pub def sphereDepth(b: Box3d, center: Vec3.Vec3, radius: Float64): Float64 =
        Float64.max(0.0, radius - Vec3.length(Vec3.sub(center, closestPoint(b, center))))

    /// カプセルを近似する球の真ん中（下から上へ）。間は radius 以下で、両端は半球の真ん中。
    /// 当たり判定の表示で体の球を並べる時にも使える。
    pub def sphereCentersOf(c: Capsule3d): List[Vec3.Vec3] =
        let r = Float64.max(0.0, c#radius);
        let lo = c#feet#y + r;
        let hi = Float64.max(lo, c#feet#y + c#height - r);
        let spacing = Float64.max(0.01, r);
        let n = Int32.min(256, Float64.tryToInt32(Float64.ceil((hi - lo) / spacing)) |> Option.getWithDefault(0));
        if (n <= 0) Vec3.v3(c#feet#x, lo, c#feet#z) :: Nil
        else List.range(0, n + 1) |> List.map(i -> Vec3.v3(c#feet#x, lo + (hi - lo) * Int32.toFloat64(i) / Int32.toFloat64(n), c#feet#z))

    /// カプセル capsule が箱 b に食い込んでいる深さ（m。0 なら触れていない）。
    /// 縦に並べた球（sphereCentersOf）の一番深い所。扉を回す前と後で比べ、体を押し込む向きへは回さない判定に使う。
    pub def penetration(b: Box3d, capsule: Capsule3d): Float64 =
        sphereCentersOf(capsule) |> List.foldLeft((acc, c) -> Float64.max(acc, sphereDepth(b, c, capsule#radius)), 0.0)

    /// 球（真ん中 center・半径 radius）を箱 b の外へ出す水平のずれ（y は 0）。重なっていなければ None。
    /// 真ん中が箱の中にある時と、真上か真下から触れている時は、水平の成分を持つ箱の向きのうち一番浅い向きへ出す。
    pub def pushOutHorizontal(b: Box3d, center: Vec3.Vec3, radius: Float64): Option[Vec3.Vec3] =
        let l = toLocal(b, center);
        let d = toWorldDir(b, Vec3.sub(unwrap(l), clampInside(b, l)));
        let dist = Vec3.length(d);
        if (not (dist < radius)) None
        else if (dist > 0.000001) {
            let flat = Vec2.sqrt(d#x * d#x + d#z * d#z);
            let v2 = Float64.max(0.0, dist * dist - flat * flat);
            // WhyNot: 差の向きの長さ (radius − dist) をそのまま水平へ写さない — 傾いた面（斜めの手すりの端）では押し切れず、割って補うと押し過ぎる。
            // 縦の差はそのままにして、水平の差が sqrt(radius² − 縦の差²) になるまで差の水平の向きへ動かす。
            if (flat > 0.02 * radius) {
                let k = (Vec2.sqrt(radius * radius - v2) - flat) / flat;
                Some(Vec3.v3(d#x * k, 0.0, d#z * k))
            }
            else insidePush(b, l, radius) |> Option.map(limitLength(radius))
        }
        else insidePush(b, l, radius)

    /// 水平のずれの長さを m までに抑える（1 回の押し出しで体が大きく飛ばない）。
    def limitLength(m: Float64, p: Vec3.Vec3): Vec3.Vec3 =
        let len = Vec3.length(p);
        if (len <= m) p else Vec3.mul(p, m / len)

    /// 真ん中が箱の中（か真上・真下）にある球を、水平の成分を持つ箱の向きのうち一番浅い向きへ出すずれ。
    def insidePush(b: Box3d, local: Local, radius: Float64): Option[Vec3.Vec3] =
        let l = unwrap(local);
        ((b#ax, b#half#x, l#x) :: (b#ay, b#half#y, l#y) :: (b#az, b#half#z, l#z) :: Nil)
            |> List.filter(e -> { let (a, _, _) = e; Vec2.sqrt(a#x * a#x + a#z * a#z) > 0.5 })
            |> List.map(e -> { let (a, h, v) = e; (h - Float64.abs(v), a, if (v >= 0.0) 1.0 else -1.0) })
            |> List.minimumBy((p, q) -> { let (dp, _, _) = p; let (dq, _, _) = q; Order.compare(dp, dq) })
            |> Option.map(e -> {
                let (depth, a, sign) = e;
                let k = (depth + radius) * sign;
                Vec3.v3(a#x * k, 0.0, a#z * k)
            })

    // ════════════════════════════════════════════════════════════════════
    // 調べる時の表示
    // ════════════════════════════════════════════════════════════════════

    /// 箱の列の 12 本の辺を細い角柱にした線の形（場面に重ねても中が見える）。`Scene3d.meshInstance(m, Mat4.identity())` で置く。
    pub def debugMesh(boxes: List[Box3d], color: Color): Mesh3d.Mesh3d =
        boxes |> List.flatMap(b -> {
            let cs = cornersOfBox(b) |> List.toVector;
            boxEdges() |> List.flatMap(e -> { let (i, j) = e; bar(Vector.get(i, cs), Vector.get(j, cs), color) })
        }) |> Mesh3d.fromPolygons

    /// 箱の 12 本の辺（cornersOfBox の番号の組）。
    def boxEdges(): List[(Int32, Int32)] =
        (0, 1) :: (1, 2) :: (2, 3) :: (3, 0) :: (4, 5) :: (5, 6) :: (6, 7) :: (7, 4) :: (0, 4) :: (1, 5) :: (2, 6) :: (3, 7) :: Nil

    /// 辺の太さ（m）。
    def barThickness(): Float64 = 0.015

    /// a から b への細い角柱の 4 つの横の面（長さ 0 の辺は面を作らない）。
    def bar(a: Vec3.Vec3, b: Vec3.Vec3, color: Color): List[Mesh3d.Polygon] =
        let d = Vec3.normalized(Vec3.sub(b, a));
        if (Vec3.length(d) < 0.5) Nil
        else {
            let pick = if (Float64.abs(d#y) < 0.9) Vec3.v3(0.0, 1.0, 0.0) else Vec3.v3(1.0, 0.0, 0.0);
            let u = Vec3.mul(Vec3.normalized(Vec3.cross(d, pick)), barThickness());
            let v = Vec3.mul(Vec3.normalized(Vec3.cross(d, u)), barThickness());
            let sides = (u, v) :: (v, Vec3.mul(u, -1.0)) :: (Vec3.mul(u, -1.0), Vec3.mul(v, -1.0)) :: (Vec3.mul(v, -1.0), u) :: Nil;
            sides |> List.map(s -> {
                let (p, q) = s;
                let pts = Vec3.add(a, p) :: Vec3.add(b, p) :: Vec3.add(b, q) :: Vec3.add(a, q) :: Nil;
                { points = facingOut(Vec3.add(p, q), pts), color = color }
            })
        }

    /// 頂点の並びを、外（out の向き）から見て時計回りに並べ直す（Newell の法線が out を向かなければ逆順）。
    def facingOut(out: Vec3.Vec3, pts: List[Vec3.Vec3]): List[Vec3.Vec3] =
        let pairs = List.zip(pts, List.append(List.drop(1, pts), List.take(1, pts)));
        let n = pairs |> List.foldLeft((acc, e) -> {
            let (a, b) = e;
            Vec3.v3(acc#x + (a#y - b#y) * (a#z + b#z), acc#y + (a#z - b#z) * (a#x + b#x), acc#z + (a#x - b#x) * (a#y + b#y))
        }, Vec3.zero());
        if (Vec3.dot(n, out) >= 0.0) pts else List.reverse(pts)
}
