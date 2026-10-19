// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す
// （bin/fge flow check が JVM なしで読み、書き間違いを行番号と近い名前の案つきで止める）。
//   make flow FLOW=e2e/doubt_dealer.flow   画面なしで最後まで流す（描き出しの jar を使うので Flix を組み直さない）
mod E2e {
    use fge::{Emit, Flow, UiDialog}

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO =
        run { Flow.Cli.main(Game.app(Controls.loadDocs(), NovelKit.spawnAssets())) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（bin/headless-run が jar を作った時に流す・make flow-vocab）。
    pub def vocab(): Unit \ IO =
        run { Flow.Cli.writeVocabOf(Game.app(Controls.loadDocs(), NovelKit.spawnAssets())) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 台詞を読み終えてから送るまでの秒（人が読んでいる間）。
    def readSeconds(): Float64 = 0.6

    /// flow の表: 役（novel.keys.json の割り当て）・問い・名前付きの操作・返事の通し番号（出来事の総数）。
    pub def table(): Flow.Table[World.World] =
        { roles = w -> {
              let keys = KeysDoc.rec(w#keys);
              let rows = (name, list) -> List.map(key -> (key, name), list);
              rows("confirm", keys#confirm) ::: rows("prev", keys#prev) ::: rows("next", keys#next) :::
              rows("menu", keys#menu) ::: rows("quit", keys#quit)
          },
          probes =
              { name = "phase", doc = "場面（Title・Story）", read = Flow.Probe.Text(w -> "${w#phase}") } ::
              { name = "talk", doc = "開いているシナリオのノード（assets/talk/novel.yarn の title:・閉じていれば空）", read = Flow.Probe.Text(World.talkNodeOf) } ::
              { name = "talkLine", doc = "今出している台詞のシナリオの行（ファイル:行・閉じていれば空）", read = Flow.Probe.Text(World.talkLineOf) } ::
              { name = "lineDone", doc = "今の台詞を出し終えた", read = Flow.Probe.Flag(w -> UiDialog.lineDone(w#kit#dialog)) } ::
              { name = "choice", doc = "選択肢が開いて選べる", read = Flow.Probe.Flag(w -> NovelKit.isAsking(w#kit)) } ::
              { name = "cursor", doc = "選択肢のカーソル（0 から）", read = Flow.Probe.Num(w -> Int32.toFloat64(w#cursor)) } ::
              { name = "lamps", doc = "点いている灯りの数", read = Flow.Probe.Num(w -> Int32.toFloat64(World.lampsLit(w))) } ::
              { name = "menu", doc = "メニューが開いている", read = Flow.Probe.Flag(w -> w#menu == World.Menu.Open) } :: Nil,
          drives =
              { name = "reader", doc = "台詞を出し終えたら少し読んでから送る（選択肢と表紙では押さない）",
                act = (waited, w) ->
                    if (w#phase != World.Phase.Story or NovelKit.isAsking(w#kit)) Flow.DriveAct.Restart
                    else if (not UiDialog.lineDone(w#kit#dialog)) Flow.DriveAct.Restart
                    else if (waited >= readSeconds()) Flow.DriveAct.Tap("confirm")
                    else Flow.DriveAct.Idle } ::
              { name = "skipTalk", doc = "会話を飛ばす: 台詞が出たらすぐ送る（選択肢と表紙では押さない）",
                act = (_, w) ->
                    if (w#phase != World.Phase.Story or NovelKit.isAsking(w#kit)) Flow.DriveAct.Restart
                    else Flow.DriveAct.Tap("confirm") } :: Nil,
          // 文字送りの間は押さずに待つ（押すと全文が出るだけで、送るつもりの押しが空振りする）。
          ready = Some(w -> if (w#phase == World.Phase.Story and not UiDialog.lineDone(w#kit#dialog)) Flow.Ready.Busy("typing") else Flow.Ready.Ready),
          replies = Some(w -> Emit.countOf(w#events))
          | Flow.emptyTable() }

    /// 指紋の元（記録の再生が 60 フレームごとに比べる）: 進行に効く欄だけ。
    pub def fingerprint(w: World.World): String =
        "${w#phase}|${World.talkNodeOf(w)}|${World.talkLineOf(w)}|done=${UiDialog.lineDone(w#kit#dialog)}|cursor=${w#cursor}" +
        "|lights=${w#lightsOut}|menu=${w#menu}|events=${Emit.countOf(w#events)}"
}
