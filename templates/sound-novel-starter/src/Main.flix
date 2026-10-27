// エントリーポイント。Doc と栞（saves/novel.json）は App を組む前に読み、その値から初期 World を作る
// （壊れていても既定値で必ず起動する）。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（デバッグの印・栞を書く出力）と、外の世界に触れる処理（effect）のハンドラ。

use fge::{App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let docs = Controls.loadDocs();
            Game.app(docs, Saves.load(docs#kind))
                // 栞・既読・設定を書く（saveRev が変わった実機のフレームの後でだけ。テスト・flow・描き出しは書かない）。
                |> App.addOutput({ keyOf = w -> if (w#saveRev == 0) "" else Int32.toString(w#saveRev),
                                   write = w -> Saves.write(w#saves), onJump = App.OnJump.Skip })
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
