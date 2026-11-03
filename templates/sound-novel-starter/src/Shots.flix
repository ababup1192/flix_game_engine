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

    /// 描き出せる場面の名前（make render の SHOT とギャラリーの並びの正）。
    pub def names(): List[String] =
        "title" :: "nvl" :: "adv" :: "choice" :: "lane" :: "engawa" :: "night" :: "morning" :: "log" :: "save" :: "load" :: "settings" :: "ask" :: "credits" :: Nil

    /// 名前 → 描き出しと同じ初めの World（initialOf）から組んだ場面の World。
    pub def worldOf(name: String, res: Res.Res): Option[World.World] = sceneOf(res, name, initialOf(res))

    /// 名前 → その場面の World。時計は秒で据える（蛍もクレジットも実時間から導くので、据えれば毎回同じ絵）。
    def sceneOf(res: Res.Res, name: String, w0: World.World): Option[World.World] =
        match name {
            // タイトル画面: 夕暮れの駅の写真に題とメニュー。
            case "title"    => Some(at(3.0, w0))
            // NVL: 最初の頁。蜩（ひぐらし）のルビが載った 3 行目まで出した所。
            case "nvl"      => Some(at(4.0, nthLine(res, "Station", 2, w0)))
            // ADV: 田んぼの畦道で千夏が振り返る台詞。
            case "adv"      => Some(at(4.0, nthLine(res, "Paddy", 3, w0)))
            // 選択肢: 千夏の呼び方を選ぶ所。
            case "choice"   => Some(at(4.0, toChoices(res, "Paddy", YarnStorage.empty(), w0)))
            // 坂道: 夕暮れの坂の上の家（ADV）。
            case "lane"     => Some(at(4.0, nthLine(res, "Lane", 2, w0)))
            // 縁側: 夜の祖母の家（風鈴が鳴った後）。
            case "engawa"   => Some(at(4.0, nthLine(res, "Engawa", 3, w0)))
            // 朝: 駅へ戻る朝（NVL）。
            case "morning"  => Some(at(4.0, nthLine(res, "Morning", 1, w0)))
            // 夜: 蛍の川で、条件つきの選択肢が選べる所（$closeness = 2）。
            case "night"    =>
                let storage = YarnStorage.withArgs(Map#{ "$closeness" => "2" }, res#dialogue, YarnStorage.empty()) |> Result.getWithDefault(YarnStorage.empty());
                Some(at(6.5, toChoices(res, "River", storage, w0)))
            // バックログ: 縁側の選択肢まで読んでから開き、田んぼの台詞に触れている所（その行へ戻れると明るくなる）。
            case "log"      =>
                let w = quiet(() -> WorldLog.openLog(readThrough(res, w0)));
                Some(at(4.0, { pointer = { x = 400.0, y = 300.0 } | w }))
            // セーブ: 読んでいる途中で開いたセーブ画面（1 ページ目に 3 つ。いちばん新しい物に NEW）。
            case "save"     => Some(at(4.0, quiet(() -> WorldSaves.openSave(withSlots(res, nthLine(res, "River", 2, w0))))))
            // ロード: タイトルから開いたロード画面（いちばん新しいデータのページ）。
            case "load"     => Some(at(4.0, quiet(() -> WorldSaves.openLoad(World.toTitle(withSlots(res, w0))))))
            // 設定: 読んでいる途中で開いた設定（見本の文が流れている所）。
            case "settings" => Some(at(1.2, quiet(() -> WorldSettings.openSettings(nthLine(res, "Paddy", 3, w0)))))
            // 確認のウィンドウ: ADV の台詞の上で「タイトルに戻りますか？」。
            case "ask"      => Some(at(4.0, quiet(() -> World.askFor(World.Ask.ToTitle, nthLine(res, "Lane", 2, w0)))))
            // クレジット: 流れ始めて 12 秒（写真の出典が見えている所）。
            case "credits"  => Some(at(12.0, World.toCredits(res, w0)))
            case _          => None
        }

    /// 物語の時計と実時間の今を、どちらも seconds 秒に据える。
    def at(seconds: Float64, w: World.World): World.World =
        { storyClock = Clock.startAt(seconds), realNow = Clock.after(seconds, Clock.zero()) | w }

    def quiet(f: Unit -> World.World \ Emit[World.Event]): World.World = fst(Emit.collect(f))

    /// node の上から n 番目（0 から）の台詞を出し終えた所（その行までのコマンドは反映して、演出は終わりの形）。
    def nthLine(res: Res.Res, node: String, n: Int32, w: World.World): World.World =
        let line = Yarn.nodeOf(node, res#dialogue)
            |> Option.map(found -> found#body |> List.filterMap(statement -> match statement {
                   case Yarn.Statement.Say(say) => Some(say#source#line)
                   case _                       => None
               }))
            |> Option.flatMap(List.nth(n)) |> Option.getWithDefault(0);
        WorldRead.revealLine(quiet(() -> WorldRead.openAt(res, YarnStorage.empty(), node, line, w)))

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
        w |> saveAt(-2900i64, 0, nthLine(res, "Paddy", 3, w))
          |> saveAt(-2860i64, 1, nthLine(res, "Lane", 2, w))
          |> saveAt(-12i64, 2, nthLine(res, "Engawa", 4, w))
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
            case Some(until) => quiet(() -> WorldRead.step(res, { storyClock = Clock.startAt(Clock.secondsOf(until)) | w }))
            case None        => w
        }
}
