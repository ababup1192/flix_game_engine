// Solve — 面を解く道具（make solve）。深さを区切った幅優先で最少手数の手の列を探し、
// levels の Doc に par・solution・solvedHash を書く。1 手は遊びと同じ World.act を通す（規則を 2 本持たない）。
mod Solve {
    use fge::App
    use World.{Move, State}

    /// 同じ局面かを見る鍵。満ち引きの位相（t mod 周期）が同じなら手数が違っても同じ局面。
    type alias Key = (Board.Cell, Set[Board.Cell], Set[Board.Cell], Map[Board.Cell, Int32], Int32)

    def keyOf(b: Board.Board, s: State): Key =
        (s#crab, s#pebbles, s#driftwood, s#water, Int32.modulo(s#t, Vector.length(b#cycle)))

    /// 最少手数の手の列（depth 手までに解けなければ None）。同じ手数の解が複数あれば W U D L R の順で先の物（待つを先に置くと、解き方の字が往復の足踏みより読みやすい）。
    pub def shortest(depth: Int32, b: Board.Board): Option[List[Move]] =
        let start = World.startOf(b);
        search(b, depth, Set#{keyOf(b, start)}, (start, Nil) :: Nil)

    /// 1 段ずつ広げる。frontier の手の列は新しい手が先頭（逆順）。
    def search(b: Board.Board, depth: Int32, seen: Set[Key], frontier: List[(State, List[Move])]): Option[List[Move]] =
        if (depth <= 0 or List.isEmpty(frontier)) None
        else {
            let moves = Move.Wait :: Move.Up :: Move.Down :: Move.Left :: Move.Right :: Nil;
            let children = frontier |> List.flatMap(match (s, path) ->
                moves |> List.filterMap(move -> World.act(b, move, s) |> Option.map(next -> (next, move :: path))));
            match List.find(c -> fst(c)#phase == World.Phase.Cleared, children) {
                case Some((_, path)) => Some(List.reverse(path))
                case None =>
                    let (nextSeen, nextFrontier) = children
                        |> List.filter(c -> fst(c)#phase == World.Phase.Playing)
                        |> List.foldLeft((acc, c) -> {
                            let (known, kept) = acc;
                            let key = keyOf(b, fst(c));
                            if (Set.memberOf(key, known)) acc else (Set.insert(key, known), c :: kept)
                        }, (seen, Nil));
                    search(b, depth - 1, nextSeen, List.reverse(nextFrontier))
            }
        }

    /// solution を流してもクリアしない・クリアの手数が par と違う面の名前と理由（テストが Nil を期待する）。
    pub def replayProblems(rules: RulesDoc.Doc, doc: LevelsDoc.Doc): List[String] =
        LevelsDoc.rec(doc)#levels |> List.filterMap(level ->
            match (LevelsDoc.boardOf(rules, level), World.movesOf(level#solution)) {
                case (Err(why), _) => Some(why)
                case (_, None) => Some("面「${level#name}」: solution に読めない字（U D L R W）")
                case (Ok(b), Some(moves)) =>
                    let last = World.actAll(b, moves, World.startOf(b));
                    if (last#phase == World.Phase.Cleared and last#t == level#parMoves) None
                    else Some("面「${level#name}」: solution の後が ${last#phase}・${last#t} 手（par ${level#parMoves}）")
            })

    /// 面の中身が make solve で確かめた時から変わった面の名前（テストが Nil を期待する。直したら make solve）。
    pub def staleLevels(rules: RulesDoc.Doc, doc: LevelsDoc.Doc): List[String] =
        LevelsDoc.rec(doc)#levels
            |> List.filter(level -> LevelsDoc.contentHash(rules, level) != level#solvedHash)
            |> List.map(level -> level#name)

    /// make solve の入口。SOLVE_DEPTH（既定 40）までに解けない面は書き換えず、その旨を言う。
    pub def main(): Unit \ IO = App.Headless.exitWith(job(App.Headless.requestFromProcess()))

    def job(req: App.Headless.Request): Int32 \ IO =
        let depth = Map.get("SOLVE_DEPTH", App.Headless.envOf(req)) |> Option.flatMap(Int32.fromString) |> Option.getWithDefault(40);
        run {
            let rules = RulesDoc.load(RulesDoc.path());
            let levels = LevelsDoc.rec(LevelsDoc.load(LevelsDoc.path()))#levels;
            let solved = levels |> List.map(level -> match LevelsDoc.boardOf(rules, level) {
                case Err(why) => { println("[solve] ${why}"); None }
                case Ok(b) => match shortest(depth, b) {
                    case None =>
                        println("[solve] 面「${level#name}」: ${depth} 手までに解けない（書き換えない）");
                        None
                    case Some(path) =>
                        println("[solve] 面「${level#name}」: par ${List.length(path)}  ${World.textOf(path)}");
                        Some({ parMoves = List.length(path), solution = World.textOf(path), solvedHash = LevelsDoc.contentHash(rules, level) })
                }
            });
            let written = Fs.FileRead.read(LevelsDoc.path()) |> Result.toOption
                |> Option.flatMap(LevelsDoc.withSolved(solved))
                |> Option.map(text -> Fs.FileWrite.write({ str = text }, LevelsDoc.path()) |> Result.isOk);
            match written {
                case Some(true) => { println("[solve] ${LevelsDoc.path()} に書きました"); 0 }
                case _ => { println("[solve] ${LevelsDoc.path()} を書けない（読めない・面の数が合わない）"); 1 }
            }
        } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO
}
