// UiScroll — 「ビューポートより長い内容を、位置をひとつ持って覗く」の共通の勘定(純粋)。
// 単位は呼び側が決める(行・項目・ピクセル)。offset は「末尾から何単位遡ったか」で、
// 0 = 末尾に張り付き。会話ログ・チャット・履歴のような「新しいものが下へ増える」UI の
// 既定に合わせる — 先頭基準で使いたい呼び側は top を読めばよい。
// 端に着いたときの振る舞い(閉じる・音を鳴らす等)はここでは決めない — 端で値が
// 止まるだけにして、暗黙のモード遷移で誤操作を作らないのは呼び側の規約。

pub mod UiScroll {

    /// 遡れる上限。内容がビューポートに収まるなら 0。
    pub def maxOffset(size: {content = Int32, viewport = Int32}): Int32 =
        Int32.max(0, size#content - size#viewport)

    /// delta ぶん遡る(正 = 過去へ、負 = 末尾へ)。両端で止まる。
    pub def scrollBy(delta: Int32, size: {content = Int32, viewport = Int32}, offset: Int32): Int32 =
        Int32.max(0, Int32.min(maxOffset(size), offset + delta))

    /// いま見えている範囲の先頭(内容先頭からの位置)。List.drop にそのまま渡せる。
    pub def top(size: {content = Int32, viewport = Int32}, offset: Int32): Int32 =
        Int32.max(0, size#content - size#viewport - offset)

    /// 画面の上にまだ内容があるか(「▲」のような印の出し分けに)。
    pub def moreAbove(size: {content = Int32, viewport = Int32}, offset: Int32): Bool =
        top(size, offset) > 0

    /// 画面の下にまだ内容があるか(「▼」)。内容が縮んで古い offset が上限を超えていても
    /// 嘘の ▼ を出さないよう、moreAbove と同じくここで clamp して判定する。
    pub def moreBelow(size: {content = Int32, viewport = Int32}, offset: Int32): Bool =
        Int32.min(offset, maxOffset(size)) > 0

    // ========================================================================
    // ピクセル版。上の行(項目)単位と同じ勘定を Float64 で行う — トラックパッドの
    // 端数をそのまま位置に流す「なめらかスクロール」用。単位が違うだけなので、
    // 行単位で使いたい操作(キーの ↑↓ など)は stepRow で行の格子に揃えられる。
    // ========================================================================

    pub def maxOffsetPx(size: {contentPx = Float64, viewportPx = Float64}): Float64 =
        Float64.max(0.0, size#contentPx - size#viewportPx)

    /// delta ピクセルぶん遡る(正 = 過去へ)。両端で止まる。NaN は 0 扱い(位置を汚染しない)。
    pub def scrollByPx(delta: Float64, size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Float64 =
        let d = if (Float64.isNan(delta)) 0.0 else delta;
        Float64.max(0.0, Float64.min(maxOffsetPx(size), offsetPx + d))

    /// いま見えている範囲の先頭(内容先頭からのピクセル位置)。
    pub def topPx(size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Float64 =
        Float64.max(0.0, size#contentPx - size#viewportPx - offsetPx)

    pub def moreAbovePx(size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Bool =
        topPx(size, offsetPx) > 0.0

    pub def moreBelowPx(size: {contentPx = Float64, viewportPx = Float64}, offsetPx: Float64): Bool =
        Float64.min(offsetPx, maxOffsetPx(size)) > 0.0

    /// 行の高さが一定のリストをピクセル位置で覗くときの描画計画:
    /// first = 最初に描く行(先頭から数えて)、shift = その行を上へずらす量(0 ≦ shift < rowH)、
    /// count = 部分行を含めて描く行数。呼び側は first から count 行を y - shift から並べる
    /// (ビューポートの外へはみ出す端は、クリップか覆いで隠す)。
    pub def visibleRows(rowH: Float64, size: {contentPx = Float64, viewportPx = Float64},
                        offsetPx: Float64): { first = Int32, shift = Float64, count = Int32 } =
        if (rowH <= 0.0)
            { first = 0, shift = 0.0, count = 0 }
        else {
            let top = topPx(size, offsetPx);
            let first = toInt(Float64.floor(top / rowH));
            let shift = top - Int32.toFloat64(first) * rowH;
            let count = toInt(Float64.ceil((size#viewportPx + shift) / rowH));
            { first = first, shift = shift, count = count }
        }

    /// 行の格子に揃えて delta 行ぶん動かす(正 = 過去へ)。ピクセル位置が行の途中でも、
    /// 次の境界へ「1 行」で届く — なめらかスクロールとキーの行単位操作を同居させる芯。
    pub def stepRow(rowH: Float64, delta: Int32, size: {contentPx = Float64, viewportPx = Float64},
                    offsetPx: Float64): Float64 =
        if (rowH <= 0.0) offsetPx
        else {
            // 遡る(正)なら床、戻る(負)なら天井から数える — 途中位置はまず手前の境界に吸われる。
            let baseRow = if (delta >= 0) Float64.floor(offsetPx / rowH) else Float64.ceil(offsetPx / rowH);
            let target = (baseRow + Int32.toFloat64(delta)) * rowH;
            Float64.max(0.0, Float64.min(maxOffsetPx(size), target))
        }

    /// Float64 → Int32(切り捨て済みの値を想定。範囲外は 0 — visibleRows の入力規模では起きない)。
    def toInt(x: Float64): Int32 =
        Float64.tryToInt32(x) |> Option.getWithDefault(0)
}
