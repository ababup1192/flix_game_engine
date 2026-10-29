// WorldTalk — 会話のウィンドウの規則: ノードを開く・文字送り・送る・選択肢を選ぶ・閉じる・コマンドを World へ当てる（すべて純粋）。
// 台詞の流れは Yarn の実行器（YarnRunner）が決め、ここは実行器が返す出来事をウィンドウの値と World へ写すだけ。
// 1 行の台詞 = 1 枚のウィンドウ。選択肢が続く台詞は、送ると台詞を残したまま選択肢を右上に出す（gallery/quest.png の形）。
//
// 旗の正は World。会話の変数（Talk.SyncedVar）は World → 実行器の一方向に写し、写すのは
// 会話を開く時・入力 1 つを流す前・コマンドを 1 つ当てた後（Talk.fromJson が差し込んだ <<wait 0>> で止まった所）。
// <<shop>> は会話を店のウィンドウへ渡し（FieldWindow.Shop が持つ）、店を閉じるとウィンドウが Talk に戻って tick が続きを流す。
// <<inn>> の暗転の間は、ウィンドウを開いたまま続きを流さない（晴れたら tick が流す）。
mod WorldTalk {
    use fge::{Clock, Dir4, Emit, Log, UiTypewriter, Yarn, YarnRunner, YarnStorage}
    use World.{FieldWindow, TalkRec}

    // ── World → 会話の変数 ──

    /// 会話へ写す World（と Doc）の値。
    def valueOf(res: Res.Res, v: Talk.SyncedVar, w: World.World): Yarn.Value = match v {
        case Talk.SyncedVar.Quest          => Yarn.Value.Text(Quest.nameOf(Progress.rec(w#progress)#quest))
        case Talk.SyncedVar.Gold           => Yarn.Value.Number(Int32.toFloat64(Bag.goldOf(w#bag)))
        case Talk.SyncedVar.InnPrice       => Yarn.Value.Number(Int32.toFloat64(ShopsDoc.rec(res#shops)#innPrice))
        case Talk.SyncedVar.Reward         => Yarn.Value.Number(Int32.toFloat64(RulesDoc.rec(res#rules)#reward))
        case Talk.SyncedVar.Joined(member) => Yarn.Value.Bool(Party.hasJoined(member, w#party))
        case Talk.SyncedVar.Has(item)      => Yarn.Value.Bool(Bag.countOf(item, w#bag) > 0)
    }

    def storageOf(res: Res.Res, w: World.World, storage: YarnStorage.Storage): YarnStorage.Storage =
        Talk.syncedVars(res#items) |> List.foldLeft((acc, v) -> YarnStorage.set(Talk.varNameOf(v), valueOf(res, v, w), acc), storage)

    /// 実行器の変数を今の World の値で書き直す。
    def syncVars(res: Res.Res, w: World.World, t: TalkRec): TalkRec =
        { runner = YarnRunner.withStorage(storageOf(res, w, YarnRunner.storageOf(t#runner)), t#runner) | t }

    /// 実行器の出来事を当てている間の会話。Showing = ウィンドウに出す / Ended = 終わった（閉じる）/
    /// Handed = コマンドが会話を別のウィンドウ（店）へ渡した（ウィンドウはそのウィンドウのまま）。
    enum Flow {
        case Showing(TalkRec)
        case Ended
        case Handed
    }

    def mapShowing(f: TalkRec -> TalkRec, flow: Flow): Flow = match flow {
        case Flow.Showing(t) => Flow.Showing(f(t))
        case _               => flow
    }

    // ── 開く・閉じる ──

    /// node の会話を開く（npc = 話しかけた人の id）。台詞が 1 行も出ずに終わるノードならウィンドウは開かない。
    pub def open(res: Res.Res, node: String, npc: Option[String], w: World.World): World.World =
        if (Option.isEmpty(Yarn.nodeOf(node, res#dialogue)))
            Log.warnThen("[talk] ノード '${node}' が会話（${Talk.dialoguePath()}）に無いので開かない", w)
        else {
            let (runner, events) = YarnRunner.startWith(storageOf(res, w, YarnStorage.empty()), res#dialogue, node, World.now(w));
            let fresh = { runner = runner, line = None, reveal = UiTypewriter.done(""), choices = Nil, cursor = 0, npc = npc };
            absorb(res, events, fresh, w)
        }

    /// 開いている会話（無ければ None）。
    pub def openTalkOf(w: World.World): Option[TalkRec] =
        World.fieldRecOf(w) |> Option.flatMap(r -> match r#window {
            case FieldWindow.Talk(t)      => Some(World.talkRecOf(t))
            case FieldWindow.Closed       => None
            case FieldWindow.Menu(_)      => None
            case FieldWindow.Shop(_, _, _) => None
            case FieldWindow.Notice(_)    => None
        })

    /// 開いている会話があれば f を掛ける（無ければそのまま）。
    def withTalk(f: TalkRec -> World.World \ ef, w: World.World): World.World \ ef =
        match openTalkOf(w) {
            case Some(t) => f(t)
            case None    => w
        }

    /// ウィンドウを talk にする（None なら World.closeWindow で閉じる）。
    def setWindow(talk: Option[TalkRec], w: World.World): World.World = match talk {
        case Some(t) => World.mapField(r -> { window = FieldWindow.Talk(World.wrapTalk(t)) | r }, w)
        case None    => World.mapField(World.closeWindow, w)
    }

    /// 開いている会話を閉じる（会話を読み直した時。読んでいた所は新しい会話に無いかもしれない）。
    /// 店に渡している会話も閉じる（店を閉じた後に戻る所が無くなる）。
    pub def close(w: World.World): World.World =
        if (Option.nonEmpty(openTalkOf(w)) or isShopOpen(w)) setWindow(None, w) else w

    def isShopOpen(w: World.World): Bool =
        World.fieldRecOf(w) |> Option.exists(r -> match r#window {
            case FieldWindow.Shop(_, _, _) => true
            case _                      => false
        })

    // ── 入力と時間 ──

    /// 文字送りを遊びの時計の 1 フレームぶん進め、<<wait>> の時刻が来ていれば続きを流す。
    pub def tick(res: Res.Res, dt: Float64, w: World.World): World.World =
        withTalk(t -> resumeOrShow(res, Flow.Showing({ reveal = UiTypewriter.step({ cps = RulesDoc.rec(res#rules)#cps }, dt, t#reveal) | t }), w), w)

    /// 決定: 出している途中なら出し切る → 選択肢があれば選ぶ → 選択肢が続くなら出す → 次の台詞へ（無ければ閉じる）。
    /// 選択肢を選んだ時は決定の音、台詞を出し切る・送る時は送りの音。
    pub def confirm(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        withTalk(t -> {
            let choosing = UiTypewriter.isDone(t#reveal) and not List.isEmpty(t#choices);
            Emit.emit(if (choosing) World.Event.Confirm else World.Event.TalkNext);
            confirmIn(res, t, w)
        }, w)

    def confirmIn(res: Res.Res, t: TalkRec, w: World.World): World.World =
        if (not UiTypewriter.isDone(t#reveal)) setWindow(Some({ reveal = UiTypewriter.skip(t#reveal) | t }), w)
        else if (not List.isEmpty(t#choices)) stepWith(res, YarnRunner.Action.Choose(t#cursor), t, w)
        else stepWith(res, YarnRunner.Action.Advance, t, w)

    /// 取消: 選択肢を出していれば最後の項目（いいえ）を選ぶ。それ以外は決定と同じ。
    pub def cancel(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match openTalkOf(w) {
            case Some(t) if not List.isEmpty(t#choices) => {
                Emit.emit(World.Event.Cancel);
                stepWith(res, YarnRunner.Action.Choose(List.length(t#choices) - 1), t, w)
            }
            case _ => confirm(res, w)
        }

    /// 選択肢のカーソルを delta だけ動かす（端で回る。選べない項目は飛ばさずに止まって見せる）。
    pub def moveCursor(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        match openTalkOf(w) {
            case Some(t) if List.length(t#choices) > 1 => {
                Emit.emit(World.Event.Cursor);
                setWindow(Some({ cursor = Int32.modulo(t#cursor + delta, List.length(t#choices)) | t }), w)
            }
            case _ => w
        }

    /// 入力 1 つを実行器へ流す（流す前に World の値を写す）。
    def stepWith(res: Res.Res, action: YarnRunner.Action, t: TalkRec, w: World.World): World.World =
        let synced = syncVars(res, w, t);
        let (runner, events) = YarnRunner.step(action, World.now(w), synced#runner);
        absorb(res, events, { runner = runner, choices = Nil | synced }, w)

    // ── 出来事を当てる ──

    /// 実行器の出来事を順にウィンドウの値と World へ当て、<<wait>> の時刻が来ていれば続きを流す。Done で閉じる。
    def absorb(res: Res.Res, events: List[YarnRunner.Event], t: TalkRec, w: World.World): World.World =
        let (flow, after) = events |> List.foldLeft((acc, e) -> applyEvent(res, e, acc), (Flow.Showing(t), w));
        resumeOrShow(res, flow, after)

    /// <<wait>> で止まっていて時刻が来ていれば、World の値を写してから続きを流す（暗転の間は流さない）。それ以外はウィンドウに出す。
    def resumeOrShow(res: Res.Res, flow: Flow, w: World.World): World.World =
        let now = World.now(w);
        match flow {
            case Flow.Showing(t) if isWaitOver(now, t) and not isDark(w) =>
                let synced = syncVars(res, w, t);
                let (runner, events) = YarnRunner.step(YarnRunner.Action.Tick, now, synced#runner);
                absorb(res, events, { runner = runner | synced }, w)
            case Flow.Showing(t) => setWindow(Some(t), w)
            case Flow.Ended      => setWindow(None, w)
            case Flow.Handed     => w
        }

    def isWaitOver(now: Clock.Time[World.Play], t: TalkRec): Bool =
        YarnRunner.waitUntilOf(t#runner) |> Option.exists(until -> Clock.since(until, now) >= 0.0)

    /// 暗転の途中か（<<inn>> の暗転の間は続きを流さない）。
    def isDark(w: World.World): Bool = World.fieldRecOf(w) |> Option.exists(r -> Option.nonEmpty(r#transition))

    def applyEvent(res: Res.Res, e: YarnRunner.Event, acc: (Flow, World.World)): (Flow, World.World) =
        let (flow, w) = acc;
        match e {
            case YarnRunner.Event.Line(line)    => (mapShowing(r -> { line = Some(line), reveal = UiTypewriter.start(line#text), choices = Nil, cursor = 0 | r }, flow), w)
            case YarnRunner.Event.Choices(opts) => (mapShowing(r -> { choices = opts, cursor = 0 | r }, flow), w)
            case YarnRunner.Event.Command(c)    => runCommand(res, c, flow, w)
            case YarnRunner.Event.Done          => (Flow.Ended, w)
        }

    // ── コマンド ──

    /// コマンド 1 つを World へ当てる（wait は実行器が待つので何もしない）。読めないコマンドは 1 行言って飛ばす。
    def runCommand(res: Res.Res, c: Yarn.Command, flow: Flow, w: World.World): (Flow, World.World) =
        if (c#name == "wait") (flow, w)
        else match Talk.commandOf(res#items, res#foes, c) {
            case Ok(command) => applyCommand(res, command, flow, w)
            case Err(reason) => Log.warnThen("[talk] ${reason}。飛ばす", (flow, w))
        }

    def applyCommand(res: Res.Res, command: Talk.Command, flow: Flow, w: World.World): (Flow, World.World) =
        match command {
            case Talk.Command.Quest(to)       => (flow, advanceQuest(res, to, w))
            case Talk.Command.Join(member)    => (flow, join(res, member, w))
            case Talk.Command.Give(item, n)   => (flow, { bag = Bag.give(item, n, w#bag) | w })
            case Talk.Command.Gold(amount)    => (flow, { bag = Bag.addGold(amount, w#bag) | w })
            case Talk.Command.Shop(shop)      => handToShop(shop, flow, w)
            case Talk.Command.Heal            => (flow, { party = Party.restoreAll(res#party, w#party) | w })
            case Talk.Command.Ride            => (Flow.Ended, World.mapField(r -> { stride = World.Stride.Boarding | r }, w))
            case Talk.Command.Inn             => (flow, WorldShop.startInn(res, w))
            case Talk.Command.Fight(foe, node) => (Flow.Ended, World.startEncounter(foe :: Nil, node, w))
            case Talk.Command.Take(item, n)   => (flow, { bag = Bag.give(item, -n, w#bag) | w })
            case Talk.Command.Open(id)        => (flow, World.fieldRecOf(w) |> Option.map(r -> { progress = Progress.markOpened(r#map, id, w#progress) | w })
                                                            |> Option.getWithDefault(w))
            case Talk.Command.Warp(id)        => (Flow.Ended, warp(res, id, w))
            case Talk.Command.Ending          => (Flow.Ended, World.startTransition(World.TransitionThen.Ending, w))
        }

    /// 今のマップの exits の id の行を通って、行き先へ暗転で移る（門は見ない）。出口か行き先のマップが引けなければ、動かずに 1 行言う。
    def warp(res: Res.Res, id: String, w: World.World): World.World =
        let target = forM (
            r <- World.fieldRecOf(w);
            map <- MapDoc.docOf(res#maps, r#map);
            exit <- MapDoc.exitNamed(id, map);
            to <- MapDoc.idOf(res#maps, exit#to)
        ) yield World.TransitionThen.Warp(to, { x = exit#spawnX, y = exit#spawnY }, exit#facing);
        match target {
            case Some(then) => World.startTransition(then, w)
            case None       => Log.warnThen("[talk] <<warp>> の出口 '${id}' が今のマップに無いか、行き先のマップが無いので移らない", w)
        }

    /// 店を開き、会話を店のウィンドウへ渡す（店を閉じると、この会話の続きへ戻る）。会話が出ていなければ何もしない。
    def handToShop(shop: String, flow: Flow, w: World.World): (Flow, World.World) = match flow {
        case Flow.Showing(t) => (Flow.Handed, WorldShop.open(shop, World.wrapTalk(t), w))
        case _               => (flow, w)
    }

    /// 依頼の段階を to へ進め、その段階のお金を払う。前の段階が合わなければ何もしない（2 回流しても 1 回だけ払う）。
    def advanceQuest(res: Res.Res, to: Quest.Quest, w: World.World): World.World =
        Progress.advanceQuest(to, w#progress)
            |> Option.map(p -> { progress = p, bag = Bag.addGold(payOf(res, to), w#bag) | w })
            |> Option.getWithDefault(w)

    def payOf(res: Res.Res, q: Quest.Quest): Int32 = match q {
        case Quest.Quest.NotAsked => 0
        case Quest.Quest.Accepted => RulesDoc.rec(res#rules)#advance
        case Quest.Quest.BossDown => 0
        case Quest.Quest.Reported => RulesDoc.rec(res#rules)#reward
    }

    /// 仲間に加える（加わっていれば何もしない）。いるマップに id が仲間の名前の人が立っていれば、その人のマスから隊列に入る
    /// （先頭の方を向く。話しかけた人でも、イベントのマスで開いた会話でも同じ）。
    def join(res: Res.Res, member: Member.Member, w: World.World): World.World =
        if (Party.hasJoined(member, w#party)) w
        else { party = Party.join(res#party, res#items, member, w#party) | w } |> World.mapField(r -> {
            let standing = forM (
                map <- MapDoc.docOf(res#maps, r#map);
                person <- MapDoc.rec(map)#npcs |> List.find(p -> p#id == Member.idOf(member))
            ) yield ({ x = person#x, y = person#y }, Dir4.opposite(r#facing));
            standing |> Option.map(at -> { trail = List.take(World.trailLength(), at :: r#trail) | r }) |> Option.getWithDefault(r)
        })
}
