// エントリーポイント。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（GPU のアトラス・静的な枠・終了の確認・注釈・デバッグの印・開発の道具の /render）。
// 外の世界に触れる処理（effect）は隠さず with で並べる。
// 複数システムの明示的な列挙が要る高度なゲームは、make から始める従来のビルダー（addSystem / withView / …）へ降りる。

use fge::{App, LwjglLayer, Resources}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else {
        run {
            // Doc を読んで App を組む所ごと渡す（flow を記録する make debug の起動でも、ここで読んだ中身を使い Doc を読み直さない）。
            App.loadAndLaunch(() -> {
                Game.app(Controls.loadDocs())
                    // ドット絵を作った 1 枚を GPU へ上げる（View はこの名前で 1 コマ 1 クアッドを貼る）。
                    // 鍵が同じ間は上げ直さないので、毎フレームの費用はゼロ。
                    |> App.withSpriteAtlases(Resources.read((res, _) ->
                        { texture = Res.atlasName(), key = res#atlasKey, baked = res#atlas } :: Nil))
                    // 動かない絵（画面の縁の枠）は 1 度だけ GPU に作り、鍵が変わるまで使い回す。
                    |> App.withStaticLayer(Resources.read((res, _) -> View.staticKey(res#theme)),
                                           Resources.read((res, _) -> View.frameBorder(res#theme)))
                    // 窓の閉じるボタンも Esc と同じ確認へ回し、はいを選んだら終わる（quitWhen を差し替えると
                    // 既定の「Esc ですぐ終了」は外れる。Esc は Controls.step が確認へ回す）。
                    |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.askQuit(w)))
                    |> App.quitWhen((_, h) -> Resources.read((_, w) -> World.isQuitting(w), h))
                    // F8 で書き出す注釈チケットに、その瞬間の文脈と z の層の名前を添える（層の表は ZOrder）。
                    |> App.withAnnotationContext(Resources.read((res, w) ->
                        { facts = ("状態", E2e.fingerprint(res, w)) :: Nil,
                          // HUD（App.withHudView）を足したら、HUD の層の enum を ZOrder に作ってその列を渡す。
                          layers = ZOrder.layers(), hudLayers = (Nil: List[ZOrder.Layer]) }))
                    |> App.withDebug(App.debugFromEnv())
                    // WhyNot: Game.app で繋がない — Game.app はテスト・flow・ブラウザ版と共有するので、開発の道具（POST /render）を持たせない。
                    |> App.onRenderRequest(SceneRender.allShots)
            })
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
