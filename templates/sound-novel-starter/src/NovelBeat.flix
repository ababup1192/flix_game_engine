// NovelBeat — 1 ビート（入力 1 回から次の台詞・選択肢を読み終えるのを待つ所まで）の出来事を engine の Timeline 1 本に並べ、
// 「いつ当てるか・今待っているか」を時刻表と PlaybackLog だけで決める（純粋）。待ちの判断はここの waitingOf 1 か所。
// 実行器は先に引き出さない: 実行器が <<wait>> で止まった所までの束を並べ、表の終わりに着いたら WorldRead が実行器を Tick して
// 続きの束を後ろへ足す（表を変えるのは後ろへ足すのと、押すと明ける待ちを今の時刻まで縮めるのだけ。waitFor を途中へ差し込むと
// PlaybackLog の解いた待ちの数がずれる）。
// 置き方: LineWait（次の台詞の字を待たせる待ち）の後ろの命令は、時間を取る命令も含めて LineWait の頭へ寄せる（古い版は束の命令を
// 全部その場で当て、歩きとコメントは台詞の字と実行器の <<wait>> だけを待たせた）。それ以外は前の待ちが全部済んでから。
// <<wait>> と流した命令の待ちは LineWait の頭から数えて重なる（古い版の記録: 歩く背景 5.4 秒の後ろの <<wait 0.8>> の後の台詞は
// 5.4 秒の次のフレーム）。台詞は続いた LineWait の最初の頭で頁に積み、字は待ちが全部済んでから出す（Typed）。
// 設計は engine の plans/novel-waits-timeline.md。
mod NovelBeat {
    use fge::{Sort, Timeline, YarnRunner}
    use fge::Timeline.{Duration, ClipState}

    /// 出来事の待ち方。予定の秒と、押して縮めた秒を別々に持つ（記録の秒は予定の秒のまま）。
    pub enum Kind with Eq, ToString {
        /// 待ちを出さない命令（時間を取る演出の絵は Stage の時計で動く。後ろを待たせない）
        case Command
        /// 押しても明けない待ちを出した命令（予定の秒）
        case Wait(Float64)
        /// 押すと明ける待ちを出した命令（予定の秒・縮めた秒）
        case WaitOrTap(Float64, Option[Float64])
        /// 次の台詞の字を待たせる待ちを出した命令（予定の秒・縮めた秒）
        case LineWait(Float64, Option[Float64])
        /// 実行器の <<wait 秒>>
        case RunnerWait(Float64)
        case Line
        case Choices
        case Done
        /// 束を足すまでに過ぎた秒（素材の待ちの暗転の間など。後ろの束を今から始める）
        case Elapsed(Float64)
    }

    /// 1 つの出来事: 待ち方・実行器の出来事とその後ろの入力の数・束を作った時のブックマーク（台詞の戻れる所の元）・
    /// 束の最初の出来事か（実行器の <<wait>> はここから数える）。
    pub type alias Item = { kind = Kind, event = Option[(YarnRunner.Event, Int32)], last = Option[YarnRunner.Bookmark], first = Bool }

    /// クリップの名前: Apply = 出来事を当てる時刻・Hold = 出来事が出した待ち・Typed = 字を出し切る・Read = 読み終える・Choose = 選ぶ。
    pub enum Key with Eq, Order, ToString {
        case Apply(Int32)
        case Hold(Int32)
        case Typed(Int32)
        case Read(Int32)
        case Choose(Int32)
    }

    /// ビート: items = 足した出来事・log = 解いた待ちと飛んだ所・applied = 当て終えた出来事の番号・reveal = 押して字を出し切る印。
    /// 時刻表は持たず、毎フレーム items から組み直す。時刻は ビートを始めた物語の時刻 origin からの秒（WorldRead が持つ）。
    pub type alias Beat = { items = Vector[Item], log = Timeline.PlaybackLog, applied = Set[Int32], reveal = Bool }

    /// 何も無いビート（ロード・戻るの当て直しの後。読み終えるのを待っている扱い）。
    pub def empty(): Beat = { items = Vector.empty(), log = Timeline.playbackLog(), applied = Set.empty(), reveal = false }

    pub def isEmpty(beat: Beat): Bool = Vector.isEmpty(beat#items)

    // ── 並べ方 ──

    /// 並べる途中: steps = 書いた行（新しい順）・flowFrom = 時間を取らない命令を寄せている LineWait・
    /// chainStart = 続いた LineWait の最初（台詞を頁に積む時刻）・batchStart = 今の束の最初の出来事を当てる時刻。
    type alias Acc = { steps = List[Timeline.Step[Key]], flowFrom = Option[Key], chainStart = Option[Key], batchStart = Option[Key] }

    def place(acc: Acc, step: Timeline.Step[Key]): Acc = { steps = step :: acc#steps | acc }

    def gated(acc: Acc): Acc = { flowFrom = None, chainStart = None | acc }

    def zeroAt(anchor: Option[Key], tag: Key): Timeline.Step[Key] = match anchor {
        case Some(hold) => Timeline.atStartOf(hold, tag, Duration.Seconds(0.0))
        case None       => Timeline.append(tag, Duration.Seconds(0.0))
    }

    def holdAt(anchor: Option[Key], tag: Key, secs: Float64): Timeline.Step[Key] = match anchor {
        case Some(hold) => Timeline.atStartOf(hold, tag, Duration.Seconds(secs))
        case None       => Timeline.append(tag, Duration.Seconds(secs))
    }

    def lengthOf(planned: Float64, cut: Option[Float64]): Float64 = Option.getWithDefault(planned, cut)

    def stepOf(acc0: Acc, pair: (Int32, Item)): Acc =
        let (i, item) = pair;
        let acc = if (item#first) { batchStart = if (hasApply(item#kind)) Some(Key.Apply(i)) else None | acc0 } else acc0;
        match item#kind {
            case Kind.Command                    => place(acc, zeroAt(acc#flowFrom, Key.Apply(i)))
            case Kind.Wait(secs)                 => waitOf(i, secs, acc)
            case Kind.WaitOrTap(secs, cut)       => waitOf(i, lengthOf(secs, cut), acc)
            case Kind.LineWait(secs, cut)        => lineWaitOf(i, lengthOf(secs, cut), acc)
            case Kind.RunnerWait(secs)           => runnerWaitOf(i, secs, acc)
            case Kind.Line                       => lineOf(i, acc)
            case Kind.Choices                    => gated(place(place(gated(acc), Timeline.append(Key.Apply(i), Duration.Seconds(0.0))), Timeline.waitFor(Key.Choose(i))))
            case Kind.Done                       => place(gated(acc), Timeline.append(Key.Apply(i), Duration.Seconds(0.0)))
            case Kind.Elapsed(secs)              => place(gated(acc), Timeline.append(Key.Hold(i), Duration.Seconds(secs)))
        }

    /// 押しても・押すと明ける待ちを出した命令。LineWait の後ろなら LineWait の頭から重なり（明けるのは遅い方）、後ろは流さない。
    def waitOf(i: Int32, secs: Float64, acc: Acc): Acc =
        gated(place(place(acc, zeroAt(acc#flowFrom, Key.Apply(i))), holdAt(acc#flowFrom, Key.Hold(i), secs)))

    /// LineWait: 後ろの時間を取らない命令をこの頭へ寄せる。続いた LineWait は最初の物を台詞の積む時刻に覚えておく。
    def lineWaitOf(i: Int32, secs: Float64, acc: Acc): Acc =
        let started = place(place(acc, zeroAt(acc#flowFrom, Key.Apply(i))), holdAt(acc#flowFrom, Key.Hold(i), secs));
        { flowFrom = Some(Key.Hold(i)), chainStart = Some(Option.getWithDefault(Key.Hold(i), acc#chainStart)) | started }

    /// 実行器の <<wait>>: 実行器が束を返した時刻（束の最初の出来事の頭）から数え、前の待ちと重なる（古い版も実行器が <<wait>> に
    /// 着いた時刻から数えた。記録: 歩く背景 5.4 秒の後ろの <<wait 0.8>> の後の台詞は 5.4 秒の次のフレーム）。記録の wait はこの頭で書く。
    def runnerWaitOf(i: Int32, secs: Float64, acc: Acc): Acc =
        gated(place(place(acc, zeroAt(acc#batchStart, Key.Apply(i))), holdAt(acc#batchStart, Key.Hold(i), secs)))

    /// 束の最初の出来事として、後ろの <<wait>> の数え始めになれるか（<<wait>> 自身と過ぎた秒は自分の頭に置けない）。
    def hasApply(kind: Kind): Bool = match kind {
        case Kind.Elapsed(_)    => false
        case Kind.RunnerWait(_) => false
        case _                  => true
    }

    /// 台詞: 続いた LineWait の最初の頭で頁に積み（古い版も台詞をすぐ積み、字だけを後へずらした）、前の待ちが全部済んでから字を出す。
    def lineOf(i: Int32, acc: Acc): Acc =
        let shown = place(acc, zeroAt(acc#chainStart, Key.Apply(i)));
        gated(place(place(shown, Timeline.waitFor(Key.Typed(i))), Timeline.waitFor(Key.Read(i))))

    /// ビートの時刻表。
    pub def timelineOf(beat: Beat): Timeline.Timeline[Key] =
        let acc = beat#items |> Vector.toList |> List.zipWithIndex |> List.foldLeft(stepOf, { steps = Nil, flowFrom = None, chainStart = None, batchStart = None });
        Timeline.buildOrPanic("beat", Timeline.noTempo(), List.reverse(acc#steps))

    /// 待ちの名前を書いた順に（PlaybackLog の passed 番目がいま止まっている待ち）。
    def waitKeysOf(beat: Beat): List[Key] =
        beat#items |> Vector.toList |> List.zipWithIndex |> List.flatMap(pair -> waitKeysOfItem(fst(pair), snd(pair)#kind))

    def waitKeysOfItem(i: Int32, kind: Kind): List[Key] = match kind {
        case Kind.Line    => Key.Typed(i) :: Key.Read(i) :: Nil
        case Kind.Choices => Key.Choose(i) :: Nil
        case _            => Nil
    }

    def isTappable(kind: Kind): Bool = match kind {
        case Kind.WaitOrTap(_, _) => true
        case Kind.LineWait(_, _)  => true
        case _                       => false
    }

    def isBlockingHold(kind: Kind): Bool = match kind {
        case Kind.Wait(_)       => true
        case Kind.RunnerWait(_) => true
        case Kind.Elapsed(_)    => true
        case _                  => false
    }

    def isActive(s: ClipState): Bool = match s {
        case ClipState.Active(_) => true
        case _                   => false
    }

    // ── 待ちの判断 ──

    /// 今の待ち。Free = 演出が流れているだけ・Blocking = 押しても明けない待ちの途中（押すと明ける待ちと重なっていてもこちら）・
    /// Tappable = 押すと明ける待ちだけの途中・Typing = 字を出している・Input = 読み終えるのを待っている・Choosing = 選ぶのを待っている。
    pub enum Waiting with Eq, ToString {
        case Free
        case Blocking
        case Tappable
        case Typing
        case Input
        case Choosing
    }

    /// 場面の時計の秒 wall（ビートの頭から）での待ち。何も無いビートは読み終えるのを待っている扱い。
    pub def waitingOf(wall: Float64, beat: Beat): Waiting =
        if (isEmpty(beat)) Waiting.Input
        else {
            let tl = timelineOf(beat);
            let head = Timeline.playheadOn(wall, beat#log, tl);
            if (Timeline.isWaitingOn(wall, beat#log, tl)) waitKindOf(List.nth(head#passed, waitKeysOf(beat)))
            else {
                let active = activeHolds(head, beat, tl);
                if (List.isEmpty(active)) Waiting.Free
                else if (List.forAll(isTappable, active)) Waiting.Tappable
                else Waiting.Blocking
            }
        }

    def activeHolds(head: Timeline.Playhead, beat: Beat, tl: Timeline.Timeline[Key]): List[Kind] =
        beat#items |> Vector.toList |> List.zipWithIndex
            |> List.filter(pair -> isActive(Timeline.stateOf(Key.Hold(fst(pair)), head, tl))) |> List.map(pair -> snd(pair)#kind)

    def waitKindOf(key: Option[Key]): Waiting = match key {
        case Some(Key.Typed(_))  => Waiting.Typing
        case Some(Key.Choose(_)) => Waiting.Choosing
        case _                   => Waiting.Input
    }

    /// 待ちの途中か（台詞・選択肢を待っている所でも字を出している所でもない）。flow の reader が押さない間。
    pub def isHolding(w: Waiting): Bool = match w {
        case Waiting.Free     => true
        case Waiting.Blocking => true
        case Waiting.Tappable => true
        case _                => false
    }

    // ── 進める ──

    /// まだ当てていない出来事のうち、wall までに頭を過ぎた物の番号（時刻の順・同じ時刻は書いた順）。
    pub def dueOf(wall: Float64, beat: Beat): List[Int32] =
        if (isEmpty(beat)) Nil
        else {
            let tl = timelineOf(beat);
            let head = Timeline.playheadOn(wall, beat#log, tl);
            beat#items |> Vector.toList |> List.zipWithIndex |> List.map(fst)
                |> List.filter(i -> not Set.memberOf(i, beat#applied))
                |> List.filterMap(i -> Timeline.clipOf(Key.Apply(i), tl) |> Option.filter(c -> Timeline.stateOf(c#tag, head, tl) != ClipState.Before) |> Option.map(c -> ((c#start, i), i)))
                |> Sort.sortStableBy(fst) |> List.map(snd)
        }

    pub def markApplied(i: Int32, beat: Beat): Beat = { applied = Set.insert(i, beat#applied) | beat }

    /// 字を出し切るのを待っていれば解く（typed = 頁を出し切った・スキップ・押して出し切る印）。
    pub def resolveTyped(typed: Bool, wall: Float64, beat: Beat): Beat =
        if (isEmpty(beat) or not (typed or beat#reveal) or waitingOf(wall, beat) != Waiting.Typing) beat
        else { log = Timeline.resumeOn(wall, beat#log, timelineOf(beat)) | beat }

    /// スキップ: 次の待ち（台詞の字・読み終え・選ぶ）まで飛ぶ。飛んだか。
    pub def skipped(wall: Float64, beat: Beat): Beat =
        if (isEmpty(beat)) beat else { log = Timeline.skipToNextWait(wall, beat#log, timelineOf(beat)) | beat }

    /// 表の終わり（クリップの終わりで一番遅い所）に着いていて、当てていない出来事が無いか（実行器を Tick してよいか）。
    // WhyNot: 表の終わりに着いただけで Tick しない — 当てていない出来事（同じフレームで頭を過ぎた物）を残して次の束を引き出すと、
    //   実行器の位置が先へ進んでから前の命令が当たる。実行器が <<wait>> で止まっているかは WorldRead が実行器から見る。
    pub def isAtEnd(wall: Float64, beat: Beat): Bool =
        if (isEmpty(beat)) false
        else {
            let tl = timelineOf(beat);
            let head = Timeline.playheadOn(wall, beat#log, tl);
            let end = Timeline.clipsOf(tl) |> List.foldLeft((m, c) -> Float64.max(m, c#start + c#dur), 0.0);
            head#t >= end and not Timeline.isWaitingOn(wall, beat#log, tl) and Set.size(beat#applied) == Vector.length(beat#items)
        }

    /// 束を後ろへ足す。表の終わりより今が先なら（素材の待ちの間に時計が進んだ）、その秒を先に置いて束を今から始める。
    // WhyNot: 1 ミリ秒より短い差は置かない — 物語の時刻の差の丸め（WorldRead.wallOf）だけで、毎回 0 秒の待ちが挟まる。
    pub def appended(wall: Float64, items: List[Item], beat: Beat): Beat =
        let gap = if (isEmpty(beat)) wall else {
            let tl = timelineOf(beat);
            let end = Timeline.clipsOf(tl) |> List.foldLeft((m, c) -> Float64.max(m, c#start + c#dur), 0.0);
            Timeline.playheadOn(wall, beat#log, tl)#t - end
        };
        let lead = if (gap > 1.0e-3) { kind = Kind.Elapsed(gap), event = None, last = None, first = false } :: Nil else Nil;
        let added = List.toVector(lead ::: items);
        let leadIds = if (List.isEmpty(lead)) Set.empty() else Set#{Vector.length(beat#items)};
        { items = Vector.append(beat#items, added), applied = Set.union(beat#applied, leadIds) | beat }

    /// 押した: 演出の途中なら、今から次の台詞・選択肢か、まだ始まっていない押しても明けない待ちまでの押すと明ける待ちを全部、
    /// 今の時刻で終わる長さに縮め（まだ始まっていない物は 0 秒）、その先の字も出し切る（古い版も 1 回押すと続くコメントと歩きの終わりと
    /// 字の全部出しが起きた）。縮めた待ちがあったか。
    // WhyNot: 一番遅い終わりへ seek しない — 歩きと重なって数えている <<wait>> まで一緒に飛ばし、表の時刻も 1 本しか動かせない。
    pub def tapped(wall: Float64, beat: Beat): (Beat, Bool) =
        let tl = timelineOf(beat);
        let t = Timeline.playheadOn(wall, beat#log, tl)#t;
        let stop = stopOf(t, beat, tl);
        let cut = beat#items |> Vector.toList |> List.zipWithIndex |> List.map(pair -> {
            let (i, item) = pair;
            Timeline.clipOf(Key.Hold(i), tl)
                |> Option.filter(c -> isTappable(item#kind) and c#start < stop and c#start + c#dur > t)
                |> Option.map(c -> { kind = shortened(Float64.max(0.0, t - c#start), item#kind) | item })
                |> Option.getWithDefault(item)
        }) |> List.toVector;
        ({ items = cut, reveal = true | beat }, Vector.map(item -> item#kind, cut) != Vector.map(item -> item#kind, beat#items))

    /// 押して縮めるのをやめる所: 今より後の台詞・選択肢の待ちと、今より後に始まる押しても明けない待ちの一番早い頭。
    def stopOf(t: Float64, beat: Beat, tl: Timeline.Timeline[Key]): Float64 =
        let starts = beat#items |> Vector.toList |> List.zipWithIndex |> List.flatMap(pair -> {
            let (i, item) = pair;
            let waits = (Key.Read(i) :: Key.Choose(i) :: Nil) |> List.filterMap(key -> Timeline.clipOf(key, tl)) |> List.filter(c -> c#start >= t);
            let holds = if (isBlockingHold(item#kind)) Timeline.clipOf(Key.Hold(i), tl) |> Option.toList |> List.filter(c -> c#start > t) else Nil;
            List.map(c -> c#start, waits ::: holds)
        });
        List.minimum(starts) |> Option.getWithDefault(1.0e9)

    def shortened(secs: Float64, kind: Kind): Kind = match kind {
        case Kind.WaitOrTap(planned, _) => Kind.WaitOrTap(planned, Some(secs))
        case Kind.LineWait(planned, _)  => Kind.LineWait(planned, Some(secs))
        case other                               => other
    }

    /// 出来事 i の予定の待ちの秒（記録の秒。待ちを出さない出来事は None）。
    pub def plannedSecondsOf(i: Int32, beat: Beat): Option[Float64] =
        Vector.nth(i, beat#items) |> Option.flatMap(item -> plannedOf(item#kind))

    def plannedOf(kind: Kind): Option[Float64] = match kind {
        case Kind.Wait(secs)         => Some(secs)
        case Kind.WaitOrTap(secs, _) => Some(secs)
        case Kind.LineWait(secs, _)  => Some(secs)
        case Kind.RunnerWait(secs)      => Some(secs)
        case _                          => None
    }
}
