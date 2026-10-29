// WorldBattle — 戦いの見せ方の規則（すべて純粋）: コマンドを選ぶ・1 ターンを Battle.resolveRound に解かせる・
// 返った Beat を遊びの時計で 1 枚ずつ見せる・勝ち / 全滅 / 逃げ切りでフィールドへ戻る。
// 式（ダメージ・経験値の配り方・レベルアップ・伝言の Beat）は Battle（時計を見ない）。ここは時計と Phase だけを持つ。
//
//   出会い（WorldField が点滅し終える）──enter──▶ Show(現れた, Choose) ──▶ Choose(仲間, Commands)
//     → 生きている仲間を順に選び終える ──▶ Show(1 ターンの Beat, Judge)
//     → Judge: 勝ち ──▶ Show(Battle.resolveVictory の Beat, Leave(Won)) ──▶ フィールド（afterWin の会話を開く）
//              全滅 ──▶ Show(Battle.wipedBeat, Leave(Lost)) ──▶ 宿の前（お金は goldKeep・全快・暗転を晴らす）
//              逃げ切った ──▶ フィールド / どちらでもない ──▶ Choose（次のターン）
//
// 1 枚の Beat は「演出（Fx の seconds = rules の fxSeconds）→ 文字送り（rules の cps）→ 出し切ってから messageWait 秒」で次へ送る。
// 演出の間は InputLayer.Layer.Busy、伝言の間は BattleMessage（決定で出し切る → もう 1 回で次へ）。
// HP の表示は今見せている Beat の after を読む（ターンの最後の結果を先に出さない）。
mod WorldBattle {
    use fge::{Clock, Emit, Log}
    use World.{AfterShow, BattleCommand, BattleRec, CommandPage, Phase}

    /// 戦いの間だけ f で World を作り直す（戦いでなければそのまま）。
    def withBattle(f: BattleRec -> World.World \ ef, w: World.World): World.World \ ef =
        match World.battleRecOf(w) {
            case Some(r) => f(r)
            case None    => w
        }

    // ── 始める ──

    /// foes と戦う（今のフィールドを戻る先に持つ）。敵の数は rules の maxFoes（3 まで）で切る。フィールドでなければ何もしない。[遷移: Field→Battle]
    pub def enter(res: Res.Res, foes: List[FoesDoc.FoeId], afterWin: Option[String], w: World.World): World.World =
        match World.fieldStateOf(w) {
            case None       => w
            case Some(back) =>
                let b = Battle.start(res, List.take(maxFoesOf(res), foes), w#party, w#bag);
                World.placeBattle({ battle = b, phase = Phase.Show(Battle.openingOf(b), Nil, World.now(w), AfterShow.Choose),
                                    back = back, plans = Map.empty(), afterWin = afterWin }, w)
        }

    /// 1 戦の敵の数の上限（rules の maxFoes。描き場所が 3 つなので 3 を超えない・1 より少なくしない）。
    pub def maxFoesOf(res: Res.Res): Int32 = Int32.max(1, Int32.min(3, RulesDoc.rec(res#rules)#maxFoes))

    // ── 伝言の時間 ──

    /// 演出の秒（演出の無い Beat は 0）。
    pub def fxSecondsOf(beat: Battle.Beat): Float64 =
        Battle.beatRecOf(beat)#fx |> Option.map(fx -> fx#seconds) |> Option.getWithDefault(0.0)

    /// Beat の伝言の字（行を \n でつなぐ）。
    pub def beatTextOf(res: Res.Res, beat: Battle.Beat): String =
        Battle.beatRecOf(beat)#lines |> List.map(line -> TextDoc.battleText(line#text, line#values, res#text)) |> List.join("\n")

    /// 演出の前から出しておく字数（演出のある Beat は 1 行目「〜の こうげき！」と改行。無ければ 0）。
    def headLengthOf(res: Res.Res, beat: Battle.Beat): Int32 =
        if (Option.isEmpty(Battle.beatRecOf(beat)#fx)) 0
        else Battle.beatRecOf(beat)#lines |> List.head |> Option.map(line -> String.length(TextDoc.battleText(line#text, line#values, res#text)) + 1) |> Option.getWithDefault(0)

    /// 文字送りを出し切るまでの秒（演出の後から数える。1 行目は演出の前から出ている）。
    def revealSecondsOf(res: Res.Res, beat: Battle.Beat): Float64 =
        Int32.toFloat64(Int32.max(0, String.length(beatTextOf(res, beat)) - headLengthOf(res, beat))) / Float64.max(1.0, RulesDoc.rec(res#rules)#cps)

    /// 出し始めてから elapsed 秒の、見えている字数（演出の間は 1 行目だけ・演出の後から残りを文字送り）。
    pub def shownCharsOf(res: Res.Res, beat: Battle.Beat, elapsed: Float64): Int32 =
        let since = Float64.max(0.0, elapsed - fxSecondsOf(beat));
        let typed = Float64.floor(since * RulesDoc.rec(res#rules)#cps) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        Int32.min(String.length(beatTextOf(res, beat)), headLengthOf(res, beat) + typed)

    /// 出し始めてからの秒（演出の後から数える。演出の途中は負）。
    def sinceTextOf(beat: Battle.Beat, startedAt: Clock.Time[World.Play], w: World.World): Float64 =
        Clock.since(startedAt, World.now(w)) - fxSecondsOf(beat)

    /// 今の Beat の演出の途中か（入力を捨てる）。
    pub def isBusy(w: World.World): Bool =
        World.battleRecOf(w) |> Option.exists(r -> match r#phase {
            case Phase.Show(beat, _, at, _) => sinceTextOf(beat, at, w) < 0.0
            case Phase.Choose(_, _)         => false
        })

    // ── 時間で進む物（毎フレーム） ──

    /// 出し切ってから messageWait 秒経った Beat を送る。
    pub def tick(res: Res.Res, w: World.World): World.World =
        match World.battleRecOf(w) |> Option.map(r -> r#phase) {
            case Some(Phase.Show(beat, _, at, _)) if sinceTextOf(beat, at, w) >= revealSecondsOf(res, beat) + RulesDoc.rec(res#rules)#messageWait =>
                advance(res, w)
            case _ => w
        }

    // ── 伝言の入力 ──

    /// 決定（伝言の間）: 出している途中なら出し切る、出し切っていれば次の Beat へ。
    pub def confirmMessage(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match World.battleRecOf(w) |> Option.map(r -> r#phase) {
            case Some(Phase.Show(beat, rest, at, then)) if sinceTextOf(beat, at, w) < revealSecondsOf(res, beat) =>
                let shown = Clock.after(0.0 - (fxSecondsOf(beat) + revealSecondsOf(res, beat)), World.now(w));
                World.mapBattle(r -> { phase = Phase.Show(beat, rest, shown, then) | r }, w)
            case Some(Phase.Show(_, _, _, _)) => { Emit.emit(World.Event.Confirm); advance(res, w) }
            case _ => w
        }

    /// 今の Beat を捨てて残りを出す（残りが無ければ出し終えた後へ）。
    def advance(res: Res.Res, w: World.World): World.World =
        match World.battleRecOf(w) |> Option.map(r -> r#phase) {
            case Some(Phase.Show(_, rest, _, then)) => show(res, rest, then, w)
            case _ => w
        }

    /// 伝言を出し終えた後。
    def finish(res: Res.Res, then: AfterShow, w: World.World): World.World = match then {
        case AfterShow.Choose        => chooseFrom(res, None, w)
        case AfterShow.Judge         => judge(res, w)
        case AfterShow.Leave(outcome) => leave(res, outcome, w)
    }

    /// 伝言を出す（beats が空なら出し終えた後へ直に進む）。
    def show(res: Res.Res, beats: List[Battle.Beat], then: AfterShow, w: World.World): World.World =
        match beats {
            case beat :: rest => World.mapBattle(r -> { phase = Phase.Show(beat, rest, World.now(w), then) | r }, w)
            case Nil          => finish(res, then, w)
        }

    // ── コマンドを選ぶ ──

    /// コマンドのウィンドウの並び。
    pub def commands(): List[BattleCommand] =
        BattleCommand.Fight :: BattleCommand.Spell :: BattleCommand.Items :: BattleCommand.Defend :: BattleCommand.Flee :: Nil

    /// 選べるコマンドか。じゅもん は m が呪文を 1 つも覚えていなければ灰色、どうぐ は戦いで使える道具が残っていなければ灰色。
    pub def isCommandOpen(res: Res.Res, r: BattleRec, m: Member.Member, c: BattleCommand): Bool = match c {
        case BattleCommand.Fight  => true
        case BattleCommand.Spell  => not List.isEmpty(spellsOf(res, r, m))
        case BattleCommand.Items  => itemsOf(res, r) |> List.exists(row -> row#open)
        case BattleCommand.Defend => true
        case BattleCommand.Flee   => true
    }

    /// m の覚えた呪文と、今の MP で唱えられるか（並びは rpg.party.json の learns の順）。
    pub def spellsOf(res: Res.Res, r: BattleRec, m: Member.Member): List[{ spell = SpellsDoc.SpellId, open = Bool }] =
        let party = Battle.rec(r#battle)#party;
        Party.spellsOf(res#party, res#spells, m, party) |> List.map(id -> {
            let cost = SpellsDoc.spellOf(res#spells, id) |> Option.map(s -> s#mp) |> Option.getWithDefault(0);
            { spell = id, open = Party.mpOf(m, party) >= cost }
        })

    /// 戦いのどうぐの一覧: ふくろの使う物（Bag.listOf の順）と、このターンにもう選んだ分を引いた残り・選べるか
    /// （戦いで使える物で、残りがある時だけ。せいすいは灰色）。
    /// WhyNot: 装備とだいじなものを並べない — 戦いでは使えず、一覧のウィンドウ（5 行）を埋めて使う物が下へ隠れる。
    pub def itemsOf(res: Res.Res, r: BattleRec): List[{ item = ItemsDoc.ItemId, left = Int32, open = Bool }] =
        let reserved = r#plans |> Map.valuesOf |> List.filterMap(plan -> match plan {
            case Battle.Plan.UseItem(id, _) => Some(id)
            case _                          => None
        }) |> List.foldLeft((acc, id) -> Map.insertWith((a, b) -> a + b, id, 1, acc), Map.empty());
        Bag.listOf(res#items, Battle.rec(r#battle)#bag) |> List.filterMap(match (id, n) ->
            ItemsDoc.itemOf(res#items, id) |> Option.filter(item -> item#kind == ItemsDoc.Kind.Use) |> Option.map(item -> {
                let left = n - Map.getWithDefault(id, 0, reserved);
                { item = id, left = left, open = Battle.isBattleItem(item) and left > 0 }
            }))

    /// 戦いのどうぐの一覧の道具と、選べるか（itemsOf の並び）。
    pub def itemChoicesOf(res: Res.Res, r: BattleRec): List[(ItemsDoc.ItemId, Bool)] =
        itemsOf(res, r) |> List.map(row -> (row#item, row#open))

    /// 呪文か道具の的の向き（敵 1 体・敵全部・仲間 1 人）。
    def spellAimOf(res: Res.Res, id: SpellsDoc.SpellId): SpellsDoc.Aim =
        SpellsDoc.spellOf(res#spells, id) |> Option.map(s -> s#aim) |> Option.getWithDefault(SpellsDoc.Aim.Foe)

    def itemAimOf(res: Res.Res, id: ItemsDoc.ItemId): SpellsDoc.Aim =
        ItemsDoc.itemOf(res#items, id) |> Option.map(Battle.itemAimOf) |> Option.getWithDefault(SpellsDoc.Aim.Ally)

    /// 的のページの並び（敵 1 体は生きている敵の番号・仲間は加わった順の仲間）。
    def targetsOf(aim: SpellsDoc.Aim, r: BattleRec): List[Battle.Target] = match aim {
        case SpellsDoc.Aim.Ally => Party.membersOf(Battle.rec(r#battle)#party) |> List.map(Battle.Target.Ally)
        case _                  => Battle.aliveFoes(r#battle) |> List.map(Battle.Target.Foe)
    }

    /// 的のページの並び（ページの呪文か道具の向きで）。的のページでなければ空。
    pub def targetsOfPage(res: Res.Res, r: BattleRec, page: CommandPage): List[Battle.Target] = match page {
        case CommandPage.FoeTarget(_)       => targetsOf(SpellsDoc.Aim.Foe, r)
        case CommandPage.SpellTarget(id, _) => targetsOf(spellAimOf(res, id), r)
        case CommandPage.ItemTarget(id, _)  => targetsOf(itemAimOf(res, id), r)
        case _                              => Nil
    }

    /// after の次に選ぶ仲間（生きていて眠っていない人。after が None なら先頭）。居なければ 1 ターンを解く（全員眠っていれば敵だけが動く）。
    def chooseFrom(res: Res.Res, after: Option[Member.Member], w: World.World): World.World =
        withBattle(r -> {
            let choosers = Battle.choosersOf(r#battle);
            let rest = after |> Option.map(m -> choosers |> List.dropWhile(x -> x != m) |> List.drop(1)) |> Option.getWithDefault(choosers);
            match List.head(rest) {
                case Some(m) => World.mapBattle(br -> { phase = Phase.Choose(m, CommandPage.Commands(0)) | br }, w)
                case None    => resolve(res, r, w)
            }
        }, w)

    /// 選んでいる仲間とページ（コマンドを選んでいなければ None）。
    pub def choosingOf(w: World.World): Option[(Member.Member, CommandPage)] =
        World.battleRecOf(w) |> Option.flatMap(r -> match r#phase {
            case Phase.Choose(m, page)  => Some((m, page))
            case Phase.Show(_, _, _, _) => None
        })

    def setPage(m: Member.Member, page: CommandPage, w: World.World): World.World =
        World.mapBattle(r -> { phase = Phase.Choose(m, page) | r }, w)

    /// ページの行の数（カーソルを回す幅）。
    def pageLengthOf(res: Res.Res, r: BattleRec, m: Member.Member, page: CommandPage): Int32 = match page {
        case CommandPage.Commands(_)       => List.length(commands())
        case CommandPage.SpellList(_)      => List.length(spellsOf(res, r, m))
        case CommandPage.ItemList(_)       => List.length(itemsOf(res, r))
        case _                             => List.length(targetsOfPage(res, r, page))
    }

    /// ページのカーソルを i にしたページ。
    def withCursor(page: CommandPage, i: Int32): CommandPage = match page {
        case CommandPage.Commands(_)        => CommandPage.Commands(i)
        case CommandPage.FoeTarget(_)       => CommandPage.FoeTarget(i)
        case CommandPage.SpellList(_)       => CommandPage.SpellList(i)
        case CommandPage.SpellTarget(id, _) => CommandPage.SpellTarget(id, i)
        case CommandPage.ItemList(_)        => CommandPage.ItemList(i)
        case CommandPage.ItemTarget(id, _)  => CommandPage.ItemTarget(id, i)
    }

    /// ページのカーソル。
    pub def cursorOf(page: CommandPage): Int32 = match page {
        case CommandPage.Commands(i)       => i
        case CommandPage.FoeTarget(i)      => i
        case CommandPage.SpellList(i)      => i
        case CommandPage.SpellTarget(_, i) => i
        case CommandPage.ItemList(i)       => i
        case CommandPage.ItemTarget(_, i)  => i
    }

    /// 上下でカーソル（端で回る）。
    pub def move(res: Res.Res, delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        let next = forM (
            r <- World.battleRecOf(w);
            (m, page) <- choosingOf(w)
        ) yield (m, withCursor(page, Int32.modulo(cursorOf(page) + delta, Int32.max(1, pageLengthOf(res, r, m, page)))));
        match next {
            case Some((m, page)) => { Emit.emit(World.Event.Cursor); setPage(m, page, w) }
            case None            => w
        }

    /// 決定: コマンド → たたかう は的のページへ・じゅもん / どうぐ は一覧へ・ぼうぎょ と にげる はその行動で次の仲間へ
    /// （にげる の後の仲間は選ばない）・灰色は選べない。一覧 → 的のページへ（敵全部の呪文は的を選ばずに決める）。的のページ → 次の仲間へ。
    pub def confirm(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        let pick = forM (r <- World.battleRecOf(w); (m, page) <- choosingOf(w)) yield (r, m, page);
        match pick {
            case Some((_, m, CommandPage.Commands(i)))        => confirmCommand(res, m, List.nth(i, commands()), w)
            case Some((r, m, CommandPage.SpellList(i)))       => confirmSpell(res, m, List.nth(i, spellsOf(res, r, m)), w)
            case Some((r, m, CommandPage.ItemList(i)))        => confirmItem(m, List.nth(i, itemsOf(res, r)), w)
            case Some((r, m, CommandPage.FoeTarget(i)))       => confirmTarget(res, m, List.nth(i, targetsOfPage(res, r, CommandPage.FoeTarget(i))), planAttack, w)
            case Some((r, m, CommandPage.SpellTarget(id, i))) => confirmTarget(res, m, List.nth(i, targetsOfPage(res, r, CommandPage.SpellTarget(id, i))), planCast(id), w)
            case Some((r, m, CommandPage.ItemTarget(id, i)))  => confirmTarget(res, m, List.nth(i, targetsOfPage(res, r, CommandPage.ItemTarget(id, i))), planItem(id), w)
            case None => w
        }

    /// たたかう の行動（的の番号）。敵でない的は先頭の敵。
    def planAttack(target: Battle.Target): Battle.Plan = match target {
        case Battle.Target.Foe(i) => Battle.Plan.Attack(i)
        case _                    => Battle.Plan.Attack(0)
    }

    def planCast(id: SpellsDoc.SpellId): Battle.Target -> Battle.Plan = target -> Battle.Plan.Cast(id, target)

    def planItem(id: ItemsDoc.ItemId): Battle.Target -> Battle.Plan = target -> Battle.Plan.UseItem(id, target)

    /// 的を決めた: その行動で次の仲間へ。
    def confirmTarget(res: Res.Res, m: Member.Member, target: Option[Battle.Target], plan: Battle.Target -> Battle.Plan, w: World.World): World.World \ Emit[World.Event] =
        match target {
            case Some(t) => { Emit.emit(World.Event.Confirm); planned(res, m, plan(t), w) }
            case None    => w
        }

    /// 呪文を選んだ: MP が足りなければ選べない。敵全部の呪文はそのまま決め、ほかは的のページへ。
    def confirmSpell(res: Res.Res, m: Member.Member, row: Option[{ spell = SpellsDoc.SpellId, open = Bool }], w: World.World): World.World \ Emit[World.Event] =
        match row {
            case Some(s) if s#open and spellAimOf(res, s#spell) == SpellsDoc.Aim.AllFoes => {
                Emit.emit(World.Event.Confirm); planned(res, m, Battle.Plan.Cast(s#spell, Battle.Target.AllFoes), w)
            }
            case Some(s) if s#open => { Emit.emit(World.Event.Confirm); setPage(m, CommandPage.SpellTarget(s#spell, 0), w) }
            case Some(_)           => { Emit.emit(World.Event.Denied); w }
            case None              => w
        }

    /// 道具を選んだ: 戦いで使えない物・残りの無い物は選べない。使える物は的のページへ。
    def confirmItem(m: Member.Member, row: Option[{ item = ItemsDoc.ItemId, left = Int32, open = Bool }], w: World.World): World.World \ Emit[World.Event] =
        match row {
            case Some(it) if it#open => { Emit.emit(World.Event.Confirm); setPage(m, CommandPage.ItemTarget(it#item, 0), w) }
            case Some(_)             => { Emit.emit(World.Event.Denied); w }
            case None                => w
        }

    def confirmCommand(res: Res.Res, m: Member.Member, c: Option[BattleCommand], w: World.World): World.World \ Emit[World.Event] =
        let isOpen = cmd -> World.battleRecOf(w) |> Option.exists(r -> isCommandOpen(res, r, m, cmd));
        match c {
            case Some(BattleCommand.Fight)  => { Emit.emit(World.Event.Confirm); setPage(m, CommandPage.FoeTarget(0), w) }
            case Some(BattleCommand.Spell) if isOpen(BattleCommand.Spell) => { Emit.emit(World.Event.Confirm); setPage(m, CommandPage.SpellList(0), w) }
            case Some(BattleCommand.Items) if isOpen(BattleCommand.Items) => { Emit.emit(World.Event.Confirm); setPage(m, CommandPage.ItemList(0), w) }
            case Some(BattleCommand.Defend) => { Emit.emit(World.Event.Confirm); planned(res, m, Battle.Plan.Defend, w) }
            case Some(BattleCommand.Flee)   => {
                Emit.emit(World.Event.Confirm);
                let fleeing = withPlan(m, Battle.Plan.Flee, w);
                withBattle(r -> resolve(res, r, fleeing), fleeing)
            }
            case _                          => { Emit.emit(World.Event.Denied); w }
        }

    def withPlan(m: Member.Member, plan: Battle.Plan, w: World.World): World.World =
        World.mapBattle(r -> { plans = Map.insert(m, plan, r#plans) | r }, w)

    def planned(res: Res.Res, m: Member.Member, plan: Battle.Plan, w: World.World): World.World =
        chooseFrom(res, Some(m), withPlan(m, plan, w))

    /// コマンドのウィンドウでの c の行。
    def commandIndexOf(c: BattleCommand): Int32 = List.indexOf(c, commands()) |> Option.getWithDefault(0)

    /// 取消で戻るページ（コマンドのページは None = 前の仲間へ）。戻ったページのカーソルは、来た時に選んだ行。
    def parentOf(res: Res.Res, r: BattleRec, m: Member.Member, page: CommandPage): Option[CommandPage] = match page {
        case CommandPage.Commands(_)        => None
        case CommandPage.FoeTarget(_)       => Some(CommandPage.Commands(commandIndexOf(BattleCommand.Fight)))
        case CommandPage.SpellList(_)       => Some(CommandPage.Commands(commandIndexOf(BattleCommand.Spell)))
        case CommandPage.ItemList(_)        => Some(CommandPage.Commands(commandIndexOf(BattleCommand.Items)))
        case CommandPage.SpellTarget(id, _) =>
            Some(CommandPage.SpellList(spellsOf(res, r, m) |> List.map(s -> s#spell) |> List.indexOf(id) |> Option.getWithDefault(0)))
        case CommandPage.ItemTarget(id, _)  =>
            Some(CommandPage.ItemList(itemsOf(res, r) |> List.map(it -> it#item) |> List.indexOf(id) |> Option.getWithDefault(0)))
    }

    /// 取消: 1 つ前のページへ（parentOf）。コマンドのページなら前の仲間の選び直し（その人の行動を消す。先頭なら何もしない）。
    pub def cancel(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        let back = forM (r <- World.battleRecOf(w); (m, page) <- choosingOf(w)) yield (r, m, parentOf(res, r, m, page));
        match back {
            case Some((_, m, Some(parent))) => { Emit.emit(World.Event.Cancel); setPage(m, parent, w) }
            case Some((r, m, None))         => backTo(m, r, w)
            case None                       => w
        }

    /// m の前の行動を選ぶ仲間の選び直しへ（その人の行動を消す。m が先頭なら何もしない）。
    def backTo(m: Member.Member, r: BattleRec, w: World.World): World.World \ Emit[World.Event] =
        let before = Battle.choosersOf(r#battle) |> List.takeWhile(x -> x != m) |> List.reverse |> List.head;
        before |> Option.map(prev -> {
            Emit.emit(World.Event.Cancel);
            World.mapBattle(br -> { plans = Map.remove(prev, br#plans), phase = Phase.Choose(prev, CommandPage.Commands(0)) | br }, w)
        }) |> Option.getWithDefault(w)

    // ── 1 ターン ──

    /// 選び終えた行動（r#plans）で 1 ターンを解き、Beat を見せる。
    def resolve(res: Res.Res, r: BattleRec, w: World.World): World.World =
        let (b, beats, dice) = Battle.resolveRound(res, r#battle, r#plans, w#dice);
        show(res, beats, AfterShow.Judge, World.mapBattle(br -> { battle = b, plans = Map.empty() | br }, { dice = dice | w }))

    /// 1 ターンの後: 勝ち → 勝ちの伝言 / 全滅 → ぜんめつ / 逃げ切った → フィールドへ / どちらでもない → 次のターン。
    def judge(res: Res.Res, w: World.World): World.World =
        withBattle(r -> match Battle.outcomeOf(r#battle) {
            case Battle.Outcome.Won     =>
                let (after, beats) = Battle.resolveVictory(res, r#battle);
                show(res, beats, AfterShow.Leave(Battle.Outcome.Won), World.mapBattle(br -> { battle = after | br }, w))
            case Battle.Outcome.Lost    => show(res, Battle.wipedBeat(r#battle) :: Nil, AfterShow.Leave(Battle.Outcome.Lost), w)
            case Battle.Outcome.Fled    => leave(res, Battle.Outcome.Fled, w)
            case Battle.Outcome.Ongoing => chooseFrom(res, None, w)
        }, w)

    // ── 終える ──

    /// 戦いを終える。勝ち: 仲間とお金を World へ書き戻し、フィールドへ戻って afterWin の会話を開く。
    /// 逃げ切り: 仲間を書き戻してフィールドへ。全滅: お金を goldKeep 倍（切り捨て）・全快で宿の前へ（暗転を晴らす）。[遷移: Battle→Field]
    def leave(res: Res.Res, outcome: Battle.Outcome, w: World.World): World.World =
        withBattle(r -> {
            let party = Battle.rec(r#battle)#party;
            let bag = Battle.rec(r#battle)#bag;
            match outcome {
                case Battle.Outcome.Won =>
                    let gold = Battle.rewardsOf(res, r#battle)#gold;
                    let back = World.returnToField(r#back, { party = party, bag = Bag.addGold(gold, bag) | w });
                    r#afterWin |> Option.map(node -> WorldTalk.open(res, node, None, back)) |> Option.getWithDefault(back)
                case Battle.Outcome.Lost    => wipe(res, party, bag, r, w)
                case Battle.Outcome.Fled    => World.returnToField(r#back, { party = party, bag = bag | w })
                case Battle.Outcome.Ongoing => World.returnToField(r#back, { party = party, bag = bag | w })
            }
        }, w)

    /// 全滅: お金に goldKeep を掛けて切り捨て、全員を全快して宿の前に立つ（暗転を晴らして入る。使った道具は減ったまま）。
    def wipe(res: Res.Res, party: Party.Party, bag: Bag.Bag, r: BattleRec, w: World.World): World.World =
        let keep = RulesDoc.rec(res#rules)#goldKeep;
        let gold = Float64.floor(Int32.toFloat64(Bag.goldOf(bag)) * keep) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let healed = { party = Party.restoreAll(res#party, party), bag = Bag.addGold(gold - Bag.goldOf(bag), bag) | w };
        match WorldShop.homeOf(res) {
            case Some((map, cell, facing)) => World.enterField(map, cell, facing, healed)
            case None => Log.warnThen("[rules] 宿の前のマップが無いので、戦った所へ戻る", World.returnToField(r#back, healed))
        }

    // ── 読み直し ──

    /// Doc を読み直した後に収める（戦いの最中なら仲間と敵の HP を新しい最大へ・消えた道具を戦いのふくろから捨てる）。
    pub def settle(res: Res.Res, w: World.World): World.World =
        World.mapBattle(r -> { battle = Battle.settle(res, r#battle) | r }, w)

    /// Show の間の今の Beat と、それを出し始めた時刻（コマンドを選んでいる間は None）。
    pub def currentBeatOf(r: BattleRec): Option[(Battle.Beat, Clock.Time[World.Play])] = match r#phase {
        case Phase.Show(beat, _, at, _) => Some((beat, at))
        case Phase.Choose(_, _)         => None
    }

    /// 今見せている戦いの値（Show の間は今の Beat の after・コマンドを選んでいる間はターンの後の値）。
    pub def shownBattleOf(r: BattleRec): Battle.Battle = match r#phase {
        case Phase.Show(beat, _, _, _) => Battle.beatRecOf(beat)#after
        case Phase.Choose(_, _)        => r#battle
    }
}
