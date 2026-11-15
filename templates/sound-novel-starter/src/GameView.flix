// GameView — このゲームだけの絵（GameCommands が Stage の props に書いた game. の値を読んで描く）。
// env には Doc（res。ゲームの描く元は res#game）・並べ方の組（fit。縦横と大きさは Layout.width / height / isPortrait）・
// 物語の時計の今（storyNow）・実時間（realNow）が入る。
// 舞台の値は物語の時計で読む（Stage.particlesOf(env#storyNow, stage) や PropertyTween.numAt(env#storyNow, …)）。
//
//   draw     world の層。物ごとに「層の数」を付けて返す（ViewStage が背景・立ち絵・粒と同じ数で並べる。背景 0・背景に付く絵 100・
//            人物 500・小物 600 が既定）。同じ層の数なら立ち絵 → 粒 → GameView の順。物の中の z は 0..7。カメラと揺れも掛かる。
//   backdrop 背景の層（層の数 0）に、背景の名前 photo の絵を描く（3D の部屋など）。None ならテンプレートが写真（still）を描く。
//            area はその写真を敷く矩形（画面より揺れの分だけ大きい。aspect を書いた写真は still を真ん中で切り抜く矩形で、画面よりずっと大きいことがある。
//            サムネでは画面ちょうど）。物の中の z は 0..2。テンプレートの切り替えの間は、濃さと横のずれを掛けて重ねる
//            （濃さは Sprite・Box・Poly・Text・Shader にだけ効き、Scene3d には効かない。3D の背景へ fade・pan で入ると 3D はぱっと出る）。
//   hud      hud に描く物を、帯（View.HudBand）を付けて返す。UnderWindow = 文字の枠の覆いより奥（画面に掛かる血など）・
//            OverWindow = 本文の上・選択肢の下（状態バー・コメント欄など）。Yarn の変数は YarnRunner.valueOf(名, read#talk)。
//            <<window off>> でも消えず、セーブの枠のサムネにも出る。物の中の z は 0..8。
//   objects  tape.json の画面の物（テープの頁の「物を選ぶ」）に足す矩形。
mod GameView {
    use fge::{Rect2, Render}

    /// 今の舞台から描く物（層の数, 物）。
    pub def draw(_env: View.Env, _stage: Stage.Stage): List[(Int32, Render.PlacedItem)] = Nil

    /// 背景 photo の絵（描かない・描けない・素材がまだ届いていない時は None）。
    pub def backdrop(_env: View.Env, _stage: Stage.Stage, _photo: String, _area: Rect2.Rect2): Option[List[Render.PlacedItem]] = None

    /// 読んでいる間の hud の物。
    pub def hud(_env: View.Env, _read: World.Read): List[(View.HudBand, Render.PlacedItem)] = Nil

    /// 読んでいる間の画面の物（id・人に見せる名前・矩形）。
    pub def objects(_env: View.Env, _read: World.Read): List[{ id = String, name = String, rect = Rect2.Rect2 }] = Nil
}
