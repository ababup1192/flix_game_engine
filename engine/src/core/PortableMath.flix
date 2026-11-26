// PortableMath — JVM と wasm（ブラウザ）で同じビットを返す数の道具。足し引き掛け割りと平方根だけで書く。
// 物理（PhysicsWorld2d・3D の物理）の中と、物理へ渡す向きを角度から作る所が使う。
// 描くだけの計算（色・画面の揺れ）は Num のままでよい（ずれても絵が数画素違うだけで、World は分かれない）。
// WhyNot: Num.sin（java.lang.Math）を使わない — TeaVM では JS の Math.sin になり、最下位ビットが JVM とずれる。
// WhyNot: Num の中に置かない — Num.sin と同じ名前が並び、取り違えやすい。
pub mod PortableMath {

    /// π。
    pub def pi(): Float64 = 3.141592653589793

    /// 平方根（IEEE で正しく丸めるので JVM と wasm で同じ）。
    pub def sqrt(x: Float64): Float64 = Num.sqrt(x)

    /// sin。[-π, π) へ畳んでから四分円で [-π/4, π/4] の多項式へ寄せる。-360〜360 度で Math.sin との差は 1e-12 未満。
    pub def sin(x: Float64): Float64 =
        let twoPi = 6.283185307179586;
        let k = Float64.floor((x + pi()) / twoPi);
        let r = x - k * twoPi;
        let halfPi = 1.5707963267948966;
        let quarter = 0.7853981633974483;
        if (r > 3.0 * quarter) sinPoly(pi() - r)
        else if (r > quarter) cosPoly(r - halfPi)
        else if (r >= -quarter) sinPoly(r)
        else if (r >= -3.0 * quarter) -cosPoly(r + halfPi)
        else -sinPoly(r + pi())

    /// cos（sin を π/2 ずらす）。
    pub def cos(x: Float64): Float64 = sin(x + 1.5707963267948966)

    /// atan2(y, x)。返す角は [-π, π]。(0, 0) は 0。y が -0.0 で x が負の時も π を返す（Math.atan2 は -π）。
    pub def atan2(y: Float64, x: Float64): Float64 =
        if (x == 0.0 and y == 0.0) 0.0
        else if (Float64.abs(y) <= Float64.abs(x)) {
            let a = atanUnit(y / x);
            if (x > 0.0) a else if (y >= 0.0) a + pi() else a - pi()
        } else {
            let a = atanUnit(x / y);
            if (y > 0.0) 1.5707963267948966 - a else -1.5707963267948966 - a
        }

    /// [-1, 1] の atan。半角の式を 2 回当てて [-tan(π/16), tan(π/16)] へ縮め、級数の 25 次まで。
    def atanUnit(t: Float64): Float64 =
        let t1 = t / (1.0 + sqrt(1.0 + t * t));
        let t2 = t1 / (1.0 + sqrt(1.0 + t1 * t1));
        let u = t2 * t2;
        let series = t2 * (1.0 - u * (1.0 / 3.0 - u * (1.0 / 5.0 - u * (1.0 / 7.0 - u * (1.0 / 9.0 - u * (1.0 / 11.0
            - u * (1.0 / 13.0 - u * (1.0 / 15.0 - u * (1.0 / 17.0 - u * (1.0 / 19.0 - u * (1.0 / 21.0 - u * (1.0 / 23.0 - u / 25.0))))))))))));
        4.0 * series

    /// [-π/4, π/4] の sin（テイラーの 15 次まで）。
    def sinPoly(r: Float64): Float64 =
        let r2 = r * r;
        r * (1.0 + r2 * (-1.0 / 6.0 + r2 * (1.0 / 120.0 + r2 * (-1.0 / 5040.0 + r2 * (1.0 / 362880.0 + r2 * (-1.0 / 39916800.0 + r2 * (1.0 / 6227020800.0 + r2 * (-1.0 / 1307674368000.0))))))))

    /// [-π/4, π/4] の cos（テイラーの 16 次まで）。
    def cosPoly(r: Float64): Float64 =
        let r2 = r * r;
        1.0 + r2 * (-0.5 + r2 * (1.0 / 24.0 + r2 * (-1.0 / 720.0 + r2 * (1.0 / 40320.0 + r2 * (-1.0 / 3628800.0 + r2 * (1.0 / 479001600.0 + r2 * (-1.0 / 87178291200.0 + r2 * (1.0 / 20922789888000.0))))))))
}
