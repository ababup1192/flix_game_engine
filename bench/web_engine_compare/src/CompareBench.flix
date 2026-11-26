// CompareBench — 場面を毎コマ描き、区間ごとに 1 行の JSON（BenchRun）を出す。
// 2 つの回し方が同じ App を使う: engine の口（make bench-web）と、比べる相手の harness の adapter（harness/flix-adapter.ts）。
// つまみ: scenario=k1|k2・level=<物の数>・frames=<1 区間のコマ数>・repeat=<区間の数>・diag=0。
mod CompareBench {
    use fge::{App, Render}

    pub type alias World = { t = Float64, progress = BenchRun.Run }

    /// 外から差し込む物。sceneTime = 自分で足し上げた時刻 → 場面の時刻・now = 時計（ms）・noteSim = 場面の更新にかかった ms を外へ知らせる。
    pub type alias Hooks = { sceneTime = Float64 -> Float64 \ IO, now = Unit -> Float64 \ IO, noteSim = Float64 -> Unit \ IO }

    /// 自分の時刻のまま・知らせない（engine の口で回す時）。
    pub def standalone(now: Unit -> Float64 \ IO): Hooks = { sceneTime = t -> checked_ecast(t), now = now, noteSim = _ -> checked_ecast(()) }

    /// 起動直後は JIT とメッシュの初めての上げで dt が荒れるため、各区間の頭を捨てる。
    def warmup(): Int32 = 90

    pub def planOf(knobs: Map[String, String]): BenchRun.Plan =
        BenchRun.planOf({ warmup = warmup(), frames = 240, segments = BenchRun.intKnob("repeat", 3, knobs) }, knobs)

    /// 測る場面（無い・読めないつまみは K1）。
    pub def scenarioOf(knobs: Map[String, String]): Scenes.Scenario =
        Map.get("scenario", knobs) |> Option.flatMap(Scenes.scenarioOf) |> Option.getWithDefault(Scenes.Scenario.K1)

    /// 物の置き方（variant=optimized なら形と材質の組ごとの MultiMesh3d）。
    pub def pathOf(knobs: Map[String, String]): Draw.Path =
        if (Map.get("variant", knobs) == Some("optimized")) Draw.Path.Batched else Draw.Path.PerObject

    pub def levelOf(scenario: Scenes.Scenario, knobs: Map[String, String]): Int32 =
        BenchRun.intKnob("level", if (scenario == Scenes.Scenario.K2) 500 else 1, knobs)

    def knobsOf(kit: Draw.Kit, scenario: Scenes.Scenario, segment: Int32): List[(String, String)] =
        ("bench", BenchRun.quoted("web_engine_compare")) :: ("segment", Int32.toString(segment)) ::
        ("scenario", BenchRun.quoted(String.toLowerCase(ToString.toString(scenario)))) :: ("level", Int32.toString(kit#field#count)) ::
        ("triangles", Int32.toString(Scenes.triangleCount(kit#field, Geometry.fieldShapes()))) :: Nil

    def step(plan: BenchRun.Plan, emit: String -> Unit \ IO, kit: Draw.Kit, scenario: Scenes.Scenario, frame: App.Frame, w: World): World \ IO =
        if (w#progress#done) { t = w#t + frame#dt | w }
        else { t = w#t + frame#dt, progress = BenchRun.advance(plan, emit, knobsOf(kit, scenario), BenchRun.sampleOf(frame, 0.0), w#progress) }

    /// 場面の更新（物ごとの行列を作る）だけを測って知らせる。
    def timedItems(hooks: Hooks, kit: Draw.Kit, w: World): List[Render.PlacedItem] \ IO =
        let t = (hooks#sceneTime)(w#t);
        let (items, ms) = BenchRun.timed(hooks#now, () -> Draw.items(kit, t));
        (hooks#noteSim)(ms);
        items

    /// デスクトップとブラウザの入口が同じ App を組む。
    pub def app(plan: BenchRun.Plan, emit: String -> Unit \ IO, hooks: Hooks, kit: Draw.Kit, scenario: Scenes.Scenario): App.App[World, IO] =
        App.make({ t = 0.0, progress = BenchRun.start() })
            |> App.addSystem(step(plan, emit, kit, scenario))
            |> BenchRun.withDiagnostics(plan)
            |> App.withView((_ctx, w) -> checked_ecast(timedItems(hooks, kit, w)))
            |> App.withPostStack(_ -> checked_ecast(Draw.post()))
}
