// PhysicsBench — 2D の剛体の物理（PhysicsWorld2d）の重さと指紋を測る場面。PC（Main）とブラウザ（web/WebMain）が同じコードを流す。
// 場面: 幅 23.4 m の床と左右の壁へ、7 つに 4 つが円・2 つが正六角形・1 つが箱の物を 40 列の格子に並べて落とす（plans/engine-physics2d.md の 2 節）。
// 予算（同じ計画の 7 節）: 物 100 個が落ちて積もる 600 刻みの平均・物 1,000 個の起きた山（眠り無し）・眠った物 1,000 個。
mod PhysicsBench {
    use fge::{Collider2d, PhysicsWorld2d, PortableMath, RigidBody2d, Vec2}

    /// 外から来る物。now = 今の時刻（ms）・emit = 結果の行の出し先。
    pub type alias Host = { now = Unit -> Float64 \ IO, emit = String -> Unit \ IO }

    def dt(): Float64 = 1.0 / 60.0

    def noSleep(): PhysicsWorld2d.Settings = { sleepLinearThreshold = 0.0, sleepAngularThreshold = 0.0 | PhysicsWorld2d.settings() }

    /// 早く眠らせて山を作るしきい（測る前だけ）。
    def quickSleep(): PhysicsWorld2d.Settings = { sleepLinearThreshold = 0.1, sleepAngularThreshold = 0.15 | PhysicsWorld2d.settings() }

    def withJar(w: PhysicsWorld2d.PhysicsWorld2d): PhysicsWorld2d.PhysicsWorld2d =
        w |> PhysicsWorld2d.insert(1, RigidBody2d.fixed({ x = 0.0, y = 0.5 }, Collider2d.box(11.7, 0.5)))
          |> PhysicsWorld2d.insert(2, RigidBody2d.fixed({ x = -12.2, y = -10.0 }, Collider2d.box(0.5, 10.0)))
          |> PhysicsWorld2d.insert(3, RigidBody2d.fixed({ x = 12.2, y = -10.0 }, Collider2d.box(0.5, 10.0)))

    def hexagon(radius: Float64): Collider2d.Collider2d =
        let h = radius * PortableMath.sqrt(3.0) / 2.0;
        let half = radius / 2.0;
        Collider2d.convex(List#{{ x = radius, y = 0.0 }, { x = half, y = h }, { x = -half, y = h },
                                { x = -radius, y = 0.0 }, { x = -half, y = -h }, { x = half, y = -h }})

    def pieceOf(k: Int32): RigidBody2d.RigidBody2d =
        let size = 0.16 + Int32.toFloat64(Int32.modulo(k * 7, 11)) * 0.01;
        let col = Int32.modulo(k, 40);
        let row = k / 40;
        let pos = { x = -9.75 + Int32.toFloat64(col) * 0.5, y = -1.0 - Int32.toFloat64(row) * 0.55 };
        let kind = Int32.modulo(k, 7);
        let collider = if (kind < 4) Collider2d.circle(size) else if (kind < 6) hexagon(size) else Collider2d.box(size, size);
        RigidBody2d.dynamic(pos, collider)

    /// 物 n 個の場面（id 10 から順。engine_world の TestPhysicsWorld2d と同じ場面）。
    pub def pile(settings: PhysicsWorld2d.Settings, n: Int32): PhysicsWorld2d.PhysicsWorld2d =
        List.range(0, n) |> List.foldLeft((w, k) -> PhysicsWorld2d.insert(10 + k, pieceOf(k), w), withJar(PhysicsWorld2d.empty(settings, dt())))

    pub def advance(steps: Int32, w: PhysicsWorld2d.PhysicsWorld2d): PhysicsWorld2d.PhysicsWorld2d =
        if (steps <= 0) w else advance(steps - 1, PhysicsWorld2d.step(w))

    /// 全部眠るまで進める（上限 limit 刻み）。
    def settle(limit: Int32, w: PhysicsWorld2d.PhysicsWorld2d): PhysicsWorld2d.PhysicsWorld2d =
        if (limit <= 0 or PhysicsWorld2d.awakeCount(w) == 0) w else settle(limit - 30, advance(30, w))

    /// steps 刻みを流した 1 刻みの平均（ms）と、流した後の World。
    // WhyNot: let で advance を直に束ねない — 純粋な束ねは使う所（時計を読んだ後）まで下げて組まれ、0 ms と出る。時計の間で Ref へ書いて順を止める。
    def timeSteps(host: Host, steps: Int32, w: PhysicsWorld2d.PhysicsWorld2d): (Float64, PhysicsWorld2d.PhysicsWorld2d) \ IO = region rc {
        let cell = Ref.fresh(rc, w);
        let start = host#now();
        Ref.put(advance(steps, w), cell);
        let count = PhysicsWorld2d.stepCount(Ref.get(cell));
        let ms = host#now() - start;
        (ms / Int32.toFloat64(steps) + 0.0 * Int64.toFloat64(count), Ref.get(cell))
    }

    def result(host: Host, scene: String, n: Int32, avg: Float64, w: PhysicsWorld2d.PhysicsWorld2d): Unit \ IO =
        host#emit("[bench] result {\"scene\":\"${scene}\",\"n\":${n},\"step_avg_ms\":${avg},\"awake\":${PhysicsWorld2d.awakeCount(w)},\"hash\":\"${PhysicsWorld2d.stateHash(w)}\"}")

    /// 予算の 3 場面と、起きた 500 個の場面を流す。reps = 同じ場面を流す回数（2 回目からが温まった後の値）。指紋は PC とブラウザで比べる（make physics2d-same）。
    pub def runAll(host: Host, reps: Int32): Unit \ IO =
        host#emit("[bench] begin");
        List.range(0, reps) |> List.forEach(_ -> {
            // 物 100 個が落ちて積もる 600 刻み（眠りは既定のしきい）。指紋は TestPhysicsWorld2d の基準と同じになる。
            let (a100, w100) = timeSteps(host, 600, pile(PhysicsWorld2d.settings(), 100));
            result(host, "fall100", 100, a100, w100);
            // 物 500 個・1,000 個の起きた山（眠り無し）。
            let (a500, w500) = timeSteps(host, 600, pile(noSleep(), 500));
            result(host, "awake500", 500, a500, w500);
            let (a1000, w1000) = timeSteps(host, 600, pile(noSleep(), 1000));
            result(host, "awake1000", 1000, a1000, w1000);
            // 眠った物 1,000 個: 早く眠るしきいで山を作ってから、既定のしきいに戻して測る。
            let slept = settle(6000, pile(quickSleep(), 1000)) |> PhysicsWorld2d.withSettings(PhysicsWorld2d.settings());
            let (aSleep, wSleep) = timeSteps(host, 600, slept);
            result(host, "asleep1000", 1000, aSleep, wSleep)
        });
        host#emit("[bench] done")
}
