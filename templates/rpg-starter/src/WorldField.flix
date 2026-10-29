// WorldField — マップを歩く規則: マス単位の歩き・当たり・出入口・イベントのマス・次の戦いまでの歩数・
// 話しかける・読み直しで収める（すべて純粋）。マスにある物（宝箱・扉…）は見つけて WorldObject へ渡すだけ、
// 暗転を進めるのは WorldTransition。
// 1 マスは rules の secondsPerTile 秒。押したままなら着いたフレームで次の 1 マスへ続け、次の歩き始めは
// 前の歩き始め + secondsPerTile にする（着いたフレームの今を使うと、はみ出したぶん 1 マスごとに遅れが積もる）。
mod WorldField {
    use fge::{Clock, Dir4, Emit, Grid, Log}
    use World.{TransitionThen, FieldRec, Stride}

    def secondsPerTile(res: Res.Res): Float64 = RulesDoc.rec(res#rules)#secondsPerTile

    def mapOf(res: Res.Res, r: FieldRec): Option[MapDoc.Doc] = MapDoc.docOf(res#maps, r#map)

    // ── 当たり ──

    /// マップの人と物の今: absent = マップから消えた人の id（加わった仲間）・
    /// objects = 物の今のマス → そのマスの物（WorldObject.objectsNow。床のスイッチに載った岩のように 1 マスに 2 つ並ぶ事がある。塞ぐ物が先）。
    pub type alias Occupancy = { absent = Set[String], objects = Map[(Int32, Int32), List[WorldObject.Placed]] }

    /// World の今の、map（いるマップの Doc）の人と物（フィールドでなければ物は無し）。
    pub def occupancyOf(map: MapDoc.Doc, w: World.World): Occupancy =
        let objects = World.fieldRecOf(w) |> Option.map(r -> WorldObject.objectsNow(map, r, w#progress)) |> Option.getWithDefault(Nil);
        let (blocking, flat) = objects |> List.partition(WorldObject.blocks);
        { absent = Party.joinedIds(w#party),
          objects = List.append(blocking, flat) |> List.foldRight((p, acc) -> Map.insertWith((mine, rest) -> List.append(mine, rest), (p#cell#x, p#cell#y), p :: Nil, acc), Map.empty()) }

    /// cell に立てるか: 地図の文字が歩ける（扉の文字は出入口のあるマスだけ。現れた飛び石の上は水でも立てる）・人がいない・塞ぐ物が無い。
    pub def canEnter(map: MapDoc.Doc, occ: Occupancy, cell: Grid.Cell): Bool =
        let m = MapDoc.rec(map);
        let key = (cell#x, cell#y);
        let someone = Map.get(key, m#npcAt) |> Option.exists(npc -> not Set.memberOf(npc#id, occ#absent));
        let here = Map.getWithDefault(key, Nil, occ#objects);
        let thing = here |> List.exists(WorldObject.blocks);
        let floored = here |> List.exists(WorldObject.floors);
        not someone and not thing and (floored or allows(passageAt(map, cell), Map.memberOf(key, m#exitAt)))

    /// 今いる所（フィールドの先頭のマス）に立てるか（Starts が場面を組んだ後に見る）。
    pub def canStandHere(res: Res.Res, w: World.World): Bool =
        World.fieldRecOf(w) |> Option.exists(r -> mapOf(res, r) |> Option.exists(map -> canEnter(map, occupancyOf(map, w), r#hero)))

    def allows(passage: Tileset.Passage, hasExit: Bool): Bool = match passage {
        case Tileset.Passage.Walk    => true
        case Tileset.Passage.Door    => hasExit
        case Tileset.Passage.Block   => false
        case Tileset.Passage.Counter => false
    }

    def passageAt(map: MapDoc.Doc, cell: Grid.Cell): Tileset.Passage =
        MapDoc.charAt(cell#x, cell#y, map)
            |> Option.map(ch -> Tileset.passageOf(MapDoc.rec(map)#tileset, ch))
            |> Option.getWithDefault(Tileset.Passage.Block)

    /// cell が閉じた出入口なら、その閉じる条件（gate の仲間がまだ加わっていない）。
    def closedGateAt(map: MapDoc.Doc, party: Party.Party, cell: Grid.Cell): Option[MapDoc.Gate] =
        Map.get((cell#x, cell#y), MapDoc.rec(map)#exitAt) |> Option.flatMap(closedGateOf(party))

    /// 出入口が閉じていれば、その閉じる条件。
    def closedGateOf(party: Party.Party, exit: MapDoc.Exit): Option[MapDoc.Gate] =
        exit#gate |> Option.filter(gate -> not Party.hasJoined(gate#member, party))

    /// 今の World で cell へ進めるか（地図・人・物・閉じた gate）。
    def canStep(res: Res.Res, w: World.World, r: FieldRec, cell: Grid.Cell): Bool =
        mapOf(res, r) |> Option.exists(map ->
            canEnter(map, occupancyOf(map, w), cell) and Option.isEmpty(closedGateAt(map, w#party, cell)))

    /// cell にある物の今（塞ぐ物が先。フィールドでなければ None）。
    def objectAt(res: Res.Res, cell: Grid.Cell, w: World.World): Option[WorldObject.Placed] =
        forM (r <- World.fieldRecOf(w); map <- mapOf(res, r); here <- Map.get((cell#x, cell#y), occupancyOf(map, w)#objects); p <- List.head(here)) yield p

    def isStill(stride: Stride): Bool = match stride {
        case Stride.Still         => true
        case Stride.Walking(_, _) => false
        case Stride.Boarding      => false
        case Stride.Riding(_)     => false
    }

    /// 1 マス歩き始める: 今のマスを trail の頭に入れ（後ろの人がそこへ詰める）、cell へ向かう。
    def stepTo(cell: Grid.Cell, dir: Dir4.Dir4, at: Clock.Time[World.Play], r: FieldRec): FieldRec =
        { stride = Stride.Walking(r#hero, at), hero = cell, facing = dir,
          trail = List.take(World.trailLength(), (r#hero, r#facing) :: r#trail) | r }

    // ── 歩く（入力） ──

    /// 方向を押している（pressed = このフレームに押した）。止まっていれば向きを変え、進めれば 1 マス歩き始める。
    /// マップの端から外へ向かい、その向きの端の出入口（MapDoc.ExitPlace.Edge）があれば、その場で暗転して移る。
    /// 閉じた gate へは進めず（端の出入口も同じ）、向きを変えて gateNode の会話を開く。ウィンドウを閉じた向きを押したままの間は向きを変えるだけ。
    /// 進めない時は向きだけ変え、前の物に押された時の規則（WorldObject.onPush）があればそれを、無ければ押したフレームだけぶつかる音を出す。
    pub def walk(res: Res.Res, dir: Dir4.Dir4, pressed: Bool, w: World.World): World.World \ Emit[World.Event] =
        match World.fieldRecOf(w) {
            case Some(r) if isStill(r#stride) => stepFrom(res, dir, pressed, r, w)
            case _                            => w
        }

    def stepFrom(res: Res.Res, dir: Dir4.Dir4, pressed: Bool, r: FieldRec, w: World.World): World.World \ Emit[World.Event] =
        let next = Grid.neighborOf(r#hero, dir);
        let map = mapOf(res, r);
        let edge = map |> Option.flatMap(MapDoc.edgeExitOf(r#hero#x, r#hero#y, dir));
        let closed = match edge {
            case Some(exit) => closedGateOf(w#party, exit)
            case None       => map |> Option.flatMap(m -> closedGateAt(m, w#party, next))
        };
        let turned = World.mapField(rec -> { facing = dir | rec }, w);
        match (closed, edge) {
            case _ if List.memberOf(dir, r#awaitRelease) => turned
            case (Some(gate), _) => WorldTalk.open(res, gate#node, None, turned)
            case (None, Some(exit)) => World.mapField(rec -> startWarp(res, exit, World.now(w), rec), turned)
            case (None, None) if canStep(res, w, r, next) => World.mapField(rec -> stepTo(next, dir, World.now(w), rec), w)
            case (None, None) => pushOrBump(res, r, next, dir, pressed, turned)
        }

    /// 塞がれた前のマスへ進もうとした: そこの物が押されて何かするならそれを（押した物がどいて前が空けば、そこへ 1 マス歩き始める）、
    /// しなければ押したフレームだけぶつかる音。
    def pushOrBump(res: Res.Res, r: FieldRec, next: Grid.Cell, dir: Dir4.Dir4, pressed: Bool, w: World.World): World.World \ Emit[World.Event] =
        match objectAt(res, next, w) |> Option.flatMap(p -> WorldObject.onPush(res, r#map, p, dir, w)) {
            case Some(pushed) if canStep(res, pushed, r, next) => World.mapField(rec -> stepTo(next, dir, World.now(pushed), rec), pushed)
            case Some(pushed) => pushed
            case None => {
                if (pressed) Emit.emit(World.Event.Bump) else ();
                w
            }
        }

    // ── 時間で進む物（毎フレーム。暗転の間は Controls.tick が WorldTransition を流し、ここは呼ばない） ──

    /// 歩きとトロッコを進める。held = 押したままの方向。
    pub def tick(res: Res.Res, held: Option[Dir4.Dir4], w: World.World): World.World \ Emit[World.Event] =
        match World.fieldRecOf(w) |> Option.map(r -> r#stride) {
            case Some(Stride.Boarding)     => board(res, w)
            case Some(Stride.Riding(ride)) => rideTick(res, ride, w)
            case _                         => strideTick(res, held, w)
        }

    /// 乗ると決めた（<<ride>>）: 前のトロッコから走り出す。走れるレールが無ければ止まって、塞がっていると知らせる。
    def board(res: Res.Res, w: World.World): World.World =
        Rail.startRide(res, w) |> Option.getWithDefault(
            World.mapField(r -> { stride = Stride.Still | r }, w)
                |> World.showNotice(TextDoc.noticeText(TextDoc.NoticeText.CartStuck, Nil, res#text), World.NoticeThen.Close))

    /// トロッコ: 道の終わりまで走る時間が経ったら降りる（先頭は降りるマスに止まり、隊列はそこへ重なる）。走っている間は出会いも明かりの歩数も数えない。
    def rideTick(res: Res.Res, ride: World.Ride, w: World.World): World.World =
        let seconds = Int32.toFloat64(List.length(ride#path) - 1) * RulesDoc.rec(res#rules)#secondsPerRail;
        if (Clock.since(ride#startedAt, World.now(w)) < seconds) w
        else World.mapField(r -> { stride = Stride.Still, trail = Nil | r }, w)

    /// 歩いていて 1 マスぶんの時間が経っていれば、着いた時刻（歩き始め + secondsPerTile）。
    def arrivalOf(res: Res.Res, w: World.World): Option[Clock.Time[World.Play]] =
        World.fieldRecOf(w) |> Option.flatMap(r -> match r#stride {
            case Stride.Walking(_, at) if Clock.since(at, World.now(w)) >= secondsPerTile(res) => Some(Clock.after(secondsPerTile(res), at))
            case _ => None
        })

    def strideTick(res: Res.Res, held: Option[Dir4.Dir4], w: World.World): World.World \ Emit[World.Event] =
        match arrivalOf(res, w) {
            case Some(at) => arrive(res, held, at, w)
            case None     => w
        }

    /// 着いたマスにある物: 出入口・イベント・マスにある物（いるマップと一緒に）・何も無い。
    enum Here {
        case Exit(MapDoc.Exit)
        case Event(MapDoc.Event)
        case Object(MapDoc.MapId, WorldObject.Placed)
        case Plain
    }

    def hereOf(res: Res.Res, w: World.World): Here =
        let found = forM (r <- World.fieldRecOf(w); map <- mapOf(res, r)) yield {
            let key = (r#hero#x, r#hero#y);
            let m = MapDoc.rec(map);
            Map.get(key, m#exitAt) |> Option.map(Here.Exit)
                |> Option.withDefault(default = Map.get(key, m#eventAt) |> Option.map(Here.Event))
                |> Option.withDefault(default = Map.get(key, occupancyOf(map, w)#objects) |> Option.flatMap(List.head) |> Option.map(p -> Here.Object(r#map, p)))
        };
        found |> Option.flatMap(x -> x) |> Option.getWithDefault(Here.Plain)

    /// 今のマスに着いた（at = 着いた時刻）。出入口なら暗転、イベントなら止まって会話を開く、物なら WorldObject.onArrive に任せ、
    /// 何も無いマス（と、着いても何もしない物のマス）なら次の戦いまでの歩数を数え、出会わなければ押したままの方向へ次の 1 マスへ続ける。
    def arrive(res: Res.Res, held: Option[Dir4.Dir4], at: Clock.Time[World.Play], w0: World.World): World.World \ Emit[World.Event] =
        let w = burnLight(res, w0);
        match hereOf(res, w) {
            case Here.Exit(exit)     => World.mapField(r -> startWarp(res, exit, at, r), w)
            case Here.Event(e)       => WorldTalk.open(res, e#node, None, World.mapField(r -> { stride = Stride.Still | r }, w))
            case Here.Object(map, p) => arriveAtObject(res, held, at, map, p, w)
            case Here.Plain          => continueOrMeet(res, held, at, countStep(res, w))
        }

    /// 暗いマップで 1 マス歩き終えた: たいまつの残りの歩数を 1 減らす（明るいマップでは減らさない）。
    def burnLight(res: Res.Res, w: World.World): World.World =
        World.mapField(r -> {
            let dark = mapOf(res, r) |> Option.exists(map -> MapDoc.rec(map)#dark);
            if (dark and r#light > 0) { light = r#light - 1 | r } else r
        }, w)

    def arriveAtObject(res: Res.Res, held: Option[Dir4.Dir4], at: Clock.Time[World.Play], map: MapDoc.MapId, p: WorldObject.Placed,
                       w: World.World): World.World \ Emit[World.Event] =
        match WorldObject.onArrive(res, map, p, w) {
            case Some(handled) => handled
            case None          => continueOrMeet(res, held, at, countStep(res, w))
        }

    /// 何も無いマスに着いた: 数えた歩数で出会ったら止まり（点滅が始まっている）、出会わなければ押したままの方向へ続ける。
    /// WhyNot: 出入口とイベントのマスでは数えない — 出会いの点滅と出入口の暗転・会話が同じマスで重なると、どちらかが黙って捨てられる。
    def continueOrMeet(res: Res.Res, held: Option[Dir4.Dir4], at: Clock.Time[World.Play], w: World.World): World.World \ Emit[World.Event] =
        if (World.fieldRecOf(w) |> Option.exists(r -> Option.nonEmpty(r#transition))) w
        else continueOrStop(res, held, at, w)

    /// 押したままなら次の 1 マスへ続ける。進めない（閉じた gate も）なら止まる（gate の会話は次のフレームの walk が開く）。
    def continueOrStop(res: Res.Res, held: Option[Dir4.Dir4], at: Clock.Time[World.Play], w: World.World): World.World \ Emit[World.Event] =
        let next = forM (r <- World.fieldRecOf(w); d <- held; cell <- Some(Grid.neighborOf(r#hero, d)); ok <- if (canStep(res, w, r, cell)) Some(cell) else None)
                   yield (d, ok);
        match next {
            case Some((d, cell)) => strideTick(res, held, World.mapField(r -> stepTo(cell, d, at, r), w))
            case None            => World.mapField(r -> { stride = Stride.Still | r }, w)
        }

    // ── 次の戦いまでの歩数と出会い ──

    /// 1 マス歩き終えた: 出会いの組のあるマップなら次の戦いまでの歩数を 1 減らす（まだ引いていなければ先に引く）。
    /// 0 になったら次の歩数を引き直し、組を重みで 1 つ選んで点滅を始める（点滅し終えたら戦う）。
    def countStep(res: Res.Res, w: World.World): World.World =
        match World.fieldRecOf(w) {
            case Some(r) if hasEncounters(res, r) => {
                let (left, drawn) = if (r#stepsToFight > 0) (r#stepsToFight, w) else drawSteps(res, w);
                if (left > 1) World.mapField(rec -> { stepsToFight = left - 1 | rec }, drawn)
                else {
                    let (next, after) = drawSteps(res, drawn);
                    encounter(res, r, World.mapField(rec -> { stepsToFight = next | rec }, after))
                }
            }
            case _ => w
        }

    /// 出会う: マップの encounter から組を重みで選び（Doc に無い敵は飛ばす）、点滅を始める。選べる組が無ければ何もしない。
    def encounter(res: Res.Res, r: FieldRec, w: World.World): World.World =
        let groups = mapOf(res, r) |> Option.map(map -> MapDoc.rec(map)#encounter) |> Option.getWithDefault(Nil)
            |> List.map(e -> (e#foes |> List.filterMap(FoesDoc.idOf(res#foes)), e#weight))
            |> List.filter(row -> not List.isEmpty(fst(row)));
        let (picked, after) = Dice.weighted(Dice.Channel.EncounterGroup, groups, w);
        picked |> Option.map(foes -> World.startEncounter(foes, None, after)) |> Option.getWithDefault(after)

    def hasEncounters(res: Res.Res, r: FieldRec): Bool =
        mapOf(res, r) |> Option.exists(map -> not List.isEmpty(MapDoc.rec(map)#encounter))

    /// 次の戦いまでの歩数を、いるマップの minSteps..maxSteps（無ければ rules の範囲。両端を含む）から引く。
    def drawSteps(res: Res.Res, w: World.World): (Int32, World.World) =
        let rules = RulesDoc.rec(res#rules);
        let (min, max) = World.fieldRecOf(w) |> Option.flatMap(r -> mapOf(res, r)) |> Option.flatMap(map -> MapDoc.rec(map)#steps)
            |> Option.getWithDefault((rules#minSteps, rules#maxSteps));
        let lo = Int32.max(1, min);
        Dice.range(Dice.Channel.EncounterSteps, lo, Int32.max(lo, max), w)

    // ── 出入口 ──

    /// 出入口を通る: 暗転を始め、覆い切ったら行き先へ移る（WorldTransition）。行き先のマップが無ければ動かずに 1 行言う。
    def startWarp(res: Res.Res, exit: MapDoc.Exit, at: Clock.Time[World.Play], r: FieldRec): FieldRec \ Emit[World.Event] =
        match MapDoc.idOf(res#maps, exit#to) {
            case Some(id) => {
                Emit.emit(World.Event.Door);
                let arrival = { x = exit#spawnX, y = exit#spawnY };
                { stride = Stride.Still, transition = Some({ startedAt = at, then = TransitionThen.Warp(id, arrival, exit#facing) }) | r }
            }
            case None =>
                Log.warnThen("[map] 出入口 '${exit#id}' の行き先 '${exit#to}' が無いので移らない", { stride = Stride.Still | r })
        }

    // ── 話しかける・調べる ──

    /// 決定: 向いている前のマスの人（机などの Counter の向こうの人も）の会話を開く。人がいなければ前のマスの物を調べる。
    /// 歩きの途中・node の無い人は何もしない（node の無い人は Res.problemsOf が起動時に言う）。
    pub def interact(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        tryInteract(res, w) |> Option.getWithDefault(w)

    /// interact と同じ。話せる人も調べる物も無ければ None（メニューの はなす・しらべる が「だれも いない」を出す）。
    pub def tryInteract(res: Res.Res, w: World.World): Option[World.World] \ Emit[World.Event] =
        let still = World.fieldRecOf(w) |> Option.exists(r -> isStill(r#stride));
        let talk = npcInFrontOf(res, w)
            |> Option.filter(npc -> not String.isEmpty(npc#node))
            |> Option.map(npc -> WorldTalk.open(res, npc#node, Some(npc#id), w));
        match talk {
            case _ if not still => None
            case Some(opened)   => Some(opened)
            case None           => examineInFront(res, w)
        }

    /// 向いている前のマスの人（机などの Counter の向こうの人も。加わってマップから消えた人は数えない）。
    pub def npcInFrontOf(res: Res.Res, w: World.World): Option[MapDoc.Npc] =
        forM (r <- World.fieldRecOf(w); map <- mapOf(res, r); npc <- npcInFront(map, Party.joinedIds(w#party), r)) yield npc

    def npcInFront(map: MapDoc.Doc, absent: Set[String], r: FieldRec): Option[MapDoc.Npc] =
        let npcAt = cell -> Map.get((cell#x, cell#y), MapDoc.rec(map)#npcAt) |> Option.filter(npc -> not Set.memberOf(npc#id, absent));
        let front = Grid.neighborOf(r#hero, r#facing);
        let beyond = Grid.neighborOf(front, r#facing);
        let acrossCounter = if (passageAt(map, front) == Tileset.Passage.Counter) npcAt(beyond) else None;
        npcAt(front) |> Option.withDefault(default = acrossCounter)

    /// 向いている前のマスの物を調べる（物が無い・調べても何も無ければ None）。
    def examineInFront(res: Res.Res, w: World.World): Option[World.World] \ Emit[World.Event] =
        forM (r <- World.fieldRecOf(w); p <- objectAt(res, Grid.neighborOf(r#hero, r#facing), w);
              examined <- WorldObject.examine(res, r#map, p, w))
        yield examined

    // ── 始まりの場所と、読み直しで収める ──

    /// rules の始まりのマップとマスと向き（マップが無ければ None）。
    pub def startOf(res: Res.Res): Option[(MapDoc.MapId, Grid.Cell, Dir4.Dir4)] =
        let rules = RulesDoc.rec(res#rules);
        MapDoc.idOf(res#maps, rules#startMap) |> Option.map(id -> (id, { x = rules#startX, y = rules#startY }, rules#startFacing))

    /// マップを読み直した後に、いる所を収める: いるマップが消えたら始まりの場所へ、
    /// いるマスに立てなくなったら一番近い立てるマスへ（歩きの途中なら止める）。
    pub def settle(res: Res.Res, w: World.World): World.World =
        match World.fieldRecOf(w) |> Option.map(r -> mapOf(res, r)) {
            case Some(Some(map)) => World.mapField(rec -> settleIn(map, occupancyOf(map, w), rec), w)
            case Some(None)      => toStart(res, w)
            case None            => w
        }

    def toStart(res: Res.Res, w: World.World): World.World =
        startOf(res) |> Option.map(match (map, cell, facing) -> World.placeField(map, cell, facing, w)) |> Option.getWithDefault(w)

    def settleIn(map: MapDoc.Doc, occ: Occupancy, r: FieldRec): FieldRec =
        if (canEnter(map, occ, r#hero)) r
        else nearestOpen(map, occ, r#hero)
            |> Option.map(cell -> { hero = cell, stride = Stride.Still, trail = Nil | r })
            |> Option.getWithDefault(r)

    /// origin に一番近い（縦横の遠い方の差が小さい順・同じなら上の行・左の列）立てるマス。
    def nearestOpen(map: MapDoc.Doc, occ: Occupancy, origin: Grid.Cell): Option[Grid.Cell] =
        let m = MapDoc.rec(map);
        Grid.cellsOfRows(m#rows)
            |> List.map(fst)
            |> List.filter(cell -> canEnter(map, occ, cell))
            |> List.map(cell -> ((Int32.max(Int32.abs(cell#x - origin#x), Int32.abs(cell#y - origin#y)), cell#y, cell#x), cell))
            |> List.sortBy(fst)
            |> List.head
            |> Option.map(snd)
}
