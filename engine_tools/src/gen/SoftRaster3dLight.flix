// SoftRaster3dLight — 生成した物（LightModel3d.Codegen.generateFlix）。手で直さない。直すのは LightModel3d の木で、
// `make gen-light3d` で作り直す（入っている物と作り直した物が同じことは engine_tools の TestSoftRaster3dLight が確かめる）。

/// 3D の光の式（LightModel3d の木）を CPU の描き手が画素ごとに回す関数（engine の中で使う。ゲームは使わない）。
/// 光の並びは LightModel3d.packPointLights・packSpotLights の形。shadow = 影を落とすスポット（SoftRaster3d.SpotShadow）。
pub mod SoftRaster3dLight {

    def clamp01(x: Float64): Float64 = Float64.max(0.0, Float64.min(1.0, x))

    def smoothstep(lo: Float64, hi: Float64, x: Float64): Float64 =
        let t = if (hi == lo) (if (x >= hi) 1.0 else 0.0) else clamp01((x - lo) / (hi - lo));
        t * t * (3.0 - 2.0 * t)

    def toon(steps: Int32, x: Float64): Float64 =
        if (steps <= 0) x
        else {
            let s = Int32.toFloat64(steps);
            Float64.floor(x * s + 0.5) / s
        }

    /// lightingModel の光の量（toon の丸めまで済ませた値）。
    pub def lightAt(steps: Int32, points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, ambientX: Float64, ambientY: Float64, ambientZ: Float64, hemisphere: Float64): (Float64, Float64, Float64) =
        let sky_0 = (hemisphere * Float64.max(0.0, nY));
        let (points_1X, points_1Y, points_1Z) = lightAtPoints(points, 0, pX, pY, pZ, nX, nY, nZ, 0.0, 0.0, 0.0);
        let (spots_2X, spots_2Y, spots_2Z) = lightAtSpots(spots, 0, shadow, pX, pY, pZ, nX, nY, nZ, 0.0, 0.0, 0.0);
        (toon(steps, (((ambientX + sky_0) + points_1X) + spots_2X)), toon(steps, (((ambientY + sky_0) + points_1Y) + spots_2Y)), toon(steps, (((ambientZ + sky_0) + points_1Z) + spots_2Z)))

    /// lightmapLightingModel の光の量（lightmap は段つきで読んだ後の rgb を渡す）。
    pub def lightmapLightAt(steps: Int32, points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, lightmapX: Float64, lightmapY: Float64, lightmapZ: Float64, lightmapSrgb: Float64, lightmapIntensity: Float64): (Float64, Float64, Float64) =
        let c_1 = (lightmapSrgb > 0.0);
        let t_0X = (if (c_1) Texture3d.srgbToLinear(lightmapX) else lightmapX);
        let t_0Y = (if (c_1) Texture3d.srgbToLinear(lightmapY) else lightmapY);
        let t_0Z = (if (c_1) Texture3d.srgbToLinear(lightmapZ) else lightmapZ);
        let (points_2X, points_2Y, points_2Z) = lightAtPoints(points, 0, pX, pY, pZ, nX, nY, nZ, 0.0, 0.0, 0.0);
        let (spots_3X, spots_3Y, spots_3Z) = lightAtSpots(spots, 0, shadow, pX, pY, pZ, nX, nY, nZ, 0.0, 0.0, 0.0);
        (toon(steps, ((Texture3d.linearToSrgb(Float64.max(0.0, (t_0X * lightmapIntensity))) + points_2X) + spots_3X)), toon(steps, ((Texture3d.linearToSrgb(Float64.max(0.0, (t_0Y * lightmapIntensity))) + points_2Y) + spots_3Y)), toon(steps, ((Texture3d.linearToSrgb(Float64.max(0.0, (t_0Z * lightmapIntensity))) + points_2Z) + spots_3Z)))

    /// fogModel の色（fog が無い場面では呼ばない）。
    pub def fogAt(pX: Float64, pY: Float64, pZ: Float64, eyeX: Float64, eyeY: Float64, eyeZ: Float64, colorX: Float64, colorY: Float64, colorZ: Float64, fogColorX: Float64, fogColorY: Float64, fogColorZ: Float64, fogNear: Float64, fogFar: Float64): (Float64, Float64, Float64) =
        let t_0 = (pX - eyeX);
        let t_1 = (pY - eyeY);
        let t_2 = (pZ - eyeZ);
        let t_3 = clamp01(((Num.sqrt((((t_0 * t_0) + (t_1 * t_1)) + (t_2 * t_2))) - fogNear) / Float64.max((fogFar - fogNear), 1.0e-6)));
        ((colorX + ((fogColorX - colorX) * t_3)), (colorY + ((fogColorY - colorY) * t_3)), (colorZ + ((fogColorZ - colorZ) * t_3)))

    /// skyModel の空の色。
    pub def skyAt(_dirX: Float64, dirY: Float64, _dirZ: Float64, zenithX: Float64, zenithY: Float64, zenithZ: Float64, horizonX: Float64, horizonY: Float64, horizonZ: Float64, groundX: Float64, groundY: Float64, groundZ: Float64, skyCurve: Float64): (Float64, Float64, Float64) =
        let c_1 = (dirY >= 0.0);
        let t_0X = (if (c_1) zenithX else groundX);
        let t_0Y = (if (c_1) zenithY else groundY);
        let t_0Z = (if (c_1) zenithZ else groundZ);
        let t_2 = Float64.min(1.0, (if ((dirY >= 0.0)) Float64.pow(base = dirY, skyCurve) else Float64.pow(base = (0.0 - dirY), skyCurve)));
        ((horizonX + ((t_0X - horizonX) * t_2)), (horizonY + ((t_0Y - horizonY) * t_2)), (horizonZ + ((t_0Z - horizonZ) * t_2)))

    def lightAtPoints(lights: Vector[Float64], i: Int32, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 7 > Vector.length(lights)) (accX, accY, accZ)
        else {
            let d_l0X = (Vector.get(i, lights) - pX);
            let d_l0Y = (Vector.get(i + 1, lights) - pY);
            let d_l0Z = (Vector.get(i + 2, lights) - pZ);
            let dSq_l1 = (((d_l0X * d_l0X) + (d_l0Y * d_l0Y)) + (d_l0Z * d_l0Z));
            let falloff_l2 = Float64.max(0.0, (1.0 - (dSq_l1 / Float64.max(Vector.get(i + 6, lights), 1.0e-12))));
            let att_l3 = (falloff_l2 * falloff_l2);
            let len_l4 = Num.sqrt(dSq_l1);
            let inv_l5 = (if ((1.0e-12 > len_l4)) 0.0 else (1.0 / len_l4));
            let l_l6X = (d_l0X * inv_l5);
            let l_l6Y = (d_l0Y * inv_l5);
            let l_l6Z = (d_l0Z * inv_l5);
            let facing_l7 = clamp01((0.0 + (((nX * l_l6X) + (nY * l_l6Y)) + (nZ * l_l6Z))));
            let k_l8 = (att_l3 * facing_l7);
            lightAtPoints(lights, i + 7, pX, pY, pZ, nX, nY, nZ, (accX + (Vector.get(i + 3, lights) * k_l8)), (accY + (Vector.get(i + 4, lights) * k_l8)), (accZ + (Vector.get(i + 5, lights) * k_l8)))
        }

    def lightAtSpots(lights: Vector[Float64], i: Int32, shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 12 > Vector.length(lights)) (accX, accY, accZ)
        else {
            let d_l0X = (Vector.get(i, lights) - pX);
            let d_l0Y = (Vector.get(i + 1, lights) - pY);
            let d_l0Z = (Vector.get(i + 2, lights) - pZ);
            let dSq_l1 = (((d_l0X * d_l0X) + (d_l0Y * d_l0Y)) + (d_l0Z * d_l0Z));
            let falloff_l2 = Float64.max(0.0, (1.0 - (dSq_l1 / Float64.max(Vector.get(i + 11, lights), 1.0e-12))));
            let att_l3 = (falloff_l2 * falloff_l2);
            let len_l4 = Num.sqrt(dSq_l1);
            let inv_l5 = (if ((1.0e-12 > len_l4)) 0.0 else (1.0 / len_l4));
            let l_l6X = (d_l0X * inv_l5);
            let l_l6Y = (d_l0Y * inv_l5);
            let l_l6Z = (d_l0Z * inv_l5);
            let facing_l7 = clamp01((0.0 + (((nX * l_l6X) + (nY * l_l6Y)) + (nZ * l_l6Z))));
            let k_l8 = (att_l3 * facing_l7);
            let cone_l9 = smoothstep(Vector.get(i + 6, lights), Vector.get(i + 7, lights), (0.0 - (((l_l6X * Vector.get(i + 3, lights)) + (l_l6Y * Vector.get(i + 4, lights))) + (l_l6Z * Vector.get(i + 5, lights)))));
            let lit_l10 = (if (((k_l8 > 0.0) and (cone_l9 > 0.0))) SoftRaster3d.shadowFactorAt(shadow, i, pX, pY, pZ) else 1.0);
            lightAtSpots(lights, i + 12, shadow, pX, pY, pZ, nX, nY, nZ, (accX + (((Vector.get(i + 8, lights) * k_l8) * cone_l9) * lit_l10)), (accY + (((Vector.get(i + 9, lights) * k_l8) * cone_l9) * lit_l10)), (accZ + (((Vector.get(i + 10, lights) * k_l8) * cone_l9) * lit_l10)))
        }
}
