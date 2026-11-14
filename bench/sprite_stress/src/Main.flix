// エントリーポイント。Bench の世界を App に繋ぎ、区間を走り切ったら自動終了する。つまみは環境変数（Makefile の頭）。

use fge::{App, LwjglLayer}

def main(): Unit \ IO =
    if (LwjglLayer.ensureMainThread()) ()
    else {
        let config = Bench.configOf(BenchEnv.knobs(
            ("COUNTS", "n") :: ("TEX", "tex") :: ("BLEND", "blend") :: ("FRAMES", "frames") :: ("HUD", "hud") :: ("DIAG", "diag") :: Nil));
        run {
            Bench.app(BenchEnv.emit, config)
                |> App.quitWhen((_frame, w) -> checked_ecast(w#progress#done))
                |> App.launchForBench
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
    }
