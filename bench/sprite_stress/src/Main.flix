// エントリーポイント。Bench の世界を App に繋ぎ、4 区間を走り切ったら自動終了する。
// HUD=1 で HUD あり構成（withHudView = HUD の範囲持ち上げ + 範囲別ソート経路）の計測になる。

use fge::{App, GameEngine, LwjglLayer}

def main(): Unit \ IO =
    if (GameEngine.ensureMainThread()) ()
    else {
        let withHud = Bench.hudEnabled();
        run {
            let app = App.make(Bench.initialWorld())
                |> App.addSystem(Bench.step)
                |> App.withView((ctx, w) -> checked_ecast(Bench.view(ctx, w)))
                |> App.quitWhen((_frame, w) -> checked_ecast(w#done));
            if (withHud)
                app |> App.withHudView((ctx, w) -> checked_ecast(Bench.hud(ctx, w)))
                    |> App.launch
            else
                app |> App.launch
        } with LwjglLayer.withProject(".")
          with Fs.FileRead.runWithIO
          with Fs.FileWrite.runWithIO
          with Fs.Glob.runWithIO
          with Fs.ModificationTime.runWithFileTime
          with Fs.FileTime.runWithIO
    }
