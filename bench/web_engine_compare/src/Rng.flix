// Rng — 比べる相手のベンチと同じ並びの乱数（mulberry32）。k 番目の値は種と k だけで決まるので、前の値を回さずに引ける。
mod Rng {
    use fge::Num

    /// 1 回ごとに状態へ足す数（mulberry32 の決まりの値）。
    def step(): Int32 = 1831565813

    /// 種 seed の列の k 番目（0 から）の値（0 以上 1 未満）。
    pub def at(seed: Int32, k: Int32): Float64 =
        let a = seed + (k + 1) * step();
        let t1 = Int32.bitwiseXor(a, Int32.logicalRightShift(dist = 15, a)) * Int32.bitwiseOr(a, 1);
        let t2 = Int32.bitwiseXor(t1, t1 + Int32.bitwiseXor(t1, Int32.logicalRightShift(dist = 7, t1)) * Int32.bitwiseOr(t1, 61));
        let out = Int32.bitwiseXor(t2, Int32.logicalRightShift(dist = 14, t2));
        Int64.toFloat64(Int64.bitwiseAnd(4294967295i64, Int32.toInt64(out))) / 4294967296.0

    /// 種 seed の列の k 番目を min..max へ広げた値。
    pub def rangeAt(seed: Int32, k: Int32, span: { min = Float64, max = Float64 }): Float64 =
        span#min + (span#max - span#min) * at(seed, k)

    /// 種 seed の列の k 番目から作る 0 以上 n 未満の整数。
    pub def intAt(seed: Int32, k: Int32, n: Int32): Int32 =
        Num.floorInt(at(seed, k) * Int32.toFloat64(n))

    /// 種 seed の列の k 番目と k + 1 番目から作る、球の上に一様に散る長さ 1 の向き（x, y, z）。
    pub def unitAt(seed: Int32, k: Int32): (Float64, Float64, Float64) =
        let z = at(seed, k) * 2.0 - 1.0;
        let phi = at(seed, k + 1) * Num.tau();
        let r = Num.sqrt(1.0 - z * z);
        (r * Num.cos(phi), r * Num.sin(phi), z)
}
