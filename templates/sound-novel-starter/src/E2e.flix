// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す。
//   make flow FLOW=e2e/true_ending.flow   画面なしで最後まで流す
mod E2e {
    use fge::{App, Emit, Flow}

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    pub def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(appOf(), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    pub def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(appOf(), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// flow と窓なしのゲームが使う App（セーブデータは読まない = いつも初めて遊ぶ人と同じ所から。時刻は 0 に据える）。
    def appOf(): App.App[World.World, {}] \ Fs.FileRead =
        let docs = Controls.loadDocs();
        Game.app(docs, Saves.fresh(docs#kind), 0i64)

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    /// 窓なしのゲーム（Studio の会話のプレビューと bin/fge talk shot）と、描き出しの入口の常駐（/run）。
    pub def serveHeadless(): Unit \ IO =
        let jobs = SceneRender.jobs() ::: jobs();
        run { App.Headless.serveJobs(appOf(), jobs) } with Fs.FileRead.runWithIO

    /// 行を読み終えてから送るまでの秒（人が読んでいる間）。
    def readSeconds(): Float64 = 0.4

    /// flow の表: 役（novel.keys.json の割り当て）・問い・名前付きの操作・返事の通し番号（出来事の総数）。
    pub def table(): Flow.Table[World.World] =
        { roles = w -> {
              let keys = KeysDoc.rec(w#keys);
              let rows = (name, list) -> List.map(key -> (key, name), list);
              rows("confirm", keys#confirm) ::: rows("back", keys#back) ::: rows("prev", keys#prev) ::: rows("next", keys#next) :::
              rows("left", keys#left) ::: rows("right", keys#right) ::: rows("log", keys#log) ::: rows("auto", keys#auto) :::
              rows("skip", keys#skip) ::: rows("hide", keys#hide) ::: rows("rollback", keys#rollback) :::
              rows("quickSave", keys#quickSave) ::: rows("quickLoad", keys#quickLoad) ::: rows("tabPrev", keys#tabPrev) :::
              rows("tabNext", keys#tabNext) ::: rows("remove", keys#remove)
          },
          probes =
              { name = "phase", doc = "場面（Title・Reading・Credits）", read = Flow.Probe.Text(w -> "${w#phase}") } ::
              { name = "panel", doc = "開いている画面（Closed・Log・SaveSlots・LoadSlots・Settings・Hidden）", read = Flow.Probe.Text(w -> "${w#panel}") } ::
              { name = "ask", doc = "確認の窓で尋ねている事（無ければ空。Overwrite(0)・ToTitle・Quit など）", read = Flow.Probe.Text(w -> w#ask |> Option.map(a -> "${a}") |> Option.getWithDefault("")) } ::
              { name = "tab", doc = "セーブ・ロードの今のページ（Auto・Quick・Numbered(1) など）", read = Flow.Probe.Text(w -> "${w#slotTab}") } ::
              { name = "logSize", doc = "バックログの行の数", read = Flow.Probe.Num(w -> Int32.toFloat64(List.length(w#log))) } ::
              { name = "talk", doc = "開いているシナリオのノード（閉じていれば空）", read = Flow.Probe.Text(World.talkNodeOf) } ::
              { name = "talkLine", doc = "今出している行のシナリオの行（ファイル:行）", read = Flow.Probe.Text(World.talkLineOf) } ::
              { name = "mode", doc = "文章の出し方（Nvl・Adv）", read = Flow.Probe.Text(w -> "${w#stage#mode}") } ::
              { name = "photo", doc = "今の背景の写真の名前（無ければ空）", read = Flow.Probe.Text(w -> w#stage#shot |> Option.map(s -> s#photo) |> Option.getWithDefault("")) } ::
              { name = "lineDone", doc = "今の行を出し終えた", read = Flow.Probe.Flag(w -> Page.isDone(w#page)) } ::
              { name = "choice", doc = "選択肢を出している", read = Flow.Probe.Flag(World.isAsking) } ::
              { name = "cursor", doc = "カーソル（0 から）", read = Flow.Probe.Num(w -> Int32.toFloat64(w#cursor)) } ::
              { name = "stayed", doc = "シナリオの変数 $stayed（true の結末へ向かっている）", read = Flow.Probe.Flag(w -> World.variableOf("$stayed", w) == "True") } ::
              { name = "closeness", doc = "シナリオの変数 $closeness", read = Flow.Probe.Num(w -> World.variableOf("$closeness", w) |> Float64.fromString |> Option.getWithDefault(0.0)) } :: Nil,
          drives =
              { name = "reader", doc = "行を出し終えたら少し読んでから送る（選択肢・窓・タイトル画面では押さない）",
                act = (waited, w) ->
                    if (w#phase != World.Phase.Reading or w#panel != World.Panel.Closed or Option.nonEmpty(w#ask) or World.isAsking(w)) Flow.DriveAct.Restart
                    else if (not Page.isDone(w#page)) Flow.DriveAct.Restart
                    else if (waited >= readSeconds()) Flow.DriveAct.Tap("confirm")
                    else Flow.DriveAct.Idle } :: Nil,
          ready = Some(w -> if (w#phase == World.Phase.Reading and not Page.isDone(w#page)) Flow.Ready.Busy("typing") else Flow.Ready.Ready),
          replies = Some(w -> Emit.countOf(w#events))
          | Flow.emptyTable() }

    /// 指紋の元（記録の再生が 60 フレームごとに比べる）: 進行に効く欄だけ。
    pub def fingerprint(w: World.World): String =
        "${w#phase}|${w#panel}|${World.talkNodeOf(w)}|${World.talkLineOf(w)}|done=${Page.isDone(w#page)}|cursor=${w#cursor}" +
        "|mode=${w#stage#mode}|playback=${w#playback}|ask=${w#ask}|tab=${w#slotTab}|events=${Emit.countOf(w#events)}"
}
