// Decal3d.Internal.Clip — デカールの箱で的の三角形を切り、面から浮かせた多角形の頂点を作る。

/// 箱を組む・的の三角形を箱の 6 面で切る・頂点の属性を的から写す。ゲームは呼ばない。
pub mod Decal3d.Internal.Clip {

    /// デカールの箱（world の中）。right・up・forward は長さ 1 で互いに直交し、forward は貼る面から外へ向く。
    /// size は right・up・forward の向きの辺の長さ（どれも 0 より大きい）。
    pub type alias Box = { center = Vec3.Vec3, right = Vec3.Vec3, up = Vec3.Vec3, forward = Vec3.Vec3, size = Vec3.Vec3 }

    /// 切った後の 1 頂点（world の座標・長さ 1 の法線・頂点の色・1 本目の uv・2 本目の uv（lightmap の矩形を掛けた後））。
    pub type alias Vertex = { position = Vec3.Vec3, normal = Vec3.Vec3, color = Vec3.Vec3, uv = Vec2.Vec2, uv2 = Vec2.Vec2 }

    /// 切る時の決まり（箱・絵の矩形・面の向きの下限の cos・浮かせる量）。
    pub type alias ClipSettings = { box = Box, uvRect = Rect2.Rect2, minFacingCos = Float64, offset = Float64 }

    /// 辺の長さの下限（0 の辺は箱の中の座標へ戻す時に割れない）。
    def minSide(): Float64 = 1.0e-6

    /// デカールの値から切る時の決まりを作る。
    pub def settingsOf(d: Decal3d.Decal): ClipSettings =
        let box = boxOf(d#center, d#normal, d#size, d#rotation);
        let cutoff = Float64.min(180.0, Float64.max(0.0, d#angleCutoff));
        let offset = d#offset |> Option.getWithDefault(Float64.min(box#size#x, box#size#y) * 0.01);
        { box = box, uvRect = d#uvRect, minFacingCos = Num.cos(cutoff * PortableMath.pi() / 180.0), offset = offset }

    /// 点・面の向き・大きさ・回り（度・正面から見て反時計回り）から箱を組む。right・up は正面から見た画面の右・上。
    /// 面の向きが真上・真下に近い時は −Z を上の手がかりにする。
    pub def boxOf(center: Vec3.Vec3, normal: Vec3.Vec3, size: Vec3.Vec3, rotationDeg: Float64): Box =
        let n0 = Vec3.normalized(normal);
        let forward = if (Vec3.length(n0) < 0.5) Log.warnThen("@decal-zero-normal decal3d: normal の長さが 0 — 上（+Y）へ向けて貼る", Vec3.v3(0.0, 1.0, 0.0)) else n0;
        let hint = if (Float64.abs(forward#y) > 0.999) Vec3.v3(0.0, 0.0, -1.0) else Vec3.v3(0.0, 1.0, 0.0);
        // WhyNot: cross(hint, forward) で right を組まない — 左手系では right × up が見る向き（−forward）になる組み方でないと、絵が鏡に映した向きで貼られる。
        let right0 = Vec3.normalized(Vec3.cross(forward, hint));
        let up0 = Vec3.cross(right0, forward);
        let a = rotationDeg * PortableMath.pi() / 180.0;
        let (s, c) = (Num.sin(a), Num.cos(a));
        let right = Vec3.add(Vec3.mul(right0, c), Vec3.mul(up0, s));
        let up = Vec3.sub(Vec3.mul(up0, c), Vec3.mul(right0, s));
        let side = x -> Float64.max(minSide(), Float64.abs(x));
        { center = center, right = right, up = up, forward = forward, size = Vec3.v3(side(size#x), side(size#y), side(size#z)) }

    /// 箱を囲む world の AABB。
    pub def boundsOf(b: Box): Mesh3d.Bounds =
        let half = (pick: Vec3.Vec3 -> Float64) ->
            Float64.abs(pick(b#right)) * b#size#x * 0.5 + Float64.abs(pick(b#up)) * b#size#y * 0.5 + Float64.abs(pick(b#forward)) * b#size#z * 0.5;
        let h = Vec3.v3(half(v -> v#x), half(v -> v#y), half(v -> v#z));
        { min = Vec3.sub(b#center, h), max = Vec3.add(b#center, h) }

    /// 2 つの AABB が交わるか（面が触れるだけでも交わる）。
    pub def overlaps(a: Mesh3d.Bounds, b: Mesh3d.Bounds): Bool =
        a#min#x <= b#max#x and b#min#x <= a#max#x and a#min#y <= b#max#y and b#min#y <= a#max#y and a#min#z <= b#max#z and b#min#z <= a#max#z

    /// 的の形を world へ写した頂点の並び（デカールの数によらず的ごとに 1 回作る）。
    pub type alias Target = { source = Source, world = Vector[Float64] }

    /// 的の形の頂点の並び（world の行列と法線の行列は行優先の 16 個）。
    type alias Source = { p = Vector[Float64], n = Vector[Float64], c = Vector[Float64], uv2 = Option[(Rect2.Rect2, Vector[Float64])],
                          w = Vector[Float64], nm = Vector[Float64], ix = Vector[Int32] }

    /// 的の頂点を world へ写しておく。uv2 は的に使える lightmap（Scene3d.lightmapOfFields）と 2 本目の uv がある時だけ持つ。
    pub def targetOf(f: Scene3d.InstanceFields): Target =
        let m = f#mesh;
        let p = Mesh3d.positions(m);
        let lmRect = Scene3d.lightmapOfFields(f) |> Option.map(lm -> lm#uvRect);
        let uv2 = match (lmRect, Mesh3d.uvs2(m)) {
            case (Some(r), Some(u)) => Some((r, u))
            case _                  => None
        };
        let w = Mat4.asRows(f#world);
        let source = { p = p, n = Mesh3d.normals(m), c = Mesh3d.colors(m), uv2 = uv2, w = w, nm = Mat4.asRows(Mat4.normalMatrix(f#world)),
                       ix = Mesh3d.indices(m) };
        let count = Vector.length(p) / 3;
        let world = region rc {
            let out: Array[Float64, rc] = Array.empty(rc, count * 3);
            foreach (k <- Vector.range(0, count)) {
                let (px, py, pz) = (Vector.get(k * 3, p), Vector.get(k * 3 + 1, p), Vector.get(k * 3 + 2, p));
                Array.put(rowDot(w, 0, px, py, pz) + Vector.get(3, w), k * 3, out);
                Array.put(rowDot(w, 1, px, py, pz) + Vector.get(7, w), k * 3 + 1, out);
                Array.put(rowDot(w, 2, px, py, pz) + Vector.get(11, w), k * 3 + 2, out)
            };
            Array.toVector(out)
        };
        { source = source, world = world }

    /// 的 1 つを箱で切った多角形の列（三角形の並びの順・各多角形は的の三角形の巻き方のまま）。uv2 は矩形を掛けて写す（無ければ (0, 0)）。
    /// bounds は箱を囲む world の AABB（boundsOf）。
    pub def clipTarget(rule: ClipSettings, bounds: Mesh3d.Bounds, t: Target): List[List[Vertex]] =
        clipFrom(rule, bounds, t, Vector.length(t#source#ix) / 3 - 1, Nil)

    /// 三角形 tri から 0 へ向かって切り、前へ積む（積み終わった列は三角形の並びの順）。
    // WhyNot: 三角形ごとに頂点の record を作ってから箱で外さない — 箱に掛からない三角形が大半で、数のまま world の AABB を比べて先に外す方が一桁速い。
    def clipFrom(rule: ClipSettings, bounds: Mesh3d.Bounds, t: Target, tri: Int32, acc: List[List[Vertex]]): List[List[Vertex]] =
        if (tri < 0) acc
        else {
            let ix = t#source#ix;
            let (i0, i1, i2) = (Vector.get(tri * 3, ix), Vector.get(tri * 3 + 1, ix), Vector.get(tri * 3 + 2, ix));
            let next = if (not triangleTouches(bounds, t#world, i0, i1, i2)) acc
                else match clipTriangle(rule, t, i0, i1, i2) {
                    case Some(poly) => poly :: acc
                    case None       => acc
                };
            clipFrom(rule, bounds, t, tri - 1, next)
        }

    /// 三角形の world の AABB が b と交わるか。
    def triangleTouches(b: Mesh3d.Bounds, w: Vector[Float64], i0: Int32, i1: Int32, i2: Int32): Bool =
        axisTouches(w, i0, i1, i2, 0, b#min#x, b#max#x) and axisTouches(w, i0, i1, i2, 1, b#min#y, b#max#y)
            and axisTouches(w, i0, i1, i2, 2, b#min#z, b#max#z)

    def axisTouches(w: Vector[Float64], i0: Int32, i1: Int32, i2: Int32, k: Int32, lo: Float64, hi: Float64): Bool =
        let (a, c, d) = (Vector.get(i0 * 3 + k, w), Vector.get(i1 * 3 + k, w), Vector.get(i2 * 3 + k, w));
        Float64.min(a, Float64.min(c, d)) <= hi and Float64.max(a, Float64.max(c, d)) >= lo

    /// 三角形の 3 頂点の world の値。
    type alias Corner = { position = Vec3.Vec3, normal = Vec3.Vec3, color = Vec3.Vec3, uv2 = Vec2.Vec2, local = Vec3.Vec3 }

    /// 切る途中の頂点（3 頂点の重みと、箱の中の座標）。
    type alias ClipPoint = { b0 = Float64, b1 = Float64, b2 = Float64, x = Float64, y = Float64, z = Float64 }

    def clipTriangle(rule: ClipSettings, t: Target, i0: Int32, i1: Int32, i2: Int32): Option[List[Vertex]] =
        let k0 = cornerOf(rule#box, t, i0);
        let k1 = cornerOf(rule#box, t, i1);
        let k2 = cornerOf(rule#box, t, i2);
        if (not touchesUnitBox(k0#local, k1#local, k2#local)) None
        else {
            let facing = facingOf(k0, k1, k2);
            if (Vec3.length(facing) < 0.5 or Vec3.dot(facing, rule#box#forward) < rule#minFacingCos) None
            else {
                let start = { b0 = 1.0, b1 = 0.0, b2 = 0.0, x = k0#local#x, y = k0#local#y, z = k0#local#z }
                    :: { b0 = 0.0, b1 = 1.0, b2 = 0.0, x = k1#local#x, y = k1#local#y, z = k1#local#z }
                    :: { b0 = 0.0, b1 = 0.0, b2 = 1.0, x = k2#local#x, y = k2#local#y, z = k2#local#z } :: Nil;
                let cut = start
                    |> clipPlane(v -> v#x - 0.5) |> clipPlane(v -> -0.5 - v#x)
                    |> clipPlane(v -> v#y - 0.5) |> clipPlane(v -> -0.5 - v#y)
                    |> clipPlane(v -> v#z - 0.5) |> clipPlane(v -> -0.5 - v#z);
                if (List.length(cut) < 3) None
                else Some(List.map(vertexOf(rule, facing, k0, k1, k2), cut))
            }
        }

    def cornerOf(b: Box, t: Target, i: Int32): Corner =
        let s = t#source;
        let position = Vec3.v3(Vector.get(i * 3, t#world), Vector.get(i * 3 + 1, t#world), Vector.get(i * 3 + 2, t#world));
        let (nx, ny, nz) = (Vector.get(i * 3, s#n), Vector.get(i * 3 + 1, s#n), Vector.get(i * 3 + 2, s#n));
        let normal = Vec3.normalized(Vec3.v3(rowDot(s#nm, 0, nx, ny, nz), rowDot(s#nm, 1, nx, ny, nz), rowDot(s#nm, 2, nx, ny, nz)));
        let color = Vec3.v3(Vector.get(i * 3, s#c), Vector.get(i * 3 + 1, s#c), Vector.get(i * 3 + 2, s#c));
        let uv2 = s#uv2 |> Option.map(match (r, u) ->
            Vec2.v2(r#position#x + Vector.get(i * 2, u) * r#size#x, r#position#y + Vector.get(i * 2 + 1, u) * r#size#y))
            |> Option.getWithDefault(Vec2.v2(0.0, 0.0));
        let d = Vec3.sub(position, b#center);
        let local = Vec3.v3(Vec3.dot(d, b#right) / b#size#x, Vec3.dot(d, b#up) / b#size#y, Vec3.dot(d, b#forward) / b#size#z);
        { position = position, normal = normal, color = color, uv2 = uv2, local = local }

    /// 行優先の行列 m の row 行の左 3 列と (x, y, z) の内積。
    def rowDot(m: Vector[Float64], row: Int32, x: Float64, y: Float64, z: Float64): Float64 =
        Vector.get(row * 4, m) * x + Vector.get(row * 4 + 1, m) * y + Vector.get(row * 4 + 2, m) * z

    /// 3 点の囲む箱が [−0.5, 0.5]³ と交わるか。
    def touchesUnitBox(a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3): Bool =
        let within = (pick: Vec3.Vec3 -> Float64) ->
            Float64.min(pick(a), Float64.min(pick(b), pick(c))) <= 0.5 and Float64.max(pick(a), Float64.max(pick(b), pick(c))) >= -0.5;
        within(v -> v#x) and within(v -> v#y) and within(v -> v#z)

    /// 三角形の外向きの面の向き（長さ 1。面積 0 なら長さ 0）。巻き方（外から見て時計回り・cross(b − a, c − a) が外）で決め、頂点の法線の和と逆なら裏返す。
    // WhyNot: 巻き方だけで決めない — 反転した world（大きさが負）や逆巻きの glb で、表の面が全部 angleCutoff で落ちる。
    def facingOf(k0: Corner, k1: Corner, k2: Corner): Vec3.Vec3 =
        let g = Vec3.normalized(Vec3.cross(Vec3.sub(k1#position, k0#position), Vec3.sub(k2#position, k0#position)));
        let hint = Vec3.add(k0#normal, Vec3.add(k1#normal, k2#normal));
        if (Vec3.dot(g, hint) < 0.0) Vec3.mul(g, -1.0) else g

    /// Sutherland–Hodgman の 1 面（dist ≦ 0 が内側）。
    def clipPlane(dist: ClipPoint -> Float64, poly: List[ClipPoint]): List[ClipPoint] =
        match List.last(poly) {
            case None       => Nil
            case Some(last) =>
                let step = (acc, cur) -> {
                    let (prev, out) = acc;
                    let dp = dist(prev);
                    let dc = dist(cur);
                    let crossed = (dp > 0.0 and dc < 0.0) or (dp < 0.0 and dc > 0.0);
                    let withCross = if (crossed) lerpPoint(prev, cur, dp / (dp - dc)) :: out else out;
                    let next = if (dc <= 0.0) cur :: withCross else withCross;
                    (cur, next)
                };
                let (_, reversed) = List.foldLeft(step, (last, Nil), poly);
                List.reverse(reversed)
        }

    def lerpPoint(a: ClipPoint, b: ClipPoint, t: Float64): ClipPoint =
        let mix = (x, y) -> x + (y - x) * t;
        { b0 = mix(a#b0, b#b0), b1 = mix(a#b1, b#b1), b2 = mix(a#b2, b#b2), x = mix(a#x, b#x), y = mix(a#y, b#y), z = mix(a#z, b#z) }

    /// 切った点の属性を 3 頂点の重みで写し、面の向きへ offset だけ浮かせる。
    def vertexOf(rule: ClipSettings, facing: Vec3.Vec3, k0: Corner, k1: Corner, k2: Corner, v: ClipPoint): Vertex =
        let mix3 = (a: Vec3.Vec3, b: Vec3.Vec3, c: Vec3.Vec3) -> Vec3.add(Vec3.mul(a, v#b0), Vec3.add(Vec3.mul(b, v#b1), Vec3.mul(c, v#b2)));
        let position = Vec3.add(mix3(k0#position, k1#position, k2#position), Vec3.mul(facing, rule#offset));
        let n = Vec3.normalized(mix3(k0#normal, k1#normal, k2#normal));
        let normal = if (Vec3.length(n) < 0.5) facing else n;
        let r = rule#uvRect;
        let uv = Vec2.v2(r#position#x + (v#x + 0.5) * r#size#x, r#position#y + (0.5 - v#y) * r#size#y);
        let uv2 = Vec2.v2(k0#uv2#x * v#b0 + k1#uv2#x * v#b1 + k2#uv2#x * v#b2, k0#uv2#y * v#b0 + k1#uv2#y * v#b1 + k2#uv2#y * v#b2);
        { position = position, normal = normal, color = mix3(k0#color, k1#color, k2#color), uv = uv, uv2 = uv2 }
}
