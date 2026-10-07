// UiShape — 図形 widget の共有語彙。パラメトリックな図形（Shape）と、その内在サイズ・
// 「確定 rect の中心に描く」射影（placedItems）を持つ。
// UiDoc（宣言ドキュメント → Flex の静的経路）と UiExtract（UiStore の動的経路）の両方が
// ここを呼ぶことで、同じ JSON の図形ノードが経路によらず同じ絵になる。
// 注意: 幾何は flix_ge_shapes ギャラリーで PNG バイト一致まで検証した実装の逐語移設 —
// 演算の順序ひとつで検証が壊れるので、見た目の等価な書き換えもしないこと。

pub mod UiShape {

    /// パラメトリックな図形。座標を持つもの（line/polyline/bezier/poly 由来の点列）は
    /// 「解決 rect の中心相対」で持ち、placedItems が中心へ写す。
    pub enum Shape {
        case CircleS({ radius = Float64 })
        case NgonS({ n = Int32, radius = Float64 })
        case StarS({ points = Int32, outer = Float64, inner = Float64, via = Via })
        case EllipseS({ radii = Vec2.Vec2, segments = Int32, via = Via })
        case SectorS({ radius = Float64, fromT = Float64, toT = Float64 })
        case SegmentS({ radius = Float64, fromT = Float64, toT = Float64 })
        case LineS({ a = Vec2.Vec2, b = Vec2.Vec2, lineWidth = Float64 })
        case PolylineS({ points = List[Vec2.Vec2], lineWidth = Float64 })
        case BezierS({ p0 = Vec2.Vec2, ctrl = Vec2.Vec2, p1 = Vec2.Vec2,
                       steps = Int32, widthFrom = Float64, widthTo = Float64 })
    }

    /// 同じ絵を出す 2 レイヤの選択（star / ellipse）。RenderVia = Item の近道、
    /// BezierVia = 頂点列 + fill（加工できる素材レイヤ）。
    pub enum Via with Eq { case RenderVia case BezierVia }

    /// 図形 widget の描画コンポーネント。alpha は Render.fade、border は円（Box）にのみ効く。
    pub type alias ShapeComp = {
        shape = Shape, color = Color, alpha = Float64, zIndex = Int32,
        borderWidth = Float64, borderColor = Option[Color]
    }

    /// 図形のパラメータから導く内在サイズ（width/height 未指定時に Px として敷かれる）。
    pub def intrinsicSize(shape: Shape): Vec2.Vec2 =
        match shape {
            case Shape.CircleS(c)   => { x = c#radius * 2.0, y = c#radius * 2.0 }
            case Shape.NgonS(g)     => { x = g#radius * 2.0, y = g#radius * 2.0 }
            case Shape.StarS(s)     => { x = s#outer * 2.0, y = s#outer * 2.0 }
            case Shape.EllipseS(e)  => { x = e#radii#x * 2.0, y = e#radii#y * 2.0 }
            case Shape.SectorS(s)   => { x = s#radius * 2.0, y = s#radius * 2.0 }
            case Shape.SegmentS(s)  => { x = s#radius * 2.0, y = s#radius * 2.0 }
            case Shape.LineS(l)     => bboxSize(RawDraw.lineQuad(l#a, l#b, l#lineWidth))
            case Shape.PolylineS(p) => bboxSize(p#points)
            case Shape.BezierS(b)   => bboxSize(Bezier.quadratic(b#p0, b#ctrl, b#p1, b#steps))
        }

    /// 頂点列のバウンディングボックスの大きさ（空なら 0）。
    def bboxSize(points: List[Vec2.Vec2]): Vec2.Vec2 =
        match points {
            case Nil => { x = 0.0, y = 0.0 }
            case first :: rest =>
                let bounds = List.foldLeft((acc, p) -> {
                    minX = Float64.min(acc#minX, p#x), minY = Float64.min(acc#minY, p#y),
                    maxX = Float64.max(acc#maxX, p#x), maxY = Float64.max(acc#maxY, p#y)
                }, { minX = first#x, minY = first#y, maxX = first#x, maxY = first#y }, rest);
                { x = bounds#maxX - bounds#minX, y = bounds#maxY - bounds#minY }
        }

    /// 図形を rect の中心に描く。修飾は「fade → outline → 置く」の順（ギャラリーの書き味と同順）。
    pub def placedItems(s: ShapeComp, r: Rect2.Rect2): List[Render.PlacedItem] =
        let center = Rect2.center(r);
        match s#shape {
            case Shape.CircleS(c) =>
                let item = RawDraw.circle(c#radius, s#color, s#zIndex)
                    |> fadeIf(s#alpha)
                    |> outlineIf(s);
                Render.atCenter(center, { x = c#radius * 2.0, y = c#radius * 2.0 }, item) :: Nil
            case Shape.NgonS(g) =>
                ({ at = center, item = fadeIf(s#alpha, RawDraw.ngon(g#n, g#radius, s#color, s#zIndex)) }) :: Nil
            case Shape.StarS(st) => match st#via {
                case Via.RenderVia =>
                    ({ at = center,
                       item = fadeIf(s#alpha, RawDraw.star(st#points, { outer = st#outer, inner = st#inner },
                                                          s#color, s#zIndex)) }) :: Nil
                case Via.BezierVia =>
                    Bezier.fill(Bezier.star(center, rOut = st#outer, rIn = st#inner), s#color, s#zIndex)
            }
            case Shape.EllipseS(e) => match e#via {
                case Via.RenderVia =>
                    ({ at = center, item = fadeIf(s#alpha, RawDraw.ellipse(e#radii, s#color, s#zIndex)) }) :: Nil
                case Via.BezierVia =>
                    Bezier.convexFill(Bezier.ellipse(center, e#radii#x, e#radii#y, e#segments), s#color, s#zIndex)
            }
            case Shape.SectorS(sc) =>
                ({ at = center,
                   item = fadeIf(s#alpha, RawDraw.sector(sc#radius, { fromT = sc#fromT, toT = sc#toT },
                                                        s#color, s#zIndex)) }) :: Nil
            case Shape.SegmentS(sg) =>
                ({ at = center,
                   item = fadeIf(s#alpha, RawDraw.circleSegment(sg#radius, { fromT = sg#fromT, toT = sg#toT },
                                                               s#color, s#zIndex)) }) :: Nil
            case Shape.LineS(l) =>
                RawDraw.lineSeg(Vec2.add(center, l#a), Vec2.add(center, l#b), l#lineWidth,
                               s#color, s#zIndex) :: Nil
            case Shape.PolylineS(pl) =>
                Bezier.polyline(List.map(p -> Vec2.add(center, p), pl#points),
                                width = pl#lineWidth, s#color, s#zIndex)
            case Shape.BezierS(b) =>
                let spine = Bezier.quadratic(Vec2.add(center, b#p0), Vec2.add(center, b#ctrl),
                                             Vec2.add(center, b#p1), b#steps);
                Bezier.stroke({ spine = spine, color = s#color, z = s#zIndex },
                              t -> b#widthFrom + (b#widthTo - b#widthFrom) * t)
        }

    /// alpha < 1 のときだけ Render.fade を掛ける（1.0 は無修飾のまま — 既存の絵を変えない）。
    pub def fadeIf(alpha: Float64, item: Render.Item): Render.Item =
        if (alpha < 1.0) Render.fade(alpha, item) else item

    def outlineIf(s: ShapeComp, item: Render.Item): Render.Item =
        if (s#borderWidth > 0.0)
            Render.outline(Option.getWithDefault(white(), s#borderColor), s#borderWidth, item)
        else item

    def white(): Color = {r = 1.0, g = 1.0, b = 1.0}
}
