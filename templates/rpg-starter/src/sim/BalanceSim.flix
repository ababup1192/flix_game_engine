// BalanceSim — つり合いのシミュレーション（make balance → debug/balance.md）。戦いだけを流す。
// Battle.resolveRound を直に回し、フレームも時計も WorldBattle も通さない。行動は bot と同じ方針（Bot.battlePlans: 回復の呪文・やくそう・
// 逃げられない組での攻めの呪文と ばくだんいし）。1 戦ごとに区間の初めの HP / MP（最大）とふくろから始める。
// テストではなく知らせる口（重いので make test に入れない。終了コードはいつも 0）。外れた行には ⚠ を付ける。
// 外れたら Doc（敵の値・出会いの組・経験値）の数だけで直して流し直す。式は直さない（直す時は docs/PLAN.md を先に直す）。
//   BALANCE_SEEDS=n … 1 組あたりの種の数（既定 500）
mod BalanceSim {
    use fge::App

    import java.lang.System

    /// 区間のパーティ: マップ・仲間・Lv・付けている物（ぶき・よろい。空は Doc の初めの物のまま）・ふくろ（道具の鍵と数）・
    /// encounters = マップの出会いの組を流すか（偽なら固定の戦いだけ）・
    /// fixed = その区間の固定の戦い（会話の <<fight>> の敵の並び。マップの出会いの組と並べて、重みの欄を「固定」で出す）。
    /// Lv は make bot の「区間に入った時の Lv」の多い値、装備とふくろは bot がその区間に入った時に持っている物。
    type alias Section = { map = String, title = String, members = List[Member.Member], lv = Int32, gear = List[(Member.Member, String)],
                           bag = List[(String, Int32)], encounters = Bool, fixed = List[List[String]] }

    def sectionTable(): List[Section] =
        { map = "world", title = "ワールド（行き）", members = Member.Member.Luka :: Member.Member.Mina :: Nil, lv = 1,
          gear = (Member.Member.Luka, "dounotsurugi") :: Nil, bag = ("yakusou", 3) :: Nil, encounters = true, fixed = Nil } ::
        { map = "toto_cave", title = "森の岩穴（トトの杖）", members = Member.Member.Luka :: Member.Member.Mina :: Nil, lv = 1,
          gear = (Member.Member.Luka, "dounotsurugi") :: Nil, bag = ("yakusou", 3) :: Nil, encounters = true, fixed = ("horimogu" :: Nil) :: Nil } ::
        { map = "mine_b1", title = "坑道 B1", members = Member.all(), lv = 2,
          gear = (Member.Member.Luka, "dounotsurugi") :: Nil, bag = ("yakusou", 3) :: Nil, encounters = true, fixed = Nil } ::
        { map = "mine_b2", title = "坑道 B2", members = Member.all(), lv = 3,
          gear = (Member.Member.Luka, "dounotsurugi") :: (Member.Member.Luka, "kawanoyoroi") :: (Member.Member.Mina, "tetsunotsuruhashi") :: Nil,
          bag = ("yakusou", 6) :: ("taimatsu", 2) :: Nil, encounters = true, fixed = Nil } ::
        { map = "mine_b2", title = "坑道 B2 の奥（くろがねゴブリン）", members = Member.all(), lv = 5,
          gear = (Member.Member.Luka, "dounotsurugi") :: (Member.Member.Luka, "kawanoyoroi") :: (Member.Member.Mina, "tetsunotsuruhashi") ::
                 (Member.Member.Toto, "mahounorobe") :: Nil,
          bag = ("yakusou", 4) :: ("maryoku", 2) :: ("taimatsu", 1) :: Nil, encounters = false, fixed = ("kurogane" :: Nil) :: Nil } ::
        { map = "mine_b3", title = "坑道 B3", members = Member.all(), lv = 6,
          gear = (Member.Member.Luka, "haganenotsurugi") :: (Member.Member.Luka, "kawanoyoroi") :: (Member.Member.Mina, "tetsunotsuruhashi") ::
                 (Member.Member.Toto, "mahounorobe") :: Nil,
          bag = ("yakusou", 4) :: ("maryoku", 2) :: ("bakudanishi", 3) :: Nil, encounters = true, fixed = ("mimic" :: Nil) :: Nil } :: Nil

    /// 1 戦を打ち切るターンの数。
    def maxRounds(): Int32 = 60

    /// 雑魚を倒すのに要るルカの たたかう の回数の目安（両端を含む）と、1 戦で受けるダメージの割合の上限（中央値）。
    def hitsLo(): Int32 = 2
    def hitsHi(): Int32 = 3
    def damageCap(): Float64 = 0.30

    /// 逃げられない固定の戦い（中ボス・ひとくいばこ）のターン数の目安（中央値。両端を含む）。
    /// WhyNot: 固定の戦いの敵を「ルカの 2〜3 発」で見ない — HP を多く持たせた敵で、呪文と道具も合わせて数ターンで倒す作り。
    def fixedTurnsLo(): Float64 = 3.0
    def fixedTurnsHi(): Float64 = 5.0

    pub def play(): Unit \ IO = App.Headless.exitWith(playJob(App.Headless.requestFromProcess()))

    def playJob(req: App.Headless.Request): Int32 \ IO =
        let seeds = Map.get("BALANCE_SEEDS", App.Headless.envOf(req)) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(500);
        let started = System.nanoTime();
        let res = run { Res.load() } with Fs.FileRead.runWithIO;
        let body = sectionTable() |> List.map(section -> sectionText(res, seeds, section)) |> List.join("\n");
        let seconds = Int64.toFloat64(System.nanoTime() - started) / 1.0e9;
        let text = "# つり合いのシミュレーション（make balance）\n\n" +
            "組ごとに ${seeds} 種。方針は bot と同じ（Bot.battlePlans: HP 35% 未満の仲間を回復の呪文 → やくそう・逃げられない組では攻めの呪文 → ばくだんいし・ほかは HP の一番少ない敵を たたかう）。" +
            "1 戦ごとに HP / MP は最大・ふくろは区間の初めの物から。\n" +
            "目安: 雑魚はその区間の Lv のルカが ${hitsLo()}〜${hitsHi()} 発 / 1 戦で受けるダメージは中央値で最大 HP の ${Float64.round(damageCap() * 100.0)}% 以下 / " +
            "逃げられない固定の戦いは ${fixedTurnsLo()}〜${fixedTurnsHi()} ターン（中央値）。外れた行に ⚠。\n" +
            "区間の Lv と装備とふくろは make bot の表（debug/bot.md）の「区間に入った時の Lv」の多い値と、その区間に入った時の物を BalanceSim.sectionTable に写した物（bot の流れが変わったら写し直す）。\n" +
            "流した時間: ${Float64.round(seconds * 10.0) / 10.0} 秒\n\n" + body;
        println(text);
        run {
            discard Fs.FileWrite.mkDirs("debug");
            discard Fs.FileWrite.write({ str = text }, "debug/balance.md")
        } with Fs.FileWrite.runWithIO;
        0

    // ── 区間のパーティ ──

    def partyOf(res: Res.Res, s: Section): Party.Party =
        let joined = s#members |> List.foldLeft((p, m) -> Party.join(res#party, res#items, m, p), Party.empty()) |> Party.atLevel(res#party, s#lv);
        s#gear |> List.foldLeft((p, pair) -> {
            let (m, key) = pair;
            match ItemsDoc.idOf(res#items, key) |> Option.flatMap(id -> ItemsDoc.itemOf(res#items, id) |> Option.map(item -> (id, item))) {
                case Some((id, item)) if item#kind == ItemsDoc.Kind.Weapon => Party.withEquip(m, Party.Slot.Weapon, Some(id), p)
                case Some((id, item)) if item#kind == ItemsDoc.Kind.Armor  => Party.withEquip(m, Party.Slot.Armor, Some(id), p)
                case _ => p
            }
        }, joined)

    def bagOf(res: Res.Res, s: Section): Bag.Bag =
        s#bag |> List.foldLeft((bag, pair) -> {
            let (key, n) = pair;
            ItemsDoc.idOf(res#items, key) |> Option.map(id -> Bag.give(id, n, bag)) |> Option.getWithDefault(bag)
        }, Bag.withGold(0))

    // ── 1 戦 ──

    /// 1 戦の結果: 勝ったか・全滅したか・ターン数・受けたダメージ（仲間の最大 HP の合計に対する割合）・使った MP・使った道具の数。
    type alias Fight = { won = Bool, lost = Bool, rounds = Int32, damage = Float64, mp = Int32, items = Int32 }

    /// 1 戦の初めの値（ダメージ・MP・道具の数を比べる元）。
    type alias Start = { maxHp = Int32, mp = Int32, items = Int32 }

    def fightOf(res: Res.Res, party: Party.Party, bag: Bag.Bag, foes: List[FoesDoc.FoeId], seed: Int32): Fight =
        let b = Battle.start(res, foes, party, bag);
        let start = { maxHp = Party.membersOf(party) |> List.map(m -> Party.maxHpOf(res#party, m, party)) |> List.sum,
                      mp = mpSum(party), items = itemSum(bag) };
        roundsOf(res, b, seed * 10007, 0, start)

    def mpSum(party: Party.Party): Int32 = Party.statsList(party) |> List.map(row -> snd(row)#mp) |> List.sum

    def itemSum(bag: Bag.Bag): Int32 = Bag.itemsOf(bag) |> List.map(snd) |> List.sum

    def roundsOf(res: Res.Res, b: Battle.Battle, dice: Int32, rounds: Int32, start: Start): Fight =
        let outcome = Battle.outcomeOf(b);
        if (outcome != Battle.Outcome.Ongoing or rounds >= maxRounds()) {
            let r = Battle.rec(b);
            let hp = Party.statsList(r#party) |> List.map(row -> snd(row)#hp) |> List.sum;
            { won = outcome == Battle.Outcome.Won, lost = outcome == Battle.Outcome.Lost, rounds = rounds,
              damage = Int32.toFloat64(start#maxHp - hp) / Float64.max(1.0, Int32.toFloat64(start#maxHp)),
              mp = start#mp - mpSum(r#party), items = start#items - itemSum(r#bag) }
        } else {
            let (next, _, d) = Battle.resolveRound(res, b, Bot.battlePlans(res, b), dice);
            roundsOf(res, next, d, rounds + 1, start)
        }

    // ── 表 ──

    def sectionText(res: Res.Res, seeds: Int32, s: Section): String =
        let party = partyOf(res, s);
        let bag = bagOf(res, s);
        let encounters = if (s#encounters) Map.get(s#map, res#maps) |> Option.map(d -> MapDoc.rec(d)#encounter) |> Option.getWithDefault(Nil) else Nil;
        let groups = List.append(encounters, s#fixed |> List.map(foes -> { foes = foes, weight = 0 }));
        let lv = Party.statsList(party) |> List.map(match (m, st) -> "${PartyDoc.memberOf(m, res#party)#name} Lv${st#lv}") |> List.join("・");
        let carried = s#bag |> List.map(match (key, n) -> "${key}×${n}") |> List.join("・");
        let groupRows = groups |> List.map(g -> groupRow(res, seeds, party, bag, g)) |> List.join("\n");
        let fixedKeys = s#fixed |> List.flatten |> List.toSet;
        let foeKeys = groups |> List.flatMap(g -> g#foes) |> firstOccurrences;
        let foeRows = foeKeys |> List.filterMap(FoesDoc.idOf(res#foes)) |> List.map(id -> foeRow(res, party, id, Set.memberOf(FoesDoc.keyOf(id), fixedKeys))) |> List.join("\n");
        "## ${s#title}（${lv}・${carried}）\n\n" +
        "| 組 | 重み | 勝率 | ターン（中央値 / 9 割） | 受けたダメージ（中央値 / 9 割） | 全滅の率 | 使った MP（中央値） | 使った道具（中央値） |\n|---|---|---|---|---|---|---|---|\n" + groupRows + "\n\n" +
        "| 敵 | HP | まもり | ルカの たたかう 1 発（中央値） | 倒れるまでの回数 |\n|---|---|---|---|---|\n" + foeRows + "\n"

    def groupRow(res: Res.Res, seeds: Int32, party: Party.Party, bag: Bag.Bag, g: MapDoc.Encounter): String =
        let foes = g#foes |> List.filterMap(FoesDoc.idOf(res#foes));
        let fights = List.range(0, seeds) |> List.map(seed -> fightOf(res, party, bag, foes, seed));
        let n = Int32.toFloat64(Int32.max(1, List.length(fights)));
        let wins = Int32.toFloat64(List.count(f -> f#won, fights)) / n;
        let lost = Int32.toFloat64(List.count(f -> f#lost, fights)) / n;
        let rounds = fights |> List.map(f -> Int32.toFloat64(f#rounds));
        let damage = fights |> List.map(f -> f#damage);
        let fixed = g#weight <= 0;
        let guarded = fixed and List.exists(id -> FoesDoc.foeOrBlank(res#foes, id)#noFlee, foes);
        let turnsOff = guarded and (quantile(0.5, rounds) < fixedTurnsLo() or quantile(0.5, rounds) > fixedTurnsHi());
        let warn = if (quantile(0.5, damage) > damageCap() or turnsOff) "⚠ " else "";
        let weight = if (fixed) "固定" else "${g#weight}";
        let mp = quantile(0.5, fights |> List.map(f -> Int32.toFloat64(f#mp)));
        let items = quantile(0.5, fights |> List.map(f -> Int32.toFloat64(f#items)));
        "| ${warn}${List.join("・", g#foes)} | ${weight} | ${percent(wins)} | ${quantile(0.5, rounds)} / ${quantile(0.9, rounds)} | ${percent(quantile(0.5, damage))} / ${percent(quantile(0.9, damage))} | ${percent(lost)} | ${mp} | ${items} |"

    /// その区間の Lv のルカの たたかう（ぶれの真ん中・会心なし）で倒れるまでの回数（固定の戦いの敵は目安と比べない）。
    def foeRow(res: Res.Res, party: Party.Party, id: FoesDoc.FoeId, fixed: Bool): String =
        let foe = FoesDoc.foeOrBlank(res#foes, id);
        let atk = Party.atkOf(res#party, res#items, Member.Member.Luka, party);
        let hit = Battle.damageOf(RulesDoc.rec(res#rules)#spread, atk, foe#defense, 0.5);
        let hits = (foe#hp + hit - 1) / Int32.max(1, hit);
        let warn = if (not fixed and (hits < hitsLo() or hits > hitsHi())) "⚠ " else "";
        let note = if (fixed) "（固定の戦い）" else "";
        "| ${warn}${foe#name}（${FoesDoc.keyOf(id)}） | ${foe#hp} | ${foe#defense} | ${hit} | ${hits}${note} |"

    /// 同じ値の 2 つ目からを除いた並び（最初に出た順）。
    def firstOccurrences(xs: List[String]): List[String] =
        let (_, kept) = xs |> List.foldLeft((acc, x) -> {
            let (seen, out) = acc;
            if (Set.memberOf(x, seen)) acc else (Set.insert(x, seen), x :: out)
        }, (Set.empty(), Nil));
        List.reverse(kept)

    def percent(x: Float64): String = "${Float64.round(x * 100.0) |> Float64.tryToInt32 |> Option.getWithDefault(0)}%"

    /// 値の並びの q の位置の値（並べ替えて、切り上げた番目）。
    def quantile(q: Float64, xs: List[Float64]): Float64 =
        let sorted = List.sort(xs) |> List.toVector;
        let n = Vector.length(sorted);
        if (n == 0) 0.0
        else {
            let at = Float64.ceil(q * Int32.toFloat64(n)) |> Float64.tryToInt32 |> Option.getWithDefault(1);
            Vector.nth(Int32.max(0, Int32.min(n - 1, at - 1)), sorted) |> Option.getWithDefault(0.0)
        }
}
