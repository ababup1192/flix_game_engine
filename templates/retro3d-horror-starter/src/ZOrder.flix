// ZOrder — HUD（App.withHudView）の重なりの層（奥から手前）。Unity の Sorting Layer と同じ考え方。
// 3D の場面は App の view（View.frame）が 1 枚で描き、HUD はその上に必ず出る。
// 新しい層は case を足し、zRange に範囲を書く（書き忘れは match の網羅で止まる）。使い方の全文は engine の docs/z-bands.md。
mod ZOrder {

    use fge::SortingLayer

    pub enum Layer with Eq, ToString {
        case Caption  // 画面の下の部屋の名前
        case Dialogue // 人物との会話の窓
        case Map      // 古びた紙のマップ（開いている間）
        case Hint     // しばらく操作しないと隅に出る操作方法
        case Items    // アイテム画面の一覧と説明文
        case Prompt   // 終了の確認の窓（どれよりも手前）
    }

    instance SortingLayer[Layer] {
        pub def zRange(layer: Layer): (Int32, Int32) =
            match layer {
                case Layer.Caption => (0, 49)
                case Layer.Dialogue => (50, 99)
                case Layer.Map     => (100, 199)
                case Layer.Hint    => (200, 249)
                case Layer.Items   => (250, 299)
                case Layer.Prompt  => (300, 309)
            }
    }

    /// 奥から手前へ全部の層（F8 の注釈の文脈・表のテストが使う）。
    pub def layers(): List[Layer] = Layer.Caption :: Layer.Dialogue :: Layer.Map :: Layer.Hint :: Layer.Items :: Layer.Prompt :: Nil
}
