// SoftRaster3d — 3D の場面（Scene3d.RenderCmd）1 つを CPU で画素に塗り、SoftRaster の下地へ重ねる。
// GL を使わない描き出し（スナップショット・テスト）で、Render3d（GL）と同じ場面を同じ光の式で描く。
// GL と画素は一致させない（Shader 面と同じ扱い）。比べは CPU の絵どうしで行う。
//
// 光の式（GL の Render3d も同じ式を書く。式を変える時は両方を直す）:
//
//   light  = ambient + hemisphere × max(0, n.y)
//          + Σ 点光源   color × intensity × att × facing
//          + Σ スポット color × intensity × att × facing × cone
//   att    = (max(0, 1 − d² / range²))²          d = 光と点の距離
//   facing = clamp(wrap + n·l, 0, 1)              l = 点から光への向き（長さ 1）・wrap = 0.0
//   cone   = smoothstep(cos(fovY / 2), cos(fovY / 2 × spotInnerRatio()), dot(−l, spotDir))
//            spotDir = normalize(target − position)・smoothstep(a, b, x) = t² (3 − 2t)、t = clamp((x − a) / (b − a), 0, 1)
//   toonSteps > 0 なら light の各成分を floor(light × steps + 0.5) / steps に丸める
//   色     = 頂点の色 × tint × light
//   材質のある置いた物: 色 = albedo × tint × light（頂点の色は掛けない）・fog の後に emission を足す
//            albedo・α・emission = ShaderEval.evalMaterial3(world の点, 法線, 時刻)。cutout なら α < materialCutoff() の画素を捨てる（深度も書かない）
//   fog    = clamp((|点 − 目| − near) / max(far − near, 1e-6), 0, 1) の割合で fog の色へ寄せる
//   range は 1e-6 未満にしない（0 割りを避ける）
//   Output.Depth の灰色 = clamp((|点 − 目| − near) / max(range, 1e-6), 0, 1)（目からの直線の距離。view の z ではない）
//
// ビルボード: 絵の α が billboardCutoff() 未満の画素は捨てる（深度も書かない）。lit が真なら法線をカメラへ向けて同じ光と fog を当てる。
// 光は Scene3d.pickLights（目に近い順に点光源 8・スポット 2）で選んだ物だけを使う。
// ジョイント: Scene3d.skinningOf が Some の置いた物は、頂点を GL の Render3d と同じ式で曲げてから写す（式は placedOf の doc。影の地図も同じ形）。
//
// 影（GL の Render3d と同じ約束。本文は Scene3d.shadowMatrix の doc）:
//   影を落とすのは、pickLights の後の並びで shadow が Some の最初のスポット 1 本だけ（2 本目以降の shadow は無視）。
//   地図 = mapSize × mapSize。置いた物の三角形を表も裏も shadowMatrix で写して near で切り、画素ごとに一番近い z × 0.5 + 0.5。
//          何も無い画素は 1。ビルボードは影を落とさない。
//   地図の画素 = ((x × 0.5 + 0.5) × mapSize, (y × 0.5 + 0.5) × mapSize) の切り捨て（NDC の x・y）。行 0 が NDC の y = −1 側（GL のテクスチャと同じ向き）。
//   pcf の周りの画素が地図の外に出たら端の画素を読む（GL の CLAMP_TO_EDGE）。
//   光の w が 0 以下（光の後ろ）の点は、NDC の外と同じく影にしない。
//   影はスポットの光の量（att × facing × cone）に掛け、環境光・半球・点光源には掛けない。Output.Depth では地図を作らない。
pub mod SoftRaster3d {
    import java.awt.image.BufferedImage
    import java.lang.System
    import java.util.function.IntConsumer
    import java.util.stream.IntStream

    /// スポットライトの円錐で、明るさが落ち始める角の割合（円錐の半角 × この値の内側は落ちない）。
    pub def spotInnerRatio(): Float64 = 0.8

    /// 光が面を回り込む量（facing の wrap）。Environment3d に欄が無いので固定。
    pub def wrap(): Float64 = 0.0

    /// ビルボードの絵の α がこれ未満の画素は捨てる。
    pub def billboardCutoff(): Float64 = 0.5

    /// cutout の材質で、α がこれ未満の画素は捨てる。
    pub def materialCutoff(): Float64 = 0.5

    // ════════════════════════════════════════════════════════
    // 光の式（pub の口は GL の担当と値を突き合わせるため）
    // ════════════════════════════════════════════════════════

    /// world の点 position・法線 normal（長さ 1）に当たる光の量（色ごと。toonSteps の丸めまで済ませた値）。
    // WhyNot: ここで影を見ない — 影の地図は場面の置いた物から作るので、光の並びだけでは作れない。影は drawScene の道でだけ付く。
    pub def lightAt(env: Scene3d.Environment3d, pointLights: List[Scene3d.PointLight], spotLights: List[Scene3d.SpotLight],
                    position: Vec3.Vec3, normal: Vec3.Vec3): Color =
        let (r, g, b) = evalLight(compileLights(env, pointLights, spotLights, None),
                                  position#x, position#y, position#z, normal#x, normal#y, normal#z);
        { r = r, g = g, b = b }

    /// 目 eye から見た world の点 position の色 c に、距離のかすみを掛けた色（fog が None なら c のまま）。
    pub def fogAt(env: Scene3d.Environment3d, eye: Vec3.Vec3, position: Vec3.Vec3, c: Color): Color =
        let (r, g, b) = applyFog(compileFog(env#fog), eye#x, eye#y, eye#z, position#x, position#y, position#z, c#r, c#g, c#b);
        { r = r, g = g, b = b }

    // 点光源 1 本 = 7 個（位置 3・color × intensity 3・range²）、スポット 1 本 = 12 個（位置 3・向き 3・
    // 外の cos・内の cos・color × intensity 3・range²）を 1 本の Vector に並べた物。
    // WhyNot: 光をレコードの列のまま画素ごとに読まない — レコードの欄は名前で引くので、画素 × 光の数だけ重くなる。
    enum Lights {
        // ambient r, g, b・hemisphere・toonSteps・点光源の並び・スポットの並び・影
        case Lights(Float64, Float64, Float64, Float64, Int32, Vector[Float64], Vector[Float64], Option[Shadow])
    }

    /// 影を落とすスポット 1 本の地図と判定に要る値。スポットの並びの中の位置（spots の Vector の先頭からの欄の数）・
    /// shadowMatrix の 16 個（行優先）・mapSize・bias・pcfRadius・strength・地図（行 0 が NDC の y = −1 側）。
    enum Shadow { case Shadow(Int32, Vector[Float64], Int32, Float64, Int32, Float64, Vector[Float64]) }

    def compileLights(env: Scene3d.Environment3d, pointLights: List[Scene3d.PointLight],
                      spotLights: List[Scene3d.SpotLight], shadow: Option[Shadow]): Lights =
        let points = pointLights |> List.flatMap(l ->
            l#position#x :: l#position#y :: l#position#z ::
            l#color#r * l#intensity :: l#color#g * l#intensity :: l#color#b * l#intensity ::
            rangeSquared(l#range) :: Nil) |> List.toVector;
        let spots = spotLights |> List.flatMap(l -> {
            let dir = Vec3.normalized(Vec3.sub(l#target, l#position));
            let half = l#fovY / 2.0;
            l#position#x :: l#position#y :: l#position#z :: dir#x :: dir#y :: dir#z ::
            Vec2.cos(half) :: Vec2.cos(half * spotInnerRatio()) ::
            l#color#r * l#intensity :: l#color#g * l#intensity :: l#color#b * l#intensity ::
            rangeSquared(l#range) :: Nil
        }) |> List.toVector;
        Lights.Lights(env#ambient#r, env#ambient#g, env#ambient#b, env#hemisphere, env#toonSteps, points, spots, shadow)

    def evalLight(lights: Lights, px: Float64, py: Float64, pz: Float64,
                  nx: Float64, ny: Float64, nz: Float64): (Float64, Float64, Float64) =
        let Lights.Lights(ar, ag, ab, hemi, steps, points, spots, shadow) = lights;
        let sky = hemi * Float64.max(0.0, ny);
        let (pr, pg, pb) = sumPoints(points, 0, px, py, pz, nx, ny, nz, 0.0, 0.0, 0.0);
        let (sr, sg, sb) = sumSpots(spots, shadow, 0, px, py, pz, nx, ny, nz, 0.0, 0.0, 0.0);
        (toon(steps, ar + sky + pr + sr), toon(steps, ag + sky + pg + sg), toon(steps, ab + sky + pb + sb))

    def rangeSquared(range: Float64): Float64 =
        let r = Float64.max(range, 1.0e-6);
        r * r

    def toon(steps: Int32, x: Float64): Float64 =
        if (steps <= 0) x
        else {
            let s = Int32.toFloat64(steps);
            Float64.floor(x * s + 0.5) / s
        }

    /// 光から点までの (att × facing, 点から光への向き x, y, z)。
    def reach(lx: Float64, ly: Float64, lz: Float64, rangeSq: Float64,
              px: Float64, py: Float64, pz: Float64, nx: Float64, ny: Float64, nz: Float64): (Float64, Float64, Float64, Float64) =
        let dx = lx - px;
        let dy = ly - py;
        let dz = lz - pz;
        let dSq = dx * dx + dy * dy + dz * dz;
        let fall = Float64.max(0.0, 1.0 - dSq / Float64.max(rangeSq, 1.0e-12));
        let att = fall * fall;
        let len = Vec2.sqrt(dSq);
        let inv = if (len < 1.0e-12) 0.0 else 1.0 / len;
        let (ux, uy, uz) = (dx * inv, dy * inv, dz * inv);
        let facing = clamp01(wrap() + nx * ux + ny * uy + nz * uz);
        (att * facing, ux, uy, uz)

    def sumPoints(points: Vector[Float64], i: Int32, px: Float64, py: Float64, pz: Float64,
                  nx: Float64, ny: Float64, nz: Float64, r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) =
        if (i + 7 > Vector.length(points)) (r, g, b)
        else {
            let at = k -> Vector.get(i + k, points);
            let (k, _, _, _) = reach(at(0), at(1), at(2), at(6), px, py, pz, nx, ny, nz);
            sumPoints(points, i + 7, px, py, pz, nx, ny, nz, r + at(3) * k, g + at(4) * k, b + at(5) * k)
        }

    def sumSpots(spots: Vector[Float64], shadow: Option[Shadow], i: Int32, px: Float64, py: Float64, pz: Float64,
                 nx: Float64, ny: Float64, nz: Float64, r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) =
        if (i + 12 > Vector.length(spots)) (r, g, b)
        else {
            let at = k -> Vector.get(i + k, spots);
            let (k, ux, uy, uz) = reach(at(0), at(1), at(2), at(11), px, py, pz, nx, ny, nz);
            let cd = 0.0 - (ux * at(3) + uy * at(4) + uz * at(5));
            let cone = smoothstep(at(6), at(7), cd);
            // WhyNot: 光の届かない点で地図を引かない — 掛ける先が 0 なので結果は同じで、pcf の (2r+1)² 回が無駄になる。
            let lit = if (k > 0.0 and cone > 0.0) shadowFactorAt(shadow, i, px, py, pz) else 1.0;
            sumSpots(spots, shadow, i + 12, px, py, pz, nx, ny, nz,
                     r + at(8) * k * cone * lit, g + at(9) * k * cone * lit, b + at(10) * k * cone * lit)
        }

    /// スポットの並びの位置 offset のスポットが、world の点 (px, py, pz) へ届ける光に掛ける割合（影を落とさないスポットは 1）。
    def shadowFactorAt(shadow: Option[Shadow], offset: Int32, px: Float64, py: Float64, pz: Float64): Float64 = match shadow {
        case Some(Shadow.Shadow(at, m, n, bias, radius, strength, map)) if at == offset =>
            let row = k -> Vector.get(k * 4, m) * px + Vector.get(k * 4 + 1, m) * py + Vector.get(k * 4 + 2, m) * pz + Vector.get(k * 4 + 3, m);
            let w = row(3);
            let (sx, sy, sz) = if (w <= 0.0) (2.0, 2.0, 0.0) else (row(0) / w, row(1) / w, row(2) / w);
            if (sx < -1.0 or sx > 1.0 or sy < -1.0 or sy > 1.0) 1.0
            else {
                let r = Int32.max(0, radius);
                let side = 2 * r + 1;
                let lit = countLit(map, n, mapTexel(n, sx) - r, mapTexel(n, sy) - r, side, sz * 0.5 + 0.5 - bias, 0, 0);
                1.0 - strength * (1.0 - Int32.toFloat64(lit) / Int32.toFloat64(side * side))
            }
        case _ => 1.0
    }

    /// NDC の x か y（−1..1）が落ちる地図の画素（0..n−1）。
    def mapTexel(n: Int32, ndc: Float64): Int32 =
        Int32.max(0, Int32.min(n - 1, floorInt((ndc * 0.5 + 0.5) * Int32.toFloat64(n))))

    /// 左下 (x0, y0) から side × side の地図の画素のうち、depth が地図の値以下の画素の数（地図の外は端の画素を読む）。
    def countLit(map: Vector[Float64], n: Int32, x0: Int32, y0: Int32, side: Int32, depth: Float64, k: Int32, acc: Int32): Int32 =
        if (k >= side * side) acc
        else {
            let x = Int32.max(0, Int32.min(n - 1, x0 + (k - (k / side) * side)));
            let y = Int32.max(0, Int32.min(n - 1, y0 + k / side));
            countLit(map, n, x0, y0, side, depth, k + 1, if (depth <= Vector.get(y * n + x, map)) acc + 1 else acc)
        }

    def smoothstep(lo: Float64, hi: Float64, x: Float64): Float64 =
        let t = if (hi == lo) (if (x >= hi) 1.0 else 0.0) else clamp01((x - lo) / (hi - lo));
        t * t * (3.0 - 2.0 * t)

    // fog があるか・色 r, g, b・near・far。
    enum Fog { case Fog(Bool, Float64, Float64, Float64, Float64, Float64) }

    def compileFog(fog: Option[Scene3d.DistanceFog]): Fog = match fog {
        case None    => Fog.Fog(false, 0.0, 0.0, 0.0, 0.0, 0.0)
        case Some(f) => Fog.Fog(true, f#color#r, f#color#g, f#color#b, f#near, f#far)
    }

    def applyFog(fog: Fog, ex: Float64, ey: Float64, ez: Float64, px: Float64, py: Float64, pz: Float64,
                 r: Float64, g: Float64, b: Float64): (Float64, Float64, Float64) =
        let Fog.Fog(on, fr, fg, fb, near, far) = fog;
        if (not on) (r, g, b)
        else {
            let (dx, dy, dz) = (px - ex, py - ey, pz - ez);
            let dist = Vec2.sqrt(dx * dx + dy * dy + dz * dz);
            let f = clamp01((dist - near) / Float64.max(far - near, 1.0e-6));
            (r + (fr - r) * f, g + (fg - g) * f, b + (fb - b) * f)
        }

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))

    // ════════════════════════════════════════════════════════
    // 場面 1 つを下地へ
    // ════════════════════════════════════════════════════════

    /// 場面 cmd を image へ重ねる。sf = design px → 出力の画素の倍率。textures = ビルボードが引く絵（名前 → 画素）。
    /// time = 材質の Spec に渡す秒（Shader 面の time と同じ物）。
    /// Native は出力の画素で塗り、Design は design の画素で塗ってから最も近い画素で広げる。
    /// 何も描かれない画素は background が Some ならその色、None なら透明（下地が見える）。重ね方は Shader 面と同じ blendPixel。
    pub def drawScene(image: BufferedImage, sf: Float64, textures: Map[String, ShaderEval.TexData],
                      time: Float64, cmd: Scene3d.RenderCmd): Unit \ IO = region rc {
        let scene = cmd#scene;
        let (rx0, ry0, rx1, ry1) = DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, { position = cmd#at, size = scene#size });
        let dw = rx1 - rx0;
        let dh = ry1 - ry0;
        let (cx0, cy0, cx1, cy1) = match cmd#clip {
            case None    => (rx0, ry0, rx1, ry1)
            case Some(r) => DrawCmd.clipPixels({ scaleX = sf, scaleY = sf }, r)
        };
        let x0 = Int32.max(0, Int32.max(rx0, cx0));
        let y0 = Int32.max(0, Int32.max(ry0, cy0));
        let x1 = Int32.min(image.getWidth(), Int32.min(rx1, cx1));
        let y1 = Int32.min(image.getHeight(), Int32.min(ry1, cy1));
        let w = x1 - x0;
        let h = y1 - y0;
        if (dw <= 0 or dh <= 0 or w <= 0 or h <= 0 or scene#size#x <= 0.0 or scene#size#y <= 0.0) ()
        else {
            let (lw, lh) = match scene#resolution {
                case Scene3d.Resolution.Native => (dw, dh)
                case Scene3d.Resolution.Design =>
                    (Int32.max(1, roundInt(scene#size#x)), Int32.max(1, roundInt(scene#size#y)))
            };
            let layer = renderLayer(scene, lw, lh, textures, time);
            let buf: Array[Int32, rc] = Array.empty(rc, w * h);
            discard image.getRGB(x0, y0, w, h, buf, 0, w);
            List.range(0, h) |> List.forEach(j -> {
                let ly = nearestIndex(y0 + j - ry0, dh, lh);
                List.range(0, w) |> List.forEach(i -> {
                    let lx = nearestIndex(x0 + i - rx0, dw, lw);
                    let k = j * w + i;
                    Array.put(SoftRaster.blendPixel(DrawCmd.BlendMode.Normal, Array.get(ly * lw + lx, layer), Array.get(k, buf)), k, buf)
                })
            });
            image.setRGB(x0, y0, w, h, buf, 0, w)
        }
    }

    /// 出力の画素 o（0..outN−1）が拾う層の画素（0..srcN−1）。同じ数なら o のまま。
    def nearestIndex(o: Int32, outN: Int32, srcN: Int32): Int32 =
        if (outN == srcN) o
        else Int32.max(0, Int32.min(srcN - 1, floorInt((Int32.toFloat64(o) + 0.5) * Int32.toFloat64(srcN) / Int32.toFloat64(outN))))

    // ════════════════════════════════════════════════════════
    // 場面 1 つを lw × lh の ARGB へ
    // ════════════════════════════════════════════════════════

    // 1 頂点の欄の数。clip の段では (clip x, y, z, w, world x, y, z, 法線 x, y, z, 色 r, g, b か uv u, v, 0)、
    // 画面へ写した後は先頭 4 つが (画面 x, y, NDC の z, 1 / w) に替わる。材質のある置いた物の色の欄は tint だけ。
    def stride(): Int32 = 13

    /// 画面へ写した三角形 1 枚。頂点 3 つ（stride() 個ずつ）・符号つきの面積（画面の px²）・
    /// ビルボードの番号（メッシュは −1）・材質の番号（材質の無い物とビルボードは −1）。
    enum Tri { case Tri(Vector[Float64], Float64, Int32, Int32) }

    /// 置いた物 1 つの材質。組み直した Spec（Param は値に置き換え済み）・cutout。
    enum Mat { case Mat(ShaderEval.CompiledSpec, Bool) }

    def matOf(m: Scene3d.Material3d): Mat =
        Mat.Mat(ShaderEval.compileMaterial(m#spec, m#emission, m#params), m#cutout)

    /// 置いた物ごとの材質の番号（材質の無い物は −1）。番号は材質のある物だけを前から数える。
    def numberMaterials(placed: List[Placed]): List[(Placed, Int32)] =
        let (_, numbered) = placed |> List.foldLeft((acc, p) -> {
            let (next, out) = acc;
            if (Option.isEmpty(p#fields#material)) (next, (p, -1) :: out) else (next + 1, (p, next) :: out)
        }, (0, Nil));
        List.reverse(numbered)

    /// 置いた物 1 つの中身と、ジョイントで曲げた後の頂点の位置と法線（形の座標・頂点ごとに 3 つ。曲げない物は形のまま）。
    type alias Placed = { fields = Scene3d.InstanceFields, positions = Vector[Float64], normals = Vector[Float64] }

    /// 置いた物 i を、Scene3d.skinningOf が Some なら曲げて Placed にする（GL の Render3d の頂点シェーダーと同じ式）:
    ///   位置 = Σ w_k × (jointMatrices[j_k] × p)・法線 = Σ w_k × (jointMatrices[j_k] の左上 3×3 × n)
    /// world と normalMatrix(world) は instanceTris が後から掛ける。
    // WhyNot: instanceTris の中で曲げない — 影の地図と画面の 2 回通るので、置いた物ごとに 1 回で済むようここで曲げる。
    // WhyNot: 法線に skin の逆行列の転置を使わない — ジョイントの倍率が軸ごとに違うと少しずれるが、GL も左上 3×3 のままで、両方の絵がそろう方を取る。
    def placedOf(i: Scene3d.Instance3d): Placed =
        let f = Scene3d.instanceFieldsOf(i);
        let bent = forM (
            pose <- Scene3d.skinningOf(i);
            joints <- Mesh3d.skinJoints(f#mesh);
            weights <- Mesh3d.skinWeights(f#mesh)
        ) yield bendVertices(Pose3d.jointMatrices(pose), joints, weights, f#mesh);
        let (positions, normals) = Option.getWithDefault((Mesh3d.positions(f#mesh), Mesh3d.normals(f#mesh)), bent);
        { fields = f, positions = positions, normals = normals }

    /// 形 mesh の頂点を、頂点ごとの 4 つのジョイント（joints の番号・weights の重み。頂点 k は [4k, 4k + 4)）で曲げた位置と法線。
    // WhyNot: 重み 0 の欄を飛ばす — 足しても値が変わらず、多くの頂点は 1〜2 本しか使わない。
    def bendVertices(matrices: Vector[Mat4.Mat4], joints: Vector[Int32], weights: Vector[Float64],
                     mesh: Mesh3d.Mesh3d): (Vector[Float64], Vector[Float64]) =
        let blendAt = (move: (Mat4.Mat4, Vec3.Vec3) -> Vec3.Vec3, v: Vec3.Vec3, k: Int32) ->
            List.range(k * 4, k * 4 + 4) |> List.foldLeft((acc, s) -> {
                let w = Vector.get(s, weights);
                if (w == 0.0) acc else Vec3.add(acc, Vec3.mul(move(Vector.get(Vector.get(s, joints), matrices), v), w))
            }, Vec3.zero());
        let ps = Mesh3d.positions(mesh);
        let ns = Mesh3d.normals(mesh);
        let bent = Vector.range(0, Mesh3d.vertexCount(mesh)) |> Vector.map(k ->
            (blendAt(Mat4.apply, vec3At(ps, k), k), blendAt(Mat4.applyDir, vec3At(ns, k), k)));
        (Vector.flatMap(pair -> xyzOf(fst(pair)), bent), Vector.flatMap(pair -> xyzOf(snd(pair)), bent))

    /// 頂点ごとに 3 つ並んだ v の k 番目の頂点。
    def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 =
        Vec3.v3(Vector.get(k * 3, v), Vector.get(k * 3 + 1, v), Vector.get(k * 3 + 2, v))

    def xyzOf(v: Vec3.Vec3): Vector[Float64] = Vector#{ v#x, v#y, v#z }

    /// ビルボード 1 枚の絵。画素・region の px 矩形（x0, y0, x1, y1。x1・y1 は含まない）・tint r, g, b・光を当てるか。
    enum Ink { case Ink(ShaderEval.TexData, Int32, Int32, Int32, Int32, Float64, Float64, Float64, Bool) }

    /// 場面を lw × lh の ARGB（行優先）に塗る。
    def renderLayer(scene: Scene3d.Scene3dCmd, lw: Int32, lh: Int32,
                    textures: Map[String, ShaderEval.TexData], time: Float64): Array[Int32, Static] \ IO = region rc {
        let cam = scene#camera;
        let picked = Scene3d.pickLights(cam#eye, scene);
        let view = Camera3d.viewMatrix(cam);
        let proj = Camera3d.projectionMatrix(cam, scene#size#x / scene#size#y);
        let screen = { w = Int32.toFloat64(lw), h = Int32.toFloat64(lh), near = cam#near };
        let placed = scene#billboards |> List.filterMap(b -> {
            let f = Scene3d.billboardFieldsOf(b);
            Map.get(f#texture, textures) |> Option.map(tex -> (f, tex))
        });
        let inks = placed |> List.map(pair -> inkOf(snd(pair), fst(pair))) |> List.toVector;
        let numbered = numberMaterials(scene#instances |> List.map(placedOf));
        // WhyNot: 同じ Spec の材質を 1 つに束ねない — Spec に Eq が無く、束ねる鍵（JSON の字）を作る手間が組み直しと同じくらいかかる。
        let mats = hoist(rc, numbered |> List.filterMap(pair -> fst(pair)#fields#material) |> List.map(matOf) |> List.toVector);
        let meshTris = numbered |> List.flatMap(pair -> instanceTris(view, proj, screen, true, fst(pair), snd(pair)));
        let billboardTris = List.zipWithIndex(placed) |> List.flatMap(entry -> {
            let (index, (f, _)) = entry;
            billboardTris(view, proj, screen, cam, index, f)
        });
        let tris = hoist(rc, List.append(meshTris, billboardTris) |> List.toVector);
        let bins = hoist(rc, binRows(rc, lh, tris));
        let shadow = match scene#output {
            case Scene3d.Output.Color    => shadowOf(numbered |> List.map(fst), picked#spotLights)
            case Scene3d.Output.Depth(_) => None
        };
        let lights = hoist(rc, compileLights(picked#environment, picked#pointLights, picked#spotLights, shadow));
        let fog = hoist(rc, compileFog(scene#environment#fog));
        let inkTable = hoist(rc, inks);
        let eye = hoist(rc, (cam#eye#x, cam#eye#y, cam#eye#z));
        let fill = hoist(rc, match scene#environment#background {
            case Some(c) => SoftRaster.argbOfRgba(c#r, c#g, c#b, 1.0)
            case None    => 0
        });
        let depthBand = hoist(rc, match scene#output {
            case Scene3d.Output.Color    => None
            case Scene3d.Output.Depth(d) => Some((d#near, d#range))
        });
        let out: Array[Int32, Static] = Array.repeat(Static, lw * lh, 0);
        forEachRow(lh, y -> region rr {
            let depth: Array[Float64, rr] = Array.repeat(rr, lw, 2.0);
            let winner: Array[Int32, rr] = Array.repeat(rr, lw, -1);
            let w0: Array[Float64, rr] = Array.repeat(rr, lw, 0.0);
            let w1: Array[Float64, rr] = Array.repeat(rr, lw, 0.0);
            let py = Int32.toFloat64(y) + 0.5;
            Vector.get(y, bins) |> List.forEach(ti -> coverRow(lw, py, tris, inkTable, mats, time, ti, depth, winner, w0, w1));
            List.range(0, lw) |> List.forEach(x -> {
                let ti = Array.get(x, winner);
                let argb = if (ti < 0) fill
                           else shadePixel(Vector.get(ti, tris), inkTable, mats, time, lights, fog, eye, depthBand,
                                           Array.get(x, w0), Array.get(x, w1));
                Array.put(argb, y * lw + x, out)
            })
        });
        out
    }

    /// 画素ループの外で 1 回だけ計算した値を、そのまま返す。
    // WhyNot: `let x = 式` で直に置かない — Flix 0.78 の最適化は、純粋な let の値がラムダの中で 1 回だけ使われると
    // 式をラムダの中へ書き写すので、三角形の組み立てが行ごとに走る（SoftRaster.onceOutsideLoop と同じ罠）。
    def hoist(rc: Region[r], x: a): a \ r = Ref.get(Ref.fresh(rc, x))

    /// 行 0..n−1 を rowFn で塗る。行どうしは互いの画素を読まないので、Java の並列ストリームでコアの数だけ並べる
    /// （SoftRaster.shadeAll と同じく FGE_SOFT_SERIAL=1 なら 1 本で回す）。
    def forEachRow(n: Int32, rowFn: Int32 -> Unit \ IO): Unit \ IO =
        let serial = System.getenv("FGE_SOFT_SERIAL");
        let range = IntStream.range(0, n);
        let stream = if (not Object.isNull(serial) and serial == "1") range else range.parallel();
        stream.forEach(new IntConsumer {
            def accept(_this: IntConsumer, i: Int32): Unit \ IO = rowFn(i)
        })

    // ── 影の地図 ─────────────────────────────────────────

    /// spots（pickLights の後の並び）のうち shadow が Some の最初の 1 本の地図。mapSize が 0 以下なら影を落とさない。
    def shadowOf(instances: List[Placed], spots: List[Scene3d.SpotLight]): Option[Shadow] \ IO =
        let caster = List.zipWithIndex(spots) |> List.findMap(entry -> {
            let (index, spot) = entry;
            spot#shadow |> Option.filter(sm -> sm#mapSize > 0) |> Option.map(sm -> (index, spot, sm))
        });
        match caster {
            case None => None
            case Some((index, spot, sm)) =>
                let m = Mat4.toColumns(Scene3d.shadowMatrix(spot));
                let rows = Vector.range(0, 16) |> Vector.map(k -> { let row = k / 4; Vector.get((k - row * 4) * 4 + row, m) });
                let size = Int32.min(sm#mapSize, Scene3d.maxShadowMapSize());
                let pcf = Int32.min(sm#pcfRadius, Scene3d.maxShadowPcfRadius());
                Some(Shadow.Shadow(index * 12, rows, size, sm#bias, pcf, sm#strength,
                                   buildShadowMap(instances, spot, size)))
        }

    /// 光から見た n × n の地図（一番近い面の NDC の z × 0.5 + 0.5。何も無い画素は 1。行 0 が NDC の y = −1 側）。
    // WhyNot: 裏の面を捨てない — 薄い板や片面だけの物は、光へ裏を向けていても影を落としてほしい。
    // WhyNot: cutout の材質の α を見ない — 材質を画素ごとに評価すると地図が場面の塗りと同じくらい重くなる。抜いた穴の影は今は埋まる。
    def buildShadowMap(instances: List[Placed], spot: Scene3d.SpotLight, n: Int32): Vector[Float64] \ IO = region rc {
        let cam = Scene3d.shadowCamera(spot);
        let view = Camera3d.viewMatrix(cam);
        let proj = Camera3d.projectionMatrix(cam, 1.0);
        let screen = { w = Int32.toFloat64(n), h = Int32.toFloat64(n), near = cam#near };
        let tris = hoist(rc, instances |> List.flatMap(f -> instanceTris(view, proj, screen, false, f, -1)) |> List.toVector);
        let bins = hoist(rc, binRows(rc, n, tris));
        let noInks: Vector[Ink] = Vector.empty();
        let noMats: Vector[Mat] = Vector.empty();
        let out: Array[Float64, Static] = Array.repeat(Static, n * n, 1.0);
        forEachRow(n, y -> region rr {
            let depth: Array[Float64, rr] = Array.repeat(rr, n, 2.0);
            let winner: Array[Int32, rr] = Array.repeat(rr, n, -1);
            let w0: Array[Float64, rr] = Array.repeat(rr, n, 0.0);
            let w1: Array[Float64, rr] = Array.repeat(rr, n, 0.0);
            let py = Int32.toFloat64(y) + 0.5;
            Vector.get(y, bins) |> List.forEach(ti -> coverRow(n, py, tris, noInks, noMats, 0.0, ti, depth, winner, w0, w1));
            // WhyNot: 画面の行の順（上が行 0）のまま置かない — GL の深度テクスチャは行 0 が NDC の y = −1 側で、向きをそろえる。
            List.range(0, n) |> List.forEach(x -> {
                let z = Array.get(x, depth);
                if (z <= 1.0) Array.put(z * 0.5 + 0.5, (n - 1 - y) * n + x, out) else ()
            })
        });
        Array.toVector(out)
    }

    def inkOf(tex: ShaderEval.TexData, f: Scene3d.BillboardFields): Ink =
        let r = f#regionRect;
        let x0 = Int32.max(0, Int32.min(tex#width - 1, floorInt(r#position#x)));
        let y0 = Int32.max(0, Int32.min(tex#height - 1, floorInt(r#position#y)));
        let x1 = Int32.max(x0 + 1, Int32.min(tex#width, floorInt(r#position#x + r#size#x)));
        let y1 = Int32.max(y0 + 1, Int32.min(tex#height, floorInt(r#position#y + r#size#y)));
        Ink.Ink(tex, x0, y0, x1, y1, f#tint#r, f#tint#g, f#tint#b, f#lit)

    // ── 三角形を組む ─────────────────────────────────────

    type alias Screen = { w = Float64, h = Float64, near = Float64 }

    /// clip の段の頂点（stride() 個）。w は目の座標の −z（Mat4.perspective の 4 行目が (0, 0, −1, 0)）。
    // WhyNot: proj × view の 1 本の行列で w を出さない — Mat4 は閉じた型で 4 行目を読めず、apply は w を返さない。
    def clipVertex(view: Mat4.Mat4, proj: Mat4.Mat4, p: Vec3.Vec3, n: Vec3.Vec3,
                   a0: Float64, a1: Float64, a2: Float64): Vector[Float64] =
        let e = Mat4.apply(view, p);
        let c = Mat4.apply(proj, e);
        Vector#{ c#x, c#y, c#z, 0.0 - e#z, p#x, p#y, p#z, n#x, n#y, n#z, a0, a1, a2 }

    /// 置いた物 placed の三角形（頂点は placedOf で曲げた後の物）。mat = 材質の番号（−1 なら頂点の色 × tint を色の欄に、それ以外は tint だけを入れる）。
    /// cull が真なら裏の三角形を捨てる。
    def instanceTris(view: Mat4.Mat4, proj: Mat4.Mat4, screen: Screen, cull: Bool, placed: Placed, mat: Int32): List[Tri] =
        let f = placed#fields;
        let world = f#world;
        let nm = Mat4.normalMatrix(world);
        let cs = Mesh3d.colors(f#mesh);
        let colorAt = (k: Int32, channel: Int32) -> if (mat < 0) Vector.get(k * 3 + channel, cs) else 1.0;
        let vertices = List.range(0, Mesh3d.vertexCount(f#mesh)) |> List.map(k ->
            clipVertex(view, proj, Mat4.apply(world, vec3At(placed#positions, k)), Vec3.normalized(Mat4.applyDir(nm, vec3At(placed#normals, k))),
                       colorAt(k, 0) * f#tint#r, colorAt(k, 1) * f#tint#g, colorAt(k, 2) * f#tint#b))
            |> List.toVector;
        let idx = Mesh3d.indices(f#mesh);
        List.range(0, Vector.length(idx) / 3) |> List.flatMap(t ->
            screenTris(screen, cull, -1, mat,
                       Vector.get(Vector.get(t * 3, idx), vertices) ::
                       Vector.get(Vector.get(t * 3 + 1, idx), vertices) ::
                       Vector.get(Vector.get(t * 3 + 2, idx), vertices) :: Nil))

    /// ビルボード 1 枚の三角形 2 枚。四角はカメラの right / up に沿って立て、anchor の点を position に合わせる。
    /// uv の欄には絵の px（region の中）を入れる。
    // WhyNot: 裏を捨てない — 四角はいつもカメラへ向くので、裏になるのは size が負の時だけで、それは左右・上下の反転として描く。
    def billboardTris(view: Mat4.Mat4, proj: Mat4.Mat4, screen: Screen, cam: Camera3d.Camera3d,
                      index: Int32, f: Scene3d.BillboardFields): List[Tri] =
        let right = Camera3d.right(cam);
        let up = Camera3d.up(cam);
        let facing = Vec3.mul(Camera3d.forward(cam), -1.0);
        let r = f#regionRect;
        let corner = (u: Float64, v: Float64) -> {
            let p = Vec3.add(f#position, Vec3.add(Vec3.mul(right, (u - f#anchor#x) * f#size#x),
                                                  Vec3.mul(up, (f#anchor#y - v) * f#size#y)));
            clipVertex(view, proj, p, facing, r#position#x + u * r#size#x, r#position#y + v * r#size#y, 0.0)
        };
        let tl = corner(0.0, 0.0);
        let tr = corner(1.0, 0.0);
        let br = corner(1.0, 1.0);
        let bl = corner(0.0, 1.0);
        List.append(screenTris(screen, false, index, -1, tl :: tr :: br :: Nil),
                    screenTris(screen, false, index, -1, tl :: br :: bl :: Nil))

    /// clip の段の三角形を near で切り、扇に割って画面へ写す。cull が真なら画面で反時計回り（裏）の物を捨てる。
    def screenTris(screen: Screen, cull: Bool, ink: Int32, mat: Int32, tri: List[Vector[Float64]]): List[Tri] =
        match List.map(projectVertex(screen), clipNear(screen#near, tri)) {
            case v0 :: rest =>
                List.zip(rest, List.drop(1, rest)) |> List.filterMap(pair -> {
                    let (v1, v2) = pair;
                    let area = signedArea(v0, v1, v2);
                    if (Float64.abs(area) < 1.0e-12 or (cull and area < 0.0)) None
                    else Some(Tri.Tri(Vector.append(v0, Vector.append(v1, v2)), area, ink, mat))
                })
            case Nil => Nil
        }

    /// 画面（y は下へ）で頂点が時計回りなら正。
    def signedArea(a: Vector[Float64], b: Vector[Float64], c: Vector[Float64]): Float64 =
        let ax = Vector.get(0, a);
        let ay = Vector.get(1, a);
        (Vector.get(0, b) - ax) * (Vector.get(1, c) - ay) - (Vector.get(0, c) - ax) * (Vector.get(1, b) - ay)

    /// 多角形を w ≥ near の側だけ残して切る（Sutherland–Hodgman。欄は全部 clip 空間でまっすぐつなぐ）。
    def clipNear(near: Float64, poly: List[Vector[Float64]]): List[Vector[Float64]] =
        let inside = (v: Vector[Float64]) -> Vector.get(3, v) >= near;
        let next = List.append(List.drop(1, poly), List.take(1, poly));
        List.zip(poly, next) |> List.flatMap(edge -> {
            let (a, b) = edge;
            let cut = _ -> {
                let wa = Vector.get(3, a);
                let wb = Vector.get(3, b);
                let t = (near - wa) / (wb - wa);
                Vector.zipWith((x, y) -> x + (y - x) * t, a, b)
            };
            match (inside(a), inside(b)) {
                case (true, true)   => b :: Nil
                case (true, false)  => cut(()) :: Nil
                case (false, true)  => cut(()) :: b :: Nil
                case (false, false) => Nil
            }
        })

    /// clip の段の頂点を画面の段へ（先頭 4 つを 画面 x, y・NDC の z・1 / w に替える）。
    def projectVertex(screen: Screen, v: Vector[Float64]): Vector[Float64] =
        let invW = 1.0 / Vector.get(3, v);
        let sx = (Vector.get(0, v) * invW + 1.0) / 2.0 * screen#w;
        let sy = (1.0 - Vector.get(1, v) * invW) / 2.0 * screen#h;
        let sz = Vector.get(2, v) * invW;
        Vector.mapWithIndex((i, x) -> if (i == 0) sx else if (i == 1) sy else if (i == 2) sz else if (i == 3) invW else x, v)

    /// 行ごとに、その行の画素の中心を通る三角形の番号（番号の小さい順）。
    def binRows(rc: Region[r], lh: Int32, tris: Vector[Tri]): Vector[List[Int32]] \ r =
        let bins: Array[List[Int32], r] = Array.repeat(rc, lh, Nil);
        // 後ろの三角形から先頭へ積むので、各行の並びは番号の小さい順になる（同じ深さなら先に渡した物が勝つ）。
        List.range(0, Vector.length(tris)) |> List.reverse |> List.forEach(ti -> {
            let Tri.Tri(v, _, _, _) = Vector.get(ti, tris);
            let s = stride();
            let ys = Vector.get(1, v) :: Vector.get(1 + s, v) :: Vector.get(1 + s * 2, v) :: Nil;
            let lo = Int32.max(0, ceilInt(List.foldLeft(Float64.min, 1.0e18, ys) - 0.5));
            let hi = Int32.min(lh - 1, floorInt(List.foldLeft(Float64.max, -1.0e18, ys) - 0.5));
            List.range(lo, hi + 1) |> List.forEach(y -> Array.put(ti :: Array.get(y, bins), y, bins))
        });
        Array.toVector(bins)

    // ── 塗る ─────────────────────────────────────────────

    /// 三角形 ti が行 py（画素の中心の y）で覆う画素の奥行きを比べ、手前なら番号と重み（画面の段の λ0・λ1）を残す。
    /// ビルボードの α の抜きと cutout の材質の α の抜きは、深度を書く前に行う（抜いた画素の奥の物が見える）。
    def coverRow(lw: Int32, py: Float64, tris: Vector[Tri], inks: Vector[Ink], mats: Vector[Mat], time: Float64, ti: Int32,
                 depth: Array[Float64, r], winner: Array[Int32, r],
                 w0: Array[Float64, r], w1: Array[Float64, r]): Unit \ r =
        let Tri.Tri(v, area, ink, mat) = Vector.get(ti, tris);
        let s = stride();
        let (x0, y0, z0, q0) = (Vector.get(0, v), Vector.get(1, v), Vector.get(2, v), Vector.get(3, v));
        let (x1, y1, z1, q1) = (Vector.get(s, v), Vector.get(s + 1, v), Vector.get(s + 2, v), Vector.get(s + 3, v));
        let (x2, y2, z2, q2) = (Vector.get(s * 2, v), Vector.get(s * 2 + 1, v), Vector.get(s * 2 + 2, v), Vector.get(s * 2 + 3, v));
        let lo = Int32.max(0, ceilInt(Float64.min(x0, Float64.min(x1, x2)) - 0.5));
        let hi = Int32.min(lw - 1, floorInt(Float64.max(x0, Float64.max(x1, x2)) - 0.5));
        def loop(x: Int32): Unit \ r =
            if (x > hi) ()
            else {
                let px = Int32.toFloat64(x) + 0.5;
                let l0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) / area;
                let l1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) / area;
                let l2 = 1.0 - l0 - l1;
                let z = l0 * z0 + l1 * z1 + l2 * z2;
                let covered = l0 >= 0.0 and l1 >= 0.0 and l2 >= 0.0 and z >= -1.0 and z <= 1.0 and z < Array.get(x, depth);
                let keep = covered and (ink < 0 or {
                    let (u, uv) = perspectiveUv(v, l0, l1, l2, q0, q1, q2);
                    alphaOf(sampleInk(Vector.get(ink, inks), u, uv)) >= billboardCutoff()
                }) and (mat < 0 or not isCutAway(Vector.get(mat, mats), time, v, perspectiveWeights(l0, l1, l2, q0, q1, q2)));
                if (keep) {
                    Array.put(z, x, depth);
                    Array.put(ti, x, winner);
                    Array.put(l0, x, w0);
                    Array.put(l1, x, w1)
                } else ();
                loop(x + 1)
            };
        loop(lo)

    /// 画面の段の重み λ を、奥行きで補正した重み b へ（b_i = λ_i / w_i ÷ Σ λ_j / w_j）。和の逆数（目からの奥行き）も返す。
    def perspectiveWeights(l0: Float64, l1: Float64, l2: Float64, q0: Float64, q1: Float64, q2: Float64): (Float64, Float64, Float64, Float64) =
        let a = l0 * q0;
        let b = l1 * q1;
        let c = l2 * q2;
        let sum = a + b + c;
        if (sum <= 0.0) (l0, l1, l2, 0.0) else (a / sum, b / sum, c / sum, 1.0 / sum)

    /// 頂点の欄 k を奥行きで補正して補間する。
    def attr(v: Vector[Float64], k: Int32, b0: Float64, b1: Float64, b2: Float64): Float64 =
        let s = stride();
        b0 * Vector.get(k, v) + b1 * Vector.get(s + k, v) + b2 * Vector.get(s * 2 + k, v)

    /// 奥行きで補正した重み（perspectiveWeights の値）での world の点。
    def worldAt(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): Vec3.Vec3 =
        let (b0, b1, b2, _) = weights;
        Vec3.v3(attr(v, 4, b0, b1, b2), attr(v, 5, b0, b1, b2), attr(v, 6, b0, b1, b2))

    /// 奥行きで補正した重みでの法線（長さ 1 にそろえる）。
    def normalAt(v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): Vec3.Vec3 =
        let (b0, b1, b2, _) = weights;
        Vec3.normalized(Vec3.v3(attr(v, 7, b0, b1, b2), attr(v, 8, b0, b1, b2), attr(v, 9, b0, b1, b2)))

    /// cutout の材質 m で、この画素の α が materialCutoff() 未満か（cutout でない材質は捨てない）。
    def isCutAway(m: Mat, time: Float64, v: Vector[Float64], weights: (Float64, Float64, Float64, Float64)): Bool =
        let Mat.Mat(compiled, cutout) = m;
        cutout and ShaderEval.evalMaterial3(compiled, worldAt(v, weights), normalAt(v, weights), time)#alpha < materialCutoff()

    def perspectiveUv(v: Vector[Float64], l0: Float64, l1: Float64, l2: Float64,
                      q0: Float64, q1: Float64, q2: Float64): (Float64, Float64) =
        let (b0, b1, b2, _) = perspectiveWeights(l0, l1, l2, q0, q1, q2);
        (attr(v, 10, b0, b1, b2), attr(v, 11, b0, b1, b2))

    def sampleInk(ink: Ink, u: Float64, v: Float64): Int32 =
        let Ink.Ink(tex, x0, y0, x1, y1, _, _, _, _) = ink;
        let ix = Int32.max(x0, Int32.min(x1 - 1, floorInt(u)));
        let iy = Int32.max(y0, Int32.min(y1 - 1, floorInt(v)));
        Vector.get(iy * tex#width + ix, tex#pixels)

    def alphaOf(argb: Int32): Float64 = Int32.toFloat64(SoftRaster.channelOf(24, argb)) / 255.0

    def channel01(shift: Int32, argb: Int32): Float64 = Int32.toFloat64(SoftRaster.channelOf(shift, argb)) / 255.0

    /// 勝った三角形の画素の色（ARGB・不透明）。
    def shadePixel(tri: Tri, inks: Vector[Ink], mats: Vector[Mat], time: Float64, lights: Lights, fog: Fog,
                   eye: (Float64, Float64, Float64), depthBand: Option[(Float64, Float64)], l0: Float64, l1: Float64): Int32 =
        let Tri.Tri(v, _, ink, mat) = tri;
        let s = stride();
        let weights = perspectiveWeights(l0, l1, 1.0 - l0 - l1, Vector.get(3, v), Vector.get(s + 3, v), Vector.get(s * 2 + 3, v));
        let (b0, b1, b2, _) = weights;
        let (px, py, pz) = (attr(v, 4, b0, b1, b2), attr(v, 5, b0, b1, b2), attr(v, 6, b0, b1, b2));
        let (ex, ey, ez) = eye;
        match depthBand {
            case Some((near, range)) =>
                let (dx, dy, dz) = (px - ex, py - ey, pz - ez);
                let gray = clamp01((Vec2.sqrt(dx * dx + dy * dy + dz * dz) - near) / Float64.max(range, 1.0e-6));
                SoftRaster.argbOfRgba(gray, gray, gray, 1.0)
            case None =>
                let n = normalAt(v, weights);
                let (a0, a1, a2) = (attr(v, 10, b0, b1, b2), attr(v, 11, b0, b1, b2), attr(v, 12, b0, b1, b2));
                let litFogged = (base: (Float64, Float64, Float64)) -> {
                    let (br, bg, bb) = base;
                    let (lr, lg, lb) = evalLight(lights, px, py, pz, n#x, n#y, n#z);
                    applyFog(fog, ex, ey, ez, px, py, pz, br * lr, bg * lg, bb * lb)
                };
                let (r, g, b) =
                    if (ink >= 0) inkColor(Vector.get(ink, inks), a0, a1, litFogged)
                    else if (mat < 0) litFogged((a0, a1, a2))
                    else materialColor(Vector.get(mat, mats), time, Vec3.v3(px, py, pz), n, (a0, a1, a2), litFogged);
                SoftRaster.argbOfRgba(r, g, b, 1.0)
        }

    /// ビルボードの絵の (u, v) の色に tint を掛け、lit なら光とかすみを当てる。
    def inkColor(ink: Ink, u: Float64, v: Float64,
                 litFogged: ((Float64, Float64, Float64)) -> (Float64, Float64, Float64)): (Float64, Float64, Float64) =
        let Ink.Ink(_, _, _, _, _, tr, tg, tb, isLit) = ink;
        let texel = sampleInk(ink, u, v);
        let base = (channel01(16, texel) * tr, channel01(8, texel) * tg, channel01(0, texel) * tb);
        if (isLit) litFogged(base) else base

    /// 材質の色: albedo × tint に光とかすみを当ててから emission を足す（GL の Render3d と同じ順）。
    // WhyNot: emission にかすみを掛けない — 自分で光る物（溶岩・目）は遠くでもかすみに沈まずに見えてほしい。
    def materialColor(m: Mat, time: Float64, world: Vec3.Vec3, normal: Vec3.Vec3, tint: (Float64, Float64, Float64),
                      litFogged: ((Float64, Float64, Float64)) -> (Float64, Float64, Float64)): (Float64, Float64, Float64) =
        let Mat.Mat(compiled, _) = m;
        let sample = ShaderEval.evalMaterial3(compiled, world, normal, time);
        let (tr, tg, tb) = tint;
        let (r, g, b) = litFogged((sample#albedo#r * tr, sample#albedo#g * tg, sample#albedo#b * tb));
        (r + sample#emission#r, g + sample#emission#g, b + sample#emission#b)

    // ── 数の小物 ─────────────────────────────────────────

    def clampForInt(x: Float64): Float64 = Float64.max(-1.0e9, Float64.min(1.0e9, x))

    def floorInt(x: Float64): Int32 = Float64.tryToInt32(Float64.floor(clampForInt(x))) |> Option.getWithDefault(0)

    def ceilInt(x: Float64): Int32 = Float64.tryToInt32(Float64.ceil(clampForInt(x))) |> Option.getWithDefault(0)

    def roundInt(x: Float64): Int32 = floorInt(x + 0.5)
}
