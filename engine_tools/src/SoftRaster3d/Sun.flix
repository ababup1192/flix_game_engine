// SoftRaster3d.Sun — CPU の描き手（SoftRaster3d）の太陽の光と影の判定。約束は Scene3d.directionalShadowOf の doc。
pub mod SoftRaster3d.Sun {

    /// 影の判定に要る値。matrix = 光の行列の 16 個（行優先）・mapSize・depthBias・pcfRadius・normalShift・strength・
    /// map = 地図（行 0 が NDC の y = −1 側）・view = 目の位置 3 つと前の向き 3 つ・distance・fadeWidth（Scene3d.SunShadowSetup）。
    pub enum Shadow {
        case Shadow(Vector[Float64], Int32, Float64, Int32, Float64, Float64, Vector[Float64], Vector[Float64], Float64, Float64)
    }

    /// 場面の太陽。点から太陽への向きの x・y・z・linear の color × intensity の r・g・b・影（無ければ None）。
    /// 太陽が無い場面は向きも色も 0（拡散も鏡面も 0 になる）。
    // WhyNot: Option[DirectionalLight] のまま画素ごとに読まない — レコードの欄は名前で引くので、画素の数だけ重くなる。
    pub enum Light {
        case Light(Float64, Float64, Float64, Float64, Float64, Float64, Option[Shadow])
    }

    /// 太陽の無い場面。
    pub def none(): Light = Light.Light(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, None)

    /// 太陽 light（Scene3d.directionalLightOf の値）と影 shadow の太陽。light が None なら太陽なし。
    pub def of(light: Option[Scene3d.DirectionalLight], shadow: Option[Shadow]): Light = match light {
        case None    => none()
        case Some(l) =>
            let t = Scene3d.sunTermsOf(l);
            Light.Light(t#toward#x, t#toward#y, t#toward#z, t#color#x, t#color#y, t#color#z, shadow)
    }

    /// 太陽（toward = 点から太陽への向き・color = color × intensity。値はそのまま使う）。engine の開発用の口（gl-parity の式の行）。
    pub def raw(toward: Vec3.Vec3, color: Vec3.Vec3, shadow: Option[Shadow]): Light =
        Light.Light(toward#x, toward#y, toward#z, color#x, color#y, color#z, shadow)

    /// 影の判定の材料を組む（setup = Scene3d.directionalShadowOf・eye = カメラの目・map = 影の地図）。
    pub def shadowOf(setup: Scene3d.SunShadowSetup, eye: Vec3.Vec3, map: Vector[Float64]): Shadow =
        let f = setup#forward;
        Shadow.Shadow(SoftRaster3d.rowMajorOf(setup#matrix), setup#mapSize, setup#depthBias, setup#pcfRadius, setup#normalShift, setup#strength, map,
                      Vector#{ eye#x, eye#y, eye#z, f#x, f#y, f#z }, setup#distance, setup#fadeWidth)

    /// 点から太陽への向きの x・y・z と、color × intensity の r・g・b。
    pub def terms(s: Light): (Float64, Float64, Float64, Float64, Float64, Float64) =
        let Light.Light(tx, ty, tz, cr, cg, cb, _) = s;
        (tx, ty, tz, cr, cg, cb)

    /// world の点 (px, py, pz) へ届く太陽の光に掛ける影の割合（式は LightModel3d の頭の sunLit）。(gx, gy, gz) = 点を地図の画素の幅だけずらす向きの
    /// 法線（法線マップを当てる前・裏の面は裏返した物）・(nx, ny, nz) = 光の計算に使う法線。影の地図が無い・太陽へ背を向けている・
    /// 影を薄める距離の外は 1。GL の sunLitAt（Render3dGlsl）と同じ式で、gl-parity の式の行が値をそろえて確かめる。
    // WhyNot: 太陽へ背を向けた点で地図を引かない — facing が 0 なので掛ける先が 0 で、pcf の (2r+1)² 回が無駄になる。
    pub def litAt(s: Light, px: Float64, py: Float64, pz: Float64, gx: Float64, gy: Float64, gz: Float64,
                  nx: Float64, ny: Float64, nz: Float64): Float64 = match s {
        case Light.Light(tx, ty, tz, _, _, _, Some(shadow)) =>
            if (nx * tx + ny * ty + nz * tz <= 0.0) 1.0 else shadowedLit(shadow, px, py, pz, gx, gy, gz)
        case _ => 1.0
    }

    def shadowedLit(shadow: Shadow, px: Float64, py: Float64, pz: Float64, gx: Float64, gy: Float64, gz: Float64): Float64 =
        let Shadow.Shadow(m, n, bias, pcf, shift, strength, map, view, distance, fadeWidth) = shadow;
        let depth = (px - Vector.get(0, view)) * Vector.get(3, view) + (py - Vector.get(1, view)) * Vector.get(4, view)
                    + (pz - Vector.get(2, view)) * Vector.get(5, view);
        let fade = Float64.max(0.0, Float64.min(1.0, (distance - depth) / fadeWidth));
        if (fade <= 0.0) 1.0
        else 1.0 - strength * fade * (1.0 - SoftRaster3d.shadowLitFractionAt(m, n, bias, pcf, map, shift, px, py, pz, gx, gy, gz))
}
