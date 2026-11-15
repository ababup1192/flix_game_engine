// GameView — このゲームだけの絵（GameCommands が Stage の props に書いた game. の値を読んで描く）。
// world の層に入り、物ごとに「層の数」を付けて返す（ViewStage が背景・立ち絵・粒と同じ数で並べる。背景 0・背景に付く絵 100・
// 人物 500・小物 600 が既定）。同じ層の数なら立ち絵 → 粒 → GameView の順。物の中の z は 0..7（ViewStage が層ごとの z へ詰める）。
// カメラと揺れも掛かる。文字の枠は hud なので必ずその上。
// env には Doc（res）・並べ方の組（fit。縦横と大きさは Layout.width / height / isPortrait）・物語の時計の今（storyNow）・実時間（realNow）が入る。
// 舞台の値は物語の時計で読む（Stage.particlesOf(env#storyNow, stage) や PropertyTween.numAt(env#storyNow, …)）。
mod GameView {
    use fge::{Render}

    /// 今の舞台から描く物（層の数, 物）。
    pub def draw(_env: View.Env, _stage: Stage.Stage): List[(Int32, Render.PlacedItem)] = Nil
}
