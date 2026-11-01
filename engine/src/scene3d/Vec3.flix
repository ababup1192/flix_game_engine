// Vec3 — 3D の場面（Scene3d）の部品。座標の約束は scene3d/Scene3d.flix の頭。

/// 3D の点・向き（開いたレコード。Vec2 と同じ）。
pub mod Vec3 {

    /// x = 東・y = 上・z = 北。
    pub type alias Vec3 = { x = Float64, y = Float64, z = Float64 }

    /// (x, y, z) から作る。リストの中などでレコードの型が決まらない所の注釈を消す。
    pub def v3(x: Float64, y: Float64, z: Float64): Vec3 = { x = x, y = y, z = z }

    pub def zero(): Vec3 = v3(0.0, 0.0, 0.0)

    pub def one(): Vec3 = v3(1.0, 1.0, 1.0)

    pub def add(a: Vec3, b: Vec3): Vec3 = v3(a#x + b#x, a#y + b#y, a#z + b#z)

    pub def sub(a: Vec3, b: Vec3): Vec3 = v3(a#x - b#x, a#y - b#y, a#z - b#z)

    /// 長さを s 倍する。
    pub def mul(v: Vec3, s: Float64): Vec3 = v3(v#x * s, v#y * s, v#z * s)

    pub def dot(a: Vec3, b: Vec3): Float64 = a#x * b#x + a#y * b#y + a#z * b#z

    /// 外積。左手系では、外から見て時計回りの a → b → c について cross(b − a, c − a) が外を向く。
    pub def cross(a: Vec3, b: Vec3): Vec3 =
        v3(a#y * b#z - a#z * b#y, a#z * b#x - a#x * b#z, a#x * b#y - a#y * b#x)

    pub def length(v: Vec3): Float64 = Vec2.sqrt(dot(v, v))

    pub def distanceSquared(a: Vec3, b: Vec3): Float64 = let d = sub(a, b); dot(d, d)

    /// 長さ 1 にした向き。長さ 0 の時は 0 のまま返す。
    // WhyNot: 0 で割って NaN にしない — 面積 0 の面の法線が NaN だと、鍵（contentHash）と CPU の塗りが NaN を運ぶ。
    pub def normalized(v: Vec3): Vec3 =
        let len = length(v);
        if (len < 1.0e-12) zero() else mul(v, 1.0 / len)
}
