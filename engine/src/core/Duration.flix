/// Duration — 時間の長さ（継続時間・経過時間・残り時間）を表す型
///
/// 設計意図:
///   - 「16.0 / 200.0」のような **裸の Float64 で時間を表すのを禁止** する
///   - `Duration.frames(count = 16, fps = 200)` のように **意図が読める形** で構築する
///   - Float64 と区別された型（newtype）にして、pixel や ratio との取り違えを防ぐ
///
/// 内部表現は **秒（Float64）** に揃える。最終的な物理計算では `toSeconds` で剥がす。
///
/// 使い分け:
///   - 継続時間（Tween 1 本の所要時間など）        : `Duration.seconds(0.5)` / `frames(...)`
///   - 1 フレーム分の経過（physicsProcess の delta）: gameLoop が毎フレーム生成
///   - カウントダウン残時間（Timer の timeLeft）     : 起動値から delta を引き続ける
pub mod Duration {

    /// 内部表現は秒。`Of` という単一コンストラクタでラップすることで
    /// `Float64` から区別された型にする。
    pub enum Duration with Eq, ToString {
        case Of(Float64)
    }

    // ════════════════════════════════════════════════════════
    // 構築
    // ════════════════════════════════════════════════════════

    /// 0 秒。「まだ何も経過していない」「カウントダウン完了」などの基準値。
    pub def zero(): Duration = Duration.Of(0.0)

    /// 秒単位で生成。`1.5 |> Duration.seconds` のようにパイプで書ける。
    pub def seconds(value: Float64): Duration = Duration.Of(value)

    /// ミリ秒単位で生成。`500 |> Duration.millis` で 0.5 秒。
    pub def millis(value: Int32): Duration =
        Duration.Of(Int32.toFloat64(value) / 1000.0)

    /// 「N フレーム分の時間」を fps 想定で生成。
    /// 例: `frames(count = 16, fps = 200)` で 0.08 秒（モーションが 200fps で 16 フレーム再生される長さ）。
    /// Tween の duration 設計時に「○フレーム分にしたい」を直接書ける。
    pub def frames(c: {count = Int32}, f: {fps = Int32}): Duration =
        Duration.Of(Int32.toFloat64(c#count) / Int32.toFloat64(f#fps))

    // ════════════════════════════════════════════════════════
    // 取り出し（境界用 — できる限り Duration のまま扱うこと）
    // ════════════════════════════════════════════════════════

    /// 秒単位の Float64 に戻す。Tween の lerp 計算など Float64 が必要な末端でだけ使う。
    pub def toSeconds(duration: Duration): Float64 =
        let Duration.Of(value) = duration;
        value

    // ════════════════════════════════════════════════════════
    // 演算
    // ════════════════════════════════════════════════════════

    /// 2 つの時間を足す。`elapsed + delta` のように経過を伸ばす用途。
    pub def add(a: Duration, b: Duration): Duration =
        Duration.Of(toSeconds(a) + toSeconds(b))

    /// `a - b` を返す。負になり得る（カウントダウン用）。
    /// 0 でクランプしたいときは `subClampedToZero` を使う。
    pub def sub(a: Duration, b: Duration): Duration =
        Duration.Of(toSeconds(a) - toSeconds(b))

    /// `a - b` を 0 でクランプして返す。Timer の timeLeft 減算など、
    /// 「マイナスは許さない、限界まで来たら 0 で止める」用途に使う。
    pub def subClampedToZero(a: Duration, b: Duration): Duration =
        Duration.Of(Float64.max(0.0, toSeconds(a) - toSeconds(b)))

    /// Float64 倍する。`lifetime * speedScale` のような縮尺調整用。
    pub def scale(duration: Duration, factor: Float64): Duration =
        Duration.Of(toSeconds(duration) * factor)

    /// `Duration / Float64` の除算。「lifetime / 個数 = 1 個あたりの間隔」のような計算用。
    pub def divBy(duration: Duration, divisor: Float64): Duration =
        Duration.Of(toSeconds(duration) / divisor)

    /// 経過時間 / 総時間 の進度を 0.0..1.0 に **クランプして** 返す。
    /// Tween の lerp 進度計算 (`min(1.0, elapsed / total)`) を 1 か所に集約する。
    pub def ratio(elapsed: Duration, total: Duration): Float64 =
        Float64.min(1.0, toSeconds(elapsed) / toSeconds(total))

    // ════════════════════════════════════════════════════════
    // 判定
    // ════════════════════════════════════════════════════════

    /// 残り時間が尽きたか（<= 0）。Timer のカウントダウン終了判定に使う。
    pub def isExpired(duration: Duration): Bool =
        toSeconds(duration) <= 0.0

    /// 正の長さを持つか（> 0）。「まだ動いている tween か」等の判定に使う。
    pub def isPositive(duration: Duration): Bool =
        toSeconds(duration) > 0.0
}
