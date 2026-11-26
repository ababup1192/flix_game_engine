// RenderPaint.Internal.DiagnosticsCollector — 1 コマの診断を溜める入れ物（GL と WebGPU の塗りのコアで同じ物を使う）。
// 入れ物が None の間は集めていない（F8 を閉じている）。取り出すと空に戻す。
pub mod RenderPaint.Internal.DiagnosticsCollector {

    pub type alias Collector = Ref[Option[FrameDiagnostics.Diagnostics], Static]

    pub def fresh(): Collector \ IO = Ref.fresh(Static, None)

    /// 診断を集めている時だけ、このコマの診断を f で書き換える（集めていなければ f を呼ばない）。
    pub def note(collector: Collector, f: FrameDiagnostics.Diagnostics -> FrameDiagnostics.Diagnostics): Unit \ IO =
        match Ref.get(collector) {
            case Some(d) => Ref.put(Some(f(d)), collector)
            case None    => ()
        }

    pub def setEnabled(collector: Collector, on: Bool): Unit \ IO =
        Ref.put(if (on) Some(FrameDiagnostics.empty()) else None, collector)

    /// 溜まった診断を取り出して空に戻す。draw2dCounts と scene3dCounts は呼ぶ側が取り出した数をそのまま入れる。
    /// shaderBuilds は 2D のシェーダーの後ろに 3D の材質のプログラムを足す（liveShaders には 3D の材質を数えない）。
    // WhyNot: 集めていない時に draw2d と scene3d を受け取っても捨てる — 数の取り出しは集めているかに関わらず毎回呼ぶ側で行い、溜めっぱなしにしない。
    pub def take(collector: Collector, draw2d: FrameDiagnostics.Draw2dCounts, scene3d: FrameDiagnostics.Scene3dCounts,
                 liveShaders: Int32): FrameDiagnostics.Diagnostics \ IO =
        match Ref.get(collector) {
            case None    => FrameDiagnostics.empty()
            case Some(d) =>
                Ref.put(Some(FrameDiagnostics.empty()), collector);
                { shaderBuilds = List.append(List.reverse(d#shaderBuilds), scene3d#materialBuilds),
                  textureUploads = List.reverse(d#textureUploads), liveShaders = liveShaders,
                  draw2dCounts = draw2d, scene3dCounts = scene3d | d }
        }
}
