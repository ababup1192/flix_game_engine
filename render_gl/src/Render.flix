// RenderType — 描画コマンドの型エイリアス
//
// shape は engine の GameEngine.Drawable / TileInstance / TileMapRenderCmd と一致。

mod RenderType {

    /// 角丸＋枠線スタイル。共有の描画命令型 `DrawCmd.BoxStyle`。
    pub type alias BoxStyle = DrawCmd.BoxStyle

    /// スプライト 1 つ分の描画コマンド。共有型 `DrawCmd.Drawable`。
    pub type alias Drawable = DrawCmd.Drawable

    /// TileLayer の 1 タイル分の GPU インスタンスデータ。共有型 `DrawCmd.TileInstance`。
    pub type alias TileInstance = DrawCmd.TileInstance

    /// Polygon の塗り潰し描画コマンド。共有型 `DrawCmd.PolygonRenderCmd`。
    pub type alias PolygonCmd = DrawCmd.PolygonRenderCmd

    /// TileLayer のインスタンス描画コマンド (1 draw call で全タイル)。共有型 `DrawCmd.TileMapRenderCmd`。
    pub type alias TileMapRenderCmd = DrawCmd.TileMapRenderCmd

}
