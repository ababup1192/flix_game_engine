// World — ゲームの状態そのものと、次の状態を作る規則（すべて純粋）。
// 見下ろしの里を 1 マスずつ歩き、住人に話しかけ、薬草を拾う。
// 扉の鍵は物ではなく約束 — 頼まれた数の薬草を持って約束の相手と話すと扉が開く。
// 盤面のデータ（rows・配置・文言）は MapDoc、手触りは KindDoc — 実行中の状態はこの World だけが持つ。
//
// 場面の移り変わり（Phase）:
//
//     Title ──決定(confirm/begin)──▶ Play ──薬草が goal 個(pickUp)──▶ Clear
//       ▲                                                                │
//       └─────────────────────決定(confirm)──────────────────────────────┘
//
// 遷移を起こす関数の doc には [遷移: X→Y] を付けてある（探すときの目印）。
//
// Doc が壊れていても止まらない（fail-open の 3 段階）:
//   読めない → 既定値で起動（Controls.loadDocs / *Doc.defaults）
//   一部が欠け → その欄だけ既定値（fromJson が欄ごとに拾う）
//   型が違う   → その欄は既定値のまま（数を入れる欄に文字 等）
// だからプレイヤーの前でクラッシュしない。編集ミスは既定へ落ちて遊びは続く。
mod World {

    /// いま画面が何をしているか。Title = 表紙（決定で歩き出す）、Play = 里を歩いている、
    /// Battle = 魔物と向き合っている、Clear = 薬草がそろった（決定で表紙へ戻る）。
    pub enum Phase with Eq, ToString {
        case Title
        case Play
        case Battle
        case Clear
    }

    /// 戦いのどのフェーズか。Choosing = コマンドを選んでいる、Report = 打ち合いの結果を読んでいる
    /// （決定でつぎの番へ）、Done = 決着（決定で里へ戻る）。
    pub enum BattleStep with Eq, ToString {
        case Choosing
        case Report
        case Done
    }

    /// 戦いの終わり方。
    pub enum Outcome with Eq, ToString {
        case Win
        case Lose
        case Flee
    }

    /// いま戦っている 1 回ぶん。主人公の体力は戦いをまたいで残るので World 側が持ち、
    /// ここには「この戦いの中だけの物」を置く。
    ///   step … いまどのフェーズか。cursor … 選んでいるコマンド（0 = たたかう / 1 = にげる）。
    ///   foeHp … 魔物の残り体力。lines … 下のウィンドウに出す文（上から順）。
    ///   foeHurt … 魔物が殴られたコマを出すか。outcome … 決着（まだなら None）。
    pub type alias Battle = {
        step = BattleStep,
        cursor = Int32,
        foeHp = Int32,
        lines = List[String],
        foeHurt = Bool,
        outcome = Option[Outcome]
    }

    /// 起動時に読む Doc の束（Main と SceneRender が同じ形で組む）。
    pub type alias Docs = {
        map = MapDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        battle = BattleDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        townSprites = PxSpriteDoc.Doc,
        townMap = TownMapDoc.Doc,
        waterShader = ShaderDoc.Spec,
        smokeFx = FxDoc.Spec
    }

    /// ゲームの状態。hero / facing = 主人公のマスと向き、stepGauge = 次の一歩までの残り秒、
    /// steps = 歩いた歩数（歩きのコマ送りに使う）、herbs = まだ拾っていない薬草のマス、
    /// picked = 拾った薬草の数、doorOpen = 扉が開いたか、
    /// dialog = ふきだし（開いている間は歩けない）、talkingTo = 話し相手のマス（ふきだしの位置）。
    /// t = 起動からの積み上げ秒（場面に関係なく進む — 待っている画面でも絵を止めないため）。
    /// heroHp = 主人公の残り体力（戦いをまたいで残る）。battle = いま戦っている 1 回ぶん。
    pub type alias World = {
        map = MapDoc.Doc,
        kind = KindDoc.Doc,
        theme = ThemeDoc.Doc,
        battleDoc = BattleDoc.Doc,
        sprites = PxSpriteDoc.Doc,
        townSprites = PxSpriteDoc.Doc,
        townMap = TownMapDoc.Doc,
        townAtlas = PxSpriteAtlas.Baked,
        townAtlasKey = String,
        charAtlas = PxSpriteAtlas.Baked,
        charAtlasKey = String,
        tileSpec = TileLayerSpec,
        bridgeCells = List[Grid.Cell],
        waterRect = Option[Rect2.Rect2],
        waterMaskRects = List[Rect2.Rect2],
        waterShader = ShaderDoc.Spec,
        smokeFx = FxDoc.Spec,
        phase = Phase,
        npcClock = Float64,
        t = Float64,
        hero = Grid.Cell,
        facing = Dir4.Dir4,
        stepGauge = Float64,
        steps = Int32,
        herbs = List[Grid.Cell],
        picked = Int32,
        doorOpen = Bool,
        heroHp = Int32,
        battle = Battle,
        dialog = UiDialog.Dialog,
        talkingTo = Option[Grid.Cell],
        activeDocsWritten = String
    }

    // ── 画面と盤の寸法（design 320×240 は project.json と同じ値。盤は design より広く、
    //    camera が主人公を追ってスクロールする） ──

    pub def width(): Float64 = 320.0
    pub def height(): Float64 = 240.0

    /// タイルの 1 辺（px）。画面には 20×15 マスぶんが見える。
    pub def tileSize(): Float64 = 16.0

    /// 盤全体の world 矩形（camera の bounds）。盤原点は (0,0) 固定 —
    /// 盤が design より大きいので中央寄せはせず、world 座標 = マス×16 にする。
    pub def boardRect(w: World): Rect2.Rect2 =
        { position = { x = 0.0, y = 0.0 },
          size = { x = Int32.toFloat64(MapDoc.cols(w#map)) * tileSize(),
                   y = Int32.toFloat64(MapDoc.rowCount(w#map)) * tileSize() } }

    /// camera の中心。里（表紙・クリアの幕の下も含む）では主人公のマス中心を追い、
    /// 戦い（盤を映さない画面）では design の中央に固定してずらしを消す —
    /// 戦いの絵は画面座標のまま world 側に組んであるため。
    pub def cameraCenter(w: World): Vec2.Vec2 =
        match w#phase {
            case Phase.Battle => { x = width() / 2.0, y = height() / 2.0 }
            case _            => Grid.cellCenterOf(tileSize(), w#hero)
        }

    /// 人と物の絵の Doc。街の絵と同じく、増える方向ごとに分けてある
    /// （人が増える / 持ち物が増える / 魔物が増える）。アトラスは 1 枚のまま。
    pub def charSpritePaths(): List[String] =
        "assets/rpg_people.sprite.json"
            :: "assets/rpg_item.sprite.json"
            :: "assets/rpg_foe.sprite.json"
            :: Nil

    /// 人と物の絵を全部読んで 1 枚の Doc にする。
    pub def loadCharSprites(): PxSpriteDoc.Doc \ Fs.FileRead =
        charSpritePaths()
            |> List.map(PxSpriteDoc.load)
            |> List.foldLeft(joinSpriteDocs, PxSpriteDoc.empty())

    /// 街の絵の Doc。1 ファイル = 同じときに描き直す物だけ（地面 / 水路と橋 / 小物 /
    /// 建物は 1 棟ずつ）。分けるのは編集のためで、GPU へ上げるアトラスは 1 枚のまま
    /// — 読んだ後にここで 1 つの Doc へ束ねる。
    pub def townSpritePaths(): List[String] =
        "assets/town_ground.sprite.json"
            :: "assets/town_water.sprite.json"
            :: "assets/town_prop.sprite.json"
            :: "assets/town_house.sprite.json"
            :: "assets/town_shop.sprite.json"
            :: "assets/town_church.sprite.json"
            :: Nil

    /// 街の絵を全部読んで 1 枚の Doc にする。
    pub def loadTownSprites(): PxSpriteDoc.Doc \ Fs.FileRead =
        townSpritePaths()
            |> List.map(PxSpriteDoc.load)
            |> List.foldLeft(joinSpriteDocs, PxSpriteDoc.empty())

    /// 絵の名前はファイルをまたいで重ならない（重ねたら後から読んだ方が勝つ）。
    def joinSpriteDocs(acc: PxSpriteDoc.Doc, doc: PxSpriteDoc.Doc): PxSpriteDoc.Doc =
        { legend = Map.union(doc#legend, acc#legend),
          sprites = Map.union(doc#sprites, acc#sprites) | acc }

    /// 街タイルのアトラスを作り、GPU キャッシュ用の key と対にして返す。
    /// key に画素のハッシュを織り込むのは、Doc や色票の保存即反映で絵が変わったとき、
    /// 同じ key のまま古いテクスチャが画面に残らないため（毎フレーム計算しない —
    /// 作るのはここ 1 回で、World が結果を持つ）。
    pub def bakeTownAtlas(doc: PxSpriteDoc.Doc, theme: ThemeDoc.Doc): (PxSpriteAtlas.Baked, String) =
        bakedOf("town-tiles-v1", doc, theme)

    /// 人と物（rpg_*.sprite.json）のアトラス。街タイルとは別の 1 枚にまとめる
    /// （絵の出どころが違う Doc なので、片方を保存し直したときにもう片方まで作り直さない）。
    pub def bakeCharAtlas(doc: PxSpriteDoc.Doc, theme: ThemeDoc.Doc): (PxSpriteAtlas.Baked, String) =
        bakedOf(charAtlasName(), doc, theme)

    /// GPU に登録する人と物のアトラスの論理名（View の drawQuad と Main の
    /// withSpriteAtlases がこの名前で待ち合わせる）。
    pub def charAtlasName(): String = "chars"

    /// ドット絵の Doc を 1 枚のアトラスにまとめ、GPU キャッシュ用の鍵と対で返す。
    /// まとめるのは読み込みの 1 回だけで、描くときは 1 コマ = 1 クアッドになる
    /// （PxSprite.draw は 1 コマを画素ぶんの四角に開くので、人や物が増えるほど重くなる。
    ///  予算と検査は engine の docs/performance.md §9）。
    def bakedOf(tag: String, doc: PxSpriteDoc.Doc, theme: ThemeDoc.Doc): (PxSpriteAtlas.Baked, String) =
        let baked = PxSpriteAtlas.bake(doc, key -> ThemeDoc.resolver(theme, key));
        let h = baked#pixels |> Vector.foldLeft((acc, px) -> acc * 31 + px, 17);
        (baked, "${tag}:${Int32.toString(baked#side)}:${Int32.toString(h)}")

    /// 街タイル盤から導く値（タイル層の宣言・橋のマス・水面の矩形）を持ち直す。
    /// 毎フレーム計算しないのは、どれも全盤走査で 1 フレーム予算（120fps=8.3ms）を
    /// 食い潰すため — 盤とアトラスが変わるのは Doc の保存と F1 だけ。
    def refreshTownCache(w: World): World =
        { tileSpec = TownMap.spec(w#townMap, w#townAtlas),
          bridgeCells = TownMap.bridgeCells(w#townMap),
          waterRect = TownMap.waterRect(w#townMap),
          waterMaskRects = TownMap.waterMaskRects(w#townMap) | w }

    /// ゲーム開始時の状態。表紙から始まる。
    pub def initial(docs: Docs): World =
        let (townAtlas, townKey) = bakeTownAtlas(docs#townSprites, docs#theme);
        let (charAtlas, charKey) = bakeCharAtlas(docs#sprites, docs#theme);
        { map = docs#map, kind = docs#kind, theme = docs#theme, battleDoc = docs#battle,
          sprites = docs#sprites,
          townSprites = docs#townSprites, townMap = docs#townMap,
          townAtlas = townAtlas, townAtlasKey = townKey,
          charAtlas = charAtlas, charAtlasKey = charKey,
          tileSpec = TownMap.spec(docs#townMap, townAtlas),
          bridgeCells = TownMap.bridgeCells(docs#townMap),
          waterRect = TownMap.waterRect(docs#townMap),
          waterMaskRects = TownMap.waterMaskRects(docs#townMap),
          waterShader = docs#waterShader, smokeFx = docs#smokeFx,
          phase = Phase.Title, t = 0.0, npcClock = 0.0,
          hero = MapDoc.rec(docs#map)#start, facing = Dir4.Down, stepGauge = 0.0, steps = 0,
          herbs = MapDoc.rec(docs#map)#herbs, picked = 0, doorOpen = false,
          heroHp = BattleDoc.rec(docs#battle)#heroMaxHp, battle = noBattle(),
          dialog = UiDialog.closed(), talkingTo = None, activeDocsWritten = "" }

    /// 戦っていないときの空の戦い（場が無い間の置き物）。
    def noBattle(): Battle =
        { step = BattleStep.Choosing, cursor = 0, foeHp = 0,
          lines = Nil, foeHurt = false, outcome = None }

    /// 里を歩ける状態に置き直す（表紙から始めるとき・間取りの Doc を差し替えたとき）。
    /// 薬草は全部戻り、扉は閉じ、体力は満タン、主人公は start のマスに立つ。[遷移: Title→Play]
    def begin(w: World): World =
        { phase = Phase.Play,
          hero = MapDoc.rec(w#map)#start, facing = Dir4.Down, stepGauge = 0.0, steps = 0,
          herbs = MapDoc.rec(w#map)#herbs, picked = 0, doorOpen = false,
          heroHp = BattleDoc.rec(w#battleDoc)#heroMaxHp, battle = noBattle(),
          dialog = UiDialog.closed(), talkingTo = None | w }

    // ── 収支の導出 ──

    /// クリアに要る薬草の数。置いてある数より多くは求めない（詰みを作らない）。最低 1。
    pub def goalOf(w: World): Int32 =
        Int32.max(1, Int32.min(MapDoc.rec(w#map)#goal, List.length(MapDoc.rec(w#map)#herbs)))

    /// ともっている灯りの数（薬草を拾うたびひとつ点く。灯りの数より多くは点かない）。
    pub def lampsLit(w: World): Int32 =
        Int32.min(w#picked, List.length(MapDoc.rec(w#map)#lamps))

    // ── 住人の巡回（Journey: 状態は npcClock だけ・位置は時刻の純関数） ──

    /// 巡回路（歩けるマスを結ぶ角の列。末尾から先頭へ戻って循環）。
    /// 知らない id は巡回しない（Doc のマスに立ち続ける = fail-open）。
    pub def routeOf(id: String): List[Grid.Cell] =
        match id {
            case "monban"   => { x = 4, y = 8 } :: { x = 7, y = 8 }
                            :: { x = 7, y = 6 } :: { x = 4, y = 6 } :: Nil
            case "hatasaku" => { x = 4, y = 2 } :: { x = 8, y = 2 }
                            :: { x = 8, y = 4 } :: { x = 4, y = 4 } :: Nil
            case "ko"       => { x = 14, y = 6 } :: { x = 14, y = 7 }
                            :: { x = 21, y = 7 } :: { x = 14, y = 7 } :: Nil
            case _          => Nil
        }

    /// 巡回で踏む全マス（角の間も展開。テストが「歩けるマスしか通らない」を縛る口）。
    pub def routeCells(id: String): List[Grid.Cell] =
        match routeOf(id) {
            case Nil => Nil
            case pts =>
                let closed = List.append(pts, List.take(1, pts));
                List.zip(closed, List.drop(1, closed))
                    |> List.flatMap(pair -> { let (a, b) = pair; cellsBetween(a, b) })
        }

    /// 軸に沿った 2 マス間の経路（両端込み）。斜めは想定しない（巡回路は角で曲がる）。
    def cellsBetween(a: Grid.Cell, b: Grid.Cell): List[Grid.Cell] =
        if (a#x == b#x)
            List.range(Int32.min(a#y, b#y), Int32.max(a#y, b#y) + 1)
                |> List.map(y -> { x = a#x, y = y })
        else
            List.range(Int32.min(a#x, b#x), Int32.max(a#x, b#x) + 1)
                |> List.map(x -> { x = x, y = a#y })

    /// 住人の今の見本（位置と歩いた距離）。巡回しない住人は Doc のマスに立つ。
    pub def villagerSampleAt(w: World, villager: MapDoc.Villager): Journey.Sample =
        match routeOf(villager#id) {
            case Nil => { pos = Grid.cellCenterOf(tileSize(), villager#cell),
                          walking = 0.0, done = true }
            case pts => {
                let centers = pts |> List.map(c -> Grid.cellCenterOf(tileSize(), c));
                let closed = List.append(centers, List.take(1, centers));
                let legs = List.zip(closed, List.drop(1, closed))
                    |> List.map(pair -> { let (a, b) = pair;
                        ({ src = a, dst = b, speed = 22.0 }: Journey.Leg) });
                let total = Journey.total(legs);
                // 同じフレームで全員が曲がらないよう、名前の長さで位相をずらす。
                let phase = Int32.toFloat64(String.length(villager#id)) * 3.7;
                let tt = wrapBy(total, w#npcClock + phase);
                Journey.at(legs, tt)
            }
        }

    /// 住人が今いるマス（歩ける・話せるの判定はこのマスで行う — 絵と規則を同じ見本から導く）。
    pub def villagerCellAt(w: World, villager: MapDoc.Villager): Grid.Cell =
        let smp = villagerSampleAt(w, villager);
        { x = Float64.tryToInt32(Float64.floor(smp#pos#x / tileSize())) |> Option.getWithDefault(0),
          y = Float64.tryToInt32(Float64.floor(smp#pos#y / tileSize())) |> Option.getWithDefault(0) }

    /// 0 <= 戻り値 < total の折り返し（total が 0 以下なら 0）。
    def wrapBy(total: Float64, t: Float64): Float64 =
        if (total <= 0.0) 0.0
        else t - total * Float64.floor(t / total)

    // ── 歩ける・ぶつかるの規則 ──

    /// cell へ歩けるか。盤の中で、石垣でなく、住人が立っておらず、閉じた扉でもないこと。
    pub def walkable(cell: Grid.Cell, w: World): Bool =
        Grid.inRectOf(cell, MapDoc.cols(w#map), MapDoc.rowCount(w#map))
            and not MapDoc.solidAt(cell, w#map)
            and not List.exists(v -> MapDoc.sameCell(villagerCellAt(w, v), cell), MapDoc.rec(w#map)#villagers)
            and not (MapDoc.sameCell(cell, MapDoc.rec(w#map)#door#cell) and not w#doorOpen)

    /// 1 歩の規則: まず向きを変え、行き先に歩ければ進み、薬草があれば拾う。
    /// 歩けなければ向きだけ変わる（壁の前で足踏みしない）。
    pub def stepOnce(direction: Dir4.Dir4, w: World): World =
        let faced = { facing = direction | w };
        let target = Grid.neighborOf(w#hero, direction);
        if (walkable(target, faced))
            pickUp({ hero = target, steps = w#steps + 1 | faced }) |> meetFoe
        else
            faced

    /// いま立っているマスの薬草を拾う。goal に届いたらクリア（Phase.Clear）。[遷移: Play→Clear]
    /// 拾った薬草は盤から消えるので、同じマスをまた踏んでも二度は数えない。
    def pickUp(w: World): World =
        if (List.exists(cell -> MapDoc.sameCell(cell, w#hero), w#herbs)) {
            let picked = w#picked + 1;
            { herbs = List.filter(cell -> not MapDoc.sameCell(cell, w#hero), w#herbs),
              picked = picked,
              phase = if (picked >= goalOf(w)) Phase.Clear else w#phase | w }
        } else w

    /// 毎フレーム: ふきだしの文字送りを進め、開いていなければ歩みを進める。
    /// ふきだしが開いている間は歩けない（会話中に動かないのはルール）。
    /// 歩く速さは KindDoc（walk マス/秒）— 押しっぱなしで 1/walk 秒ごとに 1 歩。
    /// 時計（t）だけは場面を問わず進める — 表紙でも戦いの最中でも霧が流れ、魔物が息をする。
    pub def step(direction: Option[Dir4.Dir4], dt: Float64, w: World): World =
        let ticked = { t = w#t + dt | w };
        match ticked#phase {
            case Phase.Play => {
                let talked = { dialog = UiDialog.step(cps = KindDoc.rec(w#kind)#cps, dt, ticked#dialog) | ticked };
                if (UiDialog.isOpen(talked#dialog))
                    // 会話中は住人の巡回も止める — 話し相手が歩き去ると、
                    // ふきだしの根本が誰も居ないマスを指すため。
                    talked
                else
                    walk(direction, Clock.countdown(talked#stepGauge, dt),
                         { npcClock = talked#npcClock + dt | talked })
            }
            case _ => ticked
        }

    /// 歩みの更新。向きは押せばすぐ変わり、gauge が 0 になったフレームだけ 1 歩進む。
    /// 実際に進んだら次の一歩まで stepInterval を貯め直す。
    def walk(direction: Option[Dir4.Dir4], gauge: Float64, w: World): World =
        match direction {
            case None => { stepGauge = gauge | w }
            case Some(d) =>
                if (gauge > 0.0)
                    { stepGauge = gauge, facing = d | w }
                else {
                    let stepped = stepOnce(d, { stepGauge = gauge | w });
                    if (not MapDoc.sameCell(stepped#hero, w#hero))
                        { stepGauge = stepInterval(w) | stepped }
                    else stepped
                }
        }

    /// 1 歩にかける秒数（walk マス/秒の逆数。1 未満の walk は 1 マス/秒にする）。
    def stepInterval(w: World): Float64 =
        1.0 / Float64.max(1.0, KindDoc.rec(w#kind)#walk)

    // ══════════════════════════════════════════════════════
    // 戦い（歩数で出会い、殴り合い、勝つか負けるか逃げる）
    // ══════════════════════════════════════════════════════
    //
    //   Play ──encounterSteps 歩ごと(meetFoe)──▶ Battle
    //     ▲                                        │
    //     └────勝ち / 逃げ / 負け(leaveBattle)──────┘
    //
    // 乱数は持ち込まない: 何歩めで出会うかも、一撃の重さも Doc の数から決まる。
    // 決定的なので描き出した絵もテストの期待値も揺れない（強さの調整は Doc 側で足りる）。

    /// この歩数で魔物と出会うか。encounterSteps 歩ごとに 1 回。0 以下なら出会わない。
    pub def meetsFoeAt(steps: Int32, doc: BattleDoc.Doc): Bool =
        let d = BattleDoc.rec(doc);
        d#encounterSteps > 0 and steps > 0 and Int32.modulo(steps, d#encounterSteps) == 0

    /// 1 歩ぶん進んだあとの出会い判定。里を歩いている間だけ。[遷移: Play→Battle]
    def meetFoe(w: World): World =
        if (w#phase == Phase.Play and meetsFoeAt(w#steps, w#battleDoc))
            { phase = Phase.Battle,
              battle = { step = BattleStep.Report, cursor = 0, foeHp = BattleDoc.rec(w#battleDoc)#foeMaxHp,
                         lines = "${BattleDoc.rec(w#battleDoc)#foeName} ${BattleDoc.rec(w#battleDoc)#foeAppears}" :: Nil,
                         foeHurt = false, outcome = None } | w }
        else w

    /// 戦いのコマンドの並び（見出しは UI の構造なので固定でよい）。
    pub def battleCommands(): List[String] = "たたかう" :: "にげる" :: Nil

    /// 選ぶカーソルを 1 つ動かす（上下。端で止まる）。Choosing の間だけ効く。
    pub def moveCursor(delta: Int32, w: World): World =
        if (w#phase != Phase.Battle or w#battle#step != BattleStep.Choosing) w
        else {
            let last = List.length(battleCommands()) - 1;
            let cursor = Int32.max(0, Int32.min(last, w#battle#cursor + delta));
            { battle = { cursor = cursor | w#battle } | w }
        }

    /// 戦いの決定 1 回分。フェーズによって意味が変わる:
    ///   Report   … 読み終えた → つぎのコマンド選びへ。
    ///   Choosing … 選んだコマンドを実行する（たたかう / にげる）。
    ///   Done     … 決着を読み終えた → 里へ戻る。
    def battleConfirm(w: World): World =
        match w#battle#step {
            case BattleStep.Report =>
                { battle = { step = BattleStep.Choosing, lines = Nil, foeHurt = false | w#battle } | w }
            case BattleStep.Done   => leaveBattle(w)
            case BattleStep.Choosing =>
                if (w#battle#cursor == 1) flee(w) else strike(w)
        }

    /// 「たたかう」1 回分。こちらが殴り、倒せなければ相手が殴り返す。
    def strike(w: World): World =
        let doc = BattleDoc.rec(w#battleDoc);
        let foeHp = Int32.max(0, w#battle#foeHp - doc#heroAttack);
        let hitLine = "${doc#foeName} に ${Int32.toString(doc#heroAttack)} ${doc#damageSuffix}";
        if (foeHp <= 0)
            { battle = { step = BattleStep.Done, foeHp = 0, foeHurt = true,
                         lines = hitLine :: doc#heroWins :: Nil,
                         outcome = Some(Outcome.Win) | w#battle } | w }
        else {
            let heroHp = Int32.max(0, w#heroHp - doc#foeAttack);
            let backLine = "こちらに ${Int32.toString(doc#foeAttack)} ${doc#damageSuffix}";
            if (heroHp <= 0)
                { heroHp = 0,
                  battle = { step = BattleStep.Done, foeHp = foeHp, foeHurt = true,
                             lines = hitLine :: backLine :: doc#heroLoses :: Nil,
                             outcome = Some(Outcome.Lose) | w#battle } | w }
            else
                { heroHp = heroHp,
                  battle = { step = BattleStep.Report, foeHp = foeHp, foeHurt = true,
                             lines = hitLine :: backLine :: Nil, outcome = None | w#battle } | w }
        }

    /// 「にげる」1 回分。必ず逃げられる（starter は詰ませない — 難しさは Doc の数で足す）。
    def flee(w: World): World =
        { battle = { step = BattleStep.Done, lines = BattleDoc.rec(w#battleDoc)#heroFlees :: Nil,
                     foeHurt = false, outcome = Some(Outcome.Flee) | w#battle } | w }

    /// 決着して里へ戻る。倒れていたら入口へ戻って体力が満ちる（詰まない）。
    /// [遷移: Battle→Play]
    def leaveBattle(w: World): World =
        let back = { phase = Phase.Play, battle = noBattle() | w };
        match w#battle#outcome {
            case Some(Outcome.Lose) =>
                { hero = MapDoc.rec(w#map)#start, facing = Dir4.Down, heroHp = BattleDoc.rec(w#battleDoc)#heroMaxHp | back }
            case _ => back
        }

    // ── 決定（話す・進める）の規則 ──

    /// 決定 1 回分。表紙では歩き出し［遷移: Title→Play］、クリア画面では表紙へ戻る［遷移: Clear→Title］。
    /// 里では: ふきだしが開いていれば送り（文字送り中なら全文へ・読み終えていれば閉じる）、
    /// 閉じていれば目の前の住人に話しかける（Play のまま）。
    /// 戦いの最中は battleConfirm へ渡す。
    pub def confirm(w: World): World =
        match w#phase {
            case Phase.Title  => begin(w)
            case Phase.Clear  => { phase = Phase.Title | w }
            case Phase.Battle => battleConfirm(w)
            case Phase.Play =>
                if (UiDialog.isOpen(w#dialog)) {
                    let dialog = UiDialog.advance(w#dialog);
                    { dialog = dialog,
                      talkingTo = if (UiDialog.isOpen(dialog)) w#talkingTo else None | w }
                } else
                    talk(Grid.neighborOf(w#hero, w#facing), w)
        }

    /// 目の前のマスに住人がいれば話しかける。いなければ何も起きない。
    def talk(cell: Grid.Cell, w: World): World =
        match List.find(v -> MapDoc.sameCell(villagerCellAt(w, v), cell), MapDoc.rec(w#map)#villagers) {
            case None           => w
            case Some(villager) => speak(villager, w)
        }

    /// 住人の 1 行を選び、ふきだしを開く。約束の相手（door の promise）だけは特別で、
    /// 扉が閉じている間: 薬草が足りなければ頼まれごと（ask）、足りていれば扉が開いて opened。
    /// それ以外（扉が開いた後も）はその住人のいつもの 1 行。
    def speak(villager: MapDoc.Villager, w: World): World =
        let door = MapDoc.rec(w#map)#door;
        let isPromise = villager#id == door#promise and not w#doorOpen;
        let fulfilled = isPromise and w#picked >= door#need;
        let line = if (fulfilled) door#opened
                   else if (isPromise) door#ask
                   else villager#line;
        { doorOpen = w#doorOpen or fulfilled,
          dialog = UiDialog.openWith(
              { speaker = villager#id, body = RichText.plain(line) :: Nil } :: Nil),
          talkingTo = Some(villagerCellAt(w, villager)) | w }

    // ── Doc の差し替え（保存即反映） ──

    /// 間取りの差し替え。歩いている途中なら盤を作り直す（編集がその場で画面に出る。
    /// 拾いかけの薬草は戻る — 盤が変わったら仕切り直すのが一番迷わない）。
    pub def withMap(map: MapDoc.Doc, w: World): World =
        let w1 = { map = map | w };
        match w1#phase {
            case Phase.Play => begin(w1)
            case _          => w1
        }

    pub def withKind(kind: KindDoc.Doc, w: World): World = { kind = kind | w }

    /// 戦いの数値・文言の差し替え。体力の上限が動くので、いまの体力もそこへ収める。
    pub def withBattleDoc(doc: BattleDoc.Doc, w: World): World =
        { battleDoc = doc, heroHp = Int32.min(w#heroHp, BattleDoc.rec(doc)#heroMaxHp) | w }

    /// 色票の差し替え。アトラスは色票から実色を組み込んでいるので、2 枚とも作り直す
    /// （作り直さないと、タイルや人だけ古い色のまま画面に残る）。
    pub def withTheme(theme: ThemeDoc.Doc, w: World): World =
        let (townAtlas, townKey) = bakeTownAtlas(w#townSprites, theme);
        let (charAtlas, charKey) = bakeCharAtlas(w#sprites, theme);
        refreshTownCache({ theme = theme, townAtlas = townAtlas, townAtlasKey = townKey,
                           charAtlas = charAtlas, charAtlasKey = charKey | w })

    /// 人と物の Doc の差し替え（保存即反映）。アトラスも一緒に作り直す。
    pub def withSprites(sprites: PxSpriteDoc.Doc, w: World): World =
        let (charAtlas, charKey) = bakeCharAtlas(sprites, w#theme);
        { sprites = sprites, charAtlas = charAtlas, charAtlasKey = charKey | w }

    /// 街タイルの Doc の差し替え（保存即反映）。アトラスも一緒に作り直す。
    pub def withTownSprites(doc: PxSpriteDoc.Doc, w: World): World =
        let (townAtlas, townKey) = bakeTownAtlas(doc, w#theme);
        refreshTownCache({ townSprites = doc, townAtlas = townAtlas, townAtlasKey = townKey | w })

    /// 街のタイル盤の差し替え（保存即反映）。アトラスは盤に依らないので作り直さない —
    /// タイル層は Doc の読み直しをエンジンが世代で検知して勝手に敷き直す。
    pub def withTownMap(doc: TownMapDoc.Doc, w: World): World =
        refreshTownCache({ townMap = doc | w })

    pub def withWaterShader(spec: ShaderDoc.Spec, w: World): World = { waterShader = spec | w }

    pub def withSmokeFx(spec: FxDoc.Spec, w: World): World = { smokeFx = spec | w }
}
