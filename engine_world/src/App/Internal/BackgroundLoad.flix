// App.Internal.BackgroundLoad — 後回しの素材（web.deferred）をループの中で区切って読む step の中身: グループの鍵を予算の内で解く・届いていない名前を World へ写す・コマの予算で step を順に当てる。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.BackgroundLoad {
    import java.lang.System

    /// App.withBackgroundLoad の step: 予算をブラウザへ届け、待ちの表を 1 回進め、解けた鍵を store へ渡す。
    pub def groupStep(spec: { group = BackgroundLoad.Group[r, a],
                              downloads = LoadProgress.AssetDownloads,
                              pendingOf = w -> BackgroundLoad.Pending,
                              withPending = (BackgroundLoad.Pending, w) -> w,
                              store = (String, Result[String, a], w) -> w,
                              priority = w -> List[String] }): (LoadProgress.DecodeBudget, Float64, w) -> w \ {IO, Fs.FileRead} =
        (budget, spentMs, world) -> {
            spec#downloads#setBudget(budget);
            let stepped = BackgroundLoad.Internal.step({ group = spec#group, downloads = spec#downloads, nowMs = nowMs,
                                                         budget = budget, priority = () -> spec#priority(world), spentMs = spentMs },
                                                       spec#pendingOf(world));
            match stepped {
                case None                  => world
                case Some((next, results)) =>
                    List.foldLeft((acc, entry) -> { let (key, result) = entry; spec#store(key, result, acc) }, spec#withPending(next, world), results)
            }
        }

    /// App.withMissingAssets の step: 予算をブラウザへ届け、届いていない名前の集まりが変わった時だけ書く。
    pub def missingStep(spec: { downloads = LoadProgress.AssetDownloads,
                                missingOf = w -> Set[String],
                                withMissing = (Set[String], w) -> w }): (LoadProgress.DecodeBudget, Float64, w) -> w \ {IO, Fs.FileRead} =
        (budget, _spentMs, world) -> checked_ecast({
            spec#downloads#setBudget(budget);
            let before = spec#missingOf(world);
            if (Set.isEmpty(before)) world
            else {
                let now = spec#downloads#missing();
                if (now == before) world else spec#withMissing(now, world)
            }
        })

    /// App.stepBackgroundLoad の中身: 前の step が使った ms を次の step へ渡す。
    pub def stepAll(r: App.Rec[w, ef], world: w): w \ {IO, Fs.FileRead} =
        if (List.isEmpty(r#backgroundSteps)) world
        else {
            let budget = r#decodeBudget(world);
            let (stepped, _) = List.foldLeft((acc, step) -> {
                let (w, spentMs) = acc;
                let before = nowMs();
                let next = step(budget, spentMs, w);
                (next, spentMs + (nowMs() - before))
            }, (world, 0.0), r#backgroundSteps);
            stepped
        }

    /// 解く時間を測る時刻（ミリ秒・差だけを使う）。
    def nowMs(): Float64 \ IO = Int64.toFloat64(System.nanoTime()) / 1000000.0
}
