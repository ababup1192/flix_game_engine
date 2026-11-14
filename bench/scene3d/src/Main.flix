// 入口。実機の窓で場面を毎コマ描き、区間ごとに 1 行の JSON（BenchRun）を出して閉じる。場面は 2 つ:
//   部屋（既定）… 固定の部屋をカメラを左右へゆっくり振りながら描く
//   物を並べた場面（SCENE=field）… Field のつまみ（Makefile の頭）で物の数・形・材質・動く割合・半透明・影を替える
// 描く道は実機と同じ（App の view → App.Internal.Paint.submitGpuItems → Platform.Draw3d.drawScene3d）。
use fge::LwjglLayer

mod SceneBench {
    use fge::{App, LwjglLayer, Num, Render}

    import java.lang.System

    /// 描く場面。
    pub enum Scene {
        case Room(Room.Kit)
        case Field(Field.Kit)
    }

    pub type alias World = { t = Float64, progress = BenchRun.Run }

    pub def initialWorld(): World = { t = 0.0, progress = BenchRun.start() }

    /// 起動直後は JIT とメッシュの初めての上げで dt が荒れるため、各区間の頭を捨てる。
    def warmup(): Int32 = 60

    /// つまみの表の repeat = 同じ条件を続けて測る回数（揺れを見る）。
    pub def planOf(knobs: Map[String, String]): BenchRun.Plan =
        BenchRun.planOf({ warmup = warmup(), frames = 240, segments = BenchRun.intKnob("repeat", 4, knobs) }, knobs)

    /// つまみの表の scene が field かどうか。
    pub def isField(knobs: Map[String, String]): Bool = Map.get("scene", knobs) == Some("field")

    /// カメラの yaw（ラジアン）。正面（北）を中心に ±0.6 を 16 秒ほどで往復する。
    pub def yawAt(t: Float64): Float64 = 0.6 * Num.sin(t * 0.4)

    def knobsOf(scene: Scene, segment: Int32): List[(String, String)] =
        let head = ("bench", BenchRun.quoted("scene3d")) :: ("segment", Int32.toString(segment)) :: Nil;
        match scene {
            case Scene.Room(_)    => List.append(head, ("scene", BenchRun.quoted("room")) :: Nil)
            case Scene.Field(kit) => List.append(head, ("scene", BenchRun.quoted("field")) :: Field.knobFields(kit#config))
        }

    pub def step(plan: BenchRun.Plan, emit: String -> Unit \ IO, scene: Scene, frame: App.Frame, w: World): World \ IO =
        if (w#progress#done) w
        else { t = w#t + frame#dt, progress = BenchRun.advance(plan, emit, knobsOf(scene), BenchRun.sampleOf(frame, 0.0), w#progress) }

    pub def items(scene: Scene, w: World): List[Render.PlacedItem] = match scene {
        case Scene.Room(kit)  => Room.items(kit, yawAt(w#t))
        case Scene.Field(kit) => Field.items(kit, w#t)
    }

    /// デスクトップとブラウザの入口が同じ App を組む。
    pub def app(plan: BenchRun.Plan, emit: String -> Unit \ IO, scene: Scene): App.App[World, IO] =
        App.make(initialWorld())
            |> App.addSystem(step(plan, emit, scene))
            |> BenchRun.withDiagnostics(plan)
            |> App.withView((_ctx, w) -> checked_ecast(items(scene, w)))

    def loadScene(knobs: Map[String, String]): Result[String, Scene] \ Fs.FileRead =
        if (isField(knobs)) Ok(Scene.Field(Field.kitOf(Field.configOf(knobs))))
        else Room.loadMeshes() |> Result.map(meshes -> Scene.Room(Room.kitOf(meshes)))

    pub def go(): Unit \ IO =
        let knobs = BenchEnv.knobs(("SCENE", "scene") :: ("COUNT", "n") :: ("SHAPES", "shapes") :: ("MATS", "mats") :: ("MOVING", "moving") ::
                                   ("ALPHA", "alpha") :: ("SHADOW", "shadow") :: ("FRAMES", "frames") :: ("REPEAT", "repeat") :: ("DIAG", "diag") :: Nil);
        run {
            match loadScene(knobs) {
                case Err(why) =>
                    println("[scene3d] 家具を読めない: ${why}");
                    System.exit(1)
                case Ok(scene) =>
                    app(planOf(knobs), BenchEnv.emit, scene)
                        |> App.quitWhen((_frame, w) -> checked_ecast(w#progress#done))
                        |> App.launchForBench
            }
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else SceneBench.go()
