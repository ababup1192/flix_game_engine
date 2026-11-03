// ShaderEffect — 描き手の handler がまだ受けている、宣言シェーダー面と 3D の場面の op（eff Shader）。
// render_gl の RenderLegacyBridge が Platform.GpuResources・Platform.Draw2d・Platform.Draw3d からここへ回す。

pub mod ShaderEffect {

    /// DrawCmd.SurfaceRenderCmd の古い名前。0.84.0 で消える。
    pub type alias ShaderRenderCmd = DrawCmd.SurfaceRenderCmd

    /// WhyNot 呼ぶ側から使わない: 呼ぶ側は Platform.GpuResources.buildProgram・Platform.Draw2d.drawSurface・
    /// Platform.Draw3d.drawScene3d を使う（App はこの op を出さない）。
    pub eff Shader {
        /// Spec を GLSL プログラムへコンパイルしハンドルを返す（起動時/リロード時に 1 回）。
        /// 失敗時は bug! でなく単色フォールバックプログラムを返す（fail-open）— theme 由来の
        /// codegen ミスで全体がクラッシュしないように。
        def buildProgram(spec: ShaderDoc.Spec): GpuHandle.ShaderProgram
        /// シェーダー面 1 枚を描く。骨格では「床タイルと壁の間の固定 z-index の範囲」へそろえて
        /// renderCommands の下に敷く（暗くするオーバーレイ・ハロが上に正しく乗る）。
        def drawSurface(cmd: DrawCmd.SurfaceRenderCmd): Unit
        /// 3D の場面 1 つを、深度で前後を決めて描く（2D の並びの中では cmd#scene#zIndex の 1 点に入る）。
        def drawScene3d(cmd: Scene3d.RenderCmd): Unit
    }

    /// この eff の op を直に呼ぶ物向けの何もしないハンドラ。buildProgram は無効ハンドル（0）を返し、drawSurface と drawScene3d は捨てる。
    /// WhyNot App を包んでも効かない: App は Platform の effect を出すので、ここまで届かない。
    pub def runNoop(f: Unit -> a \ ef + Shader): a \ ef =
        run f() with handler Shader {
            def buildProgram(_spec, k) = k(GpuHandle.wrapShaderProgram(0))
            def drawSurface(_cmd, k)   = k(())
            def drawScene3d(_cmd, k)   = k(())
        }
}
