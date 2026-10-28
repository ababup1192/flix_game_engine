// エントリーポイント。描く元（Doc とシナリオ = Res）とセーブデータ（saves/novel.json）は App を組む前に読み、その値から初期 World を作る
// （壊れていても既定値で必ず起動する）。App の組み立ては Game.app（flow の入口 E2e とテストも同じ物を使う）。
// ここで足すのは main だけが知る物（デバッグの印・セーブを書く出力・今の時刻）と、外の世界に触れる処理（effect）のハンドラ。

use fge::{App, GameEngine, LwjglLayer, Resources}

import java.lang.System
import java.util.TimeZone

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        run {
            let res = Controls.loadRes();
            Game.app(res, Saves.load(res#kind), localEpochSeconds())
                // セーブデータ・既読・設定を書く（saveRev が変わった実機のフレームの後でだけ。テスト・flow・描き出しは書かない）。
                |> App.addOutput(Resources.liftOutput({ keyOf = w -> if (w#saveRev == 0) "" else Int32.toString(w#saveRev),
                                                        write = w -> Saves.write(w#saves), onJump = App.OnJump.Skip }))
                |> App.withDebug(App.debugFromEnv())
                |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
    }

/// 今のその土地の時刻（1970-01-01 00:00 からの秒。セーブの日時の元。系は時計を読まないので起動の 1 回だけ読んで渡す）。
def localEpochSeconds(): Int64 \ IO =
    let ms = System.currentTimeMillis();
    let offset = TimeZone.getDefault().getOffset(ms);
    (ms + Int32.toInt64(offset)) / 1000i64
