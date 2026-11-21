// Items — 拾える物と鍵のかかった戸の決まり（純粋）: 持ち物の並び・目の前の拾える物と鍵の戸・戸口の位置と閉まった戸の当たり。
// 置き場所・鍵・演出の値は ItemsDoc（items.kind.json）。拾った物と開けた戸の記録は World が持つ。
//
// 戸口は配置の表から引く: 鍵のかかった部屋の四角の縁から 0.4 m 以内にある door-* の小物が、その部屋の戸。
// 小物は開いた位置（戸袋の側）に置いてあるので、同じ壁の当たり判定の箱の切れ目（幅 0.5〜1.6 m）の一番近い所を戸口とし、
// 閉めた戸はその戸口の真ん中へ滑らせた位置に描く。
// WhyNot: 戸口の位置を Doc に書かない — 校舎の glb と layout.json を書き出し直して戸口が動いても、表から引けば付いていく。
mod Items {
    use fge::{CollisionShape3d, Num, Sort, Vec3}
    use fge::CollisionShape3d.Box3d

    /// 鍵のかかった部屋の戸口 1 つ。room = 部屋の id・prop = 開いた位置の戸の小物（配置の表の行）・
    /// center = 戸口の真ん中（床の高さ・壁の線の上。向いているかを測る点）・closed = 閉めた戸を描く位置・box = 閉まった戸の当たり・
    /// outside = 壁に直角で、戸の小物が置いてある側（廊下の側）への向き（長さ 1）。
    pub type alias Door = { room = String, prop = Layout.Prop, center = Vec3.Vec3, closed = Vec3.Vec3, box = Box3d, outside = Vec3.Vec3 }

    // ── 持ち物 ──

    /// 番号 id の持ち物。
    pub def itemOf(doc: ItemsDoc.Doc, id: String): Option[ItemsDoc.Item] = ItemsDoc.rec(doc)#items |> List.find(i -> i#id == id)

    /// 番号 id の置き場所。
    pub def pickupOf(doc: ItemsDoc.Doc, id: String): Option[ItemsDoc.Pickup] = ItemsDoc.rec(doc)#pickups |> List.find(p -> p#id == id)

    /// 置き場所 id に置いてある持ち物。
    pub def itemAt(doc: ItemsDoc.Doc, pickup: String): Option[ItemsDoc.Item] =
        pickupOf(doc, pickup) |> Option.flatMap(p -> itemOf(doc, p#item))

    /// 拾った置き場所の並び（拾った順）から持ち物の並び（同じ物は 1 つ）。
    pub def inventoryOf(doc: ItemsDoc.Doc, taken: List[String]): List[ItemsDoc.Item] =
        taken |> List.filterMap(itemAt(doc)) |> List.distinctWith((a, b) -> a#id == b#id)

    /// 持ち物 id を持っているか。
    pub def holds(doc: ItemsDoc.Doc, taken: List[String], id: String): Bool =
        inventoryOf(doc, taken) |> List.exists(i -> i#id == id)

    /// 持ち物 id が置いてある最初の置き場所（始まりの口で「持っている」ことにする所）。
    pub def firstPickupOf(doc: ItemsDoc.Doc, id: String): Option[String] =
        ItemsDoc.rec(doc)#pickups |> List.find(p -> p#item == id) |> Option.map(p -> p#id)

    /// 部屋 id に鍵がかかっているか（Doc の locks にあるか。開けたかは見ない）。
    pub def isLockedRoom(doc: ItemsDoc.Doc, room: String): Bool = ItemsDoc.rec(doc)#locks |> List.exists(l -> l#room == room)

    /// 部屋 id を開ける鍵の持ち物。
    pub def keyOf(doc: ItemsDoc.Doc, room: String): Option[ItemsDoc.Item] =
        ItemsDoc.rec(doc)#locks |> List.find(l -> l#room == room) |> Option.flatMap(l -> itemOf(doc, l#key))

    // ── 目の前の物 ──

    /// 拾える物: まだ拾っていない・形の読めた物（available）・足元と同じ部屋・同じ階（高さの差 1.5 m 以内）で、扇形の中の角の小さい方。
    pub def facedPickup(layout: Layout.Layout, doc: ItemsDoc.Doc, cone: Cast.Cone, taken: List[String], available: ItemsDoc.Item -> Bool): Option[ItemsDoc.Pickup] =
        let here = Layout.roomAt(cone#feet, layout) |> Option.map(r -> r#id);
        ItemsDoc.rec(doc)#pickups
            |> List.filter(p -> not List.memberOf(p#id, taken) and Float64.abs(p#pos#y - cone#feet#y) < 1.5)
            |> List.filter(p -> itemOf(doc, p#item) |> Option.exists(available))
            |> List.filter(p -> Option.nonEmpty(here) and (Layout.roomAt(p#pos, layout) |> Option.map(r -> r#id)) == here)
            |> Cast.nearestInCone(cone, p -> p#pos)

    /// 調べられる鍵の戸: まだ開けていない部屋の戸口で、足元がその部屋の中か廊下・同じ階（高さの差 1 m 以内）・扇形の中の角の小さい方。
    pub def facedDoor(layout: Layout.Layout, doors: List[Door], cone: Cast.Cone, opened: String -> Bool): Option[Door] =
        let here = Layout.roomAt(cone#feet, layout);
        let beside = (d: Door) -> here |> Option.exists(r -> r#id == d#room or r#kind == "corridor");
        doors
            |> List.filter(d -> not opened(d#room) and Float64.abs(d#center#y - cone#feet#y) < 1.0 and beside(d))
            |> Cast.nearestInCone(cone, d -> d#center)

    /// 部屋 room の戸口（表の順）。
    pub def doorsOfRoom(room: String, doors: List[Door]): List[Door] = doors |> List.filter(d -> d#room == room)

    /// 閉まった戸の当たり（開けていない部屋の戸口だけ）。
    pub def closedBoxes(doors: List[Door], opened: String -> Bool): List[Box3d] =
        doors |> List.filter(d -> not opened(d#room)) |> List.map(d -> d#box)

    // ── 戸口（配置の表から） ──

    /// 鍵のかかった部屋の戸口の全部。
    pub def doorsOf(layout: Layout.Layout, doc: ItemsDoc.Doc): List[Door] =
        ItemsDoc.rec(doc)#locks |> List.flatMap(l -> layout#floors |> List.flatMap(f ->
            f#rooms |> List.filter(r -> r#id == l#room) |> List.flatMap(r ->
                layout#props |> List.filter(p -> p#floor == f#index and String.startsWith(prefix = "door-", p#prop))
                    |> List.filterMap(doorOf(f, r)))))

    /// 配置の表の同じ小物か（名前・階・位置）。
    pub def isSameProp(a: Layout.Prop, b: Layout.Prop): Bool =
        a#prop == b#prop and a#floor == b#floor and Vec3.length(Vec3.sub(a#pos, b#pos)) < 0.001

    /// 小物 p が部屋 r の縁の戸なら、その戸口。戸の板が x に沿う（表の yaw が 0 か 180 度）なら z の縁、z に沿うなら x の縁を見る。
    def doorOf(f: Layout.Floor, r: Layout.Room, p: Layout.Prop): Option[Door] =
        let alongX = Float64.abs(Num.cos(p#yaw)) > 0.7;
        let edge = if (alongX) { along = p#pos#x, across = p#pos#z, lo = r#min#x, hi = r#max#x, sides = r#min#y :: r#max#y :: Nil }
                   else { along = p#pos#z, across = p#pos#x, lo = r#min#y, hi = r#max#y, sides = r#min#x :: r#max#x :: Nil };
        let line = edge#sides |> List.minimumBy((a, b) -> Float64.abs(a - edge#across) <=> Float64.abs(b - edge#across)) |> Option.getWithDefault(edge#across);
        if (Float64.abs(line - edge#across) > 0.4 or edge#along < edge#lo or edge#along > edge#hi) None
        else gapNear(wallSpans(f, alongX, line), edge#along) |> Option.map(gap -> {
            let (g0, g1) = gap;
            let mid = (g0 + g1) / 2.0;
            let at = (a: Float64, c: Float64, y: Float64) -> if (alongX) Vec3.v3(a, y, c) else Vec3.v3(c, y, a);
            let half = if (alongX) Vec3.v3((g1 - g0) / 2.0, doorHeight() / 2.0, 0.08) else Vec3.v3(0.08, doorHeight() / 2.0, (g1 - g0) / 2.0);
            let side = if (edge#across >= line) 1.0 else -1.0;
            { room = r#id, prop = p, center = at(mid, line, f#y), closed = at(mid, edge#across, p#pos#y),
              box = CollisionShape3d.box3d(at(mid, line, f#y + doorHeight() / 2.0), half),
              outside = if (alongX) Vec3.v3(0.0, 0.0, side) else Vec3.v3(side, 0.0, 0.0) }
        })

    /// 戸口の高さ（閉まった戸の当たりの高さ・m）。
    def doorHeight(): Float64 = 2.1

    /// 階 f の床から立つ薄い壁の箱のうち、壁の線 line に掛かる物の、壁に沿う向きの範囲（始まりの順）。
    def wallSpans(f: Layout.Floor, alongX: Bool, line: Float64): List[(Float64, Float64)] =
        f#colliders
            |> List.filter(b -> Float64.abs(b#min#y - f#y) < 0.05 and b#max#y - b#min#y > 0.5)
            |> List.filterMap(b -> {
                let (a0, a1, c0, c1) = if (alongX) (b#min#x, b#max#x, b#min#z, b#max#z) else (b#min#z, b#max#z, b#min#x, b#max#x);
                if (c1 - c0 <= 0.3 and c0 - 0.1 <= line and line <= c1 + 0.1) Some((a0, a1)) else None
            })
            |> Sort.sortStableBy(fst)

    /// 範囲の並びの切れ目のうち、幅が戸口ほど（0.5〜1.6 m）で、真ん中が at から 1.5 m 以内の一番近い物。
    def gapNear(spans: List[(Float64, Float64)], at: Float64): Option[(Float64, Float64)] =
        gapsOf(spans)
            |> List.filter(g -> { let (g0, g1) = g; g1 - g0 >= 0.5 and g1 - g0 <= 1.6 and Float64.abs((g0 + g1) / 2.0 - at) <= 1.5 })
            |> List.minimumBy((a, b) -> Float64.abs((fst(a) + snd(a)) / 2.0 - at) <=> Float64.abs((fst(b) + snd(b)) / 2.0 - at))

    /// 始まりの順の範囲の並びの、間の切れ目（重なる範囲は 1 つにつなぐ）。
    def gapsOf(spans: List[(Float64, Float64)]): List[(Float64, Float64)] = match spans {
        case first :: rest =>
            let (_, gaps) = rest |> List.foldLeft((acc, s) -> {
                let (reach, found) = acc;
                if (fst(s) > reach) (snd(s), (reach, fst(s)) :: found) else (Float64.max(reach, snd(s)), found)
            }, (snd(first), Nil));
            List.reverse(gaps)
        case Nil => Nil
    }
}
