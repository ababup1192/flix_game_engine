// Viewport — 画面の矩形に対して、その外へ出た物を見つけて返す。
// 「画面外に出たか」を毎回自分で調べなくても、余白付きの範囲から外れた物の id をまとめて得られる。
// 利用例: 画面外へ飛んだ弾を片付ける / 見えなくなった敵を止める / 枠外の演出を打ち切る。
// 注意: 見つけて返すだけ。出た物をどうするか（消す等）はゲーム側の仕事。

pub mod Viewport {

    /// 軸平行の矩形領域。画面なら {0, 0, width, height}。
    pub type alias Bounds = { minX = Float64, minY = Float64, maxX = Float64, maxY = Float64 }

    /// 幅・高さから原点基準の bounds を作る。
    pub def bounds(width: Float64, height: Float64): Bounds =
        { minX = 0.0, minY = 0.0, maxX = width, maxY = height }

    /// 点が bounds の外（各辺から margin 以上はみ出している）か。
    pub def isOutside(p: Vec2.Vec2, b: Bounds, margin: Float64): Bool =
        p#x < (b#minX - margin) or p#x > (b#maxX + margin) or
        p#y < (b#minY - margin) or p#y > (b#maxY + margin)

    /// position を持つ entity のうち、bounds の外（margin 付き）に出ているものの id 一覧。
    pub def offscreenEntities(positions: Map[EntityId, Vec2.Vec2], b: Bounds, margin: Float64): List[EntityId] =
        Map.foldLeftWithKey((acc, id, p) -> if (isOutside(p, b, margin)) id :: acc else acc, Nil, positions)
}
