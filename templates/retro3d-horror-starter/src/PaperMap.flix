// PaperMap — 古びた紙のマップの中身（純粋）: 配置の表から、階ごとの間取りの線・行った部屋の丸と名前・階段の段を、
// 紙の上の画素の位置で組む。描くのは MapView（鉛筆の線の絵を貼る）。どの部屋に居るかを引くのもここ（World が行った部屋を覚える）。
//
// 紙の上の向き: 表の glTF の座標をそのまま見下ろす（左が西 = glTF の −X・上が北 = glTF の −Z）。engine の x は反転しているので戻して写す。
// 縮尺は全部の階を通して 1 つ（階を切り替えても建物の外形が動かない）。外形は床の板・部屋は表の rooms の四角。
mod PaperMap {
    use fge::{Hash01, Vec2, Vec3}
    use Layout.{Floor, Room}

    /// 紙の絵の左上（design px）と大きさ（map_paper.png と同じ 288×208）。
    pub def paperAt(): Vec2.Vec2 = { x = 16.0, y = 16.0 }

    pub def paperSize(): Vec2.Vec2 = { x = 288.0, y = 208.0 }

    /// 紙の上の線 1 本（design px）。
    pub type alias Seg = { a = Vec2.Vec2, b = Vec2.Vec2 }

    /// 行った部屋の印。label = 紙に書く名前（「1-2」「理科室」）・circle = 丸の絵の番号（1〜4）・tilt = 丸の傾き（回転数）。
    pub type alias Mark = { key = String, label = String, center = Vec2.Vec2, circle = Int32, tilt = Float64 }

    /// 1 階分の紙の中身。walls = 外形と部屋の仕切りの線・steps = 階段の段の線・marks = 行った部屋だけ。
    pub type alias Sheet = { floor = Int32, walls = List[Seg], steps = List[Seg], marks = List[Mark] }

    /// 世界（engine の x・z）を紙へ写す縮尺と原点。glX0 = 建物の西の端（glTF の x）・zMid = 建物の南北の真ん中・scale = 1 m の画素。
    pub type alias Frame = { glX0 = Float64, zMid = Float64, scale = Float64 }

    /// 平らな四角（glTF の x と z。紙の向き）。
    type alias Rect = { x0 = Float64, z0 = Float64, x1 = Float64, z1 = Float64 }

    def roomRect(r: Room): Rect = { x0 = 0.0 - r#max#x, x1 = 0.0 - r#min#x, z0 = r#min#y, z1 = r#max#y }

    def stairRects(f: Floor): List[Rect] =
        f#stairs |> List.flatMap(s -> s#ramps) |> List.map(pts -> {
            let xs = pts |> List.map(p -> 0.0 - p#x);
            let zs = pts |> List.map(p -> p#z);
            { x0 = List.minimum(xs) |> Option.getWithDefault(0.0), x1 = List.maximum(xs) |> Option.getWithDefault(0.0),
              z0 = List.minimum(zs) |> Option.getWithDefault(0.0), z1 = List.maximum(zs) |> Option.getWithDefault(0.0) }
        })

    /// 階の外形: 床の板の四角（L 字の校舎なら板ごとに 1 つ）。廊下は部屋の四角と外形の間に残る。
    def outlineOfFloor(f: Floor): List[Rect] =
        f#colliders |> List.filter(Layout.isSlab(f)) |> List.map(b -> { x0 = 0.0 - b#max#x, x1 = 0.0 - b#min#x, z0 = b#min#z, z1 = b#max#z })

    /// 全部の階を通した縮尺（紙の幅 256 px・高さ 150 px に収める）。
    pub def frameOf(layout: Layout.Layout): Frame =
        let outlines = layout#floors |> List.flatMap(outlineOfFloor);
        let x0 = outlines |> List.map(r -> r#x0) |> List.minimum |> Option.getWithDefault(0.0);
        let x1 = outlines |> List.map(r -> r#x1) |> List.maximum |> Option.getWithDefault(1.0);
        let z0 = outlines |> List.map(r -> r#z0) |> List.minimum |> Option.getWithDefault(0.0);
        let z1 = outlines |> List.map(r -> r#z1) |> List.maximum |> Option.getWithDefault(1.0);
        { glX0 = x0, zMid = (z0 + z1) / 2.0, scale = Float64.min(256.0 / Float64.max(1.0, x1 - x0), 150.0 / Float64.max(1.0, z1 - z0)) }

    /// glTF の (x, z) → 紙の上の点。
    def place(fr: Frame, glX: Float64, z: Float64): Vec2.Vec2 =
        { x = paperAt()#x + 16.0 + (glX - fr#glX0) * fr#scale, y = paperAt()#y + 108.0 + (z - fr#zMid) * fr#scale }

    /// engine の足元 → 紙の上の点。
    pub def toPaper(fr: Frame, feet: Vec3.Vec3): Vec2.Vec2 = place(fr, 0.0 - feet#x, feet#z)

    def edges(fr: Frame, r: Rect): List[Seg] =
        let a = place(fr, r#x0, r#z0);
        let b = place(fr, r#x1, r#z0);
        let c = place(fr, r#x1, r#z1);
        let d = place(fr, r#x0, r#z1);
        { a = a, b = b } :: { a = b, b = c } :: { a = d, b = c } :: { a = a, b = d } :: Nil

    /// 坂の段: 坂の長い向きに 0.5 m ごとの横線。
    def rungs(fr: Frame, r: Rect): List[Seg] =
        let alongZ = r#z1 - r#z0 >= r#x1 - r#x0;
        let len = if (alongZ) r#z1 - r#z0 else r#x1 - r#x0;
        let n = Float64.floor(len / 0.5) |> Float64.tryToInt32 |> Option.getWithDefault(0);
        List.range(1, n) |> List.map(i -> {
            let t = Int32.toFloat64(i) * 0.5;
            if (alongZ) { a = place(fr, r#x0, r#z0 + t), b = place(fr, r#x1, r#z0 + t) }
            else { a = place(fr, r#x0 + t, r#z0), b = place(fr, r#x0 + t, r#z1) }
        })

    /// 階 index の紙の中身。visited = 行った部屋の鍵（roomKey）。
    pub def sheetOf(layout: Layout.Layout, fr: Frame, index: Int32, visited: Set[String]): Sheet =
        match Layout.floorAt(index, layout) {
            case None => { floor = index, walls = Nil, steps = Nil, marks = Nil }
            case Some(f) =>
                let rooms = f#rooms |> List.map(roomRect);
                let stairs = stairRects(f);
                { floor = index,
                  walls = List.append(outlineOfFloor(f) |> List.flatMap(edges(fr)), rooms |> List.flatMap(edges(fr))),
                  steps = List.append(stairs |> List.flatMap(edges(fr)), stairs |> List.flatMap(rungs(fr))),
                  marks = f#rooms |> List.filter(r -> isNamed(r) and Set.memberOf(roomKey(index, r#id), visited)) |> List.map(markOf(fr, index)) }
        }

    /// 丸と名前を付ける部屋か（廊下と階段の四角は線だけ）。
    def isNamed(r: Room): Bool = r#kind != "corridor" and r#kind != "stairs"

    def markOf(fr: Frame, index: Int32, r: Room): Mark =
        let rect = roomRect(r);
        let key = roomKey(index, r#id);
        let seed = String.foldLeft((acc, c) -> acc * 31 + Char.toBmpCodePoint(c), 7, key);
        { key = key, label = shortLabel(r#name), center = place(fr, (rect#x0 + rect#x1) / 2.0, (rect#z0 + rect#z1) / 2.0),
          circle = 1 + Int32.modulo(Int32.abs(seed), 4), tilt = (Hash01.at(seed, 5) - 0.5) * 0.06 }

    /// 階の名前（漢字の数字: 「一階」「二階」「三階」）。
    pub def floorName(index: Int32): String =
        let kanji = String.toList("〇一二三四五六七八九") |> List.drop(index) |> List.head
            |> Option.filter(_ -> index >= 0) |> Option.map(Char.toString) |> Option.getWithDefault(Int32.toString(index));
        "${kanji}階"

    /// 紙に書いてある名前（行った部屋の分だけ）。
    pub def labelsOf(s: Sheet): List[String] = s#marks |> List.map(m -> m#label)

    /// 行った部屋の鍵（階の番号と部屋の id）。
    pub def roomKey(floor: Int32, id: String): String = "${Int32.toString(floor)}:${id}"

    /// 足元が入っている部屋の鍵（廊下と階段では None）。
    pub def roomAt(layout: Layout.Layout, feet: Vec3.Vec3): Option[String] =
        Layout.roomAt(feet, layout) |> Option.map(r -> roomKey(Layout.floorIndexAt(feet#y, layout), r#id))

    /// 紙に書く名前: 「1年2組」は「1-2」に縮める（部屋の幅に収まる 3 字）。ほかの部屋はそのまま。
    def shortLabel(name: String): String =
        let chars = String.toList(name);
        match chars {
            case g :: '年' :: c :: '組' :: Nil => "${g}-${c}"
            case _                           => name
        }
}
