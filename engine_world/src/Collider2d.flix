// Collider2d — 2D の剛体の中の形（Rapier の ColliderBuilder・Godot の CollisionShape2D と collision_layer）。
// 形は体の座標で持つ（円・箱・凸多角形 8 頂点まで）。材質は名前で指し（PhysicsWorld2d.withMaterials の表で引く）、
// sensor の形は押し返さず、入った・出たの出来事（SensorEvent2d）だけを出す。
pub mod Collider2d {
    use PhysicsWorld2d.Internal.Shape.Shape

    enum ColliderOf {
        case ColliderOf({ shape = Shape, material = String, sensor = Bool, layer = Int32, mask = Int32, mass = Option[Float64] })
    }

    /// 体の中の形。作るのは circle・box・convex、差し替えるのは with*。
    pub type alias Collider2d = ColliderOf

    def of(shape: Shape): Collider2d =
        ColliderOf.ColliderOf({ shape = shape, material = "", sensor = false, layer = 1, mask = -1, mass = None })

    def data(c: Collider2d): { shape = Shape, material = String, sensor = Bool, layer = Int32, mask = Int32, mass = Option[Float64] } =
        match c { case ColliderOf.ColliderOf(d) => d }

    /// 半径 radius（m）の円。0 以下・NaN は 0.01 m にして 1 行言う。
    pub def circle(radius: Float64): Collider2d = of(PhysicsWorld2d.Internal.Shape.circle(positive("circle", radius)))

    /// 半分の幅・半分の高さ（m）の箱。中心が体の位置。
    pub def box(halfWidth: Float64, halfHeight: Float64): Collider2d =
        of(PhysicsWorld2d.Internal.Shape.box(positive("box", halfWidth), positive("box", halfHeight)))

    /// 点の列の凸包（体の座標）。凸包の重心が体の位置になるよう頂点を動かして持つ（重心と体の位置を分けない）。
    /// 点が 1 直線に並ぶ時は 0.01 m の箱にして 1 行言う。8 頂点を超える凸包はそのまま使って 1 行言う（重い）。
    pub def convex(points: List[Vec2.Vec2]): Collider2d =
        match PhysicsWorld2d.Internal.Shape.convexHull(points |> List.map(p -> (p#x, p#y))) {
            case None => Log.fellBackThen("Collider2d", "convex", "0.01 m の箱", "点が 3 つ未満か 1 直線に並ぶ", box(0.01, 0.01))
            case Some((shape, _)) =>
                let c = of(shape);
                if (PhysicsWorld2d.Internal.Shape.vertexCount(shape) > 8)
                    Log.warnThen("[Collider2d] convex の頂点が 8 を超えた（${PhysicsWorld2d.Internal.Shape.vertexCount(shape)} 個）。当たりが重くなる", c)
                else c
        }

    def positive(what: String, x: Float64): Float64 =
        if (x > 0.0 and not Float64.isInfinite(x)) x
        else Log.fellBackThen("Collider2d", what, "0.01 m", "大きさが 0 以下か NaN・無限大（${x}）", 0.01)

    /// 材質の名前（PhysicsWorld2d.withMaterials の表の鍵。引けない名前は既定の材質で続けて 1 回だけ言う）。
    pub def withMaterial(name: String, c: Collider2d): Collider2d = ColliderOf.ColliderOf({ material = name | data(c) })

    /// sensor にする（押し返さず、SensorEvent2d の Started・Stopped だけを出す。Godot の Area2D）。
    pub def withSensor(sensor: Bool, c: Collider2d): Collider2d = ColliderOf.ColliderOf({ sensor = sensor | data(c) })

    /// 当たり層（Godot と同じ 32 bit）。layer = 自分が居る層・mask = 当たる相手の層。2 つの形は「a の層が b の mask に入り、かつ b の層が a の mask に入る」時だけ当たる。
    /// 既定は layer 1・mask 全部。
    pub def withCollisionLayers(layer: Int32, mask: Int32, c: Collider2d): Collider2d =
        ColliderOf.ColliderOf({ layer = layer, mask = mask | data(c) })

    /// 重さ（kg）を直に決める（密度 × 面積の代わり。慣性も同じ割合で直す）。0 以下・NaN は効かせず 1 行言う。
    pub def withMass(mass: Float64, c: Collider2d): Collider2d =
        if (mass > 0.0 and not Float64.isInfinite(mass)) ColliderOf.ColliderOf({ mass = Some(mass) | data(c) })
        else Log.fellBackThen("Collider2d", "withMass", "密度 × 面積", "重さが 0 以下か NaN・無限大（${mass}）", c)

    // ── 読む口（描く・当たりの中身） ──

    /// 円なら半径。
    pub def circleRadius(c: Collider2d): Option[Float64] = match data(c)#shape {
        case Shape.Circle(r) => Some(r)
        case Shape.Polygon(_, _, _, _) => None
    }

    /// 多角形なら体の座標の頂点（反時計回り。円は空）。描く時は Rot2.rotate して体の位置を足す。
    pub def vertices(c: Collider2d): List[Vec2.Vec2] = match data(c)#shape {
        case Shape.Circle(_) => Nil
        case Shape.Polygon(xs, ys, _, _) => Vector.zipWith((x, y) -> ({ x = x, y = y }: Vec2.Vec2), xs, ys) |> Vector.toList
    }

    pub def materialName(c: Collider2d): String = data(c)#material

    pub def isSensor(c: Collider2d): Bool = data(c)#sensor

    pub def collisionLayer(c: Collider2d): Int32 = data(c)#layer

    pub def collisionMask(c: Collider2d): Int32 = data(c)#mask

    pub def massOverride(c: Collider2d): Option[Float64] = data(c)#mass

    /// 形（PhysicsWorld2d の中身が使う）。
    pub def shapeOf(c: Collider2d): Shape = data(c)#shape
}
