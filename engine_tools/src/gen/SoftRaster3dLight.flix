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
        (toon(steps, ((Float64.max(0.0, (t_0X * lightmapIntensity)) + points_2X) + spots_3X)), toon(steps, ((Float64.max(0.0, (t_0Y * lightmapIntensity)) + points_2Y) + spots_3Y)), toon(steps, ((Float64.max(0.0, (t_0Z * lightmapIntensity)) + points_2Z) + spots_3Z)))

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
        let t_2 = Float64.min(1.0, Float64.pow(base = Float64.max(dirY, (0.0 - dirY)), skyCurve));
        ((horizonX + ((t_0X - horizonX) * t_2)), (horizonY + ((t_0Y - horizonY) * t_2)), (horizonZ + ((t_0Z - horizonZ) * t_2)))

    /// pbrModel の、かすみの前の色（light = lightAt か lightmapLightAt の値・metalRough の x = metallic・y = roughness・z は使わない）。
    pub def pbrAt(points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, albedoX: Float64, albedoY: Float64, albedoZ: Float64, lightX: Float64, lightY: Float64, lightZ: Float64, metalRoughX: Float64, metalRoughY: Float64, _metalRoughZ: Float64, eyeX: Float64, eyeY: Float64, eyeZ: Float64, zenithX: Float64, zenithY: Float64, zenithZ: Float64, horizonX: Float64, horizonY: Float64, horizonZ: Float64, groundX: Float64, groundY: Float64, groundZ: Float64, skyCurve: Float64): (Float64, Float64, Float64) =
        let metallic_0 = metalRoughX;
        let roughness_1 = metalRoughY;
        let alpha_2 = Float64.max(0.002, (roughness_1 * roughness_1));
        let alphaSq_3 = (alpha_2 * alpha_2);
        let fZero_4X = (0.04 + ((albedoX - 0.04) * metallic_0));
        let fZero_4Y = (0.04 + ((albedoY - 0.04) * metallic_0));
        let fZero_4Z = (0.04 + ((albedoZ - 0.04) * metallic_0));
        let toEye_5X = (eyeX - pX);
        let toEye_5Y = (eyeY - pY);
        let toEye_5Z = (eyeZ - pZ);
        let toEyeSq_6 = (((toEye_5X * toEye_5X) + (toEye_5Y * toEye_5Y)) + (toEye_5Z * toEye_5Z));
        let invToEye_7 = (if ((1.0e-24 > toEyeSq_6)) 0.0 else (1.0 / Num.sqrt(toEyeSq_6)));
        let v_8X = (toEye_5X * invToEye_7);
        let v_8Y = (toEye_5Y * invToEye_7);
        let v_8Z = (toEye_5Z * invToEye_7);
        let nv_9 = Float64.max(1.0e-4, (((nX * v_8X) + (nY * v_8Y)) + (nZ * v_8Z)));
        let viewTerm_10 = ((nv_9 / ((nv_9 * (1.0 - (0.5 * alpha_2))) + (0.5 * alpha_2))) / (4.0 * nv_9));
        let dScale_11 = (alphaSq_3 / 3.141592653589793);
        let t_12 = (1.0 - metallic_0);
        let (points_13X, points_13Y, points_13Z) = pbrAtPoints(points, 0, pX, pY, pZ, nX, nY, nZ, alphaSq_3, alpha_2, dScale_11, fZero_4X, fZero_4Y, fZero_4Z, v_8X, v_8Y, v_8Z, viewTerm_10, 0.0, 0.0, 0.0);
        let (spots_14X, spots_14Y, spots_14Z) = pbrAtSpots(spots, 0, shadow, pX, pY, pZ, nX, nY, nZ, alphaSq_3, alpha_2, dScale_11, fZero_4X, fZero_4Y, fZero_4Z, v_8X, v_8Y, v_8Z, viewTerm_10, 0.0, 0.0, 0.0);
        let t_15 = (2.0 * nv_9);
        let t_16 = ((nX * t_15) - v_8X);
        let t_17 = ((nY * t_15) - v_8Y);
        let t_18 = ((nZ * t_15) - v_8Z);
        let t_19 = (roughness_1 * roughness_1);
        let q_20X = (t_16 + ((nX - t_16) * t_19));
        let q_20Y = (t_17 + ((nY - t_17) * t_19));
        let q_20Z = (t_18 + ((nZ - t_18) * t_19));
        let t_21 = (1.0 / Num.sqrt(Float64.max((((q_20X * q_20X) + (q_20Y * q_20Y)) + (q_20Z * q_20Z)), 1.0e-12)));
        let r_22Y = (q_20Y * t_21);
        let c_24 = (r_22Y >= 0.0);
        let t_23X = (if (c_24) zenithX else groundX);
        let t_23Y = (if (c_24) zenithY else groundY);
        let t_23Z = (if (c_24) zenithZ else groundZ);
        let t_25 = Float64.min(1.0, Float64.pow(base = Float64.max(r_22Y, (0.0 - r_22Y)), skyCurve));
        let t_26 = (1.0 - roughness_1);
        let base_27 = (1.0 - nv_9);
        let t_28 = (((base_27 * base_27) * (base_27 * base_27)) * base_27);
        (((((albedoX * lightX) * t_12) + (points_13X + spots_14X)) + ((horizonX + ((t_23X - horizonX) * t_25)) * (fZero_4X + ((Float64.max(t_26, fZero_4X) - fZero_4X) * t_28)))), ((((albedoY * lightY) * t_12) + (points_13Y + spots_14Y)) + ((horizonY + ((t_23Y - horizonY) * t_25)) * (fZero_4Y + ((Float64.max(t_26, fZero_4Y) - fZero_4Y) * t_28)))), ((((albedoZ * lightZ) * t_12) + (points_13Z + spots_14Z)) + ((horizonZ + ((t_23Z - horizonZ) * t_25)) * (fZero_4Z + ((Float64.max(t_26, fZero_4Z) - fZero_4Z) * t_28)))))

    def lightAtPoints(lights: Vector[Float64], i: Int32, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 7 > Vector.length(lights)) (accX, accY, accZ)
        else {
            let d_l0X = (Vector.get(i, lights) - pX);
            let d_l0Y = (Vector.get(i + 1, lights) - pY);
            let d_l0Z = (Vector.get(i + 2, lights) - pZ);
            let dSq_l1 = (((d_l0X * d_l0X) + (d_l0Y * d_l0Y)) + (d_l0Z * d_l0Z));
            let falloff_l2 = Float64.max(0.0, (1.0 - (dSq_l1 / Float64.max(Vector.get(i + 6, lights), 1.0e-12))));
            let att_l3 = (falloff_l2 * falloff_l2);
            let inv_l4 = (if ((1.0e-24 > dSq_l1)) 0.0 else (1.0 / Num.sqrt(dSq_l1)));
            let l_l5X = (d_l0X * inv_l4);
            let l_l5Y = (d_l0Y * inv_l4);
            let l_l5Z = (d_l0Z * inv_l4);
            let facing_l6 = clamp01((0.0 + (((nX * l_l5X) + (nY * l_l5Y)) + (nZ * l_l5Z))));
            let k_l7 = (att_l3 * facing_l6);
            lightAtPoints(lights, i + 7, pX, pY, pZ, nX, nY, nZ, (accX + (Vector.get(i + 3, lights) * k_l7)), (accY + (Vector.get(i + 4, lights) * k_l7)), (accZ + (Vector.get(i + 5, lights) * k_l7)))
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
            let inv_l4 = (if ((1.0e-24 > dSq_l1)) 0.0 else (1.0 / Num.sqrt(dSq_l1)));
            let l_l5X = (d_l0X * inv_l4);
            let l_l5Y = (d_l0Y * inv_l4);
            let l_l5Z = (d_l0Z * inv_l4);
            let facing_l6 = clamp01((0.0 + (((nX * l_l5X) + (nY * l_l5Y)) + (nZ * l_l5Z))));
            let k_l7 = (att_l3 * facing_l6);
            let cone_l8 = smoothstep(Vector.get(i + 6, lights), Vector.get(i + 7, lights), (0.0 - (((l_l5X * Vector.get(i + 3, lights)) + (l_l5Y * Vector.get(i + 4, lights))) + (l_l5Z * Vector.get(i + 5, lights)))));
            let lit_l9 = (if (((k_l7 > 0.0) and (cone_l8 > 0.0))) SoftRaster3d.shadowFactorAt(shadow, i, pX, pY, pZ) else 1.0);
            lightAtSpots(lights, i + 12, shadow, pX, pY, pZ, nX, nY, nZ, (accX + (((Vector.get(i + 8, lights) * k_l7) * cone_l8) * lit_l9)), (accY + (((Vector.get(i + 9, lights) * k_l7) * cone_l8) * lit_l9)), (accZ + (((Vector.get(i + 10, lights) * k_l7) * cone_l8) * lit_l9)))
        }

    def pbrAtPoints(lights: Vector[Float64], i: Int32, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, alphaSq_3: Float64, alpha_2: Float64, dScale_11: Float64, fZero_4X: Float64, fZero_4Y: Float64, fZero_4Z: Float64, v_8X: Float64, v_8Y: Float64, v_8Z: Float64, viewTerm_10: Float64, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 7 > Vector.length(lights)) (accX, accY, accZ)
        else {
            let d_l0X = (Vector.get(i, lights) - pX);
            let d_l0Y = (Vector.get(i + 1, lights) - pY);
            let d_l0Z = (Vector.get(i + 2, lights) - pZ);
            let dSq_l1 = (((d_l0X * d_l0X) + (d_l0Y * d_l0Y)) + (d_l0Z * d_l0Z));
            let falloff_l2 = Float64.max(0.0, (1.0 - (dSq_l1 / Float64.max(Vector.get(i + 6, lights), 1.0e-12))));
            let att_l3 = (falloff_l2 * falloff_l2);
            let inv_l4 = (if ((1.0e-24 > dSq_l1)) 0.0 else (1.0 / Num.sqrt(dSq_l1)));
            let l_l5X = (d_l0X * inv_l4);
            let l_l5Y = (d_l0Y * inv_l4);
            let l_l5Z = (d_l0Z * inv_l4);
            let facing_l6 = clamp01((0.0 + (((nX * l_l5X) + (nY * l_l5Y)) + (nZ * l_l5Z))));
            let k_l7 = (att_l3 * facing_l6);
            let (t_l17X, t_l17Y, t_l17Z) = if ((k_l7 > 0.0)) {
                let h_l8X = (l_l5X + v_8X);
                let h_l8Y = (l_l5Y + v_8Y);
                let h_l8Z = (l_l5Z + v_8Z);
                let hSq_l9 = (((h_l8X * h_l8X) + (h_l8Y * h_l8Y)) + (h_l8Z * h_l8Z));
                let invH_l10 = (if ((1.0e-24 > hSq_l9)) 0.0 else (1.0 / Num.sqrt(hSq_l9)));
                let nh_l11 = Float64.max(0.0, ((((nX * h_l8X) + (nY * h_l8Y)) + (nZ * h_l8Z)) * invH_l10));
                let vh_l12 = Float64.max(0.0, ((((v_8X * h_l8X) + (v_8Y * h_l8Y)) + (v_8Z * h_l8Z)) * invH_l10));
                let spread_l13 = (((nh_l11 * nh_l11) * (alphaSq_3 - 1.0)) + 1.0);
                let base_l14 = (1.0 - vh_l12);
                let t_l15 = (((base_l14 * base_l14) * (base_l14 * base_l14)) * base_l14);
                let t_l16 = ((dScale_11 / (spread_l13 * spread_l13)) * ((facing_l6 / ((facing_l6 * (1.0 - (0.5 * alpha_2))) + (0.5 * alpha_2))) * viewTerm_10));
                ((((Vector.get(i + 3, lights) * att_l3) * (fZero_4X + ((1.0 - fZero_4X) * t_l15))) * t_l16), (((Vector.get(i + 4, lights) * att_l3) * (fZero_4Y + ((1.0 - fZero_4Y) * t_l15))) * t_l16), (((Vector.get(i + 5, lights) * att_l3) * (fZero_4Z + ((1.0 - fZero_4Z) * t_l15))) * t_l16))
            } else {
                (0.0, 0.0, 0.0)
            };
            pbrAtPoints(lights, i + 7, pX, pY, pZ, nX, nY, nZ, alphaSq_3, alpha_2, dScale_11, fZero_4X, fZero_4Y, fZero_4Z, v_8X, v_8Y, v_8Z, viewTerm_10, (accX + t_l17X), (accY + t_l17Y), (accZ + t_l17Z))
        }

    def pbrAtSpots(lights: Vector[Float64], i: Int32, shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, alphaSq_3: Float64, alpha_2: Float64, dScale_11: Float64, fZero_4X: Float64, fZero_4Y: Float64, fZero_4Z: Float64, v_8X: Float64, v_8Y: Float64, v_8Z: Float64, viewTerm_10: Float64, accX: Float64, accY: Float64, accZ: Float64): (Float64, Float64, Float64) =
        if (i + 12 > Vector.length(lights)) (accX, accY, accZ)
        else {
            let d_l0X = (Vector.get(i, lights) - pX);
            let d_l0Y = (Vector.get(i + 1, lights) - pY);
            let d_l0Z = (Vector.get(i + 2, lights) - pZ);
            let dSq_l1 = (((d_l0X * d_l0X) + (d_l0Y * d_l0Y)) + (d_l0Z * d_l0Z));
            let falloff_l2 = Float64.max(0.0, (1.0 - (dSq_l1 / Float64.max(Vector.get(i + 11, lights), 1.0e-12))));
            let att_l3 = (falloff_l2 * falloff_l2);
            let inv_l4 = (if ((1.0e-24 > dSq_l1)) 0.0 else (1.0 / Num.sqrt(dSq_l1)));
            let l_l5X = (d_l0X * inv_l4);
            let l_l5Y = (d_l0Y * inv_l4);
            let l_l5Z = (d_l0Z * inv_l4);
            let facing_l6 = clamp01((0.0 + (((nX * l_l5X) + (nY * l_l5Y)) + (nZ * l_l5Z))));
            let k_l7 = (att_l3 * facing_l6);
            let cone_l8 = smoothstep(Vector.get(i + 6, lights), Vector.get(i + 7, lights), (0.0 - (((l_l5X * Vector.get(i + 3, lights)) + (l_l5Y * Vector.get(i + 4, lights))) + (l_l5Z * Vector.get(i + 5, lights)))));
            let lit_l9 = (if (((k_l7 > 0.0) and (cone_l8 > 0.0))) SoftRaster3d.shadowFactorAt(shadow, i, pX, pY, pZ) else 1.0);
            let (t_l19X, t_l19Y, t_l19Z) = if (((k_l7 > 0.0) and (cone_l8 > 0.0))) {
                let h_l10X = (l_l5X + v_8X);
                let h_l10Y = (l_l5Y + v_8Y);
                let h_l10Z = (l_l5Z + v_8Z);
                let hSq_l11 = (((h_l10X * h_l10X) + (h_l10Y * h_l10Y)) + (h_l10Z * h_l10Z));
                let invH_l12 = (if ((1.0e-24 > hSq_l11)) 0.0 else (1.0 / Num.sqrt(hSq_l11)));
                let nh_l13 = Float64.max(0.0, ((((nX * h_l10X) + (nY * h_l10Y)) + (nZ * h_l10Z)) * invH_l12));
                let vh_l14 = Float64.max(0.0, ((((v_8X * h_l10X) + (v_8Y * h_l10Y)) + (v_8Z * h_l10Z)) * invH_l12));
                let spread_l15 = (((nh_l13 * nh_l13) * (alphaSq_3 - 1.0)) + 1.0);
                let base_l16 = (1.0 - vh_l14);
                let t_l17 = (((base_l16 * base_l16) * (base_l16 * base_l16)) * base_l16);
                let t_l18 = ((dScale_11 / (spread_l15 * spread_l15)) * ((facing_l6 / ((facing_l6 * (1.0 - (0.5 * alpha_2))) + (0.5 * alpha_2))) * viewTerm_10));
                ((((((Vector.get(i + 8, lights) * att_l3) * cone_l8) * lit_l9) * (fZero_4X + ((1.0 - fZero_4X) * t_l17))) * t_l18), (((((Vector.get(i + 9, lights) * att_l3) * cone_l8) * lit_l9) * (fZero_4Y + ((1.0 - fZero_4Y) * t_l17))) * t_l18), (((((Vector.get(i + 10, lights) * att_l3) * cone_l8) * lit_l9) * (fZero_4Z + ((1.0 - fZero_4Z) * t_l17))) * t_l18))
            } else {
                (0.0, 0.0, 0.0)
            };
            pbrAtSpots(lights, i + 12, shadow, pX, pY, pZ, nX, nY, nZ, alphaSq_3, alpha_2, dScale_11, fZero_4X, fZero_4Y, fZero_4Z, v_8X, v_8Y, v_8Z, viewTerm_10, (accX + t_l19X), (accY + t_l19Y), (accZ + t_l19Z))
        }
}
