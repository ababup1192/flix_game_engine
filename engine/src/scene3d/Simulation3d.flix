// Simulation3d — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 見た目だけの物を何千個も毎コマ規則で進める仕事の宣言（閉じた型。Unreal の Niagara の Simulation Stage・Unity の VFX Graph・Godot の GPUParticles3D に当たる）。
/// WebGPU の描き手は GPU の compute で進め、ほかの描き手（GL・WebGL2・CPU の描き出し）は数を減らして同じ規則を CPU で解く。
/// 状態は描き手の中にだけあり、位置を返す口は無い。当たり・押し合いのような遊びの規則には使わない（World に持って CPU で解く）。
/// 宣言の値は 2 種類: 構造の値（プリセットの種類・数・seed）が変わると状態を作り直し、毎コマの値（規則の値・箱・時刻）は作り直さない。
/// 型の引数 k は仕事の形の目印（今は Elements だけ）。
pub mod Simulation3d {

    /// 要素（count 個）の仕事の目印。出口は 1 体ごとの値の表（MultiMesh と同じ描く道）。
    pub enum Elements { case Elements }

    /// 群れ（Boids）の規則。毎コマ変えてよい（作り直さない）。長さは world の単位・速さは単位 / 秒・力は単位 / 秒²。
    /// neighborRadius = 近所と見る距離・separationRadius = 離れようとする距離（neighborRadius 以下）・
    /// cohesion = 近所の真ん中へ寄る重み・alignment = 近所の速さにそろう重み・separation = 近すぎる物から離れる重み・
    /// maxSpeed = 速さの上限・maxForce = 規則の力の上限・margin = 箱の端から中へ押し返し始める幅・
    /// target = 向かう点（None なら寄らない）・targetWeight = target へ寄る力。
    pub type alias FlockRules = { neighborRadius = Float64, separationRadius = Float64, cohesion = Float64, alignment = Float64,
                                  separation = Float64, maxSpeed = Float64, maxForce = Float64, margin = Float64,
                                  target = Option[Vec3.Vec3], targetWeight = Float64 }

    enum PresetData[_k] { case PresetData(Simulation3d.Internal.PresetRules) }

    /// 仕事の規則（閉じた型。中身はデータで、関数も kernel の名前も持たない）。
    pub type alias Preset[k] = PresetData[k]

    enum SimulationData[k] { case SimulationData(Simulation3d.Internal.Fields[k]) }

    /// 仕事の宣言（閉じた型）。
    pub type alias Simulation3d[k] = SimulationData[k]

    def fieldsOf(sim: Simulation3d[k]): Simulation3d.Internal.Fields[k] = let SimulationData.SimulationData(r) = sim; r

    def rulesOf(preset: Preset[k]): Simulation3d.Internal.PresetRules = let PresetData.PresetData(r) = preset; r
}
