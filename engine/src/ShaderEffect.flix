// ShaderEffect — 宣言シェーダー面の描画命令の古い型の名前だけを残す所（中身は DrawCmd.SurfaceRenderCmd）。

pub mod ShaderEffect {

    /// DrawCmd.SurfaceRenderCmd の古い名前。0.84.0 で消える。
    pub type alias ShaderRenderCmd = DrawCmd.SurfaceRenderCmd
}
