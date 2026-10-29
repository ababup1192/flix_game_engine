// Rail — トロッコの走る道（すべて純粋）。乗った時に 1 回だけ、レールのマスを辿って列を作る（走っている間は列を読むだけ）。
// 進み方: 分かれ目のマスでは分かれ目が選んだ向きへ、ほかのマスでは今の向きのまま。前がレールでなければ左右のレールへ曲がり（曲がり角）、
// どちらも無ければそこで終わる（降りるマス）。来た向きへは戻らない。
mod Rail {
    use fge::{Dir4, Grid}
    use World.Stride

    /// 向いている前のマスのトロッコに乗って走り出す（会話の <<ride>>）: 先頭はトロッコのマスから道の終わりまで走り（FieldRec#hero は降りるマス）、
    /// 隊列は畳む。前にトロッコが無い・走れるレールが無ければ None（レールが塞がっていると知らせるのは呼ぶ側の会話の後）。
    /// 分かれ目は今の旗で選んだ向き（WorldObject の状態が Opened なら dirOn）、ほかのトロッコと岩のマスの手前で止まる。
    /// 走り出す音は Controls.rideSoundsOf（前後の World の見比べ。会話のコマンドは音を出せない所から呼ばれる）。
    pub def startRide(res: Res.Res, w: World.World): Option[World.World] =
        forM (
            r <- World.fieldRecOf(w);
            map <- MapDoc.docOf(res#maps, r#map);
            placed <- Some(WorldObject.objectsNow(map, r, w#progress));
            front <- Some(Grid.neighborOf(r#hero, r#facing));
            cart <- placed |> List.find(p -> sameCell(p#cell, front) and Option.nonEmpty(cartDirOf(p)));
            dir <- cartDirOf(cart);
            path <- Some(pathOf(map, placed, cart));
            last <- List.last(path)
        ) yield {
            let facing = lastDirOf(front :: path) |> Option.getWithDefault(dir);
            World.mapField(rec -> { stride = Stride.Riding({ cart = cart#object#id, path = front :: path, startedAt = World.now(w) }),
                                    hero = last, facing = facing, trail = Nil | rec }, w)
        }

    /// cart（placed の中のトロッコ）に今乗ると走るマスの列（トロッコのマスは含まない・最後が降りるマス。トロッコでなければ空）。
    /// placed は map の物の今（WorldObject.objectsNow）。bot が「どのトロッコに乗ればどこへ着くか」を見るのにも使う。
    pub def pathOf(map: MapDoc.Doc, placed: List[WorldObject.Placed], cart: WorldObject.Placed): List[Grid.Cell] =
        match cartDirOf(cart) {
            case None => Nil
            case Some(dir) => pathFrom({ grid = MapDoc.rec(map)#grid, turns = turnsOf(placed),
                                         blocked = placed |> List.filter(p -> WorldObject.blocks(p) and p#object#id != cart#object#id)
                                                          |> List.map(p -> (p#cell#x, p#cell#y)) |> List.toSet,
                                         start = cart#cell, dir = dir })
        }

    /// トロッコか（Cart の種類）。
    pub def isCart(p: WorldObject.Placed): Bool = Option.nonEmpty(cartDirOf(p))

    def sameCell(a: Grid.Cell, b: Grid.Cell): Bool = a#x == b#x and a#y == b#y

    def cartDirOf(p: WorldObject.Placed): Option[Dir4.Dir4] = match p#object#kind {
        case MapDoc.ObjectKind.Cart(cart) => Some(cart#dir)
        case _                            => None
    }

    /// 分かれ目のマス → 今の旗で選んだ向き（旗が立っていれば dirOn）。
    def turnsOf(placed: List[WorldObject.Placed]): Map[(Int32, Int32), Dir4.Dir4] =
        placed |> List.filterMap(p -> match p#object#kind {
            case MapDoc.ObjectKind.Junction(j) =>
                Some(((p#cell#x, p#cell#y), if (p#state == WorldObject.ObjectState.Opened) j#dirOn else j#dir))
            case _ => None
        }) |> List.toMap

    /// 道の最後の 1 マスを進んだ向き（2 マス無ければ None）。
    def lastDirOf(cells: List[Grid.Cell]): Option[Dir4.Dir4] =
        let tail = List.drop(Int32.max(0, List.length(cells) - 2), cells);
        match tail {
            case a :: b :: Nil => Dir4.all() |> List.find(d -> sameCell(Grid.neighborOf(a, d), b))
            case _             => None
        }

    /// レールの文字（横 = と縦 |。曲がり角も同じ 2 文字で、絵は隣のレールから選ぶ）。
    def chars(): Set[Char] = Set#{'=', '|'}

    /// 走る道を作るのに要る物: grid = マップの格子・turns = 分かれ目のマス → 今の旗で選んだ向き・
    /// blocked = 塞ぐ物のあるマス（ほかのトロッコ・岩。手前で止まる）・start = 乗ったマス・dir = 走り出す向き。
    pub type alias Spec = { grid = Vector[Vector[Char]], turns = Map[(Int32, Int32), Dir4.Dir4], blocked = Set[(Int32, Int32)],
                            start = Grid.Cell, dir = Dir4.Dir4 }

    /// start から走るマスの列（start は含まない・最後が降りるマス）。走れなければ空。
    /// WhyNot: 長さを格子のマス数で切る — 輪になったレールでも止まる（同じマスへ戻るのは描き損じなので、そこで降ろす）。
    def pathFrom(spec: Spec): List[Grid.Cell] =
        let limit = spec#grid |> Vector.map(Vector.length) |> Vector.sum;
        follow(spec, spec#start, spec#dir, Nil, limit)

    def follow(spec: Spec, cell: Grid.Cell, dir: Dir4.Dir4, acc: List[Grid.Cell], left: Int32): List[Grid.Cell] =
        let out = Map.get((cell#x, cell#y), spec#turns) |> Option.getWithDefault(dir);
        let isTurn = Map.memberOf((cell#x, cell#y), spec#turns);
        let choices = if (isTurn) out :: Nil else out :: sidesOf(out);
        match (left > 0, choices |> List.find(d -> canRide(spec, Grid.neighborOf(cell, d)))) {
            case (true, Some(d)) => {
                let next = Grid.neighborOf(cell, d);
                follow(spec, next, d, next :: acc, left - 1)
            }
            case _ => List.reverse(acc)
        }

    /// 向きの左右（曲がり角で選ぶ向き。上下なら左・右の順、左右なら上・下の順）。
    def sidesOf(dir: Dir4.Dir4): List[Dir4.Dir4] = match dir {
        case Dir4.Dir4.Up    => Dir4.Dir4.Left :: Dir4.Dir4.Right :: Nil
        case Dir4.Dir4.Down  => Dir4.Dir4.Left :: Dir4.Dir4.Right :: Nil
        case Dir4.Dir4.Left  => Dir4.Dir4.Up :: Dir4.Dir4.Down :: Nil
        case Dir4.Dir4.Right => Dir4.Dir4.Up :: Dir4.Dir4.Down :: Nil
    }

    def canRide(spec: Spec, cell: Grid.Cell): Bool =
        let isRail = Vector.nth(cell#y, spec#grid) |> Option.flatMap(Vector.nth(cell#x)) |> Option.exists(ch -> Set.memberOf(ch, chars()));
        isRail and not Set.memberOf((cell#x, cell#y), spec#blocked)
}
