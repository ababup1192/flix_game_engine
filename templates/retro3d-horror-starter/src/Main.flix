// エントリーポイント。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（終了の確認・注釈・F3 の重さの行・デバッグの印・開発の道具の /render）。
// 外の世界に触れる処理（effect）は隠さず with で並べる。

use fge::{App, LwjglLayer, Resources}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else {
        run {
            // Doc と校舎の glb を読んで App を組む所ごと渡す（読む間は起動画面が進む）。
            App.loadAndLaunch(() -> Game.app(Controls.loadDocs())
                // 窓の閉じるボタンも Esc と同じ確認へ回し、はいを選んだら終わる（quitWhen を差し替えると
                // 既定の「Esc ですぐ終了」は外れる。Esc は Controls.step が確認へ回す）。
                |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.askQuit(w)))
                |> App.quitWhen((_, h) -> Resources.read((_, w) -> World.isQuitting(w), h))
                // F8 で書き出す注釈チケットに、その瞬間の文脈と HUD の層の名前を添える（層の表は ZOrder）。
                |> App.withAnnotationContext(Resources.read((res, w) ->
                    { facts = ("状態", E2e.fingerprint(res, w)) :: Nil,
                      layers = (Nil: List[ZOrder.Layer]), hudLayers = ZOrder.layers() }))
                // F3 の重さの行（GPU と CPU の 1 コマの時間・3D の描いた数）を測る。
                |> App.withDiagnostics
                |> App.withDebug(App.debugFromEnv())
                // WhyNot: Game.app で繋がない — Game.app はテスト・flow と共有するので、開発の道具（POST /render）を持たせない。
                |> App.onRenderRequest(SceneRender.allShots))
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
