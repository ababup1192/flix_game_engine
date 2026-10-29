// WorldObject — マスにある物（マップ Doc の objects）の規則を、種類（MapDoc.ObjectKind）ごとに 1 か所へ集める（すべて純粋）。
// 物の今（いるマス・状態）を組むのは objectsNow だけ（Doc の位置 → 今の位置・開けたかと旗 → 状態）。当たり・調べる・着く・押すは
// WorldField が見つけた物をここへ渡すだけで、種類で分けるのはここの関数:
//   stateOf  … 種類と今の事実（開けたか・立っている旗・岩が載っているか・乗っているか）から導く状態（ObjectState）。絵（FieldScreen.thingPart）はこれだけを読む
//   blocks   … そのマスを塞ぐか（種類と状態から。床に敷く物は塞がない）/ floors … 水のマスでも立てるようにするか（現れた飛び石）
//   examine  … 前のマスを調べた時（決定・メニューの しらべる）
//   onArrive … そのマスに着いた時（床のスイッチ。何もしない種類は None で、歩きはそのまま続く）
//   onPush   … 塞がれたマスへ進もうとした時（岩。何もしない種類は None で、ぶつかる音が鳴る）
// 種類を足す時は MapDoc.ObjectKind に case を足して make check を流すと、stateOf・blocks・examine・onArrive・onPush・
// MapDoc.defaultSpriteOf・FieldScreen.thingBoxOf・Res.kindProblemsOf が並ぶ。読むのは MapDoc.objectKindOf に 1 行。
mod WorldObject {
    use fge::{Dir4, Emit, Grid}
    use MapDoc.ObjectKind
    use TextDoc.Placeholder
    use World.{FieldRec, NoticeThen, Stride}

    /// 物の今の状態。Closed = 閉じている・上がっている・消えている（閉じた絵）/ Opened = 開いた・沈んだ・点いた（開いた絵）/
    /// Gone = 無い（描かない）。
    pub enum ObjectState with Eq, ToString {
        case Closed
        case Opened
        case Gone
    }

    /// 今のマップの物 1 つ: Doc の行・今いるマス・状態（stateOf）。
    pub type alias Placed = { object = MapDoc.Object, cell = Grid.Cell, state = ObjectState }

    /// 物の上にある物。Nothing = 何も無い / Rock = 岩が載っている（床のスイッチを沈める）/ Rider = 乗って走っている（トロッコが駅から無くなる）。
    enum Occupant with Eq {
        case Nothing
        case Rock
        case Rider
    }

    /// 状態を導く今の事実。opened = 開けた（宝箱・扉・番をする者・点けた水晶）/ flags = 立っている旗 / on = 物の上にある物。
    type alias Facts = { opened = Bool, flags = Set[Flag.FlagId], on = Occupant }

    /// (x, y) の物の上にある物（岩のマスなら岩・乗っているトロッコなら乗り手）。
    def occupantOf(o: MapDoc.Object, cell: Grid.Cell, rockCells: Set[(Int32, Int32)], riding: Option[String]): Occupant =
        if (riding == Some(o#id)) Occupant.Rider
        else if (Set.memberOf((cell#x, cell#y), rockCells)) Occupant.Rock
        else Occupant.Nothing

    /// r のいるマップ（map はその Doc）の物の今（Doc の並びの順）。岩は動かした今のマス（r#rocks）、ほかは Doc の位置。
    pub def objectsNow(map: MapDoc.Doc, r: FieldRec, progress: Progress.Progress): List[Placed] =
        let opened = Progress.openedIn(r#map, progress);
        let flags = Progress.flagsOf(progress);
        let riding = World.rideOf(r) |> Option.map(ride -> ride#cart);
        let placed = MapDoc.rec(map)#objects |> List.map(o -> (o, cellNow(r, o)));
        let rockCells = placed |> List.filter(pair -> isRock(fst(pair)#kind)) |> List.map(pair -> (snd(pair)#x, snd(pair)#y)) |> List.toSet;
        placed |> List.map(match (o, cell) ->
            { object = o, cell = cell,
              state = stateOf(o#kind, { opened = Set.memberOf(o#id, opened), flags = flags, on = occupantOf(o, cell, rockCells, riding) }) })

    def cellNow(r: FieldRec, o: MapDoc.Object): Grid.Cell =
        if (isRock(o#kind)) Map.get(o#id, r#rocks) |> Option.getWithDefault({ x = o#x, y = o#y })
        else { x = o#x, y = o#y }

    def isRock(kind: ObjectKind): Bool = match kind {
        case ObjectKind.Rock => true
        case _               => false
    }

    // ── 種類ごとの規則 ──

    /// 種類と今の事実から導く状態: 宝箱は開けると開いた絵のまま塞ぎ、扉と番をする者は開ける（<<open>>）と無くなる。
    /// レバー・分かれ目は旗が立つと Opened、開く物は旗が openWhen の時に無くなる。床のスイッチは旗が立つか岩が載ると沈む。
    /// 水晶は点けたか旗が立つと Opened。飛び石は旗が立つまで無い。トロッコは乗って走っている間だけ駅から無くなる。
    def stateOf(kind: ObjectKind, facts: Facts): ObjectState =
        let flagged = flag -> Set.memberOf(flag, facts#flags);
        let openedIf = cond -> if (cond) ObjectState.Opened else ObjectState.Closed;
        match kind {
            case ObjectKind.Chest(_)    => openedIf(facts#opened)
            case ObjectKind.Door(_)     => if (facts#opened) ObjectState.Gone else ObjectState.Closed
            case ObjectKind.Lever(l)    => openedIf(flagged(l#flag))
            case ObjectKind.Gate(g)     => if (flagged(g#flag) == g#openWhen) ObjectState.Gone else ObjectState.Closed
            case ObjectKind.Guard(_)    => if (facts#opened) ObjectState.Gone else ObjectState.Closed
            case ObjectKind.Plate(p)    => openedIf(flagged(p#flag) or facts#on == Occupant.Rock)
            case ObjectKind.Rock        => ObjectState.Closed
            case ObjectKind.Cart(_)     => if (facts#on == Occupant.Rider) ObjectState.Gone else ObjectState.Closed
            case ObjectKind.Junction(j) => openedIf(flagged(j#flag))
            case ObjectKind.Crystal(c)  => openedIf(facts#opened or flagged(c#flag))
            case ObjectKind.Bridge(b)   => if (flagged(b#flag)) ObjectState.Opened else ObjectState.Gone
            case ObjectKind.Sign(_)     => ObjectState.Closed
        }

    /// そのマスを塞ぐか: 床に敷く物（床のスイッチ・分かれ目・飛び石）は塞がず、ほかは無い物だけ通れる。
    pub def blocks(p: Placed): Bool = match p#object#kind {
        case ObjectKind.Plate(_)    => false
        case ObjectKind.Junction(_) => false
        case ObjectKind.Bridge(_)   => false
        case _                      => p#state != ObjectState.Gone
    }

    /// 地図の文字が入れないマス（湖）でも立てるようにするか（現れた飛び石）。
    pub def floors(p: Placed): Bool = match p#object#kind {
        case ObjectKind.Bridge(_) => p#state == ObjectState.Opened
        case _                    => false
    }

    /// 調べる（map = いるマップ）。開いた宝箱は空と知らせ、無い物と床に敷く物は何も無い（None）。
    /// レバーは旗を切り替えて知らせ、閉じた開く物は「閉じている」と知らせ、番をする者とトロッコはその会話を開く。
    /// 岩は押せると知らせ、水晶は順番を見て点ける。
    pub def examine(res: Res.Res, map: MapDoc.MapId, p: Placed, w: World.World): Option[World.World] \ Emit[World.Event] =
        match p#object#kind {
            case _ if p#state == ObjectState.Gone                 => None
            case ObjectKind.Chest(_) if p#state == ObjectState.Opened => Some(say(res, TextDoc.NoticeText.ChestEmpty :: Nil, Nil, w))
            case ObjectKind.Chest(chest)                          => Some(openChest(res, map, p#object#id, chest, w))
            case ObjectKind.Door(door)                            => Some(tryUnlock(res, map, p#object#id, door#key, w))
            case ObjectKind.Lever(lever)                          => Some(pull(res, lever#flag, w))
            case ObjectKind.Gate(_)                               => Some(say(res, TextDoc.NoticeText.GateShut :: Nil, Nil, w))
            case ObjectKind.Guard(guard)                          => Some(WorldTalk.open(res, guard#node, None, w))
            case ObjectKind.Plate(_)                              => None
            case ObjectKind.Rock                                  => Some(say(res, TextDoc.NoticeText.RockHint :: Nil, Nil, w))
            case ObjectKind.Cart(cart)                            => Some(WorldTalk.open(res, cart#node, None, w))
            case ObjectKind.Junction(_)                           => None
            case ObjectKind.Crystal(crystal)                      => Some(touchCrystal(res, map, p, crystal, w))
            case ObjectKind.Bridge(_)                             => None
            case ObjectKind.Sign(sign)                            => Some(WorldTalk.open(res, sign#node, None, w))
        }

    /// 着いた時。踏むだけの床のスイッチ（hold = false）は、旗がまだなら立てて知らせ（歩きはそこで止まる）、ほかは何もしない。
    pub def onArrive(res: Res.Res, _map: MapDoc.MapId, p: Placed, w: World.World): Option[World.World] \ Emit[World.Event] =
        match p#object#kind {
            case ObjectKind.Plate(plate) if not plate#hold and not Progress.isFlagSet(plate#flag, w#progress) => {
                Emit.emit(World.Event.Lever);
                Some(say(res, TextDoc.NoticeText.PlatePressed :: Nil, Nil,
                         { progress = Progress.withFlag(plate#flag, true, w#progress) | World.mapField(r -> { stride = Stride.Still | r }, w) }))
            }
            case ObjectKind.Chest(_)    => None
            case ObjectKind.Door(_)     => None
            case ObjectKind.Lever(_)    => None
            case ObjectKind.Gate(_)     => None
            case ObjectKind.Guard(_)    => None
            case ObjectKind.Plate(_)    => None
            case ObjectKind.Rock        => None
            case ObjectKind.Cart(_)     => None
            case ObjectKind.Junction(_) => None
            case ObjectKind.Crystal(_)  => None
            case ObjectKind.Bridge(_)   => None
            case ObjectKind.Sign(_)     => None
        }

    /// dir へ進もうとして塞がれた時。岩は 1 マス先が空いていれば動き（先頭が進むのは WorldField）、ほかの種類は動かない。
    pub def onPush(res: Res.Res, map: MapDoc.MapId, p: Placed, dir: Dir4.Dir4, w: World.World): Option[World.World] \ Emit[World.Event] =
        match p#object#kind {
            case ObjectKind.Rock        => pushRock(res, map, p, dir, w)
            case ObjectKind.Chest(_)    => None
            case ObjectKind.Door(_)     => None
            case ObjectKind.Lever(_)    => None
            case ObjectKind.Gate(_)     => None
            case ObjectKind.Guard(_)    => None
            case ObjectKind.Plate(_)    => None
            case ObjectKind.Cart(_)     => None
            case ObjectKind.Junction(_) => None
            case ObjectKind.Crystal(_)  => None
            case ObjectKind.Bridge(_)   => None
            case ObjectKind.Sign(_)     => None
        }

    // ── 岩と床のスイッチ ──

    /// 岩を dir へ 1 マス押す。行き先が岩の入れるマス（rockCanEnter）なら動かし、押さえる床のスイッチが揃った旗を立てる。
    def pushRock(res: Res.Res, map: MapDoc.MapId, p: Placed, dir: Dir4.Dir4, w: World.World): Option[World.World] \ Emit[World.Event] =
        let target = Grid.neighborOf(p#cell, dir);
        forM (r <- World.fieldRecOf(w); doc <- MapDoc.docOf(res#maps, map); _ <- if (rockCanEnter(doc, r, w, target)) Some(()) else None) yield {
            Emit.emit(World.Event.RockPush);
            let moved = World.mapField(rec -> { rocks = Map.insert(p#object#id, target, rec#rocks) | rec }, w);
            raiseHeldPlates(res, doc, moved)
        }

    /// 岩が入れるマス: 歩ける床（レールも）で、人・出入口・会話のマスが無く、物は床のスイッチだけ（ほかの岩・塞ぐ物・飛び石の上へは行かない）。
    /// WhyNot: 出入口と会話のマスへ押させない — 階段の上に岩が載ると、マップを出ないと戻せない所で道が塞がる。
    def rockCanEnter(doc: MapDoc.Doc, r: FieldRec, w: World.World, cell: Grid.Cell): Bool =
        let m = MapDoc.rec(doc);
        let key = (cell#x, cell#y);
        let walkable = MapDoc.charAt(cell#x, cell#y, doc) |> Option.exists(ch -> Tileset.passageOf(m#tileset, ch) == Tileset.Passage.Walk);
        let someone = Option.nonEmpty(MapDoc.standingAt(Party.joinedIds(w#party), Progress.rec(w#progress)#quest, cell#x, cell#y, doc));
        let things = objectsNow(doc, r, w#progress) |> List.filter(o -> o#cell#x == cell#x and o#cell#y == cell#y);
        let onlyPlates = things |> List.forAll(o -> match o#object#kind {
            case ObjectKind.Plate(_) => true
            case _                   => false
        });
        walkable and not someone and onlyPlates and not Map.memberOf(key, m#exitAt) and not Map.memberOf(key, m#eventAt)

    /// 岩で押さえる床のスイッチ（hold = true）のうち、同じ旗の床が全部岩で沈んだ旗を立てる（立てたら知らせる）。
    def raiseHeldPlates(res: Res.Res, doc: MapDoc.Doc, w: World.World): World.World \ Emit[World.Event] =
        let placed = World.fieldRecOf(w) |> Option.map(r -> objectsNow(doc, r, w#progress)) |> Option.getWithDefault(Nil);
        let held = placed |> List.filterMap(p -> match p#object#kind {
            case ObjectKind.Plate(plate) if plate#hold => Some((plate#flag, p#state == ObjectState.Opened))
            case _                                     => None
        });
        let solved = held |> List.foldLeft((acc, pair) -> Map.insertWith((a, b) -> a and b, fst(pair), snd(pair), acc), Map.empty())
            |> Map.toList
            |> List.filter(match (flag, down) -> down and not Progress.isFlagSet(flag, w#progress))
            |> List.map(fst);
        if (List.isEmpty(solved)) w
        else {
            Emit.emit(World.Event.Lever);
            let progress = solved |> List.foldLeft((acc, flag) -> Progress.withFlag(flag, true, acc), w#progress);
            say(res, TextDoc.NoticeText.GateRaised :: Nil, Nil, { progress = progress | w })
        }

    // ── 水晶 ──

    /// 水晶を調べる: 旗が立っているか点けた物は光っていると知らせる。順番（今点いている数 + 1）が合えば点け、全部点いたら旗を立てる。
    /// 合わなければ同じ旗の水晶を全部消す（罰の戦いは無い）。
    def touchCrystal(res: Res.Res, map: MapDoc.MapId, p: Placed, crystal: { flag = Flag.FlagId, order = Int32 }, w: World.World): World.World \ Emit[World.Event] =
        let group = MapDoc.docOf(res#maps, map) |> Option.map(doc -> MapDoc.rec(doc)#objects) |> Option.getWithDefault(Nil)
            |> List.filter(o -> match o#kind {
                case ObjectKind.Crystal(c) => c#flag == crystal#flag
                case _                     => false
            });
        let lit = group |> List.filter(o -> Progress.isOpened(map, o#id, w#progress)) |> List.length;
        if (p#state == ObjectState.Opened) say(res, TextDoc.NoticeText.CrystalShining :: Nil, Nil, w)
        else if (crystal#order == lit + 1 and lit + 1 == List.length(group)) {
            Emit.emit(World.Event.CrystalLit);
            say(res, TextDoc.NoticeText.CrystalAll :: Nil, Nil,
                { progress = w#progress |> Progress.markOpened(map, p#object#id) |> Progress.withFlag(crystal#flag, true) | w })
        }
        else if (crystal#order == lit + 1) {
            Emit.emit(World.Event.CrystalLit);
            say(res, TextDoc.NoticeText.CrystalLit :: Nil, Nil, { progress = Progress.markOpened(map, p#object#id, w#progress) | w })
        }
        else {
            Emit.emit(World.Event.CrystalReset);
            say(res, TextDoc.NoticeText.CrystalReset :: Nil, Nil,
                { progress = Progress.unmarkOpened(map, group |> List.map(o -> o#id), w#progress) | w })
        }

    // ── レバー ──

    /// レバーを動かす: 旗が下りていれば立て、立っていれば下ろして知らせる。
    def pull(res: Res.Res, flag: Flag.FlagId, w: World.World): World.World \ Emit[World.Event] =
        let on = not Progress.isFlagSet(flag, w#progress);
        Emit.emit(World.Event.Lever);
        say(res, (if (on) TextDoc.NoticeText.LeverOn else TextDoc.NoticeText.LeverOff) :: Nil, Nil,
            { progress = Progress.withFlag(flag, on, w#progress) | w })

    // ── 宝箱と扉 ──

    /// 知らせの言葉を行ごとに並べた 1 枚を出す（values は {item}・{gold} を埋める値）。
    def say(res: Res.Res, texts: List[TextDoc.NoticeText], values: List[(Placeholder, String)], w: World.World): World.World =
        let text = texts |> List.map(t -> TextDoc.noticeText(t, values, res#text)) |> List.join("\n");
        World.showNotice(text, NoticeThen.Close, w)

    /// 宝箱を開ける: 中の道具をふくろへ・お金を足し、開けた旗を立てる。ふくろに空きが無ければ開けずに知らせる。
    def openChest(res: Res.Res, map: MapDoc.MapId, id: String, chest: MapDoc.ChestContents, w: World.World): World.World =
        let roomy = chest#item |> Option.forAll(item -> Bag.hasRoomFor(item, w#bag));
        let name = chest#item |> Option.map(item -> ItemsDoc.nameOf(res#items, item) + (if (chest#count > 1) " ×${chest#count}" else "")) |> Option.getWithDefault("");
        let lines = TextDoc.NoticeText.ChestOpened ::
            List.append(if (Option.isEmpty(chest#item)) Nil else TextDoc.NoticeText.ItemGot :: Nil,
                        if (chest#gold > 0) TextDoc.NoticeText.GoldGot :: Nil else Nil);
        let values = (Placeholder.Item, name) :: (Placeholder.Gold, "${chest#gold}") :: Nil;
        if (not roomy) say(res, TextDoc.NoticeText.ChestOpened :: TextDoc.NoticeText.BagFull :: Nil, Nil, w)
        else {
            let bag = chest#item |> Option.map(item -> Bag.give(item, chest#count, w#bag)) |> Option.getWithDefault(w#bag) |> Bag.addGold(chest#gold);
            say(res, lines, values, { bag = bag, progress = Progress.markOpened(map, id, w#progress) | w })
        }

    /// 扉: 鍵の道具がふくろにあれば開けて旗を立てる（鍵は減らさない）。無ければ鍵が掛かっていると知らせる。
    def tryUnlock(res: Res.Res, map: MapDoc.MapId, id: String, key: ItemsDoc.ItemId, w: World.World): World.World =
        if (Bag.countOf(key, w#bag) > 0)
            say(res, TextDoc.NoticeText.Unlocked :: Nil, (Placeholder.Item, ItemsDoc.nameOf(res#items, key)) :: Nil,
                { progress = Progress.markOpened(map, id, w#progress) | w })
        else say(res, TextDoc.NoticeText.Locked :: Nil, Nil, w)
}
