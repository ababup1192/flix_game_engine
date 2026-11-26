// PhysicsWorld2d.Internal.Data — 物理の World の中身（欄ごとの Vector・structure of arrays）と、刻みをまたいで持つ控え。
// ゲームからは呼ばない（PhysicsWorld2d が非 pub の enum で包んで外へ出す）。
pub mod PhysicsWorld2d.Internal.Data {
    use PhysicsWorld2d.Internal.Shape.Shape

    /// gravity = 重力（m/s²・y は下が正）・solverSubsteps = 1 刻みを割る回数（soft step・Box2D 3 の subStepCount）・
    /// sleepLinearThreshold・sleepAngularThreshold = 眠りのしきい（m/s・rad/s。島の全部の体が 0.5 秒続けて下回ったら眠る。0 以下なら眠らない）。
    pub type alias Settings = { gravity = Vec2.Vec2, solverSubsteps = Int32, sleepLinearThreshold = Float64, sleepAngularThreshold = Float64 }

    /// 1 刻みの出来事（当たり始め・離れた・sensor に入った・出た）。
    pub type alias Events = { collisions = List[CollisionEvent2d.CollisionEvent2d], sensors = List[SensorEvent2d.SensorEvent2d] }

    /// warm start の控え: 組の鍵を小さい順に並べた Vector と、組ごとに 2 つの枠（特徴の番号・法線の衝撃・接線の衝撃。空の枠は特徴 -1）。
    // WhyNot: Map で持たない — 木への挿し込みと引きが 1 刻みの 1 割を食った。並べた配列と二分探索にした。
    // WhyNot: 鍵を (a << 40 | b << 16 | 特徴) の 1 語にしない — id が 2^23 を超えるとぶつかる。組の鍵（a と b の 32 bit ずつ）と特徴を分けて持つ。
    pub type alias Warm = (Vector[Int64], Vector[Int32], Vector[Float64], Vector[Float64])

    /// 体の欄（どれも id の順。state は stride 8: x・y・cos・sin・vx・vy・w・眠りの時計。prev は stride 4: 前の刻みの x・y・cos・sin。
    /// props は stride 3: 粗い当たりの半径・重さの逆数・慣性の逆数）。
    // WhyNot: Vector[Body] で持たない — 毎刻み体の record を全部作り直し、欄を名前で探して書き戻す代金が 1 刻みの 3 割を食った。
    pub type alias Data = {
        ids = Vector[Int32], types = Vector[RigidBody2d.BodyType], colliders = Vector[Collider2d.Collider2d], shapes = Vector[Shape],
        materialIndex = Vector[Int32], props = Vector[Float64], state = Vector[Float64], prev = Vector[Float64], asleep = Vector[Bool],
        targets = Map[Int32, (Float64, Float64, Float64, Float64)],
        warm = Warm, touching = Vector[Int64], sensing = Vector[Int64],
        pending = List[Events], events = Events,
        settings = Settings, stepSeconds = Float64,
        materials = Vector[PhysicsMaterial.PhysicsMaterial], materialNames = Map[String, Int32],
        warned = Set[String], steps = Int64
    }

    pub def stateStride(): Int32 = 8
    pub def prevStride(): Int32 = 4
    pub def propStride(): Int32 = 3

    pub def noEvents(): Events = { collisions = Nil, sensors = Nil }

    pub def emptyWarm(): Warm = (Vector.empty(), Vector.empty(), Vector.empty(), Vector.empty())

    /// 組 (a, b)（a < b の id）の鍵。a を上の 32 bit・b を下の 32 bit に置くので、id の値の範囲によらずぶつからない。
    pub def pairKey(a: Int32, b: Int32): Int64 =
        Int64.bitwiseOr(Int64.leftShift(Int32.toInt64(a), 32), Int64.bitwiseAnd(Int32.toInt64(b), 4294967295i64))

    pub def pairA(key: Int64): Int32 = Int64.tryToInt32(Int64.rightShift(key, 32)) |> Option.getWithDefault(0)

    pub def pairB(key: Int64): Int32 =
        let low = Int64.bitwiseAnd(key, 4294967295i64);
        Int64.tryToInt32(if (low > 2147483647i64) low - 4294967296i64 else low) |> Option.getWithDefault(0)

    /// 並んだ keys の lo〜hi から key の位置（無ければ -1）。
    pub def searchKey(key: Int64, keys: Vector[Int64], lo: Int32, hi: Int32): Int32 =
        if (lo > hi) -1
        else {
            let mid = lo + (hi - lo) / 2;
            let k = Vector.get(mid, keys);
            if (k == key) mid else if (k < key) searchKey(key, keys, mid + 1, hi) else searchKey(key, keys, lo, mid - 1)
        }

    /// 並んだ ids から id の位置（無ければ None）。
    pub def indexOf(id: Int32, ids: Vector[Int32]): Option[Int32] = searchId(id, ids, 0, Vector.length(ids) - 1)

    def searchId(id: Int32, ids: Vector[Int32], lo: Int32, hi: Int32): Option[Int32] =
        if (lo > hi) None
        else {
            let mid = lo + (hi - lo) / 2;
            let k = Vector.get(mid, ids);
            if (k == id) Some(mid) else if (k < id) searchId(id, ids, mid + 1, hi) else searchId(id, ids, lo, mid - 1)
        }

    /// id を入れる位置（id より小さい物の数）。
    pub def insertionPoint(id: Int32, ids: Vector[Int32]): Int32 = lowerBound(id, ids, 0, Vector.length(ids))

    def lowerBound(id: Int32, ids: Vector[Int32], lo: Int32, hi: Int32): Int32 =
        if (lo >= hi) lo
        else {
            let mid = lo + (hi - lo) / 2;
            if (Vector.get(mid, ids) < id) lowerBound(id, ids, mid + 1, hi) else lowerBound(id, ids, lo, mid)
        }

    pub def isFinite(x: Float64): Bool = not Float64.isNan(x) and not Float64.isInfinite(x)

    /// 同じ文面を 1 回だけ言う（言った文面を warned に覚える）。
    pub def warnOnce(line: String, d: Data): Data =
        if (Set.memberOf(line, d#warned)) d
        else Log.warnThen(line, { warned = Set.insert(line, d#warned) | d })
}
