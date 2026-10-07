// Terrain — 「どのセル文字に、どの質感(Material.Spec)を着せるか」の表と rows アダプタ。
// 表(Entry)は呼び側が注入し、Terrain はそれを消費して DualGrid・Material への描画へ写すだけ
// — Terrain 自身は Theme も Doc も知らない。
// 初学者向けの概念説明は docs/dual-grid.md。

pub mod Terrain {

    /// 表の1行(Surfaces.Entry の一般形)。spec = Material.Spec なので、
    /// 立体感(持ち上げ壁)は spec#height = Material.HeightProfile.Lifted({...}) で表に乗る
    /// — height のために別フィールドは持たない(Doc からの接続は TerrainDoc.specOf)。
    /// 責務の線引き: spec は TerrainDoc.specOf が EntryDoc+resolver から生成する
    /// (色と height の解決は TerrainDoc の責務)。Terrain は spec を消費するだけ。
    /// flagsAt = 角の埋まり方の読み方、cells = このセル種の座標集合(表面演出と岸の判定用)、
    /// z = 塗り・フチの stroke・表面(粒とむら)の重なり順。
    pub type alias Entry = {
        flagsAt = ((Int32, Int32)) -> DualGrid.Corner,
        cells   = Set[(Int32, Int32)],
        spec    = Material.Spec,
        z       = { fill = Int32, stroke = Int32, surface = Int32 }
    }

    // ════════════════════════════════════════════════════════
    // rows(文字格子)アダプタ — 「マップ=rows を塗るだけ」の入口
    // ════════════════════════════════════════════════════════

    /// rows から「この種のセル」の座標集合を拾う。
    pub def cellsOf(isKind: Char -> Bool, rows: List[String]): Set[(Int32, Int32)] =
        rows |> List.zipWithIndex |> List.flatMap(rowEntry -> {
            let (y, row) = rowEntry;
            String.toList(row) |> List.zipWithIndex |> List.filterMap(colEntry -> {
                let (x, ch) = colEntry;
                if (isKind(ch)) Some((x, y)) else None
            })
        }) |> List.toSet

    /// 角 (i, j) のまわり4セル(左上・右上・左下・右下)の埋まり方。
    pub def flagsOf(cells: Set[(Int32, Int32)]): ((Int32, Int32)) -> DualGrid.Corner =
        corner -> {
            let (i, j) = corner;
            { tl = Set.memberOf((i - 1, j - 1), cells),
              tr = Set.memberOf((i,     j - 1), cells),
              bl = Set.memberOf((i - 1, j    ), cells),
              br = Set.memberOf((i,     j    ), cells) }
        }

    /// デュアル格子の全角。セル格子 cols×rowCount に対し角は (cols+1)×(rowCount+1)、
    /// 北の行から順に返す(持ち上げ壁は南の行が北の行に重なる 2.5D の見た目)。
    pub def cornersOf(cols: Int32, rowCount: Int32): List[(Int32, Int32)] =
        List.range(0, rowCount + 1) |> List.flatMap(j ->
            List.range(0, cols + 1) |> List.map(i -> (i, j)))

    // ════════════════════════════════════════════════════════
    // 描画(角の並び順は呼び側 — 2.5D の重なりを呼び側が決める)
    // ════════════════════════════════════════════════════════

    /// 表の全エントリ×渡された角の、静止した見た目。
    /// z の不変式(呼び側契約): table の z は「ベース床の z < fill/stroke/surface < 前景(扉等)の z」
    /// の秩序を呼び側が保証する。この関数は z を検証しない(fail-open)。
    /// 静的なむら(blotch)は塗り・縁の後に重ねる — 同じ z の重なりは並び順が前後を決めるため、
    /// 表の順も見た目の一部。
    pub def staticItems(opts: { tileSize = Float64, styleMix = DualGrid.StyleMix },
                        table: List[Entry],
                        corners: List[(Int32, Int32)]): List[Render.PlacedItem] =
        table |> List.flatMap(entry ->
            List.append(
                corners |> List.flatMap(corner -> itemsAt(opts, entry, corner)),
                List.append(
                    mottleItemsOf(entry, opts#tileSize),
                    blotchItemsOf(entry, opts#tileSize))))

    /// 表面の時間演出(水のきらめきなど)。静止した見た目と違い毎フレーム呼ぶ —
    /// 状態は持たず、同じ時刻なら同じ絵(巻き戻しても揺れない)。
    /// セルごとに上下左右の隣も同じ種かを Material へ渡す — 岸(隣が別種)の側に粒が
    /// はみ出して外へ漏れないよう、Material が内側へ詰める/間引くため。
    pub def surfaceItems(tileSize: Float64, table: List[Entry],
                         time: Float64): List[Render.PlacedItem] =
        table |> List.flatMap(entry ->
            entry#cells |> Set.toList |> List.flatMap(cell ->
                Material.surfaceItems(entry#spec#surface, cell, tileSize,
                                      time, entry#z#surface, edgesOf(entry#cells, cell))))

    /// 面シェーダー等を地形の形どおりに抜くためのマスク多角形(ワールド座標)。
    /// 塗りに使うのと同じ DualGrid.resolve(丸角固定・揺らぎなし)を通すので、マスクの形は
    /// 画面に出る塗りと 1px も違わない。角ごとのタイル頂点は角の原点からの相対なので、
    /// 原点を足してワールド座標へ直す。
    pub def maskPolys(tileSize: Float64, flagsAt: ((Int32, Int32)) -> DualGrid.Corner,
                      corners: List[(Int32, Int32)]): List[List[Vec2.Vec2]] =
        corners |> List.flatMap(corner -> {
            let flags = flagsAt(corner);
            if (DualGrid.caseIndex(flags) == 0) Nil
            else {
                let tile = DualGrid.resolve({ tile = tileSize, corner = corner,
                                              style = DualGrid.CornerStyle.Round,
                                              jitter = 0.0 }, flags);
                let origin = DualGrid.originOf(tileSize, corner);
                tile#polys |> List.map(poly -> poly |> List.map(v -> Vec2.add(origin, v)))
            }
        })

    /// 教科書用の1発 API: Doc 由来の表 + rows → 置き場所つき描画(origin で盤ずらし)。
    /// 返すのは table に載った地形(石垣・畑など)だけ — ベース床は含めない。
    /// 床は角の変化形を持たないベタ塗りで DualGrid の仕事ではなく、呼び側(View)が
    /// 全セルに敷く — table に無い文字・未知文字が自動的に床へ落ちる fail-open は
    /// 「呼び側が下に床を敷いてある」ことで成立する。
    pub def fromRows(opts: { tileSize = Float64, origin = Vec2.Vec2,
                             styleMix = DualGrid.StyleMix },
                     table: List[{ char = Char, spec = Material.Spec,
                                   z = { fill = Int32, stroke = Int32, surface = Int32 } }],
                     rows: List[String]): List[Render.PlacedItem] =
        let rowCount = List.length(rows);
        let cols = rows |> List.map(String.length) |> List.foldLeft(Int32.max, 0);
        let entries = table |> List.map(tableRow -> {
            let cells = cellsOf(ch -> ch == tableRow#char, rows);
            { flagsAt = flagsOf(cells), cells = cells,
              spec = tableRow#spec, z = tableRow#z }
        });
        staticItems({ tileSize = opts#tileSize, styleMix = opts#styleMix },
                    entries, cornersOf(cols, rowCount))
            |> Render.movedAll(opts#origin)

    // ════════════════════════════════════════════════════════
    // 内部(1角ぶんの描画・むら・岸の判定)
    // ════════════════════════════════════════════════════════

    /// 1エントリ×1角の描画。埋まっていない角(ケース0)は形が無いので早めに抜ける。
    /// 角の形はエントリの forceStyle が無ければ styleMix で場所ごとに混ぜる。
    def itemsAt(opts: { tileSize = Float64, styleMix = DualGrid.StyleMix },
                entry: Entry, corner: (Int32, Int32)): List[Render.PlacedItem] =
        let flags = entry#flagsAt(corner);
        if (DualGrid.caseIndex(flags) == 0) Nil
        else {
            let style = entry#spec#forceStyle
                |> Option.getWithDefault(DualGrid.styleAt(opts#styleMix, corner));
            let tile = DualGrid.resolve({ tile = opts#tileSize, corner = corner, style = style,
                                          jitter = entry#spec#jitter }, flags);
            Material.place(entry#spec, tile, DualGrid.originOf(opts#tileSize, corner),
                           { fill = entry#z#fill, stroke = entry#z#stroke })
        }

    /// 1エントリぶんの静的なむら(セル単位。角単位の塗り・縁とは粒度が違う)。
    /// z は塗りと同じでなく surface — むら(円=sprite系)を塗り(多角形)と同じ z に置くと、
    /// 描画部の同 z 併合(sprite系が先)で塗りの下に沈んで見えなくなる。
    def blotchItemsOf(entry: Entry, tileSize: Float64): List[Render.PlacedItem] =
        match entry#spec#blotch {
            case None     => Nil
            case Some(fx) =>
                entry#cells |> Set.toList |> List.flatMap(cell ->
                    Material.blotchItems(fx, cell, tileSize, entry#z#surface))
        }

    /// 1エントリぶんのセル別の明度ゆらぎ(耕した畑のパッチワーク感)。mottle <= 0 は
    /// 描かない(fail-open 既定オフ)。白の薄箱をセルに重ねる — 白 α=t の重ねは
    /// lighten(fill, t) と等価なので、α = hash × mottle で「セルごとに fill を
    /// 0..mottle だけ白へ近づけた」市松のゆらぎになる。
    /// 境界側(隣が同種でない)は tile×0.3 内側へ詰める — デュアルグリッドの角の丸み・
    /// 欠き(最悪はひし形の 1/2 タイル)から食み出さないため。持ち上げ地形は天面と同じだけ
    /// 上へずらす(天面に乗る明度ゆらぎ = 石積みの石ごとの色違い)。
    /// z は blotch と同じ surface — 塗りと同 z だと sprite 系が先に併合されて沈むため。
    def mottleItemsOf(entry: Entry, tileSize: Float64): List[Render.PlacedItem] =
        if (entry#spec#mottle <= 0.0009)
            Nil
        else {
            let lift = match entry#spec#height {
                case Material.HeightProfile.Flat      => 0.0
                case Material.HeightProfile.Lifted(l) => l#height
            };
            let margin = tileSize * 0.3;
            entry#cells |> Set.toList |> List.filterMap(cell -> {
                let (x, y) = cell;
                let edges = edgesOf(entry#cells, cell);
                let x0 = Int32.toFloat64(x) * tileSize + (if (edges#w) 0.0 else margin);
                let x1 = Int32.toFloat64(x + 1) * tileSize - (if (edges#e) 0.0 else margin);
                let y0 = Int32.toFloat64(y) * tileSize - lift + (if (edges#n) 0.0 else margin);
                let y1 = Int32.toFloat64(y + 1) * tileSize - lift - (if (edges#s) 0.0 else margin);
                let alpha = entry#spec#mottle * DualGrid.hash(x, y, 45);
                if (x1 - x0 <= 0.5 or y1 - y0 <= 0.5) None
                else Some(
                    { at = { x = x0, y = y0 },
                      item = RawDraw.box({ x = x1 - x0, y = y1 - y0 },
                                        { r = 1.0, g = 1.0, b = 1.0 },
                                        entry#z#surface)
                          |> Render.fade(alpha) })
            })
        }

    /// このセルの上下左右の隣も同じ種か。cells は1種のセル集合なので、メンバー判定だけで
    /// 岸(隣が別種)が分かる — Material はマップを知らずに岸を扱える。
    def edgesOf(cells: Set[(Int32, Int32)], cell: (Int32, Int32)): Material.Edges =
        let (x, y) = cell;
        { n = Set.memberOf((x, y - 1), cells),
          s = Set.memberOf((x, y + 1), cells),
          e = Set.memberOf((x + 1, y), cells),
          w = Set.memberOf((x - 1, y), cells) }
}
