// StateHash — 状態のビットを 64 bit の指紋へ流す（FNV-1a の掛けと xor を 64 bit の語ごとに）。
// 物理の World の指紋（PhysicsWorld2d.stateHash）と、JVM と wasm の比べ・巻き戻しのテストが使う。
// WhyNot: 数を字にして hash しない — Float64.toString は JVM と wasm で字が違いうる。ビットのまま流す。
pub mod StateHash {
    import java.lang.Double

    enum StateHashOf with Eq, ToString {
        case StateHashOf(Int64)
    }

    /// 流している途中の指紋。中身は toInt64 で読む。
    pub type alias StateHash = StateHashOf

    /// 何も流していない指紋（FNV-1a の 64 bit の初期値）。
    pub def start(): StateHash = StateHashOf.StateHashOf(-3750763034362895579i64)

    /// 64 bit の語を 1 つ流す。
    pub def mixInt64(word: Int64, h: StateHash): StateHash = match h {
        case StateHashOf.StateHashOf(v) => StateHashOf.StateHashOf(Int64.bitwiseXor(v, word) * 1099511628211i64)
    }

    pub def mixInt32(word: Int32, h: StateHash): StateHash = mixInt64(Int32.toInt64(word), h)

    pub def mixBool(b: Bool, h: StateHash): StateHash = mixInt64(if (b) 1i64 else 0i64, h)

    /// Float64 のビットを流す（NaN は 1 つのビットに、-0.0 は 0.0 にまとめて流す）。
    // WhyNot: -0.0 と 0.0 を分けて流さない — 0 の符号は Math.max(-0.0, 0.0) などで JVM と wasm が分かれうる一方、値として同じ。0 の符号が 0 でない値を分けるのは 0 で割る所だけで、物理は割る前に 0 を確かめている。
    pub def mixFloat64(x: Float64, h: StateHash): StateHash = mixInt64(Double.doubleToLongBits(x + 0.0), h)

    pub def toInt64(h: StateHash): Int64 = match h { case StateHashOf.StateHashOf(v) => v }
}
