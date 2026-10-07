/// Anchor — 親の枠の中で子をどこに置くか（左上・中央・全面など）を、決まった型で選ぶ。
/// 座標を数値で細かく指定せず「どの位置か」を名前で選べるので、画面サイズが変わっても寄せ方が保たれる。
/// 利用例: ボタンを親の中央に置く / パネルを親いっぱいに広げる / ラベルを右下に置く。
///
/// 配置の決め方 (`applyAnchor`):
///   - 全面系 (FullRect): 子は親の枠いっぱい（margin で内側に詰められる）
///   - 位置系 (TopLeft, Center など): 子の大きさはそのまま、置く位置だけを選んだ寄せに合わせる

pub enum Anchor with Eq, ToString {
    /// 左上。デフォルト
    case TopLeft
    /// 上中央
    case TopCenter
    /// 右上
    case TopRight
    /// 左中央
    case LeftCenter
    /// 中央
    case Center
    /// 右中央
    case RightCenter
    /// 左下
    case BottomLeft
    /// 下中央
    case BottomCenter
    /// 右下
    case BottomRight
    /// 親 rect 全面 (margin で inset 可)
    case FullRect
}

pub mod Anchor {

    /// 文字列から Anchor を parse する。scene.json の `"anchor": "FullRect"` 等のパース用。
    pub def fromString(s: String): Option[Anchor] =
        match s {
            case "TopLeft"      => Some(Anchor.TopLeft)
            case "TopCenter"    => Some(Anchor.TopCenter)
            case "TopRight"     => Some(Anchor.TopRight)
            case "LeftCenter"   => Some(Anchor.LeftCenter)
            case "Center"       => Some(Anchor.Center)
            case "RightCenter"  => Some(Anchor.RightCenter)
            case "BottomLeft"   => Some(Anchor.BottomLeft)
            case "BottomCenter" => Some(Anchor.BottomCenter)
            case "BottomRight"  => Some(Anchor.BottomRight)
            case "FullRect"     => Some(Anchor.FullRect)
            case _              => None
        }

    /// anchor preset と親 rect (+ 子の natural size + margin) から子の rect を計算する。
    ///   - `FullRect`: 親 rect 全面、margin で内側 inset (子 size は無視)
    ///   - その他 (位置系): 子 size を保持、anchor 位置に配置。margin はアンカー辺から
    ///     内側へのインセット (例: BottomRight なら右・下の端から margin だけ内側)。
    pub def applyAnchor(anchor: Anchor,
                          parentRect: Rect2.Rect2,
                          childSize: Vec2.Vec2,
                          margin: Float64): Rect2.Rect2 =
        match anchor {
            case Anchor.FullRect =>
                Rect2.grow(-margin, parentRect)
            case _ =>
                let pos = anchorPosition(anchor, parentRect, childSize, margin);
                ({position = pos, size = childSize}: Rect2.Rect2)
        }

    /// 位置系 anchor (FullRect 以外) で子の top-left position を計算する。
    /// 子の size を考慮して anchor 位置 (中央寄せ等) を決め、`margin` はアンカー辺から
    /// 内側へインセットする (左/上端は +margin、右/下端は -margin、中央軸は不変)。
    def anchorPosition(anchor: Anchor, parent: Rect2.Rect2, childSize: Vec2.Vec2,
                        margin: Float64): Vec2.Vec2 =
        let px = parent#position#x;
        let py = parent#position#y;
        let pw = parent#size#x;
        let ph = parent#size#y;
        let cw = childSize#x;
        let ch = childSize#y;
        let m  = margin;
        match anchor {
            case Anchor.TopLeft      => {x = px + m,                y = py + m}
            case Anchor.TopCenter    => {x = px + (pw - cw) / 2.0,  y = py + m}
            case Anchor.TopRight     => {x = px + pw - cw - m,      y = py + m}
            case Anchor.LeftCenter   => {x = px + m,                y = py + (ph - ch) / 2.0}
            case Anchor.Center       => {x = px + (pw - cw) / 2.0,  y = py + (ph - ch) / 2.0}
            case Anchor.RightCenter  => {x = px + pw - cw - m,      y = py + (ph - ch) / 2.0}
            case Anchor.BottomLeft   => {x = px + m,                y = py + ph - ch - m}
            case Anchor.BottomCenter => {x = px + (pw - cw) / 2.0,  y = py + ph - ch - m}
            case Anchor.BottomRight  => {x = px + pw - cw - m,      y = py + ph - ch - m}
            case Anchor.FullRect     => parent#position  // unreachable, handled above
        }
}
