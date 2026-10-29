// Battle — 戦いの式（すべて純粋。時計とフレームを見ない）。
// 1 ターン = 眠っていない生きている仲間全員の行動（Plan）を受け、敵の技を選び、敵味方をすばやさ順に 1 つずつ行う。
// 1 手ごとに伝言と、その手の後の戦いの値を Beat に残す（見せる側の WorldBattle は Beat を 1 つずつ演出し、
// HP の表示は今見せている Beat の after を読む）。つり合いのシミュレーション（BalanceSim）も同じ resolveRound を回す。
//
// 式（数は rules・foes・spells・items の Doc）:
//   行動順   … すばやさ × (1 + 0.25 × r) の大きい順。同じ値は仲間が先
//   ダメージ … max(1, round((ちから − まもり ÷ 2) × (1 − spread + 2 × spread × r)))
//   会心     … 仲間の たたかう だけ・率は critRate。まもりを 0 として 1.5 倍
//   呪文     … max(1, round(power × (0.9 + 0.2 × r)))。まもりを見ない。回復は最大 HP で止める。仲間は MP を使い、足りなければ手番を使うだけ
//   道具     … burn の物は敵 1 体に burn のダメージ（ぶれ無し）、heal / mpHeal の物は仲間 1 人の HP / MP を戻す。使った時に 1 つ減る
//   ぼうぎょ・guard … そのターンのうちに受けるダメージを半分（切り上げ。呪文と道具にも効く）。ターンの終わりに外す
//   sweep    … 生きている仲間全員へ、ちから × 0.6 で同じ式
//   sleep    … 生きている仲間 1 人を引き、眠っていなければ sleepRate で眠らせる。眠った人は選ぶページを飛ばし、
//              その人の手番の頭で wakeRate で起きる（起きた手番は動かない。眠った次の手番は必ず眠る）。叩かれても起きない
//   にげる   … fleeBase + (仲間の一番速い − 敵の一番速い) × fleeSlope を 0.1..0.95 に収めた率。noFlee の組では手番を使うだけ
// 倒れた的への たたかう・呪文・道具は、生きている別の敵（並びの先頭）へ振り替える。敵か仲間が全滅したら、残りの行動は流さない。
mod Battle {
    use fge::Num
    use FoeMovesDoc.Act
    use TextDoc.{BattleText, Placeholder}

    /// 仲間 1 人の行動。Attack = たたかう（敵の並びの番号）/ Defend = ぼうぎょ / Flee = にげる /
    /// Cast = じゅもん（呪文と的）/ UseItem = どうぐ（道具と的）。
    pub enum Plan with Eq, ToString {
        case Attack(Int32)
        case Defend
        case Flee
        case Cast(SpellsDoc.SpellId, Target)
        case UseItem(ItemsDoc.ItemId, Target)
    }

    /// 敵 1 体の今。label = 画面に出す名前（同じ名前が 2 体以上なら「コケだまA」）、phase2 = 技を phase 2 の行へ替えたか。
    pub type alias FoeState = { id = FoesDoc.FoeId, label = String, hp = Int32, phase2 = Bool }

    /// 戦いの値。party / bag = 戦いの間の仲間とふくろ（正はこちら。勝つ・逃げる・全滅で World へ書き戻す）、
    /// guarding = このターンに guard した敵の番号、defending = このターンに ぼうぎょ した仲間、
    /// asleep = 眠っている仲間 → 眠ってから過ぎた自分の手番の数（0 の間は起きない）、fled = 逃げ切った。
    pub type alias Rec = { party = Party.Party, bag = Bag.Bag, foes = Vector[FoeState], guarding = Set[Int32], defending = Set[Member.Member],
                           asleep = Map[Member.Member, Int32], fled = Bool }

    /// WhyNot: World に record のまま持たない — Beat の列ごとに何度も入り、World を取る全 def の型が大きくなる。
    enum BattleOf(Rec)

    /// 戦いの値（作るのは start だけ。中身は rec で読む）。
    pub type alias Battle = BattleOf

    pub def rec(b: Battle): Rec = match b { case BattleOf.BattleOf(r) => r }

    def wrap(r: Rec): Battle = BattleOf.BattleOf(r)

    /// 戦いの終わり方。
    pub enum Outcome with Eq, ToString {
        case Ongoing
        case Won
        case Lost
        case Fled
    }

    /// 行動と演出の的。Foe = 敵の並びの番号 / AllFoes = 生きている敵全部 / Ally = 仲間 1 人 / AllAllies = 仲間全員。
    pub enum Target with Eq, ToString {
        case Foe(Int32)
        case AllFoes
        case Ally(Member.Member)
        case AllAllies
    }

    /// 演出の種類（battlefx の絵）。Slash = 仲間の攻撃（敵に斬撃と点滅）/ Hit = 敵の攻撃（仲間に当たる）/
    /// Spell = 呪文（rpg.spells.json の fx の絵）/ Burn = 敵に投げる道具（炎の絵）/ Mend = 仲間に使う道具（回復の絵）。
    pub enum FxKind with Eq, ToString {
        case Slash
        case Hit
        case Spell(String)
        case Burn
        case Mend
    }

    /// 演出 1 つ: 種類・的・長さの秒（rules の fxSeconds。その間は入力を捨て、伝言は 1 行目だけ出す）・
    /// shake = 仲間が叩かれた（背景をゆらす）。
    pub type alias Fx = { kind = FxKind, target = Target, seconds = Float64, shake = Bool }

    def fxOf(res: Res.Res, kind: FxKind, target: Target, shake: Bool): Option[Fx] =
        Some({ kind = kind, target = target, seconds = Float64.max(0.0, RulesDoc.rec(res#rules)#fxSeconds), shake = shake })

    /// 伝言の 1 行: 言葉の名前と、埋める値。字にするのは View（TextDoc.battleText）。
    pub type alias Msg = { text = BattleText, values = List[(Placeholder, String)] }

    /// 1 手ぶん: 伝言の行・演出・その手の後の戦いの値。
    pub type alias BeatRec = { lines = List[Msg], fx = Option[Fx], after = Battle }

    /// WhyNot: record のまま List に入れない — World の型に Beat の中身が展開されて大きくなる。
    enum BeatOf(BeatRec)

    pub type alias Beat = BeatOf

    def beatOf(r: BeatRec): Beat = BeatOf.BeatOf(r)

    pub def beatRecOf(b: Beat): BeatRec = match b { case BeatOf.BeatOf(r) => r }

    // ── 始める ──

    /// 敵の並びと仲間とふくろから戦いを始める（敵の HP は最大・同じ名前の 2 体以上は出た順に A・B…・誰も眠っていない）。
    pub def start(res: Res.Res, foes: List[FoesDoc.FoeId], party: Party.Party, bag: Bag.Bag): Battle =
        let names = foes |> List.map(id -> FoesDoc.foeOrBlank(res#foes, id)#name);
        let counts = names |> List.foldLeft((acc, n) -> Map.insertWith((a, b) -> a + b, n, 1, acc), Map.empty());
        let (_, states) = List.zip(foes, names) |> List.foldLeft((acc, pair) -> {
            let (seen, out) = acc;
            let (id, name) = pair;
            let nth = Map.getWithDefault(name, 0, seen);
            let label = if (Map.getWithDefault(name, 0, counts) > 1) name + letterOf(nth) else name;
            (Map.insert(name, nth + 1, seen),
             { id = id, label = label, hp = FoesDoc.foeOrBlank(res#foes, id)#hp, phase2 = false } :: out)
        }, (Map.empty(), Nil));
        wrap({ party = party, bag = bag, foes = states |> List.reverse |> List.toVector, guarding = Set.empty(), defending = Set.empty(),
               asleep = Map.empty(), fled = false })

    def letterOf(i: Int32): String = String.slice(start = i, end = i + 1, "ABCDEFGH")

    /// 敵が現れた時の 1 手（伝言は名前ごとに 1 行。演出なし）。
    pub def openingOf(b: Battle): Beat =
        let names = rec(b)#foes |> Vector.toList |> List.map(f -> f#label);
        beatOf({ lines = names |> List.map(n -> msg(BattleText.Appear, (Placeholder.Name, n) :: Nil)), fx = None, after = b })

    def msg(text: BattleText, values: List[(Placeholder, String)]): Msg = { text = text, values = values }

    // ── 読む ──

    /// 勝ち負け（敵が全員倒れた → Won・仲間が全員倒れた → Lost・逃げ切った → Fled）。
    pub def outcomeOf(b: Battle): Outcome =
        let r = rec(b);
        if (r#fled) Outcome.Fled
        else if (Vector.forAll(f -> f#hp <= 0, r#foes)) Outcome.Won
        else if (List.isEmpty(Party.aliveOf(r#party))) Outcome.Lost
        else Outcome.Ongoing

    /// 生きている敵の番号（並びの順）。
    pub def aliveFoes(b: Battle): List[Int32] =
        rec(b)#foes |> Vector.toList |> List.zipWithIndex |> List.filter(p -> snd(p)#hp > 0) |> List.map(fst)

    /// 眠っているか。
    pub def isAsleep(m: Member.Member, b: Battle): Bool = Map.memberOf(m, rec(b)#asleep)

    /// 行動を選ぶ仲間（生きていて眠っていない人。加わった順）。
    pub def choosersOf(b: Battle): List[Member.Member] = Party.aliveOf(rec(b)#party) |> List.filter(m -> not isAsleep(m, b))

    /// 組に noFlee の敵がいるか（逃げられない）。
    pub def isNoFlee(res: Res.Res, b: Battle): Bool =
        rec(b)#foes |> Vector.exists(f -> FoesDoc.foeOrBlank(res#foes, f#id)#noFlee)

    /// 倒した時の経験値とお金の合計（敵の Doc の exp と gold）。
    pub def rewardsOf(res: Res.Res, b: Battle): { exp = Int32, gold = Int32 } =
        let foes = rec(b)#foes |> Vector.toList |> List.map(f -> FoesDoc.foeOrBlank(res#foes, f#id));
        { exp = foes |> List.map(f -> f#exp) |> List.sum, gold = foes |> List.map(f -> f#gold) |> List.sum }

    /// 戦いで使える道具か（使う物で、HP か MP を戻すか敵にダメージを与える）。せいすい・装備・だいじなものは使えない。
    pub def isBattleItem(item: ItemsDoc.Item): Bool =
        item#kind == ItemsDoc.Kind.Use and (item#heal > 0 or item#mpHeal > 0 or item#burn > 0)

    /// 道具の的の向き（burn の物は敵 1 体・ほかは仲間 1 人）。
    pub def itemAimOf(item: ItemsDoc.Item): SpellsDoc.Aim =
        if (item#burn > 0) SpellsDoc.Aim.Foe else SpellsDoc.Aim.Ally

    /// 仲間の名前。
    def nameOf(res: Res.Res, m: Member.Member): String = PartyDoc.memberOf(m, res#party)#name

    // ── 式 ──

    /// ダメージ: max(1, round((atk − def ÷ 2) × (1 − spread + 2 × spread × r)))。
    pub def damageOf(spread: Float64, atk: Int32, defense: Int32, r: Float64): Int32 =
        let base = Int32.toFloat64(atk) - Int32.toFloat64(defense) / 2.0;
        let scaled = base * (1.0 - spread + 2.0 * spread * r);
        Int32.max(1, Float64.round(scaled) |> Float64.tryToInt32 |> Option.getWithDefault(1))

    /// 呪文の数（ダメージか回復）: max(1, round(power × (0.9 + 0.2 × r)))。まもりを見ない。
    def spellPowerOf(power: Int32, r: Float64): Int32 =
        Int32.max(1, Float64.round(Int32.toFloat64(power) * (0.9 + 0.2 * r)) |> Float64.tryToInt32 |> Option.getWithDefault(1))

    /// 半分（切り上げ）。ぼうぎょ・guard の時。
    def halfOf(n: Int32): Int32 = (n + 1) / 2

    /// にげる率: fleeBase + (仲間の一番速い − 敵の一番速い) × fleeSlope を 0.1..0.95 に収める。
    pub def fleeRateOf(res: Res.Res, b: Battle): Float64 =
        let rules = RulesDoc.rec(res#rules);
        let r = rec(b);
        let allyAgi = Party.aliveOf(r#party) |> List.map(m -> Party.agiOf(res#party, m, r#party)) |> List.maximum |> Option.getWithDefault(0);
        let foeAgi = aliveFoes(b) |> List.filterMap(i -> Vector.nth(i, r#foes)) |> List.map(f -> FoesDoc.foeOrBlank(res#foes, f#id)#agi)
            |> List.maximum |> Option.getWithDefault(0);
        Num.clamp(0.1, 0.95, rules#fleeBase + Int32.toFloat64(allyAgi - foeAgi) * rules#fleeSlope)

    /// 乱数を 1 つ引く（回数 dice から。戦いの式は World を持たないので回数だけを受け渡す）。
    def roll(channel: Dice.Channel, dice: Int32): (Float64, Int32) =
        let (r, next) = Dice.roll(channel, { dice = dice });
        (r, next#dice)

    // ── 1 ターン ──

    /// 手番の持ち主。
    enum Actor with Eq {
        case Ally(Member.Member)
        case Foe(Int32)
    }

    /// 1 ターンを解く間の値: 今の戦い・出した Beat（新しい順）・乱数の回数。
    type alias Turn = { b = Battle, beats = List[Beat], dice = Int32 }

    /// 1 ターン: plans（行動を選んだ仲間の行動。無い人は たたかう で先頭の敵）を受け、敵の技を選び、すばやさ順に 1 手ずつ行う。
    /// 眠っている人は plans によらず眠りの手番になる。返すのはターンの後の戦い・1 手ずつの Beat（行った順）・乱数の回数。
    pub def resolveRound(res: Res.Res, b0: Battle, plans: Map[Member.Member, Plan], dice0: Int32): (Battle, List[Beat], Int32) =
        let (acts, dice1) = foeActsOf(res, b0, dice0);
        let defending = plans |> Map.toList |> List.filter(p -> snd(p) == Plan.Defend) |> List.map(fst) |> List.toSet;
        let guarding = acts |> Map.toList |> List.filter(p -> snd(p) == Act.Guard) |> List.map(fst) |> List.toSet;
        let b1 = wrap({ guarding = guarding, defending = defending | rec(b0) });
        let (order, dice2) = turnOrderOf(res, b1, dice1);
        let fleeing = plans |> Map.valuesOf |> List.exists(p -> p == Plan.Flee);
        let done = order |> List.foldLeft((turn, actor) ->
            if (outcomeOf(turn#b) != Outcome.Ongoing) turn else turnOf(res, plans, acts, fleeing, actor, turn),
            { b = b1, beats = Nil, dice = dice2 });
        let after = wrap({ guarding = Set.empty(), defending = Set.empty() | rec(done#b) });
        (after, List.reverse(done#beats), done#dice)

    /// 生きている敵ごとに、このターンの技（phase の行から重み付きに。行が無ければ attack）。
    def foeActsOf(res: Res.Res, b: Battle, dice: Int32): (Map[Int32, Act], Int32) =
        aliveFoes(b) |> List.foldLeft((acc, i) -> {
            let (out, d) = acc;
            let foe = Vector.nth(i, rec(b)#foes);
            let rows = foe |> Option.map(f -> FoeMovesDoc.movesOf(res#foeMoves, FoesDoc.keyOf(f#id), if (f#phase2) 2 else 1)) |> Option.getWithDefault(Nil);
            let (picked, next) = Dice.weighted(Dice.Channel.FoeMove, rows, { dice = d });
            (Map.insert(i, Option.getWithDefault(Act.Attack, picked), out), next#dice)
        }, (Map.empty(), dice))

    /// 行動順: すばやさ × (1 + 0.25 × r) の大きい順（同じ値は仲間が先、その中は並びの順）。
    def turnOrderOf(res: Res.Res, b: Battle, dice: Int32): (List[Actor], Int32) =
        let r = rec(b);
        let allies = Party.aliveOf(r#party) |> List.map(m -> (Actor.Ally(m), Party.agiOf(res#party, m, r#party)));
        let foes = aliveFoes(b) |> List.map(i -> (Actor.Foe(i), Vector.nth(i, r#foes) |> Option.map(f -> FoesDoc.foeOrBlank(res#foes, f#id)#agi) |> Option.getWithDefault(0)));
        let (keyed, next) = List.append(allies, foes) |> List.zipWithIndex |> List.foldLeft((acc, entry) -> {
            let (out, d) = acc;
            let (at, (actor, agi)) = entry;
            let (roll1, d1) = roll(Dice.Channel.Order, d);
            let speed = Int32.toFloat64(agi) * (1.0 + 0.25 * roll1);
            let side = match actor {
                case Actor.Ally(_) => 0
                case Actor.Foe(_)  => 1
            };
            (((0.0 - speed, side, at), actor) :: out, d1)
        }, (Nil, dice));
        (keyed |> List.sortBy(fst) |> List.map(snd), next)

    def turnOf(res: Res.Res, plans: Map[Member.Member, Plan], acts: Map[Int32, Act], fleeing: Bool, actor: Actor, turn: Turn): Turn =
        match actor {
            case Actor.Ally(m) if Party.isAlive(m, rec(turn#b)#party) => allyTurn(res, m, planOf(plans, fleeing, m), turn)
            case Actor.Ally(_) => turn
            case Actor.Foe(i) if isFoeAlive(i, turn#b) => foeTurn(res, i, Map.getWithDefault(i, Act.Attack, acts), turn)
            case Actor.Foe(_) => turn
        }

    /// その人の行動。誰かが にげる を選んだターンは、にげる人のほかは何もしない（None）。
    def planOf(plans: Map[Member.Member, Plan], fleeing: Bool, m: Member.Member): Option[Plan] =
        match Map.get(m, plans) {
            case Some(Plan.Flee)        => Some(Plan.Flee)
            case _ if fleeing           => None
            case Some(plan)             => Some(plan)
            case None                   => Some(Plan.Attack(0))
        }

    def isFoeAlive(i: Int32, b: Battle): Bool = Vector.nth(i, rec(b)#foes) |> Option.exists(f -> f#hp > 0)

    def push(lines: List[Msg], fx: Option[Fx], b: Battle, dice: Int32, turn: Turn): Turn =
        { b = b, beats = beatOf({ lines = lines, fx = fx, after = b }) :: turn#beats, dice = dice }

    /// wanted が倒れていれば生きている先頭の敵（全員倒れていれば None）。
    def liveFoeOf(wanted: Int32, b: Battle): Option[(Int32, FoeState)] =
        let target = if (isFoeAlive(wanted, b)) Some(wanted) else List.head(aliveFoes(b));
        target |> Option.flatMap(t -> Vector.nth(t, rec(b)#foes) |> Option.map(foe -> (t, foe)))

    /// 敵 t に raw のダメージ（guard していれば半分）。HP が phase2At を切ったら phase 2 へ。伝言の行は新しい順に積む。
    def damageFoe(res: Res.Res, t: Int32, raw: Int32, acc: (List[Msg], Battle)): (List[Msg], Battle) =
        let (lines, b) = acc;
        let r = rec(b);
        match Vector.nth(t, r#foes) {
            case None      => acc
            case Some(foe) =>
                let doc = FoesDoc.foeOrBlank(res#foes, foe#id);
                let dealt = if (Set.memberOf(t, r#guarding)) halfOf(raw) else raw;
                let hp = Int32.max(0, foe#hp - dealt);
                let phase2 = foe#phase2 or (doc#phase2At > 0.0 and Int32.toFloat64(hp) < doc#phase2At * Int32.toFloat64(doc#hp));
                let hit = msg(BattleText.FoeDamaged, (Placeholder.Target, foe#label) :: (Placeholder.N, "${dealt}") :: Nil);
                let down = if (hp <= 0) msg(BattleText.FoeDown, (Placeholder.Target, foe#label) :: Nil) :: Nil else Nil;
                (List.append(down, hit :: lines), wrap({ foes = Vector.update(t, { hp = hp, phase2 = phase2 | foe }, r#foes) | r }))
        }

    /// 仲間 m に raw のダメージ（ぼうぎょ していれば半分）。倒れたら眠りも消す。伝言の行は新しい順に積む。
    def damageAlly(res: Res.Res, m: Member.Member, raw: Int32, acc: (List[Msg], Battle)): (List[Msg], Battle) =
        let (lines, b) = acc;
        let r = rec(b);
        let dealt = if (Set.memberOf(m, r#defending)) halfOf(raw) else raw;
        let hp = Int32.max(0, Party.hpOf(m, r#party) - dealt);
        let party = Party.withHpMp(res#party, m, hp, Party.mpOf(m, r#party), r#party);
        let name = nameOf(res, m);
        let hit = msg(BattleText.AllyDamaged, (Placeholder.Target, name) :: (Placeholder.N, "${dealt}") :: Nil);
        let down = if (hp <= 0) msg(BattleText.AllyDown, (Placeholder.Target, name) :: Nil) :: Nil else Nil;
        let asleep = if (hp <= 0) Map.remove(m, r#asleep) else r#asleep;
        (List.append(down, hit :: lines), wrap({ party = party, asleep = asleep | r }))

    /// 仲間 m の HP を amount まで戻す（最大で止める）。倒れている人には効かない。戻した数の行を新しい順に積む。
    def healAlly(res: Res.Res, m: Member.Member, amount: Int32, acc: (List[Msg], Battle)): (List[Msg], Battle) =
        let (lines, b) = acc;
        let r = rec(b);
        if (not Party.isAlive(m, r#party)) (msg(BattleText.NoEffect, Nil) :: lines, b)
        else {
            let gained = Int32.min(amount, Party.maxHpOf(res#party, m, r#party) - Party.hpOf(m, r#party));
            let party = Party.recover(res#party, m, { hp = gained, mp = 0 }, r#party);
            (msg(BattleText.AllyHealed, (Placeholder.Target, nameOf(res, m)) :: (Placeholder.N, "${gained}") :: Nil) :: lines, wrap({ party = party | r }))
        }

    // ── 仲間の手番 ──

    /// 眠っている人は眠りの手番、ほかは選んだ行動。
    def allyTurn(res: Res.Res, m: Member.Member, plan: Option[Plan], turn: Turn): Turn =
        match Map.get(m, rec(turn#b)#asleep) {
            case Some(slept) => sleepingTurn(res, m, slept, turn)
            case None        => allyAct(res, m, plan, turn)
        }

    def allyAct(res: Res.Res, m: Member.Member, plan: Option[Plan], turn: Turn): Turn =
        match plan {
            case Some(Plan.Attack(t))         => allyAttack(res, m, t, turn)
            case Some(Plan.Defend)            => push(msg(BattleText.Defend, (Placeholder.Name, nameOf(res, m)) :: Nil) :: Nil, None, turn#b, turn#dice, turn)
            case Some(Plan.Flee)              => tryFlee(res, m, turn)
            case Some(Plan.Cast(id, target))  => allyCast(res, m, id, target, turn)
            case Some(Plan.UseItem(id, target)) => allyUseItem(res, m, id, target, turn)
            case None                         => turn
        }

    /// 眠りの手番: 眠った次の手番（slept = 0）は必ず眠る。その後は wakeRate で起きる（起きた手番は動かない）。
    def sleepingTurn(res: Res.Res, m: Member.Member, slept: Int32, turn: Turn): Turn =
        let r = rec(turn#b);
        let name = (Placeholder.Name, nameOf(res, m)) :: Nil;
        let (wake, d1) = if (slept <= 0) (1.0, turn#dice) else roll(Dice.Channel.Wake, turn#dice);
        if (wake < RulesDoc.rec(res#rules)#wakeRate)
            push(msg(BattleText.Woke, name) :: Nil, None, wrap({ asleep = Map.remove(m, r#asleep) | r }), d1, turn)
        else push(msg(BattleText.Asleep, name) :: Nil, None, wrap({ asleep = Map.insert(m, slept + 1, r#asleep) | r }), d1, turn)

    /// たたかう: 倒れた的は生きている先頭の敵へ振り替える。会心は まもり を 0 として 1.5 倍。guard した敵へは半分。
    def allyAttack(res: Res.Res, m: Member.Member, wanted: Int32, turn: Turn): Turn =
        match liveFoeOf(wanted, turn#b) {
            case None            => turn
            case Some((t, foe))  => strikeFoe(res, m, t, foe, turn)
        }

    def strikeFoe(res: Res.Res, m: Member.Member, t: Int32, foe: FoeState, turn: Turn): Turn =
        let rules = RulesDoc.rec(res#rules);
        let doc = FoesDoc.foeOrBlank(res#foes, foe#id);
        let (critRoll, d1) = roll(Dice.Channel.Critical, turn#dice);
        let (spreadRoll, d2) = roll(Dice.Channel.Damage, d1);
        let critical = critRoll < rules#critRate;
        let atk = Party.atkOf(res#party, res#items, m, rec(turn#b)#party);
        let raw = if (critical) Float64.round(Int32.toFloat64(damageOf(rules#spread, atk, 0, spreadRoll)) * 1.5) |> Float64.tryToInt32 |> Option.getWithDefault(1)
                  else damageOf(rules#spread, atk, doc#defense, spreadRoll);
        let head = msg(BattleText.Attack, (Placeholder.Name, nameOf(res, m)) :: Nil);
        let crit = if (critical) msg(BattleText.Critical, Nil) :: Nil else Nil;
        let (lines, after) = damageFoe(res, t, raw, (List.append(crit, head :: Nil), turn#b));
        push(List.reverse(lines), fxOf(res, FxKind.Slash, Target.Foe(t), false), after, d2, turn)

    /// じゅもん: MP が足りなければ手番を使うだけ。足りれば MP を使い、呪文の的（aim）ごとに効かせる。
    def allyCast(res: Res.Res, m: Member.Member, id: SpellsDoc.SpellId, target: Target, turn: Turn): Turn =
        let head = msg(BattleText.Cast, (Placeholder.Name, nameOf(res, m)) :: (Placeholder.Spell, SpellsDoc.nameOf(res#spells, id)) :: Nil);
        let r = rec(turn#b);
        match SpellsDoc.spellOf(res#spells, id) {
            case Some(spell) if Party.mpOf(m, r#party) >= spell#mp =>
                let paid = wrap({ party = Party.withHpMp(res#party, m, Party.hpOf(m, r#party), Party.mpOf(m, r#party) - spell#mp, r#party) | r });
                castBy(res, spell, head, target, { b = paid | turn })
            case Some(_) => push(head :: msg(BattleText.MpShort, Nil) :: Nil, None, turn#b, turn#dice, turn)
            case None    => push(head :: msg(BattleText.NoEffect, Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    /// 仲間が唱えた呪文を的に効かせる（Foe は振り替える・AllFoes は生きている敵全部・Ally は target の仲間）。
    def castBy(res: Res.Res, spell: SpellsDoc.Spell, head: Msg, target: Target, turn: Turn): Turn =
        match (spell#aim, target) {
            case (SpellsDoc.Aim.Foe, Target.Foe(wanted)) => castOnFoe(res, spell, head, wanted, turn)
            case (SpellsDoc.Aim.Foe, _)                  => castOnFoe(res, spell, head, 0, turn)
            case (SpellsDoc.Aim.AllFoes, _)              => castOnAllFoes(res, spell, head, turn)
            case (SpellsDoc.Aim.Ally, Target.Ally(m))    => castOnAlly(res, spell, head, m, turn)
            case (SpellsDoc.Aim.Ally, _)                 => push(head :: msg(BattleText.NoEffect, Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    def castOnFoe(res: Res.Res, spell: SpellsDoc.Spell, head: Msg, wanted: Int32, turn: Turn): Turn =
        match liveFoeOf(wanted, turn#b) {
            case None         => push(head :: Nil, None, turn#b, turn#dice, turn)
            case Some((t, _)) =>
                let (r1, d1) = roll(Dice.Channel.Damage, turn#dice);
                let (lines, after) = damageFoe(res, t, spellPowerOf(spell#power, r1), (head :: Nil, turn#b));
                push(List.reverse(lines), fxOf(res, FxKind.Spell(spell#fx), Target.Foe(t), false), after, d1, turn)
        }

    def castOnAllFoes(res: Res.Res, spell: SpellsDoc.Spell, head: Msg, turn: Turn): Turn =
        let (lines, after, d) = aliveFoes(turn#b) |> List.foldLeft((acc, t) -> {
            let (ls, b, dice) = acc;
            let (r1, d1) = roll(Dice.Channel.Damage, dice);
            let (ls2, b2) = damageFoe(res, t, spellPowerOf(spell#power, r1), (ls, b));
            (ls2, b2, d1)
        }, (head :: Nil, turn#b, turn#dice));
        push(List.reverse(lines), fxOf(res, FxKind.Spell(spell#fx), Target.AllFoes, false), after, d, turn)

    def castOnAlly(res: Res.Res, spell: SpellsDoc.Spell, head: Msg, m: Member.Member, turn: Turn): Turn =
        let (r1, d1) = roll(Dice.Channel.Damage, turn#dice);
        let (lines, after) = healAlly(res, m, spellPowerOf(spell#power, r1), (head :: Nil, turn#b));
        push(List.reverse(lines), fxOf(res, FxKind.Spell(spell#fx), Target.Ally(m), false), after, d1, turn)

    /// どうぐ: ふくろに無ければ手番を使うだけ。あれば 1 つ減らし、burn の物は敵 1 体（振り替える）、ほかは仲間 1 人に効かせる。
    def allyUseItem(res: Res.Res, m: Member.Member, id: ItemsDoc.ItemId, target: Target, turn: Turn): Turn =
        let itemName = (Placeholder.Item, ItemsDoc.nameOf(res#items, id));
        let head = msg(BattleText.UseItem, (Placeholder.Name, nameOf(res, m)) :: itemName :: Nil);
        let r = rec(turn#b);
        match ItemsDoc.itemOf(res#items, id) {
            case Some(item) if Bag.countOf(id, r#bag) > 0 =>
                let used = { b = wrap({ bag = Bag.give(id, -1, r#bag) | r }) | turn };
                useOn(res, item, head, target, used)
            case _ => push(head :: msg(BattleText.ItemGone, itemName :: Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    def useOn(res: Res.Res, item: ItemsDoc.Item, head: Msg, target: Target, turn: Turn): Turn =
        match (itemAimOf(item), target) {
            case (SpellsDoc.Aim.Foe, Target.Foe(wanted)) => burnFoe(res, item, head, wanted, turn)
            case (SpellsDoc.Aim.Foe, _)                  => burnFoe(res, item, head, 0, turn)
            case (_, Target.Ally(m))                     => mendAlly(res, item, head, m, turn)
            case _                                       => push(head :: msg(BattleText.NoEffect, Nil) :: Nil, None, turn#b, turn#dice, turn)
        }

    def burnFoe(res: Res.Res, item: ItemsDoc.Item, head: Msg, wanted: Int32, turn: Turn): Turn =
        match liveFoeOf(wanted, turn#b) {
            case None         => push(head :: Nil, None, turn#b, turn#dice, turn)
            case Some((t, _)) =>
                let (lines, after) = damageFoe(res, t, item#burn, (head :: Nil, turn#b));
                push(List.reverse(lines), fxOf(res, FxKind.Burn, Target.Foe(t), false), after, turn#dice, turn)
        }

    /// HP と MP を戻す道具（それぞれ最大で止める。倒れている人には効かない）。
    def mendAlly(res: Res.Res, item: ItemsDoc.Item, head: Msg, m: Member.Member, turn: Turn): Turn =
        let (healed, b1) = if (item#heal > 0) healAlly(res, m, item#heal, (head :: Nil, turn#b)) else (head :: Nil, turn#b);
        let r = rec(b1);
        let gainMp = Int32.min(item#mpHeal, Party.maxMpOf(res#party, m, r#party) - Party.mpOf(m, r#party));
        let mpLine = msg(BattleText.AllyMpHealed, (Placeholder.Target, nameOf(res, m)) :: (Placeholder.N, "${gainMp}") :: Nil);
        let (lines, after) = if (item#mpHeal > 0 and Party.isAlive(m, r#party))
                                 (mpLine :: healed, wrap({ party = Party.recover(res#party, m, { hp = 0, mp = gainMp }, r#party) | r }))
                             else (healed, b1);
        push(List.reverse(lines), fxOf(res, FxKind.Mend, Target.Ally(m), false), after, turn#dice, turn)

    /// にげる: noFlee の組では「にげられない」で手番を使う。率は fleeRateOf。
    def tryFlee(res: Res.Res, m: Member.Member, turn: Turn): Turn =
        let head = msg(BattleText.Run, (Placeholder.Name, nameOf(res, m)) :: Nil);
        if (isNoFlee(res, turn#b)) push(head :: msg(BattleText.NoFlee, Nil) :: Nil, None, turn#b, turn#dice, turn)
        else {
            let (r, d1) = roll(Dice.Channel.Flee, turn#dice);
            if (r < fleeRateOf(res, turn#b))
                push(head :: msg(BattleText.Fled, Nil) :: Nil, None, wrap({ fled = true | rec(turn#b) }), d1, turn)
            else push(head :: msg(BattleText.Blocked, Nil) :: Nil, None, turn#b, d1, turn)
        }

    // ── 敵の手番 ──

    def foeTurn(res: Res.Res, i: Int32, act: Act, turn: Turn): Turn =
        let label = Vector.nth(i, rec(turn#b)#foes) |> Option.map(f -> f#label) |> Option.getWithDefault("");
        match act {
            case Act.Guard      => push(msg(BattleText.Guard, (Placeholder.Name, label) :: Nil) :: Nil, None, turn#b, turn#dice, turn)
            case Act.Attack     => foeAttack(res, i, label, turn)
            case Act.Sweep      => foeSweep(res, i, label, turn)
            case Act.Sleep      => foeSleep(res, label, turn)
            case Act.Spell(key) => foeCast(res, i, label, key, turn)
        }

    /// 生きている仲間から 1 人を引く。
    def pickAlly(turn: Turn): (Option[Member.Member], Int32) =
        let alive = Party.aliveOf(rec(turn#b)#party);
        let (picked, next) = Dice.weighted(Dice.Channel.FoeTarget, alive |> List.map(m -> (m, 1)), { dice = turn#dice });
        (picked, next#dice)

    /// 生きている仲間から 1 人を引いて叩く。
    def foeAttack(res: Res.Res, i: Int32, label: String, turn: Turn): Turn =
        match pickAlly(turn) {
            case (None, _)    => turn
            case (Some(m), d) =>
                let (lines, b, d1) = hitAlly(res, i, 1.0, m, (Nil, turn#b, d));
                push(msg(BattleText.Attack, (Placeholder.Name, label) :: Nil) :: List.reverse(lines), fxOf(res, FxKind.Hit, Target.Ally(m), true), b, d1, turn)
        }

    /// 生きている仲間全員を ちから × 0.6 で叩く。
    def foeSweep(res: Res.Res, i: Int32, label: String, turn: Turn): Turn =
        let (lines, b, d) = Party.aliveOf(rec(turn#b)#party) |> List.foldLeft((acc, m) -> hitAlly(res, i, 0.6, m, acc), (Nil, turn#b, turn#dice));
        push(msg(BattleText.Sweep, (Placeholder.Name, label) :: Nil) :: List.reverse(lines), fxOf(res, FxKind.Hit, Target.AllAllies, true), b, d, turn)

    /// 敵 i が仲間 m を、ちから × scale で叩く（ぼうぎょ していれば半分）。伝言の行は新しい順に積む。
    def hitAlly(res: Res.Res, i: Int32, scale: Float64, m: Member.Member, acc: (List[Msg], Battle, Int32)): (List[Msg], Battle, Int32) =
        let (lines, b, dice) = acc;
        let r = rec(b);
        let doc = Vector.nth(i, r#foes) |> Option.map(f -> FoesDoc.foeOrBlank(res#foes, f#id));
        let atk = doc |> Option.map(f -> Float64.round(Int32.toFloat64(f#atk) * scale) |> Float64.tryToInt32 |> Option.getWithDefault(0)) |> Option.getWithDefault(0);
        let (spreadRoll, d1) = roll(Dice.Channel.Damage, dice);
        let raw = damageOf(RulesDoc.rec(res#rules)#spread, atk, Party.defenseOf(res#party, res#items, m, r#party), spreadRoll);
        let (lines1, b1) = damageAlly(res, m, raw, (lines, b));
        (lines1, b1, d1)

    /// 生きている仲間から 1 人を引き、眠っていなければ sleepRate で眠らせる（眠った次の手番は必ず眠る）。
    def foeSleep(res: Res.Res, label: String, turn: Turn): Turn =
        let head = msg(BattleText.SleepAct, (Placeholder.Name, label) :: Nil);
        match pickAlly(turn) {
            case (None, _)    => turn
            case (Some(m), d) =>
                let (r1, d1) = roll(Dice.Channel.Sleep, d);
                let target = (Placeholder.Target, nameOf(res, m)) :: Nil;
                let r = rec(turn#b);
                if (isAsleep(m, turn#b) or r1 >= RulesDoc.rec(res#rules)#sleepRate)
                    push(head :: msg(BattleText.SleepMiss, target) :: Nil, None, turn#b, d1, turn)
                else push(head :: msg(BattleText.FellAsleep, target) :: Nil, fxOf(res, FxKind.Hit, Target.Ally(m), true),
                          wrap({ asleep = Map.insert(m, 0, r#asleep) | r }), d1, turn)
        }

    /// 敵が呪文（rpg.spells.json の鍵）を唱える。敵 1 体向けの呪文は仲間 1 人へ・敵全部向けは仲間全員へ・回復は唱えた敵自身へ。
    /// 鍵が Doc に無ければ たたかう。
    def foeCast(res: Res.Res, i: Int32, label: String, key: String, turn: Turn): Turn =
        match SpellsDoc.idOf(res#spells, key) |> Option.flatMap(id -> SpellsDoc.spellOf(res#spells, id) |> Option.map(s -> (id, s))) {
            case None              => foeAttack(res, i, label, turn)
            case Some((id, spell)) =>
                let head = msg(BattleText.Cast, (Placeholder.Name, label) :: (Placeholder.Spell, SpellsDoc.nameOf(res#spells, id)) :: Nil);
                foeCastAt(res, i, spell, head, turn)
        }

    def foeCastAt(res: Res.Res, i: Int32, spell: SpellsDoc.Spell, head: Msg, turn: Turn): Turn =
        match spell#aim {
            case SpellsDoc.Aim.Foe     => foeSpellOnOne(res, spell, head, turn)
            case SpellsDoc.Aim.AllFoes =>
                let (lines, b, d) = Party.aliveOf(rec(turn#b)#party) |> List.foldLeft((acc, m) -> spellOnAlly(res, spell, m, acc), (head :: Nil, turn#b, turn#dice));
                push(List.reverse(lines), fxOf(res, FxKind.Spell(spell#fx), Target.AllAllies, true), b, d, turn)
            case SpellsDoc.Aim.Ally    => foeHealSelf(res, i, spell, head, turn)
        }

    def foeSpellOnOne(res: Res.Res, spell: SpellsDoc.Spell, head: Msg, turn: Turn): Turn =
        match pickAlly(turn) {
            case (None, _)    => turn
            case (Some(m), d) =>
                let (lines, b, d1) = spellOnAlly(res, spell, m, (head :: Nil, turn#b, d));
                push(List.reverse(lines), fxOf(res, FxKind.Spell(spell#fx), Target.Ally(m), true), b, d1, turn)
        }

    /// 呪文のダメージを仲間 m に（まもりを見ない・ぼうぎょ していれば半分）。
    def spellOnAlly(res: Res.Res, spell: SpellsDoc.Spell, m: Member.Member, acc: (List[Msg], Battle, Int32)): (List[Msg], Battle, Int32) =
        let (lines, b, dice) = acc;
        let (r1, d1) = roll(Dice.Channel.Damage, dice);
        let (lines1, b1) = damageAlly(res, m, spellPowerOf(spell#power, r1), (lines, b));
        (lines1, b1, d1)

    def foeHealSelf(res: Res.Res, i: Int32, spell: SpellsDoc.Spell, head: Msg, turn: Turn): Turn =
        let r = rec(turn#b);
        match Vector.nth(i, r#foes) {
            case None      => turn
            case Some(foe) =>
                let (r1, d1) = roll(Dice.Channel.Damage, turn#dice);
                let top = FoesDoc.foeOrBlank(res#foes, foe#id)#hp;
                let gained = Int32.min(spellPowerOf(spell#power, r1), top - foe#hp);
                let after = wrap({ foes = Vector.update(i, { hp = foe#hp + gained | foe }, r#foes) | r });
                push(head :: msg(BattleText.FoeHealed, (Placeholder.Target, foe#label) :: (Placeholder.N, "${gained}") :: Nil) :: Nil,
                     fxOf(res, FxKind.Spell(spell#fx), Target.Foe(i), false), after, d1, turn)
        }

    // ── 終わり ──

    /// 勝った後: 経験値（敵の合計）を生きている仲間がそれぞれ全部受け取る。返すのは受け取った後の戦いと、
    /// 「やっつけた」・経験値・お金（あれば）・レベルアップ（上がった Lv ごとに 1 枚と、その Lv で覚えた呪文ごとに 1 枚）の Beat。
    /// お金をふくろへ入れるのは戦いを終える側。
    pub def resolveVictory(res: Res.Res, b: Battle): (Battle, List[Beat]) =
        let rewards = rewardsOf(res, b);
        let party0 = rec(b)#party;
        let (party, ups) = Party.aliveOf(party0) |> List.foldLeft((acc, m) -> {
            let (p, out) = acc;
            let (next, gained) = Party.gainExp(res#party, m, rewards#exp, p);
            (next, List.append(out, gained))
        }, (party0, Nil));
        let after = wrap({ party = party | rec(b) });
        let line = (text, values) -> beatOf({ lines = msg(text, values) :: Nil, fx = None, after = after });
        let upBeats = ups |> List.flatMap(match (who, lv) -> {
            let name = (Placeholder.Name, nameOf(res, who));
            let learned = PartyDoc.spellKeysLearnedAt(who, lv, res#party) |> List.filterMap(SpellsDoc.idOf(res#spells))
                |> List.map(id -> line(BattleText.Learned, name :: (Placeholder.Spell, SpellsDoc.nameOf(res#spells, id)) :: Nil));
            line(BattleText.LevelUp, name :: (Placeholder.Lv, "${lv}") :: Nil) :: learned
        });
        let beats = List.flatten(
            (line(BattleText.Won, Nil) :: line(BattleText.Exp, (Placeholder.N, "${rewards#exp}") :: Nil) :: Nil) ::
            (if (rewards#gold > 0) line(BattleText.GoldGot, (Placeholder.N, "${rewards#gold}") :: Nil) :: Nil else Nil) ::
            upBeats :: Nil);
        (after, beats)

    /// 仲間を置き換えた戦い。
    pub def withParty(party: Party.Party, b: Battle): Battle = wrap({ party = party | rec(b) })

    /// 全滅した時の 1 枚（演出なし）。
    pub def wipedBeat(b: Battle): Beat = beatOf({ lines = msg(BattleText.Wiped, Nil) :: Nil, fx = None, after = b })

    // ── 読み直し ──

    /// Doc を読み直した後に収める: 仲間の HP / MP を新しい最大へ、敵の HP を新しい最大へ、消えた道具をふくろから捨てる。
    pub def settle(res: Res.Res, b: Battle): Battle =
        let r = rec(b);
        wrap({ party = Party.settle(res#party, res#items, r#party), bag = Bag.settle(res#items, r#bag),
               foes = r#foes |> Vector.map(f -> { hp = Int32.min(f#hp, FoesDoc.foeOrBlank(res#foes, f#id)#hp) | f }) | r })
}
