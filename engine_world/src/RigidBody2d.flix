// RigidBody2d — 2D の剛体の作り（Rapier の RigidBodyBuilder）。PhysicsWorld2d.insert(id, body, w) で World へ足す。
// 向きは Rot2 で渡す（角度は受けない。角度から作るなら Rot2.fromDegrees）。単位は m・秒・kg。y は下が正（画面と同じ向き）。
pub mod RigidBody2d {

    /// Dynamic = 重力と押し合いで動く・Kinematic = 重さ無限で、ゲームが setKinematicTarget か速さで動かす・Fixed = 動かない（床・壁）。
    pub enum BodyType with Eq, ToString {
        case Dynamic
        case Kinematic
        case Fixed
    }

    enum BodyOf {
        case BodyOf({ bodyType = BodyType, position = Vec2.Vec2, rotation = Rot2.Rot2,
                      linearVelocity = Vec2.Vec2, angularVelocity = Float64, collider = Collider2d.Collider2d })
    }

    /// 体の作り。作るのは dynamic・kinematic・fixed、差し替えるのは with*。
    pub type alias RigidBody2d = BodyOf

    def of(bodyType: BodyType, position: Vec2.Vec2, collider: Collider2d.Collider2d): RigidBody2d =
        BodyOf.BodyOf({ bodyType = bodyType, position = position, rotation = Rot2.identity(),
                        linearVelocity = Vec2.zero(), angularVelocity = 0.0, collider = collider })

    def data(b: RigidBody2d): { bodyType = BodyType, position = Vec2.Vec2, rotation = Rot2.Rot2,
                                linearVelocity = Vec2.Vec2, angularVelocity = Float64, collider = Collider2d.Collider2d } =
        match b { case BodyOf.BodyOf(d) => d }

    /// 重力と押し合いで動く体（位置は m・重心の位置）。
    pub def dynamic(position: Vec2.Vec2, collider: Collider2d.Collider2d): RigidBody2d = of(BodyType.Dynamic, position, collider)

    /// 重さ無限で、ゲームが動かす体（動く床・押す主役）。
    pub def kinematic(position: Vec2.Vec2, collider: Collider2d.Collider2d): RigidBody2d = of(BodyType.Kinematic, position, collider)

    /// 動かない体（床・壁）。
    pub def fixed(position: Vec2.Vec2, collider: Collider2d.Collider2d): RigidBody2d = of(BodyType.Fixed, position, collider)

    pub def withRotation(rotation: Rot2.Rot2, b: RigidBody2d): RigidBody2d = BodyOf.BodyOf({ rotation = rotation | data(b) })

    /// 速さ（m/s）。
    pub def withLinearVelocity(v: Vec2.Vec2, b: RigidBody2d): RigidBody2d = BodyOf.BodyOf({ linearVelocity = v | data(b) })

    /// 回る速さ（rad/s。y が下向きの座標では正が時計回りに見える）。
    pub def withAngularVelocity(w: Float64, b: RigidBody2d): RigidBody2d = BodyOf.BodyOf({ angularVelocity = w | data(b) })

    pub def withCollider(c: Collider2d.Collider2d, b: RigidBody2d): RigidBody2d = BodyOf.BodyOf({ collider = c | data(b) })

    pub def bodyTypeOf(b: RigidBody2d): BodyType = data(b)#bodyType

    pub def positionOf(b: RigidBody2d): Vec2.Vec2 = data(b)#position

    pub def rotationOf(b: RigidBody2d): Rot2.Rot2 = data(b)#rotation

    pub def linearVelocityOf(b: RigidBody2d): Vec2.Vec2 = data(b)#linearVelocity

    pub def angularVelocityOf(b: RigidBody2d): Float64 = data(b)#angularVelocity

    pub def colliderOf(b: RigidBody2d): Collider2d.Collider2d = data(b)#collider
}
