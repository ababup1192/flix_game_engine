// スパイク（本実装でテンプレートの NovelBeat へ移す。engine には残さない）: サウンドノベルの 1 ビート
// （入力 1 回から次の台詞を読み終えるまで）の出来事を Timeline 1 本に並べ、待ちの判断を表と PlaybackLog だけで決める。
// 実行器は先に引き出さない: 実行器が <<wait>> で止まった所までを並べ、表の終わりに着いたら実行器を Tick して
// 続きを表の後ろへ足す（append だけ）。<<set>> は実行器がその場で書くので、Tick した時に当たる。
// 時刻は全部フレームの番号（30 fps）で比べる。

mod TestTimelineNovelSpike {
    use Timeline.{Duration, ClipState, Playback}

    /// 実行器と命令の表から来る出来事を、待ち方で分けた物（本実装では Commands.Out と Commands.timingOf から作る）。
    /// 押すと明ける待ちは、予定の秒と押して縮めた秒を別々に持つ（記録の秒は予定の秒のまま）。
    enum Item with Eq {
        /// 時間を取らない命令（鳴らす音があれば Some）
        case Instant(String, Option[String])
        /// 時間を取る演出の命令（絵は Stage の時計で動く。後ろを待たせない）
        case Timed(String)
        /// 押しても明けない待ち（テンプレートの命令の Wait）
        case Wait(String, Float64)
        /// 押すと明ける待ち（テンプレートの命令の WaitOrTap）: 予定の秒・縮めた秒
        case WaitOrTap(String, Float64, Option[Float64])
        /// 次の台詞の字を待たせる待ち（テンプレートの命令の LineWait。押すと明ける・後ろの時間を取らない命令は先に流す）:
        /// 予定の秒・縮めた秒・音 (秒, 名前)
        case LineWait(String, Float64, Option[Float64], List[(Float64, String)])
        /// 実行器の <<wait 秒>>（実行器はここで止まる）
        case RunnerWait(Float64)
        /// 素材が届くのを待つ（足した時に届いていない素材がある命令の前にだけ置く）
        case AwaitAssets(List[String])
        /// 台詞: 字・字を出し切る秒
        case Line(String, Float64)
    }

    /// クリップの名前: Apply = 出来事を当てる時刻・Hold = 出来事が出した待ち・Typed = 字を出し切る・Read = 読み終える・Assets = 素材が届く。
    enum Key with Eq, Order, ToString {
        case Apply(Int32)
        case Hold(Int32)
        case Typed(Int32)
        case Read(Int32)
        case Assets(Int32)
    }

    // ── 並べ方 ──

    /// 並べる途中: steps = 書いた行（新しい順）・flowFrom = 時間を取らない命令を寄せている LineWait・
    /// chainStart = 続いた LineWait の最初（台詞を頁に積む時刻。字は待ちが済んでから）。
    type alias Acc = { steps = List[Timeline.Step[Key]], flowFrom = Option[Key], chainStart = Option[Key] }

    def place(acc: Acc, step: Timeline.Step[Key]): Acc = { steps = step :: acc#steps | acc }

    def gated(acc: Acc): Acc = { flowFrom = None, chainStart = None | acc }

    def zeroAt(anchor: Option[Key], tag: Key): Timeline.Step[Key] = match anchor {
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

    def lengthOf(planned: Float64, cut: Option[Float64]): Float64 = Option.getWithDefault(planned, cut)

    /// 出来事 1 つを並べる。LineWait の後ろの時間を取らない命令だけが LineWait の頭へ寄り、ほかは前の待ちが済んでから。
    def stepOf(acc: Acc, pair: (Int32, Item)): Acc =
        let (i, item) = pair;
        match item {
            case Item.Instant(_, sound)      => place(acc, zeroAt(acc#flowFrom, Key.Apply(i)) |> withSoundOf(sound))
            case Item.Timed(_)               => place(gated(acc), Timeline.append(Key.Apply(i), Duration.Seconds(0.0)))
            case Item.Wait(_, secs)          => waitOf(i, secs, acc)
            case Item.WaitOrTap(_, secs, cut) => waitOf(i, lengthOf(secs, cut), acc)
            case Item.LineWait(_, secs, cut, sounds) => lineWaitOf(i, lengthOf(secs, cut), sounds, acc)
            case Item.RunnerWait(secs)       => runnerWaitOf(i, secs, acc)
            case Item.AwaitAssets(_)         => place(gated(acc), Timeline.waitFor(Key.Assets(i)))
            case Item.Line(_, _)             => lineOf(i, acc)
        }

    /// LineWait: 前の待ちが済んでから始め、後ろの時間を取らない命令をこの頭へ寄せる。続いた LineWait は最初の物を覚えておく。
    def lineWaitOf(i: Int32, secs: Float64, sounds: List[(Float64, String)], acc: Acc): Acc =
        let started = place(place(acc, Timeline.append(Key.Apply(i), Duration.Seconds(0.0))),
                            hold(i, secs) |> withSounds(sounds |> List.filter(pair -> fst(pair) <= secs)));
        { flowFrom = Some(Key.Hold(i)), chainStart = Some(Option.getWithDefault(Key.Hold(i), acc#chainStart)) | started }

    /// 待ちを出した命令。LineWait の後ろで流した命令の待ちは LineWait の頭から数えて重なり（明けるのは遅い方）、後ろはどちらも待つ。
    def waitOf(i: Int32, secs: Float64, acc: Acc): Acc = match acc#flowFrom {
        case Some(flow) =>
            let applied = place(acc, Timeline.atStartOf(flow, Key.Apply(i), Duration.Seconds(0.0)));
            gated(place(applied, Timeline.atStartOf(flow, Key.Hold(i), Duration.Seconds(secs))))
        case None =>
            place(place(acc, Timeline.append(Key.Apply(i), Duration.Seconds(0.0))), hold(i, secs))
    }

    /// 実行器の <<wait>>。LineWait の後ろなら LineWait の頭から数えて重なる（古い版の記録: 歩く <<bg genkan>> 5.4 秒の後ろの
    /// <<wait 0.8>> の後の台詞は bg から 5.433 秒 = 歩きの終わりの次のフレーム）。
    def runnerWaitOf(i: Int32, secs: Float64, acc: Acc): Acc = match acc#flowFrom {
        case Some(flow) => gated(place(acc, Timeline.atStartOf(flow, Key.Hold(i), Duration.Seconds(secs))))
        case None       => gated(place(acc, hold(i, secs)))
    }

    /// 台詞: 頁に積む時刻は続いた LineWait の最初の頭（古い版は台詞をすぐ積み、字だけを後へずらした）、
    /// 字を出し始めるのは前の待ちが全部済んでから（Typed）、その後に読み終えるのを待つ（Read）。
    def lineOf(i: Int32, acc: Acc): Acc =
        let shown = place(acc, zeroAt(acc#chainStart, Key.Apply(i)));
        gated(place(place(shown, Timeline.waitFor(Key.Typed(i))), Timeline.waitFor(Key.Read(i))))

    /// ビートの時刻表（毎フレーム組み直す。数十行なら µs）。
    def beatOf(items: List[Item]): Timeline.Timeline[Key] =
        let acc = items |> List.zipWithIndex |> List.foldLeft(stepOf, { steps = Nil, flowFrom = None, chainStart = None });
        Timeline.buildOrPanic("beat", Timeline.noTempo(), List.reverse(acc#steps))

    /// 待ちの名前を書いた順に（Player の passed 番目がいま止まっている待ち）。
    def waitKeysOf(items: List[Item]): List[Key] =
        items |> List.zipWithIndex |> List.flatMap(pair -> {
            let (i, item) = pair;
            match item {
                case Item.Line(_, _)      => Key.Typed(i) :: Key.Read(i) :: Nil
                case Item.AwaitAssets(_)  => Key.Assets(i) :: Nil
                case _                    => Nil
            }
        })

    def isTappable(item: Item): Bool = match item {
        case Item.WaitOrTap(_, _, _)   => true
        case Item.LineWait(_, _, _, _) => true
        case _                         => false
    }

    def isBlockingHold(item: Item): Bool = match item {
        case Item.Wait(_, _)     => true
        case Item.RunnerWait(_)  => true
        case _                   => false
    }

    def isActive(s: ClipState): Bool = match s {
        case ClipState.Active(_) => true
        case _                   => false
    }

    // ── 待ちの判断（reader・ready・送る・オート・送りの印・セーブ・ゲートが読む 1 か所） ──

    enum Waiting with Eq, ToString {
        /// 待ちの途中ではない（演出が流れているだけ）
        case Free
        /// 押しても明けない待ちの途中（押すと明ける待ちと重なっていてもこちら）
        case Blocking
        /// 押すと明ける待ちだけの途中
        case Tappable
        /// 字を出している
        case Typing
        /// 読み終えるのを待っている
        case Input
        /// 素材を待っている
        case AtAssets
    }

    type alias Beat = { items = List[Item], pending = List[List[Item]], log = Timeline.PlaybackLog, reveal = Bool }

    def currentWait(beat: Beat, head: Timeline.Playhead): Option[Key] = List.nth(head#passed, waitKeysOf(beat#items))

    def waitingOf(beat: Beat, wall: Float64, tl: Timeline.Timeline[Key]): Waiting =
        let head = Timeline.playheadOn(wall, beat#log, tl);
        if (Timeline.isWaitingOn(wall, beat#log, tl)) waitKindOf(currentWait(beat, head))
        else {
            let active = beat#items |> List.zipWithIndex |> List.filter(pair -> isActive(Timeline.stateOf(Key.Hold(fst(pair)), head, tl))) |> List.map(snd);
            if (List.isEmpty(active)) Waiting.Free
            else if (List.forAll(isTappable, active)) Waiting.Tappable
            else Waiting.Blocking
        }

    def waitKindOf(key: Option[Key]): Waiting = match key {
        case Some(Key.Typed(_))  => Waiting.Typing
        case Some(Key.Assets(_)) => Waiting.AtAssets
        case _                   => Waiting.Input
    }

    // ── 押した時 ──

    /// 押した: 読み終えを待っていれば解く。字を出していれば出し切る。演出の途中なら、今から次の Read・素材の待ち・
    /// まだ始まっていない押しても明けない待ちまでの押すと明ける待ちを全部、今の時刻で終わる長さに縮め（まだ始まっていない物は 0 秒）、
    /// その先の字も出し切る（古い版も 1 回押すと続くコメントと歩きの終わりと字の全部出しが起きた）。
    // WhyNot: 一番遅い終わりへ seek しない — 歩きと重なって数えている <<wait>> まで一緒に飛ばし、表の時刻も 1 本しか動かせない。
    def tap(beat: Beat, wall: Float64, tl: Timeline.Timeline[Key]): Beat = match waitingOf(beat, wall, tl) {
        case Waiting.Input    => { log = Timeline.resumeOn(wall, beat#log, tl) | beat }
        case Waiting.Typing   => { log = Timeline.resumeOn(wall, beat#log, tl), reveal = true | beat }
        case Waiting.AtAssets => beat
        case _                => { items = shortenedAll(beat, wall, tl), reveal = true | beat }
    }

    def shortenedAll(beat: Beat, wall: Float64, tl: Timeline.Timeline[Key]): List[Item] =
        let t = Timeline.playheadOn(wall, beat#log, tl)#t;
        let stop = stopOf(beat#items, t, tl);
        beat#items |> List.zipWithIndex |> List.map(pair -> {
            let (i, item) = pair;
            Timeline.clipOf(Key.Hold(i), tl)
                |> Option.filter(c -> isTappable(item) and c#start < stop and c#start + c#dur > t)
                |> Option.map(c -> shortened(Float64.max(0.0, t - c#start), item))
                |> Option.getWithDefault(item)
        })

    /// 押して縮めるのをやめる所: 今より後の Read・素材の待ちと、今より後に始まる押しても明けない待ちの一番早い頭。
    def stopOf(items: List[Item], t: Float64, tl: Timeline.Timeline[Key]): Float64 =
        let starts = items |> List.zipWithIndex |> List.flatMap(pair -> {
            let (i, item) = pair;
            let waits = (Key.Read(i) :: Key.Assets(i) :: Nil) |> List.filterMap(key -> Timeline.clipOf(key, tl)) |> List.filter(c -> c#start >= t);
            let holds = if (isBlockingHold(item)) Timeline.clipOf(Key.Hold(i), tl) |> Option.toList |> List.filter(c -> c#start > t) else Nil;
            List.map(c -> c#start, waits ::: holds)
        });
        List.minimum(starts) |> Option.getWithDefault(1.0e9)

    def shortened(secs: Float64, item: Item): Item = match item {
        case Item.WaitOrTap(name, planned, _)        => Item.WaitOrTap(name, planned, Some(secs))
        case Item.LineWait(name, planned, _, sounds) => Item.LineWait(name, planned, Some(secs), sounds)
        case other                                   => other
    }

    // ── 毎フレーム（App の道とテストの道が同じこの関数を通る） ──

    enum Mode with Eq {
        case Manual
        case Auto
        case Skip
    }

    def autoWait(): Float64 = 1.5

    def skipInterval(): Float64 = 0.1

    def itemsById(items: List[Item]): Map[Int32, Item] = items |> List.zipWithIndex |> List.toMap

    def typeSecondsOf(i: Int32, items: Map[Int32, Item]): Float64 = match Map.get(i, items) {
        case Some(Item.Line(_, secs)) => secs
        case _                        => 0.0
    }

    def namesOf(i: Int32, items: Map[Int32, Item]): List[String] = match Map.get(i, items) {
        case Some(Item.AwaitAssets(names)) => names
        case _                             => Nil
    }

    /// 終わりのクリップの頭か終わりで一番遅い所（音は数えない）。
    def clipsEndOf(tl: Timeline.Timeline[Key]): Float64 =
        Timeline.clipsOf(tl) |> List.foldLeft((m, c) -> Float64.max(m, c#start + c#dur), 0.0)

    def isRunnerStopped(items: List[Item]): Bool = match List.last(items) {
        case Some(Item.RunnerWait(_)) => true
        case _                        => false
    }

    /// 1 手だけ進める: 止まっている待ちを解いてよければ解く・スキップなら次の待ちへ飛ぶ・表の終わりに着いて実行器が
    /// <<wait>> で止まっていれば Tick して続きを後ろへ足す。誰が resumeOn するかは設計書の 3.4 の表。
    def advanceOnce(mode: Mode, present: Set[String], wall: Float64, beat: Beat): Beat =
        let tl = beatOf(beat#items);
        let head = Timeline.playheadOn(wall, beat#log, tl);
        if (Timeline.isWaitingOn(wall, beat#log, tl)) resolveWait(mode, present, wall, beat, tl, currentWait(beat, head))
        else if (mode == Mode.Skip and Timeline.skipToNextWait(wall, beat#log, tl) != beat#log) { log = Timeline.skipToNextWait(wall, beat#log, tl) | beat }
        else if (head#t >= clipsEndOf(tl) and isRunnerStopped(beat#items)) tick(beat)
        else beat

    def resolveWait(mode: Mode, present: Set[String], wall: Float64, beat: Beat, tl: Timeline.Timeline[Key], key: Option[Key]): Beat =
        let waited = Timeline.waitedOn(wall, beat#log, tl) |> Option.getWithDefault(0.0);
        let items = itemsById(beat#items);
        let resume = match key {
            case Some(Key.Typed(i))  => beat#reveal or mode == Mode.Skip or waited >= typeSecondsOf(i, items)
            case Some(Key.Read(_))   => (mode == Mode.Auto and waited >= autoWait()) or (mode == Mode.Skip and waited >= skipInterval())
            case Some(Key.Assets(i)) => List.forAll(name -> Set.memberOf(name, present), namesOf(i, items))
            case _                   => false
        };
        if (resume) { log = Timeline.resumeOn(wall, beat#log, tl) | beat } else beat

    /// 実行器を Tick した: 次の <<wait>> か台詞までの出来事を後ろへ足す。
    def tick(beat: Beat): Beat = match beat#pending {
        case next :: rest => { items = beat#items ::: next, pending = rest | beat }
        case Nil          => beat
    }

    def sameBeat(x: Beat, y: Beat): Bool = x#items == y#items and x#log == y#log and x#pending == y#pending and x#reveal == y#reveal

    /// 解ける待ち・飛べる所・Tick が無くなるまで進める（同じフレームの中で続けて起きる）。
    def settle(fuel: Int32, mode: Mode, present: Set[String], wall: Float64, beat: Beat): Beat =
        let next = advanceOnce(mode, present, wall, beat);
        if (fuel <= 0 or sameBeat(next, beat)) beat else settle(fuel - 1, mode, present, wall, next)

    /// ビートを読み終えたか（最後の台詞の Read を解いた）。
    def isFinished(beat: Beat, wall: Float64, tl: Timeline.Timeline[Key]): Bool =
        let waits = List.length(waitKeysOf(beat#items));
        waits > 0 and not isRunnerStopped(beat#items) and Timeline.playheadOn(wall, beat#log, tl)#passed >= waits

    /// フレームで起きた事の名前（台詞を積む・字を出し始める・命令を当てる・<<wait>> の頭・音）。
    def labelOf(items: Map[Int32, Item], key: Key): Option[String] = match key {
        case Key.Apply(i) => Map.get(i, items) |> Option.map(applyLabel)
        case Key.Typed(i) => Map.get(i, items) |> Option.map(item -> "text:${lineText(item)}")
        case Key.Hold(i)  => Map.get(i, items) |> Option.filter(item -> not isTappable(item)) |> Option.map(_ -> "wait")
        case _            => None
    }

    def applyLabel(item: Item): String = match item {
        case Item.Instant(name, _)        => "apply:${name}"
        case Item.Timed(name)             => "apply:${name}"
        case Item.Wait(name, _)           => "apply:${name}"
        case Item.WaitOrTap(name, _, _)   => "apply:${name}"
        case Item.LineWait(name, _, _, _) => "apply:${name}"
        case Item.Line(text, _)           => "line:${text}"
        case _                            => "apply"
    }

    def lineText(item: Item): String = match item {
        case Item.Line(text, _) => text
        case _                  => ""
    }

    def freshBeat(batches: List[List[Item]]): Beat = match batches {
        case first :: rest => { items = first, pending = rest, log = Timeline.playbackLog(), reveal = false }
        case Nil           => { items = Nil, pending = Nil, log = Timeline.playbackLog(), reveal = false }
    }

    /// 流した結果: (フレームの番号, 起きた事) の古い順。
    type alias Script = { mode = Mode, taps = Set[Int32], arrivals = Map[String, Int32], last = Int32 }

    /// ビートの列（ビート = 実行器が止まるごとの出来事の列の列）を、フレームごとに流す。
    def playScript(script: Script, beats: List[List[List[Item]]]): List[(Int32, String)] =
        def go(i: Int32, origin: Int32, beat: Beat, rest: List[List[List[Item]]], heard: List[(Int32, String)]): List[(Int32, String)] = {
            if (i > script#last) heard
            else {
                let (next, out) = frameOf(script, i, origin, beat);
                let tl = beatOf(next#items);
                let wall = Int32.toFloat64(i - origin) / 30.0;
                match rest {
                    case batches :: more if isFinished(next, wall, tl) =>
                        let (opened, first) = frameOf(script, i, i, freshBeat(batches));
                        go(i + 1, i, opened, more, heard ::: out ::: first)
                    case _ => go(i + 1, origin, next, rest, heard ::: out)
                }
            }
        };
        match beats {
            case first :: rest => go(0, 0, freshBeat(first), rest, Nil)
            case Nil           => Nil
        }

    /// 1 フレーム: 押した手を当て、進められるだけ進め、頭を過ぎたクリップと音を出す。
    def frameOf(script: Script, i: Int32, origin: Int32, beat: Beat): (Beat, List[(Int32, String)]) =
        let wall = Int32.toFloat64(i - origin) / 30.0;
        let prev = Int32.toFloat64(i - 1 - origin) / 30.0;
        let playback = if (i == origin) Playback.Enter else Playback.Play;
        let lower = if (i == origin) wall else prev;
        let present = script#arrivals |> Map.filter(at -> at <= i) |> Map.keysOf;
        let tapped = if (Set.memberOf(i, script#taps)) tap(beat, wall, beatOf(beat#items)) else beat;
        let next = settle(32, script#mode, present, wall, tapped);
        let tl = beatOf(next#items);
        let items = itemsById(next#items);
        let started = Timeline.startedOnWall(playback, lower, wall, next#log, tl) |> List.filterMap(key -> labelOf(items, key));
        let sounds = Timeline.soundsOnWall(playback, lower, wall, next#log, tl) |> List.map(name -> "se:${name}");
        (next, List.map(label -> (i, label), started ::: sounds))

    /// ロード・戻る（Silent）: 時計を進めずに、次の Read まで当て直す。素材の待ちで届いていなければそこで止まる
    /// （止まった所から遊ぶ側が暗転して待つ）。返すのは当てた事と、止まった待ち。
    def loadTo(present: Set[String], batches: List[List[Item]]): (List[String], Waiting) =
        let beat = settle(64, Mode.Skip, present, 0.0, freshBeat(batches) |> (b -> { reveal = true | b }));
        let settled = settle(64, Mode.Manual, present, 0.0, beat);
        let tl = beatOf(settled#items);
        let items = itemsById(settled#items);
        let started = Timeline.startedOnWall(Playback.Enter, 0.0, 0.0, settled#log, tl) |> List.filterMap(key -> labelOf(items, key));
        (started, waitingOf(settled, 0.0, tl))

    def frameOfLabel(label: String, heard: List[(Int32, String)]): Int32 =
        heard |> List.find(pair -> snd(pair) == label) |> Option.map(fst) |> Option.getWithDefault(-1)

    def manual(taps: List[Int32]): Script = { mode = Mode.Manual, taps = List.toSet(taps), arrivals = Map.empty(), last = 400 }

    // ── (1) の並び: 歩く bg 5.4 秒 → <<audio>> ×2 → <<wait 0.8>> | <<set>> → 台詞 ──

    def walkThenWait(): List[List[Item]] = List#{
        List#{ Item.LineWait("bg", 5.4, None, List#{ (0.0, "door"), (2.0, "step") }),
               Item.Instant("audio", Some("ambience")), Item.Instant("bgm", Some("bgm")), Item.RunnerWait(0.8) },
        List#{ Item.Instant("set", None), Item.Line("narration", 1.0) }
    }

    @Test
    def testTheSetAfterTheRunnerWaitIsAppliedWhenTheWalkEnds(): Unit \ Assert =
        let heard = playScript(manual(Nil), walkThenWait() :: Nil);
        Assert.assertEq(expected = (0, 162, 162, 162),
            (frameOfLabel("wait", heard), frameOfLabel("apply:set", heard), frameOfLabel("line:narration", heard), frameOfLabel("text:narration", heard)))

    @Test
    def testARunnerWaitLongerThanTheWalkHoldsTheLine(): Unit \ Assert =
        let beats = List#{ List#{ Item.LineWait("bg", 5.4, None, Nil), Item.RunnerWait(6.0) }, List#{ Item.Line("narration", 1.0) } };
        Assert.assertEq(expected = 180, frameOfLabel("text:narration", playScript(manual(Nil), beats :: Nil)))

    @Test
    def testTheWalkSoundsAndTheFlowedAudioPlayAtTheirFrames(): Unit \ Assert =
        let heard = playScript(manual(Nil), walkThenWait() :: Nil) |> List.filter(pair -> String.startsWith(prefix = "se:", snd(pair)));
        Assert.assertEq(expected = List#{ (0, "se:door"), (0, "se:ambience"), (0, "se:bgm"), (60, "se:step") }, heard)

    @Test
    def testTappingDuringTheRunnerWaitEndsTheWalkButKeepsTheWait(): Unit \ Assert =
        let heard = playScript(manual(15 :: Nil), walkThenWait() :: Nil);
        Assert.assertEq(expected = (24, 24, -1), (frameOfLabel("apply:set", heard), frameOfLabel("text:narration", heard), frameOfLabel("se:step", heard)))

    @Test
    def testTappingAfterTheRunnerWaitShowsTheTextAtOnce(): Unit \ Assert =
        Assert.assertEq(expected = 30, frameOfLabel("text:narration", playScript(manual(30 :: Nil), walkThenWait() :: Nil)))

    @Test
    def testTheWaitJudgementFollowsTheWalkAndTheRunnerWait(): Unit \ Assert =
        let beat = freshBeat(walkThenWait());
        let tl = beatOf(beat#items);
        Assert.assertEq(expected = (Waiting.Blocking, Waiting.Tappable), (waitingOf(beat, 0.5, tl), waitingOf(beat, 1.0, tl)))

    @Test
    def testTheTextWaitsForTheWalkButTheLineIsShownAtItsStart(): Unit \ Assert =
        let beats = List#{ List#{ Item.LineWait("bg", 5.4, None, Nil), Item.Line("narration", 1.0) } };
        let heard = playScript(manual(Nil), beats :: Nil);
        Assert.assertEq(expected = (0, 162), (frameOfLabel("line:narration", heard), frameOfLabel("text:narration", heard)))

    // ── コメント（LineWait）が続く所 ──

    def comments(): List[List[Item]] = List#{ List#{
        Item.LineWait("c1", 1.5, None, Nil), Item.Instant("ping", Some("ping")),
        Item.LineWait("c2", 1.5, None, Nil), Item.LineWait("c3", 1.5, None, Nil), Item.Line("next", 1.0) } }

    @Test
    def testCommentsRunInTurnAndTheTextWaitsForTheLast(): Unit \ Assert =
        let heard = playScript(manual(Nil), comments() :: Nil);
        Assert.assertEq(expected = (0, 0, 135), (frameOfLabel("se:ping", heard), frameOfLabel("line:next", heard), frameOfLabel("text:next", heard)))

    @Test
    def testOneTapEndsEveryCommentAndShowsTheText(): Unit \ Assert =
        Assert.assertEq(expected = 15, frameOfLabel("text:next", playScript(manual(15 :: Nil), comments() :: Nil)))

    @Test
    def testAWaitOrTapCommentHoldsTheSoundToo(): Unit \ Assert =
        let beats = List#{ List#{ Item.WaitOrTap("comment", 1.5, None), Item.Instant("ping", Some("ping")), Item.Line("next", 1.0) } };
        Assert.assertEq(expected = 45, frameOfLabel("se:ping", playScript(manual(Nil), beats :: Nil)))

    @Test
    def testTappingTheWalkKeepsAPlainWaitFromAFlowedCommand(): Unit \ Assert =
        let beats = List#{ List#{ Item.LineWait("bg", 5.4, None, Nil), Item.Wait("se", 6.0), Item.Line("next", 1.0) } };
        Assert.assertEq(expected = 180, frameOfLabel("text:next", playScript(manual(30 :: Nil), beats :: Nil)))

    // ── 字を出す・読み終える・次のビート ──

    def twoLines(): List[List[List[Item]]] = List#{
        List#{ List#{ Item.Line("first", 2.0) } },
        List#{ List#{ Item.Instant("set", None), Item.Line("second", 1.0) } }
    }

    @Test
    def testTappingWhileTypingRevealsAndTheNextTapStartsTheNextBeat(): Unit \ Assert =
        let heard = playScript(manual(30 :: 45 :: Nil), twoLines());
        Assert.assertEq(expected = (0, 45, 45), (frameOfLabel("text:first", heard), frameOfLabel("apply:set", heard), frameOfLabel("line:second", heard)))

    @Test
    def testNothingStartsAfterTheReadUntilTheTap(): Unit \ Assert =
        let heard = playScript(manual(200 :: Nil), twoLines());
        Assert.assertEq(expected = 200, frameOfLabel("apply:set", heard))

    @Test
    def testAutoReadsAfterTheTextAndTheAutoWait(): Unit \ Assert =
        // 字を 2 秒（60 フレーム）で出し切り、オートの待ち 1.5 秒（45 フレーム）の後に次のビートへ。
        let heard = playScript({ mode = Mode.Auto | manual(Nil) }, twoLines());
        Assert.assertEq(expected = 105, frameOfLabel("line:second", heard))

    @Test
    def testSkipAppliesEverythingAndDropsTheWalkSounds(): Unit \ Assert =
        let heard = playScript({ mode = Mode.Skip | manual(Nil) }, walkThenWait() :: Nil);
        Assert.assertEq(expected = (0, 0, -1), (frameOfLabel("apply:set", heard), frameOfLabel("text:narration", heard), frameOfLabel("se:step", heard)))

    // ── 素材の待ち・ロード ──

    def withAssets(): List[List[Item]] = List#{ List#{ Item.AwaitAssets(List#{"amb"}), Item.Instant("audio", Some("amb")), Item.Line("next", 1.0) } }

    @Test
    def testTheCommandWaitsUntilItsAssetArrives(): Unit \ Assert =
        let heard = playScript({ arrivals = Map#{ "amb" => 40 } | manual(Nil) }, withAssets() :: Nil);
        Assert.assertEq(expected = (40, 40), (frameOfLabel("apply:audio", heard), frameOfLabel("text:next", heard)))

    @Test
    def testALoadReachesTheReadWithoutTime(): Unit \ Assert =
        Assert.assertEq(expected = (true, Waiting.Input), loadTo(Set.empty(), walkThenWait()) |> (r -> (List.memberOf("apply:set", fst(r)), snd(r))))

    @Test
    def testALoadStopsAtAMissingAsset(): Unit \ Assert =
        Assert.assertEq(expected = (false, Waiting.AtAssets), loadTo(Set.empty(), withAssets()) |> (r -> (List.memberOf("apply:audio", fst(r)), snd(r))))

    @Test
    def testALoadPassesAnAssetThatIsThere(): Unit \ Assert =
        Assert.assertEq(expected = Waiting.Input, snd(loadTo(Set#{"amb"}, withAssets())))
}
