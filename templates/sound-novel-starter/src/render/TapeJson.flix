// TapeJson — tape.json と restore.json の値の小物（秒・数・問いの値を JSON に）。TapeOut と MigrateOut が同じ書き方で書く。
mod TapeJson {
    use fge::{Flow, JsonCodec, Resources}
    use Util.Json.Json

    type alias AppState = Resources.With[Res.Res, World.World]

    /// i フレーム目の秒（小数 3 桁に丸める）。
    pub def secondsAt(fps: Float64, i: Int32): Float64 = Float64.round(Int32.toFloat64(i) / fps * 1000.0) / 1000.0

    pub def intJson(n: Int32): Json = Json.JNumber(JsonCodec.intToBd(n))

    /// 整数の値は整数（3 → 3）、それ以外は小数 4 桁まで。
    pub def numJson(x: Float64): Json =
        if (Float64.floor(x) == x) Float64.tryToInt32(x) |> Option.map(intJson) |> Option.getWithDefault(Json.JNumber(JsonCodec.floatToBd(x)))
        else Json.JNumber(JsonCodec.floatToBd(Float64.round(x * 10000.0) / 10000.0))

    /// 数は整数なら整数で書く。
    pub def valueJson(v: Flow.Value): Json = match v {
        case Flow.Value.Num(x)  => numJson(x)
        case Flow.Value.Text(s) => Json.JString(s)
        case Flow.Value.Flag(b) => Json.JBool(b)
    }

    /// flow の問いを、AppState から値を読む関数に。
    pub def probeValue(read: Flow.Probe[AppState]): AppState -> Flow.Value = h -> match read {
        case Flow.Probe.Num(f)  => Flow.Value.Num(f(h))
        case Flow.Probe.Text(f) => Flow.Value.Text(f(h))
        case Flow.Probe.Flag(f) => Flow.Value.Flag(f(h))
    }
}
