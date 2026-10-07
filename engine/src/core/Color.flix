// Color — 3 チャンネル sRGB-linear カラー (alpha は別途持つ運用)
//
// Float64 ベース。レンジ 0.0〜1.0。GL の uniform や AWT へ渡す Float32 化はバックエンドの入り口でやる。
// engine（契約層）の共有型なので、フロントのシーングラフとバックエンド（render_gl）が同じ色定義を見る。
//
// 混ぜる・明暗を付ける計算は Float32 に落としてから行う。バックエンドが Float32 で受け取るので、
// ここを Float64 のまま計算すると丸めの回数がバックエンドとずれて 8bit 量子化の境目が動く。

pub type alias Color = {r = Float64, g = Float64, b = Float64}

pub mod Color {

    /// 0〜1 の 3 つ組から色を作る。
    pub def rgb(r: Float64, g: Float64, b: Float64): Color =
        { r = r, g = g, b = b }

    /// 0〜255 の 3 つ組から色を作る。色見本（パレット表）は 255 段階で配られるので、
    /// 255 で割った 6 桁の小数を書き写さずに済む。
    pub def rgb8(r: Int32, g: Int32, b: Int32): Color =
        { r = byte(r), g = byte(g), b = byte(b) }

    /// "#rrggbb"（先頭の # は省略可）から色を作る。6 桁の 16 進でなければ None。
    /// 色見本をそのまま貼れるので、手で 255 で割らない。
    pub def hex(text: String): Option[Color] =
        let body = if (String.startsWith(prefix = "#", text)) String.drop(1, text) else text;
        match String.toList(body) {
            case r0 :: r1 :: g0 :: g1 :: b0 :: b1 :: Nil =>
                match (byteOf(r0, r1), byteOf(g0, g1), byteOf(b0, b1)) {
                    case (Some(r), Some(g), Some(b)) => Some({ r = byte(r), g = byte(g), b = byte(b) })
                    case _                           => None
                }
            case _ => None
        }

    /// 色を "#rrggbb" の文字列にする（hex の逆）。0〜1 の外へ出た値は端で止め、
    /// 各チャンネルを 0〜255 の整数へ四捨五入する。色票 JSON（*.palette.json）や
    /// theme を書き出すときの表記をここに一本化する — 桁の丸め方が呼び側ごとに違うと、
    /// 同じ色が別の文字列になって差分が読めなくなる。
    pub def toHex(color: Color): String =
        "#${hexByte(color#r)}${hexByte(color#g)}${hexByte(color#b)}"

    def hexByte(v: Float64): String =
        let n = Num.clampInt(0, 255, Num.roundInt(Num.clamp01(v) * 255.0));
        "${hexDigit(n / 16)}${hexDigit(Int32.remainder(n, 16))}"

    def hexDigit(n: Int32): String =
        Char.toString(String.charAt(Num.clampInt(0, 15, n), "0123456789abcdef"))

    /// 2 色の間を t（0〜1）で混ぜる。lighten（白へ）/ darken（黒へ）が「片方が決め打ち」
    /// なのに対し、こちらは任意の 2 色をつなぐ（グラデーションの段階・状態の移り変わり）。
    pub def mix(a: Color, b: Color, t: Float64): Color =
        let k = f32(t);
        { r = wide(f32(a#r) + (f32(b#r) - f32(a#r)) * k),
          g = wide(f32(a#g) + (f32(b#g) - f32(a#g)) * k),
          b = wide(f32(a#b) + (f32(b#b) - f32(a#b)) * k) }

    /// 3 チャンネルを組にして取り出す。Color は record なので **そのままでは比べられない**
    /// （Flix の record は Eq を持てない）。比べたい・並べ替えたい・Map の鍵にしたいときは
    /// これを通す。テストで色を pin するときの定石でもある。
    pub def channels(color: Color): (Float64, Float64, Float64) =
        (color#r, color#g, color#b)

    def byte(v: Int32): Float64 =
        Int32.toFloat64(v) / 255.0

    def f32(v: Float64): Float32 = RenderUtil.f32(v)

    def wide(v: Float32): Float64 = Float32.toFloat64(v)

    def byteOf(hi: Char, lo: Char): Option[Int32] =
        forM (h <- nibble(hi); l <- nibble(lo)) yield h * 16 + l

    def nibble(c: Char): Option[Int32] =
        let code = Char.toBmpCodePoint(c);
        if (code >= 48 and code <= 57) Some(code - 48)
        else if (code >= 97 and code <= 102) Some(code - 97 + 10)
        else if (code >= 65 and code <= 70) Some(code - 65 + 10)
        else None

    /// 色を白へamountだけ近づける。通常は0から1を渡し、範囲外は補正しない。
    /// 既存ゲームと同じ色を保つため、amountをFloat32へ変えてから各チャンネルを補間する。
    pub def lighten(color: Color, amount: Float64): Color =
        let value = f32(amount);
        { r = wide(f32(color#r) + (1.0f32 - f32(color#r)) * value),
          g = wide(f32(color#g) + (1.0f32 - f32(color#g)) * value),
          b = wide(f32(color#b) + (1.0f32 - f32(color#b)) * value) }

    /// 色を黒へamountだけ近づける。通常は0から1を渡し、範囲外は補正しない。
    /// 丸め順を保つため、Float64で残す割合を求めてからFloat32へ変える。
    pub def darken(color: Color, amount: Float64): Color =
        let remaining = f32(1.0 - amount);
        { r = wide(f32(color#r) * remaining),
          g = wide(f32(color#g) * remaining),
          b = wide(f32(color#b) * remaining) }

    /// 暖色（黄寄り）へ amount だけ近づける。lighten と対で使う。
    /// 明暗だけで塗ると面が塊に見えるので、光の当たる側は暖色・影の側は寒色へずらす。
    /// 離れて見ると 2 色が混ざり、実際に使った色数より多くの階調があるように見える。
    pub def warm(color: Color, amount: Float64): Color =
        let t = f32(amount);
        { r = wide(pin01(f32(color#r) + t * 0.30f32)),
          g = wide(pin01(f32(color#g) + t * 0.18f32)),
          b = wide(pin01(f32(color#b) - t * 0.14f32)) }

    /// 寒色（青寄り）へ amount だけ近づける（warm の対）。影の側に使う。
    pub def cool(color: Color, amount: Float64): Color =
        let t = f32(amount);
        { r = wide(pin01(f32(color#r) - t * 0.18f32)),
          g = wide(pin01(f32(color#g) - t * 0.06f32)),
          b = wide(pin01(f32(color#b) + t * 0.16f32)) }

    def pin01(v: Float32): Float32 = Float32.max(0.0f32, Float32.min(1.0f32, v))

    /// 目に映る明るさ（0〜1）。3 チャンネルの平均で採らないのは、人の目が緑にいちばん
    /// 敏感だから — 平均だと同じ数字の赤と緑が違う明るさに見える。緑だけ倍に数える。
    /// 「明るいところだけ / 暗いところだけを拾う」判断に使う（映り込み・しきい処理）。
    pub def brightness(color: Color): Float64 =
        (wide(f32(color#r)) + wide(f32(color#g)) * 2.0
            + wide(f32(color#b))) / 4.0

    /// HSV から色を作る。h は色相（1 周 = 1.0・0 = 赤・範囲外は折り返し）、s は鮮やかさ、
    /// v は明るさ（どちらも 0〜1）。「値に沿って色相を流す」（虹のグラデーション・
    /// 残量ゲージの緑→赤）が 1 行で導ける。
    /// 同型の Float64 が並ぶので、取り違え防止にレコードで名前渡しする。
    pub def hsv(spec: {h = Float64, s = Float64, v = Float64}): Color =
        let h6 = (spec#h - Float64.floor(spec#h)) * 6.0;
        let f = h6 - Float64.floor(h6);
        let p = spec#v * (1.0 - spec#s);
        let q = spec#v * (1.0 - spec#s * f);
        let u = spec#v * (1.0 - spec#s * (1.0 - f));
        let (r, g, b) =
            if (h6 < 1.0) (spec#v, u, p)
            else if (h6 < 2.0) (q, spec#v, p)
            else if (h6 < 3.0) (p, spec#v, u)
            else if (h6 < 4.0) (p, q, spec#v)
            else if (h6 < 5.0) (u, p, spec#v)
            else (spec#v, p, q);
        { r = clamp01(r), g = clamp01(g), b = clamp01(b) }

    /// 0〜1 へ収める。
    def clamp01(x: Float64): Float64 =
        Float64.max(0.0, Float64.min(1.0, x))
}
