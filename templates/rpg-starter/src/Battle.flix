// Battle — 戦いの式（すべて純粋。時計とフレームを見ない）。
// 1 ターン = 眠っていない生きている仲間全員の行動（Plan）を受け、敵の技を選び、敵味方をすばやさ順に 1 つずつ行う。
// 1 手ごとに伝言と、その手の後の戦いの値を Beat に残す（見せる側の WorldBattle は Beat を 1 つずつ演出し、
// HP の表示は今見せている Beat の after を読む）。つり合いのシミュレーション（BalanceSim）も同じ BattleActs.resolveRound を回す。
// ここは型・始まり・読む口・式・勝った後（resolveVictory）。1 ターンの組み立て（BattleActs.resolveRound）と 1 手の中身
// （仲間の行動・呪文・道具・敵の技）は BattleActs（依存は BattleActs → Battle の一方通行）。
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

    /// 戦いの値（作るのは start・書き替えは wrap。中身は rec で読む）。
    pub type alias Battle = BattleOf

    pub def rec(b: Battle): Rec = match b { case BattleOf.BattleOf(r) => r }

    /// 中身から戦いの値を組み直す。
    /// WhyNot: pub でも外の規則から呼ばない — 1 手の式（BattleActs）が値を書き替えるためだけに開けてある。
    pub def wrap(r: Rec): Battle = BattleOf.BattleOf(r)

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

    /// 伝言の 1 行: 言葉の名前と、埋める値。字にするのは View（TextDoc.battleText）。
    pub type alias Msg = { text = BattleText, values = List[(Placeholder, String)] }

    /// 1 手ぶん: 伝言の行・演出・その手の後の戦いの値。
    pub type alias BeatRec = { lines = List[Msg], fx = Option[Fx], after = Battle }

    /// WhyNot: record のまま List に入れない — World の型に Beat の中身が展開されて大きくなる。
    enum BeatOf(BeatRec)

    pub type alias Beat = BeatOf

    /// 1 手（伝言・演出・その手の後の戦い）を組む。
    pub def beatOf(r: BeatRec): Beat = BeatOf.BeatOf(r)

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

    /// 伝言 1 行。
    pub def msg(text: BattleText, values: List[(Placeholder, String)]): Msg = { text = text, values = values }

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
    pub def nameOf(res: Res.Res, m: Member.Member): String = PartyDoc.memberOf(m, res#party)#name

    // ── 式 ──

    /// ダメージ: max(1, round((atk − def ÷ 2) × (1 − spread + 2 × spread × r)))。
    pub def damageOf(spread: Float64, atk: Int32, defense: Int32, r: Float64): Int32 =
        let base = Int32.toFloat64(atk) - Int32.toFloat64(defense) / 2.0;
        let scaled = base * (1.0 - spread + 2.0 * spread * r);
        Int32.max(1, Float64.round(scaled) |> Float64.tryToInt32 |> Option.getWithDefault(1))

    /// にげる率: fleeBase + (仲間の一番速い − 敵の一番速い) × fleeSlope を 0.1..0.95 に収める。
    pub def fleeRateOf(res: Res.Res, b: Battle): Float64 =
        let rules = RulesDoc.rec(res#rules);
        let r = rec(b);
        let allyAgi = Party.aliveOf(r#party) |> List.map(m -> Party.agiOf(res#party, m, r#party)) |> List.maximum |> Option.getWithDefault(0);
        let foeAgi = aliveFoes(b) |> List.filterMap(i -> Vector.nth(i, r#foes)) |> List.map(f -> FoesDoc.foeOrBlank(res#foes, f#id)#agi)
            |> List.maximum |> Option.getWithDefault(0);
        Num.clamp(0.1, 0.95, rules#fleeBase + Int32.toFloat64(allyAgi - foeAgi) * rules#fleeSlope)

    /// 乱数を 1 つ引く（回数 dice から。戦いの式は World を持たないので回数だけを受け渡す）。
    pub def roll(channel: Dice.Channel, dice: Int32): (Float64, Int32) =
        let (r, next) = Dice.roll(channel, { dice = dice });
        (r, next#dice)

    /// i 番の敵が生きているか。
    pub def isFoeAlive(i: Int32, b: Battle): Bool = Vector.nth(i, rec(b)#foes) |> Option.exists(f -> f#hp > 0)

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
