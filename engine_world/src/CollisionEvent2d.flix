// CollisionEvent2d — 2D の剛体の当たり始め・離れた（Rapier の CollisionEvent）。PhysicsWorld2d.events(w)#collisions が直前の 1 刻みの分を返し、
// `App.addPhysics2d`（予定） の onEvents が刻みごとに受け取る。組の id は小さい方が先。
// 当たり始めは離れが 1 cm 以下になった刻み・離れたは 2 cm を超えた刻み（見た目で触れる前に Started を出さない）。
// 眠った島の組は触れたままと見て Stopped を出さない。体を消すと、その体の組に removed = true の Stopped が出る（消した後の次の刻みの出来事）。
pub mod CollisionEvent2d {

    pub enum CollisionEvent2d with Eq, Order, ToString {
        case Started(EntityId, EntityId)
        /// 3 つ目は removed（どちらかの体を消したので離れた）。
        case Stopped(EntityId, EntityId, Bool)
    }

    /// Started なら組。
    pub def startedPair(e: CollisionEvent2d): Option[(EntityId, EntityId)] = match e {
        case CollisionEvent2d.Started(a, b) => Some((a, b))
        case CollisionEvent2d.Stopped(_, _, _) => None
    }

    /// Stopped なら組（消した体の組も入る）。
    pub def stoppedPair(e: CollisionEvent2d): Option[(EntityId, EntityId)] = match e {
        case CollisionEvent2d.Started(_, _) => None
        case CollisionEvent2d.Stopped(a, b, _) => Some((a, b))
    }

    /// 組（どちらの出来事でも）。
    pub def pairOf(e: CollisionEvent2d): (EntityId, EntityId) = match e {
        case CollisionEvent2d.Started(a, b) => (a, b)
        case CollisionEvent2d.Stopped(a, b, _) => (a, b)
    }

    /// 体を消したので出た Stopped か。
    pub def isRemoved(e: CollisionEvent2d): Bool = match e {
        case CollisionEvent2d.Started(_, _) => false
        case CollisionEvent2d.Stopped(_, _, removed) => removed
    }
}
