// 入口。実機の窓で毎コマ同じ部屋を描き、カメラを左右へゆっくり振る。300 コマごとに 1 コマの p50 / p95 と GPU の時間の p50
// （FrameDiagnostics.gpuNs・1〜2 コマ遅れの値）を出し、4 区間で閉じる。
// 描く道は実機と同じ（App の view → App.Internal.Paint.submitGpuItems → Platform.Draw3d.drawScene3d）。
use fge::GameEngine

mod SceneBench {
    use fge::{App, LwjglLayer, RenderUtil, Num, Vec2}

    import java.lang.System
    import org.lwjgl.glfw.GLFW

    pub type alias World = { t = Float64, segment = Int32, frameInSegment = Int32, samples = List[Float64], gpuSamples = List[Float64], done = Bool }

    pub def initialWorld(): World = { t = 0.0, segment = 0, frameInSegment = 0, samples = Nil, gpuSamples = Nil, done = false }

    def segmentCount(): Int32 = 4

    def framesPerSegment(): Int32 = 300

    /// 起動直後は JIT とメッシュの初めての上げで dt が荒れるため、各区間の頭を捨てる。
    def warmup(): Int32 = 60

    /// カメラの yaw（ラジアン）。正面（北）を中心に ±0.6 を 16 秒ほどで往復する。
    pub def yawAt(t: Float64): Float64 = 0.6 * Num.sin(t * 0.4)

    /// エンジンには手を入れない決まりなので、垂直同期はゲーム側から GLFW を直接叩いて切る。
    // WhyNot: 起動直後に 1 回だけ切らない — macOS では描くループの前に呼んでも 60fps に張り付いたままだった。
    def vsyncOff(): Unit \ IO = GLFW.glfwSwapInterval(0)

    pub def step(frame: App.Frame, w: World): World \ IO =
        if (w#done) w
        else {
            if (w#frameInSegment < warmup()) vsyncOff() else ();
            let measured = w#frameInSegment >= warmup();
            let sampled = if (measured) frame#dt :: w#samples else w#samples;
            let gpu = frame#diagnostics |> Option.flatMap(d -> d#gpuNs) |> Option.filter(ns -> ns > 0i64);
            let gpuSampled = match gpu {
                case Some(ns) if measured => Int64.toFloat64(ns) / 1.0e9 :: w#gpuSamples
                case _                    => w#gpuSamples
            };
            let t = w#t + frame#dt;
            if (w#frameInSegment + 1 >= framesPerSegment()) {
                report(w#segment, sampled, gpuSampled);
                let next = w#segment + 1;
                { t = t, segment = next, frameInSegment = 0, samples = Nil, gpuSamples = Nil, done = next >= segmentCount() }
            } else
                { t = t, frameInSegment = w#frameInSegment + 1, samples = sampled, gpuSamples = gpuSampled | w }
        }

    def report(segment: Int32, samples: List[Float64], gpuSamples: List[Float64]): Unit \ IO =
        let sorted = List.sort(samples) |> List.toVector;
        let count = Vector.length(sorted);
        let gpuSorted = List.sort(gpuSamples) |> List.toVector;
        let gpuCount = Vector.length(gpuSorted);
        // WhyNot: GPU の時間が測れないコマを 0 として数えない — 隠し窓や timer query の無い GL では 0 か None が続き、中央値が嘘になる。
        let gpuText = if (gpuCount == 0) "gpu=測れない"
                      else "gpu p50=${fmt2(Vector.get(gpuCount / 2, gpuSorted) * 1000.0)}ms（${Int32.toString(gpuCount)} コマ）";
        if (count == 0) println("[scene3d] 区間 ${Int32.toString(segment)}: 測れたコマが無い")
        else {
            let at = q -> Vector.get(Int32.min(count - 1, count * q / 100), sorted) * 1000.0;
            println("[scene3d] 区間 ${Int32.toString(segment)}: p50=${fmt2(at(50))}ms p95=${fmt2(at(95))}ms（${Int32.toString(count)} コマ） ${gpuText}")
        }

    /// Float64 をそのまま補間すると桁が長すぎてログが読めないため、小数 2 桁で切る。
    def fmt2(x: Float64): String =
        let cents = RenderUtil.floatToInt32(x * 100.0);
        let frac = Int32.modulo(cents, 100);
        let fracText = if (frac < 10) "0${frac}" else "${frac}";
        "${cents / 100}.${fracText}"

    pub def go(): Unit \ IO =
        run {
            match Room.loadMeshes() {
                case Err(why) =>
                    println("[scene3d] 家具を読めない: ${why}");
                    System.exit(1)
                case Ok(meshes) =>
                    let kit = Room.kitOf(meshes);
                    App.make(initialWorld())
                        |> App.addSystem(step)
                        |> App.withDiagnostics
                        |> App.withView((_ctx, w) -> checked_ecast(Room.items(kit, yawAt(w#t))))
                        |> App.quitWhen((_frame, w) -> checked_ecast(w#done))
                        |> App.launch
            }
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else SceneBench.go()
