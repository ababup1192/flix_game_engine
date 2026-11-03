// Quat — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 回転の四元数（開いたレコード。Vec3 と同じ）。w が実部。
pub mod Quat {

    pub type alias Quat = { x = Float64, y = Float64, z = Float64, w = Float64 }

    /// 回さない向き。
    pub def identity(): Quat = { x = 0.0, y = 0.0, z = 0.0, w = 1.0 }

    /// 長さ 1 に直した物。長さ 0 の時は identity。
    // WhyNot: 0 で割って NaN にしない — 書き出しの壊れた 0 の四元数が 1 つあるだけで、行列の全部が NaN になる。
    pub def normalized(q: Quat): Quat =
        let len = Num.sqrt(q#x * q#x + q#y * q#y + q#z * q#z + q#w * q#w);
        if (len < 1.0e-12) identity()
        else { x = q#x / len, y = q#y / len, z = q#z / len, w = q#w / len }

    /// a から b へ球面の上をなめらかにつなぐ（t = 0 で a・1 で b。結果は長さ 1）。
    /// 内積が負なら b を反転して短い側の弧を通る（q と −q は同じ回転）。
    // WhyNot: ほぼ同じ向きの時に sin で割らない — 角が 0 に近いと割る数が 0 に近づいて値が暴れるので、そこは成分ごとにつないで長さを直す。
    pub def slerp(a: Quat, b: Quat, t: Float64): Quat =
        let raw = a#x * b#x + a#y * b#y + a#z * b#z + a#w * b#w;
        let sign = if (raw < 0.0) -1.0 else 1.0;
        let d = raw * sign;
        let (wa, wb) =
            if (d > 0.9995) (1.0 - t, t * sign)
            else {
                let theta = Num.atan2(Num.sqrt(1.0 - d * d), d);
                let s = Num.sin(theta);
                (Num.sin((1.0 - t) * theta) / s, Num.sin(t * theta) / s * sign)
            };
        normalized({ x = a#x * wa + b#x * wb, y = a#y * wa + b#y * wb, z = a#z * wa + b#z * wb, w = a#w * wa + b#w * wb })

    /// 回転の行列（平行移動なし）。q は長さ 1 として読む。
    pub def toMat4(q: Quat): Mat4.Mat4 =
        let x = q#x; let y = q#y; let z = q#z; let w = q#w;
        Mat4.ofLinearRows(Vec3.v3(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w),       2.0 * (x * z + y * w)),
                          Vec3.v3(2.0 * (x * y + z * w),       1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w)),
                          Vec3.v3(2.0 * (x * z - y * w),       2.0 * (y * z + x * w),       1.0 - 2.0 * (x * x + y * y)))
}
