// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す
// （bin/fge flow check が JVM なしで読み、書き間違いを行番号と近い名前の案つきで止める）。
//   make flow FLOW=e2e/clear_four.flow   画面なしで最後まで流す（描き出しの jar を使うので Flix を組み直さない）
mod E2e {
    use fge::{App, Flow, InputMap}
    use fge::GameEngine.Key

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    /// E2e.play の中身（常駐の /run からも呼ぶ）。env は要求の表（App.Headless.envOf）だけを読む。戻り値は終了コード。
    pub def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(Game.app(Controls.loadDocs()), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（bin/headless-run が jar を作った時に流す・make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    /// E2e.vocab の中身（常駐の /run からも呼ぶ）。
    pub def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(Game.app(Controls.loadDocs()), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    /// 役の名前 → キー（表の先頭のキーを押す。drop は ↑、confirm は Enter —— Space は遊び中なら叩きつけになる）。
    def roles(): InputMap.Table[String] =
        (Key.Left, "left") :: (Key.Right, "right") :: (Key.Z, "ccw") :: (Key.X, "cw") ::
        (Key.Up, "drop") :: (Key.Space, "drop") :: (Key.Down, "soft") :: (Key.Enter, "confirm") :: (Key.Space, "confirm") :: Nil

    /// flow の表: 役・問い・名前付きの操作・入力を受けられるか（行を消している間は受けない）。
    pub def table(): Flow.Table[World.World] =
        { roles = _ -> roles(),
          probes =
              { name = "phase", doc = "場面（Playing・Clearing・GameOver）", read = Flow.Probe.Text(w -> "${w#phase}") } ::
              { name = "lines", doc = "消した行の通算", read = Flow.Probe.Num(w -> Int32.toFloat64(w#lines)) } ::
              { name = "score", doc = "点", read = Flow.Probe.Num(w -> Int32.toFloat64(w#score)) } ::
              { name = "cells", doc = "盤に固定した升の数", read = Flow.Probe.Num(w -> Int32.toFloat64(Map.size(w#board))) } ::
              { name = "piece", doc = "操作中のミノの種類（I・O・T・S・Z・J・L）", read = Flow.Probe.Text(w -> "${w#current#kind}") } ::
              { name = "col", doc = "操作中のミノの原点の列", read = Flow.Probe.Num(w -> Int32.toFloat64(w#current#col)) } ::
              { name = "rot", doc = "操作中のミノの向き（0..3）", read = Flow.Probe.Num(w -> Int32.toFloat64(w#current#rot)) } ::
              { name = "over", doc = "GAME OVER の画面", read = Flow.Probe.Flag(w -> w#phase == World.Phase.GameOver) } :: Nil,
          drives =
              { name = "dropper", doc = "遊び中なら 0.5 秒ごとに叩きつける（GAME OVER まで積む）",
                act = (waited, w) -> if (w#phase != World.Phase.Playing) Flow.DriveAct.Restart
                                     else if (waited >= 0.5) Flow.DriveAct.Tap("drop")
                                     else Flow.DriveAct.Idle } :: Nil,
          ready = Some(w -> if (w#phase == World.Phase.Clearing) Flow.Ready.Busy("行を消している") else Flow.Ready.Ready)
          | Flow.emptyTable() }

    /// 指紋の元（記録の再生が 60 フレームごとに比べる）: 進行に効く欄だけ。
    pub def fingerprint(w: World.World): String =
        "${w#phase}|t=${w#t}|lines=${w#lines}|score=${w#score}|cells=${Map.size(w#board)}" +
        "|piece=${w#current#kind}:${w#current#col},${w#current#row},${w#current#rot}|next=${w#nextKind}|seed=${w#seed}"
}
