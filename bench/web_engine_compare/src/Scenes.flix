// Scenes — 比べる相手のベンチの場面のデータを、同じ種の乱数から同じ並びで作る。
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
    /// animated = 物が回るか（偽なら t = 0 の向きのまま）・turn = カメラの注視点が 1 周する秒（K5）。
    pub type alias Field = {
        camera = Camera, clearColor = V3, ambient = { color = V3, intensity = Float64 }, sun = Sun,
        materials = Vector[Pbr], count = Int32, geom = Vector[Int32], material = Vector[Int32],
        position = Vector[Float64], scale = Vector[Float64], spin = Spin, groups = Option[Groups],
        animated = Bool, turn = Option[Float64], shapes = ShapeSet, pickPoints = Vector[Float64], hud = Option[Hud],
        crowd = Option[Crowd]
    }

    /// K6 の骨つきの群れ（物を置く場面の欄は空で、カメラと光だけを使う）。position は 1 体に 3 つ・yaw はラジアン・phase は clip の時刻に足す秒。
    /// blended = Walk と Run を体ごとの重みで混ぜる（偽なら Walk だけ）。
    pub type alias Crowd = { count = Int32, scale = Float64, position = Vector[Float64], yaw = Vector[Float64], phase = Vector[Float64], blended = Bool }

    /// 形の頂点の広がり（node の置き方を掛けない）。
    pub type alias Extent = { min = V3, max = V3 }

    /// K9 の HUD（座標は canvas の画素・左上が 0・y は下向き・色は sRGB の rgba）。
    /// icons = 動かない絵（左上と atlas の升の番号）・units = 名札の基の位置と揺れの位相と icon の升・labels = 名札の字。
    pub type alias Hud = {
        panels = List[Panel], icons = { x = Vector[Float64], y = Vector[Float64], cell = Vector[Int32] },
        units = { count = Int32, baseX = Vector[Float64], baseY = Vector[Float64], phase = Vector[Float64], cell = Vector[Int32] },
        labels = Vector[String]
    }

    pub type alias Panel = { x = Float64, y = Float64, w = Float64, h = Float64, color = (Float64, Float64, Float64, Float64) }

    /// 時刻 t の名札（x, y = 字の上の真ん中・health = 0..1）。
    pub type alias Nameplate = { x = Float64, y = Float64, health = Float64 }

    /// 物の形の組。Field = Geometry.fieldShapes の 8 つ・BigSphere = 三角形 1M の球 1 つ（K8 の 1M 三角形の pick）。
    pub enum ShapeSet with Eq {
        case Field
        case BigSphere
    }

    pub def shapesOf(set: ShapeSet): Vector[Geometry.Shape] = match set {
        case ShapeSet.Field     => Geometry.fieldShapes()
        case ShapeSet.BigSphere => Vector#{Geometry.sphere(0.5, 1024, 512)}
    }

    /// 測る場面。
    pub enum Scenario with Eq, ToString {
        case K1
        case K2
        case K3
        case K5
        case K6
        case K7
        case K8
        case K9
    }

    pub def scenarioOf(name: String): Option[Scenario] = match name {
        case "k1" => Some(Scenario.K1)
        case "k2" => Some(Scenario.K2)
        case "k3" => Some(Scenario.K3)
        case "k5" => Some(Scenario.K5)
        case "k6" => Some(Scenario.K6)
        case "k7" => Some(Scenario.K7)
        case "k8" => Some(Scenario.K8)
        case "k9" => Some(Scenario.K9)
        case _    => None
    }

    /// 場面と段（K2 は物の数）から場面を作る。K6 は狐の広がりが要るので crowdField で作る（ここでは空の群れ）。
    pub def build(scenario: Scenario, level: Int32): Field = match scenario {
        case Scenario.K6 => crowdField(level, true, { min = (0.0, 0.0, 0.0), max = (1.0, 1.0, 1.0) })
        case Scenario.K1 => startup()
        case Scenario.K2 => hierarchyField(level)
        case Scenario.K3 => frustumField(3, level, palette(2300, 8, 1.0))
        case Scenario.K5 => worldField(level)
        case Scenario.K7 => frustumField(7, level, palette(2700, 16, 0.5))
        case Scenario.K8 => pickField(level)
        case Scenario.K9 => hudField(level)
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

    def ceilInt(x: Float64): Int32 = 0 - Num.floorInt(0.0 - x)

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
    def palette(seed: Int32, n: Int32, opacity: Float64): Vector[Pbr] =
        Vector.range(0, n) |> Vector.map(i -> {
            let k = i * 5;
            { color = hsvToLinear(Rng.at(seed, k), Rng.rangeAt(seed, k + 1, { min = 0.4, max = 0.9 }), Rng.rangeAt(seed, k + 2, { min = 0.5, max = 0.95 })),
              roughness = Rng.rangeAt(seed, k + 3, { min = 0.2, max = 0.9 }),
              metalness = if (Rng.at(seed, k + 4) < 0.3) 0.6 else 0.0,
              opacity = opacity }
        })

    /// 視錐台に count 個の物を散らした場面（材質は materials から 1 つずつ選ぶ）。
    def frustumField(seed: Int32, count: Int32, materials: Vector[Pbr]): Field = frustumFieldPicking(seed, count, materials, true)

    /// pickMaterial が偽なら材質を引かず、全部を材質 0 にする（乱数の列も 1 つに 2 つだけ引く）。
    def frustumFieldPicking(seed: Int32, count: Int32, materials: Vector[Pbr], pickMaterial: Bool): Field =
        let s = coverageScale(count);
        let shapeCount = 8;
        let draws = if (pickMaterial) 3 else 2;
        { camera = fieldCamera(), clearColor = clear(), ambient = ambient(), sun = sun(),
          materials = materials, count = count,
          geom = Vector.range(0, count) |> Vector.map(i -> Rng.intAt(seed, i * draws, shapeCount)),
          material = Vector.range(0, count) |> Vector.map(i -> if (pickMaterial) Rng.intAt(seed, i * draws + 1, Vector.length(materials)) else 0),
          scale = Vector.range(0, count) |> Vector.map(i -> s * Rng.rangeAt(seed, i * draws + draws - 1, { min = 0.8, max = 1.2 })),
          position = scatterInFrustum(seed, count * draws, fieldCamera(), count, { near = 25.0, far = 55.0, margin = s }),
          spin = spinner(seed, count * draws + count * 3, count),
          groups = None, animated = true, turn = None, shapes = ShapeSet.Field, pickPoints = Vector.empty(), hud = None, crowd = None }

    /// K1: 光の当たる箱 1 つ。
    def startup(): Field =
        { camera = { position = (0.0, 1.2, 3.0), target = (0.0, 0.0, 0.0), fovY = 50.0, near = 0.1, far = 100.0 },
          clearColor = clear(), ambient = ambient(), sun = sun(),
          materials = Vector#{{ color = (0.8, 0.3, 0.1), roughness = 0.4, metalness = 0.0, opacity = 1.0 }},
          count = 1, geom = Vector#{0}, material = Vector#{0}, position = Vector#{0.0, 0.0, 0.0}, scale = Vector#{1.0},
          spin = spinner(1, 0, 1), groups = None, animated = true, turn = None, shapes = ShapeSet.Field, pickPoints = Vector.empty(), hud = None, crowd = None }

    /// K3 で 1 コマに作り直す物の数。
    pub def churnPerFrame(): Int32 = 20

    /// K3 の絵の一辺（画素）。
    pub def churnTextureSize(): Int32 = 128

    /// K3 のコマ frame が作り直す組の番号（組 b は物 b × 20 .. b × 20 + 19）。
    pub def churnBatchOf(f: Field, frame: Int32): Int32 = Int32.remainder(frame, f#count / churnPerFrame())

    /// K3: コマ frame（1 以上）の作り直しをした後の場面。組の 20 個の位置・形・材質・大きさを種 300000 + frame の乱数で引き直す
    /// （位置に 60 個、続けて 1 個につき形・材質・大きさの 3 個）。回り方はそのまま。
    pub def churnAt(frame: Int32, f: Field): Field =
        let seed = 300000 + frame;
        let per = churnPerFrame();
        let s = coverageScale(f#count);
        let first = churnBatchOf(f, frame) * per;
        let fresh = scatterInFrustum(seed, 0, fieldCamera(), per, { near = 25.0, far = 55.0, margin = s });
        let inBatch = i -> i >= first and i < first + per;
        let at = (i, j) -> per * 3 + (i - first) * 3 + j;
        { geom = f#geom |> Vector.mapWithIndex((i, g) -> if (inBatch(i)) Rng.intAt(seed, at(i, 0), 8) else g),
          material = f#material |> Vector.mapWithIndex((i, m) -> if (inBatch(i)) Rng.intAt(seed, at(i, 1), Vector.length(f#materials)) else m),
          scale = f#scale |> Vector.mapWithIndex((i, x) -> if (inBatch(i)) s * Rng.rangeAt(seed, at(i, 2), { min = 0.8, max = 1.2 }) else x),
          position = f#position |> Vector.mapWithIndex((j, p) -> if (inBatch(j / 3)) Vector.get(j - first * 3, fresh) else p) | f }

    /// K3: コマ frame の絵（ARGB・行優先・一辺 churnTextureSize）。市松の升の一辺は 8・16・32 をコマごとに回す。
    pub def churnPixels(frame: Int32): Vector[Int32] =
        let size = churnTextureSize();
        let a = Int32.bitwiseAnd(frame * 37, 255);
        let b = Int32.bitwiseAnd(frame * 91, 255);
        let cell = Int32.leftShift(8, Int32.remainder(frame, 3));
        Vector.range(0, size * size) |> Vector.map(p -> {
            let on = Int32.bitwiseAnd(Int32.bitwiseXor(Int32.remainder(p, size) / cell, p / size / cell), 1) == 1;
            let (r, g, bl) = if (on) (255, b, a) else (a, 255, b);
            Int32.leftShift(255, 24) |> Int32.bitwiseOr(Int32.leftShift(r, 16)) |> Int32.bitwiseOr(Int32.leftShift(g, 8)) |> Int32.bitwiseOr(bl)
        })

    /// K3: 種の場面からコマ 1..frame の作り直しを順に済ませた場面。
    pub def churnedUpTo(frame: Int32, f: Field): Field =
        List.range(1, frame + 1) |> List.foldLeft((acc, k) -> churnAt(k, acc), f)

    /// K5 のカメラの注視点が 1 周する秒。
    def turnSeconds(): Float64 = 10.0 * Num.pi()

    /// K5: 見えるより広い動かない世界（密度は同じなので、見える物は世界の大きさによらず約 2,000）。カメラは位置を変えず向きだけ 1 周する。
    def worldField(count: Int32): Field =
        let seed = 5;
        let materials = palette(2500, 8, 1.0);
        let side = Num.sqrt(i2f(count) / 0.8);
        let at = (i, j) -> i * 6 + j;
        { camera = { position = (0.0, 6.0, 0.0), target = (10.0, 4.0, 0.0), fovY = 50.0, near = 0.5, far = 60.0 },
          clearColor = clear(), ambient = ambient(), sun = sun(), materials = materials, count = count,
          geom = Vector.range(0, count) |> Vector.map(i -> Rng.intAt(seed, at(i, 0), 8)),
          material = Vector.range(0, count) |> Vector.map(i -> Rng.intAt(seed, at(i, 1), Vector.length(materials))),
          scale = Vector.range(0, count) |> Vector.map(i -> Rng.rangeAt(seed, at(i, 2), { min = 0.6, max = 1.4 })),
          position = Vector.range(0, count) |> Vector.flatMap(i -> Vector#{
              Rng.rangeAt(seed, at(i, 3), { min = 0.0 - side / 2.0, max = side / 2.0 }),
              Rng.rangeAt(seed, at(i, 4), { min = 0.5, max = 3.0 }),
              Rng.rangeAt(seed, at(i, 5), { min = 0.0 - side / 2.0, max = side / 2.0 })}),
          spin = spinner(seed, count * 6, count), groups = None, animated = false, turn = Some(turnSeconds()), shapes = ShapeSet.Field, pickPoints = Vector.empty(), hud = None, crowd = None }

    /// 時刻 t のカメラ（turn があれば注視点が y = 4 の半径 10 の輪を回る）。
    pub def cameraAt(f: Field, t: Float64): Camera = match f#turn {
        case Some(seconds) =>
            let a = t / seconds * 2.0 * Num.pi();
            { target = (10.0 * Num.cos(a), 4.0, 10.0 * Num.sin(a)) | f#camera }
        case None => f#camera
    }

    /// 物の向きを決める時刻（動かない場面は 0）。
    def spinTime(f: Field, t: Float64): Float64 = if (f#animated) t else 0.0

    /// K8: pick の 64 点（canvas の画素・左上が 0）と、1 万の物（level 1 なら半径 15 m の 1M 三角形の球 1 つ）。物は動かない。
    def pickField(level: Int32): Field =
        let seed = 8;
        let points = Vector.range(0, 64) |> Vector.flatMap(i -> {
            let k = i * 2;
            if (level == 1) {
                let a = Rng.rangeAt(seed, k, { min = 0.0, max = Num.tau() });
                let rad = 380.0 * Num.sqrt(Rng.at(seed, k + 1));
                Vector#{roundHalfUp(width() / 2.0 + rad * Num.cos(a)), roundHalfUp(height() / 2.0 + rad * Num.sin(a))}
            } else Vector#{roundHalfUp(Rng.rangeAt(seed, k, { min = 100.0, max = width() - 100.0 })), roundHalfUp(Rng.rangeAt(seed, k + 1, { min = 100.0, max = height() - 100.0 }))}
        });
        let grey = Vector#{{ color = (0.72, 0.72, 0.72), roughness = 0.5, metalness = 0.0, opacity = 1.0 }};
        let base = if (level == 1)
            { camera = fieldCamera(), materials = grey, scale = Vector#{30.0}, spin = { axis = Vector#{0.0, 0.0, 0.0}, speed = Vector#{0.0}, phase = Vector#{0.0} }, shapes = ShapeSet.BigSphere | startup() }
            else frustumFieldPicking(seed, level, grey, false);
        { animated = false, pickPoints = points | base }

    /// K6: 狐 count 体を格子に並べた群れ。extent = 狐の形の頂点の広がり（高さを 1.6 m にそろえる）。
    pub def crowdField(count: Int32, blended: Bool, extent: Extent): Field =
        let seed = 8;
        let ((x0, y0, z0), (x1, y1, z1)) = (extent#min, extent#max);
        let scale = 1.6 / (y1 - y0);
        let spacing = Float64.max(1.4, Float64.max(x1 - x0, z1 - z0) * scale * 1.1);
        let cols = ceilInt(Num.sqrt(i2f(count) * 1.6));
        let rows = ceilInt(i2f(count) / i2f(cols));
        let dist = Float64.max(i2f(cols) * spacing / aspect(), i2f(rows) * spacing) * 0.95 + 4.0;
        let base = startup();
        { camera = { position = (0.0, dist * 0.55, dist * 0.8), target = (0.0, 0.5, 0.0), fovY = 50.0, near = 0.1, far = dist * 4.0 },
          count = 0, geom = Vector.empty(), material = Vector.empty(), position = Vector.empty(), scale = Vector.empty(),
          crowd = Some({ count = count, scale = scale, blended = blended,
                         position = Vector.range(0, count) |> Vector.flatMap(i -> Vector#{
                             (i2f(Int32.remainder(i, cols)) - i2f(cols - 1) / 2.0) * spacing, 0.0, (i2f(i / cols) - i2f(rows - 1) / 2.0) * spacing}),
                         yaw = Vector.range(0, count) |> Vector.map(i -> Rng.rangeAt(seed, i * 2, { min = -0.6, max = 0.6 })),
                         phase = Vector.range(0, count) |> Vector.map(i -> Rng.rangeAt(seed, i * 2 + 1, { min = 0.0, max = 3.0 })) }) | base }

    /// K6: 時刻 t の体 i の Run の重み（Walk は 1 − 重み）。
    pub def runWeightAt(c: Crowd, t: Float64, i: Int32): Float64 = 0.5 + 0.5 * Num.sin(t * 0.5 + Vector.get(i, c#phase) * 2.0)

    /// K9: 回る 1,000 個の上の HUD（units = 名札の数・0 なら HUD なし）。
    def hudField(units: Int32): Field =
        let base = frustumField(9, 1000, palette(2900, 4, 1.0));
        if (units == 0) base
        else {
            let seed = 99;
            let iconCount = 50;
            let at = (i, j) -> iconCount + i * 4 + j;
            let dark = (0.05, 0.07, 0.1, 0.7);
            { hud = Some({
                panels = { x = 0.0, y = 0.0, w = width(), h = 48.0, color = dark } :: { x = 16.0, y = 860.0, w = 420.0, h = 204.0, color = dark } ::
                         { x = 1484.0, y = 860.0, w = 420.0, h = 204.0, color = dark } :: { x = 1680.0, y = 64.0, w = 224.0, h = 224.0, color = (0.1, 0.2, 0.15, 0.6) } :: Nil,
                icons = { x = Vector.range(0, iconCount) |> Vector.map(i -> if (i < 20) i2f(16 + i * 40) else i2f(28 + Int32.remainder(i - 20, 10) * 40)),
                          y = Vector.range(0, iconCount) |> Vector.map(i -> if (i < 20) 8.0 else i2f(872 + (i - 20) / 10 * 40)),
                          cell = Vector.range(0, iconCount) |> Vector.map(i -> Rng.intAt(seed, i, 64)) },
                units = { count = units,
                          baseX = Vector.range(0, units) |> Vector.map(i -> Rng.rangeAt(seed, at(i, 0), { min = 60.0, max = width() - 60.0 })),
                          baseY = Vector.range(0, units) |> Vector.map(i -> Rng.rangeAt(seed, at(i, 1), { min = 80.0, max = 820.0 })),
                          phase = Vector.range(0, units) |> Vector.map(i -> Rng.rangeAt(seed, at(i, 2), { min = 0.0, max = Num.tau() })),
                          cell = Vector.range(0, units) |> Vector.map(i -> Rng.intAt(seed, at(i, 3), 64)) },
                labels = Vector.range(0, units) |> Vector.map(i -> "Unit ${i}") }) | base }
        }

    /// 時刻 t の名札 i。
    pub def nameplateAt(h: Hud, t: Float64, i: Int32): Nameplate =
        let ph = Vector.get(i, h#units#phase);
        { x = Vector.get(i, h#units#baseX) + 20.0 * Num.sin(t * 1.3 + ph),
          y = Vector.get(i, h#units#baseY) + 12.0 * Num.cos(t * 0.9 + ph),
          health = 0.5 + 0.5 * Num.sin(t * 0.7 + ph * 3.0) }

    /// 毎コマ変わる字の数。
    pub def dynamicTextCount(): Int32 = 30

    /// 時刻 t の毎コマ変わる字 i（左上の位置と字）。
    pub def dynamicTextAt(t: Float64, i: Int32): (Float64, Float64, String) =
        let words = Vector#{"DMG", "HEAL", "CRIT", "XP", "GOLD"};
        let f = Int32.toInt64(Num.roundInt(t * 60.0));
        let n = Int64.remainder(f * Int32.toInt64(i + 7) * 13i64, 100000i64);
        (i2f(1496 + Int32.remainder(i, 3) * 136), i2f(872 + i / 3 * 19), "${Vector.get(Int32.remainder(i, 5), words)} ${n}")

    /// JS の Math.round と同じ丸め（.5 は大きい方へ）。
    def roundHalfUp(x: Float64): Float64 = Float64.floor(x + 0.5)

    /// 1 つの親に入る子の数（K2）。
    def groupSize(): Int32 = 8

    /// K2: 8 個ずつの親の 2 段。子も親も回る。
    def hierarchyField(count: Int32): Field =
        let base = frustumField(2, count, palette(2100, 16, 1.0));
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
        let (x, y, z, w) = quatAt(f#spin, spinTime(f, t), i);
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
