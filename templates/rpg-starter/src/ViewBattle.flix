// ViewBattle — World から戦いの絵の In（BattleView.In）を組む（純粋）。敵の並び・演出の絵と置き場・伝言のウィンドウ・コマンドのウィンドウ。
// HP の表示は今見せている Beat の after（WorldBattle.shownBattleOf）。World を受けるのは battleIn だけ。
mod ViewBattle {
    use fge::Clock
    use TextDoc.MenuText
    use World.CommandPage

    /// n 体のうち i 番目の横の真ん中（1 体 = 中央、2 体 = 1/3・2/3、3 体 = 1/4・1/2・3/4）。倒れても場所は詰めない。
    def foeCenterXOf(i: Int32, n: Int32): Float64 =
        let width = WindowView.design()#x;
        if (n <= 1) width / 2.0
        else if (n == 2) width * Int32.toFloat64(i + 1) / 3.0
        else width * Int32.toFloat64(i + 1) / 4.0

    /// World から BattleView の In を組む（戦いでなければ None）。
    pub def battleIn(env: WindowView.Env, w: World.World): Option[BattleView.In] =
        World.battleRecOf(w) |> Option.map(r -> {
            let res = env#res;
            let shown = WorldBattle.shownBattleOf(r);
            let b = Battle.rec(shown);
            let back = World.fieldRecOfState(r#back);
            let backdrop = MapDoc.docOf(res#maps, back#map) |> Option.map(map -> MapDoc.rec(map)#battleBack) |> Option.getWithDefault("bg_plains");
            let current = WorldBattle.currentBeatOf(r) |> Option.map(match (beat, at) -> (beat, Clock.since(at, World.now(w))));
            let fx = current |> Option.flatMap(match (beat, elapsed) -> {
                let length = WorldBattle.fxSecondsOf(beat);
                Battle.beatRecOf(beat)#fx |> Option.filter(_ -> elapsed < length) |> Option.map(one -> (one, elapsed / length))
            });
            let count = Vector.length(b#foes);
            let foes = b#foes |> Vector.toList |> List.zipWithIndex |> List.map(match (i, f) -> {
                let doc = FoesDoc.foeOrBlank(res#foes, f#id);
                let struck = fx |> Option.exists(match (one, _) -> isFoeStruck(i, one#target));
                let blinkOff = struck and current |> Option.exists(pair -> Int32.modulo(Float64.floor(snd(pair) * 20.0) |> Float64.tryToInt32 |> Option.getWithDefault(0), 2) == 1);
                { part = Sheet.cycling(Sheet.SheetId.Monsters, doc#sprite, 2.0, "fc1A", { x = Int32.toFloat64(doc#width), y = Int32.toFloat64(doc#height) }),
                  recolor = Map.get(FoesDoc.keyOf(f#id), res#foeSheets), centerX = foeCenterXOf(i, count), lift = Int32.toFloat64(doc#lift),
                  shown = (f#hp > 0 or struck) and not blinkOff }
            });
            let members = Party.membersOf(b#party);
            { backdrop = backdrop,
              shake = fx |> Option.filter(match (one, _) -> one#shake)
                         |> Option.map(match (_, t) -> if (Int32.modulo(Float64.floor(t * 12.0) |> Float64.tryToInt32 |> Option.getWithDefault(0), 2) == 0) 2.0 else -2.0)
                         |> Option.getWithDefault(0.0),
              foes = foes,
              fx = fx |> Option.map(match (one, t) -> fxIn(env, foes, members, one, t)) |> Option.getWithDefault(Nil),
              members = Party.statsList(b#party) |> List.map(match (m, st) ->
                  { name = PartyDoc.memberOf(m, res#party)#name, hp = st#hp, mp = st#mp, down = st#hp <= 0, asleep = Battle.isAsleep(m, shown) }),
              foeNames = foeNamesOf(res, shown),
              command = commandIn(res, r),
              message = current |> Option.map(match (beat, elapsed) -> messageIn(env, beat, elapsed)) }
        })

    /// 的が敵 i を含むか（斬撃・呪文で点滅させる）。
    def isFoeStruck(i: Int32, target: Battle.Target): Bool = match target {
        case Battle.Target.Foe(t)   => t == i
        case Battle.Target.AllFoes  => true
        case _                      => false
    }

    /// 演出の種類 → battlefx の絵の名前。
    def fxSpriteOf(kind: Battle.FxKind): String = match kind {
        case Battle.FxKind.Slash         => "slash"
        case Battle.FxKind.Hit           => "hit"
        case Battle.FxKind.Spell(sprite) => sprite
        case Battle.FxKind.Burn          => "fire"
        case Battle.FxKind.Mend          => "heal"
    }

    /// 演出の絵と置き場: 敵の的は敵の真ん中（敵全部なら生きている敵ごと）・仲間 1 人は帯の下のその人の列・仲間全員は帯の下の真ん中。
    def fxIn(env: WindowView.Env, foes: List[BattleView.Foe], members: List[Member.Member], fx: Battle.Fx, t: Float64): List[BattleView.Fx] =
        let sprite = fxSpriteOf(fx#kind);
        let onFoe = foe -> {
            let top = BattleView.foeTopLeft(env, foe);
            let size = BattleView.foeSize(env, foe);
            { sprite = sprite, at = { x = Float64.floor(top#x + size#x / 2.0 - 16.0), y = Float64.floor(top#y + size#y / 2.0 - 16.0) }, t = t }
        };
        let below = x -> { sprite = sprite, at = { x = Float64.floor(x - 16.0), y = BattleView.footY() - 8.0 }, t = t };
        match fx#target {
            case Battle.Target.Foe(i)    => List.nth(i, foes) |> Option.map(onFoe) |> Option.toList
            case Battle.Target.AllFoes   => foes |> List.filter(f -> f#shown) |> List.map(onFoe)
            case Battle.Target.Ally(m)   => List.indexOf(m, members) |> Option.map(i -> below(BattleView.memberCenterX(i))) |> Option.toList
            case Battle.Target.AllAllies => below(WindowView.design()#x / 2.0) :: Nil
        }

    /// 伝言のウィンドウ（演出の間は 1 行目だけ・演出の後から文字送り）。
    def messageIn(env: WindowView.Env, beat: Battle.Beat, elapsed: Float64): BattleView.Message =
        let text = WorldBattle.beatTextOf(env#res, beat);
        let shown = WorldBattle.shownCharsOf(env#res, beat, elapsed);
        let all = WindowView.talkLines(env, "", text, shown, BattleView.messageWidth());
        { lines = List.drop(Int32.max(0, List.length(all) - 4), all), done = shown >= String.length(text) }

    /// 敵の一覧（生きている敵の名前ごとの数・出た順）。
    def foeNamesOf(res: Res.Res, b: Battle.Battle): List[(String, Int32)] =
        let names = Battle.aliveFoes(b) |> List.filterMap(i -> Vector.nth(i, Battle.rec(b)#foes)) |> List.map(f -> FoesDoc.foeOrBlank(res#foes, f#id)#name);
        let counts = names |> List.foldLeft((acc, n) -> Map.insertWith((a, c) -> a + c, n, 1, acc), Map.empty());
        let (_, firsts) = names |> List.foldLeft((acc, n) -> {
            let (seen, out) = acc;
            if (Set.memberOf(n, seen)) acc else (Set.insert(n, seen), n :: out)
        }, (Set.empty(), Nil));
        firsts |> List.reverse |> List.map(n -> (n, Map.getWithDefault(n, 0, counts)))

    /// コマンドを選んでいる間のウィンドウ（左のコマンドと、右の一覧。コマンドのページの右は敵の名前と数）。
    def commandIn(res: Res.Res, r: World.BattleRec): Option[BattleView.Command] =
        match r#phase {
            case World.Phase.Choose(m, page) =>
                let entries = WorldBattle.commands() |> List.map(c -> (TextDoc.menuText(battleCommandTextOf(c), res#text), WorldBattle.isCommandOpen(res, r, m, c)));
                let (cursor, side) = sideOf(res, r, m, page);
                Some({ who = PartyDoc.memberOf(m, res#party)#name, entries = entries, cursor = cursor, active = Option.isEmpty(side), side = side })
            case World.Phase.Show(_, _, _, _) => None
        }

    /// コマンドのカーソル（一覧や的を選んでいる間は来た時のコマンド）と、右の一覧のウィンドウ（コマンドのページは None）。
    def sideOf(res: Res.Res, r: World.BattleRec, m: Member.Member, page: CommandPage): (Int32, Option[WindowView.ListBox]) =
        let commandAt = c -> List.indexOf(c, WorldBattle.commands()) |> Option.getWithDefault(0);
        let i = WorldBattle.cursorOf(page);
        match page {
            case CommandPage.Commands(_)       => (i, None)
            case CommandPage.FoeTarget(_)      => (commandAt(World.BattleCommand.Fight), Some(targetBox(res, r, page, "")))
            case CommandPage.SpellList(_)      => (commandAt(World.BattleCommand.Spell), Some(spellBox(res, r, m, i)))
            case CommandPage.SpellTarget(id, _) => (commandAt(World.BattleCommand.Spell), Some(targetBox(res, r, page, SpellsDoc.nameOf(res#spells, id))))
            case CommandPage.ItemList(_)       => (commandAt(World.BattleCommand.Items), Some(itemBox(res, r, i)))
            case CommandPage.ItemTarget(id, _) => (commandAt(World.BattleCommand.Items), Some(targetBox(res, r, page, ItemsDoc.nameOf(res#items, id))))
        }

    /// 呪文の一覧（右に使う MP。足りない呪文は灰色）。
    def spellBox(res: Res.Res, r: World.BattleRec, m: Member.Member, cursor: Int32): WindowView.ListBox =
        let rows = WorldBattle.spellsOf(res, r, m) |> List.map(s -> {
            let cost = SpellsDoc.spellOf(res#spells, s#spell) |> Option.map(sp -> sp#mp) |> Option.getWithDefault(0);
            { text = SpellsDoc.nameOf(res#spells, s#spell), right = "${cost}", open = s#open }
        });
        scrolled({ title = TextDoc.menuText(MenuText.Spell, res#text), rows = rows, cursor = cursor, active = true })

    /// どうぐの一覧（右に残りの数。戦いで使えない物・残りの無い物は灰色）。
    def itemBox(res: Res.Res, r: World.BattleRec, cursor: Int32): WindowView.ListBox =
        let rows = WorldBattle.itemsOf(res, r) |> List.map(it -> { text = ItemsDoc.nameOf(res#items, it#item), right = "×${it#left}", open = it#open });
        scrolled({ title = TextDoc.menuText(MenuText.Items, res#text), rows = rows, cursor = cursor, active = true })

    /// 的の一覧（敵は呼び分けた名前・仲間は名前。題は呪文か道具の名前）。
    def targetBox(res: Res.Res, r: World.BattleRec, page: CommandPage, title: String): WindowView.ListBox =
        let b = Battle.rec(r#battle);
        let nameOf = target -> match target {
            case Battle.Target.Foe(i)  => Vector.nth(i, b#foes) |> Option.map(f -> f#label) |> Option.getWithDefault("")
            case Battle.Target.Ally(m) => PartyDoc.memberOf(m, res#party)#name
            case _                     => ""
        };
        let rows = WorldBattle.targetsOfPage(res, r, page) |> List.map(t -> { text = nameOf(t), right = "", open = true });
        scrolled({ title = title, rows = rows, cursor = WorldBattle.cursorOf(page), active = true })

    /// 一覧のウィンドウに入る行の数。
    def sideRows(): Int32 = 5

    /// 入りきらない一覧は、カーソルの行が見えるところまで上の行を落とす。
    def scrolled(box: WindowView.ListBox): WindowView.ListBox =
        let skip = Int32.max(0, box#cursor - (sideRows() - 1));
        { rows = box#rows |> List.drop(skip) |> List.take(sideRows()), cursor = box#cursor - skip | box }

    def battleCommandTextOf(c: World.BattleCommand): MenuText = match c {
        case World.BattleCommand.Fight  => MenuText.Fight
        case World.BattleCommand.Spell  => MenuText.Spell
        case World.BattleCommand.Items  => MenuText.Items
        case World.BattleCommand.Defend => MenuText.Defend
        case World.BattleCommand.Flee   => MenuText.Flee
    }
}
