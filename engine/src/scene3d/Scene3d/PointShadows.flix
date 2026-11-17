// Scene3d.PointShadows — 3D の場面（Scene3d）の部品。点光源の影の約束（影を落とす灯りの選び・atlas の並び・面の写し）。座標の約束は scene3d/Scene3d.flix の頭。

/// 点光源の影（Scene3d.withPointShadows）を描き手（GL・WebGPU・CPU）が同じ式で描くための材料。ゲームは呼ばない。
pub mod Scene3d.PointShadows {

    /// 影を落とす点光源 1 本の材料。pointIndex = pickLights の後の点光源の並びの番号・slot = atlas の塊の番号（0 から）・
    /// near と far = 面の目の奥行きの範囲（shadowCamera と同じ式: far = max(2, range)・near = min(1, far / 100)）・
    /// strength = 影の濃さ（設定の strength × 境の重み。atlasOf の doc）・faces = 面 0〜5 の world → 光の clip の行列（faceMatrixOf）・
    /// frustums = 面ごとの影を落とす物の間引き。
    pub type alias ShadowedPointLight = { pointIndex = Int32, slot = Int32, position = Vec3.Vec3, range = Float64, near = Float64, far = Float64,
                                          strength = Float64, faces = Vector[Mat4.Mat4], frustums = Vector[Frustum.Frustum] }

    /// 点光源の影の atlas 1 枚の材料。tileSize = 面 1 つの一辺の画素（縮めた後）・blocksPerRow = 塊（灯り 1 本の 6 面を 3 × 2 に並べた物）の横の数・
    /// width と height = atlas の画素・pcfRadius = 周りを平均する幅（縮めた後）・bias = 設定の値（0 未満は 0）・normalBias = 設定の normalBias（0 未満は 0）× (pcfRadius + 1)（受ける点をずらす幅を面の画素で数えた物）・
    /// guardScale = 面の射影の倍率 s = (tileSize − 2 (pcfRadius + 1)) / tileSize・lights = 影を落とす灯り（slot の順）・
    /// requestedSize = 設定の mapSize（tileSize が小さければ縮めた。描き手が 1 回知らせる）。
    pub type alias Atlas = { tileSize = Int32, blocksPerRow = Int32, width = Int32, height = Int32, pcfRadius = Int32,
                                        bias = Float64, normalBias = Float64, guardScale = Float64, lights = List[ShadowedPointLight],
                                        requestedSize = Int32 }

    /// 点光源の影の約束（GL・WebGPU・CPU で同じ）。scene は pickLights の後の場面。
    ///   None: pointShadows が None・maxShadowedLights か mapSize が 0 以下・Output.Depth・置いた物が無い。Some なら影を落とす灯りが 0 本でも Some（lights = Nil）。
    ///   選び: pointPickScoreOf が Some の点光源を点数の小さい順（画面の真ん中に近い順）に min(maxShadowedLights, Scene3d.maxShadowedPointLights()) 本。slot は選んだ順。
    ///   境の重み: 候補が本数より多く本数が 2 以上なら、最後の 1 本の strength に clamp01((次の候補の点数 − 点数) / (次の候補の点数 − 1 つ前の点数)) を掛ける
    ///     （1 つ前と入れ替わる時は 1・次の候補と入れ替わる時は 0。影がぱっと出たり消えたりしない）。
    ///   atlas: 塊の横の数 = 本数が 1 なら 1・ほかは 2。width = 3 S × 横・height = 2 S × ceil(本数 / 横)（本数は設定の上限で決め、今のコマの本数で変えない）。
    ///     S = max(16, mapSize) を width・height が Scene3d.maxShadowMapSize() に収まるまで縮めた物。pcfRadius は 0..Scene3d.maxShadowPcfRadius() と S / 4 − 2 以下に縮める。
    ///   面 f の画素の原点（行 0 が ndc.y = −1 の数え方）= tileOriginOf。面の行列と受ける点の写しは faceMatrixOf・sampleOf。
    ///   受ける点の光の量に 1 − strength × (1 − 照らされる割合) を掛ける（拡散と鏡面）。|p − 位置|² ≥ range² か dot(n, 位置 − p) ≤ 0 の点は引かない（1）。
    pub def atlasOf(scene: Scene3d.Scene3dCmd): Option[Atlas] =
        let castsShadow = match scene#output {
            case Scene3d.Output.Color    => Scene3d.hasDrawnInstance(scene)
            case Scene3d.Output.Depth(_) => false
        };
        scene#pointShadows
            |> Option.filter(m -> castsShadow and m#maxShadowedLights > 0 and m#mapSize > 0)
            |> Option.map(atlasFor(scene))

    def atlasFor(scene: Scene3d.Scene3dCmd, m: Scene3d.PointShadowMap): Atlas =
        let limit = Int32.min(m#maxShadowedLights, Scene3d.maxShadowedPointLights());
        let columns = if (limit <= 1) 1 else 2;
        let rows = (limit + columns - 1) / columns;
        let fit = Int32.min(Scene3d.maxShadowMapSize() / (3 * columns), Scene3d.maxShadowMapSize() / (2 * rows));
        let size = Int32.min(Int32.max(16, m#mapSize), fit);
        let pcf = Int32.max(0, Int32.min(Int32.min(m#pcfRadius, Scene3d.maxShadowPcfRadius()), size / 4 - 2));
        let guard = Int32.toFloat64(size - 2 * (pcf + 1)) / Int32.toFloat64(size);
        let frustum = Scene3d.frustumOf(scene);
        let ranked = List.zipWithIndex(scene#pointLights)
            |> List.filterMap(entry -> {
                let (i, light) = entry;
                Scene3d.pointPickScoreOf(scene#camera, frustum, light) |> Option.map(score -> (score, (i, light)))
            })
            |> Sort.sortStableBy(fst);
        let scores = ranked |> List.map(fst) |> List.toVector;
        let lights = ranked |> List.take(limit) |> List.zipWithIndex |> List.map(entry -> {
            let (slot, (score, (i, light))) = entry;
            let weight = shadowedLightWeightOf(scores, limit, slot, score);
            shadowedPointLightOf(guard, i, slot, Num.clamp01(m#strength) * weight, light)
        });
        { tileSize = size, blocksPerRow = columns, width = 3 * size * columns, height = 2 * size * rows, pcfRadius = pcf,
          bias = Float64.max(0.0, m#bias), normalBias = Float64.max(0.0, m#normalBias) * Int32.toFloat64(pcf + 1), guardScale = guard, lights = lights,
          requestedSize = m#mapSize }

    // WhyNot: normalBias を PCF の幅に依らず 1 画素ぶんだけにしない — すれすれに光を受ける床では、周りの (2r+1)² 画素の奥行きの差が
    //   r 画素ぶん傾きで増え、床が自分の影を拾って縞になる（mapSize 256・pcf 1 の床で gl-parity の場面に出た）。ずらす幅を (r + 1) 画素にすると、
    //   どの傾きでも周りの画素の奥行きの誤差より遠くへ出る。
    /// 影を落とす slot 番目の灯りの境の重み（式は atlasOf の doc）。
    // WhyNot: 本数 1 の時も重みを付けない — 1 つ前の候補が無く、入れ替わる瞬間の両側を 1 と 0 でつなぐ幅が取れない。
    def shadowedLightWeightOf(scores: Vector[Float64], limit: Int32, slot: Int32, score: Float64): Float64 =
        if (limit < 2 or slot != limit - 1 or Vector.length(scores) <= limit) 1.0
        else {
            let next = Vector.get(limit, scores);
            let prev = Vector.get(limit - 2, scores);
            let weight = Num.clamp01((next - score) / Float64.max(next - prev, 1.0e-6));
            if (Float64.isNan(weight)) 1.0 else weight
        }

    def shadowedPointLightOf(guard: Float64, index: Int32, slot: Int32, strength: Float64, light: Scene3d.PointLight): ShadowedPointLight =
        let far = Float64.max(2.0, light#range);
        let near = Float64.min(1.0, far / 100.0);
        let faces = List.range(0, 6) |> List.map(f -> faceMatrixOf(light#position, near, far, guard, f)) |> List.toVector;
        { pointIndex = index, slot = slot, position = light#position, range = light#range, near = near, far = far, strength = strength,
          faces = faces, frustums = Vector.map(Frustum.ofClipMatrix, faces) }

    /// 面 f（0〜5 = +X・−X・+Y・−Y・+Z・−Z）の前の向き F・上 U・右 R（R × U = F。Camera3d の right × up = forward と同じ向き）。
    /// +Y と −Y の面の上は +Z。GL の cube の面の向きにはそろえない（atlas の中だけで読む）。
    pub def basisOf(face: Int32): { right = Vec3.Vec3, up = Vec3.Vec3, forward = Vec3.Vec3 } = match face {
        case 0 => { right = Vec3.v3(0.0, 0.0, -1.0), up = Vec3.v3(0.0, 1.0, 0.0), forward = Vec3.v3(1.0, 0.0, 0.0) }
        case 1 => { right = Vec3.v3(0.0, 0.0, 1.0),  up = Vec3.v3(0.0, 1.0, 0.0), forward = Vec3.v3(-1.0, 0.0, 0.0) }
        case 2 => { right = Vec3.v3(-1.0, 0.0, 0.0), up = Vec3.v3(0.0, 0.0, 1.0), forward = Vec3.v3(0.0, 1.0, 0.0) }
        case 3 => { right = Vec3.v3(1.0, 0.0, 0.0),  up = Vec3.v3(0.0, 0.0, 1.0), forward = Vec3.v3(0.0, -1.0, 0.0) }
        case 4 => { right = Vec3.v3(1.0, 0.0, 0.0),  up = Vec3.v3(0.0, 1.0, 0.0), forward = Vec3.v3(0.0, 0.0, 1.0) }
        case _ => { right = Vec3.v3(-1.0, 0.0, 0.0), up = Vec3.v3(0.0, 1.0, 0.0), forward = Vec3.v3(0.0, 0.0, -1.0) }
    }

    /// 面 f の world → 光の clip の行列 = perspective(s, s, near, far) × ofLinearRows(R, U, −F) × translate(−位置)（s = guard）。
    pub def faceMatrixOf(position: Vec3.Vec3, near: Float64, far: Float64, guard: Float64, face: Int32): Mat4.Mat4 =
        Mat4.mul(faceProjectionOf(near, far, guard), faceViewOf(position, face))

    /// 面 f の world → 光の目の座標（GL の目の座標・−Z を見る）= ofLinearRows(R, U, −F) × translate(−位置)。
    /// CPU の描き手は w = 目の座標の −z を自分で出すので、faceMatrixOf でなくこれと faceProjectionOf を分けて渡す。
    pub def faceViewOf(position: Vec3.Vec3, face: Int32): Mat4.Mat4 =
        let b = basisOf(face);
        Mat4.mul(Mat4.ofLinearRows(b#right, b#up, Vec3.mul(b#forward, -1.0)), Mat4.translate(Vec3.mul(position, -1.0)))

    /// 面の射影 = perspective(s, s, near, far)（s = guard。6 面で同じ）。
    pub def faceProjectionOf(near: Float64, far: Float64, guard: Float64): Mat4.Mat4 =
        Mat4.perspective({ xScale = guard, yScale = guard, near = near, far = far })

    /// 光から点への向き d が写る面（|x| ≥ |y| かつ |x| ≥ |z| なら X・ほかに |y| ≥ |z| なら Y・ほかは Z。成分が 0 以上なら + の面）。
    pub def faceOf(d: Vec3.Vec3): Int32 =
        let ax = Float64.abs(d#x);
        let ay = Float64.abs(d#y);
        let az = Float64.abs(d#z);
        if (ax >= ay and ax >= az) (if (d#x >= 0.0) 0 else 1)
        else if (ay >= az) (if (d#y >= 0.0) 2 else 3)
        else if (d#z >= 0.0) 4 else 5

    /// atlas の中の slot 番目の灯りの面 f の画素の原点 (x, y)（行 0 が ndc.y = −1 の側。GL の深度テクスチャと CPU の地図の数え方）。
    /// WebGPU は viewport を (x, height − (y + tileSize)) に置き、読む画素の行を height − 1 − 行 で返す。
    pub def tileOriginOf(atlas: Atlas, slot: Int32, face: Int32): (Int32, Int32) =
        let s = atlas#tileSize;
        let column = Int32.remainder(slot, atlas#blocksPerRow);
        let row = slot / atlas#blocksPerRow;
        (column * 3 * s + Int32.remainder(face, 3) * s, row * 2 * s + (face / 3) * s)

    /// 面の目の奥行きを地図の値（ndc.z = A − B / 奥行き）へ写す A と B（A = (far + near) / (far − near)・B = 2 far near / (far − near)）。
    pub def depthTermsOf(light: ShadowedPointLight): (Float64, Float64) =
        let span = light#far - light#near;
        ((light#far + light#near) / span, 2.0 * light#far * light#near / span)

    /// 受ける点 p（g = 形の法線・長さ 1）が引く面と、その面の中の真ん中の画素 (x, y)（0..tileSize − 1 に寄せた後）と、地図の値と比べる値 ref。
    /// 1. d0 = p − 位置・major = max(|d0.x|, |d0.y|, |d0.z|)。q = p + g × normalBias × 2 major / (s × tileSize)・d = q − 位置。
    /// 2. 面 = faceOf(d)・depth = d·F。depth ≤ near なら None（影にしない）。
    /// 3. ndc = (s (d·R) / depth, s (d·U) / depth)・ref = (A − B / max(depth − bias, near)) × 0.5 + 0.5・画素 = clamp(floor((ndc × 0.5 + 0.5) × tileSize), 0, tileSize − 1)。
    /// PCF は (x + dx, y + dy) を 0..tileSize − 1 に寄せてから面の原点を足し、ref ≤ 地図の値 の数を数える。
    pub def sampleOf(atlas: Atlas, light: ShadowedPointLight, p: Vec3.Vec3, g: Vec3.Vec3): Option[{ face = Int32, x = Int32, y = Int32, ref = Float64 }] =
        let s = atlas#guardScale;
        let size = Int32.toFloat64(atlas#tileSize);
        let d0 = Vec3.sub(p, light#position);
        let major = Float64.max(Float64.abs(d0#x), Float64.max(Float64.abs(d0#y), Float64.abs(d0#z)));
        let shift = atlas#normalBias * 2.0 * major / (s * size);
        let d = Vec3.add(d0, Vec3.mul(g, shift));
        let face = faceOf(d);
        let b = basisOf(face);
        let depth = Vec3.dot(d, b#forward);
        if (not (depth > light#near)) None
        else {
            let (a, bb) = depthTermsOf(light);
            let ndcX = s * Vec3.dot(d, b#right) / depth;
            let ndcY = s * Vec3.dot(d, b#up) / depth;
            let ref = (a - bb / Float64.max(depth - atlas#bias, light#near)) * 0.5 + 0.5;
            let last = atlas#tileSize - 1;
            let texel = (v: Float64) -> Float64.max(0.0, Float64.min(Int32.toFloat64(last), Float64.floor((v * 0.5 + 0.5) * size)))
                |> Float64.tryToInt32 |> Option.getWithDefault(0);
            Some({ face = face, x = texel(ndcX), y = texel(ndcY), ref = ref })
        }

    /// 点光源 light の影の地図に描くビルボード（castShadows が真で shadowCasterScale の成分が両方正・板の外の円が光の range の球に掛かる物。来た順）と、
    /// その板の横の向き（板から光への向きで billboardShadowRightOf。光が板の真上ならカメラの right）。大きさは shadowCasterFieldsOf の物。
    /// 板は地面に垂直に立て、光の方へ向けて描く（太陽の影の板と同じ約束で、向きだけ灯りごと・板ごとに変わる）。面ごとの間引きは描き手が face の視錐台で行う。
    pub def castingBillboardsOf(scene: Scene3d.Scene3dCmd, light: ShadowedPointLight): List[(Scene3d.BillboardFields, Vec3.Vec3)] =
        let fallback = Camera3d.right(scene#camera);
        scene#billboards |> List.map(Scene3d.billboardFieldsOf) |> List.filter(f -> {
            let c = Scene3d.shadowCasterFieldsOf(f);
            let reach = light#range + Float64.abs(c#size#x) + Float64.abs(c#size#y);
            f#castShadows and f#shadowCasterScale#x > 0.0 and f#shadowCasterScale#y > 0.0 and Vec3.distanceSquared(f#position, light#position) < reach * reach
        }) |> List.map(f -> (Scene3d.shadowCasterFieldsOf(f), Scene3d.billboardShadowRightOf(Vec3.sub(light#position, f#position), fallback)))

    /// 受ける点 p（n = 光の計算の法線）で点光源 light の影の地図を引くか（光が届き、面が光へ向いている時だけ）。
    pub def isSampled(light: ShadowedPointLight, p: Vec3.Vec3, n: Vec3.Vec3): Bool =
        let toLight = Vec3.sub(light#position, p);
        Vec3.dot(toLight, toLight) < light#range * light#range and Vec3.dot(n, toLight) > 0.0
}
