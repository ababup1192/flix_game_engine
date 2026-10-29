// BotRun — 自動の通しプレイの入口とレポート（make bot → debug/bot.md）。
// タイトルから Bot の方針でキーを決め、App.traceFrame で Game.app に 1 フレームずつ流す（dt は 1/60 秒で固定）。
// エンディングに着けば 1 周を終えた事にする（区間は world・B1・B2・B3・ボス戦・ボスの後の帰り道）。
// 詰み: フィールドにいる間の遊びの時計で 60 秒、目的地までの残り（Bot.remainingOf）が一番小さかった値より縮まなければ止める
// （戦いの中の時間は数えない。全滅して宿の前へ戻った時と目的が替わった時は数え直す）。
//   BOT_RUNS=n … 種（dice の始めの値）を BOT_SEED から 1 ずつ変えて n 本流す（既定 1）
//   BOT_SEED=n … 1 本目の種（既定 0）
mod BotRun {
    use fge::{App, Clock, Flow, Resources, Vec2}
    use fge::GameEngine.Key

    import java.lang.System

    type alias Run = Resources.With[Res.Res, World.World]

    /// 1 本の結果。done = エンディングに着いた・reason = 止めた理由・playSeconds = 遊びの時計・battles = 区間（sectionOf）ごとの戦った数・
    /// lvAt = 区間に初めて入った時のルカの Lv・wipes = 全滅したマップ（ボス戦は boss）・lastLv = 終わった時の Lv（仲間ごと）・gold = 終わった時のお金・
    /// fingerprint = 止めた時の World の指紋と目的。
    /// moveSeconds = 歩き・暗転・トロッコの秒（入力の層が Walking か Busy のフィールド）・windows = 会話と知らせのウィンドウを開いた数・
    /// supplies = 終わった時のふくろの使う物と、仲間ごとの MP（今 / 最大）・log = 流した手と区間の印（新しい順。playthrough.flow に書く）。
    type alias Report = { seed = Int32, done = Bool, reason = String, frames = Int32, playSeconds = Float64,
                          battles = Map[String, Int32], lvAt = List[(String, Int32)], wipes = List[String],
                          lastLv = String, gold = Int32, fingerprint = String, moveSeconds = Float64, windows = Int32, supplies = String,
                          log = List[Logged] }

    /// 流している間の値。
    type alias Loop = { h = Run, bot = Bot.State, step = App.StepState, prev = Set[Key], frames = Int32,
                        fieldTime = Float64, best = Int32, bestAt = Float64, goal = String,
                        battles = Map[String, Int32], lvAt = List[(String, Int32)], wipes = List[String], lastMap = String,
                        moveSeconds = Float64, windows = Int32, log = List[Logged], ending = Option[{ world = World.World, frames = Int32 }] }

    /// playthrough.flow に書く物: Played = 流した 1 フレームとその後の指紋の元 / Note = そのまま書く 1 行（区間の頭の mark と expect）。
    enum Logged {
        case Played(App.Frame, String)
        case Note(String)
    }

    /// 1 本目の通しの手の置き場（動画の手順に流し直せる。区間の頭ごとに mark と expect）。
    def playthroughPath(): String = "debug/bot/playthrough.flow"

    /// 人が遊んだ時の 1 戦の秒（docs/proposals/toto-and-mine.md 3.2 の見積もり）と、ウィンドウ 1 枚を読んで送る秒。
    /// WhyNot: bot のゲーム内時間をそのまま 1 周の時間にしない — bot は文字送りも戦いの伝言も出たフレームに送るので、
    /// 戦いと会話が人の何分の 1 にも縮む。歩き（と暗転・トロッコ）だけは人とほぼ同じなので bot の秒を使う。
    def humanBattleSeconds(): Float64 = 33.0

    def humanWindowSeconds(): Float64 = 3.0

    /// 人の 1 周の目安（秒）: 歩きの秒 + 戦い × humanBattleSeconds + ウィンドウ × humanWindowSeconds。
    def humanSecondsOf(r: Report): Float64 =
        let fights = r#battles |> Map.valuesOf |> List.sum;
        r#moveSeconds + Int32.toFloat64(fights) * humanBattleSeconds() + Int32.toFloat64(r#windows) * humanWindowSeconds()

    def sections(): List[String] = "world" :: "mine_b1" :: "mine_b2" :: "mine_b3" :: "boss" :: "return" :: Nil

    /// 区間の名前: ボスを倒した後は return（坑道の入口から村まで）・ボス戦の間は boss・ほかはいるマップの名前。
    def sectionOf(w: World.World, mapName: String): String =
        if (Progress.rec(w#progress)#quest >= Quest.Quest.BossDown) "return"
        else if (isBossFight(w)) "boss"
        else mapName

    def isBossFight(w: World.World): Bool =
        World.battleRecOf(w) |> Option.exists(r -> Battle.rec(r#battle)#foes |> Vector.exists(f -> FoesDoc.keyOf(f#id) == BotBattle.bossFoe()))

    /// 1 フレームの秒（ナノ秒に丸めた 1/60 秒）。
    /// WhyNot: 1/60 秒のまま流さない — playthrough.flow はナノ秒で書くので、流し直すと文字送りの境目が 1 フレームずれて手が食い違う。
    def dt(): Float64 = Flow.roundToNanos(1.0 / 60.0)

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
        reports |> List.head |> Option.forEach(writePlaythrough);
        if (List.forAll(r -> r#done, reports)) 0 else 1

    /// 種 seed の 1 本をタイトルから流す。
    def playOne(app: App.App[Run, {}], seed: Int32): Report \ Fs.FileRead =
        let h = App.startOrBug(app, "title", startArgsOf(seed));
        loop(app, seed, { h = h, bot = Bot.initial(), step = App.freshStepState(), prev = Set.empty(), frames = 0,
                          fieldTime = 0.0, best = 1000000, bestAt = 0.0, goal = "", battles = Map.empty(), lvAt = Nil, wipes = Nil, lastMap = "",
                          moveSeconds = 0.0, windows = 0, log = Nil, ending = None })

    /// 1 本の始まりの引数（Starts の title。dice の始めの値 = 種）。
    def startArgsOf(seed: Int32): Map[String, String] = Map#{"seed" => "${seed}"}

    /// 1 フレームずつ流す。エンディングに着いたら、その時の World とフレームを数え（表の値はそこまで）、字が流れ切ってタイトルへ
    /// 戻るまで流し続ける（通しの手はタイトルまで）。
    def loop(app: App.App[Run, {}], seed: Int32, l0: Loop): Report =
        let res = l0#h#resources;
        let w = l0#h#world;
        let l = if (Option.isEmpty(l0#ending) and Bot.isAtEnding(w)) { ending = Some({ world = w, frames = l0#frames }) | l0 } else l0;
        if (Option.nonEmpty(l#ending) and World.sceneKindOf(w) == World.SceneKind.Title) reportOf(seed, true, "エンディングからタイトルへ戻った", l)
        else if (l#frames >= maxFrames()) reportOf(seed, false, "打ち切り（${maxFrames()} フレーム）", l)
        else if (l#fieldTime - l#bestAt > stuckSeconds()) reportOf(seed, false, "詰んだ（${stuckSeconds()} 秒 目的地に近づかない）", l)
        else {
            let bot1 = Bot.refresh(res, w, l#bot);
            let (keys, bot2) = Bot.decide(res, w, bot1);
            let frame = App.frameOf({ prev = l#prev }, { current = keys }, dt(), WindowView.design(),
                                    { prevCursor = None, cursor = Vec2.zero() }, { prevDown = false, down = false, wheel = 0.0 });
            let (traced, step) = App.traceFrame(app, frame, l#step, l#h);
            let played = Logged.Played(frame, E2e.fingerprint(traced#after#world));
            loop(app, seed, observe(res, w, traced#after, { bot = bot2, step = step, prev = keys, frames = l#frames + 1, log = played :: l#log | l }))
        }

    /// フレームの前後を見て数える: 戦いに入った・全滅して戻った・区間に初めて入った・詰みの残り。
    def observe(res: Res.Res, before: World.World, h: Run, l: Loop): Loop =
        let after = h#world;
        let mapName = World.fieldRecOf(after) |> Option.map(r -> MapDoc.nameOf(r#map)) |> Option.getWithDefault(l#lastMap);
        let entered = World.sceneKindOf(before) == World.SceneKind.Field and World.sceneKindOf(after) == World.SceneKind.Battle;
        let lost = World.battleRecOf(before) |> Option.exists(r -> Battle.outcomeOf(r#battle) == Battle.Outcome.Lost)
                   and World.sceneKindOf(after) == World.SceneKind.Field;
        let section = sectionOf(after, mapName);
        let battles = if (entered) Map.insertWith((a, b) -> a + b, sectionOf(after, l#lastMap), 1, l#battles) else l#battles;
        let firstVisit = List.memberOf(section, sections()) and not List.exists(p -> fst(p) == section, l#lvAt);
        let lvAt = if (firstVisit) List.append(l#lvAt, (section, leadLvOf(after)) :: Nil) else l#lvAt;
        let log = if (firstVisit) List.append(List.reverse(sectionNotesOf(section, after)), l#log) else l#log;
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
        let wipedAt = if (isBossFight(before)) "boss" else l#lastMap;
        { h = h, battles = battles, lvAt = lvAt, wipes = if (lost) List.append(l#wipes, wipedAt :: Nil) else l#wipes,
          lastMap = mapName, goal = goal, log = log, fieldTime = fieldTime, best = best, bestAt = bestAt,
          moveSeconds = if (moving) l#moveSeconds + dt() else l#moveSeconds, windows = if (opened) l#windows + 1 else l#windows | l }

    def leadLvOf(w: World.World): Int32 = Party.statsList(w#party) |> List.head |> Option.map(row -> snd(row)#lv) |> Option.getWithDefault(0)

    /// 1 本の結果。エンディングに着いていれば、その時の World とフレームで数える（タイトルへ戻ると仲間とふくろは空に戻る）。
    def reportOf(seed: Int32, done: Bool, reason: String, l: Loop): Report =
        let w = l#ending |> Option.map(e -> e#world) |> Option.getWithDefault(l#h#world);
        let frames = l#ending |> Option.map(e -> e#frames) |> Option.getWithDefault(l#frames);
        { seed = seed, done = done, reason = reason, frames = frames, playSeconds = Clock.secondsOf(World.now(w)),
          battles = l#battles, lvAt = l#lvAt, wipes = l#wipes,
          lastLv = Party.statsList(w#party) |> List.map(match (m, s) -> {
              let gear = (s#weapon :: s#armor :: Nil) |> List.filterMap(x -> x) |> List.map(ItemsDoc.keyOf) |> List.join("+");
              "${Member.idOf(m)} ${s#lv}（${gear}）"
          }) |> List.join(" / "),
          gold = Bag.goldOf(w#bag), fingerprint = "${E2e.fingerprint(w)} | goal=${l#goal}",
          moveSeconds = l#moveSeconds, windows = l#windows, supplies = suppliesOf(l#h#resources, w), log = l#log }

    /// 区間の頭に書く 2 行: mark <区間> と、その時に立っているはずの段階・場面（フィールドならマップも）の expect（問いの名前は E2e の probes）。
    def sectionNotesOf(section: String, w: World.World): List[Logged] =
        let quest = Quest.nameOf(Progress.rec(w#progress)#quest);
        let map = World.fieldRecOf(w) |> Option.map(r -> "&map=${MapDoc.nameOf(r#map)}") |> Option.getWithDefault("");
        Logged.Note("mark ${section}") :: Logged.Note("expect quest=${quest}&scene=${World.sceneKindOf(w)}${map}") :: Nil

    /// 1 本の流した手を flow の文法で書く（engine の遊んだ記録と同じ書き手。同じ入力が続くフレームは 1 行・60 フレームごとに指紋の expect）。
    def writePlaythrough(r: Report): Unit \ IO =
        match Flow.Record.open(playthroughPath()) {
            case None      => println("[bot] ${playthroughPath()} を開けないので書かない")
            case Some(rec) =>
                Flow.Record.started(rec, Flow.Record.startLine("title", startArgsOf(r#seed), Map.empty()));
                r#log |> List.reverse |> List.forEach(entry -> match entry {
                    case Logged.Played(frame, fp) => Flow.Record.frame(rec, frame, Some(fp))
                    case Logged.Note(text)        => Flow.Record.line(rec, text)
                });
                if (r#done) Flow.Record.line(rec, "expect scene=Title") else ();
                Flow.Record.close(rec)
        }

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
        let sectionNames = "（world / B1 / B2 / B3 / ボス / 帰り）";
        let columns = "種" :: "結果" :: "ゲーム内時間" :: "人の目安（歩き / ウィンドウの数）" :: "フレーム" :: "戦った数${sectionNames}" ::
                      "区間に入った時の Lv${sectionNames}" :: "全滅" :: "終わりの Lv（装備）" :: "お金" :: "終わりの使う物 / MP" :: Nil;
        let header = List.join("\n",
            "# 自動の通しプレイ（make bot）" ::
            "" ::
            "タイトルからエンディングまで（ボスを倒して村長に報告する）。方針は src/sim/Bot.flix（戦いは Bot.battlePlans: HP 35% 未満の仲間を" +
            "回復の呪文 → やくそう・逃げられない組では攻めの呪文 → ばくだんいし・ほかは たたかう・にげない。" +
            "村の外で HP 60% 未満ならフィールドで回復の呪文 → やくそう・村で HP 60% 未満なら宿）。" ::
            "流した時間: ${minutes(seconds)}（${List.length(reports)} 本）" ::
            "人の目安 = 歩き・暗転・トロッコの秒（bot と同じ）+ 戦い × ${humanBattleSeconds()} 秒 + 会話と知らせのウィンドウ × ${humanWindowSeconds()} 秒" +
            "（bot は文字送りと伝言をすぐ送るので、ゲーム内時間は人より短い）。" ::
            "" ::
            tableRow(columns) ::
            "|" + (columns |> List.map(_ -> "---|") |> List.join("")) ::
            "" :: Nil);
        let rows = reports |> List.map(r -> {
            let fights = sections() |> List.map(s -> "${Map.getWithDefault(s, 0, r#battles)}") |> List.join(" / ");
            let lvs = sections() |> List.map(s -> List.find(p -> fst(p) == s, r#lvAt) |> Option.map(p -> "${snd(p)}") |> Option.getWithDefault("-")) |> List.join(" / ");
            let wipes = if (List.isEmpty(r#wipes)) "0" else "${List.length(r#wipes)}（${List.join("・", r#wipes)}）";
            tableRow("${r#seed}" :: (if (r#done) "着いた" else r#reason) :: minutes(r#playSeconds) ::
                     "${minutes(humanSecondsOf(r))}（${minutes(r#moveSeconds)} / ${r#windows}）" :: "${r#frames}" :: fights :: lvs :: wipes ::
                     r#lastLv :: "${r#gold}" :: r#supplies :: Nil)
        }) |> List.join("\n");
        let stuck = reports |> List.filter(r -> not r#done) |> List.map(r -> "- 種 ${r#seed}: ${r#reason} — `${r#fingerprint}`") |> List.join("\n");
        header + rows + "\n" + (if (String.isEmpty(stuck)) "" else "\n## 止まった所\n\n" + stuck + "\n")

    /// 表の 1 行（| a | b |）。
    def tableRow(cells: List[String]): String = "| ${List.join(" | ", cells)} |"
}
