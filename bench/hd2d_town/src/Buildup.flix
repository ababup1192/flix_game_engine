// Buildup — 歩く先の町が出来ていく演出。マスの地面はせり上がり、箱の物と板の物は上から降って着地し（一瞬つぶれて伸びる・土ぼこり・
// 足元の影は落ちる間に小さい影から大きくなる）、建物は壁が下から伸び → 屋根がかぶさり → 窓と扉がポンと出る。目印の石の柱は降って着地し、カメラが小さく揺れる。
// 出来た物は動かない物の集まり（staticGroup）へまとめ、出来ていく途中の物だけを毎コマの置いた物として描く。座標の入れ替えは Faces と同じ。
mod Buildup {
    use fge::{DocJson, JsonCodec, Mat4, Mesh3d, Num, Scene3d, Texture3d, Vec2, Vec3}
    use Util.Json.Json
    use fge::ShaderDoc.FilterMode
    use Faces.{Owner, Quad}
    use TileMap3d.{Board}
    use TownMap.{TownMap}

    /// 演出の時刻の決まり（秒）。lead = 出来ていく前線が先頭より何行先にあるか（前線は先頭と一緒に進み、止まれば止まる）・
    /// afterRowsPerSec = 先頭が行き着いた後に、残りの奥の行が出来ていく速さ（行/秒）・
    /// rippleSec・startDelay = はじめに隊列のまわりの行が 1 行ずつ出来る間と、最初の遅れ・
    /// rise = 地面がせり上がる秒・fall・fallHeight = 物が降る秒と高さ・squash = つぶれて伸びる秒・
    /// monumentFall・monumentHeight・shake・shakeAmp = 目印が降る秒と高さ・カメラが揺れる秒と幅（m）・
    /// wallRise・roofDelay・roofFall・roofHeight・openingDelay・openingStep・pop = 建物の部品の秒・dust = 土ぼこりの秒・dustScale = 土ぼこりの粒の数の倍率・
    /// impactDust = 目印の着地の土ぼこりの倍率（粒の数・広がり）・hitstopSec = 目印の着地で止める秒・flash = 着地の瞬間に上げる露出（段・2 コマで戻る）・
    /// waveSpeed・waveHeight = 着地の衝撃が外へ伝わる速さ（m/秒）と、板の物（木・街灯・町の人）が跳ねる高さ（m・遠いほど小さい）。
    pub type alias Timing = { lead = Float64, afterRowsPerSec = Float64, rippleSec = Float64, startDelay = Float64,
                              rise = Float64, fall = Float64, fallHeight = Float64, squash = Float64,
                              monumentFall = Float64, monumentHeight = Float64, shake = Float64, shakeAmp = Float64,
                              wallRise = Float64, roofDelay = Float64, roofFall = Float64, roofHeight = Float64,
                              openingDelay = Float64, openingStep = Float64, pop = Float64, dust = Float64, dustScale = Float64,
                              impactDust = Float64, hitstopSec = Float64, flash = Float64, waveSpeed = Float64, waveHeight = Float64 }

    /// 前線（マスごとに出来始める時刻）。cellTime = 列・行 → 時刻・monumentAt = 目印が降り始める時刻（None ならそのマスの時刻のすぐ後）・
    /// pace = 出始める時刻 → 部品の動きの秒の倍率（大きいほどゆっくり。土ぼこりの粒はその逆数の倍）。
    pub type alias Front = { cellTime = Int32 -> Int32 -> Float64, monumentAt = Option[Float64], pace = Float64 -> Float64 }

    /// 部品の動きの秒を k 倍にした決まり（土ぼこりの粒は 1/k 倍）。
    pub def paced(tm: Timing, k: Float64): Timing =
        { rise = tm#rise * k, fall = tm#fall * k, squash = tm#squash * k, monumentFall = tm#monumentFall * k,
          wallRise = tm#wallRise * k, roofDelay = tm#roofDelay * k, roofFall = tm#roofFall * k, openingDelay = tm#openingDelay * k,
          openingStep = tm#openingStep * k, pop = tm#pop * k, dustScale = tm#dustScale / k | tm }

    /// 立つ点から輪が広がる前線。輪は r#buildSec 秒で一番遠いマスへ届き、届く距離は時間の 1/r#curve 乗で増える（curve が 1 より小さいほど、はじめはゆっくりで後ほど速い）。
    /// 部品の動きの秒は r#paceFrom 倍から r#paceTo 倍へ、輪の進みに合わせて替える。目印は輪が止まった時に降りはじめる。
    /// col・row = 立つマス・width・height = 地図の大きさ。マスごとに ±r#jitter 秒ずらしてそろい過ぎを崩す。
    pub def radialFront(tm: Timing, col: Int32, row: Int32, width: Int32, height: Int32, r: Radial): Front =
        let far = List.foldLeft((a, cr) -> Float64.max(a, distanceOf(col, row, fst(cr), snd(cr))), 1.0,
                                (0, 0) :: (width - 1, 0) :: (0, height - 1) :: (width - 1, height - 1) :: Nil);
        let at = (c: Int32, rr: Int32) -> {
            let u = distanceOf(col, row, c, rr) / far;
            let wobble = (Int32.toFloat64(Int32.modulo(c * 73 + rr * 151, 17)) / 16.0 - 0.5) * 2.0 * r#jitter * u;
            // WhyNot: ずれで輪の終わりより後に出る物を作らない — 輪が止まった後に遅れて降る物を待つ間が出来る
            Num.clamp(tm#startDelay, tm#startDelay + r#buildSec, tm#startDelay + r#buildSec * Float64.pow(base = u, r#curve) + wobble)
        };
        let pace = (t: Float64) -> {
            let u = Num.clamp(0.0, 1.0, (t - tm#startDelay) / r#buildSec);
            r#paceFrom + (r#paceTo - r#paceFrom) * u
        };
        { cellTime = at, monumentAt = Some(tm#startDelay + r#buildSec), pace = pace }

    def distanceOf(c0: Int32, r0: Int32, c: Int32, r: Int32): Float64 =
        let dx = Int32.toFloat64(c - c0);
        let dy = Int32.toFloat64(r - r0);
        Num.sqrt(dx * dx + dy * dy)

    /// 部品 1 つ（同じ持ち主・同じ材質の面を 1 つの形にした物）。base = 持ち主の部品の足元の真ん中（engine の座標）・
    /// center = この形の真ん中・start = 出始める時刻・plain = 窓と扉が出る前に貼る壁の形と材質。
    pub type alias Piece = { owner = Owner, key = String, mesh = Mesh3d.Mesh3d, material = Scene3d.Material3d, base = Vec3.Vec3, center = Vec3.Vec3,
                             start = Float64, plain = Option[(Mesh3d.Mesh3d, Scene3d.Material3d)], timing = Timing }

    def placed(world: Mat4.Mat4, mesh: Mesh3d.Mesh3d, material: Scene3d.Material3d): Scene3d.Instance3d =
        Scene3d.meshInstance(mesh, world) |> Scene3d.withMaterial(material)

    /// 板の物 1 枚の出し方。land = 着地する時刻。
    pub type alias BoardPiece = { board = Board, billboard = Scene3d.Billboard3d, start = Float64, land = Float64, timing = Timing }

    /// 読み込みで 1 回作る物。fixed = はじめからある物（地図の外と、まだ出来ていないマスの下の低い地面）・done = 全部出来た後の時刻。
    pub type alias Show = { timing = Timing, pieces = Vector[Piece], boards = List[BoardPiece], fixed = Scene3d.StaticGroup,
                            dustTexture = String, done = Float64, landings = List[(Vec3.Vec3, Float64, Bool, Float64)] }

    pub def defaultTiming(): Timing =
        { lead = 5.5, afterRowsPerSec = 4.0, rippleSec = 0.12, startDelay = 0.2,
          rise = 0.25, fall = 0.3, fallHeight = 5.0, squash = 0.22,
          monumentFall = 0.5, monumentHeight = 14.0, shake = 0.5, shakeAmp = 0.12,
          wallRise = 0.3, roofDelay = 0.4, roofFall = 0.24, roofHeight = 4.0,
          openingDelay = 0.7, openingStep = 0.02, pop = 0.14, dust = 0.4, dustScale = 1.0,
          impactDust = 1.0, hitstopSec = 0.0, flash = 0.0, waveSpeed = 14.0, waveHeight = 0.0 }

    /// 行 r が出来る時刻。leaderRows = コマごとの (時刻, 先頭の行（小数）)。前線は先頭の lead 行先で、先頭と一緒に進む。
    /// はじめから前線の手前にある行は隊列のまわりから 1 行ずつ rippleSec おきに、先頭が行き着いた後に残る奥の行は afterRowsPerSec で出来る。
    pub def rowTimeOf(tm: Timing, leaderRows: Vector[(Float64, Float64)], r: Int32): Float64 =
        let target = Int32.toFloat64(r) + tm#lead;
        let (t0, row0) = Vector.head(leaderRows) |> Option.getWithDefault((0.0, 0.0));
        let deepest = Vector.foldLeft((acc, tr) -> if (snd(tr) < snd(acc)) tr else acc, (t0, row0), leaderRows);
        if (row0 <= target) tm#startDelay + Float64.abs(row0 - Int32.toFloat64(r)) * tm#rippleSec
        else Vector.find(tr -> snd(tr) <= target, leaderRows) |> Option.map(fst)
            |> Option.getWithDefault(fst(deepest) + (snd(deepest) - target) / tm#afterRowsPerSec)

    /// 建物が出始める時刻（建物の敷地のマスのどれかに前線が来た時）。
    def buildingTime(front: Front, m: TownMap, id: String): Float64 =
        m#buildings |> List.find(b -> b#id == id)
            |> Option.map(b -> List.range(b#x, b#x + b#w) |> List.flatMap(c -> List.range(b#y, b#y + b#h) |> List.map(r -> front#cellTime(c, r)))
                |> List.minimum |> Option.getWithDefault(0.0))
            |> Option.getWithDefault(0.0)

    /// 持ち主の部品が出始める時刻。
    def startOf(tm: Timing, front: Front, m: TownMap, openingOrder: Map[Owner, Int32], o: Owner): Float64 = match o {
        case Owner.Fixed          => 0.0
        case Owner.Cell(c, r)     => front#cellTime(c, r)
        case Owner.Prop(c, r)     => front#cellTime(c, r) + 0.15
        case Owner.Monument(c, r) => front#monumentAt |> Option.getWithDefault(front#cellTime(c, r) + 0.2)
        case Owner.Walls(id)      => buildingTime(front, m, id)
        case Owner.Roof(id)       => buildingTime(front, m, id) + tm#roofDelay
        case Owner.Opening(id, _) => buildingTime(front, m, id) + tm#openingDelay
                                     + Int32.toFloat64(Map.getWithDefault(o, 0, openingOrder)) * tm#openingStep
    }

    /// 持ち主の部品が動き終わる時刻。
    def endOf(tm: Timing, start: Float64, o: Owner): Float64 = match o {
        case Owner.Fixed          => 0.0
        case Owner.Cell(_, _)     => start + tm#rise
        case Owner.Prop(_, _)     => start + tm#fall + tm#squash
        case Owner.Monument(_, _) => start + tm#monumentFall + tm#squash
        case Owner.Walls(_)       => start + tm#wallRise
        case Owner.Roof(_)        => start + tm#roofFall + tm#squash
        case Owner.Opening(_, _)  => start + tm#pop
    }

    /// 面の列の足元の真ん中と真ん中（engine の座標）。
    def anchorsOf(qs: List[Quad]): (Vec3.Vec3, Vec3.Vec3) =
        let ps = qs |> List.flatMap(q -> q#points);
        let lo = (f: Faces.P3 -> Float64) -> List.foldLeft((a, p) -> Float64.min(a, f(p)), 1000000.0, ps);
        let hi = (f: Faces.P3 -> Float64) -> List.foldLeft((a, p) -> Float64.max(a, f(p)), -1000000.0, ps);
        let cx = (lo(p -> p#x) + hi(p -> p#x)) / 2.0;
        let cy = (lo(p -> p#y) + hi(p -> p#y)) / 2.0;
        (Vec3.v3(cx, lo(p -> p#z), cy), Vec3.v3(cx, (lo(p -> p#z) + hi(p -> p#z)) / 2.0, cy))

    /// 窓と扉の前に貼る壁の材質の名前（"stone_window" → "stone"）。
    def plainMaterial(name: String): String =
        String.splitOn(substr = "_", name) |> List.head |> Option.getWithDefault(name)

    /// 町の面と板から演出の部品を作る。materialOf = 材質の名前 → 置いた物の材質と色の掛け目・billboardOf = 板 → ビルボード。
    pub def make(tm: Timing, front: Front, m: TownMap, quads: List[Quad], boards: List[Board],
                 materialOf: String -> Option[(Scene3d.Material3d, Faces.Rgb)], billboardOf: Board -> Option[Scene3d.Billboard3d],
                 dust: Texture3d.Texture3d): Result[String, Show] =
        let moving = quads |> List.filter(q -> q#owner != Owner.Fixed);
        let byOwner = moving |> List.foldLeft((acc, q) -> Map.insertWith((fresh, old) -> List.append(fresh, old), q#owner, q :: Nil, acc), Map.empty());
        let wallBase = (id: String) -> Map.get(Owner.Walls(id), byOwner) |> Option.map(anchorsOf) |> Option.map(fst);
        let openings = byOwner |> Map.keysOf |> Set.toList |> List.filter(o -> match o {
            case Owner.Opening(_, _) => true
            case _                   => false
        });
        let openingOrder = openings |> List.mapWithIndex((i, o) -> (o, Int32.modulo(i, 12))) |> List.toMap;
        let pieceOf = (o: Owner, material: String, qs: List[Quad]) -> forM (
            (mat, tint) <- materialOf(material) |> Option.toOk("材質 ${material} が無い");
            mesh <- Faces.toMesh(tint, qs)
        ) yield {
            let (base0, center) = anchorsOf(qs);
            let base = match o {
                case Owner.Opening(id, _) => wallBase(id) |> Option.getWithDefault(base0)
                case _                    => Map.get(o, byOwner) |> Option.map(anchorsOf) |> Option.map(fst) |> Option.getWithDefault(base0)
            };
            let plain = match o {
                case Owner.Opening(_, _) =>
                    materialOf(plainMaterial(material)) |> Option.flatMap(mt -> Faces.toMesh(snd(mt), qs) |> Result.toOption
                        |> Option.map(pm -> (pm, fst(mt))))
                case _ => None
            };
            let own = paced(tm, front#pace(startOf(tm, front, m, openingOrder, o)));
            { owner = o, key = "${o}:${material}", mesh = mesh, material = mat,
              base = base, center = center, start = startOf(own, front, m, openingOrder, o), plain = plain, timing = own }
        };
        let byOwnerMaterial = moving |> List.foldLeft((acc, q) -> Map.insertWith((fresh, old) -> List.append(fresh, old), (q#owner, q#material), q :: Nil, acc), Map.empty());
        let pieces = byOwnerMaterial |> Map.toList |> List.map(entry -> { let ((o, mat), qs) = entry; pieceOf(o, mat, qs) }) |> Result.sequence;
        let fixedQuads = List.append(quads |> List.filter(q -> q#owner == Owner.Fixed), basePlane(m) :: Nil);
        let fixedByMaterial = fixedQuads |> List.foldLeft((acc, q) -> Map.insertWith((fresh, old) -> List.append(fresh, old), q#material, q :: Nil, acc), Map.empty());
        let fixedItems = fixedByMaterial |> Map.toList |> List.filterMap(entry -> {
            let (mat, qs) = entry;
            forM (
                (material, tint) <- materialOf(mat);
                mesh <- Faces.toMesh(tint, qs) |> Result.toOption
            ) yield ("fixed:${mat}", Scene3d.meshInstance(mesh, Mat4.identity()) |> Scene3d.withMaterial(material))
        });
        let boardPieces = boards |> List.filterMap(b -> billboardOf(b) |> Option.map(bb -> {
            let start = startOf(tm, front, m, Map.empty(), b#owner);
            let own = paced(tm, front#pace(start));
            { board = b, billboard = bb, start = start, land = if (b#owner == Owner.Fixed) 0.0 else start + own#fall, timing = own }
        }));
        pieces |> Result.map(ps -> {
            let landings = List.append(
                ps |> List.filterMap(p -> match p#owner {
                    case Owner.Prop(_, _)     => Some((p#owner, (p#base, p#start + p#timing#fall, false, p#timing#dustScale)))
                    case Owner.Monument(_, _) => Some((p#owner, (p#base, p#start + p#timing#monumentFall, true, p#timing#dustScale)))
                    case _                    => None
                }) |> List.toMap |> Map.valuesOf,
                boardPieces |> List.filter(bp -> bp#board#owner != Owner.Fixed)
                    |> List.map(bp -> (Vec3.v3(bp#board#x, bp#board#z, bp#board#y), bp#land, false, bp#timing#dustScale)));
            let done = List.foldLeft((a, p) -> Float64.max(a, endOf(p#timing, p#start, p#owner)), 0.0, ps);
            { timing = tm, pieces = List.toVector(ps), boards = boardPieces, fixed = Scene3d.staticGroup("outside", fixedItems),
              dustTexture = Texture3d.name(dust), done = Float64.max(done, List.foldLeft((a, bp) -> Float64.max(a, bp#land + bp#timing#squash), 0.0, boardPieces)),
              landings = landings }
        })

    /// まだ出来ていないマスの下に見える低い地面（地図の外と同じ高さの草）。
    def basePlane(m: TownMap): Quad =
        let z = Int32.toFloat64(m#margin#level) * m#heightStep - 0.01;
        let (w, h) = (Int32.toFloat64(m#width), Int32.toFloat64(m#height));
        Faces.quad("grass", Faces.p3(0.0, 0.0, z) :: Faces.p3(w, 0.0, z) :: Faces.p3(w, h, z) :: Faces.p3(0.0, h, z) :: Nil,
                   (0.0, 0.0) :: (w, 0.0) :: (w, h) :: (0.0, h) :: Nil, 0.7 :: 0.7 :: 0.7 :: 0.7 :: Nil)

    // ── 動きの形 ──

    def clamp01(x: Float64): Float64 = Num.clamp(0.0, 1.0, x)

    /// 少し行き過ぎて戻る ease-out（せり上がり・ポンと出る）。
    def easeOutBack(u: Float64): Float64 =
        let c = 1.70158;
        let v = u - 1.0;
        1.0 + (c + 1.0) * v * v * v + c * v * v

    /// つぶれて伸びる量（τ = 0..1。前半は正 = つぶれる・後半は負 = 伸びる・最後に 0）。
    def squashOf(tau: Float64): Float64 = if (tau <= 0.0 or tau >= 1.0) 0.0 else Num.sin(2.0 * Num.pi() * tau) * (1.0 - tau)

    /// base を中心に (sx, sy, sz) 倍してから offset だけ動かす行列。
    def around(base: Vec3.Vec3, scale: Vec3.Vec3, offset: Vec3.Vec3): Mat4.Mat4 =
        Mat4.mul(Mat4.translate(Vec3.add(base, offset)), Mat4.mul(Mat4.scale(scale), Mat4.translate(Vec3.mul(base, -1.0))))

    /// 降って着地する物の (高さのずれ, 縦の倍率, 横の倍率)。
    def dropOf(t: Float64, start: Float64, fallSec: Float64, height: Float64, squashSec: Float64): (Float64, Float64, Float64) =
        let u = clamp01((t - start) / fallSec);
        let k = squashOf((t - start - fallSec) / squashSec);
        (height * (1.0 - u * u), 1.0 - 0.3 * k, 1.0 + 0.15 * k)

    /// 時刻 t の部品の行列（まだ出ていなければ None）。
    def pieceWorld(tm: Timing, t: Float64, p: Piece): Option[Mat4.Mat4] =
        if (t < p#start) None
        else Some(match p#owner {
            case Owner.Cell(_, _) =>
                around(p#base, Vec3.v3(1.0, 1.0, 1.0), Vec3.v3(0.0, -1.2 * (1.0 - easeOutBack(clamp01((t - p#start) / tm#rise))), 0.0))
            case Owner.Prop(_, _) =>
                let (dy, sy, sxz) = dropOf(t, p#start, tm#fall, tm#fallHeight, tm#squash);
                around(p#base, Vec3.v3(sxz, sy, sxz), Vec3.v3(0.0, dy, 0.0))
            case Owner.Monument(_, _) =>
                let (dy, sy, sxz) = dropOf(t, p#start, tm#monumentFall, tm#monumentHeight, tm#squash);
                around(p#base, Vec3.v3(sxz, sy, sxz), Vec3.v3(0.0, dy, 0.0))
            case Owner.Walls(_) =>
                let u = clamp01((t - p#start) / tm#wallRise);
                around(p#base, Vec3.v3(1.0, Float64.max(0.001, 1.0 - (1.0 - u) * (1.0 - u)), 1.0), Vec3.zero())
            case Owner.Roof(_) =>
                let (dy, sy, sxz) = dropOf(t, p#start, tm#roofFall, tm#roofHeight, tm#squash);
                around(p#base, Vec3.v3(sxz, sy, sxz), Vec3.v3(0.0, dy, 0.0))
            case Owner.Opening(_, _) =>
                let s = Float64.max(0.001, easeOutBack(clamp01((t - p#start) / tm#pop)));
                around(p#center, Vec3.v3(s, s, s), Vec3.zero())
            case Owner.Fixed => Mat4.identity()
        })

    /// 窓と扉の前の壁（壁が伸びる間は壁と同じ行列で伸び、窓が出たら消える）。
    def plainWorld(tm: Timing, show: Show, t: Float64, p: Piece): Option[Mat4.Mat4] = match p#owner {
        case Owner.Opening(id, _) =>
            let wallStart = Vector.find(q -> q#owner == Owner.Walls(id), show#pieces) |> Option.map(q -> q#start) |> Option.getWithDefault(p#start);
            if (t < wallStart or t >= p#start) None
            else {
                let u = clamp01((t - wallStart) / tm#wallRise);
                Some(around(p#base, Vec3.v3(1.0, Float64.max(0.001, 1.0 - (1.0 - u) * (1.0 - u)), 1.0), Vec3.zero()))
            }
        case _ => None
    }

    /// 部品が動き終わって、もう動かないか。
    def isSettled(tm: Timing, t: Float64, p: Piece): Bool = t >= endOf(tm, p#start, p#owner)

    /// 時刻 t の出来た物（集まりへまとめる鍵と物）と、動いている物（置いた物）。
    pub type alias Frame = { settled = List[(String, Scene3d.Instance3d)], moving = List[Scene3d.Instance3d], billboards = List[Scene3d.Billboard3d],
                             contacts = List[(Vec3.Vec3, Float64, Float64)] }

    /// 時刻 t の部品の分け方と、板の物（位置とつぶれ）と、板の足元の影（点・幅・大きさの割合）。
    pub def frameAt(show: Show, t: Float64): Frame =
        let ps = Vector.toList(show#pieces);
        let settled = ps |> List.filter(p -> isSettled(p#timing, t, p)) |> List.map(p -> (p#key, placed(Mat4.identity(), p#mesh, p#material)));
        let moving = ps |> List.filter(p -> not isSettled(p#timing, t, p)) |> List.flatMap(p ->
            List.append(pieceWorld(p#timing, t, p) |> Option.map(w -> placed(w, p#mesh, p#material)) |> Option.toList,
                        p#plain |> Option.flatMap(pl -> plainWorld(p#timing, show, t, p) |> Option.map(w -> placed(w, fst(pl), snd(pl)))) |> Option.toList));
        let boards = show#boards |> List.filter(bp -> t >= bp#start) |> List.map(bp -> {
            let tm = bp#timing;
            let (dy0, sy0, sxz) = dropOf(t, bp#start, tm#fall, tm#fallHeight, tm#squash);
            let f = Scene3d.billboardFieldsOf(bp#billboard);
            let (hop, stretch) = waveAt(show, t, f#position);
            let dy = dy0 + hop;
            let sy = sy0 * stretch;
            let shrink = clamp01((t - bp#start) / tm#fall);
            (Scene3d.billboard(f#texture, f#regionRect, Vec3.add(f#position, Vec3.v3(0.0, dy, 0.0)), { x = f#size#x * sxz, y = f#size#y * sy })
                |> Scene3d.withBillboardTint(f#tint) |> Scene3d.withCastShadows(f#castShadows) |> Scene3d.withReceiveShadows(f#receiveShadows),
             if (bp#board#shadow == TileMap3d.BoardShadow.Grounded) Some((Vec3.v3(bp#board#x, bp#board#z, bp#board#y), bp#board#width, 0.25 + 0.75 * shrink)) else None)
        });
        { settled = settled, moving = moving, billboards = List.append(boards |> List.map(fst), dustAt(show, t)),
          contacts = boards |> List.filterMap(snd) }

    /// 着地した所から広がる土ぼこり（ドット絵の丸い粒を α で切る板・光を当てない）。
    def dustAt(show: Show, t: Float64): List[Scene3d.Billboard3d] =
        let tm = show#timing;
        show#landings |> List.filter(l -> { let (_, at, _, _) = l; t >= at and t < at + tm#dust }) |> List.flatMap(l -> {
            let (p, at, big, dustScale) = l;
            let tau = (t - at) / tm#dust;
            let boost = if (big) tm#impactDust else 1.0;
            let count = Float64.round((if (big) 10.0 else 6.0) * dustScale * boost) |> Float64.tryToInt32 |> Option.getWithDefault(6);
            let reach = (if (big) 1.8 else 1.0) * Num.sqrt(boost);
            let size = (if (big) 0.6 else 0.36) * Float64.min(1.6, Num.sqrt(boost)) * (1.0 - tau) + 0.05;
            List.range(0, count) |> List.map(k -> {
                let a = 2.0 * Num.pi() * Int32.toFloat64(k) / Int32.toFloat64(count) + 0.4;
                let d = 0.25 + reach * (1.0 - (1.0 - tau) * (1.0 - tau));
                let at3 = Vec3.add(p, Vec3.v3(Num.cos(a) * d, 0.05 + 0.4 * tau, Num.sin(a) * d * 0.7));
                Scene3d.billboard(show#dustTexture, { position = Vec2.zero(), size = { x = 16.0, y = 16.0 } }, at3, { x = size, y = size })
                    |> Scene3d.unlit
            })
        })

    /// 目印が着地する時刻と所（目印が無ければ None）。
    pub def impactOf(show: Show): Option[(Float64, Vec3.Vec3)] =
        show#landings |> List.find(l -> { let (_, _, big, _) = l; big }) |> Option.map(l -> { let (p, at, _, _) = l; (at, p) })

    /// 実の時刻 real → 演出の時刻（目印の着地で hitstopSec だけ止める）。
    pub def storyTime(show: Show, real: Float64): Float64 =
        let h = show#timing#hitstopSec;
        impactOf(show) |> Option.map(ip -> {
            let at = fst(ip);
            if (real < at) real else if (real < at + h) at else real - h
        }) |> Option.getWithDefault(real)

    /// 実の時刻 real の着地の光（露出に足す段・着地から 2 コマで 0 へ）。
    pub def flashAt(show: Show, real: Float64): Float64 =
        impactOf(show) |> Option.map(ip -> {
            let u = (real - fst(ip)) * 15.0;
            if (u < 0.0 or u >= 1.0) 0.0 else show#timing#flash * (1.0 - u)
        }) |> Option.getWithDefault(0.0)

    /// 着地の衝撃で板の物が跳ねる高さと、縦の伸び（衝撃は距離 / waveSpeed 秒遅れて届き、0.3 秒で跳ねて戻る）。
    def waveAt(show: Show, t: Float64, at3: Vec3.Vec3): (Float64, Float64) =
        let tm = show#timing;
        if (tm#waveHeight <= 0.0) (0.0, 1.0)
        else impactOf(show) |> Option.map(ip -> {
            let (at, p) = ip;
            let d = Num.sqrt((at3#x - p#x) * (at3#x - p#x) + (at3#z - p#z) * (at3#z - p#z));
            let u = (t - at - d / tm#waveSpeed) / 0.3;
            if (u < 0.0 or u >= 1.0) (0.0, 1.0)
            else {
                let k = tm#waveHeight * Float64.pow(base = 2.718281828459045, 0.0 - d / 14.0);
                (k * Num.sin(Num.pi() * u), 1.0 - 0.6 * k * Num.sin(2.0 * Num.pi() * u))
            }
        }) |> Option.getWithDefault((0.0, 1.0))

    /// 時刻 t のカメラの揺れ（目印の石の柱の着地から減っていく上下の揺れ・m）。
    pub def shakeAt(show: Show, t: Float64): Float64 =
        let tm = show#timing;
        show#landings |> List.filter(l -> { let (_, _, big, _) = l; big }) |> List.foldLeft((acc, l) -> {
            let (_, at, _, _) = l;
            let tau = t - at;
            if (tau < 0.0 or tau > tm#shake) acc
            else acc + tm#shakeAmp * Float64.pow(base = 2.718281828459045, -8.0 * tau) * Num.sin(2.0 * Num.pi() * 9.0 * tau)
        }, 0.0)

    /// 土ぼこりの絵（16×16 のドット絵の丸い粒・明るい砂の色）。
    pub def dustTexture(): Result[String, Texture3d.Texture3d] =
        let side = 16;
        let argb = List.range(0, side) |> List.flatMap(y -> List.range(0, side) |> List.map(x -> {
            let u = Int32.toFloat64(x) + 0.5 - 8.0;
            let v = Int32.toFloat64(y) + 0.5 - 8.0;
            let inside = u * u + v * v < 49.0;
            let rim = u * u + v * v > 30.0;
            if (not inside) 0
            else if (rim) Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(214, 16), Int32.bitwiseOr(Int32.leftShift(196, 8), 168)))
            else Int32.bitwiseOr(Int32.leftShift(255, 24), Int32.bitwiseOr(Int32.leftShift(236, 16), Int32.bitwiseOr(Int32.leftShift(224, 8), 198)))
        })) |> List.toVector;
        Texture3d.fromArgb(side, side, argb)

    // ── 台本の Doc（assets/buildup.json） ──

    /// 歩く隊列の 1 人。strip = 背中・右・正面の 4 コマずつの帯・tint = 色の掛け目（線形）。
    /// idleStrip = 止まっている間の息遣いのコマの帯（背中・右・正面の 吸った・吐いた 2 コマずつ・左は右の反転。無ければ歩きの帯で代える）。
    pub type alias Walker = { strip = String, tint = Faces.Rgb, idleStrip = Option[String] }

    /// 歩く台本。path = 曲がり角・endFace = 止まった後の向き・map = 地図の Doc・ほかは Doc の note のとおり。
    pub type alias Plan = { path = List[Route.Waypoint], idleSec = Float64, holdSec = Float64, frameSec = Float64, groundFlowH = Float64,
                            feetV = Float64, stopSec = Float64, camZLagK = Float64, endFace = Route.Dir, party = List[Walker], timing = Timing, idle = Idle,
                            idleFrameSec = Float64, idlePhaseSec = Float64, radial = Option[Radial], map = String }

    /// 立ったまま輪で町が出来る台本の決まり。buildSec・curve・jitter = Buildup.radialFront の値・
    /// zoomFrom・zoomTo = カメラの引き（足元の点からの距離の倍率・輪の届いた距離に合わせる）・zoomLead = カメラが輪より先に引き終える割合（0.85 なら輪が 85% 届いた所で引き終える）・aimNorth = 引き終えた時にカメラの追う点を北へずらす m（奥の目印が画面に入るように）・
    /// walkPause = 揺れが収まってから歩き出すまでの秒・followSec = 歩き出してから追従カメラへ移りきる秒・walkZoom = 歩く追従カメラの引き（足元の点からの距離の倍率）・
    /// paceFrom・paceTo = 部品の動きの秒の倍率（出始めと終わり）・spread = 横に並ぶ間（m）。
    pub type alias Radial = { buildSec = Float64, curve = Float64, jitter = Float64, zoomFrom = Float64, zoomTo = Float64, zoomLead = Float64, aimNorth = Float64, walkPause = Float64, followSec = Float64, walkZoom = Float64,
                              paceFrom = Float64, paceTo = Float64, spread = Float64 }

    /// 止まっている間の動き。Breath = 息遣い（縦に少し伸び縮み）・Step = 足踏み（歩きのコマをゆっくりその場で）。
    pub enum Idle with Eq {
        case Breath
        case Step
    }

    /// path の台本を読む。
    pub def loadPlan(path: String): Result[String, Plan] \ Fs.FileRead =
        DocJson.readJson(path) |> Result.mapErr(e -> "${path}: ${DocJson.describe(e)}")
            |> Result.flatMap(json -> JsonCodec.expectObject(json) |> Option.toOk("${path} がオブジェクトでない"))
            |> Result.flatMap(planOf)

    def waypointOf(j: Json): Option[Route.Waypoint] =
        JsonCodec.decodeList(JsonCodec.expectFloat, j) |> Option.flatMap(xs -> match xs {
            case c :: r :: rest => Some({ col = Float64.round(c) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                          row = Float64.round(r) |> Float64.tryToInt32 |> Option.getWithDefault(0),
                                          wait = List.head(rest) |> Option.getWithDefault(0.0) })
            case _ => None
        })

    def rgbOf(xs: List[Float64]): Option[Faces.Rgb] = match xs {
        case r :: g :: b :: _ => Some({ r = r, g = g, b = b })
        case _                => None
    }

    def walkerOf(j: Json): Option[Walker] =
        JsonCodec.expectObject(j) |> Option.map(w -> {
            let tint = Map.get("tint", w) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectFloat)) |> Option.flatMap(rgbOf)
                |> Option.getWithDefault(Faces.white());
            { strip = JsonCodec.stringOr("strip", "", w), tint = tint,
              idleStrip = Map.get("idleStrip", w) |> Option.flatMap(JsonCodec.expectString) }
        })

    def faceOf(letter: String): Route.Dir = match letter {
        case "n" => Route.Dir.North
        case "e" => Route.Dir.East
        case "w" => Route.Dir.West
        case _   => Route.Dir.South
    }

    def planOf(m: Map[String, Json]): Result[String, Plan] =
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, m);
        let d = defaultTiming();
        forM (
            path <- Map.get("path", m) |> Option.flatMap(JsonCodec.decodeList(waypointOf)) |> Option.toOk("path が読めない");
            party <- Map.get("party", m) |> Option.flatMap(JsonCodec.decodeList(walkerOf)) |> Option.toOk("party が読めない")
        ) yield { path = path, idleSec = num("idleSec", 3.0), holdSec = num("holdSec", 5.0), frameSec = num("frameSec", 0.333),
                  groundFlowH = num("groundFlowH", 0.21), feetV = num("feetV", 0.55), stopSec = num("stopSec", 0.7),
                  camZLagK = num("camZLagK", 2.5), endFace = faceOf(JsonCodec.stringOr("endFace", "s", m)), party = party,
                  idle = idleOf(JsonCodec.stringOr("idle", "breath", m)),
                  idleFrameSec = num("idleFrameSec", 0.8), idlePhaseSec = num("idlePhaseSec", 0.27),
                  radial = Map.get("radial", m) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(radialOf),
                  map = JsonCodec.stringOr("map", "assets/town_avenue.map.json", m),
                  timing = { lead = num("lead", d#lead), afterRowsPerSec = num("afterRowsPerSec", d#afterRowsPerSec),
                             rippleSec = num("rippleSec", d#rippleSec), startDelay = num("startDelay", d#startDelay),
                             rise = num("rise", d#rise), fall = num("fall", d#fall), squash = num("squash", d#squash),
                             monumentFall = num("monumentFall", d#monumentFall), shake = num("shake", d#shake), shakeAmp = num("shakeAmp", d#shakeAmp),
                             wallRise = num("wallRise", d#wallRise), roofDelay = num("roofDelay", d#roofDelay), roofFall = num("roofFall", d#roofFall),
                             openingDelay = num("openingDelay", d#openingDelay), openingStep = num("openingStep", d#openingStep),
                             pop = num("pop", d#pop), dust = num("dust", d#dust), dustScale = num("dustScale", d#dustScale),
                             impactDust = num("impactDust", d#impactDust), hitstopSec = num("hitstopSec", d#hitstopSec), flash = num("flash", d#flash),
                             waveSpeed = num("waveSpeed", d#waveSpeed), waveHeight = num("waveHeight", d#waveHeight) | d } }

    def radialOf(m: Map[String, Json]): Radial =
        let num = (key: String, fallback: Float64) -> JsonCodec.floatOr(key, fallback, m);
        { buildSec = num("buildSec", 4.5), curve = num("curve", 0.85), jitter = num("jitter", 0.06),
          zoomFrom = num("zoomFrom", 0.6), zoomTo = num("zoomTo", 1.0), zoomLead = num("zoomLead", 0.85), aimNorth = num("aimNorth", 0.0), walkPause = num("walkPause", 0.7), followSec = num("followSec", 1.2), walkZoom = num("walkZoom", 1.0),
          paceFrom = num("paceFrom", 1.0), paceTo = num("paceTo", 1.0), spread = num("spread", 0.95) }

    def idleOf(name: String): Idle = match name {
        case "step" => Idle.Step
        case _      => Idle.Breath
    }
}
