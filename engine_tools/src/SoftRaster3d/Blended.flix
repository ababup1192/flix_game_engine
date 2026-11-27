// SoftRaster3d.Blended — CPU の描き手（SoftRaster3d）の半透明の物の塗り（1 段目の不透明の色の上に、遠い物から重ねる）。

/// 半透明の三角形を行ごとに重ねる。
pub mod SoftRaster3d.Blended {

    /// 半透明の物を塗る時に要る、場面ごとに 1 回だけ組んだ物（半透明の三角形・材質・lightmap・塗りの材料）。env = SSAO の mask を読む塗りの材料・glassEnv = 読まない塗りの材料・
    /// aoOnBlend = 材質の番号ごとに、半透明でも SSAO を受けるか（Scene3d.MaterialFields#screenAoOnBlend。デカールの板）。
    pub type alias BlendedShading = { tris = Vector[SoftRaster3d.Tri], mats = Vector[SoftRaster3d.Mat], bakes = Vector[Option[SoftRaster3d.Baked]],
                                      env = SoftRaster3d.ShadeEnv, glassEnv = SoftRaster3d.ShadeEnv, aoOnBlend = Vector[Bool], psx = SoftRaster3d.Psx.PsxColor }

    /// 半透明の三角形 ti が行 y で覆い、1 段目の深度 depth より手前の画素に、その色を重ねる（rgba = その行の r, g, b, α。深度は書かない）。
    /// 2 枚の三角形が分け合う縁の上の画素は、左か上の縁を持つ方だけが塗る（同じ物の 2 枚で 2 回重ねない。GL のラスタライズの決まりと同じ考え）。
    pub def blendRow(lw: Int32, y: Int32, blended: BlendedShading, ti: Int32, depth: Array[Float64, r], rgba: Array[Float64, r]): Unit \ r =
        let tri = Vector.get(ti, blended#tris);
        let SoftRaster3d.Tri.Tri(v, area, _, mat) = tri;
        let s = SoftRaster3d.stride();
        let (x0, y0, z0, q0) = (Vector.get(0, v), Vector.get(1, v), Vector.get(2, v), Vector.get(3, v));
        let (x1, y1, z1, q1) = (Vector.get(s, v), Vector.get(s + 1, v), Vector.get(s + 2, v), Vector.get(s + 3, v));
        let (x2, y2, z2, q2) = (Vector.get(s * 2, v), Vector.get(s * 2 + 1, v), Vector.get(s * 2 + 2, v), Vector.get(s * 2 + 3, v));
        let clockwise = area > 0.0;
        let own0 = ownsEdge(clockwise, x1, y1, x2, y2);
        let own1 = ownsEdge(clockwise, x2, y2, x0, y0);
        let own2 = ownsEdge(clockwise, x0, y0, x1, y1);
        let inside = (l: Float64, owns: Bool) -> l > 0.0 or (l == 0.0 and owns);
        let py = Int32.toFloat64(y) + 0.5;
        let lo = Int32.max(0, SoftRaster3d.Internal.ceilInt(Float64.min(x0, Float64.min(x1, x2)) - 0.5));
        let hi = Int32.min(lw - 1, SoftRaster3d.Internal.floorInt(Float64.max(x0, Float64.max(x1, x2)) - 0.5));
        let material = Vector.get(mat, blended#mats);
        let shade = if (Vector.get(mat, blended#aoOnBlend)) blended#env else blended#glassEnv;
        def loop(x: Int32): Unit \ r =
            if (x > hi) ()
            else {
                let px = Int32.toFloat64(x) + 0.5;
                let l0 = ((x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)) / area;
                let l1 = ((x0 - x2) * (py - y2) - (y0 - y2) * (px - x2)) / area;
                let l2 = 1.0 - l0 - l1;
                let z = l0 * z0 + l1 * z1 + l2 * z2;
                let covered = inside(l0, own0) and inside(l1, own1) and inside(l2, own2) and z >= -1.0 and z <= 1.0 and z < Array.get(x, depth);
                if (covered and not SoftRaster3d.isCutAway(material, blended#env#time, blended#env#affine, v, SoftRaster3d.Internal.perspectiveWeights(l0, l1, l2, q0, q1, q2))) {
                    let (lr, lg, lb, sa) = SoftRaster3d.materialPixel(tri, material, Vector.get(mat, blended#bakes), shade, (x, y), l0, l1);
                    let (sr, sg, sb) = SoftRaster3d.Psx.quantized(blended#psx, x, y, SoftRaster3d.toSrgbColor(blended#env#lut, (lr, lg, lb)));
                    let a = SoftRaster3d.clamp01(sa);
                    let k = x * 4;
                    let (dr, dg, db, da) = (Array.get(k, rgba), Array.get(k + 1, rgba), Array.get(k + 2, rgba), Array.get(k + 3, rgba));
                    let outA = a + da * (1.0 - a);
                    let back = da * (1.0 - a);
                    let mixed = (src: Float64, dst: Float64) -> if (outA <= 0.0) 0.0 else (src * a + dst * back) / outA;
                    Array.put(mixed(sr, dr), k, rgba);
                    Array.put(mixed(sg, dg), k + 1, rgba);
                    Array.put(mixed(sb, db), k + 2, rgba);
                    Array.put(outA, k + 3, rgba)
                } else ();
                loop(x + 1)
            };
        loop(lo)

    /// 三角形の縁 a → b の上にちょうど乗った画素の真ん中を、この三角形が持つか（左の縁と上の縁を持つ）。
    /// clockwise = 三角形が画面（y は下へ）で時計回りか。反時計回りの三角形は縁の向きを逆にして同じ決まりで見る。
    def ownsEdge(clockwise: Bool, ax: Float64, ay: Float64, bx: Float64, by: Float64): Bool =
        let (dx, dy) = if (clockwise) (bx - ax, by - ay) else (ax - bx, ay - by);
        dy < 0.0 or (dy == 0.0 and dx > 0.0)
}
