// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
//
// 真上から見下ろした磯。盤は 1 マス Layout.cell() の盤の座標で組み、最後に Layout.fitOf で画面へ写す。
// 盤の外は全部外海（遊びに効かない絵の水底: すぐ周りは砂・その外は深み）。重なり（場面の中は積んだ順）:
//   水底     … 岩の面を画面いっぱいに 1 枚 + 砂の色                        → 面に質感
//   高さ 1〜3 の段 … 落ち影 → 崖の面 → 光の縁 → 上面 → 明るさ → 濡れ           → 面に質感・層・形
//   その高さに乗った物 … 小石・海藻・イソギンチャク・巻き貝
//   水       … 水のあるマスの塊だけを型抜きで 1 枚 + 深さの段の翳り + 光の網目    → 層（深さ）
//   水際の泡・せき止めた池の縁・浮いた流木・魚・マスの角・先読み・ヤドカリ        → 時間が流れる・主役
// 1 手の間は前の状態と今の状態を blend で重ねてつなぐ（水は塊ごとに濃さを入れ替え、物とヤドカリは 2 マスの間を進む）。
// 右の板と重ね（クリア・流された）は HudView、題名と終わりは TitleView、物の形は PropView。
mod View {

    use fge::{
        App, Color, DrawCmd, DualGrid, FontAtlas, Fx, Num, Rect2, RawDraw, Render, ShaderDoc,
        SortingLayer, Sway, Terrain, TextDraw, Vec2, ZStack
    }
    use Board.Cell
    use ZOrder.Layer

    /// 描くのに要る値。部品は World でなくこれを読む（lint/rules.flix の view-no-world）。
    /// before → now を blend（0..1）でつなぐ。age は now になってからの秒（流されたの演出の時計）。
    /// hud・overlay・title は右の板・重ね・題名と終わりの画面へそのまま渡す値。
    pub type alias In = {
        t = Float64,
        board = Board.Board,
        now = World.State,
        before = World.State,
        blend = Float64,
        age = Float64,
        forecast = World.Forecast,
        screen = World.Screen,
        hud = HudView.In,
        overlay = HudView.Overlay,
        title = TitleView.In,
        rules = RulesDoc.Doc,
        surfaces = World.Surfaces,
        theme = ThemeDoc.Doc,
        askingQuit = Bool,
        quitPrompt = String
    }

    /// World から描くのに要る値だけを写す（View の中で World を読むのは入口の frame とここだけ）。
    /// 題名の画面は選んでいる面の初めの盤を、終わりの画面は最後の面の潮位を 1 手進めた盤を背に敷く。
    pub def inputOf(w: World.World): In =
        let b = World.board(w);
        let backdrop = w#screen != World.Screen.Play;
        let now = match w#screen {
            case World.Screen.Title  => World.startOf(b)
            case World.Screen.Ending => risingOf(b, World.state(w))
            case World.Screen.Play   => World.state(w)
        };
        let (parMoves, name) = (World.parMoves(w), World.stageName(w));
        let shells = World.shellsFor(w#rules, parMoves, now#t);
        { t = w#t, board = b, now = now, before = if (backdrop) now else w#before, blend = if (backdrop) 1.0 else w#blend,
          age = w#t - w#since, forecast = World.forecastOf(b, now), screen = w#screen,
          hud = { t = w#t, cycle = b#cycle, moves = now#t, parMoves = parMoves, shells = shells, level = w#level, name = name, theme = w#theme },
          overlay = { t = w#t, age = w#t - w#since, phase = now#phase, moves = now#t, parMoves = parMoves, shells = shells,
                      last = w#level + 1 >= Vector.length(w#stages), theme = w#theme },
          title = { t = w#t, level = w#level, name = name, canSelect = (World.isOpened(w#level - 1, w), World.isOpened(w#level + 1, w)),
                    best = w#best, stageCount = Vector.length(w#stages), theme = w#theme },
          rules = w#rules, surfaces = w#surfaces, theme = w#theme,
          askingQuit = World.isAskingQuit(w), quitPrompt = RulesDoc.rec(w#rules)#quitPrompt }

    /// 物はそのままに、満ち引きを 1 周回した後から 1 手ぶん潮を進めた盤（背に敷く絵。遊びの手には数えない）。
    def risingOf(b: Board.Board, s: World.State): World.State =
        { water = Tide.flow(s#pebbles, Board.tideAt(1, b), Tide.cycleOnce(s#pebbles, s#water, b), b), t = 1 | s }

    pub def frame(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        SortingLayer.compose(ctx, layers(ctx, inputOf(w)))

    /// 層ごとの木（絵と押せる物の当たり）。Controls.tapAt も同じ木から押した物を選ぶ。
    pub def layers(ctx: App.ViewCtx, w: In): List[(Layer, ZStack.Tree[Layer, World.Press])] =
        let front = match w#screen {
            case World.Screen.Title  => TitleView.title(ctx#atlas, w#title)
            case World.Screen.Ending => TitleView.ending(ctx#atlas, w#title)
            case World.Screen.Play   => HudView.hud(ctx#atlas, w#hud) ::: HudView.overlay(ctx#atlas, w#overlay)
        };
        (Layer.Scene, ZStack.of(scene(ctx#atlas, w) |> List.map(ZStack.leaf)))
            :: (Layer.Hud, ZStack.of(front |> List.map(ZStack.leaf)))
            :: (Layer.Prompt, quitPrompt(ctx, w)) :: Nil

    def isPlay(w: In): Bool = w#screen == World.Screen.Play

    // ── 盤の置き場所 ──

    /// 遊ぶ画面は右の板の手前まで、題名と終わりの画面は画面いっぱいに盤を収める。
    def fit(w: In): Layout.Fit = Layout.fitOf(w#board#cols, w#board#rows, if (isPlay(w)) 452.0 else 624.0)

    /// 画面の座標 → 盤の座標。
    def toBoard(w: In, p: Vec2.Vec2): Vec2.Vec2 = Vec2.div(Vec2.sub(p, fit(w)#offset), fit(w)#scale)

    def toCell(v: Float64): Int32 = Float64.floor(v) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    /// 画面に映る角の範囲（左上の角と、横と縦の数）。
    def cornerSpan(w: In): (Cell, Int32, Int32) =
        let lo = toBoard(w, Vec2.zero());
        let hi = toBoard(w, { x = World.width(), y = World.height() });
        let (x0, y0) = (toCell(lo#x / Layout.cell()) - 1, toCell(lo#y / Layout.cell()) - 1);
        ((x0, y0), toCell(hi#x / Layout.cell()) + 2 - x0, toCell(hi#y / Layout.cell()) + 2 - y0)

    def shownCorners(w: In): List[Cell] =
        let ((x0, y0), nx, ny) = cornerSpan(w);
        Terrain.cornersOf(nx, ny) |> List.map(match (i, j) -> (i + x0, j + y0))

    /// 画面に映る盤の外のマス（外海）。
    def seaCells(w: In): Set[Cell] =
        let ((x0, y0), nx, ny) = cornerSpan(w);
        List.range(y0 - 1, y0 + ny) |> List.flatMap(y -> List.range(x0 - 1, x0 + nx) |> List.map(x -> (x, y)))
            |> List.filter(c -> not Board.isInside(c, w#board)) |> List.toSet

    /// 面を塗る矩形（画面いっぱいの正方形。worley の網目が横に伸びないよう正方形にする）。
    def surfaceRect(w: In): Rect2.Rect2 =
        { position = toBoard(w, Vec2.zero()), size = { x = World.width() / fit(w)#scale, y = World.width() / fit(w)#scale } }

    // ── 場面 ──

    /// 奥から手前へ積む部品の列（1 部品 = 1 葉。面と多角形は同じ葉に入れない）。盤の座標で組んで画面へ写す。
    def scene(atlas: FontAtlas, w: In): List[List[Render.PlacedItem]] =
        let s = w#surfaces;
        let props = propIn(w);
        let theme = ThemeDoc.rec(w#theme);
        let r = surfaceRect(w);
        let sand = { at = r#position, item = RawDraw.box(r#size, Color.mix(theme#shell, theme#light, 0.2), 0) |> Render.fade(0.38) };
        let floor = (Render.shaderFill(s#rock, r, w#t, 0) :: Nil) :: (sand :: Nil) :: PropView.restingOn(props, 0) :: Nil;
        let perLevel = List.range(1, Board.maxHeight() + 1) |> List.flatMap(level ->
            List.append(rockLevel(w, level), PropView.restingOn(props, level) :: Nil));
        // 題名と終わりの画面は盤を背景として見せるだけなので、遊びの印（先読み・ラベル）は出さない。
        let onlyInPlay = items -> if (isPlay(w)) items else Nil;
        let top = water(w) ::: (foam(w) :: raisedPool(w) :: PropView.floating(props) :: PropView.fish(props) :: onlyInPlay(gridMarks(w))
            :: onlyInPlay(forecast(w)) :: PropView.crab(props) :: onlyInPlay(crabWarning(w))
            :: onlyInPlay(poolTag(atlas, w)) :: Nil);
        let toScreen = items -> items |> Render.scaledAllAround(fit(w)#scale, Vec2.zero()) |> Render.movedAll(fit(w)#offset);
        List.map(toScreen, floor ::: perLevel ::: top) ::: (onlyInPlay(washedWave(w)) :: vignette() :: Nil)

    /// 1 手の間の重さ: 前の状態に (1 - u)、今の状態に u。片方が 0 の時は描かない。
    def weights(w: In): List[(World.State, Float64)] =
        let u = Num.clamp01(w#blend);
        ((w#before, 1.0 - u) :: (w#now, u) :: Nil) |> List.filter(e -> snd(e) > 0.001)

    /// 盤の外の水底の高さ: 盤のすぐ周りの半分ほどが高さ 0 の砂、残りは -1 の深み（どれかはマスのハッシュで決める）。
    /// 遊びには効かない（盤の外は全部外海）。引き潮で水際が盤から離れて見えるための絵の地形。
    def seaFloorAt(w: In, c: Cell): Int32 =
        let (x, y) = c;
        let far = Int32.max(Int32.max(-x, x - w#board#cols + 1), Int32.max(-y, y - w#board#rows + 1));
        if (Int32.toFloat64(far) + DualGrid.hash(x, y, 230) * 2.0 < 2.0) 0 else -1

    /// 水のあるマス（盤の中の沈んだマスと、手数 t の潮位より低い盤の外）。
    def wetCells(w: In, s: World.State): Set[Cell] = Set.union(World.submergedCells(w#board, s), seaWet(w, s#t))

    def seaWet(w: In, t: Int32): Set[Cell] =
        seaCells(w) |> Set.filter(c -> seaFloorAt(w, c) < Board.tideAt(t, w#board))

    /// 水の深さ（水面 − 地面。盤の外は潮位 − 水底）。
    def depthAt(w: In, s: World.State, c: Cell): Int32 =
        if (Board.isInside(c, w#board)) Map.getWithDefault(c, 0, s#water) - Board.heightAt(c, w#board)
        else Board.tideAt(s#t, w#board) - seaFloorAt(w, c)

    /// マスの集合を DualGrid の塊（角の丸い多角形の列・盤の座標）にする。jitter で縁を少し揺らす。
    def blobs(w: In, cells: Set[Cell], offset: Vec2.Vec2): List[List[Vec2.Vec2]] = blobsOf(w, cells, offset, _ -> true)

    /// 塊の縁の角だけ（4 マスとも中の角を抜く）。上面の下に隠れる落ち影・崖の面・光の縁は、中の四角を塗っても見えない。
    def edgeBlobs(w: In, cells: Set[Cell], offset: Vec2.Vec2): List[List[Vec2.Vec2]] =
        blobsOf(w, cells, offset, corner -> DualGrid.caseIndex(corner) != 15)

    /// 4 マスとも中の角はただの正方形なので、行ごとに続いた所を 1 枚の長方形にまとめる（部品の数を抑える）。
    def blobsOf(w: In, cells: Set[Cell], offset: Vec2.Vec2, keep: DualGrid.Corner -> Bool): List[List[Vec2.Vec2]] =
        let flags = Terrain.flagsOf(cells);
        let (full, edge) = shownCorners(w) |> List.filter(corner -> keep(flags(corner)))
            |> List.partition(corner -> DualGrid.caseIndex(flags(corner)) == 15);
        let runs = full |> List.sortBy(c -> (snd(c), fst(c))) |> List.foldLeft((acc, c) -> match acc {
            case (first, last) :: rest if snd(last) == snd(c) and fst(last) + 1 == fst(c) => (first, c) :: rest
            case _ => (c, c) :: acc
        }, Nil);
        let squares = runs |> List.map(match (first, last) -> {
            let a = Vec2.add(DualGrid.originOf(Layout.cell(), first), offset);
            let b = Vec2.add(Vec2.add(DualGrid.originOf(Layout.cell(), last), offset), { x = Layout.cell(), y = Layout.cell() });
            { x = a#x, y = a#y } :: { x = b#x, y = a#y } :: { x = b#x, y = b#y } :: { x = a#x, y = b#y } :: Nil
        });
        squares ::: (edge |> List.flatMap(corner -> {
            let tile = DualGrid.resolve({ tile = Layout.cell(), corner = corner,
                style = DualGrid.styleAt({ round = 0.8, square = 0.0 }, corner), jitter = 4.0 }, flags(corner));
            let at = Vec2.add(DualGrid.originOf(Layout.cell(), corner), offset);
            tile#polys |> List.map(poly -> poly |> List.map(v -> Vec2.add(v, at)))
        }))

    /// 水の型（角の丸い塊）。水は縁を揺らさない（水面は岩より平らに見せる）。
    def waterMask(w: In, cells: Set[Cell]): List[List[Vec2.Vec2]] =
        Terrain.maskPolys(Layout.cell(), Terrain.flagsOf(cells), shownCorners(w))

    /// 塊の輪郭の小さな辺（盤の座標）。水際の泡と先読みの破線がこれをなぞる。
    def outline(w: In, cells: Set[Cell]): List[(Vec2.Vec2, Vec2.Vec2)] =
        let flags = Terrain.flagsOf(cells);
        shownCorners(w) |> List.flatMap(corner -> {
            let tile = DualGrid.resolve({ tile = Layout.cell(), corner = corner, style = DualGrid.CornerStyle.Round, jitter = 0.0 }, flags(corner));
            let at = DualGrid.originOf(Layout.cell(), corner);
            DualGrid.segmentsOf(tile) |> List.map(match (a, b) -> (Vec2.add(a, at), Vec2.add(b, at)))
        })

    /// spec の濃さを k 倍にした面。
    def withAlpha(k: Float64, spec: ShaderDoc.Spec): ShaderDoc.Spec =
        match spec#out {
            case ShaderDoc.Out.Fill(fill) =>
                { out = ShaderDoc.Out.Fill({ alpha = ShaderDoc.Field.Bin({ op = ShaderDoc.BinOp.Mul,
                        a = fill#alpha, b = ShaderDoc.Field.Const(k) }) | fill }) | spec }
        }

    /// 多角形の列を 1 色で塗る（濃さ 0 なら何も出さない）。
    def polys(look: { color = Color, alpha = Float64, blend = DrawCmd.BlendMode },
              shapes: List[List[Vec2.Vec2]]): List[Render.PlacedItem] =
        if (look#alpha <= 0.001) Nil else shapes |> List.map(poly ->
            { at = Vec2.zero(), item = RawDraw.polygon(poly, look#color, 0)
                |> Render.fade(look#alpha) |> Render.blended(look#blend) })

    /// 高さ level の段がどれだけ濡れているか（0..1.1）。直前の数手の潮がその面を沈めていたほど濡れている。
    def wetnessOf(w: In, level: Int32): Float64 =
        let tideAgo = k -> Board.tideAt(w#now#t - k, w#board);
        match List.range(0, 6) |> List.find(k -> tideAgo(k) > level) {
            case Some(k) => 1.1 - Int32.toFloat64(k) * 0.2
            case None    => if (tideAgo(0) == level) 0.3 else 0.0
        }

    /// 高さ level（1〜3）の段: 落ち影 → 崖の面 → 光の縁 → 上面 → 明るさ → 濡れ。
    /// 落ち影は光（左上）の反対へ、段の高さぶん伸ばす。
    def rockLevel(w: In, level: Int32): List[List[Render.PlacedItem]] =
        let theme = ThemeDoc.rec(w#theme);
        let cells = Board.cells(w#board) |> List.filter(c -> Board.heightAt(c, w#board) >= level) |> List.toSet;
        let top = blobs(w, cells, Vec2.zero());
        let rise = 7.0;
        // 高い段ほど光の色へ寄せて明るく（乾いて白っぽい岩）、高さを明るさの段でも読ませる。
        let tint = { color = theme#light, alpha = 0.13 * Int32.toFloat64(level - 1), blend = DrawCmd.BlendMode.Normal };
        polys({ color = theme#shadow, alpha = 0.42, blend = DrawCmd.BlendMode.Multiply }, edgeBlobs(w, cells, { x = rise + 2.0, y = rise + 4.0 }))
            :: polys({ color = Color.mix(theme#cliff, theme#shadow, 0.25), alpha = 1.0, blend = DrawCmd.BlendMode.Normal }, edgeBlobs(w, cells, { x = 0.0, y = rise }))
            :: polys({ color = Color.mix(theme#light, theme#cliff, 0.35), alpha = 0.55, blend = DrawCmd.BlendMode.Normal }, edgeBlobs(w, cells, { x = -1.5, y = -1.5 }))
            :: (Render.shaderFillMasked(w#surfaces#rock, surfaceRect(w), top, w#t, 0) :: Nil)
            :: polys(tint, top)
            :: polys({ color = Color.mix(theme#shadow, theme#weed, 0.25), alpha = 0.42 * wetnessOf(w, level), blend = DrawCmd.BlendMode.Multiply }, top)
            :: Nil

    /// 水: 前と今の水の塊を重さで重ね、深さの段ごとに影の色で沈め、光の網目を張る。
    /// WhyNot: 深さの段ごとに水の面を全面で塗り重ねない。面の評価が画面の広さ × 段の数になって描き出しが重くなる。
    def water(w: In): List[List[Render.PlacedItem]] =
        let theme = ThemeDoc.rec(w#theme);
        weights(w) |> List.flatMap(match (s, k) -> {
            let wet = wetCells(w, s);
            let mask = waterMask(w, wet);
            let deeper = List.range(2, 5) |> List.map(d ->
                polys({ color = Color.mix(theme#shadow, theme#sea, 0.5), alpha = 0.13 * k, blend = DrawCmd.BlendMode.Multiply },
                      blobs(w, wet |> Set.filter(c -> depthAt(w, s, c) >= d), Vec2.zero())));
            (Render.shaderFillMasked(withAlpha(1.4 * k, w#surfaces#water), surfaceRect(w), mask, w#t, 0) :: Nil)
                :: deeper ::: ((Render.shaderFillMasked(withAlpha(k, w#surfaces#caustics), surfaceRect(w), mask, w#t, 0) :: Nil) :: Nil)
        })

    /// 水際に沿う泡。辺ごとに濃さと太さを座標と時刻で揺らし、泡の粒を辺の上に浮かべる。
    def foam(w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        weights(w) |> List.flatMap(match (s, k) -> {
            let edges = List.toVector(outline(w, wetCells(w, s)));
            let lines = Vector.toList(edges) |> List.map(match (a, b) -> {
                let pulse = 0.5 + 0.5 * Sway.wave(w#t, DualGrid.hash(toCell(a#x), toCell(a#y), 5), 0.9);
                RawDraw.lineSeg(a, b, 1.2 + pulse * 1.4, theme#foam, 0) |> Render.overItem(Render.fade((0.28 + 0.35 * pulse) * k))
            });
            let count = Vector.length(edges);
            List.append(lines, if (count == 0) Nil else Fx.derive(36, w#t, (_i, rand, t) -> {
                let (a, b) = Vector.get(Int32.min(count - 1, toCell(rand(0) * Int32.toFloat64(count))), edges);
                let base = Vec2.add(Vec2.add(a, Vec2.mul(Vec2.sub(b, a), rand(1))), Sway.drift(t, rand(2), { x = 2.5, y = 1.8 }));
                let life = Vec2.sin((t * (0.3 + rand(3) * 0.4) + rand(4)) * Vec2.pi());
                RawDraw.circleAt(base, 0.8 + rand(5) * 1.4, theme#foam, 0) |> Render.overItem(Render.fade(Float64.abs(life) * 0.55 * k))
            }))
        })

    /// 外の潮より高く残った池（せき止めた水）のマス。
    def raisedCells(w: In): Set[Cell] =
        let tide = Board.tideAt(w#now#t, w#board);
        World.submergedCells(w#board, w#now) |> Set.filter(c -> Map.getWithDefault(c, 0, w#now#water) > tide)

    /// せき止めた池: 水面の縁を明るい線で縁取り（水位の段差）、堰の小石の隙間から低い側へこぼれる筋を流す。
    def raisedPool(w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let cells = raisedCells(w);
        let rim = outline(w, cells) |> List.flatMap(match (a, b) ->
            (RawDraw.lineSeg(Vec2.add(a, { x = 1.5, y = 2.0 }), Vec2.add(b, { x = 1.5, y = 2.0 }), 2.4, theme#shadow, 0)
                |> Render.overItem(item -> item |> Render.fade(0.35 * w#blend) |> Render.blended(DrawCmd.BlendMode.Multiply)))
            :: (RawDraw.lineSeg(a, b, 1.8, Color.mix(theme#foam, theme#light, 0.3), 0) |> Render.overItem(Render.fade(0.85 * w#blend)))
            :: Nil);
        let spills = Set.toList(w#now#pebbles) |> List.flatMap(dam ->
            match Board.neighbors(dam) |> List.find(c -> Set.memberOf(c, cells)) {
                case None => Nil
                case Some(src) =>
                    let dir = Vec2.normalized(Vec2.sub(Layout.centerOf(dam), Layout.centerOf(src)));
                    let start = Vec2.add(Layout.centerOf(dam), Vec2.mul(dir, 6.0));
                    Fx.derive(14, w#t, (_i, rand, t) -> {
                        let u = Num.wrapTo(1.0, t * (0.5 + rand(0) * 0.4) + rand(1));
                        let p0 = Vec2.add(Vec2.add(start, Vec2.mul(dir, u * 30.0)), Vec2.mul({ x = -dir#y, y = dir#x }, (rand(2) - 0.5) * 22.0 * (0.4 + u)));
                        RawDraw.lineSeg(p0, Vec2.add(p0, Vec2.mul(dir, 5.0 + rand(3) * 4.0)), 1.3, theme#foam, 0)
                            |> Render.overItem(Render.fade((1.0 - u) * 0.7 * w#blend))
                    })
            });
        List.append(rim, spills)

    /// せき止めた池の水位の札（外の潮との段差を数でも読ませる）。
    def poolTag(atlas: FontAtlas, w: In): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let cells = Set.toList(raisedCells(w));
        if (List.isEmpty(cells)) Nil
        else {
            let n = Int32.toFloat64(List.length(cells));
            let mid = cells |> List.foldLeft((acc, c) -> Vec2.add(acc, Vec2.div(Layout.centerOf(c), n)), Vec2.zero());
            let top = cells |> List.foldLeft((acc, c) -> Float64.min(acc, Layout.centerOf(c)#y), mid#y);
            let level = cells |> List.foldLeft((acc, c) -> Int32.max(acc, Map.getWithDefault(c, 0, w#now#water)), 0);
            let label = "潮だまり 水位 ${level} ・ 外の潮 ${Board.tideAt(w#now#t, w#board)}";
            let size = { x = TextDraw.width(label, atlas, 9.0) + 10.0, y = 14.0 };
            let at = Vec2.sub({ x = mid#x, y = top - Layout.cell() * 0.62 }, Vec2.mul(size, 0.5));
            { at = at, item = RawDraw.box(size, theme#shadow, 0) |> Render.rounded(7.0) |> Render.fade(0.62 * w#blend) }
                :: { at = { x = at#x + 5.0, y = at#y + 1.5 }, item = Render.textTinted(label, atlas, 9.0, theme#foam, 0) |> Render.fade(w#blend) }
                :: Nil
        }

    /// 盤のマスの角に置く小さな点（遊べる範囲とマス目を読ませるが、地形の形は消さない）。
    def gridMarks(w: In): List[Render.PlacedItem] =
        let ink = ThemeDoc.rec(w#theme)#ink;
        List.range(0, w#board#rows + 1) |> List.flatMap(y -> List.range(0, w#board#cols + 1) |> List.map(x ->
            RawDraw.circleAt({ x = Int32.toFloat64(x) * Layout.cell(), y = Int32.toFloat64(y) * Layout.cell() }, 1.1, ink, 0)
                |> Render.overItem(Render.fade(0.3))))

    /// 先読み: 次の 1 手の後の水際を、流れる破線で盤に重ねる（Into the Breach の「次に起きること」）。
    /// 沈むマスを淡く塗り、新しく水際になる辺だけを破線にする。1 手の動きの間は動きに合わせて濃くなる。
    def forecast(w: In): List[Render.PlacedItem] =
        let color = Layout.forecastColor(w#theme);
        let strength = RulesDoc.rec(w#rules)#forecastAlpha * w#blend;
        let wetNow = wetCells(w, w#now);
        let boardNext = Set.difference(Set.union(World.submergedCells(w#board, w#now), w#forecast#flooding), w#forecast#emerging);
        let wetNext = Set.union(boardNext, seaWet(w, w#now#t + 1));
        let key = (a: Vec2.Vec2, b: Vec2.Vec2) -> (toCell(a#x + b#x), toCell(a#y + b#y));
        let shoreNow = outline(w, wetNow) |> List.map(match (a, b) -> key(a, b)) |> List.toSet;
        let wash = polys({ color = color, alpha = strength * (0.22 + 0.06 * Sway.wave(w#t, 0.0, 1.1)), blend = DrawCmd.BlendMode.Normal },
            waterMask(w, w#forecast#flooding));
        let edge = outline(w, wetNext) |> List.filter(match (a, b) -> not Set.memberOf(key(a, b), shoreNow))
            |> List.flatMap(match (a, b) -> HudView.dashed(a, b,
                { width = 2.2, dash = 3.5, shift = w#t * 6.0 + a#x * 0.37 + a#y * 0.21, color = color }))
            |> List.map(Render.overItem(Render.fade(Float64.min(1.0, strength * 2.0))));
        List.append(wash, edge)

    /// 待つとヤドカリが流されるなら、足元に朱の破線の輪を出す（動かないと流される）。
    def crabWarning(w: In): List[Render.PlacedItem] =
        if (not w#forecast#crabWashed) Nil
        else {
            let c = Vec2.add(Layout.centerOf(w#now#crab), { x = 2.0, y = 1.0 });
            let r = 23.0 + 1.2 * Sway.wave(w#t, 0.0, 2.0);
            let n = 16;
            let at = k -> { let a = Int32.toFloat64(k) / Int32.toFloat64(n) * Vec2.tau() + w#t * 0.4;
                            { x = c#x + Vec2.cos(a) * r, y = c#y + Vec2.sin(a) * r * 0.8 } };
            List.range(0, n) |> List.map(k ->
                RawDraw.lineSeg(at(k), Vec2.add(at(k), Vec2.mul(Vec2.sub(at(k + 1), at(k)), 0.55)), 2.0,
                                ThemeDoc.rec(w#theme)#accent, 0) |> Render.overItem(Render.fade(0.85 * w#blend)))
        }

    /// 流された: 左から波が盤を横切り（泡の筋の束）、通った後を水の色で薄く覆う。画面の座標。
    def washedWave(w: In): List[Render.PlacedItem] =
        if (w#now#phase != World.Phase.Washed) Nil
        else {
            let theme = ThemeDoc.rec(w#theme);
            let front = -60.0 + Num.clamp01(w#age / 0.9) * 560.0;
            let fading = 1.0 - Num.clamp01((w#age - 0.9) / 0.6);
            let veil = { at = Vec2.zero(), item = RawDraw.polygon({ x = 0.0, y = 0.0 } :: { x = Float64.max(0.0, front), y = 0.0 }
                :: { x = Float64.max(0.0, front - 40.0), y = World.height() } :: { x = 0.0, y = World.height() } :: Nil, theme#sea, 0)
                |> Render.fade(0.22) };
            veil :: Fx.derive(48, w#t, (_i, rand, _t) -> {
                let y = rand(0) * World.height();
                let x = front - rand(1) * 90.0 - y * 0.11;
                RawDraw.lineSeg({ x = x, y = y }, { x = x + 14.0 + rand(2) * 26.0, y = y - 2.0 }, 1.2 + rand(3) * 1.6, theme#foam, 0)
                    |> Render.overItem(Render.fade((1.0 - rand(1)) * 0.75 * fading))
            })
        }

    /// 画面の四隅を影の色へ沈める（光の当たる盤の中央へ目を集める）。
    def vignette(): List[Render.PlacedItem] =
        Render.darkAt({ at = { x = -40.0, y = -30.0 }, radius = 190.0, strength = 0.35, z = 0 })
            :: Render.darkAt({ at = { x = -30.0, y = 400.0 }, radius = 210.0, strength = 0.4, z = 0 })
            :: Render.darkAt({ at = { x = 470.0, y = 410.0 }, radius = 170.0, strength = 0.3, z = 0 }) :: Nil

    /// 前の置き場所から今の置き場所へ動いた物を 1 つだけ選び、blend で間を進める（他はその場）。
    def slide(w: In, before: Set[Cell], now: Set[Cell]): List[PropView.Piece] =
        let (gone, came) = (Set.toList(Set.difference(before, now)), Set.toList(Set.difference(now, before)));
        Set.toList(now) |> List.map(c -> match (gone, came) {
            case (origin :: Nil, dest :: Nil) if dest == c =>
                { cell = c, at = Vec2.lerp(Layout.centerOf(origin), Layout.centerOf(c), Num.clamp01(w#blend)) }
            case _ => { cell = c, at = Layout.centerOf(c) }
        })

    /// ヤドカリ: 2 マスの間を進み、クリアでは巻き貝へ縮んで入り、流されると回りながら右下へ流れる。
    def propIn(w: In): PropView.In =
        let at = Vec2.lerp(Layout.centerOf(w#before#crab), Layout.centerOf(w#now#crab), Num.clamp01(w#blend));
        let (scale, turn, drift) = match w#now#phase {
            case World.Phase.Cleared => (1.0 - Num.clamp01((w#age - 0.35) / 0.55), 0.0, Vec2.zero())
            case World.Phase.Washed  =>
                let k = Num.clamp01(w#age / 1.2);
                (1.0 - 0.25 * k, k * 2.4, { x = k * 26.0, y = k * 14.0 })
            case World.Phase.Playing => (1.0, 0.0, Vec2.zero())
        };
        { t = w#t, board = w#board, wet = World.submergedCells(w#board, w#now),
          pebbles = slide(w, w#before#pebbles, w#now#pebbles), driftwood = slide(w, w#before#driftwood, w#now#driftwood),
          crab = { at = Vec2.add(at, drift), scale = scale, turn = turn }, theme = w#theme }

    // ── 終了の確認の窓（Layer.Prompt） ──

    /// Esc か閉じるボタンで出る確認。場面を薄く沈める幕・窓・文言（文言は tidepool.rules.json の quitPrompt）。
    /// 窓の中を押すと QuitYes・外を押すと QuitNo（blocking が奥の当たりを塞ぐ）。
    def quitPrompt(ctx: App.ViewCtx, w: In): ZStack.Tree[Layer, World.Press] =
        if (not w#askingQuit) ZStack.leaf(Nil)
        else {
            let theme = ThemeDoc.rec(w#theme);
            let size = { x = World.width() * 0.6, y = 48.0 };
            let at = { x = (World.width() - size#x) / 2.0, y = (World.height() - size#y) / 2.0 };
            let window =
                { at = Vec2.zero(), item = RawDraw.box({ x = World.width(), y = World.height() }, theme#shadow, 0)
                                             |> Render.fade(0.6) }
                    :: { at = at, item = RawDraw.box(size, theme#panel, 1) |> Render.rounded(6.0) }
                    :: TextDraw.centeredAt({ text = w#quitPrompt, atlas = ctx#atlas, size = 16.0,
                                             color = theme#ink, z = 2,
                                             center = { x = World.width() / 2.0, y = World.height() / 2.0 } })
                    :: Nil;
            ZStack.blocking(Some(World.Press.QuitNo),
                ZStack.of(ZStack.leaf(window) :: ZStack.hit(World.Press.QuitYes, { position = at, size = size }) :: Nil))
        }

    // ── 画面の縁の枠（静的な層） ──

    /// 画面の四辺に敷く細い枠。動かないので Main が App.withStaticLayer で 1 度だけ GPU に作る。
    pub def frameBorder(theme: ThemeDoc.Doc): List[Render.PlacedItem] =
        let color = ThemeDoc.rec(theme)#shadow;
        let z = SortingLayer.bottom(Layer.Frame);
        let edge = 3.0;
        let rect = (x, y, rw, rh) -> { at = Vec2.zero(), item = RawDraw.polygon(
            { x = x, y = y } :: { x = x + rw, y = y } :: { x = x + rw, y = y + rh } :: { x = x, y = y + rh } :: Nil, color, z) };
        rect(0.0, 0.0, World.width(), edge)
            :: rect(0.0, World.height() - edge, World.width(), edge)
            :: rect(0.0, 0.0, edge, World.height())
            :: rect(World.width() - edge, 0.0, edge, World.height()) :: Nil

    /// 静的な層の鍵。枠の中身を決める入力（色）を 1 つの文字列にまとめる。
    pub def staticKey(theme: ThemeDoc.Doc): String =
        let c = ThemeDoc.rec(theme)#shadow;
        "border:${c#r},${c#g},${c#b}"
}
