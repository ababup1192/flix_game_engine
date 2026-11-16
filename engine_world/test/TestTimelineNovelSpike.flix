// スパイク（本実装でテンプレートの NovelBeat へ移す。engine には残さない）: サウンドノベルの 1 ビート
// （入力 1 回から次の台詞まで）の出来事の列を Timeline 1 本にし、待ちの判断を表と Player だけで決める。
// 見るのは 2 つの並び: 歩く背景（5.4 秒・押すと明ける・時間を取らない命令は先に流す）→ <<set>> → <<audio>> ×2 →
// <<wait 0.8>> → 台詞、と、コメントの LineWait（後ろの <<audio se>> と <<jump>> は流れ、台詞だけ待つ）。

mod TestTimelineNovelSpike {
    use Timeline.{Duration, ClipState, Playback}

    /// 実行器と命令の表から来る出来事を、待ち方で分けた物（本実装では Commands.Out と Commands.timingOf から作る）。
    enum Item {
        /// 時間を取らない命令（鳴らす音があれば Some）
        case Instant(String, Option[String])
        /// 時間を取る演出の命令（絵は Stage の時計で動く。後ろを待たせない）
        case Timed(String)
        /// 押しても明けない待ち（テンプレートの命令の Wait）
        case Wait(String, Float64)
        /// 押すと明ける待ち（テンプレートの命令の WaitOrTap）
        case WaitOrTap(String, Float64)
        /// 次の台詞だけを待たせる待ち（テンプレートの命令の LineWait。押すと明ける・後ろの時間を取らない命令は先に流す）。音は (秒, 名前)
        case LineWait(String, Float64, List[(Float64, String)])
        /// 実行器の <<wait 秒>>
        case RunnerWait(Float64)
        /// 台詞
        case Line(String)
    }

    /// 表のクリップの名前: Apply(i) = i 番目の出来事を当てる時刻・Hold(i) = i 番目の出来事が出した待ち・Read = 台詞を読み終えるのを待つ。
    enum Key with Eq, Order, ToString {
        case Apply(Int32)
        case Hold(Int32)
        case Read
    }

    /// 並べる途中: steps = 書いた行（新しい順）・flowFrom = 時間を取らない命令を先に流している LineWait の待ち。
    type alias Acc = { steps = List[Timeline.Step[Key]], flowFrom = Option[Key] }

    def place(acc: Acc, step: Timeline.Step[Key]): Acc = { steps = step :: acc#steps | acc }

    def at(tag: Key, acc: Acc): Timeline.Step[Key] = match acc#flowFrom {
        case Some(hold) => Timeline.atStartOf(hold, tag, Duration.Seconds(0.0))
        case None       => Timeline.append(tag, Duration.Seconds(0.0))
    }

    def withSoundOf(sound: Option[String], s: Timeline.Step[Key]): Timeline.Step[Key] = match sound {
        case Some(name) => Timeline.withSound(name, s)
        case None       => s
    }

    def withSounds(sounds: List[(Float64, String)], s: Timeline.Step[Key]): Timeline.Step[Key] =
        List.foldLeft((cur, pair) -> { let (secs, name) = pair; Timeline.withSoundAt(name, Duration.Seconds(secs), cur) }, s, sounds)

    def hold(i: Int32, secs: Float64): Timeline.Step[Key] = Timeline.append(Key.Hold(i), Duration.Seconds(secs))

    /// 出来事 1 つを並べる。LineWait の後ろの時間を取らない命令だけが LineWait の頭へ寄り、ほかは前の待ちが済んでから。
    def stepOf(acc: Acc, pair: (Int32, Item)): Acc =
        let (i, item) = pair;
        let gated = { flowFrom = None | acc };
        match item {
            case Item.Instant(_, sound)      => place(acc, at(Key.Apply(i), acc) |> withSoundOf(sound))
            case Item.Timed(_)               => place(gated, Timeline.append(Key.Apply(i), Duration.Seconds(0.0)))
            case Item.Wait(_, secs)          => waitOf(i, secs, acc)
            case Item.WaitOrTap(_, secs)     => waitOf(i, secs, acc)
            case Item.LineWait(_, secs, sounds) =>
                let started = place(place(gated, Timeline.append(Key.Apply(i), Duration.Seconds(0.0))), hold(i, secs) |> withSounds(sounds));
                { flowFrom = Some(Key.Hold(i)) | started }
            case Item.RunnerWait(secs)       => place(gated, hold(i, secs))
            case Item.Line(_)                => place(place(gated, Timeline.append(Key.Apply(i), Duration.Seconds(0.0))), Timeline.waitFor(Key.Read))
        }

    /// 待ちを出した命令。LineWait の後ろで流した命令の待ちは LineWait の頭から数えて重なり（明けるのは遅い方）、後ろはどちらも待つ。
    def waitOf(i: Int32, secs: Float64, acc: Acc): Acc = match acc#flowFrom {
        case Some(flow) =>
            let applied = place(acc, Timeline.atStartOf(flow, Key.Apply(i), Duration.Seconds(0.0)));
            { flowFrom = None | place(applied, Timeline.atStartOf(flow, Key.Hold(i), Duration.Seconds(secs))) }
        case None =>
            place(place(acc, Timeline.append(Key.Apply(i), Duration.Seconds(0.0))), hold(i, secs))
    }

    /// 1 ビートの時刻表（毎フレーム組み直す。数十行なら µs）。
    def beatOf(items: List[Item]): Timeline.Timeline[Key] =
        let acc = items |> List.zipWithIndex |> List.foldLeft(stepOf, { steps = Nil, flowFrom = None });
        Timeline.buildOrPanic("beat", Timeline.noTempo(), List.reverse(acc#steps))

    /// 押すと明ける待ちか（Wait は押しても明けない）。
    def isTappable(item: Item): Bool = match item {
        case Item.WaitOrTap(_, _)   => true
        case Item.LineWait(_, _, _) => true
        case _                      => false
    }

    /// 待ちの判断（reader・ready・送る・オートが読む 1 か所）。
    enum Waiting with Eq, ToString {
        /// 待ちの途中ではない（演出が流れているだけ）
        case Free
        /// 押しても明けない待ちの途中
        case Blocking
        /// 押すと明ける待ちの途中
        case Tappable
        /// 台詞を読み終えるのを待っている（押すと次のビートへ）
        case Input
    }

    def waitingOf(items: List[Item], wall: Float64, p: Timeline.Player, tl: Timeline.Timeline[Key]): Waiting =
        let head = Timeline.playheadOn(wall, p, tl);
        let active = items |> List.zipWithIndex |> List.filter(pair -> isActive(Timeline.stateOf(Key.Hold(fst(pair)), head, tl)))
                           |> List.map(snd);
        if (Timeline.isWaitingOn(wall, p, tl)) Waiting.Input
        else if (List.isEmpty(active)) Waiting.Free
        else if (List.forAll(isTappable, active)) Waiting.Tappable
        else Waiting.Blocking

    def isActive(s: ClipState): Bool = match s {
        case ClipState.Active(_) => true
        case _                   => false
    }

    /// 押した: 押すと明ける待ちの途中なら、押した時に途中だった待ちの一番遅い終わりへ 1 回で飛ぶ。
    // WhyNot: 待ちごとに skipToEndOf を続けて当てない — 飛んだ先でちょうど始まる次の待ち（<<wait>>）まで途中に見えて飛ばしてしまう。
    def tap(items: List[Item], wall: Float64, p: Timeline.Player, tl: Timeline.Timeline[Key]): Timeline.Player =
        let ends = Timeline.activeAt(Timeline.playheadOn(wall, p, tl), tl) |> List.map(c -> c#start + c#dur);
        match List.maximum(ends) {
            case Some(end) if waitingOf(items, wall, p, tl) == Waiting.Tappable => Timeline.seekOn(wall, end, p, tl)
            case _                                                             => p
        }

    /// 台詞の出来事の番号（無ければ -1）。
    def lineIndexOf(items: List[Item]): Int32 =
        items |> List.zipWithIndex |> List.find(pair -> isLine(snd(pair))) |> Option.map(fst) |> Option.getWithDefault(-1)

    def isLine(item: Item): Bool = match item {
        case Item.Line(_) => true
        case _            => false
    }

    def isApplied(i: Int32, head: Timeline.Playhead, tl: Timeline.Timeline[Key]): Bool =
        Timeline.stateOf(Key.Apply(i), head, tl) != ClipState.Before

    def dt(): Float64 = 1.0 / 30.0

    /// 1/30 秒ずつ流し、台詞が出た最初のフレームの壁の時刻（taps の秒に押す）と、鳴った音を返す。
    def playBeat(items: List[Item], taps: List[Float64]): (Float64, List[String]) =
        let tl = beatOf(items);
        let line = lineIndexOf(items);
        def go(i: Int32, p: Timeline.Player, heard: List[String]): (Float64, List[String]) = {
            let wall = Int32.toFloat64(i) * dt();
            let pressed = List.exists(t -> Int32.toFloat64(i - 1) * dt() < t and t <= wall, taps);
            let next = if (pressed) tap(items, wall, p, tl) else p;
            let prev = if (i == 0) 0.0 else Int32.toFloat64(i - 1) * dt();
            let sounds = heard ::: Timeline.soundsOnPlayer(if (i == 0) Playback.Enter else Playback.Play, prev, wall, next, tl);
            if (isApplied(line, Timeline.playheadOn(wall, next, tl), tl) or wall > 30.0) (wall, sounds)
            else go(i + 1, next, sounds)
        };
        go(0, Timeline.player(), Nil)

    /// 歩く背景 → <<set>> → <<audio>> ×2 → <<wait 0.8>> → 台詞（移行で台詞が早く出た並び）。
    def walkThenWait(): List[Item] = List#{
        Item.LineWait("bg", 5.4, List#{ (0.0, "door"), (2.0, "step") }),
        Item.Instant("set", None),
        Item.Instant("audio", Some("ambience")),
        Item.Instant("audio", Some("bgm")),
        Item.RunnerWait(0.8),
        Item.Line("narration")
    }

    def within(t: Float64, expected: Float64): Bool = t >= expected - 1.0e-9 and t < expected + dt()

    @Test
    def testTheLineWaitsForTheWalkAndThenTheRunnerWait(): Unit \ Assert =
        Assert.assertEq(expected = true, within(fst(playBeat(walkThenWait(), Nil)), 5.4 + 0.8))

    @Test
    def testTheAudioAfterTheWalkFlowsAtTheStartOfTheWalk(): Unit \ Assert =
        let tl = beatOf(walkThenWait());
        Assert.assertEq(expected = (0.0, 0.0), (Timeline.clipOf(Key.Apply(2), tl) |> Option.map(c -> c#start) |> Option.getWithDefault(-1.0),
                                                Timeline.clipOf(Key.Apply(3), tl) |> Option.map(c -> c#start) |> Option.getWithDefault(-1.0)))

    @Test
    def testTheWalkSoundsAndTheFlowedAudioPlayInOrder(): Unit \ Assert =
        Assert.assertEq(expected = List#{"door", "ambience", "bgm", "step"}, snd(playBeat(walkThenWait(), Nil)))

    @Test
    def testTappingDuringTheWalkEndsItAndKeepsTheRunnerWait(): Unit \ Assert =
        Assert.assertEq(expected = true, within(fst(playBeat(walkThenWait(), List#{0.99})), 1.0 + 0.8))

    @Test
    def testTappingDuringTheWalkDropsItsLaterSounds(): Unit \ Assert =
        Assert.assertEq(expected = List#{"door", "ambience", "bgm"}, snd(playBeat(walkThenWait(), List#{0.99})))

    @Test
    def testTheRunnerWaitIsBlockingAndTheWalkIsTappable(): Unit \ Assert =
        let items = walkThenWait();
        let tl = beatOf(items);
        let p = Timeline.player();
        Assert.assertEq(expected = (Waiting.Tappable, Waiting.Blocking, Waiting.Input),
            (waitingOf(items, 1.0, p, tl), waitingOf(items, 5.8, p, tl), waitingOf(items, 6.3, p, tl)))

    @Test
    def testTappingDuringTheRunnerWaitDoesNothing(): Unit \ Assert =
        Assert.assertEq(expected = true, within(fst(playBeat(walkThenWait(), List#{5.59})), 5.4 + 0.8))

    // ── コメントの LineWait: 後ろの <<audio se>> と <<jump>> は流れ、台詞だけ待つ ──

    def commentThenLine(): List[Item] = List#{
        Item.LineWait("comment", 1.5, Nil),
        Item.Instant("audio", Some("ping")),
        Item.Instant("jump", None),
        Item.Line("next")
    }

    @Test
    def testTheLineWaitsForTheComment(): Unit \ Assert =
        Assert.assertEq(expected = true, within(fst(playBeat(commentThenLine(), Nil)), 1.5))

    @Test
    def testTheSoundAfterTheCommentFlowsAtOnce(): Unit \ Assert =
        let tl = beatOf(commentThenLine());
        Assert.assertEq(expected = List#{"ping"}, Timeline.soundsOnPlayer(Playback.Enter, 0.0, 0.0, Timeline.player(), tl))

    @Test
    def testAWaitOrTapCommentHoldsTheSoundToo(): Unit \ Assert =
        let items = List#{ Item.WaitOrTap("comment", 1.5), Item.Instant("audio", Some("ping")), Item.Line("next") };
        let tl = beatOf(items);
        Assert.assertEq(expected = Some(1.5), Timeline.clipOf(Key.Apply(1), tl) |> Option.map(c -> c#start))

    @Test
    def testAPlainWaitFromAFlowedCommandMakesTheWalkUntappable(): Unit \ Assert =
        let items = List#{ Item.LineWait("bg", 5.4, Nil), Item.Wait("audio", 6.0), Item.Line("next") };
        let tl = beatOf(items);
        Assert.assertEq(expected = Waiting.Blocking, waitingOf(items, 1.0, Timeline.player(), tl))
}
