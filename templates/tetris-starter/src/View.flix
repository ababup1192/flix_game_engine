// View — World から「(置き場所, 見せたい物) のリスト」への投影（純粋）。
// 盤・固定セル・落下中ミノ・着地予測（ゴースト）・NEXT・スコア・ライン消しの閃光・
// GAME OVER の幕を、World を読むだけで（変えずに）絵にする。幾何はここに閉じる。
//
// ── この画面の画風（AGENTS.local.md と同じ宣言）──
// 「生成りの紙に版で刷った積み木」。明るい紙の上に、彩度を落としたインクの色面が乗る。
//   色は 3 つ: 紙の生成り / 罫線の茶 / インクの濃い茶。ミノの 7 色はその上の刷り色。
//   やらないこと: 光らせない（Add ブレンドのネオンを使わない — 紙は発光しない）。
// **これは数ある画風の 1 つでしかない。** 真似してほしいのは「層に分けて、各層に役割を
// 持たせる」組み方の方で、色や効果ではない。別の作り方の例は `.claude/skills/visual-dict`。
//
// ── 画面の層（奥から手前へ。z が大きいほど手前）──
//    0  paper    … 紙（宣言シェーダーの面。繊維がごく遅く流れる）→ 面に質感・時間が流れる
//    1  board    … 盤の窪み（紙が一段沈んで見える）             → 面に階調
//    2  grid     … マス目の罫線
//    8  ghost    … 着地予測（下書きの薄い線）
//    9  drop     … 落下中のミノが紙に落とす影                    → 主役が背景から分離
//   10  locked   … 積んだマス（面 + 上の照り + 下の沈み）        → 面に階調
//   11  current  … 操作中のミノ（縁が息をする）                  → 主役が背景から分離・時間が流れる
//   20  clear    … ライン消しの閃光
//   HUD（30 NEXT・スコア / 40 幕）は withHudView 側 — world の z に関わらず必ず手前
//
// View は fail-open: 盤が空でも Doc が既定でも必ず何かを描く（プレイヤーの前で白画面にしない）。
mod View {

    use World.Cell

    // ── z 層 ──
    def zBg(): Int32 = 0
    def zBoard(): Int32 = 1
    def zGrid(): Int32 = 2
    def zGhost(): Int32 = 8
    def zDropShadow(): Int32 = 9
    def zLocked(): Int32 = 10
    def zCurrent(): Int32 = 11
    def zClear(): Int32 = 20
    def zHud(): Int32 = 30
    def zOverlay(): Int32 = 40

    // ── レイアウトの定数（project.json の design 256×352 と対）──
    def cell(): Float64 = 16.0                     // 1 マスの 1 辺（px）
    def originX(): Float64 = 16.0                   // 盤の左上 x（盤は x[16..176]）
    def originY(): Float64 = 16.0                   // 盤の左上 y（盤は y[16..336]）
    def panelX(): Float64 = 184.0                   // 右パネルの左端（NEXT・スコア）

    /// design の幅・高さ（背景の全面塗りに使う）。project.json と同じ値。
    def designW(): Float64 = 256.0
    def designH(): Float64 = 352.0

    pub def frame(_ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        List.flatten(
               background(w)
            :: gridLines(ThemeDoc.rec(w#theme))
            :: ghost(w)
            :: dropShadow(w)
            :: lockedCells(w)
            :: currentCells(w)
            :: clearFx(w)
            :: Nil)

    /// 画面固定の絵（NEXT・スコア・GAME OVER の幕）。App.withHudView へ繋ぐ —
    /// world 側の z がどれだけ大きくても、この絵は必ず手前に出る。
    pub def hud(ctx: App.ViewCtx, w: World.World): List[Render.PlacedItem] =
        List.flatten(
               nextPreview(ctx#atlas, w)
            :: hudPanel(ctx#atlas, w)
            :: overlay(ctx#atlas, w)
            :: Nil)

    // ── 盤面の座標（(col,row) → 画面座標） ──

    /// セルの中心の画面座標。
    def cellCenter(c: Int32, r: Int32): Vec2.Vec2 =
        { x = originX() + (Int32.toFloat64(c) + 0.5) * cell(),
          y = originY() + (Int32.toFloat64(r) + 0.5) * cell() }

    /// 1 マスを平らに塗る（中心置き・0.5px の隙間でマス目感を出す）。
    /// ゴーストと NEXT のように「そこに物は無い」印にはこちらを使う。
    def flatBlock(c: Int32, r: Int32, color: Color, z: Int32): Render.PlacedItem =
        RawDraw.boxAt(cellCenter(c, r), { x = cell() - 1.0, y = cell() - 1.0 }, color, z)

    /// 刷ったマス 1 つ。面 + 上辺の照り + 下辺の沈み の 3 枚を重ねる。
    /// 平らな 1 枚だけだと積み上がった山が「べた塗りの塊」になり、
    /// どこからどこまでが 1 マスかが読めなくなる（同じ色が隣り合うほど顕著）。
    def printedBlock(c: Int32, r: Int32, color: Color, z: Int32): List[Render.PlacedItem] =
        printedRect(cellCenter(c, r), cell() - 1.0, color, z)

    /// 刷った四角 1 つ（1 辺 side・中心置き）。盤のマスと NEXT のプレビューが共有する
    /// ので、盤の格子に縛られない形（中心と辺の長さ）で受ける。
    def printedRect(at: Vec2.Vec2, side: Float64, color: Color, z: Int32): List[Render.PlacedItem] =
           RawDraw.boxAt(at, { x = side, y = side }, color, z)
        :: RawDraw.boxAt({ x = at#x, y = at#y - side / 2.0 + 1.5 }, { x = side - 3.0, y = 3.0 },
               Color.warm(Color.lighten(color, 0.42), 0.10), z + 1)
        :: RawDraw.boxAt({ x = at#x, y = at#y + side / 2.0 - 1.0 }, { x = side, y = 2.0 },
               Color.cool(Color.darken(color, 0.42), 0.10), z + 1)
        :: Nil

    // ── 背景・枠・grid ──

    /// 紙（画素ごとの計算で塗る面）→ 盤の縁 → 盤の窪み。fail-open の土台（常に何か出る）。
    /// 紙は単色の四角ではなく、細かい繊維がごく遅く流れる面。何がどう効くかは Doc の note と
    /// engine の `docs/shader-doc.md` を参照。
    def background(w: World.World): List[Render.PlacedItem] =
        let theme = ThemeDoc.rec(w#theme);
        let boardW = Int32.toFloat64(World.cols()) * cell();
        let boardH = Int32.toFloat64(World.rows()) * cell();
        // 縁は盤より 2px 外に一回り大きく敷いてから、盤の窪みを上に重ねる（縁取りに見える）。
           Render.shaderFill(w#shader,
               { position = { x = 0.0, y = 0.0 }, size = { x = designW(), y = designH() } },
               w#t, zBg())
        :: { at = { x = originX() - 2.0, y = originY() - 2.0 },
             item = RawDraw.box({ x = boardW + 4.0, y = boardH + 4.0 }, theme#wall, zBg() + 1) }
        :: { at = { x = originX(), y = originY() },
             item = RawDraw.box({ x = boardW, y = boardH }, theme#board, zBoard()) }
        :: Nil

    /// マス目の薄い線（縦・横）。盤の手触りを出すだけの飾り。
    def gridLines(theme: ThemeDoc.Rec): List[Render.PlacedItem] =
        let boardW = Int32.toFloat64(World.cols()) * cell();
        let boardH = Int32.toFloat64(World.rows()) * cell();
        let verticals = List.range(1, World.cols()) |> List.map(c ->
            { at = { x = originX() + Int32.toFloat64(c) * cell(), y = originY() },
              item = RawDraw.box({ x = 1.0, y = boardH }, theme#grid, zGrid()) });
        let horizontals = List.range(1, World.rows()) |> List.map(r ->
            { at = { x = originX(), y = originY() + Int32.toFloat64(r) * cell() },
              item = RawDraw.box({ x = boardW, y = 1.0 }, theme#grid, zGrid()) });
        List.append(verticals, horizontals)

    // ── 固定セル・落下中ミノ・ゴースト ──

    /// 盤に固定されたセル（それぞれの Kind の色で）。
    def lockedCells(w: World.World): List[Render.PlacedItem] =
        Map.toList(w#board) |> List.flatMap(entry -> {
            let (cellPos, kind) = entry;
            let (c, r) = cellPos;
            printedBlock(c, r, ThemeDoc.colorOf(w#theme, kind), zLocked())
        })

    /// いま操作しているミノ。Clearing / GameOver 中は消える行や幕に集中させるため出さない。
    /// 積んだマスと同じ刷り方の上に、息をする縁を重ねる — 積み山の中で「いま動かせるのはこれ」が
    /// 一目で分かり、手を止めていても画面が静止しない。
    def currentCells(w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Playing =>
                let color = ThemeDoc.colorOf(w#theme, w#current#kind);
                let pulse = 0.5 + 0.5 * Sway.wave(w#t, 0.0, 0.8);
                let edge = { color = ThemeDoc.rec(w#theme)#flash,
                             alpha = 0.30 + 0.45 * pulse,
                             width = 1.0 };
                World.piecesCells(w#current) |> List.flatMap(cellPos -> {
                    let (c, r) = cellPos;
                    if (r < 0) Nil                       // 上にはみ出した分は描かない
                    else printedBlock(c, r, color, zCurrent())
                        |> List.map(item -> { item = Render.outlineA(edge, item#item) | item })
                })
            case _ => Nil
        }

    /// 落下中のミノが紙に落とす影（少し右下へずらした薄いインク）。
    /// 盤から浮いていることが分かるので、ゴースト（着地点）と混ざらない。
    def dropShadow(w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Playing =>
                World.piecesCells(w#current) |> List.filterMap(cellPos -> {
                    let (c, r) = cellPos;
                    if (r < 0) None
                    else {
                        let at = cellCenter(c, r);
                        Some(RawDraw.boxAt({ x = at#x + 2.0, y = at#y + 3.0 },
                            { x = cell() - 1.0, y = cell() - 1.0 }, ThemeDoc.rec(w#theme)#wall, zDropShadow()))
                    }
                }) |> Render.fadeAll(0.18)
            case _ => Nil
        }

    /// 着地予測（ゴースト）: current をこれ以上落ちない所まで落とした位置を薄い色で描く。
    /// 「Space でどこに落ちるか」が一目で分かる補助。Playing のときだけ。
    def ghost(w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Playing =>
                let landed = World.dropToBottom(w);
                pieceCells(landed#current, ThemeDoc.rec(w#theme)#ghost, zGhost())
                    |> Render.fadeAll(0.5)
            case _ => Nil
        }

    /// Piece の 4 マスを 1 色で描く（current・ghost・NEXT が共有）。
    def pieceCells(p: World.Piece, color: Color, z: Int32): List[Render.PlacedItem] =
        World.piecesCells(p) |> List.filterMap(cellPos -> {
            let (c, r) = cellPos;
            if (r < 0) None else Some(flatBlock(c, r, color, z))   // 上にはみ出した分は描かない
        })

    // ── ライン消しの演出（凝りすぎない: 閃光のストリップ + ソフトな光球）──
    // 進度 t（0→1）で薄れていく。t は clearTimer / clearDuration。
    def clearFx(w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.Clearing =>
                let t = Num.clamp01(w#clearTimer / Float64.max(0.0001, RulesDoc.rec(w#doc)#clearDuration));
                let fade = 1.0 - t;                                     // 1→0 に減衰
                let boardW = Int32.toFloat64(World.cols()) * cell();
                w#clearRows |> List.flatMap(r -> {
                    // 行全幅に閃光（白）を重ねる。
                    let rowFlash = { at = { x = originX(), y = originY() + Int32.toFloat64(r) * cell() },
                                     item = RawDraw.box({ x = boardW, y = cell() }, ThemeDoc.rec(w#theme)#flash, zClear())
                                         |> Render.fade(fade) };
                    // さらに各セルの中心に、紙が白く抜ける柔らかい丸を重ねる（閉形式で安全な glowAt）。
                    // Add でなく Normal なのは画風の決まり — 紙は発光しない（白へ抜けるだけ）。
                    let glows = List.range(0, World.cols()) |> List.flatMap(c ->
                        Render.glowAt(cellCenter(c, r), cell() * 0.75, ThemeDoc.rec(w#theme)#flash,
                            { alpha = 0.75 * (1.0 - t), blend = DrawCmd.BlendMode.Normal }, zClear() + 1));
                    rowFlash :: glows
                })
            case _ => Nil
        }

    // ── NEXT プレビュー ──

    /// 右パネルに "NEXT" と、次のミノを rot 0 で小さく描く。
    def nextPreview(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let label = { at = { x = panelX(), y = originY() },
                      item = Render.textTinted("NEXT", atlas, 10.0, ThemeDoc.rec(w#theme)#wall, zHud()) };
        // プレビューの原点（ラベルの下）。cellsOf の相対座標をここから並べる。
        let px0 = panelX();
        let py0 = originY() + 16.0;
        let s = cell() - 3.0;                          // 少し小さめのマス
        let color = ThemeDoc.colorOf(w#theme, w#nextKind);
        let blocks = Pieces.cellsOf(w#nextKind, 0) |> List.flatMap(cellPos -> {
            let (c, r) = cellPos;
            printedRect({ x = px0 + (Int32.toFloat64(c) + 0.5) * s,
                          y = py0 + (Int32.toFloat64(r) + 0.5) * s }, s - 1.0, color, zHud())
        });
        label :: blocks

    // ── HUD（スコア・ライン数）──

    def hudPanel(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        let x = panelX();
        // 文言はコードに直書きせず「見出し + 数」を組む。ラベルだけは UI の見出しなので固定でよい。
        let scoreY = 120.0;
        let linesY = 160.0;
           { at = { x = x, y = scoreY },
             item = Render.textTinted("SCORE", atlas, 9.0, ThemeDoc.rec(w#theme)#wall, zHud()) }
        :: { at = { x = x, y = scoreY + 12.0 },
             item = Render.textTinted(Int32.toString(w#score), atlas, 12.0,
                 Color.darken(ThemeDoc.rec(w#theme)#wall, 0.25), zHud()) }
        :: { at = { x = x, y = linesY },
             item = Render.textTinted("LINES", atlas, 9.0, ThemeDoc.rec(w#theme)#wall, zHud()) }
        :: { at = { x = x, y = linesY + 12.0 },
             item = Render.textTinted(Int32.toString(w#lines), atlas, 12.0,
                 Color.darken(ThemeDoc.rec(w#theme)#wall, 0.25), zHud()) }
        :: Nil

    // ── GAME OVER の幕 ──

    def overlay(atlas: FontAtlas, w: World.World): List[Render.PlacedItem] =
        match w#phase {
            case World.Phase.GameOver =>
                   { at = { x = 0.0, y = 0.0 },
                     item = RawDraw.box({ x = designW(), y = designH() },
                             Color.darken(ThemeDoc.rec(w#theme)#wall, 0.35), zOverlay())
                         |> Render.fade(0.62) }
                :: centered(atlas, "GAME OVER", 20.0, ThemeDoc.rec(w#theme)#flash, 150.0)
                :: centered(atlas, "PRESS SPACE", 10.0, ThemeDoc.rec(w#theme)#ghost, 180.0)
                :: Nil
            case _ => Nil
        }

    /// 盤の中央 x。幕（GAME OVER）は右パネルにかぶらないよう画面全幅でなく play エリアに合わせる。
    def boardCenterX(): Float64 = originX() + Int32.toFloat64(World.cols()) * cell() / 2.0

    /// 盤の中央にテキストを 1 行置く（幅はエンジンが実測して中央へ揃える）。
    def centered(atlas: FontAtlas, s: String, size: Float64, color: Color, y: Float64): Render.PlacedItem =
        TextDraw.centered({ text = s, atlas = atlas, size = size, color = color,
                            z = zOverlay() + 1, centerX = boardCenterX(), y = y })
}
