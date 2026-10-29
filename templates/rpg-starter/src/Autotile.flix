// Autotile — 文字の格子の 1 マスを、隣のマスとのつながりで部品（Sheet.Part）へ解く決まり（Godot の terrain の autotile と同じ考え方）。
// 岸と森の縁・家の段・岩の上面と正面・真上で替わる床を、格子だけから選ぶ。どの部品をタイル層に載せるかは MapArt、
// 敷いて描くのは View.tileLayers（タイル層）。
mod Autotile {
    use fge::{RawDraw, Render}
    use Sheet.SheetId

    /// タイル 1 枚の大きさ（px）。人も同じ 16×16。
    pub def tile(): Float64 = 16.0

    /// 隣のマスとのつながりで選ぶ縁の名前の組（岸・森の縁・地底湖の岸）。
    /// 向きの名前（n / ne …）は「外（陸・草原）がある向き」。
    /// base = 縁の無い真ん中・side = 辺の頭（sea_ → sea_n）・outer = 外角の頭・inner = 内角の頭。
    pub type alias EdgeNames = { sheet = SheetId, base = String, side = String, outer = String, inner = String,
                                 fps = Float64, placeholder = String }

    /// 横に並ぶ物の段の名前（roof_ → roof_l / roof_m / roof_r）。
    pub type alias SpanNames = { sheet = SheetId, prefix = String, placeholder = String }

    /// 格子の 1 文字が何を敷くか。
    pub enum Cell {
        /// いつも同じ部品。
        case Plain(Sheet.Part)
        /// 下の Cell を敷いた上に、部品を 1 枚重ねる（壁のたいまつ・支柱・宝箱）。
        case Over(Cell, Sheet.Part)
        /// 文字の集合を 1 つの面（海・森・湖）として数え、隣の 8 マスから辺・外角・内角を選ぶ。
        case Edged(Set[Char], EdgeNames)
        /// 岩: 真下のマスが集合（岩の文字）の外なら正面（face）、内なら上の面（top）。
        case Wall(Set[Char], Sheet.Part, Sheet.Part)
        /// 横に並ぶ物の段（家の棟・軒・壁）: 集合の中で左端なら頭 + "l"、右端なら + "r"、間は + "m"。
        case Span(Set[Char], SpanNames)
        /// 真上のマスの文字で部品を替える（たいまつの真下は照らされた床・壁の真下は影の床）。先に当たった方。
        case ByAbove(List[(Set[Char], Sheet.Part)], Sheet.Part)
        /// 線（レール）: 上下左右の 4 マスのうち集合の中の物から、縦・横・曲がり角を選ぶ。
        /// 曲がり角は 2 つの隣が直角に並ぶ時だけ（3 つ以上・1 つ以下はその文字の部品 = 最後の Part のまま）。
        case Joined(Set[Char], JoinNames, Sheet.Part)
    }

    /// 線の部品: h = 横・v = 縦・ne / nw / se / sw = 曲がり角（ne は上と右へつながる）。
    pub type alias JoinNames = { h = Sheet.Part, v = Sheet.Part, ne = Sheet.Part, nw = Sheet.Part, se = Sheet.Part, sw = Sheet.Part }

    /// 縁の向き。
    enum Edge { case Center case Side(String) case Outer(String) case Inner(String) }

    /// 文字の格子の読み取り。格子の外は「隣と同じ面が続いている」とみなす
    /// （WhyNot: 外を別の面と数えると、画面の端に岸や森の縁が並んで地図が額縁の中に見える）。
    pub type alias Grid = Vector[Vector[Char]]

    def charAt(grid: Grid, c: Int32, r: Int32): Option[Char] =
        Vector.nth(r, grid) |> Option.flatMap(Vector.nth(c))

    /// (c, r) が集合の面に入っているか。格子の外は入っている。
    def isInside(grid: Grid, set: Set[Char], c: Int32, r: Int32): Bool =
        charAt(grid, c, r) |> Option.map(ch -> Set.memberOf(ch, set)) |> Option.getWithDefault(true)

    /// 隣の 4 マスで辺と外角、4 マスとも同じ面なら斜めの 4 マスで内角を選ぶ。
    /// 向かい合う 2 辺が外になる 1 マス幅の面は作れない（片方の辺の絵になる）ので、地図の側で 2 マス幅以上にする。
    def edgeAt(grid: Grid, set: Set[Char], c: Int32, r: Int32): Edge =
        let out = (dc, dr) -> not isInside(grid, set, c + dc, r + dr);
        let (n, s, e, w) = (out(0, -1), out(0, 1), out(1, 0), out(-1, 0));
        if (n and e) Edge.Outer("ne")
        else if (n and w) Edge.Outer("nw")
        else if (s and e) Edge.Outer("se")
        else if (s and w) Edge.Outer("sw")
        else if (n) Edge.Side("n")
        else if (s) Edge.Side("s")
        else if (e) Edge.Side("e")
        else if (w) Edge.Side("w")
        else if (out(1, -1)) Edge.Inner("ne")
        else if (out(-1, -1)) Edge.Inner("nw")
        else if (out(1, 1)) Edge.Inner("se")
        else if (out(-1, 1)) Edge.Inner("sw")
        else Edge.Center

    def edgePart(names: EdgeNames, edge: Edge): Sheet.Part =
        let sprite = match edge {
            case Edge.Center   => names#base
            case Edge.Side(d)  => names#side + d
            case Edge.Outer(d) => names#outer + d
            case Edge.Inner(d) => names#inner + d
        };
        Sheet.cycling(names#sheet, sprite, names#fps, names#placeholder, { x = tile(), y = tile() })

    /// (c, r) の Cell を、重ねる順（奥から）の部品の列へ。
    def partsOf(grid: Grid, c: Int32, r: Int32, cell: Cell): List[Sheet.Part] = match cell {
        case Cell.Plain(part)             => part :: Nil
        case Cell.Over(under, part)       => List.append(partsOf(grid, c, r, under), part :: Nil)
        case Cell.Edged(set, names)       => edgePart(names, edgeAt(grid, set, c, r)) :: Nil
        case Cell.Span(set, names)        =>
            let end = if (not isInside(grid, set, c - 1, r)) "l" else if (not isInside(grid, set, c + 1, r)) "r" else "m";
            Sheet.part(names#sheet, names#prefix + end, "idle", names#placeholder, { x = tile(), y = tile() }) :: Nil
        case Cell.Wall(set, top, face)    =>
            (if (isInside(grid, set, c, r + 1)) top else face) :: Nil
        case Cell.ByAbove(choices, other) =>
            let above = charAt(grid, c, r - 1);
            choices |> List.find(choice -> above |> Option.map(ch -> Set.memberOf(ch, fst(choice))) |> Option.getWithDefault(false))
                |> Option.map(snd) |> Option.getWithDefault(other) |> (part -> part :: Nil)
        case Cell.Joined(set, names, own) =>
            joinedPart(isInside(grid, set, c, r - 1), isInside(grid, set, c, r + 1), isInside(grid, set, c + 1, r), isInside(grid, set, c - 1, r), names, own) :: Nil
    }

    /// 上・下・右・左の隣が線かどうかから、線の部品を選ぶ。
    def joinedPart(n: Bool, s: Bool, e: Bool, w: Bool, names: JoinNames, own: Sheet.Part): Sheet.Part =
        match (n, s, e, w) {
            case (true, false, true, false)  => names#ne
            case (true, false, false, true)  => names#nw
            case (false, true, true, false)  => names#se
            case (false, true, false, true)  => names#sw
            case (_, _, false, false) if n or s => names#v
            case (false, false, _, _) if e or w => names#h
            case _                           => own
        }

    /// 変種の絵の名前の候補（plains → plains_b・rock_face_deep → rock_face_b_deep）。
    def variantNameOf(sprite: String): String =
        if (String.endsWith(suffix = "_deep", sprite)) String.dropRight(5, sprite) + "_b_deep"
        else sprite + "_b"

    /// 座標から決まる 0..4 の値。WhyNot: 乱数を使わない — 描くたびに柄が変わり、描き出しの PNG が毎回変わる。
    /// 列と行の掛け算を混ぜるのは、足し算だけだと斜めの縞にそろってしまうため。
    def cellHash(c: Int32, r: Int32): Int32 =
        Int32.modulo(c * 7 + r * 13 + c * r * 3 + (c / 3) * 5, 5)

    /// 変種の絵（名前の後ろに _b）がシートにあれば、5 マスに 2 マスの割合で変種に替える。
    /// 広い面に同じ柄が格子に並ぶのを消す。変種の無い絵はそのまま。
    def withVariant(sheets: Map[SheetId, Sheet.Sheet], c: Int32, r: Int32, part: Sheet.Part): Sheet.Part =
        let variant = variantNameOf(part#sprite);
        let hasVariant = Map.get(part#sheet, sheets)
            |> Option.map(sheet -> Map.memberOf(variant, sheet#doc#sprites))
            |> Option.getWithDefault(false);
        if (hasVariant and cellHash(c, r) < 2) { sprite = variant | part } else part

    /// 文字の並びを格子へ。
    def gridOf(rows: List[String]): Grid = rows |> List.map(row -> String.toList(row) |> List.toVector) |> List.toVector

    /// (c, r) のマスに重ねる部品（奥から。0 番は地面で、変種の絵があれば座標で散らした物）。
    /// 凡例に無い文字は色票の外の色の仮の四角の部品。
    pub def cellPartsAt(sheets: Map[SheetId, Sheet.Sheet], legend: Map[Char, Cell], grid: Grid, c: Int32, r: Int32): List[Sheet.Part] =
        let unknown = Cell.Plain(Sheet.part(SheetId.Town, "", "", "missing", { x = tile(), y = tile() }));
        let cell = charAt(grid, c, r) |> Option.flatMap(ch -> Map.get(ch, legend)) |> Option.getWithDefault(unknown);
        partsOf(grid, c, r, cell) |> List.zipWithIndex |> List.map(layer -> {
            let (i, part) = layer;
            if (i == 0) withVariant(sheets, c, r, part) else part
        })

    /// 地面へ落ちる影（光は左上から）。receivers の文字のマスにだけ、半マス幅の帯を重ねる:
    /// 西隣が casters なら左半分・北隣が bottoms（物の最下段）なら上半分・北西だけが bottoms なら左上の 1/4。
    pub def dropShadows(palette: Palette.Palette, spec: { rows = List[String], casters = Set[Char], bottoms = Set[Char],
                                                    receivers = Set[Char], colorKey = String }, z: Int32): List[Render.PlacedItem] =
        let grid = gridOf(spec#rows);
        let isIn = (set, c, r) -> charAt(grid, c, r) |> Option.map(ch -> Set.memberOf(ch, set)) |> Option.getWithDefault(false);
        let color = Palette.resolve(palette, spec#colorKey);
        let h = tile() / 2.0;
        let band = (c, r, dx, dy, w, hh) -> Render.at({ x = Int32.toFloat64(c) * tile() + dx, y = Int32.toFloat64(r) * tile() + dy },
                                                      RawDraw.box({ x = w, y = hh }, color, z));
        grid |> Vector.toList |> List.zipWithIndex |> List.flatMap(rowEntry -> {
            let (r, row) = rowEntry;
            row |> Vector.toList |> List.zipWithIndex |> List.flatMap(cellEntry -> {
                let (c, ch) = cellEntry;
                if (not Set.memberOf(ch, spec#receivers)) Nil
                else {
                    let west = isIn(spec#casters, c - 1, r);
                    let north = isIn(spec#bottoms, c, r - 1);
                    let corner = not west and not north and isIn(spec#bottoms, c - 1, r - 1);
                    List.flatten(
                        (if (west) band(c, r, 0.0, 0.0, h, tile()) :: Nil else Nil) ::
                        (if (north) band(c, r, 0.0, 0.0, tile(), h) :: Nil else Nil) ::
                        (if (corner) band(c, r, 0.0, 0.0, h, h) :: Nil else Nil) :: Nil)
                }
            })
        })

}
