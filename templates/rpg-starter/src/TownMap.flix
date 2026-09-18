// TownMap — 街のタイル盤（TownMapDoc）をタイル層の宣言（TileLayerSpec）へ写す純関数。
// 盤の正典は Doc（assets/town.map.json）— ここには rows を持たない。
// GPU 経路（App.withTileLayers）も headless の描き出し（TileScene.toItems / PxSprite.draw）も
// 同じ関数を読む — 絵柄の正を 2 箇所に写経しないため。
mod TownMap {

    /// タイルアトラスのテクスチャ名。Main の withSpriteAtlases（GPU へ上げる側）と
    /// Tileset（敷く側）が同じ名前を指す — 食い違うとタイルが真っ白になる。
    pub def textureName(): String = "town_tiles"

    /// 盤の左上の world 座標。盤が design より大きいので中央寄せはせず (0,0) に固定する
    /// （world 座標 = マス×16。どこを映すかは camera が選ぶ）。
    pub def origin(): Vec2.Vec2 = { x = 0.0, y = 0.0 }

    /// 盤とアトラスからタイル層の宣言を組む。key は素の名前だけ — 盤・色票・sprite の
    /// Doc を読み直したとき（保存・F1）はエンジンが世代で自動的に作り直すので、
    /// 中身のハッシュやアトラスの key を織り込む必要はない。
    pub def spec(doc: TownMapDoc.Doc, baked: PxSpriteAtlas.Baked): TileLayerSpec =
        { key = "floor",
          tileSet = tilesetOf(baked),
          tiles = _ -> tiles(doc, baked),
          origin = origin(),
          zIndex = 0 }

    /// アトラス 1 枚ぶんの Tileset。margin / spacing は 0 — コマの位置は regionOf が
    /// 直接教えるので、切り出しの格子計算をここでやらない。
    def tilesetOf(baked: PxSpriteAtlas.Baked): Tileset =
        { atlasSource = { textureName = textureName(),
                          texWidth = Int32.toFloat64(baked#side),
                          texHeight = Int32.toFloat64(baked#side),
                          tileSize = World.tileSize(),
                          marginX = 0.0, marginY = 0.0,
                          spacingX = 0.0, spacingY = 0.0 } }

    /// rows の全マスを TileData の列へ。px は origin からの相対位置（マス座標 × 16px）。
    /// legend に無い文字・アトラスに無いコマは敷かない（fail-open: そのマスが空くだけで落ちない）。
    def tiles(doc: TownMapDoc.Doc, baked: PxSpriteAtlas.Baked): List[TileData] =
        let t = World.tileSize();
        TownMapDoc.rec(doc)#rows |> List.zipWithIndex |> List.flatMap(rowEntry -> {
            let (y, row) = rowEntry;
            String.toList(row) |> List.zipWithIndex |> List.flatMap(colEntry -> {
                let (x, _) = colEntry;
                let slot = groundTileAt(doc, x, y)
                    |> Option.flatMap(name -> PxSpriteAtlas.regionOf(baked, name, "idle"));
                match slot {
                    case None    => Nil
                    case Some(r) =>
                        ({ px = { x = Int32.toFloat64(x) * t, y = Int32.toFloat64(y) * t },
                           srcX = r#position#x, srcY = r#position#y,
                           flipH = false, flipV = false, alpha = 1.0,
                           tint = TileLayer.noTint() }: TileData) :: Nil
                }
            })
        })

    // ══════════════════════════════════════════════════════
    // タイル家族の選定（縁・角・バリエーション）
    // 境目がベタの直線で切り替わらないための核。rows には素材（g/p/w/#）しか書かず、
    // どの縁タイルを使うかはこの純関数が近傍から導く。
    // ══════════════════════════════════════════════════════

    /// (x, y) のマスに敷くタイル名。legend に無い文字は None（敷かない = fail-open）。
    pub def groundTileAt(doc: TownMapDoc.Doc, x: Int32, y: Int32): Option[String] =
        materialAt(doc, x, y) |> Option.map(m -> match m {
            case "tile_grass" => grassTileAt(doc, x, y)
            case "tile_water" => waterTileAt(doc, x, y)
            case "tile_pave"  => paveTileAt(doc, x, y)
            case other        => other
        })

    /// 石畳マスの選定: 水路を横切る所とその両隣（袂）は橋面になる。
    /// rows に橋の文字は無い — 道 'p' が水 'w' を横切る形を書けば橋になる。
    def paveTileAt(doc: TownMapDoc.Doc, x: Int32, y: Int32): String =
        if (isBridge(doc, x, y)
            or isBridge(doc, x + 1, y) or isBridge(doc, x - 1, y)
            or isBridge(doc, x, y + 1) or isBridge(doc, x, y - 1))
            "bridge_deck"
        else "tile_pave"

    /// 橋のマス: 道が南北または東西を水に挟まれている（=水路を渡っている）。
    pub def isBridge(doc: TownMapDoc.Doc, x: Int32, y: Int32): Bool =
        isPave(doc, x, y)
            and ((isWater(doc, x, y - 1) and isWater(doc, x, y + 1))
                 or (isWater(doc, x - 1, y) and isWater(doc, x + 1, y)))

    /// 橋面（橋 + 袂）を敷いたマスの一覧。View が欄干を立てる場所。
    pub def bridgeCells(doc: TownMapDoc.Doc): List[Grid.Cell] =
        List.range(0, TownMapDoc.rowCount(doc)) |> List.flatMap(y ->
            List.range(0, TownMapDoc.cols(doc)) |> List.filterMap(x ->
                if (groundTileAt(doc, x, y) == Some("bridge_deck"))
                    Some(({ x = x, y = y }: Grid.Cell))
                else None))

    /// マスの素材名（legend 経由）。盤の外は None。
    def materialAt(doc: TownMapDoc.Doc, x: Int32, y: Int32): Option[String] =
        List.nth(y, TownMapDoc.rec(doc)#rows)
            |> Option.flatMap(row -> List.nth(x, String.toList(row)))
            |> Option.flatMap(ch -> TownMapDoc.tileNameOf(doc, ch))

    def isPave(doc: TownMapDoc.Doc, x: Int32, y: Int32): Bool =
        materialAt(doc, x, y) |> Option.map(m -> m == "tile_pave")
            |> Option.getWithDefault(false)

    def isWater(doc: TownMapDoc.Doc, x: Int32, y: Int32): Bool =
        materialAt(doc, x, y) |> Option.map(m -> m == "tile_water")
            |> Option.getWithDefault(false)

    /// 水にとっての「岸」= 水でも橋でもない実在マス。盤の外は水の続きとみなす
    /// （画面端の水路に岸が生えて流れが止まって見えないように）。
    /// 橋のマスを岸にしないのは、橋の下に石積みが生えると水が堰き止まって見えるため。
    def isBank(doc: TownMapDoc.Doc, x: Int32, y: Int32): Bool =
        materialAt(doc, x, y)
            |> Option.map(m -> m != "tile_water" and not isBridge(doc, x, y))
            |> Option.getWithDefault(false)

    /// 芝マスの縁選定: 四方の石畳の並び → 縁/外角、斜めだけなら内角、
    /// どこにも無ければ 3 バリエーションを決定的に散らす（rows には書かない）。
    pub def grassTileAt(doc: TownMapDoc.Doc, x: Int32, y: Int32): String =
        let n = isPave(doc, x, y - 1);
        let e = isPave(doc, x + 1, y);
        let s = isPave(doc, x, y + 1);
        let w = isPave(doc, x - 1, y);
        match (n, e, s, w) {
            case (false, false, false, false) =>
                if      (isPave(doc, x + 1, y - 1)) "tile_grass_incorner_ne"
                else if (isPave(doc, x - 1, y - 1)) "tile_grass_incorner_nw"
                else if (isPave(doc, x + 1, y + 1)) "tile_grass_incorner_se"
                else if (isPave(doc, x - 1, y + 1)) "tile_grass_incorner_sw"
                else grassVariant(x, y)
            case (true,  true,  false, false) => "tile_grass_corner_ne"
            case (true,  false, false, true)  => "tile_grass_corner_nw"
            case (false, true,  true,  false) => "tile_grass_corner_se"
            case (false, false, true,  true)  => "tile_grass_corner_sw"
            case (true,  false, false, false) => "tile_grass_edge_n"
            case (false, true,  false, false) => "tile_grass_edge_e"
            case (false, false, true,  false) => "tile_grass_edge_s"
            case (false, false, false, true)  => "tile_grass_edge_w"
            // 3 方向以上に石畳（この盤には出ない形）は北→東の優先で決める。
            case (true,  _, _, _)             => "tile_grass_edge_n"
            case (_, _, _, _)                 => "tile_grass_edge_e"
        }

    /// 無地/草むら/小花の散らし（マス座標から決定的に）。
    def grassVariant(x: Int32, y: Int32): String =
        let h = Hash01.at(y, x);
        if (h < 0.62) "tile_grass_a"
        else if (h < 0.88) "tile_grass_b"
        else "tile_grass_c"

    /// 水マスの岸選定: 四方の岸の並び → 縁/角。岸が無ければただの水。
    /// 北隣が橋なら岸でなく「橋の落ち影」タイル（影は南の水面に落ちる）。
    pub def waterTileAt(doc: TownMapDoc.Doc, x: Int32, y: Int32): String =
        let n = isBank(doc, x, y - 1);
        let e = isBank(doc, x + 1, y);
        let s = isBank(doc, x, y + 1);
        let w = isBank(doc, x - 1, y);
        if (isBridge(doc, x, y - 1))
            (if (w) "tile_water_shadow_nw"
             else if (e) "tile_water_shadow_ne"
             else "tile_water_shadow_n")
        else match (n, e, s, w) {
            case (false, false, false, false) => "tile_water"
            case (true,  true,  false, false) => "tile_water_corner_ne"
            case (true,  false, false, true)  => "tile_water_corner_nw"
            case (false, true,  true,  false) => "tile_water_corner_se"
            case (false, false, true,  true)  => "tile_water_corner_sw"
            case (true,  false, false, false) => "tile_water_edge_n"
            case (false, true,  false, false) => "tile_water_edge_e"
            case (false, false, true,  false) => "tile_water_edge_s"
            case (false, false, false, true)  => "tile_water_edge_w"
            case (true,  _, _, _)             => "tile_water_edge_n"
            case (_, _, _, _)                 => "tile_water_edge_e"
        }

    // ── 水面（シェーダーの面が覆う範囲）──

    /// 水の全マスを覆う外接矩形（シェーダー面の rect）。水が無ければ None。
    pub def waterRect(doc: TownMapDoc.Doc): Option[Rect2.Rect2] =
        let t = World.tileSize();
        let cells = waterCells(doc);
        match (cells |> List.map(c -> c#x) |> List.minimum,
               cells |> List.map(c -> c#y) |> List.minimum,
               cells |> List.map(c -> c#x) |> List.maximum,
               cells |> List.map(c -> c#y) |> List.maximum) {
            case (Some(x0), Some(y0), Some(x1), Some(y1)) =>
                Some({ position = { x = Int32.toFloat64(x0) * t, y = Int32.toFloat64(y0) * t },
                       size = { x = Int32.toFloat64(x1 - x0 + 1) * t,
                                y = Int32.toFloat64(y1 - y0 + 1) * t } })
            case _ => None
        }

    /// シェーダー面のマスク矩形（水マスごとに 1 枚）。岸の石積み（4px）と橋の落ち影（4px）は
    /// タイルの絵を活かしたいので、その分だけ内側へ縮める — 継ぎ目はタイル側が受け持つ。
    pub def waterMaskRects(doc: TownMapDoc.Doc): List[Rect2.Rect2] =
        let t = World.tileSize();
        waterCells(doc) |> List.map(cell -> {
            // タイル名の方角接尾辞から縮める辺を導く（"_edge_e" が "_e" を含む、の類の
            // 部分一致は誤爆するので endsWith で見る）。
            let name = waterTileAt(doc, cell#x, cell#y);
            let ends = suf -> String.endsWith(suffix = suf, name);
            let li = if (ends("_w") or ends("nw") or ends("sw")) 4.0 else 0.0;
            let ri = if (ends("_e") or ends("ne") or ends("se")) 4.0 else 0.0;
            let ti = if (ends("_n") or ends("ne") or ends("nw")
                         or String.contains(substr = "shadow", name)) 4.0 else 0.0;
            let bi = if (ends("_s") or ends("se") or ends("sw")) 4.0 else 0.0;
            { position = { x = Int32.toFloat64(cell#x) * t + li, y = Int32.toFloat64(cell#y) * t + ti },
              size = { x = t - li - ri, y = t - ti - bi } }
        })

    def waterCells(doc: TownMapDoc.Doc): List[Grid.Cell] =
        List.range(0, TownMapDoc.rowCount(doc)) |> List.flatMap(y ->
            List.range(0, TownMapDoc.cols(doc)) |> List.filterMap(x ->
                if (isWater(doc, x, y)) Some(({ x = x, y = y }: Grid.Cell)) else None))

    // ── 建物の設置（コード直書き。Doc 化は街の骨格が固まってから）──

    /// 建物の設置（種類と接地面の北西マス）。接地の歩行可否は rpg.map.json 側が
    /// 同じマスを '#' にして持つ（二重管理は承知の上。Doc 化のときに一本化する）。
    pub def buildings(): List[{ kind = String, cell = Grid.Cell }] =
           { kind = "house",  cell = { x = 10, y = 11 } }
        :: { kind = "shop",   cell = { x = 20, y = 4 } }
        :: { kind = "church", cell = { x = 2,  y = 10 } }
        :: Nil

    /// 種類ごとの接地面（マス）と絵の名前。壁は接地の南端に立ち、屋根は壁の上に載る。
    pub def buildingSpec(kind: String): { w = Int32, h = Int32, wall = String, roof = String } =
        match kind {
            case "shop"   => { w = 3, h = 3, wall = "shop_wall",   roof = "shop_roof" }
            case "church" => { w = 5, h = 4, wall = "church_wall", roof = "church_top" }
            case _        => { w = 4, h = 3, wall = "house_wall",  roof = "house_roof" }
        }

    /// 低い柵のマス（門の並びの隙間を塞ぐ）。当たりは rpg.map.json 側の '#' が持ち、
    /// テストが「柵のマスは塞がっている」ことを Doc と突き合わせる。
    pub def fences(): List[Grid.Cell] =
        { x = 9, y = 14 } :: Nil
}
