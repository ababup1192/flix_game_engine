// BotRun — 自動の通しプレイの入口とレポート（make bot → debug/bot.md）。
// タイトルから Bot の方針でキーを決め、App.traceFrame で Game.app に 1 フレームずつ流す（dt は 1/60 秒で固定）。
// 坑道 B3 の封じられた扉の前に着けば着いた事にする（ボスと帰りはまだ遊べない）。
// 詰み: フィールドにいる間の遊びの時計で 60 秒、目的地までの残り（Bot.remainingOf）が一番小さかった値より縮まなければ止める
// （戦いの中の時間は数えない。全滅して宿の前へ戻った時と目的が替わった時は数え直す）。
//   BOT_RUNS=n … 種（dice の始めの値）を BOT_SEED から 1 ずつ変えて n 本流す（既定 1）
//   BOT_SEED=n … 1 本目の種（既定 0）
mod BotRun {
    use fge::{App, Clock, Resources, Vec2}
    use fge::GameEngine.Key

    import java.lang.System

    type alias Run = Resources.With[Res.Res, World.World]

    /// 1 本の結果。done = 扉の前に着いた・reason = 止めた理由・playSeconds = 遊びの時計・battles = 区間（マップ）ごとの戦った数・
    /// lvAt = 区間に初めて入った時のルカの Lv・wipes = 全滅したマップ・lastLv = 終わった時の Lv（仲間ごと）・gold = 終わった時のお金・
    /// fingerprint = 止めた時の World の指紋と目的。
    /// moveSeconds = 歩き・暗転・トロッコの秒（入力の層が Walking か Busy のフィールド）・windows = 会話と知らせのウィンドウを開いた数・
    /// supplies = 終わった時のふくろの使う物と、仲間ごとの MP（今 / 最大）。
    type alias Report = { seed = Int32, done = Bool, reason = String, frames = Int32, playSeconds = Float64,
                          battles = Map[String, Int32], lvAt = List[(String, Int32)], wipes = List[String],
                          lastLv = String, gold = Int32, fingerprint = String, moveSeconds = Float64, windows = Int32, supplies = String }

    /// 流している間の値。
    type alias Loop = { h = Run, bot = Bot.State, step = App.StepState, prev = Set[Key], frames = Int32,
                        fieldTime = Float64, best = Int32, bestAt = Float64, goal = String,
                        battles = Map[String, Int32], lvAt = List[(String, Int32)], wipes = List[String], lastMap = String,
                        moveSeconds = Float64, windows = Int32 }

    /// 人が遊んだ時の 1 戦の秒（docs/proposals/toto-and-mine.md 3.2 の見積もり）と、ウィンドウ 1 枚を読んで送る秒。
    /// WhyNot: bot のゲーム内時間をそのまま 1 周の時間にしない — bot は文字送りも戦いの伝言も出たフレームに送るので、
    /// 戦いと会話が人の何分の 1 にも縮む。歩き（と暗転・トロッコ）だけは人とほぼ同じなので bot の秒を使う。
    def humanBattleSeconds(): Float64 = 33.0

    def humanWindowSeconds(): Float64 = 3.0

    /// 人の 1 周の目安（秒）: 歩きの秒 + 戦い × humanBattleSeconds + ウィンドウ × humanWindowSeconds。
    def humanSecondsOf(r: Report): Float64 =
        let fights = r#battles |> Map.valuesOf |> List.sum;
        r#moveSeconds + Int32.toFloat64(fights) * humanBattleSeconds() + Int32.toFloat64(r#windows) * humanWindowSeconds()

    def sections(): List[String] = "world" :: "mine_b1" :: "mine_b2" :: "mine_b3" :: Nil

    /// 1 フレームの秒。
    def dt(): Float64 = 1.0 / 60.0

    /// 詰みとみなす、フィールドで縮まない秒。
    def stuckSeconds(): Float64 = 60.0

    /// 打ち切るフレームの数（遊びの時計で 60 分）。
    def maxFrames(): Int32 = 216000

    /// make bot の入口。
    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    def playJob(req: App.Headless.Request): Int32 \ IO =
        let env = App.Headless.envOf(req);
        let runs = Map.get("BOT_RUNS", env) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(1);
        let seed0 = Map.get("BOT_SEED", env) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(0);
        let started = System.nanoTime();
        let reports = run {
            let docs = Res.loadDocs();
            let app = Game.app(docs, None);
            List.range(0, runs) |> List.map(i -> playOne(app, seed0 + i))
        } with Fs.FileRead.runWithIO;
        let seconds = Int64.toFloat64(System.nanoTime() - started) / 1.0e9;
        let text = reportText(reports, seconds);
        println(text);
        run {
            discard Fs.FileWrite.mkDirs("debug");
            discard Fs.FileWrite.write({ str = text }, "debug/bot.md")
        } with Fs.FileWrite.runWithIO;
        if (List.forAll(r -> r#done, reports)) 0 else 1

    /// 種 seed の 1 本をタイトルから流す。
    def playOne(app: App.App[Run, {}], seed: Int32): Report \ Fs.FileRead =
        let h0 = App.startOrBug(app, "title", Map.empty());
        let h = Resources.of(h0#resources, Dice.withSeed(seed, h0#world));
        loop(app, seed, { h = h, bot = Bot.initial(), step = App.freshStepState(), prev = Set.empty(), frames = 0,
                          fieldTime = 0.0, best = 1000000, bestAt = 0.0, goal = "", battles = Map.empty(), lvAt = Nil, wipes = Nil, lastMap = "",
                          moveSeconds = 0.0, windows = 0 })

    def loop(app: App.App[Run, {}], seed: Int32, l: Loop): Report =
        let res = l#h#resources;
        let w = l#h#world;
        if (Bot.isDone(w)) reportOf(seed, true, "B3 の扉の前に着いた", l)
        else if (l#frames >= maxFrames()) reportOf(seed, false, "打ち切り（${maxFrames()} フレーム）", l)
        else if (l#fieldTime - l#bestAt > stuckSeconds()) reportOf(seed, false, "詰んだ（${stuckSeconds()} 秒 目的地に近づかない）", l)
        else {
            let bot1 = Bot.refresh(res, w, l#bot);
            let (keys, bot2) = Bot.decide(res, w, bot1);
            let frame = App.frameOf({ prev = l#prev }, { current = keys }, dt(), WindowView.design(),
                                    { prevCursor = None, cursor = Vec2.zero() }, { prevDown = false, down = false, wheel = 0.0 });
            let (traced, step) = App.traceFrame(app, frame, l#step, l#h);
            loop(app, seed, observe(res, w, traced#after, { bot = bot2, step = step, prev = keys, frames = l#frames + 1 | l }))
        }

    /// フレームの前後を見て数える: 戦いに入った・全滅して戻った・区間に初めて入った・詰みの残り。
    def observe(res: Res.Res, before: World.World, h: Run, l: Loop): Loop =
        let after = h#world;
        let mapName = World.fieldRecOf(after) |> Option.map(r -> MapDoc.nameOf(r#map)) |> Option.getWithDefault(l#lastMap);
        let entered = World.sceneKindOf(before) == World.SceneKind.Field and World.sceneKindOf(after) == World.SceneKind.Battle;
        let lost = World.battleRecOf(before) |> Option.exists(r -> Battle.outcomeOf(r#battle) == Battle.Outcome.Lost)
                   and World.sceneKindOf(after) == World.SceneKind.Field;
        let battles = if (entered) Map.insertWith((a, b) -> a + b, l#lastMap, 1, l#battles) else l#battles;
        let firstVisit = mapName != l#lastMap and List.memberOf(mapName, sections()) and not List.exists(p -> fst(p) == mapName, l#lvAt);
        let lvAt = if (firstVisit) List.append(l#lvAt, (mapName, leadLvOf(after)) :: Nil) else l#lvAt;
        let goal = "${Bot.goalOf(res, after)}";
        let inField = World.sceneKindOf(after) == World.SceneKind.Field;
        let fieldTime = if (inField) l#fieldTime + dt() else l#fieldTime;
        let remaining = Bot.remainingOf(res, after, l#bot);
        let reset = lost or goal != l#goal;
        let (best, bestAt) = if (reset) (remaining, fieldTime) else if (remaining < l#best) (remaining, fieldTime) else (l#best, l#bestAt);
        let moving = inField and (match InputLayer.layerOf(after) {
            case InputLayer.Layer.Walking => true
            case InputLayer.Layer.Busy    => true
            case _                        => false
        });
        let opened = Option.isEmpty(World.typingOf(before)) and Option.nonEmpty(World.typingOf(after));
        { h = h, battles = battles, lvAt = lvAt, wipes = if (lost) List.append(l#wipes, l#lastMap :: Nil) else l#wipes,
          lastMap = mapName, goal = goal, fieldTime = fieldTime, best = best, bestAt = bestAt,
          moveSeconds = if (moving) l#moveSeconds + dt() else l#moveSeconds, windows = if (opened) l#windows + 1 else l#windows | l }

    def leadLvOf(w: World.World): Int32 = Party.statsList(w#party) |> List.head |> Option.map(row -> snd(row)#lv) |> Option.getWithDefault(0)

    def reportOf(seed: Int32, done: Bool, reason: String, l: Loop): Report =
        let w = l#h#world;
        { seed = seed, done = done, reason = reason, frames = l#frames, playSeconds = Clock.secondsOf(World.now(w)),
          battles = l#battles, lvAt = l#lvAt, wipes = l#wipes,
          lastLv = Party.statsList(w#party) |> List.map(match (m, s) -> {
              let gear = (s#weapon :: s#armor :: Nil) |> List.filterMap(x -> x) |> List.map(ItemsDoc.keyOf) |> List.join("+");
              "${Member.idOf(m)} ${s#lv}（${gear}）"
          }) |> List.join(" / "),
          gold = Bag.goldOf(w#bag), fingerprint = "${E2e.fingerprint(w)} | goal=${l#goal}",
          moveSeconds = l#moveSeconds, windows = l#windows, supplies = suppliesOf(l#h#resources, w) }

    /// 終わった時のふくろの使う物（yakusou:2）と仲間ごとの MP（toto 12/36）。
    def suppliesOf(res: Res.Res, w: World.World): String =
        let items = Bag.listOf(res#items, w#bag)
            |> List.filter(pair -> ItemsDoc.itemOf(res#items, fst(pair)) |> Option.exists(item -> item#kind == ItemsDoc.Kind.Use))
            |> List.map(match (id, n) -> "${ItemsDoc.keyOf(id)}:${n}") |> List.join(",");
        let mps = Party.statsList(w#party) |> List.map(match (m, s) -> "${Member.idOf(m)} ${s#mp}/${Party.maxMpOf(res#party, m, w#party)}") |> List.join(" ");
        "${items} / ${mps}"

    // ── レポート ──

    def minutes(seconds: Float64): String =
        let total = Float64.round(seconds) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        "${total / 60}:${if (Int32.modulo(total, 60) < 10) "0" else ""}${Int32.modulo(total, 60)}"

    def reportText(reports: List[Report], seconds: Float64): String =
        let header = "# 自動の通しプレイ（make bot）\n\n" +
            "タイトルから坑道 B3 の封じられた扉の前まで。方針は src/sim/Bot.flix（戦いは Bot.battlePlans: HP 35% 未満の仲間を回復の呪文 → やくそう・逃げられない組では攻めの呪文 → ばくだんいし・ほかは たたかう・にげない。" +
            "村の外で HP 60% 未満ならフィールドで回復の呪文 → やくそう・村で HP 60% 未満なら宿）。\n" +
            "流した時間: ${minutes(seconds)}（${List.length(reports)} 本）\n" +
            "人の目安 = 歩き・暗転・トロッコの秒（bot と同じ）+ 戦い × ${humanBattleSeconds()} 秒 + 会話と知らせのウィンドウ × ${humanWindowSeconds()} 秒（bot は文字送りと伝言をすぐ送るので、ゲーム内時間は人より短い）。\n\n" +
            "| 種 | 結果 | ゲーム内時間 | 人の目安（歩き / ウィンドウの数） | フレーム | 戦った数（world / B1 / B2 / B3） | 区間に入った時の Lv（world / B1 / B2 / B3） | 全滅 | 終わりの Lv（装備） | お金 | 終わりの使う物 / MP |\n" +
            "|---|---|---|---|---|---|---|---|---|---|---|\n";
        let rows = reports |> List.map(r -> {
            let fights = sections() |> List.map(s -> "${Map.getWithDefault(s, 0, r#battles)}") |> List.join(" / ");
            let lvs = sections() |> List.map(s -> List.find(p -> fst(p) == s, r#lvAt) |> Option.map(p -> "${snd(p)}") |> Option.getWithDefault("-")) |> List.join(" / ");
            let wipes = if (List.isEmpty(r#wipes)) "0" else "${List.length(r#wipes)}（${List.join("・", r#wipes)}）";
            "| ${r#seed} | ${if (r#done) "着いた" else r#reason} | ${minutes(r#playSeconds)} | ${minutes(humanSecondsOf(r))}（${minutes(r#moveSeconds)} / ${r#windows}） | ${r#frames} | ${fights} | ${lvs} | ${wipes} | ${r#lastLv} | ${r#gold} | ${r#supplies} |"
        }) |> List.join("\n");
        let stuck = reports |> List.filter(r -> not r#done) |> List.map(r -> "- 種 ${r#seed}: ${r#reason} — `${r#fingerprint}`") |> List.join("\n");
        header + rows + "\n" + (if (String.isEmpty(stuck)) "" else "\n## 止まった所\n\n" + stuck + "\n")
}
