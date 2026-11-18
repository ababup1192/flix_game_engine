// TownMap — タイル地図の Doc（assets/town.map.json: ground・height・shape・objects の文字の格子・buildings・margin）を読む。
// 文字は読む所で 1 回だけ enum へ変え、内側は enum で回す。座標は地図の列 c（東へ増える）と行 r（0 行目が一番北）。
mod TownMap {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 上の面の材質。Water = 床を下げて水面を張る水路。
    pub enum Ground with Eq, Order, ToString {
        case Grass
        case Cobble
        case Water
    }

    /// マスの形。Stairs = 北へ上る階段（地図の "^"）。
    pub enum Shape with Eq {
        case Flat
        case Stairs
    }

    /// マスに置く物。Npc の数は地図の 1・2・3。
    pub enum Prop with Eq, ToString {
        case Tree
        case Cypress
        case Lamp
        case Crate
        case Bush
        case Hedge
        case Fence
        case Obelisk
        case Npc(Int32)
        case Empty
    }

    /// 切妻屋根の棟の向き。X = 東西（棟が横に通る）・Y = 南北（妻がカメラを向く）。
    pub enum Ridge with Eq, ToString {
        case X
        case Y
    }

    /// 壁の材質（タイルの名前の頭）。
    pub enum Wall with Eq {
        case Plaster
        case Stone
    }

    /// 建物 1 つ。x・y・w・h = 足元の矩形（マス）・level = 床の高さのレベル・floors = 階数・
    /// ridge・pitchDeg・overhang = 切妻屋根の棟の向き・勾配（度）・軒の出（m）。
    pub type alias Building = { id = String, x = Int32, y = Int32, w = Int32, h = Int32, level = Int32, floors = Int32,
                                wall = Wall, ridge = Ridge, pitchDeg = Float64, overhang = Float64 }

    /// 地図のまわり。cells = 足すマスの数・level = 高さのレベル・ground = 地面の材質・forest = 暗い森を立てるか。
    pub type alias Margin = { cells = Int32, level = Int32, ground = Ground, forest = Bool }

    /// 地図 1 枚。rows は行ごとの文字を enum にした物（行 r・列 c は Vector.get(c, Vector.get(r, …))）。
    /// heightStep = 1 レベルの m・curbRaise = 草のマスを道より上げる m（縁石）・coping = 段と水の縁に笠石を付けるか。
    pub type alias TownMap = { width = Int32, height = Int32, ground = Vector[Vector[Ground]], levels = Vector[Vector[Int32]],
                               shapes = Vector[Vector[Shape]], props = Vector[Vector[Prop]], buildings = List[Building],
                               heightStep = Float64, margin = Margin, curbRaise = Float64, coping = Bool }

    /// path の地図を読む。
    pub def load(path: String): Result[String, TownMap] \ Fs.FileRead =
        DocJson.readJson(path)
            |> Result.mapErr(e -> "${path}: ${DocJson.describe(e)}")
            |> Result.flatMap(json -> decode(json) |> Result.mapErr(why -> "${path}: ${why}"))

    /// JSON から地図を組む（文字の格子は ground の大きさにそろっている事を確かめる）。
    pub def decode(json: Json): Result[String, TownMap] =
        forM (
            top <- JsonCodec.expectObject(json) |> Option.toOk("地図がオブジェクトでない");
            groundRows <- rowsAt("ground", top);
            heightRows <- rowsAt("height", top);
            shapeRows <- rowsAt("shape", top);
            objectRows <- rowsAt("objects", top);
            buildings <- buildingsAt(top);
            _ <- sameSize(groundRows, heightRows :: shapeRows :: objectRows :: Nil)
        ) yield {
            let marginDoc = Map.get("margin", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
            { width = groundRows |> List.head |> Option.map(String.length) |> Option.getWithDefault(0),
              height = List.length(groundRows),
              ground = gridOf(groundOf, groundRows),
              levels = gridOf(levelOf, heightRows),
              shapes = gridOf(ch -> if (ch == '^') Shape.Stairs else Shape.Flat, shapeRows),
              props = gridOf(propOf, objectRows),
              buildings = buildings,
              heightStep = JsonCodec.floatOr("heightStep", 1.0, top),
              margin = { cells = JsonCodec.intOr("cells", 10, marginDoc), level = JsonCodec.intOr("level", -2, marginDoc),
                         ground = groundOf(firstChar(JsonCodec.stringOr("ground", "g", marginDoc))),
                         forest = JsonCodec.boolOr("forest", true, marginDoc) },
              curbRaise = JsonCodec.floatOr("curbRaise", 0.0, top),
              coping = JsonCodec.boolOr("coping", false, top) }
        }

    /// 文字列の頭の 1 字（空なら草の字）。
    def firstChar(s: String): Char = String.toList(s) |> List.head |> Option.getWithDefault('g')

    def rowsAt(key: String, top: Map[String, Json]): Result[String, List[String]] =
        Map.get(key, top) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.toOk("${key} が文字列の配列でない")

    def sameSize(base: List[String], others: List[List[String]]): Result[String, Unit] =
        let shapeOf = (rows: List[String]) -> (List.length(rows), rows |> List.map(String.length) |> List.distinct);
        if (List.forAll(rows -> shapeOf(rows) == shapeOf(base), others)) Ok(()) else Err("ground・height・shape・objects の大きさが違う")

    def gridOf(cellOf: Char -> a, rows: List[String]): Vector[Vector[a]] =
        rows |> List.map(row -> String.toList(row) |> List.map(cellOf) |> List.toVector) |> List.toVector

    /// 地面の文字。知らない文字は草（地図の外と同じ）にする。
    pub def groundOf(ch: Char): Ground = match ch {
        case 'c' => Ground.Cobble
        case 'b' => Ground.Cobble
        case 'w' => Ground.Water
        case _   => Ground.Grass
    }

    /// 高さの文字（0〜9・a〜z で 10〜35）。知らない文字は 0。
    def levelOf(ch: Char): Int32 =
        String.indexOf(substr = String.toLowerCase(Char.toString(ch)), "0123456789abcdefghijklmnopqrstuvwxyz") |> Option.getWithDefault(0)

    /// 物の字。知らない字は何も置かない。
    pub def propOf(ch: Char): Prop = match ch {
        case 'T' => Prop.Tree
        case 'C' => Prop.Cypress
        case 'L' => Prop.Lamp
        case 'X' => Prop.Crate
        case 'h' => Prop.Bush
        case 'H' => Prop.Hedge
        case 'f' => Prop.Fence
        case 'O' => Prop.Obelisk
        case '1' => Prop.Npc(1)
        case '2' => Prop.Npc(2)
        case '3' => Prop.Npc(3)
        case _   => Prop.Empty
    }

    def buildingsAt(top: Map[String, Json]): Result[String, List[Building]] =
        Map.get("buildings", top) |> Option.flatMap(JsonCodec.decodeList(buildingOf)) |> Option.toOk("buildings が読めない")

    def buildingOf(json: Json): Option[Building] =
        JsonCodec.expectObject(json) |> Option.map(b ->
            { id = JsonCodec.stringOr("id", "", b), x = JsonCodec.intOr("x", 0, b), y = JsonCodec.intOr("y", 0, b),
              w = JsonCodec.intOr("w", 1, b), h = JsonCodec.intOr("h", 1, b), level = JsonCodec.intOr("level", 0, b),
              floors = JsonCodec.intOr("floors", 1, b),
              wall = if (JsonCodec.stringOr("wall", "plaster", b) == "stone") Wall.Stone else Wall.Plaster,
              ridge = if (JsonCodec.stringOr("ridge", "y", b) == "x") Ridge.X else Ridge.Y,
              pitchDeg = JsonCodec.floatOr("pitchDeg", 40.0, b), overhang = JsonCodec.floatOr("overhang", 0.4, b) })

    // ── マスを引く ──

    /// (c, r) が地図の中か。
    pub def inside(m: TownMap, c: Int32, r: Int32): Bool = c >= 0 and c < m#width and r >= 0 and r < m#height

    def cell(grid: Vector[Vector[a]], fallback: a, c: Int32, r: Int32): a =
        Vector.nth(r, grid) |> Option.flatMap(Vector.nth(c)) |> Option.getWithDefault(fallback)

    /// 地面の材質（地図の外は margin の地面）。
    pub def groundAt(m: TownMap, c: Int32, r: Int32): Ground = cell(m#ground, m#margin#ground, c, r)

    /// 高さのレベル（地図の外は margin のレベル。ただし南の外（カメラの手前）は地図の一番南の行と同じ高さ）。
    // WhyNot: 南の外も margin の低い地面にしない — 地図の南の端の崖の面がカメラのすぐ前に横たわり、画面の下を屋根のような帯が横切る。
    pub def levelAt(m: TownMap, c: Int32, r: Int32): Int32 =
        if (inside(m, c, r)) cell(m#levels, 0, c, r)
        else if (r >= m#height and c >= 0 and c < m#width) cell(m#levels, 0, c, m#height - 1)
        else m#margin#level

    /// 南の外（カメラの手前）の地面の高さのレベル。
    pub def southLevel(m: TownMap): Int32 = cell(m#levels, m#margin#level, 0, m#height - 1)

    pub def shapeAt(m: TownMap, c: Int32, r: Int32): Shape = cell(m#shapes, Shape.Flat, c, r)

    pub def propAt(m: TownMap, c: Int32, r: Int32): Prop = cell(m#props, Prop.Empty, c, r)

    /// 水路の底は、マスの高さからこれだけ下げる（m）。
    pub def waterDrop(): Float64 = 0.9

    /// 水面は、マスの高さからこれだけ下げる（m）。
    pub def waterSurface(): Float64 = 0.35

    /// 1 階の高さ（壁タイル 3 段 = 下・窓・上）。
    pub def floorHeight(): Float64 = 3.0

    /// マスの上面の高さ（m）。水路は底・草は縁石の分だけ上げる・建物の足元は地面の高さ・南の外は一番南の行と同じ高さ。
    pub def topAt(m: TownMap, c: Int32, r: Int32): Float64 =
        if (r >= m#height and c >= 0 and c < m#width and m#height > 0) topAt(m, c, m#height - 1) else insideTopAt(m, c, r)

    def insideTopAt(m: TownMap, c: Int32, r: Int32): Float64 =
        let z = Int32.toFloat64(levelAt(m, c, r)) * m#heightStep;
        match groundAt(m, c, r) {
            case Ground.Water => z - waterDrop()
            case Ground.Grass => if (inside(m, c, r)) z + m#curbRaise else z
            case _            => z
        }

    /// 地図の座標の点 (x = 東, y = 北) の足の高さ（m）。平らなマスは上面・階段は 4 段の踏み面の前の縁・
    /// 階段の 1 つ手前（南）のマスは奥の 1/4 で最初の蹴上げ（1/4 段）まで上げる。
    // WhyNot: 階段の上を南の辺から北の辺への斜めの線にしない — 踏み面より最大 1/4 段沈み、足が段に埋まる。
    // WhyNot: 手前のマスを平らなまま段に入らせない — 段に入った瞬間に 1/4 段跳ねる。
    pub def groundZAt(m: TownMap, x: Float64, y: Float64): Float64 =
        let c = Float64.floor(x) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let fromSouth = Float64.floor(y) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        let r = m#height - 1 - fromSouth;
        let fy = y - Float64.floor(y);
        let isStair = (cc: Int32, rr: Int32) -> inside(m, cc, rr) and shapeAt(m, cc, rr) == Shape.Stairs;
        if (isStair(c, r)) Int32.toFloat64(levelAt(m, c, r)) * m#heightStep + Float64.min(fy + 0.25, 1.0) * m#heightStep
        else if (isStair(c, r - 1)) topAt(m, c, r) + Float64.max(0.0, fy - 0.75) * m#heightStep
        else topAt(m, c, r)

    /// 足元の建物を引く表（マス → 建物）。
    pub def footprints(m: TownMap): Map[(Int32, Int32), Building] =
        m#buildings |> List.flatMap(b -> List.range(b#y, b#y + b#h) |> List.flatMap(r -> List.range(b#x, b#x + b#w) |> List.map(c -> ((c, r), b))))
            |> List.toMap

    /// AO と側面のための高さ: 建物の足元は壁の上端まで埋まっているとみなす。階段は真ん中の高さ。
    pub def solidTopAt(m: TownMap, foot: Map[(Int32, Int32), Building], c: Int32, r: Int32): Float64 =
        match Map.get((c, r), foot) {
            case Some(b) => Int32.toFloat64(b#level) * m#heightStep + Int32.toFloat64(b#floors) * floorHeight()
            case None    =>
                let z = topAt(m, c, r);
                if (inside(m, c, r) and shapeAt(m, c, r) == Shape.Stairs) z + m#heightStep * 0.5 else z
        }

    /// マス (c, r) の真ん中の地図の座標（x = 東・y = 北）。
    pub def centerOf(m: TownMap, c: Int32, r: Int32): (Float64, Float64) =
        (Int32.toFloat64(c) + 0.5, Int32.toFloat64(m#height - 1 - r) + 0.5)
}
