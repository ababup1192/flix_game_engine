// Simulation3d.Internal — 宣言の中身を描き手（render_gl・engine_tools）と CPU の規則とテストへ渡す口。

/// Simulation3d の中身。ゲームからは呼ばない（ゲームは Simulation3d の作る関数で宣言を組む）。
pub mod Simulation3d.Internal {

    /// プリセットの規則（データ）。CPU の規則（Simulation3d.Internal.Cpu）と kernel（render_gl）がこの enum を網羅の match で引く。
    /// WhyNot: Simulation3d.Preset の中身を直に pub の enum にしない — ゲームが case で作れてしまい、目印 k（要素かセルか）と食い違う物を書ける。
    pub enum PresetRules { case Flock(Simulation3d.FlockRules) }

    /// プリセットの種類（構造の値の比べ・字にする所）。
    pub enum PresetKind with Eq, Order, ToString { case Flock }

    /// 宣言の中身。id = 状態の鍵（並びの位置ではない）・count = 数・bounds = 要素を閉じ込める箱・time = 遊びの時計の今の秒・
    /// seed = 初めの散らばり・fallbackCount = WebGPU の無い描き手での数の上限・prewarmSteps = 作り直す時に先に進める刻みの数。
    pub type alias Fields[k] = { id = String, preset = Simulation3d.Preset[k], count = Int32, bounds = Mesh3d.Bounds, time = Float64,
                                 seed = Int32, fallbackCount = Int32, prewarmSteps = Int32 }

    /// 構造の値（変わったら状態を作り直す物）: プリセットの種類・数・seed。
    pub enum Structure with Eq, ToString { case Structure(PresetKind, Int32, Int32) }

    pub def fieldsOf(sim: Simulation3d.Simulation3d[k]): Fields[k] = Simulation3d.fieldsOf(sim)

    pub def rulesOf(sim: Simulation3d.Simulation3d[k]): PresetRules = Simulation3d.rulesOf(fieldsOf(sim)#preset)

    pub def kindOf(rules: PresetRules): PresetKind = match rules {
        case PresetRules.Flock(_) => PresetKind.Flock
    }

    /// 宣言（seed・fallbackCount・prewarmSteps は既定）。
    pub def make(id: String, preset: Simulation3d.Preset[k], count: Int32, bounds: Mesh3d.Bounds, time: Float64): Simulation3d.Simulation3d[k] =
        Simulation3d.SimulationData.SimulationData({ id = id, preset = preset, count = Int32.max(0, count), bounds = bounds, time = time,
                                                     seed = 1, fallbackCount = defaultFallbackCount(), prewarmSteps = defaultPrewarmSteps() })

    /// 中身を f で書き替えた宣言（作る関数の with* が通る 1 か所）。
    pub def mapFields(f: Fields[k] -> Fields[k], sim: Simulation3d.Simulation3d[k]): Simulation3d.Simulation3d[k] =
        Simulation3d.SimulationData.SimulationData(f(fieldsOf(sim)))

    /// 群れのプリセット。
    pub def flockPreset(rules: Simulation3d.FlockRules): Simulation3d.Preset[Simulation3d.Elements] =
        Simulation3d.PresetData.PresetData(PresetRules.Flock(rules))

    /// 群れの規則の既定値（8,000 個で近所の数が平均 60 前後に収まる組。C0 の測りの組）。
    pub def defaultFlockRules(): Simulation3d.FlockRules =
        { neighborRadius = 2.0, separationRadius = 0.8, cohesion = 0.5, alignment = 1.5, separation = 2.0,
          maxSpeed = 5.0, maxForce = 10.0, margin = 3.0, target = None, targetWeight = 0.0 }

    pub def defaultFallbackCount(): Int32 = 512

    pub def defaultPrewarmSteps(): Int32 = 120

    /// CPU で解く描き手の数（count と fallbackCount の小さい方）。
    pub def cpuCountOf(sim: Simulation3d.Simulation3d[k]): Int32 =
        let r = fieldsOf(sim);
        Int32.max(0, Int32.min(r#count, r#fallbackCount))

    /// 数を count にした時の構造の値。
    pub def structureOf(count: Int32, sim: Simulation3d.Simulation3d[k]): Structure =
        Structure.Structure(kindOf(rulesOf(sim)), count, fieldsOf(sim)#seed)

    /// Float32 の 3 成分（GPU の vec3f と同じ丸め）。
    pub type alias Vec3f = { x = Float32, y = Float32, z = Float32 }

    /// 群れの 1 刻みの値（GPU の uniform と CPU の規則が同じ物を読む）。gx・gy・gz = セルの数（各 1〜32）・cellSize = セルの大きさ（各 neighborRadius 以上）。
    pub type alias FlockParams = { count = Int32, gx = Int32, gy = Int32, gz = Int32, lo = Vec3f, hi = Vec3f, cellSize = Vec3f, dt = Float32,
                                   neighborRadius = Float32, separationRadius = Float32, cohesion = Float32, alignment = Float32,
                                   separation = Float32, maxSpeed = Float32, maxForce = Float32, margin = Float32,
                                   target = Option[Vec3f], targetWeight = Float32 }

    /// セルの数の 1 軸の上限（32³ = 32,768 セル）。
    pub def maxCellsPerAxis(): Int32 = 32

    pub def stepsPerSecond(): Int32 = 60

    def f32(x: Float64): Float32 = Float64.truncateToFloat32(x)

    def vec3f(v: Vec3.Vec3): Vec3f = { x = f32(v#x), y = f32(v#y), z = f32(v#z) }

    /// 1 軸のセルの数（箱の幅 ÷ 近所の距離の床・1〜32）。
    // WhyNot: 幅 ÷ 半径をそのまま床にしない — 割り切れるとセルが半径ちょうどになり、f32 の (x − lo) ÷ size の丸めで半径未満の 2 個が 2 セル離れて数えられる。
    def cellsAlong(extent: Float64, radius: Float64): Int32 =
        Float64.min(Float64.max(Float64.floor(extent / (radius * 1.0001)), 1.0), Int32.toFloat64(maxCellsPerAxis()))
            |> Float64.tryToInt32 |> Option.getWithDefault(1)

    /// rules・bounds・count から 1 刻みの値を作る。半径は 1e-3 以上・separationRadius は neighborRadius 以下に丸める。
    // WhyNot: セルの大きさを neighborRadius そのものにしない — 箱の幅が割り切れないと端のセルがはみ出し、32 で頭打ちにした時は半径より大きくしないと近所を落とす。
    pub def flockParamsOf(rules: Simulation3d.FlockRules, bounds: Mesh3d.Bounds, count: Int32): FlockParams =
        let radius = Float64.max(rules#neighborRadius, 1.0e-3);
        let lo = bounds#min;
        let hi = { x = Float64.max(lo#x, bounds#max#x), y = Float64.max(lo#y, bounds#max#y), z = Float64.max(lo#z, bounds#max#z) };
        let gx = cellsAlong(hi#x - lo#x, radius);
        let gy = cellsAlong(hi#y - lo#y, radius);
        let gz = cellsAlong(hi#z - lo#z, radius);
        let cell = (extent: Float64, n: Int32) -> f32(Float64.max(extent / Int32.toFloat64(n), 1.0e-6));
        { count = count, gx = gx, gy = gy, gz = gz, lo = vec3f(lo), hi = vec3f(hi),
          cellSize = { x = cell(hi#x - lo#x, gx), y = cell(hi#y - lo#y, gy), z = cell(hi#z - lo#z, gz) },
          dt = 1.0f32 / Int32.toFloat32(stepsPerSecond()),
          neighborRadius = f32(radius), separationRadius = f32(Float64.min(Float64.max(rules#separationRadius, 0.0), radius)),
          cohesion = f32(rules#cohesion), alignment = f32(rules#alignment), separation = f32(rules#separation),
          maxSpeed = f32(Float64.max(rules#maxSpeed, 0.0)), maxForce = f32(Float64.max(rules#maxForce, 0.0)), margin = f32(Float64.max(rules#margin, 0.0)),
          target = rules#target |> Option.map(vec3f), targetWeight = f32(rules#targetWeight) }
}
