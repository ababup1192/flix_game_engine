// GameView — このゲームだけの絵（GameCommands が Stage の props に書いた game. の値を読んで描く）。
// world の層で、立ち絵と小物より手前・文字の枠より奥に入る。z は View.zGameView() から 4 つ（揺れも掛かる）。
mod GameView {
    use fge::{Clock, Render}

    /// now の舞台から描く物。
    pub def draw(_res: Res.Res, _now: Clock.Time[Stage.Story], _stage: Stage.Stage): List[Render.PlacedItem] = Nil
}
