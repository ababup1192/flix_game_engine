// ブラウザ版の入口（bin/fge export-web だけが組む）。
// WhyNot: SceneBench.step を使わない — 垂直同期を切る GLFW の呼び出しがあり、ブラウザの組み立てが LWJGL へ届く。
mod WebMain {
    use fge::{App, WebFs, WebLayer}

    pub def main(): Unit \ IO =
        run {
            match Room.loadMeshes() {
                case Err(why)   => println("[scene3d] 家具を読めない: ${why}")
                case Ok(meshes) =>
                    let kit = Room.kitOf(meshes);
                    App.make(0.0)
                        |> App.addSystem((frame, t) -> t + frame#dt)
                        |> App.withView((_ctx, t) -> Room.items(kit, SceneBench.yawAt(t)))
                        |> App.launchWithDevTools(App.DevTools.none())
            }
        } with WebLayer.withProject3d(".")
          with WebFs.runFileRead
          with WebFs.runFileWrite
}
