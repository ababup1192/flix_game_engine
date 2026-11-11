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

    /// lightingModel の光の量（toon の丸めまで済ませた値。sunLit = 太陽の影の割合）。
    pub def lightAt(steps: Int32, points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, ambientX: Float64, ambientY: Float64, ambientZ: Float64, hemisphere: Float64, sunDirX: Float64, sunDirY: Float64, sunDirZ: Float64, sunColorX: Float64, sunColorY: Float64, sunColorZ: Float64, sunLit: Float64): (Float64, Float64, Float64) =
        let sky_0 = (hemisphere * Float64.max(0.0, nY));
        let (points_1X, points_1Y, points_1Z) = lightAtPoints(points, 0, pX, pY, pZ, nX, nY, nZ, 0.0, 0.0, 0.0);
        let (spots_2X, spots_2Y, spots_2Z) = lightAtSpots(spots, 0, shadow, pX, pY, pZ, nX, nY, nZ, 0.0, 0.0, 0.0);
        let sunFacing_3 = clamp01((0.0 + (((nX * sunDirX) + (nY * sunDirY)) + (nZ * sunDirZ))));
        (toon(steps, ((((ambientX + sky_0) + points_1X) + spots_2X) + ((sunColorX * sunFacing_3) * sunLit))), toon(steps, ((((ambientY + sky_0) + points_1Y) + spots_2Y) + ((sunColorY * sunFacing_3) * sunLit))), toon(steps, ((((ambientZ + sky_0) + points_1Z) + spots_2Z) + ((sunColorZ * sunFacing_3) * sunLit))))

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
    pub def pbrAt(points: Vector[Float64], spots: Vector[Float64], shadow: SoftRaster3d.SpotShadow, pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, albedoX: Float64, albedoY: Float64, albedoZ: Float64, lightX: Float64, lightY: Float64, lightZ: Float64, metalRoughX: Float64, metalRoughY: Float64, _metalRoughZ: Float64, eyeX: Float64, eyeY: Float64, eyeZ: Float64, zenithX: Float64, zenithY: Float64, zenithZ: Float64, horizonX: Float64, horizonY: Float64, horizonZ: Float64, groundX: Float64, groundY: Float64, groundZ: Float64, skyCurve: Float64, envColorX: Float64, envColorY: Float64, envColorZ: Float64, envOn: Float64, sunDirX: Float64, sunDirY: Float64, sunDirZ: Float64, sunColorX: Float64, sunColorY: Float64, sunColorZ: Float64, sunLit: Float64): (Float64, Float64, Float64) =
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
        let l_15X = sunDirX;
        let l_15Y = sunDirY;
        let l_15Z = sunDirZ;
        let facing_16 = clamp01((0.0 + (((nX * sunDirX) + (nY * sunDirY)) + (nZ * sunDirZ))));
        let (t_26X, t_26Y, t_26Z) = if ((facing_16 > 0.0)) {
            let h_17X = (l_15X + v_8X);
            let h_17Y = (l_15Y + v_8Y);
            let h_17Z = (l_15Z + v_8Z);
            let hSq_18 = (((h_17X * h_17X) + (h_17Y * h_17Y)) + (h_17Z * h_17Z));
            let invH_19 = (if ((1.0e-24 > hSq_18)) 0.0 else (1.0 / Num.sqrt(hSq_18)));
            let nh_20 = Float64.max(0.0, ((((nX * h_17X) + (nY * h_17Y)) + (nZ * h_17Z)) * invH_19));
            let vh_21 = Float64.max(0.0, ((((v_8X * h_17X) + (v_8Y * h_17Y)) + (v_8Z * h_17Z)) * invH_19));
            let spread_22 = (((nh_20 * nh_20) * (alphaSq_3 - 1.0)) + 1.0);
            let base_23 = (1.0 - vh_21);
            let t_24 = (((base_23 * base_23) * (base_23 * base_23)) * base_23);
            let t_25 = ((dScale_11 / (spread_22 * spread_22)) * ((facing_16 / ((facing_16 * (1.0 - (0.5 * alpha_2))) + (0.5 * alpha_2))) * viewTerm_10));
            ((((sunColorX * sunLit) * (fZero_4X + ((1.0 - fZero_4X) * t_24))) * t_25), (((sunColorY * sunLit) * (fZero_4Y + ((1.0 - fZero_4Y) * t_24))) * t_25), (((sunColorZ * sunLit) * (fZero_4Z + ((1.0 - fZero_4Z) * t_24))) * t_25))
        } else {
            (0.0, 0.0, 0.0)
        };
        let (t_38X, t_38Y, t_38Z) = if ((envOn > 0.0)) {
            (envColorX, envColorY, envColorZ)
        } else {
            let t_27 = (2.0 * nv_9);
            let t_28 = ((nX * t_27) - v_8X);
            let t_29 = ((nY * t_27) - v_8Y);
            let t_30 = ((nZ * t_27) - v_8Z);
            let t_31 = (roughness_1 * roughness_1);
            let q_32X = (t_28 + ((nX - t_28) * t_31));
            let q_32Y = (t_29 + ((nY - t_29) * t_31));
            let q_32Z = (t_30 + ((nZ - t_30) * t_31));
            let t_33 = (1.0 / Num.sqrt(Float64.max((((q_32X * q_32X) + (q_32Y * q_32Y)) + (q_32Z * q_32Z)), 1.0e-12)));
            let r_34Y = (q_32Y * t_33);
            let c_36 = (r_34Y >= 0.0);
            let t_35X = (if (c_36) zenithX else groundX);
            let t_35Y = (if (c_36) zenithY else groundY);
            let t_35Z = (if (c_36) zenithZ else groundZ);
            let t_37 = Float64.min(1.0, Float64.pow(base = Float64.max(r_34Y, (0.0 - r_34Y)), skyCurve));
            ((horizonX + ((t_35X - horizonX) * t_37)), (horizonY + ((t_35Y - horizonY) * t_37)), (horizonZ + ((t_35Z - horizonZ) * t_37)))
        };
        let t_39 = (1.0 - roughness_1);
        let base_40 = (1.0 - nv_9);
        let t_41 = (((base_40 * base_40) * (base_40 * base_40)) * base_40);
        (((((albedoX * lightX) * t_12) + ((points_13X + spots_14X) + t_26X)) + (t_38X * (fZero_4X + ((Float64.max(t_39, fZero_4X) - fZero_4X) * t_41)))), ((((albedoY * lightY) * t_12) + ((points_13Y + spots_14Y) + t_26Y)) + (t_38Y * (fZero_4Y + ((Float64.max(t_39, fZero_4Y) - fZero_4Y) * t_41)))), ((((albedoZ * lightZ) * t_12) + ((points_13Z + spots_14Z) + t_26Z)) + (t_38Z * (fZero_4Z + ((Float64.max(t_39, fZero_4Z) - fZero_4Z) * t_41)))))

    /// environmentDirection の、環境マップを読む向き（長さ 1。metalRough の x は使わない）。
    pub def environmentDirectionAt(pX: Float64, pY: Float64, pZ: Float64, nX: Float64, nY: Float64, nZ: Float64, _albedoX: Float64, _albedoY: Float64, _albedoZ: Float64, _metalRoughX: Float64, metalRoughY: Float64, _metalRoughZ: Float64, eyeX: Float64, eyeY: Float64, eyeZ: Float64, envBoxMinX: Float64, envBoxMinY: Float64, envBoxMinZ: Float64, envBoxMaxX: Float64, envBoxMaxY: Float64, envBoxMaxZ: Float64, envBoxCenterX: Float64, envBoxCenterY: Float64, envBoxCenterZ: Float64, envBoxOn: Float64): (Float64, Float64, Float64) =
        let roughness_1 = metalRoughY;
        let toEye_5X = (eyeX - pX);
        let toEye_5Y = (eyeY - pY);
        let toEye_5Z = (eyeZ - pZ);
        let toEyeSq_6 = (((toEye_5X * toEye_5X) + (toEye_5Y * toEye_5Y)) + (toEye_5Z * toEye_5Z));
        let invToEye_7 = (if ((1.0e-24 > toEyeSq_6)) 0.0 else (1.0 / Num.sqrt(toEyeSq_6)));
        let v_8X = (toEye_5X * invToEye_7);
        let v_8Y = (toEye_5Y * invToEye_7);
        let v_8Z = (toEye_5Z * invToEye_7);
        let nv_9 = Float64.max(1.0e-4, (((nX * v_8X) + (nY * v_8Y)) + (nZ * v_8Z)));
        let (t_30X, t_30Y, t_30Z) = if ((envBoxOn > 0.0)) {
            let t_12 = (2.0 * nv_9);
            let t_13 = ((nX * t_12) - v_8X);
            let t_14 = ((nY * t_12) - v_8Y);
            let t_15 = ((nZ * t_12) - v_8Z);
            let t_16 = (roughness_1 * roughness_1);
            let q_17X = (t_13 + ((nX - t_13) * t_16));
            let q_17Y = (t_14 + ((nY - t_14) * t_16));
            let q_17Z = (t_15 + ((nZ - t_15) * t_16));
            let t_18 = (1.0 / Num.sqrt(Float64.max((((q_17X * q_17X) + (q_17Y * q_17Y)) + (q_17Z * q_17Z)), 1.0e-12)));
            let reflected_19X = (q_17X * t_18);
            let reflected_19Y = (q_17Y * t_18);
            let reflected_19Z = (q_17Z * t_18);
            let reach_20 = Float64.max(0.0, Float64.min((if ((1.0e-9 > Float64.max(reflected_19X, (0.0 - reflected_19X)))) 1.0e30 else (((if ((reflected_19X > 0.0)) envBoxMaxX else envBoxMinX) - pX) / reflected_19X)), Float64.min((if ((1.0e-9 > Float64.max(reflected_19Y, (0.0 - reflected_19Y)))) 1.0e30 else (((if ((reflected_19Y > 0.0)) envBoxMaxY else envBoxMinY) - pY) / reflected_19Y)), (if ((1.0e-9 > Float64.max(reflected_19Z, (0.0 - reflected_19Z)))) 1.0e30 else (((if ((reflected_19Z > 0.0)) envBoxMaxZ else envBoxMinZ) - pZ) / reflected_19Z)))));
            let offset_21X = ((pX + (reflected_19X * reach_20)) - envBoxCenterX);
            let offset_21Y = ((pY + (reflected_19Y * reach_20)) - envBoxCenterY);
            let offset_21Z = ((pZ + (reflected_19Z * reach_20)) - envBoxCenterZ);
            let t_22 = (1.0 / Num.sqrt(Float64.max((((offset_21X * offset_21X) + (offset_21Y * offset_21Y)) + (offset_21Z * offset_21Z)), 1.0e-12)));
            ((offset_21X * t_22), (offset_21Y * t_22), (offset_21Z * t_22))
        } else {
            let t_23 = (2.0 * nv_9);
            let t_24 = ((nX * t_23) - v_8X);
            let t_25 = ((nY * t_23) - v_8Y);
            let t_26 = ((nZ * t_23) - v_8Z);
            let t_27 = (roughness_1 * roughness_1);
            let q_28X = (t_24 + ((nX - t_24) * t_27));
            let q_28Y = (t_25 + ((nY - t_25) * t_27));
            let q_28Z = (t_26 + ((nZ - t_26) * t_27));
            let t_29 = (1.0 / Num.sqrt(Float64.max((((q_28X * q_28X) + (q_28Y * q_28Y)) + (q_28Z * q_28Z)), 1.0e-12)));
            ((q_28X * t_29), (q_28Y * t_29), (q_28Z * t_29))
        };
        (t_30X, t_30Y, t_30Z)

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
