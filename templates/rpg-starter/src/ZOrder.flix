// ZOrder — 画面全体の重なりの層（奥から手前）。Unity の Sorting Layer と同じ考え方。
// world の層（Layer）はカメラで動く絵、HUD の層（HudLayer）は App.withHudView に繋ぐ動かない絵。
// 層の中の前後は ZStack に積んだ順で決まり、葉の中の z は 0..31。根で SortingLayer.compose に渡す（View）。
// タイル層（App.withTileLayers）は compose を通らないので、層の底の z（SortingLayer.bottom）をそのまま使う。
// 使い方の全文は engine の engine_world/src/SortingLayer.flix 冒頭と docs/z-bands.md。
mod ZOrder {

    use fge::SortingLayer

    /// world の層。
    pub enum Layer with Eq, ToString {
        case Ground  // 地面（タイル層の 0 段目）と、コマの回る地面（水と岸）。タイトルの背景
        case Shade   // 家が地面へ落とす影
        case Over    // 地面に重ねる物（タイル層の 1 段目・床に敷く小物）。タイトルの題字
        case Actors  // 人と小物（足元の y の順）
        case Dark    // 暗いマップの墨（明かりの外。人と物より手前）
        case Battle  // 戦いの画面: 背景の帯 → 敵 → 演出（積んだ順）
    }

    instance SortingLayer[Layer] {
        pub def zRange(layer: Layer): (Int32, Int32) =
            match layer {
                case Layer.Ground => (0, 9)
                case Layer.Shade  => (10, 19)
                case Layer.Over   => (20, 29)
                case Layer.Actors => (30, 289)
                case Layer.Dark   => (290, 299)
                case Layer.Battle => (300, 399)
            }
    }

    /// HUD の層。
    pub enum HudLayer with Eq, ToString {
        case Window  // 会話・選択肢・タイトルのメニュー
        case Transition   // 暗転
        case Prompt  // Esc の終了の確認（どれよりも手前）
    }

    instance SortingLayer[HudLayer] {
        pub def zRange(layer: HudLayer): (Int32, Int32) =
            match layer {
                case HudLayer.Window => (0, 49)
                case HudLayer.Transition  => (50, 59)
                case HudLayer.Prompt => (60, 99)
            }
    }
}
