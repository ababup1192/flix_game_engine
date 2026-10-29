// BotBattle — bot と make balance の戦いの方針（すべて純粋）。1 ターンの行動を仲間ごとに決め（battlePlans）、
// bot はそれをコマンドのページの行へ直してキーにする（battleKeys）。BalanceSim は battlePlans を BattleActs.resolveRound へ直に渡す。
// 歩きと道筋は知らない（Bot・BotRoute を使わない）。
mod BotBattle {
    use fge::GameEngine.Key
    use World.CommandPage

    /// ボスの敵の鍵（BotRun がボス戦を区間に分ける）。
    pub def bossFoe(): String = "gemeater"

    /// m の行動（battlePlans）へ向けてページを進める: 今のページで選ぶ行へカーソルを動かして決定。行動と違うページなら取消で戻る。
    pub def battleKeys(res: Res.Res, w: World.World, k: KeysDoc.Rec, m: Member.Member, page: CommandPage): List[Key] =
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

    /// 見比べの方針: 行動を選ぶ仲間が全員、HP の一番少ない敵を たたかう（回復も呪文も道具も使わない）。make balance のボスの行が、
    /// 回復と呪文を使う battlePlans とどれだけ勝率が開くかを並べる。
    pub def attackOnlyPlans(b: Battle.Battle): Map[Member.Member, Battle.Plan] =
        let target = weakestOf(b);
        Battle.choosersOf(b) |> List.map(m -> (m, Battle.Plan.Attack(target))) |> List.toMap

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
}
