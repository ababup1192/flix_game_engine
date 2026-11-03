// Shots — ギャラリーの場面（make render-all の 1 枚）の World を組む。描き出し（SceneRender）と実機（Game の App.withShots。
// START=shot:<場面>）が同じ関数で組むので、実機で開いた場面はギャラリーの絵と同じ World から始まる。
// WhyNot: 描き出しの物（HeadlessRender・HeadlessFont・java.io）を引かない — Game.app から engine_tools へつながり、ブラウザ版で組めなくなる。
mod Shots {
    use fge::{Clock, Dir4, Emit, Resources}

    /// 描き出せる場面の名前。make render の使い方も SHOT の当たり判定も、この並びが source of truth。
    /// 場面を足したら、ここと worldOf と Makefile の SHOTS を一緒に足す。
    pub def names(): List[String] =
        "title" :: "village" :: "quest" :: "join" :: "world" :: "cave" :: "dungeon1" :: "dungeon2" :: "dungeon3" ::
        "battle" :: "magic" :: "item" :: "equip" :: "boss" :: "clear" :: "ending" :: Nil

    /// 描き出す時刻（秒）。WhyNot: 実時間を使わない — 点滅や水のゆれのコマが毎回変わり、
    /// 同じ PNG が出なくなる。0.25 秒はカーソルが見えていて、歩きが 1 コマ目の時刻。
    def shotTime(): Float64 = 0.25

    /// 名前 → Starts で組んで決まった手を進めた World（World から描ける場面だけ）。
    pub def worldOf(name: String, res: Res.Res): Option[World.World] =
        let at = w -> { realNow = Clock.after(shotTime(), Clock.zero()) | w };
        match name {
            case "title"   => started(res, "title", Map.empty()) |> Option.map(at)
            case "village" => started(res, "field", Map#{"map" => "village", "x" => "6", "y" => "11", "facing" => "up"}) |> Option.map(at)
            // 依頼の台詞を出し切り、送って はい / いいえ を出した所。
            case "quest"   => started(res, "talk", Map#{"node" => "ChiefQuest", "map" => "chief_house", "x" => "7", "y" => "5", "facing" => "up"})
                |> Option.map(confirmTimes(res, 2)) |> Option.map(at)
            // 依頼を受けた後に鍛冶屋の前でミナに話しかけ、ミナの台詞を送って「ミナが なかまに くわわった！」を出し切った所。
            case "join"    => started(res, "talk", Map#{"node" => "Mina", "map" => "smithy", "x" => "3", "y" => "6", "facing" => "up", "quest" => "accepted"})
                |> Option.map(confirmTimes(res, 3)) |> Option.map(at)
            // 村でメニューを開き、どうぐ（2 行目の右）を選んだ所。
            case "item"    => started(res, "field", Map#{"map" => "village", "x" => "7", "y" => "8", "facing" => "down", "party" => "luka,mina",
                                                       "quest" => "accepted", "gold" => "120", "items" => "yakusou:3,seisui:2,maryoku:1,taimatsu:2"})
                |> Option.map(openItems(res)) |> Option.map(at)
            // 村でメニューを開き、そうび → ルカ と進めて、ぶき / よろい の一覧とつよさのウィンドウを出した所。
            case "equip"   => started(res, "field", Map#{"map" => "village", "x" => "7", "y" => "8", "facing" => "down", "party" => "luka,mina,toto",
                                                       "quest" => "accepted", "gold" => "120", "items" => "dounotsurugi:1,kawanoyoroi:1,mahounorobe:1"})
                |> Option.map(openEquipSlots(res)) |> Option.map(at)
            // ワールドマップ: 3 人で橋の手前から北へ 2 マス歩き、橋の上に立った所（坑道の入口・川・ほこらが映る）。
            case "world"   => started(res, "field", Map#{"map" => "world", "x" => "20", "y" => "12", "facing" => "up", "party" => "luka,mina,toto", "quest" => "accepted"})
                |> Option.map(walk(res, Dir4.Dir4.Up, 2)) |> Option.map(at)
            // 森の岩穴: 入口の部屋から北へ 2 マス歩き、鉄格子（閉）と右の壁のレバー・奥のほりモグが映る所。
            case "cave"     => started(res, "field", Map#{"map" => "toto_cave", "x" => "8", "y" => "11", "facing" => "up", "party" => "luka,mina", "quest" => "accepted"})
                |> Option.map(walk(res, Dir4.Dir4.Up, 2)) |> Option.map(at)
            // 坑道 B1: 分岐の広間を東へ 2 マス歩き、トロッコの駅の前に立った所（壁のレバー・トロッコ・分かれ目・北と南へ分かれるレール・岩の部屋の入口が映る）。
            case "dungeon1" => started(res, "field", Map#{"map" => "mine_b1", "x" => "6", "y" => "16", "facing" => "right", "party" => "luka,mina,toto", "quest" => "accepted"})
                |> Option.map(walk(res, Dir4.Dir4.Right, 2)) |> Option.map(at)
            // 坑道 B2: 暗い迷路でたいまつを灯し、南へ 2 マス歩いた所（明かりの中だけ見え、先の割れた床が明かりの縁に入る）。
            case "dungeon2" => started(res, "field", Map#{"map" => "mine_b2", "x" => "19", "y" => "9", "facing" => "down", "party" => "luka,mina,toto", "quest" => "accepted", "light" => "60"})
                |> Option.map(walk(res, Dir4.Dir4.Down, 2)) |> Option.map(at)
            // 坑道 B3: 水晶を 3 つ点けて飛び石が現れた湖を、南の岸から北へ 2 マス渡った所（小島の宝箱・飛び石・点いた水晶が映る）。
            case "dungeon3" => started(res, "field", Map#{"map" => "mine_b3", "x" => "16", "y" => "21", "facing" => "up", "party" => "luka,mina,toto", "quest" => "accepted",
                                                          "flags" => "b3_crystals", "opened" => "b3_crystal_e,b3_crystal_w,b3_crystal_n"})
                |> Option.map(walk(res, Dir4.Dir4.Up, 2)) |> Option.map(at)
            // 坑道 B1 で 3 体と出会い、「あらわれた！」を送ってルカのコマンドを選ぶ所。
            case "battle"   => started(res, "battle", Map#{"foes" => "koke,koumori,goblin", "map" => "mine_b1", "x" => "4", "y" => "16", "facing" => "right",
                                                         "party" => "luka,mina,toto", "quest" => "accepted", "lv" => "3"})
                |> Option.map(confirmUntilChoose(res, 4)) |> Option.map(at)
            // 同じ組で、ルカとミナが たたかう・トトが じゅもん → ファイア → 先頭の敵 と選び、ファイアの演出の半ばまで進めた所。
            case "magic"    => started(res, "battle", Map#{"foes" => "koke,koumori,goblin", "map" => "mine_b1", "x" => "4", "y" => "16", "facing" => "right",
                                                         "party" => "luka,mina,toto", "quest" => "accepted", "lv" => "3"})
                |> Option.map(confirmUntilChoose(res, 4)) |> Option.map(castFire(res)) |> Option.map(at)
            // 坑道 B3 の扉の奥でジェムイーターと出会い、「ジェムイーターが あらわれた！」を出し切った所（地底湖の背景）。
            case "boss"     => started(res, "battle", Map#{"foes" => "gemeater", "map" => "mine_b3", "x" => "16", "y" => "6", "facing" => "up",
                                                         "party" => "luka,mina,toto", "quest" => "accepted", "lv" => "6", "opened" => "b3_door"})
                |> Option.map(playSeconds(res, 1.0)) |> Option.map(at)
            // ボスを倒して村へ帰り、泉の上の村長に報告して「いずみに みずが もどった！ 〜G を うけとった」を出し切った所
            // （水の戻った泉と、まわりに集まった村人）。
            case "clear"    => started(res, "talk", Map#{"node" => "ChiefReport", "map" => "village", "x" => "8", "y" => "5", "facing" => "left",
                                                       "party" => "luka,mina,toto", "quest" => "bossdown", "trail" => "9:5,10:5"})
                |> Option.map(confirmTimes(res, 5)) |> Option.map(at)
            // エンディング: 報告を終えた村を下敷きに、スタッフの字が 3 割ほど流れた所。
            case "ending"   => started(res, "ending", Map#{"map" => "village", "x" => "8", "y" => "5", "facing" => "left", "party" => "luka,mina,toto",
                                                        "quest" => "reported", "lv" => "7", "gold" => "640", "trail" => "9:5,10:5"})
                |> Option.map(w -> playSeconds(res, RulesDoc.rec(res#rules)#creditSeconds * 0.3, w)) |> Option.map(at)
            case _         => None
        }

    /// 遊びの時計を seconds 秒ぶん、キーを押さずに進めた所（実機と同じ道。Drive.play）。
    def playSeconds(res: Res.Res, seconds: Float64, w: World.World): World.World =
        let frames = Float64.floor(seconds * 60.0) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        Drive.play(List.repeat(frames, Set.empty()), Resources.of(res, w))#world

    /// ルカとミナは たたかう（先頭の敵）・トトは じゅもん の 1 つ目を先頭の敵へ。ファイアの演出の Beat まで伝言を送り、
    /// 演出の半ばまで遊びの時計を進めた所（音の出来事は捨てる）。
    def castFire(res: Res.Res, w: World.World): World.World =
        let chosen = fst(Emit.collect(() -> w |> WorldBattle.confirm(res) |> WorldBattle.confirm(res)
                                              |> WorldBattle.confirm(res) |> WorldBattle.confirm(res)
                                              |> WorldBattle.move(res, 1) |> WorldBattle.confirm(res) |> WorldBattle.confirm(res) |> WorldBattle.confirm(res)));
        let atSpell = untilSpellBeat(res, 12, chosen);
        let half = Float64.floor(RulesDoc.rec(res#rules)#fxSeconds * 0.3 * 60.0) |> Float64.tryToInt32 |> Option.getWithDefault(7);
        Drive.play(List.repeat(half, Set.empty()), Resources.of(res, atSpell))#world

    /// 呪文の演出のある Beat を見せている所まで伝言を送る（n 回まで）。
    def untilSpellBeat(res: Res.Res, n: Int32, w: World.World): World.World =
        let isSpell = World.battleRecOf(w) |> Option.flatMap(WorldBattle.currentBeatOf) |> Option.flatMap(pair -> Battle.beatRecOf(fst(pair))#fx)
            |> Option.exists(fx -> match fx#kind {
                case Battle.FxKind.Spell(_) => true
                case _                      => false
            });
        if (n <= 0 or isSpell) w
        else untilSpellBeat(res, n - 1, fst(Emit.collect(() -> WorldBattle.confirmMessage(res, w) |> WorldBattle.confirmMessage(res))))

    /// 戦いの伝言を決定で送り、コマンドを選ぶ番になった所（n 回まで。音の出来事は捨てる）。
    def confirmUntilChoose(res: Res.Res, n: Int32, w: World.World): World.World =
        if (n <= 0 or Option.nonEmpty(WorldBattle.choosingOf(w))) w
        else confirmUntilChoose(res, n - 1, fst(Emit.collect(() -> WorldBattle.confirmMessage(res, w))))

    /// dir へ n マス歩いた所（実機と同じ道でキーを流す。Drive.walkKeys）。
    def walk(res: Res.Res, dir: Dir4.Dir4, n: Int32, w: World.World): World.World =
        Drive.play(Drive.walkKeys(res, dir, n), Resources.of(res, w))#world

    /// メニューを開き、カーソルを下・右へ動かして どうぐ を選んだ所（音の出来事は捨てる）。
    def openItems(res: Res.Res, w: World.World): World.World =
        fst(Emit.collect(() -> WorldMenu.open(w) |> WorldMenu.move(res, Dir4.Dir4.Down) |> WorldMenu.move(res, Dir4.Dir4.Right)
                                                 |> WorldMenu.confirm(res)))

    /// メニューを開き、カーソルを下へ 2 つ動かして そうび → 先頭の仲間 を選んだ所（音の出来事は捨てる）。
    def openEquipSlots(res: Res.Res, w: World.World): World.World =
        fst(Emit.collect(() -> WorldMenu.open(w) |> WorldMenu.move(res, Dir4.Dir4.Down) |> WorldMenu.move(res, Dir4.Dir4.Down)
                                                 |> WorldMenu.confirm(res) |> WorldMenu.confirm(res)))

    /// 会話を決定で n 回送った所（音の出来事は捨てる）。
    def confirmTimes(res: Res.Res, n: Int32, w: World.World): World.World =
        if (n <= 0) w else confirmTimes(res, n - 1, fst(Emit.collect(() -> WorldTalk.confirm(res, w))))

    def started(res: Res.Res, name: String, args: Map[String, String]): Option[World.World] =
        Starts.all() |> List.find(s -> s#name == name)
            |> Option.flatMap(s -> s#build(res, World.initial(None), args) |> Result.toOption)
}
