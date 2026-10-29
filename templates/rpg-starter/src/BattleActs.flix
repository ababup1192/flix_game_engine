// BattleActs — 戦いの 1 ターン（resolveRound）と 1 手の中身（すべて純粋）。resolveRound が手番ごとに allyTurn / foeTurn を呼び、
// 手は push で Beat を 1 つ積む。式（ダメージ・会心・呪文・道具・ぼうぎょ・眠り・にげる）は Battle の冒頭の図。
// 戦いの値の型と読む口は Battle（ここから Battle を使い、Battle からはここを使わない）。
mod BattleActs {
    use FoeMovesDoc.{Act}
    use TextDoc.{BattleText, Placeholder}

    /// 演出 1 つ（秒は rules の fxSeconds）。
    def fxOf(res: Res.Res, kind: Battle.FxKind, target: Battle.Target, shake: Bool): Option[Battle.Fx] =
        Some({ kind = kind, target = target, seconds = Float64.max(0.0, RulesDoc.rec(res#rules)#fxSeconds), shake = shake })

    /// 呪文の数（ダメージか回復）: max(1, round(power × (0.9 + 0.2 × r)))。まもりを見ない。
    def spellPowerOf(power: Int32, r: Float64): Int32 =
        Int32.max(1, Float64.round(Int32.toFloat64(power) * (0.9 + 0.2 * r)) |> Float64.tryToInt32 |> Option.getWithDefault(1))

    /// 半分（切り上げ）。ぼうぎょ・guard の時。
    def halfOf(n: Int32): Int32 = (n + 1) / 2

    /// wanted が倒れていれば生きている先頭の敵（全員倒れていれば None）。
    def liveFoeOf(wanted: Int32, b: Battle.Battle): Option[(Int32, Battle.FoeState)] =
        let target = if (Battle.isFoeAlive(wanted, b)) Some(wanted) else List.head(Battle.aliveFoes(b));
        target |> Option.flatMap(t -> Vector.nth(t, Battle.rec(b)#foes) |> Option.map(foe -> (t, foe)))

    /// 敵 t に raw のダメージ（guard していれば半分）。HP が phase2At を切ったら phase 2 へ。伝言の行は新しい順に積む。
    def damageFoe(res: Res.Res, t: Int32, raw: Int32, acc: (List[Battle.Msg], Battle.Battle)): (List[Battle.Msg], Battle.Battle) =
        let (lines, b) = acc;
        let r = Battle.rec(b);
        match Vector.nth(t, r#foes) {
            case None      => acc
            case Some(foe) =>
                let doc = FoesDoc.foeOrBlank(res#foes, foe#id);
                let dealt = if (Set.memberOf(t, r#guarding)) halfOf(raw) else raw;
                let hp = Int32.max(0, foe#hp - dealt);
                let phase2 = foe#phase2 or (doc#phase2At > 0.0 and Int32.toFloat64(hp) < doc#phase2At * Int32.toFloat64(doc#hp));
                let hit = Battle.msg(BattleText.FoeDamaged, (Placeholder.Target, foe#label) :: (Placeholder.N, "${dealt}") :: Nil);
                let down = if (hp <= 0) Battle.msg(BattleText.FoeDown, (Placeholder.Target, foe#label) :: Nil) :: Nil else Nil;
                (List.append(down, hit :: lines), Battle.wrap({ foes = Vector.update(t, { hp = hp, phase2 = phase2 | foe }, r#foes) | r }))
        }

    /// 仲間 m に raw のダメージ（ぼうぎょ していれば半分）。倒れたら眠りも消す。伝言の行は新しい順に積む。
    def damageAlly(res: Res.Res, m: Member.Member, raw: Int32, acc: (List[Battle.Msg], Battle.Battle)): (List[Battle.Msg], Battle.Battle) =
        let (lines, b) = acc;
        let r = Battle.rec(b);
        let dealt = if (Set.memberOf(m, r#defending)) halfOf(raw) else raw;
        let hp = Int32.max(0, Party.hpOf(m, r#party) - dealt);
        let party = Party.withHpMp(res#party, m, hp, Party.mpOf(m, r#party), r#party);
        let name = Battle.nameOf(res, m);
        let hit = Battle.msg(BattleText.AllyDamaged, (Placeholder.Target, name) :: (Placeholder.N, "${dealt}") :: Nil);
        let down = if (hp <= 0) Battle.msg(BattleText.AllyDown, (Placeholder.Target, name) :: Nil) :: Nil else Nil;
        let asleep = if (hp <= 0) Map.remove(m, r#asleep) else r#asleep;
        (List.append(down, hit :: lines), Battle.wrap({ party = party, asleep = asleep | r }))

    /// 仲間 m の HP を amount まで戻す（最大で止める）。倒れている人には効かない。戻した数の行を新しい順に積む。
    def healAlly(res: Res.Res, m: Member.Member, amount: Int32, acc: (List[Battle.Msg], Battle.Battle)): (List[Battle.Msg], Battle.Battle) =
        let (lines, b) = acc;
        let r = Battle.rec(b);
        if (not Party.isAlive(m, r#party)) (Battle.msg(BattleText.NoEffect, Nil) :: lines, b)
        else {
            let gained = Int32.min(amount, Party.maxHpOf(res#party, m, r#party) - Party.hpOf(m, r#party));
            let party = Party.recover(res#party, m, { hp = gained, mp = 0 }, r#party);
            (Battle.msg(BattleText.AllyHealed, (Placeholder.Target, Battle.nameOf(res, m)) :: (Placeholder.N, "${gained}") :: Nil) :: lines, Battle.wrap({ party = party | r }))
        }

    // ── 仲間の手番 ──

    /// 眠っている人は眠りの手番、ほかは選んだ行動。
    def allyTurn(res: Res.Res, m: Member.Member, plan: Option[Battle.Plan], turn: Turn): Turn =
        match Map.get(m, Battle.rec(turn#b)#asleep) {
            case Some(slept) => sleepingTurn(res, m, slept, turn)
            case None        => allyAct(res, m, plan, turn)
        }

    def allyAct(res: Res.Res, m: Member.Member, plan: Option[Battle.Plan], turn: Turn): Turn =
        match plan {
            case Some(Battle.Plan.Attack(t))         => allyAttack(res, m, t, turn)
            case Some(Battle.Plan.Defend)            => push(Battle.msg(BattleText.Defend, (Placeholder.Name, Battle.nameOf(res, m)) :: Nil) :: Nil, None, turn#b, turn#dice, turn)
            case Some(Battle.Plan.Flee)              => tryFlee(res, m, turn)
            case Some(Battle.Plan.Cast(id, target))  => allyCast(res, m, id, target, turn)
            case Some(Battle.Plan.UseItem(id, target)) => allyUseItem(res, m, id, target, turn)
            case None                         => turn
        }

    /// 眠りの手番: 眠った次の手番（slept = 0）は必ず眠る。その後は wakeRate で起きる（起きた手番は動かない）。
    def sleepingTurn(res: Res.Res, m: Member.Member, slept: Int32, turn: Turn): Turn =
        let r = Battle.rec(turn#b);
        let name = (Placeholder.Name, Battle.nameOf(res, m)) :: Nil;
        let (wake, d1) = if (slept <= 0) (1.0, turn#dice) else Battle.roll(Dice.Channel.Wake, turn#dice);
        if (wake < RulesDoc.rec(res#rules)#wakeRate)
            push(Battle.msg(BattleText.Woke, name) :: Nil, None, Battle.wrap({ asleep = Map.remove(m, r#asleep) | r }), d1, turn)
        else push(Battle.msg(BattleText.Asleep, name) :: Nil, None, Battle.wrap({ asleep = Map.insert(m, slept + 1, r#asleep) | r }), d1, turn)

    /// たたかう: 倒れた的は生きている先頭の敵へ振り替える。会心は まもり を 0 として 1.5 倍。guard した敵へは半分。
    def allyAttack(res: Res.Res, m: Member.Member, wanted: Int32, turn: Turn): Turn =
        match liveFoeOf(wanted, turn#b) {
            case None            => turn
            case Some((t, foe))  => strikeFoe(res, m, t, foe, turn)
        }

    def strikeFoe(res: Res.Res, m: Member.Member, t: Int32, foe: Battle.FoeState, turn: Turn): Turn =
        let rules = RulesDoc.rec(res#rules);
        let doc = FoesDoc.foeOrBlank(res#foes, foe#id);
        let (critRoll, d1) = Battle.roll(Dice.Channel.Critical, turn#dice);
        let (spreadRoll, d2) = Battle.roll(Dice.Channel.Damage, d1);
        let critical = critRoll < rules#critRate;
        let atk = Party.atkOf(res#party, res#items, m, Battle.rec(turn#b)#party);
        let raw = if (critical) Float64.round(Int32.toFloat64(Battle.damageOf(rules#spread, atk, 0, spreadRoll)) * 1.5) |> Float64.tryToInt32 |> Option.getWithDefault(1)
                  else Battle.damageOf(rules#spread, atk, doc#defense, spreadRoll);
        let head = Battle.msg(BattleText.Attack, (Placeholder.Name, Battle.nameOf(res, m)) :: Nil);
        let crit = if (critical) Battle.msg(BattleText.Critical, Nil) :: Nil else Nil;
        let (lines, after) = damageFoe(res, t, raw, (List.append(crit, head :: Nil), turn#b));
        push(List.reverse(lines), fxOf(res, Battle.FxKind.Slash, Battle.Target.Foe(t), false), after, d2, turn)

    /// じゅもん: MP が足りなければ手番を使うだけ。足りれば MP を使い、呪文の的（aim）ごとに効かせる。
    def allyCast(res: Res.Res, m: Member.Member, id: SpellsDoc.SpellId, target: Battle.Target, turn: Turn): Turn =
        let head = Battle.msg(BattleText.Cast, (Placeholder.Name, Battle.nameOf(res, m)) :: (Placeholder.Spell, SpellsDoc.nameOf(res#spells, id)) :: Nil);
        let r = Battle.rec(turn#b);
        match SpellsDoc.spellOf(res#spells, id) {
            case Some(spell) if Party.mpOf(m, r#party) >= spell#mp =>
                let paid = Battle.wrap({ party = Party.withHpMp(res#party, m, Party.hpOf(m, r#party), Party.mpOf(m, r#party) - spell#mp, r#party) | r });
                castBy(res, spell, head, target, { b = paid | turn })
            case Some(_) => push(head :: Battle.msg(BattleText.MpShort, Nil) :: Nil, None, turn#b, turn#dice, turn)
            case None    => push(head :: Battle.msg(BattleText.NoEffect, Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    /// 仲間が唱えた呪文を的に効かせる（Foe は振り替える・AllFoes は生きている敵全部・Ally は target の仲間）。
    def castBy(res: Res.Res, spell: SpellsDoc.Spell, head: Battle.Msg, target: Battle.Target, turn: Turn): Turn =
        match (spell#aim, target) {
            case (SpellsDoc.Aim.Foe, Battle.Target.Foe(wanted)) => castOnFoe(res, spell, head, wanted, turn)
            case (SpellsDoc.Aim.Foe, _)                  => castOnFoe(res, spell, head, 0, turn)
            case (SpellsDoc.Aim.AllFoes, _)              => castOnAllFoes(res, spell, head, turn)
            case (SpellsDoc.Aim.Ally, Battle.Target.Ally(m))    => castOnAlly(res, spell, head, m, turn)
            case (SpellsDoc.Aim.Ally, _)                 => push(head :: Battle.msg(BattleText.NoEffect, Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    def castOnFoe(res: Res.Res, spell: SpellsDoc.Spell, head: Battle.Msg, wanted: Int32, turn: Turn): Turn =
        match liveFoeOf(wanted, turn#b) {
            case None         => push(head :: Nil, None, turn#b, turn#dice, turn)
            case Some((t, _)) =>
                let (r1, d1) = Battle.roll(Dice.Channel.Damage, turn#dice);
                let (lines, after) = damageFoe(res, t, spellPowerOf(spell#power, r1), (head :: Nil, turn#b));
                push(List.reverse(lines), fxOf(res, Battle.FxKind.Spell(spell#fx), Battle.Target.Foe(t), false), after, d1, turn)
        }

    def castOnAllFoes(res: Res.Res, spell: SpellsDoc.Spell, head: Battle.Msg, turn: Turn): Turn =
        let (lines, after, d) = Battle.aliveFoes(turn#b) |> List.foldLeft((acc, t) -> {
            let (ls, b, dice) = acc;
            let (r1, d1) = Battle.roll(Dice.Channel.Damage, dice);
            let (ls2, b2) = damageFoe(res, t, spellPowerOf(spell#power, r1), (ls, b));
            (ls2, b2, d1)
        }, (head :: Nil, turn#b, turn#dice));
        push(List.reverse(lines), fxOf(res, Battle.FxKind.Spell(spell#fx), Battle.Target.AllFoes, false), after, d, turn)

    def castOnAlly(res: Res.Res, spell: SpellsDoc.Spell, head: Battle.Msg, m: Member.Member, turn: Turn): Turn =
        let (r1, d1) = Battle.roll(Dice.Channel.Damage, turn#dice);
        let (lines, after) = healAlly(res, m, spellPowerOf(spell#power, r1), (head :: Nil, turn#b));
        push(List.reverse(lines), fxOf(res, Battle.FxKind.Spell(spell#fx), Battle.Target.Ally(m), false), after, d1, turn)

    /// どうぐ: ふくろに無ければ手番を使うだけ。あれば 1 つ減らし、burn の物は敵 1 体（振り替える）、ほかは仲間 1 人に効かせる。
    def allyUseItem(res: Res.Res, m: Member.Member, id: ItemsDoc.ItemId, target: Battle.Target, turn: Turn): Turn =
        let itemName = (Placeholder.Item, ItemsDoc.nameOf(res#items, id));
        let head = Battle.msg(BattleText.UseItem, (Placeholder.Name, Battle.nameOf(res, m)) :: itemName :: Nil);
        let r = Battle.rec(turn#b);
        match ItemsDoc.itemOf(res#items, id) {
            case Some(item) if Bag.countOf(id, r#bag) > 0 =>
                let used = { b = Battle.wrap({ bag = Bag.give(id, -1, r#bag) | r }) | turn };
                useOn(res, item, head, target, used)
            case _ => push(head :: Battle.msg(BattleText.ItemGone, itemName :: Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    def useOn(res: Res.Res, item: ItemsDoc.Item, head: Battle.Msg, target: Battle.Target, turn: Turn): Turn =
        match (Battle.itemAimOf(item), target) {
            case (SpellsDoc.Aim.Foe, Battle.Target.Foe(wanted)) => burnFoe(res, item, head, wanted, turn)
            case (SpellsDoc.Aim.Foe, _)                  => burnFoe(res, item, head, 0, turn)
            case (_, Battle.Target.Ally(m))                     => mendAlly(res, item, head, m, turn)
            case _                                       => push(head :: Battle.msg(BattleText.NoEffect, Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    def burnFoe(res: Res.Res, item: ItemsDoc.Item, head: Battle.Msg, wanted: Int32, turn: Turn): Turn =
        match liveFoeOf(wanted, turn#b) {
            case None         => push(head :: Nil, None, turn#b, turn#dice, turn)
            case Some((t, _)) =>
                let (lines, after) = damageFoe(res, t, item#burn, (head :: Nil, turn#b));
                push(List.reverse(lines), fxOf(res, Battle.FxKind.Burn, Battle.Target.Foe(t), false), after, turn#dice, turn)
        }

    /// HP と MP を戻す道具（それぞれ最大で止める。倒れている人には効かない）。
    def mendAlly(res: Res.Res, item: ItemsDoc.Item, head: Battle.Msg, m: Member.Member, turn: Turn): Turn =
        let (healed, b1) = if (item#heal > 0) healAlly(res, m, item#heal, (head :: Nil, turn#b)) else (head :: Nil, turn#b);
        let r = Battle.rec(b1);
        let gainMp = Int32.min(item#mpHeal, Party.maxMpOf(res#party, m, r#party) - Party.mpOf(m, r#party));
        let mpLine = Battle.msg(BattleText.AllyMpHealed, (Placeholder.Target, Battle.nameOf(res, m)) :: (Placeholder.N, "${gainMp}") :: Nil);
        let (lines, after) = if (item#mpHeal > 0 and Party.isAlive(m, r#party))
                                 (mpLine :: healed, Battle.wrap({ party = Party.recover(res#party, m, { hp = 0, mp = gainMp }, r#party) | r }))
                             else (healed, b1);
        push(List.reverse(lines), fxOf(res, Battle.FxKind.Mend, Battle.Target.Ally(m), false), after, turn#dice, turn)

    /// にげる: noFlee の組では「にげられない」で手番を使う。率は fleeRateOf。
    def tryFlee(res: Res.Res, m: Member.Member, turn: Turn): Turn =
        let head = Battle.msg(BattleText.Run, (Placeholder.Name, Battle.nameOf(res, m)) :: Nil);
        if (Battle.isNoFlee(res, turn#b)) push(head :: Battle.msg(BattleText.NoFlee, Nil) :: Nil, None, turn#b, turn#dice, turn)
        else {
            let (r, d1) = Battle.roll(Dice.Channel.Flee, turn#dice);
            if (r < Battle.fleeRateOf(res, turn#b))
                push(head :: Battle.msg(BattleText.Fled, Nil) :: Nil, None, Battle.wrap({ fled = true | Battle.rec(turn#b) }), d1, turn)
            else push(head :: Battle.msg(BattleText.Blocked, Nil) :: Nil, None, turn#b, d1, turn)
        }

    // ── 敵の手番 ──

    /// 敵 i の手番（そのターンに選んだ技 act）。
    def foeTurn(res: Res.Res, i: Int32, act: Act, turn: Turn): Turn =
        let label = Vector.nth(i, Battle.rec(turn#b)#foes) |> Option.map(f -> f#label) |> Option.getWithDefault("");
        match act {
            case Act.Guard      => push(Battle.msg(BattleText.Guard, (Placeholder.Name, label) :: Nil) :: Nil, None, turn#b, turn#dice, turn)
            case Act.Attack     => foeAttack(res, i, label, turn)
            case Act.Sweep      => foeSweep(res, i, label, turn)
            case Act.Sleep      => foeSleep(res, label, turn)
            case Act.Spell(key) => foeCast(res, i, label, key, turn)
        }

    /// 生きている仲間から 1 人を引く。
    def pickAlly(turn: Turn): (Option[Member.Member], Int32) =
        let alive = Party.aliveOf(Battle.rec(turn#b)#party);
        let (picked, next) = Dice.weighted(Dice.Channel.FoeTarget, alive |> List.map(m -> (m, 1)), { dice = turn#dice });
        (picked, next#dice)

    /// 生きている仲間から 1 人を引いて叩く。
    def foeAttack(res: Res.Res, i: Int32, label: String, turn: Turn): Turn =
        match pickAlly(turn) {
            case (None, _)    => turn
            case (Some(m), d) =>
                let (lines, b, d1) = hitAlly(res, i, 1.0, m, (Nil, turn#b, d));
                push(Battle.msg(BattleText.Attack, (Placeholder.Name, label) :: Nil) :: List.reverse(lines), fxOf(res, Battle.FxKind.Hit, Battle.Target.Ally(m), true), b, d1, turn)
        }

    /// 生きている仲間全員を ちから × 0.6 で叩く。
    def foeSweep(res: Res.Res, i: Int32, label: String, turn: Turn): Turn =
        let (lines, b, d) = Party.aliveOf(Battle.rec(turn#b)#party) |> List.foldLeft((acc, m) -> hitAlly(res, i, 0.6, m, acc), (Nil, turn#b, turn#dice));
        push(Battle.msg(BattleText.Sweep, (Placeholder.Name, label) :: Nil) :: List.reverse(lines), fxOf(res, Battle.FxKind.Hit, Battle.Target.AllAllies, true), b, d, turn)

    /// 敵 i が仲間 m を、ちから × scale で叩く（ぼうぎょ していれば半分）。伝言の行は新しい順に積む。
    def hitAlly(res: Res.Res, i: Int32, scale: Float64, m: Member.Member, acc: (List[Battle.Msg], Battle.Battle, Int32)): (List[Battle.Msg], Battle.Battle, Int32) =
        let (lines, b, dice) = acc;
        let r = Battle.rec(b);
        let doc = Vector.nth(i, r#foes) |> Option.map(f -> FoesDoc.foeOrBlank(res#foes, f#id));
        let atk = doc |> Option.map(f -> Float64.round(Int32.toFloat64(f#atk) * scale) |> Float64.tryToInt32 |> Option.getWithDefault(0)) |> Option.getWithDefault(0);
        let (spreadRoll, d1) = Battle.roll(Dice.Channel.Damage, dice);
        let raw = Battle.damageOf(RulesDoc.rec(res#rules)#spread, atk, Party.defenseOf(res#party, res#items, m, r#party), spreadRoll);
        let (lines1, b1) = damageAlly(res, m, raw, (lines, b));
        (lines1, b1, d1)

    /// 生きている仲間から 1 人を引き、眠っていなければ sleepRate で眠らせる（眠った次の手番は必ず眠る）。
    def foeSleep(res: Res.Res, label: String, turn: Turn): Turn =
        let head = Battle.msg(BattleText.SleepAct, (Placeholder.Name, label) :: Nil);
        match pickAlly(turn) {
            case (None, _)    => turn
            case (Some(m), d) =>
                let (r1, d1) = Battle.roll(Dice.Channel.Sleep, d);
                let target = (Placeholder.Target, Battle.nameOf(res, m)) :: Nil;
                let r = Battle.rec(turn#b);
                if (Battle.isAsleep(m, turn#b) or r1 >= RulesDoc.rec(res#rules)#sleepRate)
                    push(head :: Battle.msg(BattleText.SleepMiss, target) :: Nil, None, turn#b, d1, turn)
                else push(head :: Battle.msg(BattleText.FellAsleep, target) :: Nil, fxOf(res, Battle.FxKind.Hit, Battle.Target.Ally(m), true),
                          Battle.wrap({ asleep = Map.insert(m, 0, r#asleep) | r }), d1, turn)
        }

    /// 敵が呪文（rpg.spells.json の鍵）を唱える。敵 1 体向けの呪文は仲間 1 人へ・敵全部向けは仲間全員へ・回復は唱えた敵自身へ。
    /// 鍵が Doc に無ければ たたかう。
    def foeCast(res: Res.Res, i: Int32, label: String, key: String, turn: Turn): Turn =
        match SpellsDoc.idOf(res#spells, key) |> Option.flatMap(id -> SpellsDoc.spellOf(res#spells, id) |> Option.map(s -> (id, s))) {
            case None              => foeAttack(res, i, label, turn)
            case Some((id, spell)) =>
                let head = Battle.msg(BattleText.Cast, (Placeholder.Name, label) :: (Placeholder.Spell, SpellsDoc.nameOf(res#spells, id)) :: Nil);
                foeCastAt(res, i, spell, head, turn)
        }

    def foeCastAt(res: Res.Res, i: Int32, spell: SpellsDoc.Spell, head: Battle.Msg, turn: Turn): Turn =
        match spell#aim {
            case SpellsDoc.Aim.Foe     => foeSpellOnOne(res, spell, head, turn)
            case SpellsDoc.Aim.AllFoes =>
                let (lines, b, d) = Party.aliveOf(Battle.rec(turn#b)#party) |> List.foldLeft((acc, m) -> spellOnAlly(res, spell, m, acc), (head :: Nil, turn#b, turn#dice));
                push(List.reverse(lines), fxOf(res, Battle.FxKind.Spell(spell#fx), Battle.Target.AllAllies, true), b, d, turn)
            case SpellsDoc.Aim.Ally    => foeHealSelf(res, i, spell, head, turn)
        }

    def foeSpellOnOne(res: Res.Res, spell: SpellsDoc.Spell, head: Battle.Msg, turn: Turn): Turn =
        match pickAlly(turn) {
            case (None, _)    => turn
            case (Some(m), d) =>
                let (lines, b, d1) = spellOnAlly(res, spell, m, (head :: Nil, turn#b, d));
                push(List.reverse(lines), fxOf(res, Battle.FxKind.Spell(spell#fx), Battle.Target.Ally(m), true), b, d1, turn)
        }

    /// 呪文のダメージを仲間 m に（まもりを見ない・ぼうぎょ していれば半分）。
    def spellOnAlly(res: Res.Res, spell: SpellsDoc.Spell, m: Member.Member, acc: (List[Battle.Msg], Battle.Battle, Int32)): (List[Battle.Msg], Battle.Battle, Int32) =
        let (lines, b, dice) = acc;
        let (r1, d1) = Battle.roll(Dice.Channel.Damage, dice);
        let (lines1, b1) = damageAlly(res, m, spellPowerOf(spell#power, r1), (lines, b));
        (lines1, b1, d1)

    def foeHealSelf(res: Res.Res, i: Int32, spell: SpellsDoc.Spell, head: Battle.Msg, turn: Turn): Turn =
        let r = Battle.rec(turn#b);
        match Vector.nth(i, r#foes) {
            case None      => turn
            case Some(foe) =>
                let (r1, d1) = Battle.roll(Dice.Channel.Damage, turn#dice);
                let top = FoesDoc.foeOrBlank(res#foes, foe#id)#hp;
                let gained = Int32.min(spellPowerOf(spell#power, r1), top - foe#hp);
                let after = Battle.wrap({ foes = Vector.update(i, { hp = foe#hp + gained | foe }, r#foes) | r });
                push(head :: Battle.msg(BattleText.FoeHealed, (Placeholder.Target, foe#label) :: (Placeholder.N, "${gained}") :: Nil) :: Nil,
                     fxOf(res, Battle.FxKind.Spell(spell#fx), Battle.Target.Foe(i), false), after, d1, turn)
        }

    // ── 1 ターン ──

    /// 手番の持ち主。
    enum Actor with Eq {
        case Ally(Member.Member)
        case Foe(Int32)
    }

    /// 1 ターンを解く間の値: 今の戦い・出した Beat（新しい順）・乱数の回数。
    type alias Turn = { b = Battle.Battle, beats = List[Battle.Beat], dice = Int32 }

    /// 1 ターン: plans（行動を選んだ仲間の行動。無い人は たたかう で先頭の敵）を受け、敵の技を選び、すばやさ順に 1 手ずつ行う。
    /// 眠っている人は plans によらず眠りの手番になる。返すのはターンの後の戦い・1 手ずつの Beat（行った順）・乱数の回数。
    pub def resolveRound(res: Res.Res, b0: Battle.Battle, plans: Map[Member.Member, Battle.Plan], dice0: Int32): (Battle.Battle, List[Battle.Beat], Int32) =
        let (acts, dice1) = foeActsOf(res, b0, dice0);
        let defending = plans |> Map.toList |> List.filter(p -> snd(p) == Battle.Plan.Defend) |> List.map(fst) |> List.toSet;
        let guarding = acts |> Map.toList |> List.filter(p -> snd(p) == Act.Guard) |> List.map(fst) |> List.toSet;
        let b1 = Battle.wrap({ guarding = guarding, defending = defending | Battle.rec(b0) });
        let (order, dice2) = turnOrderOf(res, b1, dice1);
        let fleeing = plans |> Map.valuesOf |> List.exists(p -> p == Battle.Plan.Flee);
        let done = order |> List.foldLeft((turn, actor) ->
            if (Battle.outcomeOf(turn#b) != Battle.Outcome.Ongoing) turn else turnOf(res, plans, acts, fleeing, actor, turn),
            { b = b1, beats = Nil, dice = dice2 });
        let after = Battle.wrap({ guarding = Set.empty(), defending = Set.empty() | Battle.rec(done#b) });
        (after, List.reverse(done#beats), done#dice)

    /// 生きている敵ごとに、このターンの技（phase の行から重み付きに。行が無ければ attack）。
    def foeActsOf(res: Res.Res, b: Battle.Battle, dice: Int32): (Map[Int32, Act], Int32) =
        Battle.aliveFoes(b) |> List.foldLeft((acc, i) -> {
            let (out, d) = acc;
            let foe = Vector.nth(i, Battle.rec(b)#foes);
            let rows = foe |> Option.map(f -> FoeMovesDoc.movesOf(res#foeMoves, FoesDoc.keyOf(f#id), if (f#phase2) 2 else 1)) |> Option.getWithDefault(Nil);
            let (picked, next) = Dice.weighted(Dice.Channel.FoeMove, rows, { dice = d });
            (Map.insert(i, Option.getWithDefault(Act.Attack, picked), out), next#dice)
        }, (Map.empty(), dice))

    /// 行動順: すばやさ × (1 + 0.25 × r) の大きい順（同じ値は仲間が先、その中は並びの順）。
    def turnOrderOf(res: Res.Res, b: Battle.Battle, dice: Int32): (List[Actor], Int32) =
        let r = Battle.rec(b);
        let allies = Party.aliveOf(r#party) |> List.map(m -> (Actor.Ally(m), Party.agiOf(res#party, m, r#party)));
        let foes = Battle.aliveFoes(b) |> List.map(i -> (Actor.Foe(i), Vector.nth(i, r#foes) |> Option.map(f -> FoesDoc.foeOrBlank(res#foes, f#id)#agi) |> Option.getWithDefault(0)));
        let (keyed, next) = List.append(allies, foes) |> List.zipWithIndex |> List.foldLeft((acc, entry) -> {
            let (out, d) = acc;
            let (at, (actor, agi)) = entry;
            let (roll1, d1) = Battle.roll(Dice.Channel.Order, d);
            let speed = Int32.toFloat64(agi) * (1.0 + 0.25 * roll1);
            let side = match actor {
                case Actor.Ally(_) => 0
                case Actor.Foe(_)  => 1
            };
            (((0.0 - speed, side, at), actor) :: out, d1)
        }, (Nil, dice));
        (keyed |> List.sortBy(fst) |> List.map(snd), next)

    /// 手番 1 つ（仲間は allyTurn・敵は foeTurn）。倒れた者の手番は飛ばす。
    def turnOf(res: Res.Res, plans: Map[Member.Member, Battle.Plan], acts: Map[Int32, Act], fleeing: Bool, actor: Actor, turn: Turn): Turn =
        match actor {
            case Actor.Ally(m) if Party.isAlive(m, Battle.rec(turn#b)#party) => allyTurn(res, m, planOf(plans, fleeing, m), turn)
            case Actor.Ally(_) => turn
            case Actor.Foe(i) if Battle.isFoeAlive(i, turn#b) => foeTurn(res, i, Map.getWithDefault(i, Act.Attack, acts), turn)
            case Actor.Foe(_) => turn
        }

    /// その人の行動。誰かが にげる を選んだターンは、にげる人のほかは何もしない（None）。
    def planOf(plans: Map[Member.Member, Battle.Plan], fleeing: Bool, m: Member.Member): Option[Battle.Plan] =
        match Map.get(m, plans) {
            case Some(Battle.Plan.Flee) => Some(Battle.Plan.Flee)
            case _ if fleeing           => None
            case Some(plan)             => Some(plan)
            case None                   => Some(Battle.Plan.Attack(0))
        }

    /// 1 手を積む（伝言・演出・その手の後の戦いと乱数の回数）。
    def push(lines: List[Battle.Msg], fx: Option[Battle.Fx], b: Battle.Battle, dice: Int32, turn: Turn): Turn =
        { b = b, beats = Battle.beatOf({ lines = lines, fx = fx, after = b }) :: turn#beats, dice = dice }
}
