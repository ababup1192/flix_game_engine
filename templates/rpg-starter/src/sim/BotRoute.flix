// BotRoute — bot の道の計算（すべて純粋）。マップの間は exits をつないだ図の最短、マップの中は GridSearch.distances
// （通れるかは規則と同じ WorldField.canEnter）。目的のマスへ歩いて着けない時の寄り道（トロッコ・分かれ目のレバー）もここ。
// 何をしに行くか（道筋の表）は Bot、戦いの方針は BotBattle。この mod は Bot も BotBattle も使わない。
mod BotRoute {
    use fge::{Dir4, Grid, GridSearch}

    /// 着いたらする事。Talk = その人に話しかける / Examine = 物（宝箱・レバー・番をする者・トロッコ・水晶）を調べる / Reach = そのマスに立つ（着いたら終わり）/
    /// Push(岩の id, x, y, 向き) = (x, y) にある岩をその向きへ 1 マス押す（岩の手前のマスで押す）。
    pub enum Aim with Eq, ToString {
        case Talk(String)
        case Examine(String)
        case Reach(Int32, Int32)
        case Push(String, Int32, Int32, Dir4.Dir4)
    }

    /// 目標のマスに着いた所でする事。Stand = 立つだけ（出入口のマス・Reach）/ Face = その向きを向いて決定（話す・調べる）/
    /// Push = その向きを押す（マップの端の出入口から外へ出る）。
    pub enum Arrive with Eq {
        case Stand
        case Face(Dir4.Dir4)
        case Push(Dir4.Dir4)
    }

    /// マップの中の道: どのマップ・どの目的の、マスごとの残りのマス数と、着いた所でする事（Stand は持たない）。
    pub type alias Route = { key = String, dist = Map[(Int32, Int32), Int32], arrive = Map[(Int32, Int32), Arrive] }

    /// マップの間の図で、from から goal へ行く最初の出入口（同じマップなら None）と、残りの出入口の数。
    def nextExitOf(res: Res.Res, start: String, goal: String): Option[(MapDoc.Exit, Int32)] =
        if (start == goal) None else hopsFrom(res, goal, (start, Nil) :: Nil, Set#{start})

    /// 歩いて通れる出入口か（会話の <<warp>> だけが通る edge = none の出入口は図に入れない）。
    def isWalkable(exit: MapDoc.Exit): Bool = match exit#place {
        case MapDoc.ExitPlace.Cell(_, _) => true
        case MapDoc.ExitPlace.Edge(_)    => true
        case MapDoc.ExitPlace.Nowhere    => false
    }

    /// 幅優先: 行けるマップを順に広げ、goal に着いたら最初の出入口と出入口の数。
    def hopsFrom(res: Res.Res, goal: String, todo: List[(String, List[MapDoc.Exit])], seen: Set[String]): Option[(MapDoc.Exit, Int32)] =
        match todo {
            case Nil => None
            case (map, path) :: rest =>
                if (map == goal) List.reverse(path) |> List.head |> Option.map(first -> (first, List.length(path)))
                else {
                    let exits = Map.get(map, res#maps) |> Option.map(d -> MapDoc.rec(d)#exits) |> Option.getWithDefault(Nil)
                        |> List.filter(e -> not Set.memberOf(e#to, seen) and isWalkable(e));
                    let nextSeen = exits |> List.foldLeft((acc, e) -> Set.insert(e#to, acc), seen);
                    hopsFrom(res, goal, List.append(rest, exits |> List.map(e -> (e#to, e :: path))), nextSeen)
                }
        }

    /// 今いるマップの中の、マップ dest の aim へ向かう目標のマスと、着いた所でする事。マップの間を移る時は最初の出入口のマス（端の出入口はその辺の立てるマス）。
    pub def targetsOf(res: Res.Res, map: MapDoc.Doc, here: String, dest: String, aim: Aim): (List[((Int32, Int32), Arrive)], Int32) =
        match nextExitOf(res, here, dest) {
            case Some((exit, hops)) => (exitCellsOf(map, exit), hops)
            case None if here == dest => (aimCellsOf(map, aim), 0)
            case None => (Nil, 99)
        }

    /// 出入口を通るマス: マスの出入口はそのマス、端の出入口はその辺の全部のマスと、外へ押す向き。
    def exitCellsOf(map: MapDoc.Doc, exit: MapDoc.Exit): List[((Int32, Int32), Arrive)] =
        match MapDoc.cellOf(exit) {
            case Some(cell) => (cell, Arrive.Stand) :: Nil
            case None =>
                Grid.cellsOfRows(MapDoc.rec(map)#rows) |> List.map(fst) |> List.flatMap(cell -> Dir4.all()
                    |> List.filter(d -> MapDoc.edgeExitOf(cell#x, cell#y, d, map) |> Option.exists(e -> e#id == exit#id))
                    |> List.map(d -> ((cell#x, cell#y), Arrive.Push(d))))
        }

    /// 目的のマス: Talk はその人の隣（机の向こうなら 2 マス手前）、Open は物の隣、Reach はそのマス。
    pub def aimCellsOf(map: MapDoc.Doc, aim: Aim): List[((Int32, Int32), Arrive)] =
        let m = MapDoc.rec(map);
        let near = (x, y) -> Dir4.all() |> List.flatMap(d -> {
            let (dx, dy) = Dir4.delta(d);
            let one = (x - dx, y - dy);
            let two = (x - 2 * dx, y - 2 * dy);
            let counter = MapDoc.charAt(fst(one), snd(one), map) |> Option.exists(ch -> Tileset.passageOf(m#tileset, ch) == Tileset.Passage.Counter);
            (one, Arrive.Face(d)) :: (if (counter) (two, Arrive.Face(d)) :: Nil else Nil)
        });
        match aim {
            case Aim.Talk(id)    => m#npcs |> List.find(n -> n#id == id) |> Option.map(n -> near(n#x, n#y)) |> Option.getWithDefault(Nil)
            case Aim.Examine(id) => m#objects |> List.find(o -> o#id == id) |> Option.map(o -> near(o#x, o#y)) |> Option.getWithDefault(Nil)
            case Aim.Reach(x, y) => ((x, y), Arrive.Stand) :: Nil
            case Aim.Push(_, x, y, d) =>
                let (dx, dy) = Dir4.delta(d);
                ((x - dx, y - dy), Arrive.Push(d)) :: Nil
        }

    /// 道を引く（目標のマスを 0 とする幅優先。目標でない出入口のマスは通らない — 踏むと別のマップへ移る）。
    /// 先頭の今のマスは通れる事にする（トロッコを降りたレールの終わりは歩いて入れないマスだが、そこから出られる）。
    pub def routeOf(w: World.World, map: MapDoc.Doc, key: String, targets: List[((Int32, Int32), Arrive)]): Route =
        let occ = WorldField.occupancyOf(map, w);
        let goalCells = targets |> List.map(fst) |> List.toSet;
        let exits = MapDoc.rec(map)#exitAt;
        let hero = World.fieldRecOf(w) |> Option.map(r -> (r#hero#x, r#hero#y));
        let canEnter = cell -> Some(cell) == hero or ((Set.memberOf(cell, goalCells) or not Map.memberOf(cell, exits))
            and WorldField.canEnter(map, occ, { x = fst(cell), y = snd(cell) }));
        let sources = targets |> List.map(fst) |> List.filter(cell -> Map.memberOf(cell, exits) or canEnter(cell));
        { key = key, dist = GridSearch.distances(canEnter, sources, 4000),
          arrive = targets |> List.filter(t -> snd(t) != Arrive.Stand) |> List.toMap }

    /// 目的の道（base）へ歩いて着けない時の寄り道: 歩いて乗れて、降りた所から base へ歩けるトロッコを調べる。
    /// 無ければ、歩いて行けるレバーのうち、動かすとそういうトロッコができる物を調べる（分かれ目の向きを替える）。どちらも無ければ None。
    pub def detourOf(w: World.World, r: World.FieldRec, map: MapDoc.Doc, base: Route): Option[Aim] =
        let occ = WorldField.occupancyOf(map, w);
        let exits = MapDoc.rec(map)#exitAt;
        let heroCell = (r#hero#x, r#hero#y);
        let fromHero = GridSearch.distances(cell -> cell == heroCell or
            (not Map.memberOf(cell, exits) and WorldField.canEnter(map, occ, { x = fst(cell), y = snd(cell) })), heroCell :: Nil, 4000);
        let besides = (cell: Grid.Cell, dist: Map[(Int32, Int32), Int32]) -> Dir4.all() |> List.exists(d -> {
            let (dx, dy) = Dir4.delta(d);
            Map.memberOf((cell#x + dx, cell#y + dy), dist)
        });
        let landing = progress -> {
            let placed = WorldObject.objectsNow(map, r, progress);
            placed |> List.filter(Rail.isCart) |> List.filter(p -> besides(p#cell, fromHero))
                |> List.find(p -> Rail.pathOf(map, placed, p) |> List.last |> Option.exists(end -> besides(end, base#dist)))
        };
        let levers = WorldObject.objectsNow(map, r, w#progress) |> List.filter(p -> besides(p#cell, fromHero))
            |> List.filterMap(p -> match p#object#kind {
                case MapDoc.ObjectKind.Lever(l) => Some((p#object#id, l#flag))
                case _                          => None
            });
        match landing(w#progress) {
            case Some(cart) => Some(Aim.Examine(cart#object#id))
            case None => levers
                |> List.find(match (_, flag) -> Option.nonEmpty(landing(Progress.withFlag(flag, not Progress.isFlagSet(flag, w#progress), w#progress))))
                |> Option.map(match (id, _) -> Aim.Examine(id))
        }
}
