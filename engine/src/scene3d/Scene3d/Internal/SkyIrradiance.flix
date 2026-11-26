// Scene3d.Internal.SkyIrradiance — 景色の拡散の光（Scene3d.withSkyContribution）を 3 つの描き手へ渡す値と、その知らせ。

/// 景色の拡散の光の中身。ゲームは呼ばない（Scene3d.withSkyContribution を呼ぶ）。
pub mod Scene3d.Internal.SkyIrradiance {

    /// 場面が景色の拡散の光を混ぜる版（+sh）で描くか（環境マップがあり、割合が 0 より大きい）。拡散の光が求められるかは見ない（変種は画素を読まずに決める）。
    pub def isOn(scene: Scene3d.Scene3dCmd): Bool =
        scene#environmentMap |> Option.exists(e -> Scene3d.skyContributionOf(e) > 0.0)

    /// 描き手へ渡す (割合, 係数 27 個)。係数は SphericalHarmonics の並び（c0 の r, g, b…）に環境マップの強さを掛けた物。
    /// 版が +sh でない・拡散の光が求められない（機種の側の絵で withIrradiance も無い）場面は (0, 全部 0)（ambient のまま描く）。
    pub def valuesOf(scene: Scene3d.Scene3dCmd): (Float64, Vector[Float64]) =
        let picked = scene#environmentMap
            |> Option.filter(e -> Scene3d.skyContributionOf(e) > 0.0)
            |> Option.flatMap(e -> shOf(e) |> Option.map(sh -> (Scene3d.skyContributionOf(e), Scene3d.environmentIntensityOf(e), sh)));
        match picked {
            case Some((k, intensity, sh)) =>
                (k, SphericalHarmonics.coefficientsOf(sh) |> List.flatMap(c -> c#x * intensity :: c#y * intensity :: c#z * intensity :: Nil) |> List.toVector)
            case None => (0.0, zeros())
        }

    /// 係数が全部 0 の並び（27 個）。
    pub def zeros(): Vector[Float64] = Vector.repeat(27, 0.0)

    /// 環境マップ e の拡散の光（渡した物が先・無ければ絵から求めた物）。
    def shOf(e: Scene3d.EnvironmentMap): Option[SphericalHarmonics.SphericalHarmonics] =
        let f = Scene3d.environmentMapFieldsOf(e);
        match f#irradiance {
            case Some(sh) => Some(sh)
            case None     => force f#textureIrradiance
        }

    /// 知らせる (鍵, 1 行)。毎コマ通るので、呼ぶ側が鍵ごとに初回 1 回だけ出す（GL と CPU で同じ文面）。
    pub def warningsOf(scene: Scene3d.Scene3dCmd): List[(String, String)] =
        match scene#environmentMap |> Option.filter(e -> Scene3d.skyContributionOf(e) > 0.0) {
            case None    => Nil
            case Some(e) =>
                (if (Option.isEmpty(shOf(e)))
                    ("@sky-irradiance-unavailable", "scene3d: 空の拡散は画素を持つ絵だけ — 環境マップを Texture3d.decodeHdr か decodeUsing で読む（今は ambient のまま描く）") :: Nil
                 else Nil)
                ::: (if (scene#environment#hemisphere > 0.0)
                    ("@sky-irradiance-double", "scene3d: 空の拡散（withSkyContribution）と hemisphere は同じ空の光を 2 回足す — hemisphere は 0 に") :: Nil
                 else Nil)
        }
}
