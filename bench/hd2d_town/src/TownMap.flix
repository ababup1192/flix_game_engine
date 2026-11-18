// TownMap — タイル地図の Doc（town_avenue.map.json: ground・height・shape・objects の文字の格子・buildings・margin・camera・walk・variants）を読む。
// 文字は読む所で 1 回だけ enum へ変え、内側は enum で回す。座標は地図の列 c（東へ増える）と行 r（0 行目が一番北）。
mod TownMap {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 上の面の材質。Water = 床を下げて水面を張る水路。
    pub enum Ground with Eq, ToString {
        case Grass
        case Cobble
        case Dirt
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
    pub enum Ridge with Eq {
        case X
        case Y
    }

    /// 壁の材質（タイルの名前の頭）。
    pub enum Wall with Eq {
        case Plaster
        case Stone
    }

    /// 建物 1 つ。x・y・w・h = 足元の矩形（マス）・level = 床の高さのレベル・floors = 階数。
    pub type alias Building = { id = String, x = Int32, y = Int32, w = Int32, h = Int32, level = Int32, floors = Int32,
                                wall = Wall, ridge = Ridge, pitchDeg = Float64, overhang = Float64 }

    /// 地図のまわり。cells = 足すマスの数・level = 高さのレベル。
    pub type alias Margin = { cells = Int32, level = Int32 }

    /// カメラの写す範囲: 地面の点 anchor（列・行）を画面の上から v の高さに置き、その奥行きで画面の横幅が width m。
    /// targetZ = 写す範囲をそろえる面の高さ（m）・targetRow = ピントを合わせる行。
    pub type alias Frame = { anchorX = Float64, anchorRow = Float64, v = Float64, width = Float64, targetZ = Float64, targetRow = Float64 }

    /// 歩く隊列の 1 人。strip = 4 コマを横に並べた絵・tint = 色の掛け目（線形の値）。
    pub type alias Member = { strip = String, tint = Option[(Float64, Float64, Float64)] }

    /// 歩く台本: 先頭が col 列を fromRow 行から toRow 行まで北へ歩いて止まる。
    /// idleSec = 歩き出すまで・stopSec = カメラが止まるのにかける秒・holdSec = 止まった後に撮る秒・
    /// feetV = 先頭の足元の画面の高さ（上から）・groundFlowH = 画面の真ん中の行で地面が流れる速さ（画面の高さ / 秒）・
    /// frames = 歩きのコマの数・cycleTiles = コマが 1 巡する歩いた距離（マス）。
    pub type alias Walk = { col = Int32, fromRow = Int32, toRow = Int32, party = List[Member], frames = Int32, cycleTiles = Float64,
                            idleSec = Float64, stopSec = Float64, holdSec = Float64, feetV = Float64, groundFlowH = Float64 }

    /// 広場のにぎやかしの板 1 枚（地図の props 欄・Blender の build_props と同じ読み方）。sprite = 絵（assets からの相対）・col・row = マス・
    /// offX・offY = マスの真ん中からのずれ（m・offY は北が正）・z = 地面からの高さ（m）・frames・frameSec・seq・phase = 横 1 列の絵のコマ・
    /// flip = 左右を裏返す・sway = 揺れ（振れ幅 m と周期 秒）・shadow = 影の付け方・height = 板の高さ（m・無ければ絵の高さ）。
    pub type alias Decor = { sprite = String, col = Int32, row = Int32, offX = Float64, offY = Float64, z = Float64,
                             frames = Int32, frameSec = Float64, seq = List[Int32], phase = Float64, flip = Bool,
                             sway = Option[(Float64, Float64)], shadow = DecorShadow, height = Option[Float64] }

    /// 飾りの板の影（地図の shadow = 足元の影・cast = 太陽の影を落とす の組）。
    pub enum DecorShadow with Eq {
        case Full
        case FootOnly
        case CastOnly
        case NoShadow
    }

    /// 足元の影を置くか。
    pub def hasFootShadow(s: DecorShadow): Bool = s == DecorShadow.Full or s == DecorShadow.FootOnly

    /// 太陽の影を落とすか。
    pub def castsShadow(s: DecorShadow): Bool = s == DecorShadow.Full or s == DecorShadow.CastOnly

    /// 地図 1 枚。rows は行ごとの文字を enum にした物（行 r・列 c は Vector.get(c, Vector.get(r, …))）。
    /// heightStep = 1 レベルの m・curbRaise = 草のマスを道より上げる m（縁石）・coping = 段と水の縁に笠石を付けるか。
    pub type alias TownMap = { width = Int32, height = Int32, ground = Vector[Vector[Ground]], levels = Vector[Vector[Int32]],
                               shapes = Vector[Vector[Shape]], props = Vector[Vector[Prop]], buildings = List[Building],
                               heightStep = Float64, margin = Margin, frame = Frame, walk = Walk,
                               curbRaise = Float64, coping = Bool, decor = List[Decor] }

    /// path の地図を読む。variant = 使う差分の名前（"step" など・無ければ差分なし）。
    pub def load(variant: String, path: String): Result[String, TownMap] \ Fs.FileRead =
        DocJson.readJson(path)
            |> Result.mapErr(e -> "${path}: ${DocJson.describe(e)}")
            |> Result.flatMap(json -> decode(variant, json) |> Result.mapErr(why -> "${path}: ${why}"))

    /// JSON から地図を組む（文字の格子は ground の大きさにそろっている事を確かめる）。
    pub def decode(variant: String, json: Json): Result[String, TownMap] =
        forM (
            top <- objectOf("地図", json);
            groundRows <- rowsAt("ground", top);
            heightRows <- rowsAt("height", top);
            shapeRows <- rowsAt("shape", top);
            objectRows <- rowsAt("objects", top);
            buildings <- buildingsAt(top);
            walk <- walkAt(top);
            frame <- frameAt(top);
            _ <- sameSize(groundRows, heightRows :: shapeRows :: objectRows :: Nil)
        ) yield {
            let variantDoc = Map.get("variants", top) |> Option.flatMap(JsonCodec.expectObject)
                |> Option.flatMap(Map.get(variant)) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
            let marginDoc = Map.get("margin", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
            { width = groundRows |> List.head |> Option.map(String.length) |> Option.getWithDefault(0),
              height = List.length(groundRows),
              ground = gridOf(groundOf, groundRows),
              levels = gridOf(levelOf, heightRows),
              shapes = gridOf(ch -> if (ch == '^') Shape.Stairs else Shape.Flat, shapeRows),
              props = gridOf(propOf, objectRows),
              buildings = buildings,
              heightStep = JsonCodec.floatOr("heightStep", 1.0, top),
              margin = { cells = JsonCodec.intOr("cells", 10, marginDoc), level = JsonCodec.intOr("level", -2, marginDoc) },
              frame = frame, walk = walk,
              curbRaise = JsonCodec.floatOr("curbRaise", 0.0, variantDoc),
              coping = JsonCodec.boolOr("coping", false, variantDoc),
              decor = Map.get("props", top) |> Option.flatMap(JsonCodec.decodeList(decorOf)) |> Option.getWithDefault(Nil) |> List.filterMap(identity) }
        }

    def shadowOf(foot: Bool, cast: Bool): DecorShadow =
        if (foot and cast) DecorShadow.Full else if (foot) DecorShadow.FootOnly else if (cast) DecorShadow.CastOnly else DecorShadow.NoShadow

    /// props 欄の 1 件（案 park の物と、案の無い物だけ。行き来する move の物は読まない）。
    def decorOf(j: Json): Option[Option[Decor]] =
        JsonCodec.expectObject(j) |> Option.map(o -> {
            let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, o);
            let pair = (key: String) -> Map.get(key, o) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat));
            let at = pair("at") |> Option.getWithDefault(Nil);
            let off = pair("off") |> Option.getWithDefault(Nil);
            let nth = (xs: List[Float64], i: Int32) -> List.drop(i, xs) |> List.head |> Option.getWithDefault(0.0);
            let toInt = (v: Float64) -> Float64.round(v) |> Float64.tryToInt32 |> Option.getWithDefault(0);
            let sprite = JsonCodec.stringOr("sprite", "", o);
            let variant = JsonCodec.stringOr("variant", "park", o);
            if (variant != "park" or Map.memberOf("move", o) or sprite == "") None
            else Some({ sprite = if (String.contains(substr = "/", sprite)) sprite else "sprites/${sprite}",
                        col = toInt(nth(at, 0)), row = toInt(nth(at, 1)), offX = nth(off, 0), offY = nth(off, 1), z = num("z", 0.0),
                        frames = JsonCodec.intOr("frames", 1, o), frameSec = num("frameSec", 0.8),
                        seq = pair("seq") |> Option.getWithDefault(Nil) |> List.map(toInt), phase = num("phase", 0.0),
                        flip = JsonCodec.boolOr("flip", false, o),
                        sway = pair("sway") |> Option.flatMap(xs -> match xs {
                            case amp :: per :: _ => Some((amp, per))
                            case _               => None
                        }),
                        shadow = shadowOf(JsonCodec.boolOr("shadow", true, o), JsonCodec.boolOr("cast", true, o)),
                        height = Map.get("height", o) |> Option.flatMap(JsonCodec.expectFloat) })
        })

    def objectOf(label: String, json: Json): Result[String, Map[String, Json]] =
        JsonCodec.expectObject(json) |> Option.toOk("${label} がオブジェクトでない")

    def rowsAt(key: String, top: Map[String, Json]): Result[String, List[String]] =
        Map.get(key, top) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.toOk("${key} が文字列の配列でない")

    def sameSize(base: List[String], others: List[List[String]]): Result[String, Unit] =
        let shapeOf = (rows: List[String]) -> (List.length(rows), rows |> List.map(String.length) |> List.distinct);
        if (List.forAll(rows -> shapeOf(rows) == shapeOf(base), others)) Ok(()) else Err("ground・height・shape・objects の大きさが違う")

    def gridOf(cellOf: Char -> a, rows: List[String]): Vector[Vector[a]] =
        rows |> List.map(row -> String.toList(row) |> List.map(cellOf) |> List.toVector) |> List.toVector

    /// 地面の文字。知らない文字は草（地図の外と同じ）にする。
    def groundOf(ch: Char): Ground = match ch {
        case 'c' => Ground.Cobble
        case 'b' => Ground.Cobble
        case 'd' => Ground.Dirt
        case 'w' => Ground.Water
        case _   => Ground.Grass
    }

    /// 高さの文字（0〜9・a〜z で 10〜35）。知らない文字は 0。
    def levelOf(ch: Char): Int32 =
        String.indexOf(substr = String.toLowerCase(Char.toString(ch)), "0123456789abcdefghijklmnopqrstuvwxyz") |> Option.getWithDefault(0)

    def propOf(ch: Char): Prop = match ch {
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
        JsonCodec.expectObject(json) |> Option.map(b -> {
            let roof = Map.get("roof", b) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty());
            { id = JsonCodec.stringOr("id", "", b), x = JsonCodec.intOr("x", 0, b), y = JsonCodec.intOr("y", 0, b),
              w = JsonCodec.intOr("w", 1, b), h = JsonCodec.intOr("h", 1, b), level = JsonCodec.intOr("level", 0, b),
              floors = JsonCodec.intOr("floors", 1, b),
              wall = if (JsonCodec.stringOr("wall", "plaster", b) == "stone") Wall.Stone else Wall.Plaster,
              ridge = if (JsonCodec.stringOr("ridge", "y", roof) == "x") Ridge.X else Ridge.Y,
              pitchDeg = JsonCodec.floatOr("pitchDeg", 40.0, roof), overhang = JsonCodec.floatOr("overhang", 0.4, roof) }
        })

    def frameAt(top: Map[String, Json]): Result[String, Frame] =
        forM (
            camera <- Map.get("camera", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("camera が無い");
            frame <- Map.get("frame", camera) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("camera.frame が無い");
            anchor <- Map.get("anchor", frame) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.toOk("camera.frame.anchor が無い");
            ax <- List.head(anchor) |> Option.toOk("anchor の列が無い");
            ar <- List.drop(1, anchor) |> List.head |> Option.toOk("anchor の行が無い")
        ) yield {
            let targetRow = Map.get("target", camera) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat))
                |> Option.flatMap(xs -> List.drop(1, xs) |> List.head) |> Option.getWithDefault(ar);
            { anchorX = ax, anchorRow = ar, v = JsonCodec.floatOr("v", 0.72, frame), width = JsonCodec.floatOr("width", 16.3, frame),
              targetZ = JsonCodec.floatOr("targetZ", 1.5, camera), targetRow = targetRow }
        }

    def walkAt(top: Map[String, Json]): Result[String, Walk] =
        forM (
            walk <- Map.get("walk", top) |> Option.flatMap(JsonCodec.expectObject) |> Option.toOk("walk が無い");
            party <- Map.get("party", walk) |> Option.flatMap(JsonCodec.decodeList(memberOf)) |> Option.toOk("walk.party が読めない")
        ) yield { col = JsonCodec.intOr("col", 0, walk), fromRow = JsonCodec.intOr("fromRow", 0, walk), toRow = JsonCodec.intOr("toRow", 0, walk),
                  party = party, frames = JsonCodec.intOr("frames", 4, walk), cycleTiles = JsonCodec.floatOr("cycleTiles", 1.0, walk),
                  idleSec = JsonCodec.floatOr("idleSec", 3.0, walk), stopSec = JsonCodec.floatOr("stopSec", 0.7, walk),
                  holdSec = JsonCodec.floatOr("holdSec", 1.5, walk), feetV = JsonCodec.floatOr("feetV", 0.55, walk),
                  groundFlowH = JsonCodec.floatOr("groundFlowH", 0.14, walk) }

    def memberOf(json: Json): Option[Member] =
        JsonCodec.expectObject(json) |> Option.map(m -> {
            let tint = Map.get("tint", m) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.flatMap(rgbOf);
            { strip = JsonCodec.stringOr("strip", "", m), tint = tint }
        })

    def rgbOf(xs: List[Float64]): Option[(Float64, Float64, Float64)] = match xs {
        case r :: g :: b :: _ => Some((r, g, b))
        case _                => None
    }

    // ── マスを引く ──

    /// (c, r) が地図の中か。
    pub def inside(m: TownMap, c: Int32, r: Int32): Bool = c >= 0 and c < m#width and r >= 0 and r < m#height

    def cell(grid: Vector[Vector[a]], fallback: a, c: Int32, r: Int32): a =
        Vector.nth(r, grid) |> Option.flatMap(Vector.nth(c)) |> Option.getWithDefault(fallback)

    /// 地面の材質（地図の外は草）。
    pub def groundAt(m: TownMap, c: Int32, r: Int32): Ground = cell(m#ground, Ground.Grass, c, r)

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

    /// 起動の 1 行の知らせ。
    pub def describe(m: TownMap): String =
        "地図 ${Int32.toString(m#width)}×${Int32.toString(m#height)}・建物 ${Int32.toString(List.length(m#buildings))}・縁石 ${Float64.toString(m#curbRaise)} m"
}
