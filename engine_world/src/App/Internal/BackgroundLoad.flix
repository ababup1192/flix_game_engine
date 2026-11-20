// App.Internal.BackgroundLoad — 後回しの素材（web.deferred）をループの中で区切って読む step の中身: グループの鍵を予算の内で解く・届いていない名前を World へ写す・コマの予算で step を順に当てる。
// ゲームからは呼ばない（App の中身。ゲームの src・test で App.Internal. を書くと lint が止める）。
pub mod App.Internal.BackgroundLoad {
    import java.lang.System

    /// step 1 回分の書き込み（App.Rec#backgroundSteps の 1 つが返す物）。world = 書いた後の World・
    /// stored = 待ちの表の差し替えと解けた鍵の store を、別の World へもう一度当てる関数（書かなかった step は None）。
    pub type alias StepResult[w] = { world = w, stored = Option[{ keys = List[String], replay = w -> w }] }

    /// stepAll が返す store の記録 1 つ。step = backgroundSteps の何番目か（宣言の順・0 から）・keys = 解けた鍵・
    /// replay = 同じ待ちの表と結果を別の World（押した所の控え）へ当てる関数。
    pub type alias Stored[w] = { step = Int32, keys = List[String], replay = w -> w }

    /// App.withBackgroundLoad に渡す物（欄の意味は App.withBackgroundLoad の doc）。
    pub type alias GroupSpec[w: Type, r: Type, a: Type] = { group = BackgroundLoad.Group[r, a], downloads = LoadProgress.AssetDownloads,
                                                            pendingOf = w -> BackgroundLoad.Pending, withPending = (BackgroundLoad.Pending, w) -> w,
                                                            store = (String, Result[String, a], w) -> w, priority = w -> List[String] }

    /// App.withMissingAssets に渡す物（欄の意味は App.withMissingAssets の doc）。
    pub type alias MissingSpec[w: Type] = { downloads = LoadProgress.AssetDownloads, missingOf = w -> Set[String], withMissing = (Set[String], w) -> w }

    /// step を App の backgroundSteps の末尾へ足す。
    pub def addStep(step: (LoadProgress.DecodeBudget, Float64, w) -> StepResult[w] \ {IO, Fs.FileRead}, app: App.App[w, ef]): App.App[w, ef] =
        let r = App.rec(app);
        App.App.App({ backgroundSteps = List.append(r#backgroundSteps, step :: Nil) | r })

    /// App.withBackgroundLoad の step: 予算をブラウザへ届け、待ちの表を 1 回進め、解けた鍵を store へ渡す。
    pub def groupStep(spec: GroupSpec[w, r, a]): (LoadProgress.DecodeBudget, Float64, w) -> StepResult[w] \ {IO, Fs.FileRead} =
        (budget, spentMs, world) -> {
            spec#downloads#setBudget(budget);
            let stepped = BackgroundLoad.Internal.step({ group = spec#group, downloads = spec#downloads, nowMs = nowMs,
                                                         budget = budget, priority = () -> spec#priority(world), spentMs = spentMs },
                                                       spec#pendingOf(world));
            match stepped {
                case None                  => { world = world, stored = None }
                case Some((next, results)) =>
                    let replay = w -> List.foldLeft((acc, entry) -> { let (key, result) = entry; spec#store(key, result, acc) }, spec#withPending(next, w), results);
                    { world = replay(world), stored = Some({ keys = List.map(fst, results), replay = replay }) }
            }
        }

    /// App.withMissingAssets の step: 予算をブラウザへ届け、届いていない名前の集まりが変わった時だけ書く。
    // WhyNot: 書き替えを store の記録に積まない — 押した所へ戻した次のコマの step が、その時の集まりへ書き直す。
    pub def missingStep(spec: MissingSpec[w]): (LoadProgress.DecodeBudget, Float64, w) -> StepResult[w] \ {IO, Fs.FileRead} =
        (budget, _spentMs, world) -> checked_ecast({
            spec#downloads#setBudget(budget);
            let before = spec#missingOf(world);
            let written = if (Set.isEmpty(before)) world
                          else {
                              let now = spec#downloads#missing();
                              if (now == before) world else spec#withMissing(now, world)
                          };
            { world = written, stored = None }
        })

    /// App.stepBackgroundLoad の中身: 前の step が使った ms を次の step へ渡す。返すのは書いた後の World と、store の記録（step の順）。
    pub def stepAll(r: App.Rec[w, ef], world: w): (w, List[Stored[w]]) \ {IO, Fs.FileRead} =
        if (List.isEmpty(r#backgroundSteps)) (world, Nil)
        else {
            let budget = r#decodeBudget(world);
            let (stepped, _, newestFirst) = List.foldLeft((acc, entry) -> {
                let (w, spentMs, marks) = acc;
                let (index, step) = entry;
                let before = nowMs();
                let result = step(budget, spentMs, w);
                let nextMarks = match result#stored {
                    case None    => marks
                    case Some(s) => { step = index, keys = s#keys, replay = s#replay } :: marks
                };
                (result#world, spentMs + (nowMs() - before), nextMarks)
            }, (world, 0.0, Nil), List.zipWithIndex(r#backgroundSteps));
            (stepped, List.reverse(newestFirst))
        }

    /// 解く時間を測る時刻（ミリ秒・差だけを使う）。
    def nowMs(): Float64 \ IO = Int64.toFloat64(System.nanoTime()) / 1000000.0
}
