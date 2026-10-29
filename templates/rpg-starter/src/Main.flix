// エントリーポイント。Doc とセーブ（saves/rune.json）は App を組む前に読み、その値から描く元（Res）と初めの World を作る
// （壊れていても既定で必ず起動する）。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（アトラス・セーブを書く出力・デバッグの印）。
//
// 規則は World.flix の冒頭の図から読むとよい（場面の移り・時計・出来事）。
use fge::{App, GameEngine, LwjglLayer, Resources}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let docs = Res.loadDocs();
            Game.app(docs, Saves.load(docs#items, docs#maps))
                // セーブを書く（宿で saveRev が進んだ実機のフレームの後でだけ。テスト・flow・描き出しは書かない）。
                |> App.addOutput(Resources.liftOutput({ keyOf = w -> if (w#saveRev == 0) "" else Int32.toString(w#saveRev),
                                                        write = w -> w#save |> Option.forEach(Saves.write), onJump = App.OnJump.Skip }))
                // ドット絵のファイルごとのアトラスを GPU へ上げる（鍵が同じ間は上げ直さない）。
                |> App.withSpriteAtlases(Resources.read((res, _) -> Res.atlases(res)))
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }
