// GameView — このゲームだけの絵（GameCommands が Stage の props に書いた game. の値を読んで描く）。
// world の層で、立ち絵と小物より手前・文字の枠より奥に入る。z は View.zGameView() から 4 つ（揺れも掛かる）。
// env には Doc（res）・並べ方の組（fit。縦横と大きさは Layout.width / height / isPortrait）・物語の時計の今（storyNow）・実時間（realNow）が入る。
// 舞台の値は物語の時計で読む（Stage.particlesOf(env#storyNow, stage) や PropertyTween.numAt(env#storyNow, …)）。
mod GameView {
    use fge::{Render}

    /// 今の舞台から描く物。
    pub def draw(_env: View.Env, _stage: Stage.Stage): List[Render.PlacedItem] = Nil
}
