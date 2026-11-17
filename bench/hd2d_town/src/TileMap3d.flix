// TileMap3d — タイル地図（TownMap）から町の立体（床・段と縁石と笠石・水路・建物・箱の物・地図の外）と、立てる板の物を組む。
// Godot の GridMap・Unity の Tilemap に当たる。決まりはマス目だけで、手で 1 軒ずつ作らない。
// 面は Faces の四角（地図の座標: x = 東・y = 北・z = 上・外から見て反時計回り）で書く。1 マス = 1 m・絵は 32 テクセル = 1 m。
// 変種の選び方は座標のハッシュ（乱数を使わない＝毎回同じ絵）。
mod TileMap3d {
    use fge::{Num}
    use Faces.{P3, Quad, Rgb}
    use TownMap.{Building, Ground, Prop, Ridge, Shape, TownMap, Wall}

    /// 立てる板 1 枚。sprite = 絵のファイル（assets からの相対）・(x, y, z) = 足元（地図の座標）・
    /// width・height = 板の大きさ（m）・tint = 色の掛け目（線形）・flip = 左右反転・shadow = 影の付け方・owner = どのマスの物か（地図の外は Fixed）。
    pub type alias Board = { sprite = String, x = Float64, y = Float64, z = Float64, width = Float64, height = Float64,
                             tint = Rgb, flip = Bool, shadow = BoardShadow, owner = Faces.Owner }

    /// 板の影。Grounded = 太陽の影を落とし足元に楕円の影も置く・Unshadowed = どちらも無し（遠くの森）。
    pub enum BoardShadow with Eq {
        case Grounded
        case Unshadowed
    }

    /// 組んだ町。quads = 動かない面（材質の名前つき）・boards = 立てる板。
    pub type alias Town = { quads = List[Quad], boards = List[Board] }

    /// 絵の大きさ（px）を引く表。板の大きさを 32 テクセル = 1 m で決める。
    pub type alias SpriteSizes = Map[String, (Int32, Int32)]

    /// 町の立体で使う材質の表: 名前 → (タイルの絵, 色の掛け目（線形）)。
    pub def materialTable(): Map[String, (String, Rgb)] =
        let w = Faces.white();
        let tinted = (r, g, b) -> { r = r, g = g, b = b };
        Map#{
            "grass" => ("tiles/ground_grass.png", w), "cobble" => ("tiles/ground_cobble_fine.png", w), "dirt" => ("tiles/ground_dirt.png", w),
            "canal_floor" => ("tiles/cliff_rock.png", tinted(0.6, 0.6, 0.65)), "water" => ("tiles/water_canal.png", w),
            "rock" => ("tiles/cliff_rock.png", w), "lip" => ("tiles/cliff_lip.png", w), "bank" => ("tiles/wall_stone.png", w),
            "plaster" => ("tiles/wall_plaster.png", w), "plaster_window" => ("tiles/wall_plaster_window.png", w),
            "plaster_door" => ("tiles/wall_plaster_door.png", w), "stone" => ("tiles/wall_stone.png", w),
            "stone_window" => ("tiles/wall_stone_window.png", w), "stone_door" => ("tiles/wall_stone_door.png", w),
            "roof" => ("tiles/roof_tile.png", w), "trim" => ("tiles/wall_plaster.png", tinted(0.42, 0.28, 0.2)),
            "hedge" => ("tiles/hedge_leaf.png", w), "stone_cut" => ("tiles/stone_cut.png", w),
            "wood" => ("props3d/crate_front.png", tinted(0.8, 0.72, 0.66)),
            "crate_top" => ("props3d/crate_top.png", w), "crate_front" => ("props3d/crate_front.png", w)
        }

    /// 町を組む。skipNpcColumn = この列の町の人（地図の 1・2・3）を置かない（歩く隊列で置き換える列）。
    pub def build(m: TownMap, sizes: SpriteSizes, skipNpcColumn: Option[Int32]): Town =
        let foot = TownMap.footprints(m);
        let ctx = { map = m, foot = foot };
        let quads = List.flatten(
            floorQuads(ctx) :: cliffQuads(ctx) :: groundEdgeQuads(ctx) :: waterQuads(ctx) ::
            List.flatMap(buildingQuads(ctx), m#buildings) :: propQuads(ctx) :: marginQuads(ctx) :: Nil);
        { quads = quads, boards = List.append(propBoards(ctx, sizes, skipNpcColumn), forestBoards(ctx, sizes)) }

    /// 組む時に毎回引く物（地図と、建物の足元の表）。
    type alias Ctx = { map = TownMap, foot = Map[(Int32, Int32), Building] }

    // ── 座標とハッシュ ──

    /// 地図の行 → 地図の座標の y（北が +）。マスの南の辺の y。
    def wy(m: TownMap, r: Int32): Float64 = Int32.toFloat64(m#height - 1 - r)

    def fl(i: Int32): Float64 = Int32.toFloat64(i)

    /// 座標のハッシュ（0〜1）。Blender の試作と同じ式（下 32 bit で畳む）。
    pub def h01(c: Int32, r: Int32, salt: Int32): Float64 =
        let n = Int64.bitwiseXor(Int64.bitwiseXor(Int32.toInt64(c) * 73856093i64, Int32.toInt64(r) * 19349663i64), Int32.toInt64(salt) * 83492791i64);
        let mixed = Int64.bitwiseAnd(Int64.bitwiseXor(n, Int64.rightShift(n, 13)) * 1274126177i64, 0xFFFFFFFFi64);
        Int64.toFloat64(Int64.bitwiseAnd(mixed, 0xFFFFi64)) / 65535.0

    def floorInt(x: Float64): Int32 = Float64.floor(x) |> Float64.tryToInt32 |> Option.getWithDefault(0)

    def isFoot(ctx: Ctx, c: Int32, r: Int32): Bool = Map.memberOf((c, r), ctx#foot)

    def top(ctx: Ctx, c: Int32, r: Int32): Float64 = TownMap.topAt(ctx#map, c, r)

    def solid(ctx: Ctx, c: Int32, r: Int32): Float64 = TownMap.solidTopAt(ctx#map, ctx#foot, c, r)

    def cells(m: TownMap): List[(Int32, Int32)] =
        List.range(0, m#height) |> List.flatMap(r -> List.range(0, m#width) |> List.map(c -> (c, r)))

    def groundMaterial(g: Ground): String = match g {
        case Ground.Grass  => "grass"
        case Ground.Cobble => "cobble"
        case Ground.Dirt   => "dirt"
        case Ground.Water  => "canal_floor"
    }

    // ── ① 床 ──

    /// 頂点の AO の 4 段（Minecraft の頂点 AO）。
    def aoLevel(blocked: Int32): Float64 = match blocked {
        case 0 => 1.0
        case 1 => 0.83
        case 2 => 0.66
        case _ => 0.5
    }

    /// 角を挟む 2 マスと斜めの 1 マスが、この面より高いかで暗さを決める。dc・dr は角の向き（±1）。
    def cornerAo(ctx: Ctx, c: Int32, r: Int32, dc: Int32, dr: Int32, z: Float64): Float64 =
        let s1 = solid(ctx, c + dc, r) > z + 0.05;
        let s2 = solid(ctx, c, r + dr) > z + 0.05;
        let cr = solid(ctx, c + dc, r + dr) > z + 0.05;
        if (s1 and s2) 0.5 else aoLevel((if (s1) 1 else 0) + (if (s2) 1 else 0) + (if (cr) 1 else 0))

    /// uv の 4 つを、90° 回しと左右反転の変種 v（0..7）で並べ替える。
    def variantUv(v: Int32): List[(Float64, Float64)] =
        let base = Faces.fullUv() |> List.map(uv -> if (Int32.bitwiseAnd(v, 4) != 0) (1.0 - fst(uv), snd(uv)) else uv);
        let k = Int32.bitwiseAnd(v, 3);
        List.append(List.drop(k, base), List.take(k, base))

    def floorQuads(ctx: Ctx): List[Quad] =
        let m = ctx#map;
        cells(m) |> List.filter(cr -> { let (c, r) = cr; not isFoot(ctx, c, r) and TownMap.shapeAt(m, c, r) == Shape.Flat })
            |> List.map(cr -> {
                let (c, r) = cr;
                let z = top(ctx, c, r);
                let x0 = fl(c);
                let y0 = wy(m, r);
                let ao = cornerAo(ctx, c, r, -1, 1, z) :: cornerAo(ctx, c, r, 1, 1, z) :: cornerAo(ctx, c, r, 1, -1, z) :: cornerAo(ctx, c, r, -1, -1, z) :: Nil;
                { owner = Faces.Owner.Cell(c, r) | Faces.quad(groundMaterial(TownMap.groundAt(m, c, r)),
                           Faces.p3(x0, y0, z) :: Faces.p3(x0 + 1.0, y0, z) :: Faces.p3(x0 + 1.0, y0 + 1.0, z) :: Faces.p3(x0, y0 + 1.0, z) :: Nil,
                           variantUv(floorInt(h01(c, r, 1) * 8.0)), ao) }
            })

    // ── 箱 ──

    /// 箱の面ごとの材質。fit = 面ごとに絵 1 枚を 0..1 で貼る（偽なら uv は world の m で模様が隣と続く）。
    type alias BoxMat = { top = String, south = String, side = String, fit = Bool }

    def oneMat(name: String): BoxMat = { top = name, south = name, side = name, fit = false }

    /// 箱（x0..x1・y0..y1・z0..z1）。faces = 作る面の字（t 上・s 南・n 北・w 西・e 東）・aoFoot = 側面の下の頂点の暗さ。
    def box(mat: BoxMat, lo: P3, hi: P3, faces: String, aoFoot: Float64): List[Quad] =
        let (x0, y0, z0) = (lo#x, lo#y, lo#z);
        let (x1, y1, z1) = (hi#x, hi#y, hi#z);
        let p = Faces.p3;
        let a = aoFoot :: aoFoot :: 1.0 :: 1.0 :: Nil;
        let uvOr = (world: List[(Float64, Float64)]) -> if (mat#fit) Faces.fullUv() else world;
        let has = (f: String) -> String.contains(substr = f, faces);
        (if (has("t")) Faces.quad(mat#top, p(x0, y0, z1) :: p(x1, y0, z1) :: p(x1, y1, z1) :: p(x0, y1, z1) :: Nil,
                                  uvOr((x0, y0) :: (x1, y0) :: (x1, y1) :: (x0, y1) :: Nil), Nil) :: Nil else Nil) :::
        (if (has("s")) Faces.quad(mat#south, p(x0, y0, z0) :: p(x1, y0, z0) :: p(x1, y0, z1) :: p(x0, y0, z1) :: Nil,
                                  uvOr((x0, z0) :: (x1, z0) :: (x1, z1) :: (x0, z1) :: Nil), a) :: Nil else Nil) :::
        (if (has("n")) Faces.quad(mat#side, p(x1, y1, z0) :: p(x0, y1, z0) :: p(x0, y1, z1) :: p(x1, y1, z1) :: Nil,
                                  uvOr((0.0 - x1, z0) :: (0.0 - x0, z0) :: (0.0 - x0, z1) :: (0.0 - x1, z1) :: Nil), a) :: Nil else Nil) :::
        (if (has("w")) Faces.quad(mat#side, p(x0, y1, z0) :: p(x0, y0, z0) :: p(x0, y0, z1) :: p(x0, y1, z1) :: Nil,
                                  uvOr((0.0 - y1, z0) :: (0.0 - y0, z0) :: (0.0 - y0, z1) :: (0.0 - y1, z1) :: Nil), a) :: Nil else Nil) :::
        (if (has("e")) Faces.quad(mat#side, p(x1, y0, z0) :: p(x1, y1, z0) :: p(x1, y1, z1) :: p(x1, y0, z1) :: Nil,
                                  uvOr((y0, z0) :: (y1, z0) :: (y1, z1) :: (y0, z1) :: Nil), a) :: Nil else Nil)

    def allFaces(): String = "tnsew"

    // ── ② 段の側面・縁石・笠石 ──

    /// 4 つの向き（dc, dr）。字は地図の向き（s = 南 = 行が増える）。
    def dirs(): List[(String, Int32, Int32)] = ("s", 0, 1) :: ("n", 0, -1) :: ("e", 1, 0) :: ("w", -1, 0) :: Nil

    /// マス (c, r) の d の向きの辺の 2 点（外から見て左 → 右）。
    def edgePoints(m: TownMap, c: Int32, r: Int32, d: String): ((Float64, Float64), (Float64, Float64)) =
        let x0 = fl(c);
        let y0 = wy(m, r);
        match d {
            case "s" => ((x0, y0), (x0 + 1.0, y0))
            case "n" => ((x0 + 1.0, y0 + 1.0), (x0, y0 + 1.0))
            case "e" => ((x0 + 1.0, y0), (x0 + 1.0, y0 + 1.0))
            case _   => ((x0, y0 + 1.0), (x0, y0))
        }

    /// 1 m ごとの段に分けた高さの区間（z0 → z1）。
    def segments(z0: Float64, z1: Float64): List[(Float64, Float64)] =
        if (z0 >= z1 - 0.000001) Nil else (z0, Float64.min(z1, z0 + 1.0)) :: segments(z0 + 1.0, z1)

    /// p → q の辺に z0..z1 の縦の面を 1 m ごとの段で立てる。一番上の段は topMat（崖の縁の草・絵を上端にそろえる）。
    /// uv の u は辺の world の長さで続けて取る（角を回っても模様が切れない）。
    def sideWall(p: (Float64, Float64), q: (Float64, Float64), z0: Float64, z1: Float64, midMat: String, topMat: Option[String], footAo: Float64): List[Quad] =
        let u0 = fst(p) + snd(p);
        let segs = segments(z0, z1);
        let last = List.length(segs) - 1;
        segs |> List.mapWithIndex((i, seg) -> {
            let (za, zb) = seg;
            let onTop = i == last and Option.nonEmpty(topMat);
            let mat = if (onTop) Option.getWithDefault(midMat, topMat) else midMat;
            let (va, vb) = if (onTop) (1.0 - (zb - za), 1.0) else (za, zb);
            let aa = if (i == 0) footAo else 1.0;
            Faces.quad(mat, Faces.p3(fst(p), snd(p), za) :: Faces.p3(fst(q), snd(q), za) :: Faces.p3(fst(q), snd(q), zb) :: Faces.p3(fst(p), snd(p), zb) :: Nil,
                       (u0, va) :: (u0 + 1.0, va) :: (u0 + 1.0, vb) :: (u0, vb) :: Nil, aa :: aa :: 1.0 :: 1.0 :: Nil)
        })

    /// 段の縁の笠石: 低い側へ 0.0625 m 張り出し、上面が明るい細い箱。張り出しの下に暗い線ができ、段が読める。
    def coping(p: (Float64, Float64), q: (Float64, Float64), dc: Int32, dr: Int32, z: Float64): List[Quad] =
        let (out, inner, up, down) = (0.0625, 0.16, 0.05, 0.07);
        let ox = fl(dc);
        let oy = fl(0 - dr);
        let xs = fst(p) :: fst(q) :: fst(p) + ox * out :: fst(q) + ox * out :: fst(p) - ox * inner :: fst(q) - ox * inner :: Nil;
        let ys = snd(p) :: snd(q) :: snd(p) + oy * out :: snd(q) + oy * out :: snd(p) - oy * inner :: snd(q) - oy * inner :: Nil;
        let lo = (zs: List[Float64]) -> List.foldLeft(Float64.min, Float64.positiveInfinity(), zs);
        let hi = (zs: List[Float64]) -> List.foldLeft(Float64.max, Float64.negativeInfinity(), zs);
        box(oneMat("stone_cut"), Faces.p3(lo(xs), lo(ys), z - down), Faces.p3(hi(xs), hi(ys), z + up), allFaces(), 0.8)

    def cliffQuads(ctx: Ctx): List[Quad] =
        let m = ctx#map;
        cells(m) |> List.filter(cr -> not isFoot(ctx, fst(cr), snd(cr))) |> List.flatMap(cr -> {
            let (c, r) = cr;
            let stair = TownMap.shapeAt(m, c, r) == Shape.Stairs;
            let sides = dirs() |> List.flatMap(d -> cliffSide(ctx, c, r, d));
            let lip = if (TownMap.groundAt(m, c, r) == Ground.Grass and not stair) lipOverhang(ctx, c, r, top(ctx, c, r)) else Nil;
            Faces.withOwner(Faces.Owner.Cell(c, r), List.append(sides, lip))
        })

    /// マス (c, r) の 1 つの向きの側面（隣より高い時だけ）。
    def cliffSide(ctx: Ctx, c: Int32, r: Int32, d: (String, Int32, Int32)): List[Quad] =
        let m = ctx#map;
        let (name, dc, dr) = d;
        let (nc, nr) = (c + dc, r + dr);
        let z = top(ctx, c, r);
        let stair = TownMap.shapeAt(m, c, r) == Shape.Stairs;
        let neighborFoot = Map.get((nc, nr), ctx#foot);
        if (stair and (name == "n" or name == "s")) Nil
        else if (Option.nonEmpty(neighborFoot) and m#curbRaise > 0.0) Nil
        else {
            let nz = neighborFoot |> Option.map(b -> fl(b#level) * m#heightStep) |> Option.getWithDefault(top(ctx, nc, nr));
            let ztop = z + (if (stair) m#heightStep else 0.0);
            if (nz >= ztop - 0.000001) Nil
            else {
                let (p, q) = edgePoints(m, c, r, name);
                let here = TownMap.groundAt(m, c, r);
                let waterSide = TownMap.groundAt(m, nc, nr) == Ground.Water or here == Ground.Water;
                let lowStep = m#curbRaise > 0.0 and not stair and ztop - nz <= 0.5 + 0.000001;
                let cap = if (m#coping and not stair and (lowStep or (waterSide and here != Ground.Water))) coping(p, q, dc, dr, ztop) else Nil;
                let wall = if (lowStep and not waterSide) sideWall(p, q, nz, ztop, "stone_cut", None, 0.55)
                    else if (waterSide) sideWall(p, q, nz, ztop, "bank", None, 0.45)
                    else if (stair) sideWall(p, q, nz, z, "rock", None, 0.45)
                    else sideWall(p, q, nz, ztop, "rock", if (here == Ground.Grass) Some("lip") else None, 0.45);
                List.append(cap, wall)
            }
        }

    /// 崖の上の縁の草のはみ出し: 低い隣へ 0.1 m 張り出す薄い草の板。
    def lipOverhang(ctx: Ctx, c: Int32, r: Int32, z: Float64): List[Quad] =
        let m = ctx#map;
        dirs() |> List.filter(d -> { let (_, dc, dr) = d; top(ctx, c + dc, r + dr) < z - 0.5 and not isFoot(ctx, c + dc, r + dr) })
            |> List.map(d -> {
                let (name, dc, dr) = d;
                let (p, q) = edgePoints(m, c, r, name);
                let (ox, oy) = (fl(dc) * 0.1, fl(0 - dr) * 0.1);
                let zz = z + 0.01;
                Faces.quad("grass", Faces.p3(fst(p) + ox, snd(p) + oy, zz) :: Faces.p3(fst(q) + ox, snd(q) + oy, zz) :: Faces.p3(fst(q), snd(q), zz) :: Faces.p3(fst(p), snd(p), zz) :: Nil,
                           (0.0, 0.9) :: (1.0, 0.9) :: (1.0, 1.0) :: (0.0, 1.0) :: Nil, Nil)
            })

    // ── ③ 水面 ──

    def waterQuads(ctx: Ctx): List[Quad] =
        let m = ctx#map;
        cells(m) |> List.filter(cr -> TownMap.groundAt(m, fst(cr), snd(cr)) == Ground.Water) |> List.map(cr -> {
            let (c, r) = cr;
            let z = fl(TownMap.levelAt(m, c, r)) * m#heightStep - TownMap.waterSurface();
            let x0 = fl(c);
            let y0 = wy(m, r);
            let k = floorInt(h01(c, r, 5) * 4.0);
            let uv = Faces.fullUv();
            { owner = Faces.Owner.Cell(c, r) | Faces.quad("water", Faces.p3(x0, y0, z) :: Faces.p3(x0 + 1.0, y0, z) :: Faces.p3(x0 + 1.0, y0 + 1.0, z) :: Faces.p3(x0, y0 + 1.0, z) :: Nil,
                       List.append(List.drop(k, uv), List.take(k, uv)), Nil) }
        })

    // ── ④ 草と石畳の境（同じ高さの時だけ。縁石を立てた地図では出ない） ──

    def groundEdgeQuads(ctx: Ctx): List[Quad] =
        let m = ctx#map;
        cells(m) |> List.filter(cr -> {
            let (c, r) = cr;
            let g = TownMap.groundAt(m, c, r);
            (g == Ground.Cobble or g == Ground.Dirt) and not isFoot(ctx, c, r) and TownMap.shapeAt(m, c, r) == Shape.Flat
        }) |> List.flatMap(cr -> {
            let (c, r) = cr;
            let z = top(ctx, c, r);
            dirs() |> List.filter(d -> {
                let (_, dc, dr) = d;
                TownMap.groundAt(m, c + dc, r + dr) == Ground.Grass and Float64.abs(top(ctx, c + dc, r + dr) - z) <= 0.000001 and not isFoot(ctx, c + dc, r + dr)
            }) |> List.flatMap(d -> {
                let (name, dc, dr) = d;
                let (p, q) = edgePoints(m, c, r, name);
                let (ix, iy) = (fl(0 - dc), fl(dr));
                let w = 0.14 + 0.06 * h01(c, r, 9 + String.length(name));
                let s = 0.32;
                let at = (pt: (Float64, Float64), k: Float64, zz: Float64) -> Faces.p3(fst(pt) + ix * k, snd(pt) + iy * k, zz);
                Faces.quad("grass", at(p, 0.0, z + 0.012) :: at(q, 0.0, z + 0.012) :: at(q, w, z + 0.012) :: at(p, w, z + 0.012) :: Nil,
                           (0.0, 0.0) :: (1.0, 0.0) :: (1.0, 0.15) :: (0.0, 0.15) :: Nil, 0.85 :: 0.85 :: 0.85 :: 0.85 :: Nil) ::
                Faces.quad(groundMaterial(TownMap.groundAt(m, c, r)), at(p, 0.0, z + 0.006) :: at(q, 0.0, z + 0.006) :: at(q, s, z + 0.006) :: at(p, s, z + 0.006) :: Nil,
                           (0.0, 0.0) :: (1.0, 0.0) :: (1.0, 0.32) :: (0.0, 0.32) :: Nil, 1.0 :: 0.72 :: 0.72 :: 1.0 :: Nil) :: Nil
            })
        })

    // ── ⑤ 建物 ──

    def wallName(w: Wall): String = match w {
        case Wall.Plaster => "plaster"
        case Wall.Stone   => "stone"
    }

    /// 壁の 1 マスの中段の種類。南（カメラ向き）の 1 階の真ん中 = 扉、窓は 2 階以上の全部の列と 1 階の 1 つおき。東西は 1 つおき。北は窓なし。
    def middleKind(side: String, i: Int32, floor: Int32, door: Int32): String =
        if (side == "s" and floor == 0 and i == door) "door"
        else if (side == "s" and (floor > 0 or Int32.modulo(i, 2) == 1)) "window"
        else if ((side == "e" or side == "w") and Int32.modulo(i, 2) == 1) "window"
        else "plain"

    def buildingQuads(ctx: Ctx, b: Building): List[Quad] =
        let m = ctx#map;
        let z0 = fl(b#level) * m#heightStep;
        let (x0, x1) = (fl(b#x), fl(b#x + b#w));
        let yN = wy(m, b#y) + 1.0;
        let yS = wy(m, b#y + b#h - 1);
        let wall = wallName(b#wall);
        let zt = z0 + fl(b#floors) * TownMap.floorHeight();
        let edges = List.range(0, b#w) |> List.map(i -> ("s", i, (x0 + fl(i), yS), (x0 + fl(i) + 1.0, yS))) :::
                    List.range(0, b#w) |> List.map(i -> ("n", i, (x1 - fl(i), yN), (x1 - fl(i) - 1.0, yN))) :::
                    List.range(0, b#h) |> List.map(i -> ("e", i, (x1, yS + fl(i)), (x1, yS + fl(i) + 1.0))) :::
                    List.range(0, b#h) |> List.map(i -> ("w", i, (x0, yN - fl(i)), (x0, yN - fl(i) - 1.0)));
        let walls = edges |> List.flatMap(e -> wallColumn(b, wall, z0, (b#w) / 2, e));
        List.append(walls, Faces.withOwner(Faces.Owner.Roof(b#id), gableRoof(wall, x0, x1, yS, yN, zt, b)))

    /// 壁の 1 列（階ごとに下・中・上の 3 段の壁タイルと、階の境の帯）。
    def wallColumn(b: Building, wall: String, z0: Float64, door: Int32, e: (String, Int32, (Float64, Float64), (Float64, Float64))): List[Quad] =
        let (side, i, p, q) = e;
        let fh = TownMap.floorHeight();
        let panels = List.range(0, b#floors) |> List.flatMap(f -> {
            let zf = z0 + fl(f) * fh;
            let kind = middleKind(side, i, f, door);
            let rows = if (kind == "door") (zf, zf + 2.0, "door") :: (zf + 2.0, zf + 3.0, "plain") :: Nil
                else (zf, zf + 1.0, "plain") :: (zf + 1.0, zf + 2.0, kind) :: (zf + 2.0, zf + 3.0, "plain") :: Nil;
            rows |> List.mapWithIndex((k, row) -> {
                let (za, zb, rowKind) = row;
                let aa = if (f == 0 and k == 0) 0.5 else 1.0;
                let mat = if (rowKind == "plain") wall else "${wall}_${rowKind}";
                let u0 = fst(p) + snd(p);
                let uv = if (rowKind == "plain") (u0, za) :: (u0 + 1.0, za) :: (u0 + 1.0, zb) :: (u0, zb) :: Nil else Faces.fullUv();
                let owner = if (rowKind == "plain") Faces.Owner.Walls(b#id) else Faces.Owner.Opening(b#id, openingNumber(side, i, f));
                { owner = owner | Faces.quad(mat, Faces.p3(fst(p), snd(p), za) :: Faces.p3(fst(q), snd(q), za) :: Faces.p3(fst(q), snd(q), zb) :: Faces.p3(fst(p), snd(p), zb) :: Nil,
                           uv, aa :: aa :: 1.0 :: 1.0 :: Nil) }
            })
        });
        let (nx, ny) = match side {
            case "s" => (0.0, -1.0)
            case "n" => (0.0, 1.0)
            case "e" => (1.0, 0.0)
            case _   => (-1.0, 0.0)
        };
        let o = 0.06;
        let bands = List.range(1, b#floors) |> List.map(f -> {
            let zf = z0 + fl(f) * fh;
            let at = (pt: (Float64, Float64), zz: Float64) -> Faces.p3(fst(pt) + nx * o, snd(pt) + ny * o, zz);
            { owner = Faces.Owner.Walls(b#id) | Faces.quad("trim", at(p, zf - 0.08) :: at(q, zf - 0.08) :: at(q, zf + 0.08) :: at(p, zf + 0.08) :: Nil,
                       (0.0, 0.0) :: (1.0, 0.0) :: (1.0, 0.16) :: (0.0, 0.16) :: Nil, Nil) }
        });
        List.append(panels, bands)

    /// 建物の中の窓・扉 1 枚の番号（向き・列・階から。窓と扉を 1 枚ずつ出す時の鍵）。
    def openingNumber(side: String, i: Int32, floor: Int32): Int32 =
        let sideNumber = match side {
            case "s" => 0
            case "e" => 1
            case "w" => 2
            case _   => 3
        };
        sideNumber * 10000 + i * 10 + floor

    /// 切妻屋根を厚みのある 2 枚の斜面で作る（軒の裏・けらば・軒先の縁・妻壁）。ridge Y は棟が南北・X は東西。
    def gableRoof(wall: String, x0: Float64, x1: Float64, yS: Float64, yN: Float64, z: Float64, b: Building): List[Quad] =
        let pitch = b#pitchDeg * Num.pi() / 180.0;
        let over = b#overhang;
        let thick = 0.18;
        // 瓦は 32 画素に 2×2 枚。1.6 倍で 1 枚 0.3 m 前後にして石畳の粒とそろえる
        let s = 1.6;
        let tanP = Num.sin(pitch) / Num.cos(pitch);
        let band = (0.0, 0.0) :: (1.0, 0.0) :: (1.0, 0.2) :: (0.0, 0.2) :: Nil;
        let p = Faces.p3;
        let lower = (pts: List[P3]) -> pts |> List.map(pt -> p(pt#x, pt#y, pt#z - thick)) |> List.reverse;
        match b#ridge {
            case Ridge.Y =>
                let half = (x1 - x0) / 2.0;
                let xm = x0 + half;
                let zr = z + half * tanP;
                let ze = z - over * tanP;
                let (ya, yb) = (yS - over, yN + over);
                let span = half + over;
                let slope = Num.sqrt(span * span + (zr - ze) * (zr - ze));
                let slopes = (-1.0 :: 1.0 :: Nil) |> List.flatMap(side -> {
                    let xe = xm + side * span;
                    let raw = p(xe, ya, ze) :: p(xe, yb, ze) :: p(xm, yb, zr) :: p(xm, ya, zr) :: Nil;
                    let pts = if (side > 0.0) swapPairs(raw) else raw;
                    let eave = p(xe, ya, ze - thick) :: p(xe, yb, ze - thick) :: p(xe, yb, ze) :: p(xe, ya, ze) :: Nil;
                    Faces.quad("roof", pts, pts |> List.map(pt -> (pt#y * s, Float64.abs(pt#x - xe) / span * slope * s)), Nil) ::
                    Faces.quad("trim", lower(pts), Faces.fullUv(), Nil) ::
                    ((ya :: yb :: Nil) |> List.map(yy -> Faces.quad("trim", p(xe, yy, ze - thick) :: p(xm, yy, zr - thick) :: p(xm, yy, zr) :: p(xe, yy, ze) :: Nil, band, Nil))) :::
                    Faces.quad("trim", if (side > 0.0) eave else List.reverse(eave), band, Nil) :: Nil
                });
                let gables = (yS :: yN :: Nil) |> List.map(yy ->
                    Faces.quad(wall, p(x0, yy, z) :: p(x1, yy, z) :: p(xm, yy, zr - 0.02) :: p(xm, yy, zr - 0.02) :: Nil,
                               (x0 + yy, z) :: (x1 + yy, z) :: (xm + yy, zr) :: (xm + yy, zr) :: Nil, Nil));
                List.append(slopes, gables)
            case Ridge.X =>
                let half = (yN - yS) / 2.0;
                let ym = yS + half;
                let zr = z + half * tanP;
                let ze = z - over * tanP;
                let (xa, xb) = (x0 - over, x1 + over);
                let span = half + over;
                let slope = Num.sqrt(span * span + (zr - ze) * (zr - ze));
                let slopes = (-1.0 :: 1.0 :: Nil) |> List.flatMap(side -> {
                    let ye = ym + side * span;
                    let raw = p(xa, ye, ze) :: p(xb, ye, ze) :: p(xb, ym, zr) :: p(xa, ym, zr) :: Nil;
                    let pts = if (side > 0.0) swapPairs(raw) else raw;
                    let eave = p(xa, ye, ze - thick) :: p(xb, ye, ze - thick) :: p(xb, ye, ze) :: p(xa, ye, ze) :: Nil;
                    Faces.quad("roof", pts, pts |> List.map(pt -> (pt#x * s, Float64.abs(pt#y - ye) / span * slope * s)), Nil) ::
                    Faces.quad("trim", lower(pts), Faces.fullUv(), Nil) ::
                    ((xa :: xb :: Nil) |> List.map(xx -> Faces.quad("trim", p(xx, ye, ze - thick) :: p(xx, ym, zr - thick) :: p(xx, ym, zr) :: p(xx, ye, ze) :: Nil, band, Nil))) :::
                    Faces.quad("trim", if (side > 0.0) List.reverse(eave) else eave, band, Nil) :: Nil
                });
                let gables = (x0 :: x1 :: Nil) |> List.map(xx ->
                    Faces.quad(wall, p(xx, yS, z) :: p(xx, yN, z) :: p(xx, ym, zr - 0.02) :: p(xx, ym, zr - 0.02) :: Nil,
                               (yS - xx, z) :: (yN - xx, z) :: (ym - xx, zr) :: (ym - xx, zr) :: Nil, Nil));
                List.append(slopes, gables)
        }

    /// [a, b, c, d] → [b, a, d, c]（斜面の反対側を同じ巡りにする）。
    def swapPairs(pts: List[P3]): List[P3] = match pts {
        case a :: b :: c :: d :: Nil => b :: a :: d :: c :: Nil
        case _                       => pts
    }

    // ── ⑥ 箱の物（生垣・木箱・柵・目印の石の柱） ──

    def propQuads(ctx: Ctx): List[Quad] =
        let m = ctx#map;
        cells(m) |> List.flatMap(cr -> {
            let (c, r) = cr;
            let z = top(ctx, c, r);
            let x0 = fl(c);
            let y0 = wy(m, r);
            match TownMap.propAt(m, c, r) {
                case Prop.Hedge   => Faces.withOwner(Faces.Owner.Prop(c, r), hedge(ctx, c, r, z))
                case Prop.Crate   => Faces.withOwner(Faces.Owner.Prop(c, r), crate(x0 + 0.5 + jitter(c, r), y0 + 0.5, z))
                case Prop.Fence   => Faces.withOwner(Faces.Owner.Prop(c, r), fence(ctx, c, r, z))
                case Prop.Obelisk => Faces.withOwner(Faces.Owner.Monument(c, r), obelisk(x0 + 0.5, y0 + 0.5, z))
                case _            => Nil
            }
        })

    /// 板と木箱をマスの真ん中から少し東西へずらす量（並びが機械的に見えないように）。
    def jitter(c: Int32, r: Int32): Float64 = (h01(c, r, 3) - 0.5) * 0.2

    /// 生垣: 1 マスの箱（高さ 1 m）。隣も生垣なら境の面を作らず、続いた 1 本の箱にする。
    def hedge(ctx: Ctx, c: Int32, r: Int32, z: Float64): List[Quad] =
        let m = ctx#map;
        let isHedge = (cc, rr) -> TownMap.propAt(m, cc, rr) == Prop.Hedge;
        let open = dirs() |> List.filter(d -> { let (_, dc, dr) = d; not isHedge(c + dc, r + dr) }) |> List.map(d -> { let (n, _, _) = d; n });
        let x0 = fl(c);
        let y0 = wy(m, r);
        let xa = if (isHedge(c - 1, r)) x0 else x0 + 0.08;
        let xb = if (isHedge(c + 1, r)) x0 + 1.0 else x0 + 0.92;
        let ya = if (isHedge(c, r + 1)) y0 else y0 + 0.12;
        let yb = if (isHedge(c, r - 1)) y0 + 1.0 else y0 + 0.88;
        box(oneMat("hedge"), Faces.p3(xa, ya, z), Faces.p3(xb, yb, z + 1.0), "t" + String.flatten(open), 0.65)

    def crate(x: Float64, y: Float64, z: Float64): List[Quad] =
        let s = 0.8;
        box({ top = "crate_top", south = "crate_front", side = "crate_front", fit = true },
            Faces.p3(x - s / 2.0, y - s / 2.0, z), Faces.p3(x + s / 2.0, y + s / 2.0, z + s * 0.78), allFaces(), 0.55)

    /// 柵: 隣の柵へ向けて横木を 2 本渡し、マスの真ん中に柱を立てる（細い箱だけで組む）。
    def fence(ctx: Ctx, c: Int32, r: Int32, z: Float64): List[Quad] =
        let m = ctx#map;
        let xm = fl(c) + 0.5;
        let ym = wy(m, r) + 0.5;
        let wood = oneMat("wood");
        let post = box(wood, Faces.p3(xm - 0.06, ym - 0.06, z), Faces.p3(xm + 0.06, ym + 0.06, z + 0.85), allFaces(), 0.5);
        let cap = box(wood, Faces.p3(xm - 0.08, ym - 0.08, z + 0.85), Faces.p3(xm + 0.08, ym + 0.08, z + 0.92), allFaces(), 0.9);
        let rails = ((0, -1) :: (0, 1) :: (-1, 0) :: (1, 0) :: Nil)
            |> List.filter(d -> TownMap.propAt(m, c + fst(d), r + snd(d)) == Prop.Fence)
            |> List.flatMap(d -> {
                let (dc, dr) = d;
                (0.3 :: 0.65 :: Nil) |> List.flatMap(zr -> {
                    let (xa, xb) = (Float64.min(xm, xm + fl(dc) * 0.5), Float64.max(xm, xm + fl(dc) * 0.5));
                    let (ya, yb) = (Float64.min(ym, ym - fl(dr) * 0.5), Float64.max(ym, ym - fl(dr) * 0.5));
                    let padX = if (dc == 0) 0.025 else 0.0;
                    let padY = if (dr == 0) 0.025 else 0.0;
                    box(wood, Faces.p3(xa - padX, ya - padY, z + zr), Faces.p3(xb + padX, yb + padY, z + zr + 0.08), allFaces(), 0.9)
                })
            });
        List.flatten(post :: cap :: rails :: Nil)

    /// 目印の石の柱: 2 段の台座に細い柱と笠。
    def obelisk(x: Float64, y: Float64, z: Float64): List[Quad] =
        let st = oneMat("stone_cut");
        let block = (half: Float64, za: Float64, zb: Float64, ao: Float64) -> box(st, Faces.p3(x - half, y - half, z + za), Faces.p3(x + half, y + half, z + zb), allFaces(), ao);
        List.flatten(block(0.5, 0.0, 0.35, 0.5) :: block(0.36, 0.35, 0.6, 0.7) :: block(0.2, 0.6, 2.6, 0.8) :: block(0.12, 2.6, 2.85, 0.9) :: Nil)

    // ── ⑦ 地図の外（低い地面と暗い森） ──

    def marginQuads(ctx: Ctx): List[Quad] =
        let m = ctx#map;
        let low = fl(m#margin#level) * m#heightStep;
        let n = fl(m#margin#cells);
        let (w, h) = (fl(m#width), fl(m#height));
        let south = fl(TownMap.southLevel(m)) * m#heightStep;
        ((0.0 - n, 0.0 - n, w + n, 0.0, south) :: (0.0 - n, h, w + n, h + n * 3.0, low) :: (0.0 - n, 0.0, 0.0, h, low) :: (w, 0.0, w + n, h, low) :: Nil)
            |> List.map(rect -> {
                let (x0, y0, x1, y1, z) = rect;
                Faces.quad("grass", Faces.p3(x0, y0, z) :: Faces.p3(x1, y0, z) :: Faces.p3(x1, y1, z) :: Faces.p3(x0, y1, z) :: Nil,
                           (x0, y0) :: (x1, y0) :: (x1, y1) :: (x0, y1) :: Nil, 0.7 :: 0.7 :: 0.7 :: 0.7 :: Nil)
            })

    // ── 板の物 ──

    /// 絵 sprite を足元 (x, y, z) に立てる板。height を渡せばその高さ（m）に、無ければ 32 画素 = 1 m。
    def board(sizes: SpriteSizes, sprite: String, x: Float64, y: Float64, z: Float64, height: Option[Float64]): Option[Board] =
        Map.get(sprite, sizes) |> Option.map(wh -> {
            let (pw, ph) = wh;
            let k = height |> Option.map(hh -> hh / fl(ph)) |> Option.getWithDefault(1.0 / 32.0);
            { sprite = sprite, x = x, y = y, z = z, width = fl(pw) * k, height = fl(ph) * k,
              tint = Faces.white(), flip = false, shadow = BoardShadow.Grounded, owner = Faces.Owner.Fixed }
        })

    def propBoards(ctx: Ctx, sizes: SpriteSizes, skipNpcColumn: Option[Int32]): List[Board] =
        let m = ctx#map;
        cells(m) |> List.filterMap(cr -> {
            let (c, r) = cr;
            let z = top(ctx, c, r);
            let x = fl(c) + 0.5;
            let y = wy(m, r) + 0.5;
            let at = (sprite: String, height: Option[Float64]) -> board(sizes, sprite, x + jitter(c, r), y, z, height) |> Option.map(b -> { owner = Faces.Owner.Prop(c, r) | b });
            match TownMap.propAt(m, c, r) {
                case Prop.Tree    => at("sprites/tree_broadleaf.png", None)
                case Prop.Cypress => at("sprites/tree_cypress.png", None)
                case Prop.Lamp    => at("sprites/street_lamp_ornate.png", None)
                case Prop.Bush    => at("sprites/tree_broadleaf.png", Some(0.8 + 0.5 * h01(c, r, 4)))
                case Prop.Npc(k)  => if (skipNpcColumn == Some(c)) None else npcBoard(sizes, k, x, y, z) |> Option.map(b -> { owner = Faces.Owner.Prop(c, r) | b })
                case _            => None
            }
        })

    /// 町の人（地図の 1 = 旅人・2 = 商人・3 = 旅人を左右反転して色を寄せた物）。
    def npcBoard(sizes: SpriteSizes, k: Int32, x: Float64, y: Float64, z: Float64): Option[Board] =
        let sprite = if (k == 2) "sprites/merchant_td.png" else "sprites/traveler_td.png";
        board(sizes, sprite, x, y, z, None) |> Option.map(b ->
            if (k == 3) { tint = { r = 0.82, g = 0.86, b = 1.05 }, flip = true | b } else b)

    /// 地図の北と東西の外に並べる暗い森（影は落とさない・足元の影も置かない）。
    // WhyNot: 森の板に太陽の影を落とさせない — 画面の奥の端で暗く沈む所に 200 枚余りの影の板が増え、CPU の描き出しの 1 コマが重くなるわりに見えない。
    def forestBoards(ctx: Ctx, sizes: SpriteSizes): List[Board] =
        let m = ctx#map;
        let z = fl(m#margin#level) * m#heightStep;
        let n = m#margin#cells;
        let (w, h) = (m#width, m#height);
        let dark = { r = 0.45, g = 0.55, b = 0.6 };
        let quiet = (b: Board) -> { tint = dark, shadow = BoardShadow.Unshadowed | b };
        let rows = List.range(0, 5) |> List.flatMap(row -> {
            let yy = fl(h) + 1.0 + fl(row) * 2.4;
            List.range(0, (w + 2 * n + 1) / 2) |> List.map(i -> 0 - n + 2 * i) |> List.filterMap(x -> {
                let sprite = if (h01(x, row, 7) < 0.5) "sprites/tree_cypress.png" else "sprites/tree_broadleaf.png";
                board(sizes, sprite, fl(x) + 2.0 * h01(x, row, 8), yy + h01(x, row, 9), z, Some(5.0 + 3.0 * h01(x, row, 10))) |> Option.map(quiet)
            })
        });
        let sides = (-3.0 :: fl(w) + 2.0 :: Nil) |> List.flatMap(sideX ->
            List.range(0, (h + 1) / 2) |> List.map(i -> 2 * i) |> List.filterMap(k ->
                board(sizes, "sprites/tree_broadleaf.png", sideX + 2.0 * h01(k, 1, 11), fl(k) + 0.3, z, Some(5.5)) |> Option.map(quiet)));
        List.append(rows, sides)
}
