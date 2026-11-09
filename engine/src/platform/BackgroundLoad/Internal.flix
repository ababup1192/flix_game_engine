// BackgroundLoad.Internal — App.withBackgroundLoad が毎コマ回す中身と、BackgroundLoad の判定が共有する道の状態のまとめ方。

/// App.withBackgroundLoad が毎コマ回す中身。ゲームからは呼ばない。
pub mod BackgroundLoad.Internal {

    /// 1 コマぶんに要る物。nowMs = ミリ秒の時刻（差だけを使う）・budget = このコマの予算・priority = 今の優先順の鍵（Loaded でない鍵がある時だけ引く）・
    /// spentMs = このコマで前の step（ほかのグループ）が使った ms。
    pub type alias StepSpec[r: Type, a: Type] = {
        group = BackgroundLoad.Group[r, a],
        downloads = LoadProgress.AssetDownloads,
        nowMs = Unit -> Float64 \ IO,
        budget = LoadProgress.DecodeBudget,
        priority = Unit -> List[String],
        spentMs = Float64
    }

    /// 1 コマ進める。None = 何も変わらない（呼ぶ側は World をそのまま返す）。
    /// Some の 2 つ目は store へ渡す鍵の結果（このコマで Failed になった鍵の Err と、このコマで解いた鍵）。
    /// 順番: Loaded でない鍵の状態を引き直す → 優先順が前に送った物と違えば頼み直す → 予算の内で、優先順に届いた鍵を解く →
    /// 解いた鍵の道の生のバイトを捨てる（まだ解いていない鍵も使う道は残す）。
    /// 予算: Paused は解かない・Idle(ms) は「ここまでの ms + 見込み」が ms に収まる鍵だけ始める
    /// （届いた鍵を estimateResetMs の間 1 本も始めず、見込みが Group#costMs の 2 倍を超えていたら、見込みを Group#costMs へ戻す）・
    /// Covered(ms) は 1 本目は見込みを問わず始め、あとは ms に満たない間続ける。
    /// ここまでの ms は、このコマに機種が絵の登録に使った ms（AssetDownloads#spentMs）と前の step が使った ms（spec#spentMs）から数える。
    pub def step(spec: StepSpec[r, a], pending: BackgroundLoad.Pending): Option[(BackgroundLoad.Pending, List[(String, Result[String, a])])] \ {Fs.FileRead, IO} =
        let unfinished = pending#states |> Map.filter(state -> state != LoadProgress.LoadState.Loaded);
        if (Map.isEmpty(unfinished)) None
        else {
            let nowMs = spec#nowMs();
            let startMs = nowMs - spec#downloads#spentMs() - spec#spentMs;
            let refreshed = unfinished |> Map.mapWithKey((key, before) -> (before, settle(before, arrivalOf(spec#downloads, spec#group#pathsOf, key))));
            let failures = refreshed |> Map.toList |> List.filterMap(entry -> {
                let (key, (before, after)) = entry;
                newFailureOf(before, after) |> Option.map(why -> (key, Err(why)))
            });
            let states = Map.union(Map.map(snd, refreshed), pending#states);
            let wanted = spec#priority();
            let resent = if (wanted == pending#sentPriority) Nil else wanted |> List.filter(key -> isNotArrived(Map.get(key, states)));
            let regressed = regressedKeys(refreshed) |> List.filter(key -> not List.memberOf(key, resent));
            requestPaths(spec#downloads, spec#group#pathsOf, List.append(resent, regressed));
            let sentPriority = wanted;
            let order = distinctInOrder(List.append(wanted, spec#group#keys))
                |> List.filter(key -> Map.get(key, states) == Some(LoadProgress.LoadState.Downloaded));
            let reset = isEstimateResetDue(spec#budget, pending, nowMs, spec#group#costMs) and not List.isEmpty(order);
            let (costMs, decoded) = decodeWithin({ group = spec#group, nowMs = spec#nowMs, budget = spec#budget, startMs = startMs },
                                                 order, if (reset) spec#group#costMs else pending#costMs, Nil);
            let decodedStates = decoded |> List.foldLeft((acc, entry) -> { let (key, result) = entry; Map.insert(key, stateAfterDecode(result), acc) }, states);
            releaseLoaded(spec#downloads, spec#group#pathsOf, decodedStates, decoded);
            let idleSinceMs = nextIdleSince(spec#budget, if (reset) -1.0 else pending#idleSinceMs, nowMs, not List.isEmpty(order) and List.isEmpty(decoded));
            let next = { group = pending#group, states = decodedStates, sentPriority = sentPriority, costMs = costMs, idleSinceMs = idleSinceMs };
            let unchanged = next#states == pending#states and next#sentPriority == pending#sentPriority and List.isEmpty(decoded)
                and next#idleSinceMs == pending#idleSinceMs;
            if (unchanged) None else Some((next, List.append(failures, decoded)))
        }

    /// 前は届いていた（Downloaded）のに、今は Queued・Failed へ戻った鍵（ほかのグループが道の生のバイトを捨てた）。
    // WhyNot: 優先順が変わるまで待たない — 戻った道は誰も頼まず、行列の後ろのまま取られない。
    def regressedKeys(refreshed: Map[String, (LoadProgress.LoadState, LoadProgress.LoadState)]): List[String] =
        refreshed |> Map.toList |> List.filter(entry -> {
            let (_, (before, after)) = entry;
            before == LoadProgress.LoadState.Downloaded and isNotArrived(Some(after))
        }) |> List.map(fst)

    /// Idle の予算で、届いた鍵を始めずに待ってから見込みを Group#costMs へ戻すまでの ms。
    // WhyNot: Idle で見込みを戻さずに待ち続けない — 1 回だけ重かった（GC・初回の JIT）見込みが ms を超えたままだと、Idle では二度と始めず見込みも下がらない。
    // WhyNot: 戻す代わりに 1 本解いて測り直さない — 部屋が Idle に収まらないゲーム（既定の Idle(4)）では、遊んでいる間に一定の間で 1 部屋分止まる。
    pub def estimateResetMs(): Float64 = 2000.0

    /// このコマで、上がりすぎた見込みを初めの値へ戻すか。
    def isEstimateResetDue(budget: LoadProgress.DecodeBudget, pending: BackgroundLoad.Pending, nowMs: Float64, initialMs: Float64): Bool = match budget {
        case LoadProgress.DecodeBudget.Idle(_) =>
            pending#costMs > initialMs * 2.0 and pending#idleSinceMs >= 0.0 and nowMs - pending#idleSinceMs >= estimateResetMs()
        case _ => false
    }

    /// 次の idleSinceMs。skipped = 届いた鍵があるのに 1 本も始めなかった。Idle でなければ待ちを数えない。
    def nextIdleSince(budget: LoadProgress.DecodeBudget, idleSinceMs: Float64, nowMs: Float64, skipped: Bool): Float64 = match budget {
        case LoadProgress.DecodeBudget.Idle(_) if skipped => if (idleSinceMs < 0.0) nowMs else idleSinceMs
        case _                                            => -1.0
    }

    /// decoded のうち解けた鍵の道の生のバイトを捨てる。states でまだ Loaded でない鍵も使う道は残す（同じ絵を貼る部屋）。
    pub def releaseLoaded(downloads: LoadProgress.AssetDownloads, pathsOf: String -> List[String],
                          states: Map[String, LoadProgress.LoadState], decoded: List[(String, Result[String, a])]): Unit \ IO =
        let loaded = decoded |> List.filter(entry -> Result.isOk(snd(entry))) |> List.map(fst);
        if (List.isEmpty(loaded)) ()
        else {
            let stillNeeded = states |> Map.filter(state -> state != LoadProgress.LoadState.Loaded) |> Map.keysOf |> Set.toList
                |> List.flatMap(pathsOf) |> List.toSet;
            let paths = loaded |> List.flatMap(pathsOf) |> List.filter(path -> not Set.memberOf(path, stillNeeded)) |> List.distinct;
            if (List.isEmpty(paths)) () else downloads#release(paths)
        }

    /// 前から見て初めて出た物だけを、並びを保って残す（優先順と既定の順をつないだ時の重なりを落とす）。
    def distinctInOrder(keys: List[String]): List[String] =
        let (_, kept) = List.foldLeft((acc, key) -> {
            let (seen, out) = acc;
            if (Set.memberOf(key, seen)) acc else (Set.insert(key, seen), key :: out)
        }, (Set.empty(), Nil), keys);
        List.reverse(kept)

    /// 前の状態と、道から引き直した状態から、次の状態。Failed は行列へ戻された（Queued・Downloading）時だけ抜ける
    /// （解けずに Failed にした鍵は、道が届いたままなので毎コマ解き直さない）。
    def settle(before: LoadProgress.LoadState, fetched: LoadProgress.LoadState): LoadProgress.LoadState = match (before, fetched) {
        case (LoadProgress.LoadState.Failed(_), LoadProgress.LoadState.Queued)      => fetched
        case (LoadProgress.LoadState.Failed(_), LoadProgress.LoadState.Downloading) => fetched
        case (LoadProgress.LoadState.Failed(_), _)                                  => before
        case _                                                                      => fetched
    }

    /// このコマで初めて Failed になった時だけ、その理由。
    def newFailureOf(before: LoadProgress.LoadState, after: LoadProgress.LoadState): Option[String] = match (before, after) {
        case (LoadProgress.LoadState.Failed(_), _)   => None
        case (_, LoadProgress.LoadState.Failed(why)) => Some(why)
        case _                                       => None
    }

    /// 道がまだ届いていない鍵か（頼み直す相手。Failed は機種が取り直しへ戻せる）。
    def isNotArrived(state: Option[LoadProgress.LoadState]): Bool = match state {
        case Some(LoadProgress.LoadState.Queued)      => true
        case Some(LoadProgress.LoadState.Downloading) => true
        case Some(LoadProgress.LoadState.Failed(_))   => true
        case _                                        => false
    }

    /// keys を前から予算の内で解く。返すのは置き換えた見込みの ms と、解いた鍵の結果（解いた順）。
    def decodeWithin(ctx: { group = BackgroundLoad.Group[r, a], nowMs = Unit -> Float64 \ IO, budget = LoadProgress.DecodeBudget, startMs = Float64 },
                     keys: List[String], costMs: Float64, done: List[(String, Result[String, a])]): (Float64, List[(String, Result[String, a])]) \ {Fs.FileRead, IO} =
        match keys {
            case Nil         => (costMs, List.reverse(done))
            case key :: rest =>
                if (mayStart(ctx#budget, List.isEmpty(done), ctx#nowMs() - ctx#startMs, costMs)) {
                    let before = ctx#nowMs();
                    let result = ctx#group#decode(ctx#group#read(key));
                    let took = ctx#nowMs() - before;
                    decodeWithin(ctx, rest, (costMs + Float64.min(took, sampleCapOf(costMs))) / 2.0, (key, result) :: done)
                } else (costMs, List.reverse(done))
        }

    /// 見込みの平均に入れる 1 回の ms の上限。
    // WhyNot: 測った値をそのまま平均に入れない — 1 回の止まり（GC・初回の JIT）で見込みが跳ね上がり、Idle では長い間何も始めなくなる。
    def sampleCapOf(costMs: Float64): Float64 = Float64.max(costMs * 3.0, 50.0)

    /// 次の鍵を始めてよいか。isFirst = このコマでまだ 1 本も解いていない・elapsed = このコマで使った ms。
    def mayStart(budget: LoadProgress.DecodeBudget, isFirst: Bool, elapsed: Float64, costMs: Float64): Bool = match budget {
        case LoadProgress.DecodeBudget.Paused      => false
        case LoadProgress.DecodeBudget.Idle(ms)    => elapsed + costMs <= ms
        case LoadProgress.DecodeBudget.Covered(ms) => isFirst or elapsed < ms
    }

    /// 鍵の道の状態を 1 つにまとめる。どの道も届いて（Downloaded か Loaded）いれば Downloaded（鍵として解く順番待ち）。
    /// 届いていない道があれば、Failed・Queued・Downloading の順に重い方。道の無い鍵は Downloaded。
    pub def arrivalOf(downloads: LoadProgress.AssetDownloads, pathsOf: String -> List[String], key: String): LoadProgress.LoadState \ IO =
        pathsOf(key) |> List.map(downloads#stateOf) |> List.foldLeft(heavier, LoadProgress.LoadState.Downloaded)

    /// 2 つの道の状態のうち、鍵を待たせる方。
    def heavier(left: LoadProgress.LoadState, right: LoadProgress.LoadState): LoadProgress.LoadState =
        if (weightOf(right) > weightOf(left)) arrivedAsDownloaded(right) else arrivedAsDownloaded(left)

    /// 待たせる重さ（大きいほど重い）。
    def weightOf(state: LoadProgress.LoadState): Int32 = match state {
        case LoadProgress.LoadState.Failed(_)   => 3
        case LoadProgress.LoadState.Queued      => 2
        case LoadProgress.LoadState.Downloading => 1
        case LoadProgress.LoadState.Downloaded  => 0
        case LoadProgress.LoadState.Loaded      => 0
    }

    /// 道の Loaded（絵を登録した・音を解いた）は、鍵としてはまだ解いていないので Downloaded。
    def arrivedAsDownloaded(state: LoadProgress.LoadState): LoadProgress.LoadState = match state {
        case LoadProgress.LoadState.Loaded => LoadProgress.LoadState.Downloaded
        case other                         => other
    }

    /// decode の結果から鍵の状態（解けた = Loaded・解けない = Failed）。
    pub def stateAfterDecode(result: Result[String, a]): LoadProgress.LoadState = match result {
        case Ok(_)    => LoadProgress.LoadState.Loaded
        case Err(why) => LoadProgress.LoadState.Failed(why)
    }

    /// keys の道を並べた順で行列の頭へ頼む（空なら頼まない）。
    pub def requestPaths(downloads: LoadProgress.AssetDownloads, pathsOf: String -> List[String], keys: List[String]): Unit \ IO =
        let paths = List.flatMap(pathsOf, keys);
        if (List.isEmpty(paths)) () else downloads#request(paths)
}
