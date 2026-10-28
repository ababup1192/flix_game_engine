// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す。
//   make flow FLOW=e2e/true_ending.flow   画面なしで最後まで流す
mod E2e {
    use fge::{App, Emit, Flow, Resources}

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    pub def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(appOf(), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    pub def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(appOf(), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// flow とウィンドウなしのゲームが使う App（セーブデータは読まない = いつも初めて遊ぶ人と同じ所から。時刻は 0 に据える）。
    def appOf(): App.App[Resources.With[Res.Res, World.World], {}] \ Fs.FileRead =
        let res = Controls.loadRes();
        Game.app(res, Saves.fresh(res#kind), 0i64)

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    /// ウィンドウなしのゲーム（Studio の会話のプレビューと bin/fge talk shot）と、描き出しの入口の常駐（/run）。
    pub def serveHeadless(): Unit \ IO =
        let jobs = SceneRender.jobs() ::: FlowVideo.jobs() ::: jobs();
        run { App.Headless.serveJobs(appOf(), jobs) } with Fs.FileRead.runWithIO

    /// 行を読み終えてから送るまでの秒（人が読んでいる間）。
    def readSeconds(): Float64 = 0.4

    /// flow の表: 役（novel.keys.json の割り当て）・問い・名前付きの操作・返事の通し番号（出来事の総数）。
    pub def table(): Flow.Table[Resources.With[Res.Res, World.World]] =
        { roles = Resources.read((res, _) -> {
              let keys = KeysDoc.rec(res#keys);
              let rows = (name, list) -> List.map(key -> (key, name), list);
              rows("confirm", keys#confirm) ::: rows("back", keys#back) ::: rows("prev", keys#prev) ::: rows("next", keys#next) :::
              rows("left", keys#left) ::: rows("right", keys#right) ::: rows("log", keys#log) ::: rows("auto", keys#auto) :::
              rows("skip", keys#skip) ::: rows("hide", keys#hide) ::: rows("rollback", keys#rollback) :::
              rows("quickSave", keys#quickSave) ::: rows("quickLoad", keys#quickLoad) ::: rows("tabPrev", keys#tabPrev) :::
              rows("tabNext", keys#tabNext) ::: rows("remove", keys#remove)
          }),
          probes =
              { name = "phase", doc = "場面（Title・Reading・Credits）", read = Flow.Probe.Text(onWorld(World.sceneName)) } ::
              { name = "panel", doc = "開いている画面（Closed・Log・SaveSlots・LoadSlots・Settings・Hidden）", read = Flow.Probe.Text(onWorld(World.panelName)) } ::
              { name = "ask", doc = "確認のウィンドウで尋ねている事（無ければ空。字の間は詰める。Load(Numbered(1),0)・ToTitle・Quit など）", read = Flow.Probe.Text(onWorld(w -> World.askOf(w) |> Option.map(a -> String.replace(src = " ", dst = "", "${a}")) |> Option.getWithDefault(""))) } ::
              { name = "tab", doc = "セーブ・ロードの画面の今のページ（Auto・Quick・Numbered(1) など。画面が閉じていれば空）", read = Flow.Probe.Text(onWorld(w -> World.slotsOf(w) |> Option.map(match (tab, _) -> "${tab}") |> Option.getWithDefault(""))) } ::
              { name = "logSize", doc = "バックログの行の数", read = Flow.Probe.Num(onWorld(w -> Int32.toFloat64(List.length(World.logOf(w))))) } ::
              { name = "talk", doc = "開いているシナリオのノード（閉じていれば空）", read = Flow.Probe.Text(onWorld(World.talkNodeOf)) } ::
              { name = "talkLine", doc = "今出している行のシナリオの行（ファイル:行）", read = Flow.Probe.Text(onWorld(World.talkLineOf)) } ::
              { name = "mode", doc = "文章の出し方（Nvl・Adv）", read = Flow.Probe.Text(Resources.read((res, w) -> "${World.stageOf(res, w)#mode}")) } ::
              { name = "photo", doc = "今の背景の写真の名前（無ければ空）", read = Flow.Probe.Text(Resources.read((res, w) -> World.stageOf(res, w)#shot |> Option.map(s -> s#photo) |> Option.getWithDefault(""))) } ::
              { name = "lineDone", doc = "今の行を出し終えた", read = Flow.Probe.Flag(onWorld(w -> Page.isDone(World.pageOf(w)))) } ::
              { name = "choice", doc = "選択肢を出している", read = Flow.Probe.Flag(onWorld(World.isChoosing)) } ::
              { name = "cursor", doc = "一番手前のカーソルの番号（0 から。確認のウィンドウ → 画面 → 選択肢 → タイトルの順に見る）", read = Flow.Probe.Num(onWorld(w -> Int32.toFloat64(cursorOf(w)))) } ::
              { name = "stayed", doc = "シナリオの変数 $stayed（true の結末へ向かっている）", read = Flow.Probe.Flag(onWorld(w -> World.variableOf("$stayed", w) == "True")) } ::
              { name = "closeness", doc = "シナリオの変数 $closeness", read = Flow.Probe.Num(onWorld(w -> World.variableOf("$closeness", w) |> Float64.fromString |> Option.getWithDefault(0.0))) } :: Nil,
          drives =
              { name = "reader", doc = "行を出し終えたら少し読んでから送る（選択肢・ウィンドウ・タイトル画面では押さない）",
                act = (waited, h) -> Resources.read((_, w) ->
                    if (not World.isReading(w) or not World.isFree(w) or World.isChoosing(w)) Flow.DriveAct.Restart
                    else if (not Page.isDone(World.pageOf(w))) Flow.DriveAct.Restart
                    else if (waited >= readSeconds()) Flow.DriveAct.Tap("confirm")
                    else Flow.DriveAct.Idle, h) } :: Nil,
          ready = Some(onWorld(w -> if (World.isReading(w) and not Page.isDone(World.pageOf(w))) Flow.Ready.Busy("typing") else Flow.Ready.Ready)),
          replies = Some(onWorld(w -> Emit.countOf(w#events)))
          | Flow.emptyTable() }

    /// World だけを読む問いを、組（描く元と World）を受ける形にする。
    def onWorld(f: World.World -> a): Resources.With[Res.Res, World.World] -> a = Resources.read((_, w) -> f(w))

    /// 指紋の元（記録の再生が 60 フレームごとに比べる）: 進行に効く欄だけ。
    pub def fingerprint(res: Res.Res, w: World.World): String =
        "${World.sceneName(w)}|${World.panelName(w)}|${World.talkNodeOf(w)}|${World.talkLineOf(w)}|done=${Page.isDone(World.pageOf(w))}|cursor=${cursorOf(w)}" +
        "|mode=${World.stageOf(res, w)#mode}|playback=${World.playbackOf(w)}|ask=${World.askOf(w)}|tab=${World.slotsOf(w) |> Option.map(fst)}|events=${Emit.countOf(w#events)}"

    /// 一番手前のカーソルの番号: 確認のウィンドウ（はい = 0）→ セーブの枠・設定の行 → 選択肢 → タイトルの項目。
    def cursorOf(w: World.World): Int32 =
        match (World.answerOf(w), w#panel, w#scene) {
            case (Some(World.Answer.Yes), _, _)            => 0
            case (Some(World.Answer.No), _, _)             => 1
            case (None, World.Panel.SaveSlots(_, i), _)    => i
            case (None, World.Panel.LoadSlots(_, i), _)    => i
            case (None, World.Panel.Settings(setting), _)  => indexIn(WorldSettings.settings(), setting)
            case (None, _, World.Scene.Reading(r))         => r#choiceCursor
            case (None, _, World.Scene.Title(item))        => indexIn(WorldMenu.titleItems(), item)
            case (None, _, World.Scene.Credits(_, _))      => 0
        }

    def indexIn(xs: List[a], x: a): Int32 with Eq[a] =
        xs |> List.zipWithIndex |> List.find(match (_, y) -> y == x) |> Option.map(fst) |> Option.getWithDefault(0)
}
