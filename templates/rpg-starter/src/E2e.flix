// E2e — e2e/<名前>.flow の語彙（App.withFlow の表と指紋）と、画面なしで流す入口。
// flow の書き方は engine の engine_world/src/Flow.flix 冒頭。名前の一覧は流すたびに e2e/vocab.json へ書き出す。
//   make flow FLOW=e2e/village_walk.flow   画面なしで最後まで流す
mod E2e {
    use fge::{App, Flow, Resources, YarnRunner}

    /// make flow（bin/fge flow run|check）が流す入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    def playJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.mainOf(Game.app(Res.loadDocs(), None), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 語彙 e2e/vocab.json だけを書く入口（bin/headless-run が jar を作った時に流す・make flow-vocab）。
    pub def vocab(): Unit \ IO = App.Headless.exitWith(vocabJob(App.Headless.requestFromProcess()))

    def vocabJob(req: App.Headless.Request): Int32 \ IO =
        run { Flow.Cli.vocabMainOf(Game.app(Res.loadDocs(), None), App.Headless.envOf(req)) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO

    /// 常駐（App.Headless.serveJobs）が /run で流す E2e の入口の束。
    pub def jobs(): List[App.Headless.Job] =
        App.Headless.job("E2e", "play", req -> playJob(req)) ::
        App.Headless.job("E2e", "vocab", req -> vocabJob(req)) :: Nil

    def onWorld(f: World.World -> a): Resources.With[Res.Res, World.World] -> a = Resources.read((_, w) -> f(w))

    def fieldNum(f: World.FieldRec -> Int32): Resources.With[Res.Res, World.World] -> Float64 =
        onWorld(w -> World.fieldRecOf(w) |> Option.map(r -> Int32.toFloat64(f(r))) |> Option.getWithDefault(-1.0))

    /// flow の表: 役（rpg.keys.json の割り当て）と問い。
    pub def table(): Flow.Table[Resources.With[Res.Res, World.World]] =
        { roles = Resources.read((res, _) -> {
              let k = KeysDoc.rec(res#keys);
              let rows = (name, keys) -> List.map(key -> (key, name), keys);
              rows("up", k#up) ::: rows("down", k#down) ::: rows("left", k#left) ::: rows("right", k#right) :::
              rows("confirm", k#confirm) ::: rows("cancel", k#cancel)
          }),
          probes =
              { name = "scene", doc = "場面（Title・Field・Battle）", read = Flow.Probe.Text(onWorld(w -> "${World.sceneKindOf(w)}")) } ::
              { name = "layer", doc = "入力を受ける層（Asking・Busy・Title・Talk・Menu・Shop・Notice・Walking・BattleChoose・BattleMessage）", read = Flow.Probe.Text(onWorld(w -> InputLayer.nameOf(InputLayer.layerOf(w)))) } ::
              { name = "map", doc = "いるマップ（タイトルなら空）", read = Flow.Probe.Text(onWorld(mapNameOf)) } ::
              { name = "x", doc = "先頭のマスの列（タイトルなら -1）", read = Flow.Probe.Num(fieldNum(r -> r#hero#x)) } ::
              { name = "y", doc = "先頭のマスの行（タイトルなら -1）", read = Flow.Probe.Num(fieldNum(r -> r#hero#y)) } ::
              { name = "facing", doc = "先頭の向き（Up・Down・Left・Right）", read = Flow.Probe.Text(onWorld(w -> World.fieldRecOf(w) |> Option.map(r -> "${r#facing}") |> Option.getWithDefault(""))) } ::
              { name = "talk", doc = "開いている会話のノード（閉じていれば空）", read = Flow.Probe.Text(onWorld(talkNodeOf)) } ::
              { name = "choice", doc = "選択肢を出している", read = Flow.Probe.Flag(onWorld(w -> WorldTalk.openTalkOf(w) |> Option.exists(t -> not List.isEmpty(t#choices)))) } ::
              { name = "quest", doc = "依頼の段階（none・accepted）", read = Flow.Probe.Text(onWorld(questNameOf)) } ::
              { name = "party", doc = "加わった仲間（先頭から。luka,mina）", read = Flow.Probe.Text(onWorld(partyNamesOf)) } ::
              { name = "gold", doc = "手持ちのお金", read = Flow.Probe.Num(onWorld(w -> Int32.toFloat64(Bag.goldOf(w#bag)))) } ::
              { name = "bag", doc = "ふくろの道具と個数（鍵の名前の順。yakusou:3,seisui:1）", read = Flow.Probe.Text(onWorld(bagTextOf)) } ::
              { name = "hp", doc = "先頭の HP（戦いの間は見せている伝言の後の値。仲間がいなければ -1）", read = Flow.Probe.Num(onWorld(leadHpOf)) } ::
              { name = "lv", doc = "先頭の Lv（仲間がいなければ -1）", read = Flow.Probe.Num(onWorld(leadLvOf)) } ::
              { name = "foes", doc = "戦いの生きている敵の数（戦いでなければ -1）", read = Flow.Probe.Num(onWorld(foesLeftOf)) } ::
              { name = "mp", doc = "仲間全員の MP の合計（戦いの間は見せている伝言の後の値）", read = Flow.Probe.Num(onWorld(mpSumOf)) } ::
              { name = "page", doc = "戦いのコマンドのページ（Commands・FoeTarget・SpellList・SpellTarget・ItemList・ItemTarget。選んでいなければ空）", read = Flow.Probe.Text(onWorld(commandPageOf)) } ::
              { name = "saved", doc = "セーブを書いた回数（saveRev。宿に泊まると 1 進む）", read = Flow.Probe.Num(onWorld(w -> Int32.toFloat64(w#saveRev))) } :: Nil,
          drives =
              { name = "battle", doc = "戦いを先へ送る: 伝言とコマンドの間は 0.2 秒ごとに決定（コマンドは たたかう・的は先頭の敵）。戦いでなければ待つ",
                act = (waited, h) -> battleDrive(waited, Resources.read((_, w) -> w, h)) } :: Nil
          | Flow.emptyTable() }

    def battleDrive(waited: Float64, w: World.World): Flow.DriveAct =
        match InputLayer.layerOf(w) {
            case InputLayer.Layer.BattleMessage if waited >= 0.2 => Flow.DriveAct.Tap("confirm")
            case InputLayer.Layer.BattleChoose(_, _) if waited >= 0.2 => Flow.DriveAct.Tap("confirm")
            case _ => Flow.DriveAct.Idle
        }

    def bagTextOf(w: World.World): String =
        Bag.itemsOf(w#bag) |> List.map(match (id, n) -> "${ItemsDoc.keyOf(id)}:${n}") |> List.join(",")

    /// 先頭の HP。戦いの間は見せている Beat の後の値（World の仲間は戦いを終える時に書き戻す）。
    def leadHpOf(w: World.World): Float64 =
        let party = World.battleRecOf(w) |> Option.map(r -> Battle.rec(WorldBattle.shownBattleOf(r))#party) |> Option.getWithDefault(w#party);
        Party.statsList(party) |> List.head |> Option.map(row -> Int32.toFloat64(snd(row)#hp)) |> Option.getWithDefault(-1.0)

    def mpSumOf(w: World.World): Float64 =
        let party = World.battleRecOf(w) |> Option.map(r -> Battle.rec(WorldBattle.shownBattleOf(r))#party) |> Option.getWithDefault(w#party);
        Party.statsList(party) |> List.map(row -> snd(row)#mp) |> List.sum |> Int32.toFloat64

    def commandPageOf(w: World.World): String =
        WorldBattle.choosingOf(w) |> Option.map(pair -> match snd(pair) {
            case World.CommandPage.Commands(_)       => "Commands"
            case World.CommandPage.FoeTarget(_)      => "FoeTarget"
            case World.CommandPage.SpellList(_)      => "SpellList"
            case World.CommandPage.SpellTarget(_, _) => "SpellTarget"
            case World.CommandPage.ItemList(_)       => "ItemList"
            case World.CommandPage.ItemTarget(_, _)  => "ItemTarget"
        }) |> Option.getWithDefault("")

    def leadLvOf(w: World.World): Float64 =
        Party.statsList(w#party) |> List.head |> Option.map(row -> Int32.toFloat64(snd(row)#lv)) |> Option.getWithDefault(-1.0)

    def foesLeftOf(w: World.World): Float64 =
        World.battleRecOf(w) |> Option.map(r -> Int32.toFloat64(List.length(Battle.aliveFoes(WorldBattle.shownBattleOf(r))))) |> Option.getWithDefault(-1.0)

    def questNameOf(w: World.World): String = Progress.nameOf(Progress.rec(w#progress)#quest)

    def partyNamesOf(w: World.World): String = Party.membersOf(w#party) |> List.map(Member.idOf) |> List.join(",")

    def mapNameOf(w: World.World): String = World.fieldRecOf(w) |> Option.map(r -> MapDoc.nameOf(r#map)) |> Option.getWithDefault("")

    def talkNodeOf(w: World.World): String =
        WorldTalk.openTalkOf(w) |> Option.flatMap(t -> YarnRunner.nodeOf(t#runner)) |> Option.getWithDefault("")

    /// 指紋の元（記録の再生が比べる）: 進行に効く欄だけ。
    pub def fingerprint(w: World.World): String =
        let cell = World.fieldRecOf(w) |> Option.map(r -> "${r#hero#x},${r#hero#y}|${r#facing}") |> Option.getWithDefault("");
        "${World.sceneKindOf(w)}|${mapNameOf(w)}|${cell}|${InputLayer.nameOf(InputLayer.layerOf(w))}|talk=${talkNodeOf(w)}|quest=${questNameOf(w)}|party=${partyNamesOf(w)}|gold=${Bag.goldOf(w#bag)}|bag=${bagTextOf(w)}|saved=${w#saveRev}|dice=${w#dice}"
}
