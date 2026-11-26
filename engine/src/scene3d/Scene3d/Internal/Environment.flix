// Scene3d.Internal.Environment — 空と環境マップの読み方（どちらを背景に塗るか・空の画素の向き・箱のそろえ方・知らせる 1 行）。
// Scene3d の skyBasisOf・skyWarning・drawnSkyOf・backgroundEnvironmentOf・environmentBoxOf・environmentMap の中身。

/// 空と環境マップの中身。ゲームは呼ばない（Scene3d の同じ名前の関数を呼ぶ）。
pub mod Scene3d.Internal.Environment {

    /// 絵の形式から決める環境マップの色の意味（half の絵は線形の量・ほかは sRGB）。
    pub def colorSpaceOf(texture: Texture3d.Texture3d): Texture3d.ColorSpace =
        if (Texture3d.formatOf(texture) == Texture3d.Format.Rgba16Float) Texture3d.ColorSpace.Linear else Texture3d.ColorSpace.Srgb

    /// 空の代わりに背景へ描く環境マップ（asBackground が真で、sky が無い時だけ）。
    pub def backgroundOf(scene: Scene3d.Scene3dCmd): Option[Scene3d.EnvironmentMap] =
        if (Option.nonEmpty(scene#sky)) None
        else scene#environmentMap |> Option.filter(e -> Scene3d.environmentMapFieldsOf(e)#asBackground)

    /// 空として塗る物（sky・無くて景色を背景に描くなら黒の空）。
    pub def drawnSkyOf(scene: Scene3d.Scene3dCmd): Option[Scene3d.Sky3d] =
        match scene#sky {
            case Some(s) => Some(s)
            case None    =>
                let black = Color.rgb(0.0, 0.0, 0.0);
                backgroundOf(scene) |> Option.map(_ -> Scene3d.gradientSky(black, black, black))
        }

    /// 箱の min と max を軸ごとに小さい方・大きい方へそろえた物。
    pub def boxOf(b: Scene3d.EnvironmentBox): Scene3d.EnvironmentBox =
        { min = Vec3.v3(Float64.min(b#min#x, b#max#x), Float64.min(b#min#y, b#max#y), Float64.min(b#min#z, b#max#z)),
          max = Vec3.v3(Float64.max(b#min#x, b#max#x), Float64.max(b#min#y, b#max#y), Float64.max(b#min#z, b#max#z)) | b }

    /// 場面のカメラと縦横の比から、空の画素の向きを組む材料（Scene3d.SkyBasis の doc）。
    pub def skyBasisOf(scene: Scene3d.Scene3dCmd): Scene3d.SkyBasis =
        let c = scene#camera;
        let half = c#fovY / 2.0;
        let tanHalf = Num.sin(half) / Num.cos(half);
        let right = Vec3.mul(Camera3d.right(c), tanHalf * Scene3d.aspectOf(scene));
        let up = Vec3.mul(Camera3d.up(c), tanHalf);
        let center = if (Camera3d.hasLensShift(c))
                Vec3.add(Camera3d.forward(c), Vec3.add(Vec3.mul(right, 2.0 * c#lensShift#x), Vec3.mul(up, 2.0 * c#lensShift#y)))
            else Camera3d.forward(c);
        { forward = center, right = right, up = up }

    /// sky と environment の background が両方 Some の時の 1 行。
    pub def skyWarningOf(scene: Scene3d.Scene3dCmd): Option[String] =
        if (Option.nonEmpty(scene#sky) and Option.nonEmpty(scene#environment#background))
            Some("scene3d: sky と environment の background が両方ある — background は使わず空を描く")
        else None
}
