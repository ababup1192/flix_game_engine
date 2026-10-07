// Color 型は engine/src/core/Color.flix にある。Visual はその `Color` を構造的に使う。

/// 描画物の色変調・可視性・重なり順をまとめた共有パーツ。各描画型がこれを埋め込むので、
/// 型ごとに同じフィールドを書かずに済む。
/// 利用例: 描画物を一時的に非表示にする / 前面へ出す / 色を掛ける。
///
/// color … 色変調（{r, g, b} の乗算）
/// visible  … 表示フラグ
/// zIndex   … 重なり順（大きいほど手前）
pub type alias Visual = {
    color = Color,
    visible = Bool,
    zIndex = Int32
}

pub mod Visual {

    /// 既定の見た目（白で色変調なし・表示・重なり順 0）。
    pub def default(): Visual =
        { color = {r = 1.0, g = 1.0, b = 1.0}, visible = true, zIndex = 0 }

    /// 色変調を取得する
    pub def getColor(v: Visual): Color = v#color

    /// 色変調を設定する
    pub def setColor(color: Color, v: Visual): Visual =
        { color = color | v }

    /// 可視性を取得する
    pub def getVisible(v: Visual): Bool = v#visible

    /// 可視性を設定する
    pub def setVisible(visible: Bool, v: Visual): Visual =
        { visible = visible | v }

    /// 重なり順を取得する
    pub def getZIndex(v: Visual): Int32 = v#zIndex

    /// 重なり順を設定する
    pub def setZIndex(zIndex: Int32, v: Visual): Visual =
        { zIndex = zIndex | v }
}
