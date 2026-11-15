// 門の WebGPU の側の読み込みを、実機のウィンドウ（LwjglLayer.Internal.WebGpuWindowLayer）の読み込みそのもので通す口。
// WhyNot: 門の中に読み込みを写さない — 写すと、ウィンドウの読み込みが崩れても門が緑のまま気づけない。
// WhyNot: WebGpuWindowLayer の読み込みを pub に開かない — 子孫の mod からは pub でない物が見えるので、門をここに置けば足りる（engine の pub を増やさない）。
pub mod LwjglLayer.Internal.WebGpuWindowLayer.V1Assets {
    use LwjglLayer.Internal.WebGpuWindowLayer.{loadFonts, loadTextures}
    use RenderPaint.Internal.WebGpuPaint

    /// project.json の絵とフォントを paint に上げ、名前 → アトラスの引き口を返す。
    pub def loadAll(paint: WebGpuPaint.Paint, config: GameEngine.EngineConfig): RenderPaint.Fonts \ IO =
        loadTextures(paint, config#textureManifest, (_, _) -> checked_ecast(()));
        loadFonts(paint, config, (_, _, _) -> checked_ecast(()))
}
