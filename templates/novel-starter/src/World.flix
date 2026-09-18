// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 台本（文章・分岐・結末）は StoryDoc の rows、進め方と「疑うと灯りが消える」規則はここ。
// 表紙（Title）→ 物語（Story）→ 結末の節を読み終えたら表紙へ戻る。プレイヤーは死なない。
//
// 場面の移り変わり（Phase と、Story の中の台本の流れ）:
//
//     Title ──決定(advance/begin)──▶ Story
//                                      │  節の beats を順に読む(advance)
//                                      ▼
//                                  ask あり ──選ぶ(pick)──▶ goto の節へ(enter)
//                                  ask なし ──▶ next の節へ / next 空なら結末
//                                                              │
//     Title ◀──────結末を読み終えた・台本が切れた(toTitle)──────┘
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// Doc が壊れていても止まらない（fail-open の 3 段階）:
//   読めない → 既定値で起動（Controls.loadDocs / *Doc.defaults）
//   一部が欠け → その欄だけ既定値（fromJson が欄ごとに拾う）
//   型が違う   → その欄は既定値のまま（行き先の節が無ければ表紙へ落ちる 等）
// だからプレイヤーの前でクラッシュしない。台本の編集ミスは既定へ落ちて読みは続く。
mod World {

    /// いま画面が何をしているか。Title = 表紙（決定で物語がはじまる）、Story = 台本を読んでいる。
    pub enum Phase with Eq, ToString {
        case Title
        case Story
    }

    /// 起動時に読む Doc の束（Main と SceneRender が同じ形で組む）。
    pub type alias Docs = {
        story = StoryDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc
    }

    /// ゲームの状態。section / idx = 台本上の現在地、kit = ダイアログと選択肢、
    /// cursor = 選択肢のカーソル位置、lightsOut = 消えた灯りの数（疑うたびに増える）、
    /// t = 起動からの積み上げ秒（雨・炎の揺らぎ・埃が見る。読んでいる間も部屋を止めない）。
    pub type alias World = {
        phase = Phase,
        story = StoryDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        // ドット絵を 1 枚にまとめたアトラスと、その画素から導いた鍵（下の bakedOf を参照）。
        atlas = PxSpriteAtlas.Baked,
        atlasKey = String,
        t = Float64,
        section = String,
        idx = Int32,
        kit = NovelKit.Kit,
        cursor = Int32,
        lightsOut = Int32,
        ui = UiStore.UiWorld,
        docError = Option[String],
        activeDocsWritten = String
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
          story = docs#story, kind = docs#kind, theme = docs#theme, sprites = docs#sprites,
          atlas = baked, atlasKey = key,
          t = 0.0, section = StoryDoc.rec(docs#story)#start, idx = 0,
          kit = NovelKit.closed(), cursor = 0, lightsOut = 0,
          ui = ui, docError = None, activeDocsWritten = "" }

    /// いまついている灯りの数（消えた分を引いた残り。負にはならない）。
    pub def lampsLit(w: World): Int32 =
        Int32.max(0, StoryDoc.rec(w#story)#lamps - w#lightsOut)

    // ── 進行の規則 ──

    /// 表紙から物語をはじめる。灯りは全部つき直る（新しい夜）。[遷移: Title→Story]
    def begin(w: World): World =
        enter(StoryDoc.rec(w#story)#start, 0, { phase = Phase.Story, lightsOut = 0 | w })

    /// 表紙へ戻る（結末を読み終えた・台本が切れた）。部屋の暗さはそのまま残り、
    /// 次に begin したとき灯り直す。[遷移: Story→Title]
    def toTitle(w: World): World =
        { phase = Phase.Title, kit = NovelKit.closed() | w }

    /// 台本の (section, idx) のビートをキットに乗せる。ビートを読み終えた節は
    /// ask（分岐）→ next（次の節）→ どちらも無ければ結末 = 表紙へ、の順に出口を選ぶ。
    /// [遷移: 節→次のビート / 次の節 / 結末(Story→Title)]
    /// fuel は空の節が連なる壊れた台本でも必ず止まるための上限。
    pub def enter(sectionId: String, idx: Int32, w: World): World =
        enterFuel(8, sectionId, idx, w)

    def enterFuel(fuel: Int32, sectionId: String, idx: Int32, w: World): World =
        if (fuel <= 0) toTitle(w)
        else match StoryDoc.sectionOf(sectionId, w#story) {
            case None => toTitle(w)
            case Some(section) =>
                match List.nth(idx, section#beats) {
                    case Some(beat) =>
                        { section = sectionId, idx = idx,
                          kit = NovelKit.say(beat#speaker, beat#text) | w }
                    case None => leave(fuel, sectionId, idx, section, w)
                }
        }

    /// ビートを読み終えた節の出口。
    def leave(fuel: Int32, sectionId: String, idx: Int32, section: StoryDoc.Section, w: World): World =
        match section#ask {
            case Some(ask) =>
                { section = sectionId, idx = idx, cursor = 0,
                  kit = NovelKit.ask(ask#speaker, ask#text, entriesOf(ask#options)) | w }
            case None =>
                if (section#next == "") toTitle(w)
                else enterFuel(fuel - 1, section#next, 0, w)
        }

    /// 選択肢の rows を UI のスロット項目へ（クリックの意味は meta: novel/choice/N）。
    def entriesOf(options: List[StoryDoc.Choice]): List[UiSlots.Entry] =
        options |> List.zipWithIndex |> List.map(pair -> {
            let (i, choice) = pair;
            ({ text = choice#label, meta = Some("${NovelKit.choicePrefix()}${i}") }: UiSlots.Entry)
        })

    /// 決定 1 回分。表紙では物語をはじめ［遷移: Title→Story］、文字送り中なら全文へ、
    /// 読み終えていれば次のビートへ（Story のまま enter で進む）。
    /// 選択肢待ちは動かない（pick だけが進める）。
    pub def advance(w: World): World =
        match w#phase {
            case Phase.Title => begin(w)
            case Phase.Story =>
                if (NovelKit.isAsking(w#kit)) w
                else if (not UiDialog.lineDone(w#kit#dialog))
                    { kit = NovelKit.advance(w#kit) | w }
                else enter(w#section, w#idx + 1, w)
        }

    /// 選択肢カーソルを delta ぶん動かす（端で反対側へ回り込む）。
    pub def moveCursor(delta: Int32, w: World): World =
        let count = UiMenu.count(NovelKit.choicesPath(), w#ui);
        { cursor = UiMenu.moveCursor(delta, count, w#cursor) | w }

    /// 選択肢 i を選ぶ: 「疑う」選択（suspect）なら館の灯りをひとつ消してから、
    /// 行き先の節の先頭へ。[遷移: 分岐→goto の節]
    pub def pick(i: Int32, w: World): World =
        match currentOptions(w) |> List.nth(i) {
            case None => w
            case Some(choice) => enter(choice#goto, 0, dimIf(choice#suspect, w))
        }

    /// 疑ったときだけ灯りをひとつ消す（台本の lamps より多くは消えない）。
    def dimIf(suspect: Bool, w: World): World =
        if (suspect)
            { lightsOut = Int32.min(StoryDoc.rec(w#story)#lamps, w#lightsOut + 1) | w }
        else w

    def currentOptions(w: World): List[StoryDoc.Choice] =
        StoryDoc.sectionOf(w#section, w#story)
            |> Option.flatMap(section -> section#ask)
            |> Option.map(ask -> ask#options)
            |> Option.getWithDefault(Nil)

    /// 毎フレーム: 文字送りを進め、キットの状態を UI へ刻む（表紙ではダイアログは閉じている）。
    /// 毎フレーム: 文字送りを進め、時計を進める。時計は場面を問わず進む —
    /// 読んでいる間も表紙でも、雨は降り炎は揺れる（動かない絵は止まって見える）。
    pub def step(dt: Float64, w: World): World =
        let kit = NovelKit.step(cps = KindDoc.rec(w#kind)#cps, dt, w#kit);
        { kit = kit, ui = NovelKit.apply(kit, w#ui), t = w#t + dt | w }

    // ── Doc の差し替え（保存即反映） ──

    /// 台本の差し替え。物語の途中なら現在地を読み直す（編集がその場で画面に出る）。
    /// 現在地の節が消えていたら表紙へ落ちる（fail-open）。
    pub def withStory(story: StoryDoc.Doc, w: World): World =
        let w1 = { story = story | w };
        match w1#phase {
            case Phase.Title => w1
            case Phase.Story => enter(w1#section, w1#idx, w1)
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
