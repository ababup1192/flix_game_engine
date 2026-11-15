// WorldRead — 読み進める規則（純粋）: はじめから読む・送る・選ぶ・文字送り・オートとスキップ・戻れる所へ戻す。
// 文章・分岐・結末はシナリオ assets/talk/natsukusa.yarn（YarnRunner が辿る）、演出のコマンドの表は Commands、舞台は Stage、頁は Page。
// ここの関数は、場面が Reading の時だけ読んでいる値 Read を取り出して動く（ほかの場面では何もしない）。
//
// 戻れる所（Saves.Mark）は 3 か所が同じ物を持つ: セーブデータ・バックログの行・「戻る」。戻し方は restore 1 つで、
// ブックマークを当て直してバックログと選択肢を作り、舞台と頁は最後に Mark の値（その台詞を出した時の形）で置き換える。
// ノードの頭から開く所（openAt）は、opening から流してそのノードに最初に着いた時の舞台（entryOf）から始める。
//
// オートとスキップは同じ所（autoOrSkip）で決める: 行を出し終えた時刻 doneAt から、オートは「設定の待ち + 字数 × autoPerChar」、
// スキップは skipInterval ごとに送る。スキップは設定で「既読のみ」なら読んでいない行で止まり、選択肢で止まるかも設定で選ぶ。
//
// ブラウザ版で後回しにした背景・環境音が使う時にまだ届いていなければ、暗転して待つ（下の「素材の待ち」の節）。
mod WorldRead {
    use fge::{Clock, Emit, Log, Yarn, YarnRunner, YarnStorage}
    use Commands.Out

    /// シナリオの出来事を反映する時に、音とオートセーブを出すか。
    /// Live = 人が読み進めている時、Silent = ロード・戻る・プレビューの当て直し（音もオートセーブも出さず、行は出し終えた形）。
    type alias Replay = Commands.Replay

    /// 読んでいる間だけ f(読んでいる値) を通す（ほかの場面ではそのまま）。
    def whileReading(f: World.Read -> World.World \ ef, w: World.World): World.World \ ef =
        match World.readOf(w) {
            case Some(r) => f(r)
            case None    => w
        }

    // ── はじめから ──

    /// はじめから読む。[遷移: Title→Reading]
    pub def newGame(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Opened);
        let opened = { panel = World.Panel.Closed, ask = None | w };
        let first = StoryDoc.openingOf(res#story);
        match Yarn.nodeOf(first, res#dialogue) {
            case Some(_) =>
                let (talk, events) = YarnRunner.start(res#dialogue, first, World.now(w));
                absorb(res, Commands.Replay.Live, events, { talk = talk | World.emptyRead() }, opened)
            case None =>
                showLine(res, Commands.Replay.Live, None, { speaker = "", text = "（シナリオが読めない。assets/talk/natsukusa.yarn を直して bin/fge yarn build assets/talk を流すと、ここに物語が流れる）",
                                             parts = Nil, tags = Nil, source = { file = "", line = 0 } }, World.emptyRead(), opened)
        }

    // ── シナリオの出来事を反映する ──

    /// 実行器が返した出来事を順に反映する。r は反映を始める読んでいる値（新しいシナリオの位置 talk を入れた物）。
    /// 台詞ごとの戻れる所は、最後のブックマークから「その台詞より後に受けた入力」の数だけ入力を外した物（inputsAfter と markAt）。
    /// [遷移: シナリオが終わる(Done) → Credits]
    def absorb(res: Res.Res, replay: Replay, events: List[YarnRunner.Event], r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        absorbFrom(res, replay, YarnRunner.bookmarkOf(r#talk), List.zip(events, inputsAfter(events)), World.withRead(r, w))

    /// 出来事を頭から 1 つずつ反映する。人が読み進めている時（Live）に、まだ届いていない背景・環境音へ切り替えるコマンドに
    /// 当たったら、そこから先を素材の待ち（Hold）に預けて止まる（届いたら resumeHold が続きから反映する）。
    def absorbFrom(res: Res.Res, replay: Replay, last: Option[YarnRunner.Bookmark], pairs: List[(YarnRunner.Event, Int32)],
                   w: World.World): World.World \ Emit[World.Event] =
        match pairs {
            case Nil => w
            case (event, later) :: rest =>
                let waitFor = if (replay == Commands.Replay.Live) namesToWait(res, pairs, w) else Nil;
                if (not List.isEmpty(waitFor)) startHold(waitFor, pairs, last, w)
                else absorbFrom(res, replay, last, rest, absorbOne(res, replay, last, event, later, w))
        }

    /// 出来事 1 つ。later = その出来事より後ろに出た台詞と選択肢の数。
    def absorbOne(res: Res.Res, replay: Replay, last: Option[YarnRunner.Bookmark], event: YarnRunner.Event, later: Int32,
                  w: World.World): World.World \ Emit[World.Event] =
        match event {
            case YarnRunner.Event.Line(said)       =>
                let line = ScriptEdits.editLine(res#scriptEdits, said);
                whileReading(cur -> showLine(res, replay, bookmarkAt(last, later), line, { cursor = Some(line#source) | cur }, w), w)
            case YarnRunner.Event.Choices(offered) =>
                let options = offered |> List.map(option -> { line = ScriptEdits.editLine(res#scriptEdits, option#line) | option });
                let at = List.head(options) |> Option.map(option -> option#line#source);
                World.mapRead(cur -> { choices = options, choiceCursor = firstOpen(options), cursor = if (Option.isEmpty(at)) cur#cursor else at,
                                       stage = Stage.withWindowShown(World.now(w), cur#stage) | cur }, w)
            case YarnRunner.Event.Command(command) =>
                whileReading(cur -> World.withRead(cue(res, replay, command, { cursor = cursorAfter(res, command, cur#cursor) | cur }, w), w), w)
            case YarnRunner.Event.Done             => World.toCredits(res, w)
        }

    /// コマンドを通った後の実行位置。時間を取る演出コマンド（表の timing が Timed）だけが位置を取り、<<wait>> と
    /// 時間を取らないコマンドは前の位置のまま（<<wait>> は直前の演出の続き）。
    def cursorAfter(res: Res.Res, command: Yarn.Command, cursor: Option[Yarn.Source]): Option[Yarn.Source] =
        if (Commands.timingOf(res, command) == Commands.Timing.Timed) Some(command#source) else cursor

    /// 出来事ごとに、それより後ろに出た台詞と選択肢の数（= その所から今までに受けた入力の数）。
    /// 台詞は送る 1 回、選択肢は選ぶ 1 回で次へ進むので、後ろに出た台詞と選択肢の数がそのまま入力の数になる。
    ///
    /// 例: 出来事が [台詞 A, <<bg>>, 台詞 B, 選択肢 C, 台詞 D] なら、後ろから数えて
    ///       台詞 D → 0（後ろに何も無い）
    ///       選択肢 C → 1（D）
    ///       台詞 B → 2（C と D）
    ///       <<bg>> → 3（B・C・D。コマンドは入力を受けないので数えない）
    ///       台詞 A → 3
    ///     となり、[3, 3, 2, 1, 0] を返す。台詞 B へ戻るには、今のブックマークから入力を 2 つ外せばよい（markAt）。
    def inputsAfter(events: List[YarnRunner.Event]): List[Int32] =
        let isInput = event -> match event {
            case YarnRunner.Event.Line(_)    => 1
            case YarnRunner.Event.Choices(_) => 1
            case _                           => 0
        };
        // 後ろから 1 つずつ見て、(ここまでの答え, 後ろの入力の数) を持ち回る。
        fst(List.foldRight((event, acc) -> {
            let (counts, n) = acc;
            (n :: counts, n + isInput(event))
        }, (Nil, 0), events))

    /// 最後のブックマークから入力を later 個外した所。
    /// ブックマークの steps は「ノードの頭から受けた入力」の列なので、後ろの later 個を外すとその台詞を出した所に戻る。
    def bookmarkAt(last: Option[YarnRunner.Bookmark], later: Int32): Option[YarnRunner.Bookmark] =
        last |> Option.map(b -> { steps = List.take(Int32.max(0, List.length(b#steps) - later), b#steps) | b })

    /// bookmark と、今の舞台と頁（文字送りは出し終えた形）で作る戻れる所。
    def markOf(bookmark: YarnRunner.Bookmark, r: World.Read): Saves.Mark =
        { bookmark = bookmark, stage = Stage.snapshotOf(r#stage), page = Some(Page.revealAll(r#page)) }

    /// コマンド 1 つ（wait は実行器が待つので何もしない）。表で読んで舞台に当て、出た出来事を頁と音にする。
    /// 読めないコマンドは 1 行知らせて舞台はそのまま。
    def cue(res: Res.Res, replay: Replay, command: Yarn.Command, r: World.Read, w: World.World): World.Read \ Emit[World.Event] =
        if (command#name == "wait") r
        else match Commands.execute(replay, ctxOf(res, r, w), command, r#stage) {
            case Ok((stage, outs)) => outs |> List.foldLeft((cur, out) -> takeOut(out, cur), { stage = stage | r })
            case Err(message)      => Log.warnThen("[stage] ${message}", r)
        }

    /// コマンドの表の apply が読む物。
    def ctxOf(res: Res.Res, r: World.Read, w: World.World): Commands.Ctx =
        { now = World.now(w), node = YarnRunner.nodeOf(r#talk) |> Option.getWithDefault(""), res = res }

    /// コマンドが出した出来事 1 つ（Silent の時の音と合図は Commands.execute が落としてある）。
    def takeOut(out: Out, r: World.Read): World.Read \ Emit[World.Event] = match out {
        case Out.ClearPage   => { page = Page.clear(r#page), stage = Stage.withPageTurned(r#stage) | r }
        case Out.TurnPage    => { page = Page.turn(r#page) | r }
        case Out.Sound(name) => Emit.emit(World.Event.Cue(name)); r
        case Out.Event(name) => Emit.emit(World.Event.Signal(name)); r
    }

    /// 台詞 1 行を頁とバックログへ。NVL で頁に入り切らない時は頁をめくって（めくった数を足して）から積む。消していた文字の枠は出す。
    /// 戻れる所は行を積んだ後の舞台と頁で作る。新しいノードの最初の行ならオートセーブ。
    def showLine(res: Res.Res, replay: Replay, bookmark: Option[YarnRunner.Bookmark], line: Yarn.Line, r: World.Read, w: World.World): World.World =
        let entry = Page.lineOf(StoryDoc.nameOf(line#speaker, res#story), line);
        let fits = fitsNvl(res);
        let shownStage = Stage.withWindowShown(World.now(w), r#stage);
        let stage = if (Page.turnsOver(shownStage#mode, fits, entry, r#page)) Stage.withPageTurned(shownStage) else shownStage;
        let page = Page.show(stage#mode, fits, entry, r#page);
        let placed = { stage = stage, page = if (replay == Commands.Replay.Silent) Page.revealAll(page) else page | r };
        let mark = bookmark |> Option.map(b -> markOf(b, placed));
        let shown = { choices = Nil, doneAt = None, log = List.take(KindDoc.rec(res#kind)#logMax, World.Entry.Said(entry, mark) :: r#log) | placed };
        if (replay == Commands.Replay.Silent) World.withRead(shown, w) else autosave(res, mark, shown, w)

    /// NVL の頁に行の列が入り切るか（行の数は novel.kind.json の nvlRows）。
    def fitsNvl(res: Res.Res): List[Page.Line] -> Bool = lines ->
        let k = KindDoc.rec(res#kind);
        let rows = lines |> List.foldLeft((sum, line) -> sum + Page.rowsOf(k#bodySize, k#rubySize, Layout.nvlText()#width, line), 0);
        rows <= k#nvlRows

    def firstOpen(options: List[YarnRunner.DialogueOption]): Int32 =
        options |> List.zipWithIndex |> List.find(match (_, option) -> option#available)
                |> Option.map(fst) |> Option.getWithDefault(0)

    // ── 読み進める ──

    /// 決定 1 回分（読んでいる間・画面が閉じている時）。文字送りの途中なら全文へ、出し終えていれば次の行へ。
    /// 選択肢を出している間は動かない（pick だけが進める）。オートとスキップは止める（人が押したら人の速さに戻す）。
    pub def advance(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match World.readOf(w) {
            case Some(r) if World.isFree(w) and List.isEmpty(r#choices) and Option.isEmpty(r#hold) =>
                let manual = { playback = World.Playback.Manual | r };
                if (not Page.isDone(r#page)) {
                    Emit.emit(World.Event.Revealed);
                    World.withRead({ page = Page.revealAll(r#page) | manual }, w)
                } else next(res, manual, w)
            case _ => w
        }

    /// 今の行を既読にして、次の行へ送る。[遷移: 行→次の行 / 選択肢 / シナリオの終わり(Credits)]
    def next(res: Res.Res, r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let marked = markSeen(r, w);
        match YarnRunner.shownOf(r#talk) {
            case YarnRunner.Shown.Line(_) =>
                Emit.emit(World.Event.Paged);
                let (talk, events) = YarnRunner.step(YarnRunner.Action.Advance, World.now(marked), r#talk);
                absorb(res, Commands.Replay.Live, events, { talk = talk | r }, marked)
            case YarnRunner.Shown.Closed => World.toCredits(res, World.withRead(r, marked))
            case _                       => World.withRead(r, marked)
        }

    /// 今の行を既読の印へ（初めて読んだ行の時だけ saves を変える = 書く）。
    def markSeen(r: World.Read, w: World.World): World.World =
        match r#page#current {
            case Some(line) if not String.isEmpty(line#source) and not Saves.isSeen(line#source, w#saves) =>
                World.withSaves(Saves.withSeen(line#source, w#saves), w)
            case _ => w
        }

    /// スキップが今の行を飛ばしてよいか（既読か、設定が「未読も」）。
    def isSkippable(r: World.Read, w: World.World): Bool =
        let seen = r#page#current |> Option.exists(line -> Saves.isSeen(line#source, w#saves));
        seen or World.configOf(w)#skipScope == Saves.SkipScope.Everything

    /// 選択肢 i を選ぶ。選べない選択肢（行末の <<if>> が偽）の番号なら何もしない。[遷移: 選択肢→選んだ中身]
    pub def pick(res: Res.Res, i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.readOf(w) {
            case Some(r) if World.isFree(w) and Option.isEmpty(r#hold) =>
                match List.nth(i, r#choices) {
                    case Some(option) if option#available =>
                        Emit.emit(World.Event.Picked);
                        let marked = markSeen(r, w);
                        let logged = { log = List.take(KindDoc.rec(res#kind)#logMax, World.Entry.Chose(option#line#text) :: r#log),
                                       choices = Nil | r };
                        let (talk, events) = YarnRunner.step(YarnRunner.Action.Choose(i), World.now(w), r#talk);
                        absorb(res, Commands.Replay.Live, events, { talk = talk | logged }, marked)
                    case _ => w
                }
            case _ => w
        }

    /// 選択肢のカーソルで選ぶ。
    pub def pickHere(res: Res.Res, w: World.World): World.World \ Emit[World.Event] =
        match World.readOf(w) {
            case Some(r) => pick(res, r#choiceCursor, w)
            case None    => w
        }

    /// 選択肢のカーソルを delta ぶん動かす（選べない選択肢は飛ばし、端で反対側へ回り込む）。
    pub def moveChoice(delta: Int32, w: World.World): World.World \ Emit[World.Event] =
        whileReading(r -> {
            let open = r#choices |> List.zipWithIndex |> List.filter(match (_, option) -> option#available) |> List.map(fst);
            let count = List.length(open);
            if (count == 0) w
            else {
                let at = open |> List.zipWithIndex |> List.find(match (_, i) -> i == r#choiceCursor) |> Option.map(fst) |> Option.getWithDefault(0);
                let next = List.nth(Int32.modulo(at + delta, count), open) |> Option.getWithDefault(r#choiceCursor);
                pointChoice(next, w)
            }
        }, w)

    /// 選択肢のカーソルを i へ（マウスが乗った物。選べない選択肢と、同じ所なら何もしない）。
    pub def pointChoice(i: Int32, w: World.World): World.World \ Emit[World.Event] =
        whileReading(r -> {
            let open = List.nth(i, r#choices) |> Option.exists(option -> option#available);
            if (not open or i == r#choiceCursor) w
            else { Emit.emit(World.Event.Moved); World.withRead({ choiceCursor = i | r }, w) }
        }, w)

    // ── 毎フレーム ──

    /// 毎フレーム（App が時計を進めた後）: <<wait>> が明けたら続きを流し、文字送りを進め、出し終えた時刻を記し、オートとスキップを決める。
    /// 画面や確認のウィンドウを開いている間は物語の時計が止まるので、待ちも文字送りもオートも止まる。
    /// 素材を待っている間は、待ちの段だけを進める（dt = このフレームの実時間の秒。諦めるまでの秒を数える。確認のウィンドウの間は数えない）。
    pub def step(res: Res.Res, dt: Float64, w: World.World): World.World \ Emit[World.Event] =
        whileReading(r -> match r#hold {
            case Some(hold) => if (World.isFree(w)) stepHold(res, dt, hold, r, w) else w
            case None       => holdIfMissing(res, readOn(res, r, w))
        }, w)

    /// 待っていない時の 1 歩（<<wait>>・文字送り・出し終えた時刻・オートとスキップ）。
    def readOn(res: Res.Res, r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let waited = match YarnRunner.shownOf(r#talk) {
            case YarnRunner.Shown.Waiting =>
                // スキップ中は待ちも飛ばす（明ける時刻をそのまま渡す）。
                let at = if (r#playback == World.Playback.Skip) YarnRunner.waitUntilOf(r#talk) |> Option.getWithDefault(World.now(w)) else World.now(w);
                let (talk, events) = YarnRunner.step(YarnRunner.Action.Tick, at, r#talk);
                absorb(res, Commands.Replay.Live, events, { talk = talk | r }, w)
            case _ => w
        };
        whileReading(cur -> {
            let noWait = KindDoc.isNoWait(World.configOf(waited)#cps, res#kind);
            let fast = noWait or (cur#playback == World.Playback.Skip and isSkippable(cur, waited));
            let page = if (fast) Page.revealAll(cur#page)
                       else Page.step(World.configOf(waited)#cps, Clock.dtOf(waited#storyClock), cur#page);
            let typed = { page = page | cur };
            let stamped = if (Page.isDone(page) and Option.isEmpty(typed#doneAt)) { doneAt = Some(World.now(waited)) | typed } else typed;
            autoOrSkip(res, stamped, waited)
        }, waited)

    /// オートとスキップ（行を出し終えてから、決めた間が過ぎたら送る）。
    /// スキップは選択肢で止まるか待つか（設定の「選択肢の後」）、読んでいない行で止まるか（設定の「スキップ」）。
    def autoOrSkip(res: Res.Res, r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let manual = World.withRead({ playback = World.Playback.Manual | r }, w);
        if (not World.isFree(w)) World.withRead(r, w)
        else if (r#playback == World.Playback.Skip and not List.isEmpty(r#choices))
            if (World.configOf(w)#afterChoice == Saves.AfterChoice.StopSkip) manual else World.withRead(r, w)
        else if (r#playback == World.Playback.Skip and Option.nonEmpty(r#page#current) and not isSkippable(r, w)) manual
        else match r#doneAt {
            case None     => World.withRead(r, w)
            case Some(at) =>
                let k = KindDoc.rec(res#kind);
                let waited = Clock.since(at, World.now(w));
                let chars = r#page#current |> Option.map(line -> String.length(line#text)) |> Option.getWithDefault(0);
                let autoWait = World.configOf(w)#autoWait + Int32.toFloat64(chars) * k#autoPerChar;
                match r#playback {
                    case World.Playback.Skip   => if (waited >= k#skipInterval) next(res, r, w) else World.withRead(r, w)
                    case World.Playback.Auto   => if (waited >= autoWait) next(res, r, w) else World.withRead(r, w)
                    case World.Playback.Manual => World.withRead(r, w)
                }
        }

    /// オートかスキップを、点いていれば消し（人が押す）、そうでなければそれに替える。
    pub def togglePlayback(mode: World.Playback, w: World.World): World.World \ Emit[World.Event] =
        whileReading(r -> {
            Emit.emit(World.Event.Moved);
            World.withRead({ playback = if (r#playback == mode) World.Playback.Manual else mode | r }, w)
        }, w)

    // ── オートセーブ・今の所のデータ ──

    /// 今の所のデータ（読んでいなければ None）。セーブの画面とクイックセーブが書く。
    pub def slotHere(res: Res.Res, w: World.World): Option[Saves.Slot] =
        World.readOf(w) |> Option.flatMap(r -> slotAt(res, markHere(r), r, w))

    /// 今の所の戻れる所。<<wait>> の間は、今出している台詞の戻れる所（バックログの一番新しい物）。
    // WhyNot: 待っている間に今のブックマークと舞台で作らない — 当て直しは待ちを飛ばして次の台詞まで進むので、
    //         待つ前の舞台と頁で置き換えると、次の台詞の舞台と頁が食い違う。
    def markHere(r: World.Read): Option[Saves.Mark] =
        let current = YarnRunner.bookmarkOf(r#talk) |> Option.map(b -> markOf(b, r));
        match YarnRunner.shownOf(r#talk) {
            case YarnRunner.Shown.Waiting => r#log |> List.findMap(lineMarkOf) |> Option.withDefault(default = current)
            case _                        => current
        }

    def lineMarkOf(entry: World.Entry): Option[Saves.Mark] = match entry {
        case World.Entry.Said(_, mark) => mark
        case World.Entry.Chose(_)      => None
    }

    /// 戻れる所 mark で作るデータ（mark が無ければ None）。
    def slotAt(res: Res.Res, mark: Option[Saves.Mark], r: World.Read, w: World.World): Option[Saves.Slot] =
        mark |> Option.map(m -> {
            let place = Stage.fromSnapshot(m#stage)#shot |> Option.flatMap(shot -> BackdropDoc.photoOf(shot#photo, res#backdrops))
                |> Option.map(photo -> photo#label) |> Option.getWithDefault("");
            let (speaker, excerpt) = r#page#current |> Option.map(line -> (line#speaker, String.takeLeft(80, line#text)))
                |> Option.getWithDefault(("", ""));
            { mark = m, place = place, speaker = speaker, excerpt = excerpt, savedAt = savedAtNow(w),
              serial = Saves.nextSerial(w#saves) }
        })

    /// 今のその土地の時刻（秒）。
    def savedAtNow(w: World.World): Int64 =
        w#clockBase + (Float64.tryToInt64(Float64.floor(Clock.secondsOf(w#realNow))) |> Option.getWithDefault(0i64))

    /// 新しいノードの最初の行でオートセーブ（オートのページの先頭へ。音も知らせも出さない）。
    def autosave(res: Res.Res, mark: Option[Saves.Mark], r: World.Read, w: World.World): World.World =
        let node = YarnRunner.nodeOf(r#talk);
        if (Option.isEmpty(node) or node == r#autosavedNode) World.withRead(r, w)
        else match slotAt(res, mark, r, w) {
            case Some(slot) =>
                World.withSaves(Saves.withPushed(Saves.Tab.Auto, slot, w#saves), World.withRead({ autosavedNode = node | r }, w))
            case None => World.withRead(r, w)
        }

    // ── 戻れる所へ戻す ──

    /// 戻れる所へ戻す: ブックマークを当て直し、通ったコマンドを音を出さずに反映してバックログと選択肢を作り直し、
    /// 最後に舞台と頁を Mark の値で置き換える（頁の無い version 2 の枠は当て直しで作った頁のまま）。
    /// 画面と確認のウィンドウは閉じる。[遷移: Title / Reading→Reading]
    // WhyNot: 当て直した舞台を使わない — 当て直しは今のノードの頭からなので、前のノードの分と、数え足す値（頁の数など）が合わない。
    pub def restore(res: Res.Res, mark: Saves.Mark, w: World.World): World.World \ Emit[World.Event] =
        let saved = Stage.fromSnapshot(mark#stage);
        let (talk, events) = YarnRunner.resume(res#dialogue, mark#bookmark, World.now(w));
        let gaveUp = World.readOf(w) |> Option.map(r -> r#gaveUp) |> Option.getWithDefault(Set.empty());
        settled(absorb(res, Commands.Replay.Silent, events, { talk = talk, stage = saved, gaveUp = gaveUp | World.emptyRead() },
                       { panel = World.Panel.Closed, ask = None | w }))
            |> World.mapRead(r -> { stage = saved, page = Option.getWithDefault(r#page, mark#page) | r })

    /// 当て直した後の形: 演出の途中は終わりの形にし、今のノードはオートセーブ済みとして扱う（戻った所で同じ物を残さない）。
    def settled(w: World.World): World.World =
        World.mapRead(r -> { stage = Stage.settle(r#stage), autosavedNode = YarnRunner.nodeOf(r#talk) | r }, w)

    /// セーブの枠のサムネに映す画面: その枠の戻れる所へ音を出さずに戻した World（文は出し終え、画面・確認のウィンドウは閉じ、マウスはどこにも乗せない）。
    /// WhyNot: 保存の時に画面の絵を撮って残さない —— セーブの JSON に絵を入れると重く、描き出しと実機で同じ絵にならない。
    pub def screenOf(res: Res.Res, mark: Saves.Mark, w: World.World): World.World =
        let (back, _) = Emit.collect(() -> restore(res, mark, w));
        World.withPointer({ x = -1.0, y = -1.0 }, back)

    // ── 素材の待ち（ブラウザ版で後回しにした背景・環境音がまだ届いていない時） ──
    //
    // 待つのは背景と環境音だけ（一発の効果音は待たず、届いていなければ鳴らさない = Controls.sounds）。
    // 段は FadingOut（黒へ重ねる・物語の時計は動く）→ Waiting（黒のまま・物語の時計を止める = World.paceOf）→ FadingIn（黒から戻す）。
    // Waiting は実時間で holdGiveUpSeconds まで待ち、届かなければその素材を諦め（gaveUp）、無いまま進む（背景は暗い地で描く）。
    // 入り口は 2 つ: 読み進めて未着の背景・環境音へ切り替える所（absorbFrom。続きの出来事を預ける）と、
    // 今の舞台の背景・環境音が未着のまま止まった所（holdIfMissing。スキップが止まった・ロードや「戻る」で戻った）。

    /// pairs の頭が、まだ届いていない背景・環境音へ切り替えるコマンドなら、次の台詞か選択肢までに切り替える背景・環境音のうち
    /// まだ届いていない物の名前（暗転 1 回でまとめて待つ）。頭がそうでない・スキップ中（止まった所で待つ）なら空。
    def namesToWait(res: Res.Res, pairs: List[(YarnRunner.Event, Int32)], w: World.World): List[String] =
        let cues = pairs |> List.map(fst) |> List.takeWhile(isCommand);
        match World.readOf(w) {
            case Some(r) if r#playback != World.Playback.Skip =>
                let head = List.head(cues) |> Option.map(event -> pendingNames(res, r, eventNames(res, r#stage, event))) |> Option.getWithDefault(Nil);
                if (List.isEmpty(head)) Nil else pendingNames(res, r, namesAlong(ctxOf(res, r, w), r#stage, cues))
            case _ => Nil
        }

    def isCommand(event: YarnRunner.Event): Bool = match event {
        case YarnRunner.Event.Command(_) => true
        case _                           => false
    }

    /// 出来事が切り替える背景・環境音・立ち絵の名前（コマンドでなければ空）。stage = 今の舞台（省いた表情を埋める）。
    def eventNames(res: Res.Res, stage: Stage.Stage, event: YarnRunner.Event): List[String] = match event {
        case YarnRunner.Event.Command(command) => Commands.needsOf(res, command, stage)
        case _                                 => Nil
    }

    /// 出来事の列が順に使う背景・環境音・立ち絵の名前。舞台に 1 つずつ当てながら集める
    /// （<<show a smile>> の後の <<show a at=left>> は、笑顔のまま左へ出す絵を待つ）。
    def namesAlong(ctx: Commands.Ctx, stage: Stage.Stage, events: List[YarnRunner.Event]): List[String] =
        let step = (acc, event) -> {
            let (cur, names) = acc;
            match event {
                case YarnRunner.Event.Command(command) =>
                    let next = Commands.execute(Commands.Replay.Silent, ctx, command, cur) |> Result.map(fst) |> Result.getWithDefault(cur);
                    (next, List.append(names, Commands.needsOf(ctx#res, command, cur)))
                case _ => acc
            }
        };
        snd(List.foldLeft(step, (stage, Nil), events))

    /// 舞台が使っている背景・環境音・立ち絵の名前。
    def stageNames(res: Res.Res, stage: Stage.Stage): List[String] =
        let photo = stage#shot |> Option.flatMap(shot -> BackdropDoc.textureOf(shot#photo, res#backdrops)) |> Option.toList;
        let sound = PropertyTween.nameEnd(Stage.ambienceKey(), stage#props) |> Option.toList;
        List.flatten(photo :: sound :: Cast.textures(stage#cast) :: Nil)

    /// names のうち、まだ届いていなくて、諦めてもいない物（重なりは 1 つに）。
    def pendingNames(res: Res.Res, r: World.Read, names: List[String]): List[String] =
        names |> List.filter(name -> Set.memberOf(name, res#missing) and not Set.memberOf(name, r#gaveUp)) |> List.distinct

    /// 素材の待ちに入る（黒へ重ね始める）。rest = 届いたら反映する続きの出来事、last = その台詞の戻れる所の元。
    def startHold(names: List[String], rest: List[(YarnRunner.Event, Int32)], last: Option[YarnRunner.Bookmark], w: World.World): World.World =
        let hold = { phase = World.HoldPhase.FadingOut, phaseFrom = World.now(w), waited = 0.0, names = names, rest = rest, last = last };
        World.mapRead(r -> { hold = Some(hold) | r }, w)

    /// 今の舞台の背景・環境音がまだ届いていなければ、ここで待つ（続きは無い。届いたら黒から戻すだけ）。
    /// スキップ中と、画面や確認のウィンドウを開いている間は入らない（閉じた・止まった所で入る）。
    def holdIfMissing(res: Res.Res, w: World.World): World.World =
        match World.readOf(w) {
            case Some(r) if r#playback != World.Playback.Skip and World.isFree(w) =>
                let names = pendingNames(res, r, stageNames(res, r#stage));
                if (List.isEmpty(names)) w else startHold(names, Nil, YarnRunner.bookmarkOf(r#talk), w)
            case _ => w
        }

    /// 待ちの段を 1 歩進める。黒へ重ね切ったら Waiting、届いたら（か諦めたら）続きを反映して FadingIn、黒から戻し切ったら待ちを消す。
    /// Waiting に入る所（黒くなり切った所）で立ち絵の重ねの途中を終わりの形にする（待ちが明けて物語の時計が進み出した時に、半分透けた人物を見せない）。
    // WhyNot: Stage.settle を丸ごと掛けない — 背景の重ねは resumeHold が黒の下から出し直し、揺れは物語の時計が止まっている間は進まないので、立ち絵だけでよい。
    def stepHold(res: Res.Res, dt: Float64, hold: World.Hold, r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let k = KindDoc.rec(res#kind);
        let faded = Clock.since(hold#phaseFrom, World.now(w)) >= k#holdFadeSeconds;
        let withHold = (next: Option[World.Hold]) -> World.withRead({ hold = next | r }, w);
        match hold#phase {
            case World.HoldPhase.FadingOut =>
                if (faded) World.withRead({ hold = Some({ phase = World.HoldPhase.Waiting, waited = 0.0 | hold }),
                                            stage = { cast = Cast.settle(r#stage#cast) | r#stage } | r }, w)
                else w
            case World.HoldPhase.FadingIn  => if (faded) withHold(None) else w
            case World.HoldPhase.Waiting   =>
                let left = pendingNames(res, r, hold#names);
                let waited = hold#waited + dt;
                if (List.isEmpty(left)) resumeHold(res, hold, r, w)
                else if (waited >= k#holdGiveUpSeconds) resumeHold(res, hold, { gaveUp = Set.union(r#gaveUp, List.toSet(left)) | r }, w)
                else withHold(Some({ waited = waited | hold }))
        }

    /// 届いた（か諦めた）: 黒から戻し始め、預けておいた続きの出来事を反映する。
    /// 背景は前の写真から重ねず、黒の下の暗い地から新しい写真を出す（under を捨てる）。
    def resumeHold(res: Res.Res, hold: World.Hold, r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let opening = World.withRead({ hold = Some({ phase = World.HoldPhase.FadingIn, phaseFrom = World.now(w), rest = Nil | hold }) | r }, w);
        absorbFrom(res, Commands.Replay.Live, hold#last, hold#rest, opening)
            |> World.mapRead(cur -> { stage = { under = None | cur#stage } | cur })

    // ── 始まりの場面（Starts・描き出し） ──

    /// node の頭から、.yarn の line 行を出している所まで進めた World（Studio の会話のプレビュー・bin/fge talk goto・描き出し）。
    /// 舞台は node に最初に着いた時の形（entryOf）から始め、通ったコマンドは音を出さずに反映し、演出の途中は終わりの形にする。
    pub def openAt(res: Res.Res, storage: YarnStorage.Storage, node: String, line: Int32, w: World.World): World.World \ Emit[World.Event] =
        let (talk, events) = YarnRunner.startAtWith(storage, res#dialogue, node, line, World.now(w));
        settled(absorb(res, Commands.Replay.Silent, events, { talk = talk, stage = entryOf(res, node) | World.emptyRead() },
                       { panel = World.Panel.Closed, ask = None | w }))

    // ── ノードに着いた時の舞台 ──
    //
    // opening のノードの頭から音を出さずに流し（台詞は送り・<<wait>> は明ける時刻へ・選択肢は選べる物を全部たどる）、
    // 出来事の .yarn の行でどのノードに居るかを見て、ノードに最初に入る直前の舞台を残す。頁とコマンドの反映は読み進める時と同じ absorbOne。
    // 道が増えすぎないよう、もう着いたノードへ入った道はそこで止め、全体の歩数に上限（entryFuel）を置く。

    /// 全体の歩数の上限（台詞を送る・選ぶ・待ちを明かすの 1 回が 1 歩）。
    pub def entryFuel(): Int32 = 4000

    /// node に最初に着いた時の舞台。着かない（上限に当たった・どこからも jump しない）時は空の舞台で 1 行言う。
    pub def entryOf(res: Res.Res, node: String): Stage.Stage =
        match Map.get(node, entriesWithin(entryFuel(), res)) {
            case Some(snapshot) => Stage.fromSnapshot(snapshot)
            case None           => Log.warnThen("[stage] ${node} は ${StoryDoc.openingOf(res#story)} から流しても着かない（空の舞台から始める）", Stage.empty())
        }

    /// fuel 歩までに着いたノードごとの、最初に着いた時の舞台（opening は空の舞台）。
    pub def entriesWithin(fuel: Int32, res: Res.Res): Map[String, Stage.Snapshot] =
        let opening = StoryDoc.openingOf(res#story);
        match Yarn.nodeOf(opening, res#dialogue) {
            case None    => Map.empty()
            case Some(_) =>
                let (talk, events) = YarnRunner.start(res#dialogue, opening, Clock.zero());
                let found = Map#{ opening => Stage.snapshotOf(Stage.empty()) };
                let w = World.withRead({ talk = talk | World.emptyRead() }, World.initial(Saves.fresh(res#kind), 0i64));
                let first = absorbTracking(res, nodesBySource(res#dialogue), events, { w = w, node = opening, found = found, revisited = false });
                snd(walkEntries(res, nodesBySource(res#dialogue), fuel, first#w :: Nil, first#found))
        }

    /// .yarn の「ファイル:行」→ その行を持つノードの名前。
    def nodesBySource(program: Yarn.Program): Map[String, String] =
        Yarn.nodeNames(program) |> List.filterMap(name -> Yarn.nodeOf(name, program)) |> List.flatMap(node ->
            Talk.statementsOf(node) |> List.filterMap(Talk.sourceOf) |> List.map(source -> (Yarn.sourceText(source), node#title)))
            |> List.toMap

    /// 出来事の .yarn の行（Done は無い）。
    def eventSource(event: YarnRunner.Event): Option[Yarn.Source] = match event {
        case YarnRunner.Event.Line(line)       => Some(line#source)
        case YarnRunner.Event.Choices(options) => List.head(options) |> Option.map(option -> option#line#source)
        case YarnRunner.Event.Command(command) => Some(command#source)
        case YarnRunner.Event.Done             => None
    }

    /// 道 1 本を流している所: w = 流した World、node = 今居るノード、found = 着いたノードの舞台、revisited = この歩でもう着いたノードへ入ったか。
    type alias Tracking = { w = World.World, node = String, found = Map[String, Stage.Snapshot], revisited = Bool }

    /// 出来事を順に反映し、ノードに入る直前の舞台を残す。
    def absorbTracking(res: Res.Res, nodes: Map[String, String], events: List[YarnRunner.Event], start: Tracking): Tracking =
        let step = (t: Tracking, event) -> {
            let entered = eventSource(event) |> Option.flatMap(source -> Map.get(Yarn.sourceText(source), nodes)) |> Option.filter(n -> n != t#node);
            let marked = match entered {
                case Some(n) if Map.memberOf(n, t#found) => { node = n, revisited = true | t }
                case Some(n) =>
                    let stage = World.readOf(t#w) |> Option.map(r -> r#stage) |> Option.getWithDefault(Stage.empty());
                    { node = n, found = Map.insert(n, Stage.snapshotOf(stage), t#found) | t }
                case None => t
            };
            { w = fst(Emit.collect(() -> absorbOne(res, Commands.Replay.Silent, None, event, 0, marked#w))) | marked }
        };
        List.foldLeft(step, start, events)

    /// 流す道の列 stack を頭から 1 歩ずつ進める。返すのは (残りの歩数, 着いたノードの舞台)。
    def walkEntries(res: Res.Res, nodes: Map[String, String], fuel: Int32, stack: List[World.World],
                    found: Map[String, Stage.Snapshot]): (Int32, Map[String, Stage.Snapshot]) =
        match stack {
            case Nil => (fuel, found)
            case w :: rest if fuel > 0 =>
                let (left, more, seen) = stepEntries(res, nodes, fuel, w, found);
                walkEntries(res, nodes, left, List.append(more, rest), seen)
            case _ => (fuel, found)
        }

    /// 道 1 本の次の 1 歩（選択肢なら選べる物ごとに 1 歩）。返すのは (残りの歩数, 続ける道, 着いたノードの舞台)。
    def stepEntries(res: Res.Res, nodes: Map[String, String], fuel: Int32, w: World.World,
                    found: Map[String, Stage.Snapshot]): (Int32, List[World.World], Map[String, Stage.Snapshot]) =
        let actions = World.readOf(w) |> Option.map(r -> match YarnRunner.shownOf(r#talk) {
            case YarnRunner.Shown.Line(_)       => (YarnRunner.Action.Advance, Clock.zero()) :: Nil
            case YarnRunner.Shown.Waiting       => (YarnRunner.Action.Tick, YarnRunner.waitUntilOf(r#talk) |> Option.getWithDefault(Clock.zero())) :: Nil
            case YarnRunner.Shown.Choices(opts) =>
                opts |> List.zipWithIndex |> List.filter(match (_, option) -> option#available)
                     |> List.map(match (i, _) -> (YarnRunner.Action.Choose(i), Clock.zero()))
            case YarnRunner.Shown.Closed        => Nil
        }) |> Option.getWithDefault(Nil);
        let take = (acc, action) -> {
            let (left, kept, seen) = acc;
            let (at, now) = action;
            match World.readOf(w) {
                case Some(r) if left > 0 =>
                    let (talk, events) = YarnRunner.step(at, now, r#talk);
                    let node = YarnRunner.nodeOf(r#talk) |> Option.getWithDefault("");
                    let t = absorbTracking(res, nodes, events, { w = World.withRead({ talk = talk | r }, w), node = node, found = seen, revisited = false });
                    (left - 1, if (t#revisited) kept else List.append(kept, t#w :: Nil), t#found)
                case _ => acc
            }
        };
        List.foldLeft(take, (fuel, Nil, found), actions)

    /// 今の行を出し終えた形（描き出しが場面を作る時。時計を進めずに 1 行読み終える）。
    pub def revealLine(w: World.World): World.World = World.mapRead(r -> { page = Page.revealAll(r#page) | r }, w)

    /// シナリオを差し替えた後に World を収める（保存即反映。res は差し替えた後の描く元）。
    /// 読んでいる途中なら、開いているノードの頭から読み直す（編集がその場で画面に出る）。
    /// WhyNot: 読んでいた行から続けない —— 行の並びが変わると「同じ行」が決まらない。
    pub def settleDialogue(res: Res.Res, w: World.World): World.World =
        match World.readOf(w) {
            case Some(r) => reopenNode(res, r, w)
            case None    => w
        }

    /// 開いていたノードを新しいシナリオの頭から開き直す（ノードが消えていればタイトルへ）。
    def reopenNode(res: Res.Res, r: World.Read, w: World.World): World.World =
        match YarnRunner.nodeOf(r#talk) {
            case Some(node) if Option.nonEmpty(Yarn.nodeOf(node, res#dialogue)) =>
                let (talk, events) = YarnRunner.startWith(YarnRunner.storageOf(r#talk), res#dialogue, node, World.now(w));
                fst(Emit.collect(() -> absorb(res, Commands.Replay.Silent, events, { talk = talk, page = Page.empty(), choices = Nil, hold = None | r }, w)))
            case Some(_) => World.toTitle(w)
            case None    => w
        }
}
