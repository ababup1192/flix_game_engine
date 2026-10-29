// Tileset — マップの 1 文字が「何を敷くか（Autotile.Cell）」と「通れるか（Passage）」の表。
// マップの Doc（assets/maps/*.map.json）は tileset の名前と文字の格子だけを持ち、絵と通れるかはここで引く。
// 文字の意味は振る舞いなので Doc に出さない（通れるかを JSON で書き換えると、当たりの決まりが Doc に漏れる）。
mod Tileset {
    use fge::{Vec2}
    use Sheet.SheetId
    use Autotile.Cell

    /// タイルの組（マップの Doc の tileset の値）。
    pub enum TilesetId with Eq, Order, ToString {
        case Village
        case House
        case World
        case Mine
        case MineDeep
    }

    /// Doc の名前 → 組。知らない名前は None（読む側が既定へ落として 1 行言う）。
    pub def idOf(name: String): Option[TilesetId] = match name {
        case "village" => Some(TilesetId.Village)
        case "house"   => Some(TilesetId.House)
        case "world"   => Some(TilesetId.World)
        case "mine"    => Some(TilesetId.Mine)
        case "mine_deep" => Some(TilesetId.MineDeep)
        case _         => None
    }

    pub def nameOf(id: TilesetId): String = match id {
        case TilesetId.Village => "village"
        case TilesetId.House   => "house"
        case TilesetId.World   => "world"
        case TilesetId.Mine    => "mine"
        case TilesetId.MineDeep => "mine_deep"
    }

    /// その組の小物（マップの props）の絵が入っているファイル。
    pub def sheetOf(id: TilesetId): SheetId = match id {
        case TilesetId.Village => SheetId.Town
        case TilesetId.House   => SheetId.Town
        case TilesetId.World   => SheetId.WorldMap
        case TilesetId.Mine    => SheetId.Mine
        case TilesetId.MineDeep => SheetId.Mine
    }

    /// 1 マスの通り方。
    ///   Walk = 歩ける / Block = 入れない / Counter = 入れないが、1 マス先の人と話せる（机・店の台）/
    ///   Door = 出入口のある所だけ入れる（出入口の無い扉は壁と同じ）。
    pub enum Passage with Eq, ToString {
        case Walk
        case Block
        case Counter
        case Door
    }

    /// 文字の通り方。凡例に無い文字は入れない。
    pub def passageOf(id: TilesetId, ch: Char): Passage =
        Map.getWithDefault(ch, Passage.Block, passagesOf(id))

    def passagesOf(id: TilesetId): Map[Char, Passage] = match id {
        case TilesetId.Village => Map#{
            '.' => Passage.Walk, ',' => Passage.Walk, '"' => Passage.Walk, '=' => Passage.Walk,
            ':' => Passage.Walk, 'F' => Passage.Walk, 'D' => Passage.Door
        }
        case TilesetId.House => Map#{
            '.' => Passage.Walk, 'k' => Passage.Counter
        }
        case TilesetId.World => Map#{
            '.' => Passage.Walk, ',' => Passage.Walk, 'n' => Passage.Walk, '=' => Passage.Walk, '&' => Passage.Walk,
            'H' => Passage.Walk, 'h' => Passage.Walk, 'V' => Passage.Door, 'M' => Passage.Door, 'C' => Passage.Door
        }
        case TilesetId.Mine     => minePassages()
        case TilesetId.MineDeep => minePassages()
    }

    /// 坑道の通り方。宝箱と扉はマップの objects（閉じた扉と宝箱のマスは WorldField が塞ぐ）。
    /// WhyNot: レール（= |）を歩けるマスにしない — レールを歩いて辿れると、トロッコと分かれ目のレバーを使わずに先へ行ける。
    /// トロッコを降りた所（レールの終わり）からは、隣の床へ歩いて出る。
    def minePassages(): Map[Char, Passage] = Map#{
        '.' => Passage.Walk, ',' => Passage.Walk,
        '<' => Passage.Door, '>' => Passage.Door
    }

    /// 文字 → 敷く物。
    pub def legendOf(id: TilesetId): Map[Char, Cell] = match id {
        case TilesetId.Village => villageLegend()
        case TilesetId.House   => houseLegend()
        case TilesetId.World   => worldLegend()
        case TilesetId.Mine    => mineLegend(warmKit())
        case TilesetId.MineDeep => mineLegend(deepKit())
    }

    /// 家の影を落とす決まり（落とさない組は None）。
    pub def shadowsOf(id: TilesetId): Option[{ casters = Set[Char], bottoms = Set[Char], receivers = Set[Char], colorKey = String }] =
        match id {
            case TilesetId.Village => Some({ casters = houseChars(), bottoms = wallChars(), receivers = grassChars(), colorKey = "fc0A" })
            case TilesetId.House   => None
            case TilesetId.World   => None
            case TilesetId.Mine    => None
            case TilesetId.MineDeep => None
        }

    // ── 村 ──

    def tileSize(): Vec2.Vec2 = { x = Autotile.tile(), y = Autotile.tile() }

    def townTile(sprite: String, placeholder: String): Sheet.Part = Sheet.part(SheetId.Town, sprite, "base", placeholder, tileSize())

    /// 草の上に小物を 1 枚重ねる（小物は透明の地に接地影まで描いてある）。
    def onGrass(sprite: String, placeholder: String): Cell =
        Cell.Over(Cell.Plain(townTile("grass", "fc1A")), townTile(sprite, placeholder))

    def townLakeEdges(): Autotile.EdgeNames =
        { sheet = SheetId.Town, base = "lake", side = "lake_", outer = "lake_", inner = "lake_in_", fps = 2.0, placeholder = "fc12" }

    /// 家の段ごとの文字。棟 R（煙突 c）・軒 E・壁 W（窓 O・扉 D・宿の看板 I・道具屋の看板 S）。
    def roofChars(): Set[Char] = Set#{'R', 'c'}
    def eaveChars(): Set[Char] = Set#{'E'}
    def wallChars(): Set[Char] = Set#{'W', 'O', 'D', 'I', 'S'}
    def houseChars(): Set[Char] = Set.union(roofChars(), Set.union(eaveChars(), wallChars()))

    /// 家の影を受ける地面の文字（道や石畳には落とさない）。Y は大きな木の下の草。
    def grassChars(): Set[Char] = Set#{'.', ',', '"', 'T', 'b', 'o', 'B', 'X', 'P', 'Y'}

    def span(prefix: String, placeholder: String): Autotile.SpanNames = { sheet = SheetId.Town, prefix = prefix, placeholder = placeholder }

    /// 村の凡例。w は泉の下の石畳・Y は大きな木・炉・金床など小物の下の草（どちらも絵は下の物と同じで、入れない）。
    def villageLegend(): Map[Char, Cell] = Map#{
        '.' => Cell.Plain(townTile("grass", "fc1A")),
        'Y' => Cell.Plain(townTile("grass", "fc1A")),
        ',' => Cell.Plain(townTile("flowers", "fc2A")),
        '"' => Cell.Plain(townTile("tall_grass", "fc0A")),
        '=' => Cell.Plain(townTile("path", "fc18")),
        ':' => Cell.Plain(townTile("cobble", "fc00")),
        'w' => Cell.Plain(townTile("cobble", "fc00")),
        'F' => Cell.Plain(townTile("field", "fc08")),
        '~' => Cell.Edged(Set#{'~'}, townLakeEdges()),
        'R' => Cell.Span(roofChars(), span("roof_", "fc16")),
        'c' => Cell.Plain(townTile("chimney", "fc16")),
        'E' => Cell.Span(eaveChars(), span("eave_", "fc06")),
        'W' => Cell.Span(wallChars(), span("wall_", "fc37")),
        'O' => Cell.Plain(townTile("wall_window", "fc37")),
        'D' => Cell.Plain(townTile("door", "fc17")),
        'I' => Cell.Plain(townTile("sign_inn", "fc28")),
        'S' => Cell.Plain(townTile("sign_item", "fc28")),
        'T' => onGrass("tree", "fc0A"),
        'b' => onGrass("bush", "fc0A"),
        'o' => onGrass("rock", "fc10"),
        'B' => onGrass("barrel", "fc17"),
        'X' => onGrass("crate", "fc17"),
        'P' => onGrass("signpost", "fc17"),
        '-' => onGrass("fence_h", "fc27"),
        '|' => onGrass("fence_v", "fc27")
    }

    // ── 家の中 ──

    def floor(): Cell = Cell.Plain(townTile("floor_wood", "fc08"))

    /// 家の中の凡例。x は家具（本棚・寝床）の下の床・k は机の下の床（どちらも絵は床のまま）。
    def houseLegend(): Map[Char, Cell] = Map#{
        '#' => Cell.Plain(townTile("wall_top", "ink")),
        'W' => Cell.Plain(townTile("wall_in", "fc37")),
        'O' => Cell.Plain(townTile("window_in", "fc21")),
        '.' => floor(),
        'x' => floor(),
        'k' => floor(),
        'p' => Cell.Over(floor(), townTile("pot", "fc17")),
        'h' => Cell.Over(floor(), townTile("chair", "fc17"))
    }

    // ── ワールドマップ ──

    def worldTile(sprite: String, placeholder: String): Sheet.Part = Sheet.part(SheetId.WorldMap, sprite, "idle", placeholder, tileSize())

    /// 海の岸の名前の組。湖と川も同じ絵。
    def seaEdges(): Autotile.EdgeNames =
        { sheet = SheetId.WorldMap, base = "sea", side = "sea_", outer = "sea_", inner = "sea_in_", fps = 2.0, placeholder = "fc12" }

    def forestEdges(): Autotile.EdgeNames =
        { sheet = SheetId.WorldMap, base = "forest", side = "forest_edge_", outer = "forest_", inner = "forest_in_",
          fps = 0.0, placeholder = "fc0A" }

    /// 水として数える文字（海・湖・川・橋。橋の下も水がつながり、橋の横に岸を出さない）。
    def waterChars(): Set[Char] = Set#{'~', 'H', 'h'}

    /// ワールドマップの凡例。森は歩ける（通り抜けられる林）。山と水は入れない。V（村）・M（坑道）・C（森の岩穴）は出入口のあるマスだけ入れる。
    /// Q のほこらは入れない（横に立つトトに話しかける）。C は森の塊の南の縁にだけ置き、森の縁の絵を選ぶ時は森として数える
    /// （数えないと、東西の隣の森が外角の絵に変わる）。
    def worldLegend(): Map[Char, Cell] = Map#{
        '.' => Cell.Plain(worldTile("plains", "fc2A")),
        ',' => Cell.Plain(worldTile("plains_b", "fc2A")),
        'n' => Cell.Plain(worldTile("hills", "fc1A")),
        '=' => Cell.Plain(worldTile("road", "fc18")),
        '&' => Cell.Edged(Set#{'&', 'C'}, forestEdges()),
        '^' => Cell.Plain(worldTile("mountain", "fc00")),
        'A' => Cell.Plain(worldTile("mountain_b", "fc00")),
        'S' => Cell.Plain(worldTile("mountain_snow", "fc10")),
        '~' => Cell.Edged(waterChars(), seaEdges()),
        'H' => Cell.Plain(worldTile("bridge_v", "fc17")),
        'h' => Cell.Plain(worldTile("bridge_h", "fc17")),
        'V' => Cell.Plain(worldTile("town", "fc16")),
        'M' => Cell.Plain(worldTile("mine", "fc08")),
        'Q' => Cell.Plain(worldTile("shrine", "fc10")),
        'C' => Cell.Plain(worldTile("cave_mouth", "fc00"))
    }

    // ── 坑道 ──

    /// 坑道の 1 階層ぶんの絵の名前（浅い B1・B2 は暖色、深い B3 は寒色で _deep）。lit = 照らされた床と影の床があるか。
    type alias MineKit = { rockTop = String, rockFace = String, floor = String, stairsDown = String, stairsUp = String,
                           rubble = String, lit = Bool }

    def warmKit(): MineKit =
        { rockTop = "rock_top", rockFace = "rock_face", floor = "floor", stairsDown = "stairs_down", stairsUp = "stairs_up",
          rubble = "rubble", lit = true }

    /// WhyNot: 照らされた床と影の床は暖色の絵にしか無いので、深い階は素の床のまま。
    def deepKit(): MineKit =
        { rockTop = "rock_top_deep", rockFace = "rock_face_deep", floor = "floor_deep", stairsDown = "stairs_down_deep",
          stairsUp = "stairs_up_deep", rubble = "rubble_deep", lit = false }

    /// 岩として数える文字（真下が岩の外なら正面の絵になる）。t はたいまつを掛けた壁・P は板の支柱。
    def rockChars(): Set[Char] = Set#{'#', 't', 'P'}

    def mineTile(sprite: String, placeholder: String): Sheet.Part = Sheet.part(SheetId.Mine, sprite, "base", placeholder, tileSize())

    /// レールとして数える文字（曲がり角は隣のこの文字から選ぶ。K は古い置き方のトロッコ）。
    def railChars(): Set[Char] = Set#{'=', '|', 'K'}

    def railNames(): Autotile.JoinNames =
        { h = mineTile("rail_h", "fc18"), v = mineTile("rail_v", "fc18"),
          ne = mineTile("rail_corner_ne", "fc18"), nw = mineTile("rail_corner_nw", "fc18"),
          se = mineTile("rail_corner_se", "fc18"), sw = mineTile("rail_corner_sw", "fc18") }

    def lakeEdges(): Autotile.EdgeNames =
        { sheet = SheetId.Mine, base = "lake_dark", side = "lake_dark_", outer = "lake_dark_", inner = "lake_dark_in_",
          fps = 2.0, placeholder = "fc02" }

    /// 坑道の凡例。床はたいまつの真下で照らされ（floor_lit）、壁の真下で影に沈む（floor_shadow）。
    /// x は小物（水晶の柱）の下の床・u はがれき・c は小さい水晶（どれも入れない）。
    def mineLegend(kit: MineKit): Map[Char, Cell] =
        let face = mineTile(kit#rockFace, "fc00");
        let floor = mineTile(kit#floor, "fc08");
        let floorCell = if (kit#lit)
                Cell.ByAbove((Set#{'t'}, mineTile("floor_lit", "fc18")) :: (rockChars(), mineTile("floor_shadow", "fc08")) :: Nil, floor)
            else Cell.Plain(floor);
        Map#{
            '#' => Cell.Wall(rockChars(), mineTile(kit#rockTop, "fc2D"), face),
            't' => Cell.Over(Cell.Plain(mineTile("rock_face_lit", "fc10")), Sheet.cycling(SheetId.Mine, "torch", 6.0, "fc27", tileSize())),
            'P' => Cell.Over(Cell.Plain(face), mineTile("beam", "fc17")),
            '.' => floorCell,
            'x' => floorCell,
            '=' => Cell.Joined(railChars(), railNames(), mineTile("rail_h", "fc18")),
            '|' => Cell.Joined(railChars(), railNames(), mineTile("rail_v", "fc18")),
            'K' => Cell.Over(Cell.Plain(mineTile("rail_h", "fc18")), mineTile("minecart", "fc2D")),
            'u' => Cell.Over(floorCell, mineTile(kit#rubble, "fc2D")),
            'c' => Cell.Over(floorCell, mineTile("crystal_s", "fc23")),
            '>' => Cell.Plain(mineTile(kit#stairsDown, "fc0C")),
            '<' => Cell.Plain(mineTile(kit#stairsUp, "fc0C")),
            ',' => Cell.Plain(Sheet.cycling(SheetId.Mine, "floor_crystal", 2.0, "fc03", tileSize())),
            '~' => Cell.Edged(Set#{'~'}, lakeEdges())
        }
}
