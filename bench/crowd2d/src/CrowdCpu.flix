// 窓を開かずに規則だけを回す入口。描く仕事が混ざらない時間を見る。
mod CrowdCpu {
    use fge::Sort
    use fge::{FlowField, SpatialGrid, Steering}
    use Crowd.NearSearch

    import java.lang.System

    def settleFrames(): Int32 = 120

    def warmFrames(): Int32 = 200

    def measuredFrames(): Int32 = 300

    def pathRepeats(): Int32 = 8

    def pathWarmRepeats(): Int32 = 3

    def tileSize(): Float64 = 16.0

    def tileCols(): Int32 = 40

    def tileRows(): Int32 = 23

    pub def time(): Unit \ IO =
        Sort.sortStable(500 :: 700 :: Crowd.counts()) |> List.forEach(timeCount)

    def timeCount(n: Int32): Unit \ IO = {
        let settled = settle(settleFrames(), Crowd.start(n));
        checkSameResult(settled);
        timeSearch(NearSearch.ScanAll, settled);
        timeSearch(NearSearch.Grid, settled);
        timeGridBuild(settled);
        timePaths(settled)
    }

    def settle(left: Int32, crowd: Crowd.Crowd): Crowd.Crowd =
        if (left <= 0) crowd else settle(left - 1, Crowd.advance(NearSearch.Grid, crowd))

    // WhyNot: 位置が同じことまでは求めない — 足す順が違うので丸めの分だけ値が変わる。
    def checkSameResult(crowd: Crowd.Crowd): Unit \ IO =
        let scanned = Crowd.advance(NearSearch.ScanAll, crowd);
        let gridded = Crowd.advance(NearSearch.Grid, crowd);
        if (scanned#nearPairs == gridded#nearPairs and Crowd.maxPositionGap(scanned, gridded) < 1.0e-9) ()
        else {
            println("[crowd2d-cpu] 2 つの探し方の結果が違う n=${Vector.length(crowd#xs)} near=${scanned#nearPairs}/${gridded#nearPairs}");
            System.exit(1)
        }

    def timeSearch(search: NearSearch, settled: Crowd.Crowd): Unit \ IO = {
        discard runFrames(search, settled, warmFrames(), Nil);
        let (samples, last) = runFrames(search, settled, measuredFrames(), Nil);
        println("[crowd2d-cpu] n=${Vector.length(settled#xs)} search=${search} step_p50=${Timing.fmt3(Timing.percentile(50, samples))} step_p95=${Timing.fmt3(Timing.percentile(95, samples))} near=${Timing.fmt3(Crowd.nearPerEnemy(last))}")
    }

    def runFrames(search: NearSearch, crowd: Crowd.Crowd, left: Int32, samples: List[Float64]): (List[Float64], Crowd.Crowd) \ IO =
        if (left <= 0) (samples, crowd)
        else {
            let (moved, ms) = Timing.measureMs(() -> checked_ecast(Crowd.advance(search, crowd)));
            runFrames(search, moved, left - 1, ms :: samples)
        }

    def timeGridBuild(crowd: Crowd.Crowd): Unit \ IO = {
        discard buildRepeatedly(crowd, warmFrames(), Nil, 0);
        let (samples, seen) = buildRepeatedly(crowd, measuredFrames(), Nil, 0);
        println("[crowd2d-cpu] n=${Vector.length(crowd#xs)} grid_build_p50=${Timing.fmt3(Timing.percentile(50, samples))} seen=${seen}")
    }

    // WhyNot: 作った格子を捨てない — 使わない純粋な呼び出しはコンパイラに消される。
    def buildRepeatedly(crowd: Crowd.Crowd, left: Int32, samples: List[Float64], seen: Int32): (List[Float64], Int32) \ IO =
        if (left <= 0) (samples, seen)
        else {
            let (grid, ms) = Timing.measureMs(() -> checked_ecast(Crowd.buildGrid(crowd#xs, crowd#ys)));
            let near = SpatialGrid.foldNearIndex(grid, 320.0, 180.0, 12.0, 0, (acc, _, _, _) -> acc + 1);
            buildRepeatedly(crowd, left - 1, ms :: samples, seen + near)
        }

    def isOpen(col: Int32, row: Int32): Bool =
        Int32.modulo(col, 10) != 5 or Int32.modulo(row, 8) == 3

    def tileOf(x: Float64, y: Float64): (Int32, Int32) =
        (Int32.min(tileCols() - 1, Float64.tryToInt32(x / tileSize()) |> Option.getWithDefault(0)),
         Int32.min(tileRows() - 1, Float64.tryToInt32(y / tileSize()) |> Option.getWithDefault(0)))

    def tilesOf(crowd: Crowd.Crowd): List[(Int32, Int32)] =
        Vector.zip(crowd#xs, crowd#ys) |> Vector.map(p -> tileOf(fst(p), snd(p))) |> Vector.toList

    def isInsideOpen(cell: (Int32, Int32)): Bool =
        let (col, row) = cell;
        col >= 0 and row >= 0 and col < tileCols() and row < tileRows() and isOpen(col, row)

    def countSteps(steps: List[Option[(Int32, Int32)]]): Int32 =
        steps |> List.count(step -> not Option.isEmpty(step))

    def buildField(target: (Int32, Int32)): FlowField.FlowField =
        FlowField.build(tileCols(), tileRows(), isOpen, target :: Nil, { neighbors = FlowField.Neighbors.Four, maxSteps = tileCols() * tileRows() })

    def chaseEach(tiles: List[(Int32, Int32)], target: (Int32, Int32)): Int32 =
        tiles |> List.map(tile -> Steering.chase(isInsideOpen, tile, target, tileCols() * tileRows())) |> countSteps

    def downhillEach(field: FlowField.FlowField, tiles: List[(Int32, Int32)]): Int32 =
        tiles |> List.map(tile -> FlowField.downhill(field, tile)) |> countSteps

    /// 経路の比べ: 1 体ずつ探す形と、地図を 1 回塗って全員が読む形。
    def timePaths(crowd: Crowd.Crowd): Unit \ IO = {
        let tiles = tilesOf(crowd);
        let target = (3, 3);
        let field = buildField(target);
        let chaseMoved = chaseEach(tiles, target);
        let fieldMoved = downhillEach(field, tiles);
        let measure = (repeat: Unit -> Int32 \ IO) -> {
            List.range(0, pathWarmRepeats()) |> List.forEach(_ -> discard repeat());
            List.range(0, pathRepeats()) |> List.map(_ -> snd(Timing.measureMs(repeat))) |> Timing.percentile(50)
        };
        let chaseMs = measure(() -> checked_ecast(chaseEach(tiles, target)));
        let buildMs = measure(() -> checked_ecast(if (FlowField.isEmpty(buildField(target))) 0 else 1));
        let readMs = measure(() -> checked_ecast(downhillEach(field, tiles)));
        println("[crowd2d-path] n=${Vector.length(crowd#xs)} chase_each_p50=${Timing.fmt3(chaseMs)} field_build_p50=${Timing.fmt3(buildMs)} field_read_p50=${Timing.fmt3(readMs)} moved=${chaseMoved}/${fieldMoved}")
    }
}
