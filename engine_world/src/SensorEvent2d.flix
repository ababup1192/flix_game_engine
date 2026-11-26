// SensorEvent2d — sensor の形（Collider2d.withSensor）に体が入った・出た（Rapier の sensor の CollisionEvent・Godot の Area2D の body_entered）。
// 1 つ目の id が sensor、2 つ目が入った体。入ったは形が重なった刻み・出たは重ならなくなった刻み。
// 動かない体（Fixed）と sensor どうしは出来事を出さない。眠った体は中に居るままと見る。体を消すと removed = true の Stopped。
pub mod SensorEvent2d {

    pub enum SensorEvent2d with Eq, Order, ToString {
        case Started(EntityId, EntityId)
        /// 3 つ目は removed（どちらかの体を消したので出た）。
        case Stopped(EntityId, EntityId, Bool)
    }

    /// Started なら (sensor, 入った体)。
    pub def startedPair(e: SensorEvent2d): Option[(EntityId, EntityId)] = match e {
        case SensorEvent2d.Started(s, o) => Some((s, o))
        case SensorEvent2d.Stopped(_, _, _) => None
    }

    /// Stopped なら (sensor, 出た体)。
    pub def stoppedPair(e: SensorEvent2d): Option[(EntityId, EntityId)] = match e {
        case SensorEvent2d.Started(_, _) => None
        case SensorEvent2d.Stopped(s, o, _) => Some((s, o))
    }

    pub def isRemoved(e: SensorEvent2d): Bool = match e {
        case SensorEvent2d.Started(_, _) => false
        case SensorEvent2d.Stopped(_, _, removed) => removed
    }
}
