// SoftRaster3d.Internal — CPU の 3D の描き手の部品。環境マップ（周りの景色のパノラマ）を向きで読む所と、骨で曲げる頂点・頂点の並びの読み書き。SoftRaster3d の中身。
// ゲームからは呼ばない。

/// 環境マップの読み。式は LightModel3d の頭の説明（向きは LightModel3d.environmentDirection の木から作る SoftRaster3dLight.environmentDirectionAt）。
/// GL の Render3dGlsl.environmentSource と同じ式・同じ段・同じ補間で読む。
pub mod SoftRaster3d.Internal {

    /// 絵の段の列。Srgb = 8bit の sRGB の絵の段（読んだ値を線形の量へ戻す）・Linear = half の絵の段（線形の量のまま・1 を超える）。
    pub enum MipChain {
        case Srgb(Vector[ShaderEval.TexData])
        case Linear(Vector[ShaderEval.HdrTexture])
    }

    /// 場面の環境マップ。chain = 絵の段の列（段 0 が元の絵）・intensity = Scene3d.environmentIntensityOf・box = 箱の補正（Scene3d.environmentBoxOf で軸ごとに min < max にそろえた物）。
    pub type alias EnvironmentLookup = { chain = MipChain, intensity = Float64, box = Option[Scene3d.EnvironmentBox] }

    /// 場面 scene の環境マップ（無ければ None）。textures = 場面が読む 8bit の絵の段の列・halves = half の絵の段（halfChainsOf）。絵が無ければ透明な黒で読む（GL の代わりの絵と同じ）。
    pub def environmentLookupOf(textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], halves: Map[String, Vector[ShaderEval.HdrTexture]],
                                scene: Scene3d.Scene3dCmd): Option[EnvironmentLookup] =
        scene#environmentMap |> Option.map(e -> {
            let f = Scene3d.environmentMapFieldsOf(e);
            let key = (f#texture, Texture3d.mipSpaceOf(Texture3d.TextureUse.MaterialTexture));
            let chain = match Map.get(f#texture, halves) {
                case Some(hdr) => MipChain.Linear(hdr)
                case None      => MipChain.Srgb(Map.getWithDefault(key, Vector#{ { width = 1, height = 1, pixels = Vector#{ 0 } } }, textures))
            };
            { chain = chain, intensity = Scene3d.environmentIntensityOf(e), box = f#box |> Option.map(Scene3d.environmentBoxOf) }
        })

    /// 場面の textures の half の絵の名前 → 段の列（Mip.buildRgba16Float）。場面を描く時に 1 回作り、環境マップと lightmap が名前で引く。
    // WhyNot: 置いた物ごとに段を作らない — lightmap の絵は何百もの物が分け合い、2048² の段づくりは 1 回 40 ms ほどかかる。
    pub def halfChainsOf(scene: Scene3d.Scene3dCmd): Map[String, Vector[ShaderEval.HdrTexture]] =
        scene#textures |> List.filterMap(t -> match Texture3d.sourceOf(t) {
            case Texture3d.Source.Rgba16Float(halves) =>
                Some((Texture3d.name(t), Mip.buildRgba16Float(Texture3d.width(t), Texture3d.height(t), halves)
                    |> List.map(level -> { let (w, h, bits) = level; ShaderEval.hdrTextureOfHalves(w, h, Vector.map(b -> RenderUtil.f32(Texture3d.Internal.fromHalfBits(b)), bits)) })
                    |> List.toVector))
            case _ => None
        }) |> List.toMap

    /// lightmap の段の列 chain を、2 本目の uv uv（横隣 nextX・縦隣 nextY）に矩形 rect を当てた座標で読んだ rgb（8bit の絵は読んだ値のまま・half の絵は線形の量）。
    /// 段は Mip.lodOf（段の数は maxLevels まで）・Clamp・Linear。読む uv = uv2 × rect の大きさ + rect の位置（微分も同じ座標で取る）。
    pub def lightmapRgbAt(chain: MipChain, maxLevels: Int32, rect: Rect2.Rect2, uv: (Float64, Float64), nextX: (Float64, Float64), nextY: (Float64, Float64)): (Float64, Float64, Float64) =
        let place = (p: (Float64, Float64)) -> { let (a, b) = p; (a * rect#size#x + rect#position#x, b * rect#size#y + rect#position#y) };
        let ((u, v), (xu, xv), (yu, yv)) = (place(uv), place(nextX), place(nextY));
        let levels = Int32.min(mipLevelsOf(chain), maxLevels);
        let (w, h) = match chain {
            case MipChain.Srgb(ls)   => Vector.head(ls) |> Option.map(b -> (b#width, b#height)) |> Option.getWithDefault((1, 1))
            case MipChain.Linear(ls) => Vector.head(ls) |> Option.map(b -> (ShaderEval.hdrWidthOf(b), ShaderEval.hdrHeightOf(b))) |> Option.getWithDefault((1, 1))
        };
        let lod = Mip.lodOf({ dudx = xu - u, dvdx = xv - v, dudy = yu - u, dvdy = yv - v }, w, h, levels);
        let sampling = { linear = true, repeat = false };
        match chain {
            case MipChain.Srgb(ls)   => ShaderEval.sampleMipRgb(ls, sampling, lod, u, v)
            case MipChain.Linear(ls) => ShaderEval.sampleMipRgbHdr(ls, sampling, lod, u, v)
        }

    /// 段の列の段の数。
    pub def mipLevelsOf(chain: MipChain): Int32 = match chain {
        case MipChain.Srgb(levels)   => Vector.length(levels)
        case MipChain.Linear(levels) => Vector.length(levels)
    }

    /// 段の列を lod・uv (u, v) で読んだ線形の量の rgb（8bit の絵は sRGB から戻す）。
    pub def sampleLinearRgb(chain: MipChain, sampling: { linear = Bool, repeat = Bool }, lod: Float64, u: Float64, v: Float64): (Float64, Float64, Float64) =
        match chain {
            case MipChain.Srgb(levels) =>
                let (r, g, b) = ShaderEval.sampleMipRgb(levels, sampling, lod, u, v);
                (Texture3d.srgbToLinear(r), Texture3d.srgbToLinear(g), Texture3d.srgbToLinear(b))
            case MipChain.Linear(levels) => ShaderEval.sampleMipRgbHdr(levels, sampling, lod, u, v)
        }

    /// 層の画素 (x, y)（層の大きさ (lw, lh)）の、景色を背景に描く時の色（Scene3d.backgroundEnvironmentOf）と α。Output.Depth なら白（一番奥）。
    /// 向きは画素の真ん中の NDC を通る向き（Scene3d.skyDirectionOf）・絵は段 0 の Repeat・Linear・強さを線形に掛けて画面の値へ戻す。GL は skyFragmentSource の uEnvOn。
    pub def environmentBackgroundAt(env: EnvironmentLookup, basis: Scene3d.SkyBasis, isDepth: Bool, layer: (Int32, Int32), pixel: (Int32, Int32)): (Float64, Float64, Float64, Float64) =
        if (isDepth) (1.0, 1.0, 1.0, 1.0)
        else {
            let (lw, lh) = layer;
            let (x, y) = pixel;
            let ndc = { x = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(lw) * 2.0 - 1.0, y = 1.0 - (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(lh) * 2.0 };
            let (u, v) = LightModel3d.environmentUvOf(Scene3d.skyDirectionOf(basis, ndc));
            let (r, g, b) = sampleLinearRgb(env#chain, { linear = true, repeat = true }, 0.0, u, v);
            let screen = (c: Float64) -> Texture3d.linearToSrgb(c * env#intensity);
            (screen(r), screen(g), screen(b), 1.0)
        }

    /// 点 p・法線 n・albedo × tint の色 base・目 eye の面（metallic・roughness）が映す環境マップの色（線形の量・強さを掛けた後）。
    /// 絵は向き → 座標（LightModel3d.environmentUvOf）で、段は LightModel3d.environmentLodOf で選び、Repeat・Linear で読む。
    pub def environmentColorAt(env: EnvironmentLookup, p: (Float64, Float64, Float64), n: (Float64, Float64, Float64), base: (Float64, Float64, Float64),
                               surface: (Float64, Float64), eye: (Float64, Float64, Float64)): (Float64, Float64, Float64) =
        let (px, py, pz) = p;
        let (nx, ny, nz) = n;
        let (bx, by, bz) = base;
        let (metallic, roughness) = surface;
        let (ex, ey, ez) = eye;
        let zero = Vec3.v3(0.0, 0.0, 0.0);
        let box = env#box |> Option.getWithDefault({ min = zero, max = zero, center = zero });
        let (dx, dy, dz) = SoftRaster3dLight.environmentDirectionAt(px, py, pz, nx, ny, nz, bx, by, bz, metallic, roughness, 0.0, ex, ey, ez,
                                                                   box#min#x, box#min#y, box#min#z, box#max#x, box#max#y, box#max#z,
                                                                   box#center#x, box#center#y, box#center#z, if (Option.isEmpty(env#box)) 0.0 else 1.0);
        let (u, v) = LightModel3d.environmentUvOf(Vec3.v3(dx, dy, dz));
        let lod = LightModel3d.environmentLodOf(roughness, mipLevelsOf(env#chain));
        let (r, g, b) = sampleLinearRgb(env#chain, { linear = true, repeat = true }, lod, u, v);
        (r * env#intensity, g * env#intensity, b * env#intensity)

    /// NDC の x か y（−1..1）が落ちる地図の画素（0..n−1）。
    pub def mapTexel(n: Int32, ndc: Float64): Int32 =
        Int32.max(0, Int32.min(n - 1, floorInt((ndc * 0.5 + 0.5) * Int32.toFloat64(n))))

    /// 左下 (x0, y0) から side × side の地図の画素のうち、depth が地図の値以下の画素の数（地図の外は端の画素を読む）。
    pub def countLit(map: Vector[Float64], n: Int32, x0: Int32, y0: Int32, side: Int32, depth: Float64, k: Int32, acc: Int32): Int32 =
        if (k >= side * side) acc
        else {
            let x = Int32.max(0, Int32.min(n - 1, x0 + (k - (k / side) * side)));
            let y = Int32.max(0, Int32.min(n - 1, y0 + k / side));
            countLit(map, n, x0, y0, side, depth, k + 1, if (depth <= Vector.get(y * n + x, map)) acc + 1 else acc)
        }

    /// m の左上 3×3 の行列式（負なら鏡写しにする行列）。
    pub def linearDeterminant(m: Mat4.Mat4): Float64 =
        let c = Mat4.toColumns(m);
        let col = (j: Int32) -> Vec3.v3(Vector.get(j * 4, c), Vector.get(j * 4 + 1, c), Vector.get(j * 4 + 2, c));
        Vec3.dot(col(0), Vec3.cross(col(1), col(2)))

    /// 画面（y は下へ）で頂点が時計回りなら正。
    pub def signedArea(a: Vector[Float64], b: Vector[Float64], c: Vector[Float64]): Float64 =
        let ax = Vector.get(0, a);
        let ay = Vector.get(1, a);
        (Vector.get(0, b) - ax) * (Vector.get(1, c) - ay) - (Vector.get(0, c) - ax) * (Vector.get(1, b) - ay)

    /// 画面の段の重み λ を、奥行きで補正した重み b へ（b_i = λ_i / w_i ÷ Σ λ_j / w_j）。和の逆数（目からの奥行き）も返す。
    pub def perspectiveWeights(l0: Float64, l1: Float64, l2: Float64, q0: Float64, q1: Float64, q2: Float64): (Float64, Float64, Float64, Float64) =
        let a = l0 * q0;
        let b = l1 * q1;
        let c = l2 * q2;
        let sum = a + b + c;
        if (sum <= 0.0) (l0, l1, l2, 0.0) else (a / sum, b / sum, c / sum, 1.0 / sum)

    pub def clampForInt(x: Float64): Float64 = Float64.max(-1.0e9, Float64.min(1.0e9, x))

    pub def floorInt(x: Float64): Int32 = Float64.tryToInt32(Float64.floor(clampForInt(x))) |> Option.getWithDefault(0)

    pub def ceilInt(x: Float64): Int32 = Float64.tryToInt32(Float64.ceil(clampForInt(x))) |> Option.getWithDefault(0)

    pub def roundInt(x: Float64): Int32 = floorInt(x + 0.5)

    /// 層の画素 (x, y) の空の色（sky が None なら None・Output.Depth なら白）。向きは画素の真ん中の NDC を通る向き（Scene3d.skyDirectionOf）。
    pub def skyFill(sky:Option[(SkyColors, Scene3d.SkyBasis)], lut: Texture3d.ColorLut, isDepth: Bool, layer: (Int32, Int32), pixel: (Int32, Int32)): Option[(Float64, Float64, Float64, Float64)] =
        let (lw, lh) = layer;
        let (x, y) = pixel;
        sky |> Option.map(sb -> {
            let (colors, basis) = sb;
            if (isDepth) (1.0, 1.0, 1.0, 1.0)
            else {
                let ndc = { x = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(lw) * 2.0 - 1.0,
                            y = 1.0 - (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(lh) * 2.0 };
                let (r, g, b) = SoftRaster3d.toSrgbColor(lut, skyColorWith(colors, Scene3d.skyDirectionOf(basis, ndc)));
                (r, g, b, 1.0)
            }
        })

    pub enum SkyColors { case SkyColors(Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64, Float64) }

    /// 3 色を線形の量へ戻して並べる（空は線形の量の中で混ぜる）。
    pub def linearSkyColorsOf(s: Scene3d.Sky3d): SkyColors = skyColorsWith(Texture3d.srgbToLinearColor, s)

    /// 3 色を convert に通して並べる。
    pub def skyColorsWith(convert: Color -> Color, s: Scene3d.Sky3d): SkyColors =
        let f = Scene3d.skyFieldsOf(s);
        let (zenith, horizon, ground) = (convert(f#zenith), convert(f#horizon), convert(f#ground));
        SkyColors.SkyColors(zenith#r, zenith#g, zenith#b, horizon#r, horizon#g, horizon#b,
                            ground#r, ground#g, ground#b, Scene3d.skyCurveOf(s))

    /// 材質の映り込みに使う空の 3 色（線形の量）。場面に空が無ければ ambient + hemisphere の色（LightModel3d.reflectionSkyOf）。
    pub def reflectionColorsOf(scene: Scene3d.Scene3dCmd): SkyColors =
        let r = LightModel3d.reflectionSkyOf(scene);
        SkyColors.SkyColors(r#zenith#r, r#zenith#g, r#zenith#b, r#horizon#r, r#horizon#g, r#horizon#b, r#ground#r, r#ground#g, r#ground#b, r#curve)

    /// 目から見た向き dir（長さ 1）の空の色（LightModel3d.skyModel）。
    pub def skyColorWith(colors: SkyColors, dir: Vec3.Vec3): (Float64, Float64, Float64) =
        let SkyColors.SkyColors(zr, zg, zb, hr, hg, hb, gr, gg, gb, curve) = colors;
        SoftRaster3dLight.skyAt(dir#x, dir#y, dir#z, zr, zg, zb, hr, hg, hb, gr, gg, gb, curve)

    /// 形 mesh の頂点を、頂点ごとの 4 つのジョイント（joints の番号・weights の重み。頂点 k は [4k, 4k + 4)）で曲げた位置と法線とタンジェント。
    // WhyNot: 重み 0 の欄を飛ばす — 足しても値が変わらず、多くの頂点は 1〜2 本しか使わない。
    pub def bendVertices(matrices: Vector[Mat4.Mat4], joints: Vector[Int32], weights: Vector[Float64],
                         mesh: Mesh3d.Mesh3d): (Vector[Float64], Vector[Float64], Option[Vector[Float64]]) =
        let blendAt = (move: (Mat4.Mat4, Vec3.Vec3) -> Vec3.Vec3, v: Vec3.Vec3, k: Int32) ->
            List.range(k * 4, k * 4 + 4) |> List.foldLeft((acc, s) -> {
                let w = Vector.get(s, weights);
                if (w == 0.0) acc else Vec3.add(acc, Vec3.mul(move(Vector.get(Vector.get(s, joints), matrices), v), w))
            }, Vec3.zero());
        let ps = Mesh3d.positions(mesh);
        let ns = Mesh3d.normals(mesh);
        let bent = Vector.range(0, Mesh3d.vertexCount(mesh)) |> Vector.map(k ->
            (blendAt(Mat4.apply, vec3At(ps, k), k), blendAt(Mat4.applyDir, vec3At(ns, k), k)));
        let tangents = Mesh3d.tangents(mesh) |> Option.map(ts -> Vector.range(0, Mesh3d.vertexCount(mesh)) |> Vector.flatMap(k -> {
            let (xyz, w) = vec4At(ts, k);
            let moved = blendAt(Mat4.applyDir, xyz, k);
            Vector#{ moved#x, moved#y, moved#z, w }
        }));
        (Vector.flatMap(pair -> xyzOf(fst(pair)), bent), Vector.flatMap(pair -> xyzOf(snd(pair)), bent), tangents)

    /// 頂点ごとに 3 つ並んだ v の k 番目の頂点。
    pub def vec3At(v: Vector[Float64], k: Int32): Vec3.Vec3 =
        Vec3.v3(Vector.get(k * 3, v), Vector.get(k * 3 + 1, v), Vector.get(k * 3 + 2, v))

    pub def xyzOf(v: Vec3.Vec3): Vector[Float64] = Vector#{ v#x, v#y, v#z }

    /// 頂点ごとに 4 つ並んだ v の k 番目の頂点（xyz と w）。
    pub def vec4At(v: Vector[Float64], k: Int32): (Vec3.Vec3, Float64) =
        (Vec3.v3(Vector.get(k * 4, v), Vector.get(k * 4 + 1, v), Vector.get(k * 4 + 2, v)), Vector.get(k * 4 + 3, v))
}
