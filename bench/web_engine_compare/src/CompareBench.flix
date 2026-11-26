// CompareBench — 場面を毎コマ描き、区間ごとに 1 行の JSON（BenchRun）を出す（engine の口で回す道・make bench-web）。
// つまみ: scenario=k1|k2・level=<物の数>・frames=<1 区間のコマ数>・repeat=<区間の数>・diag=0。
mod CompareBench {
    use fge::{App, Render}

    pub type alias World = { t = Float64, progress = BenchRun.Run }

    /// 起動直後は JIT とメッシュの初めての上げで dt が荒れるため、各区間の頭を捨てる。
    def warmup(): Int32 = 90

    pub def planOf(knobs: Map[String, String]): BenchRun.Plan =
        BenchRun.planOf({ warmup = warmup(), frames = 240, segments = BenchRun.intKnob("repeat", 3, knobs) }, knobs)

    /// 測る場面（無い・読めないつまみは K1）。
    pub def scenarioOf(knobs: Map[String, String]): Scenes.Scenario =
        Map.get("scenario", knobs) |> Option.flatMap(Scenes.scenarioOf) |> Option.getWithDefault(Scenes.Scenario.K1)

    pub def levelOf(scenario: Scenes.Scenario, knobs: Map[String, String]): Int32 =
        BenchRun.intKnob("level", if (scenario == Scenes.Scenario.K2) 500 else 1, knobs)

    def knobsOf(kit: Draw.Kit, scenario: Scenes.Scenario, segment: Int32): List[(String, String)] =
        ("bench", BenchRun.quoted("web_engine_compare")) :: ("segment", Int32.toString(segment)) ::
        ("scenario", BenchRun.quoted(String.toLowerCase(ToString.toString(scenario)))) :: ("level", Int32.toString(kit#field#count)) ::
        ("triangles", Int32.toString(Scenes.triangleCount(kit#field, Geometry.fieldShapes()))) :: Nil

    def step(plan: BenchRun.Plan, emit: String -> Unit \ IO, kit: Draw.Kit, scenario: Scenes.Scenario, frame: App.Frame, w: World): World \ IO =
        if (w#progress#done) w
        else { t = w#t + frame#dt, progress = BenchRun.advance(plan, emit, knobsOf(kit, scenario), BenchRun.sampleOf(frame, 0.0), w#progress) }

    /// デスクトップとブラウザの入口が同じ App を組む。
    pub def app(plan: BenchRun.Plan, emit: String -> Unit \ IO, kit: Draw.Kit, scenario: Scenes.Scenario): App.App[World, IO] =
        App.make({ t = 0.0, progress = BenchRun.start() })
            |> App.addSystem(step(plan, emit, kit, scenario))
            |> BenchRun.withDiagnostics(plan)
            |> App.withView((_ctx, w) -> checked_ecast(Draw.items(kit, w#t)))
            |> App.withPostStack(_ -> checked_ecast(Draw.post()))
}
