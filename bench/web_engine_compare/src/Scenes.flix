// Scenes — 比べる相手のベンチの場面のデータを、同じ種の乱数から同じ並びで作る（K1・K2）。
// 値は比べる相手と同じ右手系・Y が上・m・色は線形。時刻 t の動く値は t だけから出す（前のコマを足し上げない）。
mod Scenes {
    use fge::Num

    pub type alias V3 = (Float64, Float64, Float64)

    /// 材質（color は線形・opacity は 1 未満で半透明）。
    pub type alias Pbr = { color = V3, roughness = Float64, metalness = Float64, opacity = Float64 }

    /// カメラ（fovY は度）。
    pub type alias Camera = { position = V3, target = V3, fovY = Float64, near = Float64, far = Float64 }

    /// 太陽（direction は光が進む向き・長さ 1）。
    pub type alias Sun = { direction = V3, color = V3, intensity = Float64 }

    /// 物ごとの回り方（axis は物ごとに 3 つ・speed と phase は 1 つ）。
    pub type alias Spin = { axis = Vector[Float64], speed = Vector[Float64], phase = Vector[Float64] }

    /// 2 段の親子の親（K2）。物の position・scale・回り方は親の中の値。親は子の timeScale 倍の速さで回る。
    pub type alias Groups = { count = Int32, parent = Vector[Int32], position = Vector[Float64], spin = Spin, timeScale = Float64 }

    /// 物をたくさん置く場面。geom は Geometry.fieldShapes の番号・material は materials の番号・position は物ごとに 3 つ。
    pub type alias Field = {
        camera = Camera, clearColor = V3, ambient = { color = V3, intensity = Float64 }, sun = Sun,
        materials = Vector[Pbr], count = Int32, geom = Vector[Int32], material = Vector[Int32],
        position = Vector[Float64], scale = Vector[Float64], spin = Spin, groups = Option[Groups]
    }

    /// 測る場面。
    pub enum Scenario with Eq, ToString {
        case K1
        case K2
    }

    pub def scenarioOf(name: String): Option[Scenario] = match name {
        case "k1" => Some(Scenario.K1)
        case "k2" => Some(Scenario.K2)
        case _    => None
    }

    /// 場面と段（K2 は物の数）から場面を作る。
    pub def build(scenario: Scenario, level: Int32): Field = match scenario {
        case Scenario.K1 => startup()
        case Scenario.K2 => hierarchyField(level)
    }

    pub def width(): Float64 = 1920.0
    pub def height(): Float64 = 1080.0
    def aspect(): Float64 = width() / height()

    def clear(): V3 = (0.02, 0.02, 0.025)
    def ambient(): { color = V3, intensity = Float64 } = { color = (0.6, 0.65, 0.75), intensity = 0.3 }

    def normalized(v: V3): V3 =
        let (x, y, z) = v;
        let l = Num.sqrt(x * x + y * y + z * z);
        (x / l, y / l, z / l)

    def sun(): Sun = { direction = normalized((-0.4, -1.0, -0.3)), color = (1.0, 0.97, 0.92), intensity = 2.2 }

    def fieldCamera(): Camera = { position = (0.0, 0.0, 40.0), target = (0.0, 0.0, 0.0), fovY = 50.0, near = 0.5, far = 200.0 }

    def i2f(i: Int32): Float64 = Int32.toFloat64(i)

    /// HSV（sRGB の値）を線形の色へ。
    pub def hsvToLinear(h: Float64, s: Float64, v: Float64): V3 =
        let f = n -> {
            let x = n + h * 6.0;
            let k = x - 6.0 * Float64.floor(x / 6.0);
            v - v * s * Float64.max(0.0, Float64.min(Float64.min(k, 4.0 - k), 1.0))
        };
        let lin = c -> if (c <= 0.04045) c / 12.92 else Float64.pow(base = (c + 0.055) / 1.055, 2.4);
        (lin(f(5.0)), lin(f(3.0)), lin(f(1.0)))

    /// 種 seed の列の first 番目から、count 個の回り方を作る（1 つに 5 つ引く）。
    def spinner(seed: Int32, first: Int32, count: Int32): Spin =
        let at = (i, j) -> first + i * 5 + j;
        let axes = Vector.range(0, count) |> Vector.map(i -> Rng.unitAt(seed, at(i, 0)));
        { axis = axes |> Vector.flatMap(a -> { let (x, y, z) = a; Vector#{x, y, z} }),
          speed = Vector.range(0, count) |> Vector.map(i ->
              Rng.rangeAt(seed, at(i, 2), { min = 0.3, max = 1.5 }) * (if (Rng.at(seed, at(i, 3)) < 0.5) -1.0 else 1.0)),
          phase = Vector.range(0, count) |> Vector.map(i -> Rng.rangeAt(seed, at(i, 4), { min = 0.0, max = Num.tau() })) }

    /// 時刻 t の物 i の向き（x, y, z, w の四元数）。
    pub def quatAt(spin: Spin, t: Float64, i: Int32): (Float64, Float64, Float64, Float64) =
        let half = (Vector.get(i, spin#phase) + Vector.get(i, spin#speed) * t) * 0.5;
        let s = Num.sin(half);
        (Vector.get(i * 3, spin#axis) * s, Vector.get(i * 3 + 1, spin#axis) * s, Vector.get(i * 3 + 2, spin#axis) * s, Num.cos(half))

    /// 種 seed の列の first 番目から、カメラの視錐台の near..far の間に count 個の点を散らす（1 つに 3 つ引く）。
    def scatterInFrustum(seed: Int32, first: Int32, cam: Camera, count: Int32, depth: { near = Float64, far = Float64, margin = Float64 }): Vector[Float64] =
        let half = cam#fovY * Num.pi() / 360.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let (_, _, cz) = cam#position;
        Vector.range(0, count) |> Vector.flatMap(i -> {
            let k = first + i * 3;
            let d = Rng.rangeAt(seed, k, { min = depth#near, max = depth#far });
            let halfH = Float64.max(0.0, d * tanHalf - depth#margin);
            let halfW = Float64.max(0.0, d * tanHalf * aspect() - depth#margin);
            Vector#{Rng.rangeAt(seed, k + 1, { min = 0.0 - halfW, max = halfW }), Rng.rangeAt(seed, k + 2, { min = 0.0 - halfH, max = halfH }), cz - d}
        })

    /// 物の数が増えても画面を覆う量がおよそ同じになる大きさ。
    def coverageScale(n: Int32): Float64 = Float64.min(2.0, Float64.max(0.2, Num.sqrt(3000.0 / i2f(n))))

    /// 種 seed の列から n 個の材質（1 つに 5 つ引く）。
    def palette(seed: Int32, n: Int32): Vector[Pbr] =
        Vector.range(0, n) |> Vector.map(i -> {
            let k = i * 5;
            { color = hsvToLinear(Rng.at(seed, k), Rng.rangeAt(seed, k + 1, { min = 0.4, max = 0.9 }), Rng.rangeAt(seed, k + 2, { min = 0.5, max = 0.95 })),
              roughness = Rng.rangeAt(seed, k + 3, { min = 0.2, max = 0.9 }),
              metalness = if (Rng.at(seed, k + 4) < 0.3) 0.6 else 0.0,
              opacity = 1.0 }
        })

    /// 視錐台に count 個の物を散らした場面（材質は materials から 1 つずつ選ぶ）。
    def frustumField(seed: Int32, count: Int32, materials: Vector[Pbr]): Field =
        let s = coverageScale(count);
        let shapeCount = 8;
        { camera = fieldCamera(), clearColor = clear(), ambient = ambient(), sun = sun(),
          materials = materials, count = count,
          geom = Vector.range(0, count) |> Vector.map(i -> Rng.intAt(seed, i * 3, shapeCount)),
          material = Vector.range(0, count) |> Vector.map(i -> Rng.intAt(seed, i * 3 + 1, Vector.length(materials))),
          scale = Vector.range(0, count) |> Vector.map(i -> s * Rng.rangeAt(seed, i * 3 + 2, { min = 0.8, max = 1.2 })),
          position = scatterInFrustum(seed, count * 3, fieldCamera(), count, { near = 25.0, far = 55.0, margin = s }),
          spin = spinner(seed, count * 6, count),
          groups = None }

    /// K1: 光の当たる箱 1 つ。
    def startup(): Field =
        { camera = { position = (0.0, 1.2, 3.0), target = (0.0, 0.0, 0.0), fovY = 50.0, near = 0.1, far = 100.0 },
          clearColor = clear(), ambient = ambient(), sun = sun(),
          materials = Vector#{{ color = (0.8, 0.3, 0.1), roughness = 0.4, metalness = 0.0, opacity = 1.0 }},
          count = 1, geom = Vector#{0}, material = Vector#{0}, position = Vector#{0.0, 0.0, 0.0}, scale = Vector#{1.0},
          spin = spinner(1, 0, 1), groups = None }

    /// 1 つの親に入る子の数（K2）。
    def groupSize(): Int32 = 8

    /// K2: 8 個ずつの親の 2 段。子も親も回る。
    def hierarchyField(count: Int32): Field =
        let base = frustumField(2, count, palette(2100, 16));
        let seed = 22;
        let s = coverageScale(count);
        let groups = (count + groupSize() - 1) / groupSize();
        let local = Vector.range(0, count) |> Vector.flatMap(i -> {
            let (x, y, z) = Rng.unitAt(seed, i * 3);
            let rad = Rng.rangeAt(seed, i * 3 + 2, { min = 0.8, max = 2.2 }) * s;
            Vector#{x * rad, y * rad, z * rad}
        });
        { position = local,
          groups = Some({ count = groups, parent = Vector.range(0, count) |> Vector.map(i -> i / groupSize()),
                          position = scatterInFrustum(seed, count * 3, fieldCamera(), groups, { near = 25.0, far = 55.0, margin = s * 3.0 }),
                          spin = spinner(seed, count * 3 + groups * 3, groups), timeScale = 0.5 }) | base }

    /// 物 i の world の行列（列優先の 16 個・右手系）。親があれば親の回転と位置を重ねる。
    pub def worldColumns(f: Field, t: Float64, i: Int32): Vector[Float64] = columnsOf(false, f, t, i)

    /// worldColumns を Z の裏返しで左手系へ写した物（S × m × S）。
    pub def mirroredWorldColumns(f: Field, t: Float64, i: Int32): Vector[Float64] = columnsOf(true, f, t, i)

    /// 物 i の world の行列を 1 つの Vector に詰める。親の無い場面は回転なし・位置 0 の親として同じ式を通す。
    def columnsOf(mirror: Bool, f: Field, t: Float64, i: Int32): Vector[Float64] =
        let (x, y, z, w) = quatAt(f#spin, t, i);
        let sc = Vector.get(i, f#scale);
        let (x2, y2, z2) = (x + x, y + y, z + z);
        let (xx, xy, xz, yy, yz, zz) = (x * x2, x * y2, x * z2, y * y2, y * z2, z * z2);
        let (wx, wy, wz) = (w * x2, w * y2, w * z2);
        let parent = f#groups |> Option.map(g -> { let p = Vector.get(i, g#parent); (quatAt(g#spin, t * g#timeScale, p), (Vector.get(p * 3, g#position), Vector.get(p * 3 + 1, g#position), Vector.get(p * 3 + 2, g#position))) })
            |> Option.getWithDefault(((0.0, 0.0, 0.0, 1.0), (0.0, 0.0, 0.0)));
        let (q, (gx, gy, gz)) = parent;
        let (ax, ay, az) = rotateBy(q, ((1.0 - (yy + zz)) * sc, (xy + wz) * sc, (xz - wy) * sc));
        let (bx, by, bz) = rotateBy(q, ((xy - wz) * sc, (1.0 - (xx + zz)) * sc, (yz + wx) * sc));
        let (cx, cy, cz) = rotateBy(q, ((xz + wy) * sc, (yz - wx) * sc, (1.0 - (xx + yy)) * sc));
        let (tx, ty, tz) = rotateBy(q, (Vector.get(i * 3, f#position), Vector.get(i * 3 + 1, f#position), Vector.get(i * 3 + 2, f#position)));
        let k = if (mirror) -1.0 else 1.0;
        Vector#{ax, ay, az * k, 0.0, bx, by, bz * k, 0.0, cx * k, cy * k, cz, 0.0, tx + gx, ty + gy, (tz + gz) * k, 1.0}

    /// 向き v を四元数 q で回す。
    def rotateBy(q: (Float64, Float64, Float64, Float64), v: V3): V3 =
        let (x, y, z, w) = q;
        let (vx, vy, vz) = v;
        let (tx, ty, tz) = (2.0 * (y * vz - z * vy), 2.0 * (z * vx - x * vz), 2.0 * (x * vy - y * vx));
        (vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx))

    /// 場面の物全部の三角形の数（全部が見える場面で、描いた三角形と比べる）。
    pub def triangleCount(f: Field, shapes: Vector[Geometry.Shape]): Int32 =
        f#geom |> Vector.foldLeft((acc, g) -> acc + Geometry.triangleCount(Vector.get(g, shapes)), 0)
}
