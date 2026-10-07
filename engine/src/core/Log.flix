// Log — 既定値で続けたことを人へ 1 行知らせる口。文面と出し先を 1 箇所に持つ。
// 出し先の決まりと定型文は docs/error-handling.md の決まり 3 にある。
pub mod Log {
    import java.lang.System

    /// stderr へ 1 行。効果は `unsafe IO` で隠す
    /// （知らせるためだけに呼び側の効果行を広げない）。
    pub def warn(line: String): Unit =
        unsafe IO {
            System.err.println(line)
        }

    /// 既定値へ替えた事実を定型文で 1 行知らせる。
    /// domain は領域名（shader / doc / terrain など）、subject は替えた対象、
    /// fallback は替えた先の名前、reason は替えた理由。
    pub def fellBack(domain: String, subject: String, fallback: String, reason: String): Unit =
        warn("${domain} fail-open: ${subject} を${fallback}に替えました — ${reason}")
}
