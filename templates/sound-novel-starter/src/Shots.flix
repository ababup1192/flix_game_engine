// Shots — ギャラリーの場面（make render-all の 1 枚）の World を組む。描き出し（SceneRender）と実機（Game の App.withShots。
// START=shot:<場面>）が同じ関数で組むので、実機で開いた場面はギャラリーの絵と同じ World から始まる。
// 場面は「進めて作る」: 台本が伸びても行番号を数え直さずに済むよう、「ノードの n 番目の台詞」「選択肢が出るまで」で位置を決める。
// WhyNot: 描き出しの物（HeadlessRender・HeadlessFont・java.io）を引かない — Game.app から engine_tools へつながり、ブラウザ版で組めなくなる。
mod Shots {
    use fge::{Clock, Emit, Yarn, YarnRunner, YarnStorage}

    /// 描き出しの始まりの World（セーブデータは空・時刻は clockBase）。
    def initialOf(res: Res.Res): World.World = World.initial(Saves.fresh(res#kind), clockBase())

    /// 描き出しの「起動した時刻」（2026/08/14 19:32。セーブの日時を毎回同じ字にする）。
    pub def clockBase(): Int64 = 1786735920i64

    /// 描き出せる場面の名前（novel.shots.json の並び。後ろに extra の場面）。
    pub def names(res: Res.Res): List[String] =
        List.append(ShotsDoc.namesOf(res#shots), extra() |> List.map(fst))

    /// 名前 → 描き出しと同じ初めの World（initialOf）から組んだ場面の World。
    pub def worldOf(name: String, res: Res.Res): Option[World.World] =
        match ShotsDoc.shotOf(name, res#shots) {
            case Some(shot) => Some(sceneOf(res, shot, initialOf(res)))
            case None       => extra() |> List.find(match (n, _) -> n == name) |> Option.flatMap(match (_, build) -> build(res))
        }

    /// Doc で表せない、コードで組む場面（名前, 組み立て）。novel.shots.json の場面の後ろに並ぶ。
    pub def extra(): List[(String, Res.Res -> Option[World.World])] = Nil

    /// Doc の 1 場面の World。時計は秒で据える（蛍もクレジットも実時間から導くので、据えれば毎回同じ絵）。
    def sceneOf(res: Res.Res, shot: ShotsDoc.Shot, w0: World.World): World.World =
        let storage = storageOf(res, shot#vars);
        let placed = shot#node |> Option.map(node -> placeIn(res, node, shot#place, storage, w0)) |> Option.getWithDefault(w0);
        let opened = shot#open |> Option.map(screen -> openScreen(res, screen, placed)) |> Option.getWithDefault(placed);
        let pointed = shot#pointer |> Option.map(p -> { pointer = { x = p#x, y = p#y } | opened }) |> Option.getWithDefault(opened);
        at(shot#at, pointed)

    /// 場面の変数（$ を付けない名前 → 値）を始まりの引数にしたシナリオの値。
    def storageOf(res: Res.Res, vars: Map[String, String]): YarnStorage.Storage =
        if (Map.isEmpty(vars)) YarnStorage.empty()
        else {
            let args = vars |> Map.foldLeftWithKey((acc, k, v) -> Map.insert("$" + k, v, acc), Map.empty());
            YarnStorage.withArgs(args, res#dialogue, YarnStorage.empty()) |> Result.getWithDefault(YarnStorage.empty())
        }

    def placeIn(res: Res.Res, node: String, place: ShotsDoc.Place, storage: YarnStorage.Storage, w: World.World): World.World =
        match place {
            case ShotsDoc.Place.Head      => nthLine(res, node, -1, storage, w)
            case ShotsDoc.Place.NthSay(n) => nthLine(res, node, n, storage, w)
            case ShotsDoc.Place.ToChoices => toChoices(res, node, storage, w)
        }

    /// 場面で開く画面。title はタイトル画面のまま（起動した時の World）。
    def openScreen(res: Res.Res, screen: ShotsDoc.Screen, w: World.World): World.World =
        match screen {
            case ShotsDoc.Screen.Title    => w
            // バックログ: 縁側の選択肢まで読んでから開く（何行も積む）。
            case ShotsDoc.Screen.Log      => quiet(() -> WorldLog.openLog(readThrough(res, w)))
            // セーブ: 1 ページ目に 3 つ（いちばん新しい物に NEW）。
            case ShotsDoc.Screen.Save     => quiet(() -> WorldSaves.openSave(withSlots(res, w)))
            // ロード: タイトルから開いたロード画面（いちばん新しいデータのページ）。
            case ShotsDoc.Screen.Load     => quiet(() -> WorldSaves.openLoad(World.toTitle(withSlots(res, w))))
            case ShotsDoc.Screen.Settings => quiet(() -> WorldSettings.openSettings(w))
            case ShotsDoc.Screen.Ask      => quiet(() -> World.askFor(World.Ask.ToTitle, w))
            case ShotsDoc.Screen.Credits  => World.toCredits(res, w)
            case ShotsDoc.Screen.Hold     => holding(res, w)
        }

    /// 次の写真（Paddy の paddy）を黒のまま待ち続けている形（待ちの印が出る長さだけ待った所）。
    def holding(res: Res.Res, w: World.World): World.World =
        let names = BackdropDoc.textureOf("paddy", res#backdrops) |> Option.toList;
        let hold = { phase = World.HoldPhase.Waiting, phaseFrom = World.now(w), waited = KindDoc.rec(res#kind)#holdMarkSeconds + 1.0,
                     names = names, rest = Nil, last = None };
        World.mapRead(r -> { hold = Some(hold) | r }, w)

    /// 物語の時計と実時間の今を、どちらも seconds 秒に据える。
    def at(seconds: Float64, w: World.World): World.World =
        { storyClock = Clock.startAt(seconds), realNow = Clock.after(seconds, Clock.zero()) | w }

    def quiet(f: Unit -> World.World \ Emit[World.Event]): World.World = fst(Emit.collect(f))

    /// node の上から n 番目（0 から。負ならノードの頭）の台詞を出し終えた所（その行までのコマンドは反映して、演出は終わりの形）。
    def nthLine(res: Res.Res, node: String, n: Int32, storage: YarnStorage.Storage, w: World.World): World.World =
        let line = Yarn.nodeOf(node, res#dialogue)
            |> Option.map(found -> found#body |> List.filterMap(statement -> match statement {
                   case Yarn.Statement.Say(say) => Some(say#source#line)
                   case _                       => None
               }))
            |> Option.flatMap(List.nth(n)) |> Option.getWithDefault(0);
        WorldRead.revealLine(quiet(() -> WorldRead.openAt(res, storage, node, line, w)))

    /// node の頭から選択肢が出るまで送った所（fuel で必ず止まる）。
    def toChoices(res: Res.Res, node: String, storage: YarnStorage.Storage, w: World.World): World.World =
        def walk(fuel: Int32, cur: World.World): World.World =
            if (fuel <= 0 or World.isChoosing(cur)) cur
            else walk(fuel - 1, quiet(() -> WorldRead.advance(res, WorldRead.revealLine(cur))));
        WorldRead.revealLine(walk(60, quiet(() -> WorldRead.openAt(res, storage, node, 0, w))))

    /// 1 ページ目に 3 つ（田んぼ・坂・縁側）、オートのページに 1 つセーブした World。日時は少しずつずらす。
    def withSlots(res: Res.Res, w: World.World): World.World =
        let saveAt = (minutes: Int64, i: Int32, scene: World.World, target: World.World) ->
            { saves = quiet(() -> WorldSaves.writeSlot(res, Saves.Tab.Numbered(1), i, { saves = target#saves, clockBase = clockBase() + minutes * 60i64 | scene }))#saves | target };
        w |> saveAt(-2900i64, 0, nthLine(res, "Paddy", 3, YarnStorage.empty(), w))
          |> saveAt(-2860i64, 1, nthLine(res, "Lane", 2, YarnStorage.empty(), w))
          |> saveAt(-12i64, 2, nthLine(res, "Engawa", 4, YarnStorage.empty(), w))
          |> (cur -> { toast = None | cur })

    /// はじめから、田んぼで昔の呼び名を選び、縁側の選択肢まで読んだ World（バックログに何行も積むため。文字送りは待たない）。
    def readThrough(res: Res.Res, w: World.World): World.World =
        def walk(fuel: Int32, picks: List[Int32], cur: World.World): World.World =
            if (fuel <= 0) cur
            else if (World.isChoosing(cur)) match picks {
                case i :: rest => walk(fuel - 1, rest, quiet(() -> WorldRead.pick(res, i, cur)))
                case Nil       => cur
            }
            else walk(fuel - 1, picks, settleWait(res, quiet(() -> WorldRead.advance(res, WorldRead.revealLine(cur)))));
        walk(200, 1 :: Nil, settleWait(res, quiet(() -> WorldRead.newGame(res, w))))

    /// <<wait>> を明かす（描き出しは時計を進めないので、明ける時刻で 1 歩だけ流す）。
    def settleWait(res: Res.Res, w: World.World): World.World =
        match World.readOf(w) |> Option.flatMap(r -> YarnRunner.waitUntilOf(r#talk)) {
            case Some(until) => quiet(() -> WorldRead.step(res, 0.0, { storyClock = Clock.startAt(Clock.secondsOf(until)) | w }))
            case None        => w
        }
}
