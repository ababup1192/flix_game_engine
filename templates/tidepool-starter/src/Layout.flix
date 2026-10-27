// Layout — 盤のマスと画面の位置の対応（描く側の部品どうしが共有する寸法）。
// 盤の絵は 1 マス cell() の盤の座標で組み、最後に fitOf の倍率と置き場所で画面へ写す。
// 面の中で変わらない岩の段の形（rockLevelsOf）もここで作る。段のずらし量はここ、色と濃さは View.rockLevel。
mod Layout {

    use fge::{Color, DualGrid, Terrain, Vec2}

    /// 盤の座標の 1 マスの大きさ（px）。
    pub def cell(): Float64 = 44.0

    /// 盤を置ける画面の範囲の左上と高さ（幅は画面ごとに渡す）。
    def areaAt(): Vec2.Vec2 = { x = 8.0, y = 8.0 }


    /// 盤の座標 → 画面の座標の写し方（倍率と、盤の左上を置く所）。
    pub type alias Fit = { scale = Float64, offset = Vec2.Vec2 }

    /// 盤の大きさから、周りに外海を半マスずつ残して、幅 width の範囲の真ん中へ収める倍率と置き場所。
    pub def fitOf(cols: Int32, rows: Int32, width: Float64): Fit =
        let areaSize = { x = width, y = 344.0 };
        let span = { x = Int32.toFloat64(cols) * cell(), y = Int32.toFloat64(rows) * cell() };
        let scale = Float64.min(areaSize#x / (span#x + cell()), areaSize#y / (span#y + cell()));
        { scale = scale, offset = Vec2.add(areaAt(), Vec2.mul(Vec2.sub(areaSize, Vec2.mul(span, scale)), 0.5)) }

    /// マスの中心（盤の座標）。
    pub def centerOf(c: Board.Cell): Vec2.Vec2 =
        let (x, y) = c;
        { x = (Int32.toFloat64(x) + 0.5) * cell(), y = (Int32.toFloat64(y) + 0.5) * cell() }

    /// 先読み（次の 1 手の水際）の色。盤の上の破線と潮見表の破線を同じ色でつなぐ。
    pub def forecastColor(theme: ThemeDoc.Doc): Color =
        let t = ThemeDoc.rec(theme);
        Color.mix(t#sea, t#foam, 0.45)

    // ── 岩の段の形 ──

    /// 高さ level の段の形（盤の座標）。上面と、それをずらして縁だけ残した落ち影・崖の面・光の縁。
    pub type alias RockLevel = {
        level = Int32,
        top = List[List[Vec2.Vec2]],
        shadow = List[List[Vec2.Vec2]],
        cliff = List[List[Vec2.Vec2]],
        rim = List[List[Vec2.Vec2]]
    }

    /// 丸い角の 16 通りのタイル（caseIndex の順・ローカル座標）。作れるのは buildRoundTiles だけ、引けるのは roundTileAt だけ。
    enum RoundTileTable(Vector[DualGrid.Tile])

    pub type alias RoundTiles = RoundTileTable

    /// 丸い角の 16 通りを作る。
    /// WhyNot: 角ごとに DualGrid.resolve しない。丸い角の形は 4 マスの埋まり方だけで決まり、角の場所にも jitter にもよらない。
    pub def buildRoundTiles(): RoundTiles =
        let has = (k, bit) -> Int32.bitwiseAnd(k, bit) != 0;
        List.range(0, 16) |> List.map(k ->
            DualGrid.resolve({ tile = cell(), corner = (0, 0), style = DualGrid.CornerStyle.Round, jitter = 0.0 },
                             { tl = has(k, 8), tr = has(k, 4), bl = has(k, 2), br = has(k, 1) }))
            |> List.toVector |> RoundTileTable.RoundTileTable

    /// 埋まり方 flags の丸い角のタイル（ローカル座標）。
    pub def roundTileAt(tiles: RoundTiles, flags: DualGrid.Corner): DualGrid.Tile =
        let RoundTileTable.RoundTileTable(table) = tiles;
        Vector.get(DualGrid.caseIndex(flags), table)

    /// 角 1 個のタイル。丸い角は表から引き、それ以外（揺らぎが角の場所で変わる）はその場で作る。
    def tileOf(tiles: RoundTiles, spec: { tile = Float64, corner = Board.Cell, style = DualGrid.CornerStyle, jitter = Float64 },
               flags: DualGrid.Corner): DualGrid.Tile =
        if (spec#style == DualGrid.CornerStyle.Round) roundTileAt(tiles, flags)
        else DualGrid.resolve(spec, flags)

    /// 高さ 1〜maxHeight の段の形（低い段から）。落ち影は光（左上）の反対へ、段の高さぶん伸ばす。
    /// WhyNot: 毎フレーム組まない。岩の高さは面の中で変わらないのに、角ごとの多角形づくりが描く時間の大半を占める。
    pub def rockLevelsOf(b: Board.Board): List[RockLevel] =
        let corners = Terrain.cornersOf(b#cols, b#rows);
        let tiles = buildRoundTiles();
        let rise = 7.0;
        List.range(1, Board.maxHeight() + 1) |> List.map(level -> {
            let cells = Board.cells(b) |> List.filter(c -> Board.heightAt(c, b) >= level) |> List.toSet;
            let edge = offset -> blobsOf(tiles, corners, cells, offset, corner -> DualGrid.caseIndex(corner) != 15);
            { level = level, top = blobsOf(tiles, corners, cells, Vec2.zero(), _ -> true),
              shadow = edge({ x = rise + 2.0, y = rise + 4.0 }), cliff = edge({ x = 0.0, y = rise }), rim = edge({ x = -1.5, y = -1.5 }) }
        })

    /// マスの集合を corners の範囲で DualGrid の塊（角の丸い多角形の列・盤の座標）にする。jitter で縁を少し揺らす。
    /// keep で残す角を選ぶ（4 マスとも中の角を抜けば、上面の下に隠れる縁だけになる）。
    /// 4 マスとも中の角はただの正方形なので、行ごとに続いた所を 1 枚の長方形にまとめる（部品の数を抑える）。
    pub def blobsOf(tiles: RoundTiles, corners: List[Board.Cell], cells: Set[Board.Cell], offset: Vec2.Vec2,
                    keep: DualGrid.Corner -> Bool): List[List[Vec2.Vec2]] =
        let flags = Terrain.flagsOf(cells);
        let (full, edge) = corners |> List.filter(corner -> keep(flags(corner)))
            |> List.partition(corner -> DualGrid.caseIndex(flags(corner)) == 15);
        let runs = full |> List.sortBy(c -> (snd(c), fst(c))) |> List.foldLeft((acc, c) -> match acc {
            case (first, last) :: rest if snd(last) == snd(c) and fst(last) + 1 == fst(c) => (first, c) :: rest
            case _ => (c, c) :: acc
        }, Nil);
        let squares = runs |> List.map(match (first, last) -> {
            let a = Vec2.add(DualGrid.originOf(cell(), first), offset);
            let b = Vec2.add(Vec2.add(DualGrid.originOf(cell(), last), offset), { x = cell(), y = cell() });
            { x = a#x, y = a#y } :: { x = b#x, y = a#y } :: { x = b#x, y = b#y } :: { x = a#x, y = b#y } :: Nil
        });
        squares ::: (edge |> List.flatMap(corner -> {
            let tile = tileOf(tiles, { tile = cell(), corner = corner,
                style = DualGrid.styleAt({ round = 0.8, square = 0.0 }, corner), jitter = 4.0 }, flags(corner));
            let at = Vec2.add(DualGrid.originOf(cell(), corner), offset);
            tile#polys |> List.map(poly -> poly |> List.map(v -> Vec2.add(v, at)))
        }))
}
