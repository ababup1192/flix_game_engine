// Texture3d.Internal — 絵ごとに 1 回だけ求める控え（環境マップの拡散の光）を描き手と SphericalHarmonics へ渡す口。

/// Texture3d の中身。ゲームは呼ばない。
pub mod Texture3d.Internal {

    /// 絵 t を正距円筒の景色として求めた拡散の光の控え（初めて force した時に 1 回だけ求める）。
    pub def irradianceOf(t: Texture3d.Texture3d): Lazy[Option[SphericalHarmonics.SphericalHarmonics]] = Texture3d.recOf(t)#irradiance

    /// 画素の在りか source（width × height）の拡散の光。8bit の絵は sRGB の値を線形の量へ戻して足す。機種の側の絵は画素が無いので None。
    pub def equirectangularIrradianceOf(width: Int32, height: Int32, source: Texture3d.Source): Option[SphericalHarmonics.SphericalHarmonics] =
        match source {
            case Texture3d.Source.PlatformImage(_) => None
            case Texture3d.Source.Argb(argb)       => region rc {
                let toLinear = Vector.range(0, 256) |> Vector.map(v -> Texture3d.srgbToLinear(Int32.toFloat64(v) / 255.0)) |> Vector.toArray(rc);
                let pixels = Vector.toArray(rc, argb);
                SphericalHarmonics.Internal.fromLinear(rc, width, height, (x, y, out) -> {
                    let p = Array.get(y * width + x, pixels);
                    Array.put(Array.get(Int32.bitwiseAnd(Int32.rightShift(p, 16), 255), toLinear), 0, out);
                    Array.put(Array.get(Int32.bitwiseAnd(Int32.rightShift(p, 8), 255), toLinear), 1, out);
                    Array.put(Array.get(Int32.bitwiseAnd(p, 255), toLinear), 2, out)
                })
            }
        }
}
