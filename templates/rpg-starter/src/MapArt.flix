// MapArt — マップ 1 枚の地面を、読んだ時に 1 回だけ「タイル層に載せる物」と「毎フレーム描く物」に分けた表。
// タイル層（App.withTileLayers）はアトラスから 16×16 ちょうどに切れる止まった絵だけ。コマの回る絵（水と岸）と
// 絵の無い仮の四角は毎フレーム描く側へ回し、見えているマスだけ描く（View が Grid.cellsIn で引く）。
// 家の影は地図から 1 回だけ組んで持つ（タイルの格子に乗らない半マスの帯なので、タイル層に載らない）。
mod MapArt {
    use fge::{PxSpriteAtlas, Render, TileData}
    use Sheet.SheetId

    /// タイル層 1 枚: どのファイルのアトラスの、何段目（0 = 地面・1 = 重ねる物）か。
    pub type alias Layer = { sheet = SheetId, depth = Int32, tiles = List[TileData] }

    /// layers = タイル層・moving = マス → 毎フレーム描く部品（段, 部品）・shadows = 家の影（world 座標）。
    pub type alias Rec = {
        layers = List[Layer],
        moving = Map[(Int32, Int32), List[(Int32, Sheet.Part)]],
        shadows = List[Render.PlacedItem]
    }

    /// WhyNot: 外で組ませない — タイル層と毎フレーム描く物の分け方は build がアトラスを見て決める。
    enum ArtOf(Rec)

    /// マップ 1 枚の地面の絵（作るのは build だけ）。
    pub type alias Art = ArtOf

    pub def rec(a: Art): Rec = match a { case ArtOf.ArtOf(r) => r }

    /// マップから組む。
    pub def build(palette: Palette.Palette, sheets: Map[SheetId, Sheet.Sheet], map: MapDoc.Doc): Art =
        let m = MapDoc.rec(map);
        let legend = Tileset.legendOf(m#tileset);
        let placed = forM (
            r <- List.range(0, m#height);
            c <- List.range(0, Vector.nth(r, m#grid) |> Option.map(Vector.length) |> Option.getWithDefault(0));
            layer <- Autotile.cellPartsAt(sheets, legend, m#grid, c, r) |> List.zipWithIndex
        ) yield {
            let (depth, part) = layer;
            (c, r, depth, part, srcOf(sheets, part))
        };
        let still = placed |> List.filterMap(match (c, r, depth, part, src) ->
            src |> Option.map(at -> ((part#sheet, depth), tileAt(c, r, at))));
        let layers = still |> List.foldLeft((acc, entry) -> {
            let (key, tile) = entry;
            Map.insertWith((fresh, old) -> fresh ::: old, key, tile :: Nil, acc)
        }, Map.empty())
            |> Map.toList |> List.map(match ((sheet, depth), tiles) -> { sheet = sheet, depth = depth, tiles = tiles });
        let moving = placed |> List.filter(match (_, _, _, _, src) -> Option.isEmpty(src))
            |> List.foldLeft((acc, entry) -> {
                let (c, r, depth, part, _) = entry;
                Map.insertWith((fresh, old) -> old ::: fresh, (c, r), (depth, part) :: Nil, acc)
            }, Map.empty());
        let shadows = Tileset.shadowsOf(m#tileset)
            |> Option.map(spec -> Autotile.dropShadows(palette, { +rows = m#rows | spec }, 0))
            |> Option.getWithDefault(Nil);
        ArtOf.ArtOf({ layers = layers, moving = moving, shadows = shadows })

    /// 部品がタイル層に載るなら、アトラスの中の左上（px）。コマが回る・絵が無い・16×16 でない物は None。
    def srcOf(sheets: Map[SheetId, Sheet.Sheet], part: Sheet.Part): Option[(Float64, Float64)] =
        let still = match part#pick {
            case Sheet.FramePick.Named(_) => true
            case Sheet.FramePick.Cycle(fps) => fps <= 0.0
        };
        if (not still) None
        else forM (
            sheet <- Map.get(part#sheet, sheets);
            frame <- Sheet.frameAt(sheet#doc, part#sprite, part#pick, 0.0);
            rect <- PxSpriteAtlas.regionOf(sheet#baked, part#sprite, frame);
            ok <- if (rect#size#x == Autotile.tile() and rect#size#y == Autotile.tile()) Some(rect#position) else None
        ) yield (ok#x, ok#y)

    def tileAt(c: Int32, r: Int32, src: (Float64, Float64)): TileData =
        let (sx, sy) = src;
        { px = { x = Int32.toFloat64(c) * Autotile.tile(), y = Int32.toFloat64(r) * Autotile.tile() }, srcX = sx, srcY = sy,
          flipH = false, flipV = false, alpha = 1.0, tint = { r = 1.0, g = 1.0, b = 1.0 } }
}
