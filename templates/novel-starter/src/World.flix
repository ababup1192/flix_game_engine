// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 文章・分岐・結末はシナリオ assets/talk/novel.yarn（YarnRunner が辿る）、進め方と「疑うと灯りが消える」規則はここ。
// 表紙（Title）→ 物語（Story）→ 結末のノードを読み終えたら表紙へ戻る。プレイヤーは死なない。
//
// 場面の移り変わり（Phase と、Story の中のシナリオの流れ）:
//
//     Title ──決定(advance/begin)──▶ Story（Talk.Node.Arrival のノードを開く）
//                                      │  台詞を順に読む(advance → YarnRunner の Advance)
//                                      ▼
//                                  選択肢 ──選ぶ(pick → Choose)──▶ その中身（<<jump>> で次のノード）
//                                                              │
//     Title ◀────ノードを読み終えた・シナリオが切れた(toTitle)────┘
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// Doc が壊れていても止まらない（fail-open の 3 段階）:
//   読めない → 既定値で起動（Controls.loadDocs / *Doc.defaults）
//   一部が欠け → その欄だけ既定値（fromJson が欄ごとに拾う）
//   型が違う   → その欄は既定値のまま（行き先の節が無ければ表紙へ落ちる 等）
// だからプレイヤーの前でクラッシュしない。Doc の編集ミスは既定へ落ちて読みは続く（シナリオの書き損じは build の check が止める）。
//
// 時計は 2 本（型で分けてあり、取り違えるとコンパイルが止まる）:
//   物語の時計 storyClock（Clock[Story]）… 文字送りと灯りが消える演出。メニューの間は止まる。
//                                          進めるのは App だけ（Main の App.addClock・進み方は paceOf）。
//   実時間 realNow（Time[Clock.Real]）     … 雨・炎の揺らぎ・埃・メニューの字の点滅。止まらない。
//                                          App が配る frame#realNow を Controls.step が毎フレーム写す。
mod World {

    use fge::{Clock, Emit, PxSpriteAtlas, PxSpriteDoc, UiDialog, UiMenu, UiSlots, UiSpec, UiStore, Yarn, YarnRunner, YarnStorage}

    /// 物語の時計の名前（中身は要らない）。
    pub enum Story

    /// 開いている窓。Open = メニュー（物語の時計を止める・物語の入力を受けない）。
    pub enum Menu with Eq, ToString {
        case Closed
        case Open
    }

    /// 物語の時計を止める理由。
    pub enum Halt with Eq {
        case MenuOpen
    }

    /// いま画面が何をしているか。Title = 表紙（決定で物語がはじまる）、Story = シナリオを読んでいる。
    pub enum Phase with Eq, ToString {
        case Title
        case Story
    }

    /// 決定・カーソルで起きた出来事（返事の音の材料）。規則の中で Emit.emit し、
    /// Controls.interact が集めて events 欄（Emit.Events）に溜め、音は前後の差（Emit.since）で読む。
    ///   Opened   … 表紙から物語をはじめた。
    ///   Revealed … 文字送りの途中で全文を出した。
    ///   Paged    … 次の台詞へ送った。
    ///   Ended    … 結末を読み終えて表紙へ戻った。
    ///   Moved    … 選択肢のカーソルが動いた。
    ///   Picked   … 選択肢を選んだ（true = 疑う選択）。
    pub enum Event with Eq, ToString {
        case Opened
        case Revealed
        case Paged
        case Ended
        case Moved
        case Picked(Bool)
    }

    /// 起動時に読む Doc の束（Main と SceneRender が同じ形で組む）。
    pub type alias Docs = {
        story = StoryDoc.Doc,
        dialogue = Yarn.Program,
        kind = KindDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc
    }

    /// ゲームの状態。dialogue = シナリオ、talk = シナリオの現在地（開いているノード・今出している台詞か選択肢）、
    /// kit = ダイアログと選択肢（文字送り）、
    /// cursor = 選択肢のカーソル位置、lightsOut = 消えた灯りの数（疑うたびに増える）、
    /// storyClock / realNow = 物語の時計と実時間の今（冒頭の「時計は 2 本」）、menu = 開いている窓。
    pub type alias World = {
        phase = Phase,
        story = StoryDoc.Doc,
        dialogue = Yarn.Program,
        kind = KindDoc.Doc,
        keys = KeysDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        // ドット絵を 1 枚にまとめたアトラスと、その画素から導いた鍵（下の bakedOf を参照）。
        atlas = PxSpriteAtlas.Baked,
        atlasKey = String,
        storyClock = Clock.Clock[Story],
        realNow = Clock.Time[Clock.Real],
        menu = Menu,
        talk = YarnRunner.Runner[Story],
        kit = NovelKit.Kit,
        cursor = Int32,
        lightsOut = Int32,
        // 最後に灯りが消えた物語の時刻（灯りが消える演出 LampFx の起点）。
        lampOutAt = Option[Clock.Time[Story]],
        events = Emit.Events[Event],
        ui = UiStore.UiWorld,
        docError = Option[String]
    }

    // ── 盤の寸法（design 480×300 の中の定数。project.json と同じ値） ──

    pub def width(): Float64 = 480.0
    pub def height(): Float64 = 300.0

    pub def spritePath(): String = "assets/novel.sprite.json"

    /// GPU に登録するアトラスの論理名（View の drawQuad と Main の withSpriteAtlases が
    /// この名前で待ち合わせる）。
    pub def atlasName(): String = "px"

    /// ドット絵を 1 枚のアトラスにまとめ、GPU キャッシュ用の鍵と対で返す。
    ///
    /// **なぜまとめるか**: 画面に出すとき 1 コマ = 1 クアッドで貼れる（PxSprite.drawQuad）。
    /// まとめずに描く PxSprite.draw は 1 コマを画素ぶんの四角に開くので、額縁 1 枚でも
    /// 毎フレーム百個規模の四角を組み直すことになる（予算と検査は engine の
    /// docs/performance.md §9）。まとめるのは読み込みの 1 回だけ。
    ///
    /// **なぜ鍵に画素のハッシュを混ぜるか**: Doc や色票を保存し直して絵が変わったとき、
    /// 鍵が同じままだと GPU に古いテクスチャが残って画面が更新されない。
    def bakedOf(theme: ThemeDoc.Doc, sprites: PxSpriteDoc.Doc): (PxSpriteAtlas.Baked, String) =
        let baked = PxSpriteAtlas.bake(sprites, key -> ThemeDoc.resolver(theme, key));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        (baked, "${atlasName()}:${Int32.toString(baked#side)}:${Int32.toString(h)}")

    /// ゲーム開始時の状態。表紙から始まり、灯りは全部ついている。
    pub def initial(docs: Docs, ui: UiStore.UiWorld): World =
        let (baked, key) = bakedOf(docs#theme, docs#sprites);
        { phase = Phase.Title,
          story = docs#story, dialogue = docs#dialogue, kind = docs#kind, keys = docs#keys, theme = docs#theme, sprites = docs#sprites,
          atlas = baked, atlasKey = key,
          storyClock = Clock.start(), realNow = Clock.zero(), menu = Menu.Closed,
          talk = YarnRunner.closed(),
          kit = NovelKit.closed(), cursor = 0, lightsOut = 0,
          lampOutAt = None, events = Emit.empty(),
          ui = ui, docError = None }

    /// いまついている灯りの数（消えた分を引いた残り。負にはならない）。
    pub def lampsLit(w: World): Int32 =
        Int32.max(0, StoryDoc.rec(w#story)#lamps - w#lightsOut)

    // ── 進行の規則 ──

    /// 表紙から物語をはじめる。灯りは全部つき直る（新しい夜）。[遷移: Title→Story]
    def begin(w: World): World \ Emit[Event] =
        Emit.emit(Event.Opened);
        openTalk(Talk.nodeName(Talk.Node.Arrival), reading(w))

    /// 表紙から物語へ入った World（灯りは全部点いている。読むノードは openTalk が載せる）。
    pub def reading(w: World): World = { phase = Phase.Story, lightsOut = 0, lampOutAt = None | w }

    /// 表紙へ戻る（結末を読み終えた・シナリオが切れた）。部屋の暗さはそのまま残り、
    /// 次に begin したとき灯り直す。[遷移: Story→Title]
    /// メニューも閉じる — シナリオの読み直しでノードが消えると、メニューを開いたまま表紙へ落ちうる
    /// （表紙ではメニューを開け閉めできないので、閉じないと物語の時計が止まったまま詰む）。
    def toTitle(w: World): World =
        { phase = Phase.Title, talk = YarnRunner.closed(), kit = NovelKit.closed(), menu = Menu.Closed | w }

    /// node の頭から読む。シナリオが読めずノードが無ければ、直し方を語る 1 行を出す（読み終えると表紙へ）。
    pub def openTalk(node: String, w: World): World =
        match Yarn.nodeOf(node, w#dialogue) {
            case Some(_) => show(fst(YarnRunner.start(w#dialogue, node, Clock.nowOf(w#storyClock))), w)
            case None    =>
                { talk = YarnRunner.closed(),
                  kit = NovelKit.say("", "（シナリオが読めない。assets/talk/novel.yarn を直して bin/fge yarn build assets/talk を流すと、ここに物語が流れる）") | w }
        }

    /// node の頭から、シナリオの line 行（.yarn の行番号）を出している所まで進めて読む（文字送りは使い切る）。
    /// 変数は storage の値から流す（<<if>> の枝の中の行を出す時）。
    /// 始まり `talk node=… line=… $名前=値`（Studio の会話のプレビュー・bin/fge talk goto）が使う。
    pub def openTalkAt(storage: YarnStorage.Storage, node: String, line: Int32, w: World): World =
        match Yarn.nodeOf(node, w#dialogue) {
            case Some(_) => revealLine(show(fst(YarnRunner.startAtWith(storage, w#dialogue, node, line, Clock.nowOf(w#storyClock))), w))
            case None    => openTalk(node, w)
        }

    /// 実行器が今出している物をキットに乗せる。[遷移: 台詞→次の台詞 / 選択肢 / 結末(Story→Title)]
    /// 選択肢の直前の台詞は、送るのを待たずに選択肢と同じウィンドウへ問いとして並べる。
    def show(talk: YarnRunner.Runner[Story], w: World): World =
        match YarnRunner.shownOf(talk) {
            case YarnRunner.Shown.Line(line) =>
                if (YarnRunner.choicesFollow(talk))
                    askAfter(line, fst(YarnRunner.step(YarnRunner.Action.Advance, Clock.nowOf(w#storyClock), talk)), w)
                else { talk = talk, kit = NovelKit.say(StoryDoc.nameOf(line#speaker, w#story), line#text) | w }
            case YarnRunner.Shown.Choices(options) =>
                { talk = talk, cursor = 0, kit = NovelKit.ask("", "", entriesOf(options)) | w }
            case YarnRunner.Shown.Waiting => { talk = talk | w }
            case YarnRunner.Shown.Closed  => toTitle({ talk = talk | w })
        }

    def askAfter(question: Yarn.Line, talk: YarnRunner.Runner[Story], w: World): World =
        match YarnRunner.shownOf(talk) {
            case YarnRunner.Shown.Choices(options) =>
                { talk = talk, cursor = 0,
                  kit = NovelKit.ask(StoryDoc.nameOf(question#speaker, w#story), question#text, entriesOf(options)) | w }
            case _ => show(talk, w)
        }

    /// 選択肢の行を UI のスロット項目へ（クリックの意味は meta: novel/choice/N）。
    /// 選べない選択肢（行末の <<if>> が偽）は meta を付けない — カーソルとクリックの列から外れ、キットが灰色で描く。
    def entriesOf(options: List[YarnRunner.DialogueOption]): List[UiSlots.Entry] =
        options |> List.zipWithIndex |> List.map(pair -> {
            let (i, option) = pair;
            ({ text = option#line#text, meta = if (option#available) Some("${NovelKit.choicePrefix()}${i}") else None }: UiSlots.Entry)
        })

    /// 決定 1 回分。表紙では物語をはじめ［遷移: Title→Story］、文字送り中なら全文へ、
    /// 読み終えていれば次の台詞へ（Story のまま実行器を送る）。
    /// 選択肢待ちは動かない（pick だけが進める）。
    pub def advance(w: World): World \ Emit[Event] =
        match w#phase {
            case Phase.Title => begin(w)
            case Phase.Story =>
                if (NovelKit.isAsking(w#kit)) w
                else if (not UiDialog.lineDone(w#kit#dialog)) {
                    Emit.emit(Event.Revealed);
                    { kit = NovelKit.advance(w#kit) | w }
                } else {
                    let next = if (YarnRunner.isOpen(w#talk))
                        show(fst(YarnRunner.step(YarnRunner.Action.Advance, Clock.nowOf(w#storyClock), w#talk)), w)
                    else toTitle(w);
                    Emit.emit(if (next#phase == Phase.Title) Event.Ended else Event.Paged);
                    next
                }
        }

    /// 選択肢カーソルを delta ぶん動かす（端で反対側へ回り込む）。
    pub def moveCursor(delta: Int32, w: World): World \ Emit[Event] =
        let count = UiMenu.count(NovelKit.choicesPath(), w#ui);
        let cursor = UiMenu.moveCursor(delta, count, w#cursor);
        if (cursor != w#cursor) Emit.emit(Event.Moved) else ();
        { cursor = cursor | w }

    /// 選択肢 i を選ぶ: 「疑う」選択（#suspect）なら館の灯りをひとつ消してから、その中身へ。
    /// [遷移: 選択肢→選んだ中身（<<jump>> の先のノード）]
    /// 選べない選択肢の番号なら何もしない（灯りも消さない）。
    pub def pick(i: Int32, w: World): World \ Emit[Event] =
        match currentOptions(w) |> List.nth(i) {
            case Some(option) if option#available =>
                let suspect = Talk.isSuspect(option#line);
                Emit.emit(Event.Picked(suspect));
                let dimmed = dimIf(suspect, w);
                show(fst(YarnRunner.step(YarnRunner.Action.Choose(i), Clock.nowOf(w#storyClock), w#talk)), dimmed)
            case _ => w
        }

    /// キーボードのカーソル（選べる選択肢だけを数えた位置）の選択肢を選ぶ。
    pub def pickAtCursor(cursor: Int32, w: World): World \ Emit[Event] =
        let open = currentOptions(w) |> List.zipWithIndex |> List.filter(match (_, option) -> option#available) |> List.map(fst);
        match List.nth(cursor, open) {
            case Some(i) => pick(i, w)
            case None    => w
        }

    /// 疑ったときだけ灯りをひとつ消す（novel.story.json の lamps より多くは消えない）。
    /// 消せる灯りが残っていなければ何もしない（演出の起点 lampOutAt も動かさない）。
    def dimIf(suspect: Bool, w: World): World =
        if (suspect and lampsLit(w) > 0)
            { lightsOut = w#lightsOut + 1, lampOutAt = Some(Clock.nowOf(w#storyClock)) | w }
        else w

    /// node を読み終えて選択肢が開き、問いの文を出し終えた World（選択肢の前に会話が終わるノードは None）。
    /// 始まりの登録簿（Starts）が使う。fuel は台詞の無いノードが続く壊れたシナリオでも必ず止まるための上限。
    pub def openAtChoices(node: String, w: World): Option[World] =
        choicesFrom(200, fst(YarnRunner.start(w#dialogue, node, Clock.nowOf(w#storyClock))), w)

    def choicesFrom(fuel: Int32, talk: YarnRunner.Runner[Story], w: World): Option[World] =
        match YarnRunner.shownOf(talk) {
            case YarnRunner.Shown.Line(_) if YarnRunner.choicesFollow(talk) => Some(revealLine(show(talk, w)))
            case YarnRunner.Shown.Choices(_) => Some(revealLine(show(talk, w)))
            case YarnRunner.Shown.Line(_) if fuel > 0 =>
                choicesFrom(fuel - 1, fst(YarnRunner.step(YarnRunner.Action.Advance, Clock.nowOf(w#storyClock), talk)), w)
            case _ => None
        }

    /// 開いているノードの名前（閉じていれば空。flow の問い talk・指紋・1 行の要点）。
    pub def talkNodeOf(w: World): String = YarnRunner.nodeOf(w#talk) |> Option.getWithDefault("")

    /// 今出している台詞のシナリオの行（ファイル:行。選択肢の間は先頭の選択肢の行・閉じていれば空）。
    pub def talkLineOf(w: World): String = match YarnRunner.shownOf(w#talk) {
        case YarnRunner.Shown.Line(line)     => Yarn.sourceText(line#source)
        case YarnRunner.Shown.Choices(options) => options |> List.head |> Option.map(option -> Yarn.sourceText(option#line#source)) |> Option.getWithDefault("")
        case _                               => ""
    }

    def currentOptions(w: World): List[YarnRunner.DialogueOption] = match YarnRunner.shownOf(w#talk) {
        case YarnRunner.Shown.Choices(options) => options
        case _                               => Nil
    }

    /// 毎フレーム: シナリオの <<wait>> の時刻が来ていれば続きを出し、文字送りを物語の時計がこのフレームに
    /// 進んだ秒だけ進め、キットの状態を UI へ刻む（表紙ではダイアログは閉じている）。
    /// メニューの間は物語の時計が止まるので、待ちも文字送りも止まる。
    pub def step(w: World): World =
        let waited = match YarnRunner.shownOf(w#talk) {
            case YarnRunner.Shown.Waiting => show(fst(YarnRunner.step(YarnRunner.Action.Tick, Clock.nowOf(w#storyClock), w#talk)), w)
            case _                        => w
        };
        let kit = NovelKit.step(cps = KindDoc.rec(waited#kind)#cps, Clock.dtOf(waited#storyClock), waited#kit);
        { kit = kit, ui = NovelKit.apply(kit, waited#ui) | waited }

    /// いまの行を最後まで出した状態（描き出しが場面を歩くとき。時計を進めずに 1 行読み終える）。
    pub def revealLine(w: World): World =
        let kit = if (UiDialog.lineDone(w#kit#dialog)) w#kit else NovelKit.advance(w#kit);
        { kit = kit, ui = NovelKit.apply(kit, w#ui) | w }

    /// 物語の時計のこのフレームの進み方（Main の App.addClock が読む）。止める理由はメニューだけ。
    pub def paceOf(w: World): Clock.Pace[Story, Halt] = match w#menu {
        case Menu.Closed => Clock.paceOf(Clock.Run.Running)
        case Menu.Open   => Clock.paceOf(Clock.Run.Paused(Halt.MenuOpen))
    }

    /// メニューを開く・閉じる。開けるのは物語の途中だけ（表紙には止める物語が無い）。
    /// [遷移: メニュー Closed⇄Open（Story の中）]
    pub def toggleMenu(w: World): World = match (w#phase, w#menu) {
        case (Phase.Title, _)           => w
        case (Phase.Story, Menu.Closed) => { menu = Menu.Open | w }
        case (Phase.Story, Menu.Open)   => { menu = Menu.Closed | w }
    }

    // ── Doc の差し替え（保存即反映） ──

    /// 表紙の文言・灯りの数・呼び名の差し替え（呼び名は次の台詞から出る）。
    pub def withStory(story: StoryDoc.Doc, w: World): World = { story = story | w }

    /// シナリオの差し替え。物語の途中なら、開いているノードを頭から読み直す（編集がその場で画面に出る）。
    /// WhyNot: 読んでいた行から続けない —— 行の並びが変わると「同じ行」が決まらない。
    /// 開いていたノードが消えていたら直し方の 1 行へ落ちる（fail-open）。
    pub def withDialogue(dialogue: Yarn.Program, w: World): World =
        let w1 = { dialogue = dialogue | w };
        match (w1#phase, YarnRunner.nodeOf(w1#talk)) {
            case (Phase.Story, Some(node)) => openTalk(node, w1)
            case _                         => w1
        }

    pub def withKind(kind: KindDoc.Doc, w: World): World = { kind = kind | w }

    /// 色か絵が変わったら、アトラスも作り直す（色は絵の中の意味色キーを解く材料なので、
    /// テーマだけ替えても作った画素は変わる）。
    pub def withTheme(theme: ThemeDoc.Doc, w: World): World =
        let (baked, key) = bakedOf(theme, w#sprites);
        { theme = theme, atlas = baked, atlasKey = key | w }

    pub def withSprites(sprites: PxSpriteDoc.Doc, w: World): World =
        let (baked, key) = bakedOf(w#theme, sprites);
        { sprites = sprites, atlas = baked, atlasKey = key | w }

    /// F1 リロード: ui.json を読み直す。失敗した分は元の表示のまま残し、
    /// エラー文字列を画面に出す（直して F1 で消える）。
    pub def reloadUi(w: World): World \ Fs.FileRead =
        let (ui2, errs) = UiSpec.reloadAllWithReport(w#ui);
        let msgs = errs |> List.map(entry -> { let (rootName, msg) = entry; "${rootName}: ${msg}" });
        { ui = ui2,
          docError = if (List.isEmpty(msgs)) None else Some(String.intercalate(" / ", msgs))
          | w }
}
