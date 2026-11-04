/// CanvasLayer — HUD やオーバーレイを本体より手前に重ねるための描画レイヤー番号の基準。
/// レイヤー番号 × layerStride を zIndex に加算することで、レイヤーごとの前後関係を作る。
/// 利用例: 画面固定 HUD をレイヤー 6 に置き、in-world 配置物より確実に前面へ出す。
pub mod CanvasLayer {

    /// レイヤー間の z-index ストライド。
    /// 各レイヤーの描画物の z-index に layer * layerStride を加算する（大きいほど前面）。
    pub def layerStride(): Int32 = 10000
}
