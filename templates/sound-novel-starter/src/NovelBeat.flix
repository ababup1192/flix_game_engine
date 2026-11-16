// NovelBeat — 1 ビート（入力 1 回から次の台詞・選択肢を読み終えるのを待つ所まで）の出来事を engine の Timeline 1 本に並べ、
// 「いつ当てるか・今待っているか」を時刻表と PlaybackLog だけで決める（純粋）。待ちの判断はここの waitingOf 1 か所。
// 表を変えるのは、後ろへ束を足すのと、押すと明ける待ちを今の時刻まで縮めるのだけ（waitFor を途中へ差し込むと、PlaybackLog の
// 解いた待ちの数が別の待ちを指す）。
// 置き方: 続いた LineWait（次の台詞の字を待たせる待ち。コメントなど）は前の LineWait の後ろに並び、その間の命令は、時間を取る命令も
// 含めて最初の LineWait の頭へ寄せる。実行器の <<wait>> は束の最初の出来事の頭から数える。台詞は最初の LineWait の頭で頁に積み、
// 字は待ちが全部済んでから出す（Typed）。
// 時刻表は items から組む（timelineOf）。読む口は組んだ表を受け取るので、呼ぶ側は 1 回りに 1 回だけ組む。
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
        /// 押すと明ける待ちを出した命令（予定の秒・押して縮めた秒）
        case WaitOrTap(Float64, Option[Float64])
        /// 次の台詞の字を待たせる待ちを出した命令（予定の秒・押して縮めた秒）
        case LineWait(Float64, Option[Float64])
        /// 背景を替えた命令が出した LineWait（予定の秒・押して縮めた秒）。続いた LineWait の後ろに並ばず、最初の頭から重なる
        case SwitchWait(Float64, Option[Float64])
        /// 実行器の <<wait 秒>>（予定の秒）
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
    /// 時刻はビートを始めた物語の時刻からの秒（WorldRead が持つ）。
    pub type alias Beat = { items = Vector[Item], log = Timeline.PlaybackLog, applied = Set[Int32], reveal = Bool }

    pub type alias Table = Timeline.Timeline[Key]

    /// 何も無いビート（ロード・戻るの当て直しの後。読み終えるのを待っている扱い）。
    pub def empty(): Beat = { items = Vector.empty(), log = Timeline.playbackLog(), applied = Set.empty(), reveal = false }

    pub def isEmpty(beat: Beat): Bool = Vector.isEmpty(beat#items)

    /// ビートの頭からの物語の秒に足す幅。
    // WhyNot: 物語の時刻の差をそのまま使わない — 頭 2.6 秒と今 3.5 秒の差は 0.8999… になり、実行器が 3.5 秒に明けると決めた
    //   <<wait 0.9>> がビートの上ではまだ明けず、明ける時刻へ据え直して進める所（描き出しの場面）が止まらなくなる。
    pub def wallOf(sinceOrigin: Float64): Float64 = sinceOrigin + 1.0e-6

    // ── 並べ方 ──

    /// 並べる途中: steps = 書いた行（新しい順）・chainStart = 続いた LineWait の最初（後ろの命令を寄せ、台詞を頁に積む時刻）・
    /// lineEnd = 一番新しい LineWait（次の LineWait をこの終わりに並べる）・batchStart = 今の束の最初の出来事を当てる時刻。
    type alias Acc = { steps = List[Timeline.Step[Key]], chainStart = Option[Key], lineEnd = Option[Key], batchStart = Option[Key] }

    def place(acc: Acc, step: Timeline.Step[Key]): Acc = { steps = step :: acc#steps | acc }

    def gated(acc: Acc): Acc = { chainStart = None, lineEnd = None | acc }

    def zeroAt(anchor: Option[Key], tag: Key): Timeline.Step[Key] = match anchor {
        case Some(hold) => Timeline.atStartOf(hold, tag, Duration.Seconds(0.0))
        case None       => Timeline.append(tag, Duration.Seconds(0.0))
    }

    def holdAt(anchor: Option[Key], tag: Key, secs: Float64): Timeline.Step[Key] = match anchor {
        case Some(hold) => Timeline.atStartOf(hold, tag, Duration.Seconds(secs))
        case None       => Timeline.append(tag, Duration.Seconds(secs))
    }

    def stepOf(acc0: Acc, pair: (Int32, Item)): Acc =
        let (i, item) = pair;
        let acc = if (item#first) { batchStart = if (hasApply(item#kind)) Some(Key.Apply(i)) else None | acc0 } else acc0;
        match item#kind {
            case Kind.Command                  => place(acc, zeroAt(acc#chainStart, Key.Apply(i)))
            case Kind.Wait(planned)            => waitOf(i, planned, acc)
            case Kind.WaitOrTap(planned, cut)  => waitOf(i, Option.getWithDefault(planned, cut), acc)
            case Kind.LineWait(planned, cut)   => lineWaitOf(i, Option.getWithDefault(planned, cut), acc)
            case Kind.SwitchWait(planned, cut) => switchWaitOf(i, Option.getWithDefault(planned, cut), acc)
            case Kind.RunnerWait(planned)      => runnerWaitOf(i, planned, acc)
            case Kind.Line                     => lineOf(i, acc)
            case Kind.Choices                  => gated(place(place(gated(acc), Timeline.append(Key.Apply(i), Duration.Seconds(0.0))), Timeline.waitFor(Key.Choose(i))))
            case Kind.Done                     => place(gated(acc), Timeline.append(Key.Apply(i), Duration.Seconds(0.0)))
            case Kind.Elapsed(secs)            => place(gated(acc), Timeline.append(Key.Hold(i), Duration.Seconds(secs)))
        }

    /// 押しても・押すと明ける待ちを出した命令。LineWait の後ろなら最初の LineWait の頭から重なり（明けるのは遅い方）、後ろは流さない。
    def waitOf(i: Int32, secs: Float64, acc: Acc): Acc =
        gated(place(place(acc, zeroAt(acc#chainStart, Key.Apply(i))), holdAt(acc#chainStart, Key.Hold(i), secs)))

    /// LineWait: 前の LineWait（lineEnd）が済んでから始める（続いたコメントは 1 つずつ間を空けて出る。間に挟まった歩きの終わりは待たない）。
    /// 前の LineWait が無ければ前の待ちが全部済んでから。最初の物を、後ろの命令を寄せて台詞を積む時刻に覚える。
    // WhyNot: 続いた LineWait を最初の LineWait の頭へ重ねない — コメントが全部同じ時刻に出て、効果音も 1 回にまとまる。
    def lineWaitOf(i: Int32, secs: Float64, acc: Acc): Acc =
        let after = (tag, length) -> match acc#lineEnd {
            case Some(prev) => Timeline.atEndOf(prev, tag, Duration.Seconds(length))
            case None       => Timeline.append(tag, Duration.Seconds(length))
        };
        let started = place(place(acc, after(Key.Apply(i), 0.0)), after(Key.Hold(i), secs));
        { chainStart = Some(Option.getWithDefault(Key.Hold(i), acc#chainStart)), lineEnd = Some(Key.Hold(i)) | started }

    /// 背景の切り替えの LineWait: 続いた LineWait の最初の頭から重ねて始め、後ろのコメントはこの終わりを待たない
    /// （その前に LineWait が無ければ、自分が最初になり、後ろのコメントはこの後に並ぶ）。
    // WhyNot: コメントの LineWait と同じく後ろに並べない — コメントの後ろの <<jump>> の先の歩きが、コメントの秒だけ遅れて歩き出す。
    def switchWaitOf(i: Int32, secs: Float64, acc: Acc): Acc = match acc#chainStart {
        case Some(_) => place(place(acc, zeroAt(acc#chainStart, Key.Apply(i))), holdAt(acc#chainStart, Key.Hold(i), secs))
        case None    => lineWaitOf(i, secs, acc)
    }

    /// 実行器の <<wait>>: 実行器が束を返した時刻（束の最初の出来事の頭）から数え、前の待ちと重なる。記録の wait はこの頭で書く。
    def runnerWaitOf(i: Int32, secs: Float64, acc: Acc): Acc =
        gated(place(place(acc, zeroAt(acc#batchStart, Key.Apply(i))), holdAt(acc#batchStart, Key.Hold(i), secs)))

    /// 束の最初の出来事として、後ろの <<wait>> の数え始めになれるか（<<wait>> 自身と過ぎた秒は自分の頭に置けない）。
    def hasApply(kind: Kind): Bool = match kind {
        case Kind.Elapsed(_)    => false
        case Kind.RunnerWait(_) => false
        case _                  => true
    }

    /// 台詞: 続いた LineWait の最初の頭で頁に積み、前の待ちが全部済んでから字を出す。
    def lineOf(i: Int32, acc: Acc): Acc =
        let shown = place(acc, zeroAt(acc#chainStart, Key.Apply(i)));
        gated(place(place(shown, Timeline.waitFor(Key.Typed(i))), Timeline.waitFor(Key.Read(i))))

    /// ビートの時刻表。
    pub def timelineOf(beat: Beat): Table =
        let acc = beat#items |> Vector.toList |> List.zipWithIndex |> List.foldLeft(stepOf, { steps = Nil, chainStart = None, lineEnd = None, batchStart = None });
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
        case Kind.WaitOrTap(_, _)  => true
        case Kind.LineWait(_, _)   => true
        case Kind.SwitchWait(_, _) => true
        case _                     => false
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
    pub def waitingOf(wall: Float64, beat: Beat, tl: Table): Waiting =
        if (isEmpty(beat)) Waiting.Input
        else {
            let head = Timeline.playheadOn(wall, beat#log, tl);
            if (Timeline.isWaitingOn(wall, beat#log, tl)) waitKindOf(List.nth(head#passed, waitKeysOf(beat)))
            else {
                let active = activeHolds(head, beat, tl);
                if (List.isEmpty(active)) Waiting.Free
                else if (List.forAll(isTappable, active)) Waiting.Tappable
                else Waiting.Blocking
            }
        }

    def activeHolds(head: Timeline.Playhead, beat: Beat, tl: Table): List[Kind] =
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

    /// もう当てた一番後ろの出来事より前にあって、まだ当てていない出来事の番号。dueOf と同じ順（時刻の順・同じ時刻は書いた順）。
    pub def behindOf(beat: Beat): List[Int32] =
        let tl = timelineOf(beat);
        let top = Set.maximum(beat#applied) |> Option.getWithDefault(-1);
        List.range(0, top) |> List.filter(i -> not Set.memberOf(i, beat#applied))
            |> List.map(i -> ((Timeline.clipOf(Key.Apply(i), tl) |> Option.map(c -> c#start) |> Option.getWithDefault(1.0e9), i), i))
            |> Sort.sortStableBy(fst) |> List.map(snd)

    /// まだ当てていない出来事のうち、wall までに頭を過ぎた物の番号（時刻の順・同じ時刻は書いた順）。
    pub def dueOf(wall: Float64, beat: Beat, tl: Table): List[Int32] =
        let head = Timeline.playheadOn(wall, beat#log, tl);
        beat#items |> Vector.toList |> List.zipWithIndex |> List.map(fst)
            |> List.filter(i -> not Set.memberOf(i, beat#applied))
            |> List.filterMap(i -> Timeline.clipOf(Key.Apply(i), tl) |> Option.filter(c -> Timeline.stateOf(c#tag, head, tl) != ClipState.Before) |> Option.map(c -> ((c#start, i), i)))
            |> Sort.sortStableBy(fst) |> List.map(snd)

    pub def markApplied(i: Int32, beat: Beat): Beat = { applied = Set.insert(i, beat#applied) | beat }

    /// 字を出し切るのを待っていれば解く（typed = 頁を出し切った・スキップ・押して出し切る印）。
    pub def resolveTyped(typed: Bool, wall: Float64, beat: Beat, tl: Table): Beat =
        if (isEmpty(beat) or not (typed or beat#reveal) or waitingOf(wall, beat, tl) != Waiting.Typing) beat
        else { log = Timeline.resumeOn(wall, beat#log, tl) | beat }

    /// スキップ: 次の待ち（台詞の字・読み終え・選ぶ）まで飛んだビート（もう待ちにいれば同じ物）。
    pub def skipped(wall: Float64, beat: Beat, tl: Table): Beat =
        if (isEmpty(beat)) beat else { log = Timeline.skipToNextWait(wall, beat#log, tl) | beat }

    /// 表の終わり（クリップの終わりで一番遅い所）に着いていて、当てていない出来事が無いか（実行器を Tick してよいか）。
    // WhyNot: 表の終わりに着いただけで Tick しない — 当てていない出来事（同じフレームで頭を過ぎた物）を残して次の束を引き出すと、
    //   実行器の位置が先へ進んでから前の命令が当たる。実行器が <<wait>> で止まっているかは WorldRead が実行器から見る。
    pub def isAtEnd(wall: Float64, beat: Beat, tl: Table): Bool =
        if (isEmpty(beat)) false
        else {
            let head = Timeline.playheadOn(wall, beat#log, tl);
            head#t >= endOf(tl) and not Timeline.isWaitingOn(wall, beat#log, tl) and Set.size(beat#applied) == Vector.length(beat#items)
        }

    def endOf(tl: Table): Float64 = Timeline.clipsOf(tl) |> List.foldLeft((m, c) -> Float64.max(m, c#start + c#dur), 0.0)

    /// 束を後ろへ足す。表の終わりより今が先なら（素材の待ちの間に時計が進んだ）、その秒を先に置いて束を今から始める。
    // WhyNot: 1 ミリ秒より短い差は置かない — 物語の時刻の差の丸め（wallOf）だけで、毎回 0 秒の待ちが挟まる。
    pub def appended(wall: Float64, items: List[Item], beat: Beat): Beat =
        let gap = if (isEmpty(beat)) wall else {
            let tl = timelineOf(beat);
            Timeline.playheadOn(wall, beat#log, tl)#t - endOf(tl)
        };
        let lead = if (gap > 1.0e-3) { kind = Kind.Elapsed(gap), event = None, last = None, first = false } :: Nil else Nil;
        let added = List.toVector(lead ::: items);
        let leadIds = if (List.isEmpty(lead)) Set.empty() else Set#{Vector.length(beat#items)};
        { items = Vector.append(beat#items, added), applied = Set.union(beat#applied, leadIds) | beat }

    /// 押した: 今から次の台詞・選択肢か、まだ始まっていない押しても明けない待ちまでの押すと明ける待ちを全部、今の時刻で終わる長さに
    /// 縮め（まだ始まっていない物は 0 秒）、その先の字も出し切る。縮めた待ちが無ければ None（何も替えない）。
    // WhyNot: 一番遅い終わりへ seek しない — 歩きと重なって数えている <<wait>> まで一緒に飛ばし、表の時刻も 1 本しか動かせない。
    pub def tapped(wall: Float64, beat: Beat, tl: Table): Option[Beat] =
        let t = Timeline.playheadOn(wall, beat#log, tl)#t;
        let stop = stopOf(t, beat, tl);
        let cut = beat#items |> Vector.toList |> List.zipWithIndex |> List.map(pair -> {
            let (i, item) = pair;
            Timeline.clipOf(Key.Hold(i), tl)
                |> Option.filter(c -> isTappable(item#kind) and c#start < stop and c#start + c#dur > t)
                |> Option.map(c -> { kind = shortened(Float64.max(0.0, t - c#start), item#kind) | item })
                |> Option.getWithDefault(item)
        }) |> List.toVector;
        if (Vector.map(item -> item#kind, cut) == Vector.map(item -> item#kind, beat#items)) None
        else Some({ items = cut, reveal = true | beat })

    /// 押して縮めるのをやめる所: 今より後の台詞・選択肢の待ちと、今より後に始まる押しても明けない待ちの一番早い頭。
    def stopOf(t: Float64, beat: Beat, tl: Table): Float64 =
        let starts = beat#items |> Vector.toList |> List.zipWithIndex |> List.flatMap(pair -> {
            let (i, item) = pair;
            let waits = (Key.Read(i) :: Key.Choose(i) :: Nil) |> List.filterMap(key -> Timeline.clipOf(key, tl)) |> List.filter(c -> c#start >= t);
            let holds = if (isBlockingHold(item#kind)) Timeline.clipOf(Key.Hold(i), tl) |> Option.toList |> List.filter(c -> c#start > t) else Nil;
            List.map(c -> c#start, waits ::: holds)
        });
        List.minimum(starts) |> Option.getWithDefault(1.0e9)

    def shortened(secs: Float64, kind: Kind): Kind = match kind {
        case Kind.WaitOrTap(planned, _)  => Kind.WaitOrTap(planned, Some(secs))
        case Kind.LineWait(planned, _)   => Kind.LineWait(planned, Some(secs))
        case Kind.SwitchWait(planned, _) => Kind.SwitchWait(planned, Some(secs))
        case other                       => other
    }

    /// 出来事 i の予定の待ちの秒（記録の秒。待ちを出さない出来事は None）。
    pub def plannedSecondsOf(i: Int32, beat: Beat): Option[Float64] =
        Vector.nth(i, beat#items) |> Option.flatMap(item -> plannedOf(item#kind))

    def plannedOf(kind: Kind): Option[Float64] = match kind {
        case Kind.Wait(planned)          => Some(planned)
        case Kind.WaitOrTap(planned, _)  => Some(planned)
        case Kind.LineWait(planned, _)   => Some(planned)
        case Kind.SwitchWait(planned, _) => Some(planned)
        case Kind.RunnerWait(planned)    => Some(planned)
        case _                           => None
    }

    /// 実行器が <<wait>> で止まっている所から始めるビート（当て直しが <<wait>> で止まった時）。secs = 明けるまでの秒。
    pub def runnerWaitBeat(secs: Float64): Beat =
        { items = Vector#{ { kind = Kind.RunnerWait(Float64.max(0.0, secs)), event = None, last = None, first = true } } | empty() }
}
