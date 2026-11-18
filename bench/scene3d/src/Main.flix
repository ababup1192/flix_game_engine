// 入口。実機の窓で場面を毎コマ描き、区間ごとに 1 行の JSON（BenchRun）を出して閉じる。場面は 2 つ:
//   部屋（既定）… 固定の部屋をカメラを左右へゆっくり振りながら描く
//   物を並べた場面（SCENE=field）… Field のつまみ（Makefile の頭）で物の数・形・材質・動く割合・半透明・影を替える
//   書斎の場面（SCENE=study）… 実写スキャンの家具（Poly Haven の glb。MODELS=<フォルダ>・既定 ../../build/polyhaven-glb・git に入れない）の卓に光る球・燭台・ランタン（src/Study.flix）
//   夜の街灯の場面（SCENE=lamps）… 街灯 8 本・SHADOWS=n で影を落とす灯りの数（0 = 影なし）・MAPSIZE・PCF（src/Lighting.flix）
//   光る球の場面（SCENE=orb）… 暗い部屋に強く光る緑の球・ろうそく・赤い瓶・本（src/Orb.flix。view transform の見比べ用）
// POST=1 で画面全体の後がけ（App.withPostStack の夕方の屋外の preset）を掛ける（後がけの重さを前後で比べる・PostStack の手本）。
// 描く道は実機と同じ（App の view → App.Internal.Paint.submitGpuItems → Platform.Draw3d.drawScene3d）。
use fge::LwjglLayer

mod SceneBench {
    use fge::{App, LwjglLayer, Num, PostStack, Render, Scene3d}

    import java.lang.System

    /// 描く場面。
    pub enum Scene {
        case Room(Room.Kit)
        case Field(Field.Kit)
        case Orb
        case Study(Study.Kit)
        case Lamps(Lighting.Config)
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
            case Scene.Orb        => List.append(head, ("scene", BenchRun.quoted("orb")) :: Nil)
            case Scene.Study(_)   => List.append(head, ("scene", BenchRun.quoted("study")) :: Nil)
            case Scene.Lamps(cfg) =>
                let shadowed = cfg#shadows |> Option.map(m -> m#maxShadowedLights) |> Option.getWithDefault(0);
                let size = cfg#shadows |> Option.map(m -> m#mapSize) |> Option.getWithDefault(0);
                List.append(head, ("scene", BenchRun.quoted("lamps")) :: ("lamps", Int32.toString(cfg#lamps)) :: ("shadows", Int32.toString(shadowed)) ::
                                  ("mapSize", Int32.toString(size)) :: ("crowd", Int32.toString(cfg#crowd)) :: Nil)
        }

    pub def step(plan: BenchRun.Plan, emit: String -> Unit \ IO, scene: Scene, frame: App.Frame, w: World): World \ IO =
        if (w#progress#done) w
        else { t = w#t + frame#dt, progress = BenchRun.advance(plan, emit, knobsOf(scene), BenchRun.sampleOf(frame, 0.0), w#progress) }

    pub def items(scene: Scene, w: World): List[Render.PlacedItem] = match scene {
        case Scene.Room(kit)  => Room.items(kit, yawAt(w#t))
        case Scene.Field(kit) => Field.items(kit, w#t)
        case Scene.Orb        => Orb.items(0.0)
        case Scene.Study(kit) => Study.items(kit)
        case Scene.Lamps(cfg) => Lighting.lampsItems(cfg, w#t)
    }

    /// 夜の街灯の場面のつまみ（shadows = 影を落とす灯りの数・0 で影なし・mapsize・pcf）。
    def lampsConfigOf(knobs: Map[String, String]): Lighting.Config =
        let n = BenchRun.intKnob("shadows", 0, knobs);
        let m = { maxShadowedLights = n, mapSize = BenchRun.intKnob("mapsize", 512, knobs), pcfRadius = BenchRun.intKnob("pcf", 1, knobs), bias = 0.04
                | Scene3d.pointShadowMap() };
        { lamps = 8, shadows = if (n > 0) Some(m) else None, crowd = BenchRun.intKnob("crowd", 0, knobs) | Lighting.defaultConfig() }

    /// つまみの表の post（1 = 夕方の屋外の preset・standard / agx / neutral = その view transform だけを替えた同じ後がけ・preset-<名前> = その preset・無し = 掛けない）。
    pub def postOf(knobs: Map[String, String]): Option[PostStack.Stack] = match Map.get("post", knobs) {
        case Some("1")        => Some(PostStack.preset(PostStack.Preset.DuskOutdoor) |> PostStack.withExposure(-0.3))
        case Some("standard") => Some(lookOf(PostStack.ViewTransform.Standard))
        case Some("agx")      => Some(lookOf(PostStack.ViewTransform.AgX))
        case Some("neutral")  => Some(lookOf(PostStack.ViewTransform.KhronosNeutral))
        case Some(name)       => PostStack.presets() |> List.find(p -> "preset-${p}" == name) |> Option.map(PostStack.preset)
        case None             => None
    }

    /// view transform の見比べの後がけ（ブルームと FXAA は同じ・露出 0）。
    def lookOf(vt: PostStack.ViewTransform): PostStack.Stack =
        PostStack.preset(PostStack.Preset.Neutral) |> PostStack.withViewTransform(vt) |> PostStack.withFxaa(true)
            |> PostStack.withBloom(Some({ threshold = 1.0, smoothness = 0.5, size = 0.04, strength = 0.45 }))

    /// デスクトップとブラウザの入口が同じ App を組む。
    pub def app(plan: BenchRun.Plan, emit: String -> Unit \ IO, scene: Scene): App.App[World, IO] =
        App.make(initialWorld())
            |> App.addSystem(step(plan, emit, scene))
            |> BenchRun.withDiagnostics(plan)
            |> App.withView((_ctx, w) -> checked_ecast(items(scene, w)))

    /// 後がけの手本: View は場面を返すだけで、トーンマップ・ブルーム・ビネット・FXAA の Pass は PostStack が組む。
    pub def withPost(post: Option[PostStack.Stack], app0: App.App[World, IO]): App.App[World, IO] = match post {
        case Some(s) => app0 |> App.withPostStack(_ -> checked_ecast(s))
        case None    => app0
    }

    def loadScene(knobs: Map[String, String]): Result[String, Scene] \ Fs.FileRead + IO =
        if (isField(knobs)) Ok(Scene.Field(Field.kitOf(Field.configOf(knobs))))
        else if (Map.get("scene", knobs) == Some("orb")) Ok(Scene.Orb)
        else if (Map.get("scene", knobs) == Some("lamps")) Ok(Scene.Lamps(lampsConfigOf(knobs)))
        else if (Map.get("scene", knobs) == Some("study")) Study.load(Map.getWithDefault("models", "../../build/polyhaven-glb", knobs)) |> Result.map(Scene.Study)
        else Room.loadMeshes() |> Result.map(meshes -> Scene.Room(Room.kitOf(meshes)))

    pub def go(): Unit \ IO =
        let knobs = BenchEnv.knobs(("SCENE", "scene") :: ("COUNT", "n") :: ("SHAPES", "shapes") :: ("MATS", "mats") :: ("MOVING", "moving") ::
                                   ("ALPHA", "alpha") :: ("SHADOW", "shadow") :: ("GROUP", "group") :: ("FRAMES", "frames") :: ("REPEAT", "repeat") :: ("DIAG", "diag") :: ("POST", "post") :: ("MODELS", "models") ::
                                   ("SHADOWS", "shadows") :: ("MAPSIZE", "mapsize") :: ("PCF", "pcf") :: ("CROWD", "crowd") :: Nil);
        run {
            match loadScene(knobs) {
                case Err(why) =>
                    println("[scene3d] 家具を読めない: ${why}");
                    System.exit(1)
                case Ok(scene) =>
                    app(planOf(knobs), BenchEnv.emit, scene)
                        |> withPost(postOf(knobs))
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
