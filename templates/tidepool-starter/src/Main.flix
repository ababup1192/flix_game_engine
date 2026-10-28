// エントリーポイント。Doc は App を組む前に読み、その値から描く元（Res）を作る
// （壊れていても defaults で必ず起動する）。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（GPU のアトラス・静的な枠・終了の確認・注釈・デバッグの印）。
//
// 1 手の規則（動く・押す・水の広がり・流された・クリア）は World.flix と Tide.flix。まず World 冒頭の図を読むとよい。
use fge::{App, GameEngine, LwjglLayer, Resources}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            Game.app(Controls.loadDocs())
                // ドット絵を作った 1 枚を GPU へ上げる（鍵が同じ間は上げ直さない）。
                |> App.withSpriteAtlases(Resources.read((res, _) ->
                    { texture = Res.atlasName(), key = res#atlasKey, baked = res#atlas } :: Nil))
                // 動かない絵（画面の縁の枠）は 1 度だけ GPU に作り、鍵が変わるまで使い回す。
                |> App.withStaticLayer(Resources.read((res, _) -> View.staticKey(res#theme)),
                                       Resources.read((res, _) -> View.frameBorder(res#theme)))
                // 窓の閉じるボタンも Esc と同じ確認へ回す（quitWhen を差し替えると既定の「Esc ですぐ終了」は外れる）。
                |> App.withCloseRequest(Resources.mapWorld((_, w) -> World.askQuit(w)))
                |> App.quitWhen((_, h) -> Resources.read((_, w) -> World.isQuitting(w), h))
                // F8 で書き出す注釈チケットに、その瞬間の文脈と z の層の名前を添える（層の表は ZOrder）。
                |> App.withAnnotationContext(Resources.read((res, w) ->
                    { facts = ("面", "${World.levelOf(w)}") :: ("状態", E2e.fingerprint(res, w)) :: ("終了の確認", "${w#quit}") :: Nil,
                      layers = ZOrder.layers(), hudLayers = (Nil: List[ZOrder.Layer]) }))
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
