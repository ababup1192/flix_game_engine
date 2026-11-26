// Render3d.GpuSpans — 3D の描き手が GPU の時間を測る区間の名前（FrameDiagnostics.Diagnostics.gpuPasses の行）と、送る時間を切り分ける試しの旗。
// GL（Render3d・Render3d.Shadow）と WebGPU（Render3d.WebGpuRenderer・Render3d.WebGpuShadows）が同じ名前を使う。
// 試しの旗 FLIX_GE_SKIP_3D_DRAWS=shadow|color|all は、pass を開いて閉じるだけにして中の draw を積まない（絵は欠ける）。
// 影の pass か色の pass の draw を積む CPU の分と、GPU が塗る分を、submit の時間の変わり方で分けて見る（docs/performance.md の §11）。
mod Render3d.GpuSpans {
    import java.lang.System

    /// 影の地図の pass の区間の名前（光の種類ごと）。
    pub def shadowSpanOf(sampling: Render3d.ShadowMaps.ShadowSampling): String = match sampling {
        case Render3d.ShadowMaps.ShadowSampling.Sun(_)   => "shadow:sun"
        case Render3d.ShadowMaps.ShadowSampling.Spot(_)  => "shadow:spot"
        case Render3d.ShadowMaps.ShadowSampling.Point(_) => "shadow:point"
    }

    /// 場面の pass の区間の名前（色の場面と奥行きの書き出しを分ける）。
    pub def sceneSpanOf(scene: Scene3d.Scene3dCmd): String = match scene#output {
        case Scene3d.Output.Color    => "scene3d"
        case Scene3d.Output.Depth(_) => "scene3d:depth"
    }

    /// 場面の pass spec の区間の名前（sceneSpanOf と同じ名前）。
    pub def passSpanOf(spec: Render3d.ScenePlan.ScenePassSpec): String = match spec {
        case Render3d.ScenePlan.ScenePassSpec.Color       => "scene3d"
        case Render3d.ScenePlan.ScenePassSpec.DepthOut(_) => "scene3d:depth"
    }

    /// FLIX_GE_SKIP_3D_DRAWS の字から、影の pass の draw を積まないか。
    pub def isShadowSkippedBy(text: Option[String]): Bool = text == Some("shadow") or text == Some("all")

    /// FLIX_GE_SKIP_3D_DRAWS の字から、場面の pass の draw を積まないか。
    pub def isColorSkippedBy(text: Option[String]): Bool = text == Some("color") or text == Some("all")

    /// 今の環境で影の pass の draw を積まないか。
    pub def skipsShadowDraws(): Bool \ IO = isShadowSkippedBy(skipText())

    /// 今の環境で場面の pass の draw を積まないか。
    pub def skipsColorDraws(): Bool \ IO = isColorSkippedBy(skipText())

    def skipText(): Option[String] \ IO = Object.toOption(System.getenv("FLIX_GE_SKIP_3D_DRAWS"))
}
