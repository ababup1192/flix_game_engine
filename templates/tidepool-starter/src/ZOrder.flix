// ZOrder — 画面全体の重なりの層（奥から手前）。Unity の Sorting Layer と同じ考え方。
// 新しい層（ポーズ・確認の窓）は case を足し、zRange に範囲を書く（書き忘れは match の網羅で止まる）。
// 層の中の前後は ZStack に積んだ順で決まり、葉の中の z は 0..31。根で SortingLayer.compose に渡す（View.frame）。
// 使い方の全文は engine の engine_world/src/SortingLayer.flix 冒頭と docs/z-bands.md。
mod ZOrder {

    use fge::SortingLayer

    pub enum Layer with Eq, ToString {
        case Scene   // 場面の絵（背景・主人公・塵）
        case Hud     // 右の板（潮見表・手数）と題名の画面の文字
        case Frame   // 画面の縁の枠（App.withStaticLayer で 1 度だけ作る静的な絵。compose を通らないので z は bottom で引く）
        case Prompt  // 終了の確認の窓（場面と枠のどれよりも手前）
    }

    instance SortingLayer[Layer] {
        pub def zRange(layer: Layer): (Int32, Int32) =
            match layer {
                case Layer.Scene  => (0, 179)
                case Layer.Hud    => (180, 199)
                case Layer.Frame  => (200, 209)
                case Layer.Prompt => (300, 309)
            }
    }

    /// 奥から手前へ全部の層（F8 の注釈の文脈・表のテストが使う）。
    pub def layers(): List[Layer] = Layer.Scene :: Layer.Hud :: Layer.Frame :: Layer.Prompt :: Nil
}
