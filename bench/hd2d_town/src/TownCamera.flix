// TownCamera — HD-2D の町のカメラ: 水平に向けたまま写す範囲を下へずらす（Camera3d.lensShift）。
// 画面の上の端で地面を見下ろす角度 topDeg・下の端で bottomDeg を決めると、画角とずらす量が決まる
// （シフトのカメラでは、画面の行と見下ろす角度の tan が比例する）。座標は engine の (x = 東, y = 上, z = 北)。
mod TownCamera {
    use fge::{Camera3d, Num, Vec2, Vec3}
    use TownMap.{TownMap}

    def tanOf(rad: Float64): Float64 = Num.sin(rad) / Num.cos(rad)

    /// レンズ。ta・tb = 画面の上の端・下の端で地面を見下ろす角度の tan・fovY = 縦の画角・shiftY = lensShift の y（画面の高さに対する比）。
    pub type alias Lens = { ta = Float64, tb = Float64, fovY = Float64, shiftY = Float64 }

    /// 見下ろす角度の組（度）からレンズを作る。
    pub def lensOf(topDeg: Float64, bottomDeg: Float64): Lens =
        let ta = tanOf(topDeg * Num.pi() / 180.0);
        let tb = tanOf(bottomDeg * Num.pi() / 180.0);
        { ta = ta, tb = tb, fovY = 2.0 * Num.atan2((tb - ta) / 2.0, 1.0), shiftY = 0.0 - (ta + tb) / (2.0 * (tb - ta)) }

    /// 画面の高さ v（上の端 0・下の端 1）の行で地面を見下ろす角度の tan。
    pub def tanAt(lens: Lens, v: Float64): Float64 = lens#ta + v * (lens#tb - lens#ta)

    /// 写す範囲から決めたカメラの目の位置。eyeZ は地図の北の座標（engine の z）。
    pub type alias Eye = { x = Float64, height = Float64, z = Float64 }

    /// 地図の frame（地面の 1 点 anchor を画面の上から v の高さに置き、その奥行きで画面の横幅が width m）に合わせた目の位置。
    /// 画面の縦横の比は 16:9（Blender の試作の 36 mm のセンサーと同じ合わせ方）。
    pub def frameEye(m: TownMap, lens: Lens): Eye =
        let f = m#frame;
        let aspect = 16.0 / 9.0;
        // 画面の横幅が width m になる奥行き d: 横の画角の tan の半分は (tb − ta) / 2 × aspect
        let d = f#width / ((lens#tb - lens#ta) * aspect);
        let h = d * tanAt(lens, f#v);
        let anchorZ = Int32.toFloat64(m#height) - f#anchorRow;
        { x = f#anchorX, height = f#targetZ + h, z = anchorZ - d }

    /// 目の位置からカメラを作る（pitch 0・yaw 0・far は太陽の影の範囲とそろえて絞る）。
    pub def cameraAt(lens: Lens, far: Float64, eye: Eye): Camera3d.Camera3d =
        { near = 0.3, far = far, lensShift = Vec2.v2(0.0, lens#shiftY)
          | Camera3d.camera(Vec3.v3(eye#x, eye#height, eye#z), 0.0, 0.0, lens#fovY) }

    /// 高さ groundZ の地面で、画面の高さ v に写る点までの水平の奥行き。
    pub def depthAt(lens: Lens, eye: Eye, groundZ: Float64, v: Float64): Float64 = (eye#height - groundZ) / tanAt(lens, v)

    /// 画面の高さ v の行で、地面の 1 m が画面の高さの何割に写るか（地面が流れる速さを m/秒へ直すのに使う）。
    pub def screenPerMeterAt(lens: Lens, eye: Eye, groundZ: Float64, v: Float64): Float64 =
        let t = tanAt(lens, v);
        t * t / ((eye#height - groundZ) * (lens#tb - lens#ta))

    /// 1 テクセル（1/32 m）に丸める。
    pub def snapToTexel(v: Float64): Float64 = Float64.round(v * 32.0) / 32.0
}
