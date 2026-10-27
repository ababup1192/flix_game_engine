// WorldRead — 読み進める規則（純粋）: はじめから読む・送る・選ぶ・文字送り・オートとスキップ・戻れる所へ戻す。
// 文章・分岐・結末はシナリオ assets/talk/natsukusa.yarn（YarnRunner が辿る）、舞台の変え方は Stage、頁は Page。
// ここの関数は、場面が Reading の時だけ読んでいる値 Read を取り出して動く（ほかの場面では何もしない）。
//
// 戻れる所（Saves.Mark）は 3 か所が同じ物を持つ: セーブデータ・バックログの行・「戻る」。戻し方は restore 1 つで、
// ブックマークを当て直し（通ったコマンドは音を出さずに頁と舞台へ反映し直す）、前のノードから持ち越す舞台は Mark の値で戻す。
//
// オートとスキップは同じ所（autoOrSkip）で決める: 行を出し終えた時刻 doneAt から、オートは「設定の待ち + 字数 × autoPerChar」、
// スキップは skipInterval ごとに送る。スキップは設定で「既読のみ」なら読んでいない行で止まり、選択肢で止まるかも設定で選ぶ。
mod WorldRead {
    use fge::{Clock, Emit, Log, Yarn, YarnRunner, YarnStorage}

    /// シナリオの出来事を反映する時に、音とオートセーブを出すか。
    /// Live = 人が読み進めている時、Silent = ロード・戻る・プレビューの当て直し（音もオートセーブも出さず、行は出し終えた形）。
    enum Replay with Eq {
        case Live
        case Silent
    }

    /// 読んでいる間だけ f(読んでいる値) を通す（ほかの場面ではそのまま）。
    def whileReading(f: World.Read -> World.World \ ef, w: World.World): World.World \ ef =
        match World.readOf(w) {
            case Some(r) => f(r)
            case None    => w
        }

    // ── はじめから ──

    /// はじめから読む。[遷移: Title→Reading]
    pub def newGame(w: World.World): World.World \ Emit[World.Event] =
        Emit.emit(World.Event.Opened);
        let opened = { panel = World.Panel.Closed, ask = None | w };
        let first = Talk.nodeName(Talk.Node.Opening);
        match Yarn.nodeOf(first, w#docs#dialogue) {
            case Some(_) =>
                let (talk, events) = YarnRunner.start(w#docs#dialogue, first, World.now(w));
                absorb(Replay.Live, events, { talk = talk | World.emptyRead() }, opened)
            case None =>
                showLine(Replay.Live, None, { speaker = "", text = "（シナリオが読めない。assets/talk/natsukusa.yarn を直して bin/fge yarn build assets/talk を流すと、ここに物語が流れる）",
                                             parts = Nil, tags = Nil, source = { file = "", line = 0 } }, World.emptyRead(), opened)
        }

    // ── シナリオの出来事を反映する ──

    /// 実行器が返した出来事を順に反映する。r は反映を始める読んでいる値（新しいシナリオの位置 talk を入れた物）。
    /// 台詞ごとの戻れる所は、最後のブックマークから「その台詞より後に受けた入力」の数だけ入力を外した物（inputsAfter と markAt）。
    /// [遷移: シナリオが終わる(Done) → Credits]
    def absorb(replay: Replay, events: List[YarnRunner.Event], r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let last = YarnRunner.bookmarkOf(r#talk);
        List.zip(events, inputsAfter(events)) |> List.foldLeft((acc, pair) -> {
            let (event, later) = pair;
            match event {
                case YarnRunner.Event.Line(line)       =>
                    whileReading(cur -> showLine(replay, markAt(last, later, cur#stage), line, cur, acc), acc)
                case YarnRunner.Event.Choices(options) =>
                    World.mapRead(cur -> { choices = options, choiceCursor = firstOpen(options) | cur }, acc)
                case YarnRunner.Event.Command(command) =>
                    whileReading(cur -> World.withRead(cue(replay, command, cur, acc), acc), acc)
                case YarnRunner.Event.Done             => World.toCredits(acc)
            }
        }, World.withRead(r, w))

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

    /// 最後のブックマークから入力を later 個外した所と、その時の舞台。
    /// ブックマークの steps は「ノードの頭から受けた入力」の列なので、後ろの later 個を外すとその台詞を出した所に戻る。
    def markAt(last: Option[YarnRunner.Bookmark], later: Int32, stage: Stage.Stage): Option[Saves.Mark] =
        last |> Option.map(b -> {
            let kept = Int32.max(0, List.length(b#steps) - later);
            { bookmark = { steps = List.take(kept, b#steps) | b }, shot = stage#shot, ambience = stage#ambience,
              particles = stage#particles, mode = stage#mode }
        })

    /// コマンド 1 つ（wait は実行器が待つので何もしない）。読めないコマンドは 1 行知らせて舞台はそのまま。
    def cue(replay: Replay, command: Yarn.Command, r: World.Read, w: World.World): World.Read \ Emit[World.Event] =
        if (command#name == "wait") r
        else match Stage.cueOf(w#docs#backdrops, command) {
            case Ok(Stage.Cue.Clear)        => { page = Page.clear(r#page) | r }
            case Ok(Stage.Cue.Se(name))     => if (replay == Replay.Silent) r else { Emit.emit(World.Event.Cue("se_${name}")); r }
            case Ok(Stage.Cue.ToMode(mode)) =>
                let page = if (mode == r#stage#mode) r#page else Page.clear(r#page);
                { stage = Stage.applyCue(World.now(w), Stage.Cue.ToMode(mode), r#stage), page = page | r }
            case Ok(c)                      => { stage = Stage.applyCue(World.now(w), c, r#stage) | r }
            case Err(message)               => Log.warnThen("[stage] ${message}", r)
        }

    /// 台詞 1 行を頁とバックログへ。NVL で頁に入り切らない時は頁をめくってから積む。新しいノードの最初の行ならオートセーブ。
    def showLine(replay: Replay, mark: Option[Saves.Mark], line: Yarn.Line, r: World.Read, w: World.World): World.World =
        let entry = Page.lineOf(StoryDoc.nameOf(line#speaker, w#docs#story), line);
        let page = Page.show(r#stage#mode, fitsNvl(w), entry, r#page);
        let shown = { page = if (replay == Replay.Silent) Page.revealAll(page) else page, choices = Nil, doneAt = None,
                      log = List.take(KindDoc.rec(w#docs#kind)#logMax, World.Entry.Said(entry, mark) :: r#log) | r };
        if (replay == Replay.Silent) World.withRead(shown, w) else autosave(mark, shown, w)

    /// NVL の頁に行の列が入り切るか（行の数は novel.kind.json の nvlRows）。
    def fitsNvl(w: World.World): List[Page.Line] -> Bool = lines ->
        let k = KindDoc.rec(w#docs#kind);
        let rows = lines |> List.foldLeft((sum, line) -> sum + Page.rowsOf(k#bodySize, k#rubySize, Layout.nvlText()#width, line), 0);
        rows <= k#nvlRows

    def firstOpen(options: List[YarnRunner.DialogueOption]): Int32 =
        options |> List.zipWithIndex |> List.find(match (_, option) -> option#available)
                |> Option.map(fst) |> Option.getWithDefault(0)

    // ── 読み進める ──

    /// 決定 1 回分（読んでいる間・画面が閉じている時）。文字送りの途中なら全文へ、出し終えていれば次の行へ。
    /// 選択肢を出している間は動かない（pick だけが進める）。オートとスキップは止める（人が押したら人の速さに戻す）。
    pub def advance(w: World.World): World.World \ Emit[World.Event] =
        match World.readOf(w) {
            case Some(r) if World.isFree(w) and List.isEmpty(r#choices) =>
                let manual = { playback = World.Playback.Manual | r };
                if (not Page.isDone(r#page)) {
                    Emit.emit(World.Event.Revealed);
                    World.withRead({ page = Page.revealAll(r#page) | manual }, w)
                } else next(manual, w)
            case _ => w
        }

    /// 今の行を既読にして、次の行へ送る。[遷移: 行→次の行 / 選択肢 / シナリオの終わり(Credits)]
    def next(r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let marked = markSeen(r, w);
        match YarnRunner.shownOf(r#talk) {
            case YarnRunner.Shown.Line(_) =>
                Emit.emit(World.Event.Paged);
                let (talk, events) = YarnRunner.step(YarnRunner.Action.Advance, World.now(marked), r#talk);
                absorb(Replay.Live, events, { talk = talk | r }, marked)
            case YarnRunner.Shown.Closed => World.toCredits(World.withRead(r, marked))
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
    pub def pick(i: Int32, w: World.World): World.World \ Emit[World.Event] =
        match World.readOf(w) {
            case Some(r) if World.isFree(w) =>
                match List.nth(i, r#choices) {
                    case Some(option) if option#available =>
                        Emit.emit(World.Event.Picked);
                        let marked = markSeen(r, w);
                        let logged = { log = List.take(KindDoc.rec(w#docs#kind)#logMax, World.Entry.Chose(option#line#text) :: r#log),
                                       choices = Nil | r };
                        let (talk, events) = YarnRunner.step(YarnRunner.Action.Choose(i), World.now(w), r#talk);
                        absorb(Replay.Live, events, { talk = talk | logged }, marked)
                    case _ => w
                }
            case _ => w
        }

    /// 選択肢のカーソルで選ぶ。
    pub def pickHere(w: World.World): World.World \ Emit[World.Event] =
        match World.readOf(w) {
            case Some(r) => pick(r#choiceCursor, w)
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
    pub def step(w: World.World): World.World \ Emit[World.Event] =
        whileReading(r -> {
            let waited = match YarnRunner.shownOf(r#talk) {
                case YarnRunner.Shown.Waiting =>
                    // スキップ中は待ちも飛ばす（明ける時刻をそのまま渡す）。
                    let at = if (r#playback == World.Playback.Skip) YarnRunner.waitUntilOf(r#talk) |> Option.getWithDefault(World.now(w)) else World.now(w);
                    let (talk, events) = YarnRunner.step(YarnRunner.Action.Tick, at, r#talk);
                    absorb(Replay.Live, events, { talk = talk | r }, w)
                case _ => w
            };
            whileReading(cur -> {
                let fast = cur#playback == World.Playback.Skip and isSkippable(cur, waited);
                let page = if (fast) Page.revealAll(cur#page)
                           else Page.step(World.configOf(waited)#cps, Clock.dtOf(waited#storyClock), cur#page);
                let typed = { page = page | cur };
                let stamped = if (Page.isDone(page) and Option.isEmpty(typed#doneAt)) { doneAt = Some(World.now(waited)) | typed } else typed;
                autoOrSkip(stamped, waited)
            }, waited)
        }, w)

    /// オートとスキップ（行を出し終えてから、決めた間が過ぎたら送る）。
    /// スキップは選択肢で止まるか待つか（設定の「選択肢の後」）、読んでいない行で止まるか（設定の「スキップ」）。
    def autoOrSkip(r: World.Read, w: World.World): World.World \ Emit[World.Event] =
        let manual = World.withRead({ playback = World.Playback.Manual | r }, w);
        if (not World.isFree(w)) World.withRead(r, w)
        else if (r#playback == World.Playback.Skip and not List.isEmpty(r#choices))
            if (World.configOf(w)#afterChoice == Saves.AfterChoice.StopSkip) manual else World.withRead(r, w)
        else if (r#playback == World.Playback.Skip and Option.nonEmpty(r#page#current) and not isSkippable(r, w)) manual
        else match r#doneAt {
            case None     => World.withRead(r, w)
            case Some(at) =>
                let k = KindDoc.rec(w#docs#kind);
                let waited = Clock.since(at, World.now(w));
                let chars = r#page#current |> Option.map(line -> String.length(line#text)) |> Option.getWithDefault(0);
                let autoWait = World.configOf(w)#autoWait + Int32.toFloat64(chars) * k#autoPerChar;
                match r#playback {
                    case World.Playback.Skip   => if (waited >= k#skipInterval) next(r, w) else World.withRead(r, w)
                    case World.Playback.Auto   => if (waited >= autoWait) next(r, w) else World.withRead(r, w)
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
    pub def slotHere(w: World.World): Option[Saves.Slot] =
        World.readOf(w) |> Option.flatMap(r -> slotAt(None, r, w))

    /// mark を渡せばその戻れる所で、無ければ今のブックマークで作るデータ。
    def slotAt(mark: Option[Saves.Mark], r: World.Read, w: World.World): Option[Saves.Slot] =
        let here = match mark {
            case Some(m) => Some(m)
            case None    => markAt(YarnRunner.bookmarkOf(r#talk), 0, r#stage)
        };
        here |> Option.map(m -> {
            let place = m#shot |> Option.flatMap(shot -> BackdropDoc.photoOf(shot#photo, w#docs#backdrops))
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
    def autosave(mark: Option[Saves.Mark], r: World.Read, w: World.World): World.World =
        let node = YarnRunner.nodeOf(r#talk);
        if (Option.isEmpty(node) or node == r#autosavedNode) World.withRead(r, w)
        else match slotAt(mark, r, w) {
            case Some(slot) =>
                World.withSaves(Saves.withPushed(Saves.Tab.Auto, slot, w#saves), World.withRead({ autosavedNode = node | r }, w))
            case None => World.withRead(r, w)
        }

    // ── 戻れる所へ戻す ──

    /// 戻れる所へ戻す: ブックマークを当て直し、通ったコマンドを音を出さずに反映して舞台と頁とバックログを作り直す。
    /// 前のノードから持ち越す背景・環境音・パーティクル・文章の出し方は Mark の値から始め、背景の重ねや揺れの途中は終わりの形にする。
    /// 画面と確認のウィンドウは閉じる。[遷移: Title / Reading→Reading]
    pub def restore(mark: Saves.Mark, w: World.World): World.World \ Emit[World.Event] =
        let carried = { shot = mark#shot, ambience = mark#ambience, particles = mark#particles, mode = mark#mode | Stage.empty() };
        let (talk, events) = YarnRunner.resume(w#docs#dialogue, mark#bookmark, World.now(w));
        settled(absorb(Replay.Silent, events, { talk = talk, stage = carried | World.emptyRead() },
                       { panel = World.Panel.Closed, ask = None | w }))

    /// 当て直した後の形: 演出の途中は終わりの形にし、今のノードはオートセーブ済みとして扱う（戻った所で同じ物を残さない）。
    def settled(w: World.World): World.World =
        World.mapRead(r -> { stage = Stage.settle(r#stage), autosavedNode = YarnRunner.nodeOf(r#talk) | r }, w)

    /// セーブの枠のサムネに映す画面: その枠の戻れる所へ音を出さずに戻した World（文は出し終え、画面・確認のウィンドウは閉じ、マウスはどこにも乗せない）。
    /// WhyNot: 保存の時に画面の絵を撮って残さない —— セーブの JSON に絵を入れると重く、描き出しと実機で同じ絵にならない。
    pub def screenOf(mark: Saves.Mark, w: World.World): World.World =
        let (back, _) = Emit.collect(() -> restore(mark, w));
        World.withPointer({ x = -1.0, y = -1.0 }, back)

    // ── 始まりの場面（Starts・描き出し） ──

    /// node の頭から、.yarn の line 行を出している所まで進めた World（Studio の会話のプレビュー・bin/fge talk goto）。
    /// 通ったコマンドは音を出さずに反映し、演出の途中は終わりの形にする。
    pub def openAt(storage: YarnStorage.Storage, node: String, line: Int32, w: World.World): World.World \ Emit[World.Event] =
        let (talk, events) = YarnRunner.startAtWith(storage, w#docs#dialogue, node, line, World.now(w));
        settled(absorb(Replay.Silent, events, { talk = talk | World.emptyRead() }, { panel = World.Panel.Closed, ask = None | w }))

    /// 今の行を出し終えた形（描き出しが場面を作る時。時計を進めずに 1 行読み終える）。
    pub def revealLine(w: World.World): World.World = World.mapRead(r -> { page = Page.revealAll(r#page) | r }, w)

    /// シナリオの差し替え（保存即反映）。読んでいる途中なら、開いているノードの頭から読み直す（編集がその場で画面に出る）。
    /// WhyNot: 読んでいた行から続けない —— 行の並びが変わると「同じ行」が決まらない。
    pub def withDialogue(dialogue: Yarn.Program, w: World.World): World.World =
        let w1 = { docs = { dialogue = dialogue | w#docs } | w };
        match World.readOf(w1) {
            case Some(r) =>
                match YarnRunner.nodeOf(r#talk) {
                    case Some(node) if Option.nonEmpty(Yarn.nodeOf(node, dialogue)) =>
                        let (talk, events) = YarnRunner.startWith(YarnRunner.storageOf(r#talk), dialogue, node, World.now(w1));
                        fst(Emit.collect(() -> absorb(Replay.Silent, events, { talk = talk, page = Page.empty(), choices = Nil | r }, w1)))
                    case Some(_) => World.toTitle(w1)
                    case None    => w1
                }
            case None => w1
        }
}
