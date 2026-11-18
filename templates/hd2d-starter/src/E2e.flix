// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す。
//   make flow FLOW=e2e/walk.flow   画面なしで最後まで流す
mod E2e {
    use fge::{App, Flow, InputMap, Resources}
    use fge::GameEngine.Key

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(Game.app(loadRes()), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（bin/headless-run が jar を作った時に流す・make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(Game.app(loadRes()), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    /// 画面なしの描く元（窓を開かないので絵は javax.imageio で読む）。
    def loadRes(): Res.Res \ IO =
        run { Res.loadOrBug(Images.readImageIo, TownScene.TextureNames.SceneTextures, Map.empty(), Res.loadDocsOrBug()) } with Fs.FileRead.runWithIO

    /// 役の名前 → キー（表の先頭のキーを押す。explore.keys.json の既定と同じ）。
    def roles(): InputMap.Table[String] =
        (Key.Left, "left") :: (Key.Right, "right") :: (Key.Up, "up") :: (Key.Down, "down") ::
        (Key.Enter, "confirm") :: (Key.Escape, "cancel") :: Nil

    /// 先頭の立つマスの列か行（Walk の外では -1）。
    def leaderCoord(pick: ((Int32, Int32)) -> Int32, res: Res.Res, w: World.World): Float64 =
        World.leaderCell(res, w) |> Option.map(cr -> Int32.toFloat64(pick(cr))) |> Option.getWithDefault(-1.0)

    /// flow の表: 役と問い。
    pub def table(): Flow.Table[Resources.With[Res.Res, World.World]] =
        { roles = _ -> roles(),
          probes =
              { name = "col", doc = "先頭の立つマスの列（Walk の外では -1）", read = Flow.Probe.Num(Resources.read((r, w) -> leaderCoord(fst, r, w))) } ::
              { name = "row", doc = "先頭の立つマスの行（0 が一番北・Walk の外では -1）", read = Flow.Probe.Num(Resources.read((r, w) -> leaderCoord(snd, r, w))) } ::
              { name = "quit", doc = "終了の確認（Walking・Asking・Confirmed）", read = Flow.Probe.Text(Resources.read((_, w) -> "${w#quit}")) } :: Nil
          | Flow.emptyTable() }

    /// 指紋の元（記録の再生が比べる）: 進行に効く欄だけ。
    pub def fingerprint(res: Res.Res, w: World.World): String =
        let at = World.leaderCell(res, w) |> Option.map(cr -> "${fst(cr)},${snd(cr)}") |> Option.getWithDefault("-");
        "leader=${at}|quit=${w#quit}"
}
