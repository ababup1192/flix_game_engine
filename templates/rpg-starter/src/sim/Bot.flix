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
// 歩きの道の計算は BotRoute（マップの間の最短・マップの中の幅優先・トロッコとレバーの寄り道 detourOf）。落とし穴（目的でない出入口のマス）は踏まない。
// 戦いの方針は BotBattle.battlePlans（HP が 35% 未満の仲間を回復の呪文 → やくそう で回復・逃げられない組では攻めの呪文 → ばくだんいし・
//   ほかは HP の一番少ない敵を たたかう。にげない）。村の外で HP が 60% 未満なら、フィールドで回復の呪文 → やくそう。
// 依存は Bot → BotRoute・BotBattle の一方通行（BotRoute と BotBattle は Bot を使わない）。
// 会話: 文字送りは決定で進め、はい / いいえ は「はい」（先頭）。
mod Bot {
    use fge::{Dir4}
    use fge::GameEngine.Key
    use World.{MenuPage, ShopMode, ShopPage}

    use BotRoute.{Aim, Arrive}

    // ── 目的 ──

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

    /// 目的の行き先（歩く目的でなければ None）。
    def destinationOf(goal: Goal): Option[(String, Aim)] = match goal {
        case Goal.Equip(_, _, _) => None
        case Goal.Heal(_, _)     => None
        case Goal.Cast(_, _, _)  => None
        case Goal.Go(dest, aim)  => Some((dest, aim))
    }

    /// 今いるマップの中の目標のマスと、着いた所でする事（行き先が無ければ空）。
    def goalTargetsOf(res: Res.Res, map: MapDoc.Doc, here: String, goal: Goal): (List[((Int32, Int32), Arrive)], Int32) =
        destinationOf(goal) |> Option.map(match (dest, aim) -> BotRoute.targetsOf(res, map, here, dest, aim)) |> Option.getWithDefault((Nil, 0))

    // ── 状態 ──

    /// bot の値。route = 引いた道（マップか目的が変わった時だけ引き直す）、tapped = 前のフレームに決定などを押した（次は離す）。
    pub type alias State = { route = Option[BotRoute.Route], tapped = Bool }

    pub def initial(): State = { route = None, tapped = false }

    /// 今の目的地までの残り（出入口の数 × 100 + マップの中のマス数。道が無ければ 100000）。詰みの判定が比べる。
    pub def remainingOf(res: Res.Res, w: World.World, st: State): Int32 =
        match (World.fieldRecOf(w), st#route) {
            case (Some(r), Some(route)) =>
                let (_, hops) = MapDoc.docOf(res#maps, r#map) |> Option.map(map -> goalTargetsOf(res, map, MapDoc.nameOf(r#map), goalOf(res, w))) |> Option.getWithDefault((Nil, 99));
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
            case InputLayer.Layer.BattleChoose(m, page) => tap(BotBattle.battleKeys(res, w, k, m, page))
            case InputLayer.Layer.Walking         => walkKeys(res, w, k, st)
            case InputLayer.Layer.Ending if WorldTitle.creditProgressOf(res, w) >= 1.0 => tap(k#confirm)
            case InputLayer.Layer.Ending          => (Set.empty(), { tapped = false | st })
        }

    // ── 戦い ──

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
                    let (targets, _) = goalTargetsOf(res, map, here, goal);
                    let base = BotRoute.routeOf(w, map, key, targets);
                    let route = if (Map.memberOf(heroCell, base#dist) or List.isEmpty(targets)) base
                        else BotRoute.detourOf(w, r, map, base) |> Option.map(aim -> BotRoute.routeOf(w, map, key, BotRoute.aimCellsOf(map, aim))) |> Option.getWithDefault(base);
                    { route = Some(route) | st }
                }
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
