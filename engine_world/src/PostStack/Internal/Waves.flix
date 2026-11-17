// PostStack.Internal.Waves — 向きと長さの違う波を重ねた揺らぎ（−1..1）の場。画面の歪みと霧のむらが使う。
// ゲームからは呼ばない（PostStack の中身）。
// WhyNot: Fbm・FbmTile（hash の value noise）を使わない — hash は fract(sin(大きい数) × 43758) で、GPU の float32 と CPU の Float64 で
// 模様がまるごと違う（3 つの描き手で同じ絵にならない）。sin の引数が数十までの波の和なら float32 でも 1e-5 ほどしか違わない。
pub mod PostStack.Internal.Waves {

    use ShaderDoc.{BinOp, Field, UnOp}

    /// 波 1 本: angle = 進む向き（ラジアン）・length = 波長（基準の長さに掛ける倍率）・weight = 重み（1 組の重みの和が 1）・phase0 = 頭の位相。
    pub type alias Wave = { angle = Float64, length = Float64, weight = Float64, phase0 = Float64 }

    pub def pi(): Float64 = 3.141592653589793

    /// 長さ 1 あたりの位相の進み（x, y）。unit = 基準の長さ。
    pub def waveNumber(unit: Float64, w: Wave): (Float64, Float64) =
        let kappa = 2.0 * pi() / (unit * w#length);
        (kappa * Num.cos(w#angle), kappa * Num.sin(w#angle))

    /// 模様が velocity（長さ / 秒）で流れる時の、時刻 time の位相（0..2π に折り返す）。
    // WhyNot: 時刻を Field.Time（面の t）で掛けない — 時刻 × 速さが増え続けると GL の float32 の sin が崩れる。CPU の Float64 で折り返してから渡す。
    pub def phaseAt(unit: Float64, velocity: Vec2.Vec2, time: Float64, w: Wave): Float64 =
        let (kx, ky) = waveNumber(unit, w);
        let raw = w#phase0 - (kx * velocity#x + ky * velocity#y) * time;
        raw - 2.0 * pi() * Float64.floor(raw / (2.0 * pi()))

    /// 位置 (x, y)（長さ）の揺らぎ。波 i の位相は Param phaseNames[i]。
    pub def field(x: Field, y: Field, unit: Float64, waves: List[Wave], phaseNames: List[String]): Field =
        List.zip(waves, phaseNames) |> List.map(e -> {
            let (w, name) = e;
            let (kx, ky) = waveNumber(unit, w);
            let arg = add(add(mul(x, Field.Const(kx)), mul(y, Field.Const(ky))), Field.Param({ name = name }));
            mul(Field.Const(w#weight), Field.Un({ op = UnOp.Sin, of = arg }))
        }) |> List.reduceLeft(add) |> Option.getWithDefault(Field.Const(0.0))

    def add(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Add, a = a, b = b })
    def mul(a: Field, b: Field): Field = Field.Bin({ op = BinOp.Mul, a = a, b = b })
}
