// SoftRaster3d.Internal — CPU の 3D の描き手の部品。環境マップ（周りの景色のパノラマ）を向きで読む所。SoftRaster3d の中身。
// ゲームからは呼ばない。

/// 環境マップの読み。式は LightModel3d の頭の説明（向きは LightModel3d.environmentDirection の木から作る SoftRaster3dLight.environmentDirectionAt）。
/// GL の Render3dGlsl.environmentSource と同じ式・同じ段・同じ補間で読む。
pub mod SoftRaster3d.Internal {

    /// 場面の環境マップ。chain = 絵の段の列（段 0 が元の絵）・intensity = Scene3d.environmentIntensityOf・box = 箱の補正（Scene3d.environmentBoxOf で軸ごとに min < max にそろえた物）。
    pub type alias EnvironmentLookup = { chain = Vector[ShaderEval.TexData], intensity = Float64, box = Option[Scene3d.EnvironmentBox] }

    /// 場面 scene の環境マップ（無ければ None）。textures = 場面が読む絵の段の列。絵が無ければ透明な黒で読む（GL の代わりの絵と同じ）。
    pub def environmentLookupOf(textures: Map[(String, Texture3d.ColorSpace), Vector[ShaderEval.TexData]], scene: Scene3d.Scene3dCmd): Option[EnvironmentLookup] =
        scene#environmentMap |> Option.map(e -> {
            let f = Scene3d.environmentMapFieldsOf(e);
            let key = (f#texture, Texture3d.mipSpaceOf(Texture3d.TextureUse.MaterialTexture));
            { chain = Map.getWithDefault(key, Vector#{ { width = 1, height = 1, pixels = Vector#{ 0 } } }, textures),
              intensity = Scene3d.environmentIntensityOf(e), box = f#box |> Option.map(Scene3d.environmentBoxOf) }
        })

    /// 層の画素 (x, y)（層の大きさ (lw, lh)）の、景色を背景に描く時の色（Scene3d.backgroundEnvironmentOf）と α。Output.Depth なら白（一番奥）。
    /// 向きは画素の真ん中の NDC を通る向き（Scene3d.skyDirectionOf）・絵は段 0 の Repeat・Linear・強さを線形に掛けて画面の値へ戻す。GL は skyFragmentSource の uEnvOn。
    pub def environmentBackgroundAt(env: EnvironmentLookup, basis: Scene3d.SkyBasis, isDepth: Bool, layer: (Int32, Int32), pixel: (Int32, Int32)): (Float64, Float64, Float64, Float64) =
        if (isDepth) (1.0, 1.0, 1.0, 1.0)
        else {
            let (lw, lh) = layer;
            let (x, y) = pixel;
            let ndc = { x = (Int32.toFloat64(x) + 0.5) / Int32.toFloat64(lw) * 2.0 - 1.0, y = 1.0 - (Int32.toFloat64(y) + 0.5) / Int32.toFloat64(lh) * 2.0 };
            let (u, v) = LightModel3d.environmentUvOf(Scene3d.skyDirectionOf(basis, ndc));
            let (r, g, b) = ShaderEval.sampleMipRgb(env#chain, { linear = true, repeat = true }, 0.0, u, v);
            let screen = (c: Float64) -> Texture3d.linearToSrgb(Texture3d.srgbToLinear(c) * env#intensity);
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
        let lod = LightModel3d.environmentLodOf(roughness, Vector.length(env#chain));
        let (r, g, b) = ShaderEval.sampleMipRgb(env#chain, { linear = true, repeat = true }, lod, u, v);
        (Texture3d.srgbToLinear(r) * env#intensity, Texture3d.srgbToLinear(g) * env#intensity, Texture3d.srgbToLinear(b) * env#intensity)

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
}
