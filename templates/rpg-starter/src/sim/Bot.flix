// Bot — 自動の通しプレイの方針（すべて純粋）。毎フレーム World を見て、押すキーを 1 組決める。
// 手は実機と同じ経路（BotRun が App.traceFrame で Game.app へ流す）なので、入力の層・門・ウィンドウの詰まりもそのまま出る。
//
// 何をするかは goalOf（依頼の段階・仲間・ふくろ・装備から「次の目的地と、着いたらする事」）。先に割り込み（interruptOf）:
//   ふくろに付けられる良い装備 → そうび / 村の外で HP が 60% 未満 → 回復 / 村で HP が 60% 未満の人がいる → 宿。
// 無ければ道筋の表（stepsOf）の最初の済んでいない行:
//   依頼の前 → 村長 / ミナがいない → 鍛冶屋の前のミナ / どうのつるぎを買っていない → 道具屋 /
//   トトがいない: 森の岩穴のレバー → ほりモグ（固定の戦い）→ ほこらのトトに杖を返す /
//   B1 の かわのよろい → てつのつるはし（北の行き止まり）→ 岩の部屋 1（押す手は rockPlanOf）→ 小部屋の宝箱 /
//   B2 の たいまつ → ふるびたかぎ → まほうのローブ → くろがねゴブリン（固定の戦い）→ はがねのつるぎ /
//   B3 で HP が 60% 未満ならミナの父に話す → 岩の部屋 2 → ばくだんいし → ひとくいばこ（固定の戦い）→ 水晶を order の順に →
//   小島の みずのはごろも → 封じられた扉を開ける → HP か MP が減っていればミナの父の全快 → 奥のジェムイーター（固定の戦い）/
//   ボスを倒した後（坑道の入口へ戻される）→ ワールドマップを歩いて村へ → 泉の上の村長に報告 → エンディングの字が流れ切ったら決定でタイトルへ（そこで終わり）
// 歩き: マップの間は exits をつないだ図の最短、マップの中は GridSearch.distances（通れるかは規則と同じ WorldField.canEnter）。
//   目的のマスへ歩いて着けない時は寄り道（detourOf）: 乗れば着くトロッコに乗り、無ければ、動かせば乗れば着くようになる分かれ目のレバーを動かす。
//   落とし穴（目的でない出入口のマス）は踏まない。
// 戦い: battlePlans（HP が 35% 未満の仲間を回復の呪文 → やくそう で回復・逃げられない組では攻めの呪文 → ばくだんいし・
//   ほかは HP の一番少ない敵を たたかう。にげない）。村の外で HP が 60% 未満なら、フィールドで回復の呪文 → やくそう。
// 会話: 文字送りは決定で進め、はい / いいえ は「はい」（先頭）。
mod Bot {
    use fge::{Dir4, Grid, GridSearch}
    use fge::GameEngine.Key
    use World.{CommandPage, MenuPage, ShopMode, ShopPage}

    // ── 目的 ──

    /// 着いたらする事。Talk = その人に話しかける / Examine = 物（宝箱・レバー・番をする者・トロッコ・水晶）を調べる / Reach = そのマスに立つ（着いたら終わり）/
    /// Push(岩の id, x, y, 向き) = (x, y) にある岩をその向きへ 1 マス押す（岩の手前のマスで押す）。
    pub enum Aim with Eq, ToString {
        case Talk(String)
        case Examine(String)
        case Reach(Int32, Int32)
        case Push(String, Int32, Int32, Dir4.Dir4)
    }

    /// 次の目的。Go = マップ（名前）へ行って Aim する / Equip = メニューのそうびで付け替える（仲間・置き場・道具）/
    /// Heal = メニューのどうぐで、その仲間にその道具を使う（坑道で HP が減った時の やくそう）/
    /// Cast = メニューのじゅもんで、唱える人がその仲間にその呪文を唱える（やくそうより先に回復の呪文）。
    pub enum Goal with Eq, ToString {
        case Go(String, Aim)
        case Equip(Member.Member, Party.Slot, ItemsDoc.ItemId)
        case Heal(Member.Member, ItemsDoc.ItemId)
        case Cast(Member.Member, Member.Member, SpellsDoc.SpellId)
    }

    /// 坑道の封じられた扉のあるマップ（扉を開け、奥のボスを調べる）。
    def doorMap(): String = "mine_b3"

    /// ボスの敵の鍵（BotRun がボス戦を区間に分ける）。
    pub def bossFoe(): String = "gemeater"

    /// 岩を押す 1 手: 岩の id・押す前の岩のマス・押す向き。
    type alias Push = { rock = String, x = Int32, y = Int32, dir = Dir4.Dir4 }

    /// 岩の部屋の押す手（旗 → マップと手の並び。知らない旗は None）。
    def rockPlanOf(flag: String): Option[(String, List[Push])] =
        let push = (rock, x, y, dir) -> { rock = rock, x = x, y = y, dir = dir };
        match flag {
            case "b1_room" => Some(("mine_b1", push("b1_rock", 14, 24, Dir4.Dir4.Right) :: push("b1_rock", 15, 24, Dir4.Dir4.Right) :: Nil))
            case "b3_room" => Some(("mine_b3", push("b3_rock_b", 24, 25, Dir4.Dir4.Right) :: push("b3_rock_b", 25, 25, Dir4.Dir4.Right) ::
                                               push("b3_rock_a", 23, 26, Dir4.Dir4.Down) :: push("b3_rock_a", 23, 27, Dir4.Dir4.Right) ::
                                               push("b3_rock_a", 24, 27, Dir4.Dir4.Right) :: push("b3_rock_a", 25, 27, Dir4.Dir4.Right) :: Nil))
            case _         => None
        }

    /// map の岩 id の今のマス（いるマップなら動かした今のマス、ほかのマップなら Doc の位置）。
    def rockCellNow(res: Res.Res, w: World.World, map: String, id: String): Option[(Int32, Int32)] =
        let moved = World.fieldRecOf(w) |> Option.filter(r -> MapDoc.nameOf(r#map) == map)
            |> Option.flatMap(r -> MapDoc.docOf(res#maps, r#map) |> Option.flatMap(doc ->
                WorldObject.objectsNow(doc, r, w#progress) |> List.find(p -> p#object#id == id) |> Option.map(p -> (p#cell#x, p#cell#y))));
        let placed = Map.get(map, res#maps) |> Option.flatMap(doc -> MapDoc.rec(doc)#objects |> List.find(o -> o#id == id)) |> Option.map(o -> (o#x, o#y));
        Option.withDefault(default = placed, moved)

    /// 次の 1 手: 岩が手の「押す前のマス」にいる手（押し終えた手は飛ばされる）。どの手にも当たらなければ最初の手。
    def nextPush(res: Res.Res, w: World.World, map: String, plan: List[Push]): Option[Push] =
        plan |> List.find(p -> rockCellNow(res, w, map, p#rock) == Some((p#x, p#y))) |> Option.withDefault(default = List.head(plan))

    /// 岩の部屋（旗 flag）の次の 1 手へ向かう目的。
    def pushOf(res: Res.Res, flag: String, w: World.World): Option[Goal] =
        forM ((map, plan) <- rockPlanOf(flag); p <- nextPush(res, w, map, plan)) yield Goal.Go(map, Aim.Push(p#rock, p#x, p#y, p#dir))

    /// 名前の旗が立っているか。
    def isFlagNamed(name: String, w: World.World): Bool =
        Flag.listOfArg(name) |> List.head |> Option.exists(flag -> Progress.isFlagSet(flag, w#progress))

    /// map の水晶のうち、まだ点けていない一番小さい order の物の id（全部点いていれば None）。
    def nextCrystalOf(res: Res.Res, map: String, w: World.World): Option[String] =
        let rows = Map.get(map, res#maps) |> Option.map(doc -> MapDoc.rec(doc)#objects) |> Option.getWithDefault(Nil);
        rows |> List.filterMap(o -> match o#kind {
            case MapDoc.ObjectKind.Crystal(c) => Some((c#order, o#id))
            case _                            => None
        }) |> List.filter(pair -> not isOpenedIn(res, map, snd(pair), w))
            |> List.sortBy(fst) |> List.head |> Option.map(snd)

    /// 村の中のマップ（宿へ寄ってよい所）。
    def villageMaps(): Set[String] = Set#{"village", "inn", "shop", "chief_house", "smithy"}

    /// 道筋の 1 行: done = もう済んだか / goal = 済んでいない時に向かう目的（None なら次の行へ）。
    /// WhyNot: goal を World から決める関数にする — 岩の部屋の次の手と次の水晶は、今の岩の位置と点けた水晶で変わる。
    type alias Step = { done = World.World -> Bool, goal = World.World -> Option[Goal] }

    /// 次の目的: 割り込み（interruptOf）があればそれ、無ければ道筋（stepsOf）の最初の済んでいない行。全部済めば村長に報告する。
    pub def goalOf(res: Res.Res, w: World.World): Goal =
        interruptOf(res, w)
            |> Option.withDefault(default = stepsOf(res) |> List.findMap(step -> if (step#done(w)) None else step#goal(w)))
            |> Option.getWithDefault(Goal.Go("village", Aim.Talk("chief_spring")))

    /// 道筋より先にする事: ふくろに付けられる良い装備 → 村の外で HP が 60% 未満なら回復 → 村で HP が 60% 未満でお金があれば宿。
    def interruptOf(res: Res.Res, w: World.World): Option[Goal] =
        let inVillage = Set.memberOf(hereOf(w), villageMaps());
        let inn = inVillage and isTired(res, w) and Bag.goldOf(w#bag) >= ShopsDoc.rec(res#shops)#innPrice;
        upgradeOf(res, w)
            |> Option.withDefault(default = if (inVillage) None else healOf(res, w))
            |> Option.withDefault(default = if (inn) Some(Goal.Go("inn", Aim.Talk("innkeeper"))) else None)

    /// 道筋（上の行ほど先）。
    def stepsOf(res: Res.Res): List[Step] =
        let door = doorMap();
        let go = (map, aim) -> (_: World.World) -> Some(Goal.Go(map, aim));
        let accepted = w -> Progress.rec(w#progress)#quest == Quest.Quest.Accepted;
        let joined = (m, w) -> Party.hasJoined(m, w#party);
        let has = (name, w) -> ItemsDoc.idOf(res#items, name) |> Option.exists(id -> Bag.countOf(id, w#bag) > 0);
        let totoReady = w -> joined(Member.Member.Toto, w) or has("totostaff", w);
        { done = w -> Progress.rec(w#progress)#quest != Quest.Quest.NotAsked, goal = go("chief_house", Aim.Talk("chief")) } ::
        { done = w -> joined(Member.Member.Mina, w),                           goal = go("smithy", Aim.Talk("mina")) } ::
        { done = w -> not wantsSword(res, w),                                  goal = go("shop", Aim.Talk("shopkeeper")) } ::
        { done = w -> totoReady(w) or flagRaisedBy(res, "toto_cave", "cave_lever", w), goal = go("toto_cave", Aim.Examine("cave_lever")) } ::
        { done = totoReady,                                                    goal = go("toto_cave", Aim.Examine("cave_mole")) } ::
        { done = w -> joined(Member.Member.Toto, w),                           goal = go("world", Aim.Talk("toto")) } ::
        examineUntilOpened(res, "mine_b1", "b1_kawa") ::
        examineUntilOpened(res, "mine_b1", "b1_pick") ::
        { done = w -> isFlagNamed("b1_room", w),                              goal = pushOf(res, "b1_room") } ::
        examineUntilOpened(res, "mine_b1", "b1_reward") ::
        examineUntilOpened(res, "mine_b2", "b2_torch") ::
        { done = w -> has("furubitakagi", w),                                  goal = go("mine_b2", Aim.Examine("b2_kagi")) } ::
        examineUntilOpened(res, "mine_b2", "b2_robe") ::
        examineUntilOpened(res, "mine_b2", "b2_kurogane") ::
        examineUntilOpened(res, "mine_b2", "b2_sword") ::
        { done = w -> not (hereOf(w) == "mine_b3" and isTired(res, w)),        goal = go("mine_b3", Aim.Talk("mina_father")) } ::
        { done = w -> isFlagNamed("b3_room", w),                               goal = pushOf(res, "b3_room") } ::
        examineUntilOpened(res, "mine_b3", "b3_bomb") ::
        examineUntilOpened(res, "mine_b3", "b3_mimic") ::
        { done = w -> isFlagNamed("b3_crystals", w),                           goal = w -> nextCrystalOf(res, "mine_b3", w) |> Option.map(id -> Goal.Go("mine_b3", Aim.Examine(id))) } ::
        examineUntilOpened(res, "mine_b3", "b3_robe") ::
        { done = w -> not accepted(w) or isOpenedIn(res, door, "b3_door", w),  goal = go(door, Aim.Examine("b3_door")) } ::
        { done = w -> not (accepted(w) and hereOf(w) == door and isWorn(res, w)), goal = go(door, Aim.Talk("mina_father")) } ::
        { done = w -> not accepted(w),                                         goal = go(door, Aim.Examine("b3_boss")) } :: Nil

    /// map の物 id を開けるまで調べる行（宝箱・番をする者）。
    def examineUntilOpened(res: Res.Res, map: String, id: String): Step =
        { done = w -> isOpenedIn(res, map, id, w), goal = _ -> Some(Goal.Go(map, Aim.Examine(id))) }

    /// map の物 id を開けたか。
    def isOpenedIn(res: Res.Res, map: String, id: String, w: World.World): Bool =
        MapDoc.idOf(res#maps, map) |> Option.exists(m -> Progress.isOpened(m, id, w#progress))

    /// いるマップの名前（フィールドでなければ空）。
    def hereOf(w: World.World): String =
        World.fieldRecOf(w) |> Option.map(r -> MapDoc.nameOf(r#map)) |> Option.getWithDefault("")

    /// map の id のレバーの旗が立っているか（レバーが無ければ false）。
    def flagRaisedBy(res: Res.Res, map: String, id: String, w: World.World): Bool =
        Map.get(map, res#maps) |> Option.flatMap(doc -> MapDoc.rec(doc)#objects |> List.find(o -> o#id == id))
            |> Option.flatMap(o -> MapDoc.profileOf(o#kind)#raises)
            |> Option.exists(flag -> Progress.isFlagSet(flag, w#progress))

    /// どうのつるぎ を買う（ルカが付けていない・ふくろに無い・お金が足りる）。
    def wantsSword(res: Res.Res, w: World.World): Bool =
        match ItemsDoc.idOf(res#items, "dounotsurugi") {
            case None     => false
            case Some(id) =>
                let price = ItemsDoc.itemOf(res#items, id) |> Option.map(i -> i#price) |> Option.getWithDefault(0);
                Party.equipOf(Member.Member.Luka, Party.Slot.Weapon, w#party) != Some(id) and Bag.countOf(id, w#bag) == 0 and Bag.goldOf(w#bag) >= price
        }

    /// 村の外で、生きている仲間の HP が最大の 60% 未満なら、一番減っている人に回復の呪文（フィールドで唱えられ、MP の足りる人が居れば）、
    /// 無ければ やくそう（ふくろにあれば）。
    def healOf(res: Res.Res, w: World.World): Option[Goal] =
        let herb = ItemsDoc.idOf(res#items, "yakusou") |> Option.filter(id -> Bag.countOf(id, w#bag) > 0);
        let ratioOf = (m, s) -> Int32.toFloat64(s#hp) / Int32.toFloat64(Int32.max(1, Party.maxHpOf(res#party, m, w#party)));
        let hurt = Party.statsList(w#party) |> List.filter(match (_, s) -> s#hp > 0)
            |> List.map(match (m, s) -> (ratioOf(m, s), m)) |> List.filter(pair -> fst(pair) < 0.6)
            |> List.sortBy(fst) |> List.head |> Option.map(snd);
        let caster = Party.aliveOf(w#party) |> List.findMap(m -> healSpellOf(res, m, w#party) |> Option.map(id -> (m, id)));
        let byCast = forM (m <- hurt; (who, id) <- caster) yield Goal.Cast(who, m, id);
        Option.withDefault(default = forM (id <- herb; m <- hurt) yield Goal.Heal(m, id), byCast)

    /// m が今の MP で唱えられる、フィールドで唱えられる回復の呪文。
    def healSpellOf(res: Res.Res, m: Member.Member, party: Party.Party): Option[SpellsDoc.SpellId] =
        Party.spellsOf(res#party, res#spells, m, party) |> List.find(id -> SpellsDoc.spellOf(res#spells, id)
            |> Option.exists(s -> s#field and s#aim == SpellsDoc.Aim.Ally and Party.mpOf(m, party) >= s#mp))

    /// 誰かの HP が最大の 60% 未満か。
    def isTired(res: Res.Res, w: World.World): Bool =
        Party.statsList(w#party) |> List.exists(match (m, s) -> Int32.toFloat64(s#hp) < 0.6 * Int32.toFloat64(Party.maxHpOf(res#party, m, w#party)))

    /// ふくろの中に、今の物より ちから + みのまもり の多い付けられる物があれば、その付け替え。
    def upgradeOf(res: Res.Res, w: World.World): Option[Goal] =
        let bonusOf = id -> ItemsDoc.itemOf(res#items, id) |> Option.map(i -> i#atk + i#defense) |> Option.getWithDefault(0);
        Party.membersOf(w#party) |> List.flatMap(m -> Party.slots() |> List.map(slot -> (m, slot)))
            |> List.filterMap(match (m, slot) -> {
                let now = Party.equipOf(m, slot, w#party) |> Option.map(bonusOf) |> Option.getWithDefault(0);
                WorldMenu.candidatesOf(res, m, slot, w#bag) |> List.filterMap(x -> x)
                    |> List.filter(id -> bonusOf(id) > now)
                    |> List.map(id -> (bonusOf(id), id)) |> List.sortBy(fst) |> List.reverse |> List.head
                    |> Option.map(match (_, id) -> Goal.Equip(m, slot, id))
            })
            |> List.head

    // ── 道 ──

    /// 目標のマスに着いた所でする事。Stand = 立つだけ（出入口のマス・Reach）/ Face = その向きを向いて決定（話す・調べる）/
    /// Push = その向きを押す（マップの端の出入口から外へ出る）。
    enum Arrive with Eq {
        case Stand
        case Face(Dir4.Dir4)
        case Push(Dir4.Dir4)
    }

    /// マップの中の道: どのマップ・どの目的の、マスごとの残りのマス数と、着いた所でする事（Stand は持たない）。
    pub type alias Route = { key = String, dist = Map[(Int32, Int32), Int32], arrive = Map[(Int32, Int32), Arrive] }

    /// マップの間の図で、from から goal へ行く最初の出入口（同じマップなら None）と、残りの出入口の数。
    def nextExitOf(res: Res.Res, start: String, goal: String): Option[(MapDoc.Exit, Int32)] =
        if (start == goal) None else hopsFrom(res, goal, (start, Nil) :: Nil, Set#{start})

    /// 歩いて通れる出入口か（会話の <<warp>> だけが通る edge = none の出入口は図に入れない）。
    def isWalkable(exit: MapDoc.Exit): Bool = match exit#place {
        case MapDoc.ExitPlace.Cell(_, _) => true
        case MapDoc.ExitPlace.Edge(_)    => true
        case MapDoc.ExitPlace.Nowhere    => false
    }

    /// 幅優先: 行けるマップを順に広げ、goal に着いたら最初の出入口と出入口の数。
    def hopsFrom(res: Res.Res, goal: String, todo: List[(String, List[MapDoc.Exit])], seen: Set[String]): Option[(MapDoc.Exit, Int32)] =
        match todo {
            case Nil => None
            case (map, path) :: rest =>
                if (map == goal) List.reverse(path) |> List.head |> Option.map(first -> (first, List.length(path)))
                else {
                    let exits = Map.get(map, res#maps) |> Option.map(d -> MapDoc.rec(d)#exits) |> Option.getWithDefault(Nil)
                        |> List.filter(e -> not Set.memberOf(e#to, seen) and isWalkable(e));
                    let nextSeen = exits |> List.foldLeft((acc, e) -> Set.insert(e#to, acc), seen);
                    hopsFrom(res, goal, List.append(rest, exits |> List.map(e -> (e#to, e :: path))), nextSeen)
                }
        }

    /// 今いるマップの中の目標のマスと、着いた所でする事。マップの間を移る時は最初の出入口のマス（端の出入口はその辺の立てるマス）。
    def targetsOf(res: Res.Res, map: MapDoc.Doc, here: String, goal: Goal): (List[((Int32, Int32), Arrive)], Int32) =
        match goal {
            case Goal.Equip(_, _, _) => (Nil, 0)
            case Goal.Heal(_, _)     => (Nil, 0)
            case Goal.Cast(_, _, _)  => (Nil, 0)
            case Goal.Go(dest, aim) =>
                match nextExitOf(res, here, dest) {
                    case Some((exit, hops)) => (exitCellsOf(map, exit), hops)
                    case None if here == dest => (aimCellsOf(map, aim), 0)
                    case None => (Nil, 99)
                }
        }

    /// 出入口を通るマス: マスの出入口はそのマス、端の出入口はその辺の全部のマスと、外へ押す向き。
    def exitCellsOf(map: MapDoc.Doc, exit: MapDoc.Exit): List[((Int32, Int32), Arrive)] =
        match MapDoc.cellOf(exit) {
            case Some(cell) => (cell, Arrive.Stand) :: Nil
            case None =>
                Grid.cellsOfRows(MapDoc.rec(map)#rows) |> List.map(fst) |> List.flatMap(cell -> Dir4.all()
                    |> List.filter(d -> MapDoc.edgeExitOf(cell#x, cell#y, d, map) |> Option.exists(e -> e#id == exit#id))
                    |> List.map(d -> ((cell#x, cell#y), Arrive.Push(d))))
        }

    /// 目的のマス: Talk はその人の隣（机の向こうなら 2 マス手前）、Open は物の隣、Reach はそのマス。
    def aimCellsOf(map: MapDoc.Doc, aim: Aim): List[((Int32, Int32), Arrive)] =
        let m = MapDoc.rec(map);
        let near = (x, y) -> Dir4.all() |> List.flatMap(d -> {
            let (dx, dy) = Dir4.delta(d);
            let one = (x - dx, y - dy);
            let two = (x - 2 * dx, y - 2 * dy);
            let counter = MapDoc.charAt(fst(one), snd(one), map) |> Option.exists(ch -> Tileset.passageOf(m#tileset, ch) == Tileset.Passage.Counter);
            (one, Arrive.Face(d)) :: (if (counter) (two, Arrive.Face(d)) :: Nil else Nil)
        });
        match aim {
            case Aim.Talk(id)    => m#npcs |> List.find(n -> n#id == id) |> Option.map(n -> near(n#x, n#y)) |> Option.getWithDefault(Nil)
            case Aim.Examine(id) => m#objects |> List.find(o -> o#id == id) |> Option.map(o -> near(o#x, o#y)) |> Option.getWithDefault(Nil)
            case Aim.Reach(x, y) => ((x, y), Arrive.Stand) :: Nil
            case Aim.Push(_, x, y, d) =>
                let (dx, dy) = Dir4.delta(d);
                ((x - dx, y - dy), Arrive.Push(d)) :: Nil
        }

    /// 道を引く（目標のマスを 0 とする幅優先。目標でない出入口のマスは通らない — 踏むと別のマップへ移る）。
    /// 先頭の今のマスは通れる事にする（トロッコを降りたレールの終わりは歩いて入れないマスだが、そこから出られる）。
    def routeOf(w: World.World, map: MapDoc.Doc, key: String, targets: List[((Int32, Int32), Arrive)]): Route =
        let occ = WorldField.occupancyOf(map, w);
        let goalCells = targets |> List.map(fst) |> List.toSet;
        let exits = MapDoc.rec(map)#exitAt;
        let hero = World.fieldRecOf(w) |> Option.map(r -> (r#hero#x, r#hero#y));
        let canEnter = cell -> Some(cell) == hero or ((Set.memberOf(cell, goalCells) or not Map.memberOf(cell, exits))
            and WorldField.canEnter(map, occ, { x = fst(cell), y = snd(cell) }));
        let sources = targets |> List.map(fst) |> List.filter(cell -> Map.memberOf(cell, exits) or canEnter(cell));
        { key = key, dist = GridSearch.distances(canEnter, sources, 4000),
          arrive = targets |> List.filter(t -> snd(t) != Arrive.Stand) |> List.toMap }

    // ── 状態 ──

    /// bot の値。route = 引いた道（マップか目的が変わった時だけ引き直す）、tapped = 前のフレームに決定などを押した（次は離す）。
    pub type alias State = { route = Option[Route], tapped = Bool }

    pub def initial(): State = { route = None, tapped = false }

    /// 今の目的地までの残り（出入口の数 × 100 + マップの中のマス数。道が無ければ 100000）。詰みの判定が比べる。
    pub def remainingOf(res: Res.Res, w: World.World, st: State): Int32 =
        match (World.fieldRecOf(w), st#route) {
            case (Some(r), Some(route)) =>
                let (_, hops) = MapDoc.docOf(res#maps, r#map) |> Option.map(map -> targetsOf(res, map, MapDoc.nameOf(r#map), goalOf(res, w))) |> Option.getWithDefault((Nil, 99));
                hops * 100 + Map.getWithDefault((r#hero#x, r#hero#y), 100000, route#dist)
            case _ => 100000
        }

    // ── キーを決める ──

    def keyOf(keys: List[Key]): Set[Key] = List.take(1, keys) |> List.toSet

    /// このフレームに押すキー。決定・取消のような 1 回押す物は、前のフレームに押していたら離す（押し直さないと効かない）。
    pub def decide(res: Res.Res, w: World.World, st: State): (Set[Key], State) =
        let k = KeysDoc.rec(res#keys);
        let tap = keys -> if (st#tapped) (Set.empty(), { tapped = false | st }) else (keyOf(keys), { tapped = true | st });
        match InputLayer.layerOf(w) {
            case InputLayer.Layer.Asking(_)       => tap(k#cancel)
            case InputLayer.Layer.Busy            => (Set.empty(), { tapped = false | st })
            case InputLayer.Layer.Title(_)        => tap(k#confirm)
            case InputLayer.Layer.Talk(_)         => tap(k#confirm)
            case InputLayer.Layer.Notice          => tap(k#confirm)
            case InputLayer.Layer.Shop(page)      => tap(shopKeys(res, w, k, page))
            case InputLayer.Layer.Menu(page)      => tap(menuKeys(res, w, k, page))
            case InputLayer.Layer.BattleMessage   => tap(k#confirm)
            case InputLayer.Layer.BattleChoose(m, page) => tap(battleKeys(res, w, k, m, page))
            case InputLayer.Layer.Walking         => walkKeys(res, w, k, st)
            case InputLayer.Layer.Ending if WorldTitle.creditProgressOf(res, w) >= 1.0 => tap(k#confirm)
            case InputLayer.Layer.Ending          => (Set.empty(), { tapped = false | st })
        }

    // ── 戦い ──

    /// m の行動（battlePlans）へ向けてページを進める: 今のページで選ぶ行へカーソルを動かして決定。行動と違うページなら取消で戻る。
    def battleKeys(res: Res.Res, w: World.World, k: KeysDoc.Rec, m: Member.Member, page: CommandPage): List[Key] =
        let want = World.battleRecOf(w) |> Option.flatMap(r -> {
            let plan = Map.get(m, battlePlans(res, r#battle)) |> Option.getWithDefault(Battle.Plan.Attack(0));
            wantedRowOf(res, r, m, plan, page)
        });
        let at = WorldBattle.cursorOf(page);
        match want {
            case Some(row) if row == at => k#confirm
            case Some(row) if row > at  => k#down
            case Some(_)                => k#up
            case None                   => k#cancel
        }

    /// 行動 plan のために、page で選ぶ行（そのページで選ぶ物が plan に無ければ None = 取消で戻る）。
    def wantedRowOf(res: Res.Res, r: World.BattleRec, m: Member.Member, plan: Battle.Plan, page: CommandPage): Option[Int32] =
        let targets = WorldBattle.targetsOfPage(res, r, page);
        match (page, plan) {
            case (CommandPage.Commands(_), _)                                      => List.indexOf(commandOf(plan), WorldBattle.commands())
            case (CommandPage.FoeTarget(_), Battle.Plan.Attack(i))                 => List.indexOf(Battle.Target.Foe(i), targets)
            case (CommandPage.SpellList(_), Battle.Plan.Cast(id, _))               => List.indexOf(id, WorldBattle.spellsOf(res, r, m) |> List.map(s -> s#spell))
            case (CommandPage.SpellTarget(at, _), Battle.Plan.Cast(id, t)) if at == id => List.indexOf(t, targets)
            case (CommandPage.ItemList(_), Battle.Plan.UseItem(id, _))             => List.indexOf(id, WorldBattle.itemChoicesOf(res, r) |> List.map(fst))
            case (CommandPage.ItemTarget(at, _), Battle.Plan.UseItem(id, t)) if at == id => List.indexOf(t, targets)
            case _                                                                 => None
        }

    /// 行動を選ぶコマンド。
    def commandOf(plan: Battle.Plan): World.BattleCommand = match plan {
        case Battle.Plan.Attack(_)     => World.BattleCommand.Fight
        case Battle.Plan.Defend        => World.BattleCommand.Defend
        case Battle.Plan.Flee          => World.BattleCommand.Flee
        case Battle.Plan.Cast(_, _)    => World.BattleCommand.Spell
        case Battle.Plan.UseItem(_, _) => World.BattleCommand.Items
    }

    /// 生きている敵のうち HP の一番少ない物の、敵の並びでの番号。
    def weakestOf(b: Battle.Battle): Int32 =
        Battle.aliveFoes(b)
            |> List.filterMap(i -> Vector.nth(i, Battle.rec(b)#foes) |> Option.map(f -> ((f#hp, i), i)))
            |> List.sortBy(fst) |> List.head |> Option.map(snd) |> Option.getWithDefault(0)

    /// 戦いで回復する HP の割合の線（これより減った仲間を回復する）。
    def battleHealBelow(): Float64 = 0.35

    /// 1 ターンの方針を決める間の値: 決めた行動・このターンに回復する仲間・このターンに使う道具の数。
    type alias Planning = { plans = Map[Member.Member, Battle.Plan], healing = Set[Member.Member], used = Map[ItemsDoc.ItemId, Int32] }

    /// つり合いのシミュレーションと同じ方針の行動（行動を選ぶ仲間を加わった順に）:
    ///   HP が最大の 35% 未満の仲間（一番減っている人。このターンにまだ誰も回復しない人）がいれば、回復の呪文（MP があれば）→ HP の戻る道具。
    ///   逃げられない組（中ボス・ひとくいばこ・ボス）では、攻めの呪文（回復の呪文の分の MP を残して。敵が 2 体以上なら敵全部の呪文）→
    ///   たたかう の 2 倍より強いなら burn の道具（攻めの弱い人が投げる）。ほかは HP の一番少ない敵を たたかう。にげない。
    pub def battlePlans(res: Res.Res, b: Battle.Battle): Map[Member.Member, Battle.Plan] =
        let done = Battle.choosersOf(b) |> List.foldLeft((acc, m) -> {
            let plan = healPlanOf(res, b, m, acc) |> Option.withDefault(default = bossPlanOf(res, b, m, acc))
                |> Option.getWithDefault(Battle.Plan.Attack(weakestOf(b)));
            planned(m, plan, acc)
        }, { plans = Map.empty(), healing = Set.empty(), used = Map.empty() });
        done#plans

    def planned(m: Member.Member, plan: Battle.Plan, acc: Planning): Planning =
        let healing = match plan {
            case Battle.Plan.Cast(_, Battle.Target.Ally(t))    => Set.insert(t, acc#healing)
            case Battle.Plan.UseItem(_, Battle.Target.Ally(t)) => Set.insert(t, acc#healing)
            case _                                             => acc#healing
        };
        let used = match plan {
            case Battle.Plan.UseItem(id, _) => Map.insertWith((x, y) -> x + y, id, 1, acc#used)
            case _                          => acc#used
        };
        { plans = Map.insert(m, plan, acc#plans), healing = healing, used = used }

    /// 呪文の値と、m が今の MP で唱えられるか（残す MP を引いて）。
    def castable(res: Res.Res, b: Battle.Battle, m: Member.Member, keep: Int32, aim: SpellsDoc.Aim): List[(SpellsDoc.SpellId, SpellsDoc.Spell)] =
        let mp = Party.mpOf(m, Battle.rec(b)#party);
        Party.spellsOf(res#party, res#spells, m, Battle.rec(b)#party)
            |> List.filterMap(id -> SpellsDoc.spellOf(res#spells, id) |> Option.map(s -> (id, s)))
            |> List.filter(match (_, s) -> s#aim == aim and mp - keep >= s#mp)

    /// ふくろの道具のうち、条件に合い、このターンにまだ残る物（Bag.listOf の順で最初）。
    def bagItemOf(res: Res.Res, b: Battle.Battle, acc: Planning, wanted: ItemsDoc.Item -> Bool): Option[ItemsDoc.ItemId] =
        Bag.listOf(res#items, Battle.rec(b)#bag)
            |> List.filter(match (id, n) -> n - Map.getWithDefault(id, 0, acc#used) > 0)
            |> List.map(fst)
            |> List.find(id -> ItemsDoc.itemOf(res#items, id) |> Option.exists(item -> Battle.isBattleItem(item) and wanted(item)))

    /// HP が減った仲間の回復（回復の呪文 → HP の戻る道具）。回復する人が居なければ None。
    def healPlanOf(res: Res.Res, b: Battle.Battle, m: Member.Member, acc: Planning): Option[Battle.Plan] =
        let party = Battle.rec(b)#party;
        let ratioOf = x -> Int32.toFloat64(Party.hpOf(x, party)) / Int32.toFloat64(Int32.max(1, Party.maxHpOf(res#party, x, party)));
        let hurt = Party.aliveOf(party) |> List.filter(x -> not Set.memberOf(x, acc#healing))
            |> List.map(x -> (ratioOf(x), x)) |> List.filter(pair -> fst(pair) < battleHealBelow())
            |> List.sortBy(fst) |> List.head |> Option.map(snd);
        hurt |> Option.flatMap(t -> {
            let bySpell = castable(res, b, m, 0, SpellsDoc.Aim.Ally) |> List.head |> Option.map(match (id, _) -> Battle.Plan.Cast(id, Battle.Target.Ally(t)));
            let byItem = bagItemOf(res, b, acc, item -> item#heal > 0) |> Option.map(id -> Battle.Plan.UseItem(id, Battle.Target.Ally(t)));
            Option.withDefault(default = byItem, bySpell)
        })

    /// 逃げられない組での攻め: 回復の呪文の MP を残した攻めの呪文（敵が 2 体以上なら敵全部の呪文が先）→ たたかう の 2 倍より強い burn の道具。
    def bossPlanOf(res: Res.Res, b: Battle.Battle, m: Member.Member, acc: Planning): Option[Battle.Plan] =
        if (not Battle.isNoFlee(res, b)) None
        else {
            let keep = castable(res, b, m, 0, SpellsDoc.Aim.Ally) |> List.map(pair -> snd(pair)#mp) |> List.minimum |> Option.getWithDefault(0);
            let target = weakestOf(b);
            let strongest = spells -> spells |> List.map(match (id, s) -> (0 - s#power, id)) |> List.sortBy(fst) |> List.head |> Option.map(snd);
            let all = if (List.length(Battle.aliveFoes(b)) >= 2) strongest(castable(res, b, m, keep, SpellsDoc.Aim.AllFoes)) else None;
            let one = strongest(castable(res, b, m, keep, SpellsDoc.Aim.Foe));
            let atk = Party.atkOf(res#party, res#items, m, Battle.rec(b)#party);
            let foeDef = Vector.nth(target, Battle.rec(b)#foes) |> Option.map(f -> FoesDoc.foeOrBlank(res#foes, f#id)#defense) |> Option.getWithDefault(0);
            let hit = Battle.damageOf(RulesDoc.rec(res#rules)#spread, atk, foeDef, 0.5);
            let bomb = bagItemOf(res, b, acc, item -> item#burn > 2 * hit);
            all |> Option.map(id -> Battle.Plan.Cast(id, Battle.Target.AllFoes))
                |> Option.withDefault(default = one |> Option.map(id -> Battle.Plan.Cast(id, Battle.Target.Foe(target))))
                |> Option.withDefault(default = bomb |> Option.map(id -> Battle.Plan.UseItem(id, Battle.Target.Foe(target))))
        }

    // ── 店とメニュー ──

    /// 店: どうのつるぎ を 1 本買う（かう → 品 → 個数 1 → はい）。要らなくなったら取消で閉じる。
    def shopKeys(res: Res.Res, w: World.World, k: KeysDoc.Rec, page: ShopPage): List[Key] =
        let sword = ItemsDoc.idOf(res#items, "dounotsurugi");
        let wanted = wantsSword(res, w);
        match page {
            case ShopPage.Top(i) if wanted                 => if (i == 0) k#confirm else k#up
            case ShopPage.Goods(ShopMode.Buy, i) if wanted =>
                let at = sword |> Option.flatMap(id -> WorldShop.goodsOf(res, WorldShop.shopOf(w), ShopMode.Buy, w#bag) |> List.map(g -> g#item) |> List.indexOf(id)) |> Option.getWithDefault(0);
                if (i == at) k#confirm else k#down
            case ShopPage.Count(_, _, _) if wanted         => k#confirm
            case ShopPage.Confirm(_, _, _, World.Answer.Yes) if wanted => k#confirm
            case ShopPage.Confirm(_, _, _, World.Answer.No) if wanted  => k#up
            case _                                         => k#cancel
        }

    /// メニュー: そうび → 仲間 → 置き場 → 道具。付け替える物が無ければ取消で閉じる。
    def menuKeys(res: Res.Res, w: World.World, k: KeysDoc.Rec, page: MenuPage): List[Key] =
        match (goalOf(res, w), page) {
            case (Goal.Equip(_, _, _), MenuPage.Root(i)) =>
                let at = List.indexOf(WorldMenu.RootItem.Equip, WorldMenu.rootItems()) |> Option.getWithDefault(0);
                if (i == at) k#confirm else if (i / 2 < at / 2) k#down else if (i / 2 > at / 2) k#up else if (i < at) k#right else k#left
            case (Goal.Equip(m, _, _), MenuPage.EquipWho(i)) =>
                if (List.indexOf(m, Party.membersOf(w#party)) == Some(i)) k#confirm else k#down
            case (Goal.Equip(m, slot, _), MenuPage.EquipSlot(who, i)) =>
                if (who != m) k#cancel else if (List.indexOf(slot, Party.slots()) == Some(i)) k#confirm else k#down
            case (Goal.Equip(m, slot, item), MenuPage.EquipPick(who, at, i)) =>
                if (who != m or at != slot) k#cancel
                else if (List.indexOf(Some(item), WorldMenu.candidatesOf(res, m, slot, w#bag)) == Some(i)) k#confirm else k#down
            case (Goal.Heal(_, _), MenuPage.Root(i)) =>
                let at = List.indexOf(WorldMenu.RootItem.Items, WorldMenu.rootItems()) |> Option.getWithDefault(0);
                if (i == at) k#confirm else if (i / 2 < at / 2) k#down else if (i / 2 > at / 2) k#up else if (i < at) k#right else k#left
            case (Goal.Heal(_, item), MenuPage.Items(i)) =>
                if (List.indexOf(item, WorldMenu.bagItemsOf(res, w#bag)) == Some(i)) k#confirm else k#down
            case (Goal.Heal(m, item), MenuPage.ItemTarget(it, i)) =>
                if (it != item) k#cancel else if (List.indexOf(m, Party.membersOf(w#party)) == Some(i)) k#confirm else k#down
            case (Goal.Cast(_, _, _), MenuPage.Root(i)) =>
                let at = List.indexOf(WorldMenu.RootItem.Spell, WorldMenu.rootItems()) |> Option.getWithDefault(0);
                if (i == at) k#confirm else if (i / 2 < at / 2) k#down else if (i / 2 > at / 2) k#up else if (i < at) k#right else k#left
            case (Goal.Cast(who, _, _), MenuPage.SpellWho(i)) =>
                if (List.indexOf(who, Party.membersOf(w#party)) == Some(i)) k#confirm else k#down
            case (Goal.Cast(who, _, spell), MenuPage.Spells(m, i)) =>
                if (m != who) k#cancel else if (List.indexOf(spell, WorldMenu.spellsOf(res, m, w)) == Some(i)) k#confirm else k#down
            case (Goal.Cast(who, target, spell), MenuPage.SpellTarget(m, id, i)) =>
                if (m != who or id != spell) k#cancel else if (List.indexOf(target, Party.membersOf(w#party)) == Some(i)) k#confirm else k#down
            case _ => k#cancel
        }

    // ── 歩く ──

    /// 歩く: 道の残りが減る隣へ方向を押したまま。着いたら向きをそろえて決定（Talk・Open）。そうび の目的はメニューを開く。
    def walkKeys(res: Res.Res, w: World.World, k: KeysDoc.Rec, st0: State): (Set[Key], State) =
        let goal = goalOf(res, w);
        let tap = (keys, st) -> if (st#tapped) (Set.empty(), { tapped = false | st }) else (keyOf(keys), { tapped = true | st });
        match (goal, World.fieldRecOf(w)) {
            case (Goal.Equip(_, _, _), _) => tap(k#cancel, st0)
            case (Goal.Heal(_, _), _) => tap(k#cancel, st0)
            case (Goal.Cast(_, _, _), _) => tap(k#cancel, st0)
            case (_, None) => (Set.empty(), st0)
            case (Goal.Go(_, _), Some(r)) =>
                let st = withRoute(res, w, goal, st0);
                let cell = (r#hero#x, r#hero#y);
                let route = st#route;
                let dist = route |> Option.flatMap(rt -> Map.get(cell, rt#dist));
                match (dist, route |> Option.flatMap(rt -> Map.get(cell, rt#arrive))) {
                    case (Some(0), Some(Arrive.Push(d))) => (keyOf(KeysDoc.dirKeys(k, d)), { tapped = false | st })
                    case (Some(0), Some(Arrive.Face(d))) if d != r#facing => (keyOf(KeysDoc.dirKeys(k, d)), { tapped = false | st })
                    case (Some(0), Some(Arrive.Face(_))) => tap(k#confirm, st)
                    case (Some(0), _) => (Set.empty(), { tapped = false | st })
                    case _ =>
                        let step = Dir4.all() |> List.filterMap(d -> {
                            let (dx, dy) = Dir4.delta(d);
                            route |> Option.flatMap(rt -> Map.get((r#hero#x + dx, r#hero#y + dy), rt#dist)) |> Option.map(n -> ((n, dx, dy), d))
                        }) |> List.filter(pair -> dist |> Option.forAll(here -> { let (n, _, _) = fst(pair); n < here })) |> List.sortBy(fst) |> List.head;
                        match step {
                            case Some((_, d)) => (keyOf(KeysDoc.dirKeys(k, d)), { tapped = false | st })
                            case None         => (Set.empty(), { tapped = false | st })
                        }
                }
        }

    /// マップか目的が変わった時と、先頭が引いた道の外へ出た時（トロッコで運ばれた）だけ道を引き直す
    /// （加わった仲間・開けた宝箱・旗・動かした岩でも塞ぐ物が変わるので鍵に入れる）。先頭から目的へ歩いて着けなければ寄り道の道（detourOf）。
    def withRoute(res: Res.Res, w: World.World, goal: Goal, st: State): State =
        match World.fieldRecOf(w) |> Option.flatMap(r -> MapDoc.docOf(res#maps, r#map) |> Option.map(map -> (r, map))) {
            case None => st
            case Some((r, map)) =>
                let here = MapDoc.nameOf(r#map);
                let flags = Progress.flagsOf(w#progress) |> Set.toList |> List.map(Flag.nameOf) |> List.join(",");
                let rocks = r#rocks |> Map.toList |> List.map(match (id, c) -> "${id}:${c#x}:${c#y}") |> List.join(",");
                let key = "${here}|${goal}|${Party.joinedIds(w#party) |> Set.toList |> List.join(",")}|${Set.size(Progress.openedIn(r#map, w#progress))}|${flags}|${rocks}";
                let heroCell = (r#hero#x, r#hero#y);
                if (st#route |> Option.exists(rt -> rt#key == key and Map.memberOf(heroCell, rt#dist))) st
                else {
                    let (targets, _) = targetsOf(res, map, here, goal);
                    let base = routeOf(w, map, key, targets);
                    let route = if (Map.memberOf(heroCell, base#dist) or List.isEmpty(targets)) base
                        else detourOf(w, r, map, base) |> Option.map(aim -> routeOf(w, map, key, aimCellsOf(map, aim))) |> Option.getWithDefault(base);
                    { route = Some(route) | st }
                }
        }

    /// 目的の道（base）へ歩いて着けない時の寄り道: 歩いて乗れて、降りた所から base へ歩けるトロッコを調べる。
    /// 無ければ、歩いて行けるレバーのうち、動かすとそういうトロッコができる物を調べる（分かれ目の向きを替える）。どちらも無ければ None。
    def detourOf(w: World.World, r: World.FieldRec, map: MapDoc.Doc, base: Route): Option[Aim] =
        let occ = WorldField.occupancyOf(map, w);
        let exits = MapDoc.rec(map)#exitAt;
        let heroCell = (r#hero#x, r#hero#y);
        let fromHero = GridSearch.distances(cell -> cell == heroCell or
            (not Map.memberOf(cell, exits) and WorldField.canEnter(map, occ, { x = fst(cell), y = snd(cell) })), heroCell :: Nil, 4000);
        let besides = (cell: Grid.Cell, dist: Map[(Int32, Int32), Int32]) -> Dir4.all() |> List.exists(d -> {
            let (dx, dy) = Dir4.delta(d);
            Map.memberOf((cell#x + dx, cell#y + dy), dist)
        });
        let landing = progress -> {
            let placed = WorldObject.objectsNow(map, r, progress);
            placed |> List.filter(Rail.isCart) |> List.filter(p -> besides(p#cell, fromHero))
                |> List.find(p -> Rail.pathOf(map, placed, p) |> List.last |> Option.exists(end -> besides(end, base#dist)))
        };
        let levers = WorldObject.objectsNow(map, r, w#progress) |> List.filter(p -> besides(p#cell, fromHero))
            |> List.filterMap(p -> match p#object#kind {
                case MapDoc.ObjectKind.Lever(l) => Some((p#object#id, l#flag))
                case _                          => None
            });
        match landing(w#progress) {
            case Some(cart) => Some(Aim.Examine(cart#object#id))
            case None => levers
                |> List.find(match (_, flag) -> Option.nonEmpty(landing(Progress.withFlag(flag, not Progress.isFlagSet(flag, w#progress), w#progress))))
                |> Option.map(match (id, _) -> Aim.Examine(id))
        }

    /// 道を今の World で引き直しておく（BotRun が残りを数える前に呼ぶ）。
    pub def refresh(res: Res.Res, w: World.World, st: State): State = withRoute(res, w, goalOf(res, w), st)

    /// エンディングに着いたか（表の値はここまでで数え、手はタイトルへ戻るまで続ける）。
    pub def isAtEnding(w: World.World): Bool = World.sceneKindOf(w) == World.SceneKind.Ending

    /// 仲間の誰かの HP か MP が最大でないか（ボスの前にミナの父の全快を受ける）。
    def isWorn(res: Res.Res, w: World.World): Bool =
        Party.statsList(w#party) |> List.exists(match (m, s) ->
            s#hp < Party.maxHpOf(res#party, m, w#party) or s#mp < Party.maxMpOf(res#party, m, w#party))
}
