// CollisionGrid — 地図のマスごとの「通れる・通れない」の格子と、先頭を円として通れないマスの四角とぶつけ、壁に沿って滑らせる動き
// （Godot の CharacterBody2D.move_and_slide に当たる）。座標は地図の座標（x = 東・y = 北・1 マス = 1 m）で、
// マス (c, r) の四角は x が c〜c+1・y が (height − 1 − r)〜(height − r)。
mod CollisionGrid {
    use fge::{Num}
    use TownMap.{Building, Decor, Prop, Ridge, TownMap}

    /// 格子。blocked = 通れないマス・levels = マスの床の高さのレベル（行ごと）・stairs = 階段のマス。地図の外は通れない。
    pub type alias Grid = { width = Int32, height = Int32, blocked = Set[(Int32, Int32)], levels = Vector[Vector[Int32]], stairs = Set[(Int32, Int32)] }

    /// 建物の北に隠れるマスの決め方（H1）。slope = 先頭の足元を写す画面の行で、目へ向かう線が 1 m 南へ進むと上がる高さ（m）・
    /// seenHeight = キャラの足元から見えていてほしい高さ（m・この高さの点が建物に隠れるマスを塞ぐ）・reach = 塞ぐ行の上限・
    /// halfWidth = キャラの板の横幅の半分（m）・sideDrift = 目へ向かう線が 1 m 南へ進むと横へずれる量（m・カメラが先頭より横へ先を見せる分）。
    pub type alias HideRule = { slope = Float64, seenHeight = Float64, reach = Int32, halfWidth = Float64, sideDrift = Float64 }

    /// 地図から格子を作る。skipNpcColumn = 地図の町の人（1・2・3）を置かない列（TownScene.load と同じ・隊列が歩く列）・
    /// decorWidth = 広場のにぎやかしの絵の横幅（m）・passable = 通れるにぎやかしか（鳩など）・hide = 建物の北に隠れるマスも塞ぐ決め方（None は塞がない）。
    pub def build(m: TownMap, skipNpcColumn: Option[Int32], decorWidth: Decor -> Float64, passable: Decor -> Bool, hide: Option[HideRule]): Grid =
        let cells = List.range(0, m#height) |> List.flatMap(r -> List.range(0, m#width) |> List.map(c -> (c, r)));
        let foot = TownMap.footprints(m);
        let fromMap = cells |> List.filter(cr -> { let (c, r) = cr; Map.memberOf(cr, foot) or isBlockedGround(m, skipNpcColumn, c, r) }) |> List.toSet;
        let fromDecor = m#decor |> List.filter(d -> not passable(d)) |> List.flatMap(d -> decorCells(m, decorWidth(d), d)) |> List.toSet;
        let fromHide = hide |> Option.map(rule -> m#buildings |> List.flatMap(hiddenNorthOf(m, rule)) |> List.toSet) |> Option.getWithDefault(Set.empty());
        { width = m#width, height = m#height,
          blocked = Set.union(fromMap, Set.union(fromDecor, fromHide)) |> Set.filter(cr -> { let (c, r) = cr; TownMap.inside(m, c, r) }),
          levels = m#levels,
          stairs = cells |> List.filter(cr -> { let (c, r) = cr; TownMap.shapeAt(m, c, r) == TownMap.Shape.Stairs }) |> List.toSet }

    /// 地面と物の字で通れないマスか（水路・木・街灯・木箱・低木・生垣・柵・目印・町の人・板の物）。
    def isBlockedGround(m: TownMap, skipNpcColumn: Option[Int32], c: Int32, r: Int32): Bool =
        TownMap.groundAt(m, c, r) == TownMap.Ground.Water or isBlockingProp(skipNpcColumn == Some(c), TownMap.propAt(m, c, r))

    def isBlockingProp(skippedColumn: Bool, p: Prop): Bool = match p {
        case Prop.Empty  => false
        case Prop.Npc(_) => not skippedColumn
        case _           => true
    }

    /// にぎやかし d の板が地面に触れるマス（板の横幅にかかる列・奥行きは 1 マス）。
    def decorCells(m: TownMap, width: Float64, d: Decor): List[(Int32, Int32)] =
        let x = Int32.toFloat64(d#col) + 0.5 + d#offX;
        let y = Int32.toFloat64(m#height - 1 - d#row) + 0.5 + d#offY;
        let r = m#height - 1 - floorInt(y);
        // WhyNot: 板の端をそのまま列に丸めない — 絵の端の透けた数画素で隣の列まで塞ぎ、屋台の脇の道が通れなくなる。
        let half = Float64.max(0.0, width / 2.0 - 0.15);
        List.range(floorInt(x - half), floorInt(x + half) + 1) |> List.map(c -> (c, r))

    /// 建物 b の北と、その東西の脇で、足元から seenHeight の点が建物に隠れるマス（北へ 1 行ずつ、見える行が来たら止める）。
    // WhyNot: 建物の幅の列だけにしない — 屋根の軒が壁から 0.4〜0.5 m 出て、横へ先を見せるカメラの線は南へ行くほど横へずれ、
    // 脇の列に立つキャラの板にもかかる。
    def hiddenNorthOf(m: TownMap, rule: HideRule, b: Building): List[(Int32, Int32)] =
        let side = Float64.ceil(b#overhang + rule#halfWidth + rule#sideDrift * Int32.toFloat64(rule#reach + b#h)) |> Float64.tryToInt32 |> Option.getWithDefault(1);
        List.range(b#x - side, b#x + b#w + side) |> List.flatMap(c -> hiddenRows(m, rule, b, c, 1))

    def hiddenRows(m: TownMap, rule: HideRule, b: Building, c: Int32, k: Int32): List[(Int32, Int32)] =
        let r = b#y - k;
        if (k > rule#reach or r < 0 or not (isUnderSide(rule, b, c, k) and isHidden(m, rule, b, c, k))) Nil
        else (c, r) :: hiddenRows(m, rule, b, c, k + 1)

    /// 建物 b の北の k 行目の列 c に立つキャラの板が、横から見て建物（軒と、南へ行くほど横へずれる目への線）にかかるか。
    def isUnderSide(rule: HideRule, b: Building, c: Int32, k: Int32): Bool =
        // 先頭の足元はマスの中のどこにも立てるので、建物に一番近い縁で測る
        let gap = Float64.max(Int32.toFloat64(b#x - c - 1), Int32.toFloat64(c - b#x - b#w));
        gap < b#overhang + rule#halfWidth + rule#sideDrift * (Int32.toFloat64(k) - 0.5 + Int32.toFloat64(b#h))

    /// 建物 b の北の k 行目の列 c に立つキャラの seenHeight の点が、目へ向かう線の上で建物の形より低いか。
    /// 建物の形は壁の上端と屋根の棟の折れ線なので、線との差は折れ目（北の壁・棟・南の壁）だけを見れば足りる。
    def isHidden(m: TownMap, rule: HideRule, b: Building, c: Int32, k: Int32): Bool =
        let r = b#y - k;
        let feet = TownMap.topAt(m, c, r);
        let wallTop = Int32.toFloat64(b#level) * m#heightStep + Int32.toFloat64(b#floors) * TownMap.floorHeight();
        let roofRise = (half: Float64) -> half * Num.sin(b#pitchDeg * Num.pi() / 180.0) / Num.cos(b#pitchDeg * Num.pi() / 180.0);
        let depth = Int32.toFloat64(b#h);
        let across = Num.clamp(0.5, Int32.toFloat64(b#w) - 0.5, Int32.toFloat64(c - b#x) + 0.5);
        let topAt = (u: Float64) -> match b#ridge {
            case Ridge.X => wallTop + roofRise(Float64.min(u, depth - u))
            case Ridge.Y => wallTop + roofRise(Float64.min(across, Int32.toFloat64(b#w) - across))
        };
        let rayAt = (u: Float64) -> feet + rule#seenHeight + rule#slope * (Int32.toFloat64(k) - 0.5 + u);
        (0.0 :: depth / 2.0 :: depth :: Nil) |> List.exists(u -> rayAt(u) < topAt(u))

    def floorInt(v: Float64): Int32 = Float64.floor(v) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    /// 地図の座標の点 (x, y) のマス。
    pub def cellAt(g: Grid, x: Float64, y: Float64): (Int32, Int32) = (floorInt(x), g#height - 1 - floorInt(y))

    def levelOf(g: Grid, cr: (Int32, Int32)): Int32 =
        let (c, r) = cr;
        Vector.nth(r, g#levels) |> Option.flatMap(Vector.nth(c)) |> Option.getWithDefault(0)

    /// origin のマスに立つ者から見て、マス cr へ入れないか（通れないマス・地図の外・階段を通らない段差）。
    pub def isBlockedFrom(g: Grid, origin: (Int32, Int32), cr: (Int32, Int32)): Bool =
        let (c, r) = cr;
        let outside = c < 0 or c >= g#width or r < 0 or r >= g#height;
        let step = levelOf(g, origin) != levelOf(g, cr) and not Set.memberOf(origin, g#stairs) and not Set.memberOf(cr, g#stairs);
        outside or Set.memberOf(cr, g#blocked) or step

    /// 半径 radius の円を at から delta だけ動かし、通れないマスの四角とぶつけて壁に沿って滑らせた先。
    /// 1 回に動く量を半径の半分までに刻む（速く動いても四角を抜けない）。
    pub def moveAndSlide(g: Grid, radius: Float64, at: (Float64, Float64), delta: (Float64, Float64)): (Float64, Float64) =
        let (dx, dy) = delta;
        let length = Num.sqrt(dx * dx + dy * dy);
        let n = Int32.max(1, Float64.ceil(length / (radius * 0.5)) |> Float64.tryToInt32 |> Option.getWithDefault(1));
        let sx = dx / Int32.toFloat64(n);
        let sy = dy / Int32.toFloat64(n);
        List.range(0, n) |> List.foldLeft((p, _) -> {
            let (x, y) = p;
            let origin = cellAt(g, x, y);
            resolve(g, radius, origin, p, pushOut(g, radius, origin, pushOut(g, radius, origin, (x + sx, y + sy))))
        }, at)

    /// 押し出した後もまだ四角に重なっていたら（角に挟まれた）、その刻みは動かない。
    def resolve(g: Grid, radius: Float64, origin: (Int32, Int32), before: (Float64, Float64), after: (Float64, Float64)): (Float64, Float64) =
        if (overlapsAny(g, radius, origin, after)) before else after

    /// p のまわり 3×3 のマスのうち入れないマスの四角から、円を押し出す（重なった深さだけ四角の外へ）。
    def pushOut(g: Grid, radius: Float64, origin: (Int32, Int32), p: (Float64, Float64)): (Float64, Float64) =
        neighbors(g, p) |> List.filter(isBlockedFrom(g, origin)) |> List.foldLeft((q, cr) -> pushFromCell(g, radius, cr, q), p)

    def neighbors(g: Grid, p: (Float64, Float64)): List[(Int32, Int32)] =
        let (c, r) = cellAt(g, fst(p), snd(p));
        List.range(r - 1, r + 2) |> List.flatMap(rr -> List.range(c - 1, c + 2) |> List.map(cc -> (cc, rr)))

    /// マス cr の四角の中で p に一番近い点。
    def closestOnCell(g: Grid, cr: (Int32, Int32), p: (Float64, Float64)): (Float64, Float64) =
        let (c, r) = cr;
        let x0 = Int32.toFloat64(c);
        let y0 = Int32.toFloat64(g#height - 1 - r);
        (Num.clamp(x0, x0 + 1.0, fst(p)), Num.clamp(y0, y0 + 1.0, snd(p)))

    def pushFromCell(g: Grid, radius: Float64, cr: (Int32, Int32), p: (Float64, Float64)): (Float64, Float64) =
        let (qx, qy) = closestOnCell(g, cr, p);
        let (x, y) = p;
        let ex = x - qx;
        let ey = y - qy;
        let d = Num.sqrt(ex * ex + ey * ey);
        if (d >= radius or d < 0.000001) p
        else (qx + ex / d * radius, qy + ey / d * radius)

    def overlapsAny(g: Grid, radius: Float64, origin: (Int32, Int32), p: (Float64, Float64)): Bool =
        neighbors(g, p) |> List.filter(isBlockedFrom(g, origin)) |> List.exists(cr -> {
            let (qx, qy) = closestOnCell(g, cr, p);
            let ex = fst(p) - qx;
            let ey = snd(p) - qy;
            ex * ex + ey * ey < radius * radius - 0.000001
        })
}
