/// ※ これは Drawable 経路（view = None で renderCommands を自前で組むゲーム）
/// の投影部品。PlacedItem 経路（withView のゲーム）は App.withCamera / withZoom + CameraRig が
/// 同じ役割を担うので、そちらでは使わない。
///
/// world → screen のビュー変換と、その投影数式を持つ。カメラ位置に依存しない純関数だけを置く。
/// カメラは viewTransform でこの ViewTransform を作り、描画側が各描画物の
/// worldPos を applyToWorldPos に通して screen 座標へ移す。
pub mod Projection {

    /// ビュー変換: screenPos = worldPos * scale - offset。
    /// scale は zoom 倍率、offset は screen 原点のずれ。
    pub type alias ViewTransform = { offset = Vec2.Vec2, scale = Vec2.Vec2 }

    /// world 座標を screen 座標に変換する: screen = world * scale - offset
    pub def applyToWorldPos(transform: ViewTransform, worldPos: Vec2.Vec2): Vec2.Vec2 =
        {x = worldPos#x * transform#scale#x - transform#offset#x,
         y = worldPos#y * transform#scale#y - transform#offset#y}

    /// カメラ位置 `center` を画面中央に置く投影を作る。
    ///   screen = world * zoom - (center * zoom - viewport/2)
    /// zoom は「大きいほど寄る」（例: 0.32 で引き）。Bevy OrthographicProjection.scale とは
    /// 逆センスで、これは意図的な非互換。
    pub def viewTransform(zoom: Vec2.Vec2, center: Vec2.Vec2,
                          viewport: {viewportWidth = Float64, viewportHeight = Float64}): ViewTransform =
        let halfW = viewport#viewportWidth / 2.0;
        let halfH = viewport#viewportHeight / 2.0;
        { scale = zoom,
          offset = {x = center#x * zoom#x - halfW, y = center#y * zoom#y - halfH} }
}
