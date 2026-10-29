// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す。
//   make flow FLOW=e2e/walk.flow   画面なしで最後まで流す
mod E2e {
    use fge::{App, Flow, InputMap, Resources, Vec2}
    use fge::GameEngine.Key

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(Game.app(Controls.loadDocs()), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（bin/headless-run が jar を作った時に流す・make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(Game.app(Controls.loadDocs()), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    /// 役の名前 → キー（表の先頭のキーを押す。player.keys.json の既定と同じ）。
    def roles(): InputMap.Table[String] =
        (Key.Left, "left") :: (Key.Right, "right") :: (Key.Up, "up") :: (Key.Down, "down") ::
        (Key.Enter, "confirm") :: (Key.Escape, "cancel") :: Nil

    /// 主人公の中心（出ていない画面では -1）。
    def heroCoord(pick: Vec2.Vec2 -> Float64, w: World.World): Float64 =
        World.heroAt(w) |> Option.map(pick) |> Option.getWithDefault(-1.0)

    /// flow の表: 役と問い。
    pub def table(): Flow.Table[Resources.With[Res.Res, World.World]] =
        { roles = _ -> roles(),
          probes =
              { name = "x", doc = "主人公の中心の x（出ていない画面では -1）", read = Flow.Probe.Num(Resources.read((_, w) -> heroCoord(p -> p#x, w))) } ::
              { name = "y", doc = "主人公の中心の y（出ていない画面では -1）", read = Flow.Probe.Num(Resources.read((_, w) -> heroCoord(p -> p#y, w))) } ::
              { name = "quit", doc = "終了の確認（Playing・Asking・Confirmed）", read = Flow.Probe.Text(Resources.read((_, w) -> "${w#quit}")) } :: Nil
          | Flow.emptyTable() }

    /// 指紋の元（記録の再生が比べる）: 進行に効く欄だけ。
    pub def fingerprint(_res: Res.Res, w: World.World): String =
        let at = World.heroAt(w) |> Option.map(p -> "${p#x},${p#y}") |> Option.getWithDefault("-");
        "hero=${at}|quit=${w#quit}"
}
