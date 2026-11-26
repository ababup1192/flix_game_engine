// CompareBench — 場面を毎コマ描き、区間ごとに 1 行の JSON（BenchRun）を出す。
// 2 つの回し方が同じ App を使う: engine の口（make bench-web）と、比べる相手の harness の adapter（harness/flix-adapter.ts）。
// つまみ: scenario=k1|k2|k3|k5|k7|k8|k9・variant=naive|optimized・level=<物の数>・frames=<1 区間のコマ数>・repeat=<区間の数>・diag=0。
mod CompareBench {
    use fge::{App, Num, Render}

    /// pickSeq = 最後に答えた pick の頼みの番号・churn = K3 の作り直しの状態（ほかの場面は None）。
    pub type alias World = { t = Float64, progress = BenchRun.Run, pickSeq = Int32, churn = Option[Draw.Churn] }

    /// pick の頼み（番号と canvas の画素）。
    pub type alias PickRequest = { seq = Int32, x = Float64, y = Float64 }

    /// 外から差し込む物。sceneTime = 自分で足し上げた時刻 → 場面の時刻・now = 時計（ms）・noteSim = 場面の更新にかかった ms を外へ知らせる・
    /// pickRequest = 今の pick の頼み・notePick = pick の答え（頼みの番号・物の番号か -1・かかった ms）を外へ知らせる。
    pub type alias Hooks = { sceneTime = Float64 -> Float64 \ IO, now = Unit -> Float64 \ IO, noteSim = Float64 -> Unit \ IO,
                             pickRequest = Unit -> Option[PickRequest] \ IO, notePick = (Int32, Int32, Float64) -> Unit \ IO }

    /// 自分の時刻のまま・知らせない（engine の口で回す時）。
    pub def standalone(now: Unit -> Float64 \ IO): Hooks =
        { sceneTime = t -> checked_ecast(t), now = now, noteSim = _ -> checked_ecast(()), pickRequest = () -> checked_ecast(None), notePick = (_, _, _) -> checked_ecast(()) }

    /// 起動直後は JIT とメッシュの初めての上げで dt が荒れるため、各区間の頭を捨てる。
    def warmup(): Int32 = 90

    pub def planOf(knobs: Map[String, String]): BenchRun.Plan =
        BenchRun.planOf({ warmup = warmup(), frames = 240, segments = BenchRun.intKnob("repeat", 3, knobs) }, knobs)

    /// 測る場面（無い・読めないつまみは K1）。
    pub def scenarioOf(knobs: Map[String, String]): Scenes.Scenario =
        Map.get("scenario", knobs) |> Option.flatMap(Scenes.scenarioOf) |> Option.getWithDefault(Scenes.Scenario.K1)

    /// 物の置き方（variant=optimized なら K5 は区画ごとの staticGroup・ほかは形と材質の組ごとの MultiMesh3d）。
    pub def pathOf(scenario: Scenes.Scenario, knobs: Map[String, String]): Draw.Path =
        if (Map.get("variant", knobs) != Some("optimized")) Draw.Path.PerObject
        else if (scenario == Scenes.Scenario.K5) Draw.Path.Chunks
        else Draw.Path.Batched

    pub def levelOf(scenario: Scenes.Scenario, knobs: Map[String, String]): Int32 =
        BenchRun.intKnob("level", if (scenario == Scenes.Scenario.K1) 1 else 500, knobs)

    def knobsOf(kit: Draw.Kit, scenario: Scenes.Scenario, segment: Int32): List[(String, String)] =
        ("bench", BenchRun.quoted("web_engine_compare")) :: ("segment", Int32.toString(segment)) ::
        ("scenario", BenchRun.quoted(String.toLowerCase(ToString.toString(scenario)))) :: ("level", Int32.toString(kit#field#count)) ::
        ("triangles", Int32.toString(Scenes.triangleCount(kit#field, Scenes.shapesOf(kit#field#shapes)))) :: Nil

    /// 新しい pick の頼みがあれば答える。
    def answerPick(hooks: Hooks, kit: Draw.Kit, w: World): World \ IO =
        match (hooks#pickRequest)() {
            case Some(req) if req#seq != w#pickSeq =>
                let t = (hooks#sceneTime)(w#t);
                let (hit, ms) = BenchRun.timed(hooks#now, () -> Draw.pick(kit, t, req#x, req#y));
                (hooks#notePick)(req#seq, Option.getWithDefault(-1, hit), ms);
                { pickSeq = req#seq | w }
            case _ => w
        }

    /// K3: 場面の時刻のコマ（round(t × 60)）が進んでいれば、そのコマの 20 個を作り直す。
    /// 場面の写しと絵の画素を作る所は比べる相手の scene.update に当たるので場面の更新として知らせ、絵と材質を作る所は engine の仕事として CPU に残す。
    def churnStep(hooks: Hooks, w: World): World \ IO =
        match w#churn {
            case Some(c) =>
                let frame = Num.roundInt((hooks#sceneTime)(w#t) * 60.0);
                if (frame == 0 or frame == c#frame) w
                else {
                    let ((field, pixels), ms) = BenchRun.timed(hooks#now, () -> (Scenes.churnAt(frame, c#field), Scenes.churnPixels(frame)));
                    (hooks#noteSim)(ms);
                    { churn = Some(Draw.respawn(frame, field, pixels, c)) | w }
                }
            case None => w
        }

    def step(plan: BenchRun.Plan, emit: String -> Unit \ IO, hooks: Hooks, kit: Draw.Kit, scenario: Scenes.Scenario, frame: App.Frame, w0: World): World \ IO =
        let w = churnStep(hooks, answerPick(hooks, kit, w0));
        if (w#progress#done) { t = w#t + frame#dt | w }
        else { t = w#t + frame#dt, progress = BenchRun.advance(plan, emit, knobsOf(kit, scenario), BenchRun.sampleOf(frame, 0.0), w#progress) | w }

    /// 場面の更新（物ごとの行列を作る）だけを測って知らせる。
    def timedItems(hooks: Hooks, kit: Draw.Kit, w: World): List[Render.PlacedItem] \ IO =
        let t = (hooks#sceneTime)(w#t);
        let (items, ms) = BenchRun.timed(hooks#now, () -> Draw.items(kit, w#churn, t));
        (hooks#noteSim)(ms);
        items

    /// 区画の staticGroup を全部、起動の時に先に作らせる（見える区画を出し入れしても、初めて出るコマで作らない）。
    def withChunkPreload(kit: Draw.Kit, app0: App.App[World, IO]): App.App[World, IO] =
        if (kit#path == Draw.Path.Chunks)
            app0 |> App.withPreload3d({ groups = _ -> kit#chunks |> List.map(c -> c#group), scenes = _ -> Draw.scene(kit, None, 0.0) :: Nil | App.preload3d(_ -> "wec_chunks", _ -> Nil) })
        else app0

    /// K9: HUD の絵。名札の位置（比べる相手の scene.update に当たる）は場面の更新として知らせ、絵の列を組む所は CPU に残す。
    /// widths = 名札の字の幅の控え（字のアトラスは View で初めて手に入るので、初めのコマで 1 回量る）。
    def hudView(hooks: Hooks, h: Scenes.Hud, widths: Ref[Option[Vector[Float64]], Static], ctx: App.ViewCtx, w: World): List[Render.PlacedItem] \ IO =
        let font = (ctx#fontOf)(HudDraw.fontName());
        let measured = match Ref.get(widths) {
            case Some(v) => v
            case None    => { let v = HudDraw.labelWidths(font, h); Ref.put(Some(v), widths); v }
        };
        let t = (hooks#sceneTime)(w#t);
        let (plates, ms) = BenchRun.timed(hooks#now, () -> Vector.range(0, h#units#count) |> Vector.map(Scenes.nameplateAt(h, t)));
        (hooks#noteSim)(ms);
        HudDraw.items(h, font, measured, plates, t)

    def withHud(hooks: Hooks, kit: Draw.Kit, app0: App.App[World, IO]): App.App[World, IO] \ IO =
        match kit#field#hud {
            case Some(h) =>
                let widths = Ref.fresh(Static, None);
                app0 |> App.withFonts(HudDraw.fontName() :: Nil) |> App.withHudView((ctx, w) -> checked_ecast(hudView(hooks, h, widths, ctx, w)))
            case None => app0
        }

    /// デスクトップとブラウザの入口が同じ App を組む。
    pub def app(plan: BenchRun.Plan, emit: String -> Unit \ IO, hooks: Hooks, kit: Draw.Kit, scenario: Scenes.Scenario): App.App[World, IO] \ IO =
        App.make({ t = 0.0, progress = BenchRun.start(), pickSeq = 0, churn = if (scenario == Scenes.Scenario.K3) Some(Draw.churnOf(kit)) else None })
            |> App.addSystem(step(plan, emit, hooks, kit, scenario))
            |> BenchRun.withDiagnostics(plan)
            |> withChunkPreload(kit)
            |> App.withView((_ctx, w) -> checked_ecast(timedItems(hooks, kit, w)))
            |> App.withPostStack(_ -> checked_ecast(Draw.post()))
            |> withHud(hooks, kit)
}
