// エントリーポイント。Doc は App を組む前に読み、その値から初期 World を作る
// （壊れていても defaults で必ず起動する）。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（デバッグの印）と、外の世界に触れる処理（effect）のハンドラ。
//
// 落下・移動・回転・接地/固定・ライン消去・涌き の規則そのものは World.flix にある。
// まず World 冒頭の「毎フレームの流れ」と「場面の移り変わりの図」を読むとよい。
use fge::{App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            Game.app(Controls.loadDocs())
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
