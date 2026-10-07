/// Polygon — 局所座標の単純多角形 `points` を単色（color + alpha）で塗り潰す描画物。
/// 三角形や円などの簡単な図形を画像なしで出せるので、マーカーや図形エフェクトに手軽。
/// 利用例: 円形マーカー、簡易的な図形の演出。
/// 注意: テクスチャ・穴あき・UV は未対応。塗りは描画側が耳切りで三角形化するので、
/// 自己交差しない単純多角形なら凹でもよい。円は `circle` で 12 角形として生成する。
pub enum Polygon {
    case Polygon({
        transform = Transform,     // 位置・回転・スケール・せん断
        visual = Visual,           // 色変調・可視性・描画順
        alpha = Float64,
        points = List[Vec2.Vec2]   // 局所座標の頂点列（自己交差しない単純多角形・順序付き）
    })
}

pub mod Polygon {

    /// 任意の頂点列から Polygon を生成する（alpha=1.0 不透明）。
    pub def make(points: List[Vec2.Vec2], color: Color): Polygon =
        Polygon.Polygon({
            transform = { position = {x = 0.0, y = 0.0}, rotation = 0.0, scale = {x = 1.0, y = 1.0}, skew = 0.0 },
            visual = Visual.setColor(color, Visual.default()),
            alpha = 1.0,
            points = points
        })

    /// 半径 `radius`（px）の円を 12 角形として生成する。小さなマーカーには十分滑らか。
    pub def circle(radius: Float64, color: Color): Polygon =
        make(unitCircle12() |> List.map(p -> ({x = p#x * radius, y = p#y * radius}: Vec2.Vec2)),
             color)

    /// 単位円上の 12 点（30°刻み）。engine に三角関数 FFI を持ち込まないための定数テーブル。
    pub def unitCircle12(): List[Vec2.Vec2] =
        let h = 0.8660254037844387;  // cos 30° = sin 60°
        let half = 0.5;
        ({x = 1.0,        y = 0.0}: Vec2.Vec2) ::
        ({x = h,          y = half}: Vec2.Vec2) ::
        ({x = half,       y = h}: Vec2.Vec2) ::
        ({x = 0.0,        y = 1.0}: Vec2.Vec2) ::
        ({x = 0.0 - half, y = h}: Vec2.Vec2) ::
        ({x = 0.0 - h,    y = half}: Vec2.Vec2) ::
        ({x = 0.0 - 1.0,  y = 0.0}: Vec2.Vec2) ::
        ({x = 0.0 - h,    y = 0.0 - half}: Vec2.Vec2) ::
        ({x = 0.0 - half, y = 0.0 - h}: Vec2.Vec2) ::
        ({x = 0.0,        y = 0.0 - 1.0}: Vec2.Vec2) ::
        ({x = half,       y = 0.0 - h}: Vec2.Vec2) ::
        ({x = h,          y = 0.0 - half}: Vec2.Vec2) :: Nil

    /// 埋め込んだ Transform 部品を取り出す
    pub def transform(poly: Polygon): Transform =
        let Polygon.Polygon(r) = poly;
        r#transform

    /// Transform 部品に関数を適用して差し替える
    pub def mapTransform(f: Transform -> Transform \ ef, poly: Polygon): Polygon \ ef =
        let Polygon.Polygon(r) = poly;
        Polygon.Polygon({transform = f(r#transform) | r})

    /// 埋め込んだ Visual 部品を取り出す
    pub def visual(poly: Polygon): Visual =
        let Polygon.Polygon(r) = poly;
        r#visual

    /// Visual 部品に関数を適用して差し替える
    pub def mapVisual(f: Visual -> Visual \ ef, poly: Polygon): Polygon \ ef =
        let Polygon.Polygon(r) = poly;
        Polygon.Polygon({visual = f(r#visual) | r})

    pub def setAlpha(alpha: Float64, poly: Polygon): Polygon =
        let Polygon.Polygon(r) = poly;
        Polygon.Polygon({alpha = alpha | r})

    /// スクリーン px の塗り潰しコマンドに変換する。`screenPos` は描画原点
    /// （カメラ/CanvasLayer 適用後）、`scaleVec` はワールドの zoom 倍率（CanvasLayer 下は (1,1)）。
    /// 頂点 = screenPos + 局所点 * scaleVec * 描画物の scale。回転/skew は未適用。
    pub def toRenderCmd(screenPos: Vec2.Vec2, scaleVec: Vec2.Vec2,
                         poly: Polygon): GameEngine.PolygonRenderCmd =
        let Polygon.Polygon(r) = poly;
        let sx = scaleVec#x * r#transform#scale#x;
        let sy = scaleVec#y * r#transform#scale#y;
        let verts = r#points |> List.map(p ->
            ({x = screenPos#x + p#x * sx, y = screenPos#y + p#y * sy}: Vec2.Vec2));
        {vertices = verts, color = r#visual#color, alpha = r#alpha, zIndex = r#visual#zIndex, clip = None,
         blend = DrawCmd.BlendMode.Normal, grad = None}
}
