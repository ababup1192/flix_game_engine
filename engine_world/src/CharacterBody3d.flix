// CharacterBody3d — 3D の部屋を一人称で歩く体（純粋: 前の体 + 動く速さ + 秒 → 次の体）。Godot の CharacterBody3D.move_and_slide・
// Unity の CharacterController.Move に当たる。2D の体は Physics2D・当たり判定の形は engine の CollisionShape3d。
//
// 体は足元の点と足の着き方（Footing）だけを持つ。向き（yaw・pitch）・足音・頭の上下はゲームが持つ。
// 壁は向きのある箱（CollisionShape3d.Box3d）。体は縦に並べた球の列で、足元から段の高さより上だけを壁として扱う
// （段の高さより低い物は上に乗る）。床は体の真ん中から真下へ伸ばしたレイが最初に当たる箱の上の面。
// 水平の動きは 1 回に進む距離が maxSubstep を超えないよう細かく区切り、区切りごとに
// 「押し出し → 床に乗るか落ちる」の順で進める（速く走っても薄い壁を抜けない）。
pub mod CharacterBody3d {

    /// 体の寸法と動き方。radius = 体の半径（m）・height = 体の高さ・stepHeight = そのまま上がれる段の高さ・
    /// floorMaxAngleDeg = 床として乗れる面の傾きの上限（度。面の向きと真上の角。超える面は壁）・
    /// snapLength = 立っている間に下の床へ吸い付く深さ（階段を下りても浮かない）・gravity = 重力（m/秒²）・
    /// maxSubstep = 1 回の押し出しで進む水平の距離の上限（m。体の半径の半分以下にする — 押し出しは食い込みの浅い側へ出すので、
    /// 1 回で体の半分より深く入ると反対側へ抜けうる）。
    /// 字で全部の欄を書かず `{ stepHeight = .. | CharacterBody3d.settings(r, h) }` の形で替える（欄が増えても止まらない）。
    pub type alias Settings = { radius = Float64, height = Float64, stepHeight = Float64, floorMaxAngleDeg = Float64,
                                snapLength = Float64, gravity = Float64, maxSubstep = Float64 }

    /// 半径 radius・高さ height の体の既定の動き方: 段 0.3 m・床の傾き 45°（Godot の既定）・吸い付き 0.45 m・重力 9.8・
    /// 区切り min(0.05, radius / 2)。
    pub def settings(radius: Float64, height: Float64): Settings =
        { radius = radius, height = height, stepHeight = 0.3, floorMaxAngleDeg = 45.0, snapLength = 0.45, gravity = 9.8,
          maxSubstep = Float64.min(0.05, radius / 2.0) }

    /// 立っている床。y = 床の高さ・normal = 床の面の向き（長さ 1）・sloped = 床の箱が傾いている（箱のどの軸も真上から 11.5° より離れている。
    /// 足音の種類を分ける時に使う）。
    pub type alias Floor = { y = Float64, normal = Vec3.Vec3, sloped = Bool }

    /// 足の着き方。OnFloor = 床に立っている・Airborne = 落ちている（縦の速さ m/秒・上が正）。
    pub enum Footing {
        case OnFloor(Floor)
        case Airborne(Float64)
    }

    /// 体の状態。feet = 足元の点（体の真ん中の真下）・footing = 足の着き方。
    pub type alias Body = { feet = Vec3.Vec3, footing = Footing }

    /// 足元 feet に置いた、まだ床に着いていない体（縦の速さ 0）。始まりは `snapToFloor` で床に合わせる（合わせなければ次の moveAndSlide から落ちる）。
    pub def bodyAt(feet: Vec3.Vec3): Body = { feet = feet, footing = Footing.Airborne(0.0) }

    /// 床に立っているか。
    pub def isOnFloor(b: Body): Bool = match b#footing {
        case Footing.OnFloor(_)  => true
        case Footing.Airborne(_) => false
    }

    /// 1 回の moveAndSlide で進める秒の上限（ヒッチで 1 コマが長くても区切りの数が膨らまない）。
    def maxStepSeconds(): Float64 = 0.25

    /// 1 回の moveAndSlide の区切りの数の上限。
    def maxSubsteps(): Int32 = 4096

    /// snapToFloor が下へ探す深さ（m）。
    def snapSearchDepth(): Float64 = 20.0

    // ════════════════════════════════════════════════════════════════════
    // 進める
    // ════════════════════════════════════════════════════════════════════

    /// 体を dt 秒進める。motion = 水平の速さ（m/秒。y は使わない — 縦の速さは footing が持ち、跳ぶ口は無い）・
    /// world = 動かない箱・moving = このコマの動く箱（扉の板。world の箱の後に、この並びの順で押し出す）。
    /// 立っていて motion が 0 なら体は 1 bit も動かない（動く箱が食い込んだ時だけ押し出す。足元の床が消えていれば落ち始める）。
    /// dt は 0〜0.25 秒に収める（NaN は 0）。motion に NaN・無限大があれば水平に動かない。
    /// 区切りは 4096 回まで（既定の区切り 5 cm で 1 コマ 0.25 秒なら約 820 m/秒まで。それより速いと区切りが長くなり薄い壁を抜けうる）。
    pub def moveAndSlide(world: CollisionWorld3d.CollisionWorld3d, moving: List[CollisionShape3d.Box3d], s: Settings,
                         motion: Vec3.Vec3, dt: Float64, b: Body): Body =
        let step = if (dt > 0.0) Float64.min(maxStepSeconds(), dt) else 0.0;
        let finite = Float64.isFinite(motion#x) and Float64.isFinite(motion#z);
        let (vx, vz) = if (finite) (motion#x, motion#z) else (0.0, 0.0);
        let travel = Num.sqrt(vx * vx + vz * vz) * step;
        let n = Int32.min(maxSubsteps(), Int32.max(1, Float64.tryToInt32(Float64.ceil(travel / substepLength(s))) |> Option.getWithDefault(maxSubsteps())));
        let near = nearBoxes(world, moving, s, b#feet, travel);
        let sub = step / Int32.toFloat64(n);
        let moved = List.range(0, n) |> List.foldLeft((acc, _) -> substep(near, s, vx * sub, vz * sub, sub, acc), b);
        pushedBy(near, moving, s, moved)

    /// 同じ速さと同じ秒で n コマ moveAndSlide した体の列（1 コマ目の後から n コマ目の後まで）。
    /// テストと、操作を記録した手順から挟まった所を探す時に使う。
    pub def simulate(world: CollisionWorld3d.CollisionWorld3d, moving: List[CollisionShape3d.Box3d], s: Settings,
                     motion: Vec3.Vec3, dt: Float64, n: Int32, b: Body): List[Body] =
        List.range(0, n) |> List.foldLeft((acc, _) -> {
            let (cur, out) = acc;
            let next = moveAndSlide(world, moving, s, motion, dt, cur);
            (next, next :: out)
        }, (b, Nil)) |> snd |> List.reverse

    /// 足元を下の床に合わせた体（足元から段の高さより上を探し始め、下へ 20 m まで。床が無ければそのまま）。
    /// 始まりと置き直しで使う（Godot の apply_floor_snap）。上の階に立たせる時は feet の y にその階のおおよその高さを入れる。
    pub def snapToFloor(world: CollisionWorld3d.CollisionWorld3d, moving: List[CollisionShape3d.Box3d], s: Settings, b: Body): Body =
        let near = nearBoxes(world, moving, s, b#feet, 0.0);
        match groundBelow(near, s, b#feet#x, b#feet#y, b#feet#z, snapSearchDepth()) {
            case Some(g) => { feet = Vec3.v3(b#feet#x, g#y, b#feet#z), footing = Footing.OnFloor(g) }
            case None    => b
        }

    /// 体が箱に食い込んでいる一番深い所（m。0 なら食い込んでいない）。段の高さより下は見ない（乗る物なので）。
    pub def overlapDepth(world: CollisionWorld3d.CollisionWorld3d, moving: List[CollisionShape3d.Box3d], s: Settings, b: Body): Float64 =
        deepest(nearBoxes(world, moving, s, b#feet, 0.0), s, b#feet#x, b#feet#y, b#feet#z)

    /// 押し出しに使う体の形（足元の段の高さより上の、縦のカプセル）。扉を回す前と後で `CollisionShape3d.penetration` を比べる時に使う。
    pub def capsuleOf(s: Settings, b: Body): CollisionShape3d.Capsule3d = capsuleAt(s, b#feet#x, b#feet#y, b#feet#z)

    /// 体の範囲を囲む軸にそろった箱（足元から height まで・水平は ±radius。Bevy の Collider の aabb・Godot の get_aabb に当たる）。
    /// 段の高さより下も含む体全体（押し出しに使う形は capsuleOf）。`CollisionShape3d.boxOfBounds(Mat4.identity(), ..)` で箱にでき、`debugMesh` で描ける。
    pub def aabbOf(s: Settings, b: Body): Mesh3d.Bounds =
        let r = Float64.max(0.0, s#radius);
        let h = Float64.max(0.0, s#height);
        { min = Vec3.v3(b#feet#x - r, b#feet#y, b#feet#z - r), max = Vec3.v3(b#feet#x + r, b#feet#y + h, b#feet#z + r) }

    def capsuleAt(s: Settings, x: Float64, feet: Float64, z: Float64): CollisionShape3d.Capsule3d =
        { feet = Vec3.v3(x, feet + s#stepHeight, z), radius = s#radius, height = Float64.max(2.0 * s#radius, s#height - s#stepHeight) }

    /// 区切り 1 回の長さ（maxSubstep が小さすぎる・NaN の時は 1 mm）。
    def substepLength(s: Settings): Float64 = if (s#maxSubstep > 0.001) s#maxSubstep else 0.001

    /// 体の周りの箱: 動かない箱を足元から水平に (進む距離 + 直径 + 1 m) の範囲で引き、その後に動く箱。
    def nearBoxes(world: CollisionWorld3d.CollisionWorld3d, moving: List[CollisionShape3d.Box3d], s: Settings,
                  feet: Vec3.Vec3, travel: Float64): List[CollisionShape3d.Box3d] =
        List.append(CollisionWorld3d.boxesNear(world, feet, travel + 2.0 * Float64.max(0.0, s#radius) + 1.0), moving)

    /// 区切り 1 つ: 水平に (dx, dz) 動いて壁から出し、床に乗るか落ちる。
    /// 立っていて動かない区切りは押し出しも床合わせもせず、足元の床がまだあるかだけを見る（止まっている時に位置が震えない）。
    def substep(near: List[CollisionShape3d.Box3d], s: Settings, dx: Float64, dz: Float64, dt: Float64, b: Body): Body =
        if (dx == 0.0 and dz == 0.0 and isOnFloor(b)) keepFloorOrFall(near, s, b)
        else {
            let (nx, nz) = resolve(near, s, b#feet#x + dx, b#feet#y, b#feet#z + dz);
            let (feet, footing) = fall(near, s, nx, nz, dt, b);
            // WhyNot: 押し出しと床合わせの後でも前より深く食い込む動き（下から段板の低い端へ潜り込む・角で押し合う）を通さない —
            // 通すと次の区切りの押し出しが反対側へ出して壁を抜ける。水平には動かず、落ちる・立つの縦だけ残す。
            let before = deepest(near, s, b#feet#x, b#feet#y, b#feet#z);
            let after = deepest(near, s, nx, feet, nz);
            if (after > Float64.max(0.005, before)) verticalOnly(near, s, dt, b)
            else { feet = Vec3.v3(nx, feet, nz), footing = footing }
        }

    /// 水平に動かない区切りの体（落ちている間は落ち続けて下の床に着き・立っていればそのまま）。
    def verticalOnly(near: List[CollisionShape3d.Box3d], s: Settings, dt: Float64, b: Body): Body =
        match b#footing {
            case Footing.OnFloor(_)  => b
            case Footing.Airborne(_) =>
                let (y, footing) = fall(near, s, b#feet#x, b#feet#z, dt, b);
                { feet = Vec3.v3(b#feet#x, y, b#feet#z), footing = footing }
        }

    /// 立っている体の足元（snapLength の中）に床がまだあれば、その床に立つ（高さの差が 1 mm 以下なら位置は 1 bit も変えない）。
    /// 無ければ落ち始める（止まっている間に足元の箱が外れた・動く箱に縁の外へ押し出された）。
    // WhyNot: 1 mm 以下の差では高さを合わせ直さない — 止まっている体が床の高さの丸めの差で上下に震える。
    def keepFloorOrFall(near: List[CollisionShape3d.Box3d], s: Settings, b: Body): Body =
        match groundBelow(near, s, b#feet#x, b#feet#y, b#feet#z, s#snapLength) {
            case Some(g) if Float64.abs(g#y - b#feet#y) > 0.001 => { feet = Vec3.v3(b#feet#x, g#y, b#feet#z), footing = Footing.OnFloor(g) }
            case Some(g) => { footing = Footing.OnFloor(g) | b }
            case None    => { footing = Footing.Airborne(0.0) | b }
        }

    /// 足元の高さと足の着き方の次の値。立っている間は snapLength の中で床に吸い付き、
    /// 床が無くなったら落ち始め、落ちている間は下の床に着いた所で止まる。
    def fall(near: List[CollisionShape3d.Box3d], s: Settings, x: Float64, z: Float64, dt: Float64, b: Body): (Float64, Footing) =
        match b#footing {
            case Footing.OnFloor(_) =>
                match groundBelow(near, s, x, b#feet#y, z, s#snapLength) {
                    case Some(g) => (g#y, Footing.OnFloor(g))
                    case None    => (b#feet#y, Footing.Airborne(0.0))
                }
            case Footing.Airborne(vy0) =>
                let vy = vy0 - s#gravity * dt;
                let next = b#feet#y + vy * dt;
                match groundBelow(near, s, x, b#feet#y, z, b#feet#y - next + 0.02) {
                    case Some(g) if g#y >= next => (g#y, Footing.OnFloor(g))
                    case _                      => (next, Footing.Airborne(vy))
                }
        }

    /// 動く箱に食い込んだ体を、周りの全部の箱の外へ水平に出した体（食い込んでいなければそのまま）。
    def pushedBy(near: List[CollisionShape3d.Box3d], moving: List[CollisionShape3d.Box3d], s: Settings, b: Body): Body =
        if (deepest(moving, s, b#feet#x, b#feet#y, b#feet#z) <= 0.0) b
        else {
            let (x, z) = resolve(near, s, b#feet#x, b#feet#y, b#feet#z);
            let pushed = { feet = Vec3.v3(x, b#feet#y, z) | b };
            if (isOnFloor(pushed)) keepFloorOrFall(near, s, pushed) else pushed
        }

    // ════════════════════════════════════════════════════════════════════
    // 押し出しと床
    // ════════════════════════════════════════════════════════════════════

    /// 足元 (x, feet, z) の体を箱の外へ出した水平の位置。球ごとに、箱を並びの順に 1 つずつ押し出し、それを 3 回くり返す
    /// （角で 2 枚に挟まれた時に、1 枚目へ押し戻された分を 2 回目以降で解く）。
    def resolve(boxes: List[CollisionShape3d.Box3d], s: Settings, x: Float64, feet: Float64, z: Float64): (Float64, Float64) =
        let heights = CollisionShape3d.sphereCentersOf(capsuleAt(s, 0.0, feet, 0.0)) |> List.map(c -> c#y);
        let once = (p: (Float64, Float64)) -> heights |> List.foldLeft((acc, h) ->
            boxes |> List.foldLeft((inner, box) -> {
                let (ix, iz) = inner;
                match CollisionShape3d.pushOutHorizontal(box, Vec3.v3(ix, h, iz), s#radius) {
                    case Some(d) => (ix + d#x, iz + d#z)
                    case None    => inner
                }
            }, acc), p);
        once(once(once((x, z))))

    /// 足元 (x, feet, z) の体が箱に食い込んでいる一番深い所。
    def deepest(boxes: List[CollisionShape3d.Box3d], s: Settings, x: Float64, feet: Float64, z: Float64): Float64 =
        let capsule = capsuleAt(s, x, feet, z);
        boxes |> List.foldLeft((acc, box) -> Float64.max(acc, CollisionShape3d.penetration(box, capsule)), 0.0)

    /// 足元 (x, feet, z) の下で、段の高さより上から下へ drop まで探した一番高い床。無ければ None。
    /// 体の真ん中の真下で決め、真ん中の下に床が無い時（板の継ぎ目・縁）だけ、半径の 0.6 倍だけ離れた 4 点から探す。
    /// WhyNot: 5 点の一番高い所を取らない — 斜めの手すりの端の面を縁の点が拾い、体が手すりに乗り上げて上下に震える。
    def groundBelow(boxes: List[CollisionShape3d.Box3d], s: Settings, x: Float64, feet: Float64, z: Float64, drop: Float64): Option[Floor] =
        let k = s#radius * 0.6;
        match probe(boxes, s, x, feet, z, drop) {
            case Some(g) => Some(g)
            case None    =>
                highest(probe(boxes, s, x + k, feet, z, drop) :: probe(boxes, s, x - k, feet, z, drop)
                        :: probe(boxes, s, x, feet, z + k, drop) :: probe(boxes, s, x, feet, z - k, drop) :: Nil)
        }

    /// (x, z) の真上の「足元 + 段の高さ」から真下へ (段の高さ + drop) まで伸ばしたレイが当たる、床として乗れる面のうち一番高い物。
    def probe(boxes: List[CollisionShape3d.Box3d], s: Settings, x: Float64, feet: Float64, z: Float64, drop: Float64): Option[Floor] =
        let top = feet + s#stepHeight;
        let ray = Ray3d.ray3d(Vec3.v3(x, top, z), Vec3.v3(0.0, -1.0, 0.0));
        let minUp = floorMinNormalY(s);
        boxes
            |> List.map(box -> Ray3d.hitBox(ray, s#stepHeight + drop, box)
                |> Option.filter(h -> h#normal#y >= minUp)
                |> Option.map(h -> { y = top - h#distance, normal = h#normal, sloped = isTilted(box) }))
            |> highest

    /// 床の列のうち一番高い物（同じ高さなら並びの前）。
    def highest(floors: List[Option[Floor]]): Option[Floor] =
        floors |> List.foldLeft((best, f) -> match (best, f) {
            case (Some(bf), Some(nf)) => if (nf#y > bf#y) f else best
            case (None, _)            => f
            case (_, None)            => best
        }, None)

    /// 床として乗れる面の向きの y の下限（floorMaxAngleDeg の cos。角は 0〜90 に収め、NaN は 45）。
    def floorMinNormalY(s: Settings): Float64 =
        let deg = if (s#floorMaxAngleDeg >= 0.0) Float64.min(90.0, s#floorMaxAngleDeg) else if (s#floorMaxAngleDeg < 0.0) 0.0 else 45.0;
        Num.cos(deg * Num.pi() / 180.0) - 1.0e-9

    /// 箱が傾いているか（3 本の向きのどれも、真上から 11.5° より離れている）。Floor の sloped と同じ判定。
    /// 床の箱を坂と平らな床に分ける時（足音の種類・滑る床）に、立っていない箱にも使える。
    pub def isTilted(b: CollisionShape3d.Box3d): Bool =
        Float64.abs(b#ax#y) < 0.98 and Float64.abs(b#ay#y) < 0.98 and Float64.abs(b#az#y) < 0.98
}
