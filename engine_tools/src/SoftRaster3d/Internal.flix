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
}
