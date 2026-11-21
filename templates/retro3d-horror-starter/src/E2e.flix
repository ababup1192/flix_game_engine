// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す。
//   make flow FLOW=e2e/walk.flow   画面なしで最後まで流す
mod E2e {
    use fge::{App, Flow, HeadlessLoad, InputMap, Resources}
    use fge::GameEngine.Key

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(Game.app(HeadlessLoad.handle(Controls.loadDocs)), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（bin/headless-run が jar を作った時に流す・make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(Game.app(HeadlessLoad.handle(Controls.loadDocs)), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    /// 役の名前 → キー（表の先頭のキーを押す。player.keys.json の既定と同じ）。
    def roles(): InputMap.Table[String] =
        (Key.W, "forward") :: (Key.S, "back") :: (Key.A, "strafeLeft") :: (Key.D, "strafeRight") ::
        (Key.Left, "turnLeft") :: (Key.Right, "turnRight") :: (Key.R, "lookUp") :: (Key.F, "lookDown") :: (Key.Space, "talk") :: (Key.I, "items") :: (Key.M, "map") :: (Key.Enter, "confirm") :: (Key.Escape, "cancel") :: Nil

    /// flow の表: 役と問い。
    pub def table(): Flow.Table[Resources.With[Res.Res, World.World]] =
        { roles = _ -> roles(),
          probes =
              { name = "x", doc = "足元の x（m）", read = Flow.Probe.Num(Resources.read((_, w) -> World.feetOf(w)#x)) } ::
              { name = "y", doc = "足元の高さ（m。階段で変わる）", read = Flow.Probe.Num(Resources.read((_, w) -> World.feetOf(w)#y)) } ::
              { name = "z", doc = "足元の z（m）", read = Flow.Probe.Num(Resources.read((_, w) -> World.feetOf(w)#z)) } ::
              { name = "floor", doc = "今の階の番号", read = Flow.Probe.Num(Resources.read((res, w) -> Int32.toFloat64(Layout.floorIndexAt(World.feetOf(w)#y, res#layout)))) } ::
              { name = "talk", doc = "話している人物の id（話していなければ -）", read = Flow.Probe.Text(Resources.read((_, w) -> World.talkOf(w) |> Option.map(t -> t#who) |> Option.getWithDefault("-"))) } ::
              { name = "screen", doc = "画面（Walk・Map・Talk・Pickup・Items）", read = Flow.Probe.Text(Resources.read((_, w) -> screenName(w))) } ::
              { name = "items", doc = "持ち物の id（拾った順・a,b の形。無ければ -）", read = Flow.Probe.Text(Resources.read((res, w) -> joined(World.inventoryIdsOf(res, w)))) } ::
              { name = "unlocked", doc = "開けた部屋の id（a,b の形。無ければ -）", read = Flow.Probe.Text(Resources.read((_, w) -> joined(World.unlockedOf(w) |> Map.keysOf |> Set.toList))) } ::
              { name = "notice", doc = "出している一言（出していなければ -）", read = Flow.Probe.Text(Resources.read((_, w) -> World.noticeOf(w) |> Option.map(n -> n#text) |> Option.getWithDefault("-"))) } ::
              { name = "quit", doc = "終了の確認（Playing・Asking・Confirmed）", read = Flow.Probe.Text(Resources.read((_, w) -> "${w#quit}")) } :: Nil
          | Flow.emptyTable() }

    def joined(names: List[String]): String = if (List.isEmpty(names)) "-" else List.join(",", names)

    /// 今の画面の名前。
    def screenName(w: World.World): String =
        if (World.isMapOpen(w)) "Map" else if (World.isTalking(w)) "Talk" else if (World.isPickingUp(w)) "Pickup" else if (World.isItemsOpen(w)) "Items" else "Walk"

    /// 1 行の要点（flow の失敗・遠隔の /state）: 指紋に、重さの表示を出していればその字を足す。
    pub def statusLine(res: Res.Res, w: World.World): String =
        let perf = w#perf |> Option.map(p -> " | " + List.join(" / ", PerfText.linesOf(p, None))) |> Option.getWithDefault("");
        fingerprint(res, w) + perf

    /// 指紋の元（記録の再生が比べる）: 進行に効く欄だけ（足元は cm に丸める）。拾った物と開けた戸は、ある時だけ足す。
    pub def fingerprint(_res: Res.Res, w: World.World): String =
        let cm = (v: Float64) -> Int32.toString(Float64.round(v * 100.0) |> Float64.tryToInt32 |> Option.getWithDefault(0));
        let p = World.feetOf(w);
        let taken = if (List.isEmpty(World.takenOf(w))) "" else "|taken=${List.join(",", World.takenOf(w))}";
        let unlocked = if (Map.isEmpty(World.unlockedOf(w))) "" else "|unlocked=${joined(World.unlockedOf(w) |> Map.keysOf |> Set.toList)}";
        "feet=${cm(p#x)},${cm(p#y)},${cm(p#z)}|quit=${w#quit}${taken}${unlocked}"
}
