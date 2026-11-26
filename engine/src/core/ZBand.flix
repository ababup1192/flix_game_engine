// ZBand — 重なり順（zIndex）を用途ごとの範囲に区切る取り決めの source of truth。
// world の絵がどれだけ大きい z を使っても HUD より手前には出ない、を数で保証する。
// 利用例: composeScene が hud の z を HUD の範囲へ持ち上げる / 描画部が範囲ごとに並べ替える。
// 範囲の地図（どの範囲が何用か）は docs/z-bands.md にある。
pub mod ZBand {

    /// 範囲 1 本の幅。範囲の中で使える z は 0..innerMax（幅 - 1）まで。
    pub def width(): Int32 = 100_000_000

    /// 範囲の中で使える z の上限。はみ出した z は clamp する（wrap しない —
    /// 折り返すと「大きい z ほど手前」の決まりが範囲の境目で裏返るため）。
    pub def innerMax(): Int32 = 99_999_999

    /// HUD の範囲の底。withHudView の絵は composeScene がここへ持ち上げる。
    pub def hudBase(): Int32 = 1_000_000_000

    /// 読み込み中の表示の範囲の底（ブラウザ版で App が届いていない物を待つ間の輪と、押した点からの波紋）。
    /// HUD の範囲より手前・エンジンデバッグの範囲より奥 — 待ちの表示はゲームのどの絵にも隠されず、F8 の注釈は隠さない。
    pub def loadingBase(): Int32 = 1_900_000_000

    /// staticGroup を先に作る間の黒（App.withAutoPreload3d の Cover）の z。HUD の範囲より手前・待ちの表示より奥。
    // WhyNot: loadingBase ちょうどにしない — 波紋が同じ z で、同じ z の中は種類の順で描くので、積む順で奥へ置けない。
    pub def autoPreloadCover(): Int32 = loadingBase() - 1

    /// エンジンデバッグの範囲の底（fps・矩形注釈・トースト・スクラブ表示）。
    /// HUD の範囲よりさらに手前 — デバッグ中の表示はゲームのどの絵にも隠されない。
    /// Int32 の上限 2_147_483_647 に収まる（この範囲の中は 0..10 しか使わない）。
    pub def debugBase(): Int32 = 2_000_000_000

    /// hud の z を HUD の範囲へ持ち上げる（範囲内は 0..innerMax に clamp）。
    pub def liftHud(z: Int32): Int32 =
        hudBase() + Int32.max(0, Int32.min(innerMax(), z))
}
