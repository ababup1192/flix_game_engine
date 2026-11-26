// GL と WebGPU の塗りのコアが共有する診断の入れ物の、取り出しの形を固定する（F8 の数が描き手で違わないこと）。
mod TestDiagnosticsCollector {
    use RenderPaint.Internal.DiagnosticsCollector

    def build(name: String): FrameDiagnostics.ShaderBuild = { name = name, reason = FrameDiagnostics.BuildReason.First }

    def scene3dWith(builds: List[FrameDiagnostics.ShaderBuild]): FrameDiagnostics.Scene3dCounts =
        { materialBuilds = builds | FrameDiagnostics.emptyScene3dCounts() }

    def names(d: FrameDiagnostics.Diagnostics): List[String] = List.map(b -> b#name, d#shaderBuilds)

    /// 取り出した shaderBuilds は、2D のシェーダーを作った順の後ろに 3D の材質のプログラムが続く。
    @Test
    def testShaderBuildsPut2dBeforeMaterials(): Unit \ {Assert, IO} =
        let c = DiagnosticsCollector.fresh();
        DiagnosticsCollector.setEnabled(c, true);
        DiagnosticsCollector.note(c, d -> { shaderBuilds = build("a") :: d#shaderBuilds | d });
        DiagnosticsCollector.note(c, d -> { shaderBuilds = build("b") :: d#shaderBuilds | d });
        let d = DiagnosticsCollector.take(c, FrameDiagnostics.emptyDraw2dCounts(), scene3dWith(build("m1") :: build("m2") :: Nil), 0);
        Assert.assertEq(expected = "a" :: "b" :: "m1" :: "m2" :: Nil, names(d))

    /// 2D のシェーダーを 1 つも作っていないコマ（WebGPU の 2D）でも、3D の材質のプログラムは shaderBuilds に数える。
    @Test
    def testMaterialBuildsCountWithoutAny2dBuild(): Unit \ {Assert, IO} =
        let c = DiagnosticsCollector.fresh();
        DiagnosticsCollector.setEnabled(c, true);
        let d = DiagnosticsCollector.take(c, FrameDiagnostics.emptyDraw2dCounts(), scene3dWith(build("m1") :: Nil), 0);
        Assert.assertEq(expected = 1, List.length(d#shaderBuilds))

    /// 取り出した後は空に戻り、次の取り出しに前のコマの物が残らない。
    @Test
    def testTakeResetsToEmpty(): Unit \ {Assert, IO} =
        let c = DiagnosticsCollector.fresh();
        DiagnosticsCollector.setEnabled(c, true);
        DiagnosticsCollector.note(c, d -> { textureUploads = "t" :: d#textureUploads | d });
        discard DiagnosticsCollector.take(c, FrameDiagnostics.emptyDraw2dCounts(), FrameDiagnostics.emptyScene3dCounts(), 0);
        let d = DiagnosticsCollector.take(c, FrameDiagnostics.emptyDraw2dCounts(), FrameDiagnostics.emptyScene3dCounts(), 0);
        Assert.assertEq(expected = Nil, d#textureUploads)

    /// 集めていない間は、渡した数も捨てて空の診断を返す。
    @Test
    def testDisabledReturnsEmpty(): Unit \ {Assert, IO} =
        let c = DiagnosticsCollector.fresh();
        let d = DiagnosticsCollector.take(c, FrameDiagnostics.emptyDraw2dCounts(), scene3dWith(build("m1") :: Nil), 3);
        Assert.assertEq(expected = Nil, names(d))
}
