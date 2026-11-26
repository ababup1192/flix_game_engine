// Rot2 — 2D の向き（cos と sin の組・いつも長さ 1）。角度は持たない（Box2D 3 の b2Rot と同じ形）。
// 物理の中は組のまま回すので三角関数が要らず、JVM と wasm で同じビットになる。
// 角度から作る口（fromDegrees・fromRadians）は PortableMath を通る。
pub mod Rot2 {

    enum Rot2Of with Eq, ToString {
        case Rot2Of(Float64, Float64)
    }

    /// 向き。中身は cos・sin の読む口からだけ見える。
    pub type alias Rot2 = Rot2Of

    /// 回っていない向き。
    pub def identity(): Rot2 = Rot2Of.Rot2Of(1.0, 0.0)

    /// 組 (c, s) を長さ 1 に戻して向きにする（長さ 0・NaN・無限大の組は identity）。
    /// 組をそのまま信じる口なので、Num.cos・Num.sin で作った組を渡すと JVM と wasm で向きが分かれる（lint の rot2-from-num が知らせる）。
    pub def fromCosSin(c: Float64, s: Float64): Rot2 =
        let len2 = c * c + s * s;
        if (not (len2 > 0.0) or Float64.isInfinite(len2)) identity()
        else {
            let len = PortableMath.sqrt(len2);
            Rot2Of.Rot2Of(c / len, s / len)
        }

    /// 度から作る（Doc の角度・ゲームの入口）。y が下向きの画面の座標では、正の角は時計回りに見える。
    pub def fromDegrees(degrees: Float64): Rot2 = fromRadians(degrees * PortableMath.pi() / 180.0)

    /// ラジアンから作る。
    pub def fromRadians(radians: Float64): Rot2 = fromCosSin(PortableMath.cos(radians), PortableMath.sin(radians))

    pub def cos(r: Rot2): Float64 = match r { case Rot2Of.Rot2Of(c, _) => c }

    pub def sin(r: Rot2): Float64 = match r { case Rot2Of.Rot2Of(_, s) => s }

    /// 角（ラジアン・[-π, π]）。描く口（Render の回転）へ渡す時に使う。
    pub def toRadians(r: Rot2): Float64 = PortableMath.atan2(sin(r), cos(r))

    /// 角（度・[-180, 180]）。
    pub def toDegrees(r: Rot2): Float64 = toRadians(r) * 180.0 / PortableMath.pi()

    /// a だけ回した後に b だけ回した向き（角の足し算）。
    pub def mul(a: Rot2, b: Rot2): Rot2 =
        fromCosSin(cos(a) * cos(b) - sin(a) * sin(b), sin(a) * cos(b) + cos(a) * sin(b))

    /// 逆に回す向き。
    pub def inverse(r: Rot2): Rot2 = Rot2Of.Rot2Of(cos(r), -sin(r))

    /// 点 v を原点のまわりに r だけ回す。
    pub def rotate(v: Vec2.Vec2, r: Rot2): Vec2.Vec2 =
        { x = cos(r) * v#x - sin(r) * v#y, y = sin(r) * v#x + cos(r) * v#y }

    /// a と b の間を t（0〜1）でなめらかにつなぐ（組を混ぜて長さ 1 に戻す）。描く時の補間に使う。
    pub def nlerp(a: Rot2, b: Rot2, t: Float64): Rot2 =
        fromCosSin(cos(a) + (cos(b) - cos(a)) * t, sin(a) + (sin(b) - sin(a)) * t)
}
