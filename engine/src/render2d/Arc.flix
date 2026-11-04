/// 円弧・リングを描く描画物。中心（描画原点）から半径 `radius`（外周）・太さ `width` の
/// リングを、`startAngle` から `endAngle` まで単色で塗る。角度はラジアンで、時計回りに
/// 増える（画面の +y は下向き）。
/// `endAngle` を毎フレーム動かすだけで扇形を伸縮できるので、クールダウンやタイマーの
/// 円形ゲージを状態を持たずに描ける（伸縮の駆動はゲーム側）。
/// 利用例: スキルのクールダウンを残り時間ぶんの扇形で見せる / 背景の輪を描く。
/// 注意: 塗りは凸ポリゴンだけなので、リングは中空円として `segments` 個の台形に分割し、
///       各セグメントを 1 つの PolygonRenderCmd として出す。
pub enum Arc {
    case Arc({
        transform = Transform,     // 位置・回転・スケール・せん断
        visual = Visual,           // 色変調・可視性・描画順
        alpha = Float64,
        radius = Float64,      // 外周半径（px）
        width = Float64,       // リングの太さ（px）。内半径 = radius - width（0 未満は中心まで塗る扇形）
        startAngle = Float64,  // 円弧開始角（ラジアン）
        endAngle = Float64,    // 円弧終了角（ラジアン）。endAngle <= startAngle なら非描画
        segments = Int32       // 円弧の分割数（多いほど滑らか）
    })
}

pub mod Arc {

    /// 全周（2π）の既定分割数。小さなインジケータには十分滑らか。
    def defaultSegments(): Int32 = 32

    /// 全周 = 2π（ラジアン）。全周リングの endAngle 既定や、比率→角度の換算に使う。
    pub def tau(): Float64 = 6.283185307179586

    /// 半径・太さ・開始/終了角を指定して円弧を生成する（alpha=1.0 不透明、segments 既定）。
    pub def make(radius: Float64, width: Float64,
                 startAngle: Float64, endAngle: Float64, color: Color): Arc =
        Arc.Arc({
            transform = { position = {x = 0.0, y = 0.0}, rotation = 0.0, scale = {x = 1.0, y = 1.0}, skew = 0.0 },
            visual = Visual.setColor(color, Visual.default()),
            alpha = 1.0,
            radius = radius,
            width = width,
            startAngle = startAngle,
            endAngle = endAngle,
            segments = defaultSegments()
        })

    /// 全周リング（startAngle=0, endAngle=2π）を生成するショートカット。背景の輪などに使う。
    pub def ring(radius: Float64, width: Float64, color: Color): Arc =
        make(radius, width, 0.0, tau(), color)

    /// 埋め込んだ Transform 部品を取り出す
    pub def transform(arc: Arc): Transform =
        let Arc.Arc(r) = arc;
        r#transform

    /// Transform 部品に関数を適用して差し替える
    pub def mapTransform(f: Transform -> Transform \ ef, arc: Arc): Arc \ ef =
        let Arc.Arc(r) = arc;
        Arc.Arc({transform = f(r#transform) | r})

    /// 埋め込んだ Visual 部品を取り出す
    pub def visual(arc: Arc): Visual =
        let Arc.Arc(r) = arc;
        r#visual

    /// Visual 部品に関数を適用して差し替える
    pub def mapVisual(f: Visual -> Visual \ ef, arc: Arc): Arc \ ef =
        let Arc.Arc(r) = arc;
        Arc.Arc({visual = f(r#visual) | r})

    pub def getRadius(arc: Arc): Float64 =
        let Arc.Arc(r) = arc; r#radius

    pub def setRadius(radius: Float64, arc: Arc): Arc =
        let Arc.Arc(r) = arc;
        Arc.Arc({radius = radius | r})

    pub def getWidth(arc: Arc): Float64 =
        let Arc.Arc(r) = arc; r#width

    pub def setWidth(width: Float64, arc: Arc): Arc =
        let Arc.Arc(r) = arc;
        Arc.Arc({width = width | r})

    pub def getEndAngle(arc: Arc): Float64 =
        let Arc.Arc(r) = arc; r#endAngle

    /// 円弧の終了角を更新する。クールダウンは `setEndAngle(start + 2π*ratio)` を毎フレーム呼ぶ。
    pub def setEndAngle(endAngle: Float64, arc: Arc): Arc =
        let Arc.Arc(r) = arc;
        Arc.Arc({endAngle = endAngle | r})

    pub def getSegments(arc: Arc): Int32 =
        let Arc.Arc(r) = arc; r#segments

    /// 分割数を設定する。1 未満は 1 にクランプ（state と描画を一致させる）。
    pub def setSegments(segments: Int32, arc: Arc): Arc =
        let Arc.Arc(r) = arc;
        Arc.Arc({segments = Int32.max(1, segments) | r})

    pub def getAlpha(arc: Arc): Float64 =
        let Arc.Arc(r) = arc; r#alpha

    pub def setAlpha(alpha: Float64, arc: Arc): Arc =
        let Arc.Arc(r) = arc;
        Arc.Arc({alpha = alpha | r})

    /// スクリーン px の塗り潰しコマンド列に変換する。`screenPos` は描画原点
    /// （カメラ/CanvasLayer 適用後）、`scaleVec` はワールドの zoom 倍率（CanvasLayer 下は (1,1)）。
    /// 各クアッドの頂点 = screenPos + (cosθ, sinθ) * 半径 * scaleVec * 描画物の scale。回転/skew は未適用。
    /// 太さ 0 以下、または endAngle <= startAngle のときは空（非描画）。
    pub def toRenderCmds(screenPos: Vec2.Vec2, scaleVec: Vec2.Vec2,
                         arc: Arc): List[GameEngine.PolygonRenderCmd] =
        let Arc.Arc(r) = arc;
        let sweep = r#endAngle - r#startAngle;
        if (sweep <= 0.0 or r#width <= 0.0) Nil
        else {
            let sx = scaleVec#x * r#transform#scale#x;
            let sy = scaleVec#y * r#transform#scale#y;
            let outerR = r#radius;
            let innerR = Float64.max(0.0, r#radius - r#width);
            let n = Int32.max(1, r#segments);
            let step = sweep / Int32.toFloat64(n);
            let mkPt = (angle, radius) ->
                ({x = screenPos#x + RenderUtil.cosF(angle) * radius * sx,
                  y = screenPos#y + RenderUtil.sinF(angle) * radius * sy}: Vec2.Vec2);
            List.range(0, n) |> List.map(i -> {
                let a0 = r#startAngle + step * Int32.toFloat64(i);
                let a1 = r#startAngle + step * Int32.toFloat64(i + 1);
                let verts =
                    mkPt(a0, outerR) :: mkPt(a1, outerR) ::
                    mkPt(a1, innerR) :: mkPt(a0, innerR) :: Nil;
                ({vertices = verts, color = r#visual#color, alpha = r#alpha, clip = None,
                  zIndex = r#visual#zIndex, blend = DrawCmd.BlendMode.Normal,
                  grad = None}: GameEngine.PolygonRenderCmd)
            })
        }
}
