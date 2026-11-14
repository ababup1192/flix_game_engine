// ブラウザ版の入口（bin/fge export-web だけが組む）。
// URL の query に scene があれば測る（?scene=room か ?scene=field&n=12000&shapes=16&mats=16&moving=100&alpha=10&shadow=1。結果は頁の上に残す）。
// 無ければ部屋を描き続けるだけ（?capture=<n> で絵を撮る道）。
// WhyNot: 撮る道でも測らない — 診断を付けると撮る絵の道が実機の既定と変わる。
mod WebMain {
    use fge::{App, Platform, WebFs, WebLayer}

    import fge.web.Browser

    def loadScene(knobs: Map[String, String]): Result[String, SceneBench.Scene] \ Fs.FileRead =
        if (SceneBench.isField(knobs)) Ok(SceneBench.Scene.Field(Field.kitOf(Field.configOf(knobs))))
        else Room.loadMeshes() |> Result.map(meshes -> SceneBench.Scene.Room(Room.kitOf(meshes)))

    def measure(knobs: Map[String, String]): Unit \ (IO + Fs.FileRead + Fs.FileWrite + Platform.Services) =
        match loadScene(knobs) {
            case Err(why)  => println("[scene3d] 家具を読めない: ${why}")
            case Ok(scene) =>
                SceneBench.app(SceneBench.planOf(knobs), line -> Browser.log(line), scene)
                    |> App.quitWhen((_frame, _w) -> checked_ecast(false))
                    |> App.launchForBench
        }

    def show(): Unit \ (IO + Fs.FileRead + Fs.FileWrite + Platform.Services) =
        match Room.loadMeshes() {
            case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
            case Ok(meshes) =>
                let kit = Room.kitOf(meshes);
                App.make(0.0)
                    |> App.addSystem((frame, t) -> t + frame#dt)
                    |> App.withView((_ctx, t) -> Room.items(kit, SceneBench.yawAt(t)))
                    |> App.launchWithDevTools(App.DevTools.none())
        }

    pub def main(): Unit \ IO =
        let knobs = BenchRun.knobsOfPairs(Array.toList(Browser.queryPairs()));
        run {
            if (Map.memberOf("scene", knobs)) measure(knobs) else show()
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
