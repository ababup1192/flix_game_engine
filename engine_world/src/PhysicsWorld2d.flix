// PhysicsWorld2d — 2D の剛体の物理の World（Box2D の b2World・Rapier の PhysicsPipeline に当たる不変の値）。
// ゲームの World の欄に 1 つ置き、App.addPhysics2d が遊びの時計で貯めた固定刻みで step する（ゲームは step を呼ばない）。
// 体の id はゲームの EntityId。形は円・箱・凸多角形（8 頂点まで）。関節・CCD・凹んだ形は無い。
// 単位は m・秒・kg で、y は下が正（画面と同じ向き）。描く時は 1 m あたりの画素を掛ける。
// 決まり（docs/physics.md）: 同じ入力の World は JVM と wasm で同じビット・足す順によらない・巻き戻しても同じ。
// 位置の持ち主はここだけ。ゲームの store に位置を写して 2 か所に持たない（読むのは positionOf・bodies）。
pub mod PhysicsWorld2d {
    use PhysicsWorld2d.Internal.Data.Data

    enum WorldOf {
        case WorldOf(Data)
    }

    /// 物理の World。作るのは empty、変えるのは insert・remove・with*・set*（どれも新しい World を返す）。
    pub type alias PhysicsWorld2d = WorldOf

    /// gravity = 重力（m/s²・y は下が正）・solverSubsteps = 1 刻みを割る回数（soft step）・
    /// sleepLinearThreshold・sleepAngularThreshold = 眠りのしきい（m/s・rad/s。0 以下なら眠らない）。
    pub type alias Settings = PhysicsWorld2d.Internal.Data.Settings

    /// 1 刻みの出来事。collisions = 当たり始め・離れた（鍵の順）・sensors = sensor に入った・出た。
    pub type alias Events = PhysicsWorld2d.Internal.Data.Events

    /// 読む口が返す体 1 つ（bodies）。
    pub type alias BodyState = { id = EntityId, bodyType = RigidBody2d.BodyType, position = Vec2.Vec2, rotation = Rot2.Rot2,
                                 linearVelocity = Vec2.Vec2, angularVelocity = Float64, isSleeping = Bool, collider = Collider2d.Collider2d }

    /// 描く用の姿勢（interpolatedPoseOf）。
    pub type alias Pose2d = { position = Vec2.Vec2, rotation = Rot2.Rot2 }

    /// 光線の当たり（castRay）。normal は当たった面の外向き（長さ 1）。
    pub type alias RayHit2d = { id = EntityId, point = Vec2.Vec2, normal = Vec2.Vec2, distance = Float64 }

    /// 既定の設定: 重力 (0, 9.8)・substep 4 回・眠りのしきい 0.01 m/s・0.02 rad/s。
    pub def settings(): Settings =
        { gravity = { x = 0.0, y = 9.8 }, solverSubsteps = 4, sleepLinearThreshold = 0.01, sleepAngularThreshold = 0.02 }

    def data(w: PhysicsWorld2d): Data = match w { case WorldOf.WorldOf(d) => d }

    /// 空の World。stepSeconds は 1 刻みの秒（App.withFixedStep と同じ値。App.addPhysics2d がこの値と合っているか確かめる）。
    /// 刻みを World が持つので、step は dt を受けない（可変の dt で物理を進められない）。
    pub def empty(s: Settings, stepSeconds: Float64): PhysicsWorld2d =
        let step = if (stepSeconds > 0.0 and PhysicsWorld2d.Internal.Data.isFinite(stepSeconds)) stepSeconds
                   else Log.fellBackThen("PhysicsWorld2d", "empty", "1/60 秒", "刻みが 0 以下か NaN・無限大（${stepSeconds}）", 1.0 / 60.0);
        WorldOf.WorldOf({
            ids = Vector.empty(), types = Vector.empty(), colliders = Vector.empty(), shapes = Vector.empty(),
            materialIndex = Vector.empty(), props = Vector.empty(), state = Vector.empty(), prev = Vector.empty(), asleep = Vector.empty(),
            targets = Map.empty(), warm = PhysicsWorld2d.Internal.Data.emptyWarm(), touching = Vector.empty(), sensing = Vector.empty(),
            pending = Nil, events = PhysicsWorld2d.Internal.Data.noEvents(),
            settings = validSettings(s), stepSeconds = step,
            materials = Vector#{PhysicsMaterial.default()}, materialNames = Map.empty(), warned = Set.empty(), steps = 0i64
        })

    def validSettings(s: Settings): Settings =
        let finite = PhysicsWorld2d.Internal.Data.isFinite;
        let ok = finite(s#gravity#x) and finite(s#gravity#y) and s#solverSubsteps >= 1 and s#solverSubsteps <= 64
                 and finite(s#sleepLinearThreshold) and finite(s#sleepAngularThreshold);
        if (ok) s else Log.fellBackThen("PhysicsWorld2d", "Settings", "PhysicsWorld2d.settings()", "重力が NaN・無限大か、solverSubsteps が 1〜64 の外", settings())

    /// 1 刻みの秒。
    pub def stepSecondsOf(w: PhysicsWorld2d): Float64 = data(w)#stepSeconds

    /// 進めた刻みの数。
    pub def stepCount(w: PhysicsWorld2d): Int64 = data(w)#steps

    pub def settingsOf(w: PhysicsWorld2d): Settings = data(w)#settings

    /// 設定を差し替える（次の刻みから効く。Doc の読み直し）。
    pub def withSettings(s: Settings, w: PhysicsWorld2d): PhysicsWorld2d =
        WorldOf.WorldOf({ settings = validSettings(s) | data(w) })

    /// 材質の表（名前 → 材質）を差し替える。もう居る体の摩擦と跳ね返りにも次の刻みから効く（重さは体を作った時に出すので変わらない）。
    /// 使えない値の材質は既定の材質にして 1 行言う。表に無い名前を指す体は既定の材質で続ける。
    pub def withMaterials(table: Map[String, PhysicsMaterial.PhysicsMaterial], w: PhysicsWorld2d): PhysicsWorld2d =
        let d = data(w);
        let entries = Map.toList(table);
        let checked = entries |> List.map(e -> {
            let (name, m) = e;
            if (PhysicsMaterial.isValid(m)) m
            else Log.fellBackThen("PhysicsWorld2d", "材質 ${name}", "既定の材質", "摩擦・跳ね返りが負か、密度が 0 以下か、NaN・無限大", PhysicsMaterial.default())
        });
        let materials = Vector.append(Vector#{PhysicsMaterial.default()}, List.toVector(checked));
        let names = List.zip(entries |> List.map(fst), List.range(1, List.length(entries) + 1)) |> List.toMap;
        let reindexed = { materials = materials, materialNames = names | d };
        let index = Vector.map(c -> materialIndexOf(Collider2d.materialName(c), reindexed), d#colliders);
        WorldOf.WorldOf({ materialIndex = Vector.map(fst, index) | List.foldLeft((acc, p) -> snd(p)(acc), reindexed, Vector.toList(index)) })

    /// 材質の番号と、引けなかった時に 1 回言う関数（空の名前は既定の材質で黙る）。
    def materialIndexOf(name: String, d: Data): (Int32, Data -> Data) =
        if (name == "") (0, x -> x)
        else match Map.get(name, d#materialNames) {
            case Some(i) => (i, x -> x)
            case None => (0, PhysicsWorld2d.Internal.Data.warnOnce("[PhysicsWorld2d] 材質 '${name}' が表に無い。既定の材質（摩擦 0.5・跳ね返り 0・密度 1）で続ける"))
        }

    // ── 足す・消す ──

    /// 体を足す。重さは材質の密度 × 形の面積（Collider2d.withMass で直に決めた時はその値）。近くで眠っている体は起こす。
    /// 同じ id がもう居れば置き換える（出来事は出さず、触れていた組は続く。離れていれば次の刻みに Stopped）。
    /// 位置・速さが NaN・無限大なら 0 にして 1 回言う。
    /// 1 回で体の数ぶんの写しがかかる（不変の Vector）。数百個を毎フレーム足し引きせず、足すのは起動・面の切り替え・合わさった時に。
    pub def insert(id: EntityId, body: RigidBody2d.RigidBody2d, w: PhysicsWorld2d): PhysicsWorld2d =
        let d = data(w);
        let base = PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) |> Option.map(at -> dropBody(at, d)) |> Option.getWithDefault(d);
        let collider = RigidBody2d.colliderOf(body);
        let shape = Collider2d.shapeOf(collider);
        let (matIndex, warnMissing) = materialIndexOf(Collider2d.materialName(collider), base);
        let material = Vector.get(matIndex, base#materials);
        let (area, moment) = PhysicsWorld2d.Internal.Shape.areaAndMoment(shape);
        let computed = material#density * area;
        let mass = Collider2d.massOverride(collider) |> Option.getWithDefault(computed);
        let inertia = if (computed > 0.0) moment * material#density * mass / computed else 0.0;
        let bodyType = RigidBody2d.bodyTypeOf(body);
        let dynamic = bodyType == RigidBody2d.BodyType.Dynamic;
        let (p, v, av, d0) = cleanInput(body, warnMissing(base));
        let rot = RigidBody2d.rotationOf(body);
        let radius = PhysicsWorld2d.Internal.Shape.boundingRadius(shape);
        let at = PhysicsWorld2d.Internal.Data.insertionPoint(id, d0#ids);
        let isFixed = bodyType == RigidBody2d.BodyType.Fixed;
        let state = Vector#{p#x, p#y, Rot2.cos(rot), Rot2.sin(rot), if (isFixed) 0.0 else v#x, if (isFixed) 0.0 else v#y, if (isFixed) 0.0 else av, 0.0};
        let props = Vector#{radius, if (dynamic and mass > 0.0) 1.0 / mass else 0.0, if (dynamic and inertia > 0.0) 1.0 / inertia else 0.0};
        let woken = wakeNear(p#x, p#y, radius, d0);
        WorldOf.WorldOf({
            ids = insertAt(at, 1, Vector#{id}, woken#ids), types = insertAt(at, 1, Vector#{bodyType}, woken#types),
            colliders = insertAt(at, 1, Vector#{collider}, woken#colliders), shapes = insertAt(at, 1, Vector#{shape}, woken#shapes),
            materialIndex = insertAt(at, 1, Vector#{matIndex}, woken#materialIndex),
            props = insertAt(at, PhysicsWorld2d.Internal.Data.propStride(), props, woken#props),
            state = insertAt(at, PhysicsWorld2d.Internal.Data.stateStride(), state, woken#state),
            prev = insertAt(at, PhysicsWorld2d.Internal.Data.prevStride(), Vector#{p#x, p#y, Rot2.cos(rot), Rot2.sin(rot)}, woken#prev),
            asleep = insertAt(at, 1, Vector#{false}, woken#asleep) | woken })

    /// 位置・速さ・回る速さ（NaN・無限大は 0 にして 1 回言う）。
    def cleanInput(body: RigidBody2d.RigidBody2d, d: Data): (Vec2.Vec2, Vec2.Vec2, Float64, Data) =
        let finite = PhysicsWorld2d.Internal.Data.isFinite;
        let p = RigidBody2d.positionOf(body);
        let v = RigidBody2d.linearVelocityOf(body);
        let av = RigidBody2d.angularVelocityOf(body);
        let ok = finite(p#x) and finite(p#y) and finite(v#x) and finite(v#y) and finite(av);
        if (ok) (p, v, av, d)
        else {
            let clean = x -> if (finite(x)) x else 0.0;
            ({ x = clean(p#x), y = clean(p#y) }, { x = clean(v#x), y = clean(v#y) }, clean(av),
             PhysicsWorld2d.Internal.Data.warnOnce(nonFiniteLine(), d))
        }

    def nonFiniteLine(): String = "[PhysicsWorld2d] NaN か無限大の位置・速さ・衝撃を受けた。その値は捨てて続ける（最初の 1 回だけ言う）"

    def insertAt(at: Int32, stride: Int32, items: Vector[a], v: Vector[a]): Vector[a] =
        Vector.append(Vector.append(Vector.slice(start = 0, end = at * stride, v), items), Vector.slice(start = at * stride, end = Vector.length(v), v))

    def dropAt(at: Int32, stride: Int32, v: Vector[a]): Vector[a] =
        Vector.append(Vector.slice(start = 0, end = at * stride, v), Vector.slice(start = (at + 1) * stride, end = Vector.length(v), v))

    /// 体を消す（居なければそのまま）。その体の組に removed = true の Stopped を出し（次の刻みの出来事）、近くで眠っている体を起こす。
    /// insert と同じく 1 回で体の数ぶんの写しがかかる。
    pub def remove(id: EntityId, w: PhysicsWorld2d): PhysicsWorld2d =
        let d = data(w);
        match PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) {
            case None => w
            case Some(at) =>
                let so = at * PhysicsWorld2d.Internal.Data.stateStride();
                let involves = k -> PhysicsWorld2d.Internal.Data.pairA(k) == id or PhysicsWorld2d.Internal.Data.pairB(k) == id;
                let collisions = d#touching |> Vector.filter(involves) |> Vector.toList
                    |> List.map(k -> CollisionEvent2d.CollisionEvent2d.Stopped(PhysicsWorld2d.Internal.Data.pairA(k), PhysicsWorld2d.Internal.Data.pairB(k), true));
                let sensors = d#sensing |> Vector.filter(involves) |> Vector.toList
                    |> List.map(k -> { let (s, o) = PhysicsWorld2d.Internal.Step.sensorFirst(d, k); SensorEvent2d.SensorEvent2d.Stopped(s, o, true) });
                let (keys, features, normal, tangent) = d#warm;
                let keepWarm = Vector.range(0, Vector.length(keys)) |> Vector.filter(i -> not involves(Vector.get(i, keys)));
                let gone = {
                    targets = Map.remove(id, d#targets),
                    warm = (Vector.map(i -> Vector.get(i, keys), keepWarm), pickPairs(keepWarm, features), pickPairs(keepWarm, normal), pickPairs(keepWarm, tangent)),
                    touching = Vector.filter(k -> not involves(k), d#touching), sensing = Vector.filter(k -> not involves(k), d#sensing),
                    pending = { collisions = collisions, sensors = sensors } :: d#pending | dropBody(at, d) };
                let radius = Vector.get(at * PhysicsWorld2d.Internal.Data.propStride(), d#props);
                WorldOf.WorldOf(wakeNear(Vector.get(so, d#state), Vector.get(so + 1, d#state), radius, gone))
        }

    /// 番号 at の体の欄を抜く（組・控え・出来事はそのまま）。
    def dropBody(at: Int32, d: Data): Data =
        { ids = dropAt(at, 1, d#ids), types = dropAt(at, 1, d#types), colliders = dropAt(at, 1, d#colliders), shapes = dropAt(at, 1, d#shapes),
          materialIndex = dropAt(at, 1, d#materialIndex), props = dropAt(at, PhysicsWorld2d.Internal.Data.propStride(), d#props),
          state = dropAt(at, PhysicsWorld2d.Internal.Data.stateStride(), d#state), prev = dropAt(at, PhysicsWorld2d.Internal.Data.prevStride(), d#prev),
          asleep = dropAt(at, 1, d#asleep) | d }

    /// 控えの組の枠（組ごとに 2 つ）から、残す組 keep の分だけを抜き出す。
    def pickPairs(keep: Vector[Int32], v: Vector[a]): Vector[a] =
        keep |> Vector.flatMap(i -> Vector#{Vector.get(i * 2, v), Vector.get(i * 2 + 1, v)})

    /// 中心 (x, y)・半径 radius の近くで眠っている体を起こす（下の体が消えて積んだ物が宙に浮かないように）。
    def wakeNear(x: Float64, y: Float64, radius: Float64, d: Data): Data =
        let n = Vector.length(d#ids);
        let ss = PhysicsWorld2d.Internal.Data.stateStride();
        let near = i -> {
            let dx = Vector.get(i * ss, d#state) - x;
            let dy = Vector.get(i * ss + 1, d#state) - y;
            let reach = Vector.get(i * PhysicsWorld2d.Internal.Data.propStride(), d#props) + radius + PhysicsWorld2d.Internal.Narrowphase.margin() * 4.0;
            Vector.get(i, d#asleep) and dx * dx + dy * dy <= reach * reach
        };
        let woken = Vector.range(0, n) |> Vector.filter(near) |> Vector.toList |> List.toSet;
        if (Set.isEmpty(woken)) d
        else { asleep = Vector.mapWithIndex((i, a) -> if (Set.memberOf(i, woken)) false else a, d#asleep),
               state = Vector.mapWithIndex((k, v) -> if (Int32.modulo(k, ss) == 7 and Set.memberOf(k / ss, woken)) 0.0 else v, d#state) | d }

    // ── 1 刻み ──

    /// 1 刻み進める（刻みは empty で決めた秒）。ゲームは呼ばない — App.addPhysics2d が遊びの時計で貯めた固定刻みで呼ぶ（lint-forbid の physics-step-direct）。
    /// 中で NaN・無限大になった体は消し、removed = true の Stopped を出して 1 回言う。
    pub def step(w: PhysicsWorld2d): PhysicsWorld2d =
        let (stepped, broken) = PhysicsWorld2d.Internal.Step.step(data(w));
        if (List.isEmpty(broken)) WorldOf.WorldOf(stepped)
        else {
            let warned = PhysicsWorld2d.Internal.Data.warnOnce("[PhysicsWorld2d] 体の位置か速さが NaN・無限大になったので消した（removed の Stopped を出す・最初の 1 回だけ言う）", stepped);
            let removed = List.foldLeft((acc, id) -> remove(id, acc), WorldOf.WorldOf(warned), broken);
            let d = data(removed);
            let late = d#pending |> List.reverse;
            WorldOf.WorldOf({ events = { collisions = List.append(d#events#collisions, List.flatMap(e -> e#collisions, late)),
                                         sensors = List.append(d#events#sensors, List.flatMap(e -> e#sensors, late)) },
                              pending = Nil | d })
        }

    /// 直前の 1 刻みの出来事（step のたびに入れ替わる）。App.addPhysics2d の onEvents が刻みごとに受け取るので、ゲームの系はふつう読まない。
    pub def events(w: PhysicsWorld2d): Events = data(w)#events

    // ── 外から動かす（World を最後に） ──

    /// id の state の欄 k に f を当てる（居なければそのまま）。
    def updateState(id: EntityId, f: (Int32, Float64) -> Float64, w: PhysicsWorld2d): PhysicsWorld2d =
        let d = data(w);
        match PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) {
            case None => w
            case Some(at) =>
                let ss = PhysicsWorld2d.Internal.Data.stateStride();
                let lo = at * ss;
                WorldOf.WorldOf(wakeAt(at, { state = Vector.mapWithIndex((k, v) -> if (k >= lo and k < lo + ss) f(k - lo, v) else v, d#state) | d }))
        }

    def wakeAt(at: Int32, d: Data): Data =
        if (not Vector.get(at, d#asleep)) d
        else { asleep = Vector.mapWithIndex((i, a) -> if (i == at) false else a, d#asleep) | d }

    def typeOf(id: EntityId, w: PhysicsWorld2d): Option[RigidBody2d.BodyType] =
        let d = data(w);
        PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) |> Option.map(i -> Vector.get(i, d#types))

    def rejectNonFinite(w: PhysicsWorld2d): PhysicsWorld2d = WorldOf.WorldOf(PhysicsWorld2d.Internal.Data.warnOnce(nonFiniteLine(), data(w)))

    /// 重心に衝撃（kg·m/s）を掛ける（Dynamic の体だけ・起こす）。set* と同じく 1 回で体の数ぶんの写しがかかるので、
    /// 多くの体へ毎フレーム掛けるなら applyImpulses で 1 回にまとめる。
    pub def applyImpulse(id: EntityId, impulse: Vec2.Vec2, w: PhysicsWorld2d): PhysicsWorld2d =
        let d = data(w);
        if (not PhysicsWorld2d.Internal.Data.isFinite(impulse#x) or not PhysicsWorld2d.Internal.Data.isFinite(impulse#y)) rejectNonFinite(w)
        else match PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) {
            case None => w
            case Some(at) =>
                let invMass = Vector.get(at * PhysicsWorld2d.Internal.Data.propStride() + 1, d#props);
                updateState(id, (k, v) -> if (k == 4) v + impulse#x * invMass else if (k == 5) v + impulse#y * invMass else if (k == 7) 0.0 else v, w)
        }

    /// 衝撃をまとめて掛ける（同じ id が 2 回あれば足す・居ない id は飛ばす・NaN の衝撃は捨てて 1 回言う）。体の数ぶんの写しは 1 回だけ。
    pub def applyImpulses(impulses: List[(EntityId, Vec2.Vec2)], w: PhysicsWorld2d): PhysicsWorld2d =
        let d = data(w);
        let finite = PhysicsWorld2d.Internal.Data.isFinite;
        let (good, bad) = List.partition(p -> finite(snd(p)#x) and finite(snd(p)#y), impulses);
        let checked = if (List.isEmpty(bad)) d else PhysicsWorld2d.Internal.Data.warnOnce(nonFiniteLine(), d);
        let ps = PhysicsWorld2d.Internal.Data.propStride();
        let byIndex = good |> List.foldLeft((acc, p) -> {
            let (id, j) = p;
            match PhysicsWorld2d.Internal.Data.indexOf(id, checked#ids) {
                case None => acc
                case Some(at) =>
                    let invMass = Vector.get(at * ps + 1, checked#props);
                    Map.insertWith((a, b) -> (fst(a) + fst(b), snd(a) + snd(b)), at, (j#x * invMass, j#y * invMass), acc)
            }
        }, Map.empty());
        if (Map.isEmpty(byIndex)) WorldOf.WorldOf(checked)
        else {
            let ss = PhysicsWorld2d.Internal.Data.stateStride();
            let bump = (k, v) -> match Map.get(k / ss, byIndex) {
                case None => v
                case Some((dx, dy)) =>
                    let slot = Int32.modulo(k, ss);
                    if (slot == 4) v + dx else if (slot == 5) v + dy else if (slot == 7) 0.0 else v
            };
            WorldOf.WorldOf({ state = Vector.mapWithIndex(bump, checked#state),
                              asleep = Vector.mapWithIndex((i, a) -> if (Map.memberOf(i, byIndex)) false else a, checked#asleep) | checked })
        }

    /// 速さ（m/s）を置く（Fixed の体には効かない・起こす）。
    pub def setLinearVelocity(id: EntityId, v: Vec2.Vec2, w: PhysicsWorld2d): PhysicsWorld2d =
        if (not PhysicsWorld2d.Internal.Data.isFinite(v#x) or not PhysicsWorld2d.Internal.Data.isFinite(v#y)) rejectNonFinite(w)
        else if (typeOf(id, w) == Some(RigidBody2d.BodyType.Fixed)) w
        else updateState(id, (k, x) -> if (k == 4) v#x else if (k == 5) v#y else if (k == 7) 0.0 else x, w)

    /// 回る速さ（rad/s）を置く（Fixed の体には効かない・起こす）。
    pub def setAngularVelocity(id: EntityId, av: Float64, w: PhysicsWorld2d): PhysicsWorld2d =
        if (not PhysicsWorld2d.Internal.Data.isFinite(av)) rejectNonFinite(w)
        else if (typeOf(id, w) == Some(RigidBody2d.BodyType.Fixed)) w
        else updateState(id, (k, x) -> if (k == 6) av else if (k == 7) 0.0 else x, w)

    /// Kinematic の体を、次の刻みで position・rotation へ着くように動かす（Rapier の set_next_kinematic_position）。
    /// 着いた刻みの後は止まる（毎刻み呼べば付いてくる）。ほかの種類の体には効かない。触れた眠りの体は起こす。
    /// 着いた後は linearVelocityOf が 0 を返す（動く床に乗せる計算は、前と今の目標の差 ÷ 刻みでゲームが出す）。
    pub def setKinematicTarget(id: EntityId, position: Vec2.Vec2, rotation: Rot2.Rot2, w: PhysicsWorld2d): PhysicsWorld2d =
        if (not PhysicsWorld2d.Internal.Data.isFinite(position#x) or not PhysicsWorld2d.Internal.Data.isFinite(position#y)) rejectNonFinite(w)
        else if (typeOf(id, w) != Some(RigidBody2d.BodyType.Kinematic)) w
        else WorldOf.WorldOf({ targets = Map.insert(id, (position#x, position#y, Rot2.cos(rotation), Rot2.sin(rotation)), data(w)#targets) | data(w) })

    /// 瞬間移動（Rapier の set_position）。描く時の補間の前の姿勢も同じ所へそろえる（Godot の reset_physics_interpolation）。起こす。
    pub def setPosition(id: EntityId, position: Vec2.Vec2, rotation: Rot2.Rot2, w: PhysicsWorld2d): PhysicsWorld2d =
        if (not PhysicsWorld2d.Internal.Data.isFinite(position#x) or not PhysicsWorld2d.Internal.Data.isFinite(position#y)) rejectNonFinite(w)
        else {
            let pose = k -> if (k == 0) position#x else if (k == 1) position#y else if (k == 2) Rot2.cos(rotation) else Rot2.sin(rotation);
            let moved = updateState(id, (k, x) -> if (k < 4) pose(k) else if (k == 7) 0.0 else x, w);
            let d = data(moved);
            match PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) {
                case None => moved
                case Some(at) =>
                    let ps = PhysicsWorld2d.Internal.Data.prevStride();
                    WorldOf.WorldOf({ prev = Vector.mapWithIndex((k, x) -> if (k >= at * ps and k < at * ps + ps) pose(k - at * ps) else x, d#prev) | d })
            }
        }

    /// 眠っている体を起こす。
    pub def wakeUp(id: EntityId, w: PhysicsWorld2d): PhysicsWorld2d = updateState(id, (k, x) -> if (k == 7) 0.0 else x, w)

    // ── 読む（render-from-World） ──

    def stateAt(id: EntityId, k: Int32, w: PhysicsWorld2d): Option[Float64] =
        let d = data(w);
        PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) |> Option.map(i -> Vector.get(i * PhysicsWorld2d.Internal.Data.stateStride() + k, d#state))

    pub def contains(id: EntityId, w: PhysicsWorld2d): Bool = not Option.isEmpty(PhysicsWorld2d.Internal.Data.indexOf(id, data(w)#ids))

    pub def bodyCount(w: PhysicsWorld2d): Int32 = Vector.length(data(w)#ids)

    /// 重心の位置（m）。
    pub def positionOf(id: EntityId, w: PhysicsWorld2d): Option[Vec2.Vec2] =
        forM (x <- stateAt(id, 0, w); y <- stateAt(id, 1, w)) yield { x = x, y = y }

    pub def rotationOf(id: EntityId, w: PhysicsWorld2d): Option[Rot2.Rot2] =
        forM (c <- stateAt(id, 2, w); s <- stateAt(id, 3, w)) yield Rot2.fromCosSin(c, s)

    pub def linearVelocityOf(id: EntityId, w: PhysicsWorld2d): Option[Vec2.Vec2] =
        forM (x <- stateAt(id, 4, w); y <- stateAt(id, 5, w)) yield { x = x, y = y }

    pub def angularVelocityOf(id: EntityId, w: PhysicsWorld2d): Option[Float64] = stateAt(id, 6, w)

    pub def isSleeping(id: EntityId, w: PhysicsWorld2d): Bool =
        let d = data(w);
        PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) |> Option.map(i -> Vector.get(i, d#asleep)) |> Option.getWithDefault(false)

    pub def colliderOf(id: EntityId, w: PhysicsWorld2d): Option[Collider2d.Collider2d] =
        let d = data(w);
        PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) |> Option.map(i -> Vector.get(i, d#colliders))

    /// 起きている Dynamic の体の数。
    pub def awakeCount(w: PhysicsWorld2d): Int32 =
        let d = data(w);
        Vector.range(0, Vector.length(d#ids)) |> Vector.count(i -> Vector.get(i, d#types) == RigidBody2d.BodyType.Dynamic and not Vector.get(i, d#asleep))

    /// 全部の体（id の順）。
    pub def bodies(w: PhysicsWorld2d): Vector[BodyState] =
        let d = data(w);
        let ss = PhysicsWorld2d.Internal.Data.stateStride();
        Vector.range(0, Vector.length(d#ids)) |> Vector.map(i -> {
            let st = k -> Vector.get(i * ss + k, d#state);
            { id = Vector.get(i, d#ids), bodyType = Vector.get(i, d#types), position = { x = st(0), y = st(1) },
              rotation = Rot2.fromCosSin(st(2), st(3)), linearVelocity = { x = st(4), y = st(5) }, angularVelocity = st(6),
              isSleeping = Vector.get(i, d#asleep), collider = Vector.get(i, d#colliders) }
        })

    /// 前の刻みと今の刻みの間を alpha（0〜1。ViewCtx#fixedAlpha）でなめらかにつないだ姿勢。描くだけに使う（決定性は要らない）。
    pub def interpolatedPoseOf(id: EntityId, alpha: Float64, w: PhysicsWorld2d): Option[Pose2d] =
        let d = data(w);
        let t = Num.clamp01(alpha);
        PhysicsWorld2d.Internal.Data.indexOf(id, d#ids) |> Option.map(i -> {
            let st = k -> Vector.get(i * PhysicsWorld2d.Internal.Data.stateStride() + k, d#state);
            let pv = k -> Vector.get(i * PhysicsWorld2d.Internal.Data.prevStride() + k, d#prev);
            { position = { x = pv(0) + (st(0) - pv(0)) * t, y = pv(1) + (st(1) - pv(1)) * t },
              rotation = Rot2.nlerp(Rot2.fromCosSin(pv(2), pv(3)), Rot2.fromCosSin(st(2), st(3)), t) }
        })

    // ── 光線と点 ──

    /// origin から direction（長さは問わない）へ maxDistance（m）まで光線を飛ばし、一番近い当たり（sensor の形は的にしない）。
    /// mask は当たり層（Collider2d.withCollisionLayers の layer と重なる形だけ）。起点が中にある形には当てない。同じ距離なら id の小さい方。
    pub def castRay(origin: Vec2.Vec2, direction: Vec2.Vec2, maxDistance: Float64, mask: Int32, w: PhysicsWorld2d): Option[RayHit2d] =
        let d = data(w);
        let len = PortableMath.sqrt(direction#x * direction#x + direction#y * direction#y);
        let finite = PhysicsWorld2d.Internal.Data.isFinite;
        if (not (len > 0.0) or not finite(len) or not finite(origin#x) or not finite(origin#y) or not (maxDistance >= 0.0) or not finite(maxDistance)) None
        else {
            let ray = (origin#x, origin#y, direction#x / len, direction#y / len);
            Vector.range(0, Vector.length(d#ids)) |> Vector.foldLeft((best, i) -> {
                let c = Vector.get(i, d#colliders);
                if (Collider2d.isSensor(c) or Int32.bitwiseAnd(Collider2d.collisionLayer(c), mask) == 0) best
                else match PhysicsWorld2d.Internal.Narrowphase.rayCast(Vector.get(i, d#shapes), poseAt(i, d), ray, maxDistance) {
                    case None => best
                    case Some((t, nx, ny)) =>
                        let closer = best |> Option.map(b -> t < b#distance) |> Option.getWithDefault(true);
                        if (closer) Some({ id = Vector.get(i, d#ids), point = { x = origin#x + (direction#x / len) * t, y = origin#y + (direction#y / len) * t },
                                           normal = { x = nx, y = ny }, distance = t })
                        else best
                }
            }, None)
        }

    def poseAt(i: Int32, d: Data): PhysicsWorld2d.Internal.Narrowphase.Pose =
        let o = i * PhysicsWorld2d.Internal.Data.stateStride();
        (Vector.get(o, d#state), Vector.get(o + 1, d#state), Vector.get(o + 2, d#state), Vector.get(o + 3, d#state))

    /// 点を含む体の id（id の順・sensor の形も入る）。mask は当たり層。
    pub def queryPoint(point: Vec2.Vec2, mask: Int32, w: PhysicsWorld2d): List[EntityId] =
        let d = data(w);
        Vector.range(0, Vector.length(d#ids)) |> Vector.toList |> List.filter(i -> {
            let c = Vector.get(i, d#colliders);
            Int32.bitwiseAnd(Collider2d.collisionLayer(c), mask) != 0
                and PhysicsWorld2d.Internal.Narrowphase.containsPoint(Vector.get(i, d#shapes), poseAt(i, d), point#x, point#y)
        }) |> List.map(i -> Vector.get(i, d#ids))

    // ── 指紋 ──

    /// 各体の id・位置・向き・速さ・眠りの時計・眠りと、触れている組・warm start の控えを、Float64 のビットのまま id の順に流した 64 bit の指紋（StateHash）。
    /// JVM と wasm の比べ・巻き戻しのテストに使う（控えも入れるので、指紋が同じ World は次の刻みも同じ）。
    pub def stateHash(w: PhysicsWorld2d): Int64 =
        let d = data(w);
        let withBodies = Vector.foldLeft((h, x) -> StateHash.mixFloat64(x, h),
                                         Vector.foldLeft((h, id) -> StateHash.mixInt32(id, h), StateHash.start(), d#ids), d#state);
        let withSleep = Vector.foldLeft((h, b) -> StateHash.mixBool(b, h), withBodies, d#asleep);
        let withPairs = Vector.foldLeft((h, k) -> StateHash.mixInt64(k, h), withSleep, d#touching);
        let (keys, features, normal, tangent) = d#warm;
        let withWarm = Vector.foldLeft((h, k) -> StateHash.mixInt64(k, h), withPairs, keys)
            |> h0 -> Vector.foldLeft((h, f) -> StateHash.mixInt32(f, h), h0, features)
            |> h1 -> Vector.foldLeft((h, x) -> StateHash.mixFloat64(x, h), h1, normal)
            |> h2 -> Vector.foldLeft((h, x) -> StateHash.mixFloat64(x, h), h2, tangent);
        StateHash.toInt64(withWarm)
}
