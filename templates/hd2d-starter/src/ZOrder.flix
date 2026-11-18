// ZOrder — HUD の重なりの層（奥から手前）。Unity の Sorting Layer と同じ考え方。
// 3D の場面は View.frame の 1 枚（奥行きで重なる）なので、層に分けるのは HUD だけ。
// 新しい層（ポーズ・会話の窓）は case を足し、zRange に範囲を書く（書き忘れは match の網羅で止まる）。
// 層の中の前後は ZStack に積んだ順で決まり、葉の中の z は 0..31。根で SortingLayer.compose に渡す（View.hud）。
// 使い方の全文は engine の engine_world/src/SortingLayer.flix 冒頭と docs/z-bands.md。
mod ZOrder {

    use fge::SortingLayer

    pub enum Layer with Eq, ToString {
        case Prompt  // 終了の確認の窓
    }

    instance SortingLayer[Layer] {
        pub def zRange(layer: Layer): (Int32, Int32) =
            match layer {
                case Layer.Prompt => (300, 309)
            }
    }

    /// 奥から手前へ全部の層（F8 の注釈の文脈が使う）。
    pub def layers(): List[Layer] = Layer.Prompt :: Nil
}
